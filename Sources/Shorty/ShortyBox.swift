import AppKit
import Carbon

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
    private let container = NSView()
    private var stack: [ShortyBoxContent] = []

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
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
        }

        content.boxDidPresent(in: panel)
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
            guard let self else {
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

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
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
