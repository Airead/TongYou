import Testing
import Foundation
@testable import TYProtocol
@testable import TYTerminal
import TYConfig

@Suite("BinaryEncoder/Decoder round-trip tests", .serialized)
struct BinaryCoderTests {

    // MARK: - Primitives

    @Test func roundTripUInt8() throws {
        var encoder = BinaryEncoder()
        encoder.writeUInt8(0)
        encoder.writeUInt8(255)
        encoder.writeUInt8(42)

        var decoder = BinaryDecoder(encoder.data)
        #expect(try decoder.readUInt8() == 0)
        #expect(try decoder.readUInt8() == 255)
        #expect(try decoder.readUInt8() == 42)
        #expect(decoder.remaining == 0)
    }

    @Test func roundTripBool() throws {
        var encoder = BinaryEncoder()
        encoder.writeBool(true)
        encoder.writeBool(false)

        var decoder = BinaryDecoder(encoder.data)
        #expect(try decoder.readBool() == true)
        #expect(try decoder.readBool() == false)
    }

    @Test func roundTripUInt16() throws {
        var encoder = BinaryEncoder()
        encoder.writeUInt16(0)
        encoder.writeUInt16(0xFFFF)
        encoder.writeUInt16(12345)

        var decoder = BinaryDecoder(encoder.data)
        #expect(try decoder.readUInt16() == 0)
        #expect(try decoder.readUInt16() == 0xFFFF)
        #expect(try decoder.readUInt16() == 12345)
    }

    @Test func roundTripUInt32() throws {
        var encoder = BinaryEncoder()
        encoder.writeUInt32(0)
        encoder.writeUInt32(0xDEADBEEF)

        var decoder = BinaryDecoder(encoder.data)
        #expect(try decoder.readUInt32() == 0)
        #expect(try decoder.readUInt32() == 0xDEADBEEF)
    }

    @Test func roundTripInt32() throws {
        var encoder = BinaryEncoder()
        encoder.writeInt32(0)
        encoder.writeInt32(-1)
        encoder.writeInt32(Int32.max)
        encoder.writeInt32(Int32.min)

        var decoder = BinaryDecoder(encoder.data)
        #expect(try decoder.readInt32() == 0)
        #expect(try decoder.readInt32() == -1)
        #expect(try decoder.readInt32() == Int32.max)
        #expect(try decoder.readInt32() == Int32.min)
    }

    @Test func roundTripFloat() throws {
        var encoder = BinaryEncoder()
        encoder.writeFloat(0.5)
        encoder.writeFloat(3.14)

        var decoder = BinaryDecoder(encoder.data)
        #expect(try decoder.readFloat() == 0.5)
        #expect(try decoder.readFloat() == Float(3.14))
    }

    @Test func roundTripUUID() throws {
        let uuid = UUID()
        var encoder = BinaryEncoder()
        encoder.writeUUID(uuid)

        var decoder = BinaryDecoder(encoder.data)
        #expect(try decoder.readUUID() == uuid)
    }

    @Test func roundTripString() throws {
        var encoder = BinaryEncoder()
        encoder.writeString("")
        encoder.writeString("hello")
        encoder.writeString("你好世界")

        var decoder = BinaryDecoder(encoder.data)
        #expect(try decoder.readString() == "")
        #expect(try decoder.readString() == "hello")
        #expect(try decoder.readString() == "你好世界")
    }

    @Test func roundTripBytes() throws {
        let data: [UInt8] = [0x01, 0x02, 0xFF, 0x00]
        var encoder = BinaryEncoder()
        encoder.writeBytes(data)
        encoder.writeBytes([])

        var decoder = BinaryDecoder(encoder.data)
        #expect(try decoder.readBytes() == data)
        #expect(try decoder.readBytes() == [])
    }

    // MARK: - Identifiers

    @Test func roundTripIdentifiers() throws {
        let sessionID = SessionID()
        let tabID = TabID()
        let paneID = PaneID()

        var encoder = BinaryEncoder()
        encoder.writeSessionID(sessionID)
        encoder.writeTabID(tabID)
        encoder.writePaneID(paneID)

        var decoder = BinaryDecoder(encoder.data)
        #expect(try decoder.readSessionID() == sessionID)
        #expect(try decoder.readTabID() == tabID)
        #expect(try decoder.readPaneID() == paneID)
    }

    // MARK: - Cell

