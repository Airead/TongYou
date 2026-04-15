# TongYou 渲染性能优化计划

**问题**：在 TongYou 中运行 `opencode` 等逐字流式输出程序时，TongYou 自身 CPU 占用极高。

**根因**：渲染循环未做节流、每帧深拷贝整个终端网格、滚动操作强制全屏重绘、文本 shaping 与字形光栅化在主线程重复执行。

**参考实现**：本计划大量参考 Ghostty（`~/work/ghostty/`）的渲染架构设计。

---

## 阶段一：DisplayLink 节流与内容去重（快速胜利）

**目标**：避免 PTY 每来一小批数据就触发 60–120 Hz 满速渲染，减少无意义帧。

**涉及文件**：
- `/Users/fanrenhao/work/TongYou/TongYou/Renderer/MetalView.swift`
- `/Users/fanrenhao/work/TongYou/TongYou/Terminal/TerminalController.swift`
- `/Users/fanrenhao/work/TongYou/TongYou/Renderer/MetalRenderer.swift`

**具体改动**：
1. 在 `MetalView.swift` 的 `displayLinkFired(_:)` 中，增加**内容 generation 去重**：
   - 若 `consumeSnapshot()` 返回的 `contentGeneration` 与上一帧相同，则跳过 `setContent()` 与 `render()`，直接 `return`。
2. 在 `TerminalController.swift` 的 `processBytes(_:)` 与 `wakeDisplayLink` 之间引入**帧合并窗口**（约 8 ms，对应 120 Hz）：
   - 使用 `Timer` 或 `DispatchSourceTimer`，在 `markScreenDirty()` 后不立即唤醒 DisplayLink，而是等待一个极短窗口，让同一次 Runloop 内的多次 `processBytes` 合并为一次渲染。
3. 在 `MetalRenderer.swift` 的 `drawFrame` 入口增加 `needsRender` 守卫：
   - 若 `pendingDirtyRegion` 为空且没有尺寸变化/动画需求，直接返回，不提交 command buffer。

**预期收益**：流式输出时帧率从盲目的 120 FPS 下降到与内容实际变化频率匹配，CPU 立即下降 30–50%。

**参考实现**：
- `/Users/fanrenhao/work/ghostty/src/renderer/Thread.zig`（`DRAW_INTERVAL = 8` ms 的 draw timer 与 `drawNowCallback` 唤醒逻辑）
- `/Users/fanrenhao/work/ghostty/src/renderer/generic.zig`（`drawFrame` 中的 `needs_redraw` 检查与 `presentLastTarget` 空操作）
- `/Users/fanrenhao/work/ghostty/pkg/macos/video/display_link.zig`（CVDisplayLink 启停控制）

---

## 阶段二：增量快照（避免深拷贝整个 grid）

**状态**：已实现。

**目标**：彻底对齐 Ghostty 的逐行 dirty 模型，消除 `Screen.snapshot()` 每帧深拷贝整个 `grid` 的开销；让 `MetalRenderer` 只重建真正变脏的行。

**涉及文件**：
- `/Users/fanrenhao/work/TongYou/Packages/TongYouCore/Sources/TYTerminal/Screen.swift`
- `/Users/fanrenhao/work/TongYou/TongYou/Renderer/MetalRenderer.swift`
- `/Users/fanrenhao/work/TongYou/TongYou/Renderer/FrameMetrics.swift`
- `/Users/fanrenhao/work/TongYou/TongYouTests/`

**具体改动**：
1. **升级 `DirtyRegion` 为逐行 bitset**：
   - 将 `DirtyRegion` 从单个连续 `lineRange` 升级为按行追踪的 `[Bool]` bitset，支持不连续的多行脏行标记。
   - 新增 `markLine(_:)`、`dirtyRows`、`isDirty(row:)` 等 API；`markRange` 内部按行设置 bit。
2. **`ScreenSnapshot` 支持不连续脏行**：
   - 增加 `isPartial: Bool`、`dirtyRows: [Int]` 与 `partialRows: [(row: Int, cells: [Cell])]`。
   - `snapshot()` 在 `!fullRebuild && isDirty && viewportOffset == 0` 时，仅深拷贝真正 dirty 的行；其他情况自动回退为全量快照。
3. **`MetalRenderer` 引入 `backingCells` + 按行重建**：
   - 新增 `backingCells`、`backingColumns`、`backingRows`；`setContent(_:)` 收到 partial snapshot 时按行合并到 backing store。
   - `fillBgInstanceBuffer` 逐行检查 `isDirty(row:)`，clean row 直接 `continue`。
   - `fillTextInstanceBuffer` 采用 Ghostty `rebuildCells` 风格：保留 CPU 侧 staging buffer，只调用 `rebuildTextRow(row:)` 重建 dirty rows，其余行复用旧 instances。
   - `resize()` 时 grid 尺寸变化自动清空 `backingCells` 并 `markFull()`。
