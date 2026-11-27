import AppKit
import Carbon
import ShortyCore
import UniformTypeIdentifiers

@MainActor
final class ClipboardPickerPanelController: NSObject, ShortyBoxContent, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Metrics {
        /// How far down the list cards are read ahead.
        static let prefetchedLinks = 20
        static let panelWidth: CGFloat = 820
        static let listWidth: CGFloat = 320
        static let dividerWidth: CGFloat = 1
        /// How far down the viewport the opening selection sits.
        static let selectionContextRatio: CGFloat = 0.25
        static let maxVisibleRows = 35
        static let rowHeight: CGFloat = 24
        static let headerRowHeight: CGFloat = 18
        static let topPadding: CGFloat = 8
        static let searchHorizontalPadding: CGFloat = 8
        static let searchHeight: CGFloat = 22
        static let searchBottomSpacing: CGFloat = 6
        static let bottomPadding: CGFloat = 4
        static let nonOverflowSlack: CGFloat = 12
        static let topOffsetRatio: CGFloat = 0.20
        static let bottomMargin: CGFloat = 20
        static let iconSize: CGFloat = 16
    }

    private let box: ShortyBoxController
    private let contentView = NSView()
    private let header = ShortyBoxHeaderView()
    private var searchField: NSTextField { header.searchField }
    private let tableView = ClipboardPickerTableView()
    private let scrollView = ClipboardPickerScrollView()
    private let detailView = ClipboardPickerDetailView()
    private let footerDivider = NSView()
    private let footer = NSTextField(labelWithString: "")

    var showsLinkPreviews = true {
        didSet {
            detailView.showsLinkPreviews = showsLinkPreviews
        }
    }
    private let detailDateFormatter = ClipboardItemDetailBuilder.defaultDateFormatter()
    private var mode: ClipboardPickerMode = .all
    private var history: [ClipboardItem] = []
    private var snippetGroups: [SnippetGroup] = []
    private var currentFolder: ClipboardPickerFolder?
    private var query = ""
    private var entries: [ClipboardPickerEntry] = []
    private var selectedIndex = -1
    private var onSelect: ((ClipboardPickerResult, ClipboardPickerActivationMode) -> Void)?
    private var onCancel: (() -> Void)?
    private var onDelete: ((ClipboardItem) -> Void)?
    private var closesBoxOnSelect = true
    private var savedSelection: NSRange?
    private var sourceIconCache: [String: NSImage] = [:]
    private var thumbnailCache: [String: NSImage] = [:]
    private let assetStore = ClipboardAssetStore()
    private lazy var documentIcon = Self.icon(NSWorkspace.shared.icon(for: UTType.plainText))
    private lazy var folderIcon: NSImage = {
        if let image = NSImage(named: NSImage.folderName) {
            return Self.icon(image)
        }

        return Self.icon(NSWorkspace.shared.icon(for: UTType.folder))
    }()

    init(box: ShortyBoxController) {
        self.box = box
        super.init()

        configureContent()
        configureSearchField()
        configureTable()
    }

    var isPresented: Bool {
        box.isPresenting(self)
    }

    // MARK: ShortyBoxContent

    var route: ShortyBoxRoute {
        let kind: ClipboardMenuKind = mode == .snippetsOnly ? .snippets : .combined
        let purpose: ClipboardPickerPurpose = closesBoxOnSelect ? .paste : .insert
        return .clipboard(kind, purpose: purpose)
    }

    var view: NSView {
        contentView
    }

    var hasDraft: Bool {
        !query.isEmpty || currentFolder != nil
    }

    func boxDidPresent(in window: NSWindow) {
        window.makeFirstResponder(searchField)
    }

    func boxWillSuspend() {
        savedSelection = selectedRange()
    }

    func boxDidResume(in window: NSWindow) {
        window.makeFirstResponder(searchField)
        restoreCaretAfterResume()
    }

    func boxPerformsKeyEquivalent(_ event: NSEvent) -> Bool {
        switch UInt32(event.keyCode) {
        case UInt32(kVK_Return), UInt32(kVK_ANSI_KeypadEnter):
            let activationMode = Self.activationMode(event: event)
            guard activationMode != .standard else {
                return false
            }

            activateSelected(activationMode: activationMode)
            return true

        default:
            return false
        }
    }

    func boxDidDismiss() {
        let handler = onCancel
        onSelect = nil
        onCancel = nil
        currentFolder = nil
        query = ""
        searchField.stringValue = ""
        savedSelection = nil
        handler?()
    }

    /// Escape clears what you typed first, then leaves a folder, then lets
    /// the box go back a level.
    func boxHandlesEscape() -> Bool {
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            query = ""
            savedSelection = nil
            applyFilter(resetSelection: true)
            return true
        }

        return leaveFolderIfNeeded()
    }

    func show(
        mode: ClipboardPickerMode,
        history: [ClipboardItem],
        snippetGroups: [SnippetGroup],
        closesBoxOnSelect: Bool = true,
        onSelect: @escaping (ClipboardPickerResult, ClipboardPickerActivationMode) -> Void,
        onCancel: (() -> Void)? = nil,
        onDelete: ((ClipboardItem) -> Void)? = nil
    ) {
        self.mode = mode
        self.history = history
        self.snippetGroups = snippetGroups
        self.closesBoxOnSelect = closesBoxOnSelect
        self.currentFolder = nil
        self.query = ""
        self.savedSelection = nil
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onCancel = onCancel
        searchField.stringValue = ""
        updateHeader()

        applyFilter(resetSelection: true)
    }

    func refresh(
        history: [ClipboardItem],
        snippetGroups: [SnippetGroup],
        showsLinkPreviews: Bool
    ) {
        self.history = history
        self.snippetGroups = snippetGroups
        self.showsLinkPreviews = showsLinkPreviews
        if let folder = currentFolder {
            let roots = ClipboardPickerSearch.rootEntries(
                history: history,
                snippetGroups: snippetGroups,
                query: "",
                mode: mode
            )
            currentFolder = roots.compactMap(\.folder).first(where: { $0.id == folder.id })
        }
        updateHeader()
        applyFilter(resetSelection: false)
    }

    func switchMode(_ mode: ClipboardPickerMode) {
        self.mode = mode
        currentFolder = nil
        query = ""
        savedSelection = nil
        searchField.stringValue = ""
        updateHeader()
        applyFilter(resetSelection: true)
    }

    func hide() {
        guard box.isPresenting(self) else {
            return
        }

        box.close()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard entries.indices.contains(row) else {
            return nil
        }

        return makeCell(for: entries[row])
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard entries.indices.contains(row) else {
            return Metrics.rowHeight
        }

        return height(for: entries[row])
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        entries.indices.contains(row) && entries[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipboardPickerRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRow
        if entries.indices.contains(selectedRow), entries[selectedRow].isSelectable {
            selectedIndex = selectedRow
            updateDetail()
        }
    }

    private func configureContent() {
        let container = contentView

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor

        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail

        for view in [header, scrollView, divider, detailView, footerDivider, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.topPadding),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.searchBottomSpacing),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: Metrics.listWidth),
            scrollView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -Metrics.bottomPadding),

            divider.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: Metrics.dividerWidth),
            divider.topAnchor.constraint(equalTo: scrollView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            detailView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            detailView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            detailView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            footerDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            footerDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
    }

    private func configureSearchField() {
        searchField.delegate = self
        updateHeader()
    }

    /// Names the section on screen, down to the snippet folder you opened.
    private func updateHeader() {
        updateFooter()
        if let currentFolder {
            header.update(title: currentFolder.title, symbolName: "folder")
            return
        }

        let title = mode == .snippetsOnly ? "Snippets" : "Clipboard History"
        header.update(
            title: title,
            symbolName: mode == .snippetsOnly ? "text.quote" : "doc.on.clipboard"
        )
    }

    private func updateFooter() {
        var parts: [String] = []
        if closesBoxOnSelect {
            parts = ["↩ paste", "⌘↩ copy", "⌥↩ plain", "⇧↩ join", "⇧⌘E scratch pad", "⇧⌫ delete"]
        } else {
            parts = ["↩ insert"]
        }

        if currentFolder != nil {
            parts.append("← back")
        }

        parts.append(closesBoxOnSelect ? "esc close" : "esc back")
        footer.stringValue = parts.joined(separator: "    ")
    }

    private func configureTable() {
        scrollView.contentView = ClipboardPickerClipView()

        tableView.headerView = nil
        tableView.rowHeight = Metrics.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.autoresizingMask = [.width]
        tableView.keyHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        tableView.mouseSelectionHandler = { [weak self] row, activationMode in
            self?.activate(row: row, activationMode: activationMode)
        }
        tableView.hoverSelectionHandler = { [weak self] row in
            self?.selectHoveredRow(row)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = Metrics.listWidth
        column.minWidth = 0
        column.maxWidth = Metrics.listWidth
        column.resizingMask = []
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
    }

    func controlTextDidChange(_ notification: Notification) {
        query = searchField.stringValue
        applyFilter(resetSelection: true)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true

        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true

        case #selector(NSResponder.moveLeft(_:)):
            guard caretIsAtStartOfQuery else {
                return false
            }

            return leaveFolderIfNeeded()

        case #selector(NSResponder.moveRight(_:)):
            guard caretIsAtEndOfQuery else {
                return false
            }

            return enterSelectedFolderIfNeeded()

        case #selector(NSResponder.deleteBackward(_:)),
            #selector(NSResponder.deleteForward(_:)):
            // `shift+backspace` deletes the selected entry, so the field
            // editor must not take a character out of the search box as well.
            // AppKit drops the modifier when it turns a key into a command,
            // so the shift is read back off the event.
            if Self.shiftModifierIsActive(event: NSApp.currentEvent) {
                return deleteSelectedHistoryItem()
            }

            if !query.isEmpty {
                return false
            }

            return leaveFolderIfNeeded()

        case #selector(NSResponder.insertNewline(_:)):
            activateSelected(activationMode: Self.activationMode(event: NSApp.currentEvent))
            return true

        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let mode = ClipboardPickerActivationMode.fromModifiers(
                command: Self.commandModifierIsActive(event: NSApp.currentEvent),
                shift: Self.shiftModifierIsActive(event: NSApp.currentEvent),
                option: true
            )
            activateSelected(activationMode: mode)
            return true

        case #selector(NSResponder.cancelOperation(_:)):
            // The box handles escape.
            return false

        default:
            return false
        }
    }

    private func applyFilter(resetSelection: Bool, preferredEntryID: String? = nil) {
        if let currentFolder {
            entries = ClipboardPickerSearch.folderEntries(in: currentFolder, query: query)
            entries.append(.back(".."))
        } else {
            entries = ClipboardPickerSearch.rootEntries(
                history: history,
                snippetGroups: snippetGroups,
                query: query,
                mode: mode
            )
        }

        if let preferredEntryID,
           let preferredIndex = entries.firstIndex(where: { $0.id == preferredEntryID && $0.isSelectable }) {
            selectedIndex = preferredIndex
        } else if resetSelection || !entries.indices.contains(selectedIndex) || !entries[selectedIndex].isSelectable {
            selectedIndex = initialSelectionIndex() ?? -1
        }

        resizePanelForCurrentEntries()
        tableView.reloadData()
        syncTableWidth()
        selectCurrentRow(anchorContextAbove: true)
        prefetchLinkPreviews()
    }

    /// The cards for the links on screen, fetched before they are asked for.
    /// Only the opening stretch of the list: further down is scrolling the
    /// user has not done, and the cards keep for a week once read.
    func prefetchLinkPreviews(_ urls: [URL]) {
        guard showsLinkPreviews else {
            return
        }

        detailView.prefetch(urls)
    }

    private func prefetchLinkPreviews() {
        guard showsLinkPreviews else {
            return
        }

        let urls = entries
            .prefix(Metrics.prefetchedLinks)
            .compactMap { entry -> URL? in
                guard case let .history(item) = entry,
                      ClipboardItemDetailBuilder.isLink(item.plainText) else {
                    return nil
                }

                return URL(string: item.plainText.trimmingCharacters(in: .whitespacesAndNewlines))
            }

        detailView.prefetch(urls)
    }

    private func resizePanelForCurrentEntries() {
        let documentContentHeight = entries.reduce(CGFloat(0)) { $0 + height(for: $1) }
        let documentHeight = max(documentContentHeight + Metrics.nonOverflowSlack, Metrics.rowHeight)

        contentView.layoutSubtreeIfNeeded()

        scrollView.hasVerticalScroller = documentHeight > scrollView.contentSize.height
        tableView.setFrameOrigin(NSPoint(x: 0, y: tableView.frame.origin.y))
        tableView.setFrameSize(NSSize(width: visibleTableWidth(), height: documentHeight))
        syncTableWidth()
    }

    private func syncTableWidth() {
        let tableWidth = visibleTableWidth()
        guard let column = tableView.tableColumns.first else {
            return
        }

        column.maxWidth = tableWidth
        column.width = tableWidth
        tableView.setFrameSize(NSSize(width: tableWidth, height: tableView.frame.height))
    }

    private func visibleTableWidth() -> CGFloat {
        let width = scrollView.contentSize.width
        return max(1, floor(min(Metrics.listWidth, width > 0 ? width : Metrics.listWidth)))
    }


    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch UInt32(event.keyCode) {
        case UInt32(kVK_Escape):
            // The box handles escape.
            return false

        case UInt32(kVK_UpArrow):
            moveSelection(by: -1)
            return true

        case UInt32(kVK_DownArrow):
            moveSelection(by: 1)
            return true

        case UInt32(kVK_LeftArrow):
            return leaveFolderIfNeeded()

        case UInt32(kVK_RightArrow):
            return enterSelectedFolderIfNeeded()

        case UInt32(kVK_Delete), UInt32(kVK_ForwardDelete):
            // Shift, not command: `cmd+backspace` means "delete to the start
            // of the line" in a text field, and taking that away from the
            // search box is worse than choosing a key the field ignores.
            if event.modifierFlags.contains(.shift) {
                return deleteSelectedHistoryItem()
            }

            if !query.isEmpty {
                return false
            }

            return leaveFolderIfNeeded()

        case UInt32(kVK_Return), UInt32(kVK_ANSI_KeypadEnter):
            activateSelected(activationMode: Self.activationMode(event: event))
            return true

        default:
            return false
        }
    }

    private var caretIsAtStartOfQuery: Bool {
        let text = searchField.stringValue
        guard !text.isEmpty else {
            return true
        }

        guard let range = searchField.currentEditor()?.selectedRange else {
            return false
        }

        return range.location == 0 && range.length == 0
    }

    private var caretIsAtEndOfQuery: Bool {
        let length = (searchField.stringValue as NSString).length
        guard let range = searchField.currentEditor()?.selectedRange else {
            return true
        }

        return range.location + range.length >= length
    }

    private func selectedRange() -> NSRange {
        if let editor = searchField.currentEditor() {
            return editor.selectedRange
        }

        return NSRange(location: (searchField.stringValue as NSString).length, length: 0)
    }

    private func restoreCaretAfterResume() {
        let value = searchField.stringValue as NSString
        let fallback = NSRange(location: value.length, length: 0)
        let candidate = savedSelection ?? fallback
        savedSelection = nil

        let range: NSRange
        if candidate.location >= 0, candidate.location <= value.length {
            range = NSRange(location: candidate.location, length: min(candidate.length, value.length - candidate.location))
        } else {
            range = fallback
        }

        searchField.currentEditor()?.selectedRange = range
    }

    /// What is selected, for the scratch pad to open on.
    ///
    /// Nil when the row is not something with text in it, which is what
    /// tells the pad's hotkey to behave as it does everywhere else.
    var selectedTextForScratchPad: String? {
        guard entries.indices.contains(selectedIndex) else {
            return nil
        }

        let text: String

        switch entries[selectedIndex] {
        case let .history(item):
            // A picture with words read out of it has something to work on.
            text = item.plainText.isEmpty ? (item.ocrText ?? "") : item.plainText
        case let .snippet(_, snippet):
            text = snippet.content
        default:
            return nil
        }

        return text.isEmpty ? nil : text
    }

    fileprivate static func activationMode(event: NSEvent? = nil) -> ClipboardPickerActivationMode {
        ClipboardPickerActivationMode.fromModifiers(
            command: commandModifierIsActive(event: event),
            shift: shiftModifierIsActive(event: event),
            option: optionModifierIsActive(event: event)
        )
    }

    fileprivate static func optionModifierIsActive(event: NSEvent? = nil) -> Bool {
        if event?.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.option) == true {
            return true
        }

        return NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.option)
    }

    fileprivate static func shiftModifierIsActive(event: NSEvent? = nil) -> Bool {
        if event?.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift) == true {
            return true
        }

        let appKitShiftIsDown = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
        let coreGraphicsShiftIsDown = CGEventSource
            .flagsState(.combinedSessionState)
            .contains(.maskShift)
        let physicalShiftIsDown =
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Shift)) ||
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_RightShift))

        return appKitShiftIsDown || coreGraphicsShiftIsDown || physicalShiftIsDown
    }

    fileprivate static func commandModifierIsActive(event: NSEvent? = nil) -> Bool {
        if event?.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command) == true {
            return true
        }

        let appKitCommandIsDown = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        let coreGraphicsCommandIsDown = CGEventSource
            .flagsState(.combinedSessionState)
            .contains(.maskCommand)
        let physicalCommandIsDown =
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Command)) ||
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_RightCommand))

        return appKitCommandIsDown || coreGraphicsCommandIsDown || physicalCommandIsDown
    }

    private func moveSelection(by offset: Int) {
        let selectableIndices = entries.indices.filter { entries[$0].isSelectable }
        guard !selectableIndices.isEmpty else {
            return
        }

        guard let currentPosition = selectableIndices.firstIndex(of: selectedIndex) else {
            selectedIndex = offset < 0 ? selectableIndices.last! : selectableIndices.first!
            selectCurrentRow()
            return
        }

        let lastPosition = selectableIndices.index(before: selectableIndices.endIndex)
        let nextPosition: Int

        if offset < 0, currentPosition == selectableIndices.startIndex {
            nextPosition = lastPosition
        } else if offset > 0, currentPosition == lastPosition {
            nextPosition = selectableIndices.startIndex
        } else {
            nextPosition = min(max(currentPosition + offset, selectableIndices.startIndex), lastPosition)
        }

        selectedIndex = selectableIndices[nextPosition]
        selectCurrentRow()
    }

    private func selectHoveredRow(_ row: Int) {
        guard entries.indices.contains(row), entries[row].isSelectable, selectedIndex != row else {
            return
        }

        selectedIndex = row
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        updateDetail()
    }

    private func updateDetail() {
        guard entries.indices.contains(selectedIndex) else {
            detailView.update(with: nil)
            return
        }

        detailView.update(
            with: ClipboardItemDetailBuilder.detail(
                for: entries[selectedIndex],
                dateFormatter: detailDateFormatter
            )
        )
    }

    private func activateSelected(activationMode: ClipboardPickerActivationMode) {
        activate(row: selectedIndex, activationMode: activationMode)
    }

    private func enterSelectedFolderIfNeeded() -> Bool {
        enterFolder(at: selectedIndex)
    }

    private func enterFolder(at row: Int) -> Bool {
        guard entries.indices.contains(row), let folder = entries[row].folder else {
            return false
        }

        currentFolder = folder
        query = ""
        searchField.stringValue = ""
        updateHeader()
        applyFilter(resetSelection: true)
        return true
    }

    /// Removes the selected entry from history, keeping the selection where
    /// it was so a run of deletes does not jump about. Snippets come from the
    /// config, so they are not ours to delete.
    private func deleteSelectedHistoryItem() -> Bool {
        guard entries.indices.contains(selectedIndex),
              case let .history(item) = entries[selectedIndex] else {
            NSSound.beep()
            return true
        }

        onDelete?(item)
        history.removeAll { $0.id == item.id }

        let previousIndex = selectedIndex
        applyFilter(resetSelection: true)
        selectedIndex = min(previousIndex, entries.indices.last ?? 0)

        if entries.indices.contains(selectedIndex), !entries[selectedIndex].isSelectable {
            selectedIndex = firstSelectableIndex() ?? -1
        }

        selectCurrentRow()
        return true
    }

    private func activate(row: Int, activationMode: ClipboardPickerActivationMode) {
        guard entries.indices.contains(row), entries[row].isSelectable else {
            NSSound.beep()
            return
        }

        let entry = entries[row]

        if enterFolder(at: row) {
            return
        }

        if case .back = entry {
            _ = leaveFolderIfNeeded()
            return
        }

        guard let result = entry.pasteResult else {
            NSSound.beep()
            return
        }

        let handler = onSelect
        onSelect = nil
        onCancel = nil
        if closesBoxOnSelect {
            box.close()
        } else {
            box.pop()
        }
        handler?(result, activationMode)
    }

    private func leaveFolderIfNeeded() -> Bool {
        guard let folder = currentFolder else {
            return false
        }

        let parentEntryID = ClipboardPickerEntry.folder(folder).id
        currentFolder = nil
        query = ""
        searchField.stringValue = ""
        updateHeader()
        applyFilter(resetSelection: true, preferredEntryID: parentEntryID)
        return true
    }


    private func firstSelectableIndex() -> Int? {
        entries.indices.first { entries[$0].isSelectable }
    }

    /// Opens on the newest history item, leaving the snippets above it one
    /// `up` away. While filtering, the first match wins whatever section it is
    /// in, since that is what the query asked for.
    private func initialSelectionIndex() -> Int? {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return firstSelectableIndex()
        }

        let historyIndex = entries.indices.first { index in
            if case .history = entries[index] {
                return true
            }

            return false
        }

        return historyIndex ?? firstSelectableIndex()
    }

    private func selectCurrentRow(anchorContextAbove: Bool = false) {
        updateDetail()

        guard entries.indices.contains(selectedIndex), entries[selectedIndex].isSelectable else {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)

        if anchorContextAbove {
            scrollKeepingContextAboveSelection()
        } else {
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// Opening on the newest history item would otherwise scroll the snippets
    /// off the top. Leave the selected row a little way down the viewport so
    /// whatever sits above it stays in view.
    private func scrollKeepingContextAboveSelection() {
        let rowRect = tableView.rect(ofRow: selectedIndex)
        let viewportHeight = scrollView.contentView.bounds.height
        let maximumOffset = max(0, tableView.frame.height - viewportHeight)
        let offset = min(
            max(0, rowRect.minY - viewportHeight * Metrics.selectionContextRatio),
            maximumOffset
        )

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func makeCell(for entry: ClipboardPickerEntry) -> NSView {
        let presentation = entry.presentation
        return ClipboardPickerCellView(
            title: presentation.title,
            trailingLabel: presentation.trailingLineCountLabel,
            textColor: textColor(for: entry),
            icon: image(for: entry),
            showsDisclosure: showsDisclosure(for: entry),
            layoutWidthLimit: Metrics.panelWidth
        )
    }

    private func showsDisclosure(for entry: ClipboardPickerEntry) -> Bool {
        switch entry {
        case .folder:
            return true
        case .header, .history, .snippet, .back, .empty:
            return false
        }
    }

    private func height(for entry: ClipboardPickerEntry) -> CGFloat {
        switch entry {
        case .header:
            return Metrics.headerRowHeight
        case .folder, .history, .snippet, .back, .empty:
            return Metrics.rowHeight
        }
    }

    private func image(for entry: ClipboardPickerEntry) -> NSImage? {
        switch entry {
        case .folder, .back:
            return folderIcon
        case let .history(item):
            return thumbnail(for: item)
                ?? sourceIcon(forBundleID: item.source?.bundleID)
                ?? documentIcon
        case .snippet:
            return documentIcon
        case .header, .empty:
            return nil
        }
    }

    private func thumbnail(for item: ClipboardItem) -> NSImage? {
        if let asset = item.image {
            if let cached = thumbnailCache[asset.fileName] {
                return cached
            }

            guard let image = assetStore.image(for: asset) else {
                return nil
            }

            let thumbnail = Self.icon(image)
            thumbnailCache[asset.fileName] = thumbnail
            return thumbnail
        }

        guard let file = item.files.first, file.exists else {
            return nil
        }

        return Self.icon(NSWorkspace.shared.icon(forFile: file.path))
    }

    private func sourceIcon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID else {
            return nil
        }

        if let cached = sourceIconCache[bundleID] {
            return cached
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        let icon = Self.icon(NSWorkspace.shared.icon(forFile: url.path))
        sourceIconCache[bundleID] = icon
        return icon
    }

    private func textColor(for entry: ClipboardPickerEntry) -> NSColor {
        switch entry {
        case .header, .empty:
            return .secondaryLabelColor
        case .folder, .history, .snippet, .back:
            return .labelColor
        }
    }

    private static func icon(_ source: NSImage, size: CGFloat = Metrics.iconSize) -> NSImage {
        let targetSize = NSSize(width: size, height: size)
        let image = NSImage(size: targetSize)
        image.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = source.isTemplate
        return image
    }
}

@MainActor
private final class ClipboardPickerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else {
            return
        }

        NSColor.systemBlue.setFill()
        bounds.insetBy(dx: 0, dy: 1).fill()
    }
}

