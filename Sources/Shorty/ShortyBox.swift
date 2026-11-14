import AppKit

/// The window both the command box and the clipboard picker live in. Keeping
/// one window means moving between them swaps the contents rather than closing
/// one panel and opening another, so the box never blinks out of existence.
@MainActor
final class ShortyBoxController: NSObject, NSWindowDelegate {
    enum Metrics {
        static let width: CGFloat = 820
        static let height: CGFloat = 440
        static let cornerRadius: CGFloat = 8
        static let topOffsetRatio: CGFloat = 0.20
        static let bottomMargin: CGFloat = 20
    }

    /// What the box is showing, so a controller can tell whether it still owns
    /// the window before acting on it.
    private(set) var currentContentID: ObjectIdentifier?

    private let panel: ShortyBoxPanel
    private let container = NSView()
    private var keyHandler: ((NSEvent) -> Bool)?
    private var resignKeyHandler: (() -> Void)?

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

    func isPresenting(_ owner: AnyObject) -> Bool {
        panel.isVisible && currentContentID == ObjectIdentifier(owner)
    }

    /// Installs a content view. The window itself stays where it is, which is
    /// what makes the swap look like one box changing its mind.
    func present(
        _ content: NSView,
        owner: AnyObject,
        keyHandler: @escaping (NSEvent) -> Bool,
        onResignKey: @escaping () -> Void,
        focus: (NSWindow) -> Void
    ) {
        let wasVisible = panel.isVisible

        self.keyHandler = keyHandler
        resignKeyHandler = onResignKey
        currentContentID = ObjectIdentifier(owner)

        container.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        panel.setContentSize(NSSize(width: Metrics.width, height: Metrics.height))
        container.layoutSubtreeIfNeeded()

        if !wasVisible {
            positionPanel()
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
        }

        focus(panel)
    }

    func dismiss(owner: AnyObject) {
        guard currentContentID == ObjectIdentifier(owner) else {
            return
        }

        currentContentID = nil
        keyHandler = nil
        resignKeyHandler = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else {
            return
        }

        resignKeyHandler?()
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
        panel.keyEventHandler = { [weak self] event in
            self?.keyHandler?(event) ?? false
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
