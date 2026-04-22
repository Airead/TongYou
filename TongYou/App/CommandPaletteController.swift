import AppKit
import Foundation

/// Which bucket of candidates the palette is currently matching against.
/// Derived from the current input's leading prefix — see
/// ``PaletteScope/parse(input:)``.
enum PaletteScope: Equatable {
    /// SSH connection (`ssh ` prefix).
    case ssh
    /// Command / action enumeration (`> ` prefix).
    case command
    /// Profile search (`p ` prefix).
    case profile
    /// Already-open tab switcher (`t ` prefix).
    case tab
    /// Already-open session switcher (default, no prefix).
    case session

    /// Parse the visible input into a `(scope, fuzzyText)` pair. `fuzzyText`
    /// is what gets fed to the fuzzy matcher — the prefix is stripped so
    /// `"s db"` searches "db" inside sessions, not "s db" literally.
    ///
    /// Session is the default scope: an empty input or any leading text that
    /// doesn't start with a known prefix fuzzy-matches against the open
    /// sessions list. SSH is reached via `"ssh <query>"`; the bare word
    /// `"ssh"` (no trailing space) stays in session scope so typing the
    /// three letters without committing to an SSH doesn't rip the list
    /// out from under the user.
    static func parse(input: String) -> (scope: PaletteScope, query: String) {
        if let tail = matchPrefix(input, prefix: "> ") { return (.command, tail) }
        if input == ">" { return (.command, "") }
        if let tail = matchPrefix(input, prefix: "p ") { return (.profile, tail) }
        if let tail = matchPrefix(input, prefix: "t ") { return (.tab, tail) }
        if let tail = matchPrefix(input, prefix: "s ") { return (.session, tail) }
        if let tail = matchPrefix(input, prefix: "ssh ") { return (.ssh, tail) }
        return (.session, input)
    }

    private static func matchPrefix(_ s: String, prefix: String) -> String? {
        guard s.hasPrefix(prefix) else { return nil }
        return String(s.dropFirst(prefix.count))
    }
}

/// The four modifier variants of the Enter key supported by the palette.
/// Dispatch is handled by the phase-specific scope; Phase 5 only records
/// which variant fired.
enum PaletteEnterMode: Equatable {
    case plain          // Enter
    case commandEnter   // ⌘Enter — split right
    case shiftEnter     // ⇧Enter — split below
    case optionEnter    // ⌥Enter — float pane
}

/// A single row in the candidate list. Opaque to the view apart from the
/// fields it renders.
///
/// `id` must be stable across re-renders of the same underlying entity.
/// Using `UUID` (fresh per build) is fine for Phase 5 because the controller
/// rebuilds candidates only when the query changes; later phases that back
/// candidates with real models should plumb the real ID through.
struct PaletteCandidate: Identifiable, Equatable {
    let id: UUID
    let primaryText: String
    let secondaryText: String?
    let scope: PaletteScope
    /// Optional accent color rendered as a small swatch next to the
    /// secondary text. SSH rows use it to show the template's background
    /// ("this will turn red") before Enter is pressed (plan Phase 6.5).
    let accentHex: String?
    /// Opaque per-scope payload. SSH scope stores the full `SSHResolution`
    /// here so the commit path can spawn without re-resolving. Kept as
    /// `Sendable`/`Equatable`-friendly optional to avoid dragging other
    /// scopes into SSH types.
    let sshResolution: SSHResolution?
    /// Profile-scope payload — the profile id the commit should spawn
    /// with. Non-nil only on profile-scope candidates.
    let profileID: String?
    /// Command-scope payload — the action the commit should dispatch.
    /// Non-nil only on command-scope candidates.
    let commandAction: Keybinding.Action?
    /// Non-nil when this candidate represents a history entry. Used for
    /// visual distinction (clock icon) and for ⌘⌫ deletion.
    let historyIdentifier: String?

    init(
        id: UUID = UUID(),
        primaryText: String,
        secondaryText: String? = nil,
        scope: PaletteScope,
        accentHex: String? = nil,
        sshResolution: SSHResolution? = nil,
        profileID: String? = nil,
        commandAction: Keybinding.Action? = nil,
        historyIdentifier: String? = nil
    ) {
        self.id = id
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.scope = scope
        self.accentHex = accentHex
        self.sshResolution = sshResolution
        self.profileID = profileID
        self.commandAction = commandAction
        self.historyIdentifier = historyIdentifier
    }
}

/// A ranked candidate — pairs the candidate with the fuzzy match result so
/// the view can render highlight ranges.
struct PaletteRow: Identifiable, Equatable {
    var id: UUID { candidate.id }
    let candidate: PaletteCandidate
    let match: FuzzyMatcher.Match
}

