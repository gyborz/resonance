import Carbon
import RecognitionCore

enum ShortcutRegistrationError: Error, Equatable {
    case alreadyInUse
    case system(OSStatus)
}

@MainActor
final class CarbonShortcutRegistrar: ShortcutRegistering {
    private static let signature: OSType = 0x52534E43 // RSNC

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var shortcut: GlobalShortcut?
    private var onPress: (@MainActor () -> Void)?
    private var identifier: UInt32 = 0
    private var isPressed = false

    isolated deinit {
        unregister()
    }

    func register(_ shortcut: GlobalShortcut, onPress: @escaping @MainActor () -> Void) throws {
        if self.shortcut == shortcut {
            self.onPress = onPress
            return
        }
        try installHandlerIfNeeded()

        let nextIdentifier = identifier &+ 1
        let id = EventHotKeyID(signature: Self.signature, id: nextIdentifier)
        var registration: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), carbonModifiers(shortcut.modifiers), id,
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &registration
        )
        guard status == noErr, let registration else {
            if hotKey == nil { unregister() }
            if status == eventHotKeyExistsErr { throw ShortcutRegistrationError.alreadyInUse }
            throw ShortcutRegistrationError.system(status)
        }

        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = registration
        self.shortcut = shortcut
        identifier = nextIdentifier
        self.onPress = onPress
        isPressed = false
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        shortcut = nil
        onPress = nil
        isPressed = false
    }

    private func installHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        let events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(), shortcutEventHandler, events.count, events, context, &eventHandler
        )
        guard status == noErr else { throw ShortcutRegistrationError.system(status) }
    }

    fileprivate func handleEvent(kind: UInt32, id: EventHotKeyID) -> OSStatus {
        guard hotKey != nil, id.signature == Self.signature, id.id == identifier else {
            return OSStatus(eventNotHandledErr)
        }

        if kind == kEventHotKeyReleased {
            isPressed = false
        } else if !isPressed {
            isPressed = true
            onPress?()
        }
        return noErr
    }

    private func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

private let shortcutEventHandler: EventHandlerUPP = { _, event, context in
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr else { return status }
    let kind = GetEventKind(event)

    // The application event target delivers on the main event loop. Installation and
    // removal are also main-actor operations, so context remains valid during delivery.
    let registrar = Unmanaged<CarbonShortcutRegistrar>.fromOpaque(context).takeUnretainedValue()
    return MainActor.assumeIsolated { registrar.handleEvent(kind: kind, id: id) }
}
