import Foundation

public struct RecognitionAttemptID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct RecognizedTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let artist: String?
    public let appleMusicURL: URL?
    public let artworkURL: URL?
    public let recognizedAt: Date

    public init(
        id: String,
        title: String?,
        artist: String?,
        appleMusicURL: URL? = nil,
        artworkURL: URL? = nil,
        recognizedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.appleMusicURL = appleMusicURL
        self.artworkURL = artworkURL
        self.recognizedAt = recognizedAt
    }
}

public enum RecognitionFailure: Error, Equatable, Sendable {
    case audioPermissionDenied
    case noAudio
    case silence
    case captureInterrupted
    case captureUnavailable(diagnostic: String?)
    case recognitionTimedOut
    case recognitionService(diagnostic: String?)
}

public enum RecognitionState: Equatable, Sendable {
    case idle
    case starting
    case listening
    case searching
    case matched(RecognizedTrack)
    case noMatch
    case cancelled
    case failed(RecognitionFailure)

    public var isActive: Bool {
        switch self {
        case .starting, .listening, .searching: true
        default: false
        }
    }
}

public struct RecognitionSnapshot: Equatable, Sendable {
    public let state: RecognitionState
    public let lastTrack: RecognizedTrack?

    public init(state: RecognitionState = .idle, lastTrack: RecognizedTrack? = nil) {
        self.state = state
        self.lastTrack = lastTrack
    }
}

public struct RecognitionPolicy: Sendable {
    public let captureDuration: Duration
    public let resultGracePeriod: Duration
    public let startupTimeout: Duration
    public let activityThreshold: Float
    public let captureQueueCapacity: Int

    public init(
        captureDuration: Duration = .seconds(10),
        resultGracePeriod: Duration = .seconds(5),
        startupTimeout: Duration = .seconds(3),
        activityThreshold: Float = 0.000_01,
        captureQueueCapacity: Int = 32
    ) {
        precondition(captureDuration > .zero && resultGracePeriod > .zero && startupTimeout > .zero)
        precondition(activityThreshold.isFinite && activityThreshold >= 0 && captureQueueCapacity > 0)
        self.captureDuration = captureDuration
        self.resultGracePeriod = resultGracePeriod
        self.startupTimeout = startupTimeout
        self.activityThreshold = activityThreshold
        self.captureQueueCapacity = captureQueueCapacity
    }
}

/// Owned mono Float32 PCM at 48 kHz. Positions count samples from the start of the attempt.
public struct PCMFrame: Equatable, Sendable {
    public static let sampleRate: Double = 48_000

    public let attemptID: RecognitionAttemptID
    public let position: Int64
    public let samples: [Float]

    public init(attemptID: RecognitionAttemptID, position: Int64, samples: [Float]) {
        self.attemptID = attemptID
        self.position = position
        self.samples = samples
    }
}
