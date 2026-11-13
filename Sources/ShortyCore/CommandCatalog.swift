import Foundation

/// What picking a command entry does.
public enum CommandAction: Equatable, Sendable {
    /// Put text on the pasteboard, such as a converted timestamp.
    case copyText(String)
    case moveWindow(WindowMoveCommand)
    case openClipboard(ClipboardMenuKind)
}

public struct CommandEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// Result text or a short hint, shown under the title.
    public let detail: String?
    public let action: CommandAction?
    /// Non-empty for a group, which opens instead of running.
    public let children: [CommandEntry]
    /// Extra words the query can match, beyond the title.
    public let keywords: [String]

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        action: CommandAction? = nil,
        children: [CommandEntry] = [],
        keywords: [String] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
        self.children = children
        self.keywords = keywords
    }

    public var isGroup: Bool {
        !children.isEmpty
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
        transformers: [CommandTransformer] = CommandTransformerEngine.defaultTransformers
    ) -> [CommandEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return resultEntries(query: normalizedQuery, now: now, transformers: transformers)
            + matching(actionEntries(now: now, localTimeZone: localTimeZone), query: normalizedQuery)
    }

    public static func entries(in group: CommandEntry, query: String) -> [CommandEntry] {
        matching(group.children, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
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

    private static func actionEntries(now: Date, localTimeZone: TimeZone) -> [CommandEntry] {
        [
            CommandEntry(
                id: "clipboard.history",
                title: "Clipboard History",
                detail: "Browse everything you copied",
                action: .openClipboard(.combined),
                keywords: ["paste", "copy", "clipboard"]
            ),
            CommandEntry(
                id: "clipboard.snippets",
                title: "Snippets",
                detail: "Insert a configured snippet",
                action: .openClipboard(.snippets),
                keywords: ["text", "template"]
            ),
            CommandEntry(
                id: "time",
                title: "Time",
                detail: "Current time around the world",
                children: timeEntries(now: now, localTimeZone: localTimeZone),
                keywords: ["clock", "timezone", "zone", "utc"]
            ),
            windowEntry("left-half", "Move Window Left Half", .cycleHalf(.left)),
            windowEntry("right-half", "Move Window Right Half", .cycleHalf(.right)),
            windowEntry("maximize", "Maximize Window", .maximize),
            windowEntry("left-monitor", "Move Window to Left Monitor", .moveToMonitor(.left)),
            windowEntry("right-monitor", "Move Window to Right Monitor", .moveToMonitor(.right)),
        ]
    }

    private static func windowEntry(
        _ id: String,
        _ title: String,
        _ command: WindowMoveCommand
    ) -> CommandEntry {
        CommandEntry(
            id: "window.\(id)",
            title: title,
            action: .moveWindow(command),
            keywords: ["window", "move", "screen", "display"]
        )
    }

    private static func timeEntries(now: Date, localTimeZone: TimeZone) -> [CommandEntry] {
        var zones: [(name: String, timeZone: TimeZone)] = [
            ("Local", localTimeZone),
            ("UTC", TimeZone(secondsFromGMT: 0)!),
        ]

        for (name, identifier) in Self.namedZones {
            guard let timeZone = TimeZone(identifier: identifier) else {
                continue
            }

            zones.append((name, timeZone))
        }

        return zones.map { zone in
            let text = CommandTransformerEngine.currentTime(in: zone.timeZone, now: now)

            return CommandEntry(
                id: "time.\(zone.timeZone.identifier)",
                title: zone.name,
                detail: text,
                action: .copyText(text),
                keywords: [zone.timeZone.identifier]
            )
        }
    }

    private static let namedZones: [(String, String)] = [
        ("ET", "America/New_York"),
        ("CET", "Europe/Paris"),
        ("Turkey", "Europe/Istanbul"),
        ("Dubai", "Asia/Dubai"),
        ("Korea", "Asia/Seoul"),
        ("Japan", "Asia/Tokyo"),
    ]

    private static func matching(_ entries: [CommandEntry], query: String) -> [CommandEntry] {
        guard !query.isEmpty else {
            return entries
        }

        let needle = query.lowercased()

        return entries.filter { entry in
            ([entry.title] + entry.keywords).contains { $0.lowercased().contains(needle) }
        }
    }
}
