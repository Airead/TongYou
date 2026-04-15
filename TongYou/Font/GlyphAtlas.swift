import CoreGraphics
import CoreText
import Metal

/// Cached glyph information stored per character.
struct GlyphInfo {
    /// Position in atlas texture (physical pixels).
    let atlasX: UInt32
    let atlasY: UInt32
    /// Rasterized glyph size in atlas (physical pixels).
    let width: UInt32
    let height: UInt32
    /// Bearing offsets from cell origin (physical pixels).
    /// offset_x: left edge of cell to left edge of glyph bbox.
    /// offset_y: top of cell (baseline - ascent region) to top of glyph bbox.
    let bearingX: Int16
    let bearingY: Int16
}

/// Cache key for glyph-based lookup (supports font fallback).
struct GlyphCacheKey: Hashable, Equatable {
    let fontName: String
    let fontSize: CGFloat
    let glyph: CGGlyph
}

/// Cache entry wrapping GlyphInfo with LRU tracking.
struct GlyphEntry {
    var info: GlyphInfo
    var lastUsedFrame: UInt64
}

/// Grayscale glyph texture atlas using shelf (row) packing.
///
/// Design (informed by Ghostty):
/// - R8Unorm single-channel texture for text glyphs
/// - 1px border around the atlas to prevent sampling artifacts
/// - Shelf-packing: rows filled left-to-right, row height = tallest glyph in that row
/// - Doubles texture size when full, copies existing data
final class GlyphAtlas {

    private let device: MTLDevice
    private let grayscaleColorSpace = CGColorSpace(name: CGColorSpace.linearGray)!
    private(set) var texture: MTLTexture
    private(set) var textureSize: UInt32

    private var cache: [GlyphCacheKey: GlyphEntry] = [:]

    // Shelf packing state
    private var shelfX: UInt32 = 1       // current x in active shelf (1px border)
    private var shelfY: UInt32 = 1       // current shelf top y (1px border)
    private var shelfHeight: UInt32 = 0  // tallest glyph in current shelf

    /// Whether the atlas texture has been modified since last GPU sync.
    private(set) var isDirty = false

    /// Monotonically increased on reset/grow/compact to detect stale async work.
    private(set) var generation: UInt64 = 0

    /// Incremented whenever the atlas texture content changes.
    private(set) var modified: UInt64 = 0

    /// Tracks glyphs currently being rasterized asynchronously to avoid duplicate work.
    private var pendingRasterizationKeys: Set<GlyphCacheKey> = []

    /// Background queue for CoreGraphics glyph rasterization.
    private let rasterizationQueue = DispatchQueue(
        label: "io.github.airead.tongyou.glyph-rasterizer",
        qos: .userInitiated
    )

    /// Number of active (non-evicted) entries.
    var activeEntryCount: Int { cache.count }

    private static let evictionTriggerRatio: Double = 0.75

    private let maxTextureSize: UInt32

    init(device: MTLDevice, initialSize: UInt32 = 1024, maxTextureSize: UInt32 = 8192) {
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
        pendingRasterizationKeys.removeAll()
        shelfX = 1
        shelfY = 1
        shelfHeight = 0
        texture = Self.createTexture(device: device, size: textureSize)
        generation &+= 1
        modified &+= 1
        isDirty = true
    }

    // MARK: - Glyph Lookup

    /// Synchronous lookup only. Returns nil on cache miss without rasterizing.
    func get(glyph: CGGlyph, font: CTFont) -> GlyphInfo? {
        let key = cacheKey(for: glyph, font: font)
        return cache[key]?.info
    }

    /// Get or rasterize a glyph by character. Resolves the font via FontSystem fallback on cache miss.
    /// The `frameNumber` is used for LRU tracking.
    func getOrRasterize(
        character: Unicode.Scalar,
        fontSystem: FontSystem,
        frameNumber: UInt64 = 0
    ) -> GlyphInfo? {
        let font = fontSystem.fontForCharacter(character)
        guard let glyph = fontSystem.glyphForCharacter(character, in: font) else {
            return nil
        }
        return getOrRasterize(
            glyph: glyph, font: font, fontSystem: fontSystem, frameNumber: frameNumber
        )
    }

