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
        let history = ["db-prod-1", "api1"]
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
        env.launcher.rebuildCandidates(history: [])
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
        env.launcher.rebuildCandidates(history: [])
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
        #expect(resolution.variables["CMDPLT_SSH_HOST"] == "db-prod-1")
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
        env.launcher.rebuildCandidates(history: [])

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
        #expect(call.variables["CMDPLT_SSH_HOST"] == "db1.example.com")
        #expect(call.variables["CMDPLT_SSH_USER"] == "alice")
        #expect(call.placement == .newTab)
    }

    @Test func spawnUndefinedVariableShowsError() async throws {
        let env = try makeEnv(
            validateError: .undefinedVariable(name: "CMDPLT_SSH_HOST")
        )
        defer { env.cleanup() }
        let candidate = SSHCandidate(target: "db1", hostname: nil, isAdHoc: false)
        let resolution = env.launcher.resolve(candidate: candidate)

        await #expect(throws: SSHLauncherError.undefinedVariable("CMDPLT_SSH_HOST")) {
            try await env.launcher.commit(resolution: resolution, placement: .newTab)
        }
        #expect(env.spy.spawnCalls.isEmpty)
    }

    @Test func historyCallbackFiresOnSuccess() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        var recorded: [(String, String)] = []
        env.launcher.onRecordHistory = { candidate, templateID in
            recorded.append((candidate.target, templateID))
        }

        let candidate = SSHCandidate(target: "db1", hostname: nil, isAdHoc: false)
        let resolution = env.launcher.resolve(candidate: candidate)
        try await env.launcher.commit(resolution: resolution, placement: .newTab)

        #expect(recorded.count == 1)
        #expect(recorded[0].0 == "db1")
        #expect(recorded[0].1 == SSHLauncher.fallbackTemplate)
    }

    @Test func historyCallbackNotFiredOnFailure() async throws {
        let env = try makeEnv(validateError: .profileNotFound(id: "ssh"))
        defer { env.cleanup() }

        var recorded: [(String, String)] = []
        env.launcher.onRecordHistory = { candidate, templateID in
            recorded.append((candidate.target, templateID))
        }

        let candidate = SSHCandidate(target: "db1", hostname: nil, isAdHoc: false)
        let resolution = env.launcher.resolve(candidate: candidate)

        _ = try? await env.launcher.commit(resolution: resolution, placement: .newTab)
        #expect(recorded.isEmpty)
    }

    // MARK: - Batch validation + history (one-shot grid path)

    @Test func validateBatchReturnsSuccessWhenEveryProfileResolves() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        let resolutions = Self.resolutions(env, targets: ["db1", "db2", "db3"])
        let result = env.launcher.validateBatch(resolutions: resolutions)

        guard case .success(let validated) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }
        #expect(validated.count == 3)
        #expect(validated.map(\.candidate.target) == ["db1", "db2", "db3"])
    }

    @Test func validateBatchSurfacesFirstFailure() async throws {
        // First resolution that fails wins — callers surface that error to
        // the user and abort the whole batch before any PTY spawns.
        let env = try makeEnv()
        defer { env.cleanup() }
        env.spy.validationFailures = [1: .undefinedVariable(name: "CMDPLT_SSH_HOST")]

        let resolutions = Self.resolutions(env, targets: ["db1", "db2", "db3"])
        let result = env.launcher.validateBatch(resolutions: resolutions)

        guard case .failure(let failure) = result else {
            Issue.record("Expected .failure, got \(result)")
            return
        }
        #expect(failure.target == "db2")
        #expect(failure.error == .undefinedVariable("CMDPLT_SSH_HOST"))
    }

    @Test func recordBatchHistoryFiresCallbackForEveryResolution() throws {
        // Called after a successful one-shot tab spawn: every resolution's
        // target should trigger the history callback so the outer layer can
        // record it in PaletteHistory.
        let env = try makeEnv()
        defer { env.cleanup() }

        var recorded: [(String, String)] = []
        env.launcher.onRecordHistory = { candidate, templateID in
            recorded.append((candidate.target, templateID))
        }

        let resolutions = Self.resolutions(env, targets: ["db1", "db2", "db3"])
        env.launcher.recordBatchHistory(resolutions: resolutions)

        let targets = Set(recorded.map(\.0))
        #expect(targets == ["db1", "db2", "db3"])
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
        /// Counter for how many times `validateProfile` has run — lets the
        /// batch-validation test trigger a specific index to fail.
        var validateCallIndex: Int = 0
        /// Optional per-call override that makes `validateProfile` throw
        /// instead of succeed. Key = 0-based call index.
        var validationFailures: [Int: ProfileResolveError] = [:]
    }

    private struct Env {
        let launcher: SSHLauncher
        let spy: Spy
        let cleanup: @Sendable () -> Void
    }

    private func makeEnv(
        matcher: SSHRuleMatcher = SSHRuleMatcher(),
        sshHosts: [SSHConfigHost] = [],
        validateError: ProfileResolveError? = nil
    ) throws -> Env {
        let spy = Spy()
        let launcher = SSHLauncher(
            matcher: matcher,
            sshConfigHosts: sshHosts,
            validateProfile: { _, _ in
                if let err = validateError { throw err }
                let index = spy.validateCallIndex
                spy.validateCallIndex += 1
                if let err = spy.validationFailures[index] { throw err }
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
            launcher: launcher,
            spy: spy,
            cleanup: {}
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
