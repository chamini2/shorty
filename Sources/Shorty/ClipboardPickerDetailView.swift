import AppKit
import ShortyCore

/// Right-hand pane of the clipboard picker: full contents on top, an
/// `Information` table underneath.
@MainActor
final class ClipboardPickerDetailView: NSView {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 12
        static let bodyFontSize: CGFloat = 12
        static let rowFontSize: CGFloat = 11.5
        static let rowHeight: CGFloat = 26
        static let rowSpacing: CGFloat = 2
        static let sectionTitleSpacing: CGFloat = 6
        static let sectionTopSpacing: CGFloat = 14
        static let rowCornerRadius: CGFloat = 5
        static let rowInset: CGFloat = 8
        static let iconSize: CGFloat = 15
        static let iconSpacing: CGFloat = 6
    }

    private let bodyScrollView = NSScrollView()
    private let bodyTextView = NSTextView()
    private let sectionTitleLabel = NSTextField(labelWithString: "Information")
    private let rowsStackView = NSStackView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private var iconCache: [String: NSImage] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(with detail: ClipboardItemDetail?) {
        guard let detail else {
            bodyScrollView.isHidden = true
            sectionTitleLabel.isHidden = true
            rowsStackView.isHidden = true
            placeholderLabel.isHidden = false
            return
        }

        placeholderLabel.isHidden = true
        bodyScrollView.isHidden = detail.body.isEmpty
        sectionTitleLabel.isHidden = false
        rowsStackView.isHidden = false

        bodyTextView.string = detail.body
        bodyTextView.scrollToBeginningOfDocument(nil)

        rowsStackView.arrangedSubviews.forEach { view in
            rowsStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, row) in detail.rows.enumerated() {
            let icon = row.label == "Source" ? applicationIcon(for: detail.sourceBundleID) : nil
            let rowView = makeRowView(row: row, icon: icon, isEven: index.isMultiple(of: 2))
            rowsStackView.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: rowsStackView.widthAnchor).isActive = true
        }
    }

    private func configure() {
        wantsLayer = true

        bodyTextView.isEditable = false
        bodyTextView.isSelectable = true
        bodyTextView.drawsBackground = false
        bodyTextView.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        bodyTextView.font = NSFont.monospacedSystemFont(ofSize: Metrics.bodyFontSize, weight: .regular)
        bodyTextView.textContainerInset = NSSize(width: 0, height: 0)
        bodyTextView.isVerticallyResizable = true
        bodyTextView.isHorizontallyResizable = false
        bodyTextView.textContainer?.widthTracksTextView = true

        bodyScrollView.translatesAutoresizingMaskIntoConstraints = false
        bodyScrollView.documentView = bodyTextView
        bodyScrollView.drawsBackground = false
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.autohidesScrollers = true
        bodyScrollView.horizontalScrollElasticity = .none
        bodyScrollView.borderType = .noBorder

        sectionTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        sectionTitleLabel.font = .systemFont(ofSize: Metrics.rowFontSize, weight: .semibold)
        sectionTitleLabel.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)

        rowsStackView.translatesAutoresizingMaskIntoConstraints = false
        rowsStackView.orientation = .vertical
        rowsStackView.alignment = .leading
        rowsStackView.distribution = .fill
        rowsStackView.spacing = Metrics.rowSpacing

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .systemFont(ofSize: Metrics.rowFontSize)
        placeholderLabel.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
        placeholderLabel.stringValue = "No selection"
        placeholderLabel.isHidden = true

        addSubview(bodyScrollView)
        addSubview(sectionTitleLabel)
        addSubview(rowsStackView)
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            bodyScrollView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalPadding),
            bodyScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            bodyScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),

            sectionTitleLabel.topAnchor.constraint(
                equalTo: bodyScrollView.bottomAnchor,
                constant: Metrics.sectionTopSpacing
            ),
            sectionTitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),

            rowsStackView.topAnchor.constraint(
                equalTo: sectionTitleLabel.bottomAnchor,
                constant: Metrics.sectionTitleSpacing
            ),
            rowsStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            rowsStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
            rowsStackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.verticalPadding),

            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func makeRowView(row: ClipboardDetailRow, icon: NSImage?, isEven: Bool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = Metrics.rowCornerRadius
        container.layer?.backgroundColor = isEven
            ? NSColor(calibratedWhite: 1, alpha: 0.05).cgColor
            : NSColor.clear.cgColor

        let labelField = NSTextField(labelWithString: row.label)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.font = .systemFont(ofSize: Metrics.rowFontSize)
        labelField.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)

        let valueField = NSTextField(labelWithString: row.value)
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.font = .systemFont(ofSize: Metrics.rowFontSize)
        valueField.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingTail
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addSubview(labelField)
        container.addSubview(valueField)

        var constraints: [NSLayoutConstraint] = [
            container.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),
            labelField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.rowInset),
            labelField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            valueField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.rowInset),
            valueField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ]

        if let icon {
            let iconView = NSImageView(image: icon)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyUpOrDown
            container.addSubview(iconView)

            constraints += [
                iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
                iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
                iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                iconView.trailingAnchor.constraint(
                    equalTo: valueField.leadingAnchor,
                    constant: -Metrics.iconSpacing
                ),
                iconView.leadingAnchor.constraint(
                    greaterThanOrEqualTo: labelField.trailingAnchor,
                    constant: Metrics.iconSpacing
                ),
            ]
        } else {
            constraints.append(
                valueField.leadingAnchor.constraint(
                    greaterThanOrEqualTo: labelField.trailingAnchor,
                    constant: Metrics.iconSpacing
                )
            )
        }

        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func applicationIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID else {
            return nil
        }

        if let cached = iconCache[bundleID] {
            return cached
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: Metrics.iconSize, height: Metrics.iconSize)
        iconCache[bundleID] = icon
        return icon
    }
}
