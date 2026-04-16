# TongYou 终端模拟器五层架构实现分析与解耦评估

## 背景

现代高性能终端模拟器（Alacritty、Kitty、WezTerm、Windows Terminal 等）通常将架构解耦为五个核心部分，以实现极低的输入延迟和超高的渲染吞吐量：

1. PTY 与 I/O 交互层
2. 状态机与序列解析器（VT Parser）
3. 终端模型与网格状态（Terminal Model / Grid Buffer）
4. 字体排版与缓存子系统（Text Shaping & Glyph Atlas）
5. GPU 渲染与窗口系统（GPU Renderer & Windowing）

本文档基于 TongYou 当前代码库，逐层分析其实现细节、数据流转、线程模型，并评估各层之间的解耦程度与独立调优的可行性。

---

## 1. PTY 与 I/O 交互层

### 核心文件
- `Packages/TongYouCore/Sources/TYPTY/PTYProcess.swift`

### 实现要点

| 维度 | 实现细节 |
|------|----------|
| **PTY 创建** | 通过 `openpty()` 创建主/从设备对，再经 C 辅助函数 `pty_fork_exec()` 完成 `fork + setsid + TIOCSCTTY + dup2 + execve` 启动 shell。支持 macOS 与 Linux 双平台。 |
| **异步读取** | 使用 `DispatchSource.makeReadSource(fileDescriptor:...)` 在独立的 `readQueue`（后台串行队列）上异步读取。读取 buffer 大小为 64KB。 |
| **自适应时间预算** | 交互场景预算 **8ms**，当检测到连续满 buffer 读取（≥3 次）时切换到 **16ms** 批量预算，平衡响应速度与大数据吞吐。 |
| **异步写入** | 所有写操作派发到独立的 `writeQueue`。当内核缓冲区满（`EAGAIN`）时，使用 `poll()` 阻塞等待可写（超时 1s），确保大粘贴数据（包括 bracketed-paste 结束序列）不会丢失或截断。 |
| **生命周期管理** | `stop()` / `deinit` 中先 `writeQueue.sync {}` 排空待写数据，再向子进程发送 `SIGHUP`，100ms 未退出则 `SIGKILL`。 |

### 解耦度评估
`PTYProcess` 只通过 `onRead: (UnsafeBufferPointer<UInt8>) -> Void` 向上输送原始字节，通过 `write()` / `resize()` 接收外部指令。**与上层完全解耦**。

---

## 2. 状态机与序列解析器（VT Parser）

### 核心文件
- `Packages/TongYouCore/Sources/TYTerminal/VTParser.swift`
- `Packages/TongYouCore/Sources/TYTerminal/VTAction.swift`

### 实现要点

| 维度 | 实现细节 |
|------|----------|
| **解析器模型** | 严格遵循 **Paul Williams 的 DEC VT 解析器模型**（参考 vt100.net），并借鉴 Ghostty 的实现。 |
| **状态转移表** | 使用 **扁平化的静态状态转移表**：`table[256 * VTState.count]`（约 3584 条 / 7KB），在 `feed` 时按 `(byte, state)` 直接索引，避免运行时大量分支判断。 |
| **Fast Path 优化** | 1. **Printable ASCII 批量收集**：在 `ground` 状态下对 `0x20-0x7E` 扫描并批量拷贝到 `PrintBatchBuffer`，生成 `printBatch` action，绕过逐字节状态机。<br>2. **CSI Fast Path**：对最常见的 CSI 序列（SGR `m`、CUP `H`、EL `K`、HVP `f`）提供零成本快速解析，失败时自动回退到完整状态机。 |
| **UTF-8 集成** | UTF-8 多字节解码直接集成在 `ground` 状态逻辑中，避免 C1 控制字符打断多字节序列。 |

### 解耦度评估
`VTParser` 是纯 `Sendable struct`，核心接口只有一个：
```swift
mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>, emit: (VTAction) -> Void)
```
它不保存屏幕状态，不依赖 `Screen` 或 `StreamHandler` 的具体类型。**与上下层完全解耦**。

---

## 3. 终端模型与网格状态（Screen / Grid）

### 核心文件
- `Packages/TongYouCore/Sources/TYTerminal/Screen.swift`
- `Packages/TongYouCore/Sources/TYTerminal/StreamHandler.swift`

### 实现要点

