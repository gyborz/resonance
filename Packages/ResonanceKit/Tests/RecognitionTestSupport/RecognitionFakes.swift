import Foundation
import RecognitionCore

public actor FakeAudioCapture: AudioCaptureClient {
    private let pipe = AsyncThrowingStream<PCMFrame, any Error>.makeStream()
    private let startupError: RecognitionFailure?
    public private(set) var attempts: [RecognitionAttemptID] = []
    public private(set) var stopCount = 0

    public init(startupError: RecognitionFailure? = nil) {
        self.startupError = startupError
    }

    public func start(attemptID: RecognitionAttemptID) throws -> AsyncThrowingStream<PCMFrame, any Error> {
        guard stopCount == 0 else { throw CancellationError() }
        attempts.append(attemptID)
        if let startupError { throw startupError }
        return pipe.stream
    }

    public func send(_ frame: PCMFrame) {
        pipe.continuation.yield(frame)
    }

    public func end(throwing error: RecognitionFailure? = nil) {
        pipe.continuation.finish(throwing: error)
    }

    public func stop() {
        guard stopCount == 0 else { return }
        stopCount += 1
        end()
    }
}

public actor FakeRecognition: RecognitionClient {
    private let pipe = AsyncStream<RecognitionUpdate>.makeStream()
    public private(set) var attempts: [RecognitionAttemptID] = []
    public private(set) var frames: [PCMFrame] = []
    public private(set) var finishCount = 0
    public private(set) var stopCount = 0

    public init() {}

    public func start(attemptID: RecognitionAttemptID) throws -> AsyncStream<RecognitionUpdate> {
        guard stopCount == 0 else { throw CancellationError() }
        attempts.append(attemptID)
        return pipe.stream
    }

    public func submit(_ frame: PCMFrame) {
        guard stopCount == 0 && finishCount == 0 else { return }
        frames.append(frame)
    }

    public func send(_ event: RecognitionUpdate) {
        pipe.continuation.yield(event)
    }

    public func finishInput() {
        finishCount += 1
    }

    public func stop() {
        guard stopCount == 0 else { return }
        stopCount += 1
        pipe.continuation.finish()
    }
}

public actor ManualRecognitionClock: RecognitionClock {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    public private(set) var now: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]

    public init() {}

    public func sleep(until deadline: Duration) async throws {
        try Task.checkCancellation()
        guard now < deadline else { return }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelSleep(id) }
        }
    }

    public func advance(by duration: Duration) {
        precondition(duration >= .zero)
        now += duration
        let ready = sleepers.filter { $0.value.deadline <= now }
        for (id, sleeper) in ready {
            sleepers.removeValue(forKey: id)
            sleeper.continuation.resume()
        }
    }

    private func cancelSleep(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
public final class RecordingURLOpener: TrackURLOpening {
    public private(set) var opened: [URL] = []

    public init() {}

    public func open(_ url: URL) {
        opened.append(url)
    }
}

@MainActor
public final class FakeShortcutRegistrar: ShortcutRegistering {
    public var registrationError: (any Error)?
    public private(set) var registered: GlobalShortcut?
    private var handler: (@MainActor () -> Void)?

    public init() {}

    public func register(_ shortcut: GlobalShortcut, onPress: @escaping @MainActor () -> Void) throws {
        if let registrationError { throw registrationError }
        registered = shortcut
        handler = onPress
    }

    public func unregister() {
        registered = nil
        handler = nil
    }

    public func press() { handler?() }
}