@MainActor
private final class ClipboardPickerCellView: NSTableCellView {
    private enum Metrics {
        static let iconSize: CGFloat = 16
        static let iconLeading: CGFloat = 0
        static let textSpacing: CGFloat = 4
        static let trailingPadding: CGFloat = 30
        static let headerLeading: CGFloat = 0
        static let disclosureSize: CGFloat = 12
        static let disclosureTrailing: CGFloat = 24
        static let disclosureSpacing: CGFloat = 8
    }

    private let title: String
    private let trailingLabel: String?
    private let textColor: NSColor
    private let font = NSFont.systemFont(ofSize: 13)
    private let iconView: NSImageView?
    private let showsDisclosure: Bool
    private let layoutWidthLimit: CGFloat

    init(
        title: String,
        trailingLabel: String?,
        textColor: NSColor,
        icon: NSImage?,
        showsDisclosure: Bool,
        layoutWidthLimit: CGFloat
    ) {
        self.title = title
        self.trailingLabel = trailingLabel
        self.textColor = textColor
        self.showsDisclosure = showsDisclosure
        self.layoutWidthLimit = layoutWidthLimit

        if let icon {
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyDown
            self.iconView = iconView
        } else {
            iconView = nil
        }

        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let textHeight = ceil(font.ascender - font.descender + font.leading)
        let textY = floor((bounds.height - textHeight) / 2)
        let visibleWidth = enclosingScrollView?.contentSize.width
        let layoutWidth = max(
            1,
            min(
                layoutWidthLimit,
                bounds.width,
                visibleWidth.flatMap { $0 > 0 ? $0 : nil } ?? layoutWidthLimit
            )
        )
        let textStart: CGFloat
        var textEnd = layoutWidth - Metrics.trailingPadding

        if let iconView {
            let iconRect = NSRect(
                x: Metrics.iconLeading,
                y: floor((bounds.height - Metrics.iconSize) / 2),
                width: Metrics.iconSize,
                height: Metrics.iconSize
            )
            iconView.image?.draw(
                in: iconRect,
                from: NSRect(origin: .zero, size: iconView.image?.size ?? .zero),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            textStart = iconRect.maxX + Metrics.textSpacing
        } else {
            textStart = Metrics.headerLeading
        }

        if showsDisclosure {
            let rect = NSRect(
                x: layoutWidth - Metrics.disclosureTrailing - Metrics.disclosureSize,
                y: floor((bounds.height - Metrics.disclosureSize) / 2),
                width: Metrics.disclosureSize,
                height: Metrics.disclosureSize
            )
            drawDisclosure(in: rect)
            textEnd = rect.minX - Metrics.disclosureSpacing
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]
        if let trailingLabel {
            let marker = trailingLabel as NSString
            let markerWidth = ceil(marker.size(withAttributes: attributes).width)
            let markerX = max(textStart, textEnd - markerWidth)
            let markerRect = NSRect(
                x: markerX,
                y: textY,
                width: markerWidth,
                height: textHeight
            )
            marker.draw(at: markerRect.origin, withAttributes: attributes)
            textEnd = markerRect.minX - Metrics.textSpacing
        }

        let textRect = NSRect(
            x: textStart,
            y: textY,
            width: max(0, textEnd - textStart),
            height: textHeight
        )
        let renderedTitle = truncatedTitle(forWidth: textRect.width, attributes: attributes)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: textRect).setClip()
        renderedTitle.draw(at: textRect.origin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDisclosure(in rect: NSRect) {
        NSColor.labelColor.setFill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX - 3, y: rect.midY - 5))
        path.line(to: NSPoint(x: rect.midX + 4, y: rect.midY))
        path.line(to: NSPoint(x: rect.midX - 3, y: rect.midY + 5))
        path.close()
        path.fill()
    }

