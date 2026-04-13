import Testing
import Foundation
@testable import TYServer
import TYProtocol

@Suite("SessionStore Tests", .serialized)
struct SessionStoreTests {

    private func makeTempDir() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
    }

    @Test("Load all returns empty array for missing directory")
    func loadAllMissingDirectory() {
        let store = SessionStore(directory: "/nonexistent/path/\(UUID().uuidString)")
        let sessions = store.loadAll()
        #expect(sessions.isEmpty)
    }

    @Test("Save and load roundtrip")
    func saveAndLoad() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let store = SessionStore(directory: tempDir)
        let sessionID = SessionID()
        let paneID = PaneID()
        let session = PersistedSession(
            sessionInfo: SessionInfo(
                id: sessionID,
                name: "Test",
                tabs: [
                    TabInfo(
                        id: TabID(),
                        title: "Tab",
                        layout: .leaf(paneID),
                        floatingPanes: [FloatingPaneInfo(paneID: PaneID())],
                        focusedPaneID: paneID
                    )
                ],
                activeTabIndex: 0
            ),
            paneContexts: [
                paneID: PersistedPaneContext(cwd: "/home/user")
            ]
        )

        store.save(session)
        let loaded = store.loadAll()

        #expect(loaded.count == 1)
        #expect(loaded.first?.sessionInfo.id == sessionID)
        #expect(loaded.first?.sessionInfo.name == "Test")
        #expect(loaded.first?.paneContexts[paneID]?.cwd == "/home/user")
    }

    @Test("Delete removes persisted file")
    func deleteRemovesFile() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let store = SessionStore(directory: tempDir)
        let sessionID = SessionID()
        let session = PersistedSession(
            sessionInfo: SessionInfo(id: sessionID, name: "Delete Me", tabs: []),
            paneContexts: [:]
        )

        store.save(session)
        #expect(store.loadAll().count == 1)

        store.delete(sessionID: sessionID)
        #expect(store.loadAll().isEmpty)
    }

    @Test("Multiple sessions are loaded independently")
    func multipleSessions() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let store = SessionStore(directory: tempDir)
        let idA = SessionID()
        let idB = SessionID()

        store.save(PersistedSession(
            sessionInfo: SessionInfo(id: idA, name: "A", tabs: []),
            paneContexts: [:]
        ))
        store.save(PersistedSession(
            sessionInfo: SessionInfo(id: idB, name: "B", tabs: []),
            paneContexts: [:]
        ))

        let loaded = store.loadAll()
        #expect(loaded.count == 2)
        #expect(Set(loaded.map(\.sessionInfo.name)) == Set(["A", "B"]))

        store.delete(sessionID: idA)
        #expect(store.loadAll().count == 1)
        #expect(store.loadAll().first?.sessionInfo.name == "B")
    }
}
