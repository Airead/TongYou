import CoreText
import Foundation
import TYTerminal

/// Cached shaping result aggregated for a single row of terminal cells.
struct CachedShapedRow {
    /// Shaped text runs: (run, glyphs).
    let textRuns: [(run: TextRun, glyphs: [ShapedGlyph])]
    /// Emoji entries: (column, cluster, cellWidth).
    let emojis: [(col: Int, cluster: GraphemeCluster, width: CellWidth)]
}

/// Run-level cache for CoreText shaping results.
///
/// A terminal row typically contains multiple text runs (different fonts, attributes,
/// or emoji boundaries). Caching at the run level — rather than the whole row — lets
/// a partially-changed row still hit cache for the unchanged runs (e.g. split-pane
/// scrolling where only one half of each line changes).
///
/// Key: (cells content, CTFont identity, CellAttributes). When the font configuration
/// changes, the cache must be cleared by the owner.
final class ShapedRunCache {
    private struct Entry {
        var glyphs: [ShapedGlyph]
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

    init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    /// Look up cached glyphs for the given text run.
    func get(cells: ArraySlice<Cell>, font: CTFont, attributes: CellAttributes) -> [ShapedGlyph]? {
        let (hash, digest) = Self.computeKeys(cells: cells, font: font, attributes: attributes)
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
        return slots[slot].glyphs
    }

    /// Store shaped glyphs for the given text run.
    func set(cells: ArraySlice<Cell>, font: CTFont, attributes: CellAttributes, value: [ShapedGlyph]) {
        let (hash, digest) = Self.computeKeys(cells: cells, font: font, attributes: attributes)
        if let existing = hashToSlot[hash] {
            if slots[existing].digest == digest {
                slots[existing].glyphs = value
                moveToTail(existing)
                return
            }
            // Hash collision with different key — evict the colliding entry.
            unlinkSlot(existing)
            freeSlots.append(existing)
        } else if hashToSlot.count >= capacity {
            evictHead()
        }
        let slot = allocSlot(Entry(glyphs: value, hash: hash, digest: digest))
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
    /// in a single pass over the run cells + font/attribute factors.
    ///
    /// Font identity uses the CTFont pointer. This is stable because CodepointResolver
    /// caches returned CTFont instances (LRU-keyed), so the same logical font always
    /// returns the same object reference during a session.
    private static func computeKeys(
        cells: ArraySlice<Cell>,
        font: CTFont,
        attributes: CellAttributes
    ) -> (hash: Int, digest: Int) {
        var hasher = Hasher()
        var digest = 0

        let fontID = Int(bitPattern: Unmanaged.passUnretained(font).toOpaque())
        let flags = Int(attributes.flags.rawValue)
        let fg = Int(attributes.fgColor.raw)
        let bg = Int(attributes.bgColor.raw)

        hasher.combine(fontID)
        hasher.combine(flags)
        hasher.combine(fg)
        hasher.combine(bg)

        digest = digest &* 31 &+ fontID
        digest = digest &* 31 &+ flags
        digest = digest &* 31 &+ fg
        digest = digest &* 31 &+ bg

        for cell in cells {
            let contentHash = cell.content.hashValue
            let width = Int(cell.width.rawValue)

            hasher.combine(contentHash)
            hasher.combine(width)

            digest ^= contentHash
            digest = digest &* 31 &+ width
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
