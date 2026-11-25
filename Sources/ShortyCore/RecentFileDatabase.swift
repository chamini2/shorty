import Foundation

/// The files opened through Shorty, as rows.
///
/// "Move it up rather than repeat it" is the whole rule, and it is one
/// statement here instead of a filter and a rewrite.
struct RecentFileDatabase {
    let database: ShortyDatabase

    func record(_ path: String, at date: Date = Date(), limit: Int) throws {
        try database.locked {
            try database.sqlite.transaction {
                try database.sqlite.run(
                    """
                    INSERT INTO recent_files (path, opened_at) VALUES (?, ?)
                    ON CONFLICT(path) DO UPDATE SET opened_at = excluded.opened_at
                    """,
                    [.text(path), .real(date.timeIntervalSince1970)]
                )

                try database.sqlite.run(
                    """
                    DELETE FROM recent_files WHERE path NOT IN (
                        SELECT path FROM recent_files ORDER BY opened_at DESC LIMIT ?
                    )
                    """,
                    [.integer(Int64(limit))]
                )
            }
        }
    }

    /// Used during migration, where the cap is applied once at the end.
    func record(_ path: String, at date: Date) throws {
        try database.locked {
            try database.sqlite.run(
                """
                INSERT INTO recent_files (path, opened_at) VALUES (?, ?)
                ON CONFLICT(path) DO UPDATE SET opened_at = excluded.opened_at
                """,
                [.text(path), .real(date.timeIntervalSince1970)]
            )
        }
    }

    /// Newest first, skipping anything since moved away.
    func recent(limit: Int, fileManager: FileManager = .default) throws -> [String] {
        try database.locked {
            try database.sqlite
                .query(
                    "SELECT path FROM recent_files ORDER BY opened_at DESC LIMIT ?",
                    [.integer(Int64(limit))]
                )
                .compactMap { $0[0].string }
                .filter { fileManager.fileExists(atPath: $0) }
        }
    }
}
