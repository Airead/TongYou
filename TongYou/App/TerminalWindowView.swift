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

    @State private var sessionManager = SessionManager()
    @State private var tabBarVisibility: TabBarVisibility = .auto
    @State private var focusManager = FocusManager()
    @State private var windowBackgroundColor: NSColor = .black
    @State private var sidebarVisibility: SidebarVisibility = .auto
    @State private var showingSessionPicker = false
    @State private var renamingSessionIndex: Int?

    /// Stores MetalView instances outside of SwiftUI state so that
    /// NSViewRepresentable.makeNSView can read/write without triggering
    /// "Modifying state during view update" warnings.
    @State private var viewStore = MetalViewStore()

    /// Loads config to derive the window background color.
    /// Each MetalView also has its own ConfigLoader for rendering.
    @State private var configLoader = ConfigLoader()

    var body: some View {
        HStack(spacing: 0) {
            if shouldShowSidebar {
                SessionSidebarView(
                    sessions: sessionManager.sessions,
                    activeSessionIndex: sessionManager.activeSessionIndex,
                    attachedSessionIDs: sessionManager.attachedRemoteSessionIDs,
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
                    }
                )

                Divider()
            }

            VStack(spacing: 0) {
                if shouldShowTabBar {
                    TabBarView(
                        tabs: sessionManager.tabs,
                        activeTabIndex: sessionManager.activeTabIndex,
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

                if case .detached = sessionManager.activeSessionRemoteState {
                    DetachedSessionPlaceholderView(
                        sessionName: sessionManager.activeSession?.name ?? "Session",
                        isPending: false,
                        keybindings: configLoader.config.keybindings,
                        onAttach: {
                            attachSessionAtIndex(sessionManager.activeSessionIndex)
                        },
                        onTabAction: handleTabAction
                    )
                    .id(sessionManager.activeSession?.id)
                } else if case .pendingAttach = sessionManager.activeSessionRemoteState {
                    DetachedSessionPlaceholderView(
                        sessionName: sessionManager.activeSession?.name ?? "Session",
                        isPending: true,
                        keybindings: configLoader.config.keybindings,
                        onAttach: {},
                        onTabAction: handleTabAction
                    )
                    .id(sessionManager.activeSession?.id)
                } else if let activeTab = sessionManager.activeTab {
                    let updateTabTitle: (String) -> Void = { title in
                        sessionManager.updateTitle(title, for: activeTab.id)
                    }

                    ZStack {
                        PaneSplitView(
                            node: activeTab.paneTree,
                            viewStore: viewStore,
                            focusManager: focusManager,
                            controllerForPane: { paneID in
                                sessionManager.remoteController(for: paneID)
                            },
                            onTabAction: handleTabAction,
                            onTitleChanged: updateTabTitle,
                            onNodeChanged: { newTree in
                                sessionManager.updateActivePaneTree(newTree)
                            }
                        )

                        FloatingPaneOverlay(
                            floatingPanes: activeTab.floatingPanes,
                            viewStore: viewStore,
                            focusManager: focusManager,
                            controllerForPane: { paneID in
                                sessionManager.remoteController(for: paneID)
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
                            }
                        )
                    }
                    .id(activeTab.id)
                }
            }
        }
        .overlay {
            if showingSessionPicker {
                modalOverlay(onDismiss: { showingSessionPicker = false }) {
                    SessionPickerView(
                        sessions: sessionManager.sessions,
                        attachedSessionIDs: sessionManager.attachedRemoteSessionIDs,
                        onAttach: { serverSessionID in
                            sessionManager.attachRemoteSession(serverSessionID: serverSessionID)
                        },
                        onDismiss: {
                            showingSessionPicker = false
                        }
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
        }
        .preferredColorScheme(.dark)
        .background(WindowConfigurator(
            backgroundColor: windowBackgroundColor,
            title: windowTitle,
            onWindowClose: { [sessionManager] in
                sessionManager.disconnectFromTYD()
            }
        ))
        .onAppear {
            if sessionManager.sessions.isEmpty {
                sessionManager.createSession()
            }
            focusActiveTabRootPane()
            loadWindowBackground()
            wireRemoteLayoutCallback()
        }
        .onChange(of: focusManager.focusedPaneID) { _, newID in
            sessionManager.updateFloatingPanesVisibilityForFocus(focusedPaneID: newID)
        }
    }

    /// Window title derived from the active tab's OSC title, falling back to session name.
    private var windowTitle: String {
        if let tab = sessionManager.activeTab, tab.title != TerminalTab.defaultTitle {
            return tab.title
        }
        return sessionManager.activeSession?.name ?? "TongYou"
    }

    private var shouldShowSidebar: Bool {
        switch sidebarVisibility {
        case .auto: sessionManager.sessionCount > 1
        case .always: true
        case .never: false
        }
    }

    private var shouldShowTabBar: Bool {
        switch tabBarVisibility {
        case .auto: sessionManager.tabCount > 1
        case .always: true
        case .never: false
        }
    }

    // MARK: - Session Operations

    private func createNewSession() {
        let cwd: String? = focusedPaneCWD
        sessionManager.createSession(initialWorkingDirectory: cwd)
        focusActiveTabRootPane()
    }

    private func closeSession(at index: Int) {
        let paneIDs = sessionManager.closeSession(at: index)
        for paneID in paneIDs {
            viewStore.tearDown(for: paneID)
            focusManager.removeFromHistory(id: paneID)
        }

        if sessionManager.sessions.isEmpty {
            NSApp.keyWindow?.close()
        } else {
            focusActiveTabRootPane()
        }
    }

    private func switchToSession(at index: Int) {
        sessionManager.selectSession(at: index)
        focusActiveTabRootPane()
    }

    private func toggleSidebar() {
        switch sidebarVisibility {
        case .auto:
            sidebarVisibility = sessionManager.sessionCount > 1 ? .never : .always
        case .always:
            sidebarVisibility = .never
        case .never:
            sidebarVisibility = .always
        }
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

        // Tear down all MetalViews in this tab's pane tree and floating panes.
        for paneID in tab.allPaneIDsIncludingFloating {
            viewStore.tearDown(for: paneID)
        }

        sessionManager.closeTab(at: index)

        if sessionManager.tabCount == 0 {
            closeSession(at: sessionManager.activeSessionIndex)
        } else {
            focusActiveTabRootPane()
        }
    }

    private func switchToTab(at index: Int) {
        sessionManager.selectTab(at: index)
        focusActiveTabRootPane()
    }

    // MARK: - Pane Operations

    private func splitPane(direction: SplitDirection) {
        guard let focusedID = focusManager.focusedPaneID else { return }
        let cwd = viewStore.view(for: focusedID)?.currentWorkingDirectory
        let newPane = TerminalPane(initialWorkingDirectory: cwd)
        guard sessionManager.splitPane(id: focusedID, direction: direction, newPane: newPane) else {
            return
        }
        focusManager.focusPane(id: newPane.id)
    }

    private func closePane() {
        guard let focusedID = focusManager.focusedPaneID else { return }
        removePane(id: focusedID)
    }

    /// Tear down a pane and focus the nearest sibling or close the tab/window.
    private func removePane(id paneID: UUID) {
        // Check if this is a floating pane first.
        if sessionManager.activeTab?.floatingPanes.contains(where: { $0.pane.id == paneID }) == true {
            closeFloatingPane(id: paneID)
            return
        }

        // Remote session: just send to server; layoutUpdate handles the rest.
        if sessionManager.activeSession?.source.isRemote == true {
            sessionManager.closePane(id: paneID)
            return
        }

        viewStore.tearDown(for: paneID)
        focusManager.removeFromHistory(id: paneID)

        if let siblingID = sessionManager.closePane(id: paneID) {
            focusNextPane(fallback: siblingID)
        } else if sessionManager.tabCount == 0 {
            // Last pane in last tab — close the session.
            closeSession(at: sessionManager.activeSessionIndex)
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
            focusAndActivate(paneID: targetID)
        } else {
            // Currently on a tree pane -> show all and focus floating
            sessionManager.setFloatingPanesVisibility(visible: true)
            let targetID = focusManager.previousFocusedPane(existingIn: floatingIDs)
                ?? activeTab.floatingPanes.last?.pane.id
            if let id = targetID {
                focusAndActivate(paneID: id)
            }
        }
    }

    private func closeFloatingPane(id paneID: UUID) {
        viewStore.tearDown(for: paneID)
        focusManager.removeFromHistory(id: paneID)
        sessionManager.closeFloatingPane(paneID: paneID)

        if let activeTab = sessionManager.activeTab {
            focusNextPane(fallback: activeTab.paneTree.firstPane.id)
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
            sessionManager.selectPreviousSession()
            focusActiveTabRootPane()
        case .nextSession:
            sessionManager.selectNextSession()
            focusActiveTabRootPane()
        case .toggleSidebar:
            toggleSidebar()
        // Tab actions
        case .newTab:
            createNewTab()
        case .closeTab:
            closeTab(at: sessionManager.activeTabIndex)
        case .previousTab:
            sessionManager.selectPreviousTab()
        case .nextTab:
            sessionManager.selectNextTab()
        case .gotoTab(let n):
            sessionManager.selectTabByNumber(n)
        // Pane actions
        case .splitVertical:
            splitPane(direction: .vertical)
        case .splitHorizontal:
            splitPane(direction: .horizontal)
        case .closePane:
            closePane()
        case .focusPane(let direction):
            moveFocus(direction)
        case .paneExited(let paneID):
            removePane(id: paneID)
        // Floating pane actions
        case .newFloatingPane:
            createFloatingPane()
        case .closeFloatingPane(let paneID):
            closeFloatingPane(id: paneID)
        case .toggleOrCreateFloatingPane:
            toggleOrCreateFloatingPane()
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
        }
    }

    private func moveFocus(_ direction: FocusDirection) {
        guard let activeTab = sessionManager.activeTab else { return }
        focusManager.moveFocus(direction: direction, in: activeTab.paneTree)
        if let focusedID = focusManager.focusedPaneID {
            activateFirstResponder(for: focusedID)
        }
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
        focusAndActivate(paneID: nextID)
    }

    /// Focus the root pane of the active tab.
    private func focusActiveTabRootPane() {
        if let activeTab = sessionManager.activeTab {
            focusManager.focusPane(id: activeTab.paneTree.firstPane.id)
        }
    }

    /// Focus a pane and make its MetalView the first responder for keyboard input.
    private func focusAndActivate(paneID: UUID) {
        focusManager.focusPane(id: paneID)
        activateFirstResponder(for: paneID)
    }

    private func activateFirstResponder(for paneID: UUID) {
        if let metalView = viewStore.view(for: paneID) {
            metalView.window?.makeFirstResponder(metalView)
        }
    }

    // MARK: - Remote Session

    private func showSessionPicker() {
        sessionManager.listRemoteSessions()
        showingSessionPicker = true
    }

    private func ensureSidebarVisible() {
        if sidebarVisibility == .never {
            sidebarVisibility = .auto
        }
    }

    private func withServerSession(at index: Int, _ action: (UUID) -> Void) {
        guard sessionManager.sessions.indices.contains(index),
              let serverID = sessionManager.sessions[index].source.serverSessionID else { return }
        action(serverID)
    }

    private func attachSessionAtIndex(_ index: Int) {
        withServerSession(at: index, sessionManager.attachRemoteSession)
    }

    private func detachSessionAtIndex(_ index: Int) {
        withServerSession(at: index, sessionManager.detachRemoteSession)
    }

    /// Detach the currently active remote session (Shift+Cmd+K).
    private func detachActiveSession() {
        detachSessionAtIndex(sessionManager.activeSessionIndex)
    }

    private func startRenamingActiveSession() {
        guard sessionManager.activeSession != nil else { return }
        startRenamingSession(at: sessionManager.activeSessionIndex)
    }

    private func startRenamingSession(at index: Int) {
        renamingSessionIndex = index
    }

    private func dismissRenamePanel() {
        renamingSessionIndex = nil
    }

    /// Double-click on a sidebar session: attach if it's a detached remote session.
    private func handleSidebarDoubleClick(_ index: Int) {
        guard sessionManager.isSessionDetachedRemote(at: index) else { return }
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

        sessionManager.onRemoteLayoutChanged = { [viewStore, focusManager, sessionManager] sessionID, removedPaneIDs, addedPaneIDs in
            // Tear down MetalViews for removed panes.
            for paneID in removedPaneIDs {
                viewStore.tearDown(for: paneID)
                focusManager.removeFromHistory(id: paneID)
            }

            guard sessionManager.activeSession?.id == sessionID,
                  let activeTab = sessionManager.activeSession?.activeTab else { return }
            let activePaneIDs = Set(activeTab.allPaneIDsIncludingFloating)

            let focusRoot = { focusManager.focusPane(id: activeTab.paneTree.firstPane.id) }

            // If the focused pane is no longer in the active tab (e.g. tab switched
            // or focused pane removed), focus the active tab's root pane.
            if let focused = focusManager.focusedPaneID,
               !activePaneIDs.contains(focused) {
                focusRoot()
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

            // If no pane is focused, focus the active tab's root.
            if focusManager.focusedPaneID == nil {
                focusRoot()
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
/// The dark titlebar appearance (light text, colored traffic lights) is
/// driven by `.preferredColorScheme(.dark)` on the SwiftUI side, which
/// SwiftUI propagates to the NSWindow's effective appearance.
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
