import Foundation

public enum ShortyPermissionPane: Hashable, Sendable {
    case accessibility
}

public final class ShortyController {
    public typealias StatusHandler = (String) -> Void

    public let options: LaunchOptions
    public var statusHandler: StatusHandler?
    public var clipboardMenuHandler: ((ClipboardMenuKind) -> Void)?
    public var textCommandHandler: (() -> Void)?
    public var windowSwitcherHandler: ((WindowSwitcherUpdate) -> Void)?
    public var permissionRequestHandler: ((ShortyPermissionPane) -> Void)?
    public private(set) var loadedShortcuts: [LoadedShortcut] = []
    public private(set) var loadedSnippetGroups: [SnippetGroup] = []
    public private(set) var loadedBindings: HotKeyBindings = .default

    private let console: Console
    private let hotKeyCenter: HotKeyCenter
    private let windowActivator: WindowActivator
    private let windowMover: WindowMover
    private let clipboardHistoryStore: ClipboardHistoryStore
    private let clipboardMonitor: ClipboardMonitor
    private let clipboardPaster: ClipboardPaster
    private let windowSwitchingIndex: WindowSwitchingIndex
    private lazy var windowSwitcherEventTap = WindowSwitcherEventTap { [weak self] event in
        self?.handleWindowSwitcherEvent(event)
    }
    private var configWatcher: ConfigWatcher?
    private var activeWindowSwitcherMode: WindowSwitcherMode?
    private var activeWindowSwitcherWindows: [SwitchableWindow] = []
    private var activeWindowSwitcherSelection: WindowSwitcherSessionState?
    private var requestedPermissionPanes: Set<ShortyPermissionPane> = []
    private var didCompleteStart = false

    public init(
        options: LaunchOptions,
        console: Console = Console(),
        clipboardHistoryStore: ClipboardHistoryStore = ClipboardHistoryStore()
    ) throws {
        self.options = options
        self.console = console
        self.windowActivator = WindowActivator(console: console)
        self.windowMover = WindowMover(console: console)
        self.clipboardHistoryStore = clipboardHistoryStore
        let clipboardMonitor = ClipboardMonitor(store: clipboardHistoryStore)
        self.clipboardMonitor = clipboardMonitor
        self.clipboardPaster = ClipboardPaster(monitor: clipboardMonitor)
        self.windowSwitchingIndex = WindowSwitchingIndex()
        self.hotKeyCenter = try HotKeyCenter { [windowActivator] shortcut in
            let result = windowActivator.activate(shortcut)
            if !result.succeeded {
                console.error(result.message)
            }
        }
    }

    public func start() {
        console.info("Starting Shorty with config \(options.configURL.path).")

        if !WindowActivator.requestAccessibilityIfNeeded() {
            publishStatus("Accessibility permission required")
            requestPermissionPane(.accessibility)
        }

        reloadConfig(reason: "startup")
        startClipboardCapture()
        startWindowSwitching()
        registerBuiltInHotKeys()
        didCompleteStart = true
        startWatchingConfig()
    }

    public func stop() {
        configWatcher?.stop()
        clipboardMonitor.stop()
        windowSwitchingIndex.stop()
        windowSwitcherEventTap.stop()
        hotKeyCenter.unregisterAll()
    }

    public func reloadConfig(reason: String) {
        do {
            let configuration = try ConfigurationLoader.load(from: options.configURL)
            try hotKeyCenter.replace(with: configuration.shortcuts)
            windowActivator.resetCache()
            windowSwitchingIndex.replaceShortcuts(configuration.shortcuts)
            loadedShortcuts = configuration.shortcuts
            loadedSnippetGroups = configuration.snippetGroups

            let previousBindings = loadedBindings
            loadedBindings = configuration.bindings
            if didCompleteStart, loadedBindings != previousBindings {
                applyBindings(changedFrom: previousBindings)
            }

            let snippetCount = configuration.snippetGroups.reduce(0) { $0 + $1.snippets.count }
            let message = "Loaded \(configuration.shortcuts.count) shortcut(s) and \(snippetCount) snippet(s) from \(options.configURL.path)."
            console.info("\(message) Reason: \(reason).")
            publishStatus(message)
        } catch {
            let snippetCount = loadedSnippetGroups.reduce(0) { $0 + $1.snippets.count }
            let fallback = loadedShortcuts.isEmpty && snippetCount == 0
                ? "No shortcuts or snippets active."
                : "Keeping \(loadedShortcuts.count) previous shortcut(s) and \(snippetCount) previous snippet(s)."
            let message = "Config reload failed: \(error). \(fallback)"
            console.error(message)
            publishStatus(message)
        }
    }

    public func shortcutSummaries() -> [String] {
        loadedShortcuts.map { shortcut in
            "\(shortcut.hotKey.normalizedValue) -> \(shortcut.id)"
        }
    }

