import Metal
import QuartzCore
import simd
import TYTerminal

@inline(__always)
fileprivate func scaled<T: BinaryInteger>(_ value: T, by scale: Float) -> T {
    T(Float(value) * scale)
}

/// Core Metal rendering engine.
/// Manages device, command queue, pipeline states, triple-buffered frame rendering.
/// Multi-pass: Pass 1 = cell backgrounds, Pass 2 = text glyphs.
///
/// All methods are called on the main thread (MainActor): `resize()` from AppKit callbacks,
/// `render()` from CADisplayLink on the main run loop.
final class MetalRenderer {

    private static let swapChainCount = 3
    private var clearColor: MTLClearColor

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bgPipelineState: MTLRenderPipelineState
    private let underlinePipelineState: MTLRenderPipelineState
    private let textPipelineState: MTLRenderPipelineState
    private let emojiPipelineState: MTLRenderPipelineState

    private var fontSystem: FontSystem
    private(set) var glyphAtlas: GlyphAtlas
    private(set) var emojiAtlas: ColorEmojiAtlas
    private var colorPalette: ColorPalette

    // Triple buffering (semaphore paces CPU vs GPU, not thread synchronization)
    private let frameSemaphore = DispatchSemaphore(value: swapChainCount)
    private var frameStates: [FrameState] = []
    private var frameIndex = 0

    // Current grid state (all access is MainActor-serialized)
    private var screenSize = ScreenSize(width: 0, height: 0)
    private(set) var gridSize = GridSize(columns: 0, rows: 0)
    private(set) var padding = Padding(top: 0, bottom: 0, left: 0, right: 0)
    private var instanceCount: Int { Int(gridSize.columns) * Int(gridSize.rows) }
    // After a resize, each of the 3 in-flight frame states needs its buffers updated.
    // These counters start at swapChainCount and decrement once per frame until 0.
    private var instanceRebuildCounter = swapChainCount
    private var uniformsDirtyCounter = swapChainCount
    // Tracks whether text content (glyphs) changed to trigger atlas eviction.
    // Set by setContent/markDirty/resize; untouched by markCursorDirty.
    // Decrements each rendered frame; while >0, atlas eviction runs after instance build.
    private(set) var textContentDirtyCounter = swapChainCount
    private var frameNumber: UInt64 = 0

    /// Per-frame performance metrics (nil when `debug-metrics` config is disabled).
    private(set) var frameMetrics: FrameMetrics?

    private(set) var currentSnapshot: ScreenSnapshot?

    /// Backing store for the full grid, merged from partial snapshots.
    private var backingCells: [Cell] = []
    private var backingColumns: Int = 0
    private var backingRows: Int = 0

    /// CPU-side staging buffer for per-row text/emoji instances.
    private struct RowTextInstances {
        var text: [CellTextInstance] = []
        var emoji: [CellTextInstance] = []
    }

    private var shapedRowCache = ShapedRowCache()

    /// Accumulated dirty region across setContent() calls, consumed by render().
    private(set) var pendingDirtyRegion = DirtyRegion.full

    /// Per-frame-state dirty region tracking which rows each swap-chain buffer
    /// still needs to rebuild. Enables partial updates without forcing 3 full rebuilds.
    private var frameStateDirtyRegions: [DirtyRegion] = Array(repeating: .full, count: swapChainCount)

    /// Currently highlighted URL for underline rendering (set by MetalView on Cmd+hover).
    var highlightedURL: DetectedURL? {
        didSet {
            if highlightedURL != oldValue {
                pendingDirtyRegion.markFull()
                markAllFramesDirty()
            }
        }
    }

    /// Search highlights: all matches and the focused match index.
    /// Set by MetalView when search is active.
    var searchResult: SearchResult? {
        didSet {
            if searchResult != oldValue {
                pendingDirtyRegion.markFull()
                markAllFramesDirty()
            }
        }
    }

    /// A search match range on a single line, used for per-cell highlight lookups.
    struct SearchMatchRange {
        let startCol: Int
        let endCol: Int
        let isFocused: Bool
    }

    /// Per-line index of search matches. Key = absolute line number.
    typealias SearchLineMap = [Int: [SearchMatchRange]]

    /// Build the search line map from the current search result.
    /// Returns an empty map if no search is active.
    private func buildSearchLineMap() -> SearchLineMap {
        guard let sr = searchResult, !sr.isEmpty else { return [:] }
        var map: SearchLineMap = [:]
        let focusedIdx = sr.focusedIndex
        for (i, m) in sr.matches.enumerated() {
            map[m.line, default: []].append(
                SearchMatchRange(startCol: m.startCol, endCol: m.endCol, isFocused: i == focusedIdx)
            )
        }
        return map
    }

    /// Cursor blink state. Toggled externally by the view's blink timer.
    var cursorBlinkOn: Bool = true

    /// Force full instance rebuild.
    func markDirty() {
        pendingDirtyRegion.markFull()
        markAllFramesDirty()
    }

    /// Mark only the cursor row as dirty (used by cursor blink timer).
    /// Uses counter=1 instead of swapChainCount because at idle all frame states
    /// already have current content — only the next rendered frame needs updating.
    /// textContentDirtyCounter deliberately not set — blink is color-only.
    func markCursorDirty() {
        if let snapshot = currentSnapshot {
            pendingDirtyRegion.markLine(snapshot.cursorRow)
        } else {
            pendingDirtyRegion.markFull()
        }
        instanceRebuildCounter = max(instanceRebuildCounter, 1)
    }

    /// Mark all swap-chain frames as needing instance + text content rebuild.
    private func markAllFramesDirty() {
        instanceRebuildCounter = Self.swapChainCount
        textContentDirtyCounter = Self.swapChainCount
        for i in frameStateDirtyRegions.indices {
            frameStateDirtyRegions[i] = .full
        }
    }

    /// Whether the renderer has pending work (dirty buffers, uniforms, or region to update).
    var needsRender: Bool {
        instanceRebuildCounter > 0 || uniformsDirtyCounter > 0 || pendingDirtyRegion.isDirty
    }

    func clearPendingDirtyRegionForTesting() {
        pendingDirtyRegion = .clean
    }

    /// Record a deduplicated frame for metrics when content generation did not change.
    func recordDedupedFrame() {
        frameMetrics?.recordDedupedFrame()
    }

