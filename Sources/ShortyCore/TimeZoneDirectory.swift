import Foundation

/// A zone the search found, with enough about it to tell two apart.
public struct TimeZoneMatch: Equatable, Sendable {
    public let timeZone: TimeZone
    /// The zone's representative city: `Europe/Rome` reads as `Rome`.
    public let city: String
    /// The country it is in, named in the reader's language.
    public let country: String?

    public init(timeZone: TimeZone, city: String, country: String?) {
        self.timeZone = timeZone
        self.city = city
        self.country = country
    }

    public var id: String {
        "timezone.\(timeZone.identifier)"
    }
}

/// Every time zone on the machine, searchable by city, country or identifier.
///
/// The country for each zone comes from the tz database's own table, which
/// macOS ships at `/usr/share/zoneinfo/zone.tab` and keeps current with system
/// updates. Foundation knows the zones and can name a country, but nothing in
/// it joins the two: `Locale.Region` has no list of zones.
///
/// The table is public domain and read once. Without it cities and identifiers
/// still work; only searching by country stops.
public enum TimeZoneDirectory {
    public static let tableURL = URL(fileURLWithPath: "/usr/share/zoneinfo/zone.tab")

    /// Zones matching what was typed, closest first.
    ///
    /// A pasted identifier wins outright, since `America/Argentina/Buenos_Aires`
    /// names a zone no city search would reach.
    public static func search(
        _ query: String,
        limit: Int = 8,
        locale: Locale = .current
    ) -> [TimeZoneMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= minimumQueryLength else {
            return []
        }

        if TimeZone.knownTimeZoneIdentifiers.contains(trimmed), let exact = TimeZone(identifier: trimmed) {
            return [match(for: exact, locale: locale)]
        }

        // `JST` is Tokyo, which no term would say: macOS reports that zone's
        // abbreviation as `GMT+9`, and the abbreviation table is the only
        // place the older name survives.
        if let abbreviated = TimeZone(abbreviation: trimmed.uppercased()),
           TimeZone.knownTimeZoneIdentifiers.contains(abbreviated.identifier) {
            return [match(for: abbreviated, locale: locale)]
        }

        let scored = entries(locale: locale).compactMap { entry -> (match: TimeZoneMatch, score: Int)? in
            guard let score = FuzzyMatcher.bestScore(trimmed, in: entry.terms) else {
                return nil
            }

            return (entry.match, score)
        }

        return scored
            .sorted { left, right in
                left.score == right.score
                    ? left.match.city < right.match.city
                    : left.score > right.score
            }
            .prefix(limit)
            .map(\.match)
    }

    /// Below this nearly every zone matches and the answer means nothing.
    public static let minimumQueryLength = 2

    public static func match(for timeZone: TimeZone, locale: Locale = .current) -> TimeZoneMatch {
        TimeZoneMatch(
            timeZone: timeZone,
            city: TimeZoneResolver.cityLabel(for: timeZone) ?? timeZone.identifier,
            country: countryName(for: timeZone.identifier, locale: locale)
        )
    }

    public static func countryName(for identifier: String, locale: Locale = .current) -> String? {
        countryCodes[identifier].flatMap { locale.localizedString(forRegionCode: $0) }
    }

    /// What a zone can be found by: its city, its country, its identifier and
    /// the abbreviation it goes by.
    private struct Entry {
        let match: TimeZoneMatch
        let terms: [String]
    }

    private static func entries(locale: Locale) -> [Entry] {
        TimeZone.knownTimeZoneIdentifiers.compactMap { identifier in
            guard let timeZone = TimeZone(identifier: identifier) else {
                return nil
            }

            let found = match(for: timeZone, locale: locale)
            var terms = [found.city, identifier, identifier.replacingOccurrences(of: "_", with: " ")]

            if let country = found.country {
                terms.append(country)
            }

            if let abbreviation = timeZone.abbreviation() {
                terms.append(abbreviation)
            }

            return Entry(match: found, terms: terms)
        }
    }

    /// Zone identifier to ISO country code, from the system's own table.
    private static let countryCodes: [String: String] = {
        guard let contents = try? String(contentsOf: tableURL, encoding: .utf8) else {
            return [:]
        }

        var codes: [String: String] = [:]

        for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
            // `CC	+4152-08739	America/Indiana/Indianapolis	comment`
            let columns = line.split(separator: "\t")

            guard columns.count >= 3 else {
                continue
            }

            codes[String(columns[2])] = String(columns[0])
        }

        return codes
    }()
}
