import Foundation

/// What picking a command entry does. An entry either runs one of these and
/// the box closes, or it goes somewhere: see `CommandDestination`.
public enum CommandAction: Equatable, Sendable {
    /// Put text on the pasteboard, such as a converted timestamp.
    case copyText(String)
    case moveWindow(WindowMoveCommand)
    /// Stop the machine sleeping, or let it again.
    case setKeepAwake(Bool)
    /// Open an app by bundle path, or bring it forward when it is running.
    case openApplication(path: String)
    /// Open a file in whatever usually opens it.
    case openFile(path: String)
    /// Show a file in Finder rather than opening it.
    case revealFile(path: String)
    /// Put a file's path on the pasteboard. Its own case rather than
    /// `copyText`, so reaching for a file still counts as reaching for it.
    case copyFilePath(path: String)
}

/// Where an entry leads. A plain list of entries covers most of it; a view is
/// for the few places a list cannot express, such as the clipboard picker with
/// its previews and paste modes.
public indirect enum CommandDestination: Equatable, Sendable {
    case list([CommandEntry])
    case view(CommandViewKind)
    /// A list that cannot be written down in advance: its rows come from
    /// whatever is typed once it is open.
    case search(CommandSearchKind)
}

public enum CommandSearchKind: Equatable, Sendable {
    case files
    case timeZones
}

public enum CommandViewKind: Equatable, Sendable {
    case clipboard(ClipboardMenuKind)
    case scratchPad
}

