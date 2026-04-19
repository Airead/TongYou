import CoreGraphics
import CoreText
import Metal
import TYTerminal

/// Cached emoji glyph information stored per grapheme cluster.
struct EmojiGlyphInfo {
    /// Position in atlas texture (physical pixels).
    let atlasX: UInt32
    let atlasY: UInt32
    /// Rasterized glyph size in atlas (physical pixels).
    let width: UInt32
    let height: UInt32
    /// Bearing offsets from cell origin (physical pixels).
    let bearingX: Int16
    let bearingY: Int16
}

/// Cache entry wrapping EmojiGlyphInfo with LRU tracking.
struct EmojiGlyphEntry {
    var info: EmojiGlyphInfo
    var lastUsedFrame: UInt64
}

/// Color emoji texture atlas using shelf (row) packing.
///
/// Design:
/// - BGRA8Unorm texture for color emoji glyphs
/// - 1px border around the atlas to prevent sampling artifacts
/// - Shelf-packing: rows filled left-to-right, row height = tallest glyph in that row
/// - Doubles texture size when full, copies existing data
/// - Separate from GlyphAtlas because color emoji uses Apple Color Emoji font
final class ColorEmojiAtlas {

    private let device: MTLDevice
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private(set) var texture: MTLTexture
    private(set) var textureSize: UInt32

    private var cache: [GraphemeCluster: EmojiGlyphEntry] = [:]

    // Shelf packing state
    private var shelfX: UInt32 = 1       // current x in active shelf (1px border)
    private var shelfY: UInt32 = 1       // current shelf top y (1px border)
    private var shelfHeight: UInt32 = 0  // tallest glyph in current shelf

    /// Whether the atlas texture has been modified since last GPU sync.
    private(set) var isDirty = false

    /// Count of atlas mutations (texture.replace / grow / compact) since last
    /// `advanceFrame()`. See `GlyphAtlas.atlasWritesThisFrame` for rationale.
    private(set) var atlasWritesThisFrame: UInt32 = 0

    /// Number of active (non-evicted) entries.
    var activeEntryCount: Int { cache.count }

    /// See `GlyphAtlas.growTriggerRatio` / `evictTriggerRatio` for rationale.
    private static let growTriggerRatio: Double = 0.75
    private static let evictTriggerRatio: Double = 0.95

    private let maxTextureSize: UInt32

    /// Global frame counter for LRU tracking across all renderers sharing this atlas.
    private(set) var frameNumber: UInt64 = 0

    /// Guards against redundant eviction when multiple renderers share this atlas.
    private var lastEvictionFrame: UInt64 = 0

    /// Apple Color Emoji font at different sizes
    private var emojiFontCache: [CGFloat: CTFont] = [:]

    init(device: MTLDevice, initialSize: UInt32 = 512, maxTextureSize: UInt32 = 2048) {
        self.device = device
        self.maxTextureSize = maxTextureSize
        self.textureSize = initialSize
        self.texture = Self.createTexture(device: device, size: initialSize)
    }

    /// Clear the dirty flag after GPU has consumed the updated texture.
    func clearDirty() {
        isDirty = false
    }

    /// Reset the atlas, clearing all cached glyphs. Used when font changes.
    func reset() {
        cache.removeAll(keepingCapacity: true)
        shelfX = 1
        shelfY = 1
        shelfHeight = 0
        texture = Self.createTexture(device: device, size: textureSize)
        isDirty = true
    }

    // MARK: - Glyph Lookup / Rasterization

    /// Advance the internal frame counter. Call once per render frame.
    func advanceFrame() {
        frameNumber &+= 1
        atlasWritesThisFrame = 0
    }

    /// Get or rasterize an emoji glyph. Returns nil if the cluster is not an emoji.
    func getOrRasterize(
        cluster: GraphemeCluster,
        fontSystem: FontSystem
    ) -> EmojiGlyphInfo? {
        guard cluster.isEmojiContent else { return nil }

        if let entry = cache[cluster] {
            // Only update LRU timestamp when stale (avoids dictionary write on every hit)
            if frameNumber &- entry.lastUsedFrame > 60 {
                cache[cluster] = EmojiGlyphEntry(info: entry.info, lastUsedFrame: frameNumber)
            }
            return entry.info
        }

        guard let info = rasterizeEmoji(cluster: cluster, fontSystem: fontSystem) else {
            return nil
        }
        cache[cluster] = EmojiGlyphEntry(info: info, lastUsedFrame: frameNumber)
        return info
    }

    // MARK: - Private: Rasterization

    private func rasterizeEmoji(
        cluster: GraphemeCluster,
        fontSystem: FontSystem
    ) -> EmojiGlyphInfo? {
        let emojiFont = getEmojiFont(size: fontSystem.pointSize * fontSystem.scaleFactor)

        // Get glyphs for the cluster
        let string = cluster.string as CFString
        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []

        // Use CoreText to get glyphs for the entire cluster
        guard let attributedString = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0) else { return nil }
        CFAttributedStringReplaceString(attributedString, CFRangeMake(0, 0), string)
        CFAttributedStringSetAttribute(attributedString, CFRangeMake(0, CFStringGetLength(string)), kCTFontAttributeName, emojiFont)

