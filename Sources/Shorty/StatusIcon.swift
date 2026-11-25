import AppKit

/// The menu bar cup: empty, or full with steam rising off it, and with a
/// warning triangle in its corner while the config fails to load.
///
/// The cup is `CupGlyph`, the same drawing as the app icon. Both states use
/// the same canvas, and the glyph keeps the steam's room when empty, so the
/// cup sits still when the state changes. That room alone left the empty cup
/// low in the bar, so half as much again goes under it: the empty cup sits
/// a little low and the full one a little high, rather than either by a lot.
enum StatusIcon {
    private enum Metrics {
        /// Chosen so the canvas, room underneath included, fits a 22pt bar.
        static let glyphHeight: CGFloat = 17
        static let padding: CGFloat = 1
        static let bottomRoom = glyphHeight * CupGlyph.steamRoomFraction / 2
        static let badgePointSize: CGFloat = 9
        /// Clear space cut around the badge so it does not merge with the cup.
        static let badgeHalo: CGFloat = 1.2
    }

    static func cup(filled: Bool, warning: Bool = false) -> NSImage {
        let glyph = NSSize(width: Metrics.glyphHeight * CupGlyph.aspectRatio, height: Metrics.glyphHeight)
        let canvas = NSSize(
            width: glyph.width + Metrics.padding * 2,
            height: glyph.height + Metrics.bottomRoom + Metrics.padding * 2
        )

        // Drawn on demand, so it renders sharp at the screen's scale.
        let image = NSImage(size: canvas, flipped: false) { _ in
            CupGlyph.draw(
                in: NSRect(origin: NSPoint(x: Metrics.padding, y: Metrics.padding + Metrics.bottomRoom), size: glyph),
                filled: filled,
                color: .black
            )
            if warning {
                drawBadge(in: canvas)
            }
            return true
        }

        // Template, so the menu bar tints it for light and dark alike.
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(filled: filled, warning: warning)
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

        // Level with the saucer rather than the canvas, whose bottom is the
        // empty room under the cup.
        let badgeRect = NSRect(
            x: canvas.width - badge.size.width,
            y: Metrics.bottomRoom,
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
}
