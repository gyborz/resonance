import Dispatch
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
        #expect(await rig.matcher.stopCount == 0)

        await rig.clock.advance(by: .seconds(4))
        await rig.matcher.send(.init(attemptID: id, event: .match(track)))

        _ = try await states.wait(for: .matched(track))
        await rig.expectReleased()
    }

    @Test func `The final query can win while capture teardown is blocked`() async throws {
        let stopGate = AsyncGate()
        let track = Self.track
        defer { stopGate.release() }
        let rig = Rig(capture: FakeAudioCapture(beforeStop: { await stopGate.wait() }))
        var states = try await rig.startListening()
        let id = try await rig.attemptID()
        try await rig.feed([0.3])

        await rig.clock.advance(by: .seconds(10))
        _ = try await states.wait(for: .searching)
        var stopEntry = stopGate.entered.stream.makeAsyncIterator()
        try #require(await stopEntry.next() != nil)

        let inputClosed = await receivesSignal(rig.inputEnded.stream)
        #expect(inputClosed)
        if inputClosed {
            await rig.clock.advance(by: .seconds(4))
            await rig.matcher.send(.init(attemptID: id, event: .match(track)))
        } else {
            // Force the old implementation's grace period to expire with teardown still blocked.
            await rig.clock.advance(by: .seconds(5))
        }
        var matcherStop = rig.matcherStopped.stream.makeAsyncIterator()
        try #require(await matcherStop.next() != nil)
        #expect(await rig.matcher.finishCount == 1)

        stopGate.release()
        let result = try #require(await states.next())
        #expect(result.state == .matched(track))
        await rig.expectReleased()
    }

    @Test func `Finalization waits for an accepted frame and drops unread audio at the cutoff`() async throws {
        let submitGate = AsyncGate()
        let stopGate = AsyncGate()
        defer {
            submitGate.release()
            stopGate.release()
        }
        let rig = Rig(
            capture: FakeAudioCapture(beforeStop: { await stopGate.wait() }),
            beforeSubmit: { await submitGate.wait() }
        )
        var states = try await rig.startListening()
        let id = try await rig.attemptID()
        let accepted = PCMFrame(attemptID: id, position: 0, samples: [0.3])
        await rig.capture.send(accepted)
        var submitStarted = submitGate.entered.stream.makeAsyncIterator()
        try #require(await submitStarted.next() != nil)

        await rig.clock.advance(by: .seconds(10))
        _ = try await states.wait(for: .searching)
        await rig.capture.send(.init(attemptID: id, position: 1, samples: [0.4]))
        #expect(await rig.matcher.finishCount == 0)

        submitGate.release()
        try #require(await receivesSignal(rig.inputEnded.stream))
        #expect(await rig.matcher.frames == [accepted])
        #expect(await rig.matcher.finishCount == 1)

        stopGate.release()
        await rig.matcher.send(.init(attemptID: id, event: .noMatch(isFinal: true)))
        _ = try await states.wait(for: .noMatch)
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

    @Test(arguments: [false, true])
    func `Cancel and shutdown acknowledge a blocked HAL startup`(quitting: Bool) async throws {
        let capture = CaptureWithBlockedStartup()
        defer { capture.releaseStartup() }
        let matcherStopped = AsyncStream<Void>.makeStream()
        let matcher = FakeRecognition(onStop: { matcherStopped.continuation.yield(()) })
        let retryCapture = FakeAudioCapture()
        let retryMatcher = FakeRecognition()
        let captureFactory = Mutex<[any AudioCaptureClient]>([capture, retryCapture])
        let matcherFactory = Mutex([matcher, retryMatcher])
        let coordinator = RecognitionCoordinator(
            makeCapture: { captureFactory.withLock { $0.removeFirst() } },
            makeRecognizer: { matcherFactory.withLock { $0.removeFirst() } }
        )
        var states = await coordinator.updates().makeAsyncIterator()
        #expect(await states.next()?.state == .idle)
        await coordinator.recognize()
        var startup = capture.startEntered.stream.makeAsyncIterator()
        _ = try #require(await startup.next())
        #expect(await states.next()?.state == .starting)

        let commandReturned = AsyncStream<Void>.makeStream()
        let command = Task {
            if quitting {
                await coordinator.shutdown()
            } else {
                await coordinator.cancel()
            }
            commandReturned.continuation.yield(())
        }

        var stopped = matcherStopped.stream.makeAsyncIterator()
        _ = try #require(await stopped.next())
        let stateWhileBlocked = await coordinator.snapshot.state
        #expect(stateWhileBlocked == .cancelled)
        let returnedBeforeRelease = await receivesSignal(commandReturned.stream)
        #expect(returnedBeforeRelease)
        #expect(await matcher.stopCount == 1)

        if stateWhileBlocked == .cancelled {
            #expect(await states.next()?.state == .cancelled)
            // A request during cleanup is queued after Cancel and declined after Quit.
            await coordinator.recognize()
            await coordinator.recognize()
            #expect(captureFactory.withLock { $0.count } == 1)
        }
        if quitting && returnedBeforeRelease {
            #expect(await states.next() == nil)
        }

        capture.releaseStartup()
        await command.value
        var released = capture.stopped.stream.makeAsyncIterator()
        _ = try #require(await released.next())
        #expect(await capture.stopCount == 1)

        if !quitting && stateWhileBlocked == .cancelled {
            _ = try await states.wait(for: .listening)
            #expect(await retryCapture.attempts.count == 1)
        }
        await coordinator.shutdown()
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
    let matcherStopped = AsyncStream<Void>.makeStream()

    init(capture: FakeAudioCapture = .init(), beforeSubmit: @escaping @Sendable () async -> Void = {}) {
        self.capture = capture
        let onSubmit = submitted.continuation
        let onFinishInput = inputEnded.continuation
        let onStop = matcherStopped.continuation
        let matcher = FakeRecognition(
            beforeSubmit: beforeSubmit,
            onSubmit: { onSubmit.yield($0) },
            onFinishInput: { onFinishInput.yield(()) },
            onStop: { onStop.yield(()) }
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

// A wall-clock watchdog prevents a blocked regression from hanging the suite.
// The recognition deadline itself is driven exclusively by the manual clock.
private func receivesSignal(_ stream: AsyncStream<Void>) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var events = stream.makeAsyncIterator()
            return await events.next() != nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return false
        }
        defer { group.cancelAll() }
        return await group.next() ?? false
    }
}

private final class AsyncGate: Sendable {
    let entered = AsyncStream<Void>.makeStream()
    private let permission = AsyncStream<Void>.makeStream()

    func wait() async {
        entered.continuation.yield(())
        for await _ in permission.stream {}
    }

    func release() {
        permission.continuation.finish()
    }
}

private actor CaptureWithBlockedStartup: AudioCaptureClient {
    nonisolated let startEntered = AsyncStream<Void>.makeStream()
    nonisolated let stopped = AsyncStream<Void>.makeStream()
    private let gate = DispatchSemaphore(value: 0)
    private let worker = DispatchSerialQueue(label: "ResonanceTests.blockedHAL")
    private let pipe = AsyncThrowingStream<PCMFrame, any Error>.makeStream()
    private(set) var stopCount = 0

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        worker.asUnownedSerialExecutor()
    }

    func start(attemptID: RecognitionAttemptID) throws -> AsyncThrowingStream<PCMFrame, any Error> {
        startEntered.continuation.yield(())
        gate.wait()
        try Task.checkCancellation()
        return pipe.stream
    }

    nonisolated func releaseStartup() {
        gate.signal()
    }

    func stop() {
        stopCount += 1
        pipe.continuation.finish()
        stopped.continuation.yield(())
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
