import Foundation
import SQLite3

// Swift does not expose SQLITE_TRANSIENT; this is the documented
// sentinel for sqlite3_bind_text that tells SQLite to make its own
// copy of the string before the pointer goes stale.
private nonisolated var _sqlTransient: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// Persistent history of query strings typed into the command palette.
/// Stored in a single SQLite file at `~/.cache/tongyou/palette-query-history.db`
/// by default. Test code injects a temporary `directoryURL` so production data
/// is never touched.
///
/// Uses `INSERT OR REPLACE` for deduplication: the same query string updates
/// the existing row's timestamp, keeping the database compact.
actor PaletteQueryHistory {

    /// Cap on total records before a truncation pass.
    static let maxRecords = 100
    /// Number of oldest records dropped when the cap is exceeded.
    static let truncateBatch = 20
    /// Database file basename inside `directoryURL`.
    static let fileName = "palette-query-history.db"

    /// Default cache directory (`~/.cache/tongyou`).
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/tongyou", isDirectory: true)
    }

    private let directoryURL: URL
    private let fileURL: URL
    private let fm: FileManager
    private var db: OpaquePointer?

    init(directoryURL: URL = PaletteQueryHistory.defaultDirectory,
         fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
        self.fm = fileManager
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Public API

    /// Record (or update) a query string. `timestamp` is injectable so
    /// tests can produce deterministic ordering.
    func record(query: String, timestamp: Date = Date()) throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try ensureDB()
        let stmt = try prepare(
            """
            INSERT OR REPLACE INTO palette_query_history
                (query, timestamp)
            VALUES (?, ?)
            """
        )
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, trimmed, -1, _sqlTransient)
        sqlite3_bind_double(stmt, 2, timestamp.timeIntervalSince1970)

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw SQLiteError.stepFailed(rc, msg: dbErrorMessage)
        }

        try truncateIfNeeded()
    }

    /// Return the most recent `limit` query strings, ordered by recency
    /// descending (most recent first).
    func recent(limit: Int) throws -> [String] {
        try ensureDB()
        let stmt = try prepare(
            """
            SELECT query
            FROM palette_query_history
            ORDER BY timestamp DESC
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var queries: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            queries.append(String(cString: cStr))
        }
        return queries
    }

    /// Delete a single query. Returns `true` if a row was removed.
    @discardableResult
    func remove(query: String) throws -> Bool {
        try ensureDB()
        let stmt = try prepare(
            "DELETE FROM palette_query_history WHERE query = ?"
        )
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, query, -1, _sqlTransient)

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw SQLiteError.stepFailed(rc, msg: dbErrorMessage)
        }
        return sqlite3_changes(db) > 0
    }

    /// Delete every query.
    func clear() throws {
        try ensureDB()
        let stmt = try prepare("DELETE FROM palette_query_history")
        defer { sqlite3_finalize(stmt) }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw SQLiteError.stepFailed(rc, msg: dbErrorMessage)
        }
    }

    // MARK: - Schema

    private func ensureDB() throws {
        guard db == nil else { return }
        try ensureDirectory()
        let rc = sqlite3_open(fileURL.path, &db)
        guard rc == SQLITE_OK, db != nil else {
            throw SQLiteError.openFailed(rc)
        }
        try exec(
            """
            CREATE TABLE IF NOT EXISTS palette_query_history (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                query       TEXT    NOT NULL UNIQUE,
                timestamp   REAL    NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_timestamp
                ON palette_query_history(timestamp DESC);
            """
        )
    }

    private func truncateIfNeeded() throws {
        let countStmt = try prepare("SELECT COUNT(*) FROM palette_query_history")
        defer { sqlite3_finalize(countStmt) }
        guard sqlite3_step(countStmt) == SQLITE_ROW else { return }
        let total = Int(sqlite3_column_int(countStmt, 0))
        guard total > Self.maxRecords else { return }

        let keep = Self.maxRecords - Self.truncateBatch
        let delStmt = try prepare(
            """
            DELETE FROM palette_query_history
            WHERE id IN (
                SELECT id FROM palette_query_history
                ORDER BY timestamp ASC
                LIMIT ?
            )
            """
        )
        defer { sqlite3_finalize(delStmt) }
        sqlite3_bind_int(delStmt, 1, Int32(total - keep))
        let rc = sqlite3_step(delStmt)
        guard rc == SQLITE_DONE else {
            throw SQLiteError.stepFailed(rc, msg: dbErrorMessage)
        }
    }

    // MARK: - Helpers

    private func ensureDirectory() throws {
        if !fm.fileExists(atPath: directoryURL.path) {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK, let err {
            let msg = String(cString: err)
            sqlite3_free(err)
            throw SQLiteError.execFailed(rc, msg: msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteError.prepareFailed(rc, msg: dbErrorMessage)
        }
        return stmt
    }

    private var dbErrorMessage: String? {
        guard let db else { return nil }
        guard let cStr = sqlite3_errmsg(db) else { return nil }
        return String(cString: cStr)
    }
}