    private struct FrameState {
        let uniformBuffer: MTLBuffer
        var bgInstanceBuffer: MTLBuffer
        var bgInstanceCapacity: Int
        var underlineInstanceBuffer: MTLBuffer
        var underlineInstanceCapacity: Int
        var underlineInstanceCount: Int
        var textInstanceBuffer: MTLBuffer
        var textInstanceCapacity: Int
        var textInstanceCount: Int
        var emojiInstanceBuffer: MTLBuffer
        var emojiInstanceCapacity: Int
        var emojiInstanceCount: Int
        /// Per-frame staging for text/emoji instances. Enables partial updates
        /// without interfering with other swap-chain frames.
        var stagedRowInstances: [RowTextInstances] = []
        /// Offsets for each row within this frame's text/emoji buffers.
        /// Used by partial updates to patch in-place without a full compact.
        var textRowOffsets: [Int] = []
        var emojiRowOffsets: [Int] = []
    }

    init(device: MTLDevice, fontSystem: FontSystem, config: Config = .default) {
        self.device = device
        self.fontSystem = fontSystem
        self.glyphAtlas = GlyphAtlas(device: device)
        self.emojiAtlas = ColorEmojiAtlas(device: device)

        (self.clearColor, self.colorPalette) = Self.buildColors(from: config)
        self.frameMetrics = config.debugMetrics ? FrameMetrics() : nil

        guard let queue = device.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue")
        }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary() else {
            fatalError("Failed to load Metal shader library")
        }

        // --- Background pipeline ---
        guard let bgVertexFunc = library.makeFunction(name: "cell_bg_vertex"),
              let bgFragmentFunc = library.makeFunction(name: "cell_bg_fragment") else {
            fatalError("Failed to load bg shader functions")
        }

        let bgVertexDescriptor = MTLVertexDescriptor()
        bgVertexDescriptor.attributes[0].format = .ushort2
        bgVertexDescriptor.attributes[0].offset = 0
        bgVertexDescriptor.attributes[0].bufferIndex = 1
        bgVertexDescriptor.attributes[1].format = .uchar4
        bgVertexDescriptor.attributes[1].offset = 4
        bgVertexDescriptor.attributes[1].bufferIndex = 1
        bgVertexDescriptor.layouts[1].stride = MemoryLayout<CellBgInstance>.stride
        bgVertexDescriptor.layouts[1].stepFunction = .perInstance
        bgVertexDescriptor.layouts[1].stepRate = 1

        let bgPipelineDesc = MTLRenderPipelineDescriptor()
        bgPipelineDesc.vertexFunction = bgVertexFunc
        bgPipelineDesc.fragmentFunction = bgFragmentFunc
        bgPipelineDesc.vertexDescriptor = bgVertexDescriptor
        bgPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        Self.enablePremultipliedAlpha(bgPipelineDesc.colorAttachments[0]!)

        do {
            bgPipelineState = try device.makeRenderPipelineState(descriptor: bgPipelineDesc)
        } catch {
            fatalError("Failed to create bg pipeline state: \(error)")
        }

        // --- Underline pipeline (reuses bg vertex descriptor + fragment shader) ---
        guard let underlineVertexFunc = library.makeFunction(name: "underline_vertex") else {
            fatalError("Failed to load underline_vertex shader function")
        }

        let underlinePipelineDesc = MTLRenderPipelineDescriptor()
        underlinePipelineDesc.vertexFunction = underlineVertexFunc
        underlinePipelineDesc.fragmentFunction = bgFragmentFunc
        underlinePipelineDesc.vertexDescriptor = bgVertexDescriptor
        underlinePipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        Self.enablePremultipliedAlpha(underlinePipelineDesc.colorAttachments[0]!)

        do {
            underlinePipelineState = try device.makeRenderPipelineState(descriptor: underlinePipelineDesc)
        } catch {
            fatalError("Failed to create underline pipeline state: \(error)")
        }

        // --- Text pipeline ---
        guard let textVertexFunc = library.makeFunction(name: "cell_text_vertex"),
              let textFragmentFunc = library.makeFunction(name: "cell_text_fragment") else {
            fatalError("Failed to load text shader functions")
        }

        let textVertexDescriptor = MTLVertexDescriptor()
        textVertexDescriptor.attributes[2].format = .uint2
        textVertexDescriptor.attributes[2].offset = 0
        textVertexDescriptor.attributes[2].bufferIndex = 1
        textVertexDescriptor.attributes[3].format = .uint2
        textVertexDescriptor.attributes[3].offset = 8
        textVertexDescriptor.attributes[3].bufferIndex = 1
        textVertexDescriptor.attributes[4].format = .short2
        textVertexDescriptor.attributes[4].offset = 16
        textVertexDescriptor.attributes[4].bufferIndex = 1
        textVertexDescriptor.attributes[5].format = .ushort2
        textVertexDescriptor.attributes[5].offset = 20
        textVertexDescriptor.attributes[5].bufferIndex = 1
        textVertexDescriptor.attributes[6].format = .uchar4
        textVertexDescriptor.attributes[6].offset = 24
        textVertexDescriptor.attributes[6].bufferIndex = 1
        textVertexDescriptor.attributes[7].format = .short2
        textVertexDescriptor.attributes[7].offset = 28
        textVertexDescriptor.attributes[7].bufferIndex = 1
        textVertexDescriptor.layouts[1].stride = MemoryLayout<CellTextInstance>.stride
        textVertexDescriptor.layouts[1].stepFunction = .perInstance
        textVertexDescriptor.layouts[1].stepRate = 1

        let textPipelineDesc = MTLRenderPipelineDescriptor()
        textPipelineDesc.vertexFunction = textVertexFunc
        textPipelineDesc.fragmentFunction = textFragmentFunc
        textPipelineDesc.vertexDescriptor = textVertexDescriptor
        textPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        Self.enablePremultipliedAlpha(textPipelineDesc.colorAttachments[0]!)

        do {
            textPipelineState = try device.makeRenderPipelineState(descriptor: textPipelineDesc)
        } catch {
            fatalError("Failed to create text pipeline state: \(error)")
        }

        // --- Emoji pipeline (reuses text vertex descriptor) ---
        guard let emojiFragmentFunc = library.makeFunction(name: "cell_emoji_fragment") else {
            fatalError("Failed to load emoji fragment shader function")
        }

        let emojiPipelineDesc = MTLRenderPipelineDescriptor()
        emojiPipelineDesc.vertexFunction = textVertexFunc
        emojiPipelineDesc.fragmentFunction = emojiFragmentFunc
        emojiPipelineDesc.vertexDescriptor = textVertexDescriptor
        emojiPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        Self.enablePremultipliedAlpha(emojiPipelineDesc.colorAttachments[0]!)