    /// Get or rasterize a glyph by (font, glyph) pair synchronously.
    /// The `frameNumber` is used for LRU tracking.
    func getOrRasterize(
        glyph: CGGlyph,
        font: CTFont,
        fontSystem: FontSystem,
        frameNumber: UInt64 = 0
    ) -> GlyphInfo? {
        let key = cacheKey(for: glyph, font: font)
        if let entry = cache[key] {
            // Only update LRU timestamp when stale (avoids dictionary write on every hit)
            if frameNumber &- entry.lastUsedFrame > 60 {
                cache[key] = GlyphEntry(info: entry.info, lastUsedFrame: frameNumber)
            }
            return entry.info
        }

        guard let info = rasterizeGlyph(glyph: glyph, font: font, fontSystem: fontSystem) else {
            return nil
        }
        cache[key] = GlyphEntry(info: info, lastUsedFrame: frameNumber)
        return info
    }

    /// Enqueue an asynchronous rasterization for a cache-missed glyph.
    /// The completion handler is called on the main thread after the glyph
    /// has been drawn and uploaded to the GPU texture.
    func enqueueRasterization(
        glyph: CGGlyph,
        font: CTFont,
        fontSystem: FontSystem,
        completion: @escaping () -> Void
    ) {
        let key = cacheKey(for: glyph, font: font)
        guard pendingRasterizationKeys.insert(key).inserted else {
            // Already pending: just call completion immediately since the previous
            // enqueue will dirty the atlas and trigger a redraw.
            completion()
            return
        }

        let currentGeneration = generation
        let baselineF = CGFloat(fontSystem.baseline) + fontSystem.baselineFractionalOffset
        let fontName = CTFontCopyPostScriptName(font) as String
        let fontSize = CTFontGetSize(font)
        let colorSpace = grayscaleColorSpace

        rasterizationQueue.async { [weak self] in
            // Recreate font on background thread using name/size.
            let bgFont = CTFontCreateWithName(fontName as CFString, fontSize, nil)

            var glyphCopy = glyph
            var boundingRect = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(bgFont, .horizontal, &glyphCopy, &boundingRect, 1)

            if boundingRect.width < 0.5 && boundingRect.height < 0.5 {
                DispatchQueue.main.async {
                    guard let self, self.generation == currentGeneration else {
                        completion()
                        return
                    }
                    let info = GlyphInfo(atlasX: 0, atlasY: 0, width: 0, height: 0,
                                         bearingX: 0, bearingY: 0)
                    self.cache[key] = GlyphEntry(info: info, lastUsedFrame: 0)
                    self.pendingRasterizationKeys.remove(key)
                    completion()
                }
                return
            }

            let bearingXf = boundingRect.origin.x
            let bearingYf = boundingRect.origin.y

            let pxX = floor(bearingXf)
            let pxY = floor(bearingYf)
            let fracX = bearingXf - pxX
            let fracY = bearingYf - pxY

            let canvasWidth = UInt32(ceil(boundingRect.width + fracX)) + 1
            let canvasHeight = UInt32(ceil(boundingRect.height + fracY)) + 1

            guard canvasWidth > 0, canvasHeight > 0 else {
                DispatchQueue.main.async {
                    self?.pendingRasterizationKeys.remove(key)
                    completion()
                }
                return
            }

            let bytesPerRow = Int(canvasWidth)
            var pixelData = [UInt8](repeating: 0, count: bytesPerRow * Int(canvasHeight))

            guard let context = CGContext(
                data: &pixelData,
                width: Int(canvasWidth),
                height: Int(canvasHeight),
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                DispatchQueue.main.async {
                    self?.pendingRasterizationKeys.remove(key)
                    completion()
                }
                return
            }

            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)

            context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))

            context.textMatrix = .identity
            let drawX = fracX - boundingRect.origin.x
            let drawY = fracY - boundingRect.origin.y
            var position = CGPoint(x: drawX, y: drawY)
            CTFontDrawGlyphs(bgFont, &glyphCopy, &position, 1, context)

            let bearingYFromTop = Int16(baselineF - pxY - CGFloat(canvasHeight))
            let info = GlyphInfo(
                atlasX: 0, atlasY: 0,
                width: canvasWidth,
                height: canvasHeight,
                bearingX: Int16(pxX),
                bearingY: bearingYFromTop
            )

            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else {
                    completion()
                    return
                }

                guard let region = self.reserveRegion(width: canvasWidth, height: canvasHeight) else {
                    self.pendingRasterizationKeys.remove(key)
                    completion()
                    return
                }

                let mtlRegion = MTLRegion(
                    origin: MTLOrigin(x: Int(region.x), y: Int(region.y), z: 0),
                    size: MTLSize(width: Int(canvasWidth), height: Int(canvasHeight), depth: 1)
                )
                self.texture.replace(region: mtlRegion, mipmapLevel: 0,
                                    withBytes: pixelData, bytesPerRow: bytesPerRow)

                let finalInfo = GlyphInfo(
                    atlasX: region.x,
                    atlasY: region.y,
                    width: info.width,
                    height: info.height,
                    bearingX: info.bearingX,
                    bearingY: info.bearingY
                )

                self.cache[key] = GlyphEntry(info: finalInfo, lastUsedFrame: 0)
                self.pendingRasterizationKeys.remove(key)
                self.modified &+= 1
                self.isDirty = true

                completion()
            }
        }
    }

    private func cacheKey(for glyph: CGGlyph, font: CTFont) -> GlyphCacheKey {
        let name = CTFontCopyPostScriptName(font) as String
        let size = CTFontGetSize(font)
        return GlyphCacheKey(fontName: name, fontSize: size, glyph: glyph)
    }

    // MARK: - Private: Rasterization

    private func rasterizeGlyph(
        glyph: CGGlyph,
        font: CTFont,
        fontSystem: FontSystem
    ) -> GlyphInfo? {
        var glyphCopy = glyph
        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphCopy, &boundingRect, 1)

        if boundingRect.width < 0.5 && boundingRect.height < 0.5 {
            return GlyphInfo(atlasX: 0, atlasY: 0, width: 0, height: 0,
                             bearingX: 0, bearingY: 0)
        }

        let bearingXf = boundingRect.origin.x
        let bearingYf = boundingRect.origin.y

        let pxX = floor(bearingXf)
        let pxY = floor(bearingYf)
        let fracX = bearingXf - pxX
        let fracY = bearingYf - pxY

        let canvasWidth = UInt32(ceil(boundingRect.width + fracX)) + 1  // +1 for rasterization padding
        let canvasHeight = UInt32(ceil(boundingRect.height + fracY)) + 1

        guard canvasWidth > 0, canvasHeight > 0 else { return nil }

        guard let region = reserveRegion(width: canvasWidth, height: canvasHeight) else {
            return nil
        }

        let bytesPerRow = Int(canvasWidth)
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * Int(canvasHeight))

        guard let context = CGContext(
            data: &pixelData,
            width: Int(canvasWidth),
            height: Int(canvasHeight),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: grayscaleColorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        // CRITICAL: Disable subpixel quantization — we manage positioning manually
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)

        context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))

        // CGContext origin is bottom-left: translate by fractional offset + negated bbox origin
        context.textMatrix = .identity
        let drawX = fracX - boundingRect.origin.x
        let drawY = fracY - boundingRect.origin.y
        var position = CGPoint(x: drawX, y: drawY)
        CTFontDrawGlyphs(font, &glyphCopy, &position, 1, context)

        let mtlRegion = MTLRegion(
            origin: MTLOrigin(x: Int(region.x), y: Int(region.y), z: 0),
            size: MTLSize(width: Int(canvasWidth), height: Int(canvasHeight), depth: 1)
        )
        texture.replace(region: mtlRegion, mipmapLevel: 0,
                        withBytes: pixelData, bytesPerRow: bytesPerRow)
        modified &+= 1
        isDirty = true

        // bearingY in top-down coords: baseline - pxY - canvasHeight
        let baselineF = CGFloat(fontSystem.baseline) + fontSystem.baselineFractionalOffset
        let bearingYFromTop = Int16(baselineF - pxY - CGFloat(canvasHeight))

        let info = GlyphInfo(
            atlasX: region.x,
            atlasY: region.y,
            width: canvasWidth,
            height: canvasHeight,
            bearingX: Int16(pxX),
            bearingY: bearingYFromTop
        )
        return info
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
        var pixelData = [UInt8](repeating: 0, count: oldSize * oldSize)
        texture.getBytes(
            &pixelData,
            bytesPerRow: oldSize,
            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                            size: MTLSize(width: oldSize, height: oldSize, depth: 1)),
            mipmapLevel: 0
        )
        newTexture.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: oldSize, height: oldSize, depth: 1)),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: oldSize
        )

        texture = newTexture
        textureSize = newSize
        generation &+= 1
        modified &+= 1
        isDirty = true
        return true
    }

    // MARK: - LRU Eviction

    /// Check atlas utilization and evict stale entries if needed.
    /// Call once per frame after all glyphs have been looked up.
    func evictIfNeeded(frameNumber: UInt64, fontSystem: FontSystem) {
        guard cache.count > 0 else { return }
        // Utilization = used shelf area / total texture area
        let usedArea = Double(shelfY + shelfHeight) * Double(textureSize)
        let totalArea = Double(textureSize) * Double(textureSize)
        guard usedArea / totalArea > Self.evictionTriggerRatio else { return }

        // Evict oldest 25% of cache entries
        let evictCount = max(1, cache.count / 4)
        let sorted = cache.sorted { $0.value.lastUsedFrame < $1.value.lastUsedFrame }
        for i in 0..<evictCount {
            cache.removeValue(forKey: sorted[i].key)
        }

        // Always compact after eviction to reclaim atlas space
        compact(fontSystem: fontSystem, frameNumber: frameNumber)
    }

    /// Rebuild the atlas from scratch with only active cache entries.
    private func compact(fontSystem: FontSystem, frameNumber: UInt64) {
        let activeEntries = cache

        shelfX = 1
        shelfY = 1
        shelfHeight = 0

        let newSize = compactTextureSize(entryCount: activeEntries.count)
        texture = Self.createTexture(device: device, size: newSize)
        textureSize = newSize
        cache.removeAll(keepingCapacity: true)
        pendingRasterizationKeys.removeAll()

        // Group entries by font name/size and use fontSystem to resolve the font.
        var entriesByFont: [(glyph: CGGlyph, name: String, size: CGFloat, entry: GlyphEntry)] = []
        for (key, entry) in activeEntries {
            entriesByFont.append((key.glyph, key.fontName, key.fontSize, entry))
        }

        for (glyph, name, size, entry) in entriesByFont {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            if let info = rasterizeGlyph(glyph: glyph, font: font, fontSystem: fontSystem) {
                let newKey = GlyphCacheKey(fontName: name, fontSize: size, glyph: glyph)
                cache[newKey] = GlyphEntry(info: info, lastUsedFrame: entry.lastUsedFrame)
            }
        }

        generation &+= 1
        modified &+= 1
        isDirty = true
    }

    /// Choose smallest power-of-two texture size that fits the given entry count.
    private func compactTextureSize(entryCount: Int) -> UInt32 {
        // Estimate needed area: entryCount * average glyph area * 1.5 headroom
        let avgGlyphArea: Double = 17.0 * 21.0
        let neededArea = Double(entryCount) * avgGlyphArea * 1.5
        var size: UInt32 = 1024
        while Double(size * size) < neededArea && size < maxTextureSize {
            size *= 2
        }
        return size
    }

    // MARK: - Texture Creation

    private static func createTexture(device: MTLDevice, size: UInt32) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Int(size),
            height: Int(size),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create atlas texture \(size)x\(size)")
        }
        return texture
    }
}
