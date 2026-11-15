import AVFoundation
import CoreAudio
import OSLog
import RecognitionCore
import Synchronization

/// Owns one private system audio attempt. HAL setup, conversion, and cleanup
/// run on a serial dispatch executor, outside the app's main actor.
public actor SystemAudioCaptureClient: AudioCaptureClient {
    private typealias AudioStream = AsyncThrowingStream<PCMFrame, any Error>

    private let policy: RecognitionPolicy
    private let hal: any CaptureHAL
    private let diagnosticsEnabled: Bool
    private let logger = Logger(subsystem: "Resonance.SystemAudioCapture", category: "Capture")
    private let worker = DispatchSerialQueue(label: "Resonance.SystemAudioCapture", qos: .userInitiated)
    private var capture: RunningCapture?
    private var pollTask: Task<Void, Never>?
    private var invalidated = false
    private var sampleCount: Int64 = 0

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        worker.asUnownedSerialExecutor()
    }

    public init(policy: RecognitionPolicy, diagnosticsEnabled: Bool = false) {
        self.policy = policy
        self.diagnosticsEnabled = diagnosticsEnabled
        self.hal = CoreAudioHAL(diagnosticsEnabled: diagnosticsEnabled)
    }

    init(policy: RecognitionPolicy, hal: any CaptureHAL) {
        self.policy = policy
        self.diagnosticsEnabled = false
        self.hal = hal
    }

    public func start(
        attemptID: RecognitionAttemptID
    ) throws -> AsyncThrowingStream<PCMFrame, any Error> {
        guard !invalidated else { throw CancellationError() }
        invalidated = true

        let cleanup = CaptureCleanup()
        let route = CaptureRouteSignal()
        do {
            try Task.checkCancellation()
            try observe(.defaultOutput, using: route, cleanup: cleanup)
            try observe(.outputDataSource, using: route, cleanup: cleanup)
            try observe(.serviceRestart, using: route, cleanup: cleanup)

            let tap = try hal.createTap()
            cleanup.add { [hal] in hal.destroyTap(tap) }
            try Task.checkCancellation()
            try observe(.tapFormat(tap), using: route, cleanup: cleanup)

            let tapUID = try hal.tapUID(tap)
            let device = try hal.createAggregate(tapUID: tapUID)
            cleanup.add { [hal] in hal.destroyAggregate(device) }
            try Task.checkCancellation()
            try observe(.aggregateSampleRate(device), using: route, cleanup: cleanup)

            var description = try hal.tapFormat(tap)
            let frames = try hal.bufferSize(device)
            guard description.mFormatID == kAudioFormatLinearPCM,
                  description.mSampleRate.isFinite, description.mSampleRate > 0,
                  description.mChannelsPerFrame > 0, description.mBytesPerFrame > 0,
                  frames > 0, frames <= 16_384,
                  let format = AVAudioFormat(streamDescription: &description),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw RecognitionFailure.captureUnavailable(diagnostic: "Unsupported device PCM format or buffer size")
            }
            let normalizer = try PCMNormalizer(inputFormat: format, attemptID: attemptID)
            let ring = try AudioBufferRing(format: format, capacity: policy.captureQueueCapacity, maxFrames: frames)
            let io = try hal.registerIO(on: device, ring: ring)
            cleanup.add { [hal] in hal.unregisterIO(on: device, io: io) }
            try Task.checkCancellation()

            // Stop an attempted start even when the HAL reports a partial failure.
            cleanup.add { [hal] in hal.stop(device, io: io) }
            try hal.start(device, io: io)
            try Task.checkCancellation()
            guard !route.interrupted.load(ordering: .acquiring) else {
                throw RecognitionFailure.captureInterrupted
            }

            let pipe = AudioStream.makeStream(bufferingPolicy: .bufferingOldest(policy.captureQueueCapacity))
            pipe.continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason {
                    Task { await self?.stop() }
                }
            }
            capture = RunningCapture(
                cleanup: cleanup, route: route, ring: ring, buffer: buffer,
                normalizer: normalizer, continuation: pipe.continuation
            )
            if diagnosticsEnabled {
                logger.info("Started system capture at \(format.sampleRate, privacy: .public) Hz with \(format.channelCount, privacy: .public) channels")
            }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard await self?.poll() == true else { break }
                    try? await Task.sleep(for: .milliseconds(4))
                }
            }
            return pipe.stream
        } catch {
            cleanup.releaseAll()
            if let halError = error as? HALCaptureError {
                if diagnosticsEnabled {
                    logger.error("\(halError.operation, privacy: .public) returned \(halError.status, privacy: .public)")
                }
                if halError.status == kAudioDevicePermissionsError {
                    throw RecognitionFailure.audioPermissionDenied
                }
                throw RecognitionFailure.captureUnavailable(diagnostic: "\(halError.operation): \(halError.status)")
            }
            throw error
        }
    }

    public func stop() {
        invalidated = true
        end()
    }

    private func observe(
        _ property: CaptureProperty,
        using route: CaptureRouteSignal,
        cleanup: CaptureCleanup
    ) throws {
        cleanup.add(try hal.observe(property) {
            route.interrupted.store(true, ordering: .releasing)
        })
    }

    private func poll() -> Bool {
        guard let capture else { return false }
        do {
            // Bound each drain so cancellation/stop can always run on this executor.
            for _ in 0..<policy.captureQueueCapacity {
                guard !capture.route.interrupted.load(ordering: .acquiring) else {
                    throw RecognitionFailure.captureInterrupted
                }
                guard try capture.ring.copyNext(into: capture.buffer) else { break }
                guard let frame = try capture.normalizer.convert(capture.buffer) else { continue }
                sampleCount += Int64(frame.samples.count)
                switch capture.continuation.yield(frame) {
                case .enqueued: break
                case .dropped: throw RecognitionFailure.captureInterrupted
                case .terminated:
                    end()
                    return false
                @unknown default: throw RecognitionFailure.captureInterrupted
                }
            }
            return true
        } catch {
            end(throwing: error)
            return false
        }
    }

    private func end(throwing error: (any Error)? = nil) {
        pollTask?.cancel()
        pollTask = nil
        guard let capture else { return }
        self.capture = nil
        capture.cleanup.releaseAll()
        capture.continuation.finish(throwing: error)
        if diagnosticsEnabled {
            logger.info("Stopped system capture after \(self.sampleCount, privacy: .public) normalized samples")
        }
    }
}

private final class CaptureRouteSignal: Sendable {
    let interrupted = Atomic(false)
}

private struct RunningCapture {
    let cleanup: CaptureCleanup
    let route: CaptureRouteSignal
    let ring: AudioBufferRing
    let buffer: AVAudioPCMBuffer
    let normalizer: PCMNormalizer
    let continuation: AsyncThrowingStream<PCMFrame, any Error>.Continuation
}

/// Accessed only by the startup call or running capture that owns it.
private final class CaptureCleanup {
    private var releases: [() -> Void] = []

    func add(_ release: @escaping () -> Void) {
        releases.append(release)
    }

    func releaseAll() {
        while let release = releases.popLast() {
            release()
        }
    }

    deinit { releaseAll() }
}
