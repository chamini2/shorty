import Foundation

/// What a page says about itself, as the social sites read it: the card they
/// unfurl comes from `og:` meta tags, with a few older fallbacks.
public struct LinkCard: Equatable, Sendable {
    public let url: URL
    public let title: String?
    public let summary: String?
    public let siteName: String?
    public let imageURL: URL?

    public init(
        url: URL,
        title: String? = nil,
        summary: String? = nil,
        siteName: String? = nil,
        imageURL: URL? = nil
    ) {
        self.url = url
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.imageURL = imageURL
    }

    /// A page that said nothing about itself. Showing an empty card would be
    /// worse than showing the address alone.
    public var isEmpty: Bool {
        title == nil && summary == nil && imageURL == nil
    }
}

/// Reads the card a page offers to anyone linking to it.
///
/// Open Graph first, since that is what the page author wrote for exactly
/// this; then Twitter's variant, which many sites set instead; then the plain
/// `<title>` and description, which every page has.
public enum OpenGraphParser {
    public static func card(html: String, from url: URL) -> LinkCard {
        let tags = metaTags(in: html)

        let title = tags["og:title"] ?? tags["twitter:title"] ?? documentTitle(in: html)
        let summary = tags["og:description"] ?? tags["twitter:description"] ?? tags["description"]
        let siteName = tags["og:site_name"] ?? url.host
        let image = tags["og:image"]
            ?? tags["og:image:url"]
            ?? tags["twitter:image"]
            ?? tags["twitter:image:src"]

        return LinkCard(
            url: url,
            title: title,
            summary: summary,
            siteName: siteName,
            // Pages are free to write `/card.png`, which only means anything
            // against the page it came from.
            imageURL: image.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        )
    }

    /// Every `<meta>` in the document, keyed by its `property` or `name`.
    /// First one wins: a page repeating `og:image` is listing alternatives,
    /// and the first is the one it leads with.
    private static func metaTags(in html: String) -> [String: String] {
        var tags: [String: String] = [:]

        for tag in matches(of: Self.metaPattern, in: html) {
            let attributes = self.attributes(in: tag)

            guard let key = attributes["property"] ?? attributes["name"],
                  let content = attributes["content"],
                  !content.isEmpty else {
                continue
            }

            let normalized = key.lowercased()

            if tags[normalized] == nil {
                tags[normalized] = content
            }
        }

        return tags
    }

    private static func attributes(in tag: String) -> [String: String] {
        var attributes: [String: String] = [:]

        guard let expression = try? NSRegularExpression(pattern: Self.attributePattern, options: [.caseInsensitive]) else {
            return attributes
        }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)

        for match in expression.matches(in: tag, range: range) {
            guard let name = capture(1, of: match, in: tag)?.lowercased() else {
                continue
            }

            // Quoted or bare, whichever of the three alternatives matched.
            let value = (2...4)
                .compactMap { capture($0, of: match, in: tag) }
                .first

            guard let value else {
                continue
            }

            attributes[name] = HTMLText.decoding(value)
        }

        return attributes
    }

    private static func documentTitle(in html: String) -> String? {
        guard let match = matches(of: Self.titlePattern, in: html).first else {
            return nil
        }

        // The pattern keeps the tags; the text between them is what is wanted.
        let text = match
            .replacingOccurrences(of: "<title", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "</title>", with: "", options: [.caseInsensitive])
        let body = text.drop { $0 != ">" }.dropFirst()
        let decoded = HTMLText.decoding(String(body))

        return decoded.isEmpty ? nil : decoded
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func capture(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: text) else {
            return nil
        }

        return String(text[range])
    }

    private static let metaPattern = "<meta\\b[^>]*>"
    private static let titlePattern = "<title\\b[^>]*>.*?</title>"
    private static let attributePattern = "([a-zA-Z:_-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
}

/// Turns the escapes a page writes back into the text it meant.
enum HTMLText {
    static func decoding(_ text: String) -> String {
        let unescaped = text.contains("&") ? unescape(text) : text

        return unescaped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)

        while let start = rest.firstIndex(of: "&") {
            result += rest[rest.startIndex..<start]
            rest = rest[start...]

            guard let end = rest.firstIndex(of: ";"),
                  rest.distance(from: start, to: end) <= maximumEntityLength else {
                // A bare `&`, which pages write all the time.
                result.append("&")
                rest = rest.dropFirst()
                continue
            }

            let entity = String(rest[rest.index(after: start)..<end])
            result += replacement(for: entity) ?? "&\(entity);"
            rest = rest[rest.index(after: end)...]
        }

        return result + rest
    }

    private static func replacement(for entity: String) -> String? {
        if let named = namedEntities[entity] {
            return named
        }

        guard entity.hasPrefix("#") else {
            return nil
        }

        let digits = entity.dropFirst()
        let scalarValue: UInt32?

        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            scalarValue = UInt32(digits.dropFirst(), radix: 16)
        } else {
            scalarValue = UInt32(digits)
        }

        return scalarValue
            .flatMap(Unicode.Scalar.init)
            .map { String(Character($0)) }
    }

    /// The handful worth knowing: anything rarer reads fine as written.
    private static let namedEntities: [String: String] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "nbsp": "\u{00A0}",
        "hellip": "…",
        "mdash": "—",
        "ndash": "–",
        "rsquo": "’",
        "lsquo": "‘",
        "rdquo": "”",
        "ldquo": "“",
    ]

    private static let maximumEntityLength = 10
}
