import Foundation

/// A file Spotlight knows about.
public struct FileHit: Equatable, Sendable, Identifiable {
    public let name: String
    public let path: String
    /// The folder it sits in, shown beside the name so two files of the same
    /// name can be told apart.
    public let folder: String

    public init(name: String, path: String, folder: String) {
        self.name = name
        self.path = path
        self.folder = folder
    }

    public var id: String {
        "file.\(path)"
    }

    /// The path as a person writes it: home as a tilde, and the file's own
    /// name left off since the row shows that above.
    public var displayPath: String {
        let parent = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()

        guard parent.hasPrefix(home) else {
            return parent
        }

        return "~" + parent.dropFirst(home.count)
    }
}

/// Searches the Spotlight index, which is the only way to answer in the time
/// a keystroke allows: walking the disk takes seconds, and the index takes
/// about a tenth of one.
///
/// Names and contents both count, the way Spotlight itself works, so a file
/// can be found by a phrase inside it. Only the home folder is searched: the
/// rest of the index is the system talking to itself.
@MainActor
public final class FileSearcher {
    /// The most recently changed few. A loose word matches thousands, and
    /// nobody reads past the first handful.
    public static let resultLimit = 10
    /// Long enough that a typed word is one search rather than six.
    public static let debounce: TimeInterval = 0.12
    /// Below this a query matches most of the disk and means nothing.
    public static let minimumQueryLength = 2

    /// Read before filtering, since most of what Spotlight returns for a
    /// common word is machinery rather than anything to open.
    private static let scannedResults = 200

    /// Caches, application support and the rest of `Library` are the
    /// computer's files, not yours. A content search finds a browser's blob
    /// storage for almost any word otherwise.
    nonisolated static func isWorthShowing(_ path: String) -> Bool {
        !path.contains("/Library/")
            && !path.contains("/.")
            && !path.contains("/node_modules/")
    }

    private var searchText = ""
    private var query: NSMetadataQuery?
    private var pending: DispatchWorkItem?
    private var handler: (([FileHit]) -> Void)?

    public init() {}

    /// Answers with the newest matches, or with nothing when the query is too
    /// short to mean anything. Only the latest search of a run reports back.
    public func search(_ text: String, completion: @escaping ([FileHit]) -> Void) {
        pending?.cancel()
        stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= Self.minimumQueryLength else {
            completion([])
            return
        }

        handler = completion

        let work = DispatchWorkItem { [weak self] in
            self?.start(trimmed)
        }

        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
        handler = nil
        stop()
    }

    private func start(_ text: String) {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "kMDItemFSName LIKE[cd] %@ OR kMDItemTextContent CONTAINS[cd] %@",
            "*\(text)*",
            text
        )
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false),
        ]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gathered),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )

        self.query = query
        searchText = text
        query.start()
    }

    @objc
    private func gathered(_ notification: Notification) {
        guard let query, let handler else {
            return
        }

        query.disableUpdates()

        // More than will be shown, since the junk is filtered out afterwards
        // and a name match can sit well down a list sorted by date.
        let candidates = (0..<min(Self.scannedResults, query.resultCount)).compactMap { index -> FileHit? in
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  Self.isWorthShowing(path) else {
                return nil
            }

            let url = URL(fileURLWithPath: path)

            return FileHit(
                name: item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? url.lastPathComponent,
                path: path,
                folder: url.deletingLastPathComponent().lastPathComponent
            )
        }

        let text = searchText
        // A file whose name matches is what was meant; one that merely
        // mentions the word comes after. Among the name matches the closest
        // name wins, so searching `shorty` finds the folder called exactly
        // that before the dozen files whose names merely start with it.
        let named = candidates
            .compactMap { hit -> (hit: FileHit, score: Int)? in
                FuzzyMatcher.bestScore(text, in: [hit.name]).map { (hit, $0) }
            }
            .sorted { $0.score > $1.score }
            .map(\.hit)
        let mentioned = candidates.filter { hit in
            FuzzyMatcher.bestScore(text, in: [hit.name]) == nil
        }
        let ranked = named + mentioned

        stop()
        handler(Array(ranked.prefix(Self.resultLimit)))
    }

    private func stop() {
        guard let query else {
            return
        }

        NotificationCenter.default.removeObserver(
            self,
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        query.stop()
        self.query = nil
    }
}
