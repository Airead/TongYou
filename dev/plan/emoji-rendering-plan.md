# TongYou Emoji/复杂字符渲染改进计划

## 现状分析

### 当前架构问题

1. **数据结构限制**: `Cell` 使用 `Unicode.Scalar` 而非 `Character`，无法存储多scalar的emoji序列（如 👨‍👩‍👧‍👦 = 7个scalar）
2. **宽度计算错误**: 按scalar累加宽度，导致ZWJ序列占用3-7个单元格而非1-2个
3. **缺少Shaping**: 逐字符渲染，无法正确处理ligature和复杂脚本
4. **字体回退简单**: 仅支持单字符级别的CTFontCreateForString

### Ghostty参考架构

```
┌─────────────────────────────────────────────────────────────┐
│  Terminal Grid (Cell with grapheme cluster support)         │
├─────────────────────────────────────────────────────────────┤
│  Font Resolution (CodepointResolver + Collection)           │
│  - Style correction → User codepoint map → Sprite font      │
│  - Loaded fonts → Regular fallback → System discovery       │
├─────────────────────────────────────────────────────────────┤
│  Text Shaping (CoreText CTTypesetter/CTLine/CTRun)          │
│  - Run iteration (same font/style sequences)                │
│  - Forced LTR embedding                                     │
├─────────────────────────────────────────────────────────────┤
│  Glyph Rasterization (CoreGraphics + Atlas)                 │
│  - Dual atlas: Grayscale (text) + BGRA (color emoji)        │
│  - Dynamic shelf packing                                    │
├─────────────────────────────────────────────────────────────┤
│  GPU Rendering (Metal)                                      │
│  - Background → Text → Cursor → Underlines                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 实现阶段

### 阶段1: 数据结构重构 (验证脚本: validate_grapheme_cluster.swift)

**目标**: 支持Grapheme Cluster存储

#### 1.1 修改 Cell 结构
```swift
// 当前: Unicode.Scalar (限制: 只能存储单个scalar)
public struct Cell {
    public var codepoint: Unicode.Scalar
    public var width: CellWidth
    // ...
}

// 目标: GraphemeCluster (支持多scalar序列)
public struct GraphemeCluster: Equatable, Sendable {
    public let scalars: [Unicode.Scalar]  // 小数组优化（内联存储1-4个）
    public let scalarCount: UInt8
    
    public static func from(_ character: Character) -> GraphemeCluster
    public var firstScalar: Unicode.Scalar { scalars[0] }
    public var isEmojiSequence: Bool  // 检测ZWJ/VS/skin tone等
}

public struct Cell {
    public var content: GraphemeCluster  // 替代原来的codepoint
    public var width: CellWidth
    // ...
}
```

#### 1.2 修改 VT 解析器
```swift
// 当前: 逐scalar写入
func write(_ scalar: Unicode.Scalar)

