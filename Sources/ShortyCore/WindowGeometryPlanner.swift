import CoreGraphics
import Foundation

public enum WindowHalf: Sendable {
    case left
    case right
}

public enum WindowMoveDirection: Equatable, Sendable {
    case left
    case right
}

public enum WindowGeometryPlanner {
    public static let defaultTolerance: CGFloat = 12

    public static func halfFrame(on screen: CGRect, half: WindowHalf) -> CGRect {
        let screen = screen.standardized
        let width = screen.width / 2

        switch half {
        case .left:
            return CGRect(x: screen.minX, y: screen.minY, width: width, height: screen.height)
        case .right:
            return CGRect(x: screen.midX, y: screen.minY, width: width, height: screen.height)
        }
    }

    /// Grows or shrinks a window by a share of its display, keeping it where
    /// it is on screen. Returns nil when there is nowhere left to go, so a
    /// window already filling the screen says so rather than appearing to
    /// refuse the change.
    public static func resizedFrame(
        for windowFrame: CGRect,
        screens: [CGRect],
        by step: CGFloat,
        minimumRatio: CGFloat = 0.2
    ) -> CGRect? {
        let screens = orderedScreens(screens)

        guard let index = screenIndex(containing: windowFrame, screens: screens) else {
            return nil
        }

        let screen = screens[index]
        let windowFrame = windowFrame.standardized

        let minimum = CGSize(
            width: screen.width * minimumRatio,
            height: screen.height * minimumRatio
        )
        let size = CGSize(
            width: min(max(windowFrame.width + screen.width * step, minimum.width), screen.width),
            height: min(max(windowFrame.height + screen.height * step, minimum.height), screen.height)
        )

        guard !isApproximately(size, windowFrame.size) else {
            return nil
        }

        // Grow around the middle of the window, then nudge back inside the
        // screen rather than letting an edge slide off it.
        let centred = CGRect(
            x: windowFrame.midX - size.width / 2,
            y: windowFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        return CGRect(
            origin: fittingOrigin(for: centred, actualSize: size, screens: [screen]),
            size: size
        )
    }

    public static func maximizeFrame(on screen: CGRect) -> CGRect {
        screen.standardized
    }

    /// Maximize with a margin left around it, so what is behind stays in
    /// sight. Rounded to whole points: a window placed on a half point is a
    /// window drawn blurry.
    public static func almostMaximizeFrame(on screen: CGRect, share: CGFloat = almostMaximizeShare) -> CGRect {
        let screen = screen.standardized
        let size = CGSize(
            width: (screen.width * share).rounded(),
            height: (screen.height * share).rounded()
        )

        return CGRect(
            x: (screen.midX - size.width / 2).rounded(),
            y: (screen.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    /// Lays windows out in a stack, each one down and right of the last, so
    /// every title bar stays in sight.
    ///
    /// Sizes are kept as they are, only clamped to the display: a window is
    /// whatever size its owner wants it. The step shrinks to whatever makes
    /// them all fit, so twenty windows stack tighter than three rather than
    /// marching off the screen.
    ///
    /// The order given is the order laid out, so the last one ends up at the
    /// front of the stack.
    public static func cascadeFrames(
        sizes: [CGSize],
        on screen: CGRect,
        step: CGFloat = cascadeStep,
        from anchor: CGPoint? = nil
    ) -> [CGRect] {
        let fullScreen = screen.standardized

        guard !sizes.isEmpty else {
            return []
        }

        // A pinned window is the corner the rest flow out of, so the stack
        // lives in what is left below and to the right of it. Pinned near the
        // bottom right there would be nothing left, so the corner is pulled
        // back far enough to leave the stack a usable share of the display.
        let screen: CGRect

        if let anchor {
            let widest = min(fullScreen.width * maximumAnchorOffset, max(0, anchor.x - fullScreen.minX))
            let tallest = min(fullScreen.height * maximumAnchorOffset, max(0, anchor.y - fullScreen.minY))

            screen = CGRect(
                x: fullScreen.minX + widest,
                y: fullScreen.minY + tallest,
                width: fullScreen.width - widest,
                height: fullScreen.height - tallest
            )
        } else {
            screen = fullScreen
        }

        let steps = CGFloat(max(1, sizes.count - 1))

        // How far the stack reaches. Windows are usually as tall as the
        // display, which leaves no room to step down: rather than pile them
        // all along the top, the stack claims its share of the screen and the
        // windows are trimmed to what is left.
        let spread = CGSize(
            width: min(step * steps, screen.width * maximumCascadeSpread),
            height: min(step * steps, screen.height * maximumCascadeSpread)
        )
        let room = CGSize(width: screen.width - spread.width, height: screen.height - spread.height)
        // A window smaller than the room it is given keeps its size.
        let clamped = sizes.map {
            CGSize(width: min($0.width, room.width), height: min($0.height, room.height))
        }
        let horizontal = spread.width / steps
        let vertical = spread.height / steps

        return clamped.enumerated().map { index, size in
            let offset = CGFloat(index)

            // Rounded for a crisp window, then held inside the display: a
            // fraction of a point per step adds up to the last one hanging
            // off the edge.
            return CGRect(
                x: min((screen.minX + offset * horizontal).rounded(), screen.maxX - size.width),
                y: min((screen.minY + offset * vertical).rounded(), screen.maxY - size.height),
                width: size.width,
                height: size.height
            )
        }
    }

    /// Far enough apart that a title bar and a window's edge both show.
    public static let cascadeStep: CGFloat = 32
    /// At most this much of the display goes to the stack itself, so the
    /// windows stay big enough to work in however many there are.
    public static let maximumCascadeSpread: CGFloat = 0.35
    /// How far into the display a pinned window may push the stack's corner.
    /// Beyond this there is not enough room left to stack anything in.
    public static let maximumAnchorOffset: CGFloat = 0.3

    /// How much of the display "almost" is.
    public static let almostMaximizeShare: CGFloat = 0.9

    public static func accessibilityFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        displayBounds: CGRect
    ) -> CGRect {
        let screenFrame = screenFrame.standardized
        let visibleFrame = visibleFrame.standardized
        let displayBounds = displayBounds.standardized

        return CGRect(
            x: displayBounds.minX + (visibleFrame.minX - screenFrame.minX),
            y: displayBounds.minY + (screenFrame.maxY - visibleFrame.maxY),
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    public static func halfCycleFrame(
        for windowFrame: CGRect,
        screens: [CGRect],
        direction: WindowMoveDirection,
        tolerance: CGFloat = defaultTolerance
    ) -> CGRect? {
        let screens = orderedScreens(screens)
        guard let currentIndex = screenIndex(containing: windowFrame, screens: screens) else {
            return nil
        }

        let currentScreen = screens[currentIndex]
        let targetHalf: WindowHalf = direction == .left ? .left : .right
        let targetFrame = halfFrame(on: currentScreen, half: targetHalf)

        guard isApproximately(windowFrame, targetFrame, tolerance: tolerance) ||
            isApproximatelyAnchored(windowFrame, to: targetHalf, on: currentScreen, tolerance: tolerance) else {
            return targetFrame
        }

        switch direction {
        case .left:
            let destinationIndex = currentIndex > 0 ? currentIndex - 1 : screens.count - 1
            return halfFrame(on: screens[destinationIndex], half: .right)
        case .right:
            let destinationIndex = currentIndex < screens.count - 1 ? currentIndex + 1 : 0
            return halfFrame(on: screens[destinationIndex], half: .left)
        }
    }

    public static func monitorMoveFrame(
        for windowFrame: CGRect,
        screens: [CGRect],
        direction: WindowMoveDirection
    ) -> CGRect? {
        let screens = orderedScreens(screens)
        guard screens.count > 1, let currentIndex = screenIndex(containing: windowFrame, screens: screens) else {
            return nil
        }

        let destinationIndex: Int
        switch direction {
        case .left:
            destinationIndex = currentIndex > 0 ? currentIndex - 1 : screens.count - 1
        case .right:
            destinationIndex = currentIndex < screens.count - 1 ? currentIndex + 1 : 0
        }

        return proportionalFrame(
            windowFrame.standardized,
            from: screens[currentIndex],
            to: screens[destinationIndex]
        )
    }

    public static func screenIndex(containing windowFrame: CGRect, screens: [CGRect]) -> Int? {
        let windowFrame = windowFrame.standardized
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)

        if let centerIndex = screens.firstIndex(where: { $0.standardized.contains(center) }) {
            return centerIndex
        }

        return screens
            .enumerated()
            .map { index, screen in
                (index: index, area: intersectionArea(windowFrame, screen.standardized))
            }
            .filter { $0.area > 0 }
            .max { $0.area < $1.area }?
            .index
    }

    public static func orderedScreens(_ screens: [CGRect]) -> [CGRect] {
        screens.map(\.standardized).sorted { first, second in
            if first.minX == second.minX {
                return first.minY < second.minY
            }

            return first.minX < second.minX
        }
    }

    public static func isApproximately(
        _ frame: CGRect,
        _ target: CGRect,
        tolerance: CGFloat = defaultTolerance
    ) -> Bool {
        let frame = frame.standardized
        let target = target.standardized

        return abs(frame.minX - target.minX) <= tolerance &&
            abs(frame.minY - target.minY) <= tolerance &&
            abs(frame.width - target.width) <= tolerance &&
            abs(frame.height - target.height) <= tolerance
    }

    public static func isApproximately(
        _ size: CGSize,
        _ target: CGSize,
        tolerance: CGFloat = defaultTolerance
    ) -> Bool {
        abs(size.width - target.width) <= tolerance &&
            abs(size.height - target.height) <= tolerance
    }

    public static func isApproximately(
        _ point: CGPoint,
        _ target: CGPoint,
        tolerance: CGFloat = defaultTolerance
    ) -> Bool {
        abs(point.x - target.x) <= tolerance &&
            abs(point.y - target.y) <= tolerance
    }

    public static func fittingOrigin(
        for targetFrame: CGRect,
        actualSize: CGSize,
        screens: [CGRect]
    ) -> CGPoint {
        let screens = orderedScreens(screens)
        guard let screenIndex = screenIndex(containing: targetFrame, screens: screens) else {
            return targetFrame.standardized.origin
        }

        let targetFrame = targetFrame.standardized
        let screen = screens[screenIndex]

        return CGPoint(
            x: clamp(
                targetFrame.minX,
                min: screen.minX,
                max: screen.maxX - actualSize.width
            ),
            y: clamp(
                targetFrame.minY,
                min: screen.minY,
                max: screen.maxY - actualSize.height
            )
        )
    }

    private static func proportionalFrame(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        let source = source.standardized
        let destination = destination.standardized

        let widthRatio = source.width == 0 ? 1 : frame.width / source.width
        let heightRatio = source.height == 0 ? 1 : frame.height / source.height
        let xRatio = source.width == 0 ? 0 : (frame.minX - source.minX) / source.width
        let yRatio = source.height == 0 ? 0 : (frame.minY - source.minY) / source.height

        let width = min(destination.width, destination.width * widthRatio)
        let height = min(destination.height, destination.height * heightRatio)
        let x = clamp(
            destination.minX + destination.width * xRatio,
            min: destination.minX,
            max: destination.maxX - width
        )
        let y = clamp(
            destination.minY + destination.height * yRatio,
            min: destination.minY,
            max: destination.maxY - height
        )

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func isApproximatelyAnchored(
        _ frame: CGRect,
        to half: WindowHalf,
        on screen: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        let frame = frame.standardized
        let screen = screen.standardized
        let target = halfFrame(on: screen, half: half)

        guard frame.width > target.width + tolerance,
              frame.width < screen.width - tolerance,
              abs(frame.minY - screen.minY) <= tolerance,
              abs(frame.height - screen.height) <= tolerance else {
            return false
        }

        switch half {
        case .left:
            return abs(frame.minX - screen.minX) <= tolerance
        case .right:
            return abs(frame.maxX - screen.maxX) <= tolerance
        }
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else {
            return 0
        }

        return intersection.width * intersection.height
    }

    private static func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        guard maximum >= minimum else {
            return minimum
        }

        return Swift.min(Swift.max(value, minimum), maximum)
    }
}
