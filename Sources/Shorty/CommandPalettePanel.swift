import AppKit
import Carbon
import ShortyCore

@MainActor
final class CommandPalettePanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private enum Metrics {
        static let panelWidth: CGFloat = 820
        static let panelHeight: CGFloat = 440
        static let topPadding: CGFloat = 9
        static let emptyBottomPadding: CGFloat = 10
        static let resultBottomPadding: CGFloat = 5
        static let horizontalPadding: CGFloat = 10
        static let searchHeight: CGFloat = 30
        static let searchFontSize: CGFloat = 18
        static let resultTopSpacing: CGFloat = 6
        static let rowSpacing: CGFloat = 2
        static let topOffsetRatio: CGFloat = 0.20
        static let bottomMargin: CGFloat = 20
    }

    private let panel: CommandPalettePanelWindow
    private let searchField = CommandPaletteTextField(frame: .zero)
    private let stackView = NSStackView()
    private let scrollView = NSScrollView()
    private let listContainer = CommandPaletteListContainerView()
    private var entries: [CommandEntry] = []
    private var rowHeights: [CGFloat] = []
    private var selectedIndex = 0
    /// Groups entered so far, such as Clipboard History then a snippet group.
    private var groupStack: [CommandEntry] = []
    private var isPresentingNestedPicker = false
    private var pendingInsertionRange: NSRange?
    private var selectionRangeAfterRefocus: NSRange?
    var pickerRequestHandler: ((ClipboardMenuKind) -> Void)?
    var actionHandler: ((CommandAction) -> Void)?
    var settings: CommandBoxSettings = .default
    var history: [ClipboardItem] = []
    var snippetGroups: [SnippetGroup] = []

    override init() {
        panel = CommandPalettePanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        configurePanel()
        configureSearchField()
        configureStackView()
    }

    var isPresented: Bool {
        panel.isVisible
    }

    func show() {
        searchField.stringValue = ""
        selectionRangeAfterRefocus = nil
        groupStack = []
        updateResults()
        resizePanel()
        positionPanel()

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func hide() {
        isPresentingNestedPicker = false
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isPresentingNestedPicker else {
            return
        }

        if panel.isVisible {
            hide()
        }
    }

    func insertTextFromPicker(_ text: String) {
        replaceSelectedText(with: text, fallbackRange: pendingInsertionRange)
        pendingInsertionRange = nil
        refocusAfterNestedPicker()
    }

    func cancelNestedPicker() {
        pendingInsertionRange = nil
        refocusAfterNestedPicker()
    }

    func requestNestedPickerFromHotKey(_ kind: ClipboardMenuKind) -> Bool {
        if isPresentingNestedPicker {
            return true
        }

        guard panel.isVisible else {
            return false
        }

        requestNestedPicker(kind)
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        updateResults()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            activateSelection()
            return true

        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true

        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true

        case #selector(NSResponder.cancelOperation(_:)):
            if !leaveGroupIfNeeded() {
                hide()
            }
            return true

        default:
            return false
        }
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        panel.keyEventHandler = { [weak self] event in
            self?.handlePanelKeyEvent(event) ?? false
        }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        panel.contentView = container

        searchField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        listContainer.translatesAutoresizingMaskIntoConstraints = false

        // The panel no longer grows with its rows, so the list scrolls.
        scrollView.documentView = listContainer
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder
        listContainer.addSubview(stackView)

        container.addSubview(searchField)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.topPadding),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.horizontalPadding),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.horizontalPadding),
            searchField.heightAnchor.constraint(equalToConstant: Metrics.searchHeight),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Metrics.resultTopSpacing),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.horizontalPadding),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.horizontalPadding),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Metrics.resultBottomPadding),

            listContainer.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            stackView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
        ])
    }

    private func configureSearchField() {
        searchField.placeholderString = "Command"
        searchField.delegate = self
        searchField.font = NSFont.systemFont(ofSize: Metrics.searchFontSize)
        searchField.cell?.font = searchField.font
        searchField.textColor = .labelColor
        searchField.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1)
        searchField.drawsBackground = true
        searchField.isBezeled = true
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none
        searchField.keyHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
    }

    private func configureStackView() {
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .gravityAreas
        stackView.spacing = Metrics.rowSpacing
    }

    private func updateResults(resetSelection: Bool = true) {
        let query = searchField.stringValue

        if let currentGroup = groupStack.last {
            entries = CommandCatalog.entries(in: currentGroup, query: query)
        } else {
            entries = CommandCatalog.rootEntries(
                query: query,
                settings: settings,
                history: history,
                snippetGroups: snippetGroups
            )
        }

        if resetSelection || !entries.indices.contains(selectedIndex) {
            selectedIndex = 0
        }

        rowHeights = entries.map {
            CommandPaletteEntryRowView.height(for: $0, width: Metrics.panelWidth - Metrics.horizontalPadding * 2)
        }

        renderRows()
        resizePanel()
        positionPanel()
    }

    private func renderRows() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, pair) in zip(entries, rowHeights).enumerated() {
            let row = CommandPaletteEntryRowView(entry: pair.0, isSelected: index == selectedIndex)
            row.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: stackView.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: pair.1),
            ])
        }
    }

    private func moveSelection(by offset: Int) {
        guard !entries.isEmpty else {
            return
        }

        let count = entries.count
        selectedIndex = ((selectedIndex + offset) % count + count) % count
        renderRows()
        panel.contentView?.layoutSubtreeIfNeeded()
        scrollSelectionIntoView()
    }

    /// Runs the selected entry, or opens it when it is a group.
    private func activateSelection() {
        guard entries.indices.contains(selectedIndex) else {
            NSSound.beep()
            return
        }

        let entry = entries[selectedIndex]

        if entry.isGroup {
            enterGroup(entry)
            return
        }

        guard let action = entry.action else {
            NSSound.beep()
            return
        }

        hide()
        actionHandler?(action)
    }

    private func enterGroup(_ group: CommandEntry) {
        groupStack.append(group)
        searchField.stringValue = ""
        updateResults()
    }

    @discardableResult
    private func leaveGroupIfNeeded() -> Bool {
        guard !groupStack.isEmpty else {
            return false
        }

        groupStack.removeLast()
        searchField.stringValue = ""
        updateResults()
        return true
    }

    private func resizePanel() {
        panel.setContentSize(NSSize(width: Metrics.panelWidth, height: Metrics.panelHeight))
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    /// Keeps the selected row on screen once the list is taller than the panel.
    private func scrollSelectionIntoView() {
        guard entries.indices.contains(selectedIndex) else {
            return
        }

        let rowTop = rowHeights.prefix(selectedIndex).reduce(CGFloat(0), +)
            + CGFloat(selectedIndex) * Metrics.rowSpacing
        let rowBottom = rowTop + rowHeights[selectedIndex]
        let viewport = scrollView.contentView.bounds
        var offset = viewport.origin.y

        if rowTop < offset {
            offset = rowTop
        } else if rowBottom > offset + viewport.height {
            offset = rowBottom - viewport.height
        }

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, offset)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let frame = panel.frame
        let topY = visibleFrame.maxY - visibleFrame.height * Metrics.topOffsetRatio

        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: max(visibleFrame.minY + Metrics.bottomMargin, topY - frame.height)
            )
        )
    }



    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if handleCommandKey(event) {
            return true
        }

        switch UInt32(event.keyCode) {
        case UInt32(kVK_Escape):
            if !leaveGroupIfNeeded() {
                hide()
            }
            return true

        case UInt32(kVK_Return), UInt32(kVK_ANSI_KeypadEnter):
            activateSelection()
            return true

        case UInt32(kVK_UpArrow):
            moveSelection(by: -1)
            return true

        case UInt32(kVK_DownArrow):
            moveSelection(by: 1)
            return true

        case UInt32(kVK_RightArrow):
            guard entries.indices.contains(selectedIndex), entries[selectedIndex].isGroup else {
                return false
            }

            enterGroup(entries[selectedIndex])
            return true

        case UInt32(kVK_LeftArrow):
            return leaveGroupIfNeeded()

        default:
            return false
        }
    }

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else {
            return false
        }

        switch UInt32(event.keyCode) {
        case UInt32(kVK_ANSI_A):
            searchField.selectText(nil)
            return true

        case UInt32(kVK_ANSI_C):
            copySelection()
            return true

        case UInt32(kVK_ANSI_V):
            if flags.contains(.shift) {
                requestNestedPicker(.combined)
            } else {
                pasteFromSystemClipboard()
            }
            return true

        case UInt32(kVK_ANSI_B):
            requestNestedPicker(.snippets)
            return true

        default:
            return false
        }
    }

    private func pasteFromSystemClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }

        replaceSelectedText(with: text, fallbackRange: nil)
    }

    private func copySelection() {
        let range = selectedRange()
        let currentValue = searchField.stringValue as NSString
        guard range.length > 0, NSMaxRange(range) <= currentValue.length else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentValue.substring(with: range), forType: .string)
    }

    private func requestNestedPicker(_ kind: ClipboardMenuKind) {
        guard let pickerRequestHandler else {
            return
        }

        pendingInsertionRange = selectedRange()
        isPresentingNestedPicker = true
        panel.orderOut(nil)
        pickerRequestHandler(kind)
    }

    private func replaceSelectedText(with text: String, fallbackRange: NSRange?) {
        let currentValue = searchField.stringValue as NSString
        let range = validRange(fallbackRange ?? selectedRange(), in: currentValue)
        let replacement = currentValue.replacingCharacters(in: range, with: text)
        let cursorLocation = range.location + (text as NSString).length

        searchField.stringValue = replacement
        updateResults()
        let newSelectionRange = NSRange(location: cursorLocation, length: 0)
        if searchField.currentEditor() == nil {
            selectionRangeAfterRefocus = newSelectionRange
        }
        setSelectedRange(newSelectionRange)
    }

    private func selectedRange() -> NSRange {
        if let editor = searchField.currentEditor() {
            return editor.selectedRange
        }

        return NSRange(location: (searchField.stringValue as NSString).length, length: 0)
    }

    private func setSelectedRange(_ range: NSRange) {
        searchField.currentEditor()?.selectedRange = range
    }

    private func validRange(_ range: NSRange, in value: NSString) -> NSRange {
        guard range.location >= 0, range.location <= value.length else {
            return NSRange(location: value.length, length: 0)
        }

        let maxLength = value.length - range.location
        return NSRange(location: range.location, length: min(range.length, maxLength))
    }

    private func refocusAfterNestedPicker() {
        isPresentingNestedPicker = false
        resizePanel()
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        if let selectionRangeAfterRefocus {
            setSelectedRange(selectionRangeAfterRefocus)
            self.selectionRangeAfterRefocus = nil
        }
    }

    private func handlePanelKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return false
        }

        return handleKeyDown(event)
    }
}

