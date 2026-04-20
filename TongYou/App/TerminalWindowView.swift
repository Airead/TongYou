import SwiftUI
import TYClient
import TYConfig
import TYProtocol
import TYTerminal

/// Root view for a terminal window, managing sessions, tabs, and panes.
///
/// Structure:
/// ```
/// TerminalWindowView
///   +-- HStack
///       +-- SessionSidebarView (visible when session count > 1, or toggled)
///       +-- VStack
///           +-- TabBarView (visible when tab count > 1, or configured)
///           +-- ZStack
///               +-- PaneSplitView (active tab's pane tree)
///               +-- FloatingPaneOverlay (floating panes sorted by z-order)
/// ```
struct TerminalWindowView: View {

    @State private var sessionManager: SessionManager
    @State private var tabBarVisibility: TabBarVisibility = .auto
    @State private var focusManager = FocusManager()
    @State private var paneSelectionManager = PaneSelectionManager()
    @State private var toastPresenter = ToastPresenter()
    @State private var windowBackgroundColor: NSColor = .black
    @State private var sidebarVisibility: SidebarVisibility = .auto
    @State private var suppressAutoSidebar = true
    @State private var showingSessionPicker = false
    @State private var renamingSessionIndex: Int?
    @State private var commandPalette = CommandPaletteController()
    /// Shared `SSHLauncher` for the command palette's SSH scope. Built once
    /// per window so the history and on-disk rule / ssh_config state stay
    /// in sync across palette opens. Wired in `init` because it needs
    /// closures that reference the `sessionManager`.
    @State private var sshLauncher: SSHLauncher
    @State private var sshHistory = SSHHistory()

    /// IDs of panes whose in-pane search bar is currently open. Updated via
    /// `MetalView.onSearchBarToggled`. Consumed by `zoomedPaneView` to hide
    /// the zoom badge while search is active (would otherwise overlap).
    @State private var searchActivePaneIDs: Set<UUID> = []

    /// Stores MetalView instances outside of SwiftUI state so that
    /// NSViewRepresentable.makeNSView can read/write without triggering
    /// "Modifying state during view update" warnings.
    @State private var viewStore = MetalViewStore()

    @State private var notificationStore = NotificationStore.shared

    /// Loads config + profiles. Owned here and shared with SessionManager
    /// (for startup resolution) and every MetalView (for live-field rendering
    /// + hot reload).
    @State private var configLoader: ConfigLoader

    @MainActor
    init() {
        let loader = ConfigLoader()
        _configLoader = State(initialValue: loader)
        let manager = SessionManager(profileLoader: loader.profileLoader)
        _sessionManager = State(initialValue: manager)
        let history = SSHHistory()
        _sshHistory = State(initialValue: history)
        _sshLauncher = State(initialValue: SSHLauncher(
            history: history,
            validateProfile: { [weak manager] templateID, vars in
                try manager?.tryResolveProfile(id: templateID, variables: vars)
            },
            spawn: { [weak manager] templateID, vars, placement in
                guard let manager else { return nil }
                return try Self.spawnSSH(
                    manager: manager,
                    templateID: templateID,
                    variables: vars,
                    placement: placement
                )
            }
        ))
    }

