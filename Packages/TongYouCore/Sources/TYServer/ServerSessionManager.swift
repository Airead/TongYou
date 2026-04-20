import Foundation
import TYConfig
import TYTerminal
import TYProtocol

/// Server-side tab containing a pane tree and terminal cores.
struct ServerTab {
    let id: TabID
    var title: String
    var paneTree: PaneNode
    var terminalCores: [PaneID: TerminalCore]
    var floatingPanes: [FloatingPaneInfo] = []
    var floatingPaneCores: [PaneID: TerminalCore] = [:]
    /// Profile id associated with each floating pane, keyed by paneID.
    /// Tree panes carry their own `profileID` inside `TerminalPane`; floating
    /// panes only exist as `FloatingPaneInfo` (id + geometry), so we keep the
    /// profile association here and surface it through `toSessionInfo`.
    var floatingPaneProfileIDs: [PaneID: String] = [:]
    /// Profile variables associated with each floating pane, keyed by paneID.
    /// Parallels `floatingPaneProfileIDs` — tree panes carry `variables` on
    /// `TerminalPane` directly, floating panes only have a geometry record.
    var floatingPaneVariables: [PaneID: [String: String]] = [:]
    /// `closeOnExit` associated with each floating pane, keyed by paneID.
    /// Only populated when the originating `StartupSnapshot.closeOnExit` was
    /// explicitly set; a missing entry means "unspecified" (nil on the wire).
    /// Tree panes carry the same information on `TerminalPane.startupSnapshot`.
    var floatingPaneCloseOnExit: [PaneID: Bool] = [:]
    /// The pane that was last focused in this tab by any client.
    var focusedPaneID: PaneID?

    /// Return the cwd of the focused pane (or the first pane as fallback).
    func focusedPaneCwd(coreLookup: [PaneID: TerminalCore]) -> String? {
        let target = focusedPaneID ?? PaneID(paneTree.firstPane.id)
        return coreLookup[target]?.currentWorkingDirectory
    }

    /// Return the `profileID` of the focused pane, looking through both
    /// the tree (where panes carry profileID on `TerminalPane`) and the
    /// floating-pane table. Returns nil when the focused pane cannot be
    /// located, which callers map to `default`.
    func focusedPaneProfileID() -> String? {
        let target = focusedPaneID ?? PaneID(paneTree.firstPane.id)
        if let pane = paneTree.findPane(id: target.uuid) {
            return pane.profileID
        }
        return floatingPaneProfileIDs[target]
    }

    /// Variables captured on the focused pane. Mirrors
    /// `focusedPaneProfileID()` — checks the tree first and falls back to
    /// the floating-pane table. Empty dict when the focused pane is a
    /// non-templated profile (the usual case for `default`).
    func focusedPaneVariables() -> [String: String] {
        let target = focusedPaneID ?? PaneID(paneTree.firstPane.id)
        if let pane = paneTree.findPane(id: target.uuid) {
            return pane.variables
        }
        return floatingPaneVariables[target] ?? [:]
    }
}

/// Server-side session containing tabs and panes.
struct ServerSession {
    let id: SessionID
    var name: String
    var tabs: [ServerTab]
    var activeTabIndex: Int

    var activeTab: ServerTab? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex]
    }

    func toSessionInfo(coreLookup: [PaneID: TerminalCore] = [:]) -> SessionInfo {
        let tabInfos = tabs.map { tab in
            TabInfo(
                id: tab.id,
                title: tab.title,
                layout: LayoutTree(from: tab.paneTree),
                floatingPanes: tab.floatingPanes,
                focusedPaneID: tab.focusedPaneID
            )
        }
        // Collect pane metadata from all tree panes and floating panes.
        var metadata: [PaneID: RemotePaneMetadata] = [:]
        for tab in tabs {
            // Tree panes carry profileID + startupSnapshot + variables
            // directly on TerminalPane.
            var treeProfileIDs: [PaneID: String] = [:]
            var treeCloseOnExit: [PaneID: Bool?] = [:]
            var treeVariables: [PaneID: [String: String]] = [:]
            for pane in tab.paneTree.allPanes {
                treeProfileIDs[PaneID(pane.id)] = pane.profileID
                treeCloseOnExit[PaneID(pane.id)] = pane.startupSnapshot.closeOnExit
                treeVariables[PaneID(pane.id)] = pane.variables
            }
            for paneUUID in tab.paneTree.allPaneIDs {
                let pid = PaneID(paneUUID)
                let cwd = coreLookup[pid]?.currentWorkingDirectory
                let profileID = treeProfileIDs[pid]
                let closeOnExit = treeCloseOnExit[pid] ?? nil
                let variables = treeVariables[pid] ?? [:]
                if cwd != nil || profileID != nil || closeOnExit != nil || !variables.isEmpty {
                    metadata[pid] = RemotePaneMetadata(
                        cwd: cwd,
                        profileID: profileID,
                        closeOnExit: closeOnExit,
                        variables: variables
                    )
                }
            }
            for fp in tab.floatingPanes {
                let cwd = coreLookup[fp.paneID]?.currentWorkingDirectory
                let profileID = tab.floatingPaneProfileIDs[fp.paneID]
                let closeOnExit = tab.floatingPaneCloseOnExit[fp.paneID]
                let variables = tab.floatingPaneVariables[fp.paneID] ?? [:]
                if cwd != nil || profileID != nil || closeOnExit != nil || !variables.isEmpty {
                    metadata[fp.paneID] = RemotePaneMetadata(
                        cwd: cwd,
                        profileID: profileID,
                        closeOnExit: closeOnExit,
                        variables: variables
                    )
                }
            }
        }
        return SessionInfo(
            id: id,
            name: name,
            tabs: tabInfos,
            activeTabIndex: activeTabIndex,
            paneMetadata: metadata
        )
    }

    /// Find the tab index that contains a given pane (tree or floating).
    func tabIndex(for paneID: PaneID) -> Int? {
        tabs.firstIndex {
            $0.paneTree.allPaneIDs.contains(paneID.uuid)
            || $0.floatingPanes.contains(where: { $0.paneID == paneID })
        }
    }

    /// Find the tab index and floating pane index for a given pane ID.
    func floatingPaneLocation(for paneID: PaneID) -> (tabIndex: Int, fpIndex: Int)? {
        for (tabIdx, tab) in tabs.enumerated() {
            if let fpIdx = tab.floatingPanes.firstIndex(where: { $0.paneID == paneID }) {
                return (tabIdx, fpIdx)
            }
        }
        return nil
    }
}

