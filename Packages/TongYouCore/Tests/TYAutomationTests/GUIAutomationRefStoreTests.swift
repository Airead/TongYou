import Testing
import Foundation
@testable import TYAutomation
import TYTerminal

// MARK: - Ref parsing

@Suite("GUI Automation Ref parsing")
struct GUIAutomationRefTests {

    @Test func parseSessionRef() throws {
        #expect(try AutomationRef.parse("dev") == .session("dev"))
        #expect(try AutomationRef.parse("sess:1") == .session("sess:1"))
    }

    @Test func parseTabPaneFloatRefs() throws {
        #expect(try AutomationRef.parse("dev/tab:2") == .tab(session: "dev", index: 2))
        #expect(try AutomationRef.parse("dev/pane:7") == .pane(session: "dev", index: 7))
        #expect(try AutomationRef.parse("dev/float:1") == .float(session: "dev", index: 1))
        #expect(try AutomationRef.parse("sess:3/pane:1") == .pane(session: "sess:3", index: 1))
    }

    @Test func refRoundTripsThroughDescription() throws {
        let refs = [
            AutomationRef.session("dev"),
            .session("sess:1"),
            .tab(session: "dev", index: 2),
            .pane(session: "sess:3", index: 9),
            .float(session: "dev", index: 1),
        ]
        for ref in refs {
            let roundTripped = try AutomationRef.parse(ref.description)
            #expect(roundTripped == ref)
        }
    }

    @Test func malformedRefsThrow() {
        let bad = [
            "",
            "/",
            "dev/",
            "/pane:1",
            "dev/pane",
            "dev/pane:",
            "dev/pane:abc",
            "dev/pane:-1",
            "dev/foo:1",
            "dev/pane:1/extra",
            "dev name/tab:1",   // whitespace in session segment
            "dev:extra/tab:1",  // arbitrary colon in session segment
        ]
        for raw in bad {
            #expect(throws: AutomationError.self) {
                _ = try AutomationRef.parse(raw)
            }
        }
    }

    @Test func canUseAsSessionNameEnforcesRules() {
        #expect(AutomationRef.canUseAsSessionName("dev"))
        #expect(AutomationRef.canUseAsSessionName("my-project"))
        #expect(!AutomationRef.canUseAsSessionName(""))
        #expect(!AutomationRef.canUseAsSessionName("a b"))
        #expect(!AutomationRef.canUseAsSessionName("a/b"))
        #expect(!AutomationRef.canUseAsSessionName("a:b"))
        #expect(!AutomationRef.canUseAsSessionName("sess:1"))
        #expect(!AutomationRef.canUseAsSessionName("tab:2"))
        #expect(!AutomationRef.canUseAsSessionName("pane:3"))
        #expect(!AutomationRef.canUseAsSessionName("float:4"))
        // A colon with a non-reserved prefix should still be rejected by the
        // stricter "no colon" rule.
        #expect(!AutomationRef.canUseAsSessionName("foo:1"))
    }
}

// MARK: - RefStore logic

@MainActor
@Suite("GUI Automation RefStore")
struct GUIAutomationRefStoreTests {

    // MARK: helpers

    private func makePane() -> TerminalPane {
        TerminalPane()
    }

    private func makeTab(title: String = "shell", panes: [TerminalPane]? = nil, floats: [FloatingPane] = []) -> TerminalTab {
        let tree: PaneNode
        if let panes, panes.count > 1 {
            // Build a left-leaning container chain so DFS(left-first) yields
            // the input order.
            var node: PaneNode = .leaf(panes[0])
            for p in panes.dropFirst() {
                node = .container(Container(
                    strategy: .vertical,
                    children: [node, .leaf(p)],
                    weights: [1.0, 1.0]
                ))
            }
            tree = node
        } else if let first = panes?.first {
            tree = .leaf(first)
        } else {
            tree = .leaf(TerminalPane())
        }
        return TerminalTab(
            id: UUID(),
            title: title,
            paneTree: tree,
            floatingPanes: floats,
            focusedPaneID: nil
        )
    }

    private func makeSession(
        id: UUID = UUID(),
        name: String = "",
        tabs: [TerminalTab] = [],
        source: SessionSource = .local
    ) -> TerminalSession {
        TerminalSession(
            id: id,
            name: name,
            tabs: tabs.isEmpty ? [TerminalTab()] : tabs,
            activeTabIndex: 0,
            source: source,
            isAnonymous: false
        )
    }

    private func snapshot(
        _ session: TerminalSession,
        state: AutomationSessionState = .ready,
        isActive: Bool = false
    ) -> SessionSnapshot {
        SessionSnapshot(session: session, state: state, isActive: isActive)
    }

    // MARK: naming rules

