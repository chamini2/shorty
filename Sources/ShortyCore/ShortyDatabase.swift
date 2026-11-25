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
                    image_height  INTEGER
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
                """
            )

            try sqlite.run(
                "INSERT INTO meta (key, value) VALUES ('schema_version', ?) ON CONFLICT(key) DO NOTHING",
                [.text(String(Self.schemaVersion))]
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
