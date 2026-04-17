import CoreText
import TYTerminal

final class CodepointResolver {
    private let collection: FontCollection
    private let baseFont: CTFont
    private let emojiFont: CTFont?
    private let fontSystem: FontSystem
    private var cache: [CacheKey: CTFont] = [:]
    private var cacheAccessOrder: [CacheKey] = []

    private struct CacheKey: Hashable {
        let cluster: GraphemeCluster
        let style: FontCollection.Style
    }

    private static let maxCacheSize = 512

    init(collection: FontCollection, baseFont: CTFont, emojiFont: CTFont? = nil, fontSystem: FontSystem) {
        self.collection = collection
        self.baseFont = baseFont
        self.emojiFont = emojiFont
        self.fontSystem = fontSystem
    }

    func resolveFont(for cluster: GraphemeCluster, style: FontCollection.Style) -> CTFont {
        if cluster.resolvedPresentation == .emoji {
            return emojiFont ?? baseFont
        }

        let key = CacheKey(cluster: cluster, style: style)
        if let cached = cache[key] {
            touchCache(key)
            return cached
        }

        let font = resolveThroughFallbackChain(cluster: cluster, style: style)
        insertIntoCache(key, font: font)
        return font
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

    private func touchCache(_ key: CacheKey) {
        cacheAccessOrder.removeAll { $0 == key }
        cacheAccessOrder.append(key)
    }

    private func insertIntoCache(_ key: CacheKey, font: CTFont) {
        if cache.count >= Self.maxCacheSize, let oldest = cacheAccessOrder.first {
            cacheAccessOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cache[key] = font
        cacheAccessOrder.append(key)
    }
}
