import Foundation

/// Everything Shorty remembers between launches, in one file.
///
/// It used to be three JSON documents, each rewritten whole on every change.
/// That is fine for a short list and wrong for a long one: at ten thousand
/// clipboard entries a single copy rewrote 2.3 MB, and the cost grew with
/// the history rather than staying put.
///
/// Pictures stay as files beside the database, keyed by the hash of their
/// contents. Putting the bytes in a row would bring the rewriting back, in a
/// place where it costs the most.
/// Every access goes through `locked`, which is what makes one handle safe
/// to share between the pasteboard poll and the interface.
public final class ShortyDatabase: @unchecked Sendable {
    public static let schemaVersion = 1

    let sqlite: SQLiteDatabase
    /// Where this database lives, which is also where its JSON ancestors do.
    public let url: URL
    private let lock = NSRecursiveLock()

    public init(url: URL = ShortyDatabase.defaultURL) throws {
        self.url = url
        sqlite = try SQLiteDatabase(url: url)
        try createSchema()
    }

    /// The folder this database sits in. A migration belongs to a database,
    /// not to a fixed path: pointing one at a scratch file and having it
    /// import — and rename — the real files is a way to lose them.
    var directory: URL {
        url.deletingLastPathComponent()
    }

    /// The one connection everything shares.
    ///
    /// Separate connections to the same file would each take their own lock
    /// and leave SQLite to arbitrate, which it does by failing writes as
    /// busy. One handle, one lock, no arbitration.
    public static let shared: ShortyDatabase? = try? ShortyDatabase()

    public static var defaultURL: URL {
        ClipboardHistoryStore.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("Shorty.sqlite")
    }

    /// Runs `body` with nobody else touching the database.
    ///
    /// One connection shared by the pasteboard poll and the interface, which
    /// is the usual way to corrupt a database if left unguarded.
    @discardableResult
    func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }

        return try body()
    }

    private func createSchema() throws {
        try locked {
            try sqlite.execute(
                """
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS items (
                    id            TEXT PRIMARY KEY,
                    plain_text    TEXT NOT NULL,
                    rtf           BLOB,
                    rtfd          BLOB,
                    created_at    REAL NOT NULL,
                    updated_at    REAL NOT NULL,
                    source_bundle TEXT,
                    source_name   TEXT,
                    image_file    TEXT,
                    image_type    TEXT,
                    image_bytes   INTEGER,
                    image_width   INTEGER,
                    image_height  INTEGER,
                    ocr_text      TEXT,
                    pinned_at     REAL
                );

                CREATE INDEX IF NOT EXISTS items_by_recency ON items (updated_at DESC);

                CREATE TABLE IF NOT EXISTS representations (
                    item_id  TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    type     TEXT NOT NULL,
                    data     BLOB NOT NULL,
                    PRIMARY KEY (item_id, position)
                );

                CREATE TABLE IF NOT EXISTS files (
                    item_id  TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    path     TEXT NOT NULL,
                    PRIMARY KEY (item_id, position)
                );

                CREATE TABLE IF NOT EXISTS link_cards (
                    url        TEXT PRIMARY KEY,
                    title      TEXT,
                    summary    TEXT,
                    site_name  TEXT,
                    image_file TEXT,
                    fetched_at REAL NOT NULL,
                    failed     INTEGER NOT NULL
                );

                CREATE INDEX IF NOT EXISTS link_cards_by_age ON link_cards (fetched_at);

                CREATE TABLE IF NOT EXISTS recent_files (
                    path      TEXT PRIMARY KEY,
                    opened_at REAL NOT NULL
                );

                CREATE INDEX IF NOT EXISTS recent_files_by_recency ON recent_files (opened_at DESC);

                CREATE TABLE IF NOT EXISTS recent_apps (
                    path      TEXT PRIMARY KEY,
                    opened_at REAL NOT NULL,
                    opens     INTEGER NOT NULL DEFAULT 1
                );

                CREATE INDEX IF NOT EXISTS recent_apps_by_recency ON recent_apps (opened_at DESC);
                """
            )

            try sqlite.run(
                "INSERT INTO meta (key, value) VALUES ('schema_version', ?) ON CONFLICT(key) DO NOTHING",
                [.text(String(Self.schemaVersion))]
            )

            try addMissingColumns()
        }
    }

    /// Columns added after a database was first written.
    ///
    /// `CREATE TABLE IF NOT EXISTS` leaves an existing table exactly as it
    /// was, so a new column has to be asked for separately. Adding one is
    /// cheap in SQLite and the value is null for every row already there,
    /// which is what a history with nothing read out of its pictures means.
    private func addMissingColumns() throws {
        let existing = Set(
            try sqlite.query("PRAGMA table_info(items)").compactMap { $0[1].string }
        )

        if !existing.contains("ocr_text") {
            try sqlite.execute("ALTER TABLE items ADD COLUMN ocr_text TEXT")
        }

        if !existing.contains("pinned_at") {
            try sqlite.execute("ALTER TABLE items ADD COLUMN pinned_at REAL")
        }

        try sqlite.execute("CREATE INDEX IF NOT EXISTS items_by_pinned ON items (pinned_at DESC) WHERE pinned_at IS NOT NULL")
    }

    /// A value remembered between launches, by name.
    ///
    /// `meta` already holds the schema version; anything small and singular
    /// belongs here rather than in a table of its own.
    public func metaValue(for key: String) -> String? {
        locked {
            try? sqlite.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?[0].string
        }
    }

    public func setMetaValue(_ value: String?, for key: String) {
        locked {
            guard let value else {
                _ = try? sqlite.run("DELETE FROM meta WHERE key = ?", [.text(key)])
                return
            }

            _ = try? sqlite.run(
                "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)]
            )
        }
    }

    /// Whether anything has been imported or written yet, which is what says
    /// a migration from the old JSON files is still owed.
    func isEmpty(table: String) -> Bool {
        locked {
            let rows = try? sqlite.query("SELECT COUNT(*) FROM \(table)")

            return rows?.first?.first?.int == 0
        }
    }
}
