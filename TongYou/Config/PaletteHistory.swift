import Foundation
import SQLite3

// Swift does not expose SQLITE_TRANSIENT; this is the documented
// sentinel for sqlite3_bind_text that tells SQLite to make its own
// copy of the string before the pointer goes stale.
private nonisolated var _sqlTransient: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// A single entry in the palette history database.
struct PaletteHistoryEntry: Sendable, Equatable {
    let id: Int
    let scope: PaletteScope
    let identifier: String
    let display: String
    let metadata: [String: String]
    let timestamp: Date
}

/// Persistent palette history across all scopes. Stored in a single SQLite
/// file at `~/.cache/tongyou/palette-history.db` by default. Test code
/// injects a temporary `directoryURL` so production data is never touched.
///
/// Uses `INSERT OR REPLACE` for deduplication: the same `scope + identifier`
/// updates the existing row's timestamp and display text, keeping the
/// database compact.
actor PaletteHistory {

    /// Cap on total records before a truncation pass.
    static let maxRecords = 200
    /// Number of oldest records dropped when the cap is exceeded.
    static let truncateBatch = 50
    /// Database file basename inside `directoryURL`.
    static let fileName = "palette-history.db"

    /// Default cache directory (`~/.cache/tongyou`).
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/tongyou", isDirectory: true)
    }

    private let directoryURL: URL
    private let fileURL: URL
    private let fm: FileManager
    private var db: OpaquePointer?

    init(directoryURL: URL = PaletteHistory.defaultDirectory,
         fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
        self.fm = fileManager
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Public API

    /// Record (or update) a history entry. `timestamp` is injectable so
    /// tests can produce deterministic ordering.
    func record(
        scope: PaletteScope,
        identifier: String,
        display: String,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) throws {
        try ensureDB()
        let metadataJSON = try encodeMetadata(metadata)
        let stmt = try prepare(
            """
            INSERT OR REPLACE INTO palette_history
                (scope, identifier, display, metadata, timestamp)
            VALUES (?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, scope.rawValue, -1, _sqlTransient)
        sqlite3_bind_text(stmt, 2, identifier, -1, _sqlTransient)
        sqlite3_bind_text(stmt, 3, display, -1, _sqlTransient)
        sqlite3_bind_text(stmt, 4, metadataJSON, -1, _sqlTransient)
        sqlite3_bind_double(stmt, 5, timestamp.timeIntervalSince1970)

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw SQLiteError.stepFailed(rc, msg: dbErrorMessage)
        }

        try truncateIfNeeded()
    }

    /// Return the most recent `limit` entries for a given scope, ordered
    /// by recency descending.
    func recent(scope: PaletteScope, limit: Int) throws -> [PaletteHistoryEntry] {
        try ensureDB()
        let stmt = try prepare(
            """
            SELECT id, scope, identifier, display, metadata, timestamp
            FROM palette_history
            WHERE scope = ?
            ORDER BY timestamp DESC
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, scope.rawValue, -1, _sqlTransient)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var entries: [PaletteHistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(try entryFromStatement(stmt))
        }
        return entries
    }

    /// Delete a single entry matching `scope + identifier`. Returns `true`
    /// if a row was removed.
    @discardableResult
    func remove(scope: PaletteScope, identifier: String) throws -> Bool {
        try ensureDB()
        let stmt = try prepare(
            """
            DELETE FROM palette_history
            WHERE scope = ? AND identifier = ?
            """
        )
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, scope.rawValue, -1, _sqlTransient)
        sqlite3_bind_text(stmt, 2, identifier, -1, _sqlTransient)

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw SQLiteError.stepFailed(rc, msg: dbErrorMessage)
        }
        return sqlite3_changes(db) > 0
    }

    /// Delete every entry for the given scope.
    func clear(scope: PaletteScope) throws {
        try ensureDB()
        let stmt = try prepare(
            "DELETE FROM palette_history WHERE scope = ?"
        )
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, scope.rawValue, -1, _sqlTransient)

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
            CREATE TABLE IF NOT EXISTS palette_history (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                scope       TEXT    NOT NULL,
                identifier  TEXT    NOT NULL,
                display     TEXT    NOT NULL,
                metadata    TEXT    NOT NULL DEFAULT '{}',
                timestamp   REAL    NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_scope_identifier
                ON palette_history(scope, identifier);
            CREATE INDEX IF NOT EXISTS idx_scope_time
                ON palette_history(scope, timestamp DESC);
            """
        )
    }

    private func truncateIfNeeded() throws {
        let countStmt = try prepare("SELECT COUNT(*) FROM palette_history")
        defer { sqlite3_finalize(countStmt) }
        guard sqlite3_step(countStmt) == SQLITE_ROW else { return }
        let total = Int(sqlite3_column_int(countStmt, 0))
        guard total > Self.maxRecords else { return }

        let keep = Self.maxRecords - Self.truncateBatch
        let delStmt = try prepare(
            """
            DELETE FROM palette_history
            WHERE id IN (
                SELECT id FROM palette_history
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

    private func entryFromStatement(_ stmt: OpaquePointer) throws -> PaletteHistoryEntry {
        let id = Int(sqlite3_column_int(stmt, 0))
        guard
            let scopeCStr = sqlite3_column_text(stmt, 1),
            let identifierCStr = sqlite3_column_text(stmt, 2),
            let displayCStr = sqlite3_column_text(stmt, 3),
            let metadataCStr = sqlite3_column_text(stmt, 4)
        else {
            throw SQLiteError.missingColumn
        }
        let scopeRaw = String(cString: scopeCStr)
        // PaletteScope init is a pure data conversion; bypass actor isolation.
        guard let scope = PaletteScope(rawValue: scopeRaw) else {
            throw SQLiteError.unknownScope(scopeRaw)
        }
        let identifier = String(cString: identifierCStr)
        let display = String(cString: displayCStr)
        let metadataJSON = String(cString: metadataCStr)
        let metadata = try decodeMetadata(metadataJSON)
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        return PaletteHistoryEntry(
            id: id,
            scope: scope,
            identifier: identifier,
            display: display,
            metadata: metadata,
            timestamp: timestamp
        )
    }

    private func encodeMetadata(_ metadata: [String: String]) throws -> String {
        guard !metadata.isEmpty else { return "{}" }
        let data = try JSONSerialization.data(withJSONObject: metadata)
        guard let str = String(data: data, encoding: .utf8) else {
            throw SQLiteError.jsonEncodeFailed
        }
        return str
    }

    private func decodeMetadata(_ json: String) throws -> [String: String] {
        guard json != "{}" else { return [:] }
        guard let data = json.data(using: .utf8) else { return [:] }
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: String] else { return [:] }
        return dict
    }
}

// MARK: - PaletteScope + RawRepresentable

extension PaletteScope: RawRepresentable, CaseIterable {
    nonisolated init?(rawValue: String) {
        switch rawValue {
        case "ssh":     self = .ssh
        case "command": self = .command
        case "profile": self = .profile
        case "tab":     self = .tab
        case "session": self = .session
        default:        return nil
        }
    }

    nonisolated var rawValue: String {
        switch self {
        case .ssh:     return "ssh"
        case .command: return "command"
        case .profile: return "profile"
        case .tab:     return "tab"
        case .session: return "session"
        }
    }

    static var allCases: [PaletteScope] {
        [.ssh, .command, .profile, .tab, .session]
    }
}

// MARK: - Errors

enum SQLiteError: Error, Equatable {
    case openFailed(Int32)
    case execFailed(Int32, msg: String)
    case prepareFailed(Int32, msg: String?)
    case stepFailed(Int32, msg: String?)
    case missingColumn
    case unknownScope(String)
    case jsonEncodeFailed
}
