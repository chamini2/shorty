import AppKit

/// The menu bar cup: empty, or full with steam rising off it, and with a
/// warning triangle in its corner while the config fails to load.
///
/// `cup.and.saucer.fill` is a solid cup with its opening knocked out, so
/// filling that opening reads as coffee seen from above. SF Symbols has no
/// variable value for the cup, which would otherwise give a fill level.
///
/// Both states are drawn on the same canvas, with the cup in the same place
/// and room above it for the steam. Returning the bare symbol for one state
/// and a redrawn image for the other shifted the icon by a few pixels, since
/// rasterising loses the symbol's own alignment.
enum StatusIcon {
    private enum Metrics {
        static let pointSize: CGFloat = 14
        /// Room for the steam, and the same margin on every side so the cup
        /// sits still when the state changes.
        static let padding: CGFloat = 3
        static let rayCount = 3
        static let rayLength: CGFloat = 3
        static let rayGap: CGFloat = 1
        static let rayWidth: CGFloat = 1.3
        /// How wide the steam fans out, centred on straight up.
        static let raySpread = CGFloat.pi * 0.35
        static let badgePointSize: CGFloat = 9
        /// Clear space cut around the badge so it does not merge with the cup.
        static let badgeHalo: CGFloat = 1.2
    }

    /// Where the opening sits inside the symbol, measured from the rendered
    /// image rather than guessed, as fractions of its size.
    private enum Opening {
        static let minX: CGFloat = 0.271
        static let maxX: CGFloat = 0.724
        static let minY: CGFloat = 0.656
        static let maxY: CGFloat = 0.863
    }

    static func cup(filled: Bool, warning: Bool = false) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.pointSize, weight: .regular)

        guard let cup = NSImage(
            systemSymbolName: "cup.and.saucer.fill",
            accessibilityDescription: accessibilityDescription(filled: filled, warning: warning)
        )?.withSymbolConfiguration(configuration) else {
            return nil
        }

        let canvas = NSSize(
            width: cup.size.width + Metrics.padding * 2,
            height: cup.size.height + Metrics.padding * 2
        )
        let cupRect = NSRect(
            x: Metrics.padding,
            y: Metrics.padding,
            width: cup.size.width,
            height: cup.size.height
        )

        let image = NSImage(size: canvas)
        image.lockFocus()
        cup.draw(in: cupRect)

        if filled {
            let opening = NSRect(
                x: cupRect.minX + cupRect.width * Opening.minX,
                y: cupRect.minY + cupRect.height * Opening.minY,
                width: cupRect.width * (Opening.maxX - Opening.minX),
                height: cupRect.height * (Opening.maxY - Opening.minY)
            )

            NSColor.black.setFill()
            NSBezierPath(ovalIn: opening).fill()
            steam(above: opening).stroke()
        }

        if warning {
            drawBadge(in: canvas)
        }

        image.unlockFocus()

        // Template, so the menu bar tints it for light and dark alike.
        image.isTemplate = true
        return image
    }

    private static func accessibilityDescription(filled: Bool, warning: Bool) -> String {
        switch (filled, warning) {
        case (_, true): return "Shorty, config failed to load"
        case (true, false): return "Shorty, keeping the Mac awake"
        case (false, false): return "Shorty"
        }
    }

    /// A warning triangle in the bottom-right corner, over the saucer, with
    /// the cup cleared away around it. Template like the rest, since the
    /// menu bar only tints template images for its appearance.
    private static func drawBadge(in canvas: NSSize) {
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.badgePointSize, weight: .bold)

        guard let badge = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration) else {
            return
        }

        let badgeRect = NSRect(
            x: canvas.width - badge.size.width,
            y: 0,
            width: badge.size.width,
            height: badge.size.height
        )

        // The badge's own silhouette, grown by the halo, punched out of the cup.
        for dx in [-Metrics.badgeHalo, 0, Metrics.badgeHalo] {
            for dy in [-Metrics.badgeHalo, 0, Metrics.badgeHalo] {
                badge.draw(
                    in: badgeRect.offsetBy(dx: dx, dy: dy),
                    from: .zero,
                    operation: .destinationOut,
                    fraction: 1
                )
            }
        }

        badge.draw(in: badgeRect)
    }

    private static func steam(above opening: NSRect) -> NSBezierPath {
        let centre = NSPoint(x: opening.midX, y: opening.midY)
        let radius = NSPoint(x: opening.width / 2, y: opening.height / 2)

        let path = NSBezierPath()
        path.lineWidth = Metrics.rayWidth
        path.lineCapStyle = .round

        for index in 0..<Metrics.rayCount {
            let step = CGFloat(index) / CGFloat(max(1, Metrics.rayCount - 1))
            let angle = .pi / 2 - Metrics.raySpread / 2 + Metrics.raySpread * step
            let inner = Metrics.rayGap
            let outer = Metrics.rayGap + Metrics.rayLength

            path.move(
                to: NSPoint(
                    x: centre.x + cos(angle) * (radius.x + inner),
                    y: centre.y + sin(angle) * (radius.y + inner)
                )
            )
            path.line(
                to: NSPoint(
                    x: centre.x + cos(angle) * (radius.x + outer),
                    y: centre.y + sin(angle) * (radius.y + outer)
                )
            )
        }

        NSColor.black.setStroke()
        return path
    }
}
