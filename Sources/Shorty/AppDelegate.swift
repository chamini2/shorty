import AppKit
import Carbon
import ServiceManagement
import ShortyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller: ShortyController

    private var statusItem: NSStatusItem?
    private var windowsWindow: NSWindow?
    private weak var windowsTextView: NSTextView?
    private let menu = NSMenu()
    private let issueMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let stateMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let pathMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let shortcutsHeaderItem = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
    private let emptyShortcutsItem = NSMenuItem(title: "No shortcuts loaded", action: nil, keyEquivalent: "")
    private let keepAwakeItem = NSMenuItem(title: "Caffeinate", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private var dynamicShortcutItems: [NSMenuItem] = []
    let box = ShortyBoxController()
    private lazy var clipboardPickerPanel = ClipboardPickerPanelController(box: box)
    private lazy var scratchPadPanel: ScratchPadPanelController = {
        let panel = ScratchPadPanelController(box: box)
        panel.copyHandler = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        return panel
    }()
    private let applicationIndex = ApplicationIndex()
    private let recentFiles = RecentFileStore()
    private let recentApps = RecentAppStore()
    private lazy var commandPalettePanel = CommandPalettePanelController(box: box)
    private let windowSwitcherPanel = WindowSwitcherPanelController()

    init(controller: ShortyController) {
        self.controller = controller
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        controller.statusHandler = { [weak self] message in
            DispatchQueue.main.async {
                self?.updateStatus(message)
                self?.updateConfigIssue()
                self?.reloadShortcutItems()
            }
        }
        controller.clipboardMenuHandler = { [weak self] kind in
            DispatchQueue.main.async {
                self?.handleClipboardMenuHotKey(kind)
            }
        }
        controller.textCommandHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.showCommandPalette()
            }
        }
        controller.scratchPadHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.showScratchPad()
            }
        }
        // A copied link is read the moment it lands, so its card is waiting
        // by the time the picker is opened at all.
        controller.clipboardCaptureHandler = { [weak self] item in
            DispatchQueue.main.async {
                self?.prefetchLinkPreview(for: item)
            }
        }
        commandPalettePanel.pickerRequestHandler = { [weak self] kind, palette in
            self?.showCommandInsertionPicker(kind, for: palette)
        }
        controller.commandBoxSettingsHandler = { [weak self] settings in
            DispatchQueue.main.async {
                self?.commandPalettePanel.settings = settings
            }
        }
        commandPalettePanel.viewPresenter = { [weak self] kind in
            guard let self else {
                return false
            }

            switch kind {
            case let .clipboard(menuKind):
                box.push(clipboardPickerPanel) {
                    self.prepareClipboardPicker(menuKind)
                }
                return true

            case .scratchPad:
                box.push(scratchPadPanel)
                return true
            }
        }
        commandPalettePanel.actionHandler = { [weak self] action in
            DispatchQueue.main.async {
                self?.performCommandAction(action)
            }
        }
        controller.windowSwitcherHandler = { [weak self] update in
            DispatchQueue.main.async {
                self?.handleWindowSwitcherUpdate(update)
            }
        }
        controller.permissionRequestHandler = { [weak self] pane in
            DispatchQueue.main.async {
                self?.openPermissionSettings(pane)
            }
        }

        controller.start()
        reloadShortcutItems()
    }

    func applicationWillTerminate(_ notification: Notification) {
        box.closeAll()
        controller.stop()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.toolTip = "Shorty"
            button.imagePosition = .imageOnly
        }

        updateStatusIcon()

        issueMenuItem.action = #selector(revealConfig)
        issueMenuItem.target = self
        issueMenuItem.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Config error"
        )?.withSymbolConfiguration(.init(paletteColors: [.systemYellow]))
        issueMenuItem.isHidden = true

        stateMenuItem.isEnabled = false
        pathMenuItem.isEnabled = false
        pathMenuItem.title = Self.menuLine(controller.options.configURL.path)
        pathMenuItem.toolTip = controller.options.configURL.path
        shortcutsHeaderItem.isEnabled = false
        emptyShortcutsItem.isEnabled = false

        menu.addItem(issueMenuItem)
        menu.addItem(stateMenuItem)
        menu.addItem(pathMenuItem)
        menu.addItem(.separator())
        menu.addItem(shortcutsHeaderItem)
        menu.addItem(emptyShortcutsItem)
        menu.addItem(.separator())

        keepAwakeItem.action = #selector(toggleKeepAwake)
        keepAwakeItem.target = self
        menu.addItem(keepAwakeItem)
        menu.addItem(.separator())

        let windowsItem = NSMenuItem(
            title: "Show Windows",
            action: #selector(showWindows),
            keyEquivalent: "w"
        )
        windowsItem.target = self
        menu.addItem(windowsItem)
        menu.addItem(.separator())

        let reloadItem = NSMenuItem(
            title: "Reload Config",
            action: #selector(reloadConfig),
            keyEquivalent: "r"
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        let revealItem = NSMenuItem(
            title: "Reveal Config",
            action: #selector(revealConfig),
            keyEquivalent: ""
        )
        revealItem.target = self
        menu.addItem(revealItem)

        menu.addItem(.separator())

        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        updateLaunchAtLoginItem()

        let accessibilityItem = NSMenuItem(
            title: "Open Accessibility Settings",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatus(_ message: String) {
        // The full text goes in the tooltip: a status line long enough to
        // mention a path stretches the whole menu to match.
        stateMenuItem.title = Self.menuLine(message)
        stateMenuItem.toolTip = message
        statusItem?.button?.toolTip = message
    }

    /// Shows why the config failed to load, both as a badge on the menu bar
    /// cup and as a line at the top of the menu that opens the config.
    private func updateConfigIssue() {
        let issue = controller.configIssue
        issueMenuItem.isHidden = issue == nil

        if let issue {
            let line = "Config error: \(issue)"
            issueMenuItem.title = Self.menuLine(line)
            issueMenuItem.toolTip = "\(line)\nClick to reveal the config."
            statusItem?.button?.toolTip = line
        }

        updateStatusIcon()
    }

    /// Keeps a menu line short enough that it does not set the menu's width,
    /// shortening the home folder and dropping the middle of what is left,
    /// where the ends carry the meaning.
    static func menuLine(_ text: String, limit: Int = 44) -> String {
        let shortened = (text as NSString).abbreviatingWithTildeInPath

        guard shortened.count > limit else {
            return shortened
        }

        let ellipsis = "…"
        let keep = limit - ellipsis.count
        let leading = shortened.prefix(keep - keep / 2)
        let trailing = shortened.suffix(keep / 2)

        return "\(leading)\(ellipsis)\(trailing)"
    }

    private func reloadShortcutItems() {
        for item in dynamicShortcutItems {
            menu.removeItem(item)
        }

        dynamicShortcutItems.removeAll()

        let summaries = controller.shortcutSummaries()

        if summaries.isEmpty {
            emptyShortcutsItem.isHidden = false
            return
        }

        emptyShortcutsItem.isHidden = true

        guard let insertionIndex = menu.items.firstIndex(of: emptyShortcutsItem) else {
            return
        }

        for (offset, summary) in summaries.enumerated() {
            let item = NSMenuItem(title: Self.menuLine(summary), action: nil, keyEquivalent: "")
            item.toolTip = summary
            item.isEnabled = false
            dynamicShortcutItems.append(item)
            menu.insertItem(item, at: insertionIndex + offset)
        }
    }

    @objc
    private func reloadConfig() {
        controller.reloadConfig(reason: "manual reload")
    }

    @objc
    private func revealConfig() {
        let configURL = controller.options.configURL
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: configURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([configURL])
        } else {
            let directoryURL = configURL.deletingLastPathComponent()
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directoryURL)
        }
    }

    @objc
    private func openAccessibilitySettings() {
        openPermissionSettings(.accessibility)
    }

    private func openPermissionSettings(_ pane: ShortyPermissionPane) {
        let urlString: String
        switch pane {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }

        guard let url = URL(string: urlString) else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func performCommandAction(_ action: CommandAction) {
        controller.noteCommandBoxAction(String(describing: action))

        switch action {
        case let .copyText(text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

        case let .moveWindow(command):
            controller.performWindowMove(command)

        case let .openFile(path):
            recentFiles.record(path)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))

        case let .revealFile(path):
            recentFiles.record(path)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])

        case let .copyFilePath(path):
            recentFiles.record(path)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(path, forType: .string)

        case let .openApplication(path):
            recentApps.record(path)
            // Through `NSWorkspace`, so an app already running is brought
            // forward instead of started a second time.
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path),
                configuration: NSWorkspace.OpenConfiguration()
            )

        case let .setKeepAwake(active):
            controller.setKeepAwake(active)
            updateStatusIcon()

        }
    }

    @objc
    private func toggleKeepAwake() {
        controller.setKeepAwake(!controller.isKeepAwakeActive)
        updateStatusIcon()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginItem()
    }

    private func updateLaunchAtLoginItem() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            launchAtLoginItem.isEnabled = false
            launchAtLoginItem.state = .off
            launchAtLoginItem.toolTip = "Available when running as Shorty.app"
            return
        }

        let status = SMAppService.mainApp.status
        launchAtLoginItem.isEnabled = true
        launchAtLoginItem.state = status == .enabled ? .on : .off
        launchAtLoginItem.toolTip = status == .requiresApproval
            ? "Needs approval in System Settings > General > Login Items"
            : nil
    }

    @objc
    private func toggleLaunchAtLogin() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return
        }

        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            Console().error("Launch at Login toggle failed: \(error.localizedDescription)")
            updateStatus("Launch at Login failed: \(error.localizedDescription)")
        }

        updateLaunchAtLoginItem()
    }

    /// Reads a copied link's card straight away. The setting is honoured
    /// here too: with previews off, nothing is fetched at all.
    private func prefetchLinkPreview(for item: ClipboardItem) {
        guard controller.loadedClipboardSettings.linkPreviewsEnabled,
              ClipboardItemDetailBuilder.isLink(item.plainText),
              let url = URL(string: item.plainText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }

        clipboardPickerPanel.prefetchLinkPreviews([url])
    }

    /// The menu bar cup fills while sleep is held off and empties when it is
    /// not, which says the same thing as the tick in the menu below it. A
    /// config that failed to load adds a warning badge on top of either.
    private func updateStatusIcon() {
        let active = controller.isKeepAwakeActive
        keepAwakeItem.state = active ? .on : .off

        guard let button = statusItem?.button else {
            return
        }

        button.image = StatusIcon.cup(filled: active, warning: controller.configIssue != nil)
    }

    private func showCommandPalette() {
        // The command-box hotkey always hides the box when visible, whatever
        // session is showing, preserving any unsubmitted draft.
        if box.isVisible {
            box.suspend()
            return
        }

        if box.resume(session: .commandBox, refresh: { self.refreshResumedStack($0) }) {
            return
        }

        refreshCommandPaletteData(commandPalettePanel)
        commandPalettePanel.show()
    }

    /// Puts `text` on the pad and shows it over whatever asked.
    ///
    /// Added rather than substituted: the pad holds work in progress, and an
    /// entry sent to it should not take the place of what is already there.
    /// Pushed, not opened, so escape goes back to the picker.
    private func sendToScratchPad(_ text: String) {
        box.push(scratchPadPanel) {
            self.scratchPadPanel.append(text)
        }
    }

    /// One key for the pad, wherever it is pressed.
    ///
    /// With the standalone picker open and an entry under the cursor, that
    /// entry is sent to the pad; when the pad is already on top, the hotkey
    /// suspends it; from anywhere else, resume or open the pad in-place.
    private func showScratchPad() {
        if case .clipboard(_, purpose: .paste) = box.topRoute,
           let text = clipboardPickerPanel.selectedTextForScratchPad {
            sendToScratchPad(text)
            return
        }

        if box.isVisible && box.topRoute == .scratchPad {
            box.suspend()
            return
        }

        if box.resume(session: .scratchPad, refresh: { self.refreshResumedStack($0) }) {
            return
        }

        box.open(session: .scratchPad, content: scratchPadPanel)
    }

    private func handleClipboardMenuHotKey(_ kind: ClipboardMenuKind) {
        if let palette = box.topContent as? CommandPalettePanelController {
            palette.requestNestedPicker(kind)
            return
        }

        if case let .clipboard(activeKind, purpose: .insert) = box.topRoute {
            if activeKind == kind {
                box.pop()
            } else {
                clipboardPickerPanel.switchMode(Self.pickerMode(for: kind))
            }
            return
        }

        let session: ShortyBoxSession = kind == .snippets ? .snippets : .clipboard
        if box.isVisible && box.activeSession == session {
            box.suspend()
            return
        }

        if box.resume(session: session, refresh: { self.refreshResumedStack($0) }) {
            return
        }

        showClipboardPicker(kind)
    }

    private func showCommandInsertionPicker(
        _ kind: ClipboardMenuKind,
        for palette: CommandPalettePanelController
    ) {
        box.push(clipboardPickerPanel) {
            self.clipboardPickerPanel.showsLinkPreviews = self.controller.loadedClipboardSettings.linkPreviewsEnabled
            self.clipboardPickerPanel.show(
                mode: Self.pickerMode(for: kind),
                history: self.controller.recentClipboardItems(),
                snippetGroups: self.controller.currentSnippetGroups(),
                closesBoxOnSelect: false,
                onSelect: { [weak palette] result, _ in
                    palette?.insertTextFromPicker(Self.text(for: result))
                },
                onCancel: { [weak palette] in
                    palette?.cancelNestedPicker()
                },
                onTogglePin: { [weak self] item in
                    guard let self else {
                        return []
                    }
                    self.controller.setClipboardItemPinned(!item.isPinned, item: item)
                    return self.controller.recentClipboardItems()
                }
            )
        }
    }

    private func refreshResumedStack(_ stack: [ShortyBoxContent]) {
        for content in stack {
            if let palette = content as? CommandPalettePanelController {
                refreshCommandPaletteData(palette)
            } else if let picker = content as? ClipboardPickerPanelController {
                picker.refresh(
                    history: controller.recentClipboardItems(),
                    snippetGroups: controller.currentSnippetGroups(),
                    showsLinkPreviews: controller.loadedClipboardSettings.linkPreviewsEnabled
                )
            }
        }
    }

    private func refreshCommandPaletteData(_ palette: CommandPalettePanelController) {
        palette.settings = controller.loadedCommandBox
        palette.history = controller.recentClipboardItems()
        palette.keepAwake = controller.isKeepAwakeActive
        palette.applications = applicationIndex.current()
        palette.applicationOpens = recentApps.opens()
    }

    private static func pickerMode(for kind: ClipboardMenuKind) -> ClipboardPickerMode {
        switch kind {
        case .combined:
            return .all
        case .snippets:
            return .snippetsOnly
        }
    }

    private static func text(for result: ClipboardPickerResult) -> String {
        switch result {
        case let .history(item):
            return item.plainText
        case let .snippet(_, snippet):
            return snippet.content
        }
    }

    @objc
    private func showWindows() {
        let window = windowsWindow ?? makeWindowsWindow()
        windowsWindow = window

        refreshWindowsWindow()

        if !window.isVisible {
            window.center()
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc
    private func refreshWindowsWindow() {
        windowsTextView?.string = Self.windowListText(controller.currentWindows())
    }

    private func makeWindowsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shorty Windows"
        window.isReleasedWhenClosed = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshWindowsWindow))
        refreshButton.bezelStyle = .rounded
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyWindowsText))
        copyButton.bezelStyle = .rounded
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 860, height: 520))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width, .height]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        windowsTextView = textView

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(refreshButton)
        contentView.addSubview(copyButton)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            refreshButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            refreshButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            copyButton.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: refreshButton.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])

        return window
    }

    @objc
    private func copyWindowsText() {
        let text = windowsTextView?.string ?? Self.windowListText(controller.currentWindows())
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func showClipboardPicker(_ kind: ClipboardMenuKind) {
        let session: ShortyBoxSession = kind == .snippets ? .snippets : .clipboard
        box.open(session: session, content: clipboardPickerPanel) {
            self.prepareClipboardPicker(kind)
        }
    }

    /// Fills the picker in without showing it, so either the hotkey or the
    /// command box can decide how it appears.
    private func prepareClipboardPicker(_ kind: ClipboardMenuKind) {
        clipboardPickerPanel.showsLinkPreviews = controller.loadedClipboardSettings.linkPreviewsEnabled
        clipboardPickerPanel.show(
            mode: Self.pickerMode(for: kind),
            history: controller.recentClipboardItems(),
            snippetGroups: controller.currentSnippetGroups(),
            onSelect: { [weak self] result, activationMode in
                self?.pastePickerResult(
                    result,
                    activationMode: activationMode
                )
            },
            onDelete: { [weak self] item in
                self?.controller.deleteClipboardItem(item)
            },
            onTogglePin: { [weak self] item in
                guard let self else {
                    return []
                }
                self.controller.setClipboardItemPinned(!item.isPinned, item: item)
                return self.controller.recentClipboardItems()
            }
        )
    }

    private func pastePickerResult(
        _ result: ClipboardPickerResult,
        activationMode: ClipboardPickerActivationMode
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else {
                return
            }

            switch result {
            case let .history(item):
                switch activationMode {
                case .joinedLines:
                    controller.pasteClipboardItemByJoiningTrimmedNonEmptyLines(item)
                case .plainText:
                    controller.pasteClipboardItemAsPlainText(item)
                case .copyOnly:
                    controller.copyClipboardItem(item)
                case .standard:
                    controller.pasteClipboardItem(item)
                }
            case let .snippet(_, snippet):
                if activationMode == .copyOnly {
                    controller.copySnippet(snippet)
                } else {
                    controller.pasteSnippet(snippet)
                }
            }
        }
    }

    private func handleWindowSwitcherUpdate(_ update: WindowSwitcherUpdate) {
        switch update {
        case let .show(snapshot):
            box.suspend()
            windowSwitcherPanel.show(snapshot)
        case let .update(snapshot):
            windowSwitcherPanel.update(snapshot)
        case .hide:
            windowSwitcherPanel.hide()
        }
    }

    private static func truncated(_ value: String, maxLength: Int) -> String {
        let symbol = "..."
        guard maxLength > symbol.count, value.count > maxLength else {
            return value
        }

        let endIndex = value.index(value.startIndex, offsetBy: maxLength - symbol.count)
        return String(value[..<endIndex]) + symbol
    }

    private static func windowListText(_ windows: [WindowDescriptor]) -> String {
        guard !windows.isEmpty else {
            return "No windows found."
        }

        return windows.enumerated().map { index, window in
            windowText(window, number: index + 1)
        }.joined(separator: "\n\n")
    }

    private static func windowText(_ window: WindowDescriptor, number: Int) -> String {
        var lines = [
            "Window \(number)",
            "Bundle ID: \(window.bundleID ?? "<no bundle id>")",
            "Window title: \(window.title.isEmpty ? "<untitled>" : window.title)",
            "App name: \(window.appName)",
            "PID: \(window.pid)",
            "App window index: \(window.appWindowIndex)",
        ]

        if let executablePath = window.executablePath {
            lines.append("Executable path: \(executablePath)")
        }

        if let document = window.document {
            lines.append("Document: \(document)")
        }

        if let url = window.url {
            lines.append("URL: \(url)")
        }

        if let identifier = window.identifier {
            lines.append("Identifier: \(identifier)")
        }

        if let role = window.role {
            lines.append("Role: \(role)")
        }

        if let subrole = window.subrole {
            lines.append("Subrole: \(subrole)")
        }

        if let minimized = window.minimized {
            lines.append("Minimized: \(minimized)")
        }

        if let position = window.position {
            lines.append("Position: x=\(Int(position.x)) y=\(Int(position.y))")
        }

        if let size = window.size {
            lines.append("Size: width=\(Int(size.width)) height=\(Int(size.height))")
        }

        return lines.joined(separator: "\n")
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }
}
