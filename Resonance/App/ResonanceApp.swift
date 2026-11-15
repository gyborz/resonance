import SwiftUI

@main
struct ResonanceApp: App {
    var body: some Scene {
        MenuBarExtra("Resonance", systemImage: "waveform") {
            Text("Resonance")
        }
        .menuBarExtraStyle(.window)
    }
}
