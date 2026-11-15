import Foundation
import RecognitionCore
import RecognitionTestSupport
@testable import Resonance
import Synchronization
import Testing

@MainActor
struct RecognitionPresentationTests {
    private let workflow = PresentationWorkflow()
    private let opener = RecordingURLOpener()

    @Test(arguments: [
        (.idle, "Ready to recognize", false),
        (.starting, "Starting audio capture…", true),
        (.listening, "Listening…", true),
        (.searching, "Searching Shazam…", true),
        (.cancelled, "Recognition cancelled", false),
        (.noMatch, "No song found", false),
        (.failed(.noAudio), "No audio received", false),
        (.failed(.audioPermissionDenied), "System audio access is needed", false),
        (.failed(.silence), "Only silence received", false),
        (.failed(.recognitionTimedOut), "Shazam took too long to respond", false),
    ] as [(RecognitionState, String, Bool)])
    func `Workflow states map to accessible status and actions`(
        state: RecognitionState, status: String, isActive: Bool
    ) {
        let model = makeModel()
        model.apply(.init(state: state))

        #expect(String(localized: model.status.title) == status)
        #expect(model.canCancel == isActive)
        #expect(model.canRecognize == !isActive)
    }

    @Test func `Commands dispatch explicitly and retry uses recognize`() async {
        var settingsOpened = false
        var quit = false
        let model = makeModel(quit: { quit = true })

        await model.requestRecognition()?.value
        model.apply(.init(state: .listening))
        await model.requestRecognition()?.value
        await model.cancel()
        model.apply(.init(state: .noMatch))
        #expect(String(localized: model.recognizeTitle) == "Try Again")
        await model.requestRecognition()?.value
        model.openSettings { settingsOpened = true }
        model.quit()

        #expect(await workflow.recognizeCount == 2)
        #expect(await workflow.cancelCount == 1)
        #expect(settingsOpened)
        #expect(quit)
    }

