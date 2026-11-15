import AVFoundation
import Foundation
import RecognitionCore
import ShazamKit

/// Original synthesized audio for testing fingerprint matching. The reference layers
/// four voices with seeded pitches and amplitudes. The unrelated track uses the same
/// envelope with a different seed and disjoint pitch ranges.
public enum ShazamFixture {
    public enum Variant: Sendable {
        case reference
        case unrelated
    }

    public static let title = "Resonance Test Pattern"
    public static let artist = "Synthetic Fixture"
    public static let musicURL = URL(string: "https://music.apple.com/us/song/resonance-test-pattern")!
    public static let referenceDuration = 16

    public static func catalogData(leadingMediaItems: [SHMediaItem] = []) throws -> Data {
        let catalog = SHCustomCatalog()
        let generator = SHSignatureGenerator()
        let rate = PCMFrame.sampleRate
        let format = try pcmFormat(sampleRate: rate)

        for position in stride(from: 0, to: referenceDuration * Int(rate), by: 4_800) {
            let samples = samples(in: position..<(position + 4_800))
            let buffer = try pcmBuffer(samples: samples, format: format)
            try generator.append(buffer, at: AVAudioTime(sampleTime: Int64(position), atRate: rate))
        }
        let metadata = SHMediaItem(properties: [.title: title, .artist: artist, .appleMusicURL: musicURL])
        try catalog.addReferenceSignature(generator.signature(), representing: leadingMediaItems + [metadata])
        return catalog.dataRepresentation
    }

    /// Write a temporary WAV suitable for playback in a separate process.
    public static func writePlaybackFile(to url: URL) throws {
        let rate = PCMFrame.sampleRate
        let format = try pcmFormat(sampleRate: rate)
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        for position in stride(from: 0, to: referenceDuration * Int(rate), by: 4_800) {
            let samples = samples(in: position..<(position + 4_800))
            try file.write(from: pcmBuffer(samples: samples, format: format))
        }
    }

    public static func samples(
        in frames: Range<Int>,
        sampleRate: Double = PCMFrame.sampleRate,
        variant: Variant = .reference
    ) -> [Float] {
        precondition(frames.lowerBound >= 0 && sampleRate.isFinite && sampleRate >= 16_000)
        let seed = variant == .reference ? 24 : 67_653
        var samples: [Float] = []
        samples.reserveCapacity(frames.count)
        var currentCell: Int?
        var voices: [Voice] = []

        for frame in frames {
            let time = Double(frame) / sampleRate
            let cell = Int(time * 5)
            if cell != currentCell {
                voices = (0..<4).map { lane in
                    let voiceSeed = seed &+ (cell &* 11) &+ (lane &* 331)
                    let note = switch variant {
                    case .reference: 42 + lane * 9 + Int(randomFraction(voiceSeed) * 20)
                    case .unrelated: 96 + Int(randomFraction(voiceSeed) * 12)
                    }
                    let frequency = 440 * pow(2, Double(note - 69) / 12)
                    return Voice(
                        radiansPerSecond: 2 * .pi * frequency,
                        amplitude: 0.5 + 0.5 * randomFraction(voiceSeed &+ 13)
                    )
                }
                currentCell = cell
            }

            let offset = time - Double(cell) / 5
            let envelope = min(1, offset * 140) * min(1, (0.2 - offset) * 40) * exp(-4 * offset)
            var sum = 0.0
            for voice in voices {
                let phase = voice.radiansPerSecond * offset
                sum += (sin(phase) + 0.45 * sin(phase * 2) + 0.17 * sin(phase * 3)) * voice.amplitude
            }
            samples.append(Float(sum * envelope * 0.14))
        }
        return samples
    }

    private struct Voice {
        let radiansPerSecond: Double
        let amplitude: Double
    }

    private static func randomFraction(_ seed: Int) -> Double {
        var state = UInt64(truncatingIfNeeded: seed) &+ 0x9e3779b97f4a7c15
        state = (state ^ (state >> 30)) &* 0xbf58476d1ce4e5b9
        state = (state ^ (state >> 27)) &* 0x94d049bb133111eb
        return Double((state ^ (state >> 31)) >> 11) / 9_007_199_254_740_992
    }

    private static func pcmFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw FixtureError.cannotCreateBuffer
        }
        return format
    }

    private static func pcmBuffer(samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw FixtureError.cannotCreateBuffer }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                channel.update(from: baseAddress, count: source.count)
            }
        }
        return buffer
    }

    private enum FixtureError: Error {
        case cannotCreateBuffer
    }
}
