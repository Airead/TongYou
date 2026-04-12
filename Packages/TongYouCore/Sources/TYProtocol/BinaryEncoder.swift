import Foundation
import TYTerminal

/// Lightweight binary encoder that appends to an internal byte buffer.
///
/// All multi-byte integers are written in little-endian format.
public struct BinaryEncoder: Sendable {
    public private(set) var data: [UInt8] = []

    public init() {}

    public init(capacity: Int) {
        data.reserveCapacity(capacity)
    }

    // MARK: - Primitives

    public mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    public mutating func writeBool(_ value: Bool) {
        data.append(value ? 1 : 0)
    }

    public mutating func writeUInt16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func writeUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func writeInt32(_ value: Int32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func writeFloat(_ value: Float) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: - Compound Types

    public mutating func writeUUID(_ uuid: UUID) {
        let u = uuid.uuid
        data.append(contentsOf: [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ])
    }

    public mutating func writeSessionID(_ id: SessionID) {
        writeUUID(id.uuid)
    }

    public mutating func writeTabID(_ id: TabID) {
        writeUUID(id.uuid)
    }

    public mutating func writePaneID(_ id: PaneID) {
        writeUUID(id.uuid)
    }

    /// Write a length-prefixed UTF-8 string (UInt32 length + bytes).
    public mutating func writeString(_ string: String) {
        let utf8 = string.utf8
        writeUInt32(UInt32(utf8.count))
        data.append(contentsOf: utf8)
    }

    /// Write a length-prefixed byte array (UInt32 length + bytes).
    public mutating func writeBytes(_ bytes: [UInt8]) {
        writeUInt32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    // MARK: - Terminal Types

    /// Write a single Cell (15 bytes: codepoint 4B + fgColor 4B + bgColor 4B + flags 2B + width 1B).
    public mutating func writeCell(_ cell: Cell) {
        writeUInt32(cell.codepoint.value)
        writeUInt32(cell.attributes.fgColor.raw)
        writeUInt32(cell.attributes.bgColor.raw)
        writeUInt16(cell.attributes.flags.rawValue)
        writeUInt8(cell.width.rawValue)
    }

    /// Write an array of cells with a UInt32 count prefix.
    public mutating func writeCells(_ cells: [Cell]) {
        writeUInt32(UInt32(cells.count))
        for cell in cells {
            writeCell(cell)
        }
    }

    /// Write cursor state (6 bytes: col 2B + row 2B + visible 1B + shape 1B).
    public mutating func writeCursorState(
        col: UInt16, row: UInt16, visible: Bool, shape: CursorShape
    ) {
        writeUInt16(col)
        writeUInt16(row)
        writeBool(visible)
        writeUInt8(shape.rawValue)
    }

    public mutating func writeSplitDirection(_ direction: SplitDirection) {
        switch direction {
        case .horizontal: writeUInt8(0)
        case .vertical:   writeUInt8(1)
        }
    }

    public mutating func writeLayoutTree(_ tree: LayoutTree) {
        switch tree {
        case .leaf(let paneID):
            writeUInt8(0)  // tag: leaf
            writePaneID(paneID)
        case .split(let direction, let ratio, let first, let second):
            writeUInt8(1)  // tag: split
            writeSplitDirection(direction)
            writeFloat(ratio)
            writeLayoutTree(first)
            writeLayoutTree(second)
        }
    }

    // MARK: - Protocol Messages

    /// Encode a `ScreenDiff` into the buffer.
    public mutating func writeScreenDiff(_ diff: ScreenDiff) {
        // Pre-allocate: header (4B) + dirty row indices (2B each) + cells (15B each) + cursor (6B).
        let cellBytes = diff.cellData.count * 15
        let headerBytes = 4 + diff.dirtyRows.count * 2 + 6
        data.reserveCapacity(data.count + headerBytes + cellBytes)
        writeUInt16(diff.columns)
        writeUInt16(UInt16(diff.dirtyRows.count))
        for row in diff.dirtyRows {
            writeUInt16(row)
        }
        // Cell data is not count-prefixed here; count = columns × dirtyRows.count.
        for cell in diff.cellData {
            writeCell(cell)
        }
        writeCursorState(
            col: diff.cursorCol, row: diff.cursorRow,
            visible: diff.cursorVisible, shape: diff.cursorShape
        )
    }

    /// Encode a `ScreenSnapshot` into the buffer.
    public mutating func writeScreenSnapshot(_ snapshot: ScreenSnapshot) {
        // Pre-allocate: header (4B) + cells (15B each) + cursor (6B) + scrollback/viewport (8B).
        let cellBytes = snapshot.cells.count * 15
        data.reserveCapacity(data.count + 4 + cellBytes + 6 + 8)
        writeUInt16(UInt16(snapshot.columns))
        writeUInt16(UInt16(snapshot.rows))
        for cell in snapshot.cells {
            writeCell(cell)
        }
        writeCursorState(
            col: UInt16(snapshot.cursorCol), row: UInt16(snapshot.cursorRow),
            visible: snapshot.cursorVisible, shape: snapshot.cursorShape
        )
        writeUInt32(UInt32(snapshot.scrollbackCount))
        writeUInt32(UInt32(snapshot.viewportOffset))
    }

    /// Encode a `SessionInfo` into the buffer.
    public mutating func writeSessionInfo(_ info: SessionInfo) {
        writeSessionID(info.id)
        writeString(info.name)
        writeUInt16(UInt16(info.tabs.count))
        for tab in info.tabs {
            writeTabInfo(tab)
        }
        writeUInt16(UInt16(info.activeTabIndex))
    }

    /// Encode a `TabInfo` into the buffer.
    public mutating func writeTabInfo(_ tab: TabInfo) {
        writeTabID(tab.id)
        writeString(tab.title)
        writeLayoutTree(tab.layout)
    }

    /// Encode a `ServerMessage` payload (without frame header).
    public mutating func writeServerMessage(_ message: ServerMessage) {
        switch message {
        case .sessionList(let sessions):
            writeUInt16(UInt16(sessions.count))
            for session in sessions { writeSessionInfo(session) }

        case .sessionCreated(let info):
            writeSessionInfo(info)

        case .sessionClosed(let id):
            writeSessionID(id)

        case .screenFull(let sessionID, let paneID, let snapshot):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeScreenSnapshot(snapshot)

        case .screenDiff(let sessionID, let paneID, let diff):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeScreenDiff(diff)

        case .titleChanged(let sessionID, let paneID, let title):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeString(title)

        case .bell(let sessionID, let paneID):
            writeSessionID(sessionID)
            writePaneID(paneID)

        case .paneExited(let sessionID, let paneID, let exitCode):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeInt32(exitCode)

        case .layoutUpdate(let sessionID, let tree):
            writeSessionID(sessionID)
            writeLayoutTree(tree)

        case .clipboardSet(let text):
            writeString(text)
        }
    }

    /// Encode a `ClientMessage` payload (without frame header).
    public mutating func writeClientMessage(_ message: ClientMessage) {
        switch message {
        case .listSessions:
            break  // No payload.

        case .createSession(let name):
            writeBool(name != nil)
            if let name { writeString(name) }

        case .attachSession(let id):
            writeSessionID(id)

        case .detachSession(let id):
            writeSessionID(id)

        case .closeSession(let id):
            writeSessionID(id)

        case .input(let sessionID, let paneID, let bytes):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeBytes(bytes)

        case .resize(let sessionID, let paneID, let cols, let rows):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeUInt16(cols)
            writeUInt16(rows)

        case .createTab(let sessionID):
            writeSessionID(sessionID)

        case .closeTab(let sessionID, let tabID):
            writeSessionID(sessionID)
            writeTabID(tabID)

        case .splitPane(let sessionID, let paneID, let direction):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeSplitDirection(direction)

        case .closePane(let sessionID, let paneID):
            writeSessionID(sessionID)
            writePaneID(paneID)

        case .focusPane(let sessionID, let paneID):
            writeSessionID(sessionID)
            writePaneID(paneID)
        }
    }
}