    public func currentWindows() -> [WindowDescriptor] {
        windowActivator.listWindows()
    }

    public func recentClipboardItems() -> [ClipboardItem] {
        clipboardHistoryStore.recentItems()
    }

    public func currentSnippetGroups() -> [SnippetGroup] {
        loadedSnippetGroups
    }

    public func pasteClipboardItem(_ item: ClipboardItem) {
        console.info("Pasting clipboard history item with rich representations.")
        clipboardHistoryStore.add(item)
        clipboardPaster.paste(item)
    }

    public func pasteClipboardItemAsPlainText(_ item: ClipboardItem) {
        console.info("Pasting clipboard history item as plain text.")
        clipboardHistoryStore.add(item)
        clipboardPaster.pasteText(item.plainText)
    }

    public func pasteClipboardItemByJoiningTrimmedNonEmptyLines(_ item: ClipboardItem) {
        console.info("Pasting clipboard history item with trimmed lines joined.")
        let text = clipboardHistoryStore.addJoinedTrimmedNonEmptyLines(from: item)
        clipboardPaster.pasteText(text)
    }

    public func pasteSnippet(_ snippet: Snippet) {
        clipboardHistoryStore.addPlainText(snippet.content)
        clipboardPaster.pasteText(snippet.content)
    }

    private func registerBuiltInHotKeys() {
        var actions: [HotKeyAction] = []

        func append(_ hotKey: KeyCombo?, handler: @escaping () -> Void) {
            guard let hotKey else {
                return
            }

            actions.append(HotKeyAction(hotKey: hotKey, handler: handler))
        }

        append(loadedBindings.clipboardMenu) { [weak self] in
            self?.console.info("Hotkey for clipboard menu triggered.")
            self?.clipboardMenuHandler?(.combined)
        }

        append(loadedBindings.snippetsMenu) { [weak self] in
            self?.console.info("Hotkey for snippets menu triggered.")
            self?.clipboardMenuHandler?(.snippets)
        }

        append(loadedBindings.commandBox) { [weak self] in
            self?.console.info("Hotkey for command box triggered.")
            self?.textCommandHandler?()
        }

        let moveBindings: [(KeyCombo?, WindowMoveCommand)] = [
            (loadedBindings.moveWindowLeftHalf, .cycleHalf(.left)),
            (loadedBindings.moveWindowRightHalf, .cycleHalf(.right)),
            (loadedBindings.maximizeWindow, .maximize),
            (loadedBindings.moveWindowToLeftMonitor, .moveToMonitor(.left)),
            (loadedBindings.moveWindowToRightMonitor, .moveToMonitor(.right)),
        ]

        for (hotKey, command) in moveBindings {
            guard let hotKey else {
                continue
            }

            append(hotKey) { [weak self] in
                self?.moveFocusedWindow(command, hotKey: hotKey.normalizedValue)
            }
        }

        do {
            try hotKeyCenter.replaceActions(with: actions)
            console.info("Registered built-in hotkeys: \(Self.bindingSummary(for: loadedBindings)).")
        } catch {
            let message = "Built-in hotkey registration failed: \(error)"
            console.error(message)
            publishStatus(message)
        }
    }

    private func startClipboardCapture() {
        guard loadedBindings.clipboardCaptureEnabled else {
            console.info("No clipboard hotkey bound. Clipboard history stays off.")
            return
        }

        clipboardMonitor.start()
    }

    private func startWindowSwitching() {
        guard loadedBindings.windowSwitcherEnabled else {
            console.info("No window switcher hotkey bound. Its keys stay with macOS.")
            return
        }

        windowSwitchingIndex.start()
        startWindowSwitcherEventTap()
    }

    private func stopWindowSwitching() {
        cancelWindowSwitcher()
        windowSwitcherEventTap.stop()
        windowSwitchingIndex.stop()
    }

    private func applyBindings(changedFrom previous: HotKeyBindings) {
        registerBuiltInHotKeys()

        if previous.clipboardCaptureEnabled != loadedBindings.clipboardCaptureEnabled {
            if loadedBindings.clipboardCaptureEnabled {
                startClipboardCapture()
            } else {
                clipboardMonitor.stop()
                console.info("No clipboard hotkey bound. Clipboard history stays off.")
            }
        }

        if loadedBindings.windowSwitcherEnabled {
            startWindowSwitching()
        } else if previous.windowSwitcherEnabled {
            stopWindowSwitching()
            console.info("No window switcher hotkey bound. Its keys stay with macOS.")
        }
    }

    private func startWindowSwitcherEventTap() {
        windowSwitcherEventTap.allWindowsHotKey = loadedBindings.switcherAllWindows
        windowSwitcherEventTap.currentApplicationHotKey = loadedBindings.switcherCurrentApp

        guard windowSwitcherEventTap.start() else {
            let message = "Window switcher unavailable. Allow Accessibility for Shorty, then restart."
            console.error(message)
            publishStatus(message)
            requestPermissionPane(.accessibility)
            return
        }

        console.info("Window switcher event tap installed.")
    }

