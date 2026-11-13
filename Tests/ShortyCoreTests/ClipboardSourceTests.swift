import AppKit
import XCTest
@testable import ShortyCore

final class ClipboardSourceTests: XCTestCase {
    private func window(
        owner: String,
        pid: pid_t,
        layer: Int,
        width: CGFloat = 1200,
        height: CGFloat = 800,
        alpha: Double = 1
    ) -> [String: Any] {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        return [
            kCGWindowOwnerName as String: owner,
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
    }

    /// The layout captured while iTerm2's hotkey window held focus: a HUD on
    /// top, the overlay at layer 25, then menu bar extras.
    func testPrefersTheOverlayOverAHUDAndMenuExtras() {
        let windows = [
            window(owner: "Wispr Flow", pid: 10, layer: 1000, width: 490, height: 1144),
            window(owner: "iTerm2", pid: 20, layer: 25, width: 2560, height: 1440),
            window(owner: "Control Center", pid: 30, layer: 25, width: 29, height: 30),
            window(owner: "Slack", pid: 40, layer: 0),
        ]

        XCTAssertEqual(ClipboardSource.attributableOwnerPID(from: windows, excluding: 99), 20)
    }

    func testOrdinaryWindowWins() {
        let windows = [
            window(owner: "Slack", pid: 40, layer: 0),
            window(owner: "Finder", pid: 50, layer: 0),
        ]

        XCTAssertEqual(ClipboardSource.attributableOwnerPID(from: windows, excluding: 99), 40)
    }

    func testSkipsShortysOwnWindows() {
        let windows = [
            window(owner: "Shorty", pid: 99, layer: 25),
            window(owner: "Slack", pid: 40, layer: 0),
        ]

        XCTAssertEqual(ClipboardSource.attributableOwnerPID(from: windows, excluding: 99), 40)
    }

    func testSkipsSystemUIAndInvisibleWindows() {
        let windows = [
            window(owner: "Window Server", pid: 1, layer: 25),
            window(owner: "Notification Center", pid: 2, layer: 25),
            window(owner: "Chrome", pid: 60, layer: 0, alpha: 0),
            window(owner: "Slack", pid: 40, layer: 0),
        ]

        XCTAssertEqual(ClipboardSource.attributableOwnerPID(from: windows, excluding: 99), 40)
    }

    func testNoCandidateFallsBackToNil() {
        let windows = [
            window(owner: "Wispr Flow", pid: 10, layer: 1000),
            window(owner: "Control Center", pid: 30, layer: 25, width: 29, height: 30),
        ]

        XCTAssertNil(ClipboardSource.attributableOwnerPID(from: windows, excluding: 99))
    }
}
