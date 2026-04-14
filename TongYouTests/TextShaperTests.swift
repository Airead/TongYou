import Testing
import Metal
import TYTerminal
@testable import TongYou

@Suite("CoreText Shaper tests")
struct CoreTextShaperTests {

    private func makeShaper() -> CoreTextShaper {
        let fontSystem = FontSystem(scaleFactor: 2.0)
        return CoreTextShaper(fontSystem: fontSystem)
    }

    @Test func shapesSimpleAscii() {
        let shaper = makeShaper()
        let cells = [
            Cell(content: "H", attributes: .default, width: .normal),
            Cell(content: "i", attributes: .default, width: .normal)
        ]
        let run = TextRun(
            cells: cells,
            startCol: 0,
            font: FontSystem(scaleFactor: 2.0).ctFont,
            attributes: .default
        )
        let glyphs = shaper.shape(run)
        #expect(glyphs.count == 2, "Each ASCII character should produce one glyph")
    }

    @Test func shapesLigature() {
        let shaper = makeShaper()
        // "fi" ligature: many fonts combine f+i into a single glyph.
        let cells = [
            Cell(content: "f", attributes: .default, width: .normal),
            Cell(content: "i", attributes: .default, width: .normal)
        ]
        let run = TextRun(
            cells: cells,
            startCol: 0,
            font: FontSystem(scaleFactor: 2.0).ctFont,
            attributes: .default
        )
        let glyphs = shaper.shape(run)
        // Menlo (the fallback font on macOS) does support "fi" ligature.
        // We accept either 1 (ligature) or 2 (no ligature) glyphs.
        #expect(glyphs.count <= 2)
        #expect(glyphs.count >= 1)
    }

    @Test func mapsStringIndexToCellIndex() {
        let shaper = makeShaper()
        let cells = [
            Cell(content: "A", attributes: .default, width: .normal),
            Cell(content: "B", attributes: .default, width: .normal)
        ]
        let run = TextRun(
            cells: cells,
            startCol: 3,
            font: FontSystem(scaleFactor: 2.0).ctFont,
            attributes: .default
        )
        let glyphs = shaper.shape(run)
        for glyph in glyphs {
            #expect(glyph.cellIndex >= 0)
            #expect(glyph.cellIndex < cells.count)
        }
    }

    @Test func emptyRunProducesNoGlyphs() {
        let shaper = CoreTextShaper(fontSystem: FontSystem(scaleFactor: 2.0))
        let run = TextRun(
            cells: [],
            startCol: 0,
            font: FontSystem(scaleFactor: 2.0).ctFont,
            attributes: .default
        )
        let glyphs = shaper.shape(run)
        #expect(glyphs.isEmpty)
    }

    @Test func multiScalarEmojiInRun() {
        let shaper = makeShaper()
        let cells = [
            Cell(content: GraphemeCluster(Character("👨‍👩‍👧‍👦")), attributes: .default, width: .wide),
            Cell(content: "A", attributes: .default, width: .normal)
        ]
        let run = TextRun(
            cells: cells,
            startCol: 0,
            font: FontSystem(scaleFactor: 2.0).ctFont,
            attributes: .default
        )
        let glyphs = shaper.shape(run)
        // Should produce glyphs for the emoji sequence + "A".
        #expect(glyphs.count >= 1)
    }
}

@Suite("TextRun building tests")
struct TextRunBuildingTests {

    @Test func buildRunsSplitsOnAttributeChange() {
        let renderer = makeRenderer()
        let cells = [
            Cell(content: "H", attributes: .default, width: .normal),
            Cell(content: "i", attributes: CellAttributes(flags: .bold), width: .normal)
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
        let runs = renderer.buildRuns(forRow: 0, snapshot: snapshot)
        #expect(runs.count == 2)
        #expect(runs[0].startCol == 0)
        #expect(runs[0].cells.count == 1)
        #expect(runs[1].startCol == 1)
        #expect(runs[1].cells.count == 1)
    }

    @Test func buildRunsSkipsSpaces() {
        let renderer = makeRenderer()
        let cells = [
            Cell(content: "A", attributes: .default, width: .normal),
            Cell(content: " ", attributes: .default, width: .normal),
            Cell(content: "B", attributes: .default, width: .normal)
        ]
        let snapshot = ScreenSnapshot(
            cells: cells,
            columns: 3, rows: 1,
            cursorCol: 0, cursorRow: 0,
            cursorVisible: true, cursorShape: .block,
            selection: nil,
            scrollbackCount: 0, viewportOffset: 0,
            dirtyRegion: .full
        )
        let runs = renderer.buildRuns(forRow: 0, snapshot: snapshot)
        #expect(runs.count == 2)
        #expect(runs[0].startCol == 0)
        #expect(runs[1].startCol == 2)
    }

    @Test func buildRunsSkipsContinuationCells() {
        let renderer = makeRenderer()
        let cells = [
            Cell(content: GraphemeCluster(Character("中")), attributes: .default, width: .wide),
            Cell(content: " ", attributes: .default, width: .continuation),
            Cell(content: "A", attributes: .default, width: .normal)
        ]
        let snapshot = ScreenSnapshot(
            cells: cells,
            columns: 3, rows: 1,
            cursorCol: 0, cursorRow: 0,
            cursorVisible: true, cursorShape: .block,
            selection: nil,
            scrollbackCount: 0, viewportOffset: 0,
            dirtyRegion: .full
        )
        let runs = renderer.buildRuns(forRow: 0, snapshot: snapshot)
        // Continuation cells break runs, so we have two runs: "中" and "A".
        #expect(runs.count == 2)
        #expect(runs[0].startCol == 0)
        #expect(runs[1].startCol == 2)
    }

    @Test func buildRunsMergesSameAttributes() {
        let renderer = makeRenderer()
        let cells = [
            Cell(content: "A", attributes: .default, width: .normal),
            Cell(content: "B", attributes: .default, width: .normal),
            Cell(content: "C", attributes: .default, width: .normal)
        ]
        let snapshot = ScreenSnapshot(
            cells: cells,
            columns: 3, rows: 1,
            cursorCol: 0, cursorRow: 0,
            cursorVisible: true, cursorShape: .block,
            selection: nil,
            scrollbackCount: 0, viewportOffset: 0,
            dirtyRegion: .full
        )
        let runs = renderer.buildRuns(forRow: 0, snapshot: snapshot)
        #expect(runs.count == 1)
        #expect(runs[0].cells.count == 3)
    }

    // MARK: - Helpers

    private func makeRenderer() -> MetalRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal device not available")
        }
        let fontSystem = FontSystem(scaleFactor: 2.0)
        return MetalRenderer(device: device, fontSystem: fontSystem)
    }
}
