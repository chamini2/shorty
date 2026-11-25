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

        XCTAssertEqual(
            entries.map(\.title),
            [
                "Applications",
                "Scratch Pad",
                "Files",
                "Clipboard History",
                "Time",
                "Keep the Mac Awake",
                "Window",
            ]
        )
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
            [
                "Maximize",
                "Almost Maximize",
                "Make Larger",
                "Make Smaller",
                "Left Half",
                "Right Half",
                "Left Monitor",
                "Right Monitor",
                "Cascade Windows",
                "Cascade App Windows",
                "Restore",
            ]
        )
    }

    func testMonitorMovesAreLeftOutWithOneDisplay() {
        XCTAssertEqual(
            windowMoves(screenCount: 1),
            [
                "Maximize",
                "Almost Maximize",
                "Make Larger",
                "Make Smaller",
                "Left Half",
                "Right Half",
                "Cascade Windows",
                "Cascade App Windows",
                "Restore",
            ]
        )

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
        XCTAssertEqual(root("clp").first?.title, "Clipboard History")
        XCTAssertTrue(root("maxi").contains { $0.title == "Window › Maximize" })
    }

    func testSearchReachesInsideListsAndSaysWhereFrom() {
        XCTAssertTrue(root("maximize").contains { $0.title == "Window › Maximize" })
        XCTAssertTrue(root("restore").contains { $0.title == "Window › Restore" })
    }

    /// Zones are searched inside Time rather than from here: the list is
    /// every zone on earth, and the top level would be nothing but cities.
    func testZonesAreNotSearchedFromTheTopLevel() {
        XCTAssertTrue(root("tokyo").isEmpty)
        XCTAssertTrue(root("sf").isEmpty)
        XCTAssertTrue(root("time").contains { $0.title == "Time" })
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

    func testTimeLeadsToASearchOfEveryZone() throws {
        let time = try XCTUnwrap(root("").first { $0.title == "Time" })

        XCTAssertEqual(time.destination, .search(.timeZones))
    }

    func testTimeGroupHoldsTheZones() {
        let zones = CommandCatalog.timeZoneEntries(
            query: "",
            now: now,
            localTimeZone: madrid,
            settings: settings
        )

        XCTAssertEqual(zones.map(\.title), ["San Francisco", "Tokyo"])
        // The clock sits at the end of the row and the offset underneath.
        XCTAssertEqual(zones.first { $0.title == "Tokyo" }?.trailing, "1970-01-01 09:00:00")
        XCTAssertEqual(zones.first { $0.title == "Tokyo" }?.detail, "Japan · UTC+9")

        let searched = CommandCatalog.timeZoneEntries(
            query: "tokyo",
            now: now,
            localTimeZone: madrid,
            settings: settings
        )

        XCTAssertEqual(searched.filter { $0.timeZoneIdentifier == "Asia/Tokyo" }.count, 1)
    }

    /// The list keeps the order the config gives it, so landing on the local
    /// zone is a matter of which row opens selected, not of sorting.
    func testTimeOpensOnTheLocalZoneWhereverItIsListed() throws {
        let configured = try CommandBoxSettingsParser.parse(yaml: """
        command-box:
          timezones: [San Francisco, Tokyo, Madrid]
        """)
        let zones = CommandCatalog.timeZoneEntries(
            query: "",
            now: now,
            localTimeZone: madrid,
            settings: configured
        )

        XCTAssertEqual(zones.map(\.title), ["San Francisco", "Tokyo", "Madrid"])
        XCTAssertEqual(zones.firstIndex(where: \.opensSelected), 2)
    }

    func testNothingOpensSelectedWhenTheLocalZoneIsNotListed() {
        let zones = CommandCatalog.timeZoneEntries(query: "", now: now, localTimeZone: madrid, settings: settings)

        XCTAssertFalse(zones.contains { $0.opensSelected })
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
