import XCTest
@testable import ShortyCore

final class CommandCatalogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 0)
    private let madrid = TimeZone(identifier: "Europe/Madrid")!

    private func root(_ query: String) -> [CommandEntry] {
        CommandCatalog.rootEntries(query: query, now: now, localTimeZone: madrid)
    }

    func testEmptyQueryListsTheCommands() {
        let entries = root("")

        XCTAssertEqual(entries.first?.title, "Clipboard History")
        XCTAssertTrue(entries.contains { $0.title == "Snippets" })
        XCTAssertEqual(entries.filter { $0.action == nil }.count, 1, "only Time is a group")
        XCTAssertEqual(
            entries.filter {
                if case .moveWindow = $0.action { return true }
                return false
            }.count,
            5
        )
    }

    func testEmptyQueryShowsNoConversions() {
        XCTAssertTrue(root("").allSatisfy {
            if case .copyText = $0.action { return false }
            return true
        })
    }

    func testTypedInputStillConverts() {
        XCTAssertEqual(root("1700000000").first?.title, "Epoch Seconds")
        XCTAssertEqual(root("1.5 gb").first?.title, "Disk Size Units")
    }

    func testFiltersByTitleAndKeyword() {
        XCTAssertTrue(root("maxim").contains { $0.title == "Maximize Window" })
        XCTAssertTrue(root("paste").contains { $0.title == "Clipboard History" })
        XCTAssertTrue(root("zzzz").isEmpty)
    }

    func testTimeGroupHoldsTheZones() throws {
        let time = try XCTUnwrap(root("").first { $0.title == "Time" })
        XCTAssertTrue(time.isGroup)

        let zones = CommandCatalog.entries(in: time, query: "")
        XCTAssertEqual(zones.map(\.title).prefix(2).map(String.init), ["Local", "UTC"])
        XCTAssertEqual(zones.first { $0.title == "UTC" }?.detail, "1970-01-01 00:00:00 GMT")
        XCTAssertEqual(CommandCatalog.entries(in: time, query: "japan").count, 1)
    }

    func testZonesAreNoLongerTopLevelCommands() {
        XCTAssertFalse(root("utc time").contains { $0.title == "UTC Time" })
    }
}
