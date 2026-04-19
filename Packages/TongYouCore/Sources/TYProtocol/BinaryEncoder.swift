import Foundation
import TYConfig
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

    /// Write a count-prefixed string array (UInt16 count + length-prefixed strings).
    public mutating func writeStringArray(_ strings: [String]) {
        writeUInt16(UInt16(strings.count))
        for s in strings { writeString(s) }
    }

    /// Write a count-prefixed `[String: String]` map (UInt16 count + key/value
    /// length-prefixed strings). Keys are emitted in sorted order so the wire
    /// bytes are deterministic — useful for golden-file snapshot tests.
    public mutating func writeStringMap(_ map: [String: String]) {
        writeUInt16(UInt16(map.count))
        for key in map.keys.sorted() {
            writeString(key)
            writeString(map[key] ?? "")
        }
    }

    /// Write a length-prefixed byte array (UInt32 length + bytes).
    public mutating func writeBytes(_ bytes: [UInt8]) {
        writeUInt32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    // MARK: - Terminal Types

    /// Write a single Cell (variable size: scalarCount 1B + scalars 4B each + fgColor 4B + bgColor 4B + flags 2B + width 1B).
    public mutating func writeCell(_ cell: Cell) {
        let scalars = cell.content.scalars
        writeUInt8(UInt8(clamping: scalars.count))
        for scalar in scalars {
            writeUInt32(scalar.value)
        }
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

    public mutating func writeSelectionMode(_ mode: SelectionMode) {
        writeUInt8(mode.rawValue)
    }

    public mutating func writeSelectionPoint(_ point: SelectionPoint) {
        writeInt32(Int32(point.line))
        writeUInt16(UInt16(point.col))
    }

    public mutating func writeSelection(_ sel: Selection) {
        writeSelectionMode(sel.mode)
        writeSelectionPoint(sel.start)
        writeSelectionPoint(sel.end)
    }

    public mutating func writeSplitDirection(_ direction: SplitDirection) {
        switch direction {
        case .horizontal: writeUInt8(0)
        case .vertical:   writeUInt8(1)
        }
    }

    public mutating func writeFocusDirection(_ direction: FocusDirection) {
        switch direction {
        case .left:  writeUInt8(0)
        case .right: writeUInt8(1)
        case .up:    writeUInt8(2)
        case .down:  writeUInt8(3)
        }
    }

    public mutating func writeLayoutStrategyKind(_ kind: LayoutStrategyKind) {
        switch kind {
        case .horizontal:  writeUInt8(0)
        case .vertical:    writeUInt8(1)
        case .grid:        writeUInt8(2)
        case .masterStack: writeUInt8(3)
        case .fibonacci:   writeUInt8(4)
        }
    }

    public mutating func writeFloatingPaneInfo(_ info: FloatingPaneInfo) {
        writePaneID(info.paneID)
        writeFloat(info.frameX)
        writeFloat(info.frameY)
        writeFloat(info.frameWidth)
        writeFloat(info.frameHeight)
        writeInt32(info.zIndex)
        writeBool(info.isPinned)
        writeBool(info.isVisible)
        writeString(info.title)
    }

    public mutating func writeLayoutTree(_ tree: LayoutTree) {
        switch tree {
        case .leaf(let paneID):
            writeUInt8(0)  // tag: leaf
            writePaneID(paneID)
        case .container(let strategy, let children, let weights):
            writeUInt8(1)  // tag: container
            writeLayoutStrategyKind(strategy)
            writeUInt32(UInt32(children.count))
            for child in children {
                writeLayoutTree(child)
            }
            for weight in weights {
                writeFloat(weight)
            }
        }
    }

    /// Write a `MouseEncoder.Event` (8 bytes: action 1B + hasButton 1B + button 1B + col 2B + row 2B + modifiers 1B).
    public mutating func writeMouseEvent(_ event: MouseEncoder.Event) {
        let actionByte: UInt8 = switch event.action {
        case .press: 0
        case .release: 1
        case .motion: 2
        }
        writeUInt8(actionByte)
        writeBool(event.button != nil)
        writeUInt8(event.button?.rawValue ?? 0)
        writeUInt16(UInt16(clamping: event.col))
        writeUInt16(UInt16(clamping: event.row))
        var modBits: UInt8 = 0
        if event.modifiers.shift   { modBits |= 1 }
        if event.modifiers.option  { modBits |= 2 }
        if event.modifiers.control { modBits |= 4 }
        writeUInt8(modBits)
    }

    // MARK: - Startup Snapshot

    /// Write a single environment variable as two length-prefixed strings.
    public mutating func writeEnvVar(_ env: EnvVar) {
        writeString(env.key)
        writeString(env.value)
    }

    /// Encode a `StartupSnapshot` into the buffer. Layout:
    ///   has_command u8 + [command string]
    ///   args (u16 count + strings)
    ///   has_cwd u8 + [cwd string]
    ///   env (u16 count + [string key; string value])
    ///   close_on_exit u8 (0 = nil, 1 = false, 2 = true)
    public mutating func writeStartupSnapshot(_ snapshot: StartupSnapshot) {
        if let command = snapshot.command {
            writeUInt8(1)
            writeString(command)
        } else {
            writeUInt8(0)
        }

        writeStringArray(snapshot.args)

        if let cwd = snapshot.cwd {
            writeUInt8(1)
            writeString(cwd)
        } else {
            writeUInt8(0)
        }

        writeUInt16(UInt16(clamping: snapshot.env.count))
        for env in snapshot.env {
            writeEnvVar(env)
        }

        switch snapshot.closeOnExit {
        case .none: writeUInt8(0)
        case .some(false): writeUInt8(1)
        case .some(true): writeUInt8(2)
        }
    }

    /// Encode an optional `StartupSnapshot` as a presence byte + snapshot body.
    public mutating func writeOptionalStartupSnapshot(_ snapshot: StartupSnapshot?) {
        if let snapshot {
            writeUInt8(1)
            writeStartupSnapshot(snapshot)
        } else {
            writeUInt8(0)
        }
    }

    /// Encode an optional length-prefixed UTF-8 string (1-byte presence + body).
    public mutating func writeOptionalString(_ value: String?) {
        if let value {
            writeUInt8(1)
            writeString(value)
        } else {
            writeUInt8(0)
        }
    }

    /// Encode a `FloatFrameHint` (4 × Float32 normalized coordinates).
    public mutating func writeFloatFrameHint(_ hint: FloatFrameHint) {
        writeFloat(hint.x)
        writeFloat(hint.y)
        writeFloat(hint.width)
        writeFloat(hint.height)
    }

    /// Encode an optional `FloatFrameHint` (1-byte presence + body).
    public mutating func writeOptionalFloatFrameHint(_ hint: FloatFrameHint?) {
        if let hint {
            writeUInt8(1)
            writeFloatFrameHint(hint)
        } else {
            writeUInt8(0)
        }
    }

    // MARK: - Protocol Messages

    /// Encode a `ScreenDiff` into the buffer.
    public mutating func writeScreenDiff(_ diff: ScreenDiff) {
        let cellBytes = diff.cellData.count * 16
        let headerBytes = 4 + diff.dirtyRows.count * 2 + 6 + 8 + 1
        data.reserveCapacity(data.count + headerBytes + cellBytes)
        writeUInt16(diff.columns)
        writeUInt16(UInt16(diff.dirtyRows.count))
        for row in diff.dirtyRows {
            writeUInt16(row)
        }
        for cell in diff.cellData {
            writeCell(cell)
        }
        writeCursorState(
            col: diff.cursorCol, row: diff.cursorRow,
            visible: diff.cursorVisible, shape: diff.cursorShape
        )
        writeUInt32(UInt32(diff.scrollbackCount))
        writeUInt32(UInt32(diff.viewportOffset))
        writeUInt8(diff.mouseTrackingMode)
        writeUInt16(UInt16(bitPattern: diff.scrollDelta))
    }

    /// Encode a `ScreenSnapshot` into the buffer.
    /// - Parameter mouseTrackingMode: rawValue of the terminal's current mouse tracking mode.
    public mutating func writeScreenSnapshot(_ snapshot: ScreenSnapshot, mouseTrackingMode: UInt8 = 0) {
        assert(!snapshot.isPartial, "Cannot encode a partial snapshot as screenFull")
        let cellBytes = snapshot.cells.count * 16
        data.reserveCapacity(data.count + 4 + cellBytes + 6 + 8 + 1)
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
        writeUInt8(mouseTrackingMode)
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
        // Pane metadata map
        writeUInt16(UInt16(info.paneMetadata.count))
        for (paneID, meta) in info.paneMetadata {
            writePaneID(paneID)
            writePaneMetadata(meta)
        }
    }

    /// Encode a `PaneMetadata` into the buffer.
    ///
    /// `closeOnExit` is encoded as a trinary byte matching
    /// `writeStartupSnapshot` (0 = nil, 1 = false, 2 = true) so older
    /// clients that omit the field are naturally decoded as nil.
    public mutating func writePaneMetadata(_ meta: RemotePaneMetadata) {
        writeBool(meta.cwd != nil)
        if let cwd = meta.cwd {
            writeString(cwd)
        }
        writeBool(meta.profileID != nil)
        if let profileID = meta.profileID {
            writeString(profileID)
        }
        switch meta.closeOnExit {
        case .none: writeUInt8(0)
        case .some(false): writeUInt8(1)
        case .some(true): writeUInt8(2)
        }
        writeStringMap(meta.variables)
    }

    /// Encode a `TabInfo` into the buffer.
    public mutating func writeTabInfo(_ tab: TabInfo) {
        writeTabID(tab.id)
        writeString(tab.title)
        writeLayoutTree(tab.layout)
        writeUInt16(UInt16(tab.floatingPanes.count))
        for fp in tab.floatingPanes {
            writeFloatingPaneInfo(fp)
        }
        writeBool(tab.focusedPaneID != nil)
        if let fpid = tab.focusedPaneID {
            writePaneID(fpid)
        }
    }

    /// Encode a `ServerMessage` payload (without frame header).
    public mutating func writeServerMessage(_ message: ServerMessage) {
        switch message {
        case .handshakeResult(let success):
            writeBool(success)

        case .sessionList(let sessions):
            writeUInt16(UInt16(sessions.count))
            for session in sessions { writeSessionInfo(session) }

        case .sessionCreated(let info):
            writeSessionInfo(info)

        case .sessionClosed(let id):
            writeSessionID(id)

        case .screenFull(let sessionID, let paneID, let snapshot, let mouseTrackingMode):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeScreenSnapshot(snapshot, mouseTrackingMode: mouseTrackingMode)

        case .screenDiff(let sessionID, let paneID, let diff):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeScreenDiff(diff)

        case .titleChanged(let sessionID, let paneID, let title):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeString(title)

        case .cwdChanged(let sessionID, let paneID, let cwd):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeString(cwd)

        case .bell(let sessionID, let paneID):
            writeSessionID(sessionID)
            writePaneID(paneID)

        case .paneExited(let sessionID, let paneID, let exitCode):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeInt32(exitCode)

        case .layoutUpdate(let info):
            writeSessionInfo(info)

        case .clipboardSet(let text):
            writeString(text)
        }
    }

    /// Encode a `ClientMessage` payload (without frame header).
    public mutating func writeClientMessage(_ message: ClientMessage) {
        switch message {
        case .handshake(let token):
            writeString(token)

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

        case .renameSession(let id, let name):
            writeSessionID(id)
            writeString(name)

        case .input(let sessionID, let paneID, let bytes):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeBytes(bytes)

        case .resize(let sessionID, let paneID, let cols, let rows):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeUInt16(cols)
            writeUInt16(rows)

        case .scrollViewport(let sessionID, let paneID, let delta):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeInt32(delta)

        case .extractSelection(let sessionID, let paneID, let selection):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeSelection(selection)

        case .mouseEvent(let sessionID, let paneID, let event):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeMouseEvent(event)

        case .createTab(let sessionID, let profileID, let snapshot, let variables):
            writeSessionID(sessionID)
            writeOptionalString(profileID)
            writeOptionalStartupSnapshot(snapshot)
            writeStringMap(variables)

        case .closeTab(let sessionID, let tabID):
            writeSessionID(sessionID)
            writeTabID(tabID)

        case .splitPane(let sessionID, let paneID, let direction, let profileID, let snapshot, let variables):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeSplitDirection(direction)
            writeOptionalString(profileID)
            writeOptionalStartupSnapshot(snapshot)
            writeStringMap(variables)

        case .closePane(let sessionID, let paneID):
            writeSessionID(sessionID)
            writePaneID(paneID)

        case .focusPane(let sessionID, let paneID):
            writeSessionID(sessionID)
            writePaneID(paneID)

        case .selectTab(let sessionID, let tabIndex):
            writeSessionID(sessionID)
            writeUInt16(tabIndex)

        case .setSplitRatio(let sessionID, let paneID, let ratio):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeFloat(ratio)

        case .createFloatingPane(let sessionID, let tabID, let profileID, let snapshot, let variables, let frameHint):
            writeSessionID(sessionID)
            writeTabID(tabID)
            writeOptionalString(profileID)
            writeOptionalStartupSnapshot(snapshot)
            writeStringMap(variables)
            writeOptionalFloatFrameHint(frameHint)

        case .closeFloatingPane(let sessionID, let paneID):
            writeSessionID(sessionID)
            writePaneID(paneID)

        case .updateFloatingPaneFrame(let sessionID, let paneID, let x, let y, let width, let height):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeFloat(x)
            writeFloat(y)
            writeFloat(width)
            writeFloat(height)

        case .bringFloatingPaneToFront(let sessionID, let paneID):
            writeSessionID(sessionID)
            writePaneID(paneID)

        case .toggleFloatingPanePin(let sessionID, let paneID):
            writeSessionID(sessionID)
            writePaneID(paneID)

        case .runInPlace(let sessionID, let paneID, let command, let arguments):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeString(command)
            writeStringArray(arguments)

        case .runRemoteCommand(let sessionID, let paneID, let command, let arguments):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeString(command)
            writeStringArray(arguments)

        case .restartFloatingPaneCommand(let sessionID, let paneID, let command, let arguments):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeString(command)
            writeStringArray(arguments)

        case .rerunPane(let sessionID, let paneID):
            writeSessionID(sessionID)
            writePaneID(paneID)

        case .movePane(let sessionID, let sourcePaneID, let targetPaneID, let side):
            writeSessionID(sessionID)
            writePaneID(sourcePaneID)
            writePaneID(targetPaneID)
            writeFocusDirection(side)

        case .changeStrategy(let sessionID, let paneID, let kind):
            writeSessionID(sessionID)
            writePaneID(paneID)
            writeLayoutStrategyKind(kind)
        }
    }
}
