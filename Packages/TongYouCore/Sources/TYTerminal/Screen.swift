import simd

/// Tracks which rows changed since the last snapshot, enabling partial buffer updates.
/// Supports non-contiguous dirty rows via a per-row bitset, aligned with Ghostty's model.
public struct DirtyRegion: Equatable, Sendable {
    /// When true, the renderer must rebuild all instances (scroll, resize, etc.).
    public var fullRebuild: Bool
    private var lineBits: [Bool]
    /// O(1) flag tracking whether any element in lineBits is true.
    private var anyLineDirty: Bool

    public init(rowCount: Int = 0, fullRebuild: Bool = false) {
        self.fullRebuild = fullRebuild
        self.lineBits = [Bool](repeating: false, count: rowCount)
        self.anyLineDirty = false
    }

    public static let clean = DirtyRegion(rowCount: 0, fullRebuild: false)
    public static let full = DirtyRegion(rowCount: 0, fullRebuild: true)

    /// Mark a single row as dirty.
    public mutating func markLine(_ row: Int) {
        guard !fullRebuild, row >= 0 else { return }
        if row >= lineBits.count {
            lineBits.append(contentsOf: [Bool](repeating: false, count: row - lineBits.count + 1))
        }
        lineBits[row] = true
        anyLineDirty = true
    }

    /// Mark a contiguous range of rows as dirty.
    public mutating func markRange(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        guard !fullRebuild else { return }
        let maxRow = range.upperBound - 1
        if maxRow >= lineBits.count {
            lineBits.append(contentsOf: [Bool](repeating: false, count: maxRow - lineBits.count + 1))
        }
        for i in range { lineBits[i] = true }
        anyLineDirty = true
    }

    /// Mark full rebuild required.
    public mutating func markFull() {
        fullRebuild = true
        lineBits.removeAll()
        anyLineDirty = false
    }

    /// Merge another dirty region into this one.
    public mutating func merge(_ other: DirtyRegion) {
        if other.fullRebuild {
            markFull()
            return
        }
        for (i, dirty) in other.lineBits.enumerated() where dirty {
            markLine(i)
        }
    }

    /// Whether any rows are dirty or a full rebuild is needed.
    public var isDirty: Bool {
        fullRebuild || anyLineDirty
    }

    /// Backing compatibility: returns the merged contiguous range covering all dirty rows.
    public var lineRange: Range<Int>? {
        guard !fullRebuild else { return nil }
        let indices = lineBits.enumerated().compactMap { $1 ? $0 : nil }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first..<(last + 1)
    }

    /// All dirty row indices (non-contiguous support).
    public var dirtyRows: [Int] {
        guard !fullRebuild else { return [] }
        return lineBits.enumerated().compactMap { $1 ? $0 : nil }
    }

    /// Check whether a specific row is dirty.
    public func isDirty(row: Int) -> Bool {
        guard !fullRebuild else { return true }
        return row >= 0 && row < lineBits.count && lineBits[row]
    }
}

/// Saved cursor state for DECSC/DECRC.
public struct SavedCursorState: Sendable {
    public let col: Int
    public let row: Int
    public let attributes: CellAttributes
    public let charsetState: CharsetState

    public init(col: Int, row: Int, attributes: CellAttributes, charsetState: CharsetState = CharsetState()) {
        self.col = col
        self.row = row
        self.attributes = attributes
        self.charsetState = charsetState
    }
}

/// Per-row metadata for soft-wrap tracking.
public struct LineFlags: Equatable, Sendable {
    /// True when this row's content continues on the next row (soft wrap).
    public var wrapped: Bool = false

    public init(wrapped: Bool = false) {
        self.wrapped = wrapped
    }
}

/// Immutable snapshot of screen state for cross-thread transfer to the renderer.
public struct ScreenSnapshot: Sendable {
    /// Full grid cells. Empty when `isPartial == true`.
    public let cells: [Cell]
    public let columns: Int
    public let rows: Int
    public let cursorCol: Int
    public let cursorRow: Int
    public let cursorVisible: Bool
    public let cursorShape: CursorShape
    /// Active selection (absolute line coordinates).
    public let selection: Selection?
    /// Number of scrollback lines, used to convert selection absolute coords
    /// to viewport-relative row for rendering.
    public let scrollbackCount: Int
    /// Current viewport offset (0 = bottom).
    public let viewportOffset: Int
    /// Dirty region since the previous snapshot.
    public let dirtyRegion: DirtyRegion
    /// When true, only `partialRows` contain updated rows.
    public let isPartial: Bool
    /// Dirty row indices included in `partialRows`.
    public let dirtyRows: [Int]
    /// Only dirty rows copied for incremental updates.
    public let partialRows: [(row: Int, cells: [Cell])]

    public init(
        cells: [Cell],
        columns: Int,
        rows: Int,
        cursorCol: Int,
        cursorRow: Int,
        cursorVisible: Bool,
        cursorShape: CursorShape,
        selection: Selection?,
        scrollbackCount: Int,
        viewportOffset: Int,
        dirtyRegion: DirtyRegion,
        isPartial: Bool = false,
        dirtyRows: [Int] = [],
        partialRows: [(row: Int, cells: [Cell])] = []
    ) {
        self.cells = cells
        self.columns = columns
        self.rows = rows
        self.cursorCol = cursorCol
        self.cursorRow = cursorRow
        self.cursorVisible = cursorVisible
        self.cursorShape = cursorShape
        self.selection = selection
        self.scrollbackCount = scrollbackCount
        self.viewportOffset = viewportOffset
        self.dirtyRegion = dirtyRegion
        self.isPartial = isPartial
        self.dirtyRows = dirtyRows
        self.partialRows = partialRows
    }

    public func cell(at col: Int, row: Int) -> Cell {
        if isPartial {
            fatalError("Partial snapshot does not support random cell access; use renderer backing store.")
        }
        return cells[row * columns + col]
    }

    /// Convert a viewport row to an absolute line number.
    public func absoluteLine(forViewportRow row: Int) -> Int {
        scrollbackCount - viewportOffset + row
    }

    /// Extract text from a selection over viewport-relative coordinates.
    /// Handles wide-char continuation cells and trailing-space trimming.
    public func extractText(from sel: Selection) -> String {
        if isPartial {
            fatalError("Partial snapshot does not support text extraction; use Screen.extractText directly.")
        }
        let (s, e) = sel.ordered
        var result = ""

        for row in s.line...e.line {
            guard row >= 0 && row < rows else { continue }
            let startCol = (row == s.line) ? max(0, s.col) : 0
            let endCol: Int
            if sel.mode == .line {
                endCol = columns - 1
            } else {
                endCol = (row == e.line) ? min(e.col, columns - 1) : columns - 1
            }

            for col in startCol...endCol {
                let c = cell(at: col, row: row)
                guard c.width.isRenderable else { continue }
                if c.content.scalarCount == 1, let scalar = c.content.firstScalar {
                    result.unicodeScalars.append(scalar)
                } else {
                    result.append(c.content.string)
                }
            }

            if row < e.line || sel.mode == .line {
                // Trim trailing spaces on hard line breaks.
                while result.last == " " { result.removeLast() }
                result.append("\n")
            }
        }

        while result.last == "\n" { result.removeLast() }
        return result
    }
}

/// 2D grid of terminal cells with cursor tracking.
/// Not thread-safe — confined to a single DispatchQueue by the caller.
///
/// Uses a row ring buffer: logical row 0 maps to physical row `rowBase`.
/// Full-screen scrolling rotates `rowBase` in O(columns) instead of copying
/// O(rows × columns) cells. Partial scroll regions fall back to physical copy.
public final class Screen {