    @Test func roundTripCell() throws {
        let cell = Cell(
            codepoint: Unicode.Scalar("A"),
            attributes: CellAttributes(
                flags: [.bold, .italic],
                fgColor: PackedColor(raw: 0x0200FF00),
                bgColor: PackedColor(raw: 0x010010FF)
            ),
            width: .normal
        )

        var encoder = BinaryEncoder()
        encoder.writeCell(cell)
        #expect(encoder.data.count == 16) // 1B count + 4B scalar + 4B fg + 4B bg + 2B flags + 1B width

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readCell()
        #expect(decoded.codepoint == Unicode.Scalar("A"))
        #expect(decoded.attributes.flags == [.bold, .italic])
        #expect(decoded.attributes.fgColor.raw == 0x0200FF00)
        #expect(decoded.attributes.bgColor.raw == 0x010010FF)
        #expect(decoded.width == .normal)
    }

    @Test func roundTripMultiScalarCell() throws {
        let cell = Cell(
            content: GraphemeCluster(Character("👨‍👩‍👧‍👦")),
            attributes: .default,
            width: .wide
        )

        var encoder = BinaryEncoder()
        encoder.writeCell(cell)
        #expect(encoder.data.count == 40) // 1B count + 7*4B scalars + 4B fg + 4B bg + 2B flags + 1B width

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readCell()
        #expect(decoded.content.scalarCount == 7)
        #expect(decoded.content == cell.content)
        #expect(decoded.width == .wide)
    }

    @Test func roundTripEmptyCell() throws {
        let cell = Cell.empty

        var encoder = BinaryEncoder()
        encoder.writeCell(cell)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readCell()
        #expect(decoded == cell)
    }

    @Test func roundTripWideCell() throws {
        let cell = Cell(
            codepoint: Unicode.Scalar("中"),
            attributes: .default,
            width: .wide
        )

        var encoder = BinaryEncoder()
        encoder.writeCell(cell)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readCell()
        #expect(decoded.codepoint == Unicode.Scalar("中"))
        #expect(decoded.width == .wide)
    }

    @Test func roundTripCells() throws {
        let cells = [
            Cell(codepoint: Unicode.Scalar("H"), attributes: .default, width: .normal),
            Cell(codepoint: Unicode.Scalar("i"), attributes: .default, width: .normal),
            Cell.empty,
        ]

        var encoder = BinaryEncoder()
        encoder.writeCells(cells)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readCells()
        #expect(decoded.count == 3)
        #expect(decoded[0].codepoint == Unicode.Scalar("H"))
        #expect(decoded[1].codepoint == Unicode.Scalar("i"))
        #expect(decoded[2] == Cell.empty)
    }

    // MARK: - Cursor State

    @Test func roundTripCursorState() throws {
        var encoder = BinaryEncoder()
        encoder.writeCursorState(col: 10, row: 5, visible: true, shape: .bar)

        var decoder = BinaryDecoder(encoder.data)
        let cursor = try decoder.readCursorState()
        #expect(cursor.col == 10)
        #expect(cursor.row == 5)
        #expect(cursor.visible == true)
        #expect(cursor.shape == .bar)
    }

    // MARK: - Layout Tree

    @Test func roundTripLayoutTreeLeaf() throws {
        let paneID = PaneID()
        let tree = LayoutTree.leaf(paneID)

        var encoder = BinaryEncoder()
        encoder.writeLayoutTree(tree)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readLayoutTree()
        #expect(decoded == tree)
    }

    @Test func roundTripLayoutTreeContainer() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()
        let tree = LayoutTree.container(
            strategy: .horizontal,
            children: [
                .leaf(p1),
                .container(
                    strategy: .vertical,
                    children: [.leaf(p2), .leaf(p3)],
                    weights: [0.3, 0.7]
                )
            ],
            weights: [0.5, 0.5]
        )

