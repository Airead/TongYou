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
    /// The pane that was last focused in this tab by any client.
    var focusedPaneID: PaneID?

    /// Return the cwd of the focused pane (or the first pane as fallback).
    func focusedPaneCwd(coreLookup: [PaneID: TerminalCore]) -> String? {
        let target = focusedPaneID ?? PaneID(paneTree.firstPane.id)
        return coreLookup[target]?.currentWorkingDirectory
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
            // Tree panes carry profileID directly on the TerminalPane.
            var treeProfileIDs: [PaneID: String] = [:]
            for pane in tab.paneTree.allPanes {
                treeProfileIDs[PaneID(pane.id)] = pane.profileID
            }
            for paneUUID in tab.paneTree.allPaneIDs {
                let pid = PaneID(paneUUID)
                let cwd = coreLookup[pid]?.currentWorkingDirectory
                let profileID = treeProfileIDs[pid]
                if cwd != nil || profileID != nil {
                    metadata[pid] = RemotePaneMetadata(cwd: cwd, profileID: profileID)
                }
            }
            for fp in tab.floatingPanes {
                let cwd = coreLookup[fp.paneID]?.currentWorkingDirectory
                let profileID = tab.floatingPaneProfileIDs[fp.paneID]
                if cwd != nil || profileID != nil {
                    metadata[fp.paneID] = RemotePaneMetadata(cwd: cwd, profileID: profileID)
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

    /// Debounced save work items per session to avoid synchronous disk I/O on every mutation.
    private var pendingSaves: [SessionID: DispatchWorkItem] = [:]
    private let pendingSavesLock = NSLock()

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
            let store = SessionStore(directory: directory)
            self.sessionStore = store
            for persisted in store.loadAll() {
                restoreSession(from: persisted)
            }
        } else {
            self.sessionStore = nil
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
        pendingSavesLock.lock()
        for (_, item) in pendingSaves { item.cancel() }
        pendingSaves.removeAll()
        pendingSavesLock.unlock()

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
    public func createTab(sessionID: SessionID) -> TabID? {
        guard let session = sessions[sessionID] else { return nil }

        // Inherit cwd from the focused pane of the active tab.
        let focusedCwd = session.activeTab?.focusedPaneCwd(coreLookup: coreLookup)

        let tabID = TabID()
        let (paneID, pane, core) = createAndStartPane(sessionID: sessionID, workingDirectory: focusedCwd)
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

    // MARK: - Pane Operations

    @discardableResult
    public func splitPane(
        sessionID: SessionID,
        paneID: PaneID,
        direction: SplitDirection
    ) -> PaneID? {
        guard var session = sessions[sessionID] else { return nil }
        guard let tabIndex = session.tabIndex(for: paneID) else { return nil }

        // Inherit cwd from the pane being split.
        let sourceCwd = coreLookup[paneID]?.currentWorkingDirectory

        let (newPaneID, newPane, core) = createAndStartPane(sessionID: sessionID, workingDirectory: sourceCwd)

        guard let newTree = session.tabs[tabIndex].paneTree.split(
            paneID: paneID.uuid,
            direction: direction,
            newPane: newPane
        ) else { return nil }

        session.tabs[tabIndex].paneTree = newTree
        session.tabs[tabIndex].terminalCores[newPaneID] = core
        sessions[sessionID] = session
        saveSession(id: sessionID)
        return newPaneID
    }

    public func closePane(sessionID: SessionID, paneID: PaneID) {
        guard var session = sessions[sessionID] else { return }
        guard let tabIndex = session.tabIndex(for: paneID) else { return }

        if let core = session.tabs[tabIndex].terminalCores.removeValue(forKey: paneID) {
            teardownPane(paneID, core: core)
        }

        if let newTree = session.tabs[tabIndex].paneTree.removePane(id: paneID.uuid) {
            session.tabs[tabIndex].paneTree = newTree
            sessions[sessionID] = session
            saveSession(id: sessionID)
        } else {
            closeTab(sessionID: sessionID, tabID: session.tabs[tabIndex].id)
        }
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
        guard session.tabs[tabIndex].paneTree.contains(paneID: paneID.uuid) else {
            return false
        }
        session.tabs[tabIndex].paneTree = session.tabs[tabIndex].paneTree.updateRatio(
            for: paneID.uuid, newRatio: CGFloat(ratio)
        )
        sessions[sessionID] = session
        saveSession(id: sessionID)
        return true
    }

    // MARK: - Terminal I/O

    public func sendInput(paneID: PaneID, data: [UInt8]) {
        coreLookup[paneID]?.write(data)
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
    public func createFloatingPane(sessionID: SessionID, tabID: TabID) -> PaneID? {
        guard var session = sessions[sessionID] else { return nil }
        guard let tabIndex = session.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }

        // Inherit cwd from the focused pane of the target tab.
        let focusedCwd = session.tabs[tabIndex].focusedPaneCwd(coreLookup: coreLookup)

        let (paneID, pane, core) = createAndStartPane(sessionID: sessionID, workingDirectory: focusedCwd)
        let nextZ = (session.tabs[tabIndex].floatingPanes.max(by: { $0.zIndex < $1.zIndex })?.zIndex ?? -1) + 1
        let fp = FloatingPaneInfo(paneID: paneID, zIndex: nextZ)

        session.tabs[tabIndex].floatingPanes.append(fp)
        session.tabs[tabIndex].floatingPaneCores[paneID] = core
        session.tabs[tabIndex].floatingPaneProfileIDs[paneID] = pane.profileID
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

        pendingSavesLock.lock()
        pendingSaves[id]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushSession(id: id)
        }
        pendingSaves[id] = workItem
        pendingSavesLock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func cancelPendingSave(id: SessionID) {
        pendingSavesLock.lock()
        pendingSaves.removeValue(forKey: id)?.cancel()
        pendingSavesLock.unlock()
    }

    internal func flushPendingSaves() {
        let ids: [SessionID]
        pendingSavesLock.lock()
        ids = Array(pendingSaves.keys)
        pendingSaves.removeAll()
        pendingSavesLock.unlock()
        for id in ids {
            flushSession(id: id)
        }
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
            for fp in floatingPanes {
                let (_, pane, core) = createAndStartPane(
                    sessionID: info.id,
                    workingDirectory: contexts[fp.paneID]?.cwd,
                    paneID: fp.paneID
                )
                floatingCores[fp.paneID] = core
                floatingProfileIDs[fp.paneID] = pane.profileID
            }
            let tab = ServerTab(
                id: tabInfo.id,
                title: tabInfo.title,
                paneTree: paneTree,
                terminalCores: treeCores,
                floatingPanes: floatingPanes,
                floatingPaneCores: floatingCores,
                floatingPaneProfileIDs: floatingProfileIDs,
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
        case .split(let direction, let ratio, let firstLayout, let secondLayout):
            let (firstNode, firstCores) = restorePaneTree(
                layout: firstLayout,
                contexts: contexts,
                sessionID: sessionID
            )
            let (secondNode, secondCores) = restorePaneTree(
                layout: secondLayout,
                contexts: contexts,
                sessionID: sessionID
            )
            let node = PaneNode.split(
                direction: direction,
                ratio: CGFloat(ratio),
                first: firstNode,
                second: secondNode
            )
            return (node, firstCores.merging(secondCores) { _, new in new })
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

        let wrapped = wrapCommandInLoginShell(command, arguments: arguments)

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

        let wrapped = wrapCommandInLoginShell(command, arguments: arguments)

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

    /// Create a floating pane that runs a command instead of a shell.
    /// The pane stays open after the command exits (for the user to read output).
    @discardableResult
    public func createFloatingPaneWithCommand(
        sessionID: SessionID, tabID: TabID,
        command: String, arguments: [String],
        frameX: Float? = nil, frameY: Float? = nil,
        frameWidth: Float? = nil, frameHeight: Float? = nil
    ) -> PaneID? {
        guard var session = sessions[sessionID] else { return nil }
        guard let tabIndex = session.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }

        let cwd = resolvedWorkingDirectory(session.tabs[tabIndex].focusedPaneCwd(coreLookup: coreLookup))

        let paneID = PaneID()
        let core = TerminalCore(
            columns: Int(config.defaultColumns),
            rows: Int(config.defaultRows),
            maxScrollback: config.maxScrollback
        )

        wireStandardCallbacks(core, sessionID: sessionID, paneID: paneID)
        coreLookup[paneID] = core

        let wrapped = wrapCommandInLoginShell(command, arguments: arguments)
        do {
            try core.start(
                command: wrapped.command, arguments: wrapped.arguments,
                columns: config.defaultColumns, rows: config.defaultRows,
                workingDirectory: cwd
            )
        } catch {
            Log.error("createFloatingPaneWithCommand: failed to start '\(command)': \(error)", category: .session)
            coreLookup.removeValue(forKey: paneID)
            return nil
        }

        let nextZ = (session.tabs[tabIndex].floatingPanes.max(by: { $0.zIndex < $1.zIndex })?.zIndex ?? -1) + 1
        var fp = FloatingPaneInfo(paneID: paneID, zIndex: nextZ)
        if let x = frameX { fp.frameX = x }
        if let y = frameY { fp.frameY = y }
        if let w = frameWidth { fp.frameWidth = min(max(w, 0.1), 1.0) }
        if let h = frameHeight { fp.frameHeight = min(max(h, 0.1), 1.0) }
        session.tabs[tabIndex].floatingPanes.append(fp)
        session.tabs[tabIndex].floatingPaneCores[paneID] = core
        session.tabs[tabIndex].floatingPaneProfileIDs[paneID] = TerminalPane.defaultProfileID
        sessions[sessionID] = session
        Log.info("Floating pane with command created: \(paneID), cmd=\(command)", category: .session)
        return paneID
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

        let wrapped = wrapCommandInLoginShell(command, arguments: arguments)
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
        preferred
            ?? config.defaultWorkingDirectory
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? "/"
    }

    private func resolvedUserShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/sh"
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func wrapCommandInLoginShell(_ command: String, arguments: [String]) -> (command: String, arguments: [String]) {
        let shell = resolvedUserShell()
        let expanded = (command as NSString).expandingTildeInPath
        let parts = [expanded] + arguments
        let escaped = parts.map(shellEscape).joined(separator: " ")
        return (shell, ["-l", "-c", "exec \(escaped)"])
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
    private func createAndStartPane(
        sessionID: SessionID,
        workingDirectory: String? = nil,
        paneID: PaneID? = nil,
        snapshot: StartupSnapshot? = nil
    ) -> (PaneID, TerminalPane, TerminalCore) {
        let effectiveProfileID = TerminalPane.defaultProfileID
        let resolvedSnapshot = snapshot ?? StartupSnapshot(cwd: workingDirectory)

        let pane: TerminalPane
        let actualPaneID: PaneID
        if let paneID {
            actualPaneID = paneID
            pane = TerminalPane(
                id: paneID.uuid,
                profileID: effectiveProfileID,
                startupSnapshot: resolvedSnapshot,
                initialWorkingDirectory: workingDirectory
            )
        } else {
            pane = TerminalPane(
                profileID: effectiveProfileID,
                startupSnapshot: resolvedSnapshot,
                initialWorkingDirectory: workingDirectory
            )
            actualPaneID = PaneID(pane.id)
        }

        let core = TerminalCore(
            columns: Int(config.defaultColumns),
            rows: Int(config.defaultRows),
            maxScrollback: config.maxScrollback
        )

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
