import Foundation

/// The apps opened through Shorty, as rows.
///
/// Counted as well as dated: an app opened twice a day for a month is one
/// you want near the top even on a morning you have not reached for it yet.
struct RecentAppDatabase {
    let database: ShortyDatabase

    func record(_ path: String, at date: Date = Date()) throws {
        try database.locked {
            try database.sqlite.run(
                """
                INSERT INTO recent_apps (path, opened_at, opens) VALUES (?, ?, 1)
                ON CONFLICT(path) DO UPDATE SET
                    opened_at = excluded.opened_at,
                    opens = opens + 1
                """,
                [.text(path), .real(date.timeIntervalSince1970)]
            )
        }
    }

    /// How often each app has been opened, by path.
    func opens() throws -> [String: Int] {
        try database.locked {
            let rows = try database.sqlite.query("SELECT path, opens FROM recent_apps")

            return Dictionary(
                uniqueKeysWithValues: rows.compactMap { row in
                    guard let path = row[0].string, let opens = row[1].int else {
                        return nil
                    }

                    return (path, Int(opens))
                }
            )
        }
    }
}

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