        var encoder = BinaryEncoder()
        encoder.writeLayoutTree(tree)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readLayoutTree()
        #expect(decoded == tree)
    }

    @Test func roundTripLayoutTreeContainerNAry() throws {
        // N-ary container with 4 children and distinct weights — exercises
        // the count prefix and per-child weight decoding added in P2.
        let panes = [PaneID(), PaneID(), PaneID(), PaneID()]
        let tree = LayoutTree.container(
            strategy: .vertical,
            children: panes.map { .leaf($0) },
            weights: [1.0, 2.0, 1.5, 0.5]
        )

        var encoder = BinaryEncoder()
        encoder.writeLayoutTree(tree)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readLayoutTree()
        #expect(decoded == tree)
    }

    @Test func roundTripLayoutTreeAllStrategies() throws {
        // Every strategy case must survive a round trip (the P2 wire format
        // maps each kind to a distinct UInt8 tag).
        let strategies: [LayoutStrategyKind] = [
            .horizontal, .vertical, .grid, .masterStack, .fibonacci,
        ]
        for strategy in strategies {
            let tree = LayoutTree.container(
                strategy: strategy,
                children: [.leaf(PaneID()), .leaf(PaneID())],
                weights: [1.0, 1.0]
            )
            var encoder = BinaryEncoder()
            encoder.writeLayoutTree(tree)
            var decoder = BinaryDecoder(encoder.data)
            #expect(try decoder.readLayoutTree() == tree)
        }
    }

    // MARK: - FloatingPaneInfo

    @Test func roundTripFloatingPaneInfo() throws {
        let paneID = PaneID()
        let info = FloatingPaneInfo(
            paneID: paneID,
            frameX: 0.1, frameY: 0.2,
            frameWidth: 0.5, frameHeight: 0.6,
            zIndex: 3,
            isPinned: true,
            isVisible: false,
            title: "my float"
        )

        var encoder = BinaryEncoder()
        encoder.writeFloatingPaneInfo(info)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readFloatingPaneInfo()
        #expect(decoded == info)
        #expect(decoder.remaining == 0)
    }

    @Test func roundTripTabInfoWithFloatingPanes() throws {
        let treePaneID = PaneID()
        let floatPaneID = PaneID()
        let tabID = TabID()
        let tab = TabInfo(
            id: tabID,
            title: "tab1",
            layout: .leaf(treePaneID),
            floatingPanes: [
                FloatingPaneInfo(paneID: floatPaneID, zIndex: 1, title: "Float 1"),
            ]
        )

        var encoder = BinaryEncoder()
        encoder.writeTabInfo(tab)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readTabInfo()
        #expect(decoded.id == tabID)
        #expect(decoded.title == "tab1")
        #expect(decoded.layout == .leaf(treePaneID))
        #expect(decoded.floatingPanes.count == 1)
        #expect(decoded.floatingPanes[0].paneID == floatPaneID)
        #expect(decoded.floatingPanes[0].zIndex == 1)
        #expect(decoded.floatingPanes[0].title == "Float 1")
        #expect(decoder.remaining == 0)
    }

    @Test func roundTripSessionInfoWithFloatingPanes() throws {
        let treePaneID = PaneID()
        let floatPaneID1 = PaneID()
        let floatPaneID2 = PaneID()
        let tabID = TabID()
        let sessionID = SessionID()
        let info = SessionInfo(
            id: sessionID,
            name: "test",
            tabs: [
                TabInfo(
                    id: tabID,
                    title: "tab",
                    layout: .leaf(treePaneID),
                    floatingPanes: [
                        FloatingPaneInfo(paneID: floatPaneID1, zIndex: 0, title: "F1"),
                        FloatingPaneInfo(paneID: floatPaneID2, zIndex: 1, isPinned: true, title: "F2"),
                    ]
                ),
            ],
            activeTabIndex: 0
        )

        var encoder = BinaryEncoder()
        encoder.writeSessionInfo(info)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readSessionInfo()
        #expect(decoded.id == sessionID)
        #expect(decoded.tabs.count == 1)
        #expect(decoded.tabs[0].floatingPanes.count == 2)
        #expect(decoded.tabs[0].floatingPanes[0].paneID == floatPaneID1)
        #expect(decoded.tabs[0].floatingPanes[1].isPinned == true)
        #expect(decoder.remaining == 0)
    }

    // MARK: - Floating Pane Client Messages

    @Test func roundTripCreateFloatingPaneMessage() throws {
        let sessionID = SessionID()
        let tabID = TabID()
        let msg = ClientMessage.createFloatingPane(
            sessionID, tabID,
            profileID: nil, snapshot: nil, variables: [:], frameHint: nil
        )

        var encoder = BinaryEncoder()
        encoder.writeClientMessage(msg)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readClientMessage(type: .createFloatingPane)
        if case .createFloatingPane(let sid, let tid, let profileID, let snapshot, _, let frameHint) = decoded {
            #expect(sid == sessionID)
            #expect(tid == tabID)
            #expect(profileID == nil)
            #expect(snapshot == nil)
            #expect(frameHint == nil)
        } else {
            Issue.record("Expected createFloatingPane, got \(decoded)")
        }
    }

    @Test func roundTripCloseFloatingPaneMessage() throws {
        let sessionID = SessionID()
        let paneID = PaneID()
        let msg = ClientMessage.closeFloatingPane(sessionID, paneID)

        var encoder = BinaryEncoder()
        encoder.writeClientMessage(msg)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readClientMessage(type: .closeFloatingPane)
        if case .closeFloatingPane(let sid, let pid) = decoded {
            #expect(sid == sessionID)
            #expect(pid == paneID)
        } else {
            Issue.record("Expected closeFloatingPane, got \(decoded)")
        }
    }

    @Test func roundTripUpdateFloatingPaneFrameMessage() throws {
        let sessionID = SessionID()
        let paneID = PaneID()
        let msg = ClientMessage.updateFloatingPaneFrame(sessionID, paneID, x: 0.1, y: 0.2, width: 0.5, height: 0.6)

        var encoder = BinaryEncoder()
        encoder.writeClientMessage(msg)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readClientMessage(type: .updateFloatingPaneFrame)
        if case .updateFloatingPaneFrame(let sid, let pid, let x, let y, let w, let h) = decoded {
            #expect(sid == sessionID)
            #expect(pid == paneID)
            #expect(x == Float(0.1))
            #expect(y == Float(0.2))
            #expect(w == Float(0.5))
            #expect(h == Float(0.6))
        } else {
            Issue.record("Expected updateFloatingPaneFrame, got \(decoded)")
        }
    }

    @Test func roundTripBringFloatingPaneToFrontMessage() throws {
        let sessionID = SessionID()
        let paneID = PaneID()
        let msg = ClientMessage.bringFloatingPaneToFront(sessionID, paneID)

        var encoder = BinaryEncoder()
        encoder.writeClientMessage(msg)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readClientMessage(type: .bringFloatingPaneToFront)
        if case .bringFloatingPaneToFront(let sid, let pid) = decoded {
            #expect(sid == sessionID)
            #expect(pid == paneID)
        } else {
            Issue.record("Expected bringFloatingPaneToFront, got \(decoded)")
        }
    }

    @Test func roundTripToggleFloatingPanePinMessage() throws {
        let sessionID = SessionID()
        let paneID = PaneID()
        let msg = ClientMessage.toggleFloatingPanePin(sessionID, paneID)

        var encoder = BinaryEncoder()
        encoder.writeClientMessage(msg)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readClientMessage(type: .toggleFloatingPanePin)
        if case .toggleFloatingPanePin(let sid, let pid) = decoded {
            #expect(sid == sessionID)
            #expect(pid == paneID)
        } else {
            Issue.record("Expected toggleFloatingPanePin, got \(decoded)")
        }
    }

    // MARK: - Rename Session

    @Test func roundTripRenameSessionMessage() throws {
        let sessionID = SessionID()
        let msg = ClientMessage.renameSession(sessionID, name: "New Name")

        var encoder = BinaryEncoder()
        encoder.writeClientMessage(msg)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readClientMessage(type: .renameSession)
        if case .renameSession(let sid, let name) = decoded {
            #expect(sid == sessionID)
            #expect(name == "New Name")
        } else {
            Issue.record("Expected renameSession, got \(decoded)")
        }
        #expect(decoder.remaining == 0)
    }

    // MARK: - ScreenDiff

    @Test func roundTripScreenDiff() throws {
        let columns: UInt16 = 4
        let cells = (0..<8).map { i in
            Cell(
                codepoint: Unicode.Scalar(UInt32(0x41 + i))!,
                attributes: .default,
                width: .normal
            )
        }
        let diff = ScreenDiff(
            dirtyRows: [0, 3],
            cellData: cells,
            columns: columns,
            cursorCol: 2,
            cursorRow: 3,
            cursorVisible: true,
            cursorShape: .block,
            scrollbackCount: 500,
            viewportOffset: 10
        )

        var encoder = BinaryEncoder()
        encoder.writeScreenDiff(diff)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readScreenDiff()
        #expect(decoded.columns == 4)
        #expect(decoded.dirtyRows == [0, 3])
        #expect(decoded.cellData.count == 8)
        #expect(decoded.cursorCol == 2)
        #expect(decoded.cursorRow == 3)
        #expect(decoded.cursorVisible == true)
        #expect(decoded.cursorShape == .block)
        #expect(decoded.scrollbackCount == 500)
        #expect(decoded.viewportOffset == 10)
    }

    // MARK: - ScreenSnapshot

    @Test func roundTripScreenSnapshot() throws {
        let columns = 3
        let rows = 2
        let cells = (0..<(columns * rows)).map { i in
            Cell(
                codepoint: Unicode.Scalar(UInt32(0x41 + i))!,
                attributes: .default,
                width: .normal
            )
        }
        let snapshot = ScreenSnapshot(
            cells: cells,
            columns: columns,
            rows: rows,
            cursorCol: 1,
            cursorRow: 0,
            cursorVisible: false,
            cursorShape: .underline,
            selection: nil,
            scrollbackCount: 100,
            viewportOffset: 5,
            dirtyRegion: .full
        )

        var encoder = BinaryEncoder()
        encoder.writeScreenSnapshot(snapshot, mouseTrackingMode: 103)

        var decoder = BinaryDecoder(encoder.data)
        let (decoded, mouseMode) = try decoder.readScreenSnapshotWithMouse()
        #expect(decoded.columns == 3)
        #expect(decoded.rows == 2)
        #expect(decoded.cells.count == 6)
        #expect(decoded.cursorCol == 1)
        #expect(decoded.cursorRow == 0)
        #expect(decoded.cursorVisible == false)
        #expect(decoded.cursorShape == .underline)
        #expect(decoded.scrollbackCount == 100)
        #expect(decoded.viewportOffset == 5)
        #expect(mouseMode == 103)
    }

    // MARK: - SessionInfo

    @Test func roundTripSessionInfo() throws {
        let paneID = PaneID()
        let tabID = TabID()
        let sessionID = SessionID()
        let info = SessionInfo(
            id: sessionID,
            name: "dev",
            tabs: [
                TabInfo(id: tabID, title: "shell", layout: .leaf(paneID)),
            ],
            activeTabIndex: 0
        )

        var encoder = BinaryEncoder()
        encoder.writeSessionInfo(info)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readSessionInfo()
        #expect(decoded.id == sessionID)
        #expect(decoded.name == "dev")
        #expect(decoded.tabs.count == 1)
        #expect(decoded.tabs[0].id == tabID)
        #expect(decoded.tabs[0].title == "shell")
        #expect(decoded.tabs[0].layout == .leaf(paneID))
        #expect(decoded.activeTabIndex == 0)
    }

    @Test func roundTripSessionInfoWithPaneMetadata() throws {
        let paneIDKeepAlive = PaneID()
        let paneIDAutoClose = PaneID()
        let paneIDUnspecified = PaneID()
        let tabID = TabID()
        let sessionID = SessionID()
        let info = SessionInfo(
            id: sessionID,
            name: "meta",
            tabs: [TabInfo(id: tabID, title: "t", layout: .leaf(paneIDKeepAlive))],
            activeTabIndex: 0,
            paneMetadata: [
                paneIDKeepAlive: RemotePaneMetadata(
                    cwd: "/tmp/keep", profileID: "profA", closeOnExit: false
                ),
                paneIDAutoClose: RemotePaneMetadata(
                    cwd: nil, profileID: "profB", closeOnExit: true
                ),
                paneIDUnspecified: RemotePaneMetadata(
                    cwd: "/tmp/u", profileID: nil, closeOnExit: nil
                ),
            ]
        )

        var encoder = BinaryEncoder()
        encoder.writeSessionInfo(info)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readSessionInfo()
        #expect(decoded.paneMetadata[paneIDKeepAlive]?.closeOnExit == false)
        #expect(decoded.paneMetadata[paneIDKeepAlive]?.cwd == "/tmp/keep")
        #expect(decoded.paneMetadata[paneIDKeepAlive]?.profileID == "profA")
        #expect(decoded.paneMetadata[paneIDAutoClose]?.closeOnExit == true)
        #expect(decoded.paneMetadata[paneIDAutoClose]?.cwd == nil)
        #expect(decoded.paneMetadata[paneIDUnspecified]?.closeOnExit == nil)
        #expect(decoded.paneMetadata[paneIDUnspecified]?.cwd == "/tmp/u")
        #expect(decoder.remaining == 0)
    }

    @Test func paneMetadataRejectsInvalidCloseOnExitByte() throws {
        let paneID = PaneID()
        var encoder = BinaryEncoder()
        encoder.writePaneID(paneID)
        encoder.writeBool(false) // cwd absent
        encoder.writeBool(false) // profileID absent
        encoder.writeUInt8(99)   // invalid closeOnExit byte

        var decoder = BinaryDecoder(encoder.data)
        _ = try decoder.readPaneID()
        #expect(throws: BinaryDecoderError.self) {
            _ = try decoder.readPaneMetadata()
        }
    }

    // MARK: - Client Message: scrollViewport

    @Test func roundTripScrollViewportMessage() throws {
        let sessionID = SessionID()
        let paneID = PaneID()

        // Test scroll up (positive delta).
        let msgUp = ClientMessage.scrollViewport(sessionID, paneID, delta: 5)
        var encoderUp = BinaryEncoder()
        encoderUp.writeClientMessage(msgUp)

        var decoderUp = BinaryDecoder(encoderUp.data)
        let decodedUp = try decoderUp.readClientMessage(type: .scrollViewport)
        if case .scrollViewport(let sid, let pid, let delta) = decodedUp {
            #expect(sid == sessionID)
            #expect(pid == paneID)
            #expect(delta == 5)
        } else {
            Issue.record("Expected scrollViewport, got \(decodedUp)")
        }

        // Test scroll down (negative delta).
        let msgDown = ClientMessage.scrollViewport(sessionID, paneID, delta: -3)
        var encoderDown = BinaryEncoder()
        encoderDown.writeClientMessage(msgDown)

        var decoderDown = BinaryDecoder(encoderDown.data)
        let decodedDown = try decoderDown.readClientMessage(type: .scrollViewport)
        if case .scrollViewport(_, _, let delta) = decodedDown {
            #expect(delta == -3)
        } else {
            Issue.record("Expected scrollViewport")
        }

        // Test jump to bottom (Int32.max).
        let msgBottom = ClientMessage.scrollViewport(sessionID, paneID, delta: Int32.max)
        var encoderBottom = BinaryEncoder()
        encoderBottom.writeClientMessage(msgBottom)

        var decoderBottom = BinaryDecoder(encoderBottom.data)
        let decodedBottom = try decoderBottom.readClientMessage(type: .scrollViewport)
        if case .scrollViewport(_, _, let delta) = decodedBottom {
            #expect(delta == Int32.max)
        } else {
            Issue.record("Expected scrollViewport")
        }
    }

    // MARK: - Error Cases

    @Test func decoderInsufficientData() throws {
        var decoder = BinaryDecoder([0x01])
        #expect(throws: BinaryDecoderError.self) { try decoder.readUInt16() }
    }

    @Test func decoderInvalidCellWidth() throws {
        var encoder = BinaryEncoder()
        encoder.writeUInt8(1)           // scalar count
        encoder.writeUInt32(0x41)       // codepoint
        encoder.writeUInt32(0)          // fgColor
        encoder.writeUInt32(0)          // bgColor
        encoder.writeUInt16(0)          // flags
        encoder.writeUInt8(0xFF)        // invalid width

        var decoder = BinaryDecoder(encoder.data)
        #expect(throws: BinaryDecoderError.self) { try decoder.readCell() }
    }

    @Test func decoderInvalidCursorShape() throws {
        var encoder = BinaryEncoder()
        encoder.writeUInt16(0)          // col
        encoder.writeUInt16(0)          // row
        encoder.writeBool(true)         // visible
        encoder.writeUInt8(0xFF)        // invalid shape

        var decoder = BinaryDecoder(encoder.data)
        #expect(throws: BinaryDecoderError.self) { try decoder.readCursorState() }
    }

    // MARK: - StartupSnapshot

    @Test func startupSnapshotRoundTripEmpty() throws {
        let snapshot = StartupSnapshot()

        var encoder = BinaryEncoder()
        encoder.writeStartupSnapshot(snapshot)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readStartupSnapshot()
        #expect(decoded == snapshot)
        #expect(decoded.command == nil)
        #expect(decoded.args.isEmpty)
        #expect(decoded.cwd == nil)
        #expect(decoded.env.isEmpty)
        #expect(decoded.closeOnExit == nil)
        #expect(decoder.remaining == 0)
    }

    @Test func startupSnapshotRoundTripFull() throws {
        let snapshot = StartupSnapshot(
            command: "/bin/bash",
            args: ["-l", "-c", "echo 你好 && exec /bin/bash -l"],
            cwd: "/Users/tester/工作",
            env: [
                EnvVar(key: "TY_CI", value: "1"),
                EnvVar(key: "LANG", value: "zh_CN.UTF-8"),
                EnvVar(key: "EMOJI", value: "👨‍👩‍👧‍👦"),
            ],
            closeOnExit: false
        )

        var encoder = BinaryEncoder()
        encoder.writeStartupSnapshot(snapshot)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readStartupSnapshot()
        #expect(decoded == snapshot)
        #expect(decoded.env.map(\.key) == ["TY_CI", "LANG", "EMOJI"])
        #expect(decoded.env.map(\.value) == ["1", "zh_CN.UTF-8", "👨‍👩‍👧‍👦"])
        #expect(decoder.remaining == 0)
    }

    @Test func startupSnapshotCloseOnExitTrinary() throws {
        let states: [Bool?] = [nil, false, true]
        for state in states {
            let snapshot = StartupSnapshot(closeOnExit: state)
            var encoder = BinaryEncoder()
            encoder.writeStartupSnapshot(snapshot)

            var decoder = BinaryDecoder(encoder.data)
            let decoded = try decoder.readStartupSnapshot()
            #expect(decoded.closeOnExit == state)
            #expect(decoder.remaining == 0)
        }
    }

    @Test func startupSnapshotInvalidCloseOnExitByte() throws {
        var encoder = BinaryEncoder()
        encoder.writeUInt8(0)           // has_command = false
        encoder.writeUInt16(0)          // args count = 0
        encoder.writeUInt8(0)           // has_cwd = false
        encoder.writeUInt16(0)          // env count = 0
        encoder.writeUInt8(3)           // close_on_exit invalid

        var decoder = BinaryDecoder(encoder.data)
        #expect(throws: BinaryDecoderError.self) {
            try decoder.readStartupSnapshot()
        }
    }

    @Test func optionalStartupSnapshotNil() throws {
        var encoder = BinaryEncoder()
        encoder.writeOptionalStartupSnapshot(nil)
        #expect(encoder.data == [0])

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readOptionalStartupSnapshot()
        #expect(decoded == nil)
        #expect(decoder.remaining == 0)
    }

    // MARK: - FloatFrameHint

    @Test func roundTripFloatFrameHint() throws {
        let hint = FloatFrameHint(x: 0.1, y: 0.25, width: 0.5, height: 0.75)

        var encoder = BinaryEncoder()
        encoder.writeFloatFrameHint(hint)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readFloatFrameHint()
        #expect(decoded == hint)
        #expect(decoder.remaining == 0)
    }

    @Test func optionalFloatFrameHintNilAndPresent() throws {
        var encoder = BinaryEncoder()
        encoder.writeOptionalFloatFrameHint(nil)
        let hint = FloatFrameHint(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        encoder.writeOptionalFloatFrameHint(hint)

        var decoder = BinaryDecoder(encoder.data)
        #expect(try decoder.readOptionalFloatFrameHint() == nil)
        #expect(try decoder.readOptionalFloatFrameHint() == hint)
    }

    // MARK: - FloatFrameHint <- ResolvedStartupFields

    @Test func frameHintFromResolvedFieldsHappyPath() throws {
        let fields = ResolvedStartupFields(
            initialX: "0.25",
            initialY: "0.3",
            initialWidth: "0.5",
            initialHeight: "0.4"
        )
        var warnings: [String] = []
        let hint = FloatFrameHint(from: fields, warnings: &warnings)
        #expect(hint == FloatFrameHint(x: 0.25, y: 0.3, width: 0.5, height: 0.4))
        #expect(warnings.isEmpty)
    }

    @Test func frameHintFromResolvedFieldsReturnsNilWhenAllAbsent() throws {
        let fields = ResolvedStartupFields()
        var warnings: [String] = []
        let hint = FloatFrameHint(from: fields, warnings: &warnings)
        #expect(hint == nil)
        #expect(warnings.isEmpty)
    }

    @Test func frameHintFromResolvedFieldsNilOnPartial() throws {
        let fields = ResolvedStartupFields(
            initialX: "0.1",
            initialY: "0.1"
        )
        var warnings: [String] = []
        let hint = FloatFrameHint(from: fields, warnings: &warnings)
        #expect(hint == nil)
        #expect(warnings.isEmpty)
    }

    @Test func frameHintFromResolvedFieldsNilAndWarnsOnMalformed() throws {
        let fields = ResolvedStartupFields(
            initialX: "wide",
            initialY: "0.3",
            initialWidth: "0.5",
            initialHeight: "0.4"
        )
        var warnings: [String] = []
        let hint = FloatFrameHint(from: fields, warnings: &warnings)
        #expect(hint == nil)
        #expect(warnings.contains { $0.contains("initial-x") && $0.contains("wide") })
    }

    // MARK: - Create-class messages (profileID + snapshot + frameHint)

    private func sampleSnapshot() -> StartupSnapshot {
        StartupSnapshot(
            command: "/bin/bash",
            args: ["-l"],
            env: [EnvVar(key: "TY", value: "1")],
            closeOnExit: false
        )
    }

    @Test func roundTripCreateTabAllCombinations() throws {
        let sid = SessionID()
        let snap = sampleSnapshot()
        let cases: [(String?, StartupSnapshot?)] = [
            (nil, nil),
            ("ci", nil),
            (nil, snap),
            ("ci", snap),
        ]
        for (profileID, snapshot) in cases {
            let msg = ClientMessage.createTab(
                sid, profileID: profileID, snapshot: snapshot, variables: [:]
            )
            var encoder = BinaryEncoder()
            encoder.writeClientMessage(msg)
            var decoder = BinaryDecoder(encoder.data)
            let decoded = try decoder.readClientMessage(type: .createTab)
            guard case .createTab(let dSid, let dProfile, let dSnap, _) = decoded else {
                Issue.record("Expected .createTab"); continue
            }
            #expect(dSid == sid)
            #expect(dProfile == profileID)
            #expect(dSnap == snapshot)
        }
    }

    @Test func roundTripSplitPaneAllCombinations() throws {
        let sid = SessionID()
        let pid = PaneID()
        let snap = sampleSnapshot()
        let cases: [(String?, StartupSnapshot?)] = [
            (nil, nil),
            ("ci", nil),
            (nil, snap),
            ("ci", snap),
        ]
        for (profileID, snapshot) in cases {
            let msg = ClientMessage.splitPane(
                sid, pid, .vertical,
                profileID: profileID, snapshot: snapshot, variables: [:]
            )
            var encoder = BinaryEncoder()
            encoder.writeClientMessage(msg)
            var decoder = BinaryDecoder(encoder.data)
            let decoded = try decoder.readClientMessage(type: .splitPane)
            guard case .splitPane(let dSid, let dPid, let dDir, let dProfile, let dSnap, _) = decoded else {
                Issue.record("Expected .splitPane"); continue
            }
            #expect(dSid == sid)
            #expect(dPid == pid)
            #expect(dDir == .vertical)
            #expect(dProfile == profileID)
            #expect(dSnap == snapshot)
        }
    }

    @Test func roundTripCreateFloatingPaneAllCombinations() throws {
        let sid = SessionID()
        let tid = TabID()
        let snap = sampleSnapshot()
        let hint = FloatFrameHint(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        let cases: [(String?, StartupSnapshot?, FloatFrameHint?)] = [
            (nil, nil, nil),
            ("ci", nil, nil),
            (nil, snap, nil),
            (nil, nil, hint),
            ("ci", snap, hint),
        ]
        for (profileID, snapshot, frameHint) in cases {
            let msg = ClientMessage.createFloatingPane(
                sid, tid,
                profileID: profileID,
                snapshot: snapshot,
                variables: [:],
                frameHint: frameHint
            )
            var encoder = BinaryEncoder()
            encoder.writeClientMessage(msg)
            var decoder = BinaryDecoder(encoder.data)
            let decoded = try decoder.readClientMessage(type: .createFloatingPane)
            guard case .createFloatingPane(let dSid, let dTid, let dProfile, let dSnap, _, let dHint) = decoded else {
                Issue.record("Expected .createFloatingPane"); continue
            }
            #expect(dSid == sid)
            #expect(dTid == tid)
            #expect(dProfile == profileID)
            #expect(dSnap == snapshot)
            #expect(dHint == frameHint)
        }
    }

    // MARK: - Optional StartupSnapshot presence

    @Test func optionalStartupSnapshotPresent() throws {
        let snapshot = StartupSnapshot(
            command: "/usr/bin/env",
            args: ["sh", "-c", "true"],
            env: [EnvVar(key: "K", value: "V")],
            closeOnExit: true
        )

        var encoder = BinaryEncoder()
        encoder.writeOptionalStartupSnapshot(snapshot)
        #expect(encoder.data.first == 1)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readOptionalStartupSnapshot()
        #expect(decoded == snapshot)
        #expect(decoder.remaining == 0)
    }
}
