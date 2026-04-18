import Foundation
import TYTerminal

/// MainActor-isolated store that assigns and resolves automation refs.
///
/// Contract:
///   - Refs assigned once stay stable for the lifetime of the underlying
///     object (rename / reorder / split does not change the ref).
///   - Counters (`sess:<n>`, `tab:<n>`, `pane:<n>`, `float:<n>`) are
///     monotonically increasing and never reused within a single GUI
///     process lifetime.
///   - Closed objects are pruned: their refs disappear from the active
///     map (subsequent `resolve` throws `NOT_FOUND`) but counters keep
///     advancing so no new object ever inherits an old number.
///
/// This type is actor-isolated to MainActor because it reads `TerminalSession`
/// snapshots that live on MainActor in the GUI app.
@MainActor
public final class GUIAutomationRefStore {

    // MARK: - Public types

    /// Result of resolving a ref against the current snapshot.
    public struct ResolvedTarget: Sendable, Equatable {
        public let sessionID: UUID
        public let tabID: UUID?
        public let paneID: UUID?
        public let floatID: UUID?

        public init(sessionID: UUID, tabID: UUID? = nil, paneID: UUID? = nil, floatID: UUID? = nil) {
            self.sessionID = sessionID
            self.tabID = tabID
            self.paneID = paneID
            self.floatID = floatID
        }
    }

    // MARK: - Internal state

    /// Per-session counters and mappings. A session's entry is dropped
    /// entirely when the session is closed.
    private struct PerSession {
        var tabCounter: UInt = 0
        var paneCounter: UInt = 0
        var floatCounter: UInt = 0

        var tabIndexByID: [UUID: UInt] = [:]
        var tabIDByIndex: [UInt: UUID] = [:]

        var paneIndexByID: [UUID: UInt] = [:]
        var paneIDByIndex: [UInt: UUID] = [:]
        var paneToTab: [UUID: UUID] = [:]

        var floatIndexByID: [UUID: UInt] = [:]
        var floatIDByIndex: [UInt: UUID] = [:]
        var floatToTab: [UUID: UUID] = [:]
    }

    /// Monotonic counter for `sess:<n>` fallback refs.
    private var sessionCounter: UInt = 0

    /// Active sessions: ref string ↔ session UUID.
    private var sessionIDByRef: [String: UUID] = [:]
    private var sessionRefByID: [UUID: String] = [:]

    /// Per-session state.
    private var perSession: [UUID: PerSession] = [:]

    public init() {}

    // MARK: - Refresh

    /// Reconcile the store with a new set of session snapshots.
    ///
    /// - Prunes entries for sessions no longer in the snapshot.
    /// - Assigns refs to new sessions, tabs, panes, and floats.
    /// - Leaves existing ref assignments untouched (stability guarantee).
    public func refreshRefs(snapshots: [SessionSnapshot]) {
        let activeSessionIDs = Set(snapshots.map(\.session.id))

        // Prune closed sessions entirely — their refs, counters, and subrefs.
        for (sessionID, ref) in sessionRefByID where !activeSessionIDs.contains(sessionID) {
            sessionIDByRef.removeValue(forKey: ref)
            sessionRefByID.removeValue(forKey: sessionID)
            perSession.removeValue(forKey: sessionID)
        }

        for snapshot in snapshots {
            let session = snapshot.session
            assignSessionRefIfNeeded(for: session)
            refreshChildren(of: session)
        }
    }

    private func assignSessionRefIfNeeded(for session: TerminalSession) {
        guard sessionRefByID[session.id] == nil else { return }

        // Try to use the name directly; fall back to `sess:<n>` otherwise.
        let name = session.name
        if AutomationRef.canUseAsSessionName(name), sessionIDByRef[name] == nil {
            sessionIDByRef[name] = session.id
            sessionRefByID[session.id] = name
        } else {
            sessionCounter += 1
            let ref = "sess:\(sessionCounter)"
            sessionIDByRef[ref] = session.id
            sessionRefByID[session.id] = ref
        }
    }

    private func refreshChildren(of session: TerminalSession) {
        var per = perSession[session.id] ?? PerSession()

        // Track currently-present child UUIDs so we can drop stale entries.
        var activeTabIDs: Set<UUID> = []
        var activePaneIDs: Set<UUID> = []
        var activeFloatIDs: Set<UUID> = []

        for tab in session.tabs {
            activeTabIDs.insert(tab.id)
            if per.tabIndexByID[tab.id] == nil {
                per.tabCounter += 1
                per.tabIndexByID[tab.id] = per.tabCounter
                per.tabIDByIndex[per.tabCounter] = tab.id
            }

            // Tree panes — DFS (left-first) order from PaneNode.allPaneIDs.
            for paneID in tab.paneTree.allPaneIDs {
                activePaneIDs.insert(paneID)
                per.paneToTab[paneID] = tab.id
                if per.paneIndexByID[paneID] == nil {
                    per.paneCounter += 1
                    per.paneIndexByID[paneID] = per.paneCounter
                    per.paneIDByIndex[per.paneCounter] = paneID
                }
            }

            // Floating panes, in array order.
            //
            // We key by `float.pane.id` rather than `float.id` (the
            // FloatingPane struct UUID) because the rest of the app —
            // FocusManager, MetalViewStore, SessionManager.closeFloatingPane,
            // etc. — all identify floats by their inner TerminalPane ID.
            // Keying by the struct UUID here would hand callers an identifier
            // they can't use anywhere else.
            for float in tab.floatingPanes {
                let floatID = float.pane.id
                activeFloatIDs.insert(floatID)
                per.floatToTab[floatID] = tab.id
                if per.floatIndexByID[floatID] == nil {
                    per.floatCounter += 1
                    per.floatIndexByID[floatID] = per.floatCounter
                    per.floatIDByIndex[per.floatCounter] = floatID
                }
            }
        }

        // Prune tabs/panes/floats that disappeared.
        for (tabID, idx) in per.tabIndexByID where !activeTabIDs.contains(tabID) {
            per.tabIndexByID.removeValue(forKey: tabID)
            per.tabIDByIndex.removeValue(forKey: idx)
        }
        for (paneID, idx) in per.paneIndexByID where !activePaneIDs.contains(paneID) {
            per.paneIndexByID.removeValue(forKey: paneID)
            per.paneIDByIndex.removeValue(forKey: idx)
            per.paneToTab.removeValue(forKey: paneID)
        }
        for (floatID, idx) in per.floatIndexByID where !activeFloatIDs.contains(floatID) {
            per.floatIndexByID.removeValue(forKey: floatID)
            per.floatIDByIndex.removeValue(forKey: idx)
            per.floatToTab.removeValue(forKey: floatID)
        }

        perSession[session.id] = per
    }

