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

    func testLocalZoneIsNamedAfterItsCity() {
        XCTAssertEqual(TimeZoneResolver.cityLabel(for: TimeZone(identifier: "Europe/Madrid")!), "Madrid")
        XCTAssertEqual(TimeZoneResolver.cityLabel(for: TimeZone(identifier: "America/New_York")!), "New York")
        XCTAssertNil(TimeZoneResolver.cityLabel(for: TimeZone(secondsFromGMT: 0)!))
    }

    func testTimeGroupLabelsTheLocalRowWithTheCity() throws {
        let root = CommandCatalog.rootEntries(
            query: "",
            now: Date(timeIntervalSince1970: 0),
            localTimeZone: TimeZone(identifier: "America/Caracas")!
        )
        let time = try XCTUnwrap(root.first { $0.title == "Time" })

        guard case let .list(zones) = time.destination else {
            return XCTFail("Expected Time to lead to a list")
        }

        XCTAssertEqual(CommandCatalog.entries(in: zones, query: "").map(\.title), ["Caracas", "UTC"])
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

        guard case let .list(zones) = time.destination else {
            return XCTFail("Expected Time to lead to a list")
        }

        XCTAssertEqual(CommandCatalog.entries(in: zones, query: "").map(\.title), ["Local", "UTC", "Tokyo"])
    }
}
