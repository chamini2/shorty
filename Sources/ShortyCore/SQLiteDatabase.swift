import Foundation
import SQLite3

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case statement(String, sql: String)

    public var description: String {
        switch self {
        case let .open(message):
            return "Could not open the database: \(message)"
        case let .statement(message, sql):
            return "Database error: \(message) while running `\(sql)`"
        }
    }
}

/// A value going into a statement, or coming out of one.
public enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var int: Int64? {
        if case let .integer(value) = self {
            return value
        }

        return nil
    }

    public var double: Double? {
        switch self {
        case let .real(value):
            return value
        case let .integer(value):
            return Double(value)
        default:
            return nil
        }
    }

    public var string: String? {
        if case let .text(value) = self {
            return value
        }

        return nil
    }

    public var data: Data? {
        if case let .blob(value) = self {
            return value
        }

        return nil
    }
}

/// The bare amount of SQLite needed to keep Shorty's own records.
///
/// SQLite is part of macOS, so this costs no dependency, but it is a C API:
/// every prepared statement has to be finalised and every string bound with
/// a lifetime the library understands. That is all this type exists to get
/// right, once, so nothing above it handles a raw pointer.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    /// How many transactions deep the current call is.
    private var depth = 0

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard sqlite3_open(url.path, &handle) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError.open(message)
        }

        // Appends to a log rather than rewriting the file, which is the whole
        // reason for moving off JSON; `NORMAL` skips an fsync per write and
        // is safe under WAL against anything but a power cut.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Statements with nothing to bind and nothing to read back.
    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?

        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SQLiteError.statement(message, sql: sql)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int {
        try prepared(sql) { statement in
            try bind(parameters, to: statement, sql: sql)

            let status = sqlite3_step(statement)

            guard status == SQLITE_DONE || status == SQLITE_ROW else {
                throw error(sql: sql)
            }

            return Int(sqlite3_changes(handle))
        }
    }

    public func query(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        try prepared(sql) { statement in
            try bind(parameters, to: statement, sql: sql)

            var rows: [[SQLiteValue]] = []

            while true {
                let status = sqlite3_step(statement)

                if status == SQLITE_DONE {
                    return rows
                }

                guard status == SQLITE_ROW else {
                    throw error(sql: sql)
                }

                rows.append(
                    (0..<sqlite3_column_count(statement)).map { column in
                        value(of: statement, at: column)
                    }
                )
            }
        }
    }

    /// Everything or nothing: a half-written import is worse than none.
    ///
    /// Nestable, because the callers nest: importing a history wraps a
    /// transaction around writing each item, and each of those writes its
    /// rows in a transaction of its own. SQLite refuses a second `BEGIN`, so
    /// the inner ones become savepoints and only the outermost commits.
    public func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        let name = "shorty_\(depth)"
        try execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(name)")
        depth += 1

        do {
            let result = try body()
            depth -= 1
            try execute(depth == 0 ? "COMMIT" : "RELEASE \(name)")
            return result
        } catch {
            depth -= 1
            try? execute(depth == 0 ? "ROLLBACK" : "ROLLBACK TO \(name)")
            throw error
        }
    }

    private func prepared<Result>(
        _ sql: String,
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error(sql: sql)
        }

        // The one thing a C API will not forgive being skipped.
        defer { sqlite3_finalize(statement) }

        return try body(statement)
    }

    private func bind(_ parameters: [SQLiteValue], to statement: OpaquePointer, sql: String) throws {
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32

            switch parameter {
            case .null:
                status = sqlite3_bind_null(statement, index)
            case let .integer(value):
                status = sqlite3_bind_int64(statement, index, value)
            case let .real(value):
                status = sqlite3_bind_double(statement, index, value)
            case let .text(value):
                // `TRANSIENT`, so SQLite copies the bytes: the Swift string
                // behind them is gone by the time the statement runs.
                status = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case let .blob(value):
                status = value.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : value.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), Self.transient)
                    }
            }

            guard status == SQLITE_OK else {
                throw error(sql: sql)
            }
        }
    }

    private func value(of statement: OpaquePointer, at column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, column) else {
                return .blob(Data())
            }

            return .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))))
        default:
            return .null
        }
    }

    private func error(sql: String) -> SQLiteError {
        .statement(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown", sql: sql)
    }

    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
}