    @Test func userNameUsedWhenValidAndUnique() {
        let store = GUIAutomationRefStore()
        let s = makeSession(name: "dev")
        store.refreshRefs(snapshots: [snapshot(s)])
        #expect(store.sessionRef(for: s.id) == "dev")
    }

    @Test func emptyNameFallsBackToCounter() {
        let store = GUIAutomationRefStore()
        let a = makeSession(name: "")
        let b = makeSession(name: "")
        store.refreshRefs(snapshots: [snapshot(a), snapshot(b)])
        #expect(store.sessionRef(for: a.id) == "sess:1")
        #expect(store.sessionRef(for: b.id) == "sess:2")
    }

    @Test func nameWithSpecialCharactersFallsBack() {
        let store = GUIAutomationRefStore()
        let cases = ["a/b", "a:b", "a b", "sess:42", "tab:1", "pane:1", "float:1"]
        var snapshots: [SessionSnapshot] = []
        var ids: [UUID] = []
        for name in cases {
            let s = makeSession(name: name)
            ids.append(s.id)
            snapshots.append(snapshot(s))
        }
        store.refreshRefs(snapshots: snapshots)
        for (i, id) in ids.enumerated() {
            let ref = store.sessionRef(for: id)
            #expect(ref == "sess:\(i + 1)", "case '\(cases[i])' should get sess:\(i + 1), got \(ref ?? "nil")")
        }
    }

    // MARK: conflict handling

    @Test func duplicateNameSecondFallsBack() {
        let store = GUIAutomationRefStore()
        let first = makeSession(name: "dev")
        let second = makeSession(name: "dev")
        store.refreshRefs(snapshots: [snapshot(first), snapshot(second)])
        #expect(store.sessionRef(for: first.id) == "dev")
        #expect(store.sessionRef(for: second.id) == "sess:1")
    }

    // MARK: stability

    @Test func renameDoesNotChangeRef() {
        let store = GUIAutomationRefStore()
        let id = UUID()
        let original = makeSession(id: id, name: "dev")
        store.refreshRefs(snapshots: [snapshot(original)])
        #expect(store.sessionRef(for: id) == "dev")

        let renamed = makeSession(id: id, name: "work")
        store.refreshRefs(snapshots: [snapshot(renamed)])
        #expect(store.sessionRef(for: id) == "dev", "rename must not change ref")
    }

    @Test func autoGeneratedRefNotUpgradedWhenNameBecomesValid() {
        let store = GUIAutomationRefStore()
        let id = UUID()
        let unnamed = makeSession(id: id, name: "")
        store.refreshRefs(snapshots: [snapshot(unnamed)])
        #expect(store.sessionRef(for: id) == "sess:1")

        let named = makeSession(id: id, name: "dev")
        store.refreshRefs(snapshots: [snapshot(named)])
        #expect(store.sessionRef(for: id) == "sess:1", "existing ref must stay stable")
    }

    @Test func paneRefsStableAfterSplit() throws {
        let store = GUIAutomationRefStore()

        let pane1 = makePane()
        let tab = makeTab(panes: [pane1])
        let sessionID = UUID()
        let s1 = makeSession(id: sessionID, name: "dev", tabs: [tab])
        store.refreshRefs(snapshots: [snapshot(s1)])
        let originalPaneRef = store.paneRef(sessionID: sessionID, paneID: pane1.id)
        #expect(originalPaneRef == "dev/pane:1")

        // Simulate a split: pane1 stays, pane2 added; keep the same tab ID.
        let pane2 = makePane()
        let splitTree: PaneNode = .container(Container(
            strategy: .vertical,
            children: [.leaf(pane1), .leaf(pane2)],
            weights: [1.0, 1.0]
        ))
        let splitTab = TerminalTab(
            id: tab.id,
            title: tab.title,
            paneTree: splitTree,
            floatingPanes: [],
            focusedPaneID: nil
        )
        let s2 = makeSession(id: sessionID, name: "dev", tabs: [splitTab])
        store.refreshRefs(snapshots: [snapshot(s2)])
        #expect(store.paneRef(sessionID: sessionID, paneID: pane1.id) == "dev/pane:1")
        #expect(store.paneRef(sessionID: sessionID, paneID: pane2.id) == "dev/pane:2")
    }

