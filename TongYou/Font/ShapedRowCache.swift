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
    private struct Entry {
        var row: CachedShapedRow
        var hash: Int
        var digest: Int
        var prev: Int?
        var next: Int?
    }

    /// Entries indexed by slot. Slots are reused via `freeSlots`.
    private var slots: [Entry] = []
    private var freeSlots: [Int] = []
    /// Maps hash → slot index for O(1) lookup.
    private var hashToSlot: [Int: Int] = [:]
    /// Doubly-linked list head (LRU) and tail (MRU).
    private var head: Int?
    private var tail: Int?
    private let capacity: Int

    private(set) var hits: UInt64 = 0
    private(set) var misses: UInt64 = 0

    init(capacity: Int = 300) {
        self.capacity = capacity
    }

    /// Look up a cached shaping result for the given row of cells.
    func get(cells: ArraySlice<Cell>) -> CachedShapedRow? {
        let (hash, digest) = Self.computeKeys(cells)
        guard let slot = hashToSlot[hash] else {
            misses += 1
            return nil
        }
        guard slots[slot].digest == digest else {
            misses += 1
            return nil
        }
        hits += 1
        moveToTail(slot)
        return slots[slot].row
    }

    /// Store a shaping result for the given row of cells.
    func set(cells: ArraySlice<Cell>, value: CachedShapedRow) {
        let (hash, digest) = Self.computeKeys(cells)
        if let existing = hashToSlot[hash] {
            if slots[existing].digest == digest {
                slots[existing].row = value
                moveToTail(existing)
                return
            }
            // Hash collision with different cells — evict the colliding entry.
            unlinkSlot(existing)
            freeSlots.append(existing)
        } else if hashToSlot.count >= capacity {
            evictHead()
        }
        let slot = allocSlot(Entry(row: value, hash: hash, digest: digest))
        hashToSlot[hash] = slot
        appendToTail(slot)
    }

    /// Remove all cached entries and reset counters.
    func clear() {
        slots.removeAll(keepingCapacity: true)
        freeSlots.removeAll(keepingCapacity: true)
        hashToSlot.removeAll(keepingCapacity: true)
        head = nil
        tail = nil
        hits = 0
        misses = 0
    }

    // MARK: - Private

    /// Compute primary hash (Dict key) and secondary digest (collision verifier)
    /// in a single pass over the row cells.
    private static func computeKeys(_ cells: ArraySlice<Cell>) -> (hash: Int, digest: Int) {
        var hasher = Hasher()
        var digest = 0
        for cell in cells {
            let contentHash = cell.content.hashValue
            let flags = cell.attributes.flags.rawValue
            let fg = cell.attributes.fgColor.raw
            let bg = cell.attributes.bgColor.raw
            let width = cell.width.rawValue

            hasher.combine(contentHash)
            hasher.combine(flags)
            hasher.combine(fg)
            hasher.combine(bg)
            hasher.combine(width)

            digest ^= contentHash
            digest = digest &* 31 &+ Int(flags)
            digest = digest &* 31 &+ Int(fg)
            digest = digest &* 31 &+ Int(bg)
            digest = digest &* 31 &+ Int(width)
        }
        return (hasher.finalize(), digest)
    }

    private func allocSlot(_ entry: Entry) -> Int {
        if let free = freeSlots.popLast() {
            slots[free] = entry
            return free
        }
        slots.append(entry)
        return slots.count - 1
    }

    private func unlinkSlot(_ slot: Int) {
        let prev = slots[slot].prev
        let next = slots[slot].next
        if let p = prev { slots[p].next = next } else { head = next }
        if let n = next { slots[n].prev = prev } else { tail = prev }
        slots[slot].prev = nil
        slots[slot].next = nil
    }

    private func appendToTail(_ slot: Int) {
        slots[slot].prev = tail
        slots[slot].next = nil
        if let t = tail { slots[t].next = slot }
        tail = slot
        if head == nil { head = slot }
    }

    private func moveToTail(_ slot: Int) {
        guard slot != tail else { return }
        unlinkSlot(slot)
        appendToTail(slot)
    }

    private func evictHead() {
        guard let h = head else { return }
        unlinkSlot(h)
        hashToSlot.removeValue(forKey: slots[h].hash)
        freeSlots.append(h)
    }
}
