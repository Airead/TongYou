import Foundation
import Testing
@testable import TongYou

@Suite("PaletteHistory", .serialized)
struct PaletteHistoryTests {

    // MARK: - Record / insert

    @Test func recordInsertsNewEntry() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(
            scope: .ssh,
            identifier: "alice@db1",
            display: "db1",
            metadata: ["template": "ssh-prod"],
            timestamp: Date(timeIntervalSince1970: 1000)
        )

        let entries = try await env.history.recent(scope: .ssh, limit: 10)
        #expect(entries.count == 1)
        #expect(entries[0].scope == .ssh)
        #expect(entries[0].identifier == "alice@db1")
        #expect(entries[0].display == "db1")
        #expect(entries[0].metadata == ["template": "ssh-prod"])
        #expect(entries[0].timestamp == Date(timeIntervalSince1970: 1000))
    }

    @Test func recordUpdatesExistingEntry() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(
            scope: .ssh,
            identifier: "alice@db1",
            display: "db1",
            metadata: ["template": "ssh-prod"],
            timestamp: Date(timeIntervalSince1970: 1000)
        )

        try await env.history.record(
            scope: .ssh,
            identifier: "alice@db1",
            display: "db1-new",
            metadata: ["template": "ssh-prod-new"],
            timestamp: Date(timeIntervalSince1970: 2000)
        )

        let entries = try await env.history.recent(scope: .ssh, limit: 10)
        #expect(entries.count == 1)
        #expect(entries[0].display == "db1-new")
        #expect(entries[0].metadata == ["template": "ssh-prod-new"])
        #expect(entries[0].timestamp == Date(timeIntervalSince1970: 2000))
    }

    // MARK: - Recent / order / limits

    @Test func recentReturnsMRUOrder() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(scope: .command, identifier: "newTab", display: "New Tab", timestamp: Date(timeIntervalSince1970: 1000))
        try await env.history.record(scope: .command, identifier: "closeTab", display: "Close Tab", timestamp: Date(timeIntervalSince1970: 3000))
        try await env.history.record(scope: .command, identifier: "newTab", display: "New Tab", timestamp: Date(timeIntervalSince1970: 2000))

        let entries = try await env.history.recent(scope: .command, limit: 10)
        #expect(entries.map(\.identifier) == ["closeTab", "newTab"])
    }

    @Test func recentLimitsResults() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        for i in 0..<10 {
            try await env.history.record(scope: .profile, identifier: "p\(i)", display: "Profile \(i)", timestamp: Date(timeIntervalSince1970: Double(1000 + i)))
        }

        let entries = try await env.history.recent(scope: .profile, limit: 3)
        #expect(entries.count == 3)
    }

    @Test func recentFiltersByScope() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(scope: .ssh, identifier: "host1", display: "host1", timestamp: Date(timeIntervalSince1970: 1000))
        try await env.history.record(scope: .command, identifier: "newTab", display: "New Tab", timestamp: Date(timeIntervalSince1970: 2000))

        let sshEntries = try await env.history.recent(scope: .ssh, limit: 10)
        let commandEntries = try await env.history.recent(scope: .command, limit: 10)

        #expect(sshEntries.count == 1)
        #expect(sshEntries[0].identifier == "host1")
        #expect(commandEntries.count == 1)
        #expect(commandEntries[0].identifier == "newTab")
    }

    // MARK: - Remove

    @Test func removeDeletesSpecificEntry() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(scope: .ssh, identifier: "host1", display: "host1")
        try await env.history.record(scope: .ssh, identifier: "host2", display: "host2")

        let removed = try await env.history.remove(scope: .ssh, identifier: "host1")
        #expect(removed == true)

        let entries = try await env.history.recent(scope: .ssh, limit: 10)
        #expect(entries.count == 1)
        #expect(entries[0].identifier == "host2")
    }

    @Test func removeMissingReturnsFalse() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        let removed = try await env.history.remove(scope: .ssh, identifier: "missing")
        #expect(removed == false)
    }

    // MARK: - Clear

    @Test func clearEmptiesScope() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(scope: .ssh, identifier: "host1", display: "host1")
        try await env.history.record(scope: .command, identifier: "newTab", display: "New Tab")

        try await env.history.clear(scope: .ssh)

        let sshEntries = try await env.history.recent(scope: .ssh, limit: 10)
        let commandEntries = try await env.history.recent(scope: .command, limit: 10)

        #expect(sshEntries.isEmpty)
        #expect(commandEntries.count == 1)
    }

    // MARK: - Capacity

    @Test func capacityTruncatesOldest() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        // Write one over the cap.
        let total = PaletteHistory.maxRecords + 1
        for i in 0..<total {
            try await env.history.record(
                scope: .ssh,
                identifier: "host-\(i)",
                display: "Host \(i)",
                timestamp: Date(timeIntervalSince1970: Double(1000 + i))
            )
        }

        // After truncation, keep (max - truncateBatch) records.
        let expectedCount = PaletteHistory.maxRecords - PaletteHistory.truncateBatch
        let entries = try await env.history.recent(scope: .ssh, limit: total)
        #expect(entries.count == expectedCount)

        // Oldest surviving record.
        let firstKept = total - expectedCount
        #expect(entries.last?.identifier == "host-\(firstKept)")
        #expect(entries.first?.identifier == "host-\(total - 1)")
    }

    // MARK: - Missing DB

    @Test func missingDBStartsEmpty() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        let entries = try await env.history.recent(scope: .ssh, limit: 10)
        #expect(entries.isEmpty)
    }

    // MARK: - Helpers

    private struct Env {
        let directoryURL: URL
        let history: PaletteHistory
        let cleanup: @Sendable () -> Void
    }

    private func makeEnv() throws -> Env {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tongyou-palette-history-\(UUID().uuidString)", isDirectory: true)
        let history = PaletteHistory(directoryURL: dir)
        return Env(
            directoryURL: dir,
            history: history,
            cleanup: { try? FileManager.default.removeItem(at: dir) }
        )
    }
}
