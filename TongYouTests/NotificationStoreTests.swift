import Foundation
import Testing
import TYServer
import TYTerminal
@testable import TongYou

@Suite("NotificationStore", .serialized)
struct NotificationStoreTests {

    private func makeStore() -> NotificationStore {
        let store = NotificationStore()
        store.reset()
        return store
    }

    // MARK: - Add

    @Test func testAddNotification() {
        let store = makeStore()
        let sessionID = UUID()
        let tabID = UUID()
        let paneID = UUID()

        store.add(
            sessionID: sessionID,
            tabID: tabID,
            paneID: paneID,
            title: "title",
            body: "body"
        )

        #expect(store.items.count == 1)
        #expect(store.unreadPaneIDs.contains(paneID))
        #expect(store.unreadCountByTabID[tabID] == 1)
        #expect(store.unreadCountBySessionID[sessionID] == 1)
    }

    @Test func testCooldown() {
        let store = makeStore()
        let sessionID = UUID()
        let tabID = UUID()
        let paneID = UUID()

        store.add(
            sessionID: sessionID,
            tabID: tabID,
            paneID: paneID,
            title: "t1",
            body: "b1",
            cooldownKey: "same-key",
            cooldownInterval: 5
        )
        store.add(
            sessionID: sessionID,
            tabID: tabID,
            paneID: paneID,
            title: "t2",
            body: "b2",
            cooldownKey: "same-key",
            cooldownInterval: 5
        )

        #expect(store.items.count == 1)
        #expect(store.items.first?.title == "t1")
    }

    // MARK: - Mark Read

    @Test func testMarkReadPane() {
        let store = makeStore()
        let sessionID = UUID()
        let tabID = UUID()
        let paneID = UUID()

        store.add(
            sessionID: sessionID,
            tabID: tabID,
            paneID: paneID,
            title: "title",
            body: "body"
        )
        #expect(store.unreadPaneIDs.contains(paneID))

        store.markRead(paneID: paneID)

        #expect(!store.unreadPaneIDs.contains(paneID))
        #expect(store.unreadCountByTabID[tabID] == nil)
        #expect(store.unreadCountBySessionID[sessionID] == nil)
        #expect(store.items.first?.isRead == true)
    }

    // MARK: - Clear All

    @Test func testClearAllForTab() {
        let store = makeStore()
        let sessionID = UUID()
        let tab1 = UUID()
        let tab2 = UUID()
        let pane1 = UUID()
        let pane2 = UUID()

        store.add(sessionID: sessionID, tabID: tab1, paneID: pane1, title: "", body: "")
        store.add(sessionID: sessionID, tabID: tab2, paneID: pane2, title: "", body: "")

        store.clearAll(forTabID: tab1)

        #expect(store.items.count == 1)
        #expect(store.items.first?.tabID == tab2)
        #expect(store.unreadCountByTabID[tab1] == nil)
        #expect(store.unreadCountByTabID[tab2] == 1)
    }

    @Test func testClearAllForPaneID() {
        let store = makeStore()
        let sessionID = UUID()
        let tabID = UUID()
        let pane1 = UUID()
        let pane2 = UUID()

        store.add(sessionID: sessionID, tabID: tabID, paneID: pane1, title: "", body: "")
        store.add(sessionID: sessionID, tabID: tabID, paneID: pane2, title: "", body: "")

        store.clearAll(forPaneID: pane1)

        #expect(store.items.count == 1)
        #expect(store.items.first?.paneID == pane2)
    }

    @Test func testClearAllForSessionID() {
        let store = makeStore()
        let session1 = UUID()
        let session2 = UUID()
        let tabID = UUID()
        let paneID = UUID()

        store.add(sessionID: session1, tabID: tabID, paneID: paneID, title: "", body: "")
        store.add(sessionID: session2, tabID: tabID, paneID: paneID, title: "", body: "")

        store.clearAll(forSessionID: session1)

        #expect(store.items.count == 1)
        #expect(store.items.first?.sessionID == session2)
    }
}

@Suite("SessionManager Pane Owner IDs")
struct SessionManagerPaneOwnerTests {

    private func makeManager() -> SessionManager {
        let store = SessionStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .path
        )
        return SessionManager(localSessionStore: store)
    }

    @Test func paneOwnerIDsFindsTreePane() {
        let mgr = makeManager()
        let sessionID = mgr.createSession()
        let tabID = mgr.activeTab!.id
        let paneID = mgr.activeTab!.paneTree.firstPane.id

        let result = mgr.paneOwnerIDs(paneID: paneID)

        #expect(result?.sessionID == sessionID)
        #expect(result?.tabID == tabID)
    }

    @Test func paneOwnerIDsFindsFloatingPane() {
        let mgr = makeManager()
        let sessionID = mgr.createSession()
        let tabID = mgr.activeTab!.id
        let paneID = mgr.createFloatingPane()!

        let result = mgr.paneOwnerIDs(paneID: paneID)

        #expect(result?.sessionID == sessionID)
        #expect(result?.tabID == tabID)
    }

    @Test func paneOwnerIDsReturnsNilForUnknownPane() {
        let mgr = makeManager()
        _ = mgr.createSession()

        let result = mgr.paneOwnerIDs(paneID: UUID())

        #expect(result == nil)
    }
}