/// Manages all server-side sessions, tabs, and panes.
///
/// Each pane owns a `TerminalCore` instance that runs its PTY process.
public final class ServerSessionManager {

    private var sessions: [SessionID: ServerSession] = [:]
    private var config: ServerConfig
    private let sessionStore: SessionStore?

    /// Flat lookup from PaneID to its TerminalCore for O(1) access on the hot path.
    private var coreLookup: [PaneID: TerminalCore] = [:]

    /// Per-pane map of client window sizes for multi-client size negotiation.
    /// Effective PTY size = min(cols) × min(rows) across all clients (tmux-style).
    private var clientPaneSizes: [PaneID: [UUID: (cols: UInt16, rows: UInt16)]] = [:]

    /// Overlay stack for run-in-place: maps paneID to suspended original cores.
    /// When an overlay is active, coreLookup[paneID] points to the overlay core;
    /// the original core is preserved here and restored when the overlay exits.
    private var overlayStacks: [PaneID: [TerminalCore]] = [:]

    /// Debounced persistence: batches mutation-triggered saves so we
    /// only write to disk at most once per 0.5s per session.
    private var saveScheduler: DebouncedSaver<SessionID>!

    var onScreenDirty: ((SessionID, PaneID) -> Void)?
    var onTitleChanged: ((SessionID, PaneID, String) -> Void)?
    var onCwdChanged: ((SessionID, PaneID, String) -> Void)?
    var onBell: ((SessionID, PaneID) -> Void)?
    var onClipboardSet: ((String) -> Void)?
    var onPaneExited: ((SessionID, PaneID, Int32) -> Void)?

    /// Tracks the last known cwd per pane so we only fire onCwdChanged on actual changes.
    private var lastKnownCwd: [PaneID: String] = [:]

    public init(config: ServerConfig) {
        self.config = config
        if let directory = config.persistenceDirectory {
            self.sessionStore = SessionStore(directory: directory)
        } else {
            self.sessionStore = nil
        }
        // Initialise the scheduler before restoring so that any
        // save-triggering code paths reached during restoration find
        // a live scheduler instead of a nil IUO.
        self.saveScheduler = DebouncedSaver<SessionID> { [weak self] id in
            self?.flushSession(id: id)
        }
        if let sessionStore {
            for persisted in sessionStore.loadAll() {
                restoreSession(from: persisted)
            }
        }
    }

    /// Legacy convenience init for tests.
    public convenience init(
        defaultColumns: UInt16 = 80,
        defaultRows: UInt16 = 24,
        defaultWorkingDirectory: String? = nil
    ) {
        self.init(config: ServerConfig(
            defaultColumns: defaultColumns,
            defaultRows: defaultRows,
            defaultWorkingDirectory: defaultWorkingDirectory
        ))
    }

    /// Update configuration for future sessions.
    /// Existing sessions retain their original settings.
    public func updateConfig(_ newConfig: ServerConfig) {
        config = newConfig
    }

    // MARK: - Session Operations

    public func listSessions() -> [SessionInfo] {
        sessions.values.map { $0.toSessionInfo(coreLookup: coreLookup) }
    }

    @discardableResult
    public func createSession(name: String? = nil) -> SessionInfo {
        let sessionID = SessionID()
        let tabID = TabID()
        let sessionName = name ?? "Session \(sessions.count + 1)"

        let (paneID, pane, core) = createAndStartPane(sessionID: sessionID)
        let paneTree = PaneNode.leaf(pane)

        let tab = ServerTab(
            id: tabID,
            title: sessionName,
            paneTree: paneTree,
            terminalCores: [paneID: core]
        )

        let session = ServerSession(
            id: sessionID,
            name: sessionName,
            tabs: [tab],
            activeTabIndex: 0
        )

        sessions[sessionID] = session
        saveSession(id: sessionID)
        Log.info("Session created: \(sessionName) (\(sessionID))", category: .session)
        return session.toSessionInfo(coreLookup: coreLookup)
    }

    public func renameSession(id: SessionID, name: String) {
        guard sessions[id] != nil else { return }
        sessions[id]?.name = name
        saveSession(id: id)
        Log.info("Session renamed: \(name) (\(id))", category: .session)
    }

    public func stopAllSessions() {
        saveScheduler.cancelAll()

        for (_, session) in sessions {
            for tab in session.tabs { teardownAllPanes(in: tab) }
        }
        sessions.removeAll()
    }

    public func closeSession(id: SessionID) {
        cancelPendingSave(id: id)
        guard let session = sessions.removeValue(forKey: id) else { return }
        for tab in session.tabs { teardownAllPanes(in: tab) }
        sessionStore?.delete(sessionID: id)
        Log.info("Session closed: \(session.name) (\(id))", category: .session)
    }

    public func sessionInfo(for id: SessionID) -> SessionInfo? {
        sessions[id]?.toSessionInfo(coreLookup: coreLookup)
    }

    public var hasSessions: Bool { !sessions.isEmpty }
    public var sessionCount: Int { sessions.count }

    // MARK: - Tab Operations

    @discardableResult
    public func createTab(
        sessionID: SessionID,
        profileID: String? = nil,
        snapshot: StartupSnapshot? = nil,
        variables: [String: String] = [:]
    ) -> TabID? {
        guard let session = sessions[sessionID] else { return nil }

        // If caller provided a snapshot, trust it fully; otherwise inherit
        // cwd from the focused pane of the active tab (current behavior).
        let focusedCwd = session.activeTab?.focusedPaneCwd(coreLookup: coreLookup)
        let effectiveCwd = snapshot == nil ? focusedCwd : nil

        let tabID = TabID()
        let (paneID, pane, core) = createAndStartPane(
            sessionID: sessionID,
            workingDirectory: effectiveCwd,
            snapshot: snapshot,
            profileID: profileID,
            variables: variables
        )
        let paneTree = PaneNode.leaf(pane)

        let tab = ServerTab(
            id: tabID,
            title: "Tab",
            paneTree: paneTree,
            terminalCores: [paneID: core]
        )

        sessions[sessionID]!.tabs.append(tab)
        sessions[sessionID]!.activeTabIndex = sessions[sessionID]!.tabs.count - 1
        saveSession(id: sessionID)
        Log.info("Tab created: \(tabID) in session \(sessionID)", category: .session)
        return tabID
    }