4. **边界处理与 Metrics**：
   - 自动回退场景：resize、selection 变化、scrollback（`viewportOffset != 0`）、alternate screen buffer 切换均走全量路径。
   - `FrameMetrics.snapshotCellCopyCount` 记录每帧实际拷贝的 cell 数，便于 Debug Metrics HUD 观测。
5. **单元测试**：
   - `DirtyRegionTests.swift`：验证逐行标记、不连续脏行、`merge`。
   - `ScreenPartialSnapshotTests.swift`：验证 partial snapshot 构造与全量回退。
   - `MetalRendererBackingCellsTests.swift`：验证 `setContent()` 对 `backingCells` 的增量/全量更新。

**预期收益**：120×40 终端在增量场景下每帧内存拷贝从 ~200 KB 降至 `columns × dirtyRowCount`（通常几 KB），CPU 和内存压力显著下降；`buildRuns` / `CoreTextShaper.shape` 的调用次数和耗时同步下降。

**参考实现**：
- `/Users/fanrenhao/work/ghostty/src/terminal/render.zig`（`RenderState.Row.dirty`、`update` 按行拷贝）
- `/Users/fanrenhao/work/ghostty/src/renderer/generic.zig`（`rebuildCells` 遍历 `row_dirty`、跳过 clean rows、`clear(y)` + `rebuildRow`）

---

## 阶段三：滚动脏区优化（避免 scroll 触发 full rebuild）

**目标**：流式输出时换行滚动不应标记整屏为脏，从而保留阶段二的增量收益。

**涉及文件**：
- `/Users/fanrenhao/work/TongYou/Packages/TongYouCore/Sources/TYTerminal/Screen.swift`

**具体改动**：
1. 修改 `Screen.swift` 的 `scrollRegionUp()` 和 `scrollRegionDown()`：
   - 将 `dirtyRegion.markFull()` 替换为精确逐行标记。
   - `scrollRegionUp` 只需标记新暴露出的底端行以及发生内容变化的滚动区域内的各行；`scrollRegionDown` 同理。
   - 利用阶段二已具备的 `dirtyRegion.markRange(_:)` 和 `markLine(_:)` 直接表达不连续或连续的脏行集合。
2. 确保 `advanceRow()`（被流式输出频繁调用）触发的滚动不再级联为 `markFull()`。
3. 验证 `MetalRenderer` 对不连续 dirty rows 的处理：由于阶段二已支持逐行 dirty bitset 与 `backingCells` 按行重建，本阶段无需修改渲染侧逻辑，画面应自然正确。

**预期收益**：`opencode` 流式输出时几乎每帧都在滚动，此优化能让 90% 的帧从 full rebuild 降级为 partial rebuild（仅 1~3 行 dirty），CPU 再降 20–30%。

**参考实现**：
- `/Users/fanrenhao/work/ghostty/src/terminal/render.zig`（`RenderState.Dirty` 的 `.partial` 与 `.full` 区分；viewport pin 变化时才是 `.full`）
- `/Users/fanrenhao/work/ghostty/src/renderer/generic.zig`（`rebuildCells` 中根据 `state.dirty` 级别选择全量或逐行重建）

---

## 阶段四：文本 Shaping 缓存与优化

**目标**：消除每帧对所有行重新调用 `CTTypesetter`/`CTLine` 的高昂 CoreText 开销。

**涉及文件**：
- `/Users/fanrenhao/work/TongYou/TongYou/Font/TextShaper.swift`
- `/Users/fanrenhao/work/TongYou/TongYou/Font/CoreTextShaper.swift`（若存在）
- `/Users/fanrenhao/work/TongYou/TongYou/Renderer/MetalRenderer.swift`

**具体改动**：
1. 在 `TextShaper.swift` 或 `MetalRenderer.swift` 中引入**行级 shaping cache**：
   - Key 使用该行文本内容的哈希（或 `String`/`[UInt32]`）+ 字体 ID + 字号。
   - Value 存储已 shaping 的 `GlyphRun` 数组。
   - 缓存容量按屏幕行数 2–3 倍设计（例如 200 行），使用 LRU 淘汰策略。
2. 修改 `MetalRenderer.swift` 的 `rebuildTextRow(row:)`（阶段二已提取的按行重建辅助函数）：
   - 在调用 `buildRuns(forRow:)` 前，先查行级 cache；命中则跳过 `CoreTextShaper.shape(_:)`。
   - clean rows 在 `fillTextInstanceBuffer` 阶段已被 `continue` 跳过，不会进入本函数。
3. CoreText 对象释放优化（可选前置）：
   - 若当前在主线程同步释放大量 `CTLine`/`CTRun`，参考 Ghostty 将释放操作批量投递到独立后台线程（或延迟到帧末统一释放）。

**预期收益**：内容不变或仅光标闪烁的帧，shaping 开销接近 0；流式输出时只有新增/变化行需要重新 shape，CPU 显著下降。

