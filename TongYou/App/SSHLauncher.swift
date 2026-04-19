import Foundation
import TYConfig

/// Where a new SSH pane should materialise when the user commits a
/// candidate from the palette. Phase 6 implements the single-row variants
/// (`newTab` / `splitRight` / `splitBelow` / `floatPane`). The `currentTab`
/// case is reserved for Phase 7 batch spawns.
enum SSHPlacement: Equatable {
    case newTab
    case splitRight(parentPaneID: UUID)
    case splitBelow(parentPaneID: UUID)
    case floatPane
    case currentTab(parentPaneID: UUID)
}

/// User-facing errors surfaced by the palette when spawning an SSH pane
/// fails. The palette renders these as red toasts without closing itself
/// (plan Phase 6.6).
enum SSHLauncherError: Error, LocalizedError, Equatable {
    case undefinedVariable(String)
    case profileNotFound(String)
    case invalidProfile(String)

    var errorDescription: String? {
        switch self {
        case .undefinedVariable(let name):
            return "Profile uses undefined variable '${\(name)}'"
        case .profileNotFound(let id):
            return "Profile '\(id)' not found"
        case .invalidProfile(let detail):
            return "Invalid profile: \(detail)"
        }
    }
}

/// A single palette candidate in the SSH scope. Carries enough metadata
/// for the view to render the subtitle (`ssh-prod · #1a0a0a`) and for the
/// commit path to spawn the right pane.
struct SSHCandidate: Equatable {
    /// Display string (alias or typed text). Also drives fuzzy matching.
    let target: String
    /// Optional hostname (from `~/.ssh/config`'s `Hostname` directive).
    /// Template rules run against this in addition to `target`.
    let hostname: String?
    /// Whether this is the synthetic "connect ad-hoc: <input>" row that the
    /// palette inserts when no real candidate matches.
    let isAdHoc: Bool
}

/// The "user@host" parse of a target string.
struct SSHTarget: Equatable {
    /// The text before `@`, if present. Nil means "profile provides USER".
    let user: String?
    /// The text after `@`, or the entire target when no `@` was supplied.
    let host: String

    /// Split `target` at the first `@`. Multiple `@`s are unusual; we treat
    /// only the first one as the user separator (the rest become part of
    /// the host, matching ssh(1) behaviour).
    static func parse(_ target: String) -> SSHTarget {
        guard let atIndex = target.firstIndex(of: "@") else {
            return SSHTarget(user: nil, host: target)
        }
        let user = String(target[..<atIndex])
        let host = String(target[target.index(after: atIndex)...])
        return SSHTarget(user: user, host: host)
    }
}

/// A resolved candidate paired with the template it will be launched with
/// and the variables that get fed to `${HOST}` / `${USER}`. The palette
/// uses this to show the template subtitle *before* Enter is pressed so
/// the user can see which colour they're about to get.
struct SSHResolution: Equatable {
    let candidate: SSHCandidate
    let target: SSHTarget
    /// Template profile id the palette would use on commit.
    let templateID: String
    /// Variables the caller hands to `ProfileMerger.resolve`.
    let variables: [String: String]
}

/// Owns the Phase 2/3/4 data sources and bridges them to the Phase 5
/// command palette. `@MainActor` because it mutates the history actor
/// only through awaited calls and hands candidates back to SwiftUI.
@MainActor
final class SSHLauncher {

    /// Fallback template when no rule matches. Matches Phase 9's seeded
    /// default profile name.
    static let fallbackTemplate = "ssh"

    // MARK: - Collaborators

    /// Returns the new pane's UUID when the spawn is local and the id is
    /// known synchronously, or nil for remote spawns (server allocates
    /// asynchronously) / non-local fallbacks. Batch commits use the
    /// returned id to chain subsequent splits off the previous pane.
    private let spawn: @MainActor (String, [String: String], SSHPlacement) throws -> UUID?
    private let validateProfile: @MainActor (String, [String: String]) throws -> Void
    private let history: SSHHistory
    private var matcher: SSHRuleMatcher
    private var sshConfigHosts: [SSHConfigHost]

    /// Cached candidate list. Rebuilt from `history` + `sshConfigHosts`
    /// when `refreshCandidates()` is called (palette open / after a
    /// successful spawn).
    private(set) var candidates: [SSHCandidate] = []