/// How much room a row is given.
public enum CommandEntryLayout: Equatable, Sendable {
    /// One line: a title, and a detail beside it.
    case compact
    /// Two lines and a larger icon, for rows where the detail is what tells
    /// one result from another. A file search needs it: half the matches are
    /// called `README.md` and only the path says which is which.
    case detailed
    /// What was asked on the left, the answer on the right, each with a note
    /// beneath it. For the rows that work something out.
    case result
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
    /// Where this entry is in the world, for lists that show a map behind
    /// themselves: the time zones do.
    public let marker: WorldMapMarker?
    /// A file whose icon stands for this entry, such as an app bundle. The
    /// catalog knows nothing about drawing; it only says where to look.
    public let iconPath: String?
    /// An SF Symbol standing for the entry, for rows with no file to take an
    /// icon from.
    public let symbolName: String?
    /// Shown at the end of the title line of a detailed row, where a value
    /// belongs beside the name it answers for.
    public let trailing: String?
    /// The note under `trailing` in a result row.
    public let trailingDetail: String?
    public let layout: CommandEntryLayout
    /// The row its list opens on. Time marks the local zone: the list is
    /// about elsewhere, but you read it from where you are.
    public let opensSelected: Bool

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        action: CommandAction? = nil,
        destination: CommandDestination? = nil,
        keywords: [String] = [],
        marker: WorldMapMarker? = nil,
        opensSelected: Bool = false,
        iconPath: String? = nil,
        trailing: String? = nil,
        trailingDetail: String? = nil,
        symbolName: String? = nil,
        layout: CommandEntryLayout = .compact
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
        self.destination = destination
        self.keywords = keywords
        self.marker = marker
        self.opensSelected = opensSelected
        self.iconPath = iconPath
        self.symbolName = symbolName
        self.trailing = trailing
        self.trailingDetail = trailingDetail
        self.layout = layout
    }

    /// The zone a time row stands for, which it carries as a keyword.
    public var timeZoneIdentifier: String? {
        keywords.first { TimeZone.knownTimeZoneIdentifiers.contains($0) }
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
            keywords: keywords,
            marker: marker,
            opensSelected: opensSelected,
            iconPath: iconPath,
            trailing: trailing,
            trailingDetail: trailingDetail,
            symbolName: symbolName,
            layout: layout
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
        keepAwake: Bool = false,
        screenCount: Int = 1,
        applications: [InstalledApplication] = [],
        applicationOpens: [String: Int] = [:],
        transformers: [CommandTransformer] = CommandTransformerEngine.defaultTransformers
    ) -> [CommandEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = actionEntries(
            now: now,
            localTimeZone: localTimeZone,
            settings: settings,
            history: history,
            snippetGroups: snippetGroups,
            keepAwake: keepAwake,
            screenCount: screenCount,
            applications: applications,
            applicationOpens: applicationOpens
        )

        return resultEntries(
            query: normalizedQuery,
            now: now,
            localTimeZone: localTimeZone,
            transformers: transformers
        )
            + cappingApplications(matching(actions, query: normalizedQuery))
    }

    /// A machine holds hundreds of apps and a loose query matches dozens of
    /// them. Only the best few are kept, so the commands are never buried
    /// under a list of apps.
    private static let maximumApplicationMatches = 10

    private static func cappingApplications(_ entries: [CommandEntry]) -> [CommandEntry] {
        var seen = 0

        return entries.filter { entry in
            guard entry.id.hasPrefix("app.") else {
                return true
            }

            seen += 1

            return seen <= maximumApplicationMatches
        }
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
        localTimeZone: TimeZone,
        transformers: [CommandTransformer]
    ) -> [CommandEntry] {
        guard !query.isEmpty else {
            return []
        }

        return dateEntry(for: query, now: now, localTimeZone: localTimeZone)
            + calculatorEntry(for: query)
            + CommandTransformerEngine.evaluate(query, transformers: transformers, now: now)
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

    /// The answer to what was typed, when it is arithmetic. Shown grouped for
    /// reading; what lands on the pasteboard has no commas in it, since a
    /// comma pasted into a spreadsheet is not a number.
    /// Date arithmetic: `now - 1h in pst`, `today + 3d`, `2026-12-25 - now`.
    private static func dateEntry(
        for query: String,
        now: Date,
        localTimeZone: TimeZone
    ) -> [CommandEntry] {
        guard let result = DateExpression.evaluate(query, now: now, localTimeZone: localTimeZone) else {
            return []
        }

        return [
            CommandEntry(
                id: "result:date",
                title: query.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: result.base,
                action: .copyText(result.value),
                trailing: result.value,
                trailingDetail: result.valueDetail,
                layout: .result
            ),
        ]
    }

    private static func calculatorEntry(for query: String) -> [CommandEntry] {
        guard Calculator.isWorthEvaluating(query), let value = Calculator.evaluate(query) else {
            return []
        }

        return [
            CommandEntry(
                id: "result:calculator",
                title: query.trimmingCharacters(in: .whitespacesAndNewlines),
                action: .copyText(Calculator.plain(value)),
                trailing: Calculator.display(value),
                layout: .result
            ),
        ]
    }

    private static func actionEntries(
        now: Date,
        localTimeZone: TimeZone,
        settings: CommandBoxSettings,
        history: [ClipboardItem],
        snippetGroups: [SnippetGroup],
        keepAwake: Bool,
        screenCount: Int,
        applications: [InstalledApplication] = [],
        applicationOpens: [String: Int] = [:]
    ) -> [CommandEntry] {
        [
            CommandEntry(
                id: "applications",
                title: "Applications",
                detail: applications.isEmpty ? "None found" : "\(applications.count) installed",
                destination: .list(applicationEntries(applications, opens: applicationOpens)),
                keywords: ["app", "apps", "open", "launch", "run"]
            ),
            CommandEntry(
                id: "scratch-pad",
                title: "Scratch Pad",
                detail: "Work text over before copying it out",
                destination: .view(.scratchPad),
                keywords: ["scratch", "edit", "draft", "note", "text", "format", "pad"]
            ),
            CommandEntry(
                id: "files",
                title: "Files",
                detail: "Search your home folder",
                destination: .search(.files),
                keywords: ["file", "find", "spotlight", "document", "folder", "open"]
            ),
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
                destination: .search(.timeZones),
                keywords: ["clock", "timezone", "zone"]
            ),
            CommandEntry(
                id: "keep-awake",
                title: keepAwake ? "Let the Mac Sleep" : "Keep the Mac Awake",
                detail: keepAwake ? "On, sleep is held off" : "Off",
                action: .setKeepAwake(!keepAwake),
                keywords: ["caffeine", "caffeinate", "sleep", "awake", "insomnia", "screensaver"]
            ),
            CommandEntry(
                id: "window",
                title: "Window",
                detail: "Move the focused window",
                destination: .list(windowEntries(screenCount: screenCount)),
                keywords: ["layout", "position", "arrange"]
            ),
        ]
    }

    /// One row per app, labelled with where it was found so two apps of the
    /// same name can be told apart.
    private static func applicationEntries(
        _ applications: [InstalledApplication],
        opens: [String: Int] = [:]
    ) -> [CommandEntry] {
        // The ones you open, most used first; everything else keeps its
        // alphabetical place underneath.
        let ordered = applications.sorted { left, right in
            let leftOpens = opens[left.path] ?? 0
            let rightOpens = opens[right.path] ?? 0

            return leftOpens == rightOpens
                ? left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                : leftOpens > rightOpens
        }

        return ordered.map { application in
            CommandEntry(
                id: application.id,
                title: application.name,
                detail: application.directoryName,
                action: .openApplication(path: application.path),
                keywords: [application.directoryName],
                iconPath: application.path
            )
        }
    }

    /// One row per file, labelled with the folder it sits in.
    public static func fileEntries(_ hits: [FileHit]) -> [CommandEntry] {
        hits.map { hit in
            CommandEntry(
                id: hit.id,
                title: hit.name,
                detail: hit.displayPath,
                action: .openFile(path: hit.path),
                iconPath: hit.path,
                layout: .detailed
            )
        }
    }

    /// Maximize first, as the one most often wanted, then the halves, then
    /// the monitor moves, and the undo last. The monitor moves are left out
    /// with a single display, where they can only report that there is
    /// nowhere to go.
    private static func windowEntries(screenCount: Int) -> [CommandEntry] {
        var entries = [
            windowEntry("maximize", "Maximize", .maximize, ["full", "fill"]),
            windowEntry(
                "almost-maximize",
                "Almost Maximize",
                .almostMaximize,
                ["nearly", "centre", "center", "big"]
            ),
            windowEntry("larger", "Make Larger", .resize(sizeStep), ["bigger", "grow", "expand", "wider"]),
            windowEntry("smaller", "Make Smaller", .resize(-sizeStep), ["shrink", "reduce", "narrower"]),
            windowEntry("left-half", "Left Half", .cycleHalf(.left), ["half", "split"]),
            windowEntry("right-half", "Right Half", .cycleHalf(.right), ["half", "split"]),
        ]

        if screenCount > 1 {
            entries.append(
                windowEntry("left-monitor", "Left Monitor", .moveToMonitor(.left), ["display", "screen", "monitor"])
            )
            entries.append(
                windowEntry("right-monitor", "Right Monitor", .moveToMonitor(.right), ["display", "screen", "monitor"])
            )
        }

        entries.append(
            windowEntry(
                "cascade",
                "Cascade Windows",
                .cascade(.space),
                ["stack", "arrange", "tile", "all", "desktop", "space", "overlap"]
            )
        )
        entries.append(
            windowEntry(
                "cascade-app",
                "Cascade App Windows",
                .cascade(.application),
                ["stack", "arrange", "app", "same", "application"]
            )
        )
        entries.append(
            windowEntry("restore", "Restore", .restore, ["undo", "revert", "back", "original"])
        )

        return entries
    }

    /// How much of the display a single larger or smaller step covers.
    private static let sizeStep: CGFloat = 0.05

    private static func windowEntry(
        _ id: String,
        _ title: String,
        _ command: WindowMoveCommand,
        _ extraKeywords: [String],
        detail: String? = nil
    ) -> CommandEntry {
        CommandEntry(
            id: "window.\(id)",
            title: title,
            detail: detail,
            action: .moveWindow(command),
            keywords: ["window", "move"] + extraKeywords
        )
    }

    /// Local and UTC always; anything else comes from the config.
    /// The zone rows for what was typed inside Time.
    ///
    /// Empty, it is the list you configured. Typing searches every zone on
    /// earth and ranks the two together, so a city you keep on the list wins
    /// over the same city found by search, and anywhere else is a word away.
    public static func timeZoneEntries(
        query: String,
        now: Date = Date(),
        localTimeZone: TimeZone = .current,
        settings: CommandBoxSettings = .default
    ) -> [CommandEntry] {
        let configured = timeEntries(now: now, localTimeZone: localTimeZone, settings: settings)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return configured
        }

        let known = Set(configured.compactMap(\.timeZoneIdentifier))
        let found = TimeZoneDirectory.search(trimmed)
            .filter { !known.contains($0.timeZone.identifier) }
            .map { foundZoneEntry($0, now: now) }

        return rankedByMatch(matching(configured, query: trimmed) + found, query: trimmed)
    }

    /// Found zones say where they are, since a city alone leaves `Cordoba` in
    /// Spain and `Cordoba` in Argentina looking identical.
    private static func foundZoneEntry(_ match: TimeZoneMatch, now: Date) -> CommandEntry {
        let text = CommandTransformerEngine.currentTime(in: match.timeZone, now: now)
        let place = placeLabel(for: match.timeZone, now: now, titled: match.city)

        return CommandEntry(
            id: "time.found.\(match.timeZone.identifier)",
            title: match.city,
            detail: place,
            action: .copyText(text),
            keywords: [match.timeZone.identifier, match.country].compactMap { $0 },
            marker: TimeZoneLocations.marker(for: match.timeZone, at: now),
            trailing: CommandTransformerEngine.wallClock(now, in: match.timeZone),
            layout: .detailed
        )
    }

    /// Where a zone is and how far from UTC, which is what tells two rows
    /// with similar names apart. A configured row is labelled whatever its
    /// owner called it, so the city is named here when it differs.
    /// Everything a zone can be found by: its identifier, its city and its
    /// country.
    private static func searchTerms(for timeZone: TimeZone) -> [String] {
        [
            timeZone.identifier,
            timeZone.identifier.replacingOccurrences(of: "_", with: " "),
            TimeZoneResolver.cityLabel(for: timeZone),
            TimeZoneDirectory.countryName(for: timeZone.identifier),
        ].compactMap { $0 }
    }

    private static func placeLabel(for timeZone: TimeZone, now: Date, titled title: String) -> String {
        let offset = CommandTransformerEngine.utcOffsetLabel(of: timeZone, at: now)
        let city = TimeZoneResolver.cityLabel(for: timeZone)
        let country = TimeZoneDirectory.countryName(for: timeZone.identifier)
        // The city is named only when the row is not already called that:
        // `San Francisco` is a label for the Los Angeles zone, while a found
        // `Rome` would only repeat itself.
        let place = (city == title || city == country) ? nil : city

        return [place, country, offset].compactMap { $0 }.joined(separator: " · ")
    }

    private static func rankedByMatch(_ entries: [CommandEntry], query: String) -> [CommandEntry] {
        entries
            .map { entry in
                (entry, FuzzyMatcher.bestScore(query, in: [entry.title] + entry.keywords) ?? 0)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

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

        // Shown in the order the config lists them, and in the same shape as
        // a zone the search finds: one list, one kind of row.
        return zones.map { zone in
            let text = CommandTransformerEngine.currentTime(in: zone.timeZone, now: now)

            return CommandEntry(
                id: "time.\(zone.label)",
                title: zone.label,
                detail: placeLabel(for: zone.timeZone, now: now, titled: zone.label),
                action: .copyText(text),
                // Findable by where it is, not only by what it was called:
                // a row labelled `Turkey` is still Istanbul in Türkiye, and
                // `San Francisco` is still the Los Angeles zone.
                keywords: searchTerms(for: zone.timeZone),
                marker: TimeZoneLocations.marker(for: zone.timeZone, at: now),
                opensSelected: zone.timeZone.identifier == localTimeZone.identifier,
                trailing: CommandTransformerEngine.wallClock(now, in: zone.timeZone),
                layout: .detailed
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
