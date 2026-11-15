import Carbon
import RecognitionCore
import SwiftUI

struct ShortcutSettingsView: View {
    let model: ShortcutSettingsModel

    @State private var keyCode: UInt16
    @State private var modifiers: ShortcutModifiers

    init(model: ShortcutSettingsModel) {
        self.model = model
        _keyCode = State(initialValue: model.configured?.keyCode ?? UInt16(kVK_ANSI_R))
        _modifiers = State(initialValue: model.configured?.modifiers ?? [])
    }

    var body: some View {
        let shortcut = GlobalShortcut(keyCode: keyCode, modifiers: modifiers)
        let needsConfirmation = model.shortcutToConfirm == shortcut
        let keys = model.keyLabels(for: modifiers)
        Form {
            Section("Recognition Shortcut") {
                if let label = model.shortcutLabel {
                    LabeledContent(model.isRegistered ? "Active shortcut" : "Saved shortcut", value: label)
                } else {
                    Text("No shortcut assigned")
                        .foregroundStyle(.secondary)
                }

                Picker("Key", selection: $keyCode) {
                    ForEach(keys, id: \.id) { key in
                        Text(key.label).tag(key.id)
                    }
                }

                Toggle("Command", isOn: modifierBinding(.command))
                Toggle("Option", isOn: modifierBinding(.option))
                Toggle("Control", isOn: modifierBinding(.control))
                Toggle("Shift", isOn: modifierBinding(.shift))

                if let issue = model.issue {
                    Text(issue.description)
                        .foregroundStyle(.secondary)
                }
                if needsConfirmation {
                    Text("\(model.label(for: shortcut)) overlaps a common app command. Pressing it in other apps may trigger recognition.")
                }

                HStack {
                    Button("Disable Shortcut") { model.disable() }
                        .disabled(model.configured == nil)
                    Spacer()
                    if needsConfirmation {
                        Button("Cancel") { model.dismissAssignmentWarning() }
                        Button("Save Anyway") { model.confirmAssignment(shortcut) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Save Shortcut") { model.assign(shortcut) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: shortcut) {
            model.dismissAssignmentWarning()
        }
    }

    private func modifierBinding(_ modifier: ShortcutModifiers) -> Binding<Bool> {
        Binding(
            get: { modifiers.contains(modifier) },
            set: { enabled in
                if enabled {
                    modifiers.insert(modifier)
                } else {
                    modifiers.remove(modifier)
                }
            }
        )
    }
}

private extension ShortcutSettingsModel.Issue {
    var description: LocalizedStringResource {
        switch self {
        case .invalidShortcut: "Select Command, Option, or Control for your shortcut."
        case .alreadyInUse: "This shortcut is already in use. Choose another combination."
        case .registrationFailed: "The shortcut couldn’t be saved. Try another combination."
        }
    }
}