    // MARK: - Init

    /// Construct a launcher with the shared SSH data sources. `spawn` and
    /// `validateProfile` are closures so tests can inject mocks without
    /// pulling in `SessionManager`.
    init(
        history: SSHHistory,
        matcher: SSHRuleMatcher = SSHRuleMatcher(),
        sshConfigHosts: [SSHConfigHost] = [],
        validateProfile: @escaping @MainActor (String, [String: String]) throws -> Void,
        spawn: @escaping @MainActor (String, [String: String], SSHPlacement) throws -> UUID?
    ) {
        self.history = history
        self.matcher = matcher
        self.sshConfigHosts = sshConfigHosts
        self.validateProfile = validateProfile
        self.spawn = spawn
    }

    // MARK: - Data-source refresh

    /// Re-read `~/.ssh/config` and the rules file, and rebuild the
    /// candidate list from on-disk state. Intended to run every time the
    /// palette opens so a freshly edited ssh_config is picked up without
    /// restarting TongYou.
    func reload(
        ruleFileURL: URL = URL(fileURLWithPath: "/dev/null"),
        sshConfigURL: URL = SSHConfigHosts.defaultURL
    ) async {
        do { matcher = try SSHRuleMatcher.load(from: ruleFileURL) }
        catch { matcher = SSHRuleMatcher() }
        do { sshConfigHosts = try SSHConfigHosts.load(from: sshConfigURL).hosts }
        catch { sshConfigHosts = [] }
        await rebuildCandidates()
    }

    /// Drop every history record whose target matches, then rebuild the
    /// candidate list so the palette stops showing it. No-op when the
    /// target has no history (e.g. ssh_config-only aliases — the palette
    /// row will stay since it is sourced from the config file).
    /// Returns the number of dropped records for callers that want to
    /// distinguish "nothing happened" from "deleted".
    @discardableResult
    func deleteHistory(target: String) async -> Int {
        let dropped = (try? await history.remove(target: target)) ?? 0
        await rebuildCandidates()
        return dropped
    }

    /// Rebuild the in-memory candidate list without re-reading the
    /// on-disk files. Callers use this after an append-to-history so the
    /// freshly used target bubbles to the top.
    func rebuildCandidates() async {
        let historyEntries = (try? await history.entries()) ?? []
        candidates = Self.mergeCandidates(
            history: historyEntries,
            sshHosts: sshConfigHosts
        )
    }

    /// Merge history + ssh_config hosts into a single ordered list, preserving
    /// history-recency order first, then ssh_config order. De-duplicates by
    /// `target` (case-sensitive, matching `SSHHistory`).
    static func mergeCandidates(
        history: [SSHHistoryEntry],
        sshHosts: [SSHConfigHost]
    ) -> [SSHCandidate] {
        var result: [SSHCandidate] = []
        var seen = Set<String>()
        for entry in history {
            guard seen.insert(entry.target).inserted else { continue }
            // History records the user-typed target; ssh_config hostname
            // is only known for the alias path, not for the typed string.
            result.append(SSHCandidate(
                target: entry.target,
                hostname: nil,
                isAdHoc: false
            ))
        }
        for host in sshHosts {
            guard seen.insert(host.alias).inserted else { continue }
            result.append(SSHCandidate(
                target: host.alias,
                hostname: host.hostname,
                isAdHoc: false
            ))
        }
        return result
    }

    // MARK: - Resolution

    /// Candidates to feed the palette for a given query. When no fuzzy
    /// candidate matches and the query is non-empty, an `adHoc` candidate
    /// is synthesised on top so the user can still hit Enter to connect
    /// to an arbitrary host.
    func candidates(matching query: String) -> [SSHCandidate] {
        let real = candidates
        if query.isEmpty { return real }

        let matches = FuzzyMatcher
            .rank(query: query, in: real, extract: { $0.target })
            .map(\.candidate)
        if matches.isEmpty {
            return [SSHCandidate(target: query, hostname: nil, isAdHoc: true)]
        }
        return matches
    }

