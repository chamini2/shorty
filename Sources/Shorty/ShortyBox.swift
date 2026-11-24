import AppKit
import Carbon
import ShortyCore
// The tap callback is handed a `CGEvent`, which Core Graphics does not mark
// `Sendable`. It is delivered on the main run loop and read there only.
@preconcurrency import CoreGraphics

/// Anything the box can show: the command list, a list of times, the clipboard
/// picker. Each supplies a view and handles its own keys; the box handles the
/// window and the navigation between them.
@MainActor
protocol ShortyBoxContent: AnyObject {
    var view: NSView { get }

    /// Called before the content is shown, so it can refresh and focus.
    func boxWillPresent()
    func boxDidPresent(in window: NSWindow)
    /// Return true when the key was handled.
    func boxHandlesKey(_ event: NSEvent) -> Bool
    /// Return true to deal with escape internally, such as leaving a folder,
    /// instead of the box going back a level.
    func boxHandlesEscape() -> Bool
    /// Called when the box closes or this content is popped off the stack.
    func boxDidDismiss()
}

extension ShortyBoxContent {
    func boxWillPresent() {}
    func boxDidDismiss() {}
    func boxHandlesEscape() -> Bool { false }
}

/// The window the command box and the clipboard picker live in, and the stack
/// of what is showing. One window and one stack means one rule for going back:
/// escape pops, and the box closes when the last content pops.
@MainActor
final class ShortyBoxController: NSObject, NSWindowDelegate {
    enum Metrics {
        static let width: CGFloat = 820
        static let height: CGFloat = 520
        static let cornerRadius: CGFloat = 8
        static let topOffsetRatio: CGFloat = 0.20
        static let bottomMargin: CGFloat = 20
    }

    private let panel: ShortyBoxPanel
    /// Frosted rather than flat: the box floats over whatever it was opened
    /// on top of, and letting that show through says so.
    private let container = NSVisualEffectView()
    private var stack: [ShortyBoxContent] = []
    /// Live while the box is open; see `startKeyboardCapture`.
    private var keyboardTap: CFMachPort?
    private var keyboardTapSource: CFRunLoopSource?
    /// Set while a captured key is being handed to the panel, so the box's
    /// key handler does not see the same keystroke twice.
    private var isDeliveringCapturedKey = false
    /// Hotkeys that must reach macOS even while the box has the keyboard.
    var boundHotKeys: [KeyCombo] = []

