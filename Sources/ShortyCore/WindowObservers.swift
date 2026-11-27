import AppKit
@preconcurrency import ApplicationServices

/// Watches every app for the window events a switcher cares about.
///
/// The alternative is asking, which is what this replaces: there is no system
/// notification for "the focused window changed", so the index used to poll
/// four times a second forever. Accessibility will push the same news
/// instead, and then nothing wakes up while nothing moves.
///
/// An observer belongs to one process, so apps are attached as they launch
/// and dropped as they quit.
@MainActor
final class WindowObservers {
    /// Something changed about which windows exist, or which one is focused.
    typealias Handler = () -> Void

    private let handler: Handler
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() {
        NSWorkspace.shared.runningApplications.forEach(attach)

        let center = NSWorkspace.shared.notificationCenter

        // Apps come and go, and an observer is bound to a process: one that
        // has quit takes its windows with it, and one that just launched has
        // nobody watching it yet.
        workspaceTokens = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication

                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }

                    if let application {
                        name == NSWorkspace.didTerminateApplicationNotification
                            ? self.detach(application)
                            : self.attach(application)
                    }

                    self.handler()
                }
            }
        }
    }

    func stop() {
        observers.keys.forEach(detach)
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceTokens = []
    }

    private func attach(_ application: NSRunningApplication) {
        let pid = application.processIdentifier

        guard observers[pid] == nil,
              pid != ownPID,
              application.activationPolicy == .regular,
              !application.isTerminated else {
            return
        }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else {
                return
            }

            Unmanaged<WindowObservers>.fromOpaque(context).takeUnretainedValue().handler()
        }

        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            return
        }

        let element = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()

        for name in Self.notifications {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        observers[pid] = observer
    }

    private func detach(_ application: NSRunningApplication) {
        detach(application.processIdentifier)
    }

    private func detach(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else {
            return
        }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    /// Focus says which window to put first; the other two say which windows
    /// there are. Destruction is reported for every element rather than only
    /// for windows, so it is the noisy one, and the index treats all three as
    /// the same news: look again.
    private static let notifications = [
        kAXFocusedWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
    ]
}
