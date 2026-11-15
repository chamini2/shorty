import XCTest
@testable import ShortyCore

final class CommandCatalogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 0)
    private let madrid = TimeZone(identifier: "Europe/Madrid")!

    private var settings: CommandBoxSettings {
        (try? CommandBoxSettingsParser.parse(yaml: """
        command-box:
          timezones: [San Francisco, Tokyo]
        """)) ?? .default
    }

    private func root(_ query: String) -> [CommandEntry] {
        CommandCatalog.rootEntries(query: query, now: now, localTimeZone: madrid, settings: settings)
    }

    func testEmptyQueryListsTheCommands() {
        let entries = root("")

        XCTAssertEqual(entries.map(\.title), ["Clipboard History", "Time", "Window"])
        XCTAssertFalse(entries.contains { $0.title == "Snippets" }, "the picker already lists them")
        XCTAssertFalse(
            entries.contains {
                if case .moveWindow = $0.action { return true }
                return false
            },
            "window moves live in their own group"
        )
    }

    func testWindowGroupHoldsTheMoves() throws {
        let window = try XCTUnwrap(root("").first { $0.title == "Window" })

        guard case let .list(moves) = window.destination else {
            return XCTFail("Expected Window to lead to a list")
        }

        XCTAssertEqual(
            CommandCatalog.entries(in: moves, query: "").map(\.title),
            ["Left Half", "Right Half", "Maximize", "Left Monitor", "Right Monitor"]
        )
        XCTAssertEqual(CommandCatalog.entries(in: moves, query: "monitor").count, 2)
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
        XCTAssertTrue(root("paste").contains { $0.title == "Clipboard History" })
        XCTAssertTrue(root("timezone").contains { $0.title == "Time" })
        XCTAssertTrue(root("zzzz").isEmpty)
    }

    func testFuzzyQueriesFindTheRightEntry() {
        XCTAssertEqual(root("sf").first?.title, "Time › San Francisco")
        XCTAssertEqual(root("clp").first?.title, "Clipboard History")
        XCTAssertTrue(root("maxi").contains { $0.title == "Window › Maximize" })
    }

    func testSearchReachesInsideListsAndSaysWhereFrom() {
        XCTAssertTrue(root("maximize").contains { $0.title == "Window › Maximize" })
        XCTAssertTrue(root("utc").contains { $0.title == "Time › UTC" })
    }

    func testMatchingAListShowsTheListNotItsEntries() {
        let results = root("timezone")

        XCTAssertEqual(results.map(\.title), ["Time"])
    }

    func testSurfacedEntryKeepsItsOwnBehaviour() throws {
        let maximize = try XCTUnwrap(root("maximize").first)

        XCTAssertFalse(maximize.navigates)
        XCTAssertEqual(maximize.action, .moveWindow(.maximize))
    }

    func testTimeGroupHoldsTheZones() throws {
        let time = try XCTUnwrap(root("").first { $0.title == "Time" })

        guard case let .list(entries) = time.destination else {
            return XCTFail("Expected Time to lead to a list")
        }

        let zones = CommandCatalog.entries(in: entries, query: "")
        XCTAssertEqual(zones.map(\.title).prefix(2).map(String.init), ["Local", "UTC"])
        XCTAssertEqual(zones.first { $0.title == "UTC" }?.detail, "1970-01-01 00:00:00 UTC")
        XCTAssertEqual(CommandCatalog.entries(in: entries, query: "japan").count, 1)
    }

    func testChevronMarksAnythingThatNavigates() throws {
        let entries = root("")

        XCTAssertTrue(try XCTUnwrap(entries.first { $0.title == "Time" }).navigates)
        XCTAssertTrue(try XCTUnwrap(entries.first { $0.title == "Clipboard History" }).navigates)

        let window = try XCTUnwrap(entries.first { $0.title == "Window" })
        guard case let .list(moves) = window.destination else {
            return XCTFail("Expected Window to lead to a list")
        }

        XCTAssertFalse(try XCTUnwrap(moves.first { $0.title == "Maximize" }).navigates)
    }

    func testZonesAreNoLongerTopLevelCommands() {
        XCTAssertFalse(root("utc time").contains { $0.title == "UTC Time" })
    }
}