// 目标: 按grapheme cluster写入
func write(_ cluster: GraphemeCluster)
// 或保持scalar输入，内部累积combining marks
```

**验证方法**:
```bash
swift scripts/validate_grapheme_cluster.swift
# 预期输出: 正确识别所有测试用例的grapheme cluster分解
```

**成功标准**:
- [ ] `👨‍👩‍👧‍👦` 识别为1个cluster，包含7个scalar
- [ ] `👋🏻` 识别为1个cluster，包含2个scalar
- [ ] `🇨🇳` 识别为1个cluster，包含2个scalar

---

### 阶段2: 正确的宽度计算

**目标**: 修复emoji序列的单元格宽度计算

#### 2.1 实现 GraphemeCluster.terminalWidth
```swift
extension GraphemeCluster {
    public var terminalWidth: UInt8 {
        let scalars = self.scalars
        guard let firstScalar = scalars.first else { return 1 }
        
        // 检测emoji序列标记
        let isEmojiSequence = scalars.count > 1 && scalars.contains { s in
            s.value == 0x200D ||  // ZWJ
            s.value == 0xFE0E || s.value == 0xFE0F ||  // Variation Selectors
            (s.value >= 0x1F3FB && s.value <= 0x1F3FF) ||  // Skin tones
            (s.value >= 0x1F1E6 && s.value <= 0x1F1FF) ||  // Regional indicators
            (s.value >= 0xE0020 && s.value <= 0xE007F)     // Tag characters
        }
        
        if isEmojiSequence {
            // Emoji序列使用基础emoji的宽度
            return firstScalar.terminalWidth
        }
        
        // 非emoji序列：累加各scalar宽度（用于combining marks）
        return scalars.reduce(0) { $0 + $1.terminalWidth }
    }
}
```

#### 2.2 更新 Screen.write()
```swift
public func write(_ cluster: GraphemeCluster, attributes: CellAttributes) {
    let w = Int(cluster.terminalWidth)  // 使用新的宽度计算
    
    if w == 2 && cursorCol == columns - 1 {
        // 宽字符放不下，标记spacer并换行
        cells[idx] = Cell(content: GraphemeCluster(" "), width: .spacer)
        // ...
    }
    
    cells[idx] = Cell(content: cluster, width: w == 2 ? .wide : .normal)
    // ...
}
```

**验证方法**:
```bash
swift scripts/validate_grapheme_cluster.swift
# 测试GraphemeCluster宽度计算、序列化等核心逻辑
```

**成功标准**:
- [x] `👨‍👩‍👧‍👦` (ZWJ序列) 从7 cells → 2 cells
- [x] `👋🏻` (肤色修饰) 从2 cells → 2 cells
- [x] `🇨🇳` (国旗) 从2 cells → 2 cells
- [x] 普通ASCII保持1 cell不变

---

### 阶段3: 双图集系统

**目标**: 支持彩色emoji渲染

#### 3.1 创建 ColorEmojiAtlas
```swift
final class ColorEmojiAtlas {
    private var texture: MTLTexture  // BGRA format
    private var cache: [GraphemeCluster: EmojiGlyphInfo]
    
    func getOrRasterize(
        cluster: GraphemeCluster,
        fontSystem: FontSystem
    ) -> EmojiGlyphInfo? {
        // 1. 检查是否是emoji序列
        guard cluster.isEmojiSequence || cluster.firstScalar.isEmoji else {
            return nil
        }
        
        // 2. 尝试从Apple Color Emoji获取位图
        let emojiFont = CTFontCreateWithName("Apple Color Emoji" as CFString, 
                                             fontSystem.pointSize * fontSystem.scaleFactor, nil)
        
        // 3. 使用CGContext渲染彩色位图
        // 4. 存入BGRA纹理图集
    }
}
```

#### 3.2 修改 MetalRenderer
```swift
final class MetalRenderer {
    private let glyphAtlas: GlyphAtlas        // R8Unorm - 文字
    private let emojiAtlas: ColorEmojiAtlas   // BGRA - 彩色emoji
    
    private let textPipelineState: MTLRenderPipelineState     // 现有：采样灰度图集
    private let emojiPipelineState: MTLRenderPipelineState    // 新增：采样BGRA图集
    
    func render(in layer: CAMetalLayer) {
        // ...背景渲染...
        
        // 渲染文字（灰度图集）
        encoder.setRenderPipelineState(textPipelineState)
        encoder.setFragmentTexture(glyphAtlas.texture, index: 0)
        encoder.drawPrimitives(...)
        
        // 渲染彩色emoji（BGRA图集）
        encoder.setRenderPipelineState(emojiPipelineState)
        encoder.setFragmentTexture(emojiAtlas.texture, index: 0)
        encoder.drawPrimitives(...)
    }
}
```

**验证方法**:
- 编写单元测试覆盖 `ColorEmojiAtlas` 缓存、LRU淘汰、BGRA位图生成
- 手动运行 `make run`，检查彩色emoji是否正确渲染为彩色图像

**成功标准**:
- [ ] 彩色emoji正确显示（非灰度）
- [ ] 表情符号选择器（如👨‍👩‍👧‍👦）渲染为单一图像
- [ ] 图集内存使用合理（LRU淘汰工作正常）

---

### 阶段4: CoreText Shaping

**目标**: 实现Run-based shaping

#### 4.1 创建 TextRun 和 Shaper
```swift
/// 一段相同字体/样式的文本
struct TextRun {
    let cells: [Cell]           // 连续的单元格
    let startCol: Int
    let font: CTFont
    let attributes: CellAttributes
}

