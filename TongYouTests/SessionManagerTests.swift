import Foundation
import Testing
import TYProtocol
import TYServer
import TYTerminal
@testable import TongYou

@Suite("SessionManager")
struct SessionManagerTests {

    private func makeTempDir() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
    }

    private func makeManager() -> SessionManager {
        let store = SessionStore(directory: makeTempDir())
        return SessionManager(localSessionStore: store)
    }

    // MARK: - Session Creation

    @Test func createFirstSession() {
        let mgr = makeManager()
        let id = mgr.createSession(name: "dev")
        #expect(mgr.sessionCount == 1)
        #expect(mgr.activeSessionIndex == 0)
        #expect(mgr.activeSession?.id == id)
        #expect(mgr.activeSession?.name == "dev")
        // Session starts with one tab.
        #expect(mgr.tabCount == 1)
    }

    @Test func createMultipleSessions() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "s1")
        _ = mgr.createSession(name: "s2")
        let id3 = mgr.createSession(name: "s3")

        #expect(mgr.sessionCount == 3)
        #expect(mgr.activeSessionIndex == 2)
        #expect(mgr.activeSession?.id == id3)
    }

    @Test func createSessionAutoName() {
        let mgr = makeManager()
        _ = mgr.createSession()
        _ = mgr.createSession()

        #expect(mgr.sessions[0].name == "LSession 1")
        #expect(mgr.sessions[1].name == "LSession 2")
    }

    // MARK: - Session Close

    @Test func closeActiveSession() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "s1")
        let id2 = mgr.createSession(name: "s2")
        _ = mgr.createSession(name: "s3")

        mgr.selectSession(at: 1)
        #expect(mgr.activeSession?.id == id2)

        let paneIDs = mgr.closeActiveSession()
        #expect(!paneIDs.isEmpty)
        #expect(mgr.sessionCount == 2)
        // After closing index 1, tab at index 2 slides to 1.
        #expect(mgr.activeSessionIndex == 1)
        #expect(mgr.activeSession?.name == "s3")
    }

    @Test func closeFirstSession() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "s1")
        let id2 = mgr.createSession(name: "s2")

        mgr.selectSession(at: 0)
        mgr.closeSession(at: 0)

        #expect(mgr.sessionCount == 1)
        #expect(mgr.activeSessionIndex == 0)
        #expect(mgr.activeSession?.id == id2)
    }

    @Test func closeLastRemainingSession() {
        let mgr = makeManager()
        _ = mgr.createSession()

        let paneIDs = mgr.closeActiveSession()
        #expect(!paneIDs.isEmpty)
        #expect(mgr.sessionCount == 0)
        #expect(mgr.activeSession == nil)
    }

    @Test func closeSessionReturnsAllPaneIDs() {
        let mgr = makeManager()
        _ = mgr.createSession()
        // Add a second tab to the session.
        _ = mgr.createTab()
        #expect(mgr.tabCount == 2)

        let paneIDs = mgr.closeActiveSession()
        // Each tab has one pane by default.
        #expect(paneIDs.count == 2)
    }

    @Test func closeSessionBeforeActive() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "s1")
        _ = mgr.createSession(name: "s2")
        let id3 = mgr.createSession(name: "s3")

        // Active is s3 (index 2)
        mgr.closeSession(at: 0)

        #expect(mgr.sessionCount == 2)
        #expect(mgr.activeSessionIndex == 1)
        #expect(mgr.activeSession?.id == id3)
    }

    // MARK: - Session Switching

    @Test func selectSession() {
        let mgr = makeManager()
        let id1 = mgr.createSession(name: "s1")
        _ = mgr.createSession(name: "s2")

        mgr.selectSession(at: 0)
        #expect(mgr.activeSessionIndex == 0)
        #expect(mgr.activeSession?.id == id1)
    }

    @Test func selectSessionClamped() {
        let mgr = makeManager()
        _ = mgr.createSession()
        _ = mgr.createSession()

        mgr.selectSession(at: 100)
        #expect(mgr.activeSessionIndex == 1)

        mgr.selectSession(at: -5)
        #expect(mgr.activeSessionIndex == 0)
    }

    @Test func previousSessionWraps() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "s1")
        _ = mgr.createSession(name: "s2")
        _ = mgr.createSession(name: "s3")

        mgr.selectSession(at: 0)
        mgr.selectPreviousSession()
        #expect(mgr.activeSessionIndex == 2)
    }

    @Test func nextSessionWraps() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "s1")
        _ = mgr.createSession(name: "s2")

        // Active is s2 (index 1)
        mgr.selectNextSession()
        #expect(mgr.activeSessionIndex == 0)
    }

    @Test func previousAndNextNoOpWithSingleSession() {
        let mgr = makeManager()
        _ = mgr.createSession()

        mgr.selectPreviousSession()
        #expect(mgr.activeSessionIndex == 0)

        mgr.selectNextSession()
        #expect(mgr.activeSessionIndex == 0)
    }

    // MARK: - Session Rename

    @Test func renameSession() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "old")

        mgr.renameSession(at: 0, to: "new")
        #expect(mgr.sessions[0].name == "new")
    }

    @Test func renameActiveSession() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "old")

        mgr.renameActiveSession(to: "renamed")
        #expect(mgr.activeSession?.name == "renamed")
    }

    // MARK: - Unique Session Names

    @Test func createSessionAutoNameSkipsTaken() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "LSession 1")
        _ = mgr.createSession()  // "LSession 1" is taken, should get "LSession 2"

        #expect(mgr.sessions[0].name == "LSession 1")
        #expect(mgr.sessions[1].name == "LSession 2")
    }

    @Test func createSessionWithDuplicateNameGetsSuffix() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "dev")
        _ = mgr.createSession(name: "dev")

        #expect(mgr.sessions[0].name == "dev")
        #expect(mgr.sessions[1].name != "dev")
        #expect(mgr.sessions[1].name.hasPrefix("dev-"))
    }

    @Test func createSessionWithUniqueNameUnchanged() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "alpha")
        _ = mgr.createSession(name: "beta")

        #expect(mgr.sessions[0].name == "alpha")
        #expect(mgr.sessions[1].name == "beta")
    }

    @Test func renameSessionDeduplicates() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "work")
        _ = mgr.createSession(name: "play")

        mgr.renameSession(at: 1, to: "work")
        #expect(mgr.sessions[1].name != "work")
        #expect(mgr.sessions[1].name.hasPrefix("work-"))
    }

    @Test func renameSessionToSameNameUnchanged() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "dev")

        mgr.renameSession(at: 0, to: "dev")
        #expect(mgr.sessions[0].name == "dev")
    }

    // MARK: - Tab Operations Within Session

    @Test func createTabInActiveSession() {
        let mgr = makeManager()
        _ = mgr.createSession()
        #expect(mgr.tabCount == 1)

        let tabID = mgr.createTab(title: "second")
        #expect(mgr.tabCount == 2)
        #expect(mgr.activeTab?.id == tabID)
    }

    @Test func tabsAreScopedToSession() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "s1")
        _ = mgr.createTab(title: "s1-tab2")
        #expect(mgr.tabCount == 2)

        _ = mgr.createSession(name: "s2")
        #expect(mgr.tabCount == 1)  // New session starts with 1 tab.

        mgr.selectSession(at: 0)
        #expect(mgr.tabCount == 2)  // Back to s1's tabs.
    }

    @Test func closeTabInSession() {
        let mgr = makeManager()
        _ = mgr.createSession()
        _ = mgr.createTab(title: "tab2")
        #expect(mgr.tabCount == 2)

        mgr.closeTab(at: 0)
        #expect(mgr.tabCount == 1)
    }

    @Test func closeLastTabLeavesEmptySession() {
        let mgr = makeManager()
        _ = mgr.createSession()
        #expect(mgr.tabCount == 1)

        mgr.closeActiveTab()
        #expect(mgr.tabCount == 0)
        // Session still exists — caller decides whether to close it.
        #expect(mgr.sessionCount == 1)
    }

    @Test func selectTabInSession() {
        let mgr = makeManager()
        _ = mgr.createSession()
        let id1 = mgr.tabs.first!.id
        _ = mgr.createTab(title: "tab2")

        mgr.selectTab(at: 0)
        #expect(mgr.activeTab?.id == id1)
    }

    @Test func previousAndNextTab() {
        let mgr = makeManager()
        _ = mgr.createSession()
        _ = mgr.createTab(title: "tab2")
        _ = mgr.createTab(title: "tab3")

        // Active is tab3 (index 2)
        mgr.selectTab(at: 0)
        mgr.selectPreviousTab()
        #expect(mgr.activeTabIndex == 2)

        mgr.selectNextTab()
        #expect(mgr.activeTabIndex == 0)
    }

    @Test func moveTabInSession() {
        let mgr = makeManager()
        _ = mgr.createSession()
        let id1 = mgr.tabs.first!.id
        let id2 = mgr.createTab(title: "tab2")

        mgr.selectTab(at: 0)
        mgr.moveTab(from: 0, to: 1)
        #expect(mgr.tabs[0].id == id2)
        #expect(mgr.tabs[1].id == id1)
        #expect(mgr.activeTabIndex == 1)
    }

    // MARK: - Pane Operations Within Session

    @Test func splitPaneInSession() {
        let mgr = makeManager()
        _ = mgr.createSession()
        guard let rootPaneID = mgr.activeTab?.paneTree.firstPane.id else {
            Issue.record("No active tab")
            return
        }

        let newPane = TerminalPane()
        let result = mgr.splitPane(id: rootPaneID, direction: .vertical, newPane: newPane)
        #expect(result)
        #expect(mgr.activeTab?.allPaneIDs.count == 2)
    }

    @Test func closePaneInSession() {
        let mgr = makeManager()
        _ = mgr.createSession()
        guard let rootPaneID = mgr.activeTab?.paneTree.firstPane.id else {
            Issue.record("No active tab")
            return
        }

        let newPane = TerminalPane()
        mgr.splitPane(id: rootPaneID, direction: .vertical, newPane: newPane)

        let siblingID = mgr.closePane(id: newPane.id)
        #expect(siblingID == rootPaneID)
        #expect(mgr.activeTab?.allPaneIDs.count == 1)
    }

    @Test func closeLastPaneClosesTab() {
        let mgr = makeManager()
        _ = mgr.createSession()
        _ = mgr.createTab(title: "tab2")
        #expect(mgr.tabCount == 2)

        guard let rootPaneID = mgr.activeTab?.paneTree.firstPane.id else {
            Issue.record("No active tab")
            return
        }

        let siblingID = mgr.closePane(id: rootPaneID)
        #expect(siblingID == nil)
        #expect(mgr.tabCount == 1)
    }

    // MARK: - Floating Pane Operations

    @Test func createFloatingPaneInSession() {
        let mgr = makeManager()
        _ = mgr.createSession()

        let paneID = mgr.createFloatingPane()
        #expect(paneID != nil)
        #expect(mgr.activeTab?.floatingPanes.count == 1)
    }

    @Test func closeFloatingPaneInSession() {
        let mgr = makeManager()
        _ = mgr.createSession()

        guard let paneID = mgr.createFloatingPane() else {
            Issue.record("Failed to create floating pane")
            return
        }

        let removed = mgr.closeFloatingPane(paneID: paneID)
        #expect(removed)
        #expect(mgr.activeTab?.floatingPanes.isEmpty == true)
    }

    @Test func floatingPanesScopedToSession() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "s1")
        _ = mgr.createFloatingPane()
        #expect(mgr.activeTab?.floatingPanes.count == 1)

        _ = mgr.createSession(name: "s2")
        #expect(mgr.activeTab?.floatingPanes.isEmpty == true)

        mgr.selectSession(at: 0)
        #expect(mgr.activeTab?.floatingPanes.count == 1)
    }

    // MARK: - Title Updates

    @Test func updateTabTitle() {
        let mgr = makeManager()
        _ = mgr.createSession()
        guard let tabID = mgr.activeTab?.id else {
            Issue.record("No active tab")
            return
        }

        mgr.updateTitle("vim", for: tabID)
        #expect(mgr.tabs[0].title == "vim")
    }

    // MARK: - handleAction

    @Test func handleActionNewTab() {
        let mgr = makeManager()
        _ = mgr.createSession()
        #expect(mgr.handleAction(.newTab))
        #expect(mgr.tabCount == 2)
    }

    @Test func handleActionNewSession() {
        let mgr = makeManager()
        _ = mgr.createSession()
        #expect(mgr.handleAction(.newSession))
        #expect(mgr.sessionCount == 2)
    }

    @Test func handleActionSessionActionsReturnFalse() {
        let mgr = makeManager()
        _ = mgr.createSession()

        // These actions are handled by TerminalWindowView.
        #expect(!mgr.handleAction(.closeSession))
        #expect(!mgr.handleAction(.previousSession))
        #expect(!mgr.handleAction(.nextSession))
        #expect(!mgr.handleAction(.toggleSidebar))
    }

    @Test func handleActionPaneActionsReturnFalse() {
        let mgr = makeManager()
        _ = mgr.createSession()

        #expect(!mgr.handleAction(.splitVertical))
        #expect(!mgr.handleAction(.closePane))
    }

    // MARK: - Local Session Attach / Detach

    @Test func localSessionStartsAttached() {
        let mgr = makeManager()
        let id = mgr.createSession(name: "local")
        #expect(mgr.attachedLocalSessionIDs.contains(id))
        #expect(mgr.activeSessionDisplayState == .ready)
    }

    @Test func localSessionCanDetachAndAttach() {
        let mgr = makeManager()
        let id = mgr.createSession(name: "local")

        mgr.detachLocalSession(sessionID: id)
        #expect(!mgr.attachedLocalSessionIDs.contains(id))
        #expect(mgr.isSessionDetached(at: 0))
        #expect(mgr.activeSessionDisplayState == .detached)

        mgr.attachLocalSession(sessionID: id)
        #expect(mgr.attachedLocalSessionIDs.contains(id))
        #expect(!mgr.isSessionDetached(at: 0))
        #expect(mgr.activeSessionDisplayState == .ready)
    }

    @Test func localControllerCreatedOnAttach() {
        let mgr = makeManager()
        let id = mgr.createSession(name: "local")
        let paneID = mgr.activeTab!.paneTree.firstPane.id

        mgr.detachLocalSession(sessionID: id)
        #expect(mgr.controller(for: paneID) == nil)

        mgr.attachLocalSession(sessionID: id)
        #expect(mgr.controller(for: paneID) != nil)
    }

    // MARK: - Session Reordering

    @Test func moveSessionForward() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "s1")
        _ = mgr.createSession(name: "s2")
        _ = mgr.createSession(name: "s3")

        mgr.moveSession(from: 0, to: 2)

        #expect(mgr.sessions[0].name == "s2")
        #expect(mgr.sessions[1].name == "s3")
        #expect(mgr.sessions[2].name == "s1")
    }

    @Test func moveSessionBackward() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "s1")
        _ = mgr.createSession(name: "s2")
        _ = mgr.createSession(name: "s3")

        mgr.moveSession(from: 2, to: 0)

        #expect(mgr.sessions[0].name == "s3")
        #expect(mgr.sessions[1].name == "s1")
        #expect(mgr.sessions[2].name == "s2")
    }

    @Test func moveSessionUpdatesActiveIndex() {
        let mgr = makeManager()
        _ = mgr.createSession(name: "s1")
        _ = mgr.createSession(name: "s2")
        _ = mgr.createSession(name: "s3")

        mgr.selectSession(at: 2)
        mgr.moveSession(from: 2, to: 0)

        #expect(mgr.activeSessionIndex == 0)
        #expect(mgr.activeSession?.name == "s3")
    }

    // MARK: - Session Order Persistence

    @Test func sessionOrderPersistsAcrossManagers() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let store = SessionStore(directory: tempDir)

        let mgr1 = SessionManager(localSessionStore: store)
        _ = mgr1.createSession(name: "s1")
        _ = mgr1.createSession(name: "s2")
        _ = mgr1.createSession(name: "s3")
        mgr1.moveSession(from: 2, to: 0)
        mgr1.flushPendingLocalSaves()

        let mgr2 = SessionManager(localSessionStore: store)
        mgr2.restoreLocalSessions()

        #expect(mgr2.sessions[0].name == "s3")
        #expect(mgr2.sessions[1].name == "s1")
        #expect(mgr2.sessions[2].name == "s2")
    }

    @Test func sessionOrderSurvivesAfterClose() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let store = SessionStore(directory: tempDir)

        let mgr = SessionManager(localSessionStore: store)
        _ = mgr.createSession(name: "s1")
        _ = mgr.createSession(name: "s2")
        let id3 = mgr.createSession(name: "s3")
        mgr.moveSession(from: 2, to: 0)
        mgr.flushPendingLocalSaves()

        mgr.closeSession(at: 0) // closes s3

        let mgr2 = SessionManager(localSessionStore: store)
        mgr2.restoreLocalSessions()

        #expect(mgr2.sessions[0].name == "s1")
        #expect(mgr2.sessions[1].name == "s2")
        #expect(!mgr2.sessions.contains { $0.id == id3 })
    }

    // MARK: - Local Session Persistence

    @Test func localSessionPersistenceRoundTrip() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let store = SessionStore(directory: tempDir)

        let mgr1 = SessionManager(localSessionStore: store)
        let id = mgr1.createSession(name: "persisted")
        _ = mgr1.createTab(title: "tab2")
        mgr1.flushPendingLocalSaves()

        let mgr2 = SessionManager(localSessionStore: store)
        mgr2.restoreLocalSessions()
        #expect(mgr2.sessionCount == 1)
        #expect(mgr2.sessions[0].name == "persisted")
        #expect(mgr2.sessions[0].tabs.count == 2)
        #expect(mgr2.sessions[0].tabs[1].title == "tab2")
        #expect(!mgr2.attachedLocalSessionIDs.contains(id))
    }

    @Test func localSessionSplitPanePersistence() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let store = SessionStore(directory: tempDir)

        let mgr1 = SessionManager(localSessionStore: store)
        _ = mgr1.createSession()
        let rootPane = mgr1.activeTab!.paneTree.firstPane
        mgr1.splitPane(id: rootPane.id, direction: .vertical, newPane: TerminalPane())
        mgr1.flushPendingLocalSaves()

        let mgr2 = SessionManager(localSessionStore: store)
        mgr2.restoreLocalSessions()
        #expect(mgr2.sessions[0].tabs[0].paneTree.paneCount == 2)
    }

    @Test func closeLocalSessionDeletesPersistence() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let store = SessionStore(directory: tempDir)

        let mgr = SessionManager(localSessionStore: store)
        _ = mgr.createSession()
        mgr.flushPendingLocalSaves()
        #expect(store.loadAll().count == 1)

        _ = mgr.closeActiveSession()
        #expect(store.loadAll().isEmpty)
    }

    // MARK: - Anonymous Session

    @Test func createAnonymousSessionHasDraftName() {
        let mgr = makeManager()
        let id = mgr.createAnonymousSession()
        #expect(mgr.sessionCount == 1)
        #expect(mgr.activeSession?.id == id)
        #expect(mgr.activeSession?.name == "Draft")
        #expect(mgr.activeSession?.isAnonymous == true)
    }

    @Test func renamingAnonymousSessionMakesItPersistent() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let store = SessionStore(directory: tempDir)

        let mgr = SessionManager(localSessionStore: store)
        let id = mgr.createAnonymousSession()
        mgr.renameSession(at: 0, to: "persistent")
        #expect(mgr.sessions.first { $0.id == id }?.isAnonymous == false)
        #expect(mgr.sessions.first { $0.id == id }?.name == "persistent")
        mgr.flushPendingLocalSaves()

        let mgr2 = SessionManager(localSessionStore: store)
        mgr2.restoreLocalSessions()
        #expect(mgr2.sessionCount == 1)
        #expect(mgr2.sessions[0].name == "persistent")
        #expect(mgr2.sessions[0].id == id)
    }

    @Test func renamingAnonymousSessionPreservesActiveIndex() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let store = SessionStore(directory: tempDir)

        let mgr = SessionManager(localSessionStore: store)
        let id1 = mgr.createSession(name: "s1")
        let id2 = mgr.createAnonymousSession()
        mgr.selectSession(at: 0)

        mgr.renameSession(at: 1, to: "s2")
        #expect(mgr.activeSession?.id == id1)
        #expect(mgr.sessions.contains { $0.id == id2 && $0.name == "s2" && !$0.isAnonymous })
    }

    @Test func anonymousSessionIsNotPersisted() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let store = SessionStore(directory: tempDir)

        let mgr = SessionManager(localSessionStore: store)
        _ = mgr.createAnonymousSession()
        mgr.flushPendingLocalSaves()

        #expect(store.loadAll().isEmpty)
    }

    @Test func anonymousSessionNotInSortOrder() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let store = SessionStore(directory: tempDir)

        let mgr = SessionManager(localSessionStore: store)
        let id1 = mgr.createSession(name: "s1")
        let id2 = mgr.createAnonymousSession()
        let id3 = mgr.createSession(name: "s2")
        mgr.flushPendingLocalSaves()

        let anonymousIndex = mgr.sessions.firstIndex(where: { $0.id == id2 })!
        mgr.closeSession(at: anonymousIndex) // close anonymous

        let mgr2 = SessionManager(localSessionStore: store)
        mgr2.restoreLocalSessions()
        mgr2.flushPendingLocalSaves()

        #expect(mgr2.sessionCount == 2)
        #expect(mgr2.sessions.contains { $0.id == id1 })
        #expect(mgr2.sessions.contains { $0.id == id3 })
        #expect(!mgr2.sessions.contains { $0.id == id2 })
    }

    @Test func anonymousSessionTabOperationsDoNotPersist() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let store = SessionStore(directory: tempDir)

        let mgr = SessionManager(localSessionStore: store)
        _ = mgr.createAnonymousSession()
        _ = mgr.createTab(title: "tab2")
        mgr.splitPane(id: mgr.activeTab!.paneTree.firstPane.id, direction: .vertical, newPane: TerminalPane())
        mgr.flushPendingLocalSaves()

        #expect(store.loadAll().isEmpty)
    }

    @Test func closingAnonymousSessionDoesNotAffectPersistence() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let store = SessionStore(directory: tempDir)

        let mgr = SessionManager(localSessionStore: store)
        _ = mgr.createSession(name: "persisted")
        _ = mgr.createAnonymousSession()
        mgr.flushPendingLocalSaves()

        #expect(store.loadAll().count == 1)

        mgr.closeSession(at: 1) // close anonymous
        #expect(store.loadAll().count == 1)
    }
}

