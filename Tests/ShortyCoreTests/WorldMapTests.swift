import XCTest
@testable import ShortyCore

final class WorldMapTests: XCTestCase {
    func testZonesWithACityGetABeaconOnIt() throws {
        guard case let .city(madrid) = TimeZoneLocations.marker(for: TimeZone(identifier: "Europe/Madrid")!) else {
            return XCTFail("Expected a city")
        }

        XCTAssertEqual(madrid.latitude, 40.4, accuracy: 0.1)
        XCTAssertEqual(madrid.longitude, -3.7, accuracy: 0.1)
    }

    func testOlderSpellingsLandOnTheSameCity() {
        XCTAssertEqual(
            TimeZoneLocations.coordinate(for: TimeZone(identifier: "Asia/Calcutta")!),
            TimeZoneLocations.coordinate(for: TimeZone(identifier: "Asia/Kolkata")!)
        )
    }

    /// `GMT` is the one the system lists with no city; it gets a meridian.
    func testEveryZoneTheSystemListsHasACity() {
        let missing = TimeZone.knownTimeZoneIdentifiers.filter {
            $0.contains("/") && TimeZoneLocations.coordinate(for: TimeZone(identifier: $0)!) == nil
        }

        XCTAssertEqual(missing, [])
        XCTAssertEqual(TimeZoneLocations.marker(for: TimeZone(identifier: "GMT")!), .meridian(longitude: 0))
    }

    func testFixedOffsetsGetTheirMeridian() {
        XCTAssertEqual(TimeZoneLocations.marker(for: TimeZone(secondsFromGMT: 0)!), .meridian(longitude: 0))
        XCTAssertEqual(TimeZoneLocations.marker(for: TimeZone(secondsFromGMT: 9 * 3600)!), .meridian(longitude: 135))
        XCTAssertEqual(TimeZoneLocations.marker(for: TimeZone(secondsFromGMT: -5 * 3600)!), .meridian(longitude: -75))
        // UTC+14 is past the date line, so it comes round the other side.
        XCTAssertEqual(TimeZoneLocations.marker(for: TimeZone(secondsFromGMT: 14 * 3600)!), .meridian(longitude: -150))
    }

    func testOutlineDecodesIntoRingsOnTheMap() {
        let rings = WorldMapOutline.rings

        XCTAssertGreaterThan(rings.count, 50)
        XCTAssertTrue(rings.allSatisfy { $0.count >= 3 })

        for coordinate in rings.joined() {
            XCTAssertTrue(WorldMapOutline.latitudeRange.contains(coordinate.latitude), "\(coordinate)")
            XCTAssertTrue(WorldMapOutline.longitudeRange.contains(coordinate.longitude), "\(coordinate)")
        }
    }

    func testTimeEntriesCarryTheirPlace() throws {
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        let entries = CommandCatalog.timeZoneEntries(query: "", localTimeZone: madrid)

        XCTAssertEqual(entries.map(\.title), ["Madrid", "UTC"])
        XCTAssertEqual(entries[0].marker, TimeZoneLocations.marker(for: madrid))
        // A zone with no city of its own is drawn at its meridian.
        XCTAssertEqual(entries[1].marker, .meridian(longitude: 0))

        // The place survives being found by search, which is what the map
        // behind the list draws.
        let found = try XCTUnwrap(
            CommandCatalog.timeZoneEntries(query: "rome", localTimeZone: madrid).first
        )
        XCTAssertEqual(found.title, "Rome")
        XCTAssertEqual(found.marker, TimeZoneLocations.marker(for: TimeZone(identifier: "Europe/Rome")!))
    }
}
