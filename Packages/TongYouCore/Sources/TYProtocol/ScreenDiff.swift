import TYTerminal

/// Incremental screen update containing only changed rows.
///
/// Sent during normal operation to minimize bandwidth. A full `ScreenSnapshot`
/// is sent on attach/reconnect; subsequent updates use `ScreenDiff`.
public struct ScreenDiff: Equatable, Sendable {
    /// Viewport row indices that changed (0-based).
    public let dirtyRows: [UInt16]

    /// Cell data for dirty rows only. Layout: `columns × dirtyRows.count` cells,
    /// ordered row-by-row matching `dirtyRows` order.
    public let cellData: [Cell]

    /// Number of columns per row (needed to interpret `cellData`).
    public let columns: UInt16

    /// Cursor column position.
    public let cursorCol: UInt16
    /// Cursor row position.
    public let cursorRow: UInt16
    /// Whether the cursor is visible.
    public let cursorVisible: Bool
    /// Cursor shape (block, underline, bar).
    public let cursorShape: CursorShape

    /// Number of scrollback lines available on the server.
    public let scrollbackCount: Int
    /// Current viewport offset (0 = bottom, >0 = scrolled up).
    public let viewportOffset: Int

    public init(
        dirtyRows: [UInt16],
        cellData: [Cell],
        columns: UInt16,
        cursorCol: UInt16,
        cursorRow: UInt16,
        cursorVisible: Bool,
        cursorShape: CursorShape,
        scrollbackCount: Int = 0,
        viewportOffset: Int = 0
    ) {
        self.dirtyRows = dirtyRows
        self.cellData = cellData
        self.columns = columns
        self.cursorCol = cursorCol
        self.cursorRow = cursorRow
        self.cursorVisible = cursorVisible
        self.cursorShape = cursorShape
        self.scrollbackCount = scrollbackCount
        self.viewportOffset = viewportOffset
    }
}
