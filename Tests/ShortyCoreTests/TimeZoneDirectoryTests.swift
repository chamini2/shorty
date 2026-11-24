import XCTest
@testable import ShortyCore

final class TimeZoneDirectoryTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_763_481_600)

    private var settings: CommandBoxSettings {
        (try? CommandBoxSettingsParser.parse(yaml: """
        command-box:
          timezones: [San Francisco, Turkey, Tokyo]
        """)) ?? .default
    }

    private func cities(_ query: String) -> [String] {
        TimeZoneDirectory.search(query, locale: english).map(\.city)
    }

    private func rows(_ query: String) -> [CommandEntry] {
        CommandCatalog.timeZoneEntries(
            query: query,
            now: now,
            localTimeZone: TimeZone(identifier: "Europe/Madrid")!,
            settings: settings
        )
    }

    func testAZoneIsFoundByCityOrCountry() {
        XCTAssertEqual(cities("rome").first, "Rome")
        XCTAssertEqual(cities("guayaquil").first, "Guayaquil")
        // A country with several zones offers each of them.
        XCTAssertEqual(Set(cities("ecuador")), ["Galapagos", "Guayaquil"])
    }

    func testAPastedIdentifierWinsOutright() {
        XCTAssertEqual(cities("Asia/Tokyo"), ["Tokyo"])
        // No city search would reach this one.
        XCTAssertEqual(cities("America/Argentina/Buenos_Aires"), ["Buenos Aires"])
    }

    func testAnAbbreviationFindsItsZone() {
        // macOS reports Tokyo's abbreviation as `GMT+9`, so the older name
        // survives only in Foundation's abbreviation table.
        XCTAssertEqual(cities("JST"), ["Tokyo"])
    }

    func testAShortQueryFindsNothing() {
        XCTAssertTrue(cities("a").isEmpty)
        XCTAssertTrue(cities("").isEmpty)
    }

    func testConfiguredZonesAreFoundByWhereTheyAreNotOnlyByTheirLabel() {
        // The label is the owner's word for it; the city and country are the
        // zone's own, and both have to find the row.
        XCTAssertEqual(rows("istanbul").first?.title, "Turkey")
        XCTAssertEqual(rows("los angeles").first?.title, "San Francisco")
        XCTAssertEqual(rows("japan").first?.title, "Tokyo")
    }

    func testAConfiguredZoneIsNotAlsoOfferedAsAFind() {
        XCTAssertEqual(rows("tokyo").filter { $0.timeZoneIdentifier == "Asia/Tokyo" }.count, 1)
    }

    func testAnEmptyQueryIsTheConfiguredList() {
        XCTAssertEqual(rows("").map(\.title), ["San Francisco", "Turkey", "Tokyo"])
    }

    func testARowShowsTheClockBesideItAndThePlaceBeneath() throws {
        let row = try XCTUnwrap(rows("").first { $0.title == "San Francisco" })

        // The offset belongs to the second line, so the clock is alone.
        XCTAssertEqual(row.trailing, "2025-11-18 08:00:00")
        // The city is named because the row is called something else.
        XCTAssertEqual(row.detail, "Los Angeles · United States · UTC-8")
        // Copying still takes the offset along.
        XCTAssertEqual(row.action, .copyText("2025-11-18 08:00:00 UTC-8"))
        XCTAssertEqual(row.layout, .detailed)
    }

    func testAFoundRowDoesNotRepeatItsOwnName() throws {
        let row = try XCTUnwrap(rows("rome").first)

        XCTAssertEqual(row.title, "Rome")
        XCTAssertEqual(row.detail, "Italy · UTC+1")
        // Every row carries a place on the map behind the list.
        XCTAssertNotNil(row.marker)
    }
}