    private func truncatedTitle(
        forWidth width: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSString {
        guard width > 0 else {
            return ""
        }

        let fullTitle = title as NSString
        guard fullTitle.size(withAttributes: attributes).width > width else {
            return fullTitle
        }

        let ellipsis = "..." as NSString
        guard ellipsis.size(withAttributes: attributes).width <= width else {
            return ""
        }

        var low = 0
        var high = title.count

        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = String(title.prefix(mid)) + "..."
            if (candidate as NSString).size(withAttributes: attributes).width <= width {
                low = mid
            } else {
                high = mid - 1
            }
        }

        return (String(title.prefix(low)) + "...") as NSString
    }
}

@MainActor
private final class ClipboardPickerScrollView: ShortyScrollView {
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.origin.y))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
private final class ClipboardPickerClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = 0
        return bounds
    }
}

@MainActor
private final class ClipboardPickerTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?
    var mouseSelectionHandler: ((Int, ClipboardPickerActivationMode) -> Void)?
    var hoverSelectionHandler: ((Int) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: localPoint)
        let activationMode = ClipboardPickerPanelController.activationMode(event: event)

        super.mouseDown(with: event)

        if clickedRow >= 0 {
            mouseSelectionHandler?(clickedRow, activationMode)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let hoveredRow = row(at: localPoint)

        if hoveredRow >= 0 {
            hoverSelectionHandler?(hoveredRow)
        }
    }
}
