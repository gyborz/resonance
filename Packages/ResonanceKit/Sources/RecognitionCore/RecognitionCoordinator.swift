import Foundation

/// Owns one capture and matcher at a time, including the time spent releasing them.
public actor RecognitionCoordinator: RecognitionWorkflow {
    private enum Phase {
        case starting
        case listening(cutoff: Duration, watchdog: Duration)
        case searching(cutoff: Duration)
        case completing(startupPending: Bool)
    }

    // All reads and writes of an attempt are isolated to the coordinator.
    private final class Attempt {
        let id = RecognitionAttemptID()
        let capture: any AudioCaptureClient
        let matcher: any RecognitionClient
        var phase = Phase.starting
        var nextPosition: Int64 = 0
        var heardSignal = false
        var captureWork: Task<Void, Never>?
        var frameWork: Task<Void, Never>?
        var submittingFrame = false
        var resultWork: Task<Void, Never>?
        var deadlineWork: Task<Void, Never>?
        var supersededDeadlineWork: Task<Void, Never>?
        var captureStop: Task<Void, Never>?
        var cleanup: Task<Void, Never>?

        init(capture: any AudioCaptureClient, matcher: any RecognitionClient) {
            self.capture = capture
            self.matcher = matcher
        }
    }

    private let policy: RecognitionPolicy
    private let clock: any RecognitionClock
    private let makeCapture: @Sendable () -> any AudioCaptureClient
    private let makeRecognizer: @Sendable () -> any RecognitionClient
    private var active: Attempt?
    private var observers: [UUID: AsyncStream<RecognitionSnapshot>.Continuation] = [:]
    private var isShutDown = false
    public private(set) var snapshot = RecognitionSnapshot()

    public init(
        policy: RecognitionPolicy = .init(),
        clock: any RecognitionClock = MonotonicRecognitionClock(),
        makeCapture: @escaping @Sendable () -> any AudioCaptureClient,
        makeRecognizer: @escaping @Sendable () -> any RecognitionClient
    ) {
        self.policy = policy
        self.clock = clock
        self.makeCapture = makeCapture
        self.makeRecognizer = makeRecognizer
    }

    public func updates() -> AsyncStream<RecognitionSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: RecognitionSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.yield(snapshot)
        if isShutDown {
            continuation.finish()
        } else {
            let id = UUID()
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
        return stream
    }

    public func recognize() {
        guard !isShutDown else { return }
        if active != nil {
            if snapshot.state == .cancelled && !snapshot.hasQueuedRetry {
                publish(.cancelled, hasQueuedRetry: true)
            }
            return
        }
        let capture = makeCapture()
        let matcher = makeRecognizer()
        let attempt = Attempt(capture: capture, matcher: matcher)
        let id = attempt.id
        active = attempt
        publish(.starting)
        attempt.captureWork = Task { [weak self] in
            await self?.runAttempt(id, capture: capture, matcher: matcher)
        }
    }

    public func cancel() {
        guard let attempt = active else { return }
        if snapshot.hasQueuedRetry {
            publish(.cancelled)
        } else {
            complete(attempt, with: .cancelled)
        }
    }

    /// Ends the current attempt after an interruption such as system sleep.
    public func interrupt() async {
        guard let attempt = active else { return }
        if snapshot.hasQueuedRetry { cancel() }
        complete(attempt, with: .failed(.captureInterrupted))
        await attempt.cleanup?.value
    }

    /// Drains a running capture before exit. During startup, cleanup remains owned
    /// by its task while the app is free to quit even if the HAL call is still blocked.
    public func shutdown() async {
        isShutDown = true
        cancel()
        if let attempt = active, case .completing(startupPending: false) = attempt.phase {
            await attempt.cleanup?.value
        }
        for observer in observers.values {
            observer.finish()
        }
        observers.removeAll()
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func publish(_ state: RecognitionState, hasQueuedRetry: Bool = false) {
        var lastTrack = snapshot.lastTrack
        if case .matched(let track) = state {
            lastTrack = track
        }
        snapshot = RecognitionSnapshot(state: state, lastTrack: lastTrack, hasQueuedRetry: hasQueuedRetry)
        for observer in observers.values {
            observer.yield(snapshot)
        }
    }

    private func current(_ id: RecognitionAttemptID) -> Attempt? {
        guard let active, active.id == id else { return nil }
        if case .completing = active.phase { return nil }
        return active
    }

    private func runAttempt(
        _ id: RecognitionAttemptID,
        capture: any AudioCaptureClient,
        matcher: any RecognitionClient
    ) async {
        do {
            try Task.checkCancellation()
            let results = try await matcher.start(attemptID: id)
            guard let attempt = current(id) else { return }
            observeResults(results, for: attempt)
        } catch {
            fail(id, with: error, defaultTo: RecognitionFailure.recognitionService)
            return
        }

        do {
            try Task.checkCancellation()
            let frames = try await capture.start(attemptID: id)
            // The HAL start call may involve a permission prompt. Start both timers
            // after that call succeeds, before waiting for the first delivered frame.
            let started = await clock.now
            guard let attempt = current(id) else { return }
            let cutoff = started + policy.captureDuration
            let watchdog = min(started + policy.startupTimeout, cutoff)
            attempt.phase = .listening(cutoff: cutoff, watchdog: watchdog)
            scheduleDeadline(for: attempt, at: watchdog)
            publish(.listening)

            let frameWork = Task<Void, Never> { [weak self] in
                await self?.readFrames(frames, from: id, matcher: matcher)
            }
            attempt.frameWork = frameWork
            await frameWork.value
        } catch {
            fail(id, with: error, defaultTo: RecognitionFailure.captureUnavailable)
            return
        }

        await endInput(id, matcher: matcher)
    }

    private func readFrames(
        _ frames: AsyncThrowingStream<PCMFrame, any Error>,
        from id: RecognitionAttemptID,
        matcher: any RecognitionClient
    ) async {
        do {
            for try await frame in frames {
                guard frame.attemptID == id, !frame.samples.isEmpty else { continue }
                guard await accept(frame, from: id) else { break }
                do {
                    try await matcher.submit(frame)
                } catch {
                    fail(id, with: error, defaultTo: RecognitionFailure.recognitionService)
                    return
                }
                guard let attempt = current(id) else { return }
                attempt.submittingFrame = false
                guard case .listening = attempt.phase else { return }
            }
        } catch {
            guard !Task.isCancelled else { return }
            fail(id, with: error, defaultTo: RecognitionFailure.captureUnavailable)
        }
    }

    private func accept(_ frame: PCMFrame, from id: RecognitionAttemptID) async -> Bool {
        let now = await clock.now
        guard let attempt = current(id), case .listening(let cutoff, let watchdog) = attempt.phase else {
            return false
        }
        if attempt.nextPosition == 0, now >= watchdog {
            complete(attempt, with: .failed(.noAudio))
            return false
        }
        if now >= cutoff {
            finishCapture(attempt, at: cutoff)
            return false
        }

        let (nextPosition, overflow) = frame.position.addingReportingOverflow(Int64(frame.samples.count))
        guard frame.position == attempt.nextPosition, !overflow else {
            complete(attempt, with: .failed(.captureInterrupted))
            return false
        }
        for sample in frame.samples {
            guard sample.isFinite else {
                complete(attempt, with: .failed(.captureInterrupted))
                return false
            }
            if abs(sample) > policy.activityThreshold {
                attempt.heardSignal = true
            }
        }
        attempt.nextPosition = nextPosition
        attempt.submittingFrame = true
        return true
    }

    private func endInput(_ id: RecognitionAttemptID, matcher: any RecognitionClient) async {
        let ended = await clock.now
        guard let attempt = current(id) else { return }
        if case .listening(let cutoff, _) = attempt.phase {
            finishCapture(attempt, at: min(ended, cutoff))
        }

        guard case .searching(let cutoff) = attempt.phase else { return }
        guard ended < cutoff else {
            complete(attempt, with: .failed(.recognitionTimedOut))
            return
        }
        // The frame reader has finished submitting accepted audio. Hardware teardown
        // runs independently while the matcher has the grace period to finish.
        do {
            try await matcher.finishInput()
        } catch {
            fail(id, with: error, defaultTo: RecognitionFailure.recognitionService)
        }
    }

    private func observeResults(_ results: AsyncStream<RecognitionUpdate>, for attempt: Attempt) {
        let id = attempt.id
        attempt.resultWork = Task { [weak self] in
            for await update in results {
                guard !Task.isCancelled else { return }
                await self?.receive(update, from: id)
            }
            await self?.resultsEnded(for: id)
        }
    }

    private func resultsEnded(for id: RecognitionAttemptID) {
        guard !Task.isCancelled, let attempt = current(id) else { return }
        complete(attempt, with: .failed(.recognitionService(diagnostic: "Result stream closed")))
    }

    private func receive(_ update: RecognitionUpdate, from id: RecognitionAttemptID) async {
        guard update.attemptID == id else { return }
        if case .noMatch(isFinal: false) = update.event { return }
        let now = await clock.now
        guard let attempt = current(id) else { return }
        if case .listening(let cutoff, _) = attempt.phase, now >= cutoff {
            finishCapture(attempt, at: cutoff)
        }
        guard current(id) != nil else { return }
        if case .searching(let cutoff) = attempt.phase, now >= cutoff {
            complete(attempt, with: .failed(.recognitionTimedOut))
            return
        }

        switch update.event {
        case .match(let track):
            guard attempt.heardSignal else { return }
            complete(attempt, with: .matched(track))
        case .noMatch(isFinal: true):
            guard case .searching = attempt.phase else { return }
            complete(attempt, with: .noMatch)
        case .noMatch(isFinal: false):
            break
        case .failure(let failure):
            complete(attempt, with: .failed(failure))
        }
    }

    private func scheduleDeadline(for attempt: Attempt, at deadline: Duration) {
        if let prior = attempt.deadlineWork {
            // A finite stream can end before its capture cutoff. Drain the
            // cancelled timer with the rest of this attempt's work.
            prior.cancel()
            attempt.supersededDeadlineWork = prior
        }
        let id = attempt.id
        let clock = self.clock
        attempt.deadlineWork = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.deadlineElapsed(for: id, at: deadline)
        }
    }

    private func deadlineElapsed(for id: RecognitionAttemptID, at deadline: Duration) {
        guard !Task.isCancelled, let attempt = current(id) else { return }
        attempt.deadlineWork = nil
        switch attempt.phase {
        case .listening(let cutoff, _):
            if attempt.nextPosition == 0 {
                complete(attempt, with: .failed(.noAudio))
            } else if deadline < cutoff {
                scheduleDeadline(for: attempt, at: cutoff)
            } else {
                finishCapture(attempt, at: cutoff)
            }
        case .searching:
            complete(attempt, with: .failed(.recognitionTimedOut))
        case .starting, .completing:
            break
        }
    }

    private func finishCapture(_ attempt: Attempt, at ended: Duration) {
        guard attempt.nextPosition > 0 else {
            complete(attempt, with: .failed(.noAudio))
            return
        }
        guard attempt.heardSignal else {
            complete(attempt, with: .failed(.silence))
            return
        }

        let cutoff = ended + policy.resultGracePeriod
        attempt.phase = .searching(cutoff: cutoff)
        // An idle read may be waiting for HAL teardown to finish the stream.
        // An accepted frame still needs to finish submitting before we close input.
        if !attempt.submittingFrame {
            attempt.frameWork?.cancel()
        }
        stopCapture(attempt)
        scheduleDeadline(for: attempt, at: cutoff)
        publish(.searching)
    }

    @discardableResult
    private func stopCapture(_ attempt: Attempt) -> Task<Void, Never> {
        if let stop = attempt.captureStop { return stop }
        let capture = attempt.capture
        let stop = Task { await capture.stop() }
        attempt.captureStop = stop
        return stop
    }

    private func complete(_ attempt: Attempt, with state: RecognitionState) {
        guard attempt.cleanup == nil else { return }
        let startupPending = if case .starting = attempt.phase { true } else { false }
        attempt.phase = .completing(startupPending: startupPending)
        attempt.frameWork?.cancel()
        let workers = [attempt.captureWork, attempt.resultWork, attempt.deadlineWork].compactMap { $0 }
        for worker in workers {
            worker.cancel()
        }

        let stop = stopCapture(attempt)
        let supersededDeadline = attempt.supersededDeadlineWork
        let matcher = attempt.matcher
        let id = attempt.id
        let stateAfterCleanup: RecognitionState? = state == .cancelled ? nil : state
        attempt.cleanup = Task { [weak self] in
            async let matcherStopped: Void = matcher.stop()
            await stop.value
            await matcherStopped
            await supersededDeadline?.value
            for worker in workers {
                await worker.value
            }
            await self?.didComplete(id, with: stateAfterCleanup)
        }
        if state == .cancelled {
            publish(state)
        }
    }

    private func didComplete(_ id: RecognitionAttemptID, with state: RecognitionState?) {
        guard active?.id == id else { return }
        active = nil
        if let state { publish(state) }
        if snapshot.hasQueuedRetry { recognize() }
    }

    private func fail(
        _ id: RecognitionAttemptID,
        with error: any Error,
        defaultTo fallback: (String?) -> RecognitionFailure
    ) {
        guard let attempt = current(id) else { return }
        let nsError = error as NSError
        let failure = error as? RecognitionFailure ?? fallback("\(nsError.domain) (\(nsError.code))")
        complete(attempt, with: .failed(failure))
    }
}
