import Foundation

/// How often each app has been opened through Shorty.
///
/// The list of apps is alphabetical, which is predictable but puts the six
/// you actually launch wherever their names fall. This is what lifts them.
public final class RecentAppStore {
    private let apps: RecentAppDatabase?

    public init(database: ShortyDatabase? = .shared) {
        apps = database.map { RecentAppDatabase(database: $0) }
    }

    public func record(_ path: String) {
        try? apps?.record(path)
    }

    public func opens() -> [String: Int] {
        (try? apps?.opens()) ?? [:]
    }
}

/// The files opened through Shorty, newest first.
///
/// Spotlight knows what the machine opened, but not what you reached for
/// here, and the two answer different questions: one is everything you have
/// touched, the other is the handful you came to this box for. Kept beside
/// the history, so it survives a restart.
public final class RecentFileStore {
    /// Enough to remember a working set, few enough that it stays a short
    /// list rather than a second history.
    public static let limit = 20

    private let recents: RecentFileDatabase?

    public init(database: ShortyDatabase? = .shared) {
        recents = database.map { RecentFileDatabase(database: $0) }
    }

    /// A store of its own, rooted beside the given file.
    public convenience init(fileURL: URL) {
        self.init(
            database: try? ShortyDatabase(
                url: fileURL.deletingLastPathComponent().appendingPathComponent("Shorty.sqlite")
            )
        )
    }

    /// What was opened, newest first, skipping anything since moved away.
    public func recent() -> [String] {
        (try? recents?.recent(limit: Self.limit)) ?? []
    }

    /// Records a file as the most recent, moving it up rather than repeating
    /// it when it was already there.
    public func record(_ path: String) {
        try? recents?.record(path, limit: Self.limit)
    }
}
