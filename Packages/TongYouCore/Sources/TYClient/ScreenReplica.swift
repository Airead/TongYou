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
    private var _scrollbackCount: Int = 0
    private var _viewportOffset: Int = 0
    private var _mouseTrackingMode: UInt8 = 0
    private var dirty = false
    private var pendingDirtyRegion = DirtyRegion.full

    private let lock = NSLock()

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = columns
        self.rows = rows
        self.cells = [Cell](repeating: Cell.empty, count: columns * rows)
    }

    /// Viewport state snapshot taken under a single lock acquisition.
    public struct ViewportInfo {
        public let scrollbackCount: Int
        public let viewportOffset: Int
        public let rows: Int
        public let columns: Int
    }

    /// Number of scrollback lines on the server.
    public var scrollbackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _scrollbackCount
    }

    /// Current viewport offset (0 = bottom).
    public var viewportOffset: Int {
        lock.lock()
        defer { lock.unlock() }
        return _viewportOffset
    }

    /// Current mouse tracking mode (rawValue of MouseTrackingMode).
    public var mouseTrackingMode: UInt8 {
        lock.lock()
        defer { lock.unlock() }
        return _mouseTrackingMode
    }

    /// Atomically read all viewport-related state in a single lock acquisition.
    public func viewportInfo() -> ViewportInfo {
        lock.lock()
        defer { lock.unlock() }
        return ViewportInfo(
            scrollbackCount: _scrollbackCount,
            viewportOffset: _viewportOffset,
            rows: rows,
            columns: columns
        )
    }

    // MARK: - Apply Server Updates

    /// Apply a full screen snapshot from the server.
    public func applyFullSnapshot(_ snapshot: ScreenSnapshot, mouseTrackingMode: UInt8 = 0) {
        lock.lock()
        defer { lock.unlock() }
        columns = snapshot.columns
        rows = snapshot.rows
        cells = snapshot.cells
        cursorCol = snapshot.cursorCol
        cursorRow = snapshot.cursorRow
        cursorVisible = snapshot.cursorVisible
        cursorShape = snapshot.cursorShape
        _scrollbackCount = snapshot.scrollbackCount
        _viewportOffset = snapshot.viewportOffset
        _mouseTrackingMode = mouseTrackingMode
        pendingDirtyRegion.markFull()
        dirty = true
    }

    /// Apply an incremental diff from the server.
    public func applyDiff(_ diff: ScreenDiff) {
        lock.lock()
        defer { lock.unlock() }
        let cols = Int(diff.columns)

        // Resize if column count changed or any dirty row exceeds current buffer.
        let maxDirtyRow = diff.dirtyRows.max().map { Int($0) + 1 } ?? rows
        var resized = false
        if cols != columns || maxDirtyRow > rows {
            let newRows = max(rows, maxDirtyRow)
            if cols != columns || newRows != rows {
                columns = cols
                rows = newRows
                cells = [Cell](repeating: Cell.empty, count: columns * rows)
                resized = true
            }
        }

        // Shift buffer up when scrollDelta is present.
        let delta = Int(diff.scrollDelta)
        if delta > 0 && !resized && delta < rows {
            let shiftCells = delta * columns
            let totalCells = rows * columns
            // Move rows [delta..<rows] to [0..<rows-delta].
            cells.replaceSubrange(0..<(totalCells - shiftCells),
                                  with: cells[shiftCells..<totalCells])
            // Clear the newly revealed bottom rows.
            let emptyStart = totalCells - shiftCells
            for i in emptyStart..<totalCells {
                cells[i] = .empty
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
        _scrollbackCount = diff.scrollbackCount
        _viewportOffset = diff.viewportOffset
        _mouseTrackingMode = diff.mouseTrackingMode

        if resized {
            pendingDirtyRegion.markFull()
        } else if delta > 0 {
            pendingDirtyRegion.markScroll(delta: delta, rowCount: rows)
            for row in diff.dirtyRows {
                pendingDirtyRegion.markLine(Int(row))
            }
        } else {
            for row in diff.dirtyRows {
                pendingDirtyRegion.markLine(Int(row))
            }
        }
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
        var region = pendingDirtyRegion
        pendingDirtyRegion = DirtyRegion(rowCount: rows, fullRebuild: false)
        // The renderer doesn't handle scroll-shift of GPU instance buffers,
        // so convert scrollDelta to fullRebuild for correct rendering.
        // Network savings from Plan B are preserved (server sends only new rows).
        if region.scrollDelta > 0 {
            region.markFull()
        }
        return ScreenSnapshot(
            cells: cells,
            columns: columns,
            rows: rows,
            cursorCol: cursorCol,
            cursorRow: cursorRow,
            cursorVisible: cursorVisible,
            cursorShape: cursorShape,
            selection: selection,
            scrollbackCount: _scrollbackCount,
            viewportOffset: _viewportOffset,
            dirtyRegion: region
        )
    }

    /// Mark as needing redraw (e.g. after selection change).
    public func markDirty() {
        lock.lock()
        pendingDirtyRegion.markFull()
        dirty = true
        lock.unlock()
    }

    public var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dirty
    }
}
