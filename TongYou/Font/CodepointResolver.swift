import CoreText
import TYTerminal

final class CodepointResolver {
    private let collection: FontCollection
    private let baseFont: CTFont
    private let emojiFont: CTFont?
    private let fontSystem: FontSystem

    /// Primary font for each style, snapshotted at init so the ASCII fast path
    /// in `resolveFont` can return without a dict lookup or LRU touch.
    /// Missing styles fall back to `regularFont`.
    private let regularFont: CTFont
    private let boldFont: CTFont?
    private let italicFont: CTFont?
    private let boldItalicFont: CTFont?

    private struct CacheKey: Hashable {
        let cluster: GraphemeCluster
        let style: FontCollection.Style
    }

    /// LRU entry stored in a slot pool. `prev`/`next` form a doubly-linked list
    /// over slot indices, so touch/evict are O(1).
    private struct Entry {
        let key: CacheKey
        let font: CTFont
        var prev: Int?
        var next: Int?
    }

    private var slots: [Entry] = []
    private var freeSlots: [Int] = []
    private var keyToSlot: [CacheKey: Int] = [:]
    /// Head is the least-recently used; tail is the most-recently used.
    private var head: Int?
    private var tail: Int?

    private static let maxCacheSize = 512

    init(collection: FontCollection, baseFont: CTFont, emojiFont: CTFont? = nil, fontSystem: FontSystem) {
        self.collection = collection
        self.baseFont = baseFont
        self.emojiFont = emojiFont
        self.fontSystem = fontSystem
        self.regularFont = collection.fonts(for: .regular).first ?? baseFont
        self.boldFont = collection.fonts(for: .bold).first
        self.italicFont = collection.fonts(for: .italic).first
        self.boldItalicFont = collection.fonts(for: .boldItalic).first
    }

    func resolveFont(for cluster: GraphemeCluster, style: FontCollection.Style) -> CTFont {
        if cluster.isEmojiContent {
            return emojiFont ?? baseFont
        }

        // Fast path: a single printable-ASCII scalar is always covered by the
        // primary font of the requested style — no fallback chain, no LRU.
        // Skips the hash + dict + moveToTail overhead that dominates buildRuns.
        if cluster.scalarCount == 1,
           let scalar = cluster.firstScalar,
           scalar.value >= 0x20 && scalar.value < 0x7F {
            return styleFont(style)
        }

        let key = CacheKey(cluster: cluster, style: style)
        if let slot = keyToSlot[key] {
            moveToTail(slot)
            return slots[slot].font
        }

        let font = resolveThroughFallbackChain(cluster: cluster, style: style)
        insertIntoCache(key, font: font)
        return font
    }

    private func styleFont(_ style: FontCollection.Style) -> CTFont {
        switch style {
        case .regular: return regularFont
        case .bold: return boldFont ?? regularFont
        case .italic: return italicFont ?? regularFont
        case .boldItalic: return boldItalicFont ?? regularFont
        }
    }

    private func resolveThroughFallbackChain(cluster: GraphemeCluster, style: FontCollection.Style) -> CTFont {
        let regularStyle = FontCollection.Style.regular
        var checkedStyles: Set<FontCollection.Style> = []

        // Layer 1: Requested style fonts.
        for font in collection.fonts(for: style) {
            if fontSystem.canRender(cluster, in: font) { return font }
        }
        checkedStyles.insert(style)

        // Layer 2: Fallback to regular if requested style is not available.
        if style != regularStyle {
            for font in collection.fonts(for: regularStyle) {
                if fontSystem.canRender(cluster, in: font) { return font }
            }
            checkedStyles.insert(regularStyle)
        }

        // Layer 3-5: All loaded fonts (any style), skipping already-checked styles.
        for s in FontCollection.Style.allCases where !checkedStyles.contains(s) {
            for font in collection.fonts(for: s) {
                if fontSystem.canRender(cluster, in: font) { return font }
            }
        }

        // Layer 6-7: System font discovery and final fallback.
        let string = cluster.string as CFString
        let fallback = CTFontCreateForString(baseFont, string, CFRange(location: 0, length: CFStringGetLength(string)))

        let baseName = CTFontCopyPostScriptName(baseFont) as String
        let fallbackName = CTFontCopyPostScriptName(fallback) as String
        if fallbackName != baseName {
            return fallback
        }
        return fallback
    }

    private func insertIntoCache(_ key: CacheKey, font: CTFont) {
        if keyToSlot.count >= Self.maxCacheSize {
            evictHead()
        }
        let slot = allocSlot(Entry(key: key, font: font, prev: nil, next: nil))
        keyToSlot[key] = slot
        appendToTail(slot)
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
        keyToSlot.removeValue(forKey: slots[h].key)
        unlinkSlot(h)
        freeSlots.append(h)
    }

    #if DEBUG
    /// Internal accessor for tests to verify cache state.
    var _cacheCount: Int { keyToSlot.count }
    #endif
}
