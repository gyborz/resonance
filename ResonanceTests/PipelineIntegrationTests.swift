import AppKit
import AVFoundation
import Carbon
import Foundation
import Observation
import RecognitionCore
import RecognitionTestSupport
@testable import Resonance
import ShazamFixtureSupport
import ShazamRecognition
import Synchronization
import SystemAudioCapture
import Testing

@MainActor
struct PipelineIntegrationTests {
    private let settingsSuite = "ResonanceTests.Pipeline.\(UUID())"

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func `Converted stereo fixture reaches the presentation through real ShazamKit`(isReference: Bool) async throws {
        let catalog = try ShazamFixture.catalogData()
        let capture = ConvertedFixtureCapture(variant: isReference ? .reference : .unrelated)
        let coordinator = RecognitionCoordinator(
            clock: ManualRecognitionClock(),
            makeCapture: { capture },
            makeRecognizer: { ShazamRecognitionClient(customCatalogData: catalog) }
        )
        let (runtime, _, defaults) = try makeRuntime(coordinator: coordinator)
        defer { defaults.removePersistentDomain(forName: settingsSuite) }
        runtime.start()
        await runtime.presentation.requestRecognition()?.value
        let result = try await waitFor(runtime.presentation) { !$0.state.isActive && $0.state != .idle }
        await runtime.shutdown()

        #expect(await capture.stops == 1)
        if isReference {
            let track = try #require(result.lastTrack, "Expected a local catalog match, got \(result.state)")
            #expect(result.state == .matched(track))
            #expect(track.title == ShazamFixture.title)
            #expect(runtime.presentation.track?.artist == ShazamFixture.artist)
            #expect(runtime.presentation.track?.appleMusicURL == ShazamFixture.musicURL)
        } else {
            #expect(result.state == .noMatch)
            #expect(runtime.presentation.track == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `Recognition stays blocked after the sleep interruption until a fresh trigger after wake`() async throws {
        let firstCapture = FakeAudioCapture()
        let secondCapture = FakeAudioCapture()
        let captures = Mutex([firstCapture, secondCapture])
        let coordinator = RecognitionCoordinator(
            clock: ManualRecognitionClock(),
            makeCapture: { captures.withLock { $0.removeFirst() } },
            makeRecognizer: { FakeRecognition() }
        )
        let notifications = NotificationCenter()
        let (runtime, registrar, defaults) = try makeRuntime(coordinator: coordinator, workspaceNotifications: notifications)
        defer { defaults.removePersistentDomain(forName: settingsSuite) }
        runtime.start()
        runtime.shortcuts.assign(GlobalShortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: [.control, .option]))
        registrar.press()
        _ = try await waitFor(runtime.presentation) { $0.state == .listening }

        notifications.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        _ = try await waitFor(runtime.presentation) { $0.state == .failed(.captureInterrupted) }
        #expect(await firstCapture.stopCount == 1)
        #expect(!runtime.presentation.canRecognize)

        registrar.press()
        #expect(runtime.presentation.requestRecognition() == nil)
        await coordinator.recognize()
        #expect(await secondCapture.attempts.isEmpty)
        notifications.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        _ = try await waitFor(runtime.presentation) { _ in runtime.presentation.canRecognize }
        #expect(await secondCapture.attempts.isEmpty)

        registrar.press()
        _ = try await waitFor(runtime.presentation) { $0.state == .listening }
        #expect(await secondCapture.attempts.count == 1)
        await runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func `A trigger pending at sleep stays discarded across an immediate wake`() async throws {
        let factoryCalls = Mutex(0)
        let coordinator = RecognitionCoordinator(
            clock: ManualRecognitionClock(),
            makeCapture: {
                factoryCalls.withLock { $0 += 1 }
                return FakeAudioCapture()
            },
            makeRecognizer: { FakeRecognition() }
        )
        let notifications = NotificationCenter()
        let (runtime, registrar, defaults) = try makeRuntime(coordinator: coordinator, workspaceNotifications: notifications)
        defer { defaults.removePersistentDomain(forName: settingsSuite) }
        runtime.start()
        runtime.shortcuts.assign(GlobalShortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: [.control, .option]))

        let pending = try #require(runtime.presentation.requestRecognition())
        notifications.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        #expect(!runtime.presentation.canRecognize)
        registrar.press()
        notifications.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        await pending.value
        _ = try await waitFor(runtime.presentation) { _ in runtime.presentation.canRecognize }
        #expect(factoryCalls.withLock { $0 } == 0)
        #expect(await coordinator.snapshot.state == .idle)

        await runtime.presentation.requestRecognition()?.value
        _ = try await waitFor(runtime.presentation) { $0.state == .listening }
        #expect(factoryCalls.withLock { $0 } == 1)
        await runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func `Shortcut starts the workflow and application shutdown stops it`() async throws {
        let factoryCalls = Mutex(0)
        let capture = FakeAudioCapture()
        let matcher = FakeRecognition()
        let coordinator = RecognitionCoordinator(
            clock: ManualRecognitionClock(),
            makeCapture: {
                factoryCalls.withLock { $0 += 1 }
                return capture
            },
            makeRecognizer: { matcher }
        )
        let (runtime, registrar, defaults) = try makeRuntime(coordinator: coordinator)
        defer { defaults.removePersistentDomain(forName: settingsSuite) }
        runtime.start()
        runtime.shortcuts.assign(GlobalShortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: [.control, .option]))
        #expect(factoryCalls.withLock { $0 } == 0)
        #expect(await matcher.attempts.isEmpty)

        registrar.press()
        _ = try await waitFor(runtime.presentation) { $0.state == .listening }
        await runtime.presentation.requestRecognition()?.value
        #expect(factoryCalls.withLock { $0 } == 1)

        await runtime.shutdown()
        #expect(await capture.stopCount == 1)
        #expect(await matcher.stopCount == 1)
        #expect(registrar.registered == nil)
        await runtime.presentation.requestRecognition()?.value
        #expect(factoryCalls.withLock { $0 } == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        RecognitionFailure.recognitionService(diagnostic: nil),
        .captureInterrupted,
        .noAudio,
    ])
    func `The presentation reflects capture, service and deadline outcomes`(failure: RecognitionFailure) async throws {
        let capture = FakeAudioCapture()
        let matcher = FakeRecognition()
        let clock = ManualRecognitionClock()
        let policy = RecognitionPolicy()
        let coordinator = RecognitionCoordinator(
            policy: policy, clock: clock, makeCapture: { capture }, makeRecognizer: { matcher }
        )
        let (runtime, _, defaults) = try makeRuntime(coordinator: coordinator)
        defer { defaults.removePersistentDomain(forName: settingsSuite) }
        runtime.start()
        await runtime.presentation.requestRecognition()?.value
        _ = try await waitFor(runtime.presentation) { $0.state == .listening }

        switch failure {
        case .recognitionService:
            let attempt = try #require(await capture.attempts.first)
            await matcher.send(RecognitionUpdate(attemptID: attempt, event: .failure(failure)))
        case .captureInterrupted:
            await capture.end(throwing: failure)
        case .noAudio:
            await clock.advance(by: policy.startupTimeout)
        default:
            Issue.record("Unexpected fixture failure")
        }

        let result = try await waitFor(runtime.presentation) { !$0.state.isActive && $0.state != .idle }
        #expect(result.state == .failed(failure))
        #expect(runtime.presentation.canRecognize)
        #expect(await capture.stopCount == 1)
        #expect(await matcher.stopCount == 1)
        await runtime.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func `Cancel and retry invalidate older results before updating the menu`() async throws {
        let firstCapture = FakeAudioCapture()
        let secondCapture = FakeAudioCapture()
        let firstMatcher = FakeRecognition()
        let submitted = AsyncStream<Void>.makeStream()
        let secondMatcher = FakeRecognition(onSubmit: { _ in
            submitted.continuation.yield(())
            submitted.continuation.finish()
        })
        let captureFactory = Mutex<[FakeAudioCapture]>([firstCapture, secondCapture])
        let matcherFactory = Mutex<[FakeRecognition]>([firstMatcher, secondMatcher])
        let coordinator = RecognitionCoordinator(
            clock: ManualRecognitionClock(),
            makeCapture: { captureFactory.withLock { $0.removeFirst() } },
            makeRecognizer: { matcherFactory.withLock { $0.removeFirst() } }
        )
        let (runtime, _, defaults) = try makeRuntime(coordinator: coordinator)
        defer { defaults.removePersistentDomain(forName: settingsSuite) }
        runtime.start()
        await runtime.presentation.requestRecognition()?.value
        _ = try await waitFor(runtime.presentation) { $0.state == .listening }
        let firstID = try #require(await firstCapture.attempts.first)

        await runtime.presentation.cancel()
        _ = try await waitFor(runtime.presentation) { $0.state == .cancelled }
        await runtime.presentation.requestRecognition()?.value
        _ = try await waitFor(runtime.presentation) { $0.state == .listening }
        let secondID = try #require(await secondCapture.attempts.first)
        #expect(firstID != secondID)

        await secondCapture.send(PCMFrame(attemptID: secondID, position: 0, samples: [0.2]))
        var submission = submitted.stream.makeAsyncIterator()
        try #require(await submission.next() != nil)

        let oldTrack = RecognizedTrack(id: "old", title: "Old result", artist: nil)
        let newTrack = RecognizedTrack(id: "new", title: "New result", artist: nil)
        await secondMatcher.send(RecognitionUpdate(attemptID: firstID, event: .match(oldTrack)))
        await secondMatcher.send(RecognitionUpdate(attemptID: secondID, event: .match(newTrack)))
        let result = try await waitFor(runtime.presentation) { !$0.state.isActive && $0.state != .idle }
        #expect(result.state == .matched(newTrack))
        #expect(runtime.presentation.track?.title == "New result")
        #expect(await firstCapture.stopCount == 1)
        #expect(await secondCapture.stopCount == 1)
        await runtime.shutdown()
    }

    private func makeRuntime(
        coordinator: RecognitionCoordinator,
        workspaceNotifications: NotificationCenter = NotificationCenter()
    ) throws -> (RecognitionRuntime, FakeShortcutRegistrar, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: settingsSuite))
        let registrar = FakeShortcutRegistrar()
        let runtime = RecognitionRuntime(
            coordinator: coordinator, defaults: defaults, registrar: registrar,
            urlOpener: RecordingURLOpener(), workspaceNotifications: workspaceNotifications,
            explainSystemAudio: { true }, quit: {}
        )
        return (runtime, registrar, defaults)
    }

    private func waitFor(
        _ model: RecognitionPresentationModel,
        _ predicate: (RecognitionSnapshot) -> Bool
    ) async throws -> RecognitionSnapshot {
        while !Task.isCancelled {
            let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let (snapshot, matches) = withObservationTracking {
                let snapshot = model.snapshot
                return (snapshot, predicate(snapshot))
            } onChange: {
                changes.continuation.yield(())
                changes.continuation.finish()
            }

            if matches {
                changes.continuation.finish()
                return snapshot
            }
            var iterator = changes.stream.makeAsyncIterator()
            guard await iterator.next() != nil else { break }
        }
        throw CancellationError()
    }
}

private actor ConvertedFixtureCapture: AudioCaptureClient {
    let variant: ShazamFixture.Variant
    private(set) var stops = 0

    init(variant: ShazamFixture.Variant) {
        self.variant = variant
    }

    func start(attemptID: RecognitionAttemptID) throws -> AsyncThrowingStream<PCMFrame, any Error> {
        let rate = 44_100
        let samples = ShazamFixture.samples(in: 2 * rate..<12 * rate, sampleRate: Double(rate), variant: variant)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        let channels = try #require(buffer.floatChannelData)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, value) in samples.enumerated() {
            channels[0][index] = value
            channels[1][index] = value * 0.8
        }

        let converter = try PCMNormalizer(inputFormat: format, attemptID: attemptID)
        let frame = try #require(try converter.convert(buffer))
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1)) { continuation in
            continuation.yield(frame)
            continuation.finish()
        }
    }

    func stop() {
        if stops == 0 {
            stops += 1
        }
    }
}