    /// Create a new tab seeded with N panes arranged as a canonical grid.
    /// Each spec is spawned in order, then `LayoutEngine.canonicalGridTree`
    /// builds the final tree in one shot; the single resulting layout is
    /// broadcast so clients only reshape once rather than after every
    /// individual pane creation. Empty spec list is a no-op (returns nil).
    @discardableResult
    public func createTabWithGridPanes(
        sessionID: SessionID,
        specs: [GridPaneSpec]
    ) -> TabID? {
        guard sessions[sessionID] != nil, !specs.isEmpty else { return nil }

        let tabID = TabID()
        var panes: [TerminalPane] = []
        var cores: [PaneID: TerminalCore] = [:]
        panes.reserveCapacity(specs.count)
        for spec in specs {
            let (paneID, pane, core) = createAndStartPane(
                sessionID: sessionID,
                snapshot: spec.snapshot,
                profileID: spec.profileID,
                variables: spec.variables
            )
            panes.append(pane)
            cores[paneID] = core
        }

        let paneTree = LayoutEngine.canonicalGridTree(panes: panes)
        let tab = ServerTab(
            id: tabID,
            title: "Tab",
            paneTree: paneTree,
            terminalCores: cores
        )
        sessions[sessionID]!.tabs.append(tab)
        sessions[sessionID]!.activeTabIndex = sessions[sessionID]!.tabs.count - 1
        saveSession(id: sessionID)
        Log.info(
            "Tab created with \(panes.count) grid panes: \(tabID) in session \(sessionID)",
            category: .session
        )
        return tabID
    }

    public func closeTab(sessionID: SessionID, tabID: TabID) {
        guard var session = sessions[sessionID] else { return }
        guard let tabIndex = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }

        teardownAllPanes(in: session.tabs[tabIndex])

        session.tabs.remove(at: tabIndex)
        Log.info("Tab closed: \(tabID) in session \(sessionID)", category: .session)

        if session.tabs.isEmpty {
            cancelPendingSave(id: sessionID)
            sessions.removeValue(forKey: sessionID)
            sessionStore?.delete(sessionID: sessionID)
            Log.info("Session removed (last tab closed): \(sessionID)", category: .session)
            return
        }

