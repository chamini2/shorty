import XCTest
@testable import ShortyCore

final class KeepAwakeTests: XCTestCase {
    func testStartsOffAndTogglesCleanly() {
        let awake = KeepAwake(reason: "Shorty tests")

        XCTAssertFalse(awake.isActive)

        awake.start()
        XCTAssertTrue(awake.isActive)

        // Holding one activity, not a new one per call.
        awake.start()
        XCTAssertTrue(awake.isActive)

        awake.stop()
        XCTAssertFalse(awake.isActive)

        awake.stop()
        XCTAssertFalse(awake.isActive)
    }

    func testSetFollowsTheFlag() {
        let awake = KeepAwake(reason: "Shorty tests")

        awake.set(true)
        XCTAssertTrue(awake.isActive)

        awake.set(false)
        XCTAssertFalse(awake.isActive)
    }

    func testCommandReflectsTheStateAndOffersTheOpposite() throws {
        let off = try XCTUnwrap(CommandCatalog.rootEntries(query: "", keepAwake: false).first { $0.id == "keep-awake" })
        let on = try XCTUnwrap(CommandCatalog.rootEntries(query: "", keepAwake: true).first { $0.id == "keep-awake" })

        XCTAssertEqual(off.title, "Keep the Mac Awake")
        XCTAssertEqual(off.detail, "Off")
        XCTAssertEqual(off.action, .setKeepAwake(true))

        XCTAssertEqual(on.title, "Let the Mac Sleep")
        XCTAssertEqual(on.detail, "On, sleep is held off")
        XCTAssertEqual(on.action, .setKeepAwake(false))
    }

    func testFoundByTheWordsPeopleUse() {
        for query in ["caffeinate", "caffeine", "sleep", "awake"] {
            XCTAssertTrue(
                CommandCatalog.rootEntries(query: query).contains { $0.id == "keep-awake" },
                "expected \(query) to find it"
            )
        }
    }
}
