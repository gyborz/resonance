import AVFoundation
import RecognitionCore

/// A streaming converter confined to its caller's serial isolation domain.
/// Input buffers are borrowed only for each synchronous call. Output samples are independently owned.
public final class PCMNormalizer {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let attemptID: RecognitionAttemptID
    private var position: Int64 = 0

    public init(inputFormat: AVAudioFormat, attemptID: RecognitionAttemptID) throws {
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0, inputFormat.commonFormat != .otherFormat,
              let outputFormat = AVAudioFormat(
                  standardFormatWithSampleRate: PCMFrame.sampleRate,
                  channels: 1
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecognitionFailure.captureUnavailable(diagnostic: "Unsupported linear PCM format")
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.attemptID = attemptID
        converter.downmix = true
        converter.primeMethod = .none
    }

    public func convert(_ input: AVAudioPCMBuffer) throws -> PCMFrame? {
        guard input.format == inputFormat else { throw RecognitionFailure.captureInterrupted }
        guard input.frameLength > 0 else { return nil }

        // Reserve space for any samples buffered by the previous conversion.
        let expectedFrames = Double(input.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = ceil(expectedFrames) + 1024
        guard let frameCapacity = AVAudioFrameCount(exactly: capacity),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            throw RecognitionFailure.captureInterrupted
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, status == .haveData || status == .inputRanDry else {
            throw RecognitionFailure.captureInterrupted
        }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else {
            return nil
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        guard samples.allSatisfy(\.isFinite) else { throw RecognitionFailure.captureInterrupted }
        let frame = PCMFrame(attemptID: attemptID, position: position, samples: samples)
        position += Int64(output.frameLength)
        return frame
    }
}
