import RecognitionCore
import RecognitionTestSupport
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RecognitionCoordinatorTests {
    @Test func `A match after an intermediate miss stops listening early`() async throws {
        let rig = Rig()
        var states = try await rig.startListening()
        let id = try await rig.attemptID()
        let track = Self.track

        try await rig.feed([0.25, -0.1])
        await rig.matcher.send(.init(attemptID: id, event: .noMatch(isFinal: false)))
        try await rig.feed([0.05, -0.04], position: 2)
        await rig.matcher.send(.init(attemptID: id, event: .match(track)))

        let result = try await states.wait(for: .matched(track))
        #expect(result.lastTrack == track)
        #expect(await rig.matcher.frames.map(\.position) == [0, 2])
        #expect(await rig.matcher.finishCount == 0)
        await rig.expectReleased()
    }

    @Test func `Capture stops on schedule while a pending match can still win`() async throws {
        let rig = Rig()
        var states = try await rig.startListening()
        let id = try await rig.attemptID()
        let track = Self.track
        try await rig.feed([0.3])

        await rig.clock.advance(by: .seconds(9))
        #expect(await rig.capture.stopCount == 0)
        await rig.clock.advance(by: .seconds(1))
        _ = try await states.wait(for: .searching)
        try await rig.waitForEndOfInput()
        #expect(await rig.capture.stopCount == 1)
        #expect(await rig.matcher.stopCount == 0)

        await rig.clock.advance(by: .seconds(4))
        await rig.matcher.send(.init(attemptID: id, event: .match(track)))

        _ = try await states.wait(for: .matched(track))
        await rig.expectReleased()
    }

    @Test func `A match at the end of the grace period cannot revive the attempt`() async throws {
        let rig = Rig()
        var states = try await rig.startListening()
        let id = try await rig.attemptID()
        try await rig.feed([0.3])
        await rig.clock.advance(by: .seconds(10))
        _ = try await states.wait(for: .searching)
        try await rig.waitForEndOfInput()

        await rig.clock.advance(by: .seconds(5))
        await rig.matcher.send(.init(attemptID: id, event: .match(Self.track)))

        let result = try await states.wait(for: .failed(.recognitionTimedOut))
        #expect(result.lastTrack == nil)
        await rig.expectReleased()
    }

    @Test func `A final miss returns no match after terminating input`() async throws {
        let rig = Rig()
        var states = try await rig.startListening()
        let id = try await rig.attemptID()
        try await rig.feed([0.3])

        await rig.capture.end()
        _ = try await states.wait(for: .searching)
        try await rig.waitForEndOfInput()
        await rig.matcher.send(.init(attemptID: id, event: .noMatch(isFinal: true)))

        _ = try await states.wait(for: .noMatch)
        await rig.expectReleased()
    }

    @Test func `The startup watchdog detects missing frames`() async throws {
        let rig = Rig()
        var states = try await rig.startListening()
        let id = try await rig.attemptID()
        await rig.capture.send(PCMFrame(attemptID: id, position: 0, samples: []))
        await rig.clock.advance(by: .seconds(3))

        _ = try await states.wait(for: .failed(.noAudio))
        #expect(await rig.matcher.frames.isEmpty)
        #expect(await rig.matcher.finishCount == 0)
        await rig.expectReleased()
    }

    @Test(arguments: [Float.zero, 0.000_001])
    func `Delivered silence uses the capture deadline`(sample: Float) async throws {
        let rig = Rig()
        var states = try await rig.startListening()
        try await rig.feed([sample])

        await rig.clock.advance(by: .seconds(3))
        #expect(await rig.coordinator.snapshot.state == .listening)
        await rig.clock.advance(by: .seconds(7))

        _ = try await states.wait(for: .failed(.silence))
        #expect(await rig.matcher.finishCount == 0)
        await rig.expectReleased()
    }

    @Test(arguments: [RecognitionFailure.audioPermissionDenied, .captureUnavailable(diagnostic: "HAL (-1)")])
    func `Capture startup failures clean up the prepared matcher`(failure: RecognitionFailure) async throws {
        let rig = Rig(capture: FakeAudioCapture(startupError: failure))
        var states = await rig.coordinator.updates().makeAsyncIterator()
        #expect(await states.next()?.state == .idle)

        await rig.coordinator.recognize()

        _ = try await states.wait(for: .failed(failure))
        #expect(await rig.matcher.attempts.count == 1)
        await rig.expectReleased()
    }

    @Test func `The sound budget starts after permission startup returns`() async throws {
        let capture = CaptureAwaitingPermission()
        let matcher = FakeRecognition()
        let clock = ManualRecognitionClock()
        let coordinator = RecognitionCoordinator(clock: clock, makeCapture: { capture }, makeRecognizer: { matcher })
        var states = await coordinator.updates().makeAsyncIterator()
        #expect(await states.next()?.state == .idle)
        await coordinator.recognize()
        var startup = await capture.requests.makeAsyncIterator()
        let id = try #require(await startup.next())
        #expect(await states.next()?.state == .starting)

        await clock.advance(by: .seconds(60))
        #expect(await coordinator.snapshot.state == .starting)
        #expect(await capture.stopCount == 0)
        #expect(await matcher.attempts == [id])

        await capture.grant()
        _ = try await states.wait(for: .listening)
        await clock.advance(by: .seconds(2))
        #expect(await coordinator.snapshot.state == .listening)
        await clock.advance(by: .seconds(1))
        _ = try await states.wait(for: .failed(.noAudio))
        #expect(await capture.stopCount == 1)
        #expect(await matcher.stopCount == 1)
    }

    @Test func `Cancel while permission startup is suspended waits for rollback`() async throws {
        let capture = CaptureAwaitingPermission()
        let matcher = FakeRecognition()
        let coordinator = RecognitionCoordinator(makeCapture: { capture }, makeRecognizer: { matcher })
        var startup = await capture.requests.makeAsyncIterator()
        await coordinator.recognize()
        _ = try #require(await startup.next())

        await coordinator.cancel()
        await capture.grant()

        #expect(await coordinator.snapshot.state == .cancelled)
        #expect(await capture.stopCount == 1)
        #expect(await matcher.stopCount == 1)
    }

    @Test func `A capture interruption is actionable and leaves no active worker`() async throws {
        let rig = Rig()
        var states = try await rig.startListening()
        try await rig.feed([0.25])

        await rig.capture.end(throwing: .captureInterrupted)

        _ = try await states.wait(for: .failed(.captureInterrupted))
        await rig.expectReleased()
    }

    @Test func `A frame gap prevents stitching unrelated PCM regions`() async throws {
        let rig = Rig()
        var states = try await rig.startListening()
        try await rig.feed([0.25])

        await rig.capture.send(.init(attemptID: try await rig.attemptID(), position: 2, samples: [0.3]))

        _ = try await states.wait(for: .failed(.captureInterrupted))
        #expect(await rig.matcher.frames.map(\.position) == [0])
        await rig.expectReleased()
    }

    @Test func `Matcher service errors propagate during the grace period`() async throws {
        let rig = Rig()
        var states = try await rig.startListening()
        let id = try await rig.attemptID()
        try await rig.feed([0.3])
        await rig.capture.end()
        _ = try await states.wait(for: .searching)
        try await rig.waitForEndOfInput()

        let failure = RecognitionFailure.recognitionService(diagnostic: "ShazamKit (-2)")
        await rig.matcher.send(.init(attemptID: id, event: .failure(failure)))

        _ = try await states.wait(for: .failed(failure))
        await rig.expectReleased()
    }

    @Test func `Cancel and a competing match publish only one terminal state`() async throws {
        let rig = Rig()
        var states = try await rig.startListening()
        let id = try await rig.attemptID()
        let track = Self.track
        try await rig.feed([0.3])

        async let cancel: Void = rig.coordinator.cancel()
        async let match: Void = rig.matcher.send(.init(attemptID: id, event: .match(track)))
        _ = await (cancel, match)

        let result = try #require(await states.next())
        #expect(result.state == .matched(track) || result.state == .cancelled)
        #expect(result.lastTrack == (result.state == .cancelled ? nil : track))
        await rig.matcher.send(.init(attemptID: id, event: .failure(.recognitionTimedOut)))
        await rig.coordinator.shutdown()
        #expect(await states.next() == nil)
        await rig.expectReleased()
    }

    @Test func `Retry starts fresh and ignores stale callbacks without losing the last match`() async throws {
        let track = Self.track
        let firstCapture = FakeAudioCapture()
        let secondCapture = FakeAudioCapture()
        let submissions = AsyncStream<PCMFrame>.makeStream()
        let firstMatcher = FakeRecognition(onSubmit: { submissions.continuation.yield($0) })
        let secondMatcher = FakeRecognition(onSubmit: { submissions.continuation.yield($0) })
        let captures = Mutex([firstCapture, secondCapture])
        let matchers = Mutex([firstMatcher, secondMatcher])
        let clock = ManualRecognitionClock()
        let coordinator = RecognitionCoordinator(
            clock: clock,
            makeCapture: { captures.withLock { $0.removeFirst() } },
            makeRecognizer: { matchers.withLock { $0.removeFirst() } }
        )
        var states = await coordinator.updates().makeAsyncIterator()
        var frames = submissions.stream.makeAsyncIterator()
        #expect(await states.next()?.state == .idle)

        await coordinator.recognize()
        _ = try await states.wait(for: .listening)
        let firstID = try #require(await firstCapture.attempts.first)
        let firstFrame = PCMFrame(attemptID: firstID, position: 0, samples: [0.33])
        await firstCapture.send(firstFrame)
        #expect(await frames.next() == firstFrame)
        await firstMatcher.send(.init(attemptID: firstID, event: .match(track)))
        _ = try await states.wait(for: .matched(track))

        await coordinator.recognize()
        await coordinator.recognize()
        let listening = try await states.wait(for: .listening)
        #expect(listening.lastTrack == track)
        let secondID = try #require(await secondCapture.attempts.first)
        #expect(firstID != secondID)
        #expect(await secondMatcher.attempts == [secondID])
        let secondFrame = PCMFrame(attemptID: secondID, position: 0, samples: [0.42])
        await secondCapture.send(firstFrame)
        await secondCapture.send(secondFrame)
        #expect(await frames.next() == secondFrame)

        await firstMatcher.send(.init(attemptID: firstID, event: .failure(.recognitionTimedOut)))
        await secondMatcher.send(.init(attemptID: firstID, event: .failure(.recognitionTimedOut)))
        await secondMatcher.send(.init(attemptID: secondID, event: .failure(.recognitionService(diagnostic: nil))))
        let result = try await states.wait(for: .failed(.recognitionService(diagnostic: nil)))
        #expect(result.lastTrack == track)
        #expect(await firstCapture.stopCount == 1)
        #expect(await secondCapture.stopCount == 1)
        #expect(await firstMatcher.stopCount == 1)
        #expect(await secondMatcher.stopCount == 1)
    }

    @Test func `Sleep and shutdown await cleanup and shutdown closes observations`() async throws {
        let capture = FakeAudioCapture()
        let matcher = FakeRecognition()
        let factoryCalls = Mutex(0)
        let coordinator = RecognitionCoordinator(
            makeCapture: {
                factoryCalls.withLock { $0 += 1 }
                return capture
            },
            makeRecognizer: { matcher }
        )
        var states = await coordinator.updates().makeAsyncIterator()
        #expect(await states.next()?.state == .idle)
        #expect(factoryCalls.withLock { $0 } == 0)
        await coordinator.recognize()
        _ = try await states.wait(for: .listening)

        await coordinator.interrupt()

        _ = try await states.wait(for: .failed(.captureInterrupted))
        #expect(await capture.stopCount == 1)
        #expect(await matcher.stopCount == 1)
        await coordinator.shutdown()
        await coordinator.recognize()
        #expect(factoryCalls.withLock { $0 } == 1)
        #expect(await states.next() == nil)
    }

    @Test func `Shutdown while listening waits for both clients and closes observations`() async throws {
        let rig = Rig()
        var states = try await rig.startListening()
        try await rig.feed([0.4])

        await rig.coordinator.shutdown()

        _ = try await states.wait(for: .cancelled)
        #expect(await states.next() == nil)
        await rig.expectReleased()
    }

    private static var track: RecognizedTrack {
        RecognizedTrack(id: "fixture", title: "First Song", artist: "Fixture Artist")
    }
}