    @Test func `First use waits for agreement and remembers it`() async {
        let firstUse = FirstUseState()
        let model = makeModel(
            needsExplanation: { !firstUse.seen },
            explain: {
                firstUse.explanationCount += 1
                return firstUse.accept
            },
            markSeen: { firstUse.seen = true }
        )

        await model.requestRecognition()?.value
        #expect(await workflow.recognizeCount == 0)
        #expect(!firstUse.seen)

        firstUse.accept = true
        await model.requestRecognition()?.value
        await model.requestRecognition()?.value
        #expect(firstUse.seen)
        #expect(firstUse.explanationCount == 2)
        #expect(await workflow.recognizeCount == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `A retry queued during cleanup is visible and can be cancelled`(cancelRetry: Bool) async throws {
        let stopStarted = AsyncStream<Void>.makeStream()
        let allowStop = AsyncStream<Void>.makeStream()
        defer { allowStop.continuation.finish() }
        let firstCapture = FakeAudioCapture(beforeStop: {
            stopStarted.continuation.yield(())
            for await _ in allowStop.stream {}
        })
        let retryCapture = FakeAudioCapture()
        let captures = Mutex([firstCapture, retryCapture])
        let coordinator = RecognitionCoordinator(
            makeCapture: { captures.withLock { $0.removeFirst() } },
            makeRecognizer: { FakeRecognition() }
        )
        let model = makeModel(workflow: coordinator)
        await model.requestRecognition()?.value
        model.apply(try await listeningSnapshot(from: coordinator))
        await model.cancel()
        var stops = stopStarted.stream.makeAsyncIterator()
        try #require(await stops.next() != nil)
        var updates = await coordinator.updates().makeAsyncIterator()
        model.apply(try #require(await updates.next()))
        #expect(model.canRecognize)

        await model.requestRecognition()?.value
        model.apply(try #require(await updates.next()))
        #expect(String(localized: model.status.title) == "Recognition queued")
        #expect(model.canCancel)
        #expect(!model.canRecognize)
        #expect(await retryCapture.attempts.isEmpty)

        if cancelRetry {
            await model.cancel()
            model.apply(try #require(await updates.next()))
            #expect(String(localized: model.status.title) == "Recognition cancelled")
            #expect(!model.canCancel)
            #expect(model.canRecognize)
        }

        allowStop.continuation.finish()
        if !cancelRetry {
            model.apply(try await listeningSnapshot(from: coordinator))
            #expect(model.canCancel)
            #expect(await retryCapture.attempts.count == 1)
        }
        await coordinator.shutdown()
        if cancelRetry {
            #expect(await retryCapture.attempts.isEmpty)
        }
    }

    @Test(arguments: [nil, "/local", "file:///tmp/fixture", "music://example.com", "https://user@example.com"])
    func `Absent and unsupported URLs do not appear or open`(rawURL: String?) throws {
        let model = makeModel()
        let url = try rawURL.map { try #require(URL(string: $0)) }
        let track = RecognizedTrack(id: "fixture", title: " \n", artist: nil, appleMusicURL: url)
        model.apply(.init(state: .matched(track), lastTrack: track))

        #expect(model.track?.title == "Unknown song")
        #expect(model.track?.artist == "Unknown artist")
        #expect(model.track?.appleMusicURL == nil)
        #expect(model.track?.openAppleMusic == nil)
        #expect(opener.opened.isEmpty)
    }

    @Test func `Returned link opens only when requested and last match survives retry`() throws {
        let model = makeModel()
        let url = try #require(URL(string: "https://music.apple.com/us/album/test/123"))
        let track = RecognizedTrack(id: "fixture", title: " Song ", artist: "Artist", appleMusicURL: url)
        model.apply(.init(state: .matched(track), lastTrack: track))

        #expect(model.track?.title == "Song")
        #expect(model.track?.artist == "Artist")
        #expect(model.isLatestMatch)
        #expect(opener.opened.isEmpty)
        let action = try #require(model.track?.openAppleMusic)
        action()
        #expect(opener.opened == [url])

        model.apply(.init(state: .listening, lastTrack: track))
        #expect(!model.isLatestMatch)
        #expect(model.track?.appleMusicURL == url)
    }

    @Test func `A rendered result opens its own Apple Music link after a new match`() throws {
        let model = makeModel()
        let firstURL = try #require(URL(string: "https://music.apple.com/us/song/first/1"))
        let secondURL = try #require(URL(string: "https://music.apple.com/us/song/second/2"))
        let first = RecognizedTrack(id: "first", title: "First", artist: nil, appleMusicURL: firstURL)
        let second = RecognizedTrack(id: "second", title: "Second", artist: nil, appleMusicURL: secondURL)

        model.apply(.init(state: .matched(first), lastTrack: first))
        #expect(model.track?.appleMusicURL == firstURL)
        let firstCardAction = try #require(model.track?.openAppleMusic)
        model.apply(.init(state: .matched(second), lastTrack: second))
        #expect(model.track?.appleMusicURL == secondURL)
        let secondCardAction = try #require(model.track?.openAppleMusic)

        firstCardAction()
        secondCardAction()
        #expect(opener.opened == [firstURL, secondURL])
    }

    private func listeningSnapshot(from coordinator: RecognitionCoordinator) async throws -> RecognitionSnapshot {
        for await snapshot in await coordinator.updates() where snapshot.state == .listening {
            return snapshot
        }
        return try #require(nil as RecognitionSnapshot?, "Recognition ended before capture started")
    }

    private func makeModel(
        workflow: (any RecognitionWorkflow)? = nil,
        needsExplanation: @escaping @MainActor () -> Bool = { false },
        explain: @escaping @MainActor () async -> Bool = { true },
        markSeen: @escaping @MainActor () -> Void = {},
        quit: @escaping @MainActor () -> Void = {}
    ) -> RecognitionPresentationModel {
        RecognitionPresentationModel(
            workflow: workflow ?? self.workflow,
            urlOpener: opener,
            needsExplanation: needsExplanation,
            explainSystemAudio: explain,
            markExplanationSeen: markSeen,
            quitApplication: quit
        )
    }
}

private actor PresentationWorkflow: RecognitionWorkflow {
    private(set) var recognizeCount = 0
    private(set) var cancelCount = 0

    func updates() -> AsyncStream<RecognitionSnapshot> {
        AsyncStream { $0.finish() }
    }

    func recognize() { recognizeCount += 1 }
    func cancel() { cancelCount += 1 }
}


@MainActor
private final class FirstUseState {
    var seen = false
    var accept = false
    var explanationCount = 0
}
