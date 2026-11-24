import Foundation

/// What a date expression worked out to.
public struct DateExpressionResult: Equatable, Sendable {
    /// The moment it names, when it names one.
    public let date: Date?
    /// What the expression started from: `Today, 4:18 PM`.
    public let base: String?
    /// The answer, as the row shows it: `7:18 PM`, or `31 days`.
    public let value: String
    /// What the answer means: `Today · Los Angeles`.
    public let valueDetail: String?

    public init(date: Date?, base: String?, value: String, valueDetail: String?) {
        self.date = date
        self.base = base
        self.value = value
        self.valueDetail = valueDetail
    }
}

/// Date arithmetic typed in words: `now - 1h in pst`, `today + 3d`,
/// `15:00 in tokyo`, `2026-12-25 - now`.
///
/// Months and years go through `Calendar` rather than multiplying seconds, so
/// a month later is the same day of the next month and an hour either side of
/// a daylight-saving change lands where a person would expect.
public enum DateExpression {
    public static func evaluate(
        _ text: String,
        now: Date = Date(),
        localTimeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> DateExpressionResult? {
        var parser = Parser(text: text, now: now, zone: localTimeZone)

        guard let parsed = parser.parse() else {
            return nil
        }

        switch parsed {
        case let .moment(date, zone, named):
            // `now` on its own is not arithmetic, and the Time list answers it
            // better than a row here would.
            guard named else {
                return nil
            }

            let shown = zone ?? localTimeZone

            return DateExpressionResult(
                date: date,
                base: describe(now, in: localTimeZone, now: now, locale: locale),
                value: clock(date, in: shown, locale: locale),
                valueDetail: detail(for: date, in: shown, now: now, named: zone != nil, locale: locale)
            )

        case let .span(seconds, from, to):
            return DateExpressionResult(
                date: nil,
                base: describe(from, in: localTimeZone, now: now, locale: locale),
                value: Self.describe(seconds: seconds),
                valueDetail: "until \(describe(to, in: localTimeZone, now: now, locale: locale))"
            )
        }
    }

    /// `3 days 4 hours`, down to the two units that matter: an answer in
    /// seconds is precise and unreadable.
    static func describe(seconds: TimeInterval) -> String {
        let total = Int(abs(seconds).rounded())
        let units: [(name: String, size: Int)] = [
            ("year", 365 * 24 * 3600),
            ("month", 30 * 24 * 3600),
            ("day", 24 * 3600),
            ("hour", 3600),
            ("minute", 60),
            ("second", 1),
        ]

        var remaining = total
        var parts: [String] = []

        for unit in units where parts.count < 2 {
            let count = remaining / unit.size

            guard count > 0 else {
                continue
            }

            remaining -= count * unit.size
            parts.append("\(count) \(unit.name)\(count == 1 ? "" : "s")")
        }

        let described = parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")

        return seconds < 0 ? "-\(described)" : described
    }

    private static func clock(_ date: Date, in zone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "HH:mm"

        return formatter.string(from: date)
    }

    /// `Today, 4:18 PM`, which is what a base is read as.
    private static func describe(_ date: Date, in zone: TimeZone, now: Date, locale: Locale) -> String {
        [day(date, in: zone, now: now, locale: locale), clock(date, in: zone, locale: locale)]
            .joined(separator: ", ")
    }

    /// What the answer lands on, and where: `Tomorrow · Tokyo`.
    private static func detail(
        for date: Date,
        in zone: TimeZone,
        now: Date,
        named: Bool,
        locale: Locale
    ) -> String {
        let parts = [
            day(date, in: zone, now: now, locale: locale),
            named ? TimeZoneResolver.cityLabel(for: zone) ?? zone.identifier : nil,
        ]

        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// `Today`, `Tomorrow`, `Yesterday`, or the date itself.
    private static func day(_ date: Date, in zone: TimeZone, now: Date, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = locale

        // Counted against the moment being worked from, not against the real
        // clock: `isDateInToday` asks the system what day it is, which made
        // every answer wrong whenever the two differed.
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day

        switch days {
        case 0:
            return "Today"
        case 1:
            return "Tomorrow"
        case -1:
            return "Yesterday"
        default:
            break
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: sameYear ? "EEEMMMd" : "MMMdyyyy",
            options: 0,
            locale: locale
        ) ?? "yyyy-MM-dd"

        return formatter.string(from: date)
    }
}

/// Reads `now - 1h in pst` left to right.
private struct Parser {
    enum Parsed {
        /// A moment, the zone it should be read in, and whether the
        /// expression did more than name the current time.
        case moment(Date, TimeZone?, named: Bool)
        /// The gap between two moments.
        case span(TimeInterval, from: Date, to: Date)
    }

    private let words: [String]
    private let now: Date
    private let zone: TimeZone
    private var index = 0
    /// `now` alone is the current time, which the Time list answers better.
    private var baseWasNow = false

    init(text: String, now: Date, zone: TimeZone) {
        // Split on spaces and on the signs, so `now-1h` reads the same as
        // `now - 1h`. The hyphens inside a date are not signs, so those are
        // put aside first: `2026-12-25` is one word, not three numbers.
        let dates = try? NSRegularExpression(pattern: "\\d{4}-\\d{2}-\\d{2}")
        var protected = text
        var held: [String] = []

        if let dates {
            let range = NSRange(protected.startIndex..., in: protected)

            for match in dates.matches(in: protected, range: range).reversed() {
                guard let found = Range(match.range, in: protected) else {
                    continue
                }

                held.insert(String(protected[found]), at: 0)
                protected.replaceSubrange(found, with: "\u{1}")
            }
        }

        let spaced = protected
            .replacingOccurrences(of: "+", with: " + ")
            .replacingOccurrences(of: "-", with: " - ")
        var tokens = spaced.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        var remaining = held

        for position in tokens.indices where tokens[position] == "\u{1}" {
            tokens[position] = remaining.isEmpty ? "" : remaining.removeFirst()
        }

        words = tokens
        self.now = now
        self.zone = zone
    }

    mutating func parse() -> Parsed? {
        guard var current = parseBase() else {
            return nil
        }

        var didArithmetic = false

        while index < words.count {
            let word = words[index]

            if word == "in", let named = parseZone() {
                guard index >= words.count else {
                    return nil
                }

                return .moment(current, named, named: true)
            }

            guard word == "+" || word == "-" else {
                return nil
            }

            index += 1

            if let interval = parseInterval(negated: word == "-") {
                guard let moved = interval.applied(to: current) else {
                    return nil
                }

                current = moved
                didArithmetic = true
                continue
            }

            // Not an interval, so the other side is a moment and the answer
            // is the gap between them: `2026-12-25 - now`.
            guard word == "-", let other = parseBase(), index >= words.count else {
                return nil
            }

            return .span(current.timeIntervalSince(other), from: other, to: current)
        }

        return .moment(current, nil, named: didArithmetic || !baseWasNow)
    }

    private mutating func parseZone() -> TimeZone? {
        let remaining = words[(index + 1)...].joined(separator: " ")

        guard !remaining.isEmpty, let match = TimeZoneDirectory.search(remaining, limit: 1).first else {
            return nil
        }

        index = words.count

        return match.timeZone
    }

    private mutating func parseBase() -> Date? {
        guard index < words.count else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        switch words[index] {
        case "now":
            index += 1
            baseWasNow = true
            return now
        case "today":
            index += 1
            return calendar.startOfDay(for: now)
        case "tomorrow":
            index += 1
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case "yesterday":
            index += 1
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        default:
            break
        }

        if let stamp = parseStamp(calendar: calendar) {
            return stamp
        }

        return nil
    }

    /// A clock time, a date, or an epoch.
    private mutating func parseStamp(calendar: Calendar) -> Date? {
        let word = words[index]

        // Epoch seconds, which the box already converts but which can anchor
        // arithmetic here.
        if word.count == 10, let seconds = TimeInterval(word) {
            index += 1
            return Date(timeIntervalSince1970: seconds)
        }

        if let date = parseDate(word, calendar: calendar) {
            index += 1

            // `2026-12-25 15:00`
            if index < words.count, let time = clockComponents(words[index]) {
                index += 1
                return calendar.date(
                    bySettingHour: time.hour,
                    minute: time.minute,
                    second: 0,
                    of: date
                )
            }

            return date
        }

        if let time = clockComponents(word) {
            index += 1
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now)
        }

        return nil
    }

    private func parseDate(_ word: String, calendar: Calendar) -> Date? {
        let parts = word.split(separator: "-", omittingEmptySubsequences: false)

        guard parts.count == 3,
              let year = Int(parts[0]), parts[0].count == 4,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// `15:00`, `3pm`, `3:30pm`.
    private func clockComponents(_ word: String) -> (hour: Int, minute: Int)? {
        var text = word
        var afternoon: Bool?

        if text.hasSuffix("pm") {
            afternoon = true
            text.removeLast(2)
        } else if text.hasSuffix("am") {
            afternoon = false
            text.removeLast(2)
        }

        let parts = text.split(separator: ":")

        guard let hour = Int(parts.first ?? ""), hour >= 0, hour <= 23 else {
            return nil
        }

        let minute = parts.count > 1 ? Int(parts[1]) ?? -1 : 0

        guard minute >= 0, minute < 60 else {
            return nil
        }

        // A bare number is only a time when it is written as one or carries
        // am or pm: `3` is not half past two in the morning.
        guard parts.count > 1 || afternoon != nil else {
            return nil
        }

        switch afternoon {
        case true:
            return (hour == 12 ? 12 : hour + 12, minute)
        case false:
            return (hour == 12 ? 0 : hour, minute)
        default:
            return (hour, minute)
        }
    }

    private struct Interval {
        let value: Int
        let component: Calendar.Component
        let zone: TimeZone

        func applied(to date: Date) -> Date? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone

            return calendar.date(byAdding: component, value: value, to: date)
        }
    }

    /// `1h`, `30m`, `2 days`, `3mo`.
    private mutating func parseInterval(negated: Bool) -> Interval? {
        guard index < words.count else {
            return nil
        }

        let word = words[index]
        let digits = word.prefix { $0.isNumber }

        guard let amount = Int(digits) else {
            return nil
        }

        var unit = String(word.dropFirst(digits.count))

        // `2 days` as well as `2days`.
        if unit.isEmpty {
            guard index + 1 < words.count, let next = Self.components[words[index + 1]] else {
                return nil
            }

            index += 2

            return Interval(value: negated ? -amount : amount, component: next, zone: zone)
        }

        unit = unit.trimmingCharacters(in: .whitespaces)

        guard let component = Self.components[unit] else {
            return nil
        }

        index += 1

        return Interval(value: negated ? -amount : amount, component: component, zone: zone)
    }

    /// `mo` is months and `m` is minutes, which is the one place this syntax
    /// has to pick a side: a clipboard box is asked for minutes far more
    /// often than for months.
    private static let components: [String: Calendar.Component] = [
        "s": .second, "sec": .second, "secs": .second, "second": .second, "seconds": .second,
        "m": .minute, "min": .minute, "mins": .minute, "minute": .minute, "minutes": .minute,
        "h": .hour, "hr": .hour, "hrs": .hour, "hour": .hour, "hours": .hour,
        "d": .day, "day": .day, "days": .day,
        "w": .weekOfYear, "wk": .weekOfYear, "week": .weekOfYear, "weeks": .weekOfYear,
        "mo": .month, "mon": .month, "month": .month, "months": .month,
        "y": .year, "yr": .year, "year": .year, "years": .year,
    ]
}
