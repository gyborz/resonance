import Foundation
import Testing

@Test func `The host is a menu bar app`() {
    #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
}

@Test func `The deterministic plan isolates the app host from launch preferences`() {
    #expect(ProcessInfo.processInfo.environment["RESONANCE_TEST_HOST"] == "1")
}
