import Carbon
import Foundation
import Observation
import RecognitionCore

struct ShortcutKey {
    let id: UInt16
    let fallbackLabel: String

    func label(using source: TISInputSource?, modifiers: ShortcutModifiers) -> String {
        KeyboardLayout.label(for: id, modifiers: modifiers, source: source) ?? fallbackLabel
    }

    static let choices: [Self] = [
        (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"),
        (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"),
        (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"),
        (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
        (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
        (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"),
        (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"), (kVK_ANSI_U, "U"),
        (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
        (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"),
        (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
        (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"),
        (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
    ].map { Self(id: UInt16($0.0), fallbackLabel: $0.1) }
}

private enum KeyboardLayout {
    static func label(for keyCode: UInt16, modifiers: ShortcutModifiers, source: TISInputSource?) -> String? {
        guard let source,
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        // Command can remap the base key. The other modifiers have their own glyphs.
        let modifierState = modifiers.contains(.command) ? UInt32(cmdKey) >> 8 : 0
        var deadKeyState: UInt32 = 0
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        let status = withExtendedLifetime(source) {
            UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), modifierState, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, units.count, &length, &units
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(decoding: units.prefix(length), as: UTF16.self).uppercased()
    }
}

private extension GlobalShortcut {
    var isValid: Bool {
        let primary: ShortcutModifiers = [.command, .option, .control]
        let supported = primary.union(.shift)
        return ShortcutKey.choices.contains { $0.id == keyCode }
            && !modifiers.intersection(primary).isEmpty
            && modifiers.subtracting(supported).isEmpty
    }

    func label(with keyLabel: String) -> String {
        let modifierLabels: [(ShortcutModifiers, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        let prefix = modifierLabels.filter { modifiers.contains($0.0) }.map(\.1).joined()
        return prefix + keyLabel
    }

    func overlapsCommonAppCommand(keyLabel: String) -> Bool {
        switch modifiers {
        case .command:
            ["A", "C", "F", "G", "H", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "V", "W", "X", "Z"].contains(keyLabel)
        case [.command, .shift]:
            ["G", "N", "S", "Z"].contains(keyLabel)
        case [.command, .option]:
            ["C", "H", "M", "Q", "V", "W"].contains(keyLabel)
        case [.command, .option, .shift]:
            keyLabel == "V"
        default:
            false
        }
    }
}

@MainActor
struct ShortcutSettingsStore {
    private let defaults: UserDefaults
    private static let key = "recognitionGlobalShortcut"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> GlobalShortcut? {
        guard let data = defaults.data(forKey: Self.key),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data),
              shortcut.isValid else {
            clear()
            return nil
        }
        return shortcut
    }

    func save(_ shortcut: GlobalShortcut) throws {
        defaults.set(try JSONEncoder().encode(shortcut), forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

@MainActor
@Observable
final class ShortcutSettingsModel {
    enum Issue: Equatable {
        case invalidShortcut
        case alreadyInUse
        case registrationFailed
    }

    private(set) var configured: GlobalShortcut?
    private(set) var isRegistered = false
    private(set) var issue: Issue?
    private(set) var shortcutToConfirm: GlobalShortcut?

    @ObservationIgnored private let store: ShortcutSettingsStore
    @ObservationIgnored private let registrar: any ShortcutRegistering
    @ObservationIgnored private let keyboardSource: @MainActor () -> TISInputSource?
    @ObservationIgnored private let onRecognize: @MainActor () -> Void
    @ObservationIgnored private var didStart = false

    init(
        store: ShortcutSettingsStore,
        registrar: any ShortcutRegistering,
        keyboardSource: @escaping @MainActor () -> TISInputSource? = {
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        },
        onRecognize: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.registrar = registrar
        self.keyboardSource = keyboardSource
        self.onRecognize = onRecognize
    }

    var shortcutLabel: String? { configured.map { label(for: $0) } }

    func label(for shortcut: GlobalShortcut) -> String {
        shortcut.label(with: keyLabel(for: shortcut))
    }

    func keyLabels(for modifiers: ShortcutModifiers) -> [(id: UInt16, label: String)] {
        let source = keyboardSource()
        return ShortcutKey.choices.map { key in
            (id: key.id, label: key.label(using: source, modifiers: modifiers))
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private func keyLabel(for shortcut: GlobalShortcut) -> String {
        ShortcutKey.choices.first { $0.id == shortcut.keyCode }?
            .label(using: keyboardSource(), modifiers: shortcut.modifiers) ?? ""
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        configured = store.load()
        if let configured {
            register(configured, persist: false)
        }
    }

    func assign(_ shortcut: GlobalShortcut) {
        shortcutToConfirm = nil
        guard shortcut.isValid else {
            issue = .invalidShortcut
            return
        }
        guard shortcut != configured || !isRegistered else {
            issue = nil
            return
        }
        if shortcut.overlapsCommonAppCommand(keyLabel: keyLabel(for: shortcut)) {
            issue = nil
            shortcutToConfirm = shortcut
            return
        }
        register(shortcut, persist: true)
    }

    func confirmAssignment(_ shortcut: GlobalShortcut) {
        guard shortcutToConfirm == shortcut else { return }
        shortcutToConfirm = nil
        register(shortcut, persist: true)
    }

    func dismissAssignmentWarning() {
        shortcutToConfirm = nil
    }

    func disable() {
        stop()
        store.clear()
        configured = nil
        issue = nil
    }

    func stop() {
        shortcutToConfirm = nil
        guard isRegistered else { return }
        registrar.unregister()
        isRegistered = false
    }

    private func register(_ shortcut: GlobalShortcut, persist: Bool) {
        do {
            try registrar.register(shortcut, onPress: onRecognize)
        } catch ShortcutRegistrationError.alreadyInUse {
            issue = .alreadyInUse
            return
        } catch {
            issue = .registrationFailed
            return
        }

        isRegistered = true
        configured = shortcut
        issue = nil
        if persist {
            do {
                try store.save(shortcut)
            } catch {
                issue = .registrationFailed
            }
        }
    }
}
