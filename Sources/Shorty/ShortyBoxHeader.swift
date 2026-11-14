import AppKit

/// The top strip of the box: an icon and the search field, whose placeholder
/// names what is on screen. Both the command box and the clipboard picker use
/// it, so they look like one tool, and the name follows where you are:
/// Command, Clipboard History, or Time once you step into a group.
@MainActor
final class ShortyBoxHeaderView: NSView {
    enum Metrics {
        static let height: CGFloat = 38
        static let horizontalPadding: CGFloat = 12
        static let iconSize: CGFloat = 16
        static let iconSpacing: CGFloat = 8
        static let fontSize: CGFloat = 17
    }

    let searchField: ShortyBoxSearchField

    private let iconView = NSImageView()

    init(searchField: ShortyBoxSearchField = ShortyBoxSearchField(frame: .zero)) {
        self.searchField = searchField
        super.init(frame: .zero)

        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// `symbolName` is an SF Symbol, so the icon matches the system's weight.
    func update(title: String, symbolName: String) {
        searchField.placeholderString = title
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: title
        )
        iconView.contentTintColor = .secondaryLabelColor
    }

    private func configure() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = .systemFont(ofSize: Metrics.fontSize)
        searchField.cell?.font = searchField.font
        searchField.textColor = .labelColor
        searchField.drawsBackground = false
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.focusRingType = .none

        addSubview(iconView)
        addSubview(searchField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

            searchField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Metrics.iconSpacing),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

@MainActor
final class ShortyBoxSearchField: NSTextField {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }

        super.keyDown(with: event)
    }
}
