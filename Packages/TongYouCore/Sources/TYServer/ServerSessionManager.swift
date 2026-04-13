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
}

/// Server-side session containing tabs and panes.
struct ServerSession {
    let id: SessionID
    var name: String
    var tabs: [ServerTab]
    var activeTabIndex: Int

    func toSessionInfo() -> SessionInfo {
        let tabInfos = tabs.map { tab in
            TabInfo(
                id: tab.id,
                title: tab.title,
                layout: LayoutTree(from: tab.paneTree),
                floatingPanes: tab.floatingPanes
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

    /// Flat lookup from PaneID to its TerminalCore for O(1) access on the hot path.
    private var coreLookup: [PaneID: TerminalCore] = [:]

    var onScreenDirty: ((SessionID, PaneID) -> Void)?
    var onTitleChanged: ((SessionID, PaneID, String) -> Void)?
    var onBell: ((SessionID, PaneID) -> Void)?
    var onClipboardSet: ((String) -> Void)?
    var onPaneExited: ((SessionID, PaneID, Int32) -> Void)?

    public init(config: ServerConfig) {
        self.config = config
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
        Log.info("Session created: \(sessionName) (\(sessionID))", category: .session)
        return session.toSessionInfo()
    }

    public func closeSession(id: SessionID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        for tab in session.tabs {
            for (paneID, core) in tab.terminalCores {
                core.stop()
                coreLookup.removeValue(forKey: paneID)
            }
            for (paneID, core) in tab.floatingPaneCores {
                core.stop()
                coreLookup.removeValue(forKey: paneID)
            }
        }
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
        guard sessions[sessionID] != nil else { return nil }

        let tabID = TabID()
        let (paneID, pane, core) = createAndStartPane(sessionID: sessionID)
        let paneTree = PaneNode.leaf(pane)

        let tab = ServerTab(
            id: tabID,
            title: "Tab",
            paneTree: paneTree,
            terminalCores: [paneID: core]
        )

        sessions[sessionID]!.tabs.append(tab)
        sessions[sessionID]!.activeTabIndex = sessions[sessionID]!.tabs.count - 1
        Log.info("Tab created: \(tabID) in session \(sessionID)", category: .session)
        return tabID
    }

    public func closeTab(sessionID: SessionID, tabID: TabID) {
        guard var session = sessions[sessionID] else { return }
        guard let tabIndex = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }

        let tab = session.tabs[tabIndex]
        for (paneID, core) in tab.terminalCores {
            core.stop()
            coreLookup.removeValue(forKey: paneID)
        }
        for (paneID, core) in tab.floatingPaneCores {
            core.stop()
            coreLookup.removeValue(forKey: paneID)
        }

        session.tabs.remove(at: tabIndex)
        Log.info("Tab closed: \(tabID) in session \(sessionID)", category: .session)

        if session.tabs.isEmpty {
            sessions.removeValue(forKey: sessionID)
            Log.info("Session removed (last tab closed): \(sessionID)", category: .session)
            return
        }

        session.activeTabIndex = min(session.activeTabIndex, session.tabs.count - 1)
        sessions[sessionID] = session
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

        let (newPaneID, newPane, core) = createAndStartPane(sessionID: sessionID)

        guard let newTree = session.tabs[tabIndex].paneTree.split(
            paneID: paneID.uuid,
            direction: direction,
            newPane: newPane
        ) else { return nil }

        session.tabs[tabIndex].paneTree = newTree
        session.tabs[tabIndex].terminalCores[newPaneID] = core
        sessions[sessionID] = session
        return newPaneID
    }

    public func closePane(sessionID: SessionID, paneID: PaneID) {
        guard var session = sessions[sessionID] else { return }
        guard let tabIndex = session.tabIndex(for: paneID) else { return }

        if let core = session.tabs[tabIndex].terminalCores.removeValue(forKey: paneID) {
            core.stop()
            coreLookup.removeValue(forKey: paneID)
        }

        if let newTree = session.tabs[tabIndex].paneTree.removePane(id: paneID.uuid) {
            session.tabs[tabIndex].paneTree = newTree
            sessions[sessionID] = session
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

    public func scrollViewport(paneID: PaneID, delta: Int32) {
        coreLookup[paneID]?.scrollViewport(delta: delta)
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

        let (paneID, _, core) = createAndStartPane(sessionID: sessionID)
        let nextZ = (session.tabs[tabIndex].floatingPanes.max(by: { $0.zIndex < $1.zIndex })?.zIndex ?? -1) + 1
        let fp = FloatingPaneInfo(paneID: paneID, zIndex: nextZ)

        session.tabs[tabIndex].floatingPanes.append(fp)
        session.tabs[tabIndex].floatingPaneCores[paneID] = core
        sessions[sessionID] = session
        Log.info("Floating pane created: \(paneID) in tab \(tabID)", category: .session)
        return paneID
    }

    public func closeFloatingPane(sessionID: SessionID, paneID: PaneID) {
        guard var session = sessions[sessionID] else { return }
        guard let (tabIndex, _) = session.floatingPaneLocation(for: paneID) else { return }

        if let core = session.tabs[tabIndex].floatingPaneCores.removeValue(forKey: paneID) {
            core.stop()
            coreLookup.removeValue(forKey: paneID)
        }
        session.tabs[tabIndex].floatingPanes.removeAll { $0.paneID == paneID }
        sessions[sessionID] = session
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

    /// Mutate a floating pane in-place, handling session/tab/index lookup.
    private func modifyFloatingPane(
        sessionID: SessionID, paneID: PaneID,
        _ body: (inout FloatingPaneInfo) -> Void
    ) {
        guard var session = sessions[sessionID] else { return }
        guard let (tabIndex, fpIndex) = session.floatingPaneLocation(for: paneID) else { return }
        body(&session.tabs[tabIndex].floatingPanes[fpIndex])
        sessions[sessionID] = session
    }

    /// Create a new pane with its TerminalCore and start the PTY.
    private func createAndStartPane(sessionID: SessionID) -> (PaneID, TerminalPane, TerminalCore) {
        let pane = TerminalPane()
        let paneID = PaneID(pane.id)

        let core = TerminalCore(
            columns: Int(config.defaultColumns),
            rows: Int(config.defaultRows),
            maxScrollback: config.maxScrollback
        )

        core.onScreenDirty = { [weak self] in
            self?.onScreenDirty?(sessionID, paneID)
        }
        core.onTitleChanged = { [weak self] title in
            self?.updateFloatingPaneTitle(sessionID: sessionID, paneID: paneID, title: title)
            self?.onTitleChanged?(sessionID, paneID, title)
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

        coreLookup[paneID] = core

        do {
            try core.start(
                columns: config.defaultColumns,
                rows: config.defaultRows,
                workingDirectory: config.defaultWorkingDirectory
                    ?? ProcessInfo.processInfo.environment["HOME"]
                    ?? "/"
            )
        } catch {
            Log.error("Failed to start PTY for pane \(paneID): \(error)", category: .session)
        }

        return (paneID, pane, core)
    }
}