/// Observable state for the command palette. Purely data-driven — the view
/// binds to `input` / `highlightedIndex` / `rows` and calls back into
/// `moveHighlight` / `commit` etc. in response to key presses.
///
/// Phase 5 does not talk to any scope data source; the `ssh` candidate list
/// is set by the test harness, and Phase 6+ will wire in history /
/// ssh_config / rules.
@MainActor
@Observable
final class CommandPaletteController {

    /// The raw text shown in the palette input field.
    var input: String = "" {
        didSet {
            if input != oldValue {
                // If the user edits while browsing history, exit history mode.
                if isBrowsingHistory, !isProgrammaticInputChange, input != historyBrowsingSnapshot {
                    exitHistoryBrowsing()
                }
                isProgrammaticInputChange = false
                refreshRows(resetHighlight: true)
            }
        }
    }

    /// Set to `true` before programmatically changing `input` from inside
    /// history-browsing methods so the didSet observer does not exit
    /// history mode.
    private var isProgrammaticInputChange: Bool = false

    /// Derived from `input`. Re-evaluated on every text change.
    private(set) var scope: PaletteScope = .session

    /// Text fed to the fuzzy matcher — `input` with any scope prefix removed.
    private(set) var query: String = ""

    /// Ranked candidates for the current scope + query.
    private(set) var rows: [PaletteRow] = []

    /// Currently highlighted row index. `-1` when `rows` is empty.
    private(set) var highlightedIndex: Int = -1

    /// Multi-selection chip; Phase 5 just records toggles, Phase 7 wires
    /// into batch spawn. `OrderedSet` would be nicer but `[UUID]` with
    /// explicit dedup logic is sufficient — selection sets stay tiny
    /// (usually < 10).
    private(set) var selection: [UUID] = []

    /// When true, the palette view is mounted and should capture keystrokes.
    /// Writing `false` (via `close()`) is the canonical way to dismiss.
    private(set) var isOpen: Bool = false

    // MARK: - Scope data source

    /// Candidates for the SSH scope. Phase 5 leaves this empty; Phase 6 wires
    /// history + ssh_config entries in.
    var sshCandidates: [PaletteCandidate] = [] {
        didSet { refreshRows(resetHighlight: true) }
    }

    /// Phase 6 hook: when `scope == .ssh`, the fuzzy match yields no rows,
    /// and `query` is non-empty, the palette asks this closure for a
    /// synthesised "Connect ad-hoc: <query>" candidate. Returning nil
    /// leaves the list empty (the "No matches" placeholder renders).
    var sshAdHocBuilder: ((_ query: String) -> PaletteCandidate?)?

    /// Candidates for the session scope (Phase 8 will feed this from
    /// SessionManager). Kept here so the Phase 5 controller can be tested
    /// end-to-end.
    var sessionCandidates: [PaletteCandidate] = [] {
        didSet { refreshRows(resetHighlight: true) }
    }

    /// Candidates for the profile scope — populated by the window layer
    /// from `ProfileLoader.allRawProfiles` on every palette open.
    var profileCandidates: [PaletteCandidate] = [] {
        didSet { refreshRows(resetHighlight: true) }
    }

    /// Candidates for the command scope — populated by the window layer
    /// from the available `Keybinding.Action` set, with subtitles showing
    /// the bound shortcut (if any).
    var commandCandidates: [PaletteCandidate] = [] {
        didSet { refreshRows(resetHighlight: true) }
    }

    // MARK: - History candidates

    /// History candidates injected by the outer layer before `open()`.
    /// Shown at the top of the list when the query is empty.
    var historyCandidates: [PaletteCandidate] = [] {
        didSet { refreshRows(resetHighlight: true) }
    }

    /// Called when the user hits ⌘⌫ on a history row.
    var onDeleteHistoryEntry: ((_ scope: PaletteScope, _ identifier: String) -> Void)?

    // MARK: - Query history browsing

    /// Query strings for the current scope, injected by the outer layer on
    /// `open()`. Used for ↑↓ history browsing when the input is empty.
    var queryHistory: [String] = []

    /// When non-negative, the user is browsing query history with ↑↓ keys.
    /// The value is an index into `queryHistory` (0 = most recent).
    private(set) var historyBrowsingIndex: Int = -1

    /// Snapshot of the input text when history browsing started. Used to
    /// detect manual edits so we can exit history mode.
    private var historyBrowsingSnapshot: String = ""

    /// Returns `true` when the user is currently browsing query history.
    var isBrowsingHistory: Bool { historyBrowsingIndex >= 0 }

    /// Enter or continue browsing history backwards (older entries).
    /// Only works when the input is empty or already in history mode.
    /// Moves `input` to the next older query in `queryHistory`.
    func browseHistoryPrevious() {
        guard input.isEmpty || isBrowsingHistory else { return }
        guard !queryHistory.isEmpty else { return }

        if !isBrowsingHistory {
            historyBrowsingSnapshot = input
            historyBrowsingIndex = 0
        } else if historyBrowsingIndex < queryHistory.count - 1 {
            historyBrowsingIndex += 1
        }
        isProgrammaticInputChange = true
        input = queryHistory[historyBrowsingIndex]
    }

