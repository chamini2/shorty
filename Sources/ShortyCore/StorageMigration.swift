import Foundation

/// Moves what the JSON files held into the database, once.
///
/// Each file is imported in a single transaction and then renamed rather than
/// deleted: a migration that goes wrong should cost a rename to undo, not a
/// history. Nothing re-imports afterwards, since the renamed file is no
/// longer where the importer looks.
public enum StorageMigration {
    public static let suffix = "migrated"

    /// Imports whatever is still in JSON. Safe to call on every launch.
    @discardableResult
    public static func run(
        into database: ShortyDatabase,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [String] {
        // Beside the database unless told otherwise, so a database in a
        // scratch directory can never reach the real files.
        let directory = directory ?? database.directory
        var migrated: [String] = []

        if importHistory(into: database, directory: directory, fileManager: fileManager) {
            migrated.append("clipboard history")
        }

        if importLinkCards(into: database, directory: directory, fileManager: fileManager) {
            migrated.append("link cards")
        }

        if importRecentFiles(into: database, directory: directory, fileManager: fileManager) {
            migrated.append("recent files")
        }

        return migrated
    }

    private static func importHistory(
        into database: ShortyDatabase,
        directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let url = directory.appendingPathComponent("ClipboardHistory.json")

        guard let items: [ClipboardItem] = decode(url, fileManager: fileManager) else {
            return false
        }

        let history = ClipboardHistoryDatabase(database: database)

        do {
            try database.locked {
                try database.sqlite.transaction {
                    for item in items {
                        try history.write(item)
                    }
                }
            }
        } catch {
            return false
        }

        retire(url, fileManager: fileManager)

        return true
    }

    private static func importLinkCards(
        into database: ShortyDatabase,
        directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let url = directory
            .appendingPathComponent("LinkCards", isDirectory: true)
            .appendingPathComponent("Index.json")

        guard let records: [String: LinkCardRecord] = decode(url, fileManager: fileManager, iso8601: true) else {
            return false
        }

        let cards = LinkCardDatabase(database: database)

        do {
            try database.locked {
                try database.sqlite.transaction {
                    for (key, record) in records {
                        try cards.write(record, for: key)
                    }
                }
            }
        } catch {
            return false
        }

        retire(url, fileManager: fileManager)

        return true
    }

    private static func importRecentFiles(
        into database: ShortyDatabase,
        directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let url = directory.appendingPathComponent("RecentFiles.json")

        guard let paths: [String] = decode(url, fileManager: fileManager) else {
            return false
        }

        let recents = RecentFileDatabase(database: database)

        do {
            try database.locked {
                try database.sqlite.transaction {
                    // The list was newest first and carried no times, so they
                    // are invented in order: only the order ever mattered.
                    for (offset, path) in paths.enumerated() {
                        try recents.record(path, at: Date(timeIntervalSinceNow: -Double(offset)))
                    }
                }
            }
        } catch {
            return false
        }

        retire(url, fileManager: fileManager)

        return true
    }

    private static func decode<Value: Decodable>(
        _ url: URL,
        fileManager: FileManager,
        iso8601: Bool = false
    ) -> Value? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()

        if iso8601 {
            decoder.dateDecodingStrategy = .iso8601
        }

        return try? decoder.decode(Value.self, from: data)
    }

    /// Kept, not deleted: a bad migration should be undone with a rename.
    private static func retire(_ url: URL, fileManager: FileManager) {
        let backup = url.appendingPathExtension(suffix)
        try? fileManager.removeItem(at: backup)
        try? fileManager.moveItem(at: url, to: backup)
    }
}