/// 使用CoreText进行shaping
struct CoreTextShaper {
    let baseFont: CTFont
    
    func shape(_ run: TextRun) -> [ShapedGlyph] {
        // 1. 构建CFAttributedString
        let text = run.cells.map { $0.content }.joined()
        let attrString = CFAttributedStringCreateMutable(...)
        CFAttributedStringReplaceString(attrString, ..., text as CFString)
        CFAttributedStringSetAttribute(attrString, ..., kCTFontAttributeName, run.font)
        
        // 2. 创建CTTypesetter（强制LTR）
        let options = [kCTTypesetterOptionForcedEmbeddingLevel: 0] as CFDictionary
        guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(
            attrString, options) else { return [] }
        
        // 3. 创建CTLine并提取CTRun
        let line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, text.utf16.count))
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        
        // 4. 提取glyph信息
        var shapedGlyphs: [ShapedGlyph] = []
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            // 获取glyphs, positions, advances, stringIndices
            // 构建ShapedGlyph数组
        }
        
        return shapedGlyphs
    }
}

struct ShapedGlyph {
    let glyph: CGGlyph
    let position: CGPoint      // 相对于run起点的位置
    let advance: CGSize
    let cellIndex: Int         // 映射回哪个单元格
}
```

#### 4.2 修改 MetalRenderer.fillTextInstanceBuffer()
```swift
private func fillTextInstanceBuffer(...) {
    // 当前: 逐单元格处理
    for row in 0..<snapRows {
        for col in 0..<snapCols {
            let cell = snapshot.cells[rowBase + col]
            // 单独处理每个cell...
        }
    }
    
    // 目标: 按run处理
    for row in 0..<snapRows {
        let runs = buildRuns(for: row, snapshot: snapshot)
        for run in runs {
            let shapedGlyphs = shaper.shape(run)
            for glyph in shapedGlyphs {
                // 生成CellTextInstance
            }
        }
    }
}

private func buildRuns(for row: Int, snapshot: ScreenSnapshot) -> [TextRun] {
    // 1. 跳过continuation和spacer单元格
    // 2. 当字体或样式变化时，开始新的run
    // 3. 收集连续的、同字体同样式的单元格
}
```

**验证方法**:
- 单元测试：对比shaping前后的glyph数量（如 👨‍👩‍👧‍👦 应该只有1个glyph）
- 集成测试：使用复杂文本验证CTTypesetter是否正确处理run边界

**成功标准**:
- [ ] `👨‍👩‍👧‍👦` 从7个glyph → 1个glyph
- [ ] Ligature（如"fi"）正确渲染为单一glyph
- [ ] 复杂脚本（阿拉伯语、印地语）渲染正确

---

### 阶段5: 字体回退链

**目标**: 实现完整的字体回退链

#### 5.1 创建 FontCollection 和 CodepointResolver
```swift
/// 按样式组织的字体集合
struct FontCollection {
    enum Style { case regular, bold, italic, boldItalic }
    
    private var fonts: [Style: [CTFont]]
    
    mutating func addFont(_ font: CTFont, style: Style) {
        fonts[style, default: []].append(font)
    }
    
    func font(for style: Style, at index: Int) -> CTFont?
}

/// 码点→字体索引解析器
struct CodepointResolver {
    private var collection: FontCollection
    private var cache: [CacheKey: FontIndex]
    
