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

    func testZoneRowsCarryCleanTextForDisplayAndCopy() throws {
        let settings = try CommandBoxSettingsParser.parse(yaml: """
        command-box:
          timezones: [San Francisco, India, UTC]
        """)
        let root = CommandCatalog.rootEntries(
            query: "",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            localTimeZone: TimeZone(identifier: "America/Caracas")!,
            settings: settings
        )

        guard case let .list(zones) = try XCTUnwrap(root.first { $0.title == "Time" }).destination else {
            return XCTFail("Expected Time to lead to a list")
        }

        // Lining the clocks up is the row view's job, by reserving a column
        // the width of the longest detail. Padding here would not survive:
        // trailing spaces are dropped when a label is aligned.
        XCTAssertEqual(zones.first?.detail, "2023-11-14 14:13:20 UTC-8")
        XCTAssertEqual(zones.first?.action, .copyText("2023-11-14 14:13:20 UTC-8"))
        XCTAssertTrue(zones.allSatisfy { $0.detail == $0.detail?.trimmingCharacters(in: .whitespaces) })
    }

    func testZoneTimesSpellOutTheOffset() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            CommandTransformerEngine.currentTime(in: TimeZone(identifier: "America/Los_Angeles")!, now: now),
            "2023-11-14 14:13:20 UTC-8"
        )
        XCTAssertEqual(
            CommandTransformerEngine.currentTime(in: TimeZone(identifier: "Asia/Kolkata")!, now: now),
            "2023-11-15 03:43:20 UTC+5:30"
        )
        XCTAssertEqual(
            CommandTransformerEngine.currentTime(in: TimeZone(secondsFromGMT: 0)!, now: now),
            "2023-11-14 22:13:20 UTC"
        )
    }

    func testOffsetFollowsDaylightSaving() {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let summer = Date(timeIntervalSince1970: 1_689_000_000)
        let winter = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(CommandTransformerEngine.utcOffsetLabel(of: losAngeles, at: summer), "UTC-7")
        XCTAssertEqual(CommandTransformerEngine.utcOffsetLabel(of: losAngeles, at: winter), "UTC-8")
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

    func testConfiguredZonesReplaceTheDefaultPair() throws {
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

        XCTAssertEqual(CommandCatalog.entries(in: zones, query: "").map(\.title), ["Tokyo"])
    }
}
