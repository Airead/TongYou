import Testing
import Foundation
@testable import TYServer
import TYProtocol
import TYTerminal

@Suite("ServerSessionManager Tests", .serialized)
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

        manager.closeSession(id: info.id)
    }

    @Test("Create session with default name")
    func createSessionDefaultName() {
        let manager = ServerSessionManager()
        let info = manager.createSession()
        #expect(info.name == "Session 1")
        manager.closeSession(id: info.id)
    }

    @Test("List sessions returns all sessions")
    func listSessions() {
        let manager = ServerSessionManager()
        let a = manager.createSession(name: "A")
        let b = manager.createSession(name: "B")

        let sessions = manager.listSessions()
        #expect(sessions.count == 2)
        #expect(Set(sessions.map(\.name)) == Set(["A", "B"]))

        manager.closeSession(id: a.id)
        manager.closeSession(id: b.id)
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

        manager.closeSession(id: info.id)
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

        manager.closeSession(id: session.id)
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

        manager.closeSession(id: session.id)
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

        manager.closeSession(id: session.id)
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

        manager.closeSession(id: session.id)
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

        manager.closeSession(id: session.id)
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

    // MARK: - Floating Pane Operations

    @Test("Create floating pane adds to tab")
    func createFloatingPane() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Float Test")
        let tabID = session.tabs[0].id

        let fpID = manager.createFloatingPane(sessionID: session.id, tabID: tabID)
        #expect(fpID != nil)

        let info = manager.sessionInfo(for: session.id)
        #expect(info?.tabs[0].floatingPanes.count == 1)
        #expect(info?.tabs[0].floatingPanes[0].paneID == fpID)
        #expect(info?.tabs[0].floatingPanes[0].title == "Float")

        manager.closeSession(id: session.id)
    }

    @Test("Create floating pane returns nil for unknown tab")
    func createFloatingPaneUnknownTab() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Float Unknown Tab")

        let fpID = manager.createFloatingPane(sessionID: session.id, tabID: TabID())
        #expect(fpID == nil)

        manager.closeSession(id: session.id)
    }

    @Test("Close floating pane removes from tab")
    func closeFloatingPane() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Float Close Test")
        let tabID = session.tabs[0].id

        let fpID = manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        manager.closeFloatingPane(sessionID: session.id, paneID: fpID)

        let info = manager.sessionInfo(for: session.id)
        #expect(info?.tabs[0].floatingPanes.isEmpty == true)

        manager.closeSession(id: session.id)
    }

    @Test("Update floating pane frame persists")
    func updateFloatingPaneFrame() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Float Frame Test")
        let tabID = session.tabs[0].id

        let fpID = manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        manager.updateFloatingPaneFrame(
            sessionID: session.id, paneID: fpID,
            x: 0.1, y: 0.2, width: 0.5, height: 0.6
        )

        let info = manager.sessionInfo(for: session.id)
        let fp = info?.tabs[0].floatingPanes[0]
        #expect(fp?.frameX == Float(0.1))
        #expect(fp?.frameY == Float(0.2))
        #expect(fp?.frameWidth == Float(0.5))
        #expect(fp?.frameHeight == Float(0.6))

        manager.closeSession(id: session.id)
    }

    @Test("Bring floating pane to front updates zIndex")
    func bringFloatingPaneToFront() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Float ZIndex Test")
        let tabID = session.tabs[0].id

        let fp1 = manager.createFloatingPane(sessionID: session.id, tabID: tabID)!
        let fp2 = manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        // fp2 should have higher zIndex than fp1
        var info = manager.sessionInfo(for: session.id)!
        let z1Before = info.tabs[0].floatingPanes.first(where: { $0.paneID == fp1 })!.zIndex
        let z2Before = info.tabs[0].floatingPanes.first(where: { $0.paneID == fp2 })!.zIndex
        #expect(z2Before > z1Before)

        // Bring fp1 to front
        manager.bringFloatingPaneToFront(sessionID: session.id, paneID: fp1)

        info = manager.sessionInfo(for: session.id)!
        let z1After = info.tabs[0].floatingPanes.first(where: { $0.paneID == fp1 })!.zIndex
        #expect(z1After > z2Before)

        manager.closeSession(id: session.id)
    }

    @Test("Toggle floating pane pin")
    func toggleFloatingPanePin() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Float Pin Test")
        let tabID = session.tabs[0].id

        let fpID = manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        var info = manager.sessionInfo(for: session.id)!
        #expect(info.tabs[0].floatingPanes[0].isPinned == false)

        manager.toggleFloatingPanePin(sessionID: session.id, paneID: fpID)

        info = manager.sessionInfo(for: session.id)!
        #expect(info.tabs[0].floatingPanes[0].isPinned == true)

        manager.closeSession(id: session.id)
    }

    @Test("allPaneIDs includes floating panes")
    func allPaneIDsIncludesFloatingPanes() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "All IDs Float Test")
        let tabID = session.tabs[0].id

        let fpID = manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        let allIDs = manager.allPaneIDs(sessionID: session.id)
        #expect(allIDs.count == 2) // 1 tree pane + 1 floating pane
        #expect(allIDs.contains(fpID))

        manager.closeSession(id: session.id)
    }

    @Test("Floating pane I/O works via coreLookup")
    func floatingPaneIO() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Float IO Test")
        let tabID = session.tabs[0].id

        let fpID = manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        // Wait for PTY to start
        Thread.sleep(forTimeInterval: 0.2)

        // Should not crash — confirms the pane is in coreLookup
        manager.sendInput(paneID: fpID, data: Array("echo hello\n".utf8))

        let snap = manager.snapshot(paneID: fpID)
        #expect(snap != nil)
        #expect(snap?.columns == 80)
        #expect(snap?.rows == 24)

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

    // MARK: - Multi-Client Size Negotiation

    @Test("registerClientSize with single client uses that client's size")
    func registerClientSizeSingleClient() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Size Single")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        let result = manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 120, rows: 40)

        #expect(result?.cols == 120)
        #expect(result?.rows == 40)

        manager.closeSession(id: session.id)
    }

    @Test("registerClientSize with two clients uses minimum")
    func registerClientSizeMinimum() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Size Min")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        let clientB = UUID()
        manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 120, rows: 40)
        let result = manager.registerClientSize(clientID: clientB, paneID: paneID, cols: 80, rows: 24)

        #expect(result?.cols == 80)
        #expect(result?.rows == 24)

        manager.closeSession(id: session.id)
    }

    @Test("registerClientSize picks min per dimension independently")
    func registerClientSizeMinPerDimension() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Size Mixed")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        let clientB = UUID()
        // A: wide but short. B: narrow but tall.
        manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 200, rows: 20)
        let result = manager.registerClientSize(clientID: clientB, paneID: paneID, cols: 80, rows: 50)

        #expect(result?.cols == 80)
        #expect(result?.rows == 20)

        manager.closeSession(id: session.id)
    }

    @Test("removeClientFromPane recalculates size for remaining clients")
    func removeClientFromPaneRecalculates() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Size Remove")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        let clientB = UUID()
        manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 120, rows: 40)
        manager.registerClientSize(clientID: clientB, paneID: paneID, cols: 80, rows: 24)

        // Remove the smaller client — effective size should grow back to A's size
        manager.removeClientFromPane(clientID: clientB, paneID: paneID)

        // Re-register A to verify the effective size (registerClientSize returns current effective)
        let result = manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 120, rows: 40)
        #expect(result?.cols == 120)
        #expect(result?.rows == 40)

        manager.closeSession(id: session.id)
    }

    @Test("removeClientFromAllPanes cleans up all panes")
    func removeClientFromAllPanes() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Size RemoveAll")
        guard case .leaf(let paneID1) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        // Create a second pane via split
        guard let paneID2 = manager.splitPane(
            sessionID: session.id, paneID: paneID1, direction: .vertical
        ) else {
            Issue.record("Split failed")
            return
        }

        let clientA = UUID()
        let clientB = UUID()
        manager.registerClientSize(clientID: clientA, paneID: paneID1, cols: 120, rows: 40)
        manager.registerClientSize(clientID: clientB, paneID: paneID1, cols: 80, rows: 24)
        manager.registerClientSize(clientID: clientA, paneID: paneID2, cols: 100, rows: 30)
        manager.registerClientSize(clientID: clientB, paneID: paneID2, cols: 60, rows: 20)

        // Remove client B from all panes
        manager.removeClientFromAllPanes(clientID: clientB)

        // Only client A remains — verify by re-registering
        let r1 = manager.registerClientSize(clientID: clientA, paneID: paneID1, cols: 120, rows: 40)
        #expect(r1?.cols == 120)
        #expect(r1?.rows == 40)

        let r2 = manager.registerClientSize(clientID: clientA, paneID: paneID2, cols: 100, rows: 30)
        #expect(r2?.cols == 100)
        #expect(r2?.rows == 30)

        manager.closeSession(id: session.id)
    }

    @Test("Client size update overwrites previous size for same client")
    func clientSizeUpdateOverwrite() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Size Overwrite")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        let clientB = UUID()
        manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 80, rows: 24)
        manager.registerClientSize(clientID: clientB, paneID: paneID, cols: 120, rows: 40)

        // A resizes to be larger than B
        let result = manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 200, rows: 50)

        // min should now be B: 120x40
        #expect(result?.cols == 120)
        #expect(result?.rows == 40)

        manager.closeSession(id: session.id)
    }

    @Test("removeClientFromPane with last client does not crash")
    func removeLastClient() {
        let manager = ServerSessionManager()
        let session = manager.createSession(name: "Size LastClient")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 120, rows: 40)
        manager.removeClientFromPane(clientID: clientA, paneID: paneID)

        // Should not crash, pane retains its last size
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
