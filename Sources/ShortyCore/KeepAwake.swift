import Foundation

/// Keeps the machine awake while it is on, the way `caffeinate` does.
///
/// This asks Foundation to hold an activity rather than spawning
/// `/usr/bin/caffeinate`: no child process to supervise or leave behind if
/// Shorty quits unexpectedly, and the assertion shows up in `pmset -g
/// assertions` under Shorty's own name.
public final class KeepAwake {
    private let processInfo: ProcessInfo
    private let reason: String
    private var token: NSObjectProtocol?

    public init(processInfo: ProcessInfo = .processInfo, reason: String = "Shorty keep awake") {
        self.processInfo = processInfo
        self.reason = reason
    }

    deinit {
        if let token {
            processInfo.endActivity(token)
        }
    }

    public var isActive: Bool {
        token != nil
    }

    /// Idle sleep and display sleep both, since a screen that goes dark is
    /// usually what people mean by the machine sleeping.
    public func start() {
        guard token == nil else {
            return
        }

        token = processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: reason
        )
    }

    public func stop() {
        guard let token else {
            return
        }

        processInfo.endActivity(token)
        self.token = nil
    }

    public func set(_ active: Bool) {
        active ? start() : stop()
    }
}
