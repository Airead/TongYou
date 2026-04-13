import Testing
import Foundation
@testable import TYProtocol
@testable import TYTerminal

@Suite("BinaryEncoder/Decoder round-trip tests")
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
        #expect(encoder.data.count == 15)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readCell()
        #expect(decoded.codepoint == Unicode.Scalar("A"))
        #expect(decoded.attributes.flags == [.bold, .italic])
        #expect(decoded.attributes.fgColor.raw == 0x0200FF00)
        #expect(decoded.attributes.bgColor.raw == 0x010010FF)
        #expect(decoded.width == .normal)
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

    @Test func roundTripLayoutTreeSplit() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()
        let tree = LayoutTree.split(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(p1),
            second: .split(
                direction: .vertical,
                ratio: 0.3,
                first: .leaf(p2),
                second: .leaf(p3)
            )
        )

        var encoder = BinaryEncoder()
        encoder.writeLayoutTree(tree)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readLayoutTree()
        #expect(decoded == tree)
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
        let msg = ClientMessage.createFloatingPane(sessionID, tabID)

        var encoder = BinaryEncoder()
        encoder.writeClientMessage(msg)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readClientMessage(type: .createFloatingPane)
        if case .createFloatingPane(let sid, let tid) = decoded {
            #expect(sid == sessionID)
            #expect(tid == tabID)
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
        encoder.writeScreenSnapshot(snapshot)

        var decoder = BinaryDecoder(encoder.data)
        let decoded = try decoder.readScreenSnapshot()
        #expect(decoded.columns == 3)
        #expect(decoded.rows == 2)
        #expect(decoded.cells.count == 6)
        #expect(decoded.cursorCol == 1)
        #expect(decoded.cursorRow == 0)
        #expect(decoded.cursorVisible == false)
        #expect(decoded.cursorShape == .underline)
        #expect(decoded.scrollbackCount == 100)
        #expect(decoded.viewportOffset == 5)
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
}