    /// Browse history forwards (newer entries). Exits history mode and
    /// restores an empty input when already at the most recent entry.
    func browseHistoryNext() {
        guard isBrowsingHistory else { return }
        if historyBrowsingIndex > 0 {
            historyBrowsingIndex -= 1
            isProgrammaticInputChange = true
            input = queryHistory[historyBrowsingIndex]
        } else {
            exitHistoryBrowsing()
        }
    }

    /// Exit history browsing mode and restore the pre-browsing input.
    private func exitHistoryBrowsing() {
        historyBrowsingIndex = -1
        isProgrammaticInputChange = true
        input = historyBrowsingSnapshot
        historyBrowsingSnapshot = ""
    }

    // MARK: - Delete (⌘⌫)

    /// Invoked when the user hits ⌘⌫ on a highlighted SSH row whose
    /// `sshResolution` targets a real (non ad-hoc) host. The string is the
    /// `target` — the host key used by history. The outer layer is
    /// expected to drop the matching history records and call
    /// ``requestRefocusInput()``.
    var onDeleteHistory: ((_ target: String) -> Void)?

    /// Invoked when the user hits ⌘⌫ on a highlighted session row.
    /// The UUID is the session id (stuffed into `candidate.id` by the
    /// session-scope builder). The outer layer closes the session and
    /// refreshes candidates.
    var onDeleteSession: ((_ sessionID: UUID) -> Void)?

    /// Bumped whenever the palette needs the input field to retake first
    /// responder — after an external side-effect that may have stolen
    /// focus (e.g. closing a session from the palette triggers
    /// `focusActiveTabRootPane`, which promotes a MetalView). The view
    /// observes changes to this counter via SwiftUI's update pass and
    /// re-asserts `makeFirstResponder`.
    private(set) var refocusTick: Int = 0

    /// Ask the view layer to re-focus the palette input field on the next
    /// update pass. Increments `refocusTick`.
    func requestRefocusInput() {
        refocusTick &+= 1
    }

    /// Dispatch ⌘⌫ for the currently highlighted row. Returns `true` when
    /// a callback actually ran so the view can skip the default field
    /// behaviour (which would clear the input). Returns `false` for
    /// scopes / rows that have no delete semantics (ad-hoc SSH,
    /// command/profile/tab) — in that case the key is ignored.
    @discardableResult
    func deleteHighlighted() -> Bool {
        guard rows.indices.contains(highlightedIndex) else { return false }
        let candidate = rows[highlightedIndex].candidate

        // History entries take priority — delete from history, not the
        // underlying resource.
        if let identifier = candidate.historyIdentifier {
            onDeleteHistoryEntry?(candidate.scope, identifier)
            return true
        }

        switch candidate.scope {
        case .ssh:
            guard let resolution = candidate.sshResolution,
                  !resolution.candidate.isAdHoc,
                  let handler = onDeleteHistory
            else { return false }
            handler(resolution.candidate.target)
            return true
        case .session:
            guard let handler = onDeleteSession else { return false }
            handler(candidate.id)
            return true
        case .command, .profile, .tab:
            return false
        }
    }

    // MARK: - Open / close

    /// Open the palette in session scope (the default) with an empty input.
    func open() {
        input = ""
        selection = []
        historyBrowsingIndex = -1
        historyBrowsingSnapshot = ""
        isOpen = true
        refreshRows(resetHighlight: true)
    }

    /// Close the palette. Resets transient state so the next open starts
    /// from a clean slate.
    func close() {
        isOpen = false
        input = ""
        selection = []
        rows = []
        highlightedIndex = -1
        historyBrowsingIndex = -1
        historyBrowsingSnapshot = ""
    }

    // MARK: - Keyboard navigation

    /// Move highlight by `delta` rows (wraps around the end of the list).
    /// No-op when `rows` is empty.
    func moveHighlight(by delta: Int) {
        guard !rows.isEmpty else {
            highlightedIndex = -1
            return
        }
        let count = rows.count
        let next = ((highlightedIndex + delta) % count + count) % count
        highlightedIndex = next
    }

    /// Toggle the currently highlighted row in/out of the multi-select bag.
    /// No-op when nothing is highlighted. Phase 5 only records the bag;
    /// Phase 7 wires batch spawn.
    func toggleSelection() {
        guard rows.indices.contains(highlightedIndex) else { return }
        let id = rows[highlightedIndex].id
        if let idx = selection.firstIndex(of: id) {
            selection.remove(at: idx)
        } else {
            selection.append(id)
        }
    }

