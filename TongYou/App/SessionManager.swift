import CoreGraphics
import Foundation
import TYClient
import TYProtocol
import TYTerminal

/// Manages terminal sessions, each containing its own set of tabs and panes.
/// Absorbs all logic previously in TabManager, scoped to the active session.
///
/// Supports mixed-mode operation: local sessions (direct PTY) and remote sessions
/// (backed by a tongyou server) can coexist in the same sidebar.
@Observable
final class SessionManager {

    private(set) var sessions: [TerminalSession] = []
    private(set) var activeSessionIndex: Int = 0

    /// Remote session client for server communication. Nil when not connected.
    private(set) var remoteClient: RemoteSessionClient?

    /// Connection manager for auto-connect. Reused across reconnections.
    private var connectionManager: TYDConnectionManager?

    /// Connection status exposed to UI for overlay display.
    /// Also guards against concurrent `ensureConnected` calls.
    private(set) var connectionStatus: DaemonConnectionStatus = .idle

    /// Tracks which remote sessions are currently attached (receiving screen updates).
    private(set) var attachedRemoteSessionIDs: Set<UUID> = []

    /// Sessions that have been attached but haven't received their first layoutUpdate yet.
    /// While pending, the placeholder view is shown instead of rendering empty local panes.
    private(set) var pendingAttachSessionIDs: Set<UUID> = []

    deinit {
        remoteClient?.disconnect()
    }

    /// Controllers for remote panes, keyed by local pane UUID.
    private var remoteControllers: [UUID: ClientTerminalController] = [:]
    /// Bidirectional mapping between server pane UUID and local pane UUID.
    private var serverToLocalPaneID: [UUID: UUID] = [:]
    /// Maps session UUID → ordered list of server TabIDs (parallel to session.tabs).
    private var serverTabIDs: [UUID: [TabID]] = [:]

    /// Generate the next available name with a given prefix (e.g. "LSession 1", "LSession 2").
    private func nextAvailableName(prefix: String) -> String {
        let existingNames = Set(sessions.map(\.name))
        for n in 1... {
            let candidate = "\(prefix) \(n)"
            if !existingNames.contains(candidate) { return candidate }
        }
        fatalError("unreachable")
    }

    /// Ensure a session name is unique among existing sessions.
    /// If `name` conflicts, appends "-X" where X is an incrementally longer prefix
    /// of `sessionID`'s hex string until unique.
    private func uniqueSessionName(_ name: String, for sessionID: UUID, excludingIndex: Int? = nil) -> String {
        let otherNames = sessions.enumerated()
            .filter { $0.offset != excludingIndex }
            .map(\.element.name)
        let nameSet = Set(otherNames)
        if !nameSet.contains(name) { return name }

        let hex = sessionID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        for length in 1...hex.count {
            let suffix = String(hex.prefix(length))
            let candidate = "\(name)-\(suffix)"
            if !nameSet.contains(candidate) { return candidate }
        }
        return name
    }

    /// Find the index of a remote session by its server-side UUID.
    private func sessionIndex(forServerSessionID uuid: UUID) -> Int? {
        sessions.firstIndex(where: { $0.source == .remote(serverSessionID: uuid) })
    }

    /// Reverse lookup: find the server pane UUID for a local pane UUID.
    private func serverPaneUUID(for localID: UUID) -> UUID? {
        serverToLocalPaneID.first(where: { $0.value == localID })?.key
    }

    /// The currently active session, if any.
    var activeSession: TerminalSession? {
        guard sessions.indices.contains(activeSessionIndex) else { return nil }
        return sessions[activeSessionIndex]
    }

    var activeTab: TerminalTab? { activeSession?.activeTab }

    /// Status of the daemon connection lifecycle, exposed to UI for overlay display.
    enum DaemonConnectionStatus: Equatable {
        /// No connection activity.
        case idle
        /// Starting daemon and/or connecting to socket.
        case connecting
        /// Connection failed with an error message.
        case failed(String)
    }

    /// Dismiss the connection status overlay (used when user closes the failed state).
    func dismissConnectionStatus() {
        connectionStatus = .idle
    }

    /// Describes the remote-attach state of a session from the UI's perspective.
    enum RemoteSessionState {
        /// Not a remote session, or session is fully attached with layout received.
        case ready
        /// Remote session is detached — show "Press Enter to attach" placeholder.
        case detached
        /// Attach sent but layoutUpdate not yet received — show "Connecting..." placeholder.
        case pendingAttach
    }

