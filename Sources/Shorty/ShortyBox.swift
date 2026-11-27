import AppKit
import Carbon
import ShortyCore

enum ShortyBoxSession: Hashable {
    case commandBox
    case clipboard
    case snippets
    case scratchPad
}

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
    /// Whether this view holds an unsubmitted draft worth keeping across hide/reopen.
    var hasDraft: Bool { get }

    /// Called before the content is shown fresh, so it can refresh and focus.
    func boxWillPresent()
    func boxDidPresent(in window: NSWindow)
    /// Called before the box hides or another view is pushed over this one,
    /// while the field editor is still active so caret/selection can be saved.
    func boxWillSuspend()
    /// Called when returning to an already-created view (via resume or pop),
    /// preserving its search text and caret position.
    func boxDidResume(in window: NSWindow)
    /// Return true when the content handled a command-modified key equivalent.
    func boxPerformsKeyEquivalent(_ event: NSEvent) -> Bool
    /// Return true to deal with escape internally, such as leaving a folder,
    /// instead of the box going back a level.
    func boxHandlesEscape() -> Bool
    /// Called when the box closes or this content is popped off the stack.
    func boxDidDismiss()
}

extension ShortyBoxContent {
    var hasDraft: Bool { false }
    func boxWillPresent() {}
    func boxWillSuspend() {}
    func boxDidResume(in window: NSWindow) { boxDidPresent(in: window) }
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

    private struct SuspendedSession {
        let stack: [ShortyBoxContent]
        let suspendedAt: Date
    }

    /// How long an unsubmitted draft stack survives after hiding.
    private static let draftLifetime: TimeInterval = 10 * 60

    private let panel: ShortyBoxPanel
    /// Frosted rather than flat: the box floats over whatever it was opened
    /// on top of, and letting that show through says so.
    private let container = NSVisualEffectView()
    /// Sits over the frosted material to give the text some contrast.
    private let tint = NSView()
    private(set) var activeSession: ShortyBoxSession?
    private var stack: [ShortyBoxContent] = []
    private var suspendedSessions: [ShortyBoxSession: SuspendedSession] = [:]

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

    /// Starts a fresh session with `content` as the only item on the stack.
    /// Suspends any other active session in-place so its unsubmitted draft
    /// survives switching hotkeys, and releases `content` from any suspended
    /// session before running `prepare`.
    func open(
        session: ShortyBoxSession,
        content: ShortyBoxContent,
        prepare: () -> Void = {}
    ) {
        if let current = activeSession, !stack.isEmpty {
            if current == session {
                dismissActiveStack()
            } else {
                parkActiveStack(orderOut: false)
            }
        }

        dropSuspended(session: session)
        releaseFromSuspendedSessions(content)
        prepare()
        activeSession = session
        stack = [content]
        install(content, resuming: false)
    }

    /// Restores a suspended session if one exists and has not expired.
    @discardableResult
    func resume(
        session: ShortyBoxSession,
        refresh: ([ShortyBoxContent]) -> Void = { _ in }
    ) -> Bool {
        evictExpiredSessions()

        guard let saved = suspendedSessions.removeValue(forKey: session),
              let top = saved.stack.last else {
            return false
        }

        if let current = activeSession, !stack.isEmpty {
            if current == session {
                dismissActiveStack()
            } else {
                parkActiveStack(orderOut: false)
            }
        }

        activeSession = session
        stack = saved.stack
        refresh(stack)
        install(top, resuming: true)
        return true
    }

    /// Shows `content` above what is already there, keeping the window as is.
    func push(_ content: ShortyBoxContent, prepare: () -> Void = {}) {
        guard !stack.contains(where: { $0 === content }) else {
            return
        }

        releaseFromSuspendedSessions(content)
        stack.last?.boxWillSuspend()
        prepare()
        stack.append(content)
        install(content, resuming: false)
    }

    /// Goes back one level, closing the session when nothing is left.
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

        install(previous, resuming: true)
        return true
    }

    /// Hides the box while preserving an unsubmitted stack/draft for resume.
    func suspend() {
        parkActiveStack(orderOut: true)
    }

    /// Completes or abandons the active session and clears its stack.
    func close() {
        if let session = activeSession {
            dropSuspended(session: session)
        }
        dismissActiveStack()
        panel.orderOut(nil)
    }

    /// Dismisses the active session and every suspended draft (e.g. on quit).
    func closeAll() {
        dismissActiveStack()
        let sessions = suspendedSessions.values
        suspendedSessions.removeAll()
        for session in sessions {
            session.stack.reversed().forEach { $0.boxDidDismiss() }
        }
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

        suspend()
    }

    @objc
    private func activeSpaceDidChange(_ notification: Notification) {
        guard panel.isVisible else {
            return
        }

        suspend()
    }

    private func parkActiveStack(orderOut: Bool) {
        if let session = activeSession, !stack.isEmpty {
            stack.last?.boxWillSuspend()
            let shouldKeep = stack.count > 1 || stack.contains(where: \.hasDraft)
            if shouldKeep {
                suspendedSessions[session] = SuspendedSession(stack: stack, suspendedAt: Date())
                stack = []
                activeSession = nil
            } else {
                dismissActiveStack()
            }
        }

        if orderOut {
            panel.orderOut(nil)
        }
    }

    private func dismissActiveStack() {
        let dismissed = stack.reversed()
        stack = []
        activeSession = nil
        dismissed.forEach { $0.boxDidDismiss() }
    }

    private func dropSuspended(session: ShortyBoxSession) {
        guard let saved = suspendedSessions.removeValue(forKey: session) else {
            return
        }

        saved.stack.reversed().forEach { $0.boxDidDismiss() }
    }

    /// If another suspended session holds a shared controller instance (such as
    /// a nested clipboard picker), trim from that point upward so the parent
    /// draft stays intact without aliasing the reused controller.
    private func releaseFromSuspendedSessions(_ content: ShortyBoxContent) {
        for (session, saved) in suspendedSessions {
            guard let index = saved.stack.firstIndex(where: { $0 === content }) else {
                continue
            }

            let kept = Array(saved.stack[..<index])
            let trimmed = saved.stack[index...].reversed()

            if kept.isEmpty {
                suspendedSessions.removeValue(forKey: session)
            } else {
                suspendedSessions[session] = SuspendedSession(
                    stack: kept,
                    suspendedAt: saved.suspendedAt
                )
            }

            trimmed.forEach { $0.boxDidDismiss() }
        }
    }

    private func evictExpiredSessions(now: Date = Date()) {
        for (session, saved) in suspendedSessions {
            guard now.timeIntervalSince(saved.suspendedAt) >= Self.draftLifetime else {
                continue
            }

            suspendedSessions.removeValue(forKey: session)
            saved.stack.reversed().forEach { $0.boxDidDismiss() }
        }
    }

    private func install(_ content: ShortyBoxContent, resuming: Bool) {
        let wasVisible = panel.isVisible
        if !resuming {
            content.boxWillPresent()
        }

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

        if resuming {
            content.boxDidResume(in: panel)
        } else {
            content.boxDidPresent(in: panel)
        }
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