    /// Attach a template + variables to a candidate so the palette can
    /// show the subtitle ("ssh-prod · #1a0a0a") before commit.
    func resolve(candidate: SSHCandidate) -> SSHResolution {
        let target = SSHTarget.parse(candidate.target)
        let templateID = templateForCandidate(candidate, target: target)
        var variables: [String: String] = ["HOST": target.host]
        if let user = target.user, !user.isEmpty {
            variables["USER"] = user
        }
        return SSHResolution(
            candidate: candidate,
            target: target,
            templateID: templateID,
            variables: variables
        )
    }

    /// Pick a template for a candidate. Runs rules against both the alias
    /// (so `Host db01` matches `db*` rules) and the `Hostname` value from
    /// ssh_config (so rules keyed on real DNS names still fire even when
    /// the user picks an alias). First hit on either wins; fallback is
    /// `fallbackTemplate`.
    private func templateForCandidate(
        _ candidate: SSHCandidate,
        target: SSHTarget
    ) -> String {
        if let hit = matcher.match(hostname: target.host) { return hit }
        if let hostname = candidate.hostname,
           let hit = matcher.match(hostname: hostname) { return hit }
        return Self.fallbackTemplate
    }

    // MARK: - Commit

    /// Launch the SSH session described by `resolution` at `placement`. On
    /// success, append a history record; on failure, throw and do not
    /// write history (plan: "historyNotAppendedOnFailure"). Returns the new
    /// pane's UUID when the underlying spawn exposes one synchronously
    /// (local sessions), nil for remote spawns where the server allocates
    /// the id asynchronously.
    @discardableResult
    func commit(
        resolution: SSHResolution,
        placement: SSHPlacement
    ) async throws -> UUID? {
        // Validate first so we can surface `.undefinedVariable` etc. without
        // silently falling back to the default profile (which is how
        // `createPane` handles resolve failures internally).
        do {
            try validateProfile(resolution.templateID, resolution.variables)
        } catch let err as ProfileResolveError {
            throw Self.translate(err)
        }

        let paneID = try spawn(resolution.templateID, resolution.variables, placement)

        try? await history.append(
            template: resolution.templateID,
            target: resolution.candidate.target
        )
        await rebuildCandidates()
        return paneID
    }

    // MARK: - Batch commit (Phase 7)

    /// Outcome of a batch spawn. Surfaced to the caller so the palette can
    /// decide what to toast and which pane to focus.
    struct BatchOutcome: Equatable {
        /// How many resolutions were attempted (≤ input count; stops early
        /// on the first failure).
        let attempted: Int
        /// How many spawns succeeded.
        let succeeded: Int
        /// Nil on full success; on failure, the resolution that failed and
        /// the translated error.
        let failure: BatchFailure?

        struct BatchFailure: Equatable, Error {
            let target: String
            let error: SSHLauncherError
        }
    }

    /// Pre-validate every `resolutions` entry (profile resolution + variable
    /// expansion) and surface the first failure. Returns the resolutions in
    /// order when every entry is valid. Kept separate from the actual
    /// spawn path so callers (e.g. the palette) can fail fast without
    /// partially opening panes.
    func validateBatch(
        resolutions: [SSHResolution]
    ) -> Result<[SSHResolution], BatchOutcome.BatchFailure> {
        for resolution in resolutions {
            do {
                try validateProfile(resolution.templateID, resolution.variables)
            } catch let err as ProfileResolveError {
                return .failure(.init(
                    target: resolution.candidate.target,
                    error: Self.translate(err)
                ))
            } catch {
                return .failure(.init(
                    target: resolution.candidate.target,
                    error: .invalidProfile(String(describing: error))
                ))
            }
        }
        return .success(resolutions)
    }

    /// Append history records for every successfully-committed resolution
    /// and rebuild the in-memory candidate list. Called after the palette's
    /// batch path finishes spawning the new tab.
    func recordBatchHistory(resolutions: [SSHResolution]) async {
        for resolution in resolutions {
            try? await history.append(
                template: resolution.templateID,
                target: resolution.candidate.target
            )
        }
        await rebuildCandidates()
    }

    /// Map core `ProfileResolveError` cases onto the user-visible enum.
    static func translate(_ error: ProfileResolveError) -> SSHLauncherError {
        switch error {
        case .undefinedVariable(let name): return .undefinedVariable(name)
        case .profileNotFound(let id):     return .profileNotFound(id)
        default:                           return .invalidProfile(String(describing: error))
        }
    }
}
