import XCTest
@testable import ShortyCore

final class CommandBoxSettingsTests: XCTestCase {
    func testResolvesCityNames() throws {
        XCTAssertEqual(try TimeZoneResolver.resolve("Tokyo").identifier, "Asia/Tokyo")
        XCTAssertEqual(try TimeZoneResolver.resolve("new york").identifier, "America/New_York")
        XCTAssertEqual(try TimeZoneResolver.resolve("Sao Paulo").identifier, "America/Sao_Paulo")
    }

    func testResolvesIdentifiersAndAbbreviations() throws {
        XCTAssertEqual(try TimeZoneResolver.resolve("Europe/Istanbul").identifier, "Europe/Istanbul")
        // `JST` is an alias with no DST rules, so it resolves to the region zone.
        XCTAssertEqual(try TimeZoneResolver.resolve("JST").identifier, "Asia/Tokyo")
    }

    func testUnknownNameSuggestsNearMisses() {
        XCTAssertThrowsError(try TimeZoneResolver.resolve("Tokio")) { error in
            XCTAssertTrue(String(describing: error).contains("Asia/Tokyo"))
        }
    }

    func testParsesConfiguredZonesKeepingTheirLabels() throws {
        let settings = try CommandBoxSettingsParser.parse(yaml: """
        command-box:
          timezones:
            - Tokyo
            - New York
        """)

        XCTAssertEqual(settings.timeZones.map(\.label), ["Tokyo", "New York"])
        XCTAssertEqual(
            settings.timeZones.map(\.timeZone.identifier),
            ["Asia/Tokyo", "America/New_York"]
        )
    }

    func testDefaultsToNoExtraZones() throws {
        XCTAssertEqual(try CommandBoxSettingsParser.parse(yaml: "shortcuts: {}"), .default)
        XCTAssertTrue(CommandBoxSettings.default.timeZones.isEmpty)
    }

    func testRejectsUnknownSettingAndBadZone() {
        XCTAssertThrowsError(try CommandBoxSettingsParser.parse(yaml: "command-box:\n  timezonez: [Tokyo]"))
        XCTAssertThrowsError(try CommandBoxSettingsParser.parse(yaml: "command-box:\n  timezones: [Nowhere]"))
    }

    func testTimeGroupShowsLocalAndUTCThenConfiguredZones() throws {
        let settings = try CommandBoxSettingsParser.parse(yaml: """
        command-box:
          timezones:
            - Tokyo
        """)

        let root = CommandCatalog.rootEntries(
            query: "",
            now: Date(timeIntervalSince1970: 0),
            localTimeZone: TimeZone(identifier: "Europe/Madrid")!,
            settings: settings
        )
        let time = try XCTUnwrap(root.first { $0.title == "Time" })

        XCTAssertEqual(
            CommandCatalog.entries(in: time, query: "").map(\.title),
            ["Local", "UTC", "Tokyo"]
        )
    }
}
