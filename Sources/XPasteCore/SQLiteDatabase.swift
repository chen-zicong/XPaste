import Foundation
import SQLite3

enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

struct SQLiteFailure: LocalizedError {
    let operation: String
    let code: Int32
    let message: String

    var errorDescription: String? {
        "SQLite \(operation) 失败（\(code)）：\(message)"
    }
}

/// A deliberately small SQLite wrapper. Every instance is owned by one actor,
/// while FULLMUTEX protects against accidental cross-thread use as Swift actors
/// are free to resume on a different executor thread.
final class SQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &connection, flags, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "无法创建数据库连接"
            if let connection { sqlite3_close_v2(connection) }
            throw SQLiteFailure(operation: "open", code: result, message: message)
        }

        handle = connection
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 1_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? currentErrorMessage
            throw SQLiteFailure(operation: "exec", code: result, message: message)
        }
    }

    func execute(_ sql: String, bindings: [SQLiteValue]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw failure(operation: "step", code: result)
        }
    }

    func query<T>(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        row: (OpaquePointer) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                rows.append(try row(statement))
            case SQLITE_DONE:
                return rows
            default:
                throw failure(operation: "query", code: result)
            }
        }
    }

    func scalarInt(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int {
        try query(sql, bindings: bindings) { statement in
            Int(sqlite3_column_int64(statement, 0))
        }.first ?? 0
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var changes: Int {
        Int(sqlite3_changes(handle))
    }

    static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: value)
    }

    static func int(_ statement: OpaquePointer, column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    static func double(_ statement: OpaquePointer, column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw failure(operation: "prepare", code: result)
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let number):
                result = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                result = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                result = sqlite3_bind_text(statement, index, string, -1, Self.transientDestructor)
            case .blob(let data):
                if data.isEmpty {
                    result = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    result = data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(
                            statement,
                            index,
                            bytes.baseAddress,
                            Int32(data.count),
                            Self.transientDestructor
                        )
                    }
                }
            }

            guard result == SQLITE_OK else {
                throw failure(operation: "bind", code: result)
            }
        }
    }

    private var currentErrorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    private func failure(operation: String, code: Int32) -> SQLiteFailure {
        SQLiteFailure(operation: operation, code: code, message: currentErrorMessage)
    }
}
