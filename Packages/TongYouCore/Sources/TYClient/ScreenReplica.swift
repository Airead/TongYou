import Foundation
import TYProtocol
import TYTerminal

/// Client-side screen replica that stays in sync with server updates.
///
/// Maintains a local cell buffer and cursor state, updated by applying
/// full snapshots or incremental diffs received from the server.
/// Provides `ScreenSnapshot` for rendering by MetalView.
public final class ScreenReplica: @unchecked Sendable {

    private var cells: [Cell]
    public private(set) var columns: Int
    public private(set) var rows: Int
    private var cursorCol: Int = 0
    private var cursorRow: Int = 0
    private var cursorVisible: Bool = true
    private var cursorShape: CursorShape = .block
    private var dirty = false

    private let lock = NSLock()

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = columns
        self.rows = rows
        self.cells = [Cell](repeating: Cell.empty, count: columns * rows)
    }

    // MARK: - Apply Server Updates

    /// Apply a full screen snapshot from the server.
    public func applyFullSnapshot(_ snapshot: ScreenSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        columns = snapshot.columns
        rows = snapshot.rows
        cells = snapshot.cells
        cursorCol = snapshot.cursorCol
        cursorRow = snapshot.cursorRow
        cursorVisible = snapshot.cursorVisible
        cursorShape = snapshot.cursorShape
        dirty = true
    }

    /// Apply an incremental diff from the server.
    public func applyDiff(_ diff: ScreenDiff) {
        lock.lock()
        defer { lock.unlock() }
        let cols = Int(diff.columns)

        // Resize if column count changed or any dirty row exceeds current buffer.
        let maxDirtyRow = diff.dirtyRows.max().map { Int($0) + 1 } ?? rows
        if cols != columns || maxDirtyRow > rows {
            let newRows = max(rows, maxDirtyRow)
            if cols != columns || newRows != rows {
                columns = cols
                rows = newRows
                cells = [Cell](repeating: Cell.empty, count: columns * rows)
            }
        }

        // Patch dirty rows with bulk copy.
        for (i, row) in diff.dirtyRows.enumerated() {
            let dstOffset = Int(row) * columns
            let srcOffset = i * cols
            guard dstOffset + cols <= cells.count, srcOffset + cols <= diff.cellData.count else {
                continue
            }
            cells.replaceSubrange(dstOffset..<(dstOffset + cols),
                                  with: diff.cellData[srcOffset..<(srcOffset + cols)])
        }

        cursorCol = Int(diff.cursorCol)
        cursorRow = Int(diff.cursorRow)
        cursorVisible = diff.cursorVisible
        cursorShape = diff.cursorShape
        dirty = true
    }

    // MARK: - Snapshot for Rendering

    /// Returns a snapshot if content changed since last call. Nil if idle.
    public func consumeSnapshot(selection: Selection? = nil) -> ScreenSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard dirty else { return nil }
        return buildSnapshot(selection: selection)
    }

    /// Force a snapshot regardless of dirty state.
    public func forceSnapshot(selection: Selection? = nil) -> ScreenSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return buildSnapshot(selection: selection)
    }

    /// Must be called with lock held.
    private func buildSnapshot(selection: Selection?) -> ScreenSnapshot {
        dirty = false
        return ScreenSnapshot(
            cells: cells,
            columns: columns,
            rows: rows,
            cursorCol: cursorCol,
            cursorRow: cursorRow,
            cursorVisible: cursorVisible,
            cursorShape: cursorShape,
            selection: selection,
            scrollbackCount: 0,
            viewportOffset: 0,
            dirtyRegion: .full
        )
    }

    /// Mark as needing redraw (e.g. after selection change).
    public func markDirty() {
        lock.lock()
        dirty = true
        lock.unlock()
    }

    public var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dirty
    }
}
