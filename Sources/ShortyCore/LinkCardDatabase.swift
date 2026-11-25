import Foundation

/// Link cards as rows.
///
/// Expiry is a statement rather than a read-filter-rewrite: cards were kept
/// in one index file that the eager prefetch rewrote once per card fetched.
struct LinkCardDatabase {
    let database: ShortyDatabase

    func write(_ record: LinkCardRecord, for key: String) throws {
        try database.locked {
            try database.sqlite.run(
                """
                INSERT INTO link_cards (url, title, summary, site_name, image_file, fetched_at, failed)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    title = excluded.title,
                    summary = excluded.summary,
                    site_name = excluded.site_name,
                    image_file = excluded.image_file,
                    fetched_at = excluded.fetched_at,
                    failed = excluded.failed
                """,
                [
                    .text(key),
                    record.title.map(SQLiteValue.text) ?? .null,
                    record.summary.map(SQLiteValue.text) ?? .null,
                    record.siteName.map(SQLiteValue.text) ?? .null,
                    record.imageFileName.map(SQLiteValue.text) ?? .null,
                    .real(record.fetchedAt.timeIntervalSince1970),
                    .integer(record.failed ? 1 : 0),
                ]
            )
        }
    }

    func record(for key: String) throws -> LinkCardRecord? {
        try database.locked {
            let rows = try database.sqlite.query(
                """
                SELECT title, summary, site_name, image_file, fetched_at, failed
                FROM link_cards WHERE url = ?
                """,
                [.text(key)]
            )

            guard let row = rows.first else {
                return nil
            }

            return LinkCardRecord(
                title: row[0].string,
                summary: row[1].string,
                siteName: row[2].string,
                imageFileName: row[3].string,
                fetchedAt: Date(timeIntervalSince1970: row[4].double ?? 0),
                failed: row[5].int == 1
            )
        }
    }

    /// Drops what has gone stale and what is oldest past the cap, and reports
    /// the pictures still spoken for so the rest can be swept.
    func prune(
        now: Date,
        successLife: TimeInterval,
        failureLife: TimeInterval,
        limit: Int
    ) throws -> Set<String> {
        try database.locked {
            try database.sqlite.transaction {
                try database.sqlite.run(
                    """
                    DELETE FROM link_cards
                    WHERE (failed = 0 AND fetched_at < ?)
                       OR (failed = 1 AND fetched_at < ?)
                    """,
                    [
                        .real(now.addingTimeInterval(-successLife).timeIntervalSince1970),
                        .real(now.addingTimeInterval(-failureLife).timeIntervalSince1970),
                    ]
                )

                try database.sqlite.run(
                    """
                    DELETE FROM link_cards WHERE url NOT IN (
                        SELECT url FROM link_cards ORDER BY fetched_at DESC LIMIT ?
                    )
                    """,
                    [.integer(Int64(limit))]
                )
            }

            let rows = try database.sqlite.query(
                "SELECT image_file FROM link_cards WHERE image_file IS NOT NULL"
            )

            return Set(rows.compactMap { $0[0].string })
        }
    }

    func count() throws -> Int {
        try database.locked {
            Int(try database.sqlite.query("SELECT COUNT(*) FROM link_cards").first?.first?.int ?? 0)
        }
    }
}