@Suite("SessionManager Overlay Stack", .serialized)
struct SessionManagerOverlayStackTests {

    private func makeManager() -> SessionManager {
        let store = SessionStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .path
        )
        return SessionManager(localSessionStore: store)
    }

    @Test @MainActor
    func runInPlacePushesOverlayController() async {
        let mgr = makeManager()
        _ = mgr.createSession()
        let paneID = mgr.activeTab!.paneTree.firstPane.id
        _ = mgr.ensureLocalController(for: paneID)

        await mgr.runInPlace(at: paneID, command: "/bin/sleep", arguments: ["10"])

        let active = mgr.activeController(for: paneID)
        #expect(active != nil)
        #expect(active !== mgr.controller(for: paneID))

        mgr.closeActiveSession()
    }

    @Test @MainActor
    func restoreFromInPlaceResumesBaseController() async {
        let mgr = makeManager()
        _ = mgr.createSession()
        let paneID = mgr.activeTab!.paneTree.firstPane.id
        let base = mgr.ensureLocalController(for: paneID)

        await mgr.runInPlace(at: paneID, command: "/bin/sleep", arguments: ["10"])

        let overlay = mgr.activeController(for: paneID) as? TerminalController
        #expect(overlay !== base)
        #expect(base.isSuspended)

        overlay?.onProcessExited?()

        #expect(mgr.activeController(for: paneID) === base)
        #expect(!base.isSuspended)

        base.stop()
    }

    @Test @MainActor
    func nestedRunInPlaceStacksOverlays() async {
        let mgr = makeManager()
        _ = mgr.createSession()
        let paneID = mgr.activeTab!.paneTree.firstPane.id
        let base = mgr.ensureLocalController(for: paneID)

        await mgr.runInPlace(at: paneID, command: "/bin/sleep", arguments: ["10"])
        let overlay1 = mgr.activeController(for: paneID) as? TerminalController
        #expect(overlay1 !== base)

        await mgr.runInPlace(at: paneID, command: "/bin/sleep", arguments: ["10"])
        let overlay2 = mgr.activeController(for: paneID) as? TerminalController
        #expect(overlay2 !== overlay1)
        #expect(overlay1?.isSuspended == true)

        overlay2?.onProcessExited?()
        #expect(mgr.activeController(for: paneID) === overlay1)
        #expect(overlay1?.isSuspended == false)

        overlay1?.onProcessExited?()
        #expect(mgr.activeController(for: paneID) === base)
        #expect(!base.isSuspended)

        base.stop()
    }

    @Test @MainActor
    func closePaneStopsAllControllers() async {
        let mgr = makeManager()
        _ = mgr.createSession()
        let paneID = mgr.activeTab!.paneTree.firstPane.id
        _ = mgr.ensureLocalController(for: paneID)

        await mgr.runInPlace(at: paneID, command: "/bin/sleep", arguments: ["10"])
        #expect(mgr.activeController(for: paneID) != nil)

        _ = mgr.closePane(id: paneID)

        #expect(mgr.activeController(for: paneID) == nil)
    }
}
