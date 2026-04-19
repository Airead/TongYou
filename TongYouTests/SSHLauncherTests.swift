import Foundation
import Testing
import TYConfig
@testable import TongYou

@MainActor
@Suite("SSHLauncher", .serialized)
struct SSHLauncherTests {

    // MARK: - Candidate merge

    @Test func candidatesMergeHistoryBeforeSshConfig() {
        // History recency goes first; ssh_config entries fill in after.
        let history = [
            SSHHistoryEntry(target: "db-prod-1", template: "ssh-prod",
                            lastUsed: Date(timeIntervalSince1970: 2000), frequency: 1),
            SSHHistoryEntry(target: "api1", template: "ssh",
                            lastUsed: Date(timeIntervalSince1970: 1000), frequency: 1),
        ]
        let hosts = [
            SSHConfigHost(alias: "api1"),           // duplicate of history
            SSHConfigHost(alias: "web1", hostname: "web1.internal"),
        ]

        let merged = SSHLauncher.mergeCandidates(history: history, sshHosts: hosts)
        let names = merged.map(\.target)
        #expect(names == ["db-prod-1", "api1", "web1"])
        // The ssh_config hostname is preserved for rule matching.
        #expect(merged.last?.hostname == "web1.internal")
    }

    // MARK: - Ad-hoc fallback

