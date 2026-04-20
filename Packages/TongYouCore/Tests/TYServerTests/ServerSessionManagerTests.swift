import Testing
import Foundation
@testable import TYServer
import TYProtocol
import TYTerminal
import TYConfig

@Suite("ServerSessionManager Tests", .serialized)
struct ServerSessionManagerTests {

    // MARK: - Helpers

    private func makeTempDir() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
    }

    /// Returns a manager configured with a persistence directory but does NOT
    /// load any persisted sessions yet. Restoration tests must call
    /// `await manager.loadPersistedSessions()` explicitly when they need the
    /// on-disk state to be materialized.
    private func makePersistentManager(directory: String) -> ServerSessionManager {
        let config = ServerConfig(
            defaultColumns: 80,
            defaultRows: 24,
            persistenceDirectory: directory
        )
        return ServerSessionManager(config: config)
    }

    @Test("Create session returns valid SessionInfo")
    func createSession() async {
        let manager = ServerSessionManager()
        let info = await manager.createSession(name: "Test Session")

        #expect(info.name == "Test Session")
        #expect(info.tabs.count == 1)
        #expect(info.activeTabIndex == 0)

        if case .leaf = info.tabs[0].layout {
            // OK
        } else {
            Issue.record("Expected leaf layout for single-pane tab")
        }

        await manager.closeSession(id: info.id)
    }

    @Test("Create session with default name")
    func createSessionDefaultName() async {
        let manager = ServerSessionManager()
        let info = await manager.createSession()
        #expect(info.name == "Session 1")
        await manager.closeSession(id: info.id)
    }

    @Test("List sessions returns all sessions")
    func listSessions() async {
        let manager = ServerSessionManager()
        let a = await manager.createSession(name: "A")
        let b = await manager.createSession(name: "B")

        let sessions = await manager.listSessions()
        #expect(sessions.count == 2)
        #expect(Set(sessions.map(\.name)) == Set(["A", "B"]))

        await manager.closeSession(id: a.id)
        await manager.closeSession(id: b.id)
    }

    @Test("Close session removes it")
    func closeSession() async {
        let manager = ServerSessionManager()
        let info = await manager.createSession(name: "Test")

        let hasBefore = await manager.hasSessions
        #expect(hasBefore == true)
        let countBefore = await manager.sessionCount
        #expect(countBefore == 1)

        await manager.closeSession(id: info.id)

        let hasAfter = await manager.hasSessions
        #expect(hasAfter == false)
        let countAfter = await manager.sessionCount
        #expect(countAfter == 0)
    }

    @Test("sessionInfo returns correct info")
    func sessionInfo() async {
        let manager = ServerSessionManager()
        let info = await manager.createSession(name: "Query Test")

        let queried = await manager.sessionInfo(for: info.id)
        #expect(queried != nil)
        #expect(queried?.name == "Query Test")
        #expect(queried?.id == info.id)

        await manager.closeSession(id: info.id)
    }

    @Test("sessionInfo returns nil for unknown ID")
    func sessionInfoUnknown() async {
        let manager = ServerSessionManager()
        let result = await manager.sessionInfo(for: SessionID())
        #expect(result == nil)
    }

    @Test("Create tab adds to session")
    func createTab() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Tab Test")

        let tabID = await manager.createTab(sessionID: session.id)
        #expect(tabID != nil)

        let info = await manager.sessionInfo(for: session.id)
        #expect(info?.tabs.count == 2)
        #expect(info?.activeTabIndex == 1)

        await manager.closeSession(id: session.id)
    }

    @Test("Create tab returns nil for unknown session")
    func createTabUnknownSession() async {
        let manager = ServerSessionManager()
        let tabID = await manager.createTab(sessionID: SessionID())
        #expect(tabID == nil)
    }

    @Test("Close tab removes tab from session")
    func closeTab() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Tab Close Test")
        let tabID = await manager.createTab(sessionID: session.id)!

        await manager.closeTab(sessionID: session.id, tabID: tabID)

        let info = await manager.sessionInfo(for: session.id)
        #expect(info?.tabs.count == 1)

        await manager.closeSession(id: session.id)
    }

    @Test("Close last tab removes session")
    func closeLastTab() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Last Tab")
        let tabID = session.tabs[0].id

        await manager.closeTab(sessionID: session.id, tabID: tabID)

        let has = await manager.hasSessions
        #expect(has == false)
    }

    @Test("Split pane creates new pane in tree")
    func splitPane() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Split Test")

        guard case .leaf(let firstPaneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let newPaneID = await manager.splitPane(
            sessionID: session.id,
            paneID: firstPaneID,
            direction: .vertical
        )
        #expect(newPaneID != nil)

        let info = await manager.sessionInfo(for: session.id)
        if case .container(let strategy, let children, _) = info?.tabs[0].layout {
            #expect(strategy == .vertical)
            #expect(children.count == 2)
        } else {
            Issue.record("Expected container layout after splitting pane")
        }

        await manager.closeSession(id: session.id)
    }

    @Test("setSplitRatio updates parent split ratio")
    func setSplitRatioUpdatesRatio() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Ratio Test")
        guard case .leaf(let firstPaneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }
        let secondPaneID = await manager.splitPane(
            sessionID: session.id,
            paneID: firstPaneID,
            direction: .vertical
        )!

        let ok = await manager.setSplitRatio(
            sessionID: session.id, paneID: secondPaneID, ratio: 0.25
        )
        #expect(ok)

        let info = await manager.sessionInfo(for: session.id)
        // Second child targets ratio 0.25; first child's weight share becomes 0.75.
        if case .container(_, _, let weights) = info?.tabs[0].layout {
            let sum = weights.reduce(0, +)
            #expect(sum > 0)
            #expect(abs(weights[0] / sum - 0.75) < 1e-6)
        } else {
            Issue.record("Expected container layout with updated ratio")
        }

        await manager.closeSession(id: session.id)
    }

    @Test("setSplitRatio rejects unknown pane")
    func setSplitRatioUnknownPane() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Ratio Reject")
        let bogus = PaneID()

        let ok = await manager.setSplitRatio(
            sessionID: session.id, paneID: bogus, ratio: 0.5
        )
        #expect(!ok)

        await manager.closeSession(id: session.id)
    }

    @Test("movePane relocates pane within the tab")
    func movePane() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Move Pane Test")
        guard case .leaf(let first) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout"); return
        }
        let second = await manager.splitPane(
            sessionID: session.id, paneID: first, direction: .vertical
        )!
        let third = await manager.splitPane(
            sessionID: session.id, paneID: second, direction: .vertical
        )!
        // After two vertical splits flattening kicks in → V[first, second, third].
        let moved = await manager.movePane(
            sessionID: session.id,
            sourcePaneID: first,
            targetPaneID: third,
            side: .right
        )
        #expect(moved)

        let info = await manager.sessionInfo(for: session.id)
        guard case .container(let strategy, let children, _) = info?.tabs[0].layout else {
            Issue.record("Expected container layout"); return
        }
        #expect(strategy == .vertical)
        // Children flattened with first pushed past third to the right end.
        let leafIDs = children.compactMap { child -> PaneID? in
            if case .leaf(let id) = child { return id }
            return nil
        }
        #expect(leafIDs == [second, third, first])

        await manager.closeSession(id: session.id)
    }

    @Test("changeStrategy rewrites parent container's strategy")
    func changeStrategyApplies() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "ChangeStrategy Apply")
        guard case .leaf(let first) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout"); return
        }
        let second = await manager.splitPane(
            sessionID: session.id, paneID: first, direction: .vertical
        )!
        // Initial tree: V[first, second]. Switch to master-stack — always
        // reshapes (strategy differs) and picks up the plan §3.5 initial
        // weights of [1.5 × stackSum, 1].

        let changed = await manager.changeStrategy(
            sessionID: session.id,
            paneID: first,
            kind: .masterStack
        )
        #expect(changed)

        let info = await manager.sessionInfo(for: session.id)
        guard case .container(let strategy, let children, let weights) =
                info?.tabs[0].layout else {
            Issue.record("Expected container layout"); return
        }
        #expect(strategy == .masterStack)
        #expect(weights == [1.5, 1])
        let leafIDs = children.compactMap { child -> PaneID? in
            if case .leaf(let id) = child { return id }
            return nil
        }
        #expect(leafIDs == [first, second])

        await manager.closeSession(id: session.id)
    }

    @Test("changeStrategy NOOPs when kind already matches")
    func changeStrategyNoop() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "ChangeStrategy Noop")
        guard case .leaf(let first) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout"); return
        }
        _ = await manager.splitPane(
            sessionID: session.id, paneID: first, direction: .vertical
        )
        // Container is already vertical — asking for vertical again is a no-op.
        let changed = await manager.changeStrategy(
            sessionID: session.id, paneID: first, kind: .vertical
        )
        #expect(!changed)

        await manager.closeSession(id: session.id)
    }

    @Test("changeStrategy rejects single-pane tab and unknown pane")
    func changeStrategyRejectsInvalid() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "ChangeStrategy Reject")
        guard case .leaf(let first) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout"); return
        }
        // Single-pane tab — no container to install a strategy on.
        let changedSingle = await manager.changeStrategy(
            sessionID: session.id, paneID: first, kind: .grid
        )
        #expect(!changedSingle)
        // Unknown pane — can't locate the owning tab.
        let changedUnknown = await manager.changeStrategy(
            sessionID: session.id, paneID: PaneID(), kind: .grid
        )
        #expect(!changedUnknown)

        await manager.closeSession(id: session.id)
    }

    @Test("changeStrategy reshapes tree into canonical grid")
    func changeStrategyFlattensNesting() async {
        // Build a nested layout:
        //   first vertical-split  →  V[first, second]
        //   split second horizontally → V[first, H[second, third]]
        // Then change_strategy targets the whole tab: 3 panes → grid reshape
        // produces H[V[first, second], third] (row 0 has 2 cells, last row
        // is a bare leaf spanning the full width).
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "ChangeStrategy Flatten")
        guard case .leaf(let first) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout"); return
        }
        let second = await manager.splitPane(
            sessionID: session.id, paneID: first, direction: .vertical
        )!
        let third = await manager.splitPane(
            sessionID: session.id, paneID: second, direction: .horizontal
        )!

        let changed = await manager.changeStrategy(
            sessionID: session.id, paneID: first, kind: .grid
        )
        #expect(changed)

        let info = await manager.sessionInfo(for: session.id)
        guard case .container(let rootStrategy, let rootChildren, let rootWeights) =
                info?.tabs[0].layout else {
            Issue.record("Expected container layout"); return
        }
        #expect(rootStrategy == .horizontal)
        #expect(rootWeights == [1, 1])
        #expect(rootChildren.count == 2)
        // Row 0: V[first, second].
        guard case .container(let row0Strategy, let row0Children, let row0Weights) =
                rootChildren[0] else {
            Issue.record("Expected row 0 to be a .vertical container"); return
        }
        #expect(row0Strategy == .vertical)
        #expect(row0Weights == [1, 1])
        let row0IDs = row0Children.compactMap { child -> PaneID? in
            if case .leaf(let id) = child { return id }
            return nil
        }
        #expect(row0IDs == [first, second])
        // Row 1: bare leaf `third`.
        if case .leaf(let lastPaneID) = rootChildren[1] {
            #expect(lastPaneID == third)
        } else {
            Issue.record("Expected row 1 to be a bare leaf")
        }

        await manager.closeSession(id: session.id)
    }

    @Test("movePane rejects missing or same-pane inputs")
    func movePaneRejectsInvalid() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Move Pane Reject")
        guard case .leaf(let first) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout"); return
        }
        let second = await manager.splitPane(
            sessionID: session.id, paneID: first, direction: .vertical
        )!

        let m1 = await manager.movePane(
            sessionID: session.id,
            sourcePaneID: first,
            targetPaneID: first,
            side: .right
        )
        #expect(!m1)
        let m2 = await manager.movePane(
            sessionID: session.id,
            sourcePaneID: first,
            targetPaneID: PaneID(),
            side: .right
        )
        #expect(!m2)
        let m3 = await manager.movePane(
            sessionID: session.id,
            sourcePaneID: PaneID(),
            targetPaneID: second,
            side: .right
        )
        #expect(!m3)

        await manager.closeSession(id: session.id)
    }

    @Test("Close pane removes from tree")
    func closePane() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Close Pane Test")
        guard case .leaf(let firstPaneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let newPaneID = await manager.splitPane(
            sessionID: session.id,
            paneID: firstPaneID,
            direction: .horizontal
        )!

        await manager.closePane(sessionID: session.id, paneID: newPaneID)

        let info = await manager.sessionInfo(for: session.id)
        if case .leaf = info?.tabs[0].layout {
            // OK — back to single pane
        } else {
            Issue.record("Expected leaf layout after closing split pane")
        }

        await manager.closeSession(id: session.id)
    }

    @Test("allPaneIDs returns all panes in session")
    func allPaneIDs() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "All Panes Test")
        guard case .leaf(let firstPaneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        _ = await manager.splitPane(
            sessionID: session.id,
            paneID: firstPaneID,
            direction: .vertical
        )

        let paneIDs = await manager.allPaneIDs(sessionID: session.id)
        #expect(paneIDs.count == 2)

        await manager.closeSession(id: session.id)
    }

    @Test("sendInput does not crash with valid pane")
    func sendInput() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Input Test")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        await manager.sendInput(paneID: paneID, data: Array("ls\n".utf8))

        await manager.closeSession(id: session.id)
    }

    @Test("sendPaste does not crash with valid pane")
    func sendPaste() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Paste Test")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        // Shell spawned by the session has bracketed-paste disabled by
        // default, so this exercises the `\n` → `\r` path of PasteEncoder.
        await manager.sendPaste(paneID: paneID, data: Array("line1\nline2\nline3".utf8))

        await manager.closeSession(id: session.id)
    }

    @Test("sendPaste on unknown pane is a no-op")
    func sendPasteUnknownPane() async {
        let manager = ServerSessionManager()
        await manager.sendPaste(paneID: PaneID(), data: Array("hello".utf8))
    }

    @Test("resizePane does not crash")
    func resizePane() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Resize Test")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        await manager.resizePane(paneID: paneID, cols: 120, rows: 40)
        try? await Task.sleep(nanoseconds: 100_000_000)

        await manager.closeSession(id: session.id)
    }

    @Test("snapshot returns full snapshot for pane")
    func snapshot() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Snapshot Test")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        let snap = await manager.snapshot(paneID: paneID)
        #expect(snap != nil)
        #expect(snap?.columns == 80) // default
        #expect(snap?.rows == 24)    // default

        await manager.closeSession(id: session.id)
    }

    // MARK: - Floating Pane Operations

    @Test("Create floating pane adds to tab")
    func createFloatingPane() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Float Test")
        let tabID = session.tabs[0].id

        let fpID = await manager.createFloatingPane(sessionID: session.id, tabID: tabID)
        #expect(fpID != nil)

        let info = await manager.sessionInfo(for: session.id)
        #expect(info?.tabs[0].floatingPanes.count == 1)
        #expect(info?.tabs[0].floatingPanes[0].paneID == fpID)
        #expect(info?.tabs[0].floatingPanes[0].title == "Float")

        await manager.closeSession(id: session.id)
    }

    @Test("Create floating pane returns nil for unknown tab")
    func createFloatingPaneUnknownTab() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Float Unknown Tab")

        let fpID = await manager.createFloatingPane(sessionID: session.id, tabID: TabID())
        #expect(fpID == nil)

        await manager.closeSession(id: session.id)
    }

    @Test("Close floating pane removes from tab")
    func closeFloatingPane() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Float Close Test")
        let tabID = session.tabs[0].id

        let fpID = await manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        await manager.closeFloatingPane(sessionID: session.id, paneID: fpID)

        let info = await manager.sessionInfo(for: session.id)
        #expect(info?.tabs[0].floatingPanes.isEmpty == true)

        await manager.closeSession(id: session.id)
    }

    @Test("Update floating pane frame persists")
    func updateFloatingPaneFrame() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Float Frame Test")
        let tabID = session.tabs[0].id

        let fpID = await manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        await manager.updateFloatingPaneFrame(
            sessionID: session.id, paneID: fpID,
            x: 0.1, y: 0.2, width: 0.5, height: 0.6
        )

        let info = await manager.sessionInfo(for: session.id)
        let fp = info?.tabs[0].floatingPanes[0]
        #expect(fp?.frameX == Float(0.1))
        #expect(fp?.frameY == Float(0.2))
        #expect(fp?.frameWidth == Float(0.5))
        #expect(fp?.frameHeight == Float(0.6))

        await manager.closeSession(id: session.id)
    }

    @Test("Bring floating pane to front updates zIndex")
    func bringFloatingPaneToFront() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Float ZIndex Test")
        let tabID = session.tabs[0].id

        let fp1 = await manager.createFloatingPane(sessionID: session.id, tabID: tabID)!
        let fp2 = await manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        var info = await manager.sessionInfo(for: session.id)!
        let z1Before = info.tabs[0].floatingPanes.first(where: { $0.paneID == fp1 })!.zIndex
        let z2Before = info.tabs[0].floatingPanes.first(where: { $0.paneID == fp2 })!.zIndex
        #expect(z2Before > z1Before)

        await manager.bringFloatingPaneToFront(sessionID: session.id, paneID: fp1)

        info = await manager.sessionInfo(for: session.id)!
        let z1After = info.tabs[0].floatingPanes.first(where: { $0.paneID == fp1 })!.zIndex
        #expect(z1After > z2Before)

        await manager.closeSession(id: session.id)
    }

    @Test("Toggle floating pane pin")
    func toggleFloatingPanePin() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Float Pin Test")
        let tabID = session.tabs[0].id

        let fpID = await manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        var info = await manager.sessionInfo(for: session.id)!
        #expect(info.tabs[0].floatingPanes[0].isPinned == false)

        await manager.toggleFloatingPanePin(sessionID: session.id, paneID: fpID)

        info = await manager.sessionInfo(for: session.id)!
        #expect(info.tabs[0].floatingPanes[0].isPinned == true)

        await manager.closeSession(id: session.id)
    }

    @Test("allPaneIDs includes floating panes")
    func allPaneIDsIncludesFloatingPanes() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "All IDs Float Test")
        let tabID = session.tabs[0].id

        let fpID = await manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        let allIDs = await manager.allPaneIDs(sessionID: session.id)
        #expect(allIDs.count == 2) // 1 tree pane + 1 floating pane
        #expect(allIDs.contains(fpID))

        await manager.closeSession(id: session.id)
    }

    @Test("Floating pane I/O works via coreLookup")
    func floatingPaneIO() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Float IO Test")
        let tabID = session.tabs[0].id

        let fpID = await manager.createFloatingPane(sessionID: session.id, tabID: tabID)!
        try? await Task.sleep(nanoseconds: 200_000_000)

        await manager.sendInput(paneID: fpID, data: Array("echo hello\n".utf8))

        let snap = await manager.snapshot(paneID: fpID)
        #expect(snap != nil)
        #expect(snap?.columns == 80)
        #expect(snap?.rows == 24)

        await manager.closeSession(id: session.id)
    }

    @Test("onScreenDirty callback fires with correct IDs")
    func onScreenDirtyCallback() async {
        let manager = ServerSessionManager()

        let receivedPairs = Mutex<[(SessionID, PaneID)]>([])
        // onScreenDirty is nonisolated(unsafe), so no await needed here.
        manager.onScreenDirty = { sessionID, paneID in
            receivedPairs.withLock { $0.append((sessionID, paneID)) }
        }

        let session = await manager.createSession(name: "Dirty Callback Test")

        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await manager.sendInput(paneID: paneID, data: Array("echo test\n".utf8))

        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if receivedPairs.withLock({ !$0.isEmpty }) { break }
        }

        let pairs = receivedPairs.withLock { $0 }
        #expect(!pairs.isEmpty)
        if !pairs.isEmpty {
            #expect(pairs[0].0 == session.id)
        }

        await manager.closeSession(id: session.id)
    }

    // MARK: - Multi-Client Size Negotiation

    @Test("registerClientSize with single client uses that client's size")
    func registerClientSizeSingleClient() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Size Single")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        let result = await manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 120, rows: 40)

        #expect(result?.cols == 120)
        #expect(result?.rows == 40)

        await manager.closeSession(id: session.id)
    }

    @Test("registerClientSize with two clients uses minimum")
    func registerClientSizeMinimum() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Size Min")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        let clientB = UUID()
        _ = await manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 120, rows: 40)
        let result = await manager.registerClientSize(clientID: clientB, paneID: paneID, cols: 80, rows: 24)

        #expect(result?.cols == 80)
        #expect(result?.rows == 24)

        await manager.closeSession(id: session.id)
    }

    @Test("registerClientSize picks min per dimension independently")
    func registerClientSizeMinPerDimension() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Size Mixed")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        let clientB = UUID()
        _ = await manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 200, rows: 20)
        let result = await manager.registerClientSize(clientID: clientB, paneID: paneID, cols: 80, rows: 50)

        #expect(result?.cols == 80)
        #expect(result?.rows == 20)

        await manager.closeSession(id: session.id)
    }

    @Test("removeClientFromPane recalculates size for remaining clients")
    func removeClientFromPaneRecalculates() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Size Remove")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        let clientB = UUID()
        _ = await manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 120, rows: 40)
        _ = await manager.registerClientSize(clientID: clientB, paneID: paneID, cols: 80, rows: 24)

        await manager.removeClientFromPane(clientID: clientB, paneID: paneID)

        let result = await manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 120, rows: 40)
        #expect(result?.cols == 120)
        #expect(result?.rows == 40)

        await manager.closeSession(id: session.id)
    }

    @Test("removeClientFromAllPanes cleans up all panes")
    func removeClientFromAllPanes() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Size RemoveAll")
        guard case .leaf(let paneID1) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        guard let paneID2 = await manager.splitPane(
            sessionID: session.id, paneID: paneID1, direction: .vertical
        ) else {
            Issue.record("Split failed")
            return
        }

        let clientA = UUID()
        let clientB = UUID()
        _ = await manager.registerClientSize(clientID: clientA, paneID: paneID1, cols: 120, rows: 40)
        _ = await manager.registerClientSize(clientID: clientB, paneID: paneID1, cols: 80, rows: 24)
        _ = await manager.registerClientSize(clientID: clientA, paneID: paneID2, cols: 100, rows: 30)
        _ = await manager.registerClientSize(clientID: clientB, paneID: paneID2, cols: 60, rows: 20)

        await manager.removeClientFromAllPanes(clientID: clientB)

        let r1 = await manager.registerClientSize(clientID: clientA, paneID: paneID1, cols: 120, rows: 40)
        #expect(r1?.cols == 120)
        #expect(r1?.rows == 40)

        let r2 = await manager.registerClientSize(clientID: clientA, paneID: paneID2, cols: 100, rows: 30)
        #expect(r2?.cols == 100)
        #expect(r2?.rows == 30)

        await manager.closeSession(id: session.id)
    }

    @Test("Client size update overwrites previous size for same client")
    func clientSizeUpdateOverwrite() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Size Overwrite")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        let clientB = UUID()
        _ = await manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 80, rows: 24)
        _ = await manager.registerClientSize(clientID: clientB, paneID: paneID, cols: 120, rows: 40)

        let result = await manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 200, rows: 50)

        #expect(result?.cols == 120)
        #expect(result?.rows == 40)

        await manager.closeSession(id: session.id)
    }

    // MARK: - Tab Selection & Pane Focus

    @Test("selectTab updates activeTabIndex")
    func selectTab() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "SelectTab Test")
        _ = await manager.createTab(sessionID: session.id)
        _ = await manager.createTab(sessionID: session.id)

        let info1 = await manager.sessionInfo(for: session.id)
        #expect(info1?.activeTabIndex == 2)

        await manager.selectTab(sessionID: session.id, tabIndex: 0)
        let info2 = await manager.sessionInfo(for: session.id)
        #expect(info2?.activeTabIndex == 0)

        await manager.selectTab(sessionID: session.id, tabIndex: 1)
        let info3 = await manager.sessionInfo(for: session.id)
        #expect(info3?.activeTabIndex == 1)

        await manager.closeSession(id: session.id)
    }

    @Test("selectTab clamps out-of-range index")
    func selectTabClampsIndex() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "SelectTab Clamp")
        _ = await manager.createTab(sessionID: session.id) // 2 tabs total

        await manager.selectTab(sessionID: session.id, tabIndex: 999)
        let info = await manager.sessionInfo(for: session.id)
        #expect(info?.activeTabIndex == 1)

        await manager.closeSession(id: session.id)
    }

    @Test("focusPane records focusedPaneID on the correct tab")
    func focusPane() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "FocusPane Test")
        guard case .leaf(let pane1) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        guard let pane2 = await manager.splitPane(
            sessionID: session.id, paneID: pane1, direction: .vertical
        ) else {
            Issue.record("Split failed")
            return
        }

        await manager.focusPane(sessionID: session.id, paneID: pane2)
        let info = await manager.sessionInfo(for: session.id)
        #expect(info?.tabs[0].focusedPaneID == pane2)

        await manager.focusPane(sessionID: session.id, paneID: pane1)
        let info2 = await manager.sessionInfo(for: session.id)
        #expect(info2?.tabs[0].focusedPaneID == pane1)

        await manager.closeSession(id: session.id)
    }

    @Test("focusPane on floating pane records on correct tab")
    func focusPaneFloating() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "FocusPane Float")
        let tabID = session.tabs[0].id

        let fpID = await manager.createFloatingPane(sessionID: session.id, tabID: tabID)!

        await manager.focusPane(sessionID: session.id, paneID: fpID)
        let info = await manager.sessionInfo(for: session.id)
        #expect(info?.tabs[0].focusedPaneID == fpID)

        await manager.closeSession(id: session.id)
    }

    @Test("focusPane with unknown pane is no-op")
    func focusPaneUnknown() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "FocusPane Unknown")

        await manager.focusPane(sessionID: session.id, paneID: PaneID())
        let info = await manager.sessionInfo(for: session.id)
        #expect(info?.tabs[0].focusedPaneID == nil)

        await manager.closeSession(id: session.id)
    }

    @Test("removeClientFromPane with last client does not crash")
    func removeLastClient() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "Size LastClient")
        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }

        let clientA = UUID()
        _ = await manager.registerClientSize(clientID: clientA, paneID: paneID, cols: 120, rows: 40)
        await manager.removeClientFromPane(clientID: clientA, paneID: paneID)

        await manager.closeSession(id: session.id)
    }

    // MARK: - Persistence

    @Test("Session manager with persistence directory restores sessions on init")
    func persistenceRestoreSession() async throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let sessionID = SessionID()
        let tabID = TabID()
        let paneID = PaneID()
        let layout = LayoutTree.leaf(paneID)
        let sessionInfo = SessionInfo(
            id: sessionID,
            name: "Persisted",
            tabs: [
                TabInfo(id: tabID, title: "Tab", layout: layout, focusedPaneID: paneID)
            ],
            activeTabIndex: 0
        )
        let cwd = ProcessInfo.processInfo.environment["HOME"] ?? "/"
        let persisted = PersistedSession(
            sessionInfo: sessionInfo,
            paneContexts: [paneID: PersistedPaneContext(cwd: cwd)]
        )

        let store = SessionStore(directory: tempDir)
        store.save(persisted)

        let manager = makePersistentManager(directory: tempDir)
        await manager.loadPersistedSessions()

        let count = await manager.sessionCount
        #expect(count == 1)
        let info = await manager.sessionInfo(for: sessionID)
        #expect(info?.name == "Persisted")
        #expect(info?.tabs.count == 1)

        await manager.closeSession(id: sessionID)
    }

    @Test("Creating session writes persistence file")
    func persistenceSaveOnCreate() async throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let manager = makePersistentManager(directory: tempDir)
        let session = await manager.createSession(name: "Save Test")
        await manager.flushPendingSaves()

        let store = SessionStore(directory: tempDir)
        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.sessionInfo.name == "Save Test")

        await manager.closeSession(id: session.id)
    }

    @Test("Closing session removes persistence file")
    func persistenceDeleteOnClose() async throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let manager = makePersistentManager(directory: tempDir)
        let session = await manager.createSession(name: "Delete Test")
        await manager.flushPendingSaves()

        await manager.closeSession(id: session.id)

        let store = SessionStore(directory: tempDir)
        let loaded = store.loadAll()
        #expect(loaded.isEmpty)
    }

    @Test("Split pane updates persistence")
    func persistenceAfterSplit() async throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let manager = makePersistentManager(directory: tempDir)
        let session = await manager.createSession(name: "Split Persist")
        await manager.flushPendingSaves()

        guard case .leaf(let paneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            await manager.closeSession(id: session.id)
            return
        }

        _ = await manager.splitPane(sessionID: session.id, paneID: paneID, direction: .vertical)
        await manager.flushPendingSaves()

        let store = SessionStore(directory: tempDir)
        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        let layout = loaded.first?.sessionInfo.tabs.first?.layout
        if case .container(let strategy, _, _) = layout {
            #expect(strategy == .vertical)
        } else {
            Issue.record("Expected container layout in persisted data")
        }

        await manager.closeSession(id: session.id)
    }

    // MARK: - Phase 7.2: Client-supplied profileID + snapshot + frameHint

    @Test("createTab with snapshot attaches snapshot to pane")
    func createTabWithSnapshotLaunchesPTYWithCommand() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "7.2 createTab snapshot")
        let snapshot = StartupSnapshot(
            command: "/usr/bin/env",
            args: ["sh", "-c", "true"],
            env: [EnvVar(key: "TY_TEST", value: "1")],
            closeOnExit: false
        )

        let tabID = await manager.createTab(
            sessionID: session.id,
            profileID: "ci",
            snapshot: snapshot
        )
        #expect(tabID != nil)

        let info = await manager.sessionInfo(for: session.id)
        guard let newTab = info?.tabs.first(where: { $0.id == tabID }) else {
            Issue.record("New tab not found in SessionInfo")
            await manager.closeSession(id: session.id)
            return
        }
        guard case .leaf(let newPaneID) = newTab.layout else {
            Issue.record("Expected leaf layout for new tab")
            await manager.closeSession(id: session.id)
            return
        }

        #expect(info?.paneMetadata[newPaneID]?.profileID == "ci")
        let pane = await manager.treePaneForTests(paneID: newPaneID)
        #expect(pane?.profileID == "ci")
        #expect(pane?.startupSnapshot == snapshot)

        await manager.closeSession(id: session.id)
    }

    @Test("splitPane with snapshot overrides parent inheritance")
    func splitPaneWithSnapshotOverridesParentInheritance() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "7.2 split override")
        guard case .leaf(let parentPaneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout"); return
        }

        let childSnapshot = StartupSnapshot(
            command: "/bin/sh",
            args: ["-c", "exit 0"],
            closeOnExit: true
        )
        let newPaneID = await manager.splitPane(
            sessionID: session.id,
            paneID: parentPaneID,
            direction: .horizontal,
            profileID: "ci",
            snapshot: childSnapshot
        )
        #expect(newPaneID != nil)

        let newPane = await manager.treePaneForTests(paneID: newPaneID!)
        #expect(newPane?.profileID == "ci")
        #expect(newPane?.startupSnapshot == childSnapshot)

        // Parent should be unchanged.
        let parent = await manager.treePaneForTests(paneID: parentPaneID)
        #expect(parent?.profileID == TerminalPane.defaultProfileID)

        await manager.closeSession(id: session.id)
    }

    @Test("splitPane without snapshot still inherits parent profileID")
    func splitPaneWithoutSnapshotInheritsParent() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "7.2 split inherit")
        guard case .leaf(let rootPaneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout"); return
        }

        // First split explicitly carries profileID=custom so we can assert
        // the next split inherits it (classic parent-inheritance path).
        let custom = await manager.splitPane(
            sessionID: session.id,
            paneID: rootPaneID,
            direction: .vertical,
            profileID: "custom",
            snapshot: nil
        )!
        let customPane = await manager.treePaneForTests(paneID: custom)
        #expect(customPane?.profileID == "custom")

        // Now split the custom pane without providing profile/snapshot.
        let inherited = await manager.splitPane(
            sessionID: session.id,
            paneID: custom,
            direction: .horizontal
        )!
        let inheritedPane = await manager.treePaneForTests(paneID: inherited)
        #expect(inheritedPane?.profileID == "custom")

        await manager.closeSession(id: session.id)
    }

    @Test("createFloatingPane with frame hint applies clamped geometry")
    func createFloatingPaneWithFrameHintAppliesGeometry() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "7.2 float hint")
        let tabID = session.tabs[0].id

        // width/height below 0.1 must clamp up to 0.1; values stay untouched otherwise.
        let hint = FloatFrameHint(x: 0.2, y: 0.3, width: 0.05, height: 0.4)
        let paneID = await manager.createFloatingPane(
            sessionID: session.id,
            tabID: tabID,
            profileID: "ci",
            snapshot: StartupSnapshot(command: "/bin/true"),
            frameHint: hint
        )
        #expect(paneID != nil)

        let info = await manager.sessionInfo(for: session.id)
        guard let fp = info?.tabs.first?.floatingPanes.first(where: { $0.paneID == paneID }) else {
            Issue.record("Floating pane not found in SessionInfo")
            await manager.closeSession(id: session.id)
            return
        }
        #expect(fp.frameX == 0.2)
        #expect(fp.frameY == 0.3)
        #expect(fp.frameWidth == 0.1)   // clamped up from 0.05
        #expect(fp.frameHeight == 0.4)
        #expect(info?.paneMetadata[paneID!]?.profileID == "ci")

        await manager.closeSession(id: session.id)
    }

    // MARK: - Phase 8: closeOnExit surfaced in RemotePaneMetadata

    @Test("splitPane surfaces closeOnExit=false in paneMetadata")
    func splitPaneSurfacesCloseOnExitFalseInMetadata() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "phase8 split keep-alive")
        guard case .leaf(let parentPaneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout"); return
        }

        let keepAlive = StartupSnapshot(
            command: "/bin/sh",
            args: ["-c", "exit 0"],
            closeOnExit: false
        )
        let newPaneID = await manager.splitPane(
            sessionID: session.id,
            paneID: parentPaneID,
            direction: .horizontal,
            profileID: "ci",
            snapshot: keepAlive
        )
        #expect(newPaneID != nil)

        let info = await manager.sessionInfo(for: session.id)
        #expect(info?.paneMetadata[newPaneID!]?.closeOnExit == false)
        // Parent pane was created with default snapshot (closeOnExit == nil)
        // and must not leak a false value.
        #expect(info?.paneMetadata[parentPaneID]?.closeOnExit == nil)

        await manager.closeSession(id: session.id)
    }

    // MARK: - Phase 8.2: rerunPane

    @Test("rerunPane replaces TerminalCore but keeps PaneID and snapshot")
    func rerunPaneReplacesCoreAndKeepsPaneID() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "phase8 rerun keep-id")
        guard case .leaf(let rootPaneID) = session.tabs[0].layout else {
            Issue.record("Expected leaf layout"); return
        }

        let snapshot = StartupSnapshot(
            command: "/bin/sh",
            args: ["-c", "exit 0"],
            closeOnExit: false
        )
        let paneID = await manager.splitPane(
            sessionID: session.id,
            paneID: rootPaneID,
            direction: .horizontal,
            profileID: "ci",
            snapshot: snapshot
        )!

        let oldCore = await manager.terminalCoreForTests(paneID: paneID)
        #expect(oldCore != nil)

        await manager.rerunPane(sessionID: session.id, paneID: paneID)

        // Same PaneID still exists in the tree — snapshot + profileID preserved.
        let pane = await manager.treePaneForTests(paneID: paneID)
        #expect(pane != nil)
        #expect(pane?.profileID == "ci")
        #expect(pane?.startupSnapshot == snapshot)
        // closeOnExit still surfaced in metadata after rerun.
        let info = await manager.sessionInfo(for: session.id)
        #expect(info?.paneMetadata[paneID]?.closeOnExit == false)

        // Core is a fresh instance.
        let newCore = await manager.terminalCoreForTests(paneID: paneID)
        #expect(newCore != nil)
        #expect(oldCore !== newCore)

        await manager.closeSession(id: session.id)
    }

    @Test("rerunPane is a no-op for unknown pane")
    func rerunPaneIgnoresUnknownPane() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "phase8 rerun unknown")
        let bogus = PaneID()

        // Should not crash, should not mutate anything.
        await manager.rerunPane(sessionID: session.id, paneID: bogus)

        await manager.closeSession(id: session.id)
    }

    @Test("createFloatingPane surfaces closeOnExit=false in paneMetadata")
    func createFloatingPaneSurfacesCloseOnExitInMetadata() async {
        let manager = ServerSessionManager()
        let session = await manager.createSession(name: "phase8 float keep-alive")
        let tabID = session.tabs[0].id

        let paneID = await manager.createFloatingPane(
            sessionID: session.id,
            tabID: tabID,
            profileID: "ci",
            snapshot: StartupSnapshot(command: "/bin/true", closeOnExit: false)
        )
        #expect(paneID != nil)

        let info = await manager.sessionInfo(for: session.id)
        #expect(info?.paneMetadata[paneID!]?.closeOnExit == false)

        await manager.closeSession(id: session.id)
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
