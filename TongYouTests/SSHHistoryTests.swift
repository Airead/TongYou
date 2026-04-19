import Testing
import Foundation
@testable import TongYou

@Suite("SSHHistory", .serialized)
struct SSHHistoryTests {

    // MARK: - Append / read

    @Test func appendRecordsWritten() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.append(
            template: "ssh-prod",
            target: "db1.prod.example.com",
            timestamp: Date(timeIntervalSince1970: 1000)
        )

        let records = try await env.history.allRecords()
        #expect(records.count == 1)
        #expect(records[0].template == "ssh-prod")
        #expect(records[0].target == "db1.prod.example.com")
        #expect(records[0].timestamp == Date(timeIntervalSince1970: 1000))

        // The file was created inside the injected directory — not ~/.cache.
        let fileURL = env.directoryURL.appendingPathComponent(SSHHistory.fileName)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func missingFileStartsEmpty() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let records = try await env.history.allRecords()
        let entries = try await env.history.entries()
        #expect(records.isEmpty)
        #expect(entries.isEmpty)
    }

    // MARK: - Aggregation / sort

    @Test func sortByRecencyThenFrequency() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        // Three targets, crafted so recency alone breaks the tie for some
        // pairs and frequency has to break a tie for another.
        //
        // A: most recent connection overall → wins recency
        // B: same lastUsed as C, but more frequent → wins frequency tie
        // C: same lastUsed as B, less frequent → loses tie-break
        try await env.history.append(template: "ssh", target: "C",
                                     timestamp: Date(timeIntervalSince1970: 1000))
        try await env.history.append(template: "ssh", target: "B",
                                     timestamp: Date(timeIntervalSince1970: 1500))
        try await env.history.append(template: "ssh", target: "B",
                                     timestamp: Date(timeIntervalSince1970: 2000))
        try await env.history.append(template: "ssh", target: "C",
                                     timestamp: Date(timeIntervalSince1970: 2000))
        try await env.history.append(template: "ssh", target: "A",
                                     timestamp: Date(timeIntervalSince1970: 3000))

        let entries = try await env.history.entries()
        #expect(entries.map(\.target) == ["A", "B", "C"])
        let byTarget = Dictionary(uniqueKeysWithValues: entries.map { ($0.target, $0) })
        #expect(byTarget["A"]?.frequency == 1)
        #expect(byTarget["B"]?.frequency == 2)
        #expect(byTarget["C"]?.frequency == 2)
    }

    @Test func deduplicationKeepsLatest() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.append(template: "ssh", target: "db1",
                                     timestamp: Date(timeIntervalSince1970: 1000))
        try await env.history.append(template: "ssh-prod", target: "db1",
                                     timestamp: Date(timeIntervalSince1970: 2000))

        let entries = try await env.history.entries()
        #expect(entries.count == 1)
        #expect(entries[0].target == "db1")
        #expect(entries[0].template == "ssh-prod")
        #expect(entries[0].frequency == 2)
        #expect(entries[0].lastUsed == Date(timeIntervalSince1970: 2000))
    }

    @Test func targetDedupIsCaseSensitive() async throws {
        // Plan: "target 比较大小写敏感（SSH alias 可能有大小写差异，不擅自合并）".
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.append(template: "ssh", target: "DB1",
                                     timestamp: Date(timeIntervalSince1970: 1000))
        try await env.history.append(template: "ssh", target: "db1",
                                     timestamp: Date(timeIntervalSince1970: 2000))

        let entries = try await env.history.entries()
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.target)) == ["DB1", "db1"])
    }

    // MARK: - Cap / truncation

    @Test func capAtLimitDropsOldest() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        // Write one over the cap; the truncation batch rewrites down to
        // (max - truncateBatch) records so the next ~100 appends are cheap.
        let total = SSHHistory.maxRecords + 1
        for i in 0..<total {
            try await env.history.append(
                template: "ssh",
                target: "host-\(i)",
                timestamp: Date(timeIntervalSince1970: Double(1000 + i))
            )
        }

        let records = try await env.history.allRecords()
        let expectedCount = SSHHistory.maxRecords - SSHHistory.truncateBatch
        #expect(records.count == expectedCount)

        // The first surviving record is the oldest one we didn't drop.
        let firstKept = total - expectedCount
        #expect(records.first?.target == "host-\(firstKept)")
        #expect(records.last?.target == "host-\(total - 1)")
    }

    // MARK: - Clear

    @Test func clearAllWipesFile() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.append(template: "ssh", target: "db1",
                                     timestamp: Date(timeIntervalSince1970: 1000))
        let fileURL = env.directoryURL.appendingPathComponent(SSHHistory.fileName)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try await env.history.clearAll()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        // And a subsequent read yields no entries.
        let entries = try await env.history.entries()
        #expect(entries.isEmpty)
    }

    // MARK: - Malformed input

    @Test func malformedLineSkipped() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        // Write the file ourselves, mixing valid and invalid lines. The
        // directory isn't created until the first `append` call, so we do
        // it manually here since this test bypasses that path.
        try FileManager.default.createDirectory(
            at: env.directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = env.directoryURL.appendingPathComponent(SSHHistory.fileName)
        let iso = SSHHistory.isoStyle
        let valid1 = "\(iso.format(Date(timeIntervalSince1970: 1000)))\tssh\tdb1"
        let valid2 = "\(iso.format(Date(timeIntervalSince1970: 2000)))\tssh-prod\tdb2"
        let content = [
            valid1,
            "this-has-no-tabs",
            "\(iso.format(Date(timeIntervalSince1970: 1500)))\t\t",  // empty template + empty target
            "not-a-date\tssh\tdb3",
            valid2,
            ""
        ].joined(separator: "\n")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let records = try await env.history.allRecords()
        #expect(records.count == 2)
        #expect(records.map(\.target) == ["db1", "db2"])
    }

    // MARK: - Helpers

    private struct Env {
        let directoryURL: URL
        let history: SSHHistory
        let cleanup: @Sendable () -> Void
    }

    private func makeEnv() throws -> Env {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tongyou-ssh-history-\(UUID().uuidString)", isDirectory: true)
        // We intentionally do NOT create the directory here — construction
        // must survive a missing directory, and `append` creates it on demand.
        let url = dir
        let history = SSHHistory(directoryURL: url)
        return Env(
            directoryURL: url,
            history: history,
            cleanup: { try? FileManager.default.removeItem(at: url) }
        )
    }
}