    private func handleWindowSwitcherEvent(_ event: WindowSwitcherEvent) {
        switch event {
        case .advanceAllWindows:
            advanceWindowSwitcher(mode: .allWindows, direction: .forward)
        case .advanceCurrentApplication:
            advanceWindowSwitcher(mode: .currentApplication, direction: .forward)
        case .reverseActiveWindowSwitcher:
            advanceWindowSwitcher(mode: activeWindowSwitcherMode ?? .allWindows, direction: .reverse)
        case .reverseCurrentApplication:
            advanceWindowSwitcher(mode: .currentApplication, direction: .reverse)
        case .commandReleased:
            commitWindowSwitcher()
        case .cancel:
            cancelWindowSwitcher()
        }
    }

    private func moveFocusedWindow(_ command: WindowMoveCommand, hotKey: String) {
        console.info("Hotkey `\(hotKey)` triggered window move action.")
        let result = windowMover.moveFocusedWindow(command)
        publishStatus(result.message)
    }

    private func advanceWindowSwitcher(mode: WindowSwitcherMode, direction: WindowSwitcherDirection) {
        if activeWindowSwitcherMode != mode || activeWindowSwitcherSelection == nil {
            startWindowSwitcher(mode: mode, initialDirection: direction)
            return
        }

        activeWindowSwitcherSelection?.advance(direction)
        publishWindowSwitcherUpdate(.update)
    }

    private func startWindowSwitcher(mode: WindowSwitcherMode, initialDirection: WindowSwitcherDirection) {
        let windows: [SwitchableWindow]

        switch mode {
        case .allWindows:
            windows = windowSwitchingIndex.allWindowsInMRUOrder()
        case .currentApplication:
            windows = windowSwitchingIndex.windowsForFrontmostApplicationInMRUOrder()
        }

        guard !windows.isEmpty else {
            cancelWindowSwitcher()
            return
        }

        activeWindowSwitcherMode = mode
        activeWindowSwitcherWindows = windows
        activeWindowSwitcherSelection = WindowSwitcherSessionState(
            candidateCount: windows.count,
            initialDirection: initialDirection
        )
        publishWindowSwitcherUpdate(.show)
    }

    private func commitWindowSwitcher() {
        defer {
            resetWindowSwitcher()
            windowSwitcherHandler?(.hide)
        }

        guard let selectedWindow = currentWindowSwitcherSnapshot()?.selectedWindow else {
            return
        }

        windowSwitchingIndex.markFocused(selectedWindow)
        let result = windowActivator.activate(selectedWindow)
        if !result.succeeded {
            console.error(result.message)
        }
    }

    private func cancelWindowSwitcher() {
        resetWindowSwitcher()
        windowSwitcherHandler?(.hide)
    }

    private enum WindowSwitcherPublishKind {
        case show
        case update
    }

    private func publishWindowSwitcherUpdate(_ kind: WindowSwitcherPublishKind) {
        guard let snapshot = currentWindowSwitcherSnapshot() else {
            return
        }

        switch kind {
        case .show:
            windowSwitcherHandler?(.show(snapshot))
        case .update:
            windowSwitcherHandler?(.update(snapshot))
        }
    }

    private func currentWindowSwitcherSnapshot() -> WindowSwitcherSnapshot? {
        guard let mode = activeWindowSwitcherMode, let selection = activeWindowSwitcherSelection else {
            return nil
        }

        return WindowSwitcherSnapshot(
            windows: activeWindowSwitcherWindows,
            selectedIndex: selection.selectedIndex,
            mode: mode
        )
    }

    private func resetWindowSwitcher() {
        activeWindowSwitcherMode = nil
        activeWindowSwitcherWindows = []
        activeWindowSwitcherSelection = nil
    }

    private func startWatchingConfig() {
        configWatcher?.stop()
        configWatcher = ConfigWatcher(url: options.configURL) { [weak self] in
            self?.reloadConfig(reason: "config file changed")
        }
        configWatcher?.start()
    }

    private func publishStatus(_ message: String) {
        statusHandler?(message)
    }

    private func requestPermissionPane(_ pane: ShortyPermissionPane) {
        guard requestedPermissionPanes.insert(pane).inserted else {
            return
        }

        permissionRequestHandler?(pane)
    }

    private static func bindingSummary(for bindings: HotKeyBindings) -> String {
        let bound = bindings.boundActions
        guard !bound.isEmpty else {
            return "none"
        }

        return bound
            .map { "\($0.hotKey.normalizedValue) (\($0.name))" }
            .joined(separator: ", ")
    }
}
