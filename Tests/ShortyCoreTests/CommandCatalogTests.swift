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

        XCTAssertEqual(entries.map(\.title), ["Clipboard History", "Time", "Keep the Mac Awake", "Window"])
        XCTAssertFalse(entries.contains { $0.title == "Snippets" }, "the picker already lists them")
        XCTAssertFalse(
            entries.contains {
                if case .moveWindow = $0.action { return true }
                return false
            },
            "window moves live in their own group"
        )
    }

    private func windowMoves(screenCount: Int) -> [String] {
        let entries = CommandCatalog.rootEntries(
            query: "",
            now: now,
            localTimeZone: madrid,
            screenCount: screenCount
        )

        guard let window = entries.first(where: { $0.title == "Window" }),
              case let .list(moves) = window.destination else {
            return []
        }

        return moves.map(\.title)
    }

    func testWindowGroupLeadsWithMaximizeAndEndsWithRestore() {
        XCTAssertEqual(
            windowMoves(screenCount: 2),
            ["Maximize", "Left Half", "Right Half", "Left Monitor", "Right Monitor", "Restore"]
        )
    }

    func testMonitorMovesAreLeftOutWithOneDisplay() {
        XCTAssertEqual(windowMoves(screenCount: 1), ["Maximize", "Left Half", "Right Half", "Restore"])

        // Nor does searching surface something that could not work.
        let found = CommandCatalog.rootEntries(
            query: "monitor",
            now: now,
            localTimeZone: madrid,
            screenCount: 1
        )
        XCTAssertFalse(found.contains { $0.title.hasSuffix("Left Monitor") })
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
        XCTAssertTrue(root("tokyo").contains { $0.title == "Time › Tokyo" })
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
        XCTAssertEqual(zones.map(\.title), ["San Francisco", "Tokyo"])
        XCTAssertEqual(zones.first { $0.title == "Tokyo" }?.detail, "1970-01-01 09:00:00 UTC+9")
        XCTAssertEqual(CommandCatalog.entries(in: entries, query: "tokyo").count, 1)
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
