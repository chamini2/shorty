import Foundation

/// Scores how well a query matches a candidate, so `sf` finds San Francisco
/// and `maxi` finds Maximize. Written out rather than taken from a package:
/// it is eighty lines of pure Swift against a dependency to track and trust.
///
/// A match needs every query character to appear in order. The score then
/// rewards the things that make a match feel deliberate: starting a word,
/// running consecutively, sitting near the front, and matching a short name.
public enum FuzzyMatcher {
    public enum Score {
        static let exact = 1_000
        static let prefix = 400
        static let substring = 200
        static let wordStart = 60
        static let consecutive = 25
        static let gapPenalty = 3
        static let lateStartPenalty = 2
        static let lengthPenalty = 1
    }

    /// `nil` when the query does not match at all.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let needle = normalized(query)
        let haystack = normalized(candidate)

        guard !needle.isEmpty else {
            return 0
        }

        guard !haystack.isEmpty else {
            return nil
        }

        if needle == haystack {
            return Score.exact
        }

        if haystack.hasPrefix(needle) {
            return Score.prefix - haystack.count * Score.lengthPenalty
        }

        if let range = haystack.range(of: needle) {
            let start = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            return Score.substring
                + (isWordStart(haystack, offset: start) ? Score.wordStart : 0)
                - start * Score.lateStartPenalty
                - haystack.count * Score.lengthPenalty
        }

        return subsequenceScore(needle: Array(needle), haystack: Array(haystack))
    }

    /// The best score across several names, such as a title and its keywords.
    public static func bestScore(_ query: String, in candidates: [String]) -> Int? {
        candidates.compactMap { score(query, in: $0) }.max()
    }

    private static func subsequenceScore(needle: [Character], haystack: [Character]) -> Int? {
        var total = 0
        var needleIndex = 0
        var previousMatch: Int?

        for (offset, character) in haystack.enumerated() {
            guard needleIndex < needle.count, character == needle[needleIndex] else {
                continue
            }

            if isWordStart(haystack, offset: offset) {
                total += Score.wordStart
            }

            if let previousMatch, previousMatch == offset - 1 {
                total += Score.consecutive
            } else if let previousMatch {
                total -= min((offset - previousMatch - 1) * Score.gapPenalty, Score.wordStart)
            } else {
                total -= offset * Score.lateStartPenalty
            }

            previousMatch = offset
            needleIndex += 1
        }

        guard needleIndex == needle.count else {
            return nil
        }

        return total - haystack.count * Score.lengthPenalty
    }

    private static func isWordStart(_ characters: [Character], offset: Int) -> Bool {
        guard offset > 0 else {
            return true
        }

        return isSeparator(characters[offset - 1])
    }

    private static func isWordStart(_ value: String, offset: Int) -> Bool {
        isWordStart(Array(value), offset: offset)
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == " " || character == "-" || character == "_" || character == "/" || character == "."
    }

    /// Case and accent insensitive, so `tokio` still reaches `Tōkyō`.
    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}