    // MARK: - Resolve

    /// Resolve a parsed ref to concrete UUIDs.
    public func resolve(_ ref: AutomationRef) throws -> ResolvedTarget {
        guard let sessionID = sessionIDByRef[ref.sessionSegment] else {
            throw AutomationError.sessionNotFound(ref.description)
        }
        guard let per = perSession[sessionID] else {
            throw AutomationError.sessionNotFound(ref.description)
        }

        switch ref {
        case .session:
            return ResolvedTarget(sessionID: sessionID)
        case .tab(_, let index):
            guard let tabID = per.tabIDByIndex[index] else {
                throw AutomationError.tabNotFound(ref.description)
            }
            return ResolvedTarget(sessionID: sessionID, tabID: tabID)
        case .pane(_, let index):
            guard let paneID = per.paneIDByIndex[index] else {
                throw AutomationError.paneNotFound(ref.description)
            }
            let tabID = per.paneToTab[paneID]
            return ResolvedTarget(sessionID: sessionID, tabID: tabID, paneID: paneID)
        case .float(_, let index):
            guard let floatID = per.floatIDByIndex[index] else {
                throw AutomationError.floatNotFound(ref.description)
            }
            let tabID = per.floatToTab[floatID]
            return ResolvedTarget(sessionID: sessionID, tabID: tabID, floatID: floatID)
        }
    }

    /// Parse and resolve in one step — convenience wrapper.
    public func resolve(refString: String) throws -> ResolvedTarget {
        let ref = try AutomationRef.parse(refString)
        return try resolve(ref)
    }

    // MARK: - Reverse lookup

    public func sessionRef(for sessionID: UUID) -> String? {
        sessionRefByID[sessionID]
    }

    public func tabRef(sessionID: UUID, tabID: UUID) -> String? {
        guard let per = perSession[sessionID],
              let idx = per.tabIndexByID[tabID],
              let sessionRef = sessionRefByID[sessionID] else { return nil }
        return "\(sessionRef)/tab:\(idx)"
    }

    public func paneRef(sessionID: UUID, paneID: UUID) -> String? {
        guard let per = perSession[sessionID],
              let idx = per.paneIndexByID[paneID],
              let sessionRef = sessionRefByID[sessionID] else { return nil }
        return "\(sessionRef)/pane:\(idx)"
    }

    public func floatRef(sessionID: UUID, floatID: UUID) -> String? {
        guard let per = perSession[sessionID],
              let idx = per.floatIndexByID[floatID],
              let sessionRef = sessionRefByID[sessionID] else { return nil }
        return "\(sessionRef)/float:\(idx)"
    }

    // MARK: - Listing

    /// Build a `SessionListResponse` describing the given snapshots.
    /// Callers should invoke `refreshRefs(snapshots:)` first so the store
    /// has up-to-date ref assignments for every object mentioned.
    public func describeSessions(snapshots: [SessionSnapshot]) -> SessionListResponse {
        let descriptors = snapshots.map { snapshot in describe(snapshot: snapshot) }
        return SessionListResponse(sessions: descriptors)
    }

    private func describe(snapshot: SessionSnapshot) -> SessionDescriptor {
        let session = snapshot.session
        let sessionRef = sessionRefByID[session.id] ?? "sess:?"
        let type: AutomationSessionType = session.source.isRemote ? .remote : .local

        let tabs = session.tabs.enumerated().map { (offset, tab) -> TabDescriptor in
            let tabRefStr = tabRef(sessionID: session.id, tabID: tab.id) ?? "\(sessionRef)/tab:?"
            let paneRefs = tab.paneTree.allPaneIDs.compactMap {
                paneRef(sessionID: session.id, paneID: $0)
            }
            // floatRef is keyed by the inner TerminalPane UUID — see
            // refreshChildren for the rationale.
            let floatRefs = tab.floatingPanes.compactMap {
                floatRef(sessionID: session.id, floatID: $0.pane.id)
            }
            return TabDescriptor(
                ref: tabRefStr,
                title: tab.title,
                active: offset == session.activeTabIndex,
                panes: paneRefs,
                floats: floatRefs
            )
        }

        return SessionDescriptor(
            ref: sessionRef,
            name: session.name,
            type: type,
            state: snapshot.state,
            active: snapshot.isActive,
            tabs: tabs
        )
    }
}