| 维度 | 实现细节 |
|------|----------|
| **行环形缓冲区（Row Ring Buffer）** | 逻辑行 0 映射到物理行 `rowBase`。全屏滚动时只需递增 `rowBase`（O(1) 指针旋转），而非复制整个 `rows × columns` 数组。局部滚动区域仍使用物理拷贝。 |
| **Scrollback Buffer** | 独立的扁平环形缓冲区，默认最多 10000 行。支持窗口缩放时的 **内容重排（reflow）**：将软换行连接成逻辑行，再按新列宽重新折行，光标位置在重排后自动追踪。 |
| **Dirty Region 跟踪** | `DirtyRegion` 结构使用每行 bitset 标记变更行，支持非连续脏行。`ScreenSnapshot` 支持：<br>- **完整快照**：所有 cells + dirty region。<br>- **增量快照（Partial）**：仅复制变更行的 cells，显著降低跨线程传输量与渲染器合并开销。 |
| **宽字符支持** | 每个 `Cell` 记录 `.wide` / `.continuation` / `.spacer` / `.normal` 宽度状态。写入或擦除时自动清理“孤儿”半边，避免宽字符断裂。 |
| **StreamHandler 桥接** | `StreamHandler` 持有 `Screen` 实例，负责将 `VTAction` 翻译为 `Screen` 命令（cursorUp、eraseDisplay、write 等），同时管理 SGR 属性、终端模式、光标保存/恢复状态。 |

### 解耦度评估
`Screen` 通过命令式 API 接收更新，通过 `snapshot()` 输出不可变的 `ScreenSnapshot`。只要 `snapshot()` 的数据结构不变，**内部存储和算法优化完全不影响上层解析器和下层渲染器**。

**注意**：`StreamHandler` 直接持有 `Screen` 实例。如果改变 `Screen` 的公共 API（例如把 `cursorUp` 改成批量接口），需同步修改 `StreamHandler`；但只改内部实现（如换用稀疏行存储）则无需改动。

---

## 4. 字体排版与缓存子系统

### 核心文件
- `TongYou/Font/TextShaper.swift`
- `TongYou/Font/GlyphAtlas.swift`
- `TongYou/Font/ColorEmojiAtlas.swift`
- `TongYou/Font/ShapedRowCache.swift`

### 实现要点

| 维度 | 实现细节 |
|------|----------|
| **Text Shaping** | 使用 Apple **CoreText** (`CTTypesetterCreateLine` + `CTRunGetGlyphs/Positions/Advances`)，强制 LTR embedding（`kCTTypesetterOptionForcedEmbeddingLevel: 0`）。按相同字体和属性的连续 cell 分组成 `TextRun`，再逐 run shaping。 |
| **字形缓存（Glyph Atlas）** | 普通文字：R8Unorm 单通道灰度纹理，**Shelf Packing**（按行从左到右填充），1px 边框防止采样瑕疵。彩色 Emoji：独立的 RGBA atlas（`ColorEmojiAtlas`），通过 CoreGraphics 离屏渲染后上传 GPU。 |
| **动态扩容与淘汰** | Atlas 满时纹理尺寸翻倍（最大 8192）。利用率超过 75% 时触发 LRU 淘汰（移除最旧的 25% 条目），随后 compact 重建 atlas 以回收碎片空间。 |
| **行级缓存（ShapedRowCache）** | 以整行 cells 切片为 key 缓存 shaping 结果，避免每帧对未变更行重复计算。 |

### 解耦度评估
`GlyphAtlas` / `ColorEmojiAtlas` 的接口非常干净（`getOrRasterize(...)`），**atlas 的 packing 策略、淘汰策略、纹理格式都可以独立优化**。

**但是**，`MetalRenderer` 内部硬编码了 **CoreText shaping 流程**：
- `buildRuns(forRow:)` 拆分 `TextRun`
- `shapeRow(row:shaper:)` 调用 `CoreTextShaper.shape()`
- `rebuildTextRow(...)` 把 `ShapedGlyph` 转换为 GPU instance

这意味着：如果未来想**把 shaping 引擎从 CoreText 换成 HarfBuzz**，或引入 Bidi/RTL 分段，就必须修改 `MetalRenderer`。**字体子系统与渲染器在此处呈“半解耦”状态**，这是当前架构中解耦度最薄弱的环节。

---

## 5. GPU 渲染与窗口系统

### 核心文件
- `TongYou/Renderer/MetalRenderer.swift`
- `TongYou/Renderer/MetalView.swift`
- `TongYou/Renderer/Shaders.metal`

### 实现要点

| 维度 | 实现细节 |
|------|----------|
| **Metal 多通道实例渲染** | Pass 1：背景色（`cell_bg_vertex / cell_bg_fragment`）<br>Pass 2：下划线（URL hover 高亮）<br>Pass 3：普通文字（采样 `GlyphAtlas` R8 纹理）<br>Pass 4：彩色 Emoji（采样 `ColorEmojiAtlas` RGBA 纹理）<br>所有绘制均使用 `triangleStrip` + `instanceCount = rows × columns` 的 instanced draw。 |
| **Triple Buffering** | `DispatchSemaphore(value: 3)` 控制 CPU/GPU 帧 pacing，3 套 `FrameState`（uniform buffer + instance buffer）循环使用。 |
| **增量更新策略** | - `instanceRebuildCounter` 控制背景/下划线/文本 instance buffer 重建。<br>- `textContentDirtyCounter` 区分“内容变化”与“仅光标闪烁”。光标闪烁时走 `patchTextInstanceColors` 快速路径，只改颜色不改 glyph，跳过 atlas 查询和 shaping。 |
| **窗口桥接** | `MetalView`（`NSView` 子类）通过 `NSViewRepresentable` 嵌入 SwiftUI，`CADisplayLink` 绑定主线程 runloop 驱动 `render(in: CAMetalLayer)`。 |
| **Premultiplied Alpha** | 所有 pipeline 开启预乘 alpha 混合（`source * 1 + dest * (1 - sourceAlpha)`），与项目编码规范一致。 |