    override init() {
        panel = ShortyBoxPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        configurePanel()
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var window: NSWindow {
        panel
    }

    var depth: Int {
        stack.count
    }

    func isPresenting(_ content: ShortyBoxContent) -> Bool {
        panel.isVisible && stack.last === content
    }

    /// Shows `content` as the only thing on the stack, opening the box.
    func open(_ content: ShortyBoxContent) {
        stack.forEach { $0.boxDidDismiss() }
        stack = []
        push(content)
    }

    /// Shows `content` above what is already there, keeping the window as is.
    func push(_ content: ShortyBoxContent) {
        stack.append(content)
        install(content)
    }

    /// Goes back one level, closing the box when nothing is left.
    @discardableResult
    func pop() -> Bool {
        guard !stack.isEmpty else {
            return false
        }

        stack.removeLast().boxDidDismiss()

        guard let previous = stack.last else {
            close()
            return false
        }

        install(previous)
        return true
    }

    func close() {
        stopKeyboardCapture()
        stack.forEach { $0.boxDidDismiss() }
        stack = []
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible, !suppressesResignKey else {
            return
        }

        close()
    }

    /// Set while something else deliberately takes focus, such as a nested
    /// picker, so the box does not close under it.
    var suppressesResignKey = false

    private func install(_ content: ShortyBoxContent) {
        let wasVisible = panel.isVisible
        content.boxWillPresent()

        container.subviews.forEach { $0.removeFromSuperview() }
        let view = content.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)

        // Fixed, not pinned to the container's edges: a content view's own
        // constraints reach the window and can resize it, and a link preview
        // with a large image was growing the box that way.
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: Metrics.width),
            view.heightAnchor.constraint(equalToConstant: Metrics.height),
        ])

        panel.setContentSize(NSSize(width: Metrics.width, height: Metrics.height))
        container.layoutSubtreeIfNeeded()

        if !wasVisible {
            positionPanel()
            takeFocus()
        }

        content.boxDidPresent(in: panel)
    }

    /// Brings the box forward and makes sure the keys come with it.
    private func takeFocus() {
        // The keys are read from the stream whatever activation does, since
        // an overlay can hold the keyboard without ever activating and no
        // check of who is frontmost can see it happen.
        startKeyboardCapture()

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Takes the keyboard from the event stream while the box is open.
    ///
    /// Activation is not enough on its own. An overlay terminal, such as
    /// Tern, holds the keyboard without ever activating: the box becomes
    /// frontmost, draws its caret, and every keystroke still goes to the
    /// overlay. `isKeyWindow` reports the key window inside this process and
    /// says nothing about it, so there is no state to check and no moment at
    /// which checking would help.
    ///
    /// Reading the keys from the stream is what works. They are consumed, so
    /// nothing behind the box acts on them too, and the tap goes away the
    /// moment the box closes.
    private func startKeyboardCapture() {
        guard keyboardTap == nil else {
            return
        }

        let events = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: events,
            callback: { _, _, event, pointer in
                guard let pointer else {
                    return Unmanaged.passUnretained(event)
                }

                let controller = Unmanaged<ShortyBoxController>.fromOpaque(pointer).takeUnretainedValue()

                return MainActor.assumeIsolated {
                    controller.handleCaptured(event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            console.error("could not read the keyboard: Shorty needs Accessibility permission")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        keyboardTap = tap
        keyboardTapSource = source
    }

    /// Hands a captured key to the window rather than straight to the first
    /// responder.
    ///
    /// Calling `keyDown` on the responder delivers the keystroke but none of
    /// what AppKit wraps around it: an event off the stream carries no window,
    /// and without one a field editor never turns the key into an editing
    /// command. `cmd+delete` and the arrows did nothing for exactly that
    /// reason. Rebuilt against the panel, the key goes through the ordinary
    /// path and behaves as it would in any other window.
    private func deliver(_ event: NSEvent) {
        guard let windowEvent = NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else {
            return
        }

        // The panel asks its handler first; this key has been through that
        // already, so the second pass is skipped.
        isDeliveringCapturedKey = true
        panel.sendEvent(windowEvent)
        isDeliveringCapturedKey = false
    }

    private func stopKeyboardCapture() {
        guard let keyboardTap else {
            return
        }

        CGEvent.tapEnable(tap: keyboardTap, enable: false)

        if let keyboardTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), keyboardTapSource, .commonModes)
        }

        CFMachPortInvalidate(keyboardTap)
        self.keyboardTap = nil
        keyboardTapSource = nil
    }

    /// Hands a captured key to the box, and swallows it so the app behind
    /// does not act on it too.
    private func handleCaptured(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard panel.isVisible, let keyEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        // Modifier changes are state, not input: the field needs to know
        // about them but nothing else should be denied them.
        guard keyEvent.type == .keyDown else {
            panel.firstResponder?.flagsChanged(with: keyEvent)
            return Unmanaged.passUnretained(event)
        }

        // A hotkey keeps working while the box is open: the same key that
        // opened it closes it again, and swallowing it here would be the box
        // holding itself open.
        if boundHotKeys.contains(where: {
            $0.matches(keyCode: keyEvent.keyCode, flags: event.flags)
        }) {
            return Unmanaged.passUnretained(event)
        }

        if panel.keyEventHandler?(keyEvent) != true {
            deliver(keyEvent)
        }

        return nil
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        // Escape is the box's: handling it in each content let one keystroke
        // pop twice, which closed the window instead of going back a level.
        panel.keyEventHandler = { [weak self] event in
            guard let self, !isDeliveringCapturedKey else {
                return false
            }

            if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
                if stack.last?.boxHandlesEscape() == true {
                    return true
                }

                pop()
                return true
            }

            return stack.last?.boxHandlesKey(event) ?? false
        }

        container.material = .popover
        // Blurs what is behind the window, not merely what is behind the
        // view, which is the whole point for a panel that floats.
        container.blendingMode = .behindWindow
        // Stays frosted while another app holds the keyboard, which an
        // overlay terminal routinely does.
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = Metrics.cornerRadius
        container.layer?.masksToBounds = true
        panel.contentView = container
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let frame = panel.frame
        let topY = visibleFrame.maxY - visibleFrame.height * Metrics.topOffsetRatio

        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: max(visibleFrame.minY + Metrics.bottomMargin, topY - frame.height)
            )
        )
    }
}

final class ShortyBoxPanel: NSPanel {
    var keyEventHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func sendEvent(_ event: NSEvent) {
        if keyEventHandler?(event) == true {
            return
        }

        super.sendEvent(event)
    }
}