    /// User pressed Enter (possibly with a modifier). Phase 5 returns the
    /// highlighted row and enter mode; wiring each scope + mode to a real
    /// action is the job of Phases 6–8.
    func commit(mode: PaletteEnterMode) -> (rows: [PaletteRow], mode: PaletteEnterMode)? {
        let committed = committedRows()
        guard !committed.isEmpty else { return nil }
        return (committed, mode)
    }

    /// Rows that would be acted upon by a commit. When the selection bag
    /// is non-empty, those rows are returned in selection order; otherwise
    /// the single highlighted row.
    func committedRows() -> [PaletteRow] {
        if !selection.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            return selection.compactMap { byID[$0] }
        }
        guard rows.indices.contains(highlightedIndex) else { return [] }
        return [rows[highlightedIndex]]
    }

    // MARK: - Query refresh

    private func refreshRows(resetHighlight: Bool) {
        let parsed = PaletteScope.parse(input: input)
        scope = parsed.scope
        query = parsed.query
        let pool = candidates(for: scope)
        var built: [PaletteRow]
        if scope == .ssh {
            built = rankSSH(query: query, in: pool)
            // ad-hoc fallback: only when the query is a plain literal
            // (no glob metachars / comma). With wildcards or multiple
            // alternatives the user is filtering, not naming a host, so
            // synthesising `ssh <query>` would never do what they want.
            if built.isEmpty, !query.isEmpty,
               !query.contains(where: SSHGlobMatcher.metaCharacters.contains),
               let adHoc = sshAdHocBuilder?(query) {
                built = [PaletteRow(
                    candidate: adHoc,
                    match: FuzzyMatcher.Match(score: 0, matchedIndices: [])
                )]
            }
        } else {
            let ranked = FuzzyMatcher.rank(query: query, in: pool, extract: { $0.primaryText })
            built = ranked.map { PaletteRow(candidate: $0.candidate, match: $0.match) }
        }

        // Inject history candidates at the top when the query is empty.
        if query.isEmpty {
            let history = historyCandidates
                .filter { $0.scope == scope }
                .prefix(5)
            let historyIDs = Set(history.compactMap(historyKey(for:)))
            // Remove regular candidates that already appear in history so
            // the history entry stays at the top.
            built = built.filter {
                guard let key = historyKey(for: $0.candidate) else { return true }
                return !historyIDs.contains(key)
            }
            let historyRows = history.map {
                PaletteRow(
                    candidate: $0,
                    match: FuzzyMatcher.Match(score: 0, matchedIndices: [])
                )
            }
            built = historyRows + built
        }

        rows = built
        if resetHighlight {
            highlightedIndex = rows.isEmpty ? -1 : 0
        } else if highlightedIndex >= rows.count {
            highlightedIndex = rows.isEmpty ? -1 : rows.count - 1
        }
    }

    /// Extract a stable key for deduplicating history candidates against
    /// the regular candidate pool. Falls back to `candidate.id` for session
    /// and tab candidates that don't have other identifying fields.
    private func historyKey(for candidate: PaletteCandidate) -> String? {
        candidate.historyIdentifier
            ?? candidate.sshResolution?.candidate.target
            ?? candidate.profileID
            ?? candidate.commandAction?.rawValue
            ?? candidate.id.uuidString
    }

    /// SSH-scope filter: glob-based matching with `,` as an OR separator.
    /// Empty or all-whitespace query returns the pool unchanged (in
    /// upstream order: history recency → ssh_config position). A non-
    /// empty query that doesn't parse into any glob (e.g. `", ,"`)
    /// returns an empty list rather than the pool — the user clearly
    /// typed *something*, so surfacing every candidate would be
    /// surprising.
    private func rankSSH(query: String, in pool: [PaletteCandidate]) -> [PaletteRow] {
        guard !query.isEmpty else {
            return pool.map {
                PaletteRow(
                    candidate: $0,
                    match: FuzzyMatcher.Match(score: 0, matchedIndices: [])
                )
            }
        }
        guard let patterns = SSHGlobMatcher.parse(query) else {
            return []
        }
        var out: [PaletteRow] = []
        out.reserveCapacity(pool.count)
        for candidate in pool {
            guard let hit = SSHGlobMatcher.match(text: candidate.primaryText, patterns: patterns) else {
                continue
            }
            out.append(PaletteRow(
                candidate: candidate,
                match: FuzzyMatcher.Match(score: 0, matchedIndices: hit.matchedIndices)
            ))
        }
        return out
    }

    private func candidates(for scope: PaletteScope) -> [PaletteCandidate] {
        switch scope {
        case .ssh:     return sshCandidates
        case .session: return sessionCandidates
        case .profile: return profileCandidates
        case .command: return commandCandidates
        // Tab scope is still a future hookup — the palette opens empty.
        case .tab:     return []
        }
    }
}
