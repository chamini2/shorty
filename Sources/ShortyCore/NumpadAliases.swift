import Carbon
import Foundation

/// Carbon hotkeys match a key code, so `cmd+option+1` ignores the keypad even
/// though Mac menu shortcuts fire from either digit. A digit binding therefore
/// also claims its keypad twin, unless some other binding asks for that twin.
public struct NumpadAliasResolver: Sendable {
    private let claimed: Set<String>

    public init(claimedHotKeys: [KeyCombo]) {
        claimed = Set(claimedHotKeys.map(\.normalizedValue))
    }

    public func alias(for hotKey: KeyCombo) -> KeyCombo? {
        guard let twin = hotKey.numpadTwin, !claimed.contains(twin.normalizedValue) else {
            return nil
        }

        return twin
    }
}

extension KeyCombo {
    private static let numpadKeyCodesByTopRowKeyCode: [UInt32: (code: UInt32, name: String)] = [
        UInt32(kVK_ANSI_0): (UInt32(kVK_ANSI_Keypad0), "numpad0"),
        UInt32(kVK_ANSI_1): (UInt32(kVK_ANSI_Keypad1), "numpad1"),
        UInt32(kVK_ANSI_2): (UInt32(kVK_ANSI_Keypad2), "numpad2"),
        UInt32(kVK_ANSI_3): (UInt32(kVK_ANSI_Keypad3), "numpad3"),
        UInt32(kVK_ANSI_4): (UInt32(kVK_ANSI_Keypad4), "numpad4"),
        UInt32(kVK_ANSI_5): (UInt32(kVK_ANSI_Keypad5), "numpad5"),
        UInt32(kVK_ANSI_6): (UInt32(kVK_ANSI_Keypad6), "numpad6"),
        UInt32(kVK_ANSI_7): (UInt32(kVK_ANSI_Keypad7), "numpad7"),
        UInt32(kVK_ANSI_8): (UInt32(kVK_ANSI_Keypad8), "numpad8"),
        UInt32(kVK_ANSI_9): (UInt32(kVK_ANSI_Keypad9), "numpad9"),
    ]

    /// The keypad combo with the same modifiers, for digit keys only.
    public var numpadTwin: KeyCombo? {
        guard let twin = Self.numpadKeyCodesByTopRowKeyCode[keyCode] else {
            return nil
        }

        let modifierPrefix = normalizedValue
            .split(separator: "+")
            .dropLast()
            .joined(separator: "+")
        let normalized = modifierPrefix.isEmpty ? twin.name : "\(modifierPrefix)+\(twin.name)"

        return KeyCombo(keyCode: twin.code, modifiers: modifiers, normalizedValue: normalized)
    }
}
