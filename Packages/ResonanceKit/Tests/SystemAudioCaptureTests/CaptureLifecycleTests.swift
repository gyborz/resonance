import AVFoundation
import CoreAudio
import RecognitionCore
import Synchronization
@testable import SystemAudioCapture
import Testing

struct CaptureLifecycleTests {
    @Test(arguments: FakeHAL.Stage.allCases)
    fileprivate func `A setup error releases each acquired resource in reverse order`(failure: FakeHAL.Stage) async {
        let hal = FakeHAL(failingAt: failure)
        let capture = SystemAudioCaptureClient(policy: RecognitionPolicy(), hal: hal)
        await #expect(throws: RecognitionFailure.self) {
            try await capture.start(attemptID: RecognitionAttemptID())
        }
        await capture.stop()

        let cleanup: [FakeHAL.Release] = switch failure {
        case .observeOutput: []
        case .observeDataSource: [.output]
        case .observeService: [.dataSource, .output]
        case .createTap: [.service, .dataSource, .output]
        case .observeFormat: [.tap, .service, .dataSource, .output]
        case .readUID, .createAggregate: [.format, .tap, .service, .dataSource, .output]
        case .observeRate: [.aggregate, .format, .tap, .service, .dataSource, .output]
        case .observeAbnormalStop: [.rate, .aggregate, .format, .tap, .service, .dataSource, .output]
        case .readFormat, .readBufferSize, .registerIO:
            [.abnormalStop, .rate, .aggregate, .format, .tap, .service, .dataSource, .output]
        case .start: FakeHAL.fullCleanup
        }
        #expect(hal.releases == cleanup)
    }

    @Test func `Reports permission denied from a public HAL status`() async {
        let hal = FakeHAL(failingAt: .start, status: kAudioDevicePermissionsError)
        let capture = SystemAudioCaptureClient(policy: RecognitionPolicy(), hal: hal)
        await #expect(throws: RecognitionFailure.audioPermissionDenied) {
            try await capture.start(attemptID: RecognitionAttemptID())
        }
        #expect(hal.releases == FakeHAL.fullCleanup)
    }

    @Test func `Stopping before start leaves the HAL untouched`() async {
        let hal = FakeHAL()
        let capture = SystemAudioCaptureClient(policy: RecognitionPolicy(), hal: hal)
        await capture.stop()
        await #expect(throws: CancellationError.self) {
            try await capture.start(attemptID: RecognitionAttemptID())
        }
        #expect(hal.acquisitions.isEmpty)
        #expect(hal.releases.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func `Cancellation during device startup rolls back acquisition`() async throws {
        let gate = StartGate()
        let hal = FakeHAL(startGate: gate)
        let capture = SystemAudioCaptureClient(policy: RecognitionPolicy(), hal: hal)
        let starting = Task {
            defer { gate.arrivals.continuation.finish() }
            return try await capture.start(attemptID: RecognitionAttemptID())
        }

        var arrivals = gate.arrivals.stream.makeAsyncIterator()
        let arrived: Void? = await arrivals.next()
        if arrived == nil { _ = try await starting.value }
        try #require(arrived != nil)
        starting.cancel()
        async let stopped: Void = capture.stop()
        gate.resume.signal()
        await stopped

        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(hal.releases == FakeHAL.fullCleanup)
    }

    @Test(.timeLimit(.minutes(1))) func `A route change ends the stream and a retry owns fresh resources`() async throws {
        let hal = FakeHAL()
        let id = RecognitionAttemptID()
        let capture = SystemAudioCaptureClient(policy: RecognitionPolicy(), hal: hal)
        let stream = try await capture.start(attemptID: id)
        let capturedRing = try #require(hal.ring)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: FakeHAL.makeFormat(), frameCapacity: 512))
        let channels = try #require(buffer.floatChannelData)
        buffer.frameLength = 512
        channels[0].update(repeating: 0.125, count: 512)
        channels[1].update(repeating: 0.125, count: 512)
        write(buffer, at: 80, into: capturedRing)

        var frames = stream.makeAsyncIterator()
        let nextFrame = try await frames.next()
        let frame = try #require(nextFrame)
        #expect(frame.attemptID == id)
        #expect(frame.position == 0)
        #expect(frame.samples.count == 512)
        #expect(frame.samples.contains { abs($0) > 0.01 })

        let onChange = try #require(hal.outputChange)
        onChange()
        await #expect(throws: RecognitionFailure.captureInterrupted) { try await frames.next() }
        await capture.stop()
        await capture.stop()
        #expect(hal.releases == FakeHAL.fullCleanup)
        #expect(hal.ring == nil)

        let next = FakeHAL()
        let retry = SystemAudioCaptureClient(policy: RecognitionPolicy(), hal: next)
        let nextStream = try await retry.start(attemptID: RecognitionAttemptID())
        onChange() // A late notification still addresses only the retired attempt.
        await retry.stop()
        var nextFrames = nextStream.makeAsyncIterator()
        #expect(try await nextFrames.next() == nil)
        #expect(next.releases == FakeHAL.fullCleanup)
    }

    @Test(.timeLimit(.minutes(1))) func `Variable callbacks can exceed the nominal frame count`() async throws {
        let hal = FakeHAL(largestVariableBuffer: 513)
        let capture = SystemAudioCaptureClient(policy: RecognitionPolicy(), hal: hal)
        let stream = try await capture.start(attemptID: RecognitionAttemptID())
        let ring = try #require(hal.ring)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: FakeHAL.makeFormat(), frameCapacity: 513))
        let channels = try #require(buffer.floatChannelData)
        var frames = stream.makeAsyncIterator()
        var position: Int64 = 0

        for count: AVAudioFrameCount in [512, 513, 512] {
            buffer.frameLength = count
            channels[0].update(repeating: 0.25, count: Int(count))
            channels[1].update(repeating: 0.25, count: Int(count))
            write(buffer, at: Double(position), into: ring)
            let next = try await frames.next()
            let frame = try #require(next)
            #expect(frame.position == position)
            #expect(frame.samples.count == Int(count))
            position += Int64(count)
        }

        await capture.stop()
        #expect(try await frames.next() == nil)
        #expect(hal.releases == FakeHAL.fullCleanup)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `An abnormal device stop interrupts the stream and releases the capture`(afterFirstBuffer: Bool) async throws {
        let hal = FakeHAL()
        let capture = SystemAudioCaptureClient(policy: RecognitionPolicy(), hal: hal)
        let stream = try await capture.start(attemptID: RecognitionAttemptID())
        var frames = stream.makeAsyncIterator()
        let notifyStopped = try #require(hal.abnormalStop)

        if afterFirstBuffer {
            let ring = try #require(hal.ring)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: FakeHAL.makeFormat(), frameCapacity: 512))
            let channels = try #require(buffer.floatChannelData)
            buffer.frameLength = 512
            channels[0].update(repeating: 0.25, count: 512)
            channels[1].update(repeating: 0.25, count: 512)
            write(buffer, at: 0, into: ring)
            let next = try await frames.next()
            try #require(next != nil)
        }

        notifyStopped()
        await #expect(throws: RecognitionFailure.captureInterrupted) { try await frames.next() }
        await capture.stop()
        #expect(hal.releases == FakeHAL.fullCleanup)
        #expect(hal.abnormalStop == nil)
        #expect(hal.ring == nil)
    }

    @Test(.timeLimit(.minutes(1))) func `A slow consumer sees a bounded queue failure and cleanup`() async throws {
        let hal = FakeHAL()
        let capture = SystemAudioCaptureClient(policy: RecognitionPolicy(captureQueueCapacity: 1), hal: hal)
        let stream = try await capture.start(attemptID: RecognitionAttemptID())
        let capturedRing = try #require(hal.ring)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: FakeHAL.makeFormat(), frameCapacity: 512))
        buffer.frameLength = 512
        let channels = try #require(buffer.floatChannelData)
        channels[0].update(repeating: 0.25, count: 512)
        channels[1].update(repeating: 0.25, count: 512)
        write(buffer, at: 0, into: capturedRing)
        write(buffer, at: 512, into: capturedRing) // Overflows the ring or the normalized queue.

        // Await stop from the interruption itself so the consumer cannot drain its queue before overflow.
        var ended = hal.didStop.stream.makeAsyncIterator()
        _ = await ended.next()
        await #expect(throws: RecognitionFailure.captureInterrupted) {
            for try await _ in stream {}
        }
        #expect(hal.releases == FakeHAL.fullCleanup)
    }
}