        let line = CTLineCreateWithAttributedString(attributedString)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            var runGlyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var runPositions = [CGPoint](repeating: .zero, count: glyphCount)

            CTRunGetGlyphs(run, CFRangeMake(0, 0), &runGlyphs)
            CTRunGetPositions(run, CFRangeMake(0, 0), &runPositions)

            glyphs.append(contentsOf: runGlyphs)
            positions.append(contentsOf: runPositions)
        }

        guard !glyphs.isEmpty else { return nil }

        // Calculate bounding box using CTRunGetImageBounds which works better for sbix fonts
        // For Apple Color Emoji (sbix/bitmaps), CTFontGetBoundingRectsForGlyphs often returns zero
        var totalBounds = CGRect.zero

        // Create a temporary context for CTRunGetImageBounds
        let tempColorSpace = CGColorSpaceCreateDeviceRGB()
        let tempContext: CGContext? = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: tempColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        // Get image bounds from each run (this works correctly for sbix fonts)
        for run in runs {
            let runBounds = CTRunGetImageBounds(run, tempContext, CFRangeMake(0, 0))
            totalBounds = totalBounds.union(runBounds)
        }

        // Fallback if bounds are still zero (shouldn't happen with sbix, but just in case)
        if totalBounds.width < 0.5 && totalBounds.height < 0.5 {
            // Use typographic bounds
            totalBounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        }

        // Final fallback: estimate based on font metrics
        if totalBounds.width < 0.5 && totalBounds.height < 0.5 {
            let fontSize = fontSystem.pointSize * fontSystem.scaleFactor
            totalBounds = CGRect(
                x: 0, y: -fontSize * 0.2,
                width: fontSize * 1.5,
                height: fontSize * 1.2
            )
        }

        // Calculate canvas size with padding for anti-aliasing
        let canvasWidth = UInt32(ceil(totalBounds.width)) + 2
        let canvasHeight = UInt32(ceil(totalBounds.height)) + 2

        guard canvasWidth > 0, canvasHeight > 0 else { return nil }

        guard let region = reserveRegion(width: canvasWidth, height: canvasHeight) else {
            return nil
        }

        // Create BGRA bitmap context
        let bytesPerRow = Int(canvasWidth) * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * Int(canvasHeight))

        guard let context = CGContext(
            data: &pixelData,
            width: Int(canvasWidth),
            height: Int(canvasHeight),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: sRGBColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Clear to transparent
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(canvasWidth), height: CGFloat(canvasHeight)))

        // For Apple Color Emoji (sbix bitmap font), we must draw the entire CTLine
        // instead of using CTFontDrawGlyphs per-glyph, because sbix glyphs are bitmaps
        // that don't render through the standard vector glyph path.
        // CoreGraphics origin is bottom-left. We place the line so that its image bounds
        // are fully inside the canvas, leaving 1px padding.
        // CTLineDraw draws with baseline at (0,0); totalBounds is relative to that baseline.
        let lineOrigin = CGPoint(
            x: -totalBounds.origin.x + 1,
            y: -totalBounds.origin.y + 1
        )
        context.textMatrix = .identity
        context.saveGState()
        context.translateBy(x: lineOrigin.x, y: lineOrigin.y)
        CTLineDraw(line, context)
        context.restoreGState()

        // Upload to texture
        let mtlRegion = MTLRegion(
            origin: MTLOrigin(x: Int(region.x), y: Int(region.y), z: 0),
            size: MTLSize(width: Int(canvasWidth), height: Int(canvasHeight), depth: 1)
        )
        texture.replace(region: mtlRegion, mipmapLevel: 0,
                       withBytes: pixelData, bytesPerRow: bytesPerRow)
        isDirty = true
        atlasWritesThisFrame &+= 1
        GUILog.debug(
            "[ATLAS-EMOJI] cluster=\(cluster) region=(\(region.x),\(region.y) \(canvasWidth)x\(canvasHeight)) frame=\(frameNumber)",
            category: .renderer
        )

        // Calculate bearing from top
        let baselineF = CGFloat(fontSystem.baseline) + fontSystem.baselineFractionalOffset
        let bearingYFromTop = Int16(baselineF - totalBounds.origin.y - CGFloat(canvasHeight) + 1)

        let info = EmojiGlyphInfo(
            atlasX: region.x,
            atlasY: region.y,
            width: canvasWidth,
            height: canvasHeight,
            bearingX: Int16(totalBounds.origin.x - 1),
            bearingY: bearingYFromTop
        )
        return info
    }

    private func getEmojiFont(size: CGFloat) -> CTFont {
        if let cached = emojiFontCache[size] {
            return cached
        }
        let font = CTFontCreateWithName("Apple Color Emoji" as CFString, size, nil)
        emojiFontCache[size] = font
        return font
    }

    // MARK: - Shelf Packing

    private struct AtlasRegion {
        let x: UInt32
        let y: UInt32
    }

    /// Reserve a rectangular region in the atlas. Grows texture if needed.
    private func reserveRegion(width: UInt32, height: UInt32) -> AtlasRegion? {
        // Try to fit in current shelf
        let borderPadding: UInt32 = 1
        let maxCoord = textureSize - borderPadding

        if shelfX + width <= maxCoord && shelfY + height <= maxCoord {
            let region = AtlasRegion(x: shelfX, y: shelfY)
            shelfX += width + borderPadding
            shelfHeight = max(shelfHeight, height)
            return region
        }

        // Move to next shelf
        let newShelfY = shelfY + shelfHeight + borderPadding
        if borderPadding + width <= maxCoord && newShelfY + height <= maxCoord {
            shelfX = borderPadding
            shelfY = newShelfY
            shelfHeight = height
            let region = AtlasRegion(x: shelfX, y: shelfY)
            shelfX += width + borderPadding
            return region
        }

        // Atlas full — grow
        guard grow() else { return nil }
        return reserveRegion(width: width, height: height)
    }

    private func grow() -> Bool {
        let newSize = textureSize * 2
        guard newSize <= maxTextureSize else { return false }

        let newTexture = Self.createTexture(device: device, size: newSize)

        let oldSize = Int(textureSize)
        var pixelData = [UInt8](repeating: 0, count: oldSize * oldSize * 4)
        texture.getBytes(
            &pixelData,
            bytesPerRow: oldSize * 4,
            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                           size: MTLSize(width: oldSize, height: oldSize, depth: 1)),
            mipmapLevel: 0
        )
        newTexture.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                             size: MTLSize(width: oldSize, height: oldSize, depth: 1)),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: oldSize * 4
        )

        texture = newTexture
        textureSize = newSize
        isDirty = true
        atlasWritesThisFrame &+= 1
        GUILog.debug(
            "[ATLAS-EMOJI] grow oldSize=\(oldSize) newSize=\(newSize) frame=\(frameNumber)",
            category: .renderer
        )
        return true
    }

    // MARK: - LRU Eviction

    /// Check atlas utilization and evict stale entries if needed.
    /// Call once per frame after all glyphs have been looked up.
    ///
    /// - Returns: `true` if `compact()` ran. See `GlyphAtlas.evictIfNeeded`
    ///   for why callers must invalidate any instance buffers that cached
    ///   atlas coordinates.
    @discardableResult
    func evictIfNeeded(fontSystem: FontSystem) -> Bool {
        guard cache.count > 0, frameNumber > lastEvictionFrame else { return false }
        lastEvictionFrame = frameNumber
        // Utilization = used shelf area / total texture area. Looser
        // trigger at maxTextureSize — see GlyphAtlas for rationale.
        let usedArea = Double(shelfY + shelfHeight) * Double(textureSize)
        let totalArea = Double(textureSize) * Double(textureSize)
        let trigger = (textureSize < maxTextureSize)
            ? Self.growTriggerRatio
            : Self.evictTriggerRatio
        guard usedArea / totalArea > trigger else { return false }

        // Evict oldest 25% of cache entries
        let evictCount = max(1, cache.count / 4)
        let sorted = cache.sorted { $0.value.lastUsedFrame < $1.value.lastUsedFrame }
        for i in 0..<evictCount {
            cache.removeValue(forKey: sorted[i].key)
        }

        // Always compact after eviction to reclaim atlas space
        compact(fontSystem: fontSystem)
        return true
    }

    /// Rebuild the atlas from scratch with only active cache entries.
    private func compact(fontSystem: FontSystem) {
        let activeEntries = cache

        shelfX = 1
        shelfY = 1
        shelfHeight = 0

        let newSize = compactTextureSize(entryCount: activeEntries.count)
        texture = Self.createTexture(device: device, size: newSize)
        textureSize = newSize
        cache.removeAll(keepingCapacity: true)

        for (cluster, entry) in activeEntries {
            if let info = rasterizeEmoji(cluster: cluster, fontSystem: fontSystem) {
                cache[cluster] = EmojiGlyphEntry(info: info, lastUsedFrame: entry.lastUsedFrame)
            }
        }

        isDirty = true
        GUILog.debug(
            "[ATLAS-EMOJI] compact entries=\(activeEntries.count) newSize=\(newSize) frame=\(frameNumber)",
            category: .renderer
        )
    }

    /// Target texture size for `compact()`. Grows whenever possible —
    /// see the matching note on `GlyphAtlas.compactTextureSize`.
    private func compactTextureSize(entryCount: Int) -> UInt32 {
        if textureSize < maxTextureSize {
            return textureSize * 2
        }
        return textureSize
    }

    // MARK: - Texture Creation

    private static func createTexture(device: MTLDevice, size: UInt32) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size),
            height: Int(size),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create emoji atlas texture \(size)x\(size)")
        }
        return texture
    }
}