    @Test func tabReorderDoesNotChangeRefs() {
        let store = GUIAutomationRefStore()
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let sid = UUID()
        let s1 = makeSession(id: sid, name: "dev", tabs: [tabA, tabB])
        store.refreshRefs(snapshots: [snapshot(s1)])
        #expect(store.tabRef(sessionID: sid, tabID: tabA.id) == "dev/tab:1")
        #expect(store.tabRef(sessionID: sid, tabID: tabB.id) == "dev/tab:2")

        // Swap order.
        let s2 = makeSession(id: sid, name: "dev", tabs: [tabB, tabA])
        store.refreshRefs(snapshots: [snapshot(s2)])
        #expect(store.tabRef(sessionID: sid, tabID: tabA.id) == "dev/tab:1", "tab A ref must be stable after reorder")
        #expect(store.tabRef(sessionID: sid, tabID: tabB.id) == "dev/tab:2", "tab B ref must be stable after reorder")
    }

    // MARK: monotonicity

    @Test func counterDoesNotReuseAfterClose() {
        let store = GUIAutomationRefStore()
        let a = makeSession(name: "")
        let b = makeSession(name: "")
        store.refreshRefs(snapshots: [snapshot(a), snapshot(b)])
        #expect(store.sessionRef(for: a.id) == "sess:1")
        #expect(store.sessionRef(for: b.id) == "sess:2")

        // Close a.
        store.refreshRefs(snapshots: [snapshot(b)])
        #expect(store.sessionRef(for: a.id) == nil)
        #expect(store.sessionRef(for: b.id) == "sess:2")

        // New unnamed session arrives — must get sess:3, never reuse sess:1.
        let c = makeSession(name: "")
        store.refreshRefs(snapshots: [snapshot(b), snapshot(c)])
        #expect(store.sessionRef(for: c.id) == "sess:3")
    }

    @Test func paneCounterDoesNotReuseAfterClose() {
        let store = GUIAutomationRefStore()
        let pane1 = makePane()
        let pane2 = makePane()
        let tab = makeTab(panes: [pane1, pane2])
        let sid = UUID()
        let s1 = makeSession(id: sid, name: "dev", tabs: [tab])
        store.refreshRefs(snapshots: [snapshot(s1)])
        #expect(store.paneRef(sessionID: sid, paneID: pane1.id) == "dev/pane:1")
        #expect(store.paneRef(sessionID: sid, paneID: pane2.id) == "dev/pane:2")

        // Remove pane1.
        let remainingTab = TerminalTab(
            id: tab.id,
            title: tab.title,
            paneTree: .leaf(pane2),
            floatingPanes: []
        )
        let s2 = makeSession(id: sid, name: "dev", tabs: [remainingTab])
        store.refreshRefs(snapshots: [snapshot(s2)])
        #expect(store.paneRef(sessionID: sid, paneID: pane1.id) == nil)
        #expect(store.paneRef(sessionID: sid, paneID: pane2.id) == "dev/pane:2")

        // Add a new pane via split — must get pane:3, not pane:1.
        let pane3 = makePane()
        let splitTab = TerminalTab(
            id: tab.id,
            title: tab.title,
            paneTree: .container(Container(
                strategy: .vertical,
                children: [.leaf(pane2), .leaf(pane3)],
                weights: [1.0, 1.0]
            )),
            floatingPanes: []
        )
        let s3 = makeSession(id: sid, name: "dev", tabs: [splitTab])
        store.refreshRefs(snapshots: [snapshot(s3)])
        #expect(store.paneRef(sessionID: sid, paneID: pane3.id) == "dev/pane:3")
    }

    @Test func nameReuseAllowedAfterClose() {
        let store = GUIAutomationRefStore()
        let a = makeSession(name: "dev")
        store.refreshRefs(snapshots: [snapshot(a)])
        #expect(store.sessionRef(for: a.id) == "dev")

        // Close a, then create a new session also named "dev".
        store.refreshRefs(snapshots: [])
        let b = makeSession(name: "dev")
        store.refreshRefs(snapshots: [snapshot(b)])
        #expect(store.sessionRef(for: b.id) == "dev", "name is free again once previous owner closed")
    }

    // MARK: resolve / invalidation

