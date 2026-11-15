import Foundation
import RecognitionCore
import RecognitionTestSupport
@testable import Resonance
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

        await model.recognize()
        model.apply(.init(state: .listening))
        await model.recognize()
        await model.cancel()
        model.apply(.init(state: .noMatch))
        #expect(String(localized: model.recognizeTitle) == "Try Again")
        await model.recognize()
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

        await model.recognize()
        #expect(await workflow.recognizeCount == 0)
        #expect(!firstUse.seen)

        firstUse.accept = true
        await model.recognize()
        await model.recognize()
        #expect(firstUse.seen)
        #expect(firstUse.explanationCount == 2)
        #expect(await workflow.recognizeCount == 2)
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
        model.openAppleMusic()
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
        model.openAppleMusic()
        #expect(opener.opened == [url])

        model.apply(.init(state: .listening, lastTrack: track))
        #expect(!model.isLatestMatch)
        #expect(model.track?.appleMusicURL == url)
    }

    private func makeModel(
        needsExplanation: @escaping @MainActor () -> Bool = { false },
        explain: @escaping @MainActor () async -> Bool = { true },
        markSeen: @escaping @MainActor () -> Void = {},
        quit: @escaping @MainActor () -> Void = {}
    ) -> RecognitionPresentationModel {
        RecognitionPresentationModel(
            workflow: workflow,
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
