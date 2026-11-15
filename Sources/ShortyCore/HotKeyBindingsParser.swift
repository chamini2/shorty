import Foundation
import Yams

public enum HotKeyBindingsError: Error, CustomStringConvertible {
    case invalidBlock(String)
    case unknownBinding(String)
    case invalidValue(name: String, value: String, error: Error)
    case movedSetting(old: String, new: String)

    public var description: String {
        switch self {
        case let .invalidBlock(message):
            return "Invalid hotkeys config: \(message)"
        case let .unknownBinding(name):
            return "Unknown hotkey binding `\(name)`."
        case let .invalidValue(name, value, error):
            return "Hotkey binding `\(name)` has invalid value `\(value)`: \(error)"
        case let .movedSetting(old, new):
            return "`settings.\(old)` moved to `hotkeys.\(new)`. Set `\(new): off` to disable it."
        }
    }
}

/// Reads the optional `hotkeys` block. A missing entry keeps the default key;
/// `off`, `false`, `none` or an empty value leaves the action unbound.
public enum HotKeyBindingsParser {
    private static let disabledValues: Set<String> = [
        "", "~", "null", "nil", "none", "off", "false", "no", "disabled",
    ]

    public static func parse(yaml contents: String) throws -> HotKeyBindings {
        guard let root = try Yams.compose(yaml: contents) else {
            return .default
        }

        try rejectMovedSettings(in: root)

        guard let node = root["hotkeys"] else {
            return .default
        }

        return try parse(node: node)
    }

    static func parse(node: Node) throws -> HotKeyBindings {
        guard let mapping = node.mapping else {
            throw HotKeyBindingsError.invalidBlock("`hotkeys` must be a mapping of bindings.")
        }

        var bindings = HotKeyBindings.default

        for pair in mapping {
            guard let name = pair.key.string else {
                throw HotKeyBindingsError.invalidBlock("Binding names must be strings.")
            }

            switch name {
            case HotKeyBindingName.clipboardMenu:
                bindings.clipboardMenu = try combo(from: pair.value, name: name)

            case HotKeyBindingName.snippetsMenu:
                bindings.snippetsMenu = try combo(from: pair.value, name: name)

            case HotKeyBindingName.commandBox:
                bindings.commandBox = try combo(from: pair.value, name: name)

            case HotKeyBindingName.windowSwitcher:
                try applyWindowSwitcher(pair.value, to: &bindings)

            case HotKeyBindingName.windowMovement:
                try applyWindowMovement(pair.value, to: &bindings)

            default:
                throw HotKeyBindingsError.unknownBinding(name)
            }
        }

        return bindings
    }

    private static func applyWindowSwitcher(_ node: Node, to bindings: inout HotKeyBindings) throws {
        if let group = node.mapping {
            for pair in group {
                guard let key = pair.key.string else {
                    throw HotKeyBindingsError.invalidBlock("Binding names must be strings.")
                }

                let name = "\(HotKeyBindingName.windowSwitcher).\(key)"

                switch key {
                case "all-windows":
                    bindings.switcherAllWindows = try switcherCombo(from: pair.value, name: name)
                case "current-app":
                    bindings.switcherCurrentApp = try switcherCombo(from: pair.value, name: name)
                default:
                    throw HotKeyBindingsError.unknownBinding(name)
                }
            }

            return
        }

        guard isDisabled(node) else {
            throw HotKeyBindingsError.invalidBlock(
                "`\(HotKeyBindingName.windowSwitcher)` takes its own keys or `off`."
            )
        }

        bindings.switcherAllWindows = nil
        bindings.switcherCurrentApp = nil
    }

    private static func applyWindowMovement(_ node: Node, to bindings: inout HotKeyBindings) throws {
        if let group = node.mapping {
            for pair in group {
                guard let key = pair.key.string else {
                    throw HotKeyBindingsError.invalidBlock("Binding names must be strings.")
                }

                let name = "\(HotKeyBindingName.windowMovement).\(key)"

                switch key {
                case "left-half":
                    bindings.moveWindowLeftHalf = try combo(from: pair.value, name: name)
                case "right-half":
                    bindings.moveWindowRightHalf = try combo(from: pair.value, name: name)
                case "maximize":
                    bindings.maximizeWindow = try combo(from: pair.value, name: name)
                case "left-monitor":
                    bindings.moveWindowToLeftMonitor = try combo(from: pair.value, name: name)
                case "right-monitor":
                    bindings.moveWindowToRightMonitor = try combo(from: pair.value, name: name)
                default:
                    throw HotKeyBindingsError.unknownBinding(name)
                }
            }

            return
        }

        guard isDisabled(node) else {
            throw HotKeyBindingsError.invalidBlock(
                "`\(HotKeyBindingName.windowMovement)` takes its own keys or `off`."
            )
        }

        bindings.moveWindowLeftHalf = nil
        bindings.moveWindowRightHalf = nil
        bindings.maximizeWindow = nil
        bindings.moveWindowToLeftMonitor = nil
        bindings.moveWindowToRightMonitor = nil
    }

    /// The switcher cycles while its modifiers stay down, so a bare key cannot drive it.
    private static func switcherCombo(from node: Node, name: String) throws -> KeyCombo? {
        guard let combo = try combo(from: node, name: name) else {
            return nil
        }

        guard combo.hasModifiers else {
            throw HotKeyBindingsError.invalidBlock(
                "Binding `\(name)` needs a modifier, because the switcher cycles while the key is held."
            )
        }

        return combo
    }

    private static func combo(from node: Node, name: String) throws -> KeyCombo? {
        if isDisabled(node) {
            return nil
        }

        guard let rawValue = node.string else {
            throw HotKeyBindingsError.invalidBlock("Binding `\(name)` must be a hotkey or `off`.")
        }

        do {
            return try KeyCombo.parse(rawValue)
        } catch {
            throw HotKeyBindingsError.invalidValue(name: name, value: rawValue, error: error)
        }
    }

    private static func isDisabled(_ node: Node) -> Bool {
        guard let scalar = node.scalar else {
            return false
        }

        return disabledValues.contains(scalar.string.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The `settings` booleans this block replaces. Failing loudly beats
    /// silently ignoring a key that used to turn a feature off.
    private static func rejectMovedSettings(in root: Node) throws {
        guard let settings = root["settings"]?.mapping else {
            return
        }

        let replacements = [
            "command-palette": HotKeyBindingName.commandBox,
            "window-movement": HotKeyBindingName.windowMovement,
            "window-switcher": HotKeyBindingName.windowSwitcher,
        ]

        for pair in settings {
            guard let name = pair.key.string, let replacement = replacements[name] else {
                continue
            }

            throw HotKeyBindingsError.movedSetting(old: name, new: replacement)
        }
    }
}
