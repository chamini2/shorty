import AppKit
@preconcurrency import ApplicationServices

/// Which windows a cascade gathers up.
public enum WindowCascadeScope: Equatable, Sendable {
    /// Everything on the space in front of you.
    case space
    /// Only the windows of the app you are in.
    case application
}

/// What a cascade does, and what it leaves alone.
public struct WindowCascadeOptions: Equatable, Sendable {
    public let scope: WindowCascadeScope
    /// Leaves the window you are in exactly where it is, and stacks the rest
    /// behind it.
    ///
    /// The pin nobody has to configure: one window of an app is often parked
    /// where you want it while the other ten are clutter, and which one that
    /// is changes by the hour. Naming it in a config file cannot keep up;
    /// being in it says so.
    public let keepsFocused: Bool

    public init(scope: WindowCascadeScope, keepsFocused: Bool = false) {
        self.scope = scope
        self.keepsFocused = keepsFocused
    }
}

/// A window on the current space, as CoreGraphics reports it.
///
/// Spaces are not something the accessibility API talks about: it hands over
/// every window an app owns, wherever it lives. The on-screen window list is
/// the one place macOS says what is actually in front of you, so that is what
/// decides membership, and the matching accessibility element is found
/// afterwards by frame.
struct OnScreenWindow {
    let ownerPID: pid_t
    let ownerName: String
    let frame: CGRect
}

enum OnScreenWindows {
    /// Ordinary windows on this space, front to back, which is the order the
    /// window server returns them in.
    ///
    /// Titles are deliberately not used for any of this: reading them needs
    /// Screen Recording permission, and without it every title comes back
    /// empty.
    static func current(excluding excludedPID: pid_t) -> [OnScreenWindow] {
        let listing = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return listing.compactMap { window in
            guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != excludedPID,
                  // Layer zero is an ordinary window; everything above it is a
                  // panel, a menu or some piece of system furniture.
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= minimumSize.width,
                  frame.height >= minimumSize.height else {
                return nil
            }

            return OnScreenWindow(
                ownerPID: ownerPID,
                ownerName: window[kCGWindowOwnerName as String] as? String ?? "",
                frame: frame
            )
        }
    }

    /// Smaller than this and it is a palette or a notification, not something
    /// worth a place in the stack.
    private static let minimumSize = CGSize(width: 200, height: 120)
}