### 解耦度评估
`MetalRenderer` 的输入只有 `ScreenSnapshot` 和窗口尺寸事件。**渲染管线、shader、buffer 策略、显示链路都可以独立演进**，不会反噬到 Screen 或 PTY 层。

---

## 数据流与线程模型

```
键盘输入 → SwiftUI/MetalView → TerminalCore.write()
                                    ↓
                              PTYProcess (writeQueue)
                                    ↓
                            Shell 输出到 PTY master
                                    ↓
                              PTYProcess.onRead (ptyQueue)
                                    ↓
                              VTParser.feed() ──→ VTAction
                                    ↓
                              StreamHandler.handle()
                                    ↓
                              Screen 更新 + DirtyRegion
                                    ↓
                         consumeSnapshot() (ptyQueue.sync)
                                    ↓
                         MetalRenderer.setContent() (MainActor)
                                    ↓
                         fillBgInstanceBuffer / fillTextInstanceBuffer
                                    ↓
                         Metal instanced draw → 屏幕
```

| 执行环境 | 职责 |
|----------|------|
| **ptyQueue（后台串行队列）** | PTY 读取、VT 解析、Screen 状态修改、快照生成。 |
| **writeQueue（后台串行队列）** | PTY 写入，处理 EAGAIN 与 poll 重试。 |
| **MainActor（主线程）** | 窗口事件处理、Metal 渲染命令编码与提交、instance buffer 填充。 |
| **跨线程通信** | 通过不可变的 `ScreenSnapshot`（支持增量 partial snapshot）实现，天然避免数据竞争。 |

---

## 解耦度与独立调优可行性矩阵

| 层级 | 解耦度 | 独立调优可行性 | 调优示例 |
|------|--------|----------------|----------|
| **PTY I/O** | ⭐⭐⭐⭐⭐ 高 | ✅ 完全独立 | 更换 read 机制（kqueue/io_uring）、调整 buffer 大小、优化 write 重试策略 |
| **VT Parser** | ⭐⭐⭐⭐⭐ 高 | ✅ 完全独立 | 增加 CSI fast path、SIMD 批量扫描 ASCII、改用 Zig/Rust FFI 重写 |
| **Screen / Grid** | ⭐⭐⭐⭐☆ 中高 | ⚠️ 内部优化独立；API 变更需同步 StreamHandler | 换用稀疏行存储、优化 DirtyRegion bitset、改进 reflow 算法 |
| **字体 Atlas** | ⭐⭐⭐☆☆ 中 | ⚠️ Atlas 策略独立；**Shaping 逻辑与 Renderer 耦合** | 换用 Skyline/Guillotine packing、调整 LRU 策略、改变纹理格式 |
| **GPU Renderer** | ⭐⭐⭐⭐⭐ 高 | ✅ 完全独立 | 修改 shader（SDF/Subpixel）、调整 triple-buffer 数量、增加特效 pass |

---

## 结论与建议

### 现状总结
TongYou 在**数据流单向 + 快照传递**的核心架构上解耦做得相当出色：
- `PTYProcess`、`VTParser`、`MetalRenderer` 三层边界清晰，接口极简。
- `ScreenSnapshot` 的**增量快照（partial snapshot）**设计是亮点，有效支撑了高性能渲染。
- 线程模型明确，后台队列负责 I/O 与状态变更，主线程负责渲染，符合高性能终端的经典范式。

### 主要薄弱环节
当前架构中**唯一的显著耦合点**是：**字体 shaping 流程嵌在 `MetalRenderer` 内部**。
- `MetalRenderer` 不仅负责 GPU 绘制，还直接管理 `TextRun` 拆分、CoreText shaping、`ShapedGlyph` 到 GPU instance 的转换。
- 这导致任何 shaping 引擎的替换（如 HarfBuzz）、Bidi/RTL 支持、或连字（ligature）策略的变更，都会侵入渲染器代码。

### 改进建议
建议在未来规划中引入一层**独立的 Shaping Engine 抽象**：
```swift
protocol ShapingEngine {
    func shapeRow(cells: [Cell], fontSystem: FontSystem) -> ShapedRow
}
```
将 `CoreTextShaper` 作为默认实现注入 `MetalRenderer`。这样：
1. `MetalRenderer` 只关心如何把 `ShapedRow` 变成 GPU instance，不关心 shaping 细节。
2. 未来引入 HarfBuzz、Bidi 分析、或复杂 Emoji 处理时，只需新增 `ShapingEngine` 实现。
3. 甚至可以把 shaping 工作从主线程迁移到后台并发队列（只要结果在主线程合并），进一步降低帧时间。

---

*文档创建时间：2026-04-16*