        do {
            emojiPipelineState = try device.makeRenderPipelineState(descriptor: emojiPipelineDesc)
        } catch {
            fatalError("Failed to create emoji pipeline state: \(error)")
        }

        // --- Frame states ---
        let initialCapacity = 256 * 64
            let underlineInitialCapacity = 256
            for _ in 0..<Self.swapChainCount {
                guard let uniformBuf = device.makeBuffer(
                    length: MemoryLayout<Uniforms>.stride,
                    options: .storageModeShared
                ),
                let bgBuf = device.makeBuffer(
                    length: MemoryLayout<CellBgInstance>.stride * initialCapacity,
                    options: .storageModeShared
                ),
                let underlineBuf = device.makeBuffer(
                    length: MemoryLayout<CellBgInstance>.stride * underlineInitialCapacity,
                    options: .storageModeShared
                ),
                let textBuf = device.makeBuffer(
                    length: MemoryLayout<CellTextInstance>.stride * initialCapacity,
                    options: .storageModeShared
                ),
                let emojiBuf = device.makeBuffer(
                    length: MemoryLayout<CellTextInstance>.stride * initialCapacity,
                    options: .storageModeShared
                ) else {
                    fatalError("Failed to allocate frame state buffers")
                }
                frameStates.append(FrameState(
                    uniformBuffer: uniformBuf,
                    bgInstanceBuffer: bgBuf,
                    bgInstanceCapacity: initialCapacity,
                    underlineInstanceBuffer: underlineBuf,
                    underlineInstanceCapacity: underlineInitialCapacity,
                    underlineInstanceCount: 0,
                    textInstanceBuffer: textBuf,
                    textInstanceCapacity: initialCapacity,
                    textInstanceCount: 0,
                    emojiInstanceBuffer: emojiBuf,
                    emojiInstanceCapacity: initialCapacity,
                    emojiInstanceCount: 0
                ))
            }
    }

    private static func enablePremultipliedAlpha(_ attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    // MARK: - Config Update

    /// Apply a new configuration. Returns true if the font changed (caller must rebuild FontSystem).
    @discardableResult
    func applyConfig(_ config: Config, fontSystem newFontSystem: FontSystem? = nil) -> Bool {
        (clearColor, colorPalette) = Self.buildColors(from: config)
        frameMetrics = config.debugMetrics ? (frameMetrics ?? FrameMetrics()) : nil

        var fontChanged = false
        if let fs = newFontSystem {
            fontSystem = fs
            glyphAtlas.reset()
            emojiAtlas.reset()
            fontChanged = true
        }

        pendingDirtyRegion.markFull()
        markAllFramesDirty()
        return fontChanged
    }

    private static func buildColors(from config: Config) -> (MTLClearColor, ColorPalette) {
        let bg = config.background
        let clearColor = MTLClearColorMake(
            Double(bg.r) / 255.0, Double(bg.g) / 255.0, Double(bg.b) / 255.0, 1.0
        )
        var palette = ColorPalette(
            defaultFg: config.foreground.simd4,
            defaultBg: bg.simd4,
            cursorColor: config.cursorColor?.simd4,
            cursorText: config.cursorText?.simd4,
            selectionBg: config.selectionBackground?.simd4,
            selectionFg: config.selectionForeground?.simd4
        )
        palette.applyOverrides(config.palette)
        return (clearColor, palette)
    }

    // MARK: - Resize

    func resize(screen: ScreenSize) {
        guard screen != screenSize else { return }
        let oldGrid = gridSize
        screenSize = screen
        gridSize = GridSize.calculate(screen: screen, cell: fontSystem.cellSize)
        padding = Padding.balanced(screen: screen, grid: gridSize, cell: fontSystem.cellSize)
        shrinkBuffersIfNeeded()
        if oldGrid != gridSize {
            backingCells.removeAll()
            backingColumns = 0
            backingRows = 0
            for i in frameStates.indices {
                frameStates[i].stagedRowInstances.removeAll()
                frameStates[i].textRowOffsets.removeAll()
                frameStates[i].emojiRowOffsets.removeAll()
            }
        }
        pendingDirtyRegion.markFull()
        markAllFramesDirty()
        uniformsDirtyCounter = Self.swapChainCount
    }

    /// Update the terminal content to render.
    func setContent(_ snapshot: ScreenSnapshot) {
        let selectionChanged = currentSnapshot?.selection != snapshot.selection
        currentSnapshot = snapshot
        pendingDirtyRegion.merge(snapshot.dirtyRegion)
        if selectionChanged {
            pendingDirtyRegion.markFull()
        }

        if snapshot.isPartial {
            assert(snapshot.columns == backingColumns && snapshot.rows == backingRows,
                   "Partial snapshot size mismatch: expected \(backingColumns)x\(backingRows), got \(snapshot.columns)x\(snapshot.rows)")
            for (row, cells) in snapshot.partialRows {
                let dst = row * backingColumns
                backingCells.replaceSubrange(dst..<(dst + backingColumns), with: cells)
            }
            let copiedCount = snapshot.partialRows.map { $0.cells.count }.reduce(0, +)
            frameMetrics?.recordSnapshotCellCopyCount(copiedCount)
        } else {
            backingCells = snapshot.cells
            backingColumns = snapshot.columns
            backingRows = snapshot.rows
            for i in frameStates.indices {
                frameStates[i].stagedRowInstances.removeAll()
                frameStates[i].textRowOffsets.removeAll()
                frameStates[i].emojiRowOffsets.removeAll()
            }
            frameMetrics?.recordSnapshotCellCopyCount(snapshot.cells.count)
        }

        if pendingDirtyRegion.fullRebuild {
            markAllFramesDirty()
        } else {
            instanceRebuildCounter = 1
            textContentDirtyCounter = 1
            for i in frameStateDirtyRegions.indices {
                frameStateDirtyRegions[i].merge(snapshot.dirtyRegion)
            }
        }
    }

    // MARK: - Render

    func render(in layer: CAMetalLayer) {
        guard needsRender else {
            frameMetrics?.recordSkip()
            return
        }

        guard frameSemaphore.wait(timeout: .now()) == .success else {
            frameMetrics?.recordSkip()
            return
        }

        frameMetrics?.beginFrame()
        frameNumber &+= 1
        frameIndex = (frameIndex + 1) % Self.swapChainCount

        let currentInstanceCount = instanceCount
        guard currentInstanceCount > 0 else {
            frameSemaphore.signal()
            frameMetrics?.recordSkip()
            return
        }

        guard let drawable = layer.nextDrawable() else {
            frameSemaphore.signal()
            frameMetrics?.recordSkip()
            return
        }

        let rebuildInstances = instanceRebuildCounter > 0 || frameStateDirtyRegions[frameIndex].isDirty
        if instanceRebuildCounter > 0 { instanceRebuildCounter -= 1 }
        let updateUnis = uniformsDirtyCounter > 0
        if updateUnis { uniformsDirtyCounter -= 1 }
        let textContentDirty = textContentDirtyCounter > 0
        if rebuildInstances && textContentDirty { textContentDirtyCounter -= 1 }

        let currentScreen = screenSize
        let currentGrid = gridSize
        let currentPadding = padding

        let currentHighlightedURL = highlightedURL
        var dirtyRegion: DirtyRegion
        if rebuildInstances {
            dirtyRegion = pendingDirtyRegion
            dirtyRegion.merge(frameStateDirtyRegions[frameIndex])
            frameStateDirtyRegions[frameIndex] = .clean
            if instanceRebuildCounter == 0 {
                pendingDirtyRegion = .clean
            }
        } else {
            dirtyRegion = frameStateDirtyRegions[frameIndex]
            frameStateDirtyRegions[frameIndex] = .clean
        }

        withUnsafeMutablePointer(to: &frameStates[frameIndex]) { frame in
            if rebuildInstances {
                let rebuiltRows = dirtyRegion.fullRebuild ? Int(gridSize.rows) : dirtyRegion.dirtyRows.count
                frameMetrics?.recordRebuiltRowCount(rebuiltRows)
                frameMetrics?.beginInstanceBuild()
                let snapshot = currentSnapshot
                let searchMap = buildSearchLineMap()
                fillBgInstanceBuffer(frame: frame, grid: currentGrid, snapshot: snapshot,
                                     dirtyRegion: dirtyRegion, searchLineMap: searchMap)
                fillUnderlineInstanceBuffer(frame: frame, grid: currentGrid, snapshot: snapshot, url: currentHighlightedURL)
                fillTextInstanceBuffer(frame: frame, grid: currentGrid, snapshot: snapshot,
                                       dirtyRegion: dirtyRegion, searchLineMap: searchMap)
                if textContentDirty {
                    glyphAtlas.evictIfNeeded(frameNumber: frameNumber, fontSystem: fontSystem)
                    emojiAtlas.evictIfNeeded(frameNumber: frameNumber, fontSystem: fontSystem)
                }
                frameMetrics?.endInstanceBuild()
            }
            if updateUnis {
                updateUniforms(in: frame.pointee.uniformBuffer,
                               screen: currentScreen, grid: currentGrid, padding: currentPadding)
            }
        }

        let frame = frameStates[frameIndex]

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = clearColor

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            frameSemaphore.signal()
            return
        }

        let sem = frameSemaphore
        commandBuffer.addCompletedHandler { _ in
            sem.signal()
        }

        encoder.setRenderPipelineState(bgPipelineState)
        encoder.setVertexBuffer(frame.uniformBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(frame.bgInstanceBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4,
            instanceCount: currentInstanceCount
        )

        if frame.underlineInstanceCount > 0 {
            encoder.setRenderPipelineState(underlinePipelineState)
            encoder.setVertexBuffer(frame.uniformBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(frame.underlineInstanceBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: frame.underlineInstanceCount
            )
        }

        if frame.textInstanceCount > 0 {
            encoder.setRenderPipelineState(textPipelineState)
            encoder.setVertexBuffer(frame.uniformBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(frame.textInstanceBuffer, offset: 0, index: 1)
            encoder.setFragmentTexture(glyphAtlas.texture, index: 0)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: frame.textInstanceCount
            )
        }

        if frame.emojiInstanceCount > 0 {
            encoder.setRenderPipelineState(emojiPipelineState)
            encoder.setVertexBuffer(frame.uniformBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(frame.emojiInstanceBuffer, offset: 0, index: 1)
            encoder.setFragmentTexture(emojiAtlas.texture, index: 0)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: frame.emojiInstanceCount
            )
        }

        encoder.endEncoding()
        frameMetrics?.endFrame()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Private: Buffer Growth

    private func ensureBufferCapacity<T>(
        buffer: inout MTLBuffer, capacity: inout Int,
        requiredCount: Int, type: T.Type
    ) {
        guard requiredCount > capacity else { return }
        var newCapacity = max(capacity, 1)
        while newCapacity < requiredCount { newCapacity *= 2 }
        guard let newBuffer = device.makeBuffer(
            length: MemoryLayout<T>.stride * newCapacity,
            options: .storageModeShared
        ) else { return }
        buffer = newBuffer
        capacity = newCapacity
    }

    /// Shrink instance buffers when capacity exceeds 4x the needed amount after resize.
    private func shrinkBuffersIfNeeded() {
        let needed = instanceCount
        guard needed > 0 else { return }
        let threshold = needed * 4
        for i in frameStates.indices {
            var state = frameStates[i]
            if state.bgInstanceCapacity > threshold {
                let newCap = needed * 2
                if let buf = device.makeBuffer(
                    length: MemoryLayout<CellBgInstance>.stride * newCap,
                    options: .storageModeShared
                ) {
                    state.bgInstanceBuffer = buf
                    state.bgInstanceCapacity = newCap
                }
            }
            if state.textInstanceCapacity > threshold {
                let newCap = needed * 2
                if let buf = device.makeBuffer(
                    length: MemoryLayout<CellTextInstance>.stride * newCap,
                    options: .storageModeShared
                ) {
                    state.textInstanceBuffer = buf
                    state.textInstanceCapacity = newCap
                }
            }
            if state.emojiInstanceCapacity > threshold {
                let newCap = needed * 2
                if let buf = device.makeBuffer(
                    length: MemoryLayout<CellTextInstance>.stride * newCap,
                    options: .storageModeShared
                ) {
                    state.emojiInstanceBuffer = buf
                    state.emojiInstanceCapacity = newCap
                }
            }
            frameStates[i] = state
        }
    }

    // MARK: - Private: Background Instances

    private func fillBgInstanceBuffer(
        frame: UnsafeMutablePointer<FrameState>, grid: GridSize,
        snapshot: ScreenSnapshot?, dirtyRegion: DirtyRegion,
        searchLineMap: SearchLineMap
    ) {
        let cols = Int(grid.columns)
        let rows = Int(grid.rows)
        let count = cols * rows

        ensureBufferCapacity(
            buffer: &frame.pointee.bgInstanceBuffer,
            capacity: &frame.pointee.bgInstanceCapacity,
            requiredCount: count, type: CellBgInstance.self
        )

        let ptr = frame.pointee.bgInstanceBuffer.contents()
            .bindMemory(to: CellBgInstance.self, capacity: count)

        let snapRows = min(rows, backingRows)
        let snapCols = min(cols, backingColumns)
        let defaultBg = colorPalette.defaultBg
        let palette = colorPalette

        // Cursor state
        let cursorVisible = snapshot?.cursorVisible ?? false
        let cursorCol = snapshot?.cursorCol ?? -1
        let cursorRow = snapshot?.cursorRow ?? -1
        let cursorShape = snapshot?.cursorShape ?? .block
        let showCursor = cursorVisible && cursorBlinkOn

        // Precompute ordered selection bounds once (not per-cell)
        let selBounds: (start: SelectionPoint, end: SelectionPoint)?
        if let sel = snapshot?.selection {
            selBounds = sel.ordered
        } else {
            selBounds = nil
        }

        let selBgColor = palette.selectionBg ?? palette.defaultFg
        let cursorBgColor = palette.cursorColor ?? palette.defaultFg

        // Search highlight colors: yellow for matches, orange for focused match.
        let searchMatchBg = SIMD4<UInt8>(180, 150, 40, 255)
        let searchFocusBg = SIMD4<UInt8>(220, 120, 20, 255)

        for row in 0..<rows {
            if !dirtyRegion.fullRebuild && !dirtyRegion.isDirty(row: row) { continue }
            var idx = row * cols
            let absLine = snapshot?.absoluteLine(forViewportRow: row)
                ?? row

            let lineMatches = searchLineMap[absLine]

            if row < snapRows {
                let rowBase = row * backingColumns
                for col in 0..<snapCols {
                    let attrs = backingCells[rowBase + col].attributes
                    var (fg, bg) = palette.resolveDisplay(attrs)

                    if let b = selBounds, Selection.contains(ordered: b, line: absLine, col: col) {
                        if palette.selectionBg != nil {
                            bg = selBgColor
                        } else {
                            swap(&fg, &bg)
                        }
                    }

                    // Search highlight (overrides selection)
                    if let matches = lineMatches {
                        for m in matches where col >= m.startCol && col <= m.endCol {
                            bg = m.isFocused ? searchFocusBg : searchMatchBg
                            break
                        }
                    }

                    // Block cursor: use configured cursor color or invert
                    if showCursor && cursorShape == .block
                        && row == cursorRow && col == cursorCol {
                        bg = cursorBgColor
                    }

                    ptr[idx] = CellBgInstance(
                        gridPos: SIMD2<UInt16>(UInt16(col), UInt16(row)),
                        color: bg
                    )
                    idx += 1
                }
                for col in snapCols..<cols {
                    var bg = defaultBg
                    if let b = selBounds, Selection.contains(ordered: b, line: absLine, col: col) {
                        bg = selBgColor
                    }
                    ptr[idx] = CellBgInstance(
                        gridPos: SIMD2<UInt16>(UInt16(col), UInt16(row)),
                        color: bg
                    )
                    idx += 1
                }
            } else {
                for col in 0..<cols {
                    var bg = defaultBg
                    if let b = selBounds, Selection.contains(ordered: b, line: absLine, col: col) {
                        bg = selBgColor
                    }
                    if showCursor && cursorShape == .block
                        && row == cursorRow && col == cursorCol {
                        bg = cursorBgColor
                    }
                    ptr[idx] = CellBgInstance(
                        gridPos: SIMD2<UInt16>(UInt16(col), UInt16(row)),
                        color: bg
                    )
                    idx += 1
                }
            }
        }
    }

    // MARK: - Private: Underline Instances

    private func fillUnderlineInstanceBuffer(
        frame: UnsafeMutablePointer<FrameState>,
        grid: GridSize, snapshot: ScreenSnapshot?, url: DetectedURL?
    ) {
        guard let url else {
            frame.pointee.underlineInstanceCount = 0
            return
        }

        let maxCol = Int(grid.columns) - 1
        let clampedStart = min(url.startCol, maxCol)
        let clampedEnd = min(url.endCol, maxCol)
        let count = clampedEnd - clampedStart + 1
        guard count > 0 else {
            frame.pointee.underlineInstanceCount = 0
            return
        }
        ensureBufferCapacity(
            buffer: &frame.pointee.underlineInstanceBuffer,
            capacity: &frame.pointee.underlineInstanceCapacity,
            requiredCount: count, type: CellBgInstance.self
        )

        let ptr = frame.pointee.underlineInstanceBuffer.contents()
            .bindMemory(to: CellBgInstance.self, capacity: count)

        let fg: SIMD4<UInt8>
        if url.row < backingRows, clampedStart < backingColumns {
            let attrs = backingCells[url.row * backingColumns + clampedStart].attributes
            fg = colorPalette.resolveDisplay(attrs).fg
        } else {
            fg = colorPalette.defaultFg
        }

        let row = UInt16(clamping: url.row)
        for i in 0..<count {
            let col = UInt16(clamping: clampedStart + i)
            ptr[i] = CellBgInstance(
                gridPos: SIMD2<UInt16>(col, row),
                color: fg
            )
        }
        frame.pointee.underlineInstanceCount = count
    }

    // MARK: - Private: Text Color Resolution

    /// Precomputed state for resolving per-cell text foreground color.
    /// Built once per fill/patch call, avoiding repeated Optional unwraps in the inner loop.
    private struct TextColorState {
        let palette: ColorPalette
        let selBounds: (start: SelectionPoint, end: SelectionPoint)?
        let showCursor: Bool
        let cursorShape: CursorShape
        let cursorRow: Int
        let cursorCol: Int
        /// Per-line search match ranges for visible lines.
        let searchLineMap: SearchLineMap

        /// Dark text color for cells with search highlight background.
        private static let searchTextColor = SIMD4<UInt8>(20, 20, 20, 255)

        func foreground(attrs: CellAttributes, row: Int, col: Int, absLine: Int) -> SIMD4<UInt8> {
            var (fg, bg) = palette.resolveDisplay(attrs)
            if let b = selBounds, Selection.contains(ordered: b, line: absLine, col: col) {
                if let selFg = palette.selectionFg {
                    fg = selFg
                } else {
                    swap(&fg, &bg)
                }
            }
            // Search highlight: use dark text for readability on yellow/orange bg.
            if let matches = searchLineMap[absLine] {
                for m in matches where col >= m.startCol && col <= m.endCol {
                    fg = Self.searchTextColor
                    break
                }
            }
            if showCursor && cursorShape == .block
                && row == cursorRow && col == cursorCol {
                fg = palette.cursorText ?? bg
            }
            return fg
        }
    }

    private func makeTextColorState(snapshot: ScreenSnapshot, searchLineMap: SearchLineMap) -> TextColorState {
        return TextColorState(
            palette: colorPalette,
            selBounds: snapshot.selection?.ordered,
            showCursor: snapshot.cursorVisible && cursorBlinkOn,
            cursorShape: snapshot.cursorShape,
            cursorRow: snapshot.cursorRow,
            cursorCol: snapshot.cursorCol,
            searchLineMap: searchLineMap
        )
    }

    // MARK: - Private: Text Instances

    /// Build text runs for a single row. Runs are sequences of consecutive
    /// renderable, non-space cells with identical attributes.
    func buildRuns(forRow row: Int) -> [TextRun] {
        var runs: [TextRun] = []
        let rowBase = row * backingColumns
        let cols = backingColumns

        var currentStart: Int? = nil
        var currentCells: [Cell] = []
        var currentAttrs: CellAttributes? = nil
        var currentFont: CTFont? = nil

        func flushCurrentRun() {
            if let start = currentStart, let attrs = currentAttrs, let font = currentFont {
                runs.append(TextRun(
                    cells: currentCells,
                    startCol: start,
                    font: font,
                    attributes: attrs
                ))
            }
            currentStart = nil
            currentCells = []
            currentAttrs = nil
            currentFont = nil
        }

        for col in 0..<cols {
            let cell = backingCells[rowBase + col]
            guard cell.width.isRenderable else {
                flushCurrentRun()
                continue
            }
            guard cell.content.firstScalar != Unicode.Scalar(" ") else {
                flushCurrentRun()
                continue
            }

            let cellFont = fontSystem.font(for: cell.content, attributes: cell.attributes)

            if let attrs = currentAttrs, let font = currentFont {
                if cell.attributes == attrs && CTFontCopyFontDescriptor(font) === CTFontCopyFontDescriptor(cellFont) {
                    currentCells.append(cell)
                } else {
                    flushCurrentRun()
                    currentStart = col
                    currentCells = [cell]
                    currentAttrs = cell.attributes
                    currentFont = cellFont
                }
            } else {
                currentStart = col
                currentCells = [cell]
                currentAttrs = cell.attributes
                currentFont = cellFont
            }
        }

        flushCurrentRun()
        return runs
    }

    /// Build shaped runs for a single row, utilizing the row-level cache.
    private func shapeRow(row: Int, shaper: CoreTextShaper) -> CachedShapedRow {
        let rowBase = row * backingColumns
        let snapCols = backingColumns
        let rowSlice = backingCells[rowBase..<(rowBase + snapCols)]

        if let cached = shapedRowCache.get(cells: rowSlice) {
            return cached
        }

        let runs = buildRuns(forRow: row)
        var cachedTextRuns: [(run: TextRun, glyphs: [ShapedGlyph])] = []
        var cachedEmojis: [(col: Int, cluster: GraphemeCluster, width: CellWidth)] = []

        for run in runs {
            var textSegmentStart: Int? = nil

            for (offset, cell) in run.cells.enumerated() {
                let col = run.startCol + offset
                let isEmoji = cell.content.isEmojiContent

                if isEmoji {
                    if let start = textSegmentStart {
                        let end = offset
                        let textRun = TextRun(
                            cells: Array(run.cells[start..<end]),
                            startCol: run.startCol + start,
                            font: run.font,
                            attributes: run.attributes
                        )
                        cachedTextRuns.append((textRun, shaper.shape(textRun)))
                        textSegmentStart = nil
                    }
                    cachedEmojis.append((col, cell.content, cell.width))
                } else {
                    if textSegmentStart == nil {
                        textSegmentStart = offset
                    }
                }
            }

            if let start = textSegmentStart {
                let textRun = TextRun(
                    cells: Array(run.cells[start..<run.cells.count]),
                    startCol: run.startCol + start,
                    font: run.font,
                    attributes: run.attributes
                )
                cachedTextRuns.append((textRun, shaper.shape(textRun)))
            }
        }

        let cached = CachedShapedRow(textRuns: cachedTextRuns, emojis: cachedEmojis)
        shapedRowCache.set(cells: rowSlice, value: cached)
        return cached
    }

    /// Rebuild text/emoji instances for a single row.
    private func rebuildTextRow(
        row: Int,
        cols: Int,
        snapshot: ScreenSnapshot,
        colorState: TextColorState,
        shaper: CoreTextShaper,
        cellWidth: Float
    ) -> RowTextInstances {
        var rowInstances = RowTextInstances()
        let absLine = snapshot.absoluteLine(forViewportRow: row)
        let rowBase = row * backingColumns
        let snapCols = min(cols, backingColumns)

        let cached = shapeRow(row: row, shaper: shaper)

        for (run, glyphs) in cached.textRuns {
            for glyph in glyphs {
                guard let glyphInfo = glyphAtlas.getOrRasterize(
                    glyph: glyph.glyph,
                    font: glyph.font,
                    fontSystem: fontSystem,
                    frameNumber: frameNumber
                ), glyphInfo.width > 0 && glyphInfo.height > 0 else { continue }

                let glyphCol = run.startCol + glyph.cellIndex
                rowInstances.text.append(CellTextInstance(
                    glyphPos: SIMD2<UInt32>(glyphInfo.atlasX, glyphInfo.atlasY),
                    glyphSize: SIMD2<UInt32>(glyphInfo.width, glyphInfo.height),
                    bearings: SIMD2<Int16>(glyphInfo.bearingX, glyphInfo.bearingY),
                    gridPos: SIMD2<UInt16>(UInt16(glyphCol), UInt16(row)),
                    color: colorState.foreground(
                        attrs: run.cells[glyph.cellIndex].attributes,
                        row: row, col: glyphCol, absLine: absLine
                    ),
                    offset: SIMD2<Int16>(Int16(glyph.position.x - CGFloat(glyph.cellIndex) * CGFloat(cellWidth)), 0)
                ))
            }
        }

        for (col, cluster, width) in cached.emojis {
            guard col < snapCols else { continue }
            if let emojiInfo = emojiAtlas.getOrRasterize(
                cluster: cluster, fontSystem: fontSystem,
                frameNumber: frameNumber
            ), emojiInfo.width > 0 && emojiInfo.height > 0 {
                var glyphSize = SIMD2<UInt32>(emojiInfo.width, emojiInfo.height)
                var bearings = SIMD2<Int16>(emojiInfo.bearingX, emojiInfo.bearingY)

                var targetCells: Int = 1
                if width == .wide {
                    targetCells = 2
                } else if col + 1 < snapCols {
                    let nextCell = backingCells[rowBase + col + 1]
                    if nextCell.content.firstScalar == Unicode.Scalar(" ") || !nextCell.width.isRenderable {
                        targetCells = 2
                    }
                }

                if targetCells > 1 {
                    let targetWidth = cellWidth * Float(targetCells)
                    let scale = targetWidth / Float(emojiInfo.width)
                    glyphSize.x = UInt32(targetWidth)
                    glyphSize.y = scaled(emojiInfo.height, by: scale)
                    bearings.x = scaled(bearings.x, by: scale)
                    bearings.y = scaled(bearings.y, by: scale)
                }

                rowInstances.emoji.append(CellTextInstance(
                    glyphPos: SIMD2<UInt32>(emojiInfo.atlasX, emojiInfo.atlasY),
                    glyphSize: glyphSize,
                    bearings: bearings,
                    gridPos: SIMD2<UInt16>(UInt16(col), UInt16(row)),
                    color: .zero
                ))
            }
        }

        return rowInstances
    }



    private func fillTextInstanceBuffer(
        frame: UnsafeMutablePointer<FrameState>, grid: GridSize,
        snapshot: ScreenSnapshot?, dirtyRegion: DirtyRegion,
        searchLineMap: SearchLineMap
    ) {
        let cols = Int(grid.columns)
        let rows = Int(grid.rows)

        guard let snapshot else {
            frame.pointee.textInstanceCount = 0
            frame.pointee.emojiInstanceCount = 0
            frame.pointee.stagedRowInstances.removeAll()
            frame.pointee.textRowOffsets.removeAll()
            frame.pointee.emojiRowOffsets.removeAll()
            return
        }

        // Fast path: no dirty rows need text rebuilding — patch colors in-place.
        if !dirtyRegion.fullRebuild && !dirtyRegion.isDirty &&
           frame.pointee.textInstanceCount > 0 {
            patchTextInstanceColors(
                frame: frame, snapshot: snapshot, dirtyRegion: dirtyRegion,
                searchLineMap: searchLineMap)
            return
        }

        let fullRebuild = dirtyRegion.fullRebuild
            || frame.pointee.stagedRowInstances.count != rows
            || frame.pointee.stagedRowInstances.isEmpty

        let colorState = makeTextColorState(snapshot: snapshot, searchLineMap: searchLineMap)
        let cellWidth = Float(fontSystem.cellSize.width)
        let shaper = CoreTextShaper(fontSystem: fontSystem)

        if fullRebuild {
            frame.pointee.stagedRowInstances = (0..<rows).map { _ in RowTextInstances() }
            for row in 0..<min(rows, backingRows) {
                frame.pointee.stagedRowInstances[row] = rebuildTextRow(
                    row: row, cols: cols, snapshot: snapshot,
                    colorState: colorState, shaper: shaper, cellWidth: cellWidth
                )
            }
        } else {
            // Partial: only rebuild dirty rows
            var countsChanged = false
            for row in dirtyRegion.dirtyRows {
                guard row >= 0 && row < rows && row < backingRows else { continue }
                let oldTextCount = frame.pointee.stagedRowInstances[row].text.count
                let oldEmojiCount = frame.pointee.stagedRowInstances[row].emoji.count
                frame.pointee.stagedRowInstances[row] = rebuildTextRow(
                    row: row, cols: cols, snapshot: snapshot,
                    colorState: colorState, shaper: shaper, cellWidth: cellWidth
                )
                if frame.pointee.stagedRowInstances[row].text.count != oldTextCount ||
                    frame.pointee.stagedRowInstances[row].emoji.count != oldEmojiCount {
                    countsChanged = true
                }
            }

            // Fast path: instance counts unchanged and this frame has a valid offset map.
            if !countsChanged,
               frame.pointee.textRowOffsets.count == rows,
               frame.pointee.emojiRowOffsets.count == rows,
               frame.pointee.textInstanceCapacity > 0,
               frame.pointee.emojiInstanceCapacity > 0 {
                let textPtr = frame.pointee.textInstanceBuffer.contents()
                    .bindMemory(to: CellTextInstance.self, capacity: frame.pointee.textInstanceCapacity)
                let emojiPtr = frame.pointee.emojiInstanceBuffer.contents()
                    .bindMemory(to: CellTextInstance.self, capacity: frame.pointee.emojiInstanceCapacity)
                for row in dirtyRegion.dirtyRows {
                    guard row >= 0 && row < rows else { continue }
                    let tOff = frame.pointee.textRowOffsets[row]
                    for (i, inst) in frame.pointee.stagedRowInstances[row].text.enumerated() {
                        textPtr[tOff + i] = inst
                    }
                    let eOff = frame.pointee.emojiRowOffsets[row]
                    for (i, inst) in frame.pointee.stagedRowInstances[row].emoji.enumerated() {
                        emojiPtr[eOff + i] = inst
                    }
                }
                return
            }
        }

        // Full compact: rebuild GPU buffers and record per-row offsets for this frame.
        let totalTextCount = frame.pointee.stagedRowInstances.reduce(0) { $0 + $1.text.count }
        let totalEmojiCount = frame.pointee.stagedRowInstances.reduce(0) { $0 + $1.emoji.count }

        ensureBufferCapacity(
            buffer: &frame.pointee.textInstanceBuffer,
            capacity: &frame.pointee.textInstanceCapacity,
            requiredCount: max(1, totalTextCount), type: CellTextInstance.self
        )
        ensureBufferCapacity(
            buffer: &frame.pointee.emojiInstanceBuffer,
            capacity: &frame.pointee.emojiInstanceCapacity,
            requiredCount: max(1, totalEmojiCount), type: CellTextInstance.self
        )

        let textPtr = frame.pointee.textInstanceBuffer.contents()
            .bindMemory(to: CellTextInstance.self, capacity: max(1, totalTextCount))
        let emojiPtr = frame.pointee.emojiInstanceBuffer.contents()
            .bindMemory(to: CellTextInstance.self, capacity: max(1, totalEmojiCount))

        var textOffsets: [Int] = []
        textOffsets.reserveCapacity(rows)
        var emojiOffsets: [Int] = []
        emojiOffsets.reserveCapacity(rows)
        var textIdx = 0
        var emojiIdx = 0
        for row in 0..<rows {
            textOffsets.append(textIdx)
            emojiOffsets.append(emojiIdx)
            let rowInst = frame.pointee.stagedRowInstances[row]
            for inst in rowInst.text {
                textPtr[textIdx] = inst
                textIdx += 1
            }
            for inst in rowInst.emoji {
                emojiPtr[emojiIdx] = inst
                emojiIdx += 1
            }
        }
        frame.pointee.textRowOffsets = textOffsets
        frame.pointee.emojiRowOffsets = emojiOffsets

        frame.pointee.textInstanceCount = textIdx
        frame.pointee.emojiInstanceCount = emojiIdx
    }

    /// Fast color-only patch for text instances in dirty rows.
    /// Skips glyph atlas lookups — only recalculates fg color based on current
    /// cursor blink / selection state.
    private func patchTextInstanceColors(
        frame: UnsafeMutablePointer<FrameState>,
        snapshot: ScreenSnapshot,
        dirtyRegion: DirtyRegion,
        searchLineMap: SearchLineMap
    ) {
        let instanceCount = frame.pointee.textInstanceCount
        let ptr = frame.pointee.textInstanceBuffer.contents()
            .bindMemory(to: CellTextInstance.self, capacity: instanceCount)

        let snapCols = backingColumns
        let colorState = makeTextColorState(snapshot: snapshot, searchLineMap: searchLineMap)

        for i in 0..<instanceCount {
            let row = Int(ptr[i].gridPos.y)
            if !dirtyRegion.isDirty(row: row) { continue }

            let col = Int(ptr[i].gridPos.x)
            let rowBase = row * snapCols
            guard rowBase + col < backingCells.count else { continue }

            let absLine = snapshot.absoluteLine(forViewportRow: row)
            ptr[i].color = colorState.foreground(
                attrs: backingCells[rowBase + col].attributes,
                row: row, col: col, absLine: absLine)
        }
    }

    // MARK: - Private: Uniforms

    private func updateUniforms(in buffer: MTLBuffer,
                                screen: ScreenSize, grid: GridSize, padding: Padding) {
        let ptr = buffer.contents().bindMemory(to: Uniforms.self, capacity: 1)

        ptr.pointee.projectionMatrix = orthographicProjection(
            width: Float(screen.width),
            height: Float(screen.height)
        )
        ptr.pointee.screenSize = SIMD2<Float>(Float(screen.width), Float(screen.height))
        ptr.pointee.cellSize = SIMD2<Float>(Float(fontSystem.cellSize.width), Float(fontSystem.cellSize.height))
        ptr.pointee.gridSize = SIMD2<UInt16>(grid.columns, grid.rows)
        ptr.pointee.gridPadding = SIMD4<Float>(
            Float(padding.top), Float(padding.right),
            Float(padding.bottom), Float(padding.left)
        )
    }

    nonisolated private func orthographicProjection(width: Float, height: Float) -> simd_float4x4 {
        simd_float4x4(rows: [
            SIMD4<Float>( 2.0 / width,  0,              0, -1),
            SIMD4<Float>( 0,           -2.0 / height,   0,  1),
            SIMD4<Float>( 0,            0,              1,  0),
            SIMD4<Float>( 0,            0,              0,  1),
        ])
    }

    // MARK: - Resource Metrics

    var currentResourceMetrics: ResourceMetrics {
        let frame = frameStates[frameIndex]

        func bufferSize<T>(for type: T.Type, capacity: Int) -> UInt64 {
            UInt64(MemoryLayout<T>.stride) * UInt64(capacity)
        }

        let uniformSize = UInt64(MemoryLayout<Uniforms>.stride)
        let bgSize = bufferSize(for: CellBgInstance.self, capacity: frame.bgInstanceCapacity)
        let underlineSize = bufferSize(for: CellBgInstance.self, capacity: frame.underlineInstanceCapacity)
        let textSize = bufferSize(for: CellTextInstance.self, capacity: frame.textInstanceCapacity)
        let emojiSize = bufferSize(for: CellTextInstance.self, capacity: frame.emojiInstanceCapacity)
        let frameBufferBytes = uniformSize + bgSize + underlineSize + textSize + emojiSize
        let totalBufferBytes = frameBufferBytes * UInt64(Self.swapChainCount)

        let glyphAtlasBytes = UInt64(glyphAtlas.textureSize) * UInt64(glyphAtlas.textureSize)
        let emojiAtlasBytes = UInt64(emojiAtlas.textureSize) * UInt64(emojiAtlas.textureSize) * 4

        return ResourceMetrics(
            frameTimeMs: frameMetrics?.frameTimeMs ?? 0,
            instanceBuildTimeMs: frameMetrics?.instanceBuildTimeMs ?? 0,
            gpuSubmitCount: frameMetrics?.gpuSubmitCount ?? 0,
            skippedFrameCount: frameMetrics?.skippedFrameCount ?? 0,
            dedupedFrameCount: frameMetrics?.dedupedFrameCount ?? 0,
            bgInstanceCapacity: frame.bgInstanceCapacity,
            bgInstanceCount: instanceCount,
            textInstanceCapacity: frame.textInstanceCapacity,
            textInstanceCount: frame.textInstanceCount,
            emojiInstanceCapacity: frame.emojiInstanceCapacity,
            emojiInstanceCount: frame.emojiInstanceCount,
            underlineInstanceCapacity: frame.underlineInstanceCapacity,
            underlineInstanceCount: frame.underlineInstanceCount,
            glyphAtlasSize: glyphAtlas.textureSize,
            glyphAtlasEntries: glyphAtlas.activeEntryCount,
            emojiAtlasSize: emojiAtlas.textureSize,
            emojiAtlasEntries: emojiAtlas.activeEntryCount,
            gridColumns: UInt32(gridSize.columns),
            gridRows: UInt32(gridSize.rows),
            metalAllocatedSize: UInt64(device.currentAllocatedSize),
            estimatedBufferBytes: totalBufferBytes,
            estimatedAtlasBytes: glyphAtlasBytes + emojiAtlasBytes,
            snapshotCellCopyCount: frameMetrics?.snapshotCellCopyCount ?? 0,
            rebuiltRowCount: frameMetrics?.rebuiltRowCount ?? 0,
            pendingDirtyRows: frameStateDirtyRegions.reduce(0) { $0 + $1.dirtyRows.count },
            totalRowCount: Int(gridSize.rows),
            shapedRowCacheHits: shapedRowCache.hits,
            shapedRowCacheMisses: shapedRowCache.misses
        )
    }
}