**参考实现**：
- `/Users/fanrenhao/work/ghostty/src/font/shaper/Cache.zig`（shaper cache 结构）
- `/Users/fanrenhao/work/ghostty/src/font/shaper/coretext.zig`（`cf_release_pool` 与 `CFReleaseThread`）
- `/Users/fanrenhao/work/ghostty/src/renderer/generic.zig`（`rebuildRow` 中 `font_shaper_cache` 的使用）

---

## 阶段五：异步字形光栅化（Glyph Atlas 优化）

**目标**：将 cache miss 时的字形绘制与纹理上传从主线程挪走，避免渲染循环被阻塞。

**涉及文件**：
- `/Users/fanrenhao/work/TongYou/TongYou/Font/GlyphAtlas.swift`
- `/Users/fanrenhao/work/TongYou/TongYou/Renderer/MetalRenderer.swift`
- `/Users/fanrenhao/work/TongYou/TongYou/Renderer/MetalView.swift`

**具体改动**：
1. 修改 `GlyphAtlas.swift`：
   - 将 `getOrRasterize` 拆分为 `get`（主线程只读查询）和 `enqueueRasterize`（后台队列异步光栅化）。
   - 使用 `actor` 或 `DispatchQueue` 管理一个异步 rasterization worker。
2. 异步光栅化流程：
   - cache miss 时，主线程在 atlas 中预留一个空白槽位，返回占位坐标。
   - 将 `(glyph, font)` 投递到后台队列进行 `CTFontDrawGlyphs` + `CGContext` 绘制。
   - 绘制完成后，通过 `MTLBlitCommandEncoder`（或 `replace(region:mipmapLevel:...)`）将纹理数据上传到 GPU。
   - 上传完成后再唤醒 DisplayLink 重绘对应区域。
3. 在 `MetalRenderer.swift` 中增加 atlas 变更检测：
   - 仅当 atlas 实际新增/修改了内容时才触发 texture 重上传，与 Ghostty 的 `atlas_grayscale.modified` 计数器思路一致。

**预期收益**：首次显示大量新字符时（例如打开新程序、切换字体大小）不再出现主线程卡顿，整体 CPU 曲线更平滑。

**参考实现**：
- `/Users/fanrenhao/work/ghostty/src/font/SharedGrid.zig`（`renderGlyph` 的同步 but cached 路径与读写锁设计）
- `/Users/fanrenhao/work/ghostty/src/font/Atlas.zig`（`modified` / `resized` 原子计数器）
- `/Users/fanrenhao/work/ghostty/src/renderer/generic.zig`（`drawFrame` 中根据 atlas modified 计数决定是否重上传 GPU texture）

---

## 实施顺序与验证方式

| 阶段 | 优先级 | 验证方式 |
|------|--------|----------|
| 阶段一 | P0（立即做） | `opencode` 流式输出时，Xcode Instruments 中 `displayLinkFired` 采样时间占比下降 |
| 阶段二 | P0 | `buildLinearCells` 调用次数/耗时在 Time Profiler 中大幅减少 |
| 阶段三 | P1 | `scrollRegionUp` 不再出现在 `markFull` 的调用栈中，dirty region 以 partial 为主 |
| 阶段四 | P1 | CoreText 相关函数（`CTTypesetterCreate...`、`CTLineDraw`）采样时间显著下降 |
| 阶段五 | P2 | 首次显示大量文本时，主线程不再出现 >16 ms 的帧时间 spike |

---

## 附：关键参考文件索引

### TongYou 待修改文件
- `/Users/fanrenhao/work/TongYou/TongYou/Renderer/MetalView.swift`
- `/Users/fanrenhao/work/TongYou/TongYou/Renderer/MetalRenderer.swift`
- `/Users/fanrenhao/work/TongYou/TongYou/Terminal/TerminalController.swift`
- `/Users/fanrenhao/work/TongYou/Packages/TongYouCore/Sources/TYTerminal/Screen.swift`
- `/Users/fanrenhao/work/TongYou/TongYou/Font/TextShaper.swift`
- `/Users/fanrenhao/work/TongYou/TongYou/Font/GlyphAtlas.swift`

### Ghostty 参考文件
- `/Users/fanrenhao/work/ghostty/pkg/macos/video/display_link.zig`
- `/Users/fanrenhao/work/ghostty/src/renderer/Thread.zig`
- `/Users/fanrenhao/work/ghostty/src/renderer/generic.zig`
- `/Users/fanrenhao/work/ghostty/src/renderer/Metal.zig`
- `/Users/fanrenhao/work/ghostty/src/terminal/render.zig`
- `/Users/fanrenhao/work/ghostty/src/font/shaper/Cache.zig`
- `/Users/fanrenhao/work/ghostty/src/font/shaper/coretext.zig`
- `/Users/fanrenhao/work/ghostty/src/font/SharedGrid.zig`
- `/Users/fanrenhao/work/ghostty/src/font/Atlas.zig`
