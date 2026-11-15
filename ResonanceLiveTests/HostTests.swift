import Foundation
import Testing

@Test func `Live tests have a system audio purpose string in the app host`() throws {
    let usage = try #require(Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") as? String)
    #expect(!usage.isEmpty)
}
