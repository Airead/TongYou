import CoreText
import Testing
import TYTerminal
@testable import TongYou

@Suite("ShapedRunCache tests")
struct ShapedRunCacheTests {

    private func makeCache(capacity: Int = 2000) -> ShapedRunCache {
        ShapedRunCache(capacity: capacity)
    }

    private func makeFont(_ name: String = "Menlo") -> CTFont {
        CTFontCreateWithName(name as CFString, 26.0, nil)
    }

    private func makeCells(_ strings: [String]) -> [Cell] {
        strings.map { Cell(content: GraphemeCluster(Character($0)), attributes: .default, width: .normal) }
    }

    private func makeGlyph(_ index: CGGlyph) -> ShapedGlyph {
        ShapedGlyph(
            glyph: index,
            position: .zero,
            advance: .zero,
            cellIndex: 0,
            font: makeFont()
        )
    }

    @Test func cacheMissReturnsNil() {
        let cache = makeCache()
        let cells = makeCells(["A", "B"])
        let font = makeFont()
        #expect(cache.get(cells: cells[0..<2], font: font, attributes: .default) == nil)
    }

    @Test func cacheHitAfterSet() {
        let cache = makeCache()
        let cells = makeCells(["A", "B"])
        let font = makeFont()
        let glyphs = [makeGlyph(1), makeGlyph(2)]
        cache.set(cells: cells[0..<2], font: font, attributes: .default, value: glyphs)
        let got = cache.get(cells: cells[0..<2], font: font, attributes: .default)
        #expect(got?.count == 2)
    }

    @Test func cacheMissesForDifferentCells() {
        let cache = makeCache()
        let font = makeFont()
        let cellsA = makeCells(["A", "B"])
        let cellsB = makeCells(["X", "Y"])
        cache.set(cells: cellsA[0..<2], font: font, attributes: .default, value: [makeGlyph(1)])
        #expect(cache.get(cells: cellsB[0..<2], font: font, attributes: .default) == nil)
    }

    @Test func cacheMissesForDifferentFont() {
        let cache = makeCache()
        let fontA = makeFont("Menlo")
        let fontB = makeFont("Courier")
        let cells = makeCells(["A", "B"])
        cache.set(cells: cells[0..<2], font: fontA, attributes: .default, value: [makeGlyph(1)])
        #expect(cache.get(cells: cells[0..<2], font: fontB, attributes: .default) == nil)
    }

    @Test func cacheMissesForDifferentAttributes() {
        let cache = makeCache()
        let font = makeFont()
        let cells = makeCells(["A"])
        let bold = CellAttributes(flags: .bold)
        cache.set(cells: cells[0..<1], font: font, attributes: .default, value: [makeGlyph(1)])
        #expect(cache.get(cells: cells[0..<1], font: font, attributes: bold) == nil)
    }

    @Test func cacheLRUEviction() {
        let cache = makeCache(capacity: 2)
        let font = makeFont()
        let rowA = makeCells(["A"])
        let rowB = makeCells(["B"])
        let rowC = makeCells(["C"])

        cache.set(cells: rowA[0..<1], font: font, attributes: .default, value: [makeGlyph(1)])
        cache.set(cells: rowB[0..<1], font: font, attributes: .default, value: [makeGlyph(2)])
        cache.set(cells: rowC[0..<1], font: font, attributes: .default, value: [makeGlyph(3)])

        // A should have been evicted as LRU
        #expect(cache.get(cells: rowA[0..<1], font: font, attributes: .default) == nil)
        #expect(cache.get(cells: rowB[0..<1], font: font, attributes: .default) != nil)
        #expect(cache.get(cells: rowC[0..<1], font: font, attributes: .default) != nil)
    }

    @Test func cacheAccessUpdatesLRUOrder() {
        let cache = makeCache(capacity: 2)
        let font = makeFont()
        let rowA = makeCells(["A"])
        let rowB = makeCells(["B"])
        let rowC = makeCells(["C"])

        cache.set(cells: rowA[0..<1], font: font, attributes: .default, value: [makeGlyph(1)])
        cache.set(cells: rowB[0..<1], font: font, attributes: .default, value: [makeGlyph(2)])

        // Touch A → becomes MRU
        _ = cache.get(cells: rowA[0..<1], font: font, attributes: .default)

        // Insert C → B (now LRU) should be evicted
        cache.set(cells: rowC[0..<1], font: font, attributes: .default, value: [makeGlyph(3)])
        #expect(cache.get(cells: rowB[0..<1], font: font, attributes: .default) == nil)
        #expect(cache.get(cells: rowA[0..<1], font: font, attributes: .default) != nil)
        #expect(cache.get(cells: rowC[0..<1], font: font, attributes: .default) != nil)
    }

    @Test func cacheClearRemovesAllEntries() {
        let cache = makeCache()
        let font = makeFont()
        let cells = makeCells(["A", "B"])
        cache.set(cells: cells[0..<2], font: font, attributes: .default, value: [makeGlyph(1)])
        cache.clear()
        #expect(cache.get(cells: cells[0..<2], font: font, attributes: .default) == nil)
    }

    @Test func hitMissCountersTrackAccess() {
        let cache = makeCache()
        let font = makeFont()
        let cells = makeCells(["A"])
        #expect(cache.misses == 0)
        _ = cache.get(cells: cells[0..<1], font: font, attributes: .default)
        #expect(cache.misses == 1)
        cache.set(cells: cells[0..<1], font: font, attributes: .default, value: [makeGlyph(1)])
        _ = cache.get(cells: cells[0..<1], font: font, attributes: .default)
        #expect(cache.hits == 1)
    }
}
