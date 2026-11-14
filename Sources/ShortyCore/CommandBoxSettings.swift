import Foundation
import Yams

public enum CommandBoxSettingsError: Error, CustomStringConvertible {
    case invalidBlock(String)
    case unknownSetting(String)
    case unknownTimeZone(name: String, suggestions: [String])
    case ambiguousTimeZone(name: String, matches: [String])

    public var description: String {
        switch self {
        case let .invalidBlock(message):
            return "Invalid command-box config: \(message)"
        case let .unknownSetting(name):
            return "Unknown command-box setting `\(name)`."
        case let .unknownTimeZone(name, suggestions):
            guard !suggestions.isEmpty else {
                return "Unknown time zone `\(name)`. Use a city name like `Tokyo`, or an identifier like `Asia/Tokyo`."
            }

            return "Unknown time zone `\(name)`. Did you mean \(suggestions.joined(separator: ", "))?"
        case let .ambiguousTimeZone(name, matches):
            return "Time zone `\(name)` matches \(matches.joined(separator: ", ")). Use one of those instead."
        }
    }
}

/// A zone shown in the command box, labelled the way the config wrote it.
public struct CommandTimeZone: Equatable, Sendable {
    public let label: String
    public let timeZone: TimeZone

    public init(label: String, timeZone: TimeZone) {
        self.label = label
        self.timeZone = timeZone
    }
}

public struct CommandBoxSettings: Equatable, Sendable {
    /// Local and UTC are always shown; these come after them.
    public static let `default` = CommandBoxSettings(timeZones: [])

    public let timeZones: [CommandTimeZone]

    public init(timeZones: [CommandTimeZone]) {
        self.timeZones = timeZones
    }
}

/// Resolves what a person would actually type: a city, an abbreviation, or a
/// full identifier. Nobody should need to remember `America/Argentina/Salta`.
public enum TimeZoneResolver {
    public static func resolve(_ name: String) throws -> TimeZone {
        let trimmed = name.trimmingCharacters(in: .whitespaces)

        // Only real zone identifiers: `TimeZone(identifier:)` also accepts
        // aliases such as `JST`, which resolve to a fixed offset with no DST
        // rules. Those are better served by the abbreviation step below.
        if TimeZone.knownTimeZoneIdentifiers.contains(trimmed), let exact = TimeZone(identifier: trimmed) {
            return exact
        }

        let needle = normalized(trimmed)
        let cityMatches = TimeZone.knownTimeZoneIdentifiers.filter { normalized(city(of: $0)) == needle }

        if cityMatches.count == 1, let timeZone = TimeZone(identifier: cityMatches[0]) {
            return timeZone
        }

        if cityMatches.count > 1 {
            throw CommandBoxSettingsError.ambiguousTimeZone(name: trimmed, matches: cityMatches.sorted())
        }

        if let abbreviated = TimeZone(abbreviation: trimmed.uppercased()) {
            return abbreviated
        }

        throw CommandBoxSettingsError.unknownTimeZone(name: trimmed, suggestions: suggestions(for: needle))
    }

    /// Zones whose city contains what was typed, so a near miss is fixable.
    public static func suggestions(for needle: String, limit: Int = 3) -> [String] {
        guard needle.count >= 2 else {
            return []
        }

        return TimeZone.knownTimeZoneIdentifiers
            .filter { normalized(city(of: $0)).contains(needle) }
            .sorted()
            .prefix(limit)
            .map { $0 }
    }

    /// The zone's city, as a label: `Europe/Madrid` reads as `Madrid`. This is
    /// the zone's representative city, not where you physically are, so
    /// someone in Barcelona still sees Madrid.
    public static func cityLabel(for timeZone: TimeZone) -> String? {
        guard timeZone.identifier.contains("/") else {
            return nil
        }

        let name = city(of: timeZone.identifier).replacingOccurrences(of: "_", with: " ")
        return name.isEmpty ? nil : name
    }

    private static func city(of identifier: String) -> String {
        identifier.split(separator: "/").last.map(String.init) ?? identifier
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}

public enum CommandBoxSettingsParser {
    public static func parse(yaml contents: String) throws -> CommandBoxSettings {
        guard let root = try Yams.compose(yaml: contents), let node = root["command-box"] else {
            return .default
        }

        guard let mapping = node.mapping else {
            throw CommandBoxSettingsError.invalidBlock("`command-box` must be a mapping of settings.")
        }

        var settings = CommandBoxSettings.default

        for pair in mapping {
            guard let name = pair.key.string else {
                throw CommandBoxSettingsError.invalidBlock("Setting names must be strings.")
            }

            switch name {
            case "timezones":
                settings = CommandBoxSettings(timeZones: try timeZones(from: pair.value))
            default:
                throw CommandBoxSettingsError.unknownSetting(name)
            }
        }

        return settings
    }

    private static func timeZones(from node: Node) throws -> [CommandTimeZone] {
        guard let sequence = node.sequence else {
            throw CommandBoxSettingsError.invalidBlock("`timezones` must be a list of names.")
        }

        return try sequence.map { element in
            guard let name = element.string, !name.isEmpty else {
                throw CommandBoxSettingsError.invalidBlock("Time zone names must be strings.")
            }

            return CommandTimeZone(label: name, timeZone: try TimeZoneResolver.resolve(name))
        }
    }
}
