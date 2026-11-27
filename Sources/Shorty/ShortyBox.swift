import AppKit
import Carbon
import ShortyCore

enum ClipboardPickerPurpose: Equatable {
    case paste
    case insert
}

enum ShortyBoxRoute: Equatable {
    case commandRoot
    case commandList(String)
    case commandSearch(CommandSearchKind)
    case clipboard(ClipboardMenuKind, purpose: ClipboardPickerPurpose)
    case scratchPad
}

/// Anything the box can show: the command list, a list of times, the clipboard
/// picker. Each supplies a view and handles its own keys; the box handles the
/// window and the navigation between them.
@MainActor
protocol ShortyBoxContent: AnyObject {
    var route: ShortyBoxRoute { get }
    var view: NSView { get }

    /// Called before the content is shown, so it can refresh and focus.
    func boxWillPresent()
    func boxDidPresent(in window: NSWindow)
    /// Return true when the content handled a command-modified key equivalent.
    func boxPerformsKeyEquivalent(_ event: NSEvent) -> Bool
    /// Return true to deal with escape internally, such as leaving a folder,
    /// instead of the box going back a level.
    func boxHandlesEscape() -> Bool
    /// Called when the box closes or this content is popped off the stack.
    func boxDidDismiss()
}

extension ShortyBoxContent {
    func boxWillPresent() {}
    func boxDidDismiss() {}
    func boxPerformsKeyEquivalent(_ event: NSEvent) -> Bool { false }
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
        /// Enough to read against a busy desktop, little enough to still
        /// look like glass.
        static let tintOpacity: CGFloat = 0.45
    }

    private let panel: ShortyBoxPanel
    /// Frosted rather than flat: the box floats over whatever it was opened
    /// on top of, and letting that show through says so.
    private let container = NSVisualEffectView()
    /// Sits over the frosted material to give the text some contrast.
    private let tint = NSView()
    private var stack: [ShortyBoxContent] = []

    override init() {
        panel = ShortyBoxPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
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

    var topContent: ShortyBoxContent? {
        panel.isVisible ? stack.last : nil
    }

    var topRoute: ShortyBoxRoute? {
        topContent?.route
    }

    var rootRoute: ShortyBoxRoute? {
        panel.isVisible ? stack.first?.route : nil
    }

    func isPresenting(_ content: ShortyBoxContent) -> Bool {
        panel.isVisible && stack.last === content
    }

    /// Shows `content` as the only thing on the stack, opening the box.
    /// Runs `prepare` after dismissing the previous stack so reused content
    /// controllers do not have their fresh state wiped by their own dismissal.
    func open(_ content: ShortyBoxContent, prepare: () -> Void = {}) {
        let dismissed = stack.reversed()
        stack = []
        dismissed.forEach { $0.boxDidDismiss() }
        prepare()
        push(content)
    }

    /// Shows `content` above what is already there, keeping the window as is.
    func push(_ content: ShortyBoxContent) {
        guard !stack.contains(where: { $0 === content }) else {
            return
        }

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
        let dismissed = stack.reversed()
        stack = []
        dismissed.forEach { $0.boxDidDismiss() }
        panel.orderOut(nil)
    }

    func handleEscape() {
        if stack.last?.boxHandlesEscape() == true {
            return
        }

        pop()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else {
            return
        }

        close()
    }

    @objc
    private func activeSpaceDidChange(_ notification: Notification) {
        guard panel.isVisible else {
            return
        }

        close()
    }

    private func install(_ content: ShortyBoxContent) {
        let wasVisible = panel.isVisible
        content.boxWillPresent()

        // Everything but the tint, which belongs to the box rather than to
        // whatever it is showing.
        container.subviews.filter { $0 !== tint }.forEach { $0.removeFromSuperview() }
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

    /// Brings the box forward and gives it key focus without activating Shorty.
    private func takeFocus() {
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above layer-25 overlay panels (e.g. terminal hotkey windows) so the
        // box takes key focus cleanly through WindowServer without an event tap.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        // Follows the system rather than forcing dark: the frosted material
        // is mixed with whatever is behind the panel, and a dark appearance
        // over a light desktop was muddying it.
        panel.appearance = nil
        panel.delegate = self
        panel.keyEquivalentHandler = { [weak self] event in
            self?.stack.last?.boxPerformsKeyEquivalent(event) ?? false
        }
        panel.escapeHandler = { [weak self] in
            self?.handleEscape()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

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

        // Vibrancy alone has no contrast of its own: over a light desktop the
        // box all but disappeared. The tint gives the text something to sit
        // on and takes its colour from the appearance, so it is a dark wash
        // in dark mode and a light one in light.
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(Metrics.tintOpacity)
            .cgColor
        container.addSubview(tint)

        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: container.topAnchor),
            tint.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
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
    var keyEquivalentHandler: ((NSEvent) -> Bool)?
    var escapeHandler: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true {
            return true
        }

        if super.performKeyEquivalent(with: event) {
            return true
        }

        // A non-activating panel can be key while Shorty is not active, so
        // AppKit does not dispatch `NSApp.mainMenu` key equivalents on its own.
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    override func cancelOperation(_ sender: Any?) {
        escapeHandler?()
    }
}
