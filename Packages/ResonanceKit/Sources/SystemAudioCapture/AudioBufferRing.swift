import AVFoundation
import CaptureRing
import RecognitionCore

/// Core Audio owns a reference while the I/O block is registered. The serial
/// capture executor is the only reader. The C ring publishes slots with
/// acquire/release atomics, and its storage outlives both references.
final class AudioBufferRing: @unchecked Sendable {
    private let ring: OpaquePointer

    init(format: AVAudioFormat, capacity: Int, maxFrames: AVAudioFrameCount) throws {
        let interleaved = format.isInterleaved
        let buffers = interleaved ? 1 : format.channelCount
        let channelsPerBuffer = interleaved ? format.channelCount : 1
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame

        guard let capacity = UInt32(exactly: capacity),
              let ring = ResonanceCaptureRingCreate(
                  capacity, maxFrames, buffers, channelsPerBuffer, bytesPerFrame
              ) else {
            throw RecognitionFailure.captureUnavailable(diagnostic: "Could not allocate the capture queue")
        }
        self.ring = ring
    }

    deinit {
        ResonanceCaptureRingDestroy(ring)
    }

    // This is the entire real-time callback path. The pointers are valid only during the call.
    func write(_ input: UnsafePointer<AudioBufferList>, at timestamp: UnsafePointer<AudioTimeStamp>) {
        ResonanceCaptureRingWrite(ring, input, timestamp)
    }

    func copyNext(into buffer: AVAudioPCMBuffer) throws -> Bool {
        buffer.frameLength = buffer.frameCapacity
        var frames: UInt32 = 0
        let result = ResonanceCaptureRingRead(ring, buffer.mutableAudioBufferList, &frames)
        buffer.frameLength = frames
        guard result >= 0 else { throw RecognitionFailure.captureInterrupted }
        return result == 1
    }
}
