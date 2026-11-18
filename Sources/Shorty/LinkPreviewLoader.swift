import AppKit
import ShortyCore

/// Fetches the card a page offers about itself, so the detail pane can show
/// what a link is rather than only where it points.
///
/// This is the card the social sites unfurl: the page's own `og:` tags, read
/// straight from its HTML. Fetching happens for the entry you select and
/// nowhere else, and each answer is kept for the life of the session, so
/// moving up and down the list does not hit a site again. Failures are
/// remembered too: a link that cannot be read should not be retried on every
/// keypress.
@MainActor
final class LinkPreviewLoader {
    enum Result {
        case card(LinkCard, image: NSImage?)
        case unavailable
    }

    private var cache: [URL: Result] = [:]
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var waiting: [URL: [(Result) -> Void]] = [:]
    private let store: LinkCardStore

    init(store: LinkCardStore = LinkCardStore()) {
        self.store = store
    }

    /// What is already known: this session's answers first, then the ones
    /// kept on disk from earlier runs.
    func cached(for url: URL) -> Result? {
        if let result = cache[url] {
            return result
        }

        guard let record = store.record(for: url) else {
            return nil
        }

        let result: Result = record.failed
            ? .unavailable
            : .card(record.card(for: url), image: store.imageData(for: record).flatMap(NSImage.init(data:)))

        cache[url] = result

        return result
    }

    /// Calls back on the main actor, once, for every caller that asked.
    func load(_ url: URL, completion: @escaping (Result) -> Void) {
        if let known = cached(for: url) {
            completion(known)
            return
        }

        waiting[url, default: []].append(completion)

        guard tasks[url] == nil else {
            return
        }

        tasks[url] = Task { [weak self] in
            let fetched = await Self.fetch(url)

            guard let self else {
                return
            }

            self.finish(url, with: fetched)
        }
    }

    private func finish(_ url: URL, with fetched: FetchedCard?) {
        tasks[url] = nil

        let result: Result

        if let fetched {
            result = .card(fetched.card, image: fetched.imageData.flatMap(NSImage.init(data:)))
        } else {
            result = .unavailable
        }

        // Kept on disk as well, so the next run of the app already knows.
        store.save(fetched?.card, imageData: fetched?.imageData, for: url)
        cache[url] = result
        let handlers = waiting.removeValue(forKey: url) ?? []
        handlers.forEach { $0(result) }
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        waiting.removeAll()
    }

    /// Carried back to the main actor: bytes and a card, never a drawn image.
    private struct FetchedCard: Sendable {
        let card: LinkCard
        let imageData: Data?
    }

    private static func fetch(_ url: URL) async -> FetchedCard? {
        guard let html = await html(at: url) else {
            return nil
        }

        let card = OpenGraphParser.card(html: html, from: url)

        guard !card.isEmpty else {
            return nil
        }

        // The page's own picture when it has one, its icon when it does not:
        // a card with a site's mark still reads better than a bare address.
        guard let pictureURL = card.pictureURL else {
            return FetchedCard(card: card, imageData: nil)
        }

        return FetchedCard(card: card, imageData: await imageData(at: pictureURL))
    }

    private static func html(at url: URL) async -> String? {
        // The head is all that matters, and it comes first: asking for the
        // opening stretch keeps a long page from being pulled down whole.
        var request = Self.request(for: url)
        request.setValue("bytes=0-\(Self.headByteLimit)", forHTTPHeaderField: "Range")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        guard let data = await bytes(for: request, limit: Self.headByteLimit) else {
            return nil
        }

        // Pages still ship in the older encodings, where the bytes are valid
        // but not UTF-8; Latin-1 at least keeps the markup readable.
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func imageData(at url: URL) async -> Data? {
        await bytes(for: request(for: url), limit: imageByteLimit)
    }

    private static func bytes(for request: URLRequest, limit: Int) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return nil
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }

        return data.count > limit ? data.prefix(limit) : data
    }

    private static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // Sites hand a plain client the real page; some answer an empty shell
        // to anything that does not look like a browser.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static let timeout: TimeInterval = 6
    /// Enough for any `<head>` worth reading.
    private static let headByteLimit = 256 * 1024
    private static let imageByteLimit = 8 * 1024 * 1024
    private static let userAgent = """
    Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 \
    (KHTML, like Gecko) Version/17.0 Safari/605.1.15
    """
}
