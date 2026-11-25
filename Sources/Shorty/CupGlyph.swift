import AppKit

/// The Shorty cup, drawn once for both the menu bar and the app icon so the
/// two always match. `Packaging/make-icon.sh` compiles this file into the
/// icon generator.
///
/// It is drawn from paths rather than taken from SF Symbols, whose licence
/// does not allow them in app icons.
///
/// Gaps between the parts are cut out of whatever is already drawn, so draw
/// it onto a clear layer: an image, then composite that where it belongs.
enum CupGlyph {
    /// The design space the paths below are written in.
    static let designBounds = NSRect(x: 230, y: 256, width: 564, height: 570)

    /// The design space's aspect ratio, for sizing a canvas to hold the cup.
    static var aspectRatio: CGFloat { designBounds.width / designBounds.height }

    /// How much of the glyph's height, at the top, is only there for the steam.
    static var steamRoomFraction: CGFloat {
        (designBounds.maxY - (rimY + rimDepth / 2)) / designBounds.height
    }

    private static let rimY: CGFloat = 590
    private static let rimLeft: CGFloat = 300
    private static let rimRight: CGFloat = 664
    private static let rimDepth: CGFloat = 84
    private static let base: CGFloat = 330
    /// Clear space around the body, parting it from the handle and saucer.
    private static let halo: CGFloat = 26

    /// Draws the cup into `rect`, which should have the glyph's aspect ratio.
    /// Full, the cup holds coffee and steams; empty, its opening is clear.
    /// The steam's room is kept either way, so the cup does not move.
    static func draw(in rect: NSRect, filled: Bool, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / designBounds.width, yBy: rect.height / designBounds.height)
        transform.translateX(by: -designBounds.minX, yBy: -designBounds.minY)
        transform.concat()

        color.setFill()
        color.setStroke()

        NSBezierPath(roundedRect: NSRect(x: 252, y: 262, width: 520, height: 44), xRadius: 22, yRadius: 22).fill()

        let handle = handlePath()
        handle.lineWidth = 48
        handle.stroke()

        let body = bodyPath()
        body.lineWidth = halo * 2
        cut { body.stroke() }
        body.fill()

        // The opening, leaving the rim as a ring, and the coffee inside it.
        let coffee = NSRect(
            x: rimLeft + 36,
            y: rimY - rimDepth / 2 + 18,
            width: rimRight - rimLeft - 72,
            height: rimDepth - 36
        )
        cut { NSBezierPath(ovalIn: coffee.insetBy(dx: -20, dy: -12)).fill() }

        if filled {
            NSBezierPath(ovalIn: coffee).fill()
            steam().stroke()
        }
    }

    /// Runs `paint` as an eraser over what is already drawn.
    private static func cut(_ paint: () -> Void) {
        guard let context = NSGraphicsContext.current else { return }
        let previous = context.compositingOperation
        context.compositingOperation = .destinationOut
        paint()
        context.compositingOperation = previous
    }

    private static func handlePath() -> NSBezierPath {
        let handle = NSBezierPath()
        handle.lineCapStyle = .round
        handle.move(to: NSPoint(x: rimRight - 40, y: 530))
        handle.curve(
            to: NSPoint(x: rimRight - 70, y: 380),
            controlPoint1: NSPoint(x: 810, y: 560),
            controlPoint2: NSPoint(x: 810, y: 360)
        )
        return handle
    }

    /// The body narrows to the base, and its rim is an ellipse so the coffee
    /// reads as seen from slightly above.
    private static func bodyPath() -> NSBezierPath {
        let body = NSBezierPath()
        body.move(to: NSPoint(x: rimLeft, y: rimY))
        body.curve(
            to: NSPoint(x: 420, y: base),
            controlPoint1: NSPoint(x: rimLeft, y: 420),
            controlPoint2: NSPoint(x: 340, y: base)
        )
        body.line(to: NSPoint(x: 544, y: base))
        body.curve(
            to: NSPoint(x: rimRight, y: rimY),
            controlPoint1: NSPoint(x: 624, y: base),
            controlPoint2: NSPoint(x: rimRight, y: 420)
        )
        body.appendOval(in: NSRect(x: rimLeft, y: rimY - rimDepth / 2, width: rimRight - rimLeft, height: rimDepth))
        body.windingRule = .nonZero
        return body
    }

    /// Three short straight rays fanned above the coffee.
    private static func steam() -> NSBezierPath {
        let centre = NSPoint(x: (rimLeft + rimRight) / 2, y: rimY)
        let spread = CGFloat.pi * 0.36
        let inner: CGFloat = 120
        let outer: CGFloat = 215

        let rays = NSBezierPath()
        rays.lineWidth = 32
        rays.lineCapStyle = .round

        for index in 0..<3 {
            let angle = .pi / 2 - spread / 2 + spread * CGFloat(index) / 2
            rays.move(to: NSPoint(x: centre.x + cos(angle) * inner, y: centre.y + sin(angle) * inner))
            rays.line(to: NSPoint(x: centre.x + cos(angle) * outer, y: centre.y + sin(angle) * outer))
        }
        return rays
    }
}
