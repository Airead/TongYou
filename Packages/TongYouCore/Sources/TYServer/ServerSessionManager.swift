import Foundation
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

    func toSessionInfo() -> SessionInfo {
        let tabInfos = tabs.map { tab in
            TabInfo(
                id: tab.id,
                title: tab.title,
                layout: LayoutTree(from: tab.paneTree),
                floatingPanes: tab.floatingPanes,
                focusedPaneID: tab.focusedPaneID
            )
        }
        return SessionInfo(
            id: id,
            name: name,
            tabs: tabInfos,
            activeTabIndex: activeTabIndex
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

/// Convert PaneNode (TYTerminal) to LayoutTree (TYProtocol).
extension LayoutTree {
    init(from node: PaneNode) {
        switch node {
        case .leaf(let pane):
            self = .leaf(PaneID(pane.id))
        case .split(let direction, let ratio, let first, let second):
            self = .split(
                direction: direction,
                ratio: Float(ratio),
                first: LayoutTree(from: first),
                second: LayoutTree(from: second)
            )
        }
    }
}

/// Manages all server-side sessions, tabs, and panes.
///
/// Each pane owns a `TerminalCore` instance that runs its PTY process.
public final class ServerSessionManager {

    private var sessions: [SessionID: ServerSession] = [:]
    private let config: ServerConfig
    private let sessionStore: SessionStore?

    /// Flat lookup from PaneID to its TerminalCore for O(1) access on the hot path.
    private var coreLookup: [PaneID: TerminalCore] = [:]

    /// Per-pane map of client window sizes for multi-client size negotiation.
    /// Effective PTY size = min(cols) × min(rows) across all clients (tmux-style).
    private var clientPaneSizes: [PaneID: [UUID: (cols: UInt16, rows: UInt16)]] = [:]

    /// Debounced save work items per session to avoid synchronous disk I/O on every mutation.
    private var pendingSaves: [SessionID: DispatchWorkItem] = [:]
    private let pendingSavesLock = NSLock()

    var onScreenDirty: ((SessionID, PaneID) -> Void)?
    var onTitleChanged: ((SessionID, PaneID, String) -> Void)?
    var onBell: ((SessionID, PaneID) -> Void)?
    var onClipboardSet: ((String) -> Void)?
    var onPaneExited: ((SessionID, PaneID, Int32) -> Void)?

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

    // MARK: - Session Operations

    public func listSessions() -> [SessionInfo] {
        sessions.values.map { $0.toSessionInfo() }
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
        return session.toSessionInfo()
    }

    public func renameSession(id: SessionID, name: String) {
        guard sessions[id] != nil else { return }
        sessions[id]?.name = name
        saveSession(id: id)
        Log.info("Session renamed: \(name) (\(id))", category: .session)
    }

    public func closeSession(id: SessionID) {
        cancelPendingSave(id: id)
        guard let session = sessions.removeValue(forKey: id) else { return }
        for tab in session.tabs { teardownAllPanes(in: tab) }
        sessionStore?.delete(sessionID: id)
        Log.info("Session closed: \(session.name) (\(id))", category: .session)
    }

    public func sessionInfo(for id: SessionID) -> SessionInfo? {
        sessions[id]?.toSessionInfo()
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

    // MARK: - Terminal I/O

    public func sendInput(paneID: PaneID, data: [UInt8]) {
        coreLookup[paneID]?.write(data)
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
        coreLookup[paneID]?.consumeSnapshot()
    }

    // MARK: - Floating Pane Operations

    @discardableResult
    public func createFloatingPane(sessionID: SessionID, tabID: TabID) -> PaneID? {
        guard var session = sessions[sessionID] else { return nil }
        guard let tabIndex = session.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }

        // Inherit cwd from the focused pane of the target tab.
        let focusedCwd = session.tabs[tabIndex].focusedPaneCwd(coreLookup: coreLookup)

        let (paneID, _, core) = createAndStartPane(sessionID: sessionID, workingDirectory: focusedCwd)
        let nextZ = (session.tabs[tabIndex].floatingPanes.max(by: { $0.zIndex < $1.zIndex })?.zIndex ?? -1) + 1
        let fp = FloatingPaneInfo(paneID: paneID, zIndex: nextZ)

        session.tabs[tabIndex].floatingPanes.append(fp)
        session.tabs[tabIndex].floatingPaneCores[paneID] = core
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
            for (paneID, core) in tab.terminalCores.merging(tab.floatingPaneCores) { current, _ in current } {
                paneContexts[paneID] = PersistedPaneContext(
                    cwd: core.currentWorkingDirectory ?? ""
                )
            }
        }
        let persisted = PersistedSession(
            sessionInfo: session.toSessionInfo(),
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
            for fp in floatingPanes {
                let (_, _, core) = createAndStartPane(
                    sessionID: info.id,
                    workingDirectory: contexts[fp.paneID]?.cwd,
                    paneID: fp.paneID
                )
                floatingCores[fp.paneID] = core
            }
            let tab = ServerTab(
                id: tabInfo.id,
                title: tabInfo.title,
                paneTree: paneTree,
                terminalCores: treeCores,
                floatingPanes: floatingPanes,
                floatingPaneCores: floatingCores,
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

    /// Create a new pane with its TerminalCore and start the PTY.
    /// - Parameter workingDirectory: If provided, the new pane starts in this directory;
    ///   otherwise falls back to `config.defaultWorkingDirectory` / `$HOME` / `/`.
    private func createAndStartPane(
        sessionID: SessionID,
        workingDirectory: String? = nil,
        paneID: PaneID? = nil
    ) -> (PaneID, TerminalPane, TerminalCore) {
        let pane: TerminalPane
        let actualPaneID: PaneID
        if let paneID {
            actualPaneID = paneID
            pane = TerminalPane(id: paneID.uuid, initialWorkingDirectory: workingDirectory)
        } else {
            pane = TerminalPane(initialWorkingDirectory: workingDirectory)
            actualPaneID = PaneID(pane.id)
        }

        let core = TerminalCore(
            columns: Int(config.defaultColumns),
            rows: Int(config.defaultRows),
            maxScrollback: config.maxScrollback
        )

        core.onScreenDirty = { [weak self] in
            self?.onScreenDirty?(sessionID, actualPaneID)
        }
        core.onTitleChanged = { [weak self] title in
            self?.updateFloatingPaneTitle(sessionID: sessionID, paneID: actualPaneID, title: title)
            self?.onTitleChanged?(sessionID, actualPaneID, title)
        }
        core.onBell = { [weak self] in
            self?.onBell?(sessionID, actualPaneID)
        }
        core.onClipboardSet = { [weak self] text in
            self?.onClipboardSet?(text)
        }
        core.onProcessExited = { [weak self] exitCode in
            self?.onPaneExited?(sessionID, actualPaneID, exitCode)
        }

        coreLookup[actualPaneID] = core

        let effectiveCwd = workingDirectory
            ?? config.defaultWorkingDirectory
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? "/"

        do {
            try core.start(
                columns: config.defaultColumns,
                rows: config.defaultRows,
                workingDirectory: effectiveCwd
            )
        } catch {
            Log.error("Failed to start PTY for pane \(actualPaneID): \(error)", category: .session)
        }

        return (actualPaneID, pane, core)
    }
}
