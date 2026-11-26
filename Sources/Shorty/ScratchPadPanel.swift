import AppKit
import Carbon
import ShortyCore

/// A page to work text over before it goes anywhere.
///
/// The pasteboard is a bad workbench: every intermediate step overwrites the
/// thing being worked on. This holds one page that stays as it was left, so
/// text can be pasted in, reshaped, and copied back out when it says what it
/// should.
@MainActor
final class ScratchPadPanelController: NSObject, ShortyBoxContent, NSTextViewDelegate {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 10
        static let topPadding: CGFloat = 9
        static let bottomPadding: CGFloat = 10
        static let headerSpacing: CGFloat = 6
        static let fontSize: CGFloat = 14
        static let textInset = NSSize(width: 8, height: 8)
    }

    private let box: ShortyBoxController
    private let store: ScratchPadStore
    private let contentView = NSView()
    private let header = ShortyBoxHeaderView()
    private let scrollView = ShortyScrollView()
    private let textView = NSTextView()
    /// What the footer says, which is the only place the keys are written
    /// down: the pad has no rows to hint with.
    private let footer = NSTextField(labelWithString: "")
    /// Set while copying out, so the pasteboard poll's own recording is not
    /// mistaken for a change made here.
    var copyHandler: ((String) -> Void)?

    init(box: ShortyBoxController, store: ScratchPadStore = ScratchPadStore()) {
        self.box = box
        self.store = store
        super.init()

        configure()
    }

    /// Adds text to the pad, after what is already there.
    ///
    /// A blank line between, so two things sent over do not run together.
    func append(_ text: String) {
        let existing = store.text()
        store.setText(existing.isEmpty ? text : existing + "\n\n" + text)
    }

    // MARK: ShortyBoxContent

    var view: NSView {
        contentView
    }

    func boxWillPresent() {
        textView.string = store.text()
    }

    func boxDidPresent(in window: NSWindow) {
        window.makeFirstResponder(textView)
        // At the end, where writing continues from, rather than selecting
        // everything and making the first keystroke a deletion.
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        updateFooter()
    }

    func boxPerformsKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard event.keyCode == UInt16(kVK_Return) else {
            return false
        }

        // The box's own convention: `cmd+return` sends what is here
        // somewhere else, which for a pad means the pasteboard.
        if flags == .command {
            copyOut(selectionOnly: false)
            return true
        }

        // A selection is a smaller piece of the same gesture: copy just the
        // part that is wanted.
        if flags == [.command, .shift] {
            copyOut(selectionOnly: true)
            return true
        }

        return false
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            box.handleEscape()
            return true
        }

        return false
    }

    /// Escape leaves the pad as it is rather than clearing it: the text is
    /// the work, and losing it to a mistaken keystroke would be the one
    /// unforgivable thing here.
    func boxHandlesEscape() -> Bool {
        save()
        return false
    }

    func boxDidDismiss() {
        save()
    }

    // MARK: Editing

    func textDidChange(_ notification: Notification) {
        updateFooter()
        save()
    }

    private func save() {
        store.setText(textView.string)
    }

    private func copyOut(selectionOnly: Bool) {
        let selected = textView.selectedRange()
        let text = selectionOnly && selected.length > 0
            ? (textView.string as NSString).substring(with: selected)
            : textView.string

        guard !text.isEmpty else {
            return
        }

        save()
        copyHandler?(text)
        box.close()
    }

    // MARK: Layout

    private func configure() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        header.update(title: "Scratch Pad", symbolName: "square.and.pencil")
        // The header's field is there to be typed into elsewhere; here the
        // typing happens below it, so it only names the place.
        header.searchField.isEditable = false
        header.searchField.isSelectable = false

        configureTextView()

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        [header, scrollView, footer].forEach(contentView.addSubview)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Metrics.topPadding),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Metrics.horizontalPadding),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Metrics.horizontalPadding),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.headerSpacing),
            scrollView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: header.trailingAnchor),

            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Metrics.headerSpacing),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Metrics.bottomPadding),
        ])
    }

    private func configureTextView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        textView.delegate = self
        textView.font = .monospacedSystemFont(ofSize: Metrics.fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        // Plain text throughout: what comes out should paste as itself and
        // not carry the formatting of wherever it came from.
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = Metrics.textInset
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
    }

    private func updateFooter() {
        let text = textView.string
        let characters = text.count
        let words = ClipboardItemDetailBuilder.wordCount(in: text)
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count

        footer.stringValue = "\(lines) lines · \(words) words · \(characters) characters"
            + "    ⌘↩ copy all    ⇧⌘↩ copy selection    esc keep and close"
    }
}
