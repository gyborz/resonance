import Carbon
import Foundation
import RecognitionCore
import RecognitionTestSupport
@testable import Resonance
import Testing

@MainActor
struct ShortcutSettingsTests {
    private let first = GlobalShortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: [.control, .option])
    private let second = GlobalShortcut(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command, .control])

    @Test func `Only a saved shortcut registers and one press dispatches one command`() throws {
        try withSettings { _, store, registrar in
            var presses = 0
            let model = ShortcutSettingsModel(store: store, registrar: registrar) { presses += 1 }

            model.start()
            #expect(model.configured == nil)
            #expect(registrar.registered == nil)
            registrar.press()
            #expect(presses == 0)

            model.assign(first)
            #expect(store.load() == first)
            #expect(model.isRegistered)
            #expect(model.issue == nil)
            registrar.press()
            #expect(presses == 1)

            model.stop()
            registrar.press()
            #expect(presses == 1)
            #expect(registrar.registered == nil)
            #expect(store.load() == first)
        }
    }

    @Test func `Settings restore once and support change and disable`() throws {
        try withSettings { _, store, registrar in
            try store.save(first)
            let model = ShortcutSettingsModel(store: store, registrar: registrar, onRecognize: {})
            model.start()
            #expect(registrar.registered == first)
            registrar.registrationError = ShortcutRegistrationError.alreadyInUse

            model.start()
            #expect(model.issue == nil)

            registrar.registrationError = nil
            model.assign(second)
            #expect(registrar.registered == second)
            #expect(store.load() == second)
            model.disable()
            #expect(registrar.registered == nil)
            #expect(model.configured == nil)
            #expect(store.load() == nil)
            #expect(!model.isRegistered)
        }
    }

    @Test func `Registration conflict preserves the previous working shortcut`() throws {
        try withSettings { _, store, registrar in
            let model = ShortcutSettingsModel(store: store, registrar: registrar, onRecognize: {})
            model.assign(first)
            registrar.registrationError = ShortcutRegistrationError.alreadyInUse
            model.assign(second)

            #expect(model.issue == .alreadyInUse)
            #expect(model.configured == first)
            #expect(model.isRegistered)
            #expect(registrar.registered == first)
            #expect(store.load() == first)
        }
    }

    @Test(arguments: [kVK_ANSI_C, kVK_ANSI_Q])
    func `Common app shortcuts stay unsaved until confirmed`(keyCode: Int) throws {
        try withSettings { _, store, registrar in
            let model = ShortcutSettingsModel(
                store: store, registrar: registrar, keyboardSource: { nil }, onRecognize: {}
            )
            let common = GlobalShortcut(keyCode: UInt16(keyCode), modifiers: .command)
            model.assign(first)
            model.assign(common)

            #expect(model.shortcutToConfirm == common)
            #expect(model.configured == first)
            #expect(registrar.registered == first)
            #expect(store.load() == first)

            model.dismissAssignmentWarning()
            model.confirmAssignment(common)
            #expect(model.shortcutToConfirm == nil)
            #expect(registrar.registered == first)
            #expect(store.load() == first)

            model.assign(common)
            model.confirmAssignment(common)
            #expect(model.shortcutToConfirm == nil)
            #expect(model.configured == common)
            #expect(registrar.registered == common)
            #expect(store.load() == common)
        }
    }

    @Test func `The Dvorak Command mapping drives the picker and saved label`() throws {
        try withSettings { _, store, registrar in
            let sources = try #require(TISCreateInputSourceList(
                [kTISPropertyInputSourceID as String: "com.apple.keylayout.DVORAK-QWERTYCMD"] as CFDictionary, true
            )?.takeRetainedValue() as? [TISInputSource])
            let source = try #require(sources.first)
            let model = ShortcutSettingsModel(
                store: store, registrar: registrar, keyboardSource: { source }, onRecognize: {}
            )
            let physicalR = UInt16(kVK_ANSI_R)
            let commandR = GlobalShortcut(keyCode: physicalR, modifiers: .command)

            #expect(model.keyLabels(for: []).first { $0.id == physicalR }?.label == "P")
            #expect(model.keyLabels(for: [.option, .command]).first { $0.id == physicalR }?.label == "R")
            #expect(model.label(for: commandR) == "⌘R")

            try store.save(commandR)
            model.start()
            #expect(model.shortcutLabel == "⌘R")
            #expect(registrar.registered?.keyCode == physicalR)
        }
    }

    @Test func `A saved shortcut that fails to register can be retried`() throws {
        try withSettings { _, store, registrar in
            try store.save(first)
            registrar.registrationError = ShortcutRegistrationError.system(-1)
            let model = ShortcutSettingsModel(store: store, registrar: registrar, onRecognize: {})
            model.start()

            #expect(model.issue == .registrationFailed)
            #expect(model.configured == first)
            #expect(!model.isRegistered)

            registrar.registrationError = nil
            model.assign(first)
            #expect(model.isRegistered)
            #expect(model.issue == nil)
        }
    }

    @Test func `Malformed and unsupported saved values recover to no shortcut`() throws {
        try withSettings { defaults, store, registrar in
            defaults.set(Data([0xff]), forKey: "recognitionGlobalShortcut")
            #expect(store.load() == nil)
            #expect(defaults.object(forKey: "recognitionGlobalShortcut") == nil)

            let invalid = GlobalShortcut(keyCode: UInt16.max, modifiers: .shift)
            try store.save(invalid)
            let model = ShortcutSettingsModel(store: store, registrar: registrar, onRecognize: {})
            model.start()
            #expect(registrar.registered == nil)

            model.assign(invalid)
            #expect(model.issue == .invalidShortcut)
            #expect(store.load() == nil)
        }
    }

    private func withSettings(
        _ test: (UserDefaults, ShortcutSettingsStore, FakeShortcutRegistrar) throws -> Void
    ) throws {
        let suite = "ResonanceTests.ShortcutSettings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults, ShortcutSettingsStore(defaults: defaults), FakeShortcutRegistrar())
    }
}
