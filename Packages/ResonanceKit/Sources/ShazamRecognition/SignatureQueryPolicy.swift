import Foundation
import RecognitionCore

struct SignatureQueryPolicy {
    let minimumDuration: TimeInterval
    let maximumDuration: TimeInterval
    let earlyFrameCount: Int64
    let maximumFrameCount: Int64

    init(minimumDuration: TimeInterval, maximumDuration: TimeInterval, captureDuration: Duration) throws {
        let components = captureDuration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let limit = min(maximumDuration, seconds)
        let rate = PCMFrame.sampleRate
        guard minimumDuration.isFinite, maximumDuration.isFinite,
              minimumDuration > 0, limit >= minimumDuration,
              limit * rate < Double(Int64.max) else {
            throw RecognitionFailure.recognitionService(diagnostic: "Shazam catalog query duration exceeds the capture window")
        }
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
        maximumFrameCount = Int64((limit * rate).rounded(.down))
        let earlyTarget = max(minimumDuration, seconds / 2)
        earlyFrameCount = min(Int64((min(earlyTarget, limit) * rate).rounded(.up)), maximumFrameCount)
    }

    func accepts(duration: TimeInterval) -> Bool {
        duration >= minimumDuration && duration <= maximumDuration
    }
}
