import AVFoundation
import Foundation
import RecognitionCore
import ShazamKit

public actor ShazamRecognitionClient: RecognitionClient {
    private enum Phase {
        case ready, accepting, inputEnded, invalidated
    }

    private let captureDuration: Duration
    private let makeSession: @Sendable () throws -> any SignatureMatchingSession
    private var phase = Phase.ready
    private var attemptID: RecognitionAttemptID?
    private var updates: AsyncStream<RecognitionUpdate>.Continuation?
    private var session: (any SignatureMatchingSession)?
    private var generator: SHSignatureGenerator?
    private var format: AVAudioFormat?
    private var policy: SignatureQueryPolicy?

    private var nextPosition: Int64 = 0
    private var analyzedFrameCount: Int64 = 0
    private var consideredEarlyQuery = false
    private var lastQueriedFrameCount: Int64 = 0
    private var pendingQuery: UUID?

    /// A new client owns one attempt and uses the default Shazam catalog.
    public init(policy: RecognitionPolicy = RecognitionPolicy()) {
        captureDuration = policy.captureDuration
        makeSession = { try ShazamMatchingSession(customCatalogData: nil) }
    }

    /// Loads an immutable snapshot of an offline catalog inside the client actor.
    public init(customCatalogData: Data, policy: RecognitionPolicy = RecognitionPolicy()) {
        captureDuration = policy.captureDuration
        makeSession = { try ShazamMatchingSession(customCatalogData: customCatalogData) }
    }

    init(policy: RecognitionPolicy = RecognitionPolicy(), makeSession: @escaping @Sendable () throws -> any SignatureMatchingSession) {
        captureDuration = policy.captureDuration
        self.makeSession = makeSession
    }

    public func start(attemptID: RecognitionAttemptID) throws -> AsyncStream<RecognitionUpdate> {
        try Task.checkCancellation()
        guard phase == .ready else { throw CancellationError() }
        do {
            let session = try makeSession()
            let policy = try SignatureQueryPolicy(
                minimumDuration: session.minimumDuration,
                maximumDuration: session.maximumDuration,
                captureDuration: captureDuration
            )
            guard let format = AVAudioFormat(standardFormatWithSampleRate: PCMFrame.sampleRate, channels: 1) else {
                throw RecognitionFailure.recognitionService(diagnostic: "Cannot create canonical PCM format")
            }
            let stream = AsyncStream<RecognitionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(2))
            self.format = format
            self.session = session
            self.policy = policy
            self.attemptID = attemptID
            generator = SHSignatureGenerator()
            updates = stream.continuation
            phase = .accepting
            return stream.stream
        } catch {
            stop()
            throw ShazamMetadata.failure(error)
        }
    }

    public func submit(_ frame: PCMFrame) throws {
        try Task.checkCancellation()
        guard phase == .accepting, let format, let generator, let policy else { return }
        guard frame.attemptID == attemptID else { return }

        let (endPosition, overflow) = nextPosition.addingReportingOverflow(Int64(frame.samples.count))
        guard frame.position == nextPosition, !overflow else { throw RecognitionFailure.captureInterrupted }

        let remaining = policy.maximumFrameCount - analyzedFrameCount
        let count = min(remaining, Int64(frame.samples.count))
        guard count > 0 else {
            nextPosition = endPosition
            return
        }

        let samples = frame.samples.prefix(Int(count))
        guard samples.allSatisfy(\.isFinite) else { throw RecognitionFailure.captureInterrupted }
        guard let capacity = AVAudioFrameCount(exactly: count),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let channel = buffer.floatChannelData?[0] else {
            throw RecognitionFailure.recognitionService(diagnostic: "Cannot allocate canonical PCM buffer")
        }
        buffer.frameLength = capacity
        samples.withUnsafeBufferPointer {
            if let baseAddress = $0.baseAddress {
                channel.update(from: baseAddress, count: $0.count)
            }
        }

        let time = AVAudioTime(sampleTime: analyzedFrameCount, atRate: PCMFrame.sampleRate)
        do {
            try generator.append(buffer, at: time)
        } catch {
            throw ShazamMetadata.failure(error)
        }
        analyzedFrameCount += count
        nextPosition = endPosition

        if !consideredEarlyQuery && analyzedFrameCount >= policy.earlyFrameCount {
            consideredEarlyQuery = true
            requestMatch()
        }
    }

    public func finishInput() {
        guard phase == .accepting else { return }
        phase = .inputEnded
        if pendingQuery == nil {
            requestFinalMatch()
        }
    }

    public func stop() {
        phase = .invalidated
        pendingQuery = nil
        session?.invalidate()
        session = nil
        generator = nil
        format = nil
        policy = nil
        attemptID = nil
        updates?.finish()
        updates = nil
    }

    /// Queries the current snapshot of the growing signature. Only one request can be outstanding.
    @discardableResult
    private func requestMatch() -> Bool {
        guard let policy, let session, let generator,
              analyzedFrameCount > lastQueriedFrameCount,
              Double(analyzedFrameCount) / PCMFrame.sampleRate >= policy.minimumDuration else { return false }
        let signature = generator.signature()
        guard policy.accepts(duration: signature.duration) else { return false }

        let query = UUID()
        lastQueriedFrameCount = analyzedFrameCount
        pendingQuery = query
        session.match(signature) { [weak self] result in
            Task { await self?.receive(result, for: query) }
        }
        return true
    }

    private func requestFinalMatch() {
        if !requestMatch() {
            publish(.noMatch(isFinal: true))
            stop()
        }
    }

    private func receive(_ result: SignatureMatch, for query: UUID) {
        guard pendingQuery == query else { return }
        pendingQuery = nil
        switch result {
        case .match(let track):
            publish(.match(track))
            stop()
        case .failure(let failure):
            publish(.failure(failure))
            stop()
        case .noMatch:
            if phase == .inputEnded {
                requestFinalMatch()
            } else {
                publish(.noMatch(isFinal: false))
            }
        }
    }

    private func publish(_ event: RecognitionEvent) {
        guard let attemptID else { return }
        updates?.yield(RecognitionUpdate(attemptID: attemptID, event: event))
    }
}