    @Test func adHocEntryAppearsWhenNoMatch() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        await env.launcher.rebuildCandidates()
        let candidates = env.launcher.candidates(matching: "totally-novel")
        #expect(candidates.count == 1)
        #expect(candidates.first?.isAdHoc == true)
        #expect(candidates.first?.target == "totally-novel")
    }

    @Test func emptyQueryReturnsFullPool() async throws {
        let env = try makeEnv(
            sshHosts: [SSHConfigHost(alias: "alpha"), SSHConfigHost(alias: "beta")]
        )
        defer { env.cleanup() }
        await env.launcher.rebuildCandidates()
        let candidates = env.launcher.candidates(matching: "")
        #expect(candidates.map(\.target) == ["alpha", "beta"])
        // An empty pool does not produce an ad-hoc row.
        #expect(candidates.allSatisfy { !$0.isAdHoc })
    }

    // MARK: - Target parsing

    @Test func parseTargetWithUserAtHost() {
        let parsed = SSHTarget.parse("alice@db1.prod.example.com")
        #expect(parsed.user == "alice")
        #expect(parsed.host == "db1.prod.example.com")
    }

    @Test func parseTargetWithoutUser() {
        let parsed = SSHTarget.parse("db1.prod.example.com")
        #expect(parsed.user == nil)
        #expect(parsed.host == "db1.prod.example.com")
    }

    // MARK: - Template selection

    @Test func ruleHitsTemplateForAlias() throws {
        let matcher = SSHRuleMatcher.parse("ssh-prod *-prod-*")
        let env = try makeEnv(matcher: matcher)
        defer { env.cleanup() }

        let candidate = SSHCandidate(target: "db-prod-1", hostname: nil, isAdHoc: false)
        let resolution = env.launcher.resolve(candidate: candidate)
        #expect(resolution.templateID == "ssh-prod")
        #expect(resolution.variables["HOST"] == "db-prod-1")
    }

    @Test func ruleHitsTemplateForHostname() throws {
        // Alias doesn't match any glob, but the `Hostname` directive does.
        let matcher = SSHRuleMatcher.parse("ssh-prod *.prod.example.com")
        let env = try makeEnv(matcher: matcher)
        defer { env.cleanup() }

        let candidate = SSHCandidate(
            target: "db01",
            hostname: "db01.prod.example.com",
            isAdHoc: false
        )
        let resolution = env.launcher.resolve(candidate: candidate)
        #expect(resolution.templateID == "ssh-prod")
    }

    @Test func fallbackTemplateWhenNoRuleMatches() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let candidate = SSHCandidate(target: "boring-host", hostname: nil, isAdHoc: false)
        let resolution = env.launcher.resolve(candidate: candidate)
        #expect(resolution.templateID == SSHLauncher.fallbackTemplate)
    }

    // MARK: - Commit path

    @Test func spawnResolvesProfileWithVariables() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        await env.launcher.rebuildCandidates()

        let candidate = SSHCandidate(
            target: "alice@db1.example.com",
            hostname: nil,
            isAdHoc: false
        )
        let resolution = env.launcher.resolve(candidate: candidate)
        try await env.launcher.commit(resolution: resolution, placement: .newTab)

        // Spy captured the exact variables we expect `${HOST}` / `${USER}`
        // to be substituted from.
        #expect(env.spy.spawnCalls.count == 1)
        let call = env.spy.spawnCalls[0]
        #expect(call.templateID == SSHLauncher.fallbackTemplate)
        #expect(call.variables["HOST"] == "db1.example.com")
        #expect(call.variables["USER"] == "alice")
        #expect(call.placement == .newTab)
    }

    @Test func spawnUndefinedVariableShowsError() async throws {
        let env = try makeEnv(
            validateError: .undefinedVariable(name: "HOST")
        )
        defer { env.cleanup() }
        let candidate = SSHCandidate(target: "db1", hostname: nil, isAdHoc: false)
        let resolution = env.launcher.resolve(candidate: candidate)

        await #expect(throws: SSHLauncherError.undefinedVariable("HOST")) {
            try await env.launcher.commit(resolution: resolution, placement: .newTab)
        }
        #expect(env.spy.spawnCalls.isEmpty)
    }

    @Test func historyAppendedOnSuccess() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        let candidate = SSHCandidate(target: "db1", hostname: nil, isAdHoc: false)
        let resolution = env.launcher.resolve(candidate: candidate)
        try await env.launcher.commit(resolution: resolution, placement: .newTab)

        let entries = try await env.history.entries()
        #expect(entries.count == 1)
        #expect(entries[0].target == "db1")
        #expect(entries[0].template == SSHLauncher.fallbackTemplate)
    }

    @Test func historyNotAppendedOnFailure() async throws {
        let env = try makeEnv(validateError: .profileNotFound(id: "ssh"))
        defer { env.cleanup() }
        let candidate = SSHCandidate(target: "db1", hostname: nil, isAdHoc: false)
        let resolution = env.launcher.resolve(candidate: candidate)

        _ = try? await env.launcher.commit(resolution: resolution, placement: .newTab)
        let entries = try await env.history.entries()
        #expect(entries.isEmpty)
    }

    // MARK: - Batch commit (Phase 7)

    @Test func batchSpawnChainsPaneIDs() async throws {
        // First call should splitRight from the caller-supplied parent;
        // subsequent calls should splitRight from the previous spawn's id,
        // forming a chained column.
        let env = try makeEnv()
        defer { env.cleanup() }

        let parent = UUID()
        let newA = UUID()
        let newB = UUID()
        env.spy.spawnIDs = [newA, newB]

        let outcome = await env.launcher.commitBatch(
            resolutions: Self.resolutions(env, targets: ["db1", "db2"]),
            initialParent: parent
        )

        #expect(outcome.attempted == 2)
        #expect(outcome.succeeded == 2)
        #expect(outcome.failure == nil)
        #expect(outcome.lastPaneID == newB)
        #expect(env.spy.spawnCalls.count == 2)
        #expect(env.spy.spawnCalls[0].placement == .splitRight(parentPaneID: parent))
        #expect(env.spy.spawnCalls[1].placement == .splitRight(parentPaneID: newA))
    }

    @Test func batchSpawnFirstItemFallsBackToNewTabWithoutParent() async throws {
        // When no pane is focused (initialParent == nil) the first item
        // opens a new tab; the returned pane id then parents the next split.
        let env = try makeEnv()
        defer { env.cleanup() }

        let newA = UUID()
        env.spy.spawnIDs = [newA, UUID()]

        let outcome = await env.launcher.commitBatch(
            resolutions: Self.resolutions(env, targets: ["db1", "db2"]),
            initialParent: nil
        )

        #expect(outcome.succeeded == 2)
        #expect(env.spy.spawnCalls[0].placement == .newTab)
        #expect(env.spy.spawnCalls[1].placement == .splitRight(parentPaneID: newA))
    }

    @Test func batchSpawnFallsBackToNewTabWhenChainIDMissing() async throws {
        // Simulate a remote spawn: the first call returns nil (server
        // allocates asynchronously), so the chain is broken and the second
        // item restarts as a new tab rather than splitting a stale parent.
        let env = try makeEnv()
        defer { env.cleanup() }
        env.spy.spawnIDs = [nil, UUID()]

        let outcome = await env.launcher.commitBatch(
            resolutions: Self.resolutions(env, targets: ["db1", "db2"]),
            initialParent: UUID()
        )

        #expect(outcome.succeeded == 2)
        #expect(env.spy.spawnCalls[1].placement == .newTab)
    }

    @Test func batchSpawnStopsOnFirstFailure() async throws {
        // Three resolutions, second one throws. The third must not fire and
        // the outcome must report 1 success + the failing target.
        let env = try makeEnv()
        defer { env.cleanup() }
        env.spy.spawnIDs = [UUID(), UUID(), UUID()]
        env.spy.spawnFailures = [1: .undefinedVariable("HOST")]

        let outcome = await env.launcher.commitBatch(
            resolutions: Self.resolutions(env, targets: ["db1", "db2", "db3"]),
            initialParent: UUID()
        )

        // spawnCalls only records successful appends (the throw happens
        // before `.append`), so exactly one call landed before the failure.
        #expect(env.spy.spawnCalls.count == 1)
        #expect(env.spy.spawnCalls[0].variables["HOST"] == "db1")
        #expect(outcome.attempted == 2)
        #expect(outcome.succeeded == 1)
        #expect(outcome.failure?.target == "db2")
        #expect(outcome.failure?.error == .undefinedVariable("HOST"))
    }

    @Test func batchSpawnLastPaneIDIsLastSuccess() async throws {
        // Focus after a batch goes to the most recent successful pane —
        // the id of the one opened before the failure, not nil.
        let env = try makeEnv()
        defer { env.cleanup() }
        let first = UUID()
        env.spy.spawnIDs = [first, UUID()]
        env.spy.spawnFailures = [1: .profileNotFound("ssh-prod")]

        let outcome = await env.launcher.commitBatch(
            resolutions: Self.resolutions(env, targets: ["db1", "db2"]),
            initialParent: UUID()
        )

        #expect(outcome.lastPaneID == first)
    }

    @Test func batchSpawnAppendsHistoryOnlyForSuccesses() async throws {
        // History reflects what actually launched: first two succeed, third
        // fails, so the history should contain exactly two records.
        let env = try makeEnv()
        defer { env.cleanup() }
        env.spy.spawnIDs = [UUID(), UUID(), UUID()]
        env.spy.spawnFailures = [2: .undefinedVariable("HOST")]

        _ = await env.launcher.commitBatch(
            resolutions: Self.resolutions(env, targets: ["db1", "db2", "db3"]),
            initialParent: UUID()
        )

        let entries = try await env.history.entries()
        let targets = Set(entries.map(\.target))
        #expect(targets == ["db1", "db2"])
    }

    // MARK: - Helpers

    /// Records every spawn call made by a test launcher. Phase 7: `spawnID`
    /// lets a test inject the UUID the spawn closure should hand back so
    /// batch tests can verify pane-id chaining.
    final class Spy {
        struct Call: Equatable {
            let templateID: String
            let variables: [String: String]
            let placement: SSHPlacement
        }
        var spawnCalls: [Call] = []
        /// Sequence of UUIDs the spawn closure hands back, one per call.
        /// Consumed FIFO. When exhausted (or empty), the closure returns
        /// nil — simulating a remote spawn where the server allocates the
        /// id asynchronously.
        var spawnIDs: [UUID?] = []
        /// Optional per-call override that throws instead of spawning.
        /// Key = 0-based call index. Used by the batch-failure test.
        var spawnFailures: [Int: SSHLauncherError] = [:]
    }

    private struct Env {
        let directoryURL: URL
        let history: SSHHistory
        let launcher: SSHLauncher
        let spy: Spy
        let cleanup: @Sendable () -> Void
    }

    private func makeEnv(
        matcher: SSHRuleMatcher = SSHRuleMatcher(),
        sshHosts: [SSHConfigHost] = [],
        validateError: ProfileResolveError? = nil
    ) throws -> Env {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tongyou-ssh-launcher-\(UUID().uuidString)", isDirectory: true)
        let history = SSHHistory(directoryURL: dir)
        let spy = Spy()
        let launcher = SSHLauncher(
            history: history,
            matcher: matcher,
            sshConfigHosts: sshHosts,
            validateProfile: { _, _ in
                if let err = validateError { throw err }
            },
            spawn: { templateID, vars, placement in
                let index = spy.spawnCalls.count
                if let err = spy.spawnFailures[index] { throw err }
                spy.spawnCalls.append(Spy.Call(
                    templateID: templateID,
                    variables: vars,
                    placement: placement
                ))
                if index < spy.spawnIDs.count {
                    return spy.spawnIDs[index]
                }
                return nil
            }
        )
        return Env(
            directoryURL: dir,
            history: history,
            launcher: launcher,
            spy: spy,
            cleanup: { try? FileManager.default.removeItem(at: dir) }
        )
    }

    /// Convenience: make a list of resolved candidates for batch tests.
    private static func resolutions(
        _ env: Env,
        targets: [String]
    ) -> [SSHResolution] {
        targets.map { target in
            env.launcher.resolve(
                candidate: SSHCandidate(target: target, hostname: nil, isAdHoc: false)
            )
        }
    }
}
