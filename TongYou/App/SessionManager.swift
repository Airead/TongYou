import AppKit
import CoreGraphics
import Foundation
import TYClient
import TYProtocol
import TYServer
import TYTerminal

/// Info about a command used to create a floating pane.
/// Stored so the command can be re-run on Enter after exit.
struct FloatingPaneCommandInfo {
    let command: String
    let arguments: [String]
    let workingDirectory: String?
    let closeOnExit: Bool
}

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

    /// Tracks which local sessions are currently attached (rendering).
    private(set) var attachedLocalSessionIDs: Set<UUID> = []

    /// Controllers for remote panes, keyed by local pane UUID.
    private var remoteControllers: [UUID: ClientTerminalController] = [:]
    /// Bidirectional mapping between server pane UUID and local pane UUID.
    private var serverToLocalPaneID: [UUID: UUID] = [:]
    /// Maps session UUID → ordered list of server TabIDs (parallel to session.tabs).
    private var serverTabIDs: [UUID: [TabID]] = [:]

    /// Controllers for local panes, keyed by pane UUID.
    private var localControllers: [UUID: TerminalController] = [:]

    private var overlayStacks: [UUID: [TerminalController]] = [:]

    /// Floating panes whose process has exited but are kept open for reading.
    /// ESC closes them, Enter re-runs the command.
    /// Maps pane ID to the process exit code.
    private(set) var exitedFloatingPanes: [UUID: Int32] = [:]

    /// Command info for floating panes created via `createFloatingPaneWithCommand`.
    /// Keyed by local pane ID. Used to determine exit behavior and re-run commands.
    private(set) var floatingPaneCommands: [UUID: FloatingPaneCommandInfo] = [:]

    /// Pending command info for remote floating panes awaiting server layoutUpdate.
    private var pendingRemoteCommandInfos: [FloatingPaneCommandInfo] = []

    /// Callbacks keyed by requested session name, fired when the matching
    /// remote session first lands in `sessions`. Used by automation to
    /// await remote-create completion synchronously. Handlers receive the
    /// local session UUID on success or `nil` on disconnect/timeout.
    private var pendingRemoteCreateHandlers: [String: (UUID?) -> Void] = [:]

    /// Local session persistence store.
    private let localSessionStore: SessionStore

    /// Debounced save work items per local session.
    private var pendingLocalSaves: [UUID: DispatchWorkItem] = [:]
    private let pendingLocalSavesLock = NSLock()

    /// Sidebar session sort order persisted alongside local sessions.
    private var sessionSortOrder: [UUID] = []

    init(localSessionStore: SessionStore? = nil) {
        let store: SessionStore
        if let s = localSessionStore {
            store = s
        } else {
            store = SessionStore(directory: ServerConfig.defaultLocalPersistenceDirectory())
        }
        self.localSessionStore = store
        sessionSortOrder = store.loadOrder()
        MainActor.assumeIsolated {
            SessionManagerRegistry.shared.register(self)
        }
    }

    deinit {
        remoteClient?.disconnect()
        MainActor.assumeIsolated {
            SessionManagerRegistry.shared.unregister(self)
        }
    }

    /// Metadata describing which session and tab own a given pane.
    struct PaneMetadata {
        let sessionName: String
        let tabID: UUID
        let tabTitle: String
    }

    /// Looks up which session and tab own a given pane ID.
    func metadata(for paneID: UUID) -> PaneMetadata? {
        for session in sessions {
            for tab in session.tabs {
                if tab.hasPane(id: paneID) {
                    return PaneMetadata(sessionName: session.name, tabID: tab.id, tabTitle: tab.title)
                }
            }
        }
        return nil
    }

    /// Returns the session ID and tab ID that own a given pane ID.
    func paneOwnerIDs(paneID: UUID) -> (sessionID: UUID, tabID: UUID)? {
        for session in sessions {
            for tab in session.tabs {
                if tab.hasPane(id: paneID) {
                    return (session.id, tab.id)
                }
            }
        }
        return nil
    }

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

    /// Describes the display state of a session from the UI's perspective.
    enum SessionDisplayState {
        /// Session is fully attached with layout received.
        case ready
        /// Session is detached — show "Press Enter to attach" placeholder.
        case detached
        /// Attach sent but layoutUpdate not yet received — show "Connecting..." placeholder.
        case pendingAttach
    }

    /// The display state of the active session.
    var activeSessionDisplayState: SessionDisplayState {
        guard let session = activeSession else { return .ready }
        if let serverID = session.source.serverSessionID {
            if pendingAttachSessionIDs.contains(serverID) { return .pendingAttach }
            if !attachedRemoteSessionIDs.contains(serverID) { return .detached }
            return .ready
        }
        if session.source == .local {
            if !attachedLocalSessionIDs.contains(session.id) { return .detached }
        }
        return .ready
    }

    private(set) var allAttachedSessionIDs: Set<UUID> = []

    private func rebuildAllAttachedSessionIDs() {
        var ids = attachedLocalSessionIDs
        for session in sessions {
            if let serverID = session.source.serverSessionID,
               attachedRemoteSessionIDs.contains(serverID) {
                ids.insert(session.id)
            }
        }
        allAttachedSessionIDs = ids
    }

    func isSessionDetached(at index: Int) -> Bool {
        guard sessions.indices.contains(index) else { return false }
        let session = sessions[index]
        if let serverID = session.source.serverSessionID {
            return !attachedRemoteSessionIDs.contains(serverID)
        }
        if session.source == .local {
            return !attachedLocalSessionIDs.contains(session.id)
        }
        return false
    }

    var sessionCount: Int { sessions.count }
    var tabCount: Int { activeSession?.tabCount ?? 0 }
    var tabs: [TerminalTab] { activeSession?.tabs ?? [] }
    var activeTabIndex: Int { activeSession?.activeTabIndex ?? 0 }

    // MARK: - Session Lifecycle

    @discardableResult
    func createSession(name: String? = nil, initialWorkingDirectory: String? = nil, isAnonymous: Bool = false) -> UUID {
        let baseName = name ?? nextAvailableName(prefix: "LSession")
        var session = TerminalSession(name: baseName, initialWorkingDirectory: initialWorkingDirectory, isAnonymous: isAnonymous)
        session.name = uniqueSessionName(baseName, for: session.id)
        let newSessionID = session.id
        sessions.append(session)
        if !isAnonymous {
            sessionSortOrder.append(newSessionID)
            saveSessionOrder()
            applySessionOrder()
            scheduleLocalSaveIfNeeded(sessionID: newSessionID)
        }
        activeSessionIndex = sessions.firstIndex(where: { $0.id == newSessionID }) ?? sessions.count - 1
        attachedLocalSessionIDs.insert(newSessionID)
        rebuildAllAttachedSessionIDs()
        return newSessionID
    }

    @discardableResult
    func createAnonymousSession(initialWorkingDirectory: String? = nil) -> UUID {
        return createSession(name: "Draft", initialWorkingDirectory: initialWorkingDirectory, isAnonymous: true)
    }

    /// Close a session at the given index.
    /// Returns the list of all pane IDs that need teardown.
    @discardableResult
    func closeSession(at index: Int) -> [UUID] {
        guard sessions.indices.contains(index) else { return [] }
        let session = sessions[index]
        let paneIDs = session.allPaneIDs

        // Clean up exited floating pane tracking.
        for paneID in paneIDs { exitedFloatingPanes.removeValue(forKey: paneID) }

        // Clean up remote controllers if this is a remote session.
        if let serverSessionID = session.source.serverSessionID {
            teardownRemotePanes(Set(paneIDs), sessionID: session.id)
            remoteClient?.closeSession(SessionID(serverSessionID))
        }

        // Clean up local controllers and persistence if this is a local session.
        if session.source == .local {
            for paneID in paneIDs {
                stopAllControllers(for: paneID)
            }
            attachedLocalSessionIDs.remove(session.id)
            rebuildAllAttachedSessionIDs()
            cancelPendingLocalSave(sessionID: session.id)
            if !session.isAnonymous {
                localSessionStore.delete(sessionID: SessionID(session.id))
            }
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

        sessionSortOrder.removeAll { $0 == session.id }
        saveSessionOrder()
        onSessionClosed?(session.id, paneIDs)
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

    private var visualSessionIndices: [Int] {
        let attached = sessions.indices.filter { allAttachedSessionIDs.contains(sessions[$0].id) }
        let detached = sessions.indices.filter { !allAttachedSessionIDs.contains(sessions[$0].id) }
        return attached + detached
    }

    func selectPreviousSessionInVisualOrder() {
        let visual = visualSessionIndices
        guard visual.count > 1 else { return }
        guard let pos = visual.firstIndex(of: activeSessionIndex) else { return }
        let newPos = (pos - 1 + visual.count) % visual.count
        activeSessionIndex = visual[newPos]
    }

    func selectNextSessionInVisualOrder() {
        let visual = visualSessionIndices
        guard visual.count > 1 else { return }
        guard let pos = visual.firstIndex(of: activeSessionIndex) else { return }
        let newPos = (pos + 1) % visual.count
        activeSessionIndex = visual[newPos]
    }

    // MARK: - Session Reordering

    func moveSession(from source: Int, to destination: Int) {
        guard source != destination,
              sessions.indices.contains(source),
              sessions.indices.contains(destination) else { return }

        let session = sessions.remove(at: source)
        sessions.insert(session, at: destination)

        if activeSessionIndex == source {
            activeSessionIndex = destination
        } else if source < activeSessionIndex && destination >= activeSessionIndex {
            activeSessionIndex -= 1
        } else if source > activeSessionIndex && destination <= activeSessionIndex {
            activeSessionIndex += 1
        }

        sessionSortOrder = sessions.map(\.id)
        saveSessionOrder()
    }

    // MARK: - Session Rename

    func renameSession(at index: Int, to name: String) {
        guard sessions.indices.contains(index) else { return }
        let sessionID = sessions[index].id
        let oldName = sessions[index].name
        let wasAnonymous = sessions[index].isAnonymous
        let isLocal = sessions[index].source == .local
        sessions[index].name = uniqueSessionName(name, for: sessionID, excludingIndex: index)
        guard sessions[index].name != oldName else { return }

        if wasAnonymous {
            sessions[index].isAnonymous = false
        }

        if let serverSessionID = sessions[index].source.serverSessionID {
            remoteClient?.renameSession(SessionID(serverSessionID), name: sessions[index].name)
        }

        if isLocal {
            if wasAnonymous, !sessionSortOrder.contains(sessionID) {
                sessionSortOrder.append(sessionID)
                saveSessionOrder()
                let previousActiveID = activeSession?.id
                applySessionOrder()
                if let previousActiveID {
                    activeSessionIndex = sessions.firstIndex(where: { $0.id == previousActiveID }) ?? activeSessionIndex
                }
            }
            scheduleLocalSaveIfNeeded(sessionID: sessionID)
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
        if attachedLocalSessionIDs.contains(session.id) {
            for paneID in tab.allPaneIDsIncludingFloating {
                _ = ensureLocalController(for: paneID)
            }
        }
        scheduleLocalSaveIfNeeded(sessionID: session.id)
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

        let removedPaneIDs = sessions[activeSessionIndex].tabs[index].allPaneIDsIncludingFloating
        for paneID in removedPaneIDs {
            exitedFloatingPanes.removeValue(forKey: paneID)
            stopAllControllers(for: paneID)
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

        scheduleLocalSaveIfNeeded(sessionID: session.id)
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
        notifyServerTabSelected(clamped)
        if sessions[activeSessionIndex].source == .local {
            scheduleLocalSaveIfNeeded(sessionID: sessions[activeSessionIndex].id)
        }
    }

    func selectPreviousTab() {
        guard sessions.indices.contains(activeSessionIndex) else { return }
        let count = sessions[activeSessionIndex].tabs.count
        guard count > 1 else { return }
        let current = sessions[activeSessionIndex].activeTabIndex
        let newIndex = (current - 1 + count) % count
        sessions[activeSessionIndex].activeTabIndex = newIndex
        notifyServerTabSelected(newIndex)
    }

    func selectNextTab() {
        guard sessions.indices.contains(activeSessionIndex) else { return }
        let count = sessions[activeSessionIndex].tabs.count
        guard count > 1 else { return }
        let current = sessions[activeSessionIndex].activeTabIndex
        let newIndex = (current + 1) % count
        sessions[activeSessionIndex].activeTabIndex = newIndex
        notifyServerTabSelected(newIndex)
    }

    private func notifyServerTabSelected(_ tabIndex: Int) {
        guard let serverSessionID = sessions[activeSessionIndex].source.serverSessionID else { return }
        remoteClient?.selectTab(sessionID: SessionID(serverSessionID), tabIndex: UInt16(tabIndex))
    }

    /// Record the focused pane on the current tab (local state) and notify the server if remote.
    func notifyPaneFocused(_ paneID: UUID) {
        guard sessions.indices.contains(activeSessionIndex) else { return }
        let tabIndex = sessions[activeSessionIndex].activeTabIndex
        guard sessions[activeSessionIndex].tabs.indices.contains(tabIndex) else { return }
        guard sessions[activeSessionIndex].tabs[tabIndex].focusedPaneID != paneID else { return }
        sessions[activeSessionIndex].tabs[tabIndex].focusedPaneID = paneID

        if let serverSessionID = sessions[activeSessionIndex].source.serverSessionID,
           let serverPaneUUID = serverPaneUUID(for: paneID) {
            remoteClient?.focusPane(
                sessionID: SessionID(serverSessionID),
                paneID: PaneID(serverPaneUUID)
            )
        }

        if sessions[activeSessionIndex].source == .local {
            scheduleLocalSaveIfNeeded(sessionID: sessions[activeSessionIndex].id)
        }
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

        let sessionID = sessions[activeSessionIndex].id
        let isLocal = sessions[activeSessionIndex].source == .local
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

        if isLocal {
            scheduleLocalSaveIfNeeded(sessionID: sessionID)
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
                if attachedLocalSessionIDs.contains(session.id) {
                    _ = ensureLocalController(for: newPane.id)
                }
                scheduleLocalSaveIfNeeded(sessionID: session.id)
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
            stopAllControllers(for: paneID)
            if let newTree = sessions[activeSessionIndex].tabs[i].paneTree.removePane(id: paneID) {
                sessions[activeSessionIndex].tabs[i].paneTree = newTree
                scheduleLocalSaveIfNeeded(sessionID: session.id)
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
        if sessions[activeSessionIndex].source == .local {
            scheduleLocalSaveIfNeeded(sessionID: sessions[activeSessionIndex].id)
        }
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
        let floating = FloatingPane(pane: pane, frame: activeFloatingPanes.nextCascadedFrame(), zIndex: activeFloatingPanes.nextZIndex)
        activeFloatingPanes.append(floating)
        if attachedLocalSessionIDs.contains(session.id) {
            _ = ensureLocalController(for: pane.id)
        }
        scheduleLocalSaveIfNeeded(sessionID: session.id)
        return pane.id
    }

    /// Mark a floating pane as exited (process finished) with the given exit code.
    /// ESC will close it, Enter will re-run the command.
    func markFloatingPaneExited(_ paneID: UUID, exitCode: Int32) {
        exitedFloatingPanes[paneID] = exitCode
    }

    /// Close a floating pane by its pane ID. Returns true if found and removed.
    /// For remote sessions, sends the request to the server — local state
    /// updates when the server broadcasts a layoutUpdate.
    @discardableResult
    func closeFloatingPane(paneID: UUID) -> Bool {
        exitedFloatingPanes.removeValue(forKey: paneID)
        floatingPaneCommands.removeValue(forKey: paneID)
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
                    stopAllControllers(for: paneID)
                    if sessions[s].source == .local {
                        scheduleLocalSaveIfNeeded(sessionID: sessions[s].id)
                    }
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
        if activeSession?.source == .local {
            scheduleLocalSaveIfNeeded(sessionID: activeSession!.id)
        }
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
        }

        // Always update locally for immediate visual feedback.
        // For remote sessions the server's layoutUpdate will later reconcile
        // the authoritative state.
        guard let idx = activeFloatingPaneIndex(for: paneID) else { return }
        activeFloatingPanes[idx].frame = frame
        activeFloatingPanes[idx].clampFrame()
        if activeSession?.source == .local {
            scheduleLocalSaveIfNeeded(sessionID: activeSession!.id)
        }
    }

    func setFloatingPanesVisibility(visible: Bool) {
        var changed = false
        for i in activeFloatingPanes.indices {
            if activeFloatingPanes[i].isVisible != visible {
                activeFloatingPanes[i].isVisible = visible
                changed = true
            }
        }
        if changed, activeSession?.source == .local {
            scheduleLocalSaveIfNeeded(sessionID: activeSession!.id)
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
        if activeSession?.source == .local {
            scheduleLocalSaveIfNeeded(sessionID: activeSession!.id)
        }
    }

    func updateFloatingPaneTitle(paneID: UUID, title: String) {
        guard let idx = activeFloatingPaneIndex(for: paneID) else { return }
        guard activeFloatingPanes[idx].title != title else { return }
        activeFloatingPanes[idx].title = title
        if activeSession?.source == .local {
            scheduleLocalSaveIfNeeded(sessionID: activeSession!.id)
        }
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
             .focusPane, .paneExited, .growPane, .shrinkPane,
             .newFloatingPane, .closeFloatingPane, .toggleOrCreateFloatingPane,
             .rerunFloatingPaneCommand,
             .listRemoteSessions, .newRemoteSession, .showSessionPicker, .detachSession,
             .renameSession, .runInPlace(_, _), .runCommand(_, _, _),
             .paneNotification:
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
        client.onCwdChanged = { [weak self] _, paneID, cwd in
            self?.handleRemoteCwdChanged(paneID, cwd: cwd)
        }
        client.onPaneExited = { [weak self] _, paneID, exitCode in
            self?.handleRemotePaneExited(paneID, exitCode: exitCode)
        }
        client.onLayoutUpdate = { [weak self] info in
            self?.handleRemoteLayoutUpdate(info)
        }
        client.onClipboardSet = { text in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        client.onDisconnected = { [weak self] in
            self?.handleRemoteDisconnected()
        }

        client.attachConnection(connection)
        remoteClient = client
    }

    /// Disconnect from the tongyou server.
    func disconnectFromTYD() {
        failPendingRemoteCreateHandlers()
        remoteClient?.disconnect()
        remoteClient = nil
        cleanupRemoteState()
    }

    /// Invoke every pending remote-create handler with `nil` and clear the
    /// table. Called on disconnect paths so `AppControlClient.createSession`
    /// doesn't block forever when the daemon connection drops.
    private func failPendingRemoteCreateHandlers() {
        let handlers = pendingRemoteCreateHandlers
        pendingRemoteCreateHandlers.removeAll()
        for handler in handlers.values {
            handler(nil)
        }
    }

    /// Remove all remote sessions, controllers, and mappings.
    /// Called on explicit disconnect and before wiring a new connection
    /// so stale state from a previous connection doesn't block re-attach.
    private func cleanupRemoteState() {
        // Clean up exited floating pane tracking for remote panes.
        for paneID in remoteControllers.keys { exitedFloatingPanes.removeValue(forKey: paneID) }

        for controller in remoteControllers.values {
            controller.stop()
        }
        sessions.removeAll { $0.source.isRemote }
        remoteControllers.removeAll()
        serverToLocalPaneID.removeAll()
        serverTabIDs.removeAll()
        attachedRemoteSessionIDs.removeAll()
        pendingAttachSessionIDs.removeAll()
        rebuildAllAttachedSessionIDs()

        if !sessions.isEmpty {
            activeSessionIndex = min(activeSessionIndex, sessions.count - 1)
        } else {
            activeSessionIndex = 0
        }
    }

    /// Called when the server connection drops unexpectedly.
    private func handleRemoteDisconnected() {
        failPendingRemoteCreateHandlers()
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
    func ensureConnected(completion: @escaping () -> Void = {}) {
        if isConnectedToTYD {
            completion()
            return
        }
        guard connectionStatus == .idle else { return }
        connectionStatus = .connecting
        let manager = connectionManager ?? TYDConnectionManager(autoStart: true)
        connectionManager = manager
        Task {
            do {
                let conn = try await Task { @concurrent in
                    try manager.connect()
                }.value
                self.connectionStatus = .idle
                self.attachToTYD(connectionManager: manager, connection: conn)
                completion()
            } catch {
                self.connectionStatus = .failed("\(error)")
                print("[TongYou] Failed to connect to server: \(error)")
            }
        }
    }

    /// List remote sessions: connect if needed, then request session list.
    func listRemoteSessions() {
        ensureConnected {
            self.remoteClient?.requestSessionList()
        }
    }

    /// Create a new remote session: connect if needed, then request creation.
    ///
    /// When `completion` is provided, it fires on the main actor once the
    /// matching remote session is first registered locally (via
    /// `handleRemoteSessionCreated`). On disconnect before completion the
    /// handler is called with `nil`.
    func createRemoteSession(name: String? = nil, completion: ((UUID?) -> Void)? = nil) {
        let sessionName = name ?? nextAvailableName(prefix: "RSession")
        if let completion {
            pendingRemoteCreateHandlers[sessionName] = completion
        }
        ensureConnected {
            self.remoteClient?.createSession(name: sessionName)
        }
    }

    /// Attach to a remote session (start receiving screen updates).
    func attachRemoteSession(serverSessionID: UUID) {
        guard let client = remoteClient else { return }
        client.attachSession(SessionID(serverSessionID))
        attachedRemoteSessionIDs.insert(serverSessionID)
        pendingAttachSessionIDs.insert(serverSessionID)
        rebuildAllAttachedSessionIDs()
        if let session = sessions.first(where: { $0.source.serverSessionID == serverSessionID }) {
            moveSessionToBottomOfAttachedGroup(sessionID: session.id)
        }
    }

    /// Detach from a remote session (stop receiving screen updates).
    /// The session remains in the sidebar but its panes are torn down locally.
    func detachRemoteSession(serverSessionID: UUID) {
        guard let client = remoteClient else { return }
        client.detachSession(SessionID(serverSessionID))
        attachedRemoteSessionIDs.remove(serverSessionID)
        pendingAttachSessionIDs.remove(serverSessionID)
        rebuildAllAttachedSessionIDs()

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

    /// Callback fired at the end of `closeSession(at:)`, regardless of
    /// the trigger (UI click, keyboard, CLI automation). The view layer
    /// wires this to tear down MetalViews and clear focus history so
    /// every close path gets the same cleanup.
    ///
    /// Parameters: `(closedSessionID, removedPaneIDs)`.
    var onSessionClosed: ((UUID, [UUID]) -> Void)?

    /// True while an automation-initiated close is in flight. Observers
    /// that would otherwise close the hosting window when `sessions`
    /// becomes empty (e.g. `onRemoteSessionEmpty`) should skip that
    /// behavior while this flag is set — CLI callers want to remove
    /// the session without taking down the window.
    var isAutomationClose: Bool = false

    /// Get the remote controller for a pane, if it exists.
    func remoteController(for paneID: UUID) -> ClientTerminalController? {
        remoteControllers[paneID]
    }

    // MARK: - Private: Remote Helpers

    /// Stop controllers and remove ID mappings for the given local pane IDs.
    private func teardownRemotePanes(_ paneIDs: Set<UUID>, sessionID: UUID? = nil) {
        for paneID in paneIDs {
            remoteControllers.removeValue(forKey: paneID)?.stop()
            floatingPaneCommands.removeValue(forKey: paneID)
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
            if let serverFocusedID = tabInfo.focusedPaneID {
                tab.focusedPaneID = serverToLocalPaneID[serverFocusedID.uuid]
            }
            return tab
        }
    }

    /// Build a FloatingPane from a server FloatingPaneInfo.
    private func buildFloatingPane(from info: FloatingPaneInfo, sessionID: SessionID) -> FloatingPane {
        let isNew = serverToLocalPaneID[info.paneID.uuid] == nil
        let localPane = getOrCreateRemotePane(serverPaneID: info.paneID, sessionID: sessionID)

        // Associate pending remote command info with newly created floating panes.
        if isNew, !pendingRemoteCommandInfos.isEmpty {
            floatingPaneCommands[localPane.id] = pendingRemoteCommandInfos.removeFirst()
        }

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
        // Fire any automation create-completion handler waiting on this name.
        if let handler = pendingRemoteCreateHandlers.removeValue(forKey: info.name) {
            let localID = sessionIndex(forServerSessionID: sessionUUID).map { sessions[$0].id }
            handler(localID)
        }
    }

    private func handleRemoteSessionClosed(_ sessionID: SessionID) {
        guard let index = sessionIndex(forServerSessionID: sessionID.uuid) else { return }

        let paneIDs = sessions[index].allPaneIDs
        teardownRemotePanes(Set(paneIDs), sessionID: sessions[index].id)
        attachedRemoteSessionIDs.remove(sessionID.uuid)

        let localSessionID = sessions[index].id
        sessions.remove(at: index)
        rebuildAllAttachedSessionIDs()

        if !sessions.isEmpty {
            if activeSessionIndex >= sessions.count {
                activeSessionIndex = sessions.count - 1
            } else if activeSessionIndex > index {
                activeSessionIndex -= 1
            }
        } else {
            activeSessionIndex = 0
        }

        onRemoteSessionEmpty?(localSessionID, paneIDs)
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

    private func handleRemoteCwdChanged(_ paneID: PaneID, cwd: String) {
        controllerForServerPane(paneID)?.handleCwdChanged(cwd)
    }

    private func handleRemotePaneExited(_ paneID: PaneID, exitCode: Int32) {
        controllerForServerPane(paneID)?.handleProcessExited(exitCode: exitCode)
    }

    /// Apply pane metadata (cwd, etc.) from a SessionInfo to the corresponding controllers.
    private func applyPaneMetadata(_ metadata: [PaneID: RemotePaneMetadata]) {
        for (serverPaneID, meta) in metadata {
            guard let controller = controllerForServerPane(serverPaneID) else { continue }
            if let cwd = meta.cwd {
                controller.handleCwdChanged(cwd)
            }
        }
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

        // Server removed all tabs — the remote session is finished.
        if newTabs.isEmpty {
            let removedPaneIDs = Array(oldPaneIDs)
            teardownRemotePanes(oldPaneIDs)
            onRemoteSessionEmpty?(sessions[sessionIndex].id, removedPaneIDs)
            return removedPaneIDs
        }

        sessions[sessionIndex].tabs = newTabs
        sessions[sessionIndex].activeTabIndex = min(
            info.activeTabIndex, max(sessions[sessionIndex].tabs.count - 1, 0)
        )
        serverTabIDs[sessions[sessionIndex].id] = info.tabs.map(\.id)

        let newPaneIDs = Set(sessions[sessionIndex].allPaneIDs)
        let removedPaneIDs = oldPaneIDs.subtracting(newPaneIDs)
        let addedPaneIDs = newPaneIDs.subtracting(oldPaneIDs)
        teardownRemotePanes(removedPaneIDs)

        applyPaneMetadata(info.paneMetadata)

        onRemoteLayoutChanged?(sessions[sessionIndex].id, Array(removedPaneIDs), Array(addedPaneIDs))
        return Array(removedPaneIDs)
    }

    /// Callback when a remote session has no more tabs (all closed on the server).
    /// Parameters: (sessionID, removedPaneIDs)
    var onRemoteSessionEmpty: ((UUID, [UUID]) -> Void)?

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
        if !sessionSortOrder.contains(session.id) {
            sessionSortOrder.append(session.id)
        }
        saveSessionOrder()
        applySessionOrder()
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

    // MARK: - Local Session Persistence

    func restoreLocalSessions() {
        for persisted in localSessionStore.loadAll() {
            let session = buildLocalSession(from: persisted)
            sessions.append(session)
        }
        let existingIDs = Set(sessionSortOrder)
        for session in sessions where !existingIDs.contains(session.id) {
            sessionSortOrder.append(session.id)
        }
        deduplicateSessionSortOrder()
        saveSessionOrder()
        applySessionOrder()
    }

    private func deduplicateSessionSortOrder() {
        var seen = Set<UUID>()
        sessionSortOrder = sessionSortOrder.filter { seen.insert($0).inserted }
    }

    private func moveSessionToBottomOfAttachedGroup(sessionID: UUID) {
        guard sessionSortOrder.contains(sessionID) else { return }
        let otherAttachedIDs = allAttachedSessionIDs.subtracting([sessionID])
        sessionSortOrder.removeAll { $0 == sessionID }
        if let lastAttachedIndex = sessionSortOrder.lastIndex(where: { otherAttachedIDs.contains($0) }) {
            sessionSortOrder.insert(sessionID, at: lastAttachedIndex + 1)
        } else {
            sessionSortOrder.insert(sessionID, at: 0)
        }
        saveSessionOrder()
        applySessionOrder()
    }

    private func applySessionOrder() {
        guard !sessionSortOrder.isEmpty else { return }
        let orderMap = Dictionary(sessionSortOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let unknownOffset = sessionSortOrder.count
        let sorted = sessions.sorted {
            let o0 = orderMap[$0.id] ?? unknownOffset
            let o1 = orderMap[$1.id] ?? unknownOffset
            return o0 < o1
        }
        sessions = sorted
    }

    private func saveSessionOrder() {
        localSessionStore.saveOrder(sessionSortOrder)
    }

    private func buildLocalSession(from persisted: PersistedSession) -> TerminalSession {
        let info = persisted.sessionInfo
        let contexts = persisted.paneContexts
        let tabs: [TerminalTab] = info.tabs.map { tabInfo in
            let floatingPanes = tabInfo.floatingPanes.map { fpInfo in
                let pane = TerminalPane(
                    id: fpInfo.paneID.uuid,
                    initialWorkingDirectory: contexts[fpInfo.paneID]?.cwd
                )
                let frame = CGRect(
                    x: CGFloat(fpInfo.frameX), y: CGFloat(fpInfo.frameY),
                    width: CGFloat(fpInfo.frameWidth), height: CGFloat(fpInfo.frameHeight)
                )
                return FloatingPane(
                    pane: pane,
                    frame: frame,
                    isVisible: fpInfo.isVisible,
                    zIndex: Int(fpInfo.zIndex),
                    isPinned: fpInfo.isPinned,
                    title: fpInfo.title
                )
            }
            return TerminalTab(
                id: tabInfo.id.uuid,
                title: tabInfo.title,
                paneTree: buildLocalPaneNode(from: tabInfo.layout, contexts: contexts),
                floatingPanes: floatingPanes,
                focusedPaneID: tabInfo.focusedPaneID?.uuid
            )
        }
        return TerminalSession(
            id: info.id.uuid,
            name: info.name,
            tabs: tabs,
            activeTabIndex: info.activeTabIndex,
            source: .local
        )
    }

    private func buildLocalPaneNode(from layout: LayoutTree, contexts: [PaneID: PersistedPaneContext]) -> PaneNode {
        switch layout {
        case .leaf(let paneID):
            let pane = TerminalPane(
                id: paneID.uuid,
                initialWorkingDirectory: contexts[paneID]?.cwd
            )
            return .leaf(pane)
        case .split(let direction, let ratio, let first, let second):
            return .split(
                direction: direction,
                ratio: CGFloat(ratio),
                first: buildLocalPaneNode(from: first, contexts: contexts),
                second: buildLocalPaneNode(from: second, contexts: contexts)
            )
        }
    }

    private func scheduleLocalSaveIfNeeded(sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }), !session.isAnonymous else { return }
        scheduleLocalSave(sessionID: sessionID)
    }

    private func scheduleLocalSave(sessionID: UUID) {
        pendingLocalSavesLock.lock()
        pendingLocalSaves[sessionID]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushLocalSave(sessionID: sessionID)
        }
        pendingLocalSaves[sessionID] = workItem
        pendingLocalSavesLock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func cancelPendingLocalSave(sessionID: UUID) {
        pendingLocalSavesLock.lock()
        pendingLocalSaves.removeValue(forKey: sessionID)?.cancel()
        pendingLocalSavesLock.unlock()
    }

    func flushPendingLocalSaves() {
        let ids: [UUID]
        pendingLocalSavesLock.lock()
        ids = Array(pendingLocalSaves.keys)
        pendingLocalSaves.removeAll()
        pendingLocalSavesLock.unlock()
        for id in ids {
            flushLocalSave(sessionID: id)
        }
    }

    private func flushLocalSave(sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID && $0.source == .local && !$0.isAnonymous }) else {
            localSessionStore.delete(sessionID: SessionID(sessionID))
            return
        }
        let info = session.toSessionInfo()
        var contexts: [PaneID: PersistedPaneContext] = [:]
        for tab in session.tabs {
            for pane in tab.paneTree.allPanes {
                let cwd = localControllers[pane.id]?.currentWorkingDirectory
                    ?? pane.initialWorkingDirectory
                    ?? ""
                contexts[PaneID(pane.id)] = PersistedPaneContext(cwd: cwd)
            }
            for fp in tab.floatingPanes {
                let cwd = localControllers[fp.pane.id]?.currentWorkingDirectory
                    ?? fp.pane.initialWorkingDirectory
                    ?? ""
                contexts[PaneID(fp.pane.id)] = PersistedPaneContext(cwd: cwd)
            }
        }
        let persisted = PersistedSession(sessionInfo: info, paneContexts: contexts)
        localSessionStore.save(persisted)
    }

    // MARK: - Local Session Attach / Detach

    func attachLocalSession(sessionID: UUID) {
        attachedLocalSessionIDs.insert(sessionID)
        rebuildAllAttachedSessionIDs()
        moveSessionToBottomOfAttachedGroup(sessionID: sessionID)
        if let session = sessions.first(where: { $0.id == sessionID }) {
            for paneID in session.allPaneIDs {
                let controller = ensureLocalController(for: paneID)
                controller.forceFullRedraw()
            }
        }
    }

    func detachLocalSession(sessionID: UUID) {
        attachedLocalSessionIDs.remove(sessionID)
        rebuildAllAttachedSessionIDs()
    }

    /// Get or create a local TerminalController for a pane.
    func ensureLocalController(for paneID: UUID) -> TerminalController {
        if let existing = localControllers[paneID] {
            return existing
        }
        var cwd: String?
        // Fast path: search active session first.
        if let session = activeSession, session.source == .local {
            cwd = findWorkingDirectory(for: paneID, in: session)
        }
        // Fallback: search all local sessions.
        if cwd == nil {
            for session in sessions where session.source == .local {
                cwd = findWorkingDirectory(for: paneID, in: session)
                if cwd != nil { break }
            }
        }
        let controller = TerminalController(columns: 80, rows: 24)
        controller.start(workingDirectory: cwd)
        localControllers[paneID] = controller
        return controller
    }

    private func findWorkingDirectory(for paneID: UUID, in session: TerminalSession) -> String? {
        for tab in session.tabs {
            if let pane = tab.paneTree.findPane(id: paneID) {
                return pane.initialWorkingDirectory
            }
            if let fp = tab.floatingPanes.first(where: { $0.pane.id == paneID }) {
                return fp.pane.initialWorkingDirectory
            }
        }
        return nil
    }

    // MARK: - Overlay Stack

    func activeController(for paneID: UUID) -> (any TerminalControlling)? {
        if let overlay = overlayStacks[paneID]?.last {
            return overlay
        }
        if let controller = controller(for: paneID) {
            return controller
        }
        for session in sessions where session.source == .local {
            if session.hasPane(id: paneID) {
                return ensureLocalController(for: paneID)
            }
        }
        return nil
    }

    private func resolvedUserShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func resolveCommandPath(_ command: String, workingDirectory: String?) async -> String {
        let command = (command as NSString).expandingTildeInPath
        guard !command.contains("/") else { return command }
        let shell = resolvedUserShell()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "which \(shellEscape(command))"]
        if let cwd = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    continuation.resume(returning: path)
                } else {
                    continuation.resume(returning: command)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: command)
            }
        }
    }

    private func wrapCommandInLoginShell(_ command: String, arguments: [String]) -> (command: String, arguments: [String]) {
        let shell = resolvedUserShell()
        let parts = [command] + arguments
        let escaped = parts.map(shellEscape).joined(separator: " ")
        return (shell, ["-l", "-c", "exec \(escaped)"])
    }

    func runInPlace(at paneID: UUID, command: String, arguments: [String] = []) async {
        // Remote pane: forward to daemon.
        if let remote = remoteControllers[paneID] {
            remoteClient?.runInPlace(
                sessionID: remote.sessionID,
                paneID: remote.paneID,
                command: command,
                arguments: arguments
            )
            return
        }

        // Local pane: overlay stack.
        guard let active = activeController(for: paneID) as? TerminalController else { return }
        active.suspend()

        let resolvedCommand = await resolveCommandPath(command, workingDirectory: active.currentWorkingDirectory)
        let wrapped = wrapCommandInLoginShell(resolvedCommand, arguments: arguments)

        let dims = active.dimensions
        let controller = TerminalController(columns: dims.columns, rows: dims.rows)
        controller.start(workingDirectory: active.currentWorkingDirectory, command: wrapped.command, arguments: wrapped.arguments)

        controller.onProcessExited = { [weak self] _ in
            self?.restoreFromInPlace(at: paneID)
        }

        overlayStacks[paneID, default: []].append(controller)
    }

    /// Run a command, optionally in a floating pane.
    /// Returns the new floating pane ID when `showInPane` is true and a local pane was created.
    /// Remote floating panes are focused via `onRemoteLayoutChanged` instead.
    @discardableResult
    func runCommand(at paneID: UUID, command: String, arguments: [String] = [], options: CommandOptions = .empty) async -> UUID? {
        guard sessions.indices.contains(activeSessionIndex) else { return nil }
        let isRemote = sessions[activeSessionIndex].source.serverSessionID != nil

        // always_local forces local execution regardless of session type.
        let forceLocal = options.alwaysLocal

        // Check if the command is allowed in the current session type.
        if !forceLocal {
            guard (isRemote && options.runsRemote) || (!isRemote && options.runsLocal) else { return nil }
        }

        if options.showInPane {
            if forceLocal || !isRemote {
                // Local floating pane — get cwd from whichever controller owns this pane.
                let cwd = activeController(for: paneID)?.currentWorkingDirectory
                let resolvedCommand = await resolveCommandPath(command, workingDirectory: cwd)
                let wrapped = wrapCommandInLoginShell(resolvedCommand, arguments: arguments)
                return createFloatingPaneWithCommand(workingDirectory: cwd, command: wrapped.command, arguments: wrapped.arguments, closeOnExit: options.closeOnExit, customFrame: options.paneFrame)
            } else {
                await runCommandInFloatingPane(at: paneID, command: command, arguments: arguments, closeOnExit: options.closeOnExit, customFrame: options.paneFrame)
            }
            return nil
        }

        if isRemote && !forceLocal {
            guard let remote = remoteControllers[paneID] else { return nil }
            remoteClient?.runRemoteCommand(
                sessionID: remote.sessionID,
                paneID: remote.paneID,
                command: command,
                arguments: arguments
            )
        } else {
            let cwd = activeController(for: paneID)?.currentWorkingDirectory
            let resolvedCommand = await resolveCommandPath(command, workingDirectory: cwd)
            let wrapped = wrapCommandInLoginShell(resolvedCommand, arguments: arguments)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: wrapped.command)
            process.arguments = wrapped.arguments
            if let cwd {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
        return nil
    }

    /// Run a command in a new floating pane. Output is visible; ESC closes after exit.
    /// Automatically uses the remote or local path based on the active session.
    private func runCommandInFloatingPane(at paneID: UUID, command: String, arguments: [String], closeOnExit: Bool, customFrame: CGRect? = nil) async {
        guard sessions.indices.contains(activeSessionIndex) else { return }
        let session = sessions[activeSessionIndex]

        if let serverSessionID = session.source.serverSessionID {
            guard let tabIDs = serverTabIDs[session.id],
                  tabIDs.indices.contains(session.activeTabIndex) else { return }
            pendingRemoteCommandInfos.append(FloatingPaneCommandInfo(
                command: command, arguments: arguments,
                workingDirectory: nil, closeOnExit: closeOnExit
            ))
            remoteClient?.createFloatingPaneWithCommand(
                sessionID: SessionID(serverSessionID),
                tabID: tabIDs[session.activeTabIndex],
                command: command,
                arguments: arguments,
                frameX: customFrame.map { Float($0.origin.x) },
                frameY: customFrame.map { Float($0.origin.y) },
                frameWidth: customFrame.map { Float($0.width) },
                frameHeight: customFrame.map { Float($0.height) }
            )
        } else {
            guard let active = activeController(for: paneID) as? TerminalController else { return }
            let cwd = active.currentWorkingDirectory
            let resolvedCommand = await resolveCommandPath(command, workingDirectory: cwd)
            let wrapped = wrapCommandInLoginShell(resolvedCommand, arguments: arguments)
            createFloatingPaneWithCommand(workingDirectory: cwd, command: wrapped.command, arguments: wrapped.arguments, closeOnExit: closeOnExit, customFrame: customFrame)
        }
    }

    /// Create a local floating pane that runs a command directly (no shell spawned first).
    @discardableResult
    private func createFloatingPaneWithCommand(workingDirectory: String?, command: String, arguments: [String], closeOnExit: Bool, customFrame: CGRect? = nil) -> UUID? {
        guard sessions.indices.contains(activeSessionIndex),
              sessions[activeSessionIndex].tabs.indices.contains(
                  sessions[activeSessionIndex].activeTabIndex) else { return nil }

        let session = sessions[activeSessionIndex]
        let pane = TerminalPane(initialWorkingDirectory: workingDirectory)
        let frame = customFrame ?? activeFloatingPanes.nextCascadedFrame()
        let floating = FloatingPane(pane: pane, frame: frame, zIndex: activeFloatingPanes.nextZIndex)
        activeFloatingPanes.append(floating)

        floatingPaneCommands[pane.id] = FloatingPaneCommandInfo(
            command: command, arguments: arguments,
            workingDirectory: workingDirectory, closeOnExit: closeOnExit
        )

        let controller = TerminalController(columns: 80, rows: 24)
        controller.start(workingDirectory: workingDirectory, command: command, arguments: arguments)
        localControllers[pane.id] = controller

        scheduleLocalSaveIfNeeded(sessionID: session.id)
        return pane.id
    }

    /// Re-run the command in an exited floating pane.
    /// For local panes: replaces the controller and returns it.
    /// For remote panes: sends a restart request to the server and returns nil.
    @discardableResult
    func rerunFloatingPaneCommand(paneID: UUID) -> (any TerminalControlling)? {
        guard let cmdInfo = floatingPaneCommands[paneID] else { return nil }
        exitedFloatingPanes.removeValue(forKey: paneID)

        // Remote pane: send restart to server.
        if let remote = remoteControllers[paneID] {
            remoteClient?.restartFloatingPaneCommand(
                sessionID: remote.sessionID,
                paneID: remote.paneID,
                command: cmdInfo.command,
                arguments: cmdInfo.arguments
            )
            return nil
        }

        // Local pane: replace the controller.
        localControllers[paneID]?.stop()
        let controller = TerminalController(columns: 80, rows: 24)
        controller.start(
            workingDirectory: cmdInfo.workingDirectory,
            command: cmdInfo.command,
            arguments: cmdInfo.arguments
        )
        localControllers[paneID] = controller
        return controller
    }

    func restoreFromInPlace(at paneID: UUID) {
        guard var stack = overlayStacks[paneID], !stack.isEmpty else { return }
        stack.removeLast().stop()
        if !stack.isEmpty {
            overlayStacks[paneID] = stack
        } else {
            overlayStacks.removeValue(forKey: paneID)
        }
        if let active = activeController(for: paneID) as? TerminalController {
            active.resume()
            active.forceFullRedraw()
        }
    }

    private func stopAllControllers(for paneID: UUID) {
        overlayStacks.removeValue(forKey: paneID)?.forEach { $0.stop() }
        localControllers.removeValue(forKey: paneID)?.stop()
    }

    /// Look up a controller for any pane (local or remote).
    func controller(for paneID: UUID) -> (any TerminalControlling)? {
        if let local = localControllers[paneID] {
            return local
        }
        return remoteControllers[paneID]
    }
}

// MARK: - TerminalSession + SessionInfo Conversion

extension TerminalSession {
    func toSessionInfo() -> SessionInfo {
        let tabInfos = tabs.map { tab in
            TabInfo(
                id: TabID(tab.id),
                title: tab.title,
                layout: LayoutTree(from: tab.paneTree),
                floatingPanes: tab.floatingPanes.map { fp in
                    FloatingPaneInfo(
                        paneID: PaneID(fp.pane.id),
                        frameX: Float(fp.frame.origin.x),
                        frameY: Float(fp.frame.origin.y),
                        frameWidth: Float(fp.frame.width),
                        frameHeight: Float(fp.frame.height),
                        zIndex: Int32(fp.zIndex),
                        isPinned: fp.isPinned,
                        isVisible: fp.isVisible,
                        title: fp.title
                    )
                },
                focusedPaneID: tab.focusedPaneID.map(PaneID.init)
            )
        }
        return SessionInfo(
            id: SessionID(id),
            name: name,
            tabs: tabInfos,
            activeTabIndex: activeTabIndex
        )
    }
}
