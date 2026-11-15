import XCTest
@testable import ShortyCore

final class WindowRestoreStoreTests: XCTestCase {
    private let original = CGRect(x: 172, y: 132, width: 1728, height: 1071)

    func testRemembersTheFirstFrameOnly() {
        var store = WindowRestoreStore<Int>()

        XCTAssertNil(store.frame(for: 1))
        store.record(original, for: 1)

        // Half, then maximize: restoring still returns to where it started.
        store.record(CGRect(x: 0, y: 39, width: 1028, height: 1290), for: 1)
        store.record(CGRect(x: 0, y: 39, width: 2056, height: 1290), for: 1)

        XCTAssertEqual(store.frame(for: 1), original)
    }

    func testForgetReturnsAndClears() {
        var store = WindowRestoreStore<Int>()
        store.record(original, for: 1)

        XCTAssertEqual(store.forget(1), original)
        XCTAssertNil(store.frame(for: 1))
        XCTAssertNil(store.forget(1))
    }

    func testWindowsAreKeptApart() {
        var store = WindowRestoreStore<Int>()
        store.record(CGRect(x: 1, y: 1, width: 10, height: 10), for: 1)
        store.record(CGRect(x: 2, y: 2, width: 20, height: 20), for: 2)

        XCTAssertEqual(store.frame(for: 1)?.width, 10)
        XCTAssertEqual(store.frame(for: 2)?.width, 20)
    }

    func testOldestDropsOutAtTheLimit() {
        var store = WindowRestoreStore<Int>(limit: 2)
        store.record(CGRect(x: 1, y: 1, width: 10, height: 10), for: 1)
        store.record(CGRect(x: 2, y: 2, width: 20, height: 20), for: 2)
        store.record(CGRect(x: 3, y: 3, width: 30, height: 30), for: 3)

        XCTAssertEqual(store.count, 2)
        XCTAssertNil(store.frame(for: 1))
        XCTAssertEqual(store.frame(for: 3)?.width, 30)
    }

    func testRestoreIsOfferedAsACommand() throws {
        let window = try XCTUnwrap(CommandCatalog.rootEntries(query: "").first { $0.title == "Window" })

        guard case let .list(moves) = window.destination else {
            return XCTFail("Expected Window to lead to a list")
        }

        XCTAssertEqual(moves.first { $0.title == "Restore" }?.action, .moveWindow(.restore))
        XCTAssertTrue(CommandCatalog.rootEntries(query: "undo").contains { $0.title.hasSuffix("Restore") })
    }
}
