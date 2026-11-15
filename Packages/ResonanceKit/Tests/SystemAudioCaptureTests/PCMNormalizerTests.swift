import AVFoundation
import RecognitionCore
@testable import SystemAudioCapture
import Testing

struct PCMNormalizerTests {
    struct FormatCase: Sendable {
        let rate: Double
        let channels: AVAudioChannelCount
        let interleaved: Bool
        let commonFormat: AVAudioCommonFormat
    }

    @Test(arguments: [
        FormatCase(rate: 44_100, channels: 2, interleaved: true, commonFormat: .pcmFormatFloat32),
        FormatCase(rate: 44_100, channels: 2, interleaved: false, commonFormat: .pcmFormatFloat32),
        FormatCase(rate: 48_000, channels: 1, interleaved: false, commonFormat: .pcmFormatFloat32),
        FormatCase(rate: 48_000, channels: 2, interleaved: true, commonFormat: .pcmFormatInt16),
        FormatCase(rate: 96_000, channels: 1, interleaved: true, commonFormat: .pcmFormatFloat32),
        FormatCase(rate: 96_000, channels: 2, interleaved: false, commonFormat: .pcmFormatInt16),
    ])
    func `Converts a stream continuously to mono 48 kHz`(configuration: FormatCase) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: configuration.commonFormat, sampleRate: configuration.rate,
            channels: configuration.channels, interleaved: configuration.interleaved
        ))
        let attemptID = RecognitionAttemptID()
        let normalizer = try PCMNormalizer(inputFormat: format, attemptID: attemptID)
        let frames = AVAudioFrameCount(configuration.rate / 100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames

        var samples: [Float] = []
        for chunk in 0..<12 {
            // Tone in the right channel only makes accidental left-only mapping detectable.
            for channel in 0..<Int(configuration.channels) {
                let source = channel == Int(configuration.channels) - 1
                for index in 0..<Int(frames) {
                    let phase = 2 * Double.pi * 500 * Double(chunk * Int(frames) + index) / configuration.rate
                    let value = source ? Float(sin(phase) * 0.5) : 0
                    let offset = index * buffer.stride
                    if let float = buffer.floatChannelData {
                        float[channel][offset] = value
                    } else {
                        try #require(buffer.int16ChannelData)[channel][offset] = Int16(value * Float(Int16.max))
                    }
                }
            }
            if let frame = try normalizer.convert(buffer) {
                #expect(frame.attemptID == attemptID)
                #expect(frame.position == Int64(samples.count))
                samples.append(contentsOf: frame.samples)
            }
        }

        #expect(abs(samples.count - 5_760) < 128)
        #expect(samples.allSatisfy { $0.isFinite })
        let interior = samples.dropFirst(128)
        let peak = interior.map(abs).max() ?? 0
        #expect(peak > 0.20 && peak <= 0.55)
        let risingCrossings = zip(interior, interior.dropFirst()).count { $0 <= 0 && $1 > 0 }
        #expect((55...60).contains(risingCrossings))

        buffer.frameLength = 0
        #expect(try normalizer.convert(buffer) == nil)
        buffer.frameLength = frames
        for plane in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = plane.mData {
                memset(data, 0, Int(plane.mDataByteSize))
            }
        }
        // Conversion can have a short filter tail, but must not replay the previous chunk.
        let convertedSilence = try normalizer.convert(buffer)
        let silence = try #require(convertedSilence)
        #expect(silence.position == Int64(samples.count))
        #expect(silence.samples.suffix(96).allSatisfy { abs($0) < 0.0001 })
    }

    @Test func `Rejects a format change`() throws {
        let first = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let changed = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: changed, frameCapacity: 16))
        let normalizer = try PCMNormalizer(inputFormat: first, attemptID: RecognitionAttemptID())
        #expect(throws: RecognitionFailure.captureInterrupted) { try normalizer.convert(input) }
    }
}
