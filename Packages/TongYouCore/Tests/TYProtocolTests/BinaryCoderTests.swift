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
            cursorShape: .block
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
