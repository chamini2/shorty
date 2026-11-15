import Foundation

/// What picking a command entry does. An entry either runs one of these and
/// the box closes, or it goes somewhere: see `CommandDestination`.
public enum CommandAction: Equatable, Sendable {
    /// Put text on the pasteboard, such as a converted timestamp.
    case copyText(String)
    case moveWindow(WindowMoveCommand)
}

/// Where an entry leads. A plain list of entries covers most of it; a view is
/// for the few places a list cannot express, such as the clipboard picker with
/// its previews and paste modes.
public indirect enum CommandDestination: Equatable, Sendable {
    case list([CommandEntry])
    case view(CommandViewKind)
}

public enum CommandViewKind: Equatable, Sendable {
    case clipboard(ClipboardMenuKind)
}

public struct CommandEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// Result text or a short hint, shown under the title.
    public let detail: String?
    public let action: CommandAction?
    /// Set when picking this goes somewhere instead of running something.
    public let destination: CommandDestination?
    /// Extra words the query can match, beyond the title.
    public let keywords: [String]

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        action: CommandAction? = nil,
        destination: CommandDestination? = nil,
        keywords: [String] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
        self.destination = destination
        self.keywords = keywords
    }

    /// Whether picking this takes you somewhere rather than finishing a job.
    public var navigates: Bool {
        destination != nil
    }

    /// The same entry, labelled with the list it was found in.
    func under(_ breadcrumb: String?) -> CommandEntry {
        guard let breadcrumb else {
            return self
        }

        return CommandEntry(
            id: id,
            title: "\(breadcrumb) › \(title)",
            detail: detail,
            action: action,
            destination: destination,
            keywords: keywords
        )
    }
}

/// Everything the command box can offer: live conversions of what you typed,
/// plus the actions Shorty can run. With an empty query it lists the actions,
/// so the box is browsable instead of guesswork.
public enum CommandCatalog {
    public static func rootEntries(
        query: String,
        now: Date = Date(),
        localTimeZone: TimeZone = .current,
        settings: CommandBoxSettings = .default,
        history: [ClipboardItem] = [],
        snippetGroups: [SnippetGroup] = [],
        transformers: [CommandTransformer] = CommandTransformerEngine.defaultTransformers
    ) -> [CommandEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = actionEntries(
            now: now,
            localTimeZone: localTimeZone,
            settings: settings,
            history: history,
            snippetGroups: snippetGroups
        )

        return resultEntries(query: normalizedQuery, now: now, transformers: transformers)
            + matching(actions, query: normalizedQuery)
    }

