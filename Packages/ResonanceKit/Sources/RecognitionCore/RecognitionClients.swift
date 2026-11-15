import Foundation

/// Created per attempt. The returned stream has one consumer and owns its samples.
/// A full bounded queue or stream discontinuity must fail with `captureInterrupted`.
public protocol AudioCaptureClient: Sendable {
    /// Returns after the input device starts, which can involve a system permission prompt.
    /// A throw rolls back partial setup.
    func start(attemptID: RecognitionAttemptID) async throws -> AsyncThrowingStream<PCMFrame, any Error>

    /// Safe before and during startup, and after a failure. Invalidates the client,
    /// ends the stream and waits for callback storage to become safe to release.
    func stop() async
}

public enum RecognitionEvent: Equatable, Sendable {
    case match(RecognizedTrack)
    case noMatch(isFinal: Bool)
    case failure(RecognitionFailure)
}

public struct RecognitionUpdate: Equatable, Sendable {
    public let attemptID: RecognitionAttemptID
    public let event: RecognitionEvent

    public init(attemptID: RecognitionAttemptID, event: RecognitionEvent) {
        self.attemptID = attemptID
        self.event = event
    }
}

/// Created per attempt. A single caller submits ordered, contiguous frames.
public protocol RecognitionClient: Sendable {
    func start(attemptID: RecognitionAttemptID) async throws -> AsyncStream<RecognitionUpdate>
    func submit(_ frame: PCMFrame) async throws

    /// Ends input once. An outstanding result can still arrive on the event stream.
    func finishInput() async throws

    /// Invalidates the client, closes the stream, and suppresses late callbacks.
    func stop() async
}

/// Instants are relative to a private monotonic origin shared by now and sleep.
public protocol RecognitionClock: Sendable {
    var now: Duration { get async }
    func sleep(until deadline: Duration) async throws
}

public struct MonotonicRecognitionClock: RecognitionClock {
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now

    public init() {}

    public var now: Duration { origin.duration(to: clock.now) }

    public func sleep(until deadline: Duration) async throws {
        try await clock.sleep(until: origin.advanced(by: deadline))
    }
}

public protocol RecognitionWorkflow: Sendable {
    func updates() async -> AsyncStream<RecognitionSnapshot>
    func recognize() async
    func cancel() async
}