        session.activeTabIndex = min(session.activeTabIndex, session.tabs.count - 1)
        sessions[sessionID] = session
        saveSession(id: sessionID)
    }

    public func selectTab(sessionID: SessionID, tabIndex: Int) {
        guard var session = sessions[sessionID] else { return }
        let clamped = max(0, min(tabIndex, session.tabs.count - 1))
        guard clamped != session.activeTabIndex else { return }
        session.activeTabIndex = clamped
        sessions[sessionID] = session
        saveSession(id: sessionID)
    }

    public func focusPane(sessionID: SessionID, paneID: PaneID) {
        guard var session = sessions[sessionID] else { return }
        guard let tabIndex = session.tabIndex(for: paneID) else { return }
        session.tabs[tabIndex].focusedPaneID = paneID
        sessions[sessionID] = session
        saveSession(id: sessionID)
    }

    /// Forward a focus in/out transition to the PTY backing `paneID`. The
    /// underlying `TerminalCore` only writes `CSI I` / `CSI O` when the
    /// running app has subscribed via DECSET 1004; otherwise this is a
    /// no-op. Unlike `focusPane`, it does not mutate layout state.
    public func reportPaneFocus(paneID: PaneID, focused: Bool) {
        coreLookup[paneID]?.reportFocus(focused)
    }

    // MARK: - Pane Operations

    @discardableResult
    public func splitPane(
        sessionID: SessionID,
        paneID: PaneID,
        direction: SplitDirection,
        profileID: String? = nil,
        snapshot: StartupSnapshot? = nil,
        variables: [String: String] = [:]
    ) -> PaneID? {
        guard var session = sessions[sessionID] else { return nil }
        guard let tabIndex = session.tabIndex(for: paneID) else { return nil }

        // If the caller provided a snapshot, let it drive launch entirely.
        // Otherwise inherit cwd + profileID + variables from the parent
        // pane so templated profiles keep their `${HOST}` substitution.
        let parentPane = session.tabs[tabIndex].paneTree.findPane(id: paneID.uuid)
        let parentProfileID = parentPane?.profileID
        let parentVariables = parentPane?.variables ?? [:]
        let sourceCwd = coreLookup[paneID]?.currentWorkingDirectory
        let effectiveProfileID = profileID ?? parentProfileID
        let effectiveVariables = variables.isEmpty ? parentVariables : variables
        let effectiveCwd = snapshot == nil ? sourceCwd : nil

        let (newPaneID, newPane, core) = createAndStartPane(
            sessionID: sessionID,
            workingDirectory: effectiveCwd,
            snapshot: snapshot,
            profileID: effectiveProfileID,
            variables: effectiveVariables
        )

        guard let newTree = LayoutEngine.splitPane(
            tree: session.tabs[tabIndex].paneTree,
            targetPaneID: paneID.uuid,
            direction: direction,
            newPane: newPane
        ) else { return nil }

        session.tabs[tabIndex].paneTree = newTree
        session.tabs[tabIndex].terminalCores[newPaneID] = core
        sessions[sessionID] = session
        saveSession(id: sessionID)
        return newPaneID
    }

    /// Relocate `sourcePaneID` next to `targetPaneID` within the same tab
    /// (plan §P4.3). Both panes must live in the same tab; mismatched tabs
    /// or missing panes are treated as no-op. Returns `true` on success so
    /// the caller can broadcast a `layoutUpdate`.
    @discardableResult
    public func movePane(
        sessionID: SessionID,
        sourcePaneID: PaneID,
        targetPaneID: PaneID,
        side: FocusDirection
    ) -> Bool {
        guard var session = sessions[sessionID] else { return false }
        guard let tabIndex = session.tabIndex(for: sourcePaneID),
              session.tabIndex(for: targetPaneID) == tabIndex else { return false }
        guard let newTree = LayoutEngine.movePane(
            tree: session.tabs[tabIndex].paneTree,
            sourceID: sourcePaneID.uuid,
            targetID: targetPaneID.uuid,
            side: side
        ) else { return false }
        session.tabs[tabIndex].paneTree = newTree
        sessions[sessionID] = session
        saveSession(id: sessionID)
        return true
    }

    /// Rewrite the layout of the tab that owns `paneID` to `kind`,
    /// flattening any prior nesting (plan §P4.5). `paneID` identifies the
    /// target tab — the rewrite itself is applied to the entire tree.
    /// Returns `true` when the tree changed (caller should broadcast
    /// `layoutUpdate`); `false` when the pane cannot be found, the tab
    /// has a single-pane root leaf, or the tab is already a flat
    /// container using `kind`.
    @discardableResult
    public func changeStrategy(
        sessionID: SessionID,
        paneID: PaneID,
        kind: LayoutStrategyKind
    ) -> Bool {
        guard var session = sessions[sessionID] else { return false }
        guard let tabIndex = session.tabIndex(for: paneID) else { return false }
        guard let newTree = LayoutEngine.flattenToStrategy(
            tree: session.tabs[tabIndex].paneTree,
            newKind: kind
        ) else { return false }
        session.tabs[tabIndex].paneTree = newTree
        sessions[sessionID] = session
        saveSession(id: sessionID)
        return true
    }

    public func closePane(sessionID: SessionID, paneID: PaneID) {
        guard var session = sessions[sessionID] else { return }
        guard let tabIndex = session.tabIndex(for: paneID) else { return }

        if let core = session.tabs[tabIndex].terminalCores.removeValue(forKey: paneID) {
            teardownPane(paneID, core: core)
        }

        guard let outcome = LayoutEngine.closePane(
            tree: session.tabs[tabIndex].paneTree,
            paneID: paneID.uuid
        ) else { return }

        switch outcome {
        case .closed(let newTree, _):
            session.tabs[tabIndex].paneTree = newTree
            sessions[sessionID] = session
            saveSession(id: sessionID)
        case .emptiedTree:
            closeTab(sessionID: sessionID, tabID: session.tabs[tabIndex].id)
        }
    }

    /// Re-run the command in an existing tree pane, reusing the pane's
    /// original `StartupSnapshot` and `profileID`. The `PaneID` and its
    /// position in the tree are preserved; only the backing `TerminalCore`
    /// is replaced. Mirrors the local `SessionManager.rerunTreePaneCommand`
    /// path so remote zombie panes can be re-run from the GUI.
    ///
    /// No layoutUpdate is emitted: the client does not rebuild the tree.
    /// The fresh core will push a `screenFull` update as soon as it starts
    /// drawing, which naturally clears any stale output on the client.
    public func rerunPane(sessionID: SessionID, paneID: PaneID) {
        guard var session = sessions[sessionID] else { return }
        guard let tabIndex = session.tabIndex(for: paneID) else { return }
        guard let pane = session.tabs[tabIndex].paneTree.findPane(id: paneID.uuid) else {
            // Floating panes go through `restartFloatingPaneCommand`.
            return
        }

        if let old = session.tabs[tabIndex].terminalCores.removeValue(forKey: paneID) {
            teardownPane(paneID, core: old)
        }

        let (_, _, core) = createAndStartPane(
            sessionID: sessionID,
            paneID: paneID,
            snapshot: pane.startupSnapshot,
            profileID: pane.profileID
        )
        session.tabs[tabIndex].terminalCores[paneID] = core
        sessions[sessionID] = session
        Log.info("Rerun pane: \(paneID) in session \(sessionID)", category: .session)
    }

    /// Update the split ratio at the node that directly contains `paneID`
    /// as a leaf child. `ratio` is the target pane's share in `(0.0, 1.0)`.
    /// Returns true when the pane was located and the tree was updated.
    @discardableResult
    public func setSplitRatio(
        sessionID: SessionID,
        paneID: PaneID,
        ratio: Float
    ) -> Bool {
        guard var session = sessions[sessionID] else { return false }
        guard let tabIndex = session.tabIndex(for: paneID) else { return false }
        guard let newTree = LayoutEngine.resizePane(
            tree: session.tabs[tabIndex].paneTree,
            paneID: paneID.uuid,
            newRatio: CGFloat(ratio)
        ) else { return false }
        session.tabs[tabIndex].paneTree = newTree
        sessions[sessionID] = session
        saveSession(id: sessionID)
        return true
    }

    // MARK: - Terminal I/O

    public func sendInput(paneID: PaneID, data: [UInt8]) {
        coreLookup[paneID]?.write(data)
    }

    /// Write a paste payload to a pane, applying bracketed-paste wrapping
    /// (mode 2004) or `\n` → `\r` conversion based on the pane's current
    /// terminal modes. Remote clients do not know those modes, so the
    /// server performs the wrapping here to mirror the local paste path
    /// in `TerminalController.handlePaste`.
    public func sendPaste(paneID: PaneID, data: [UInt8]) {
        guard let core = coreLookup[paneID] else { return }
        let wrapped = PasteEncoder.wrap(data, bracketed: core.bracketedPasteMode)
        core.write(wrapped)
    }

    /// Forward a mouse event to the terminal core for encoding and PTY delivery.
    public func handleMouseEvent(paneID: PaneID, event: MouseEncoder.Event) {
        coreLookup[paneID]?.handleMouseEvent(event)
    }

    /// Current mouse tracking mode for a pane (rawValue of MouseTrackingMode).
    public func mouseTrackingMode(paneID: PaneID) -> UInt8 {
        coreLookup[paneID]?.mouseTrackingMode.rawValue ?? 0
    }

    public func resizePane(paneID: PaneID, cols: UInt16, rows: UInt16) {
        coreLookup[paneID]?.resize(columns: cols, rows: rows)
    }

    // MARK: - Multi-Client Size Negotiation

    /// Register a client's window size for a pane and recalculate the effective PTY size.
    @discardableResult
    public func registerClientSize(
        clientID: UUID, paneID: PaneID, cols: UInt16, rows: UInt16
    ) -> (cols: UInt16, rows: UInt16)? {
        clientPaneSizes[paneID, default: [:]][clientID] = (cols, rows)
        Log.debug(
            "registerClientSize: client=\(clientID.uuidString.prefix(8)) pane=\(paneID) "
            + "requested=\(cols)x\(rows) totalClients=\(clientPaneSizes[paneID]?.count ?? 0)",
            category: .session
        )
        return applyEffectiveSize(paneID: paneID)
    }

    /// Remove a client's size entries from all panes (called on disconnect).
    public func removeClientFromAllPanes(clientID: UUID) {
        Log.debug(
            "removeClientFromAllPanes: client=\(clientID.uuidString.prefix(8)) "
            + "paneCount=\(clientPaneSizes.count)",
            category: .session
        )
        for paneID in Array(clientPaneSizes.keys) {
            removeClientFromPane(clientID: clientID, paneID: paneID)
        }
    }

    /// Remove a client's size for a specific pane (called on session detach).
    public func removeClientFromPane(clientID: UUID, paneID: PaneID) {
        guard clientPaneSizes[paneID]?.removeValue(forKey: clientID) != nil else { return }
        if clientPaneSizes[paneID]?.isEmpty == true {
            clientPaneSizes.removeValue(forKey: paneID)
        } else {
            applyEffectiveSize(paneID: paneID)
        }
    }

    /// Compute min(cols) × min(rows) across all clients for this pane and resize the PTY.
    @discardableResult
    private func applyEffectiveSize(paneID: PaneID) -> (cols: UInt16, rows: UInt16)? {
        guard let sizes = clientPaneSizes[paneID], !sizes.isEmpty else { return nil }
        let effectiveCols = sizes.values.map(\.cols).min()!
        let effectiveRows = sizes.values.map(\.rows).min()!
        Log.debug(
            "applyEffectiveSize: pane=\(paneID) effective=\(effectiveCols)x\(effectiveRows) "
            + "from \(sizes.count) client(s)",
            category: .session
        )
        coreLookup[paneID]?.resize(columns: effectiveCols, rows: effectiveRows)
        return (effectiveCols, effectiveRows)
    }

    public func scrollViewport(paneID: PaneID, delta: Int32) {
        coreLookup[paneID]?.scrollViewport(delta: delta)
    }

    /// Extract text from a selection range in a pane.
    /// Delegates to TerminalCore which synchronizes internally via ptyQueue.
    public func extractText(paneID: PaneID, selection: Selection) -> String? {
        coreLookup[paneID]?.extractText(from: selection)
    }

    /// Force a full snapshot (e.g., on client attach).
    public func snapshot(paneID: PaneID) -> ScreenSnapshot? {
        coreLookup[paneID]?.forceSnapshot()
    }

    /// Consume a snapshot if the pane is dirty.
    public func consumeSnapshot(paneID: PaneID) -> ScreenSnapshot? {
        coreLookup[paneID]?.consumeSnapshot(allowPartial: true)
    }

    // MARK: - Floating Pane Operations

    @discardableResult
    public func createFloatingPane(
        sessionID: SessionID,
        tabID: TabID,
        profileID: String? = nil,
        snapshot: StartupSnapshot? = nil,
        variables: [String: String] = [:],
        frameHint: FloatFrameHint? = nil
    ) -> PaneID? {
        guard var session = sessions[sessionID] else { return nil }
        guard let tabIndex = session.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }

        // If caller provided a snapshot, let it drive launch. Otherwise
        // inherit cwd + profile + variables from the focused pane of the
        // target tab.
        let focusedCwd = session.tabs[tabIndex].focusedPaneCwd(coreLookup: coreLookup)
        let parentProfileID = session.tabs[tabIndex].focusedPaneProfileID()
        let parentVariables = session.tabs[tabIndex].focusedPaneVariables()
        let effectiveProfileID = profileID ?? parentProfileID
        let effectiveVariables = variables.isEmpty ? parentVariables : variables
        let effectiveCwd = snapshot == nil ? focusedCwd : nil

        let (paneID, pane, core) = createAndStartPane(
            sessionID: sessionID,
            workingDirectory: effectiveCwd,
            snapshot: snapshot,
            profileID: effectiveProfileID,
            variables: effectiveVariables
        )
        let nextZ = (session.tabs[tabIndex].floatingPanes.max(by: { $0.zIndex < $1.zIndex })?.zIndex ?? -1) + 1
        var fp = FloatingPaneInfo(paneID: paneID, zIndex: nextZ)
        if let frameHint {
            fp.frameX = frameHint.x
            fp.frameY = frameHint.y
            fp.frameWidth = min(max(frameHint.width, 0.1), 1.0)
            fp.frameHeight = min(max(frameHint.height, 0.1), 1.0)
        }

        session.tabs[tabIndex].floatingPanes.append(fp)
        session.tabs[tabIndex].floatingPaneCores[paneID] = core
        session.tabs[tabIndex].floatingPaneProfileIDs[paneID] = pane.profileID
        if !pane.variables.isEmpty {
            session.tabs[tabIndex].floatingPaneVariables[paneID] = pane.variables
        }
        if let explicitCloseOnExit = pane.startupSnapshot.closeOnExit {
            session.tabs[tabIndex].floatingPaneCloseOnExit[paneID] = explicitCloseOnExit
        }
        sessions[sessionID] = session
        saveSession(id: sessionID)
        Log.info("Floating pane created: \(paneID) in tab \(tabID)", category: .session)
        return paneID
    }

    public func closeFloatingPane(sessionID: SessionID, paneID: PaneID) {
        guard var session = sessions[sessionID] else { return }
        guard let (tabIndex, _) = session.floatingPaneLocation(for: paneID) else { return }

        if let core = session.tabs[tabIndex].floatingPaneCores.removeValue(forKey: paneID) {
            teardownPane(paneID, core: core)
        }
        session.tabs[tabIndex].floatingPanes.removeAll { $0.paneID == paneID }
        session.tabs[tabIndex].floatingPaneProfileIDs.removeValue(forKey: paneID)
        session.tabs[tabIndex].floatingPaneVariables.removeValue(forKey: paneID)
        session.tabs[tabIndex].floatingPaneCloseOnExit.removeValue(forKey: paneID)
        sessions[sessionID] = session
        saveSession(id: sessionID)
        Log.info("Floating pane closed: \(paneID) in session \(sessionID)", category: .session)
    }

    public func updateFloatingPaneFrame(
        sessionID: SessionID, paneID: PaneID,
        x: Float, y: Float, width: Float, height: Float
    ) {
        modifyFloatingPane(sessionID: sessionID, paneID: paneID) { fp in
            fp.frameX = x
            fp.frameY = y
            fp.frameWidth = width
            fp.frameHeight = height
        }
    }

    public func bringFloatingPaneToFront(sessionID: SessionID, paneID: PaneID) {
        guard var session = sessions[sessionID] else { return }
        guard let (tabIndex, fpIndex) = session.floatingPaneLocation(for: paneID) else { return }

        let maxZ = session.tabs[tabIndex].floatingPanes.max(by: { $0.zIndex < $1.zIndex })?.zIndex ?? 0
        guard session.tabs[tabIndex].floatingPanes[fpIndex].zIndex < maxZ else { return }
        session.tabs[tabIndex].floatingPanes[fpIndex].zIndex = maxZ + 1
        sessions[sessionID] = session
        saveSession(id: sessionID)
    }

    public func updateFloatingPaneTitle(sessionID: SessionID, paneID: PaneID, title: String) {
        modifyFloatingPane(sessionID: sessionID, paneID: paneID) { fp in
            fp.title = title
        }
    }

    public func toggleFloatingPanePin(sessionID: SessionID, paneID: PaneID) {
        modifyFloatingPane(sessionID: sessionID, paneID: paneID) { fp in
            fp.isPinned.toggle()
        }
    }

    // MARK: - Pane ID Queries

    /// Test-only accessor returning the backing `TerminalCore` for a pane
    /// (tree or floating). Used to assert that operations like `rerunPane`
    /// replace the core with a fresh instance.
    internal func terminalCoreForTests(paneID: PaneID) -> TerminalCore? {
        coreLookup[paneID]
    }

    /// Test-only accessor returning the `TerminalPane` for a tree pane by
    /// scanning every session's tab trees. Returns nil for floating panes
    /// (which don't persist a full `TerminalPane`) or unknown IDs.
    internal func treePaneForTests(paneID: PaneID) -> TerminalPane? {
        for session in sessions.values {
            for tab in session.tabs {
                if let pane = tab.paneTree.findPane(id: paneID.uuid) {
                    return pane
                }
            }
        }
        return nil
    }

    public func allPaneIDs(sessionID: SessionID) -> [PaneID] {
        guard let session = sessions[sessionID] else { return [] }
        return session.tabs.flatMap {
            Array($0.terminalCores.keys) + Array($0.floatingPaneCores.keys)
        }
    }

    // MARK: - Private

    private func teardownPane(_ paneID: PaneID, core: TerminalCore) {
        core.stop()
        coreLookup.removeValue(forKey: paneID)
        clientPaneSizes.removeValue(forKey: paneID)
        // Stop any overlay cores on the stack.
        overlayStacks.removeValue(forKey: paneID)?.forEach { $0.stop() }
    }

    private func teardownAllPanes(in tab: ServerTab) {
        for (paneID, core) in tab.terminalCores { teardownPane(paneID, core: core) }
        for (paneID, core) in tab.floatingPaneCores { teardownPane(paneID, core: core) }
    }

    /// Mutate a floating pane in-place, handling session/tab/index lookup.
    private func modifyFloatingPane(
        sessionID: SessionID, paneID: PaneID,
        _ body: (inout FloatingPaneInfo) -> Void
    ) {
        guard var session = sessions[sessionID] else { return }
        guard let (tabIndex, fpIndex) = session.floatingPaneLocation(for: paneID) else { return }
        body(&session.tabs[tabIndex].floatingPanes[fpIndex])
        sessions[sessionID] = session
        saveSession(id: sessionID)
    }

    // MARK: - Persistence

    private func saveSession(id: SessionID) {
        guard sessions[id] != nil, sessionStore != nil else { return }
        saveScheduler.schedule(id)
    }

    private func cancelPendingSave(id: SessionID) {
        saveScheduler.cancel(id)
    }

    internal func flushPendingSaves() {
        saveScheduler.flushAll()
    }

    private func flushSession(id: SessionID) {
        guard let session = sessions[id], let sessionStore else { return }
        var paneContexts: [PaneID: PersistedPaneContext] = [:]
        for tab in session.tabs {
            for (paneID, core) in tab.terminalCores.merging(tab.floatingPaneCores, uniquingKeysWith: { current, _ in current }) {
                paneContexts[paneID] = PersistedPaneContext(
                    cwd: core.currentWorkingDirectory ?? ""
                )
            }
        }
        let persisted = PersistedSession(
            sessionInfo: session.toSessionInfo(coreLookup: coreLookup),
            paneContexts: paneContexts
        )
        sessionStore.save(persisted)
    }

    private func restoreSession(from persisted: PersistedSession) {
        let info = persisted.sessionInfo
        let contexts = persisted.paneContexts

        var tabs: [ServerTab] = []
        for tabInfo in info.tabs {
            let (paneTree, treeCores) = restorePaneTree(
                layout: tabInfo.layout,
                contexts: contexts,
                sessionID: info.id
            )
            let floatingPanes = tabInfo.floatingPanes
            var floatingCores: [PaneID: TerminalCore] = [:]
            var floatingProfileIDs: [PaneID: String] = [:]
            var floatingCloseOnExit: [PaneID: Bool] = [:]
            for fp in floatingPanes {
                let (_, pane, core) = createAndStartPane(
                    sessionID: info.id,
                    workingDirectory: contexts[fp.paneID]?.cwd,
                    paneID: fp.paneID
                )
                floatingCores[fp.paneID] = core
                floatingProfileIDs[fp.paneID] = pane.profileID
                if let explicitCloseOnExit = pane.startupSnapshot.closeOnExit {
                    floatingCloseOnExit[fp.paneID] = explicitCloseOnExit
                }
            }
            let tab = ServerTab(
                id: tabInfo.id,
                title: tabInfo.title,
                paneTree: paneTree,
                terminalCores: treeCores,
                floatingPanes: floatingPanes,
                floatingPaneCores: floatingCores,
                floatingPaneProfileIDs: floatingProfileIDs,
                floatingPaneCloseOnExit: floatingCloseOnExit,
                focusedPaneID: tabInfo.focusedPaneID
            )
            tabs.append(tab)
        }

        let session = ServerSession(
            id: info.id,
            name: info.name,
            tabs: tabs,
            activeTabIndex: info.activeTabIndex
        )
        sessions[info.id] = session
        Log.info("Session restored: \(info.name) (\(info.id))", category: .session)
    }

    private func restorePaneTree(
        layout: LayoutTree,
        contexts: [PaneID: PersistedPaneContext],
        sessionID: SessionID
    ) -> (PaneNode, [PaneID: TerminalCore]) {
        switch layout {
        case .leaf(let paneID):
            let (_, pane, core) = createAndStartPane(
                sessionID: sessionID,
                workingDirectory: contexts[paneID]?.cwd,
                paneID: paneID
            )
            return (.leaf(pane), [paneID: core])
        case .container(let strategy, let children, let weights):
            var nodes: [PaneNode] = []
            nodes.reserveCapacity(children.count)
            var combinedCores: [PaneID: TerminalCore] = [:]
            for child in children {
                let (childNode, childCores) = restorePaneTree(
                    layout: child,
                    contexts: contexts,
                    sessionID: sessionID
                )
                nodes.append(childNode)
                combinedCores.merge(childCores) { _, new in new }
            }
            let node = PaneNode.container(Container(
                strategy: strategy,
                children: nodes,
                weights: weights.map { CGFloat($0) }
            ))
            return (node, combinedCores)
        }
    }

    // MARK: - Command Execution

    /// Run a command in-place: push the current TerminalCore onto the overlay stack,
    /// create a temporary core for the command, and restore on exit.
    public func runInPlace(sessionID: SessionID, paneID: PaneID, command: String, arguments: [String]) {
        guard let originalCore = coreLookup[paneID] else {
            Log.warning("runInPlace: no core for pane \(paneID)", category: .session)
            return
        }

        let cwd = resolvedWorkingDirectory(originalCore.currentWorkingDirectory)
        let cols = UInt16(clamping: originalCore.columns)
        let rows = UInt16(clamping: originalCore.rows)

        let wrapped = LoginShell.wrap(command: command, arguments: arguments)

        let overlayCore = TerminalCore(
            columns: Int(cols),
            rows: Int(rows),
            maxScrollback: config.maxScrollback
        )

        overlayCore.onScreenDirty = { [weak self] in
            self?.onScreenDirty?(sessionID, paneID)
        }
        overlayCore.onTitleChanged = { [weak self] title in
            self?.onTitleChanged?(sessionID, paneID, title)
        }
        overlayCore.onBell = { [weak self] in
            self?.onBell?(sessionID, paneID)
        }
        overlayCore.onClipboardSet = { [weak self] text in
            self?.onClipboardSet?(text)
        }
        overlayCore.onProcessExited = { [weak self] _ in
            self?.restoreFromInPlace(sessionID: sessionID, paneID: paneID)
        }

        // Push original onto overlay stack and swap the active core.
        overlayStacks[paneID, default: []].append(originalCore)
        coreLookup[paneID] = overlayCore

        do {
            try overlayCore.start(
                command: wrapped.command, arguments: wrapped.arguments,
                columns: cols, rows: rows,
                workingDirectory: cwd
            )
        } catch {
            Log.error("runInPlace: failed to start overlay for pane \(paneID): \(error)", category: .session)
            // Restore immediately on failure.
            overlayStacks[paneID]?.removeLast()
            if overlayStacks[paneID]?.isEmpty == true { overlayStacks.removeValue(forKey: paneID) }
            coreLookup[paneID] = originalCore
        }
    }

    /// Restore the original TerminalCore after an in-place overlay exits.
    private func restoreFromInPlace(sessionID: SessionID, paneID: PaneID) {
        guard var stack = overlayStacks[paneID], !stack.isEmpty else { return }
        // Stop the overlay core (it's currently in coreLookup).
        coreLookup[paneID]?.stop()

        let restored = stack.removeLast()
        if stack.isEmpty {
            overlayStacks.removeValue(forKey: paneID)
        } else {
            overlayStacks[paneID] = stack
        }

        coreLookup[paneID] = restored
        restored.forceFullRedraw()
        Log.info("runInPlace: overlay exited, restored pane \(paneID)", category: .session)
    }

    /// Run a command in the background on the daemon (fire-and-forget, output discarded).
    public func runRemoteCommand(paneID: PaneID, command: String, arguments: [String]) {
        let cwd = resolvedWorkingDirectory(coreLookup[paneID]?.currentWorkingDirectory)

        let wrapped = LoginShell.wrap(command: command, arguments: arguments)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wrapped.command)
        process.arguments = wrapped.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            Log.info("runRemoteCommand: started '\(command)' in \(cwd)", category: .session)
        } catch {
            Log.error("runRemoteCommand: failed to start '\(command)': \(error)", category: .session)
        }
    }

    /// Restart a command in an existing (exited) floating pane.
    /// Replaces the old TerminalCore with a new one running the same command.
    public func restartFloatingPaneCommand(
        sessionID: SessionID, paneID: PaneID,
        command: String, arguments: [String]
    ) -> Bool {
        guard var session = sessions[sessionID] else { return false }
        guard let (tabIndex, _) = session.floatingPaneLocation(for: paneID) else { return false }

        // Stop and remove the old core.
        if let oldCore = session.tabs[tabIndex].floatingPaneCores[paneID] {
            oldCore.stop()
            coreLookup.removeValue(forKey: paneID)
        }

        // Use the tree pane's shell cwd — it's always running and has a valid cwd.
        let treePaneID = PaneID(session.tabs[tabIndex].paneTree.firstPane.id)
        let cwd = resolvedWorkingDirectory(coreLookup[treePaneID]?.currentWorkingDirectory)

        // Reuse the client-reported size so the new core matches the existing MetalView.
        let effectiveSize = clientPaneSizes[paneID]?.values.first
        let cols = effectiveSize?.cols ?? config.defaultColumns
        let rows = effectiveSize?.rows ?? config.defaultRows

        let core = TerminalCore(
            columns: Int(cols),
            rows: Int(rows),
            maxScrollback: config.maxScrollback
        )

        wireStandardCallbacks(core, sessionID: sessionID, paneID: paneID)
        coreLookup[paneID] = core

        let wrapped = LoginShell.wrap(command: command, arguments: arguments)
        do {
            try core.start(
                command: wrapped.command, arguments: wrapped.arguments,
                columns: cols, rows: rows,
                workingDirectory: cwd
            )
        } catch {
            Log.error("restartFloatingPaneCommand: failed to start '\(command)': \(error)", category: .session)
            coreLookup.removeValue(forKey: paneID)
            return false
        }

        session.tabs[tabIndex].floatingPaneCores[paneID] = core
        sessions[sessionID] = session
        Log.info("Floating pane command restarted: \(paneID), cmd=\(command), cwd=\(cwd)", category: .session)
        return true
    }

    /// Wire standard callbacks on a TerminalCore for screen updates, title, bell, clipboard, and process exit.
    private func wireStandardCallbacks(
        _ core: TerminalCore,
        sessionID: SessionID,
        paneID: PaneID
    ) {
        core.onScreenDirty = { [weak self] in
            self?.onScreenDirty?(sessionID, paneID)
        }
        core.onTitleChanged = { [weak self] title in
            self?.updateFloatingPaneTitle(sessionID: sessionID, paneID: paneID, title: title)
            self?.onTitleChanged?(sessionID, paneID, title)
            self?.checkCwdChanged(core: core, sessionID: sessionID, paneID: paneID)
        }
        core.onBell = { [weak self] in
            self?.onBell?(sessionID, paneID)
        }
        core.onClipboardSet = { [weak self] text in
            self?.onClipboardSet?(text)
        }
        core.onProcessExited = { [weak self] exitCode in
            self?.onPaneExited?(sessionID, paneID, exitCode)
        }
    }

    /// Check if a pane's cwd has changed and fire onCwdChanged if so.
    private func checkCwdChanged(core: TerminalCore, sessionID: SessionID, paneID: PaneID) {
        guard let cwd = core.currentWorkingDirectory else { return }
        if lastKnownCwd[paneID] != cwd {
            lastKnownCwd[paneID] = cwd
            onCwdChanged?(sessionID, paneID, cwd)
        }
    }

    private func resolvedWorkingDirectory(_ preferred: String? = nil) -> String {
        WorkingDirectory.resolved(
            preferred: preferred,
            defaultCwd: config.defaultWorkingDirectory
        )
    }

    /// Create a new pane with its TerminalCore and start the PTY.
    /// - Parameters:
    ///   - workingDirectory: If provided, the new pane starts in this directory;
    ///     otherwise falls back to `snapshot?.cwd` / `config.defaultWorkingDirectory` /
    ///     `$HOME` / `/`.
    ///   - snapshot: Optional profile-resolved startup fields. When non-nil,
    ///     the PTY is launched with the snapshot's command/args/env; when
    ///     nil, behavior is identical to pre-profile code paths. Phase 2
    ///     leaves this parameter unused by internal callers — it is wired
    ///     end-to-end starting in Phase 5 (JSON-RPC surface).
    ///   - profileID: Stamps the new pane's `profileID`. Phase 4 plumbs
    ///     this through split/new-tab/new-float paths so the string
    ///     propagates locally; Phase 5 uses it together with `snapshot`
    ///     to actually launch the profile's command.
    private func createAndStartPane(
        sessionID: SessionID,
        workingDirectory: String? = nil,
        paneID: PaneID? = nil,
        snapshot: StartupSnapshot? = nil,
        profileID: String? = nil,
        variables: [String: String] = [:]
    ) -> (PaneID, TerminalPane, TerminalCore) {
        let effectiveProfileID = profileID ?? TerminalPane.defaultProfileID
        let resolvedSnapshot = snapshot ?? StartupSnapshot(cwd: workingDirectory)

        let pane: TerminalPane
        let actualPaneID: PaneID
        if let paneID {
            actualPaneID = paneID
            pane = TerminalPane(
                id: paneID.uuid,
                profileID: effectiveProfileID,
                startupSnapshot: resolvedSnapshot,
                variables: variables,
                initialWorkingDirectory: workingDirectory
            )
        } else {
            pane = TerminalPane(
                profileID: effectiveProfileID,
                startupSnapshot: resolvedSnapshot,
                variables: variables,
                initialWorkingDirectory: workingDirectory
            )
            actualPaneID = PaneID(pane.id)
        }

        let core = TerminalCore(
            columns: Int(config.defaultColumns),
            rows: Int(config.defaultRows),
            maxScrollback: config.maxScrollback
        )
        core.setDebugPaneTag(String(actualPaneID.uuid.uuidString.prefix(8)))

        wireStandardCallbacks(core, sessionID: sessionID, paneID: actualPaneID)
        coreLookup[actualPaneID] = core

        let effectiveCwd = resolvedWorkingDirectory(workingDirectory ?? resolvedSnapshot.cwd)
        let extraEnv = resolvedSnapshot.envTuples

        do {
            if let command = resolvedSnapshot.command, !command.isEmpty {
                try core.start(
                    command: command,
                    arguments: resolvedSnapshot.args,
                    columns: config.defaultColumns,
                    rows: config.defaultRows,
                    workingDirectory: effectiveCwd,
                    extraEnv: extraEnv
                )
            } else {
                try core.start(
                    columns: config.defaultColumns,
                    rows: config.defaultRows,
                    workingDirectory: effectiveCwd,
                    extraEnv: extraEnv
                )
            }
        } catch {
            Log.error("Failed to start PTY for pane \(actualPaneID): \(error)", category: .session)
        }

        return (actualPaneID, pane, core)
    }
}
