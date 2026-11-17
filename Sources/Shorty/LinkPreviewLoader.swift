import AppKit
import LinkPresentation

/// Fetches the title, icon and image behind a copied link, so the detail pane
/// can show what the link is rather than only its address.
///
/// Fetching happens for the entry you select and nowhere else, and each answer
/// is kept for the life of the session, so moving up and down the list does
/// not hit a site again. Failures are remembered too: a link that cannot be
/// read should not be retried on every keypress.
@MainActor
final class LinkPreviewLoader {
    enum Result {
        case metadata(LPLinkMetadata)
        case unavailable
    }

    private var cache: [URL: Result] = [:]
    private var inFlight: [URL: LPMetadataProvider] = [:]

    func cached(for url: URL) -> Result? {
        cache[url]
    }

    /// Calls back on the main actor, and only for the newest request of a URL.
    func load(_ url: URL, completion: @escaping (Result) -> Void) {
        if let cached = cache[url] {
            completion(cached)
            return
        }

        guard inFlight[url] == nil else {
            return
        }

        let provider = LPMetadataProvider()
        provider.timeout = 6
        inFlight[url] = provider

        // `LPLinkMetadata` and the callback are not Sendable, and the
        // provider answers on a queue of its own. They are carried over to the
        // main actor untouched and only read there.
        let handler = Unchecked(completion)

        provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
            let fetched = Unchecked(metadata)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }

                    self.inFlight[url] = nil
                    let result: Result = fetched.value.map(Result.metadata) ?? .unavailable
                    self.cache[url] = result
                    handler.value(result)
                }
            }
        }
    }

    /// Carries a value between queues that the compiler cannot prove safe,
    /// where the code around it keeps the value on one actor.
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    func cancelAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }
}