    struct CacheKey: Hashable {
        let codepoint: UInt32
        let style: FontCollection.Style
        let isEmoji: Bool
    }
    
    /// 完整的回退链（按优先级）:
    /// 1. 请求的样式字体中查找
    /// 2. 如果bold禁用，回退到regular
    /// 3. Sprite字体（powerline符号等）
    /// 4. 已加载字体中查找
    /// 5. 回退到regular样式（保持一致性）
    /// 6. 系统字体发现（CoreText）
    /// 7. 放宽presentation限制
    func resolve(_ cluster: GraphemeCluster, style: FontCollection.Style) -> FontIndex {
        // 实现Ghostty的7层回退逻辑
    }
}
```

#### 5.2 系统字体发现
```swift
func discoverFallbackFont(for cluster: GraphemeCluster) -> CTFont? {
    // 1. 构建CTFontDescriptor，要求包含cluster的所有scalars
    let charset = cluster.scalars.reduce(CFMutableBitVectorCreateMutable(...)) { ... }
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontCharacterSetAttribute: charset
    ] as CFDictionary)
    
    // 2. 使用CTFontDescriptorCreateMatchingFontDescriptors查找匹配字体
    guard let matches = CTFontDescriptorCreateMatchingFontDescriptors(
        descriptor, nil) as? [CTFontDescriptor] else { return nil }
    
    // 3. 返回第一个能渲染所有scalars的字体
    for desc in matches {
        let font = CTFontCreateWithFontDescriptor(desc, 0, nil)
        if canRender(cluster, in: font) { return font }
    }
    return nil
}
```

**验证方法**:
- 单元测试：验证 `CodepointResolver` 对各种字符返回正确字体
- 手动测试：显示不同语种的文本，确认都能正确渲染

**成功标准**:
- [ ] CJK字符使用PingFang/Hiragino
- [ ] Emoji使用Apple Color Emoji
- [ ] 数学符号使用STIX或系统数学字体
- [ ] 字体回退缓存命中率高

---

### 阶段6: 渲染管线整合

**目标**: 完整的端到端渲染流程

#### 6.1 更新渲染流程
```swift
func render(in layer: CAMetalLayer) {
    // Phase 1: 提取终端状态（已有）
    
    // Phase 2: 渲染线程Tick（已有）
    
    // Phase 3: 重建单元格（修改）
    // - Run iteration
    // - Shaping (缓存)
    // - Rasterization (glyphAtlas + emojiAtlas)
    // - 生成GPU顶点数据
    
    // Phase 4: GPU提交（修改）
    // - Uniform buffer
    // - Background buffer
    // - Text buffer (灰度)
    // - Emoji buffer (BGRA)
    // - Atlas textures
    
    // Phase 5: 着色器执行（修改）
    // - cell_bg
    // - cell_text (灰度图集)
    // - cell_emoji (BGRA图集)
    // - cursor, underline
}
```

#### 6.2 Metal着色器更新
```metal
// 新增: emoji_fragment shader
fragment float4 emoji_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> emojiAtlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    // 直接采样BGRA，不使用颜色乘法
    float4 color = emojiAtlas.sample(atlasSampler, in.texCoord);
    return color;  // 预乘alpha
}
```

**验证方法**:
- 单元测试：覆盖Run构建、Shaping、光栅化完整链路
- 性能测试：对比改进前后的渲染性能（FPS、图集内存）
- 手动测试：运行终端，验证各种emoji序列、复杂脚本的显示效果

**成功标准**:
- [ ] 所有验证脚本通过
- [ ] 单元测试覆盖新增代码
- [ ] 性能无明显退化（fps保持稳定）
- [ ] 内存使用合理（图集不无限增长）

---

## 测试策略

### 单元测试
```swift
@Test("Grapheme cluster width calculation")
func testGraphemeWidth() {
    #expect(GraphemeCluster("👨‍👩‍👧‍👦").terminalWidth == 2)
    #expect(GraphemeCluster("👋🏻").terminalWidth == 2)
    #expect(GraphemeCluster("🇨🇳").terminalWidth == 2)
    #expect(GraphemeCluster("A").terminalWidth == 1)
}

