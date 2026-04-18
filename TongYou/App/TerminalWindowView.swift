import SwiftUI
import TYClient
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
    @State private var windowBackgroundColor: NSColor = .black
    @State private var sidebarVisibility: SidebarVisibility = .auto
    @State private var suppressAutoSidebar = true
    @State private var showingSessionPicker = false
    @State private var renamingSessionIndex: Int?

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
        _sessionManager = State(initialValue: SessionManager(
            profileLoader: loader.profileLoader
        ))
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
            if showingSessionPicker {
                modalOverlay(onDismiss: { showingSessionPicker = false }) {
                    SessionPickerView(
                        sessions: sessionManager.sessions,
                        activeSessionIndex: sessionManager.activeSessionIndex,
                        attachedSessionIDs: sessionManager.allAttachedSessionIDs,
                        onSelect: { index in
                            switchToSessionFromPicker(at: index)
                        },
                        onDismiss: {
                            showingSessionPicker = false
                        },
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
                        onConfirm: { newName in
                            sessionManager.renameSession(at: index, to: newName)
                        },
                        onDismiss: {
                            dismissRenamePanel()
                        }
                    )
                }
            }

            if sessionManager.connectionStatus != .idle {
                DaemonConnectingOverlayView(
                    status: sessionManager.connectionStatus,
                    onDismiss: {
                        sessionManager.dismissConnectionStatus()
                    }
                )
            }
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
        .onAppear {
            focusManager.attachViewStore(viewStore)
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
        }
        .onChange(of: notificationStore.unreadPaneIDs) { _, newIDs in
            for (paneID, view) in viewStore.allViews {
                let shouldShow = newIDs.contains(paneID) && paneID != focusManager.focusedPaneID
                view.setNotificationRing(visible: shouldShow)
            }
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
                }
            )

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
                }
            )
        }
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

        // Remote session: just send to server; layoutUpdate handles the rest.
        if sessionManager.activeSession?.source.isRemote == true {
            notificationStore.clearAll(forPaneID: paneID)
            sessionManager.closePane(id: paneID)
            return
        }

        // Tree pane with `close-on-exit = false`: keep the pane so the
        // user can still read the final output. ESC dismisses, Enter re-runs.
        if let pane = sessionManager.activeSession?.tabs
            .lazy
            .compactMap({ $0.paneTree.findPane(id: paneID) })
            .first,
           pane.startupSnapshot.closeOnExit == false {
            sessionManager.markTreePaneExited(paneID, exitCode: exitCode)
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
        case .paneExited(let paneID, let exitCode):
            handlePTYExit(id: paneID, exitCode: exitCode)
        case .growPane:
            resizePane(delta: 0.1)
        case .shrinkPane:
            resizePane(delta: -0.1)
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
        }
    }

    private func moveFocus(_ direction: FocusDirection) {
        guard let activeTab = sessionManager.activeTab else { return }
        focusManager.moveFocus(direction: direction, in: activeTab.paneTree)
    }

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
        sessionManager.onRemoteDetached = { [viewStore, focusManager] paneIDs in
            for paneID in paneIDs {
                viewStore.tearDown(for: paneID)
                focusManager.removeFromHistory(id: paneID)
            }
        }

        sessionManager.onRemoteSessionEmpty = { [viewStore, focusManager, weak sessionManager] sessionID, removedPaneIDs in
            guard let sessionManager else { return }
            for paneID in removedPaneIDs {
                viewStore.tearDown(for: paneID)
                focusManager.removeFromHistory(id: paneID)
            }
            // Session may already be removed by handleRemoteSessionClosed;
            // close it here only if it still exists.
            if let index = sessionManager.sessions.firstIndex(where: { $0.id == sessionID }) {
                let paneIDs = sessionManager.closeSession(at: index)
                for paneID in paneIDs {
                    viewStore.tearDown(for: paneID)
                    focusManager.removeFromHistory(id: paneID)
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

        sessionManager.onSessionClosed = { [viewStore, focusManager] _, removedPaneIDs in
            for paneID in removedPaneIDs {
                viewStore.tearDown(for: paneID)
                focusManager.removeFromHistory(id: paneID)
            }
        }

        sessionManager.onRemoteLayoutChanged = { [viewStore, focusManager, weak sessionManager] sessionID, removedPaneIDs, addedPaneIDs in
            guard let sessionManager else { return }
            // Tear down MetalViews for removed panes.
            for paneID in removedPaneIDs {
                viewStore.tearDown(for: paneID)
                focusManager.removeFromHistory(id: paneID)
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
