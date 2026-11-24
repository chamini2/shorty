import Foundation

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

    private let fileURL: URL
    private let fileManager: FileManager
    private var paths: [String]?

    public init(fileURL: URL = RecentFileStore.defaultURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public static var defaultURL: URL {
        ClipboardHistoryStore.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("RecentFiles.json")
    }

    /// What was opened, newest first, skipping anything since moved away.
    public func recent() -> [String] {
        load().filter { fileManager.fileExists(atPath: $0) }
    }

    /// Records a file as the most recent, moving it up rather than repeating
    /// it when it was already there.
    public func record(_ path: String) {
        var updated = load().filter { $0 != path }
        updated.insert(path, at: 0)
        paths = Array(updated.prefix(Self.limit))
        write()
    }

    private func load() -> [String] {
        if let paths {
            return paths
        }

        let stored = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        paths = stored

        return stored
    }

    private func write() {
        guard let paths, let data = try? JSONEncoder().encode(paths) else {
            return
        }

        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic])
    }
}