@MainActor
private final class CommandPaletteEntryRowView: NSView {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 8
        static let topPadding: CGFloat = 6
        static let detailTopSpacing: CGFloat = 4
        static let detailSpacing: CGFloat = 12
        static let bottomPadding: CGFloat = 4
        static let titleFontSize: CGFloat = 13
        static let detailFontSize: CGFloat = 12
        static let lineHeight: CGFloat = 18
        static let singleLineHeight: CGFloat = 26
        static let cornerRadius: CGFloat = 6
    }

    init(entry: CommandEntry, isSelected: Bool) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.backgroundColor = isSelected
            ? NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
            : NSColor.clear.cgColor

        let titleField = NSTextField(labelWithString: entry.isGroup ? "\(entry.title) ›" : entry.title)
        titleField.font = Self.titleFont
        titleField.textColor = isSelected ? .labelColor : .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
        ])

        guard let detail = entry.detail, !detail.isEmpty else {
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topPadding).isActive = true
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding).isActive = true
            return
        }

        let detailField = NSTextField(labelWithString: detail)
        detailField.font = Self.detailFont
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailField)

        // One-line details sit beside the title, which keeps lists such as the
        // time zones compact. Only multi-line results need their own block.
        guard Self.isMultiline(detail) else {
            detailField.alignment = .right
            detailField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

            NSLayoutConstraint.activate([
                titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
                detailField.centerYAnchor.constraint(equalTo: centerYAnchor),
                detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
                detailField.leadingAnchor.constraint(
                    greaterThanOrEqualTo: titleField.trailingAnchor,
                    constant: Metrics.detailSpacing
                ),
            ])
            return
        }

        detailField.maximumNumberOfLines = 0
        detailField.usesSingleLineMode = false

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topPadding),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: Metrics.detailTopSpacing),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    static func height(for entry: CommandEntry, width: CGFloat) -> CGFloat {
        guard let detail = entry.detail, isMultiline(detail) else {
            return Metrics.singleLineHeight
        }

        let lines = max(1, detail.split(separator: "\n", omittingEmptySubsequences: false).count)

        return Metrics.topPadding
            + Metrics.lineHeight
            + Metrics.detailTopSpacing
            + CGFloat(lines) * Metrics.lineHeight
            + Metrics.bottomPadding
    }

    private static func isMultiline(_ detail: String) -> Bool {
        detail.contains("\n")
    }

    private static let titleFont = NSFont.systemFont(ofSize: Metrics.titleFontSize, weight: .regular)
    private static let detailFont = NSFont.monospacedSystemFont(ofSize: Metrics.detailFontSize, weight: .regular)
}

@MainActor
private final class CommandPalettePanelWindow: NSPanel {
    var keyEventHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func sendEvent(_ event: NSEvent) {
        if keyEventHandler?(event) == true {
            return
        }

        super.sendEvent(event)
    }
}

@MainActor
private final class CommandPaletteTextField: NSTextField {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }

        super.keyDown(with: event)
    }
}


/// Flipped, so the list fills from the top of the scroll view.
private final class CommandPaletteListContainerView: NSView {
    override var isFlipped: Bool {
        true
    }
}