private struct Rig {
    let capture: FakeAudioCapture
    let matcher: FakeRecognition
    let clock = ManualRecognitionClock()
    let coordinator: RecognitionCoordinator
    let submitted = AsyncStream<PCMFrame>.makeStream()
    let inputEnded = AsyncStream<Void>.makeStream()

    init(capture: FakeAudioCapture = .init()) {
        self.capture = capture
        let onSubmit = submitted.continuation
        let onFinishInput = inputEnded.continuation
        let matcher = FakeRecognition(
            onSubmit: { onSubmit.yield($0) },
            onFinishInput: { onFinishInput.yield(()) }
        )
        self.matcher = matcher
        coordinator = RecognitionCoordinator(clock: clock, makeCapture: { capture }, makeRecognizer: { matcher })
    }

    func startListening() async throws -> AsyncStream<RecognitionSnapshot>.Iterator {
        var states = await coordinator.updates().makeAsyncIterator()
        #expect(await states.next()?.state == .idle)
        await coordinator.recognize()
        _ = try await states.wait(for: .listening)
        return states
    }

    func attemptID() async throws -> RecognitionAttemptID {
        try #require(await capture.attempts.first)
    }

    // Each feed waits for the single submitted packet. Tests use virtual time
    // only after the packet has crossed the coordinator-to-matcher boundary.
    func feed(_ samples: [Float], position: Int64 = 0) async throws {
        var observations = submitted.stream.makeAsyncIterator()
        let frame = PCMFrame(attemptID: try await attemptID(), position: position, samples: samples)
        await capture.send(frame)
        #expect(await observations.next() == frame)
    }

