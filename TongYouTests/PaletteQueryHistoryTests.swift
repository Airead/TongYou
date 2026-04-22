import Foundation
import Testing
@testable import TongYou

@Suite("PaletteQueryHistory", .serialized)
struct PaletteQueryHistoryTests {

    // MARK: - Record / insert

    @Test func recordInsertsNewQuery() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(query: "ssh db1", timestamp: Date(timeIntervalSince1970: 1000))

        let queries = try await env.history.recent(limit: 10)
        #expect(queries.count == 1)
        #expect(queries[0] == "ssh db1")
    }

    @Test func recordUpdatesExistingQuery() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(query: "ssh db1", timestamp: Date(timeIntervalSince1970: 1000))
        try await env.history.record(query: "ssh db1", timestamp: Date(timeIntervalSince1970: 2000))

        let queries = try await env.history.recent(limit: 10)
        #expect(queries.count == 1)
        #expect(queries[0] == "ssh db1")
    }

    @Test func recordIgnoresEmptyQuery() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(query: "")
        try await env.history.record(query: "   ")

        let queries = try await env.history.recent(limit: 10)
        #expect(queries.isEmpty)
    }

    @Test func recordTrimsWhitespace() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(query: "  ssh db1  ")

        let queries = try await env.history.recent(limit: 10)
        #expect(queries.count == 1)
        #expect(queries[0] == "ssh db1")
    }

    // MARK: - Recent / order / limits

    @Test func recentReturnsMRUOrder() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(query: "p home", timestamp: Date(timeIntervalSince1970: 1000))
        try await env.history.record(query: "> newTab", timestamp: Date(timeIntervalSince1970: 3000))
        try await env.history.record(query: "p home", timestamp: Date(timeIntervalSince1970: 2000))

        let queries = try await env.history.recent(limit: 10)
        #expect(queries == ["> newTab", "p home"])
    }

    @Test func recentLimitsResults() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        for i in 0..<10 {
            try await env.history.record(query: "query\(i)", timestamp: Date(timeIntervalSince1970: Double(1000 + i)))
        }

        let queries = try await env.history.recent(limit: 3)
        #expect(queries.count == 3)
    }

    // MARK: - Remove

    @Test func removeDeletesSpecificQuery() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(query: "ssh host1")
        try await env.history.record(query: "ssh host2")

        let removed = try await env.history.remove(query: "ssh host1")
        #expect(removed == true)

        let queries = try await env.history.recent(limit: 10)
        #expect(queries.count == 1)
        #expect(queries[0] == "ssh host2")
    }

    @Test func removeMissingReturnsFalse() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        let removed = try await env.history.remove(query: "missing")
        #expect(removed == false)
    }

    // MARK: - Clear

    @Test func clearEmptiesAllQueries() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await env.history.record(query: "ssh host1")
        try await env.history.record(query: "> newTab")

        try await env.history.clear()

        let queries = try await env.history.recent(limit: 10)
        #expect(queries.isEmpty)
    }

    // MARK: - Capacity

    @Test func capacityTruncatesOldest() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        // Write one over the cap.
        let total = PaletteQueryHistory.maxRecords + 1
        for i in 0..<total {
            try await env.history.record(
                query: "query-\(i)",
                timestamp: Date(timeIntervalSince1970: Double(1000 + i))
            )
        }

        // After truncation, keep (max - truncateBatch) records.
        let expectedCount = PaletteQueryHistory.maxRecords - PaletteQueryHistory.truncateBatch
        let queries = try await env.history.recent(limit: total)
        #expect(queries.count == expectedCount)

        // Oldest surviving record.
        let firstKept = total - expectedCount
        #expect(queries.last == "query-\(firstKept)")
        #expect(queries.first == "query-\(total - 1)")
    }

    // MARK: - Missing DB

    @Test func missingDBStartsEmpty() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        let queries = try await env.history.recent(limit: 10)
        #expect(queries.isEmpty)
    }

    // MARK: - Helpers

    private struct Env {
        let directoryURL: URL
        let history: PaletteQueryHistory
        let cleanup: @Sendable () -> Void
    }

    private func makeEnv() throws -> Env {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tongyou-palette-query-history-\(UUID().uuidString)", isDirectory: true)
        let history = PaletteQueryHistory(directoryURL: dir)
        return Env(
            directoryURL: dir,
            history: history,
            cleanup: { try? FileManager.default.removeItem(at: dir) }
        )
    }
}
