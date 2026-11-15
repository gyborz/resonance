import AppKit
import RecognitionCore
import ShazamRecognition
import SystemAudioCapture

@MainActor
final class ResonanceAppDelegate: NSObject, NSApplicationDelegate {
    let runtime = RecognitionRuntime()

    private var sleepObserver: (any NSObjectProtocol)?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App-hosted tests use injected stores and register only their own services.
        #if DEBUG
        if ProcessInfo.processInfo.environment["RESONANCE_TEST_HOST"] == "1" { return }
        #endif

        runtime.start()
        let coordinator = runtime.coordinator
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { await coordinator.interrupt() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }

        Task {
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class RecognitionRuntime {
    let coordinator: RecognitionCoordinator
    let presentation: RecognitionPresentationModel
    let shortcuts: ShortcutSettingsModel

    convenience init() {
        let policy = RecognitionPolicy()
        self.init(
            coordinator: RecognitionCoordinator(
                policy: policy,
                makeCapture: { SystemAudioCaptureClient(policy: policy) },
                makeRecognizer: { ShazamRecognitionClient(policy: policy) }
            ),
            defaults: .standard,
            registrar: CarbonShortcutRegistrar(),
            urlOpener: WorkspaceTrackURLOpener(),
            explainSystemAudio: Self.explainSystemAudio,
            quit: { NSApp.terminate(nil) }
        )
    }

    init(
        coordinator: RecognitionCoordinator,
        defaults: UserDefaults,
        registrar: any ShortcutRegistering,
        urlOpener: any TrackURLOpening,
        explainSystemAudio: @escaping @MainActor () async -> Bool,
        quit: @escaping @MainActor () -> Void
    ) {
        self.coordinator = coordinator
        let explanationKey = "explainedSystemAudio"
        let presentation = RecognitionPresentationModel(
            workflow: coordinator,
            urlOpener: urlOpener,
            needsExplanation: { !defaults.bool(forKey: explanationKey) },
            explainSystemAudio: explainSystemAudio,
            markExplanationSeen: { defaults.set(true, forKey: explanationKey) },
            quitApplication: quit
        )
        self.presentation = presentation
        shortcuts = ShortcutSettingsModel(
            store: ShortcutSettingsStore(defaults: defaults),
            registrar: registrar,
            onRecognize: { Task { await presentation.recognize() } }
        )
    }

    func start() {
        presentation.startObserving()
        shortcuts.start()
    }

    func shutdown() async {
        shortcuts.stop()
        await coordinator.shutdown()
    }

    private static func explainSystemAudio() async -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Recognize music playing on this Mac")
        alert.informativeText = String(localized: "Resonance listens for a few seconds when you ask it to recognize a song. macOS may ask you to allow system audio access. Resonance doesn’t save a recording.")
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
private struct WorkspaceTrackURLOpener: TrackURLOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
