import Foundation

/// Every built-in hotkey, as configured. `nil` means the action has no key and
/// its feature stays off.
public struct HotKeyBindings: Equatable, Sendable {
    public var clipboardMenu: KeyCombo?
    public var snippetsMenu: KeyCombo?
    public var commandBox: KeyCombo?
    public var switcherAllWindows: KeyCombo?
    public var switcherCurrentApp: KeyCombo?
    public var moveWindowLeftHalf: KeyCombo?
    public var moveWindowRightHalf: KeyCombo?
    public var maximizeWindow: KeyCombo?
    public var moveWindowToLeftMonitor: KeyCombo?
    public var moveWindowToRightMonitor: KeyCombo?

    public init(
        clipboardMenu: KeyCombo? = nil,
        snippetsMenu: KeyCombo? = nil,
        commandBox: KeyCombo? = nil,
        switcherAllWindows: KeyCombo? = nil,
        switcherCurrentApp: KeyCombo? = nil,
        moveWindowLeftHalf: KeyCombo? = nil,
        moveWindowRightHalf: KeyCombo? = nil,
        maximizeWindow: KeyCombo? = nil,
        moveWindowToLeftMonitor: KeyCombo? = nil,
        moveWindowToRightMonitor: KeyCombo? = nil
    ) {
        self.clipboardMenu = clipboardMenu
        self.snippetsMenu = snippetsMenu
        self.commandBox = commandBox
        self.switcherAllWindows = switcherAllWindows
        self.switcherCurrentApp = switcherCurrentApp
        self.moveWindowLeftHalf = moveWindowLeftHalf
        self.moveWindowRightHalf = moveWindowRightHalf
        self.maximizeWindow = maximizeWindow
        self.moveWindowToLeftMonitor = moveWindowToLeftMonitor
        self.moveWindowToRightMonitor = moveWindowToRightMonitor
    }

    public static let `default` = HotKeyBindings(
        clipboardMenu: DefaultHotKeys.clipboardMenu,
        snippetsMenu: DefaultHotKeys.snippetsMenu,
        commandBox: DefaultHotKeys.commandBox,
        switcherAllWindows: DefaultHotKeys.switcherAllWindows,
        switcherCurrentApp: DefaultHotKeys.switcherCurrentApp,
        moveWindowLeftHalf: DefaultHotKeys.moveWindowLeftHalf,
        moveWindowRightHalf: DefaultHotKeys.moveWindowRightHalf,
        maximizeWindow: DefaultHotKeys.maximizeWindow,
        moveWindowToLeftMonitor: DefaultHotKeys.moveWindowToLeftMonitor,
        moveWindowToRightMonitor: DefaultHotKeys.moveWindowToRightMonitor
    )

    /// Config name and combo for every bound action, for conflict checks and logs.
    public var boundActions: [(name: String, hotKey: KeyCombo)] {
        var actions: [(name: String, hotKey: KeyCombo)] = []

        func append(_ name: String, _ hotKey: KeyCombo?) {
            guard let hotKey else {
                return
            }

            actions.append((name, hotKey))
        }

        append(HotKeyBindingName.clipboardMenu, clipboardMenu)
        append(HotKeyBindingName.snippetsMenu, snippetsMenu)
        append(HotKeyBindingName.commandBox, commandBox)
        append(HotKeyBindingName.switcherAllWindows, switcherAllWindows)
        append(HotKeyBindingName.switcherCurrentApp, switcherCurrentApp)
        append(HotKeyBindingName.moveWindowLeftHalf, moveWindowLeftHalf)
        append(HotKeyBindingName.moveWindowRightHalf, moveWindowRightHalf)
        append(HotKeyBindingName.maximizeWindow, maximizeWindow)
        append(HotKeyBindingName.moveWindowToLeftMonitor, moveWindowToLeftMonitor)
        append(HotKeyBindingName.moveWindowToRightMonitor, moveWindowToRightMonitor)

        return actions
    }

    /// The switcher keeps a global event tap and a window index running, so it
    /// only starts when at least one of its keys is bound.
    public var windowSwitcherEnabled: Bool {
        switcherAllWindows != nil || switcherCurrentApp != nil
    }

    /// Clipboard history is only reachable through these keys, so nothing is
    /// recorded when none of them is bound.
    public var clipboardCaptureEnabled: Bool {
        clipboardMenu != nil || snippetsMenu != nil || commandBox != nil
    }

    public var windowMovementEnabled: Bool {
        moveWindowLeftHalf != nil ||
            moveWindowRightHalf != nil ||
            maximizeWindow != nil ||
            moveWindowToLeftMonitor != nil ||
            moveWindowToRightMonitor != nil
    }
}

public enum HotKeyBindingName {
    public static let clipboardMenu = "clipboard-menu"
    public static let snippetsMenu = "snippets-menu"
    public static let commandBox = "command-box"
    public static let windowSwitcher = "window-switcher"
    public static let switcherAllWindows = "window-switcher.all-windows"
    public static let switcherCurrentApp = "window-switcher.current-app"
    public static let windowMovement = "window-movement"
    public static let moveWindowLeftHalf = "window-movement.left-half"
    public static let moveWindowRightHalf = "window-movement.right-half"
    public static let maximizeWindow = "window-movement.maximize"
    public static let moveWindowToLeftMonitor = "window-movement.left-monitor"
    public static let moveWindowToRightMonitor = "window-movement.right-monitor"
}

public enum DefaultHotKeys {
    public static let clipboardMenu = try! KeyCombo.parse("cmd+shift+v")
    public static let snippetsMenu = try! KeyCombo.parse("cmd+shift+b")
    public static let commandBox = try! KeyCombo.parse("option+space")
    public static let switcherAllWindows = try! KeyCombo.parse("cmd+tab")
    public static let switcherCurrentApp = try! KeyCombo.parse("cmd+grave")
    public static let moveWindowLeftHalf = try! KeyCombo.parse("ctrl+option+left")
    public static let moveWindowRightHalf = try! KeyCombo.parse("ctrl+option+right")
    public static let maximizeWindow = try! KeyCombo.parse("ctrl+option+cmd+up")
    public static let moveWindowToLeftMonitor = try! KeyCombo.parse("ctrl+option+cmd+left")
    public static let moveWindowToRightMonitor = try! KeyCombo.parse("ctrl+option+cmd+right")
}
