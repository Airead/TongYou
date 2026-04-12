import CoreGraphics
import Foundation

/// Manages terminal sessions, each containing its own set of tabs and panes.
/// Absorbs all logic previously in TabManager, scoped to the active session.
@Observable
final class SessionManager {

    private(set) var sessions: [TerminalSession] = []
    private(set) var activeSessionIndex: Int = 0

    /// The currently active session, if any.
    var activeSession: TerminalSession? {
        guard sessions.indices.contains(activeSessionIndex) else { return nil }
        return sessions[activeSessionIndex]
    }

    var activeTab: TerminalTab? { activeSession?.activeTab }
    var sessionCount: Int { sessions.count }
    var tabCount: Int { activeSession?.tabCount ?? 0 }
    var tabs: [TerminalTab] { activeSession?.tabs ?? [] }
    var activeTabIndex: Int { activeSession?.activeTabIndex ?? 0 }

    // MARK: - Session Lifecycle

    @discardableResult
    func createSession(name: String? = nil, initialWorkingDirectory: String? = nil) -> UUID {
        let sessionName = name ?? "Session \(sessions.count + 1)"
        let session = TerminalSession(name: sessionName, initialWorkingDirectory: initialWorkingDirectory)
        sessions.append(session)
        activeSessionIndex = sessions.count - 1
        return session.id
    }

    /// Close a session at the given index.
    /// Returns the list of all pane IDs that need teardown.
    @discardableResult
    func closeSession(at index: Int) -> [UUID] {
        guard sessions.indices.contains(index) else { return [] }
        let paneIDs = sessions[index].allPaneIDs
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
        sessions[index].name = name
    }

    func renameActiveSession(to name: String) {
        renameSession(at: activeSessionIndex, to: name)
    }

    // MARK: - Tab Lifecycle (scoped to active session)

    @discardableResult
    func createTab(title: String = "shell", initialWorkingDirectory: String? = nil) -> UUID {
        guard sessions.indices.contains(activeSessionIndex) else {
            return createSession(initialWorkingDirectory: initialWorkingDirectory)
        }
        let tab = TerminalTab(title: title, initialWorkingDirectory: initialWorkingDirectory)
        sessions[activeSessionIndex].tabs.append(tab)
        sessions[activeSessionIndex].activeTabIndex = sessions[activeSessionIndex].tabs.count - 1
        return tab.id
    }

    /// Close a tab. Returns true if the tab was found.
    /// When the last tab is closed, the session remains with an empty tab list
    /// — the caller decides whether to close the session.
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard sessions.indices.contains(activeSessionIndex),
              sessions[activeSessionIndex].tabs.indices.contains(index) else { return false }

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

    @discardableResult
    func splitPane(id paneID: UUID, direction: SplitDirection, newPane: TerminalPane) -> Bool {
        guard sessions.indices.contains(activeSessionIndex) else { return false }
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

    /// Close a specific pane. If it's the last pane in its tab, close the tab.
    /// Returns the ID of a sibling pane to focus, or nil if the tab was closed.
    @discardableResult
    func closePane(id paneID: UUID) -> UUID? {
        guard sessions.indices.contains(activeSessionIndex) else { return nil }
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
    @discardableResult
    func createFloatingPane(initialWorkingDirectory: String? = nil) -> UUID? {
        guard sessions.indices.contains(activeSessionIndex),
              sessions[activeSessionIndex].tabs.indices.contains(
                  sessions[activeSessionIndex].activeTabIndex) else { return nil }
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
    /// Searches all tabs in all sessions because a PTY exit may arrive after
    /// the user has switched away.
    @discardableResult
    func closeFloatingPane(paneID: UUID) -> Bool {
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
        guard let idx = activeFloatingPaneIndex(for: paneID) else { return }
        let maxZ = activeFloatingPanes.max(by: { $0.zIndex < $1.zIndex })?.zIndex ?? 0
        guard activeFloatingPanes[idx].zIndex < maxZ else { return }
        activeFloatingPanes[idx].zIndex = maxZ + 1
    }

    func updateFloatingPaneFrame(paneID: UUID, frame: CGRect) {
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
             .newFloatingPane, .closeFloatingPane, .toggleOrCreateFloatingPane:
            // Pane actions are handled by TerminalWindowView.
            return false
        }
    }
}