    /// The entries a list destination holds, filtered by what was typed.
    public static func entries(in list: [CommandEntry], query: String) -> [CommandEntry] {
        matching(list, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Conversions of the typed text, such as an epoch timestamp or a size.
    /// These stay driven by the input rather than living in a group.
    private static func resultEntries(
        query: String,
        now: Date,
        transformers: [CommandTransformer]
    ) -> [CommandEntry] {
        guard !query.isEmpty else {
            return []
        }

        return CommandTransformerEngine.evaluate(query, transformers: transformers, now: now)
            .filter(\.isComplete)
            .compactMap { evaluation in
                guard let text = evaluation.resultText else {
                    return nil
                }

                return CommandEntry(
                    id: "result:\(evaluation.transformerName)",
                    title: evaluation.transformerName,
                    detail: text,
                    action: .copyText(text)
                )
            }
    }

    private static func actionEntries(
        now: Date,
        localTimeZone: TimeZone,
        settings: CommandBoxSettings,
        history: [ClipboardItem],
        snippetGroups: [SnippetGroup]
    ) -> [CommandEntry] {
        [
            CommandEntry(
                id: "clipboard.history",
                title: "Clipboard History",
                detail: history.isEmpty ? "Nothing copied yet" : "\(history.count) entries",
                destination: .view(.clipboard(.combined)),
                keywords: ["paste", "copy", "clipboard", "snippet"]
            ),
            CommandEntry(
                id: "time",
                title: "Time",
                detail: "Current time around the world",
                destination: .list(timeEntries(now: now, localTimeZone: localTimeZone, settings: settings)),
                keywords: ["clock", "timezone", "zone"]
            ),
            CommandEntry(
                id: "window",
                title: "Window",
                detail: "Move the focused window",
                destination: .list(windowEntries()),
                keywords: ["layout", "position", "arrange"]
            ),
        ]
    }

    private static func windowEntries() -> [CommandEntry] {
        [
            windowEntry("left-half", "Left Half", .cycleHalf(.left), ["half", "split"]),
            windowEntry("right-half", "Right Half", .cycleHalf(.right), ["half", "split"]),
            windowEntry("maximize", "Maximize", .maximize, ["full", "fill"]),
            windowEntry("left-monitor", "Left Monitor", .moveToMonitor(.left), ["display", "screen", "monitor"]),
            windowEntry("right-monitor", "Right Monitor", .moveToMonitor(.right), ["display", "screen", "monitor"]),
        ]
    }

    private static func windowEntry(
        _ id: String,
        _ title: String,
        _ command: WindowMoveCommand,
        _ extraKeywords: [String]
    ) -> CommandEntry {
        CommandEntry(
            id: "window.\(id)",
            title: title,
            action: .moveWindow(command),
            keywords: ["window", "move"] + extraKeywords
        )
    }

    /// Local and UTC always; anything else comes from the config.
    private static func timeEntries(
        now: Date,
        localTimeZone: TimeZone,
        settings: CommandBoxSettings
    ) -> [CommandEntry] {
        // A configured list replaces the defaults rather than extending them,
        // so its order is the order shown.
        let zones = settings.timeZones.isEmpty
            ? [
                // Named after the zone's city, falling back for `GMT` and the like.
                CommandTimeZone(
                    label: TimeZoneResolver.cityLabel(for: localTimeZone) ?? "Local",
                    timeZone: localTimeZone
                ),
                CommandTimeZone(label: "UTC", timeZone: TimeZone(secondsFromGMT: 0)!),
            ]
            : settings.timeZones

        // Shown in the order the config lists them.
        return zones.map { zone in
            let text = CommandTransformerEngine.currentTime(in: zone.timeZone, now: now)

            return CommandEntry(
                id: "time.\(zone.label)",
                title: zone.label,
                detail: text,
                action: .copyText(text),
                keywords: [zone.timeZone.identifier]
            )
        }
    }

    /// Searching reaches into lists, so `san francisco` finds the zone without
    /// opening Time first. A match found inside carries where it came from, so
    /// the result reads `Time › San Francisco`.
    private static func matching(
        _ entries: [CommandEntry],
        query: String,
        breadcrumb: String? = nil
    ) -> [CommandEntry] {
        guard !query.isEmpty else {
            return entries
        }

        var results: [(entry: CommandEntry, score: Int)] = []

        for entry in entries {
            if let score = FuzzyMatcher.bestScore(query, in: [entry.title] + entry.keywords) {
                results.append((entry.under(breadcrumb), score))
                continue
            }

            // A list that does not match itself may still hold something that
            // does. A view cannot be searched from here: its contents are not
            // in the catalog.
            guard case let .list(children)? = entry.destination else {
                continue
            }

            let nested = matching(
                children,
                query: query,
                breadcrumb: breadcrumb.map { "\($0) › \(entry.title)" } ?? entry.title
            )

            // Found one level down, so rank it below an equally good match at
            // this level.
            for child in nested {
                let score = FuzzyMatcher.bestScore(query, in: [child.title] + child.keywords) ?? 0
                results.append((child, score - Self.nestedPenalty))
            }
        }

        // Best match first, and ties keep the order the catalog listed them in.
        return results
            .enumerated()
            .sorted { left, right in
                left.element.score == right.element.score
                    ? left.offset < right.offset
                    : left.element.score > right.element.score
            }
            .map(\.element.entry)
    }

    private static let nestedPenalty = 30
}