    /// The remote-attach state of the active session.
    var activeSessionRemoteState: RemoteSessionState {
        guard let session = activeSession,
              let serverID = session.source.serverSessionID else { return .ready }
        if pendingAttachSessionIDs.contains(serverID) { return .pendingAttach }
        if !attachedRemoteSessionIDs.contains(serverID) { return .detached }
        return .ready
    }

    /// Whether a session at the given index is a detached remote session.
    func isSessionDetachedRemote(at index: Int) -> Bool {
        guard sessions.indices.contains(index),
              let serverID = sessions[index].source.serverSessionID else { return false }
        return !attachedRemoteSessionIDs.contains(serverID)
    }

    var sessionCount: Int { sessions.count }
    var tabCount: Int { activeSession?.tabCount ?? 0 }
    var tabs: [TerminalTab] { activeSession?.tabs ?? [] }
    var activeTabIndex: Int { activeSession?.activeTabIndex ?? 0 }

    // MARK: - Session Lifecycle

    @discardableResult
    func createSession(name: String? = nil, initialWorkingDirectory: String? = nil) -> UUID {
        let baseName = name ?? nextAvailableName(prefix: "LSession")
        var session = TerminalSession(name: baseName, initialWorkingDirectory: initialWorkingDirectory)
        session.name = uniqueSessionName(baseName, for: session.id)
        sessions.append(session)
        activeSessionIndex = sessions.count - 1
        return session.id
    }

    /// Close a session at the given index.
    /// Returns the list of all pane IDs that need teardown.
    @discardableResult
    func closeSession(at index: Int) -> [UUID] {
        guard sessions.indices.contains(index) else { return [] }
        let session = sessions[index]
        let paneIDs = session.allPaneIDs

        // Clean up remote controllers if this is a remote session.
        if let serverSessionID = session.source.serverSessionID {
            teardownRemotePanes(Set(paneIDs), sessionID: session.id)
            remoteClient?.closeSession(SessionID(serverSessionID))
        }

        sessions.remove(at: index)

        if !sessions.isEmpty {
            if activeSessionIndex >= sessions.count {
                activeSessionIndex = sessions.count - 1
            } else if activeSessionIndex > index {
                activeSessionIndex -= 1
            }
        } else {
            activeSessionIndex = 0
        }

        return paneIDs
    }

    /// Close the active session. Returns pane IDs for teardown.
    @discardableResult
    func closeActiveSession() -> [UUID] {
        closeSession(at: activeSessionIndex)
    }

    // MARK: - Session Switching

    func selectSession(at index: Int) {
        guard !sessions.isEmpty else { return }
        let clamped = max(0, min(index, sessions.count - 1))
        guard clamped != activeSessionIndex else { return }
        activeSessionIndex = clamped
    }

    func selectPreviousSession() {
        guard sessions.count > 1 else { return }
        activeSessionIndex = (activeSessionIndex - 1 + sessions.count) % sessions.count
    }

    func selectNextSession() {
        guard sessions.count > 1 else { return }
        activeSessionIndex = (activeSessionIndex + 1) % sessions.count
    }

    // MARK: - Session Rename

    func renameSession(at index: Int, to name: String) {
        guard sessions.indices.contains(index) else { return }
        sessions[index].name = uniqueSessionName(name, for: sessions[index].id, excludingIndex: index)

        // Sync rename to server for remote sessions.
        if let serverSessionID = sessions[index].source.serverSessionID {
            remoteClient?.renameSession(SessionID(serverSessionID), name: name)
        }
    }

    func renameActiveSession(to name: String) {
        renameSession(at: activeSessionIndex, to: name)
    }

    // MARK: - Tab Lifecycle (scoped to active session)

    /// Create a new tab in the active session.
    /// For remote sessions, sends the request to the server and returns nil —
    /// the tab will be created when the server broadcasts a layoutUpdate.
    @discardableResult
    func createTab(title: String = "shell", initialWorkingDirectory: String? = nil) -> UUID? {
        guard sessions.indices.contains(activeSessionIndex) else {
            return createSession(initialWorkingDirectory: initialWorkingDirectory)
        }
        let session = sessions[activeSessionIndex]

        if let serverSessionID = session.source.serverSessionID {
            remoteClient?.createTab(sessionID: SessionID(serverSessionID))
            return nil
        }

        let tab = TerminalTab(title: title, initialWorkingDirectory: initialWorkingDirectory)
        sessions[activeSessionIndex].tabs.append(tab)
        sessions[activeSessionIndex].activeTabIndex = sessions[activeSessionIndex].tabs.count - 1
        return tab.id
    }

    /// Close a tab. Returns true if the tab was found.
    /// For remote sessions, sends the request to the server — local state
    /// updates when the server broadcasts a layoutUpdate.
    /// When the last tab is closed, the session remains with an empty tab list
    /// — the caller decides whether to close the session.
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard sessions.indices.contains(activeSessionIndex),
              sessions[activeSessionIndex].tabs.indices.contains(index) else { return false }