private final class StartGate: Sendable {
    let arrivals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let resume = DispatchSemaphore(value: 0)
}

private final class FakeHAL: CaptureHAL {
    enum Stage: String, CaseIterable {
        case observeOutput, observeDataSource, observeService, createTap, observeFormat, readUID, createAggregate
        case observeRate, observeAbnormalStop, readFormat, readBufferSize, registerIO, start
    }

    enum Release: Equatable {
        case stop, callback, abnormalStop, rate, aggregate, format, tap, service, dataSource, output
    }

    static let fullCleanup: [Release] = [
        .stop, .callback, .abnormalStop, .rate, .aggregate, .format, .tap, .service, .dataSource, .output,
    ]

    private struct Activity {
        var acquisitions: [Stage] = []
        var releases: [Release] = []
        var ring: AudioBufferRing?
        var outputChange: (@Sendable () -> Void)?
        var abnormalStop: (@Sendable () -> Void)?
    }

    private let activity = Mutex(Activity())
    private let failingAt: Stage?
    private let status: OSStatus
    private let gate: StartGate?
    private let largestVariableBuffer: UInt32?
    let didStop = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    init(
        failingAt: Stage? = nil,
        status: OSStatus = kAudioHardwareUnspecifiedError,
        startGate: StartGate? = nil,
        largestVariableBuffer: UInt32? = nil
    ) {
        self.failingAt = failingAt
        self.status = status
        self.gate = startGate
        self.largestVariableBuffer = largestVariableBuffer
    }

