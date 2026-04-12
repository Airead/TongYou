import Testing
import Foundation
@testable import TYServer
import TYProtocol
import TYTerminal

@Suite("ServerSessionManager Tests")
struct ServerSessionManagerTests {

    @Test("Create session returns valid SessionInfo")
    func createSession() {
        let manager = ServerSessionManager()
        let info = manager.createSession(name: "Test Session")

        #expect(info.name == "Test Session")
        #expect(info.tabs.count == 1)
        #expect(info.activeTabIndex == 0)

        // The tab should have a leaf layout with one pane
        if case .leaf = info.tabs[0].layout {
            // OK
        } else {
            Issue.record("Expected leaf layout for single-pane tab")
        }
    }

    @Test("Create session with default name")
    func createSessionDefaultName() {
        let manager = ServerSessionManager()
        let info = manager.createSession()
        #expect(info.name == "Session 1")
    }

    @Test("List sessions returns all sessions")
    func listSessions() {
        let manager = ServerSessionManager()
        _ = manager.createSession(name: "A")
        _ = manager.createSession(name: "B")

        let sessions = manager.listSessions()
        #expect(sessions.count == 2)
        #expect(Set(sessions.map(\.name)) == Set(["A", "B"]))
    }

    @Test("Close session removes it")
    func closeSession() {
        let manager = ServerSessionManager()
        let info = manager.createSession(name: "Test")

        #expect(manager.hasSessions == true)
        #expect(manager.sessionCount == 1)

        manager.closeSession(id: info.id)

        #expect(manager.hasSessions == false)
        #expect(manager.sessionCount == 0)
    }

    @Test("sessionInfo returns correct info")
    func sessionInfo() {
        let manager = ServerSessionManager()
        let info = manager.createSession(name: "Query Test")

        let queried = manager.sessionInfo(for: info.id)
        #expect(queried != nil)
        #expect(queried?.name == "Query Test")
        #expect(queried?.id == info.id)
    }

    @Test("sessionInfo returns nil for unknown ID")
    func sessionInfoUnknown() {
        let manager = ServerSessionManager()
        let result = manager.sessionInfo(for: SessionID())
        #expect(result == nil)
    }

    @Test("Create tab adds to session")
    func createTab() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Tab Test")

        let tabID = manager.createTab(sessionID: session.id)
        #expect(tabID != nil)

        let info = manager.sessionInfo(for: session.id)
        #expect(info?.tabs.count == 2)
        #expect(info?.activeTabIndex == 1)
    }

    @Test("Create tab returns nil for unknown session")
    func createTabUnknownSession() {
        let manager = ServerSessionManager()
        let tabID = manager.createTab(sessionID: SessionID())
        #expect(tabID == nil)
    }

    @Test("Close tab removes tab from session")
    func closeTab() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Tab Close Test")
        let tabID = manager.createTab(sessionID: session.id)!

        manager.closeTab(sessionID: session.id, tabID: tabID)

        let info = manager.sessionInfo(for: session.id)
        #expect(info?.tabs.count == 1)
    }

    @Test("Close last tab removes session")
    func closeLastTab() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Last Tab")
        let tabID = session.tabs[0].id

        manager.closeTab(sessionID: session.id, tabID: tabID)

        #expect(manager.hasSessions == false)
    }

    @Test("Split pane creates new pane in tree")
    func splitPane() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Split Test")

        // Get the initial pane ID from the layout
        guard case .leaf(let firstPaneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let newPaneID = manager.splitPane(
            sessionID: session.id,
            paneID: firstPaneID,
            direction: .vertical
        )
        #expect(newPaneID != nil)

        let info = manager.sessionInfo(for: session.id)
        if case .split(let dir, _, _, _) = info?.tabs[0].layout {
            #expect(dir == .vertical)
        } else {
            Issue.record("Expected split layout after splitting pane")
        }
    }

    @Test("Close pane removes from tree")
    func closePane() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Close Pane Test")
        guard case .leaf(let firstPaneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let newPaneID = manager.splitPane(
            sessionID: session.id,
            paneID: firstPaneID,
            direction: .horizontal
        )!

        manager.closePane(sessionID: session.id, paneID: newPaneID)

        let info = manager.sessionInfo(for: session.id)
        if case .leaf = info?.tabs[0].layout {
            // OK — back to single pane
        } else {
            Issue.record("Expected leaf layout after closing split pane")
        }
    }

    @Test("allPaneIDs returns all panes in session")
    func allPaneIDs() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "All Panes Test")
        guard case .leaf(let firstPaneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        _ = manager.splitPane(
            sessionID: session.id,
            paneID: firstPaneID,
            direction: .vertical
        )

        let paneIDs = manager.allPaneIDs(sessionID: session.id)
        #expect(paneIDs.count == 2)
    }

    @Test("sendInput does not crash with valid pane")
    func sendInput() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Input Test")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        // Wait for PTY to start
        Thread.sleep(forTimeInterval: 0.2)

        // Should not crash
        manager.sendInput(paneID: paneID, data: Array("ls\n".utf8))

        manager.closeSession(id: session.id)
    }

    @Test("resizePane does not crash")
    func resizePane() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Resize Test")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        manager.resizePane(paneID: paneID, cols: 120, rows: 40)

        Thread.sleep(forTimeInterval: 0.1)

        manager.closeSession(id: session.id)
    }

    @Test("snapshot returns full snapshot for pane")
    func snapshot() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Snapshot Test")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        Thread.sleep(forTimeInterval: 0.2)

        let snap = manager.snapshot(paneID: paneID)
        #expect(snap != nil)
        #expect(snap?.columns == 80) // default
        #expect(snap?.rows == 24)    // default

        manager.closeSession(id: session.id)
    }

    @Test("onScreenDirty callback fires with correct IDs")
    func onScreenDirtyCallback() {
        let manager = ServerSessionManager()

        let receivedPairs = Mutex<[(SessionID, PaneID)]>([])
        manager.onScreenDirty = { sessionID, paneID in
            receivedPairs.withLock { $0.append((sessionID, paneID)) }
        }

        let session = manager.createSession(name: "Dirty Callback Test")

        // Send a command to trigger output
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }
        // Wait for PTY to be ready, then send a command to trigger output
        Thread.sleep(forTimeInterval: 0.2)
        manager.sendInput(paneID: paneID, data: Array("echo test\n".utf8))

        // Poll for the callback with a timeout
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)
            if receivedPairs.withLock({ !$0.isEmpty }) { break }
        }

        let pairs = receivedPairs.withLock { $0 }
        #expect(!pairs.isEmpty)
        if !pairs.isEmpty {
            #expect(pairs[0].0 == session.id)
        }

        manager.closeSession(id: session.id)
    }
}

/// Simple thread-safe wrapper for test assertions.
private final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