        let session = sessions[activeSessionIndex]

        if let serverSessionID = session.source.serverSessionID,
           let tabIDs = serverTabIDs[session.id],
           tabIDs.indices.contains(index) {
            remoteClient?.closeTab(sessionID: SessionID(serverSessionID), tabID: tabIDs[index])
            return true
        }

        sessions[activeSessionIndex].tabs.remove(at: index)

        let tabCount = sessions[activeSessionIndex].tabs.count
        if tabCount == 0 {
            sessions[activeSessionIndex].activeTabIndex = 0
        } else if sessions[activeSessionIndex].activeTabIndex >= tabCount {
            sessions[activeSessionIndex].activeTabIndex = tabCount - 1
        } else if sessions[activeSessionIndex].activeTabIndex > index {
            sessions[activeSessionIndex].activeTabIndex -= 1
        }

        return true
    }

    @discardableResult
    func closeActiveTab() -> Bool {
        guard let session = activeSession else { return false }
        return closeTab(at: session.activeTabIndex)
    }

    // MARK: - Tab Switching

    func selectTab(at index: Int) {
        guard sessions.indices.contains(activeSessionIndex),
              !sessions[activeSessionIndex].tabs.isEmpty else { return }
        let clamped = max(0, min(index, sessions[activeSessionIndex].tabs.count - 1))
        guard clamped != sessions[activeSessionIndex].activeTabIndex else { return }
        sessions[activeSessionIndex].activeTabIndex = clamped
    }

    func selectPreviousTab() {
        guard sessions.indices.contains(activeSessionIndex) else { return }
        let count = sessions[activeSessionIndex].tabs.count
        guard count > 1 else { return }
        let current = sessions[activeSessionIndex].activeTabIndex
        sessions[activeSessionIndex].activeTabIndex = (current - 1 + count) % count
    }

    func selectNextTab() {
        guard sessions.indices.contains(activeSessionIndex) else { return }
        let count = sessions[activeSessionIndex].tabs.count
        guard count > 1 else { return }
        let current = sessions[activeSessionIndex].activeTabIndex
        sessions[activeSessionIndex].activeTabIndex = (current + 1) % count
    }

    /// Cmd+9 always goes to the last tab (browser/terminal convention).
    func selectTabByNumber(_ number: Int) {
        guard sessions.indices.contains(activeSessionIndex),
              !sessions[activeSessionIndex].tabs.isEmpty else { return }
        if number == 9 {
            selectTab(at: sessions[activeSessionIndex].tabs.count - 1)
        } else {
            selectTab(at: number - 1)
        }
    }

    // MARK: - Tab Reordering

    func moveTab(from source: Int, to destination: Int) {
        guard sessions.indices.contains(activeSessionIndex) else { return }
        let tabs = sessions[activeSessionIndex].tabs
        guard tabs.indices.contains(source),
              destination >= 0, destination < tabs.count,
              source != destination else { return }

        let tab = sessions[activeSessionIndex].tabs.remove(at: source)
        sessions[activeSessionIndex].tabs.insert(tab, at: destination)

        let active = sessions[activeSessionIndex].activeTabIndex
        if active == source {
            sessions[activeSessionIndex].activeTabIndex = destination
        } else if source < active && destination >= active {
            sessions[activeSessionIndex].activeTabIndex = active - 1
        } else if source > active && destination <= active {
            sessions[activeSessionIndex].activeTabIndex = active + 1
        }
    }

    // MARK: - Pane Operations

    /// Split a pane. For remote sessions, sends the request to the server
    /// and returns false — the local tree updates via layoutUpdate.
    @discardableResult
    func splitPane(id paneID: UUID, direction: SplitDirection, newPane: TerminalPane) -> Bool {
        guard sessions.indices.contains(activeSessionIndex) else { return false }

        let session = sessions[activeSessionIndex]

        if let sid = session.source.serverSessionID,
           let serverPaneUUID = serverPaneUUID(for: paneID) {
            remoteClient?.splitPane(
                sessionID: SessionID(sid),
                paneID: PaneID(serverPaneUUID),
                direction: direction
            )
            return false
        }

        for i in sessions[activeSessionIndex].tabs.indices {
            if let newTree = sessions[activeSessionIndex].tabs[i].paneTree.split(
                paneID: paneID, direction: direction, newPane: newPane
            ) {
                sessions[activeSessionIndex].tabs[i].paneTree = newTree
                return true
            }
        }
        return false
    }

    /// Close a specific pane. For remote sessions, sends the request to the server
    /// and returns a sentinel value — local state updates via layoutUpdate.
    /// For local sessions, if it's the last pane in its tab, closes the tab.
    /// Returns the ID of a sibling pane to focus, or nil if the tab was closed.
    @discardableResult
    func closePane(id paneID: UUID) -> UUID? {
        guard sessions.indices.contains(activeSessionIndex) else { return nil }

        let session = sessions[activeSessionIndex]

        if let sid = session.source.serverSessionID,
           let serverPaneUUID = serverPaneUUID(for: paneID) {
            remoteClient?.closePane(
                sessionID: SessionID(sid),
                paneID: PaneID(serverPaneUUID)
            )
            return nil
        }

        for i in sessions[activeSessionIndex].tabs.indices {
            guard sessions[activeSessionIndex].tabs[i].paneTree.contains(paneID: paneID)
            else { continue }
            if let newTree = sessions[activeSessionIndex].tabs[i].paneTree.removePane(id: paneID) {
                sessions[activeSessionIndex].tabs[i].paneTree = newTree
                return newTree.firstPane.id
            } else {
                closeTab(at: i)
                return nil
            }
        }
        return nil
    }

    /// Replace the active tab's pane tree (e.g. after a divider drag).
    func updateActivePaneTree(_ newTree: PaneNode) {
        guard sessions.indices.contains(activeSessionIndex) else { return }
        let tabIdx = sessions[activeSessionIndex].activeTabIndex
        guard sessions[activeSessionIndex].tabs.indices.contains(tabIdx) else { return }
        sessions[activeSessionIndex].tabs[tabIdx].paneTree = newTree
    }

    // MARK: - Floating Pane Operations

    /// Mutable access to the active tab's floating panes.
    private var activeFloatingPanes: [FloatingPane] {
        get {
            guard sessions.indices.contains(activeSessionIndex) else { return [] }
            let tabIdx = sessions[activeSessionIndex].activeTabIndex
            guard sessions[activeSessionIndex].tabs.indices.contains(tabIdx) else { return [] }
            return sessions[activeSessionIndex].tabs[tabIdx].floatingPanes
        }
        set {
            guard sessions.indices.contains(activeSessionIndex) else { return }
            let tabIdx = sessions[activeSessionIndex].activeTabIndex
            guard sessions[activeSessionIndex].tabs.indices.contains(tabIdx) else { return }
            sessions[activeSessionIndex].tabs[tabIdx].floatingPanes = newValue
        }
    }

    /// Create a new floating pane in the active tab.
    /// For remote sessions, sends the request to the server and returns nil —
    /// the floating pane will be created when the server broadcasts a layoutUpdate.
    @discardableResult
    func createFloatingPane(initialWorkingDirectory: String? = nil) -> UUID? {
        guard sessions.indices.contains(activeSessionIndex),
              sessions[activeSessionIndex].tabs.indices.contains(
                  sessions[activeSessionIndex].activeTabIndex) else { return nil }

        let session = sessions[activeSessionIndex]

        if let serverSessionID = session.source.serverSessionID,
           let tabIDs = serverTabIDs[session.id],
           tabIDs.indices.contains(session.activeTabIndex) {
            remoteClient?.createFloatingPane(
                sessionID: SessionID(serverSessionID),
                tabID: tabIDs[session.activeTabIndex]
            )
            return nil
        }

        let pane = TerminalPane(initialWorkingDirectory: initialWorkingDirectory)
        let nextZ = (activeFloatingPanes.max(by: { $0.zIndex < $1.zIndex })?.zIndex ?? -1) + 1
        let frame = nextFloatingPaneFrame()
        var floating = FloatingPane(pane: pane, frame: frame, zIndex: nextZ)
        floating.clampFrame()
        activeFloatingPanes.append(floating)
        return pane.id
    }

    private func nextFloatingPaneFrame() -> CGRect {
        let base = FloatingPane.defaultFrame
        let step: CGFloat = 0.03
        let existing = activeFloatingPanes

        guard !existing.isEmpty else { return base }

        var candidate = base
        for i in 0..<existing.count {
            let offset = step * CGFloat(i + 1)
            candidate = CGRect(
                x: base.origin.x + offset,
                y: base.origin.y + offset,
                width: base.width,
                height: base.height
            )
            let collision = existing.contains { pane in
                abs(pane.frame.origin.x - candidate.origin.x) < step / 2
                    && abs(pane.frame.origin.y - candidate.origin.y) < step / 2
            }
            if !collision { break }
        }
        return candidate
    }

    /// Close a floating pane by its pane ID. Returns true if found and removed.
    /// For remote sessions, sends the request to the server — local state
    /// updates when the server broadcasts a layoutUpdate.
    @discardableResult
    func closeFloatingPane(paneID: UUID) -> Bool {
        if let serverPaneUUID = serverPaneUUID(for: paneID) {
            if let session = sessions.first(where: {
                $0.source.isRemote && $0.allPaneIDs.contains(paneID)
            }), let serverSessionID = session.source.serverSessionID {
                remoteClient?.closeFloatingPane(
                    sessionID: SessionID(serverSessionID),
                    paneID: PaneID(serverPaneUUID)
                )
                return true
            }
        }

        for s in sessions.indices {
            for t in sessions[s].tabs.indices {
                if let idx = sessions[s].tabs[t].floatingPanes.firstIndex(
                    where: { $0.pane.id == paneID })
                {
                    sessions[s].tabs[t].floatingPanes.remove(at: idx)
                    return true
                }
            }
        }
        return false
    }

    private func activeFloatingPaneIndex(for paneID: UUID) -> Int? {
        activeFloatingPanes.firstIndex(where: { $0.pane.id == paneID })
    }

    func bringFloatingPaneToFront(paneID: UUID) {
        if let sid = activeSession?.source.serverSessionID,
           let serverPaneUUID = serverPaneUUID(for: paneID) {
            remoteClient?.bringFloatingPaneToFront(
                sessionID: SessionID(sid),
                paneID: PaneID(serverPaneUUID)
            )
            return
        }

        guard let idx = activeFloatingPaneIndex(for: paneID) else { return }
        let maxZ = activeFloatingPanes.max(by: { $0.zIndex < $1.zIndex })?.zIndex ?? 0
        guard activeFloatingPanes[idx].zIndex < maxZ else { return }
        activeFloatingPanes[idx].zIndex = maxZ + 1
    }

    func updateFloatingPaneFrame(paneID: UUID, frame: CGRect) {
        if let sid = activeSession?.source.serverSessionID,
           let serverPaneUUID = serverPaneUUID(for: paneID) {
            remoteClient?.updateFloatingPaneFrame(
                sessionID: SessionID(sid),
                paneID: PaneID(serverPaneUUID),
                x: Float(frame.origin.x), y: Float(frame.origin.y),
                width: Float(frame.width), height: Float(frame.height)
            )
            return
        }

        guard let idx = activeFloatingPaneIndex(for: paneID) else { return }
        activeFloatingPanes[idx].frame = frame
        activeFloatingPanes[idx].clampFrame()
    }

    func setFloatingPanesVisibility(visible: Bool) {
        for i in activeFloatingPanes.indices {
            if activeFloatingPanes[i].isVisible != visible {
                activeFloatingPanes[i].isVisible = visible
            }
        }
    }

    func toggleFloatingPanePin(paneID: UUID) {
        if let sid = activeSession?.source.serverSessionID,
           let serverPaneUUID = serverPaneUUID(for: paneID) {
            remoteClient?.toggleFloatingPanePin(
                sessionID: SessionID(sid),
                paneID: PaneID(serverPaneUUID)
            )
            return
        }

        guard let idx = activeFloatingPaneIndex(for: paneID) else { return }
        activeFloatingPanes[idx].isPinned.toggle()
    }

    func updateFloatingPaneTitle(paneID: UUID, title: String) {
        guard let idx = activeFloatingPaneIndex(for: paneID) else { return }
        guard activeFloatingPanes[idx].title != title else { return }
        activeFloatingPanes[idx].title = title
    }

    func updateFloatingPanesVisibilityForFocus(focusedPaneID: UUID?) {
        guard let focusedID = focusedPaneID else { return }

        let isFloatingFocused = activeFloatingPanes.contains { $0.pane.id == focusedID }

        for i in activeFloatingPanes.indices {
            let newVisible = isFloatingFocused || activeFloatingPanes[i].isPinned
            if activeFloatingPanes[i].isVisible != newVisible {
                activeFloatingPanes[i].isVisible = newVisible
            }
        }
    }

    // MARK: - Title Updates

    func updateTitle(_ title: String, for tabID: UUID) {
        guard sessions.indices.contains(activeSessionIndex) else { return }
        if let index = sessions[activeSessionIndex].tabs.firstIndex(where: { $0.id == tabID }) {
            sessions[activeSessionIndex].tabs[index].title = title
        }
    }

    // MARK: - Handle Action

    /// Handle tab-level actions. Returns false for actions that need window-level handling.
    @discardableResult
    func handleAction(_ action: TabAction) -> Bool {
        switch action {
        case .newTab:
            createTab()
            return true
        case .closeTab:
            return closeActiveTab()
        case .previousTab:
            selectPreviousTab()
            return true
        case .nextTab:
            selectNextTab()
            return true
        case .gotoTab(let number):
            selectTabByNumber(number)
            return true
        case .newSession:
            createSession()
            return true
        case .closeSession, .previousSession, .nextSession, .toggleSidebar:
            // Session-level actions are handled by TerminalWindowView.
            return false
        case .splitVertical, .splitHorizontal, .closePane,
             .focusPane, .paneExited,
             .newFloatingPane, .closeFloatingPane, .toggleOrCreateFloatingPane,
             .listRemoteSessions, .newRemoteSession, .showSessionPicker, .detachSession,
             .renameSession:
            // Pane/remote actions are handled by TerminalWindowView.
            return false
        }
    }

    // MARK: - Remote Session Support

    /// Attach to a tongyou server using a pre-established connection.
    /// Must be called on the main thread.
    func attachToTYD(connectionManager: TYDConnectionManager, connection: TYDConnection) {
        // Clean up stale state from a previous connection before wiring the new one.
        cleanupRemoteState()

        let client = RemoteSessionClient(connectionManager: connectionManager)

        client.onSessionList = { [weak self] infos in
            self?.handleRemoteSessionList(infos)
        }
        client.onSessionCreated = { [weak self] info in
            self?.handleRemoteSessionCreated(info)
        }
        client.onSessionClosed = { [weak self] sessionID in
            self?.handleRemoteSessionClosed(sessionID)
        }
        client.onScreenUpdated = { [weak self] _, paneID in
            self?.handleRemoteScreenUpdated(paneID)
        }
        client.onTitleChanged = { [weak self] _, paneID, title in
            self?.handleRemoteTitleChanged(paneID, title: title)
        }
        client.onPaneExited = { [weak self] _, paneID, _ in
            self?.handleRemotePaneExited(paneID)
        }
        client.onLayoutUpdate = { [weak self] info in
            self?.handleRemoteLayoutUpdate(info)
        }
        client.onDisconnected = { [weak self] in
            self?.handleRemoteDisconnected()
        }

        client.attachConnection(connection)
        remoteClient = client
    }

    /// Disconnect from the tongyou server.
    func disconnectFromTYD() {
        remoteClient?.disconnect()
        remoteClient = nil
        cleanupRemoteState()
    }

    /// Remove all remote sessions, controllers, and mappings.
    /// Called on explicit disconnect and before wiring a new connection
    /// so stale state from a previous connection doesn't block re-attach.
    private func cleanupRemoteState() {
        for controller in remoteControllers.values {
            controller.stop()
        }
        sessions.removeAll { $0.source.isRemote }
        remoteControllers.removeAll()
        serverToLocalPaneID.removeAll()
        serverTabIDs.removeAll()
        attachedRemoteSessionIDs.removeAll()
        pendingAttachSessionIDs.removeAll()

        if !sessions.isEmpty {
            activeSessionIndex = min(activeSessionIndex, sessions.count - 1)
        } else {
            activeSessionIndex = 0
        }
    }

    /// Called when the server connection drops unexpectedly.
    private func handleRemoteDisconnected() {
        remoteClient = nil
        cleanupRemoteState()
    }

    /// Whether we are connected to a tongyou server.
    var isConnectedToTYD: Bool {
        remoteClient != nil
    }

    /// Ensure connection to the tongyou server, auto-starting if needed.
    /// Performs blocking connect off main thread, then wires the client on main thread.
    /// Calls `completion` on the main thread after the client is wired.
    func ensureConnected(completion: @escaping @Sendable () -> Void = {}) {
        if isConnectedToTYD {
            completion()
            return
        }
        guard connectionStatus == .idle else { return }
        connectionStatus = .connecting
        let manager = connectionManager ?? TYDConnectionManager(autoStart: true)
        connectionManager = manager
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let conn = try manager.connect()
                DispatchQueue.main.async {
                    self?.connectionStatus = .idle
                    self?.attachToTYD(connectionManager: manager, connection: conn)
                    completion()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.connectionStatus = .failed("\(error)")
                    print("[TongYou] Failed to connect to server: \(error)")
                }
            }
        }
    }

    /// List remote sessions: connect if needed, then request session list.
    func listRemoteSessions() {
        ensureConnected { [weak self] in
            self?.remoteClient?.requestSessionList()
        }
    }

    /// Create a new remote session: connect if needed, then request creation.
    func createRemoteSession(name: String? = nil) {
        let sessionName = name ?? nextAvailableName(prefix: "RSession")
        ensureConnected { [weak self] in
            self?.remoteClient?.createSession(name: sessionName)
        }
    }

    /// Attach to a remote session (start receiving screen updates).
    func attachRemoteSession(serverSessionID: UUID) {
        guard let client = remoteClient else { return }
        client.attachSession(SessionID(serverSessionID))
        attachedRemoteSessionIDs.insert(serverSessionID)
        pendingAttachSessionIDs.insert(serverSessionID)
    }

    /// Detach from a remote session (stop receiving screen updates).
    /// The session remains in the sidebar but its panes are torn down locally.
    func detachRemoteSession(serverSessionID: UUID) {
        guard let client = remoteClient else { return }
        client.detachSession(SessionID(serverSessionID))
        attachedRemoteSessionIDs.remove(serverSessionID)
        pendingAttachSessionIDs.remove(serverSessionID)

        // Tear down local panes for this session but keep the session entry.
        if let sessionIndex = sessionIndex(forServerSessionID: serverSessionID) {
            let paneIDs = sessions[sessionIndex].allPaneIDs
            teardownRemotePanes(Set(paneIDs), sessionID: sessions[sessionIndex].id)
            // Replace tabs with a single empty tab (session stays in sidebar).
            sessions[sessionIndex].tabs = [TerminalTab()]
            sessions[sessionIndex].activeTabIndex = 0
            onRemoteDetached?(paneIDs)
        }
    }

    /// Callback when a remote session is detached (view layer tears down MetalViews).
    /// Parameter: pane IDs that were removed.
    var onRemoteDetached: (([UUID]) -> Void)?

    /// Get the remote controller for a pane, if it exists.
    func remoteController(for paneID: UUID) -> ClientTerminalController? {
        remoteControllers[paneID]
    }

    // MARK: - Private: Remote Helpers

    /// Stop controllers and remove ID mappings for the given local pane IDs.
    private func teardownRemotePanes(_ paneIDs: Set<UUID>, sessionID: UUID? = nil) {
        for paneID in paneIDs {
            remoteControllers.removeValue(forKey: paneID)?.stop()
            if let serverUUID = serverPaneUUID(for: paneID) {
                serverToLocalPaneID.removeValue(forKey: serverUUID)
            }
        }
        if let sessionID {
            serverTabIDs.removeValue(forKey: sessionID)
        }
    }

    /// Build tabs from server SessionInfo, reusing existing controllers.
    private func buildTabs(from info: SessionInfo) -> [TerminalTab] {
        info.tabs.map { tabInfo -> TerminalTab in
            var tab = TerminalTab(title: tabInfo.title)
            tab.paneTree = buildPaneNode(from: tabInfo.layout, sessionID: info.id)
            tab.floatingPanes = tabInfo.floatingPanes.map { fpInfo in
                buildFloatingPane(from: fpInfo, sessionID: info.id)
            }
            return tab
        }
    }

    /// Build a FloatingPane from a server FloatingPaneInfo.
    private func buildFloatingPane(from info: FloatingPaneInfo, sessionID: SessionID) -> FloatingPane {
        let localPane = getOrCreateRemotePane(serverPaneID: info.paneID, sessionID: sessionID)
        let frame = CGRect(
            x: CGFloat(info.frameX), y: CGFloat(info.frameY),
            width: CGFloat(info.frameWidth), height: CGFloat(info.frameHeight)
        )
        return FloatingPane(
            pane: localPane,
            frame: frame,
            isVisible: info.isVisible,
            zIndex: Int(info.zIndex),
            isPinned: info.isPinned,
            title: info.title
        )
    }

    // MARK: - Private: Remote Event Handlers

    private func handleRemoteSessionList(_ infos: [SessionInfo]) {
        for info in infos {
            addOrUpdateRemoteSession(info)
        }
    }

    private func handleRemoteSessionCreated(_ info: SessionInfo) {
        addOrUpdateRemoteSession(info)
        // Auto-attach and select newly created remote sessions.
        let sessionUUID = info.id.uuid
        attachRemoteSession(serverSessionID: sessionUUID)
        if let index = sessionIndex(forServerSessionID: sessionUUID) {
            activeSessionIndex = index
        }
    }

    private func handleRemoteSessionClosed(_ sessionID: SessionID) {
        guard let index = sessionIndex(forServerSessionID: sessionID.uuid) else { return }

        teardownRemotePanes(Set(sessions[index].allPaneIDs), sessionID: sessions[index].id)
        attachedRemoteSessionIDs.remove(sessionID.uuid)

        sessions.remove(at: index)

        if !sessions.isEmpty {
            if activeSessionIndex >= sessions.count {
                activeSessionIndex = sessions.count - 1
            } else if activeSessionIndex > index {
                activeSessionIndex -= 1
            }
        } else {
            activeSessionIndex = 0
        }
    }

    private func controllerForServerPane(_ paneID: PaneID) -> ClientTerminalController? {
        guard let localID = serverToLocalPaneID[paneID.uuid] else { return nil }
        return remoteControllers[localID]
    }

    private func handleRemoteScreenUpdated(_ paneID: PaneID) {
        controllerForServerPane(paneID)?.handleScreenUpdated()
    }

    private func handleRemoteTitleChanged(_ paneID: PaneID, title: String) {
        controllerForServerPane(paneID)?.handleTitleChanged(title)
    }

    private func handleRemotePaneExited(_ paneID: PaneID) {
        controllerForServerPane(paneID)?.handleProcessExited()
    }

    /// Reconcile local state with the authoritative server layout.
    /// Returns the local pane IDs that were removed and need MetalView teardown.
    @discardableResult
    private func handleRemoteLayoutUpdate(_ info: SessionInfo) -> [UUID] {
        guard let sessionIndex = sessionIndex(forServerSessionID: info.id.uuid)
        else { return [] }

        // Clear pending state — the layout is now known.
        pendingAttachSessionIDs.remove(info.id.uuid)

        // Sync session name from server (guard avoids no-op SwiftUI invalidation).
        let resolvedName = uniqueSessionName(info.name, for: sessions[sessionIndex].id, excludingIndex: sessionIndex)
        if sessions[sessionIndex].name != resolvedName {
            sessions[sessionIndex].name = resolvedName
        }

        let oldPaneIDs = Set(sessions[sessionIndex].allPaneIDs)

        let newTabs = buildTabs(from: info)
        sessions[sessionIndex].tabs = newTabs.isEmpty ? [TerminalTab()] : newTabs
        sessions[sessionIndex].activeTabIndex = min(
            info.activeTabIndex, max(sessions[sessionIndex].tabs.count - 1, 0)
        )
        serverTabIDs[sessions[sessionIndex].id] = info.tabs.map(\.id)

        let newPaneIDs = Set(sessions[sessionIndex].allPaneIDs)
        let removedPaneIDs = oldPaneIDs.subtracting(newPaneIDs)
        let addedPaneIDs = newPaneIDs.subtracting(oldPaneIDs)
        teardownRemotePanes(removedPaneIDs)

        onRemoteLayoutChanged?(sessions[sessionIndex].id, Array(removedPaneIDs), Array(addedPaneIDs))
        return Array(removedPaneIDs)
    }

    /// Callback for the view layer to handle layout changes (e.g. teardown MetalViews, refocus).
    /// Parameters: (sessionID, removedPaneIDs, addedPaneIDs)
    var onRemoteLayoutChanged: ((UUID, [UUID], [UUID]) -> Void)?

    private func addOrUpdateRemoteSession(_ info: SessionInfo) {
        let sessionUUID = info.id.uuid

        // Check if this session already exists.
        if sessionIndex(forServerSessionID: sessionUUID) != nil {
            return
        }

        // Add the session to the sidebar with an empty tab (detached state).
        // The session only gets real tabs/panes when the user explicitly attaches.
        var session = TerminalSession(
            remoteSessionID: sessionUUID,
            name: info.name,
            tabs: [TerminalTab()]
        )
        session.name = uniqueSessionName(info.name, for: session.id)
        sessions.append(session)
    }

    /// Get or create a local TerminalPane for a server pane ID,
    /// reusing existing controllers when a mapping already exists.
    private func getOrCreateRemotePane(serverPaneID: PaneID, sessionID: SessionID) -> TerminalPane {
        if let existingLocalID = serverToLocalPaneID[serverPaneID.uuid] {
            return TerminalPane(id: existingLocalID)
        }
        let pane = TerminalPane()
        if let client = remoteClient {
            let controller = ClientTerminalController(
                remoteClient: client,
                sessionID: sessionID,
                paneID: serverPaneID
            )
            remoteControllers[pane.id] = controller
            serverToLocalPaneID[serverPaneID.uuid] = pane.id
        }
        return pane
    }

    /// Recursively build a PaneNode from a server LayoutTree.
    private func buildPaneNode(from layout: LayoutTree, sessionID: SessionID) -> PaneNode {
        switch layout {
        case .leaf(let paneID):
            return .leaf(getOrCreateRemotePane(serverPaneID: paneID, sessionID: sessionID))

        case .split(let direction, let ratio, let first, let second):
            return .split(
                direction: direction,
                ratio: CGFloat(ratio),
                first: buildPaneNode(from: first, sessionID: sessionID),
                second: buildPaneNode(from: second, sessionID: sessionID)
            )
        }
    }
}
