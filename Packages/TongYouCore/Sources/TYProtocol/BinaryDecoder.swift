import Foundation
import TYTerminal

/// Error thrown when binary decoding fails.
public enum BinaryDecoderError: Error, Sendable {
    case insufficientData(expected: Int, available: Int)
    case invalidUTF8
    case invalidEnumValue(type: String, rawValue: UInt64)
}

/// Lightweight binary decoder that reads from a byte buffer.
///
/// All multi-byte integers are read in little-endian format.
public struct BinaryDecoder: Sendable {
    private let data: [UInt8]
    public private(set) var offset: Int = 0

    /// Number of bytes remaining.
    public var remaining: Int { data.count - offset }

    public init(_ data: [UInt8]) {
        self.data = data
    }

    public init(_ data: Data) {
        self.data = Array(data)
    }

    // MARK: - Primitives

    private mutating func readRawBytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard offset + count <= data.count else {
            throw BinaryDecoderError.insufficientData(expected: count, available: remaining)
        }
        let slice = data[offset..<(offset + count)]
        offset += count
        return slice
    }

    public mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw BinaryDecoderError.insufficientData(expected: 1, available: 0)
        }
        let value = data[offset]
        offset += 1
        return value
    }

    public mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    public mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw BinaryDecoderError.insufficientData(expected: 2, available: remaining)
        }
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset + 1])
        offset += 2
        return lo | (hi << 8)
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw BinaryDecoderError.insufficientData(expected: 4, available: remaining)
        }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        offset += 4
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    public mutating func readInt32() throws -> Int32 {
        let bits = try readUInt32()
        return Int32(bitPattern: bits)
    }

    public mutating func readFloat() throws -> Float {
        let bits = try readUInt32()
        return Float(bitPattern: bits)
    }

    // MARK: - Compound Types

    public mutating func readUUID() throws -> UUID {
        guard offset + 16 <= data.count else {
            throw BinaryDecoderError.insufficientData(expected: 16, available: remaining)
        }
        let o = offset
        offset += 16
        return UUID(uuid: (
            data[o], data[o+1], data[o+2], data[o+3],
            data[o+4], data[o+5], data[o+6], data[o+7],
            data[o+8], data[o+9], data[o+10], data[o+11],
            data[o+12], data[o+13], data[o+14], data[o+15]
        ))
    }

    public mutating func readSessionID() throws -> SessionID {
        SessionID(try readUUID())
    }

    public mutating func readTabID() throws -> TabID {
        TabID(try readUUID())
    }

    public mutating func readPaneID() throws -> PaneID {
        PaneID(try readUUID())
    }

    /// Read a length-prefixed UTF-8 string (UInt32 length + bytes).
    public mutating func readString() throws -> String {
        let length = Int(try readUInt32())
        let slice = try readRawBytes(length)
        guard let string = String(bytes: slice, encoding: .utf8) else {
            throw BinaryDecoderError.invalidUTF8
        }
        return string
    }

    /// Read a length-prefixed byte array (UInt32 length + bytes).
    public mutating func readBytes() throws -> [UInt8] {
        let length = Int(try readUInt32())
        return Array(try readRawBytes(length))
    }

    // MARK: - Terminal Types

    /// Read a single Cell (15 bytes).
    public mutating func readCell() throws -> Cell {
        let codepoint = try readUInt32()
        let fgRaw = try readUInt32()
        let bgRaw = try readUInt32()
        let flagsRaw = try readUInt16()
        let widthRaw = try readUInt8()

        guard let scalar = Unicode.Scalar(codepoint) else {
            throw BinaryDecoderError.invalidEnumValue(type: "Unicode.Scalar", rawValue: UInt64(codepoint))
        }
        guard let width = CellWidth(rawValue: widthRaw) else {
            throw BinaryDecoderError.invalidEnumValue(type: "CellWidth", rawValue: UInt64(widthRaw))
        }

        let attributes = CellAttributes(
            flags: StyleFlags(rawValue: flagsRaw),
            fgColor: PackedColor(raw: fgRaw),
            bgColor: PackedColor(raw: bgRaw)
        )
        return Cell(codepoint: scalar, attributes: attributes, width: width)
    }

    /// Read a count-prefixed array of cells.
    public mutating func readCells() throws -> [Cell] {
        let count = Int(try readUInt32())
        var cells: [Cell] = []
        cells.reserveCapacity(count)
        for _ in 0..<count {
            cells.append(try readCell())
        }
        return cells
    }

    /// Read cursor state (6 bytes: col 2B + row 2B + visible 1B + shape 1B).
    public mutating func readCursorState() throws
        -> (col: UInt16, row: UInt16, visible: Bool, shape: CursorShape)
    {
        let col = try readUInt16()
        let row = try readUInt16()
        let visible = try readBool()
        let shapeRaw = try readUInt8()
        guard let shape = CursorShape(rawValue: shapeRaw) else {
            throw BinaryDecoderError.invalidEnumValue(type: "CursorShape", rawValue: UInt64(shapeRaw))
        }
        return (col, row, visible, shape)
    }

    public mutating func readSplitDirection() throws -> SplitDirection {
        let raw = try readUInt8()
        switch raw {
        case 0: return .horizontal
        case 1: return .vertical
        default:
            throw BinaryDecoderError.invalidEnumValue(type: "SplitDirection", rawValue: UInt64(raw))
        }
    }

    public mutating func readLayoutTree() throws -> LayoutTree {
        let tag = try readUInt8()
        switch tag {
        case 0:  // leaf
            let paneID = try readPaneID()
            return .leaf(paneID)
        case 1:  // split
            let direction = try readSplitDirection()
            let ratio = try readFloat()
            let first = try readLayoutTree()
            let second = try readLayoutTree()
            return .split(direction: direction, ratio: ratio, first: first, second: second)
        default:
            throw BinaryDecoderError.invalidEnumValue(type: "LayoutTree", rawValue: UInt64(tag))
        }
    }

    // MARK: - Protocol Messages

    /// Decode a `ScreenDiff` from the buffer.
    public mutating func readScreenDiff() throws -> ScreenDiff {
        let columns = try readUInt16()
        let dirtyCount = Int(try readUInt16())
        var dirtyRows: [UInt16] = []
        dirtyRows.reserveCapacity(dirtyCount)
        for _ in 0..<dirtyCount {
            dirtyRows.append(try readUInt16())
        }
        let cellCount = Int(columns) * dirtyCount
        var cellData: [Cell] = []
        cellData.reserveCapacity(cellCount)
        for _ in 0..<cellCount {
            cellData.append(try readCell())
        }
        let cursor = try readCursorState()
        let scrollbackCount = Int(try readUInt32())
        let viewportOffset = Int(try readUInt32())
        return ScreenDiff(
            dirtyRows: dirtyRows,
            cellData: cellData,
            columns: columns,
            cursorCol: cursor.col,
            cursorRow: cursor.row,
            cursorVisible: cursor.visible,
            cursorShape: cursor.shape,
            scrollbackCount: scrollbackCount,
            viewportOffset: viewportOffset
        )
    }

    /// Decode a `ScreenSnapshot` from the buffer.
    public mutating func readScreenSnapshot() throws -> ScreenSnapshot {
        let columns = Int(try readUInt16())
        let rows = Int(try readUInt16())
        let cellCount = columns * rows
        var cells: [Cell] = []
        cells.reserveCapacity(cellCount)
        for _ in 0..<cellCount {
            cells.append(try readCell())
        }
        let cursor = try readCursorState()
        let scrollbackCount = Int(try readUInt32())
        let viewportOffset = Int(try readUInt32())
        return ScreenSnapshot(
            cells: cells,
            columns: columns,
            rows: rows,
            cursorCol: Int(cursor.col),
            cursorRow: Int(cursor.row),
            cursorVisible: cursor.visible,
            cursorShape: cursor.shape,
            selection: nil,
            scrollbackCount: scrollbackCount,
            viewportOffset: viewportOffset,
            dirtyRegion: .full
        )
    }

    /// Decode a `SessionInfo` from the buffer.
    public mutating func readSessionInfo() throws -> SessionInfo {
        let id = try readSessionID()
        let name = try readString()
        let tabCount = Int(try readUInt16())
        var tabs: [TabInfo] = []
        tabs.reserveCapacity(tabCount)
        for _ in 0..<tabCount {
            tabs.append(try readTabInfo())
        }
        let activeTabIndex = Int(try readUInt16())
        return SessionInfo(id: id, name: name, tabs: tabs, activeTabIndex: activeTabIndex)
    }

    /// Decode a `TabInfo` from the buffer.
    public mutating func readTabInfo() throws -> TabInfo {
        let id = try readTabID()
        let title = try readString()
        let layout = try readLayoutTree()
        return TabInfo(id: id, title: title, layout: layout)
    }

    /// Decode a `ServerMessage` payload given its type code.
    public mutating func readServerMessage(type: ServerMessageType) throws -> ServerMessage {
        switch type {
        case .sessionList:
            let count = Int(try readUInt16())
            var sessions: [SessionInfo] = []
            sessions.reserveCapacity(count)
            for _ in 0..<count {
                sessions.append(try readSessionInfo())
            }
            return .sessionList(sessions)

        case .sessionCreated:
            return .sessionCreated(try readSessionInfo())

        case .sessionClosed:
            return .sessionClosed(try readSessionID())

        case .screenFull:
            let sessionID = try readSessionID()
            let paneID = try readPaneID()
            let snapshot = try readScreenSnapshot()
            return .screenFull(sessionID, paneID, snapshot)

        case .screenDiff:
            let sessionID = try readSessionID()
            let paneID = try readPaneID()
            let diff = try readScreenDiff()
            return .screenDiff(sessionID, paneID, diff)

        case .titleChanged:
            let sessionID = try readSessionID()
            let paneID = try readPaneID()
            let title = try readString()
            return .titleChanged(sessionID, paneID, title)

        case .bell:
            let sessionID = try readSessionID()
            let paneID = try readPaneID()
            return .bell(sessionID, paneID)

        case .paneExited:
            let sessionID = try readSessionID()
            let paneID = try readPaneID()
            let exitCode = try readInt32()
            return .paneExited(sessionID, paneID, exitCode: exitCode)

        case .layoutUpdate:
            let sessionID = try readSessionID()
            let tree = try readLayoutTree()
            return .layoutUpdate(sessionID, tree)

        case .clipboardSet:
            return .clipboardSet(try readString())
        }
    }

    /// Decode a `ClientMessage` payload given its type code.
    public mutating func readClientMessage(type: ClientMessageType) throws -> ClientMessage {
        switch type {
        case .listSessions:
            return .listSessions

        case .createSession:
            let hasName = try readBool()
            let name = hasName ? try readString() : nil
            return .createSession(name: name)

        case .attachSession:
            return .attachSession(try readSessionID())

        case .detachSession:
            return .detachSession(try readSessionID())

        case .closeSession:
            return .closeSession(try readSessionID())

        case .input:
            let sessionID = try readSessionID()
            let paneID = try readPaneID()
            let bytes = try readBytes()
            return .input(sessionID, paneID, bytes)

        case .resize:
            let sessionID = try readSessionID()
            let paneID = try readPaneID()
            let cols = try readUInt16()
            let rows = try readUInt16()
            return .resize(sessionID, paneID, cols: cols, rows: rows)

        case .scrollViewport:
            let sessionID = try readSessionID()
            let paneID = try readPaneID()
            let delta = try readInt32()
            return .scrollViewport(sessionID, paneID, delta: delta)

        case .createTab:
            return .createTab(try readSessionID())

        case .closeTab:
            let sessionID = try readSessionID()
            let tabID = try readTabID()
            return .closeTab(sessionID, tabID)

        case .splitPane:
            let sessionID = try readSessionID()
            let paneID = try readPaneID()
            let direction = try readSplitDirection()
            return .splitPane(sessionID, paneID, direction)

        case .closePane:
            let sessionID = try readSessionID()
            let paneID = try readPaneID()
            return .closePane(sessionID, paneID)

        case .focusPane:
            let sessionID = try readSessionID()
            let paneID = try readPaneID()
            return .focusPane(sessionID, paneID)
        }
    }
}
