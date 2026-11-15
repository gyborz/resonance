import AppKit
import RecognitionCore
import ShazamRecognition
import SystemAudioCapture

@MainActor
final class ResonanceAppDelegate: NSObject, NSApplicationDelegate {
    let runtime = RecognitionRuntime()

    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App-hosted tests use injected stores and register only their own services.
        #if DEBUG
        if ProcessInfo.processInfo.environment["RESONANCE_TEST_HOST"] == "1" { return }
        #endif

        runtime.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        Task {
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class RecognitionRuntime {
    private enum Lifecycle {
        case awake, sleeping, shuttingDown
    }

    let coordinator: RecognitionCoordinator
    let presentation: RecognitionPresentationModel
    let shortcuts: ShortcutSettingsModel
    private let workspaceNotifications: NotificationCenter
    private var workspaceObservers: [NotificationCenter.ObservationToken] = []
    private var lifecycle = Lifecycle.awake
    private var sleepInterruption: Task<Void, Never>?

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
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        explainSystemAudio: @escaping @MainActor () async -> Bool,
        quit: @escaping @MainActor () -> Void
    ) {
        self.coordinator = coordinator
        self.workspaceNotifications = workspaceNotifications
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
            onRecognize: { presentation.requestRecognition() }
        )
    }

    func start() {
        guard lifecycle != .shuttingDown, workspaceObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared
        workspaceObservers = [
            workspaceNotifications.addObserver(of: workspace, for: NSWorkspace.WillSleepMessage.self) { [weak self] _ in
                self?.willSleep()
            },
            workspaceNotifications.addObserver(of: workspace, for: NSWorkspace.DidWakeMessage.self) { [weak self] _ in
                self?.didWake()
            },
        ]
        presentation.startObserving()
        shortcuts.start()
    }

    func shutdown() async {
        lifecycle = .shuttingDown
        setRecognitionSuspended(true)
        for observer in workspaceObservers {
            workspaceNotifications.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        shortcuts.stop()
        await coordinator.shutdown()
    }

    private func willSleep() {
        guard lifecycle == .awake else { return }
        lifecycle = .sleeping
        setRecognitionSuspended(true)
        guard sleepInterruption == nil else { return }
        sleepInterruption = Task { [weak self, coordinator] in
            await coordinator.interrupt()
            self?.sleepInterruption = nil
            self?.resumeRecognitionIfReady()
        }
    }

    private func didWake() {
        guard lifecycle == .sleeping else { return }
        lifecycle = .awake
        resumeRecognitionIfReady()
    }

    private func resumeRecognitionIfReady() {
        guard lifecycle == .awake, sleepInterruption == nil else { return }
        setRecognitionSuspended(false)
    }

    private func setRecognitionSuspended(_ suspended: Bool) {
        coordinator.setRecognitionSuspended(suspended)
        presentation.setRecognitionSuspended(suspended)
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