    /// Minimum terminal dimensions to prevent reflow issues.
    public static let minColumns = 12
    public static let minRows = 2

    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var cursorCol: Int = 0
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorVisible: Bool = true
    public private(set) var cursorShape: CursorShape = .block

    /// Scroll region bounds (inclusive). Default: full screen.
    public private(set) var scrollTop: Int = 0
    public private(set) var scrollBottom: Int = 0

    /// Tracks which rows changed since the last snapshot.
    /// Initialized to fullRebuild so the first frame renders everything.
    public private(set) var dirtyRegion = DirtyRegion(rowCount: 0, fullRebuild: true)

    /// Mark the entire screen as dirty so the next snapshot is a full rebuild.
    public func forceFullRedraw() {
        dirtyRegion.markFull()
    }

    private var cells: [Cell]

    /// Ring buffer base: logical row 0 maps to physical row `rowBase`.
    /// Full-screen scroll advances this instead of copying all rows.
    private var rowBase: Int = 0

    /// Per-row wrap flags, ring-buffered in sync with `cells` via `rowBase`.
    private var lineFlags: [LineFlags]

    /// Alternate screen buffer (for DECSET 1049).
    private var altCells: [Cell]?
    private var altCursorCol: Int = 0
    private var altCursorRow: Int = 0
    private var altRowBase: Int = 0
    private var altLineFlags: [LineFlags]?
    private var altCharsetState: CharsetState?

    // MARK: - Charset State

    public var charsetState = CharsetState()

    // MARK: - Scrollback

    /// Flat ring buffer for scrollback lines. Lazily allocated on first scroll.
    /// Layout: scrollbackColumns cells per row, up to maxScrollback rows.
    private var scrollbackBuffer: [Cell]?
    /// Column width of the scrollback buffer (set when buffer is allocated).
    private var scrollbackColumns: Int = 0
    /// Index of the oldest valid line in the scrollback ring buffer.
    private var scrollbackStart: Int = 0
    /// Per-row wrap flags for scrollback, ring-buffered in sync with scrollbackBuffer.
    private var scrollbackLineFlags: [LineFlags]?
    /// Number of valid lines in the scrollback buffer.
    public private(set) var scrollbackCount: Int = 0

    /// Maximum scrollback lines to keep.
    public private(set) var maxScrollback: Int

    /// Viewport offset: 0 = showing latest content (bottom), >0 = scrolled up.
    public private(set) var viewportOffset: Int = 0

    private let tabWidth: Int

