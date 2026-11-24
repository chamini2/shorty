import AppKit
import ShortyCore

/// The card a social site would unfurl for a link: the page's picture beside
/// its site, title and summary.
@MainActor
final class LinkPreviewCardView: NSView {
    private enum Metrics {
        static let cornerRadius: CGFloat = 8
        static let imageWidth: CGFloat = 152
        static let textInset: CGFloat = 10
        static let textSpacing: CGFloat = 3
        static let siteFontSize: CGFloat = 10.5
        static let titleFontSize: CGFloat = 13
        static let summaryFontSize: CGFloat = 11.5
        static let titleLineLimit = 2
        static let summaryLineLimit = 3
    }

    init(card: LinkCard, image: NSImage?) {
        super.init(frame: .zero)
        configure(card: card, image: image)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure(card: LinkCard, image: NSImage?) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.04).cgColor

        let text = NSStackView()
        text.translatesAutoresizingMaskIntoConstraints = false
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.textSpacing
        text.setHuggingPriority(.defaultLow, for: .horizontal)

        if let site = card.siteName, !site.isEmpty {
            text.addArrangedSubview(label(
                site,
                size: Metrics.siteFontSize,
                weight: .medium,
                colour: .tertiaryLabelColor,
                lines: 1
            ))
        }

        if let title = card.title, !title.isEmpty {
            text.addArrangedSubview(label(
                title,
                size: Metrics.titleFontSize,
                weight: .semibold,
                colour: .labelColor,
                lines: Metrics.titleLineLimit
            ))
        }

        if let summary = card.summary, !summary.isEmpty {
            text.addArrangedSubview(label(
                summary,
                size: Metrics.summaryFontSize,
                weight: .regular,
                colour: .secondaryLabelColor,
                lines: Metrics.summaryLineLimit
            ))
        }

        addSubview(text)
        var constraints = [
            // Centred, not pinned to the top: a page with nothing but a title
            // would otherwise sit above a block of empty card.
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Metrics.textInset),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Metrics.textInset),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.textInset),
        ]

        if let image {
            let pictureView = FittedImageView(image: image)
            pictureView.translatesAutoresizingMaskIntoConstraints = false

            // A page's picture is whatever size it likes; the card says how
            // much room it gets, never the other way around.
            for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                pictureView.setContentCompressionResistancePriority(.defaultLow, for: axis)
                pictureView.setContentHuggingPriority(.defaultLow, for: axis)
            }

            addSubview(pictureView)

            constraints += [
                pictureView.topAnchor.constraint(equalTo: topAnchor),
                pictureView.bottomAnchor.constraint(equalTo: bottomAnchor),
                pictureView.leadingAnchor.constraint(equalTo: leadingAnchor),
                pictureView.widthAnchor.constraint(equalToConstant: Metrics.imageWidth),
                text.leadingAnchor.constraint(
                    equalTo: pictureView.trailingAnchor,
                    constant: Metrics.textInset
                ),
            ]
        } else {
            constraints.append(
                text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.textInset)
            )
        }

        NSLayoutConstraint.activate(constraints)
    }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        colour: NSColor,
        lines: Int
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = colour
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = lines
        field.cell?.wraps = lines > 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return field
    }
}

/// Draws a picture inside its frame, whole and centred. Social art is a wide
/// banner and this column is not: cropping it to fill would zoom into the
/// middle of the picture and lose what it says.
@MainActor
private final class FittedImageView: NSView {
    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = image.size

        guard size.width > 0, size.height > 0, !bounds.isEmpty else {
            return
        }

        // Never past its own size: a favicon blown up to fill the column
        // would only be a blur of itself.
        let scale = min(min(bounds.width / size.width, bounds.height / size.height), 1)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)

        image.draw(
            in: NSRect(
                x: bounds.midX - drawn.width / 2,
                y: bounds.midY - drawn.height / 2,
                width: drawn.width,
                height: drawn.height
            )
        )
    }
}
