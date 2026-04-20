import Testing
import Foundation
@testable import TYProtocol
@testable import TYTerminal
import TYConfig

@Suite("WireFormat tests", .serialized)
struct WireFormatTests {

    // MARK: - Frame Header

    @Test func validHeader() throws {
        let frame = WireFormat.buildFrame(typeCode: 0x0100, payload: [0x01, 0x02, 0x03])
        #expect(frame.count == WireFormat.headerSize + 3)

        let (typeCode, length) = try WireFormat.parseHeader(Array(frame[0..<WireFormat.headerSize]))
        #expect(typeCode == 0x0100)
        #expect(length == 3)
    }

    @Test func emptyPayload() throws {
        let frame = WireFormat.buildFrame(typeCode: 0x0200, payload: [])
        #expect(frame.count == WireFormat.headerSize)

        let (typeCode, length) = try WireFormat.parseHeader(frame)
        #expect(typeCode == 0x0200)
        #expect(length == 0)
    }

    @Test func invalidMagicThrows() throws {
        var header = WireFormat.buildFrame(typeCode: 0, payload: [])
        header[0] = 0xFF  // corrupt magic
        #expect(throws: WireFormatError.self) {
            try WireFormat.parseHeader(header)
        }
    }

    @Test func payloadTooLargeThrows() throws {
        // Forge a header with payload length > max
        var header: [UInt8] = [0x54, 0x59, 0x00, 0x01, 0, 0, 0, 0]
        let tooLarge = WireFormat.maxPayloadSize + 1
        withUnsafeBytes(of: tooLarge.littleEndian) { bytes in
            for i in 0..<4 { header[4 + i] = bytes[i] }
        }
        #expect(throws: WireFormatError.self) {
            try WireFormat.parseHeader(header)
        }
    }

    // MARK: - Server Message Round-Trip

    @Test func roundTripSessionList() throws {
        let sid = SessionID()
        let pid = PaneID()
        let tid = TabID()
        let msg = ServerMessage.sessionList([
            SessionInfo(
                id: sid,
                name: "test",
                tabs: [TabInfo(id: tid, title: "shell", layout: .leaf(pid))],
                activeTabIndex: 0
            ),
        ])

        let frame = WireFormat.encodeServerMessage(msg)
        let raw = RawFrame(
            typeCode: ServerMessageType.sessionList.rawValue,
            payload: Array(frame[WireFormat.headerSize...])
        )
        let decoded = try WireFormat.decodeServerMessage(raw)

        guard case .sessionList(let sessions) = decoded else {
            Issue.record("Expected .sessionList, got \(decoded)")
            return
        }
        #expect(sessions.count == 1)
        #expect(sessions[0].id == sid)
        #expect(sessions[0].name == "test")
    }

    @Test func roundTripSessionCreated() throws {
        let sid = SessionID()
        let msg = ServerMessage.sessionCreated(
            SessionInfo(id: sid, name: "new-session")
        )

        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .sessionCreated(let info) = decoded else {
            Issue.record("Expected .sessionCreated")
            return
        }
        #expect(info.id == sid)
        #expect(info.name == "new-session")
    }

    @Test func roundTripSessionClosed() throws {
        let sid = SessionID()
        let msg = ServerMessage.sessionClosed(sid)

        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .sessionClosed(let id) = decoded else {
            Issue.record("Expected .sessionClosed")
            return
        }
        #expect(id == sid)
    }

    @Test func roundTripScreenFull() throws {
        let sid = SessionID()
        let pid = PaneID()
        let cells = [Cell](repeating: Cell.empty, count: 6)
        let snapshot = ScreenSnapshot(
            cells: cells, columns: 3, rows: 2,
            cursorCol: 0, cursorRow: 0,
            cursorVisible: true, cursorShape: .block,
            selection: nil, scrollbackCount: 0,
            viewportOffset: 0, dirtyRegion: .full
        )
        let msg = ServerMessage.screenFull(sid, pid, snapshot, mouseTrackingMode: 0)

        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .screenFull(let dSid, let dPid, let dSnap, let dMouse) = decoded else {
            Issue.record("Expected .screenFull")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(dSnap.columns == 3)
        #expect(dSnap.rows == 2)
        #expect(dSnap.cells.count == 6)
        #expect(dMouse == 0)
    }

    @Test func roundTripScreenDiff() throws {
        let sid = SessionID()
        let pid = PaneID()
        let cells = [Cell](repeating: Cell.empty, count: 4)
        let diff = ScreenDiff(
            dirtyRows: [2],
            cellData: cells,
            columns: 4,
            cursorCol: 1, cursorRow: 2,
            cursorVisible: true, cursorShape: .underline
        )
        let msg = ServerMessage.screenDiff(sid, pid, diff)

        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .screenDiff(let dSid, let dPid, let dDiff) = decoded else {
            Issue.record("Expected .screenDiff")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(dDiff.dirtyRows == [2])
        #expect(dDiff.cellData.count == 4)
    }

    @Test func roundTripTitleChanged() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ServerMessage.titleChanged(sid, pid, "vim ~/code")

        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .titleChanged(_, _, let title) = decoded else {
            Issue.record("Expected .titleChanged")
            return
        }
        #expect(title == "vim ~/code")
    }

    @Test func roundTripBell() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ServerMessage.bell(sid, pid)

        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .bell(let dSid, let dPid) = decoded else {
            Issue.record("Expected .bell")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
    }

    @Test func roundTripPaneExited() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ServerMessage.paneExited(sid, pid, exitCode: -1)

        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .paneExited(_, _, let code) = decoded else {
            Issue.record("Expected .paneExited")
            return
        }
        #expect(code == -1)
    }

    @Test func roundTripLayoutUpdate() throws {
        let sid = SessionID()
        let p1 = PaneID()
        let p2 = PaneID()
        let tree = LayoutTree.container(
            strategy: .vertical,
            children: [.leaf(p1), .leaf(p2)],
            weights: [0.6, 0.4]
        )
        let info = SessionInfo(
            id: sid,
            name: "layout test",
            tabs: [TabInfo(id: TabID(), title: "t", layout: tree)]
        )
        let msg = ServerMessage.layoutUpdate(info)

        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .layoutUpdate(let dInfo) = decoded else {
            Issue.record("Expected .layoutUpdate")
            return
        }
        #expect(dInfo.id == sid)
        #expect(dInfo.tabs[0].layout == tree)
    }

    @Test func roundTripClipboardSet() throws {
        let msg = ServerMessage.clipboardSet("copied text 📋")

        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .clipboardSet(let text) = decoded else {
            Issue.record("Expected .clipboardSet")
            return
        }
        #expect(text == "copied text 📋")
    }

    // MARK: - Client Message Round-Trip

    @Test func roundTripListSessions() throws {
        let msg = ClientMessage.listSessions
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .listSessions = decoded else {
            Issue.record("Expected .listSessions")
            return
        }
    }

    @Test func roundTripCreateSessionWithName() throws {
        let msg = ClientMessage.createSession(name: "dev")
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .createSession(let name) = decoded else {
            Issue.record("Expected .createSession")
            return
        }
        #expect(name == "dev")
    }

    @Test func roundTripCreateSessionWithoutName() throws {
        let msg = ClientMessage.createSession(name: nil)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .createSession(let name) = decoded else {
            Issue.record("Expected .createSession")
            return
        }
        #expect(name == nil)
    }

    @Test func roundTripAttachSession() throws {
        let sid = SessionID()
        let msg = ClientMessage.attachSession(sid)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .attachSession(let id) = decoded else {
            Issue.record("Expected .attachSession")
            return
        }
        #expect(id == sid)
    }

    @Test func roundTripInput() throws {
        let sid = SessionID()
        let pid = PaneID()
        let bytes: [UInt8] = [0x1B, 0x5B, 0x41]  // ESC [ A (arrow up)
        let msg = ClientMessage.input(sid, pid, bytes)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .input(let dSid, let dPid, let dBytes) = decoded else {
            Issue.record("Expected .input")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(dBytes == bytes)
    }

    @Test func roundTripPaste() throws {
        let sid = SessionID()
        let pid = PaneID()
        // Payload large enough to exercise the length-prefixed byte path —
        // representative of the vim paste bug (multi-KB multi-line text).
        var bytes = [UInt8](repeating: 0x61, count: 32 * 1024)
        bytes[100] = 0x0A   // a real \n so the test data looks like paste
        bytes[200] = 0x0A
        let msg = ClientMessage.paste(sid, pid, bytes)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .paste(let dSid, let dPid, let dBytes) = decoded else {
            Issue.record("Expected .paste")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(dBytes == bytes)
    }

    @Test func roundTripResize() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ClientMessage.resize(sid, pid, cols: 120, rows: 40)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .resize(let dSid, let dPid, let cols, let rows) = decoded else {
            Issue.record("Expected .resize")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(cols == 120)
        #expect(rows == 40)
    }

    @Test func roundTripCreateTab() throws {
        let sid = SessionID()
        let msg = ClientMessage.createTab(sid, profileID: nil, snapshot: nil, variables: [:])
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .createTab(let id, let profileID, let snapshot, let variables) = decoded else {
            Issue.record("Expected .createTab")
            return
        }
        #expect(id == sid)
        #expect(profileID == nil)
        #expect(snapshot == nil)
        #expect(variables.isEmpty)
    }

    @Test func roundTripCreateTabWithVariables() throws {
        // Variables round-trip with keys/values intact and order-independent
        // (sorted on the wire, reconstructed as a dict).
        let sid = SessionID()
        let vars = ["HOST": "db1.prod", "USER": "alice"]
        let msg = ClientMessage.createTab(sid, profileID: "ssh-prod", snapshot: nil, variables: vars)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .createTab(_, let profileID, _, let variables) = decoded else {
            Issue.record("Expected .createTab")
            return
        }
        #expect(profileID == "ssh-prod")
        #expect(variables == vars)
    }

    @Test func roundTripCloseTab() throws {
        let sid = SessionID()
        let tid = TabID()
        let msg = ClientMessage.closeTab(sid, tid)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .closeTab(let dSid, let dTid) = decoded else {
            Issue.record("Expected .closeTab")
            return
        }
        #expect(dSid == sid)
        #expect(dTid == tid)
    }

    @Test func roundTripSplitPane() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ClientMessage.splitPane(
            sid, pid, .horizontal,
            profileID: nil, snapshot: nil, variables: [:]
        )
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .splitPane(_, _, let dir, let profileID, let snapshot, let variables) = decoded else {
            Issue.record("Expected .splitPane")
            return
        }
        #expect(dir == .horizontal)
        #expect(profileID == nil)
        #expect(snapshot == nil)
        #expect(variables.isEmpty)
    }

    @Test func roundTripClosePane() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ClientMessage.closePane(sid, pid)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .closePane(let dSid, let dPid) = decoded else {
            Issue.record("Expected .closePane")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
    }

    @Test func roundTripFocusPane() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ClientMessage.focusPane(sid, pid)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .focusPane(let dSid, let dPid) = decoded else {
            Issue.record("Expected .focusPane")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
    }

    @Test func roundTripRefreshPane() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ClientMessage.refreshPane(sid, pid)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .refreshPane(let dSid, let dPid) = decoded else {
            Issue.record("Expected .refreshPane")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
    }

    @Test func roundTripScrollViewport() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ClientMessage.scrollViewport(sid, pid, delta: -10)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .scrollViewport(let dSid, let dPid, let delta) = decoded else {
            Issue.record("Expected .scrollViewport")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(delta == -10)
    }

    @Test func roundTripDetachSession() throws {
        let sid = SessionID()
        let msg = ClientMessage.detachSession(sid)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .detachSession(let id) = decoded else {
            Issue.record("Expected .detachSession")
            return
        }
        #expect(id == sid)
    }

    @Test func roundTripCloseSession() throws {
        let sid = SessionID()
        let msg = ClientMessage.closeSession(sid)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .closeSession(let id) = decoded else {
            Issue.record("Expected .closeSession")
            return
        }
        #expect(id == sid)
    }

    @Test func roundTripExtractSelection() throws {
        let sid = SessionID(UUID())
        let pid = PaneID(UUID())
        let sel = Selection(
            start: SelectionPoint(line: 150, col: 5),
            end: SelectionPoint(line: 160, col: 42),
            mode: .character
        )
        let msg = ClientMessage.extractSelection(sid, pid, sel)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .extractSelection(let dSid, let dPid, let dSel) = decoded else {
            Issue.record("Expected .extractSelection")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(dSel.start.line == 150)
        #expect(dSel.start.col == 5)
        #expect(dSel.end.line == 160)
        #expect(dSel.end.col == 42)
        #expect(dSel.mode == .character)
    }

    @Test func roundTripExtractSelectionLineMode() throws {
        let sid = SessionID(UUID())
        let pid = PaneID(UUID())
        let sel = Selection(
            start: SelectionPoint(line: 0, col: 0),
            end: SelectionPoint(line: 5, col: 79),
            mode: .line
        )
        let msg = ClientMessage.extractSelection(sid, pid, sel)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .extractSelection(_, _, let dSel) = decoded else {
            Issue.record("Expected .extractSelection")
            return
        }
        #expect(dSel.mode == .line)
    }

    @Test func roundTripSelectTab() throws {
        let sid = SessionID()
        let msg = ClientMessage.selectTab(sid, tabIndex: 3)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .selectTab(let dSid, let tabIndex) = decoded else {
            Issue.record("Expected .selectTab")
            return
        }
        #expect(dSid == sid)
        #expect(tabIndex == 3)
    }

    @Test func roundTripSetSplitRatio() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ClientMessage.setSplitRatio(sid, pid, ratio: 0.3)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .setSplitRatio(let dSid, let dPid, let ratio) = decoded else {
            Issue.record("Expected .setSplitRatio")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(abs(ratio - 0.3) < 1e-6)
    }

    @Test func roundTripTabInfoWithFocusedPaneID() throws {
        let sid = SessionID()
        let pid = PaneID()
        let focusedPID = PaneID()
        let tab = TabInfo(
            id: TabID(), title: "focused",
            layout: .leaf(pid),
            focusedPaneID: focusedPID
        )
        let info = SessionInfo(id: sid, name: "focus test", tabs: [tab])
        let msg = ServerMessage.layoutUpdate(info)

        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .layoutUpdate(let dInfo) = decoded else {
            Issue.record("Expected .layoutUpdate")
            return
        }
        #expect(dInfo.tabs[0].focusedPaneID == focusedPID)
    }

    @Test func roundTripTabInfoWithNilFocusedPaneID() throws {
        let sid = SessionID()
        let pid = PaneID()
        let tab = TabInfo(id: TabID(), title: "no focus", layout: .leaf(pid))
        let info = SessionInfo(id: sid, name: "nil focus test", tabs: [tab])
        let msg = ServerMessage.layoutUpdate(info)

        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .layoutUpdate(let dInfo) = decoded else {
            Issue.record("Expected .layoutUpdate")
            return
        }
        #expect(dInfo.tabs[0].focusedPaneID == nil)
    }

    @Test func roundTripMouseEvent() throws {
        let sid = SessionID()
        let pid = PaneID()
        let event = MouseEncoder.Event(
            action: .press, button: .left, col: 10, row: 5,
            modifiers: MouseEncoder.Modifiers(shift: true, option: false, control: true)
        )
        let msg = ClientMessage.mouseEvent(sid, pid, event)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .mouseEvent(let dSid, let dPid, let dEvent) = decoded else {
            Issue.record("Expected .mouseEvent")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(dEvent.col == 10)
        #expect(dEvent.row == 5)
        #expect(dEvent.modifiers.shift == true)
        #expect(dEvent.modifiers.option == false)
        #expect(dEvent.modifiers.control == true)
    }

    @Test func roundTripMouseEventMotionNoButton() throws {
        let sid = SessionID()
        let pid = PaneID()
        let event = MouseEncoder.Event(action: .motion, button: nil, col: 42, row: 13)
        let msg = ClientMessage.mouseEvent(sid, pid, event)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .mouseEvent(_, _, let dEvent) = decoded else {
            Issue.record("Expected .mouseEvent")
            return
        }
        #expect(dEvent.button == nil)
        #expect(dEvent.col == 42)
        #expect(dEvent.row == 13)
    }

    @Test func roundTripScreenFullWithMouseTrackingMode() throws {
        let sid = SessionID()
        let pid = PaneID()
        let cells = [Cell](repeating: Cell.empty, count: 4)
        let snapshot = ScreenSnapshot(
            cells: cells, columns: 2, rows: 2,
            cursorCol: 0, cursorRow: 0,
            cursorVisible: true, cursorShape: .block,
            selection: nil, scrollbackCount: 0,
            viewportOffset: 0, dirtyRegion: .full
        )
        let msg = ServerMessage.screenFull(sid, pid, snapshot, mouseTrackingMode: 103)
        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .screenFull(_, _, _, let dMouse) = decoded else {
            Issue.record("Expected .screenFull")
            return
        }
        #expect(dMouse == 103)
    }

    @Test func roundTripScreenDiffWithMouseTrackingMode() throws {
        let sid = SessionID()
        let pid = PaneID()
        let cells = [Cell](repeating: Cell.empty, count: 4)
        let diff = ScreenDiff(
            dirtyRows: [0],
            cellData: cells,
            columns: 4,
            cursorCol: 0, cursorRow: 0,
            cursorVisible: true, cursorShape: .block,
            mouseTrackingMode: 100
        )
        let msg = ServerMessage.screenDiff(sid, pid, diff)
        let decoded = try encodeAndDecode(serverMessage: msg)
        guard case .screenDiff(_, _, let dDiff) = decoded else {
            Issue.record("Expected .screenDiff")
            return
        }
        #expect(dDiff.mouseTrackingMode == 100)
    }

    @Test func roundTripRestartFloatingPaneCommand() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ClientMessage.restartFloatingPaneCommand(sid, pid, command: "git", arguments: ["status"])
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .restartFloatingPaneCommand(let dSid, let dPid, let cmd, let args) = decoded else {
            Issue.record("Expected .restartFloatingPaneCommand")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(cmd == "git")
        #expect(args == ["status"])
    }

    @Test func roundTripRerunPane() throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ClientMessage.rerunPane(sid, pid)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .rerunPane(let dSid, let dPid) = decoded else {
            Issue.record("Expected .rerunPane")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
    }

    @Test(arguments: [
        FocusDirection.left,
        FocusDirection.right,
        FocusDirection.up,
        FocusDirection.down,
    ])
    func roundTripMovePane(side: FocusDirection) throws {
        let sid = SessionID()
        let source = PaneID()
        let target = PaneID()
        let msg = ClientMessage.movePane(
            sid, sourcePaneID: source, targetPaneID: target, side: side
        )
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .movePane(let dSid, let dSource, let dTarget, let dSide) = decoded else {
            Issue.record("Expected .movePane")
            return
        }
        #expect(dSid == sid)
        #expect(dSource == source)
        #expect(dTarget == target)
        #expect(dSide == side)
    }

    @Test(arguments: [
        LayoutStrategyKind.horizontal,
        LayoutStrategyKind.vertical,
        LayoutStrategyKind.grid,
        LayoutStrategyKind.masterStack,
        LayoutStrategyKind.fibonacci,
    ])
    func roundTripChangeStrategy(kind: LayoutStrategyKind) throws {
        let sid = SessionID()
        let pid = PaneID()
        let msg = ClientMessage.changeStrategy(sid, pid, kind)
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .changeStrategy(let dSid, let dPid, let dKind) = decoded else {
            Issue.record("Expected .changeStrategy")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(dKind == kind)
    }

    // MARK: - Unknown Type Codes

    @Test func unknownServerTypeThrows() throws {
        let raw = RawFrame(typeCode: 0x09FF, payload: [])
        #expect(throws: WireFormatError.self) {
            try WireFormat.decodeServerMessage(raw)
        }
    }

    @Test func unknownClientTypeThrows() throws {
        let raw = RawFrame(typeCode: 0x09FF, payload: [])
        #expect(throws: WireFormatError.self) {
            try WireFormat.decodeClientMessage(raw)
        }
    }

    // MARK: - Helpers

    private func encodeAndDecode(serverMessage msg: ServerMessage) throws -> ServerMessage {
        let frame = WireFormat.encodeServerMessage(msg)
        let raw = RawFrame(
            typeCode: msg.typeCode.rawValue,
            payload: Array(frame[WireFormat.headerSize...])
        )
        return try WireFormat.decodeServerMessage(raw)
    }

    @Test func roundTripCreateFloatingPaneWithSnapshotAndFrame() throws {
        let sid = SessionID()
        let tid = TabID()
        let snapshot = StartupSnapshot(
            command: "htop",
            args: [],
            env: [EnvVar(key: "TERM", value: "xterm-256color")],
            closeOnExit: false
        )
        let frameHint = FloatFrameHint(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
        let msg = ClientMessage.createFloatingPane(
            sid, tid,
            profileID: "ci",
            snapshot: snapshot,
            variables: [:],
            frameHint: frameHint
        )
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .createFloatingPane(let dSid, let dTid, let profileID, let decodedSnap, _, let decodedHint) = decoded else {
            Issue.record("Expected .createFloatingPane")
            return
        }
        #expect(dSid == sid)
        #expect(dTid == tid)
        #expect(profileID == "ci")
        #expect(decodedSnap == snapshot)
        #expect(decodedHint == frameHint)
    }

    @Test func roundTripCreateFloatingPaneMinimal() throws {
        let sid = SessionID()
        let tid = TabID()
        let msg = ClientMessage.createFloatingPane(
            sid, tid,
            profileID: nil, snapshot: nil, variables: [:], frameHint: nil
        )
        let decoded = try encodeAndDecode(clientMessage: msg)
        guard case .createFloatingPane(_, _, let profileID, let snapshot, _, let frameHint) = decoded else {
            Issue.record("Expected .createFloatingPane")
            return
        }
        #expect(profileID == nil)
        #expect(snapshot == nil)
        #expect(frameHint == nil)
    }

    /// Guard against silent regression of the deleted `createFloatingPaneWithCommand`
    /// opcode (0x022D). Decoding a frame with that type code must fail.
    @Test func decodingRemovedCreateFloatingPaneWithCommandOpcode() throws {
        let raw = RawFrame(typeCode: 0x022D, payload: [])
        #expect(throws: WireFormatError.self) {
            _ = try WireFormat.decodeClientMessage(raw)
        }
    }

    private func encodeAndDecode(clientMessage msg: ClientMessage) throws -> ClientMessage {
        let frame = WireFormat.encodeClientMessage(msg)
        let raw = RawFrame(
            typeCode: msg.typeCode.rawValue,
            payload: Array(frame[WireFormat.headerSize...])
        )
        return try WireFormat.decodeClientMessage(raw)
    }
}
