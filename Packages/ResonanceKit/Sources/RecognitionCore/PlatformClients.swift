import Foundation

@MainActor
public protocol TrackURLOpening {
    func open(_ url: URL)
}

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
}

public struct GlobalShortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: ShortcutModifiers

    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

@MainActor
public protocol ShortcutRegistering {
    func register(_ shortcut: GlobalShortcut, onPress: @escaping @MainActor () -> Void) throws
    func unregister()
}
