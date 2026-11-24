import AppKit
import Carbon
import ShortyCore

@MainActor
final class CommandPalettePanelController: NSObject, ShortyBoxContent, NSTextFieldDelegate {
    private enum Metrics {
        static let panelWidth: CGFloat = 820
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

    private let box: ShortyBoxController
    private let contentView = NSView()
    private let header = ShortyBoxHeaderView()
    private var searchField: ShortyBoxSearchField { header.searchField }
    private let stackView = NSStackView()
    private let scrollView = ShortyScrollView()
    private let listContainer = CommandPaletteListContainerView()
    /// Behind the rows, for lists whose entries are places: the time zones.
    private let mapView = WorldMapView(frame: .zero)
    private var entries: [CommandEntry] = []
    private let icons = AppIconLoader()
    private var iconRefreshScheduled = false
    private var rowHeights: [CGFloat] = []
    private var selectedIndex = 0
    /// Set when this list shows a destination's entries rather than the root.
    private let listEntries: [CommandEntry]?
    private let listTitle: String?
    private let listSymbolName: String?
    /// Set when the rows come from a search rather than from a fixed list.
    private let search: CommandSearchKind?
    private let fileSearcher = FileSearcher()
    private let recentFiles = RecentFileStore()
    private var isPresentingNestedPicker = false
    private var pendingInsertionRange: NSRange?
    private var selectionRangeAfterRefocus: NSRange?
    var pickerRequestHandler: ((ClipboardMenuKind) -> Void)?
    var actionHandler: ((CommandAction) -> Void)?
    /// Supplies the bespoke views a list cannot render, such as the picker.
    var viewProvider: ((CommandViewKind) -> ShortyBoxContent?)?
    var settings: CommandBoxSettings = .default
    /// Only the entry count is shown; the picker does the browsing.
    var history: [ClipboardItem] = []
    var keepAwake = false
    /// The apps installed on the machine, supplied by the app so the scan is
    /// shared and kept between openings.
    var applications: [InstalledApplication] = []

    convenience init(box: ShortyBoxController) {
        self.init(box: box, listEntries: nil, title: nil, symbolName: nil)
    }

    init(
        box: ShortyBoxController,
        listEntries: [CommandEntry]?,
        title: String?,
        symbolName: String?,
        search: CommandSearchKind? = nil
    ) {
        self.box = box
        self.listEntries = listEntries
        self.listTitle = title
        self.listSymbolName = symbolName
        self.search = search
        super.init()

        icons.didLoad = { [weak self] in
            self?.scheduleIconRefresh()
        }

        configureContent()
        configureSearchField()
        configureStackView()
    }

    var isPresented: Bool {
        box.isPresenting(self)
    }

    // MARK: ShortyBoxContent

    var view: NSView {
        contentView
    }

    func boxDidPresent(in window: NSWindow) {
        window.makeFirstResponder(searchField)
        updateHeader()
        updateResults()
        restoreSelectionAfterReturn()
    }

    func boxHandlesKey(_ event: NSEvent) -> Bool {
        handlePanelKeyEvent(event)
    }

    /// Escape clears what you typed first, and only then goes back a level.
    func boxHandlesEscape() -> Bool {
        guard !searchField.stringValue.isEmpty else {
            return false
        }

        searchField.stringValue = ""
        updateResults()
        return true
    }

    func show() {
        // Opens with the last thing you ran, selected, so the same command can
        // be repeated with the hotkey and return alone. Typing replaces it,
        // since the text comes up selected.
        searchField.stringValue = lastRunQuery
        selectedEntryIDBeforePush = lastRunEntryID
        selectionRangeAfterRefocus = nil
        updateHeader()
        updateResults()
        resizePanel()

        box.open(self)
        searchField.currentEditor()?.selectAll(nil)
    }



    func hide() {
        isPresentingNestedPicker = false
        box.close()
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

        guard isPresented else {
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
            // The box handles escape.
            return false

        default:
            return false
        }
    }

