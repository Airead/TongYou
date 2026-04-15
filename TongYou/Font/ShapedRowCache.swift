import Foundation
import TYTerminal

/// Cached shaping result for a single row of terminal cells.
struct CachedShapedRow {
    /// Shaped text runs: (run, glyphs).
    let textRuns: [(run: TextRun, glyphs: [ShapedGlyph])]
    /// Emoji entries: (column, cluster, cellWidth).
    let emojis: [(col: Int, cluster: GraphemeCluster, width: CellWidth)]
}

/// Row-level cache for CoreText shaping results.
///
/// Key is derived from the cell contents and attributes of the entire row.
/// When the font configuration changes, the cache must be cleared by the owner.
final class ShapedRowCache {
    private struct Key: Hashable {
        let value: Int
        func hash(into hasher: inout Hasher) {
            hasher.combine(value)
        }
        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.value == rhs.value
        }
    }

    private var entries: [Key: CachedShapedRow] = [:]
    private var accessOrder: [Key] = []
    private let capacity: Int

    private(set) var hits: UInt64 = 0
    private(set) var misses: UInt64 = 0

    init(capacity: Int = 300) {
        self.capacity = capacity
    }

    /// Look up a cached shaping result for the given row of cells.
    func get(cells: ArraySlice<Cell>) -> CachedShapedRow? {
        let key = Self.makeKey(cells: cells)
        guard entries[key] != nil else {
            misses += 1
            return nil
        }
        hits += 1
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        return entries[key]
    }

    /// Store a shaping result for the given row of cells.
    func set(cells: ArraySlice<Cell>, value: CachedShapedRow) {
        let key = Self.makeKey(cells: cells)
        if entries[key] == nil, entries.count >= capacity {
            let oldest = accessOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        } else {
            accessOrder.removeAll { $0 == key }
        }
        accessOrder.append(key)
        entries[key] = value
    }

    /// Remove all cached entries and reset counters.
    func clear() {
        entries.removeAll(keepingCapacity: true)
        accessOrder.removeAll(keepingCapacity: true)
        hits = 0
        misses = 0
    }

    private static func makeKey(cells: ArraySlice<Cell>) -> Key {
        var hasher = Hasher()
        for cell in cells {
            hasher.combine(cell.content.string)
            hasher.combine(cell.attributes.flags.rawValue)
            hasher.combine(cell.attributes.fgColor.raw)
            hasher.combine(cell.attributes.bgColor.raw)
            hasher.combine(cell.width.rawValue)
        }
        return Key(value: hasher.finalize())
    }
}
