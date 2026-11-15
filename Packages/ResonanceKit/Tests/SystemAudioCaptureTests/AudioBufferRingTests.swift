import AVFoundation
import RecognitionCore
@testable import SystemAudioCapture
import Testing

struct AudioBufferRingTests {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    @Test func `Copies every plane before the caller can recycle its buffer`() throws {
        let ring = try AudioBufferRing(format: format, capacity: 2, maxFrames: 4)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        let channels = try #require(input.floatChannelData)
        let outputChannels = try #require(output.floatChannelData)

        input.frameLength = 0
        write(input, at: 0, into: ring)
        #expect(try !ring.copyNext(into: output))

        input.frameLength = 4
        channels[0].update(repeating: 0.25, count: 4)
        channels[1].update(repeating: 0.75, count: 4)
        write(input, at: 0, into: ring)
        channels[0].update(repeating: -0.5, count: 4)
        channels[1].update(repeating: -0.5, count: 4)
        #expect(try ring.copyNext(into: output))
        #expect(output.frameLength == 4)
        #expect(outputChannels[0][3] == 0.25)
        #expect(outputChannels[1][3] == 0.75)

        input.frameLength = 2
        write(input, at: 4, into: ring)
        #expect(try ring.copyNext(into: output))
        #expect(output.frameLength == 2)
        #expect(outputChannels[0][1] == -0.5)
        #expect(try !ring.copyNext(into: output))

        input.frameLength = 3
        write(input, at: 6, into: ring)
        #expect(try ring.copyNext(into: output))
        #expect(output.frameLength == 3)
    }

    @Test func `Overflow ends the stream before returning discontinuous audio`() throws {
        let ring = try AudioBufferRing(format: format, capacity: 1, maxFrames: 4)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        write(buffer, at: 0, into: ring)
        write(buffer, at: 4, into: ring)
        #expect(throws: RecognitionFailure.captureInterrupted) { try ring.copyNext(into: buffer) }
    }

    @Test(arguments: [2.0, 6.0, Double.nan])
    func `Rejects overlapping, skipped, or invalid sample timestamps`(timestamp: Double) throws {
        let ring = try AudioBufferRing(format: format, capacity: 2, maxFrames: 4)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        write(buffer, at: 0, into: ring)
        write(buffer, at: timestamp, into: ring)
        #expect(throws: RecognitionFailure.captureInterrupted) { try ring.copyNext(into: buffer) }
    }

    @Test func `Rejects changed layouts and oversized rings`() throws {
        let ring = try AudioBufferRing(format: format, capacity: 2, maxFrames: 4)
        let changed = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: changed, frameCapacity: 4))
        buffer.frameLength = 4
        write(buffer, at: 0, into: ring)
        #expect(throws: RecognitionFailure.captureInterrupted) { try ring.copyNext(into: buffer) }
        #expect(throws: RecognitionFailure.self) {
            try AudioBufferRing(format: format, capacity: 32_000, maxFrames: 4_096)
        }
    }
}

func write(_ buffer: AVAudioPCMBuffer, at sampleTime: Double, into ring: AudioBufferRing) {
    var timestamp = AudioTimeStamp()
    timestamp.mSampleTime = sampleTime
    timestamp.mFlags = .sampleTimeValid
    ring.write(buffer.audioBufferList, at: &timestamp)
}