    private func configureContent() {
        let container = contentView

        header.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.isHidden = true

        // The panel no longer grows with its rows, so the list scrolls.
        scrollView.documentView = listContainer
        scrollView.drawsBackground = false

        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder
        listContainer.addSubview(stackView)

        container.addSubview(header)
        // Added first, so the rows draw over it.
        container.addSubview(mapView)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.topPadding),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            mapView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.resultTopSpacing),
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
        searchField.delegate = self
        searchField.keyHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        updateHeader()
    }

    /// The header names what is on screen: Command at the root, or the group
    /// you stepped into, such as Time.
    private func updateHeader() {
        guard let listTitle else {
            header.update(title: "Command", symbolName: "command")
            return
        }

        header.update(title: listTitle, symbolName: listSymbolName ?? "square.grid.2x2")
    }

    static func symbolName(for entry: CommandEntry) -> String {
        switch entry.id {
        case "time":
            return "clock"
        case "clipboard.history":
            return "doc.on.clipboard"
        case "window":
            return "macwindow"
        default:
            return "square.grid.2x2"
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

        switch search {
        case .files:
            searchFiles(query: query)
            return
        case .timeZones:
            // Local work, so the answer is ready in the same breath as the
            // keystroke and there is nothing to wait for.
            show(entries: CommandCatalog.timeZoneEntries(query: query, settings: settings))
            return
        case nil:
            break
        }

        if let listEntries {
            entries = CommandCatalog.entries(in: listEntries, query: query)
        } else {
            entries = CommandCatalog.rootEntries(
                query: query,
                settings: settings,
                history: history,
                keepAwake: keepAwake,
                screenCount: NSScreen.screens.count,
                applications: applications
            )
        }

        if resetSelection || !entries.indices.contains(selectedIndex) {
            selectedIndex = openingSelectionIndex(query: query)
        }

        rowHeights = entries.map {
            CommandPaletteEntryRowView.height(for: $0, width: Metrics.panelWidth - Metrics.horizontalPadding * 2)
        }

        renderRows()
        resizePanel()
    }

    /// Spotlight answers in its own time, so the rows that are already on
    /// screen stay until it does: emptying the list on every keystroke would
    /// make the box flicker through a search.
    private func searchFiles(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            showRecentFiles()
            return
        }

        if trimmed.count < FileSearcher.minimumQueryLength {
            fileSearcher.cancel()
            show(entries: [CommandEntry(id: "files.hint", title: "Keep typing…")])
            return
        }

        fileSearcher.search(trimmed) { [weak self] hits in
            guard let self, searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
                return
            }

            show(entries: hits.isEmpty
                ? [CommandEntry(id: "files.none", title: "No files match \(trimmed)")]
                : CommandCatalog.fileEntries(hits))
        }
    }

    /// With nothing typed, what you opened through Shorty, then what the
    /// machine opened last. Yours lead: a short list of things you came to
    /// this box for beats everything the Mac has touched.
    private func showRecentFiles() {
        let own = recentFiles.recent().map(FileHit.init(path:))
        show(entries: CommandCatalog.fileEntries(own))

        fileSearcher.recentlyOpened { [weak self] hits in
            guard let self, searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            let ownPaths = Set(own.map(\.path))
            let combined = own + hits.filter { !ownPaths.contains($0.path) }

            show(entries: combined.isEmpty
                ? [CommandEntry(id: "files.hint", title: "Type to search your files")]
                : CommandCatalog.fileEntries(Array(combined.prefix(FileSearcher.resultLimit))))
        }
    }

    private func show(entries newEntries: [CommandEntry]) {
        entries = newEntries
        selectedIndex = entries.firstIndex(where: \.opensSelected)
            ?? (entries.first?.action == nil && entries.first?.destination == nil ? -1 : 0)
        rowHeights = entries.map {
            CommandPaletteEntryRowView.height(for: $0, width: Metrics.panelWidth - Metrics.horizontalPadding * 2)
        }

        renderRows()
        resizePanel()
    }

    /// A list can name the row it opens on, as Time does with the local zone.
    /// Typing overrides it: then the best match is what you asked for.
    private func openingSelectionIndex(query: String) -> Int {
        guard query.isEmpty, let index = entries.firstIndex(where: \.opensSelected) else {
            return 0
        }

        return index
    }

    /// Only a list made of places gets the map: the root, with its mix of
    /// commands, does not.
    /// Read from the rows on screen rather than from a fixed list: the zones
    /// are searched now, so there is no list to ask until something is shown.
    private var showsMap: Bool {
        entries.contains { $0.marker != nil }
    }

    private func updateMap() {
        mapView.isHidden = !showsMap

        guard showsMap else {
            return
        }

        mapView.show(
            entries.compactMap(\.marker),
            selected: entries.indices.contains(selectedIndex) ? entries[selectedIndex].marker : nil
        )
    }

    /// Icons arrive after the rows are already on screen. Redrawing is
    /// coalesced, so two hundred arrivals cost one pass, not two hundred.
    private func scheduleIconRefresh() {
        guard !iconRefreshScheduled else {
            return
        }

        iconRefreshScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            iconRefreshScheduled = false
            renderRows()
        }
    }

    private func renderRows() {
        updateMap()

        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let detailColumnWidth = CommandPaletteEntryRowView.detailColumnWidth(for: entries)
        icons.prepare(entries.compactMap(\.iconPath))

        for (index, pair) in zip(entries, rowHeights).enumerated() {
            let row = CommandPaletteEntryRowView(
                entry: pair.0,
                isSelected: index == selectedIndex,
                detailColumnWidth: detailColumnWidth,
                icon: pair.0.iconPath.flatMap { icons.icon(at: $0) }
            )
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
        contentView.layoutSubtreeIfNeeded()
        scrollSelectionIntoView()
    }

    /// Runs the selected entry, or opens it when it is a group.
    /// A file row does three things depending on what is held: open it,
    /// show it in Finder, or take its path. Everything else ignores the
    /// modifiers.
    private static func modified(_ action: CommandAction) -> CommandAction {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Shift on a cascade parks the window you are in: whichever window
        // that is, the rest stack up behind it.
        if case let .moveWindow(.cascade(options)) = action, flags.contains(.shift) {
            return .moveWindow(
                .cascade(WindowCascadeOptions(scope: options.scope, keepsFocused: true))
            )
        }

        guard case let .openFile(path) = action else {
            return action
        }

        if flags.contains(.command) {
            return .revealFile(path: path)
        }

        if flags.contains(.option) {
            return .copyFilePath(path: path)
        }

        return action
    }

    private func activateSelection() {
        guard entries.indices.contains(selectedIndex) else {
            NSSound.beep()
            return
        }

        let entry = entries[selectedIndex]

        if let destination = entry.destination {
            // Coming back should land here, not at the top of the list.
            selectedEntryIDBeforePush = entry.id
            rememberForNextTime(entry)
            open(destination, from: entry)
            return
        }

        guard let action = entry.action else {
            NSSound.beep()
            return
        }

        rememberForNextTime(entry)
        hide()
        actionHandler?(Self.modified(action))
    }

    /// Remembers what was selected while a child list is open, so coming back
    /// lands on the entry you left from rather than the top of the list.
    private var selectedEntryIDBeforePush: String?
    /// What was run last, to offer again next time the box opens. Held by the
    /// root list, which is the one `show()` presents.
    private var lastRunQuery = ""
    private var lastRunEntryID: String?

    private func rememberForNextTime(_ entry: CommandEntry) {
        lastRunQuery = searchField.stringValue
        lastRunEntryID = entry.id
    }

    private func restoreSelectionAfterReturn() {
        guard let id = selectedEntryIDBeforePush else {
            return
        }

        selectedEntryIDBeforePush = nil

        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }

        selectedIndex = index
        renderRows()
        contentView.layoutSubtreeIfNeeded()
        scrollSelectionIntoView()
    }

    /// Both kinds of destination push onto the box's stack, so going back is
    /// one rule. A list is rendered here; a view comes from the app.
    private func open(_ destination: CommandDestination, from entry: CommandEntry) {
        switch destination {
        case let .list(entries):
            let list = CommandPalettePanelController(
                box: box,
                listEntries: entries,
                title: entry.title,
                symbolName: Self.symbolName(for: entry)
            )
            list.settings = settings
            list.history = history
            list.applications = applications
            list.actionHandler = actionHandler
            list.pickerRequestHandler = pickerRequestHandler
            list.viewProvider = viewProvider
            box.push(list)

        case let .view(kind):
            guard let content = viewProvider?(kind) else {
                NSSound.beep()
                return
            }

            box.push(content)

        case let .search(kind):
            let list = CommandPalettePanelController(
                box: box,
                listEntries: [],
                title: entry.title,
                symbolName: Self.symbolName(for: entry),
                search: kind
            )
            list.settings = settings
            list.history = history
            list.applications = applications
            list.actionHandler = actionHandler
            list.pickerRequestHandler = pickerRequestHandler
            list.viewProvider = viewProvider
            box.push(list)
        }
    }

    private func resizePanel() {
        contentView.layoutSubtreeIfNeeded()
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




    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if handleCommandKey(event) {
            return true
        }

        switch UInt32(event.keyCode) {
        case UInt32(kVK_Escape):
            // The box handles escape.
            return false

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
            // Anything that goes somewhere opens with right, groups and the
            // clipboard picker alike. With text to the right of the caret the
            // key belongs to the search field.
            guard entries.indices.contains(selectedIndex),
                  entries[selectedIndex].navigates,
                  caretIsAtEndOfQuery else {
                return false
            }

            activateSelection()
            return true

        case UInt32(kVK_LeftArrow):
            guard box.depth > 1 else {
                return false
            }

            box.pop()
            return true

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
        box.suppressesResignKey = true
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

    private var caretIsAtEndOfQuery: Bool {
        let range = selectedRange()
        return range.location + range.length >= (searchField.stringValue as NSString).length
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
        box.suppressesResignKey = false
        resizePanel()
        box.pop()
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
        static let iconSize: CGFloat = 16
        static let iconSpacing: CGFloat = 7
        /// A detailed row: two lines of text beside a larger icon.
        static let detailedIconSize: CGFloat = 30
        static let detailedHeight: CGFloat = 46
        static let detailedTitleSpacing: CGFloat = 2
        static let detailedPathFontSize: CGFloat = 11
        /// Room for the scroller, which floats over the rows rather than
        /// taking space of its own: without it the clock loses its seconds.
        static let scrollerAllowance: CGFloat = 12
        /// A worked answer gets a row of its own shape.
        static let resultHeight: CGFloat = 64
        static let resultValueFontSize: CGFloat = 20
        static let resultPadding: CGFloat = 16
        static let resultNoteSpacing: CGFloat = 3
    }



    /// Widest single-line detail in the list, so every row reserves the same
    /// column and the parts that vary, such as a UTC offset, line up.
    static func detailColumnWidth(for entries: [CommandEntry]) -> CGFloat {
        let widths = entries.compactMap { entry -> CGFloat? in
            guard let detail = entry.detail, !detail.isEmpty, !isMultiline(detail) else {
                return nil
            }

            return (detail as NSString).size(withAttributes: [.font: detailFont]).width
        }

        return widths.max() ?? 0
    }

    init(entry: CommandEntry, isSelected: Bool, detailColumnWidth: CGFloat = 0, icon: NSImage? = nil) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.backgroundColor = isSelected
            ? NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
            : NSColor.clear.cgColor

        switch entry.layout {
        case .detailed:
            configureDetailed(entry: entry, isSelected: isSelected, icon: icon)
            return
        case .result:
            configureResult(entry: entry, isSelected: isSelected)
            return
        case .compact:
            break
        }

        let titleField = NSTextField(labelWithString: entry.navigates ? "\(entry.title) ›" : entry.title)
        titleField.font = Self.titleFont
        titleField.textColor = isSelected ? .labelColor : .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        // An icon shifts the text across; rows without one read as before.
        var textLeading = leadingAnchor
        var textInset = Metrics.horizontalPadding

        if entry.iconPath != nil || entry.symbolName != nil {
            let iconView = NSImageView()
            iconView.image = icon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)

            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
                iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
            ])

            textLeading = iconView.trailingAnchor
            textInset = Metrics.iconSpacing
        }

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: textLeading, constant: textInset),
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
            // Left aligned inside a fixed column: right aligning each label
            // separately is what left the clocks ragged, since the offset
            // after them differs in width.
            detailField.alignment = .left
            detailField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

            NSLayoutConstraint.activate([
                titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
                detailField.centerYAnchor.constraint(equalTo: centerYAnchor),
                detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
                detailField.widthAnchor.constraint(equalToConstant: ceil(detailColumnWidth)),
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

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Metrics.detailedIconSize - 6, weight: .regular)
            )
    }

    /// What was asked on the left, what it comes to on the right, each with
    /// its note beneath. A worked answer reads as a sum rather than as a row
    /// in a list, so it is given the room to look like one.
    private func configureResult(entry: CommandEntry, isSelected: Bool) {
        let question = Self.resultColumn(
            value: entry.title,
            note: entry.detail,
            alignment: .left,
            isSelected: isSelected
        )
        let answer = Self.resultColumn(
            value: entry.trailing ?? "",
            note: entry.trailingDetail,
            alignment: .right,
            isSelected: isSelected
        )
        let arrow = NSTextField(labelWithString: "→")
        arrow.font = .systemFont(ofSize: Metrics.resultValueFontSize, weight: .light)
        arrow.textColor = .tertiaryLabelColor
        arrow.translatesAutoresizingMaskIntoConstraints = false

        for view in [question, arrow, answer] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            question.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.resultPadding),
            question.centerYAnchor.constraint(equalTo: centerYAnchor),

            arrow.centerXAnchor.constraint(equalTo: centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.leadingAnchor.constraint(
                greaterThanOrEqualTo: question.trailingAnchor,
                constant: Metrics.detailSpacing
            ),

            answer.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(Metrics.resultPadding + Metrics.scrollerAllowance)
            ),
            answer.centerYAnchor.constraint(equalTo: centerYAnchor),
            answer.leadingAnchor.constraint(
                greaterThanOrEqualTo: arrow.trailingAnchor,
                constant: Metrics.detailSpacing
            ),
        ])
    }

    private static func resultColumn(
        value: String,
        note: String?,
        alignment: NSTextAlignment,
        isSelected: Bool
    ) -> NSStackView {
        let valueField = NSTextField(labelWithString: value)
        valueField.font = .systemFont(ofSize: Metrics.resultValueFontSize, weight: .semibold)
        valueField.textColor = isSelected ? .labelColor : .secondaryLabelColor
        valueField.alignment = alignment
        valueField.lineBreakMode = .byTruncatingTail

        let column = NSStackView(views: [valueField])
        column.orientation = .vertical
        column.alignment = alignment == .right ? .trailing : .leading
        column.spacing = Metrics.resultNoteSpacing
        column.translatesAutoresizingMaskIntoConstraints = false

        if let note, !note.isEmpty {
            let noteField = NSTextField(labelWithString: note)
            noteField.font = .systemFont(ofSize: Metrics.detailFontSize)
            noteField.textColor = .tertiaryLabelColor
            noteField.alignment = alignment
            noteField.lineBreakMode = .byTruncatingTail
            column.addArrangedSubview(noteField)
        }

        return column
    }

    /// Name on top, where it is read first, and the path under it in full.
    /// Half a search for `README` comes back with the same name every time,
    /// so the path is the part that decides.
    private func configureDetailed(entry: CommandEntry, isSelected: Bool, icon: NSImage?) {
        // A row with no picture of its own gives the space back to the text
        // rather than leaving a hole where an icon would be.
        let picture = icon ?? entry.symbolName.flatMap(Self.symbol)
        var textLeading = leadingAnchor
        var textInset = Metrics.horizontalPadding

        if let picture {
            let iconView = NSImageView()
            iconView.image = picture
            iconView.contentTintColor = icon == nil ? .secondaryLabelColor : nil
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)

            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: Metrics.detailedIconSize),
                iconView.heightAnchor.constraint(equalToConstant: Metrics.detailedIconSize),
            ])

            textLeading = iconView.trailingAnchor
            textInset = Metrics.iconSpacing
        }

        let titleField = NSTextField(labelWithString: entry.title)
        titleField.font = .systemFont(ofSize: Metrics.titleFontSize, weight: .medium)
        titleField.textColor = isSelected ? .labelColor : .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        if let trailing = entry.trailing {
            let valueField = NSTextField(labelWithString: trailing)
            valueField.font = Self.detailFont
            valueField.textColor = .secondaryLabelColor
            valueField.lineBreakMode = .byTruncatingTail
            valueField.translatesAutoresizingMaskIntoConstraints = false
            valueField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            addSubview(valueField)

            NSLayoutConstraint.activate([
                valueField.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -(Metrics.horizontalPadding + Metrics.scrollerAllowance)
                ),
                valueField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
                valueField.leadingAnchor.constraint(
                    greaterThanOrEqualTo: titleField.trailingAnchor,
                    constant: Metrics.detailSpacing
                ),
            ])
        }

        let pathField = NSTextField(labelWithString: entry.detail ?? "")
        pathField.font = .systemFont(ofSize: Metrics.detailedPathFontSize)
        pathField.textColor = .tertiaryLabelColor
        // The end of a path says more than its start, so that is what stays.
        pathField.lineBreakMode = .byTruncatingHead
        pathField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathField)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: textLeading, constant: textInset),
            titleField.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Metrics.horizontalPadding
            ),
            titleField.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -Metrics.detailedTitleSpacing / 2),

            pathField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            pathField.topAnchor.constraint(equalTo: centerYAnchor, constant: Metrics.detailedTitleSpacing / 2),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    static func height(for entry: CommandEntry, width: CGFloat) -> CGFloat {
        switch entry.layout {
        case .detailed:
            return Metrics.detailedHeight
        case .result:
            return Metrics.resultHeight
        case .compact:
            break
        }

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


/// Flipped, so the list fills from the top of the scroll view.
private final class CommandPaletteListContainerView: NSView {
    override var isFlipped: Bool {
        true
    }
}
