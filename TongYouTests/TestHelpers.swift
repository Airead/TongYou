import Metal
@testable import TongYou

/// Shared test helpers for building snapshots and renderers.
enum TestHelpers {

    /// Build a ScreenSnapshot from lines of text, padding to `cols` width.
    static func makeSnapshot(
        lines: [String], cols: Int = 80,
        cursorRow: Int = 0, cursorCol: Int = 0,
        cursorVisible: Bool = false,
        selection: Selection? = nil
    ) -> ScreenSnapshot {
        let rows = lines.count
        var cells = [Cell](repeating: .empty, count: cols * rows)
        for (row, line) in lines.enumerated() {
            for (col, ch) in line.unicodeScalars.enumerated() where col < cols {
                cells[row * cols + col] = Cell(codepoint: ch, attributes: .default, width: .normal)
            }
        }
        return ScreenSnapshot(
            cells: cells, columns: cols, rows: rows,
            cursorCol: cursorCol, cursorRow: cursorRow,
            cursorVisible: cursorVisible, cursorShape: .block,
            selection: selection, scrollbackCount: 0, viewportOffset: 0,
            dirtyRegion: .full
        )
    }

    /// Copy a snapshot with a different dirtyRegion.
    static func withDirtyRegion(_ region: DirtyRegion, from snap: ScreenSnapshot) -> ScreenSnapshot {
        ScreenSnapshot(
            cells: snap.cells, columns: snap.columns, rows: snap.rows,
            cursorCol: snap.cursorCol, cursorRow: snap.cursorRow,
            cursorVisible: snap.cursorVisible, cursorShape: snap.cursorShape,
            selection: snap.selection, scrollbackCount: snap.scrollbackCount,
            viewportOffset: snap.viewportOffset, dirtyRegion: region
        )
    }

    /// Create a MetalRenderer with the system default device.
    /// Returns nil when Metal is not available (e.g. headless CI).
    static func makeRenderer() -> MetalRenderer? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let fontSystem = FontSystem(scaleFactor: 2.0)
        return MetalRenderer(device: device, fontSystem: fontSystem)
    }
}
