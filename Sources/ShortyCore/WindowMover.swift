import AppKit
@preconcurrency import ApplicationServices
import Foundation

public enum WindowMoveCommand: Equatable, Sendable {
    case cycleHalf(WindowMoveDirection)
    case maximize
    /// Maximize but leave a margin, so the window still reads as a window.
    case almostMaximize
    case moveToMonitor(WindowMoveDirection)
    /// Grow or shrink by a share of the display.
    case resize(CGFloat)
    /// Put the window back where it was before Shorty first moved it.
    case restore
    /// Lay the windows out in a stack, each one down and right of the last.
    case cascade(WindowCascadeScope)
}

/// Accessibility elements are CoreFoundation types: equal and hashable through
/// CFEqual and CFHash, which is what lets a window be used as a key.
struct WindowKey: Hashable {
    let element: AXUIElement

    static func == (lhs: WindowKey, rhs: WindowKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

public final class WindowMover {
    private let console: Console
    private var restorePoints = WindowRestoreStore<WindowKey>()

    public init(console: Console) {
        self.console = console
    }

    @discardableResult
    public func moveFocusedWindow(_ command: WindowMoveCommand) -> ActivationResult {
        // A cascade is about every window rather than the focused one, so it
        // goes its own way from here.
        if case let .cascade(scope) = command {
            return cascade(scope)
        }

        let context = focusedWindowContext()
        let candidates = prioritizedCandidates(context.candidates, focusedPID: context.pid)
        guard !candidates.isEmpty else {
            let message = "No focused window found for window move."
            console.error(message)
            return ActivationResult(succeeded: false, message: message)
        }

        let screens = Self.accessibilityVisibleFrames()
        guard !screens.isEmpty else {
            let message = "No screens found for window move."
            console.error(message)
            return ActivationResult(succeeded: false, message: message)
        }

        if case .restore = command, restorePoints.count == 0 {
            let message = "Nothing to restore: no window has been moved yet."
            console.info(message)
            return ActivationResult(succeeded: false, message: message)
        }

        // Nothing to move to, which is not the window refusing anything.
        if case .moveToMonitor = command, screens.count < 2 {
            let message = "Only one display, so there is no monitor to move to."
            console.info(message)
            return ActivationResult(succeeded: false, message: message)
        }

        var readableWindowCount = 0
        for candidate in candidates {
            guard let currentFrame = frame(of: candidate.window) else {
                continue
            }

            readableWindowCount += 1
            console.info("Trying window move candidate `\(candidate.source)` at \(Self.describe(currentFrame)).")

            guard let targetFrame = targetFrame(
                for: command,
                window: candidate.window,
                currentFrame: currentFrame,
                screens: screens
            ) else {
                continue
            }

            let fullScreenAttribute = "AXFullScreen" as CFString
            if boolAttribute(fullScreenAttribute, on: candidate.window) == true {
                _ = setBool(false, attribute: fullScreenAttribute, on: candidate.window)
            }

            // Taken before the move, and only for the first one, so restore
            // returns to where the window started rather than to half way
            // through a sequence of moves.
            if case .restore = command {
                restorePoints.forget(WindowKey(element: candidate.window))
            } else {
                restorePoints.record(currentFrame, for: WindowKey(element: candidate.window))
            }

            if let appliedFrame = setFrame(targetFrame, on: candidate.window, screens: screens) {
                let wantedNewSize = !WindowGeometryPlanner.isApproximately(targetFrame.size, currentFrame.size)
                let sizeHeldStill = WindowGeometryPlanner.isApproximately(appliedFrame.size, currentFrame.size)

                // The app refused to resize. It is judged by whether the size
                // moved at all, not whether it hit the target: a terminal
                // snapping to whole character cells has still obeyed.
                if wantedNewSize, sizeHeldStill {
                    // Put it back. Resizing and moving are one action, so a
                    // refused resize should not leave the window somewhere
                    // else; repeated presses were walking it across the
                    // screen.
                    restoreFrame(currentFrame, on: candidate.window)
                    restorePoints.forget(WindowKey(element: candidate.window))

                    let name = Self.appName(of: candidate.window)
                    let message: String
                    if case let .resize(step) = command {
                        message = step > 0
                            ? "\(name) will not grow any further."
                            : "\(name) will not shrink any further."
                    } else {
                        message = "\(name) kept its size \(Self.describe(currentFrame.size))."
                    }

                    console.info(message)
                    return ActivationResult(succeeded: false, message: message)
                }

                let message = "Moved focused window to \(Self.describe(appliedFrame))."
                console.info(message)
                return ActivationResult(succeeded: true, message: message)
            }

            console.info("Window move candidate `\(candidate.source)` did not apply target \(Self.describe(targetFrame)).")
        }

        guard readableWindowCount > 0 else {
            let message = "Could not read focused window frame."
            console.error(message)
            return ActivationResult(succeeded: false, message: message)
        }

        if case let .resize(step) = command {
            let message = step > 0
                ? "Window is already as large as the display."
                : "Window is already as small as Shorty will make it."
            console.info(message)
            return ActivationResult(succeeded: false, message: message)
        }

        let message = "Focused window refused move or resize after trying \(readableWindowCount) candidate(s)."
        console.error(message)
        return ActivationResult(succeeded: false, message: message)
    }

    private func targetFrame(
        for command: WindowMoveCommand,
        window: AXUIElement,
        currentFrame: CGRect,
        screens: [CGRect]
    ) -> CGRect? {
        switch command {
        case .restore:
            return restorePoints.frame(for: WindowKey(element: window))

        case let .resize(step):
            return WindowGeometryPlanner.resizedFrame(for: currentFrame, screens: screens, by: step)

        case let .cycleHalf(direction):
            return WindowGeometryPlanner.halfCycleFrame(
                for: currentFrame,
                screens: screens,
                direction: direction
            )
        case .cascade:
            // Handled before a single window is ever chosen.
            return nil

        case .maximize, .almostMaximize:
            let orderedScreens = WindowGeometryPlanner.orderedScreens(screens)
            guard let screenIndex = WindowGeometryPlanner.screenIndex(containing: currentFrame, screens: orderedScreens) else {
                return nil
            }

            let screen = orderedScreens[screenIndex]

            return command == .maximize
                ? WindowGeometryPlanner.maximizeFrame(on: screen)
                : WindowGeometryPlanner.almostMaximizeFrame(on: screen)
        case let .moveToMonitor(direction):
            return WindowGeometryPlanner.monitorMoveFrame(
                for: currentFrame,
                screens: screens,
                direction: direction
            )
        }
    }

    /// Stacks the windows on this space, each one down and right of the last,
    /// so none is completely hidden behind another.
    ///
    /// Laid out back to front, which leaves whatever was in front still in
    /// front and still focused: a command that rearranges the screen should
    /// not also move you to another window.
    private func cascade(_ scope: WindowCascadeScope) -> ActivationResult {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var onScreen = OnScreenWindows.current(excluding: ownPID)
        // The topmost window, taken before anything is filtered out, is the
        // one you were in when the box opened.
        let focused = onScreen.first

        if scope == .application {
            // The owner of the topmost window, not whatever `NSWorkspace`
            // calls frontmost: by the time a command runs, the box has been
            // in front and the answer is Shorty.
            guard let focusedPID = onScreen.first?.ownerPID else {
                let message = "No app in front to cascade."
                console.error(message)
                return ActivationResult(succeeded: false, message: message)
            }

            onScreen = onScreen.filter { $0.ownerPID == focusedPID }
        }

        guard !onScreen.isEmpty else {
            let message = scope == .application
                ? "That app has no windows on this desktop."
                : "No windows on this desktop to cascade."
            console.info(message)
            return ActivationResult(succeeded: false, message: message)
        }

        let screens = Self.accessibilityVisibleFrames()

        // One display at a time: the windows in front of you are the ones on
        // the screen the frontmost window is on.
        guard let screen = screens.first(where: { $0.contains(Self.centre(of: onScreen[0].frame)) })
            ?? screens.first else {
            let message = "No screens found for window move."
            console.error(message)
            return ActivationResult(succeeded: false, message: message)
        }

        let here = onScreen.filter { screen.contains(Self.centre(of: $0.frame)) }
        // The pinned window: left where it is, and the corner the rest flow
        // out of.
        // The window you are in is always the corner the rest flow out of:
        // it is the one you were reading, and a command that tidies the
        // screen should leave it exactly where it was.
        let pinned = focused.flatMap { focused in
            here.first { $0.ownerPID == focused.ownerPID && $0.frame == focused.frame }
        }
        let movable = here.filter { window in
            guard let pinned else {
                return true
            }

            return !(window.ownerPID == pinned.ownerPID && window.frame == pinned.frame)
        }
        let elements = matchingElements(for: movable)

        guard !elements.isEmpty, elements.count + (pinned == nil ? 0 : 1) > 1 else {
            let message = "Nothing to cascade: only one window is open here."
            console.info(message)
            return ActivationResult(succeeded: false, message: message)
        }

        // Back to front, so the last one laid out and raised is the one that
        // was already in front.
        let ordered = Array(elements.reversed())
        // With a window pinned it takes the first place in the stack and the
        // rest step out from its corner; its own frame is then dropped, since
        // it is not going anywhere.
        let sizes = (pinned.map { [$0.frame.size] } ?? []) + ordered.map(\.frame.size)
        var frames = WindowGeometryPlanner.cascadeFrames(
            sizes: sizes,
            on: screen,
            from: pinned?.frame.origin
        )

        if pinned != nil {
            frames.removeFirst()
        }

        // The pinned window goes to the back first, so the stack reads as
        // flowing out from under it.
        if let pinned, let element = matchingElements(for: [pinned]).first {
            _ = AXUIElementPerformAction(element.element, kAXRaiseAction as CFString)
        }

        for (window, frame) in zip(ordered, frames) {
            restorePoints.record(window.frame, for: WindowKey(element: window.element))
            _ = setFrame(frame, on: window.element, screens: screens)
            _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        }

        let message = pinned == nil
            ? "Cascaded \(ordered.count) windows."
            : "Cascaded \(ordered.count) windows around the one you are in."
        console.info(message)
        return ActivationResult(succeeded: true, message: message)
    }

    private static func centre(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Pairs each on-screen window with the accessibility element that can
    /// move it, by frame: the window list gives no handle, and titles are
    /// blank without Screen Recording permission.
    private func matchingElements(
        for windows: [OnScreenWindow]
    ) -> [(element: AXUIElement, frame: CGRect)] {
        var byPID: [pid_t: [AXUIElement]] = [:]

        for window in Set(windows.map(\.ownerPID)) {
            byPID[window] = windowsAttribute(on: AXUIElementCreateApplication(window))
        }

        var used: Set<WindowKey> = []

        return windows.compactMap { window in
            guard let candidates = byPID[window.ownerPID] else {
                return nil
            }

            let match = candidates.first { element in
                guard !used.contains(WindowKey(element: element)),
                      let elementFrame = frame(of: element) else {
                    return false
                }

                return WindowGeometryPlanner.isApproximately(elementFrame.origin, window.frame.origin)
                    && WindowGeometryPlanner.isApproximately(elementFrame.size, window.frame.size)
            }

            guard let match else {
                return nil
            }

            used.insert(WindowKey(element: match))

            return (match, window.frame)
        }
    }

    private func focusedWindowContext() -> (pid: pid_t?, candidates: [WindowCandidate]) {
        let systemWideElement = AXUIElementCreateSystemWide()
        var candidates: [WindowCandidate] = []
        var focusedPID: pid_t?

        append(
            elementAttribute(kAXFocusedWindowAttribute as CFString, on: systemWideElement),
            source: "system focused window",
            to: &candidates
        )

        if let focusedElement = elementAttribute(kAXFocusedUIElementAttribute as CFString, on: systemWideElement) {
            append(
                elementAttribute(kAXWindowAttribute as CFString, on: focusedElement),
                source: "focused element window",
                to: &candidates
            )
        }

        if let focusedApplication = elementAttribute(kAXFocusedApplicationAttribute as CFString, on: systemWideElement) {
            focusedPID = pid(of: focusedApplication)
            appendApplicationWindows(from: focusedApplication, sourcePrefix: "focused app", to: &candidates)
        } else {
            console.info("System-wide focused application unavailable for window move.")
        }

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !frontmostApplication.isTerminated,
           frontmostApplication.activationPolicy != .prohibited {
            let pid = frontmostApplication.processIdentifier
            focusedPID = pid
            appendApplicationWindows(
                from: AXUIElementCreateApplication(pid),
                sourcePrefix: "frontmost app",
                to: &candidates
            )
        }

        if candidates.isEmpty,
           let visiblePID = topmostVisibleWindowOwnerPID(excluding: ProcessInfo.processInfo.processIdentifier) {
            focusedPID = visiblePID
            appendApplicationWindows(
                from: AXUIElementCreateApplication(visiblePID),
                sourcePrefix: "topmost visible app",
                to: &candidates
            )
        }

        return (focusedPID, candidates)
    }

    private func appendApplicationWindows(
        from application: AXUIElement,
        sourcePrefix: String,
        to candidates: inout [WindowCandidate]
    ) {
        append(
            elementAttribute(kAXFocusedWindowAttribute as CFString, on: application),
            source: "\(sourcePrefix) focused window",
            to: &candidates
        )
        append(
            elementAttribute(kAXMainWindowAttribute as CFString, on: application),
            source: "\(sourcePrefix) main window",
            to: &candidates
        )

        for (index, window) in windowsAttribute(on: application).enumerated() {
            append(window, source: "\(sourcePrefix) windows[\(index)]", to: &candidates)
        }
    }

    private func append(_ candidate: AXUIElement?, source: String, to candidates: inout [WindowCandidate]) {
        guard let candidate else {
            return
        }

        guard !candidates.contains(where: { CFEqual($0.window, candidate) }) else {
            return
        }

        candidates.append(WindowCandidate(window: candidate, source: source))
    }

    private func prioritizedCandidates(_ candidates: [WindowCandidate], focusedPID: pid_t?) -> [WindowCandidate] {
        guard let focusedPID,
              let visibleFrame = topmostVisibleWindowFrame(for: focusedPID) else {
            return candidates
        }

        let scoredCandidates = candidates.map { candidate in
            (candidate: candidate, score: visibleWindowMatchScore(candidate.window, visibleFrame: visibleFrame))
        }
        let visibleCandidates = scoredCandidates.filter { $0.score > 0.2 }
        let prioritized = visibleCandidates.isEmpty ? scoredCandidates : visibleCandidates

        return prioritized
            .sorted { first, second in
                if first.score == second.score {
                    return first.candidate.source < second.candidate.source
                }

                return first.score > second.score
            }
            .map(\.candidate)
    }

    private func visibleWindowMatchScore(_ window: AXUIElement, visibleFrame: CGRect) -> CGFloat {
        guard let candidateFrame = frame(of: window) else {
            return 0
        }

        let intersection = candidateFrame.standardized.intersection(visibleFrame.standardized)
        guard !intersection.isNull else {
            return 0
        }

        let intersectionArea = intersection.width * intersection.height
        let unionArea =
            candidateFrame.width * candidateFrame.height +
            visibleFrame.width * visibleFrame.height -
            intersectionArea

        guard unionArea > 0 else {
            return 0
        }

        return intersectionArea / unionArea
    }

    private func topmostVisibleWindowFrame(for pid: pid_t) -> CGRect? {
        topmostVisibleWindowInfo(for: pid)?.frame
    }

    private func topmostVisibleWindowOwnerPID(excluding excludedPID: pid_t) -> pid_t? {
        topmostVisibleWindowInfo(excluding: excludedPID)?.pid
    }

    private func topmostVisibleWindowInfo(for pid: pid_t? = nil, excluding excludedPID: pid_t? = nil) -> VisibleWindowInfo? {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowInfoList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = windowInfo[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  (windowInfo[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = windowInfo[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  frame.width > 0,
                  frame.height > 0 else {
                continue
            }

            let windowPID = ownerPID.int32Value
            if let pid, windowPID != pid {
                continue
            }

            if let excludedPID, windowPID == excludedPID {
                continue
            }

            return VisibleWindowInfo(pid: windowPID, frame: frame)
        }

        return nil
    }

    private func windowsAttribute(on element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)

        guard status == .success, let value else {
            return []
        }

        if let windows = value as? [AXUIElement] {
            return windows
        }

        if let array = value as? [Any] {
            return array.compactMap { $0 as! AXUIElement? }
        }

        return []
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute as CFString, on: window),
              let size = sizeAttribute(kAXSizeAttribute as CFString, on: window) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func setFrame(_ targetFrame: CGRect, on window: AXUIElement, screens: [CGRect]) -> CGRect? {
        let originalFrame = frame(of: window)

        withEnhancedUserInterfaceDisabled(for: window) {
            _ = setSize(targetFrame.size, attribute: kAXSizeAttribute as CFString, on: window)
            _ = setPoint(targetFrame.origin, attribute: kAXPositionAttribute as CFString, on: window)
            _ = setSize(targetFrame.size, attribute: kAXSizeAttribute as CFString, on: window)
            _ = setPoint(targetFrame.origin, attribute: kAXPositionAttribute as CFString, on: window)
        }

        guard let firstAppliedFrame = frame(of: window) else {
            return nil
        }

        if WindowGeometryPlanner.isApproximately(firstAppliedFrame, targetFrame) {
            return firstAppliedFrame
        }

        let fittingOrigin = WindowGeometryPlanner.fittingOrigin(
            for: targetFrame,
            actualSize: firstAppliedFrame.size,
            screens: screens
        )
        _ = setPoint(fittingOrigin, attribute: kAXPositionAttribute as CFString, on: window)

        guard let finalFrame = frame(of: window) else {
            return nil
        }

        if WindowGeometryPlanner.isApproximately(finalFrame, targetFrame) {
            return finalFrame
        }

        guard let originalFrame else {
            return nil
        }

        guard movedOrResized(from: originalFrame, to: finalFrame) else {
            return nil
        }

        if WindowGeometryPlanner.isApproximately(finalFrame.origin, fittingOrigin) {
            return finalFrame
        }

        return finalFrame
    }

    private func movedOrResized(from originalFrame: CGRect, to finalFrame: CGRect) -> Bool {
        !WindowGeometryPlanner.isApproximately(originalFrame, finalFrame, tolerance: 2)
    }

    private static func accessibilityVisibleFrames() -> [CGRect] {
        let screens = NSScreen.screens
        let convertedFrames = screens.compactMap { screen -> CGRect? in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            return WindowGeometryPlanner.accessibilityFrame(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                displayBounds: CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            )
        }

        return convertedFrames.isEmpty ? screens.map(\.visibleFrame) : convertedFrames
    }

    private func elementAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard status == .success,
              let value,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }

        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    private func pointAttribute(_ attribute: CFString, on element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func sizeAttribute(_ attribute: CFString, on element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    /// Puts a window back after a change that did not take.
    private func restoreFrame(_ frame: CGRect, on window: AXUIElement) {
        withEnhancedUserInterfaceDisabled(for: window) {
            _ = setPoint(frame.origin, attribute: kAXPositionAttribute as CFString, on: window)
            _ = setSize(frame.size, attribute: kAXSizeAttribute as CFString, on: window)
            _ = setPoint(frame.origin, attribute: kAXPositionAttribute as CFString, on: window)
        }
    }

    private static func describe(_ size: CGSize) -> String {
        "width=\(Int(size.width)), height=\(Int(size.height))"
    }

    private static func appName(of window: AXUIElement) -> String {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else {
            return "The window"
        }

        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    /// Chrome and other Electron style apps turn on `AXEnhancedUserInterface`
    /// as soon as an accessibility client attaches, and with it on they
    /// animate a programmatic resize and then put the window back where it
    /// was. Turning it off around the change makes the resize stick; it is
    /// restored afterwards so the app keeps whatever behaviour it wanted.
    private func withEnhancedUserInterfaceDisabled(for window: AXUIElement, _ body: () -> Void) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else {
            body()
            return
        }

        let application = AXUIElementCreateApplication(pid)
        let attribute = "AXEnhancedUserInterface" as CFString

        guard boolAttribute(attribute, on: application) == true else {
            body()
            return
        }

        _ = setBool(false, attribute: attribute, on: application)
        body()
        _ = setBool(true, attribute: attribute, on: application)
    }

    private func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func setPoint(_ point: CGPoint, attribute: CFString, on element: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, attribute, value) == .success
    }

    private func setSize(_ size: CGSize, attribute: CFString, on element: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, attribute, value) == .success
    }

    private func setBool(_ value: Bool, attribute: CFString, on element: AXUIElement) -> Bool {
        let boolValue: CFBoolean = value ? kCFBooleanTrue! : kCFBooleanFalse!
        return AXUIElementSetAttributeValue(element, attribute, boolValue) == .success
    }

    private func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }

        return pid
    }

    private static func describe(_ frame: CGRect) -> String {
        "x=\(Int(frame.minX)), y=\(Int(frame.minY)), width=\(Int(frame.width)), height=\(Int(frame.height))"
    }
}

private struct WindowCandidate {
    let window: AXUIElement
    let source: String
}

private struct VisibleWindowInfo {
    let pid: pid_t
    let frame: CGRect
}