    public init(columns: Int, rows: Int, maxScrollback: Int = 10000, tabWidth: Int = 8) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.maxScrollback = max(0, maxScrollback)
        self.tabWidth = max(1, tabWidth)
        self.cells = [Cell](repeating: .empty, count: self.columns * self.rows)
        self.lineFlags = [LineFlags](repeating: LineFlags(), count: self.rows)
        self.scrollBottom = self.rows - 1
        self.dirtyRegion = DirtyRegion(rowCount: self.rows, fullRebuild: true)
    }

    // MARK: - Ring Buffer Helpers

    /// Physical start index in cells[] for a logical row.
    @inline(__always) private func rowStart(_ logicalRow: Int) -> Int {
        ((rowBase + logicalRow) % rows) * columns
    }

    /// Build a contiguous cells array by unwrapping the ring buffer.
    /// Returns the array directly (COW) when rowBase == 0.
    private func buildLinearCells() -> [Cell] {
        Self.linearize(cells, rowBase: rowBase, cols: columns, rowCount: rows)
    }

    /// Clear logical rows in the given range, filling with .empty cells.
    private func clearRows(_ range: Range<Int>) {
        for row in range {
            let base = rowStart(row)
            for i in base..<(base + columns) {
                cells[i] = .empty
            }
            setLineFlagForRow(row, LineFlags())
        }
    }

    /// Unwrap a ring buffer into linear (logical) order.
    private static func linearize(_ buf: [Cell], rowBase: Int, cols: Int, rowCount: Int) -> [Cell] {
        guard rowBase != 0 else { return buf }
        var linear = [Cell](repeating: .empty, count: cols * rowCount)
        for row in 0..<rowCount {
            let src = ((rowBase + row) % rowCount) * cols
            let dst = row * cols
            linear[dst..<(dst + cols)] = buf[src..<(src + cols)]
        }
        return linear
    }

    // MARK: - Line Flags Ring Buffer Helpers

    /// Access line flags for a logical row through the ring buffer.
    @inline(__always) private func lineFlagForRow(_ logicalRow: Int) -> LineFlags {
        lineFlags[(rowBase + logicalRow) % rows]
    }

    /// Set line flags for a logical row through the ring buffer.
    @inline(__always) private func setLineFlagForRow(_ logicalRow: Int, _ flag: LineFlags) {
        lineFlags[(rowBase + logicalRow) % rows] = flag
    }

    /// Unwrap lineFlags ring buffer into linear (logical) order.
    private func buildLinearLineFlags() -> [LineFlags] {
        Self.linearizeFlags(lineFlags, rowBase: rowBase, rowCount: rows)
    }

    /// Query whether an absolute line (scrollback + screen) is soft-wrapped.
    public func isLineWrapped(absoluteLine line: Int) -> Bool {
        if line < scrollbackCount {
            guard let sbFlags = scrollbackLineFlags else { return false }
            return sbFlags[scrollbackPhysicalRow(line)].wrapped
        } else {
            let screenRow = line - scrollbackCount
            guard screenRow >= 0, screenRow < rows else { return false }
            return lineFlagForRow(screenRow).wrapped
        }
    }

    // MARK: - Read Access

    public func cell(at col: Int, row: Int) -> Cell {
        cells[rowStart(row) + col]
    }

    /// Return the current dirty region and reset it to clean.
    public func consumeDirtyRegion() -> DirtyRegion {
        let region = dirtyRegion
        dirtyRegion = DirtyRegion(rowCount: rows, fullRebuild: false)
        return region
    }

    public func snapshot(selection: Selection? = nil, allowPartial: Bool = false) -> ScreenSnapshot {
        let region = consumeDirtyRegion()

        let canBePartial = allowPartial
            && !region.fullRebuild
            && region.isDirty
            && viewportOffset == 0

        if canBePartial {
            let dirty = region.dirtyRows
            var partialRows: [(row: Int, cells: [Cell])] = []
            partialRows.reserveCapacity(dirty.count)
            for row in dirty {
                guard row >= 0 && row < rows else { continue }
                let base = rowStart(row)
                var rowCells: [Cell] = []
                rowCells.reserveCapacity(columns)
                for i in base..<(base + columns) {
                    rowCells.append(cells[i])
                }
                partialRows.append((row: row, cells: rowCells))
            }
            return ScreenSnapshot(
                cells: [],
                columns: columns,
                rows: rows,
                cursorCol: cursorCol,
                cursorRow: cursorRow,
                cursorVisible: viewportOffset == 0 && cursorVisible,
                cursorShape: cursorShape,
                selection: selection,
                scrollbackCount: scrollbackCount,
                viewportOffset: viewportOffset,
                dirtyRegion: region,
                isPartial: true,
                dirtyRows: dirty,
                partialRows: partialRows
            )
        }

        let viewCells: [Cell]
        if viewportOffset == 0 {
            viewCells = buildLinearCells()
        } else {
            viewCells = buildViewportCells()
        }
        return ScreenSnapshot(
            cells: viewCells,
            columns: columns,
            rows: rows,
            cursorCol: cursorCol,
            cursorRow: cursorRow,
            cursorVisible: viewportOffset == 0 && cursorVisible,
            cursorShape: cursorShape,
            selection: selection,
            scrollbackCount: scrollbackCount,
            viewportOffset: viewportOffset,
            dirtyRegion: region
        )
    }

    /// Build the cell array for a scrolled-up viewport.
    private func buildViewportCells() -> [Cell] {
        var result = [Cell](repeating: .empty, count: columns * rows)
        let sbCount = scrollbackCount

        for viewRow in 0..<rows {
            let absLine = sbCount - viewportOffset + viewRow
            if absLine < 0 {
                continue
            } else if absLine < sbCount {
                let srcBase = scrollbackPhysicalRow(absLine) * scrollbackColumns
                let dst = viewRow * columns
                let copyCols = min(columns, scrollbackColumns)
                result[dst..<(dst + copyCols)] = scrollbackBuffer![srcBase..<(srcBase + copyCols)]
            } else {
                // From active screen — use ring buffer mapping
                let screenRow = absLine - sbCount
                if screenRow < rows {
                    let src = rowStart(screenRow)
                    let dst = viewRow * columns
                    result[dst..<(dst + columns)] = cells[src..<(src + columns)]
                }
            }
        }
        return result
    }

    // MARK: - Write Operations

    /// Write a grapheme cluster at the cursor with given attributes and advance.
    public func write(_ cluster: GraphemeCluster, attributes: CellAttributes) {
        var effectiveCluster = cluster
        if cluster.scalarCount == 1, let s = cluster.firstScalar, s.value <= 0x7E {
            let mapped = charsetState.map(UInt8(s.value))
            if mapped.value != s.value {
                effectiveCluster = GraphemeCluster(mapped)
            }
        }
        writeCluster(effectiveCluster, attributes: attributes)
    }

    private func writeCluster(_ cluster: GraphemeCluster, attributes: CellAttributes) {
        let w = Int(cluster.terminalWidth)

        if cursorCol >= columns {
            setLineFlagForRow(cursorRow, LineFlags(wrapped: true))
            cursorCol = 0
            advanceRow()
        }

        // Wide char doesn't fit on current line: leave spacer, wrap
        if w == 2 && cursorCol == columns - 1 {
            let idx = rowStart(cursorRow) + cursorCol
            cells[idx] = Cell(content: GraphemeCluster(" "), attributes: .default, width: .spacer)
            dirtyRegion.markLine(cursorRow)
            setLineFlagForRow(cursorRow, LineFlags(wrapped: true))
            cursorCol = 0
            advanceRow()
        }

        dirtyRegion.markLine(cursorRow)
        let col = cursorCol
        let base = rowStart(cursorRow)
        let idx = base + col

        // Clean up any wide char pair that the new write would overwrite
        if cells[idx].width != .normal {
            cleanUpWideCharAt(col: col, row: cursorRow)
        }
        if w == 2 && col + 1 < columns && cells[idx + 1].width != .normal {
            cleanUpWideCharAt(col: col + 1, row: cursorRow)
        }

        cells[idx].content = cluster
        cells[idx].attributes = attributes
        cells[idx].width = w == 2 ? .wide : .normal

        if w == 2 {
            let contIdx = idx + 1
            cells[contIdx].content = GraphemeCluster(" ")
            cells[contIdx].attributes = attributes
            cells[contIdx].width = .continuation
            cursorCol = col + 2
        } else {
            cursorCol = col + 1
        }
    }

    /// Write a printable character at the cursor with given attributes and advance.
    /// Backward compatible wrapper for single scalar writes.
    public func write(_ scalar: Unicode.Scalar, attributes: CellAttributes) {
        let mapped: Unicode.Scalar = (scalar.value <= 0x7E) ? charsetState.map(UInt8(scalar.value)) : scalar
        writeCluster(GraphemeCluster(mapped), attributes: attributes)
    }

    /// Write a printable character at the cursor with default attributes and advance.
    public func write(_ scalar: Unicode.Scalar) {
        write(scalar, attributes: .default)
    }

    /// Batch-write single-width ASCII (0x20-0x7E). One dirtyRegion mark per line instead of per character.
    public func writeASCIIBatch(_ buffer: PrintBatchBuffer, count: Int, attributes: CellAttributes) {
        let needsMapping = (charsetState.gl == .g0 && charsetState.g0 != .ascii) ||
                           (charsetState.gl == .g1 && charsetState.g1 != .ascii)

        var i = 0
        while i < count {
            // Handle wrap from previous write
            if cursorCol >= columns {
                setLineFlagForRow(cursorRow, LineFlags(wrapped: true))
                cursorCol = 0
                advanceRow()
            }

            dirtyRegion.markLine(cursorRow)
            let base = rowStart(cursorRow)

            // Write as many characters as fit on the current line
            let remaining = columns - cursorCol
            let batchEnd = min(i + remaining, count)

            while i < batchEnd {
                let idx = base + cursorCol
                // Clean up wide char pair if overwriting
                if cells[idx].width != .normal {
                    cleanUpWideCharAt(col: cursorCol, row: cursorRow)
                }
                let mapped = needsMapping ? charsetState.map(buffer[i]) : Unicode.Scalar(buffer[i])
                cells[idx].codepoint = mapped
                cells[idx].attributes = attributes
                cells[idx].width = .normal
                cursorCol += 1
                i += 1
            }
        }
    }

    // MARK: - Wide Character Helpers

    /// If the cell at (col, row) is part of a wide character pair,
    /// clear the orphaned counterpart so no half-wide artifacts remain.
    private func cleanUpWideCharAt(col: Int, row: Int) {
        let base = rowStart(row)
        let cell = cells[base + col]
        if cell.width == .wide {
            // This is a wide head — clear its continuation
            let contCol = col + 1
            if contCol < columns {
                cells[base + contCol] = .empty
            }
        } else if cell.width == .continuation {
            // This is a continuation — clear its head
            let headCol = col - 1
            if headCol >= 0 {
                cells[base + headCol] = .empty
            }
        }
    }

    /// Repair a wide character that straddles the boundary at `col` within `row`.
    /// Call before/after erase/insert/delete that may cut a wide pair at the boundary.
    /// Clears both halves of the pair so no orphan remains.
    private func repairWideCharBoundary(col: Int, row: Int) {
        guard col >= 0 && col < columns else { return }
        let base = rowStart(row)
        let cell = cells[base + col]
        if cell.width == .continuation {
            // Continuation — clear it and its head
            cells[base + col] = .empty
            if col > 0 {
                cells[base + col - 1] = .empty
            }
        } else if cell.width == .wide && col + 1 < columns && cells[base + col + 1].width == .continuation {
            // Wide head with valid continuation — clear both
            cells[base + col] = .empty
            cells[base + col + 1] = .empty
        }
    }

    /// Line feed: move cursor down one row (scroll if at bottom of scroll region).
    public func lineFeed() {
        dirtyRegion.markLine(cursorRow)
        advanceRow()
        dirtyRegion.markLine(cursorRow)
    }

    /// Carriage return: move cursor to column 0.
    public func carriageReturn() {
        cursorCol = 0
    }

    /// Newline: carriage return + line feed.
    public func newline() {
        carriageReturn()
        lineFeed()
    }

    /// Backspace: move cursor left by one (stops at column 0).
    public func backspace() {
        let oldCol = cursorCol
        if cursorCol > 0 {
            cursorCol -= 1
        }
        if cursorCol != oldCol { dirtyRegion.markLine(cursorRow) }
    }

    /// Tab: advance cursor to next tab stop (every 8 columns).
    public func tab() {
        let nextStop = ((cursorCol / tabWidth) + 1) * tabWidth
        cursorCol = min(nextStop, columns - 1)
    }

    // MARK: - Cursor Movement

    /// Move cursor up by `n` rows, clamping at scroll top.
    public func cursorUp(_ n: Int) {
        moveCursorRow(to: max(scrollTop, cursorRow - max(1, n)))
    }

    /// Move cursor down by `n` rows, clamping at scroll bottom.
    public func cursorDown(_ n: Int) {
        moveCursorRow(to: min(scrollBottom, cursorRow + max(1, n)))
    }

    /// Move cursor forward (right) by `n` columns, clamping at last column.
    public func cursorForward(_ n: Int) {
        let oldCol = cursorCol
        cursorCol = min(columns - 1, cursorCol + max(1, n))
        if cursorCol != oldCol { dirtyRegion.markLine(cursorRow) }
    }

    /// Move cursor backward (left) by `n` columns, clamping at column 0.
    public func cursorBackward(_ n: Int) {
        let oldCol = cursorCol
        cursorCol = max(0, cursorCol - max(1, n))
        if cursorCol != oldCol { dirtyRegion.markLine(cursorRow) }
    }

    /// Set cursor to absolute position (0-based row, col).
    public func setCursorPos(row: Int, col: Int) {
        moveCursorRow(to: clampRow(row))
        let oldCol = cursorCol
        cursorCol = clampCol(col)
        if cursorCol != oldCol { dirtyRegion.markLine(cursorRow) }
    }

    /// Set cursor row (0-based), clamping to screen bounds.
    public func setCursorRow(_ row: Int) {
        moveCursorRow(to: clampRow(row))
    }

    /// Set cursor column (0-based), clamping to screen bounds.
    public func setCursorCol(_ col: Int) {
        let oldCol = cursorCol
        cursorCol = clampCol(col)
        if cursorCol != oldCol { dirtyRegion.markLine(cursorRow) }
    }

    public func setCursorVisible(_ visible: Bool) {
        cursorVisible = visible
        dirtyRegion.markLine(cursorRow)
    }

    public func setCursorShape(_ shape: CursorShape) {
        cursorShape = shape
        dirtyRegion.markLine(cursorRow)
    }

    // MARK: - Erase Operations

    /// Erase in display (ED). Mode: 0=below, 1=above, 2=all, 3=all+scrollback.
    public func eraseDisplay(mode: Int, attributes: CellAttributes = .default) {
        let blank = Cell(codepoint: " ", attributes: attributes, width: .normal)

        switch mode {
        case 0: // Erase from cursor to end of screen
            repairWideCharBoundary(col: cursorCol, row: cursorRow)
            // Current row from cursor to end
            let base = rowStart(cursorRow)
            for col in cursorCol..<columns {
                cells[base + col] = blank
            }
            setLineFlagForRow(cursorRow, LineFlags())
            // All rows below cursor
            for row in (cursorRow + 1)..<rows {
                let base = rowStart(row)
                for col in 0..<columns {
                    cells[base + col] = blank
                }
                setLineFlagForRow(row, LineFlags())
            }
            dirtyRegion.markRange(cursorRow..<rows)
        case 1: // Erase from start to cursor
            // All rows above cursor
            for row in 0..<cursorRow {
                let base = rowStart(row)
                for col in 0..<columns {
                    cells[base + col] = blank
                }
                setLineFlagForRow(row, LineFlags())
            }
            // Current row from start to cursor (inclusive)
            let base = rowStart(cursorRow)
            for col in 0...cursorCol {
                cells[base + col] = blank
            }
            if cursorCol + 1 < columns {
                repairWideCharBoundary(col: cursorCol + 1, row: cursorRow)
            }
            dirtyRegion.markRange(0..<(cursorRow + 1))
        case 2: // Erase entire screen
            for i in 0..<cells.count {
                cells[i] = blank
            }
            rowBase = 0
            lineFlags = [LineFlags](repeating: LineFlags(), count: rows)
            dirtyRegion.markFull()
        case 3: // Erase entire screen + scrollback
            for i in 0..<cells.count {
                cells[i] = blank
            }
            rowBase = 0
            lineFlags = [LineFlags](repeating: LineFlags(), count: rows)
            resetScrollback(deallocate: false)
            dirtyRegion.markFull()
        default:
            break
        }
    }

    /// Erase in line (EL). Mode: 0=right, 1=left, 2=all.
    public func eraseLine(mode: Int, attributes: CellAttributes = .default) {
        let blank = Cell(codepoint: " ", attributes: attributes, width: .normal)
        let base = rowStart(cursorRow)

        switch mode {
        case 0: // Erase from cursor to end of line
            repairWideCharBoundary(col: cursorCol, row: cursorRow)
            for col in cursorCol..<columns {
                cells[base + col] = blank
            }
            setLineFlagForRow(cursorRow, LineFlags())
        case 1: // Erase from start of line to cursor
            for col in 0...cursorCol {
                cells[base + col] = blank
            }
            if cursorCol + 1 < columns {
                repairWideCharBoundary(col: cursorCol + 1, row: cursorRow)
            }
        case 2: // Erase entire line
            for col in 0..<columns {
                cells[base + col] = blank
            }
            setLineFlagForRow(cursorRow, LineFlags())
        default:
            break
        }
        dirtyRegion.markLine(cursorRow)
    }

    /// Erase characters (ECH): erase `count` chars starting at cursor (fills with blank).
    public func eraseCharacters(count: Int, attributes: CellAttributes = .default) {
        let blank = Cell(codepoint: " ", attributes: attributes, width: .normal)
        let n = max(1, count)
        let base = rowStart(cursorRow)
        let end = min(cursorCol + n, columns)
        repairWideCharBoundary(col: cursorCol, row: cursorRow)
        for col in cursorCol..<end {
            cells[base + col] = blank
        }
        if end < columns {
            repairWideCharBoundary(col: end, row: cursorRow)
        }
        dirtyRegion.markLine(cursorRow)
    }

    // MARK: - Scroll Operations

    /// Scroll up by `count` lines within the scroll region.
    public func scrollUp(count: Int = 1) {
        let n = min(max(1, count), scrollBottom - scrollTop + 1)
        let shiftRows = scrollBottom - scrollTop + 1 - n
        if shiftRows > 0 {
            for i in 0..<shiftRows {
                let src = rowStart(scrollTop + n + i)
                let dst = rowStart(scrollTop + i)
                cells[dst..<(dst + columns)] = cells[src..<(src + columns)]
                setLineFlagForRow(scrollTop + i, lineFlagForRow(scrollTop + n + i))
            }
        }
        clearRows((scrollBottom - n + 1)..<(scrollBottom + 1))
        dirtyRegion.markRange(scrollTop..<(scrollBottom + 1))
    }

    /// Scroll down by `count` lines within the scroll region.
    public func scrollDown(count: Int = 1) {
        let n = min(max(1, count), scrollBottom - scrollTop + 1)
        let shiftRows = scrollBottom - scrollTop + 1 - n
        if shiftRows > 0 {
            for i in stride(from: shiftRows - 1, through: 0, by: -1) {
                let src = rowStart(scrollTop + i)
                let dst = rowStart(scrollTop + n + i)
                cells[dst..<(dst + columns)] = cells[src..<(src + columns)]
                setLineFlagForRow(scrollTop + n + i, lineFlagForRow(scrollTop + i))
            }
        }
        clearRows(scrollTop..<(scrollTop + n))
        dirtyRegion.markRange(scrollTop..<(scrollBottom + 1))
    }

    /// Set scroll region (DECSTBM). Values are 0-based inclusive.
    /// Pass top=0, bottom=rows-1 to reset to full screen.
    public func setScrollRegion(top: Int, bottom: Int) {
        let t = max(0, min(top, rows - 1))
        let b = max(t, min(bottom, rows - 1))
        scrollTop = t
        scrollBottom = b
        // DECSTBM resets cursor to home position
        cursorRow = 0
        cursorCol = 0
        dirtyRegion.markFull()
    }

    /// Reverse index (ESC M): move cursor up one row, scrolling down if at top of region.
    public func reverseIndex() {
        if cursorRow == scrollTop {
            scrollRegionDown()
        } else if cursorRow > 0 {
            moveCursorRow(to: cursorRow - 1)
        }
    }

    // MARK: - Insert / Delete

    /// Insert `count` blank characters at cursor position, shifting content right.
    public func insertCharacters(count: Int) {
        let n = min(max(1, count), columns - cursorCol)
        let base = rowStart(cursorRow)

        // If cursor is on a continuation, the insert splits the wide pair.
        if cells[base + cursorCol].width == .continuation && cursorCol > 0 {
            cells[base + cursorCol - 1] = .empty
        }

        let src = base + cursorCol
        let dst = base + cursorCol + n
        let moveCount = columns - cursorCol - n
        if moveCount > 0 {
            cells[dst..<(dst + moveCount)] = cells[src..<(src + moveCount)]
        }
        // Fill inserted positions with blanks
        for i in src..<(src + n) {
            cells[i] = .empty
        }

        // Repair wide char that may have been clipped at the right edge after shift
        let clipCol = columns - n
        if clipCol > 0 && clipCol < columns && cells[base + clipCol].width == .continuation {
            cells[base + clipCol] = .empty
            cells[base + clipCol - 1] = .empty
        }
        dirtyRegion.markLine(cursorRow)
    }

    /// Delete `count` characters at cursor position, shifting content left.
    public func deleteCharacters(count: Int) {
        let n = min(max(1, count), columns - cursorCol)
        let base = rowStart(cursorRow)

        // If cursor is on a continuation, its head stays but continuation is deleted.
        if cells[base + cursorCol].width == .continuation && cursorCol > 0 {
            cells[base + cursorCol - 1] = .empty
        }
        // If right boundary lands on a continuation, clear it.
        let rightEdge = cursorCol + n
        if rightEdge < columns && cells[base + rightEdge].width == .continuation {
            cells[base + rightEdge] = .empty
        }

        let dst = base + cursorCol
        let src = base + cursorCol + n
        let moveCount = columns - cursorCol - n
        if moveCount > 0 {
            cells[dst..<(dst + moveCount)] = cells[src..<(src + moveCount)]
        }
        // Fill vacated positions at end with blanks
        let blankStart = base + columns - n
        for i in blankStart..<(base + columns) {
            cells[i] = .empty
        }
        dirtyRegion.markLine(cursorRow)
    }

    /// Insert `count` blank lines at cursor row, pushing content down within scroll region.
    public func insertLines(count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        let n = min(max(1, count), scrollBottom - cursorRow + 1)
        for row in stride(from: scrollBottom, through: cursorRow + n, by: -1) {
            let srcRow = row - n
            let src = rowStart(srcRow)
            let dst = rowStart(row)
            cells[dst..<(dst + columns)] = cells[src..<(src + columns)]
            setLineFlagForRow(row, lineFlagForRow(srcRow))
        }
        clearRows(cursorRow..<(cursorRow + n))
        cursorCol = 0
        dirtyRegion.markFull()
    }

    /// Delete `count` lines at cursor row, pulling content up within scroll region.
    public func deleteLines(count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        let n = min(max(1, count), scrollBottom - cursorRow + 1)
        // Shift lines up within region
        let shiftEnd = scrollBottom - n
        if cursorRow <= shiftEnd {
            for row in cursorRow...shiftEnd {
                let src = rowStart(row + n)
                let dst = rowStart(row)
                cells[dst..<(dst + columns)] = cells[src..<(src + columns)]
                setLineFlagForRow(row, lineFlagForRow(row + n))
            }
        }
        clearRows((scrollBottom - n + 1)..<(scrollBottom + 1))
        cursorCol = 0
        dirtyRegion.markFull()
    }

    // MARK: - Tab

    /// Forward tabulation: advance cursor to the Nth next tab stop.
    public func forwardTab(count: Int = 1) {
        for _ in 0..<max(1, count) {
            tab()
        }
    }

    /// Backward tabulation: move cursor to the Nth previous tab stop.
    public func backwardTab(count: Int = 1) {
        for _ in 0..<max(1, count) {
            if cursorCol == 0 { break }
            // Move to previous tab stop
            let prevStop = ((cursorCol - 1) / tabWidth) * tabWidth
            cursorCol = prevStop
        }
    }

    // MARK: - Alternate Screen Buffer

    /// Switch to alternate screen buffer (DECSET 1049).
    public func switchToAltScreen() {
        guard altCells == nil else { return }
        altCells = cells
        altRowBase = rowBase
        altLineFlags = lineFlags
        altCursorCol = cursorCol
        altCursorRow = cursorRow
        altCharsetState = charsetState
        cells = [Cell](repeating: .empty, count: columns * rows)
        lineFlags = [LineFlags](repeating: LineFlags(), count: rows)
        rowBase = 0
        cursorCol = 0
        cursorRow = 0
        dirtyRegion.markFull()
    }

    /// Switch back to main screen buffer (DECRST 1049).
    public func switchToMainScreen() {
        guard let saved = altCells else { return }
        cells = saved
        altCells = nil
        rowBase = altRowBase
        altRowBase = 0
        if let savedFlags = altLineFlags {
            lineFlags = savedFlags
            altLineFlags = nil
        }
        cursorCol = altCursorCol
        cursorRow = altCursorRow
        if let savedCharset = altCharsetState {
            charsetState = savedCharset
            altCharsetState = nil
        }
        dirtyRegion.markFull()
    }

    // MARK: - Full Reset

    /// Full terminal reset (RIS).
    public func fullReset() {
        cells = [Cell](repeating: .empty, count: columns * rows)
        lineFlags = [LineFlags](repeating: LineFlags(), count: rows)
        rowBase = 0
        cursorCol = 0
        cursorRow = 0
        cursorVisible = true
        cursorShape = .block
        scrollTop = 0
        scrollBottom = rows - 1
        altCells = nil
        altLineFlags = nil
        altCursorCol = 0
        altCursorRow = 0
        altRowBase = 0
        altCharsetState = nil
        charsetState = CharsetState()
        resetScrollback(deallocate: false)
        dirtyRegion.markFull()
    }

    // MARK: - Resize

    /// Resize the screen with content reflow when columns change.
    /// Also resizes the saved alternate screen buffer (simple truncation, no reflow).
    public func resize(columns newCols: Int, rows newRows: Int) {
        let newCols = max(1, newCols)
        let newRows = max(1, newRows)

        guard newCols != columns || newRows != rows else { return }

        let oldCols = columns
        let oldRows = rows

        // Reflow main screen (scrollback + active) when columns change.
        if newCols != oldCols {
            reflowResize(newCols: newCols, newRows: newRows)
        } else {
            // Only row count changed — simple resize without reflow.
            resizeRowsOnly(newRows: newRows)
        }

        // WARNING: Do NOT defer or remove this alt-buffer resize.
        // switchToMainScreen() restores altCells as the active buffer;
        // if its element count mismatches columns * rows, every Screen
        // method (write, erase, scroll…) will crash with index-out-of-range.
        if let alt = altCells {
            let savedAltRowBase = altRowBase
            let linearAlt = Self.linearize(alt, rowBase: savedAltRowBase, cols: oldCols, rowCount: oldRows)
            let copyRows = min(oldRows, newRows)
            let copyCols = min(oldCols, newCols)
            altCells = Self.resizedGrid(from: linearAlt, oldCols: oldCols, newCols: newCols,
                                        newRows: newRows, copyRows: copyRows, copyCols: copyCols)
            altRowBase = 0
            var newAltFlags = [LineFlags](repeating: LineFlags(), count: newRows)
            if let af = altLineFlags {
                let linearAltFlags = Self.linearizeFlags(af, rowBase: savedAltRowBase, rowCount: oldRows)
                for r in 0..<min(copyRows, newRows) {
                    newAltFlags[r] = linearAltFlags[r]
                }
            }
            altLineFlags = newAltFlags
            altCursorCol = min(altCursorCol, newCols - 1)
            altCursorRow = min(altCursorRow, newRows - 1)
        }

        columns = newCols
        rows = newRows

        cursorCol = min(cursorCol, newCols - 1)
        cursorRow = min(cursorRow, newRows - 1)
        scrollTop = 0
        scrollBottom = newRows - 1
        dirtyRegion.markFull()
    }

    /// Simple resize when only row count changes (no reflow needed).
    private func resizeRowsOnly(newRows: Int) {
        let copyRows = min(rows, newRows)
        var newCells = [Cell](repeating: .empty, count: columns * newRows)
        var newFlags = [LineFlags](repeating: LineFlags(), count: newRows)
        for row in 0..<copyRows {
            let src = rowStart(row)
            let dst = row * columns
            newCells[dst..<(dst + columns)] = cells[src..<(src + columns)]
            newFlags[row] = lineFlagForRow(row)
        }
        cells = newCells
        lineFlags = newFlags
        rowBase = 0
    }

    /// Reflow all content (scrollback + active screen) to a new column width.
    /// Joins soft-wrapped lines into logical lines and re-wraps at the new width.
    private func reflowResize(newCols: Int, newRows: Int) {
        let oldCols = columns
        let oldSBCols = scrollbackColumns > 0 ? scrollbackColumns : oldCols
        let cursorAbsRow = scrollbackCount + cursorRow

        // --- Step 1: Build logical lines from scrollback + active rows ---
        // A logical line is a sequence of cells from consecutive rows where all
        // but the last have wrapped=true.

        var logicalLines: [[Cell]] = []
        var currentLine: [Cell] = []
        var cursorLogicalIdx = 0
        var cursorCellOffset = 0
        var absRow = 0
        var totalCellCount = 0

        // Shared per-row logic for building logical lines
        func processRow(_ rowCells: ArraySlice<Cell>, _ flag: LineFlags, _ rowCols: Int) {
            if absRow == cursorAbsRow {
                cursorLogicalIdx = logicalLines.count
                cursorCellOffset = currentLine.count + min(cursorCol, rowCols)
            }
            if flag.wrapped {
                currentLine.append(contentsOf: Self.trimTrailing(rowCells) { $0.width == .spacer })
            } else {
                currentLine.append(contentsOf: Self.trimTrailing(rowCells) { $0 == .empty })
                totalCellCount += currentLine.count
                logicalLines.append(currentLine)
                currentLine = []
            }
            absRow += 1
        }

        // Process scrollback rows
        if let sb = scrollbackBuffer {
            for i in 0..<scrollbackCount {
                let physRow = scrollbackPhysicalRow(i)
                let base = physRow * oldSBCols
                let rowCells = sb[base..<(base + oldSBCols)]
                let flag = scrollbackLineFlags?[physRow] ?? LineFlags()
                processRow(rowCells, flag, oldSBCols)
            }
        }

        // Process active screen rows (linearized)
        let linearCells = buildLinearCells()
        let linearFlags = buildLinearLineFlags()
        for row in 0..<rows {
            let base = row * oldCols
            let rowCells = linearCells[base..<(base + oldCols)]
            processRow(rowCells, linearFlags[row], oldCols)
        }

        // Flush remaining cells (if last row was wrapped)
        if !currentLine.isEmpty {
            if cursorAbsRow >= absRow {
                cursorLogicalIdx = logicalLines.count
                cursorCellOffset = 0
            }
            totalCellCount += currentLine.count
            logicalLines.append(currentLine)
        }

        // Handle empty screen
        if logicalLines.isEmpty {
            logicalLines.append([])
        }

        // --- Step 2: Re-wrap logical lines at new column width ---
        let estimatedRows = totalCellCount / max(1, newCols) + logicalLines.count
        var newAllCells: [Cell] = []
        newAllCells.reserveCapacity(estimatedRows * newCols)
        var newAllWrapped: [Bool] = []
        newAllWrapped.reserveCapacity(estimatedRows)
        var newCursorAbsRow = 0
        var newCursorCol = 0

        for (lineIdx, logLine) in logicalLines.enumerated() {
            let lineStartRow = newAllWrapped.count

            if logLine.isEmpty {
                newAllCells.append(contentsOf: repeatElement(Cell.empty, count: newCols))
                newAllWrapped.append(false)
            } else {
                var srcIdx = 0
                let cursorSrcTarget = (lineIdx == cursorLogicalIdx) ? cursorCellOffset : -1
                var cursorFound = false

                while srcIdx < logLine.count {
                    let rowStart = newAllCells.count
                    newAllCells.append(contentsOf: repeatElement(Cell.empty, count: newCols))
                    var col = 0

                    while col < newCols && srcIdx < logLine.count {
                        // Track cursor: cursor is at this position if srcIdx matches
                        if !cursorFound && srcIdx >= cursorSrcTarget && cursorSrcTarget >= 0 {
                            newCursorAbsRow = newAllWrapped.count
                            newCursorCol = col
                            cursorFound = true
                        }

                        let cell = logLine[srcIdx]
                        if cell.width == .wide {
                            if col + 1 < newCols {
                                newAllCells[rowStart + col] = cell
                                if srcIdx + 1 < logLine.count && logLine[srcIdx + 1].width == .continuation {
                                    newAllCells[rowStart + col + 1] = logLine[srcIdx + 1]
                                    srcIdx += 2
                                } else {
                                    newAllCells[rowStart + col + 1] = Cell(
                                        codepoint: " ", attributes: cell.attributes, width: .continuation)
                                    srcIdx += 1
                                }
                                col += 2
                            } else {
                                // Wide char doesn't fit at last column — mark spacer, wrap
                                newAllCells[rowStart + col] = Cell(
                                    codepoint: " ", attributes: .default, width: .spacer)
                                break
                            }
                        } else if cell.width == .continuation || cell.width == .spacer {
                            // Orphaned continuation or boundary spacer — skip
                            srcIdx += 1
                        } else {
                            newAllCells[rowStart + col] = cell
                            col += 1
                            srcIdx += 1
                        }
                    }

                    let isWrapped = srcIdx < logLine.count
                    newAllWrapped.append(isWrapped)
                }

                // If cursor was past the end of content in this logical line
                if !cursorFound && cursorSrcTarget >= 0 {
                    let lastRow = newAllWrapped.count - 1
                    newCursorAbsRow = lastRow
                    // Find end of content on last row
                    let rowBase = lastRow * newCols
                    var endCol = 0
                    for c in 0..<newCols {
                        if newAllCells[rowBase + c] != .empty {
                            endCol = c + 1
                        }
                    }
                    newCursorCol = min(endCol, newCols - 1)
                }
            }

            // Handle cursor on empty line — preserve column offset (clamped)
            if lineIdx == cursorLogicalIdx && logLine.isEmpty {
                newCursorAbsRow = lineStartRow
                newCursorCol = min(cursorCellOffset, newCols - 1)
            }
        }

        // --- Step 3: Trim trailing empty rows below the cursor ---
        // Empty rows from the old screen's padding shouldn't push content into scrollback.
        while newAllWrapped.count > newCursorAbsRow + 1 {
            let lastIdx = newAllWrapped.count - 1
            if newAllWrapped[lastIdx] { break }  // wrapped row — keep it
            let lastBase = lastIdx * newCols
            var isEmpty = true
            for c in 0..<newCols {
                if newAllCells[lastBase + c] != .empty { isEmpty = false; break }
            }
            if !isEmpty { break }
            newAllCells.removeLast(newCols)
            newAllWrapped.removeLast()
        }

        // --- Step 4: Split into scrollback + active screen ---
        let totalRows = newAllWrapped.count
        var sbRowCount = max(0, totalRows - newRows)
        // Ensure cursor stays in the active screen
        if newCursorAbsRow < sbRowCount {
            sbRowCount = newCursorAbsRow
        }
        let activeRowCount = min(totalRows - sbRowCount, newRows)

        // Build new scrollback
        let newSBCount = min(sbRowCount, maxScrollback)
        if newSBCount > 0 {
            var newSB = [Cell](repeating: .empty, count: newCols * maxScrollback)
            var newSBFlags = [LineFlags](repeating: LineFlags(), count: maxScrollback)
            let sbStart = sbRowCount - newSBCount  // skip oldest if over maxScrollback
            for i in 0..<newSBCount {
                let srcRow = sbStart + i
                let src = srcRow * newCols
                let dst = i * newCols
                newSB[dst..<(dst + newCols)] = newAllCells[src..<(src + newCols)]
                newSBFlags[i] = LineFlags(wrapped: newAllWrapped[srcRow])
            }
            scrollbackBuffer = newSB
            scrollbackLineFlags = newSBFlags
            scrollbackColumns = newCols
            scrollbackStart = 0
            scrollbackCount = newSBCount
        } else {
            resetScrollback(deallocate: true)
        }

        // Build new active screen
        var newCells = [Cell](repeating: .empty, count: newCols * newRows)
        var newFlags = [LineFlags](repeating: LineFlags(), count: newRows)
        let activeStart = sbRowCount
        for i in 0..<activeRowCount {
            let srcRow = activeStart + i
            let src = srcRow * newCols
            let dst = i * newCols
            newCells[dst..<(dst + newCols)] = newAllCells[src..<(src + newCols)]
            newFlags[i] = LineFlags(wrapped: newAllWrapped[srcRow])
        }

        cells = newCells
        lineFlags = newFlags
        rowBase = 0

        // Map cursor to new active screen coordinates
        if newCursorAbsRow >= sbRowCount {
            cursorRow = newCursorAbsRow - sbRowCount
            cursorCol = newCursorCol
        } else {
            // Cursor scrolled into scrollback — place at top of active screen
            cursorRow = 0
            cursorCol = 0
        }

        viewportOffset = min(viewportOffset, scrollbackCount)
    }

    /// Trim trailing cells matching `predicate` from a slice.
    private static func trimTrailing(
        _ slice: ArraySlice<Cell>,
        while predicate: (Cell) -> Bool
    ) -> ArraySlice<Cell> {
        var end = slice.endIndex
        while end > slice.startIndex && predicate(slice[end - 1]) {
            end -= 1
        }
        return slice[slice.startIndex..<end]
    }

    /// Linearize a flags array through a ring buffer base.
    private static func linearizeFlags(_ flags: [LineFlags], rowBase: Int, rowCount: Int) -> [LineFlags] {
        guard rowBase != 0 else { return flags }
        var linear = [LineFlags](repeating: LineFlags(), count: rowCount)
        for row in 0..<rowCount {
            linear[row] = flags[(rowBase + row) % rowCount]
        }
        return linear
    }

    // MARK: - Viewport Scrolling

    /// Scroll the viewport up by `lines` (view older content).
    public func scrollViewportUp(lines: Int = 1) {
        let old = viewportOffset
        viewportOffset = min(viewportOffset + max(1, lines), scrollbackCount)
        if viewportOffset != old { dirtyRegion.markFull() }
    }

    /// Scroll the viewport down by `lines` (view newer content).
    public func scrollViewportDown(lines: Int = 1) {
        let old = viewportOffset
        viewportOffset = max(0, viewportOffset - max(1, lines))
        if viewportOffset != old { dirtyRegion.markFull() }
    }

    /// Jump viewport to the bottom (most recent content).
    public func scrollViewportToBottom() {
        viewportOffset = 0
        dirtyRegion.markFull()
    }

    /// Set viewport offset directly (clamped to valid range).
    public func setViewportOffset(_ offset: Int) {
        viewportOffset = max(0, min(offset, scrollbackCount))
        dirtyRegion.markFull()
    }

    /// Whether the viewport is scrolled up from the bottom.
    public var isScrolledUp: Bool { viewportOffset > 0 }

    // MARK: - Scrollback Ring Buffer

    /// Map a logical scrollback index to the physical row in the ring buffer.
    @inline(__always) private func scrollbackPhysicalRow(_ logicalIndex: Int) -> Int {
        (scrollbackStart + logicalIndex) % maxScrollback
    }

    /// Reset scrollback state. Pass `deallocate: true` when the buffer
    /// geometry is invalid (e.g. column count changed).
    private func resetScrollback(deallocate: Bool) {
        if deallocate {
            scrollbackBuffer = nil
            scrollbackLineFlags = nil
            scrollbackColumns = 0
        }
        scrollbackStart = 0
        scrollbackCount = 0
        viewportOffset = 0
    }

    /// Append the current top screen row to the flat scrollback ring buffer.
    /// Zero steady-state allocation: copies directly into a pre-allocated slot.
    private func appendScrollbackLine() {
        if scrollbackBuffer == nil {
            scrollbackBuffer = [Cell](repeating: .empty, count: columns * maxScrollback)
            scrollbackColumns = columns
            scrollbackLineFlags = [LineFlags](repeating: LineFlags(), count: maxScrollback)
        }
        let topBase = rowStart(0)
        let slotIndex: Int
        if scrollbackCount < maxScrollback {
            slotIndex = scrollbackCount
            scrollbackCount += 1
        } else {
            slotIndex = scrollbackPhysicalRow(0)
            scrollbackStart = (scrollbackStart + 1) % maxScrollback
        }
        let dst = slotIndex * scrollbackColumns
        scrollbackBuffer![dst..<(dst + scrollbackColumns)] = cells[topBase..<(topBase + columns)]
        scrollbackLineFlags![slotIndex] = lineFlagForRow(0)

        // Keep the viewport pinned to the same content when scrolled up.
        if viewportOffset > 0 {
            viewportOffset = min(viewportOffset + 1, scrollbackCount)
        }
    }

    /// Single cell access into scrollback — zero allocation.
    @inline(__always)
    public func scrollbackCell(line: Int, col: Int) -> Cell {
        let base = scrollbackPhysicalRow(line) * scrollbackColumns
        return scrollbackBuffer![base + col]
    }

    /// Get the codepoint at an absolute line + column, resolving scrollback vs active screen.
    public func codepoint(atAbsoluteLine line: Int, col: Int) -> Unicode.Scalar {
        if line < scrollbackCount {
            guard col < scrollbackColumns else { return " " }
            return scrollbackCell(line: line, col: col).codepoint
        } else {
            let screenRow = line - scrollbackCount
            guard screenRow >= 0, screenRow < rows, col < columns else { return " " }
            return cells[rowStart(screenRow) + col].codepoint
        }
    }


    // MARK: - Text Extraction

    /// Extract text from the given absolute line range and column range.
    /// Used for selection → copy.
    public func extractText(from sel: Selection) -> String {
        let (s, e) = sel.ordered
        var result = ""
        let sbCount = scrollbackCount

        for line in s.line...e.line {
            let startCol = (line == s.line) ? s.col : 0
            let endCol: Int
            if sel.mode == .line {
                endCol = columns - 1
            } else {
                endCol = (line == e.line) ? e.col : columns - 1
            }

            if line < sbCount {
                for col in startCol...min(endCol, scrollbackColumns - 1) {
                    let cell = scrollbackCell(line: line, col: col)
                    guard cell.width.isRenderable else { continue }
                    if cell.content.scalarCount == 1, let scalar = cell.content.firstScalar {
                        result.unicodeScalars.append(scalar)
                    } else {
                        result.append(cell.content.string)
                    }
                }
            } else {
                let screenRow = line - sbCount
                if screenRow >= 0 && screenRow < rows {
                    let base = rowStart(screenRow)
                    for col in startCol...min(endCol, columns - 1) {
                        let cell = cells[base + col]
                        guard cell.width.isRenderable else { continue }
                        if cell.content.scalarCount == 1, let scalar = cell.content.firstScalar {
                            result.unicodeScalars.append(scalar)
                        } else {
                            result.append(cell.content.string)
                        }
                    }
                }
            }

            if line < e.line || sel.mode == .line {
                let wrapped = isLineWrapped(absoluteLine: line)
                // Single-pass trailing-space trim (always trim for hard breaks,
                // skip trim for soft-wrapped lines since trailing content is meaningful)
                if !wrapped {
                    while result.last == " " { result.removeLast() }
                    result.append("\n")
                }
            }
        }

        while result.last == "\n" { result.removeLast() }

        return result
    }

    // MARK: - Search

    /// Search all content (scrollback + active screen) for the given query.
    /// Returns matches ordered from top (oldest scrollback) to bottom (latest screen line).
    /// Case-insensitive substring search.
    public func search(query: String) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        let lowerQuery = query.lowercased()
        let queryScalars = Array(lowerQuery.unicodeScalars)
        guard !queryScalars.isEmpty else { return [] }

        var matches: [SearchMatch] = []
        let totalLines = scrollbackCount + rows

        for absLine in 0..<totalLines {
            let cols: Int
            if absLine < scrollbackCount {
                cols = scrollbackColumns
            } else {
                cols = columns
            }
            guard cols > 0 else { continue }

            // Extract and lowercase codepoints for this line.
            // ASCII fast path avoids heap allocations for the common case.
            var lineScalars = [Unicode.Scalar]()
            lineScalars.reserveCapacity(cols)
            for col in 0..<cols {
                let cp = codepoint(atAbsoluteLine: absLine, col: col)
                lineScalars.append(Self.lowercaseScalar(cp))
            }

            // Find all occurrences of the query in this line
            var searchFrom = 0
            while searchFrom <= cols - queryScalars.count {
                var found = true
                for qi in 0..<queryScalars.count {
                    if lineScalars[searchFrom + qi] != queryScalars[qi] {
                        found = false
                        break
                    }
                }
                if found {
                    matches.append(SearchMatch(
                        line: absLine,
                        startCol: searchFrom,
                        endCol: searchFrom + queryScalars.count - 1
                    ))
                    searchFrom += queryScalars.count
                } else {
                    searchFrom += 1
                }
            }
        }

        return matches
    }

    /// Lowercase a Unicode scalar. Uses direct arithmetic for ASCII (no allocation),
    /// falls back to Character.lowercased() for non-ASCII.
    @inline(__always)
    private static func lowercaseScalar(_ s: Unicode.Scalar) -> Unicode.Scalar {
        let v = s.value
        if v >= 0x41 && v <= 0x5A { // A-Z
            return Unicode.Scalar(v + 32)!
        }
        if v < 0x80 { return s } // other ASCII — already lowercase or non-letter
        return Character(s).lowercased().unicodeScalars.first ?? s
    }

    /// Clear the entire screen and reset cursor.
    public func clear() {
        cells = [Cell](repeating: .empty, count: columns * rows)
        lineFlags = [LineFlags](repeating: LineFlags(), count: rows)
        rowBase = 0
        cursorCol = 0
        cursorRow = 0
        dirtyRegion.markFull()
    }

    // MARK: - Private

    /// Move cursor down one row, scrolling if at the bottom of scroll region.
    private func advanceRow() {
        if cursorRow == scrollBottom {
            scrollRegionUp()
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    /// Scroll one line up within the scroll region.
    private func scrollRegionUp() {
        // Save the top line to scrollback when the scroll region starts at row 0
        // and we're on the main screen (not alt screen).
        if scrollTop == 0 && altCells == nil {
            appendScrollbackLine()
        }

        if scrollTop == 0 && scrollBottom == rows - 1 {
            // Full-screen scroll: O(columns) ring rotation.
            // Advance rowBase so old logical row 0 becomes new logical row (rows-1).
            rowBase = (rowBase + 1) % rows
            clearRows((rows - 1)..<rows)
        } else {
            // Partial scroll region: physical row-by-row copy with ring mapping
            for row in scrollTop..<scrollBottom {
                let src = rowStart(row + 1)
                let dst = rowStart(row)
                cells[dst..<(dst + columns)] = cells[src..<(src + columns)]
                setLineFlagForRow(row, lineFlagForRow(row + 1))
            }
            clearRows(scrollBottom..<(scrollBottom + 1))
        }
        dirtyRegion.markRange(scrollTop..<(scrollBottom + 1))
    }

    /// Scroll one line down within the scroll region.
    private func scrollRegionDown() {
        if scrollTop == 0 && scrollBottom == rows - 1 {
            // Full-screen reverse scroll: rotate rowBase backwards.
            rowBase = (rowBase + rows - 1) % rows
            clearRows(0..<1)
        } else {
            // Partial scroll region: physical row-by-row copy with ring mapping
            for row in stride(from: scrollBottom, through: scrollTop + 1, by: -1) {
                let src = rowStart(row - 1)
                let dst = rowStart(row)
                cells[dst..<(dst + columns)] = cells[src..<(src + columns)]
                setLineFlagForRow(row, lineFlagForRow(row - 1))
            }
            clearRows(scrollTop..<(scrollTop + 1))
        }
        dirtyRegion.markRange(scrollTop..<(scrollBottom + 1))
    }

    /// Move cursor row, marking both old and new rows dirty if changed.
    private func moveCursorRow(to newRow: Int) {
        let oldRow = cursorRow
        cursorRow = newRow
        if cursorRow != oldRow {
            dirtyRegion.markLine(oldRow)
            dirtyRegion.markLine(cursorRow)
        }
    }

    private func clampRow(_ row: Int) -> Int {
        max(0, min(row, rows - 1))
    }

    private func clampCol(_ col: Int) -> Int {
        max(0, min(col, columns - 1))
    }

    private static func resizedGrid(
        from source: [Cell],
        oldCols: Int, newCols: Int, newRows: Int,
        copyRows: Int, copyCols: Int
    ) -> [Cell] {
        var grid = [Cell](repeating: .empty, count: newCols * newRows)
        for row in 0..<copyRows {
            let srcStart = row * oldCols
            let dstStart = row * newCols
            grid[dstStart..<(dstStart + copyCols)] = source[srcStart..<(srcStart + copyCols)]
            if copyCols > 0 && copyCols < oldCols {
                let lastCopied = dstStart + copyCols - 1
                if grid[lastCopied].width == .wide {
                    grid[lastCopied] = .empty
                }
            }
        }
        return grid
    }
}