    var acquisitions: [Stage] { activity.withLock { $0.acquisitions } }
    var releases: [Release] { activity.withLock { $0.releases } }
    var ring: AudioBufferRing? { activity.withLock { $0.ring } }
    var outputChange: (@Sendable () -> Void)? { activity.withLock { $0.outputChange } }
    var abnormalStop: (@Sendable () -> Void)? { activity.withLock { $0.abnormalStop } }

    static func makeFormat() -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }

    func createTap() throws -> AudioObjectID {
        try acquired(.createTap)
        return 10
    }

    func tapUID(_ tap: AudioObjectID) throws -> String {
        try acquired(.readUID)
        return "test-tap"
    }

    func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        try acquired(.readFormat)
        let format = Self.makeFormat()
        return withExtendedLifetime(format) { format.streamDescription.pointee }
    }

    func createAggregate(tapUID: String) throws -> AudioObjectID {
        try acquired(.createAggregate)
        return 20
    }

    func maximumCallbackFrames(_ device: AudioObjectID) throws -> UInt32 {
        try acquired(.readBufferSize)
        return largestVariableBuffer ?? 512
    }

    func observe(_ property: CaptureProperty, change: @escaping @Sendable () -> Void) throws -> () -> Void {
        switch property {
        case .defaultOutput:
            try acquired(.observeOutput)
            activity.withLock { $0.outputChange = change }
            return {
                self.release(.output)
                self.activity.withLock { $0.outputChange = nil }
            }
        case .outputDataSource:
            try acquired(.observeDataSource)
            return { self.release(.dataSource) }
        case .serviceRestart:
            try acquired(.observeService)
            return { self.release(.service) }
        case .tapFormat:
            try acquired(.observeFormat)
            return { self.release(.format) }
        case .aggregateSampleRate:
            try acquired(.observeRate)
            return { self.release(.rate) }
        case .ioStoppedAbnormally:
            try acquired(.observeAbnormalStop)
            activity.withLock { $0.abnormalStop = change }
            return {
                self.release(.abnormalStop)
                self.activity.withLock { $0.abnormalStop = nil }
            }
        }
    }

    func registerIO(on device: AudioObjectID, ring: AudioBufferRing) throws -> AudioDeviceIOProcID {
        try acquired(.registerIO)
        activity.withLock { $0.ring = ring }
        return { _, _, _, _, _, _, _ in noErr }
    }

    func start(_ device: AudioObjectID, io: AudioDeviceIOProcID) throws {
        try acquired(.start)
        if let gate {
            gate.arrivals.continuation.yield()
            gate.resume.wait()
        }
    }

    func stop(_ device: AudioObjectID, io: AudioDeviceIOProcID) {
        release(.stop)
        didStop.continuation.yield()
    }

    func unregisterIO(on device: AudioObjectID, io: AudioDeviceIOProcID) {
        release(.callback)
        activity.withLock { $0.ring = nil }
    }

    func destroyAggregate(_ device: AudioObjectID) { release(.aggregate) }
    func destroyTap(_ tap: AudioObjectID) { release(.tap) }

    private func acquired(_ stage: Stage) throws {
        activity.withLock { $0.acquisitions.append(stage) }
        if failingAt == stage {
            throw HALCaptureError(operation: stage.rawValue, status: status)
        }
    }

    private func release(_ release: Release) {
        activity.withLock { $0.releases.append(release) }
    }
}
