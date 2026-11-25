import XCTest
@testable import ShortyCore

final class SQLiteDatabaseTests: XCTestCase {
    private var directory: URL!
    private var database: SQLiteDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SQLiteTests-\(UUID().uuidString)")
        database = try SQLiteDatabase(url: directory.appendingPathComponent("test.sqlite"))
        try database.execute("CREATE TABLE t (id TEXT PRIMARY KEY, n INTEGER, r REAL, b BLOB)")
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testValuesSurviveTheRoundTrip() throws {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try database.run("INSERT INTO t VALUES (?, ?, ?, ?)", [.text("a"), .integer(42), .real(1.5), .blob(bytes)])
        try database.run("INSERT INTO t VALUES (?, ?, ?, ?)", [.text("b"), .null, .null, .null])

        let rows = try database.query("SELECT id, n, r, b FROM t ORDER BY id")

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0].string, "a")
        XCTAssertEqual(rows[0][1].int, 42)
        XCTAssertEqual(rows[0][2].double, 1.5)
        XCTAssertEqual(rows[0][3].data, bytes)
        XCTAssertEqual(rows[1][1], .null)
    }

    func testABoundStringOutlivesTheCallThatBoundIt() throws {
        // Bound as transient, so SQLite copies the bytes: the Swift string
        // behind them is gone by the time the statement runs.
        func insert() throws {
            try database.run("INSERT INTO t (id) VALUES (?)", [.text(String("scoped".reversed()))])
        }

        try insert()

        XCTAssertEqual(try database.query("SELECT id FROM t WHERE id = 'depocs'").count, 1)
    }

    func testAFailedTransactionLeavesNothingBehind() throws {
        struct Failure: Error {}

        XCTAssertThrowsError(
            try database.transaction {
                try database.run("INSERT INTO t (id) VALUES ('rolled')")
                throw Failure()
            }
        )

        XCTAssertTrue(try database.query("SELECT id FROM t WHERE id = 'rolled'").isEmpty)
    }

    func testTransactionsNest() throws {
        // An import wraps a transaction around writes that open their own;
        // SQLite refuses a second `BEGIN`, so the inner ones are savepoints.
        try database.transaction {
            try database.run("INSERT INTO t (id) VALUES ('outer')")

            try database.transaction {
                try database.run("INSERT INTO t (id) VALUES ('inner')")
            }
        }

        XCTAssertEqual(try database.query("SELECT id FROM t ORDER BY id").count, 2)
    }

    func testAnInnerFailureLeavesTheOuterWorkIntact() throws {
        struct Failure: Error {}

        try database.transaction {
            try database.run("INSERT INTO t (id) VALUES ('kept')")

            try? database.transaction {
                try database.run("INSERT INTO t (id) VALUES ('dropped')")
                throw Failure()
            }
        }

        XCTAssertEqual(try database.query("SELECT id FROM t").map { $0[0].string }, ["kept"])
    }

    func testBadSQLIsReportedRatherThanIgnored() {
        XCTAssertThrowsError(try database.run("INSERT INTO nope VALUES (1)"))
    }

    func testWriteAheadLoggingIsOn() throws {
        // The reason for the move: appends instead of rewrites.
        XCTAssertEqual(try database.query("PRAGMA journal_mode")[0][0].string?.lowercased(), "wal")
        XCTAssertEqual(try database.query("PRAGMA foreign_keys")[0][0].int, 1)
    }
}