    func waitForEndOfInput() async throws {
        var observations = inputEnded.stream.makeAsyncIterator()
        try #require(await observations.next() != nil)
    }

    func expectReleased() async {
        #expect(await capture.stopCount == 1)
        #expect(await matcher.stopCount == 1)
        #expect(await clock.pendingSleepCount == 0)
    }
}

private extension AsyncStream<RecognitionSnapshot>.Iterator {
    mutating func wait(for state: RecognitionState) async throws -> RecognitionSnapshot {
        while let snapshot = await next() {
            if snapshot.state == state { return snapshot }
            try #require(snapshot.state.isActive, "Expected \(state), got \(snapshot.state)")
        }
        return try #require(nil as RecognitionSnapshot?, "Observer ended while waiting for \(state)")
    }
}

private actor CaptureAwaitingPermission: AudioCaptureClient {
    private let pipe = AsyncThrowingStream<PCMFrame, any Error>.makeStream()
    private let startup = AsyncStream<RecognitionAttemptID>.makeStream()
    private var permission: CheckedContinuation<Void, any Error>?
    private(set) var stopCount = 0

    var requests: AsyncStream<RecognitionAttemptID> { startup.stream }

    func start(attemptID: RecognitionAttemptID) async throws -> AsyncThrowingStream<PCMFrame, any Error> {
        try await withCheckedThrowingContinuation { continuation in
            permission = continuation
            startup.continuation.yield(attemptID)
        }
        return pipe.stream
    }

    func grant() {
        permission?.resume()
        permission = nil
    }

    func stop() {
        stopCount += 1
        permission?.resume(throwing: CancellationError())
        permission = nil
        pipe.continuation.finish()
    }
}
