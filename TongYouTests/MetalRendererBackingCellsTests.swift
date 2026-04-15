import Testing
import Metal
import TYTerminal
@testable import TongYou

@Suite("MetalRenderer backing cells tests")
struct MetalRendererBackingCellsTests {

    private func makeRenderer() -> MetalRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal device not available")
        }
        let fontSystem = FontSystem(scaleFactor: 2.0)
        return MetalRenderer(device: device, fontSystem: fontSystem)
    }

    @Test func setContentFullSnapshotReplacesBackingCells() {
        let renderer = makeRenderer()
        let cells = [
            Cell(content: "A", attributes: .default, width: .normal),
            Cell(content: "B", attributes: .default, width: .normal)
        ]
        let snapshot = ScreenSnapshot(
            cells: cells,
            columns: 2, rows: 1,
            cursorCol: 0, cursorRow: 0,
            cursorVisible: true, cursorShape: .block,
            selection: nil,
            scrollbackCount: 0, viewportOffset: 0,
            dirtyRegion: .full
        )
        renderer.setContent(snapshot)

        let runs = renderer.buildRuns(forRow: 0)
        #expect(runs.count == 1)
        #expect(runs[0].cells.count == 2)
    }

    @Test func setContentPartialSnapshotMergesDirtyRows() {
        let renderer = makeRenderer()

        // Initial full snapshot
        var cells = [Cell](repeating: Cell(content: " ", attributes: .default, width: .normal), count: 6)
        cells[0] = Cell(content: "A", attributes: .default, width: .normal)
        cells[3] = Cell(content: "B", attributes: .default, width: .normal)
        let fullSnapshot = ScreenSnapshot(
            cells: cells,
            columns: 3, rows: 2,
            cursorCol: 0, cursorRow: 0,
            cursorVisible: true, cursorShape: .block,
            selection: nil,
            scrollbackCount: 0, viewportOffset: 0,
            dirtyRegion: .full
        )
        renderer.setContent(fullSnapshot)

        // Partial update: only row 1 changes to ["X", "Y", "Z"]
        let dirtyRowCells = [
            Cell(content: "X", attributes: .default, width: .normal),
            Cell(content: "Y", attributes: .default, width: .normal),
            Cell(content: "Z", attributes: .default, width: .normal)
        ]
        let partialSnapshot = ScreenSnapshot(
            cells: [],
            columns: 3, rows: 2,
            cursorCol: 0, cursorRow: 1,
            cursorVisible: true, cursorShape: .block,
            selection: nil,
            scrollbackCount: 0, viewportOffset: 0,
            dirtyRegion: DirtyRegion(rowCount: 2, fullRebuild: false),
            isPartial: true,
            dirtyRows: [1],
            partialRows: [(row: 1, cells: dirtyRowCells)]
        )
        renderer.setContent(partialSnapshot)

        // Row 0 should remain unchanged
        let runs0 = renderer.buildRuns(forRow: 0)
        #expect(runs0.count == 1)
        #expect(runs0[0].cells[0].content.string == "A")

        // Row 1 should reflect partial update
        let runs1 = renderer.buildRuns(forRow: 1)
        #expect(runs1.count == 1)
        #expect(runs1[0].cells.count == 3)
        #expect(runs1[0].cells[0].content.string == "X")
        #expect(runs1[0].cells[1].content.string == "Y")
        #expect(runs1[0].cells[2].content.string == "Z")
    }

    @Test func setContentPartialSnapshotWithMultipleDirtyRows() {
        let renderer = makeRenderer()

        let fullCells = [Cell](repeating: .empty, count: 9)
        let fullSnapshot = ScreenSnapshot(
            cells: fullCells,
            columns: 3, rows: 3,
            cursorCol: 0, cursorRow: 0,
            cursorVisible: true, cursorShape: .block,
            selection: nil,
            scrollbackCount: 0, viewportOffset: 0,
            dirtyRegion: .full
        )
        renderer.setContent(fullSnapshot)

        let row0 = [
            Cell(content: "1", attributes: .default, width: .normal),
            Cell(content: "2", attributes: .default, width: .normal),
            Cell(content: "3", attributes: .default, width: .normal)
        ]
        let row2 = [
            Cell(content: "7", attributes: .default, width: .normal),
            Cell(content: "8", attributes: .default, width: .normal),
            Cell(content: "9", attributes: .default, width: .normal)
        ]
        let partialSnapshot = ScreenSnapshot(
            cells: [],
            columns: 3, rows: 3,
            cursorCol: 0, cursorRow: 0,
            cursorVisible: true, cursorShape: .block,
            selection: nil,
            scrollbackCount: 0, viewportOffset: 0,
            dirtyRegion: DirtyRegion(rowCount: 3, fullRebuild: false),
            isPartial: true,
            dirtyRows: [0, 2],
            partialRows: [
                (row: 0, cells: row0),
                (row: 2, cells: row2)
            ]
        )
        renderer.setContent(partialSnapshot)

        let runs0 = renderer.buildRuns(forRow: 0)
        #expect(runs0.count == 1)
        #expect(runs0[0].cells[0].content.string == "1")

        let runs1 = renderer.buildRuns(forRow: 1)
        #expect(runs1.isEmpty)

        let runs2 = renderer.buildRuns(forRow: 2)
        #expect(runs2.count == 1)
        #expect(runs2[0].cells[2].content.string == "9")
    }
}