@Test("Run building")
func testRunBuilding() {
    let cells = [
        Cell(content: "H", .normal),
        Cell(content: "i", .normal),
        Cell(content: "👨‍👩‍👧‍👦", .wide),
        Cell(content: "!", .normal)
    ]
    let runs = buildRuns(cells)
    #expect(runs.count == 3)  // "Hi", emoji, "!"
}
```

### 集成测试
```swift
@Suite(.serialized)
struct RenderingIntegrationTests {
    @Test("Render complex emoji sequence")
    func testEmojiRendering() async throws {
        let renderer = try makeTestRenderer()
        let snapshot = makeSnapshot(text: "👨‍👩‍👧‍👦")
        
        let image = try await renderer.renderToImage(snapshot)
        // 使用 perceptual hash 对比预期图像
        #expect(image.similarity(to: expectedImage) > 0.95)
    }
}
```

### 性能测试
```swift
@Test("Rendering performance")
func testRenderingPerformance() {
    let renderer = makeTestRenderer()
    let snapshot = makeSnapshot(text: generateComplexText())
    
    let time = ContinuousClock().measure {
        for _ in 0..<1000 {
            renderer.fillTextInstanceBuffer(snapshot: snapshot)
        }
    }
    
    #expect(time < .milliseconds(100))
}
```

---

## 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 数据结构改变导致兼容性问题 | 高 | 保持Cell内存布局稳定，使用union存储scalar/cluster |
| CoreText Shaping性能下降 | 中 | 实现run-level缓存，避免重复shaping |
| 彩色emoji图集内存爆炸 | 中 | 实现LRU淘汰，限制图集最大尺寸 |
| 字体发现阻塞主线程 | 中 | 在后台队列进行字体发现，使用回调 |
| 复杂度增加维护困难 | 低 | 每个阶段都有独立验证脚本，文档完善 |

---

## 时间线估算

| 阶段 | 预估时间 | 依赖 |
|------|----------|------|
| 阶段1: 数据结构重构 | 2-3天 | 无 |
| 阶段2: 宽度计算 | 1-2天 | 阶段1 |
| 阶段3: 双图集系统 | 3-4天 | 阶段1 |
| 阶段4: CoreText Shaping | 4-5天 | 阶段1, 2 |
| 阶段5: 字体回退链 | 3-4天 | 阶段1 |
| 阶段6: 整合测试 | 2-3天 | 阶段2-5 |
| **总计** | **15-21天** | - |

---

## 参考资源

1. **Ghostty文档**:
   - `/Users/fanrenhao/work/ghostty/docs/macos-rendering-architecture.md`
   - `/Users/fanrenhao/work/ghostty/docs/macos-rendering-architecture-details.md`

2. **参考脚本** (用于学习和诊断，非阶段验证标准):
   - `scripts/validate_emoji_step1.swift` - Unicode分解
   - `scripts/validate_emoji_step2.swift` - 字体回退
   - `scripts/validate_emoji_step3.swift` - 简单渲染对比
   - `scripts/validate_emoji_step4.swift` - CoreText Shaping
   - `scripts/validate_emoji_step5.swift` - 网格布局
   - `scripts/validate_emoji_step6.swift` - 宽度计算修复
   - `scripts/validate_emoji_step7.swift` - 最终视觉对比
   - `scripts/validate_emoji_render_pipeline.swift` - 渲染管线诊断

3. **关键源码文件**:
   - `TongYou/Renderer/MetalRenderer.swift` - 主渲染器
   - `TongYou/Font/FontSystem.swift` - 字体系统
   - `TongYou/Font/GlyphAtlas.swift` - 灰度图集
   - `Packages/TYTerminal/Cell.swift` - 单元格定义
   - `Packages/TYTerminal/Screen.swift` - 屏幕状态
