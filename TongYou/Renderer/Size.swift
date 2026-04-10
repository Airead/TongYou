/// Render target physical pixel size (integer).
struct ScreenSize: Equatable {
    let width: UInt32
    let height: UInt32
}

/// Cell physical pixel size (integer).
struct CellSize: Equatable {
    let width: UInt32
    let height: UInt32
}

/// Grid dimensions in cells (integer).
struct GridSize: Equatable {
    let columns: UInt16
    let rows: UInt16

    /// Calculate grid dimensions from screen and cell sizes.
    nonisolated static func calculate(screen: ScreenSize, cell: CellSize) -> GridSize {
        let columns = max(1, UInt16(screen.width / cell.width))
        let rows = max(1, UInt16(screen.height / cell.height))
        return GridSize(columns: columns, rows: rows)
    }
}

/// Grid padding in physical pixels (integer).
struct Padding: Equatable {
    let top: UInt32
    let bottom: UInt32
    let left: UInt32
    let right: UInt32

    /// Calculate balanced (centered) padding so that grid + padding == screen.
    nonisolated static func balanced(screen: ScreenSize, grid: GridSize, cell: CellSize) -> Padding {
        let usedWidth = UInt32(grid.columns) * cell.width
        let usedHeight = UInt32(grid.rows) * cell.height
        // Guard against underflow when screen is smaller than one cell
        // (e.g. during initial view insertion before layout).
        guard screen.width >= usedWidth, screen.height >= usedHeight else {
            return Padding(top: 0, bottom: 0, left: 0, right: 0)
        }
        let remainW = screen.width - usedWidth
        let remainH = screen.height - usedHeight

        let left = remainW / 2
        let right = remainW - left
        let top = remainH / 2
        let bottom = remainH - top

        return Padding(top: top, bottom: bottom, left: left, right: right)
    }
}