    /// Launch an SSH session with the resolved template + variables at the
    /// requested placement. Returns the new pane's UUID when the underlying
    /// SessionManager call exposes one synchronously (local sessions), nil
    /// for remote sessions (server allocates asynchronously via
    /// layoutUpdate) or when the split target could not be resolved.
    /// Split into a static helper so `init` can capture it without
    /// touching `self` (which is a struct; @State isn't initialised yet at
    /// closure-capture time).
    @MainActor
    private static func spawnSSH(
        manager: SessionManager,
        templateID: String,
        variables: [String: String],
        placement: SSHPlacement
    ) throws -> UUID? {
        switch placement {
        case .newTab:
            return manager.createTab(
                profileID: templateID,
                variables: variables
            )
        case .splitRight(let parent), .currentTab(let parent):
            return manager.splitPane(
                parentPaneID: parent,
                direction: .vertical,
                profileID: templateID,
                variables: variables
            )
        case .splitBelow(let parent):
            return manager.splitPane(
                parentPaneID: parent,
                direction: .horizontal,
                profileID: templateID,
                variables: variables
            )
        case .floatPane:
            return manager.createFloatingPane(
                profileID: templateID,
                variables: variables
            )
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if shouldShowSidebar {
                SessionSidebarView(
                    sessions: sessionManager.sessions,
                    activeSessionIndex: sessionManager.activeSessionIndex,
                    attachedSessionIDs: sessionManager.allAttachedSessionIDs,
                    sessionUnreadCounts: notificationStore.unreadCountBySessionID,
                    themeForeground: configLoader.config.foreground,
                    themeBackground: configLoader.config.background,
                    onSelect: { index in
                        switchToSession(at: index)
                    },
                    onClose: { index in
                        closeSession(at: index)
                    },
                    onNew: {
                        createNewSession()
                    },
                    onRenameRequest: { index in
                        startRenamingSession(at: index)
                    },
                    onAttach: { index in
                        attachSessionAtIndex(index)
                    },
                    onDetach: { index in
                        detachSessionAtIndex(index)
                    },
                    onDoubleClick: { index in
                        handleSidebarDoubleClick(index)
                    },
                    onMoveSession: { from, to in
                        sessionManager.moveSession(from: from, to: to)
                    }
                )

                Divider()
            }

            VStack(spacing: 0) {
                if shouldShowTabBar {
                    TabBarView(
                        tabs: sessionManager.tabs,
                        activeTabIndex: sessionManager.activeTabIndex,
                        tabUnreadCounts: notificationStore.unreadCountByTabID,
                        onSelect: { index in
                            switchToTab(at: index)
                        },
                        onClose: { index in
                            closeTab(at: index)
                        },
                        onNew: {
                            createNewTab()
                        },
                        onMove: { from, to in
                            sessionManager.moveTab(from: from, to: to)
                        }
                    )
                }

                if case .detached = sessionManager.activeSessionDisplayState {
                    DetachedSessionPlaceholderView(
                        sessionName: sessionManager.activeSession?.name ?? "Session",
                        isPending: false,
                        keybindings: configLoader.config.keybindings,
                        themeForeground: configLoader.config.foreground,
                        themeBackground: configLoader.config.background,
                        onAttach: {
                            attachSessionAtIndex(sessionManager.activeSessionIndex)
                        },
                        onTabAction: handleTabAction
                    )
                    .id(sessionManager.activeSession?.id)
                } else if case .pendingAttach = sessionManager.activeSessionDisplayState {
                    DetachedSessionPlaceholderView(
                        sessionName: sessionManager.activeSession?.name ?? "Session",
                        isPending: true,
                        keybindings: configLoader.config.keybindings,
                        themeForeground: configLoader.config.foreground,
                        themeBackground: configLoader.config.background,
                        onAttach: {},
                        onTabAction: handleTabAction
                    )
                    .id(sessionManager.activeSession?.id)
                } else if let activeTab = sessionManager.activeTab {
                    paneContent(for: activeTab)
                        .id(activeTab.id)
                }
            }
        }
        .overlay {
            modalOverlays
        }
        .background(WindowConfigurator(
            backgroundColor: windowBackgroundColor,
            title: windowTitle,
            onWindowClose: { [sessionManager, configLoader] in
                sessionManager.disconnectFromTYD()
                sessionManager.flushPendingLocalSaves()
                // Break retain cycles to allow full deallocation.
                configLoader.onConfigChanged = nil
                sessionManager.onRemoteDetached = nil
                sessionManager.onRemoteSessionEmpty = nil
                sessionManager.onRemoteLayoutChanged = nil
                sessionManager.onSessionClosed = nil
                sessionManager.onFocusPaneRequest = nil
            }
        ))
        .overlay {
            ToastOverlay(presenter: toastPresenter)
        }
        .environment(\.toastPresenter, toastPresenter)
        .onAppear {
            focusManager.attachViewStore(viewStore)
            sessionManager.attachPaneSelectionManager(paneSelectionManager)
            sessionManager.restoreLocalSessions()
            loadWindowBackground()
            if configLoader.config.draftEnabled || sessionManager.tabs.isEmpty {
                sessionManager.createAnonymousSession()
            }
            focusActiveTabRootPane()
            wireRemoteLayoutCallback()
            sessionManager.onFocusPaneRequest = { [focusManager] paneID in
                focusManager.focusPane(id: paneID)
            }
            if configLoader.config.autoConnectDaemon {
                sessionManager.ensureConnected {}
            }
        }
        .onChange(of: focusManager.focusedPaneID) { _, newID in
            sessionManager.updateFloatingPanesVisibilityForFocus(focusedPaneID: newID)
            if let paneID = newID {
                sessionManager.notifyPaneFocused(paneID)
                notificationStore.markRead(paneID: paneID)
            }
            for (paneID, view) in viewStore.allViews {
                let shouldShow = notificationStore.unreadPaneIDs.contains(paneID) && paneID != newID
                view.setNotificationRing(visible: shouldShow)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let paneID = focusManager.focusedPaneID {
                notificationStore.markRead(paneID: paneID)
            }
            sessionManager.reportWindowActiveChanged(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            sessionManager.reportWindowActiveChanged(false)
        }
        .onChange(of: notificationStore.unreadPaneIDs) { _, newIDs in
            for (paneID, view) in viewStore.allViews {
                let shouldShow = newIDs.contains(paneID) && paneID != focusManager.focusedPaneID
                view.setNotificationRing(visible: shouldShow)
            }
        }
    }

    /// All modal overlays (session picker, rename, daemon connecting, command
    /// palette). Extracted out of `body` because inlining the chain exceeds
    /// SwiftUI's type-checking budget.
    @ViewBuilder
    private var modalOverlays: some View {
        if showingSessionPicker {
            modalOverlay(onDismiss: { showingSessionPicker = false }) {
                SessionPickerView(
                    sessions: sessionManager.sessions,
                    activeSessionIndex: sessionManager.activeSessionIndex,
                    attachedSessionIDs: sessionManager.allAttachedSessionIDs,
                    onSelect: { index in switchToSessionFromPicker(at: index) },
                    onDismiss: { showingSessionPicker = false },
                    themeForeground: configLoader.config.foreground,
                    themeBackground: configLoader.config.background
                )
            }
        }

        if let index = renamingSessionIndex,
           sessionManager.sessions.indices.contains(index) {
            modalOverlay(onDismiss: { dismissRenamePanel() }) {
                SessionRenameView(
                    currentName: sessionManager.sessions[index].name,
                    onConfirm: { newName in sessionManager.renameSession(at: index, to: newName) },
                    onDismiss: { dismissRenamePanel() }
                )
            }
        }

        if sessionManager.connectionStatus != .idle {
            DaemonConnectingOverlayView(
                status: sessionManager.connectionStatus,
                onDismiss: { sessionManager.dismissConnectionStatus() }
            )
        }

        if commandPalette.isOpen {
            modalOverlay(onDismiss: { dismissCommandPalette() }) {
                CommandPaletteView(
                    controller: commandPalette,
                    themeForeground: configLoader.config.foreground,
                    themeBackground: configLoader.config.background,
                    onCommit: { mode in handlePaletteCommit(mode: mode) },
                    onDismiss: { dismissCommandPalette() }
                )
            }
        }
    }

    /// Single close path for the command palette. Restores first-responder
    /// focus to the active tab's last-focused pane so keystrokes land on
    /// the terminal immediately after the overlay goes away. Callers that
    /// spawn a fresh pane (SSH commit) should *not* use this — the new
    /// pane is focused by the commit path itself.
    private func dismissCommandPalette() {
        commandPalette.close()
        restoreTabFocusedPane()
    }

    /// Dispatch a palette commit. Phase 6 handles the SSH scope's single-row
    /// commit for the four Enter variants; Phase 7 adds a batch path for
    /// multi-select. Other scopes fall through to a simple close (Phase 8).
    private func handlePaletteCommit(mode: PaletteEnterMode) {
        guard let committed = commandPalette.commit(mode: mode) else {
            dismissCommandPalette()
            return
        }
        switch commandPalette.scope {
        case .ssh:
            handleSSHCommit(rows: committed.rows, mode: mode)
        case .session:
            handleSessionCommit(rows: committed.rows, mode: mode)
        case .profile:
            handleProfileCommit(rows: committed.rows, mode: mode)
        case .command:
            handleCommandCommit(rows: committed.rows)
        case .tab:
            // Tab scope is still a placeholder — the rewire path leaves
            // `tabCandidates` empty so this branch is unreachable for now.
            dismissCommandPalette()
        }
    }

    /// Profile-scope commit. Mirrors the SSH four-Enter mapping: plain
    /// Enter opens a new tab with the chosen profile; ⌘Enter splits the
    /// focused pane to the right, ⇧Enter splits below, ⌥Enter opens a
    /// floating pane. Profiles are non-SSH so we pass an empty variables
    /// dict — the profile is responsible for having a self-contained
    /// command.
    private func handleProfileCommit(rows: [PaletteRow], mode: PaletteEnterMode) {
        guard let profileID = rows.first?.candidate.profileID else {
            dismissCommandPalette()
            return
        }
        commandPalette.close()
        switch mode {
        case .plain:
            _ = sessionManager.createTab(profileID: profileID, variables: [:])
        case .commandEnter:
            if let parent = focusManager.focusedPaneID {
                _ = sessionManager.splitPane(
                    parentPaneID: parent, direction: .vertical,
                    profileID: profileID, variables: [:]
                )
            } else {
                _ = sessionManager.createTab(profileID: profileID, variables: [:])
            }
        case .shiftEnter:
            if let parent = focusManager.focusedPaneID {
                _ = sessionManager.splitPane(
                    parentPaneID: parent, direction: .horizontal,
                    profileID: profileID, variables: [:]
                )
            } else {
                _ = sessionManager.createTab(profileID: profileID, variables: [:])
            }
        case .optionEnter:
            _ = sessionManager.createFloatingPane(profileID: profileID, variables: [:])
        }
    }

    /// Command-scope commit. Plain Enter only — modifiers have no meaning
    /// in this scope and are ignored. Closes the palette first so the
    /// dispatched action doesn't fight the overlay for first responder.
    /// Only actions that map to a `TabAction` can be committed here; the
    /// candidate builder filters the list to exactly those, so this
    /// guard exists only as a belt-and-braces runtime check.
    private func handleCommandCommit(rows: [PaletteRow]) {
        guard let action = rows.first?.candidate.commandAction,
              let tabAction = action.tabAction else {
            dismissCommandPalette()
            return
        }
        dismissCommandPalette()
        handleTabAction(tabAction)
    }

    /// SSH scope commit. With a single row, Phase 6's four Enter variants
    /// dispatch to new tab / split-right / split-below / float. With
    /// multiple rows (Tab-multi-select), Phase 7 always runs the chained
    /// right-split column regardless of modifier — the other variants are
    /// reserved for future phases.
    private func handleSSHCommit(rows: [PaletteRow], mode: PaletteEnterMode) {
        let resolutions = rows.compactMap { $0.candidate.sshResolution }
        guard !resolutions.isEmpty else {
            dismissCommandPalette()
            return
        }
        // The spawn path focuses the freshly created pane itself, so this
        // close deliberately skips `dismissCommandPalette`'s focus-restore
        // to avoid fighting with the new pane for first responder.
        commandPalette.close()
        if resolutions.count == 1 {
            handleSingleSSHCommit(resolution: resolutions[0], mode: mode)
        } else {
            handleBatchSSHCommit(resolutions: resolutions)
        }
    }

    /// Phase 6 single-row path. Split variants require a parent pane; when
    /// no pane is focused we degrade to `newTab` so Enter is never a no-op
    /// after typing a host.
    private func handleSingleSSHCommit(resolution: SSHResolution, mode: PaletteEnterMode) {
        let placement = sshPlacement(for: mode)
        Task { @MainActor in
            do {
                try await sshLauncher.commit(
                    resolution: resolution,
                    placement: placement
                )
                rewirePaletteForSSH()
            } catch let err as SSHLauncherError {
                toastPresenter.show("SSH: \(err.localizedDescription)")
            } catch {
                toastPresenter.show("SSH: \(error.localizedDescription)")
            }
        }
    }

    /// Batch path. Opens every `resolution` in a brand-new tab, arranged
    /// as a canonical grid in one shot — SessionManager builds the tree
    /// before SwiftUI lays panes out, so every PTY sees exactly one
    /// resize instead of one per intermediate split. Fails fast on the
    /// first unresolvable profile and does **not** open any panes in that
    /// case (toast only). Focus lands on the first pane of the new tab.
    private func handleBatchSSHCommit(resolutions: [SSHResolution]) {
        switch sshLauncher.validateBatch(resolutions: resolutions) {
        case .failure(let failure):
            toastPresenter.show(
                "SSH: \"\(failure.target)\": \(failure.error.localizedDescription)"
            )
            return
        case .success(let resolved):
            let requests = resolved.map { resolution in
                SessionManager.GridPaneRequest(
                    profileID: resolution.templateID,
                    variables: resolution.variables
                )
            }
            let createdTabID = sessionManager.createTabWithGridPanes(
                requests: requests
            )
            Task { @MainActor in
                await sshLauncher.recordBatchHistory(resolutions: resolved)
                rewirePaletteForSSH()
                // Local sessions: focus the first pane of the new tab
                // (canonicalGridTree's row-major order) so the user lands
                // on the top-left terminal. Remote sessions return nil —
                // the server broadcasts a layoutUpdate that lights up
                // the new tab and restores focus naturally.
                if let tabID = createdTabID,
                   let tab = sessionManager.tabs.first(where: { $0.id == tabID }),
                   let firstPaneID = tab.paneTree.allPaneIDs.first {
                    focusManager.focusPane(id: firstPaneID)
                }
            }
        }
    }

    // MARK: - Session-scope commit (Phase 8)

    /// Decision surface for a session-scope palette commit. Pure so tests
    /// can cover the modifier-to-action mapping without spinning up a
    /// real window / SessionManager.
    enum SessionCommitAction: Equatable {
        /// Activate the session whose UUID matches. The palette stuffs
        /// the session id into the candidate's own `id` field when
        /// building session rows (session ids are already unique +
        /// stable).
        case activate(sessionID: UUID)
        /// The modifier is not meaningful for sessions (no split / float
        /// semantics). Caller should toast + close.
        case notApplicable
    }

    /// Map a committed palette row + modifier to a session-scope action.
    /// Plain Enter activates; any modifier is a no-op. Kept static so the
    /// test does not need to construct a full view.
    static func sessionCommitAction(
        for row: PaletteRow,
        mode: PaletteEnterMode
    ) -> SessionCommitAction {
        switch mode {
        case .plain:
            return .activate(sessionID: row.candidate.id)
        case .commandEnter, .shiftEnter, .optionEnter:
            return .notApplicable
        }
    }

    /// Phase 8 session commit. Plain Enter flips `activeSessionIndex` to
    /// the matching session; if the session has been closed since the
    /// palette was populated, surface that quietly rather than silently
    /// doing nothing. Detached sessions are attached before switching so
    /// the user sees a live pane immediately — matching the quick-picker
    /// behaviour in `switchToSessionFromPicker`.
    private func handleSessionCommit(rows: [PaletteRow], mode: PaletteEnterMode) {
        guard let row = rows.first else {
            dismissCommandPalette()
            return
        }
        dismissCommandPalette()
        switch Self.sessionCommitAction(for: row, mode: mode) {
        case .activate(let sessionID):
            guard let index = sessionManager.sessions.firstIndex(
                where: { $0.id == sessionID }
            ) else {
                toastPresenter.show("Session: \"\(row.candidate.primaryText)\" is no longer open")
                return
            }
            if sessionManager.isSessionDetached(at: index) {
                attachSessionAtIndex(index)
            } else {
                switchToSession(at: index)
            }
        case .notApplicable:
            toastPresenter.show("Session scope: only Enter is supported (no split / float)")
        }
    }

    /// Handle a ⌘⌫ inside the SSH scope: drop every history record whose
    /// target matches, refresh the candidate list, and re-focus the
    /// palette input so the user can keep pruning. Silent no-op when the
    /// target has no history (ssh_config-only row) — the row stays
    /// because ssh_config is the source of truth, not ours.
    private func deleteSSHHistoryFromPalette(target: String) {
        Task { @MainActor in
            let dropped = await sshLauncher.deleteHistory(target: target)
            rewirePaletteForSSH()
            if dropped == 0 {
                toastPresenter.show("SSH: \"\(target)\" 没有历史记录可删除")
            }
            commandPalette.requestRefocusInput()
        }
    }

    /// Handle a ⌘⌫ inside the session scope: close the non-active session
    /// with the given id and refresh candidates. Refuses to close the
    /// currently active session — by design, palette delete must not
    /// yank the pane the user is actively driving.
    private func deleteSessionFromPalette(sessionID: UUID) {
        guard let index = sessionManager.sessions.firstIndex(where: { $0.id == sessionID }) else {
            rewirePaletteForSessions()
            commandPalette.requestRefocusInput()
            return
        }
        if index == sessionManager.activeSessionIndex {
            toastPresenter.show("Session: 当前激活的 session 不能从面板删除")
            commandPalette.requestRefocusInput()
            return
        }
        closeSession(at: index, pickNext: false)
        rewirePaletteForSessions()
        commandPalette.requestRefocusInput()
    }

    /// Map Enter + modifier to a Phase 6 placement. Split variants fall
    /// back to `newTab` when nothing is focused (e.g. a freshly launched
    /// window with only a zombie pane).
    private func sshPlacement(for mode: PaletteEnterMode) -> SSHPlacement {
        switch mode {
        case .plain:
            return .newTab
        case .commandEnter:
            if let parent = focusManager.focusedPaneID { return .splitRight(parentPaneID: parent) }
            return .newTab
        case .shiftEnter:
            if let parent = focusManager.focusedPaneID { return .splitBelow(parentPaneID: parent) }
            return .newTab
        case .optionEnter:
            return .floatPane
        }
    }

    /// Window title derived from the active tab's OSC title, falling back to session name.
    /// When multiple sessions exist, the session name is prepended for clarity.
    private var windowTitle: String {
        let baseTitle: String
        if let tab = sessionManager.activeTab, tab.title != TerminalTab.defaultTitle {
            baseTitle = tab.title
        } else {
            baseTitle = sessionManager.activeSession?.name ?? "TongYou"
        }

        if sessionManager.sessionCount > 1,
           let sessionName = sessionManager.activeSession?.name,
           !(sessionManager.activeSession?.isAnonymous ?? false) {
            return "\(sessionName) — \(baseTitle)"
        }
        return baseTitle
    }

    internal static func shouldShowSidebar(visibility: SidebarVisibility, sessionCount: Int, suppressAutoSidebar: Bool) -> Bool {
        switch visibility {
        case .auto: sessionCount > 1 && !suppressAutoSidebar
        case .always: true
        case .never: false
        }
    }

    private var shouldShowSidebar: Bool {
        Self.shouldShowSidebar(visibility: sidebarVisibility, sessionCount: sessionManager.sessionCount, suppressAutoSidebar: suppressAutoSidebar)
    }

    private var shouldShowTabBar: Bool {
        switch tabBarVisibility {
        case .auto: sessionManager.tabCount > 1
        case .always: true
        case .never: false
        }
    }

    @ViewBuilder
    private func paneContent(for activeTab: TerminalTab) -> some View {
        let paneFocusColor: Color = {
            if sessionManager.activeSession?.source.isRemote == true {
                return .blue
            } else if sessionManager.activeSession?.isAnonymous == true {
                return .gray
            } else {
                return .green
            }
        }()
        let updateTabTitle: (String) -> Void = { title in
            sessionManager.updateTitle(title, for: activeTab.id)
        }

        ZStack {
            // Zoom / monocle (plan §P4.1): render only the zoomed pane when
            // set and the ID still resolves in the tree. MetalView instances
            // for non-zoomed panes stay alive in `viewStore` — just detached
            // from the SwiftUI hierarchy, so their PTY sizes freeze until
            // zoom exits (`dismantleNSView` intentionally does not tear down).
            if let zoomedID = activeTab.zoomedPaneID,
               let zoomedPane = activeTab.paneTree.findPane(id: zoomedID) {
                let hiddenCount = max(0, activeTab.paneTree.allPaneIDs.count - 1)
                zoomedPaneView(
                    pane: zoomedPane,
                    tabID: activeTab.id,
                    focusColor: paneFocusColor,
                    updateTabTitle: updateTabTitle,
                    hiddenPaneCount: hiddenCount
                )
            } else {
                PaneSplitView(
                    node: activeTab.paneTree,
                    viewStore: viewStore,
                    focusManager: focusManager,
                    focusColor: paneFocusColor,
                    configLoader: configLoader,
                    controllerForPane: { paneID in
                        sessionManager.activeController(for: paneID)
                    },
                    onTabAction: handleTabAction,
                    onTitleChanged: updateTabTitle,
                    onNodeChanged: { newTree in
                        sessionManager.updateActivePaneTree(newTree)
                    },
                    onUserInteraction: { paneID in
                        notificationStore.markRead(paneID: paneID)
                    },
                    isTreePaneExited: { paneID in
                        sessionManager.exitedTreePanes[paneID] != nil
                    },
                    paneSelectionManager: paneSelectionManager,
                    tabID: activeTab.id
                )
            }

            FloatingPaneOverlay(
                floatingPanes: activeTab.floatingPanes,
                viewStore: viewStore,
                focusManager: focusManager,
                focusColor: paneFocusColor,
                configLoader: configLoader,
                controllerForPane: { paneID in
                    sessionManager.activeController(for: paneID)
                },
                onTabAction: handleTabAction,
                onTitleChanged: { paneID, title in
                    sessionManager.updateFloatingPaneTitle(paneID: paneID, title: title)
                },
                onFrameChanged: { paneID, frame in
                    sessionManager.updateFloatingPaneFrame(paneID: paneID, frame: frame)
                },
                onBringToFront: { paneID in
                    sessionManager.bringFloatingPaneToFront(paneID: paneID)
                },
                onClose: { paneID in
                    closeFloatingPane(id: paneID)
                },
                onTogglePin: { paneID in
                    sessionManager.toggleFloatingPanePin(paneID: paneID)
                },
                onUserInteraction: { paneID in
                    notificationStore.markRead(paneID: paneID)
                },
                isProcessExited: { paneID in
                    sessionManager.exitedFloatingPanes[paneID] != nil
                },
                paneSelectionManager: paneSelectionManager,
                tabID: activeTab.id
            )
        }
    }

    /// Full-tab rendering of a single zoomed pane. Mirrors `PaneSplitView`'s
    /// leaf branch so the visual treatment (focus border, callbacks) stays
    /// consistent. Adds a top-center badge (⛶ +N) indicating how many
    /// other panes are hidden behind the zoom — suppressed while the
    /// pane's search bar is open (would visually collide with the bar).
    @ViewBuilder
    private func zoomedPaneView(
        pane: TerminalPane,
        tabID: UUID,
        focusColor: Color,
        updateTabTitle: @escaping (String) -> Void,
        hiddenPaneCount: Int
    ) -> some View {
        let isFocused = focusManager.focusedPaneID == pane.id
        let showBadge = hiddenPaneCount > 0 && !searchActivePaneIDs.contains(pane.id)
        TerminalPaneContainerView(
            paneID: pane.id,
            profileID: pane.profileID,
            viewStore: viewStore,
            initialWorkingDirectory: pane.initialWorkingDirectory,
            configLoader: configLoader,
            externalController: sessionManager.activeController(for: pane.id),
            onTabAction: handleTabAction,
            onTitleChanged: updateTabTitle,
            onFocused: { focusManager.focusPane(id: pane.id) },
            onUserInteraction: { notificationStore.markRead(paneID: pane.id) },
            onToggleSelection: {
                paneSelectionManager.togglePane(pane.id, inTab: tabID)
            },
            isProcessExited: { sessionManager.exitedTreePanes[pane.id] != nil },
            onSearchBarToggled: { isOpen in
                if isOpen {
                    searchActivePaneIDs.insert(pane.id)
                } else {
                    searchActivePaneIDs.remove(pane.id)
                }
            }
        )
        .id(pane.id)
        .overlay(
            Rectangle()
                .stroke(focusColor, lineWidth: 1)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        )
        .modifier(PaneSelectionBorder(
            paneID: pane.id,
            tabID: tabID,
            selectionManager: paneSelectionManager
        ))
        .overlay(alignment: .top) {
            if showBadge {
                zoomBadgeLabel(hiddenPaneCount: hiddenPaneCount)
                    .padding(.top, 6)
            }
        }
    }

    /// Small translucent chip shown at the top-center of the zoomed pane.
    /// `hiddenPaneCount` is `tab.paneTree.allPaneIDs.count - 1`.
    @ViewBuilder
    private func zoomBadgeLabel(hiddenPaneCount: Int) -> some View {
        Text("⛶ +\(hiddenPaneCount)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
            .allowsHitTesting(false)
    }

    // MARK: - Session Operations

    private func createNewSession() {
        let cwd: String? = focusedPaneCWD
        sessionManager.createSession(initialWorkingDirectory: cwd)
        suppressAutoSidebar = false
        focusActiveTabRootPane()
    }

    private func closeSession(at index: Int, pickNext: Bool = false) {
        let wasAnonymous = sessionManager.sessions.indices.contains(index)
            ? sessionManager.sessions[index].isAnonymous
            : false
        let wasOnlyAttached = sessionManager.allAttachedSessionIDs.count == 1

        if sessionManager.sessions.indices.contains(index) {
            notificationStore.clearAll(forSessionID: sessionManager.sessions[index].id)
        }

        let paneIDs = sessionManager.closeSession(at: index)
        for paneID in paneIDs {
            viewStore.tearDown(for: paneID)
            focusManager.removeFromHistory(id: paneID)
            paneSelectionManager.didRemovePane(paneID)
        }

        if sessionManager.sessions.isEmpty {
            NSApp.keyWindow?.close()
            return
        }

        if pickNext {
            if wasAnonymous && wasOnlyAttached {
                NSApp.keyWindow?.close()
                return
            }
            pickNextSession()
        }

        focusActiveTabRootPane()
    }

    /// Select the first attached session, or fall back to the first session overall.
    private func pickNextSession() {
        if let attachedIndex = sessionManager.sessions.firstIndex(where: { sessionManager.allAttachedSessionIDs.contains($0.id) }) {
            sessionManager.selectSession(at: attachedIndex)
        } else {
            sessionManager.selectSession(at: 0)
        }
    }

    private func switchToSession(at index: Int) {
        sessionManager.selectSession(at: index)
        suppressAutoSidebar = false
        restoreTabFocusedPane()
    }

    private func toggleSidebar() {
        let currentlyVisible = shouldShowSidebar
        suppressAutoSidebar = false
        sidebarVisibility = currentlyVisible ? .never : .always
    }

    // MARK: - Tab Operations

    private func createNewTab() {
        let cwd: String? = focusedPaneCWD
        let tabID = sessionManager.createTab(initialWorkingDirectory: cwd)
        // Remote sessions return nil — focus happens when layoutUpdate arrives.
        if tabID != nil {
            focusActiveTabRootPane()
        }
    }

    private func closeTab(at index: Int) {
        guard sessionManager.tabs.indices.contains(index) else { return }

        // Remote session: just send to server; layoutUpdate handles the rest.
        if sessionManager.activeSession?.source.isRemote == true {
            sessionManager.closeTab(at: index)
            return
        }

        let tab = sessionManager.tabs[index]
        notificationStore.clearAll(forTabID: tab.id)

        // Tear down all MetalViews in this tab's pane tree and floating panes.
        for paneID in tab.allPaneIDsIncludingFloating {
            viewStore.tearDown(for: paneID)
        }

        paneSelectionManager.didRemoveTab(tab.id)
        sessionManager.closeTab(at: index)

        if sessionManager.tabCount == 0 {
            closeSession(at: sessionManager.activeSessionIndex, pickNext: true)
        } else {
            focusActiveTabRootPane()
        }
    }

    private func switchToTab(at index: Int) {
        sessionManager.selectTab(at: index)
        restoreTabFocusedPane()
    }

    // MARK: - Pane Operations

    private func splitPane(direction: SplitDirection) {
        guard let focusedID = focusManager.focusedPaneID else { return }
        let cwd = viewStore.view(for: focusedID)?.currentWorkingDirectory
        // Remote sessions return nil here — focus lands on the new pane
        // when the layoutUpdate materializes.
        guard let newPaneID = sessionManager.splitPane(
            parentPaneID: focusedID,
            direction: direction,
            initialWorkingDirectory: cwd
        ) else {
            return
        }
        focusManager.focusPane(id: newPaneID)
    }

    private func closePane() {
        guard let focusedID = focusManager.focusedPaneID else { return }
        forceClosePane(id: focusedID)
    }

    /// Resize the focused pane. Works for both tree panes (adjusts split ratio)
    /// and floating panes (scales frame around center).
    private func resizePane(delta: CGFloat) {
        guard let focusedID = focusManager.focusedPaneID,
              let activeTab = sessionManager.activeTab else { return }

        // Floating pane: scale width/height around center.
        if let floating = activeTab.floatingPanes.first(where: { $0.pane.id == focusedID }) {
            let scaleDelta: CGFloat = delta * 0.5  // 0.1 → ±0.05 per axis
            var frame = floating.frame
            frame.origin.x -= scaleDelta
            frame.origin.y -= scaleDelta
            frame.size.width += scaleDelta * 2
            frame.size.height += scaleDelta * 2
            sessionManager.updateFloatingPaneFrame(paneID: focusedID, frame: frame)
            return
        }

        // Tree pane: adjust parent split ratio.
        if let newTree = activeTab.paneTree.resizePane(id: focusedID, delta: delta) {
            sessionManager.updateActivePaneTree(newTree)
        }
    }

    /// Toggle zoom / monocle on the focused tree pane. Floating panes
    /// don't zoom — tmux parity — so requests from a floating pane fall
    /// through silently.
    private func toggleZoom() {
        guard let focusedID = focusManager.focusedPaneID,
              let activeTab = sessionManager.activeTab,
              activeTab.paneTree.contains(paneID: focusedID) else { return }
        sessionManager.toggleZoom(paneID: focusedID)
    }

    /// Change the layout strategy of the container that directly holds the
    /// focused tree pane (plan §P4.5). Floating panes and a sole root-leaf
    /// pane have no container to mutate, so requests from those contexts
    /// fall through silently.
    private func changeStrategy(to kind: LayoutStrategyKind) {
        guard let focusedID = focusManager.focusedPaneID,
              let activeTab = sessionManager.activeTab,
              activeTab.paneTree.contains(paneID: focusedID) else { return }
        sessionManager.changeStrategy(paneID: focusedID, newKind: kind)
    }

    /// Cycle the strategy of the focused pane's parent container through
    /// `LayoutEngine.userCycleableStrategies` (plan §P4.5).
    private func cycleStrategy(forward: Bool) {
        guard let focusedID = focusManager.focusedPaneID,
              let activeTab = sessionManager.activeTab,
              activeTab.paneTree.contains(paneID: focusedID) else { return }
        sessionManager.cycleStrategy(paneID: focusedID, forward: forward)
    }

    /// PTY process has just exited. Decide between keep-alive (zombie) and
    /// immediate tear-down based on the pane's `close-on-exit` setting.
    /// Routed from `.paneExited`.
    private func handlePTYExit(id paneID: UUID, exitCode: Int32) {
        // Floating pane: keep alive when the command opted into close-on-exit=false
        // or exited non-zero (so the user can read the failure output).
        if sessionManager.activeTab?.floatingPanes.contains(where: { $0.pane.id == paneID }) == true {
            if let cmdInfo = sessionManager.floatingPaneCommands[paneID],
               !(cmdInfo.closeOnExit && exitCode == 0) {
                // ESC closes, Enter re-runs the command.
                sessionManager.markFloatingPaneExited(paneID, exitCode: exitCode)
            } else {
                // No command info (e.g. shell) or clean exit with close-on-exit: tear down.
                closeFloatingPane(id: paneID)
            }
            return
        }

        // Tree pane with `close-on-exit = false`: keep the pane so the
        // user can still read the final output. ESC dismisses, Enter re-runs.
        // This check runs for both local and remote sessions; the remote
        // branch relies on the server surfacing `closeOnExit` in
        // `RemotePaneMetadata`, which the client mirrors onto the
        // value-type `TerminalPane.startupSnapshot`.
        if let pane = sessionManager.activeSession?.tabs
            .lazy
            .compactMap({ $0.paneTree.findPane(id: paneID) })
            .first,
           pane.startupSnapshot.closeOnExit == false {
            sessionManager.markTreePaneExited(paneID, exitCode: exitCode)
            return
        }

        // Remote session without close-on-exit=false: send to server;
        // layoutUpdate handles the rest.
        if sessionManager.activeSession?.source.isRemote == true {
            notificationStore.clearAll(forPaneID: paneID)
            sessionManager.closePane(id: paneID)
            return
        }

        forceClosePane(id: paneID)
    }

    /// Tear down a pane unconditionally. Used by user-initiated closes
    /// (Cmd+W, ESC on an exited pane, the floating-pane close button) — the
    /// close-on-exit keep-alive logic is intentionally bypassed here, since
    /// the user has already asked for the pane to go away.
    private func forceClosePane(id paneID: UUID) {
        // Floating pane: delegate to the existing helper, which always tears down.
        if sessionManager.activeTab?.floatingPanes.contains(where: { $0.pane.id == paneID }) == true {
            closeFloatingPane(id: paneID)
            return
        }

        // Remote session: just send to server; layoutUpdate handles the rest.
        if sessionManager.activeSession?.source.isRemote == true {
            notificationStore.clearAll(forPaneID: paneID)
            sessionManager.closePane(id: paneID)
            return
        }

        notificationStore.clearAll(forPaneID: paneID)
        viewStore.tearDown(for: paneID)
        focusManager.removeFromHistory(id: paneID)
        paneSelectionManager.didRemovePane(paneID)

        if let siblingID = sessionManager.closePane(id: paneID) {
            focusNextPane(fallback: siblingID)
        } else if sessionManager.tabCount == 0 {
            closeSession(at: sessionManager.activeSessionIndex, pickNext: true)
        } else if let activeTab = sessionManager.activeTab {
            focusManager.focusPane(id: activeTab.paneTree.firstPane.id)
        }
    }

    // MARK: - Floating Pane Operations

    private func createFloatingPane() {
        let cwd = focusedPaneCWD
        guard let paneID = sessionManager.createFloatingPane(initialWorkingDirectory: cwd) else {
            return
        }
        focusManager.focusPane(id: paneID)
    }

    /// Toggle floating panes visibility, or create one if none exist.
    private func toggleOrCreateFloatingPane() {
        guard let activeTab = sessionManager.activeTab else { return }
        if activeTab.floatingPanes.isEmpty {
            createFloatingPane()
            return
        }

        let floatingIDs = Set(activeTab.floatingPanes.map(\.pane.id))
        let isFocusingFloat = focusManager.focusedPaneID.map(floatingIDs.contains) ?? false

        if isFocusingFloat {
            // Currently on a floating pane -> hide and return to previous tree pane
            sessionManager.setFloatingPanesVisibility(visible: false)
            let treeIDs = Set(activeTab.allPaneIDs)
            let targetID = focusManager.previousFocusedPane(existingIn: treeIDs)
                ?? activeTab.paneTree.firstPane.id
            focusManager.focusPane(id: targetID)
        } else {
            // Currently on a tree pane -> show all and focus floating
            sessionManager.setFloatingPanesVisibility(visible: true)
            let targetID = focusManager.previousFocusedPane(existingIn: floatingIDs)
                ?? activeTab.floatingPanes.last?.pane.id
            if let id = targetID {
                focusManager.focusPane(id: id)
            }
        }
    }

    private func closeFloatingPane(id paneID: UUID) {
        notificationStore.clearAll(forPaneID: paneID)
        viewStore.tearDown(for: paneID)
        focusManager.removeFromHistory(id: paneID)
        paneSelectionManager.didRemovePane(paneID)
        sessionManager.closeFloatingPane(paneID: paneID)

        if let activeTab = sessionManager.activeTab {
            focusNextPane(fallback: activeTab.paneTree.firstPane.id)
        }
    }

    private func rerunFloatingPaneCommand(paneID: UUID) {
        guard let controller = sessionManager.rerunFloatingPaneCommand(paneID: paneID) else { return }
        viewStore.view(for: paneID)?.bindController(controller)
    }

    private func rerunTreePaneCommand(paneID: UUID) {
        guard let controller = sessionManager.rerunTreePaneCommand(paneID: paneID) else { return }
        viewStore.view(for: paneID)?.bindController(controller)
    }

    /// Dispatch the appropriate rerun helper based on where `paneID` lives.
    private func rerunExitedPaneCommand(paneID: UUID) {
        if sessionManager.activeTab?.floatingPanes.contains(where: { $0.pane.id == paneID }) == true {
            rerunFloatingPaneCommand(paneID: paneID)
        } else {
            rerunTreePaneCommand(paneID: paneID)
        }
    }

    // MARK: - Action Dispatch

    private func handleTabAction(_ action: TabAction) {
        switch action {
        // Session actions
        case .newSession:
            createNewSession()
        case .closeSession:
            closeSession(at: sessionManager.activeSessionIndex)
        case .previousSession:
            sessionManager.selectPreviousSessionInVisualOrder()
            restoreTabFocusedPane()
        case .nextSession:
            sessionManager.selectNextSessionInVisualOrder()
            restoreTabFocusedPane()
        case .toggleSidebar:
            toggleSidebar()
        // Tab actions
        case .newTab:
            createNewTab()
        case .closeTab:
            closeTab(at: sessionManager.activeTabIndex)
        case .previousTab:
            sessionManager.selectPreviousTab()
            restoreTabFocusedPane()
        case .nextTab:
            sessionManager.selectNextTab()
            restoreTabFocusedPane()
        case .gotoTab(let n):
            sessionManager.selectTabByNumber(n)
            restoreTabFocusedPane()
        // Pane actions
        case .splitVertical:
            splitPane(direction: .vertical)
        case .splitHorizontal:
            splitPane(direction: .horizontal)
        case .closePane:
            closePane()
        case .focusPane(let direction):
            moveFocus(direction)
        case .movePane(let direction):
            movePane(direction)
        case .paneExited(let paneID, let exitCode):
            handlePTYExit(id: paneID, exitCode: exitCode)
        case .growPane:
            resizePane(delta: 0.1)
        case .shrinkPane:
            resizePane(delta: -0.1)
        case .toggleZoom:
            toggleZoom()
        case .changeStrategy(let kind):
            changeStrategy(to: kind)
        case .cycleStrategy(let forward):
            cycleStrategy(forward: forward)
        // Floating pane actions
        case .newFloatingPane:
            createFloatingPane()
        case .closeFloatingPane(let paneID):
            closeFloatingPane(id: paneID)
        case .toggleOrCreateFloatingPane:
            toggleOrCreateFloatingPane()
        case .rerunFloatingPaneCommand(let paneID):
            rerunFloatingPaneCommand(paneID: paneID)
        case .dismissExitedPane(let paneID):
            forceClosePane(id: paneID)
        case .rerunExitedPaneCommand(let paneID):
            rerunExitedPaneCommand(paneID: paneID)
        case .listRemoteSessions:
            sessionManager.listRemoteSessions()
            ensureSidebarVisible()
        case .newRemoteSession:
            sessionManager.createRemoteSession()
            ensureSidebarVisible()
        case .showSessionPicker:
            showSessionPicker()
        case .detachSession:
            detachActiveSession()
        case .renameSession:
            startRenamingActiveSession()
        case .runInPlace(let command, let arguments):
            if let paneID = focusManager.focusedPaneID {
                Task { @MainActor in
                    await sessionManager.runInPlace(at: paneID, command: command, arguments: arguments)
                }
            }
        case .runCommand(let command, let arguments, let options):
            if let paneID = focusManager.focusedPaneID {
                Task { @MainActor in
                    if let newPaneID = await sessionManager.runCommand(at: paneID, command: command, arguments: arguments, options: options) {
                        focusManager.focusPane(id: newPaneID)
                    }
                }
            }
        case .paneNotification(let paneID, let title, let body):
            guard let (sessionID, tabID) = sessionManager.paneOwnerIDs(paneID: paneID) else { break }
            notificationStore.add(
                sessionID: sessionID,
                tabID: tabID,
                paneID: paneID,
                title: title,
                body: body
            )
            if paneID == focusManager.focusedPaneID {
                viewStore.view(for: paneID)?.flashNotificationRing()
            }
        case .toggleBroadcastInput:
            toggleBroadcastInput()
        case .clearPaneSelection:
            clearPaneSelection()
        case .showCommandPalette:
            openCommandPalette()
        }
    }

    /// Refresh the palette's data sources (SSH history / rules / ssh_config
    /// + session list + profiles + commands) and open. The palette lands
    /// in session scope by default; typing `ssh <host>` / `p <profile>` /
    /// `t <tab>` / `> cmd` switches scopes from inside the input.
    private func openCommandPalette() {
        Task { @MainActor in
            await sshLauncher.reload(
                ruleFileURL: ConfigLoader.sshRulesPath(),
                sshConfigURL: SSHConfigHosts.defaultURL
            )
            rewirePaletteForSSH()
            rewirePaletteForSessions()
            rewirePaletteForProfiles()
            rewirePaletteForCommands()
            commandPalette.open()
        }
    }

    /// Snapshot the current session list into palette candidates so the
    /// session scope has something to fuzzy-match against. Recomputed on
    /// every palette open — sessions can be opened/closed between opens,
    /// and the data is small enough that incremental tracking is not worth
    /// the complexity.
    private func rewirePaletteForSessions() {
        commandPalette.sessionCandidates = sessionManager.sessions.map(
            Self.sessionPaletteCandidate(for:)
        )
        commandPalette.onDeleteSession = { sessionID in
            self.deleteSessionFromPalette(sessionID: sessionID)
        }
    }

    /// Build one session-scope palette row. The candidate's `id` reuses
    /// `session.id` so the commit path can resolve the target directly
    /// without a parallel lookup table.
    @MainActor
    private static func sessionPaletteCandidate(
        for session: TerminalSession
    ) -> PaletteCandidate {
        let sourceLabel = session.source.isRemote ? "remote" : "local"
        let tabs = session.tabCount
        let tabsLabel = tabs == 1 ? "1 tab" : "\(tabs) tabs"
        var subtitle = "\(sourceLabel) · \(tabsLabel)"
        if session.isAnonymous { subtitle += " · unsaved" }
        return PaletteCandidate(
            id: session.id,
            primaryText: session.name,
            secondaryText: subtitle,
            scope: .session
        )
    }

    /// Enumerate loaded profiles into palette candidates sorted by id. The
    /// subtitle shows the `extends` chain + background hex so the user can
    /// distinguish similar-looking profiles at a glance.
    private func rewirePaletteForProfiles() {
        let profiles = configLoader.profileLoader.allRawProfiles
        let sortedIDs = profiles.keys.sorted()
        commandPalette.profileCandidates = sortedIDs.map { id in
            Self.profilePaletteCandidate(
                id: id,
                raw: profiles[id],
                backgroundHex: configLoader.profileLoader.resolvedLive(id: id).scalars["background"]
            )
        }
    }

    /// Build one profile-scope palette candidate. Static so it can be
    /// unit-tested without a live `ProfileLoader`.
    @MainActor
    static func profilePaletteCandidate(
        id: String,
        raw: RawProfile?,
        backgroundHex: String?
    ) -> PaletteCandidate {
        let extendsLabel = raw?.extendsID.map { "extends \($0)" }
        let subtitle: String = {
            let bgPart = backgroundHex.map { "#\($0)" }
            let parts = [extendsLabel, bgPart].compactMap { $0 }
            return parts.isEmpty ? "" : parts.joined(separator: " · ")
        }()
        return PaletteCandidate(
            primaryText: id,
            secondaryText: subtitle.isEmpty ? nil : subtitle,
            scope: .profile,
            accentHex: backgroundHex,
            profileID: id
        )
    }

    /// Build palette candidates for the command scope. Filters out
    /// parameterized actions (goto_tab:N, run_command, run_in_place) and
    /// any action whose `tabAction` is nil (those are handled at the
    /// pane/editor level, not by the window-level dispatcher — offering
    /// them here would dead-end on commit). Secondary text shows the
    /// bound shortcut (if any) so the palette doubles as a shortcut
    /// reference card.
    private func rewirePaletteForCommands() {
        let shortcutByAction = Self.shortcutIndex(for: configLoader.config.keybindings)
        let actions: [Keybinding.Action] = Self.paletteCommandActions
        commandPalette.commandCandidates = actions.compactMap { action in
            guard let title = action.paletteDisplayTitle,
                  action.tabAction != nil else { return nil }
            return PaletteCandidate(
                primaryText: title,
                secondaryText: shortcutByAction[action],
                scope: .command,
                commandAction: action
            )
        }
    }

    /// Curated list of non-parameterized actions offered in the command
    /// scope, in a deliberate order (palette rendering preserves insertion
    /// order when the query is empty). Parameterized actions (`gotoTab`,
    /// `runCommand`, `runInPlace`) are intentionally excluded — each one
    /// would expand to dozens of variants in the flat list.
    private static let paletteCommandActions: [Keybinding.Action] = [
        .newSession, .closeSession, .previousSession, .nextSession,
        .toggleSidebar,
        .newTab, .closeTab, .previousTab, .nextTab,
        .splitVertical, .splitHorizontal, .closePane,
        .focusPane(.left), .focusPane(.right), .focusPane(.up), .focusPane(.down),
        .movePane(.left), .movePane(.right), .movePane(.up), .movePane(.down),
        .growPane, .shrinkPane, .toggleZoom,
        .changeStrategy(.horizontal), .changeStrategy(.vertical),
        .changeStrategy(.grid), .changeStrategy(.masterStack),
        .cycleStrategy(forward: true), .cycleStrategy(forward: false),
        .newFloatingPane, .toggleOrCreateFloatingPane,
        .listRemoteSessions, .newRemoteSession, .showSessionPicker,
        .detachSession, .renameSession,
        .toggleBroadcastInput, .clearPaneSelection,
        .showCommandPalette,
    ]

    /// Build `action → shortcut glyph` map from the active keybindings.
    /// When an action has multiple bindings the first one wins — stable
    /// enough for a reference display and avoids an ambiguous
    /// "⌘P or ⌘⇧P" subtitle.
    static func shortcutIndex(for bindings: [Keybinding]) -> [Keybinding.Action: String] {
        var result: [Keybinding.Action: String] = [:]
        for binding in bindings where result[binding.action] == nil {
            result[binding.action] = binding.shortcutString
        }
        return result
    }

    /// Convert the launcher's current candidate list into `PaletteCandidate`
    /// rows and install the ad-hoc fallback builder. Called whenever the
    /// palette opens or the launcher's history changes after a successful
    /// spawn.
    private func rewirePaletteForSSH() {
        commandPalette.sshCandidates = sshLauncher.candidates.map(paletteCandidate(for:))
        commandPalette.sshAdHocBuilder = { [sshLauncher] query in
            let adHoc = SSHCandidate(target: query, hostname: nil, isAdHoc: true)
            let resolution = sshLauncher.resolve(candidate: adHoc)
            return Self.paletteCandidate(
                for: adHoc,
                resolution: resolution,
                backgroundHex: { template in
                    configLoader.profileLoader.resolvedLive(id: template).scalars["background"]
                }
            )
        }
        commandPalette.onDeleteHistory = { target in
            self.deleteSSHHistoryFromPalette(target: target)
        }
    }

    /// Convert one launcher `SSHCandidate` into a palette row, capturing the
    /// template choice + background swatch in the process.
    private func paletteCandidate(for candidate: SSHCandidate) -> PaletteCandidate {
        let resolution = sshLauncher.resolve(candidate: candidate)
        return Self.paletteCandidate(
            for: candidate,
            resolution: resolution,
            backgroundHex: { template in
                configLoader.profileLoader.resolvedLive(id: template).scalars["background"]
            }
        )
    }

    /// Shared conversion used by both the normal candidate path and the
    /// ad-hoc builder. Kept static so the ad-hoc closure doesn't capture
    /// `self` implicitly.
    @MainActor
    private static func paletteCandidate(
        for candidate: SSHCandidate,
        resolution: SSHResolution,
        backgroundHex: (String) -> String?
    ) -> PaletteCandidate {
        let primary: String
        if candidate.isAdHoc {
            primary = "Connect ad-hoc: \(candidate.target)"
        } else {
            primary = candidate.target
        }
        let hex = backgroundHex(resolution.templateID)
        let subtitle: String = {
            if let hex { return "\(resolution.templateID) · #\(hex)" }
            return resolution.templateID
        }()
        return PaletteCandidate(
            primaryText: primary,
            secondaryText: subtitle,
            scope: .ssh,
            accentHex: hex,
            sshResolution: resolution
        )
    }

    /// Drop the active tab's multi-pane selection (and stop broadcasting if
    /// it was on). No-op when nothing was selected — we stay silent instead
    /// of flashing a misleading toast.
    private func clearPaneSelection() {
        guard let activeTab = sessionManager.activeTab else { return }
        let wasBroadcasting = paneSelectionManager.isBroadcasting(tab: activeTab.id)
        guard paneSelectionManager.clearSelection(inTab: activeTab.id) else { return }
        toastPresenter.show(wasBroadcasting ? "已清空选中 · 广播关闭" : "已清空选中")
    }

    /// Flip broadcast-input on the active tab. When no explicit selection
    /// has been curated (via Cmd+Alt+click), defaults to "all panes in this
    /// tab". Shows a toast if the tab has fewer than two panes to broadcast
    /// between — the feature is a no-op in that case.
    private func toggleBroadcastInput() {
        guard let activeTab = sessionManager.activeTab else { return }
        let candidates = activeTab.allPaneIDsIncludingFloating
        let result = paneSelectionManager.toggleBroadcast(
            tab: activeTab.id,
            candidatePanes: candidates
        )
        switch result {
        case .enabled:
            let count = paneSelectionManager.selection(inTab: activeTab.id).count
            toastPresenter.show("广播已开启 · \(count) 个 pane 同步输入")
        case .disabled:
            toastPresenter.show("广播已关闭")
        case .rejectedTooFewPanes:
            toastPresenter.show("当前 tab 至少需要 2 个 pane 才能广播")
        }
    }

    private func moveFocus(_ direction: FocusDirection) {
        guard let activeTab = sessionManager.activeTab else { return }
        focusManager.moveFocus(direction: direction, in: activeTab, screenRect: Self.focusCanvas)
    }

    /// Relocate the focused pane next to its visual neighbor in `direction`
    /// (plan §P4.3). Neighbor lookup reuses `focusNeighbor` so the UX
    /// mirrors focus navigation: the pane "jumps past" its cardinal
    /// neighbor and lands on that neighbor's far side. No-op at the edge
    /// or when no pane is focused.
    private func movePane(_ direction: FocusDirection) {
        guard let activeTab = sessionManager.activeTab else { return }
        guard let sourceID = focusManager.focusedPaneID else { return }
        guard let targetID = LayoutEngine.focusNeighbor(
            tab: activeTab,
            screenRect: Self.focusCanvas,
            from: sourceID,
            direction: direction
        ) else { return }
        sessionManager.movePane(
            sourcePaneID: sourceID,
            targetPaneID: targetID,
            side: direction
        )
    }

    /// Synthetic canvas for engine-level neighbor/rect lookups until the
    /// render layer consumes `LayoutEngine.solveRects` directly (plan §315
    /// step 7). Large enough that weights dominate and min-size clamping is
    /// irrelevant — only relative geometry matters for focus/move.
    private static let focusCanvas = Rect(x: 0, y: 0, width: 10_000, height: 10_000)

    // MARK: - Helpers

    private func modalOverlay<Content: View>(
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack {
                Spacer().frame(height: 60)
                content()
                Spacer()
            }
        }
    }

    /// Pick the best pane to focus after closing one: prefer focus history, fall back to `fallback`.
    private func focusNextPane(fallback: UUID) {
        let remaining = Set(sessionManager.activeTab?.allPaneIDsIncludingFloating ?? [])
        let nextID = focusManager.previousFocusedPane(existingIn: remaining) ?? fallback
        focusManager.focusPane(id: nextID)
    }

    /// Focus the root pane of the active tab.
    private func focusActiveTabRootPane() {
        if let activeTab = sessionManager.activeTab {
            focusManager.focusPane(id: activeTab.paneTree.firstPane.id)
        }
    }

    /// Restore the last focused pane in the active tab, falling back to the root pane.
    private func restoreTabFocusedPane() {
        guard let activeTab = sessionManager.activeTab else { return }
        Self.restoreFocusForTab(activeTab, focusManager: focusManager)
    }

    /// Focus the saved pane in a tab, or fall back to the root pane.
    private static func restoreFocusForTab(_ tab: TerminalTab, focusManager: FocusManager) {
        let allIDs = Set(tab.allPaneIDsIncludingFloating)
        if let saved = tab.focusedPaneID, allIDs.contains(saved) {
            focusManager.focusPane(id: saved)
        } else {
            focusManager.focusPane(id: tab.paneTree.firstPane.id)
        }
    }

    // MARK: - Remote Session

    private func showSessionPicker() {
        suppressAutoSidebar = false
        showingSessionPicker = true
    }

    /// Handle session selection from the quick picker.
    /// For detached remote sessions, attach first; then switch.
    private func switchToSessionFromPicker(at index: Int) {
        if sessionManager.isSessionDetached(at: index) {
            attachSessionAtIndex(index)
        } else {
            switchToSession(at: index)
        }
    }

    private func ensureSidebarVisible() {
        suppressAutoSidebar = false
        if sidebarVisibility == .never {
            sidebarVisibility = .auto
        }
    }

    private func attachSessionAtIndex(_ index: Int) {
        guard sessionManager.sessions.indices.contains(index) else { return }
        let session = sessionManager.sessions[index]
        if let serverID = session.source.serverSessionID {
            sessionManager.attachRemoteSession(serverSessionID: serverID)
        } else if session.source == .local {
            sessionManager.attachLocalSession(sessionID: session.id)
        }
        let newIndex = sessionManager.sessions.firstIndex(where: { $0.id == session.id }) ?? index
        switchToSession(at: newIndex)
    }

    private func detachSessionAtIndex(_ index: Int) {
        guard sessionManager.sessions.indices.contains(index) else { return }
        let session = sessionManager.sessions[index]
        if let serverID = session.source.serverSessionID {
            sessionManager.detachRemoteSession(serverSessionID: serverID)
            // Remote teardown is handled by onRemoteDetached callback.
        } else if session.source == .local {
            sessionManager.detachLocalSession(sessionID: session.id)
            for tab in session.tabs {
                for paneID in tab.allPaneIDsIncludingFloating {
                    viewStore.tearDown(for: paneID)
                }
            }
        }
        pickNextSession()
        suppressAutoSidebar = false
        focusActiveTabRootPane()
    }

    /// Detach the currently active session (Shift+Cmd+K).
    private func detachActiveSession() {
        suppressAutoSidebar = false
        detachSessionAtIndex(sessionManager.activeSessionIndex)
    }

    private func startRenamingActiveSession() {
        guard sessionManager.activeSession != nil else { return }
        suppressAutoSidebar = false
        startRenamingSession(at: sessionManager.activeSessionIndex)
    }

    private func startRenamingSession(at index: Int) {
        renamingSessionIndex = index
    }

    private func dismissRenamePanel() {
        renamingSessionIndex = nil
    }

    /// Double-click on a sidebar session: attach if it's detached.
    private func handleSidebarDoubleClick(_ index: Int) {
        guard sessionManager.isSessionDetached(at: index) else { return }
        suppressAutoSidebar = false
        attachSessionAtIndex(index)
    }

    /// Wire the callback that fires when the server updates a remote session's layout.
    /// Handles MetalView teardown for removed panes and refocuses the active pane.
    private func wireRemoteLayoutCallback() {
        sessionManager.onRemoteDetached = { [viewStore, focusManager, paneSelectionManager] paneIDs in
            for paneID in paneIDs {
                viewStore.tearDown(for: paneID)
                focusManager.removeFromHistory(id: paneID)
                paneSelectionManager.didRemovePane(paneID)
            }
        }

        sessionManager.onRemoteSessionEmpty = { [viewStore, focusManager, paneSelectionManager, weak sessionManager] sessionID, removedPaneIDs in
            guard let sessionManager else { return }
            for paneID in removedPaneIDs {
                viewStore.tearDown(for: paneID)
                focusManager.removeFromHistory(id: paneID)
                paneSelectionManager.didRemovePane(paneID)
            }
            // Session may already be removed by handleRemoteSessionClosed;
            // close it here only if it still exists.
            if let index = sessionManager.sessions.firstIndex(where: { $0.id == sessionID }) {
                let paneIDs = sessionManager.closeSession(at: index)
                for paneID in paneIDs {
                    viewStore.tearDown(for: paneID)
                    focusManager.removeFromHistory(id: paneID)
                    paneSelectionManager.didRemovePane(paneID)
                }
            }
            // Skip window close when the session was torn down by an
            // automation client (`tongyou app close`). The CLI caller
            // just wants the session removed — taking down the window
            // would also exit the app when this is the last window.
            if sessionManager.sessions.isEmpty, !sessionManager.isAutomationClose {
                NSApp.keyWindow?.close()
            }
        }

        sessionManager.onSessionClosed = { [viewStore, focusManager, paneSelectionManager] _, removedPaneIDs in
            for paneID in removedPaneIDs {
                viewStore.tearDown(for: paneID)
                focusManager.removeFromHistory(id: paneID)
                paneSelectionManager.didRemovePane(paneID)
            }
        }

        sessionManager.onRemoteLayoutChanged = { [viewStore, focusManager, paneSelectionManager, weak sessionManager] sessionID, removedPaneIDs, addedPaneIDs in
            guard let sessionManager else { return }
            // Tear down MetalViews for removed panes.
            for paneID in removedPaneIDs {
                viewStore.tearDown(for: paneID)
                focusManager.removeFromHistory(id: paneID)
                paneSelectionManager.didRemovePane(paneID)
            }

            guard sessionManager.activeSession?.id == sessionID,
                  let activeTab = sessionManager.activeSession?.activeTab else { return }
            let activePaneIDs = Set(activeTab.allPaneIDsIncludingFloating)

            let restoreFocus = { TerminalWindowView.restoreFocusForTab(activeTab, focusManager: focusManager) }

            // If the focused pane is no longer in the active tab (e.g. tab switched
            // or focused pane removed), restore the tab's saved focus or fall back to root.
            if let focused = focusManager.focusedPaneID,
               !activePaneIDs.contains(focused) {
                restoreFocus()
                return
            }

            // If a new pane was added (e.g. split), focus it.
            // Use tree order (deterministic) rather than Set iteration order.
            let addedSet = Set(addedPaneIDs)
            if let newPaneID = activeTab.allPaneIDsIncludingFloating
                .last(where: { addedSet.contains($0) }) {
                focusManager.focusPane(id: newPaneID)
                return
            }

            // If no pane is focused, restore saved focus or fall back to root.
            if focusManager.focusedPaneID == nil {
                restoreFocus()
            }
        }
    }

    /// Load config and derive window background color, with hot-reload support.
    private func loadWindowBackground() {
        configLoader.load()
        windowBackgroundColor = configLoader.config.background.nsColor
        configLoader.onConfigChanged = { newConfig in
            windowBackgroundColor = newConfig.background.nsColor
        }
    }

    /// Get the CWD from the currently focused pane.
    private var focusedPaneCWD: String? {
        guard let focusedID = focusManager.focusedPaneID else {
            return sessionManager.activeTab.flatMap { tab in
                viewStore.view(for: tab.paneTree.firstPane.id)?.currentWorkingDirectory
            }
        }
        return viewStore.view(for: focusedID)?.currentWorkingDirectory
    }
}

// MARK: - RGBColor + AppKit

extension RGBColor {
    var nsColor: NSColor {
        NSColor(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}

// MARK: - Window Configurator

/// Sets the hosting NSWindow's titlebar to transparent and background color
/// to match the terminal theme, so the title bar blends with the content.
struct WindowConfigurator: NSViewRepresentable {
    let backgroundColor: NSColor
    let title: String
    var onWindowClose: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        ConfiguratorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ConfiguratorView else { return }
        view.desiredBackgroundColor = backgroundColor
        view.desiredTitle = title
        view.onWindowClose = onWindowClose
        view.applyIfNeeded()
    }
}

/// Applies window-level NSWindow configuration that SwiftUI cannot
/// express declaratively: transparent titlebar, background color, title.
///
/// The titlebar appearance follows the system light/dark theme automatically.
private class ConfiguratorView: NSView {
    var desiredBackgroundColor: NSColor = .black
    var desiredTitle: String = "TongYou"
    var onWindowClose: (() -> Void)?
    private var didConfigureStyle = false
    private var observingWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfNeeded()

        // Observe window close to trigger cleanup
        if let window, window !== observingWindow {
            if let old = observingWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: old)
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window
            )
            observingWindow = window
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        onWindowClose?()
    }

    deinit {
        if let observingWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: observingWindow)
        }
    }

    override func layout() {
        super.layout()
        applyIfNeeded()
    }

    func applyIfNeeded() {
        guard let window else { return }

        if !didConfigureStyle {
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            didConfigureStyle = true
        }

        if window.backgroundColor != desiredBackgroundColor {
            window.backgroundColor = desiredBackgroundColor
        }
        if window.title != desiredTitle {
            window.title = desiredTitle
        }
    }
}

// MARK: - MetalView Store

/// Plain reference type that holds MetalView instances keyed by pane ID.
/// Not `@Observable` — invisible to SwiftUI, so mutations in `makeNSView`
/// do not trigger "Modifying state during view update" warnings.
final class MetalViewStore {
    private var views: [UUID: MetalView] = [:]

    var allViews: [UUID: MetalView] { views }

    func view(for paneID: UUID) -> MetalView? {
        views[paneID]
    }

    func store(_ view: MetalView, for paneID: UUID) {
        views[paneID] = view
    }

    func tearDown(for paneID: UUID) {
        if let view = views.removeValue(forKey: paneID) {
            view.tearDown()
        }
    }
}