    @Test func resolveClosedSessionThrows() {
        let store = GUIAutomationRefStore()
        let s = makeSession(name: "dev")
        store.refreshRefs(snapshots: [snapshot(s)])
        _ = try? store.resolve(.session("dev"))

        store.refreshRefs(snapshots: [])
        #expect(throws: AutomationError.self) {
            _ = try store.resolve(.session("dev"))
        }
    }

    @Test func resolveUnknownPaneThrows() {
        let store = GUIAutomationRefStore()
        let s = makeSession(name: "dev")
        store.refreshRefs(snapshots: [snapshot(s)])
        #expect(throws: AutomationError.self) {
            _ = try store.resolve(.pane(session: "dev", index: 99))
        }
    }

    @Test func resolveRoundTripsLiveRefs() throws {
        let store = GUIAutomationRefStore()
        let pane1 = makePane()
        let floatPane = FloatingPane(pane: makePane())
        let tab = makeTab(panes: [pane1], floats: [floatPane])
        let sid = UUID()
        let s = makeSession(id: sid, name: "dev", tabs: [tab])
        store.refreshRefs(snapshots: [snapshot(s)])

        let r1 = try store.resolve(refString: "dev")
        #expect(r1.sessionID == sid)

        let r2 = try store.resolve(refString: "dev/tab:1")
        #expect(r2.tabID == tab.id)

        let r3 = try store.resolve(refString: "dev/pane:1")
        #expect(r3.paneID == pane1.id)
        #expect(r3.tabID == tab.id)

        let r4 = try store.resolve(refString: "dev/float:1")
        // Float refs resolve to the inner TerminalPane UUID, not the
        // FloatingPane struct UUID — see GUIAutomationRefStore.refreshChildren.
        #expect(r4.floatID == floatPane.pane.id)
        #expect(r4.tabID == tab.id)
    }

    @Test func invalidRefFormatThrows() {
        let store = GUIAutomationRefStore()
        #expect(throws: AutomationError.self) {
            _ = try store.resolve(refString: "dev/bogus:1")
        }
    }

    // MARK: DFS ordering

    @Test func paneNumberingFollowsDFSLeftFirst() {
        let store = GUIAutomationRefStore()
        // Build tree: container(container(A, B), C) — DFS yields A, B, C.
        let a = makePane(); let b = makePane(); let c = makePane()
        let inner: PaneNode = .container(Container(
            strategy: .vertical,
            children: [.leaf(a), .leaf(b)],
            weights: [1.0, 1.0]
        ))
        let tree: PaneNode = .container(Container(
            strategy: .horizontal,
            children: [inner, .leaf(c)],
            weights: [1.0, 1.0]
        ))
        let tab = TerminalTab(id: UUID(), title: "t", paneTree: tree)
        let sid = UUID()
        let s = makeSession(id: sid, name: "dev", tabs: [tab])
        store.refreshRefs(snapshots: [snapshot(s)])
        #expect(store.paneRef(sessionID: sid, paneID: a.id) == "dev/pane:1")
        #expect(store.paneRef(sessionID: sid, paneID: b.id) == "dev/pane:2")
        #expect(store.paneRef(sessionID: sid, paneID: c.id) == "dev/pane:3")
    }

    // MARK: describeSessions

    @Test func describeSessionsIncludesAllFields() {
        let store = GUIAutomationRefStore()
        let pane1 = makePane(); let pane2 = makePane()
        let floatPane = FloatingPane(pane: makePane(), title: "F")
        let tab1 = makeTab(title: "Shell", panes: [pane1])
        let tab2 = makeTab(title: "Logs", panes: [pane2], floats: [floatPane])
        let sid = UUID()
        let dev = TerminalSession(
            id: sid,
            name: "dev",
            tabs: [tab1, tab2],
            activeTabIndex: 1,
            source: .local,
            isAnonymous: false
        )
        let unnamed = makeSession(name: "")
        let remote = makeSession(
            id: UUID(),
            name: "prod",
            tabs: [],
            source: .remote(serverSessionID: UUID())
        )

        let snapshots = [
            snapshot(dev, state: .ready, isActive: true),
            snapshot(unnamed, state: .ready, isActive: false),
            snapshot(remote, state: .detached, isActive: false),
        ]
        store.refreshRefs(snapshots: snapshots)
        let response = store.describeSessions(snapshots: snapshots)

        #expect(response.sessions.count == 3)

        let devDesc = response.sessions[0]
        #expect(devDesc.ref == "dev")
        #expect(devDesc.name == "dev")
        #expect(devDesc.type == .local)
        #expect(devDesc.state == .ready)
        #expect(devDesc.active == true)
        #expect(devDesc.tabs.count == 2)
        #expect(devDesc.tabs[0].active == false)
        #expect(devDesc.tabs[1].active == true)
        #expect(devDesc.tabs[1].panes == ["dev/pane:2"])
        #expect(devDesc.tabs[1].floats == ["dev/float:1"])

        let unnamedDesc = response.sessions[1]
        #expect(unnamedDesc.ref == "sess:1")
        #expect(unnamedDesc.name == "")

        let remoteDesc = response.sessions[2]
        #expect(remoteDesc.ref == "prod")
        #expect(remoteDesc.type == .remote)
        #expect(remoteDesc.state == .detached)
    }

    @Test func describeSessionsJSONEncodable() throws {
        let store = GUIAutomationRefStore()
        let s = makeSession(name: "dev")
        let snap = snapshot(s)
        store.refreshRefs(snapshots: [snap])
        let response = store.describeSessions(snapshots: [snap])

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(SessionListResponse.self, from: data)
        #expect(decoded == response)
    }
}
