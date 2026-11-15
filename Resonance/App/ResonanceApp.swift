import AppKit
import SwiftUI

@main
struct ResonanceApp: App {
    @NSApplicationDelegateAdaptor(ResonanceAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            RecognitionPopover(model: appDelegate.runtime.presentation)
        } label: {
            Label("Resonance", systemImage: appDelegate.runtime.presentation.status.icon)
                .labelStyle(.iconOnly)
        }
        .menuBarExtraStyle(.window)

        Settings {
            ShortcutSettingsView(model: appDelegate.runtime.shortcuts)
        }
    }
}
