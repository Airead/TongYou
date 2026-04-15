import Testing
import TYTerminal
@testable import TongYou

@Suite("ShapedRowCache tests")
struct ShapedRowCacheTests {

    private func makeCache(capacity: Int = 300) -> ShapedRowCache {
        ShapedRowCache(capacity: capacity)
    }

    private func makeCells(_ strings: [String]) -> [Cell] {
        strings.map { Cell(content: GraphemeCluster(Character($0)), attributes: .default, width: .normal) }
    }

    @Test func cacheMissReturnsNil() {
        let cache = makeCache()
        let cells = makeCells(["A", "B", "C"])
        #expect(cache.get(cells: cells[0..<2]) == nil)
    }

    @Test func cacheHitAfterSet() {
        let cache = makeCache()
        let cells = makeCells(["A", "B"])
        let row = CachedShapedRow(textRuns: [], emojis: [])
        cache.set(cells: cells[0..<2], value: row)
        #expect(cache.get(cells: cells[0..<2]) != nil)
    }

    @Test func cacheMissesForDifferentContent() {
        let cache = makeCache()
        let cellsA = makeCells(["A", "B"])
        let cellsB = makeCells(["X", "Y"])
        cache.set(cells: cellsA[0..<2], value: CachedShapedRow(textRuns: [], emojis: []))
        #expect(cache.get(cells: cellsB[0..<2]) == nil)
    }

    @Test func cacheMissesForDifferentAttributes() {
        let cache = makeCache()
        let cell1 = Cell(content: "A", attributes: .default, width: .normal)
        let cell2 = Cell(content: "A", attributes: CellAttributes(flags: .bold), width: .normal)
        cache.set(cells: [cell1][0..<1], value: CachedShapedRow(textRuns: [], emojis: []))
        #expect(cache.get(cells: [cell2][0..<1]) == nil)
    }

    @Test func cacheLRUEviction() {
        let cache = makeCache(capacity: 2)
        let rowA = makeCells(["A"])
        let rowB = makeCells(["B"])
        let rowC = makeCells(["C"])

        cache.set(cells: rowA[0..<1], value: CachedShapedRow(textRuns: [], emojis: []))
        cache.set(cells: rowB[0..<1], value: CachedShapedRow(textRuns: [], emojis: []))
        cache.set(cells: rowC[0..<1], value: CachedShapedRow(textRuns: [], emojis: []))

        // A should have been evicted (least recently used)
        #expect(cache.get(cells: rowA[0..<1]) == nil)
        // B and C should still be present
        #expect(cache.get(cells: rowB[0..<1]) != nil)
        #expect(cache.get(cells: rowC[0..<1]) != nil)
    }

    @Test func cacheAccessUpdatesLRUOrder() {
        let cache = makeCache(capacity: 2)
        let rowA = makeCells(["A"])
        let rowB = makeCells(["B"])
        let rowC = makeCells(["C"])

        cache.set(cells: rowA[0..<1], value: CachedShapedRow(textRuns: [], emojis: []))
        cache.set(cells: rowB[0..<1], value: CachedShapedRow(textRuns: [], emojis: []))

        // Access A so it becomes MRU
        _ = cache.get(cells: rowA[0..<1])

        // Insert C; B should be evicted now because A was accessed more recently
        cache.set(cells: rowC[0..<1], value: CachedShapedRow(textRuns: [], emojis: []))
        #expect(cache.get(cells: rowB[0..<1]) == nil)
        #expect(cache.get(cells: rowA[0..<1]) != nil)
        #expect(cache.get(cells: rowC[0..<1]) != nil)
    }

    @Test func cacheClearRemovesAllEntries() {
        let cache = makeCache()
        let cells = makeCells(["A", "B"])
        cache.set(cells: cells[0..<2], value: CachedShapedRow(textRuns: [], emojis: []))
        cache.clear()
        #expect(cache.get(cells: cells[0..<2]) == nil)
    }
}
