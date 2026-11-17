import Foundation

/// A place on the world map, as degrees. North and east are positive.
public struct GeoCoordinate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// What the map points at for an entry. A zone with a known city gets a
/// beacon on it; a bare offset such as UTC+9 has no city, so it gets the
/// meridian its clocks are centred on instead.
public enum WorldMapMarker: Equatable, Sendable {
    case city(GeoCoordinate)
    case meridian(longitude: Double)
}

/// The land outline the map draws, as rings of coordinates. Decoded once from
/// the table in `WorldMapData.swift`.
public enum WorldMapOutline {
    public static let rings: [[GeoCoordinate]] = encodedRings
        .split(separator: ";")
        .map { ring in
            ring.split(separator: " ").compactMap { pair -> GeoCoordinate? in
                let parts = pair.split(separator: ",")
                guard parts.count == 2,
                      let longitude = Double(parts[0]),
                      let latitude = Double(parts[1]) else {
                    return nil
                }

                return GeoCoordinate(latitude: latitude, longitude: longitude)
            }
        }
        .filter { $0.count >= 3 }

    /// The map stops short of Antarctica, which is dropped from the outline.
    public static let latitudeRange: ClosedRange<Double> = -58 ... 84
    public static let longitudeRange: ClosedRange<Double> = -180 ... 180
}

/// Where each zone's city is, for the beacon. `Europe/Madrid` is in Madrid;
/// the tz database keeps a coordinate for every zone it names.
public enum TimeZoneLocations {
    public static func coordinate(for timeZone: TimeZone) -> GeoCoordinate? {
        table[timeZone.identifier]
    }

    /// A city when the zone has one, else the meridian at the zone's offset.
    public static func marker(for timeZone: TimeZone, at date: Date = Date()) -> WorldMapMarker {
        if let coordinate = coordinate(for: timeZone) {
            return .city(coordinate)
        }

        // Fifteen degrees per hour, kept on the map for offsets past +12.
        let longitude = Double(timeZone.secondsFromGMT(for: date)) / 3600 * 15
        return .meridian(longitude: wrapped(longitude: longitude))
    }

    static func wrapped(longitude: Double) -> Double {
        var value = longitude.truncatingRemainder(dividingBy: 360)
        if value > 180 {
            value -= 360
        } else if value < -180 {
            value += 360
        }
        return value
    }

    private static let table: [String: GeoCoordinate] = {
        var table: [String: GeoCoordinate] = [:]

        for line in encodedTable.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3,
                  let latitude = Double(parts[1]),
                  let longitude = Double(parts[2]) else {
                continue
            }

            table[String(parts[0])] = GeoCoordinate(latitude: latitude, longitude: longitude)
        }

        return table
    }()
}
