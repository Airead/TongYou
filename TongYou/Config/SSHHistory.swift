import Foundation

/// A single SSH connection event recorded in the history log.
/// One entry per append; duplicates per target are expected and get
/// collapsed by `SSHHistory.entries()`.
struct SSHHistoryRecord: Sendable, Equatable {
    let timestamp: Date
    let template: String
    let target: String
}

/// Aggregated summary of the history file for a given connection target,
/// ready for display in the command palette.
struct SSHHistoryEntry: Sendable, Equatable {
    /// The user-typed connection target (may include `user@`).
    let target: String
    /// Template used the last time this target was connected.
    let template: String
    /// Most recent connection timestamp for this target.
    let lastUsed: Date
    /// Number of historical connections to this target.
    let frequency: Int
}

/// Persistent SSH connection history. The on-disk log is a simple
/// append-only tab-separated file (`<iso8601>\t<template>\t<target>\n`)
/// stored at `~/.cache/tongyou/ssh-history.txt` by default. Test code
/// injects a temporary `directoryURL` so production data is never
/// touched.
///
/// Writes are amortised: when the log exceeds `maxRecords` (500), the
/// oldest `truncateBatch` (100) entries are dropped in one rewrite so
/// the next ~100 appends stay cheap.
actor SSHHistory {

    /// Cap on records kept on disk before a truncation rewrite.
    static let maxRecords = 500
    /// Number of oldest records dropped when the cap is exceeded.
    static let truncateBatch = 100
    /// Log file basename inside `directoryURL`.
    static let fileName = "ssh-history.txt"

    /// Default cache directory (`~/.cache/tongyou`).
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/tongyou", isDirectory: true)
    }

    private let directoryURL: URL
    private let fileURL: URL
    private let fm: FileManager

    init(directoryURL: URL = SSHHistory.defaultDirectory,
         fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
        self.fm = fileManager
    }

    // MARK: - Public API

    /// Record a new connection. `timestamp` is injectable so tests can
    /// produce deterministic recency ordering.
    func append(template: String, target: String, timestamp: Date = Date()) throws {
        try ensureDirectory()
        let line = Self.encodeLine(timestamp: timestamp, template: template, target: target)
        try appendLine(line)
        try truncateIfNeeded()
    }

    /// All records in the log, oldest first. Invalid lines are skipped.
    func allRecords() throws -> [SSHHistoryRecord] {
        guard fm.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return Self.parseRecords(text)
    }

    /// Aggregated entries for panel display, sorted by recency desc, then
    /// frequency desc, then target alphabetically as a stable tie-break.
    func entries() throws -> [SSHHistoryEntry] {
        let records = try allRecords()
        return Self.aggregate(records)
    }

    /// Convenience: first `limit` entries of `entries()`.
    func recent(limit: Int) throws -> [SSHHistoryEntry] {
        let all = try entries()
        return Array(all.prefix(limit))
    }

    /// Delete the log file. Next append re-creates it.
    func clearAll() throws {
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
    }

    // MARK: - File IO

    private func ensureDirectory() throws {
        if !fm.fileExists(atPath: directoryURL.path) {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func appendLine(_ line: String) throws {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if fm.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL)
        }
    }

    private func truncateIfNeeded() throws {
        let records = try allRecords()
        guard records.count > Self.maxRecords else { return }
        // Amortise: rewrite down to (max - batch) so the next `batch` appends
        // don't each trigger a rewrite.
        let keepCount = Self.maxRecords - Self.truncateBatch
        let kept = records.suffix(keepCount)
        let text = kept
            .map { Self.encodeLine(timestamp: $0.timestamp, template: $0.template, target: $0.target) }
            .joined(separator: "\n") + "\n"
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Encoding / decoding

    nonisolated static let isoStyle = Date.ISO8601FormatStyle()

    static func encodeLine(timestamp: Date, template: String, target: String) -> String {
        "\(isoStyle.format(timestamp))\t\(template)\t\(target)"
    }

    static func parseRecords(_ text: String) -> [SSHHistoryRecord] {
        var records: [SSHHistoryRecord] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine
                .split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count == 3 else { continue }
            let tsStr = parts[0]
            let template = parts[1]
            let target = parts[2]
            guard !template.isEmpty, !target.isEmpty else { continue }
            guard let ts = try? isoStyle.parse(tsStr) else { continue }
            records.append(SSHHistoryRecord(
                timestamp: ts,
                template: template,
                target: target
            ))
        }
        return records
    }

    static func aggregate(_ records: [SSHHistoryRecord]) -> [SSHHistoryEntry] {
        struct Agg {
            var lastUsed: Date
            var template: String
            var frequency: Int
        }
        var byTarget: [String: Agg] = [:]
        for record in records {
            if var existing = byTarget[record.target] {
                existing.frequency += 1
                if record.timestamp >= existing.lastUsed {
                    existing.lastUsed = record.timestamp
                    existing.template = record.template
                }
                byTarget[record.target] = existing
            } else {
                byTarget[record.target] = Agg(
                    lastUsed: record.timestamp,
                    template: record.template,
                    frequency: 1
                )
            }
        }
        let entries = byTarget.map { (target, agg) in
            SSHHistoryEntry(
                target: target,
                template: agg.template,
                lastUsed: agg.lastUsed,
                frequency: agg.frequency
            )
        }
        return entries.sorted { a, b in
            if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
            if a.frequency != b.frequency { return a.frequency > b.frequency }
            return a.target < b.target
        }
    }
}
