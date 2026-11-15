import Foundation
import Testing

@Test func `The host is a menu bar app`() {
    #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
}
