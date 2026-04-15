# 阶段二：增量快照（避免深拷贝整个 grid）细分计划 — 逐行 dirty 对齐 Ghostty

**母文档**：[rendering-performance-optimization-plan.md](./rendering-performance-optimization-plan.md)

**总体目标**：彻底对齐 Ghostty 的逐行 dirty 模型，让 `DirtyRegion` 支持**不连续的多行**增量更新，从而消除 `Screen.snapshot()` 每帧深拷贝整个 `grid` 的开销；同时让 `MetalRenderer` 只重建真正变脏的行。

**核心参考**：Ghostty 的 `terminal.RenderState` 为每一行维护独立的 `dirty: bool`。`Renderer.rebuildCells` 遍历所有行，clean row 直接 `continue`，dirty row 才执行 `clear(y) + rebuildRow(y)`。

---

## 子阶段 2.1：升级 DirtyRegion 为逐行 bitset

**目标**：把 `DirtyRegion` 从单个连续 `lineRange` 升级为按行追踪的 bitset，支持不连续脏行。

**涉及文件**：
- `Packages/TongYouCore/Sources/TYTerminal/Screen.swift`

**具体改动**：
1. 重写 `DirtyRegion`：
   ```swift
   public struct DirtyRegion: Equatable, Sendable {
       public var fullRebuild: Bool
       private var lineBits: [Bool]

       public init(rowCount: Int = 0, fullRebuild: Bool = false) {
           self.fullRebuild = fullRebuild
           self.lineBits = [Bool](repeating: false, count: rowCount)
       }

       public static let clean = DirtyRegion(rowCount: 0, fullRebuild: false)
       public static let full = DirtyRegion(rowCount: 0, fullRebuild: true)

       public mutating func markLine(_ row: Int) {
           guard !fullRebuild else { return }
           if row >= lineBits.count {
               lineBits.append(contentsOf: [Bool](repeating: false, count: row - lineBits.count + 1))
           }
           lineBits[row] = true
       }

       public mutating func markRange(_ range: Range<Int>) {
           guard !fullRebuild else { return }
           let maxRow = range.upperBound - 1
           if maxRow >= lineBits.count {
               lineBits.append(contentsOf: [Bool](repeating: false, count: maxRow - lineBits.count + 1))
           }
           for i in range { lineBits[i] = true }
       }

       public mutating func markFull() {
           fullRebuild = true
           lineBits.removeAll()
       }

       public mutating func merge(_ other: DirtyRegion) {
           if other.fullRebuild { markFull(); return }
           for (i, dirty) in other.lineBits.enumerated() where dirty {
               markLine(i)
           }
       }

       /// 兼容旧 API：返回合并后的连续范围（partial 模式下方便旧代码过渡）。
       public var lineRange: Range<Int>? {
           guard !fullRebuild else { return nil }
           let indices = lineBits.enumerated().compactMap { $1 ? $0 : nil }
           guard let first = indices.first, let last = indices.last else { return nil }
           return first..<(last + 1)
       }

       public var isDirty: Bool {
           fullRebuild || lineBits.contains(true)
       }

       /// 逐行迭代脏行（Ghostty 风格）。
       public var dirtyRows: [Int] {
           guard !fullRebuild else { return [] }
           return lineBits.enumerated().compactMap { $1 ? $0 : nil }
       }

       public func isDirty(row: Int) -> Bool {
           guard !fullRebuild else { return true }
           return row < lineBits.count && lineBits[row]
       }
   }
   ```
2. 修改 `Screen` 中 `dirtyRegion` 的初始化：
   - 从 `DirtyRegion.full` 改为 `DirtyRegion(rowCount: rows, fullRebuild: true)`。
3. 更新 `Screen` 中所有调用 `dirtyRegion.markLine` / `markRange` 的代码：
   - 无需改动调用点（API 签名不变），但注意 `markRange` 内部现在会按行设置 bit。
4. 更新 `consumeDirtyRegion()`：
   - 返回当前 `dirtyRegion` 后，重置为 `DirtyRegion(rowCount: rows, fullRebuild: false)`（保留行数，避免后续 `markLine` 频繁扩容）。

**人工验证方式**：
1. 在 `Screen` 中添加一个内部测试入口或临时日志：
   ```swift
   print("dirtyRegion rows=\(dirtyRows)")
   ```
2. 构建并运行，在终端中快速敲击键盘（例如输入 `abc`，然后回车，再输入 `d`）。
3. **预期结果**：
   - 输入 `a` 时日志显示 `[cursorRow]`。
   - 输入回车时（假设触发 `scrollRegionUp` 当前仍 `markFull()`），日志显示 `fullRebuild=true`。
   - 后续阶段三会把 `scrollRegionUp` 的 `markFull()` 改为逐行标记，届时可见不连续或连续的多行 dirty。

---

## 子阶段 2.2：ScreenSnapshot 支持不连续脏行

**目标**：让 `Screen.snapshot()` 在 `dirtyRegion.fullRebuild == false` 时，仅深拷贝真正 dirty 的行，且能表达不连续分布。

**涉及文件**：
- `Packages/TongYouCore/Sources/TYTerminal/Screen.swift`

**具体改动**：
1. 扩展 `ScreenSnapshot`：
   ```swift
   public let isPartial: Bool
   public let dirtyRows: [Int]
   public let partialRows: [(row: Int, cells: [Cell])]
   ```
   - `isPartial == true` 时：`cells` 为空数组，`partialRows` 只包含 dirty 的行（每行附带其逻辑行号 `row`）。
   - `isPartial == false` 时：保持现有行为（`cells` 为完整网格）。
2. 修改 `Screen.snapshot(selection:)`：
   - 当 `!dirtyRegion.fullRebuild && dirtyRegion.isDirty && viewportOffset == 0` 时：
     - 遍历 `dirtyRegion.dirtyRows`，对每一行深拷贝 `columns` 个 `Cell` 到 `[Cell]`。
     - 构造 `partialRows`。
   - 其他情况（`fullRebuild`、scrollback、无脏行）走全量路径。
3. **隔离 `snapshot.cells` 的误用**：
   - `ScreenSnapshot.cell(at:col:row:)` 在 `isPartial == true` 时直接 `fatalError("Partial snapshot does not support random cell access; use renderer backing store.")`。

**人工验证方式**：
1. 临时日志：
   ```swift
   print("snapshot partial=\(isPartial) dirtyRows=\(dirtyRows.count) copiedCells=\(dirtyRows.count * columns)")
   ```
2. 构建并运行，执行以下动作：
   - 在终端输入一行文字（同一行连续输入多个字符）。
   - 另开一屏执行 `echo -e "line1\nline2"`。
3. **预期结果**：
   - 普通逐字符输入：`dirtyRows.count == 1`，`copiedCells == columns`。
   - `echo` 输出两行时（在阶段三之前可能仍触发 `markFull`）：会显示 `partial=false`；若阶段三已完成，则应看到 `dirtyRows.count == 2` 或更多（不连续或连续均可）。

---

## 子阶段 2.3：Renderer Backing Store + 按行重建

**目标**：让 `MetalRenderer` 维护 `backingCells`，并在 `fillBgInstanceBuffer` / `fillTextInstanceBuffer` 中跳过 clean rows，只重建 dirty rows。

**涉及文件**：
- `TongYou/Renderer/MetalRenderer.swift`

**具体改动**：
1. 新增 `backingCells`：
   ```swift
   private var backingCells: [Cell] = []
   private var backingColumns: Int = 0
   private var backingRows: Int = 0
   ```
2. 修改 `setContent(_:)`：
   ```swift
   if snapshot.isPartial {
       assert(snapshot.columns == backingColumns && snapshot.rows == backingRows)
       for (row, cells) in snapshot.partialRows {
           let dst = row * backingColumns
           backingCells.replaceSubrange(dst..<(dst + backingColumns), with: cells)
       }
   } else {
       backingCells = snapshot.cells
       backingColumns = snapshot.columns
       backingRows = snapshot.rows
   }
   ```
3. **迁移所有 `snapshot.cells[...]` 访问点到 `backingCells`**。
   涉及的函数清单：
   - `fillBgInstanceBuffer`
   - `fillUnderlineInstanceBuffer`
   - `buildRuns(forRow:)`
   - `fillTextInstanceBuffer`
   - `patchTextInstanceColors`
4. **升级 `fillBgInstanceBuffer` 为逐行 dirty 检查**：
   - 将原来的 "按 `dirtyRegion.lineRange` 连续区间写" 改为：
   ```swift
   for row in 0..<rows {
       if !dirtyRegion.fullRebuild && !dirtyRegion.isDirty(row: row) { continue }
       // ... 写该行的 bg instances
   }
   ```
   - 这样即使脏行不连续，也能只更新对应的行。
5. **升级 `fillTextInstanceBuffer` 为只重建 dirty rows**（Ghostty `rebuildCells` 风格）：
   - 保留 CPU 侧 staging buffer（`stagedTextInstances`、`stagedEmojiInstances`、`textRowRanges`、`emojiRowRanges`）。
   - 新增 `rebuildTextRow(row: Int, ...)` 辅助函数，复用 `buildRuns` + `flushTextSegment`。
   - 修改逻辑：
     ```swift
     if dirtyRegion.fullRebuild || contentChanged /* 且需要全量时 */ {
         // 全量：清空 staged，遍历所有行 rebuild
     } else if contentChanged {
         // Partial：只遍历 dirty rows，替换这些行在 staged 中的范围，再整体 compact
     } else {
         // Cursor blink：patch colors
     }
     ```
   - 注意：若某帧 dirty rows 不连续（如第 3 和第 7 行），partial 路径只对第 3、7 行调用 `rebuildTextRow`，其余行直接复制旧 instances。
6. `resize()` 中 grid 尺寸变化时，清空 `backingCells`（`backingColumns = 0`），并 `markFull()` 等待全量快照。

**人工验证方式**：
1. 临时日志（`fillTextInstanceBuffer` 入口）：
   ```swift
   let dirtyCount = (0..<grid.rows).filter { dirtyRegion.isDirty(row: Int($0)) }.count
   print("fillText full=\(dirtyRegion.fullRebuild) dirtyCount=\(dirtyCount)/\(grid.rows)")
   ```
2. 构建并运行，执行普通输入、流式输出（`opencode` / `yes`）、改变窗口大小、鼠标选择、scrollback 滚动。
3. **预期结果**：
   - 画面完全正确，无错位、无空白行、无残留。
   - 非全量帧日志显示 `dirtyCount` 为 1–3（或不连续的几行），远小于 `grid.rows`。
4. Xcode Instruments → Time Profiler，录制流式输出 5 秒：
   - **预期结果**：`buildLinearCells` 采样时间和调用次数大幅下降；`fillTextInstanceBuffer` 中 `buildRuns` / `CoreTextShaper.shape` 的耗时同样下降。

---

## 子阶段 2.4：边界处理、Metrics 与单元测试

**目标**：覆盖 resize、selection、scrollback、alternate screen 的自动回退；添加可观测指标；写自动化测试。

**涉及文件**：
- `Packages/TongYouCore/Sources/TYTerminal/Screen.swift`
- `TongYou/Renderer/MetalRenderer.swift`
- `TongYou/Renderer/FrameMetrics.swift`
- `TongYouTests/`

**具体改动**：
1. **Resize 回退**：`MetalRenderer.resize()` 在 `gridSize` 变化时 `markFull()` 并清空 `backingCells`。
2. **Selection 变化**：现有 `setContent(_:)` 已检测 `selectionChanged` 并 `markFull()`。
3. **Viewport offset != 0**：`Screen.snapshot()` 在 `viewportOffset != 0` 时仍走 `buildViewportCells()` 全量路径。
4. **Alternate screen buffer**：切换 buffer 时已触发 `markFull()`，自动全量。
5. **新增 Metrics**：
   - `FrameMetrics.snapshotCellCopyCount`：记录 `setContent` 时实际拷贝的 cell 数（`partialRows.map { $0.cells.count }.reduce(0, +)` 或全量 `cells.count`）。
   - 在 `ResourceMetrics` 中暴露，便于 Debug Metrics HUD 观察。
6. **新增单元测试**：
   - `DirtyRegionTests.swift`：
     - 测试 `markLine` 后 `dirtyRows` 返回 `[3]`。
     - 测试 `markLine(3)` + `markLine(7)` 后 `dirtyRows` 返回 `[3, 7]`（不连续）。
     - 测试 `markRange(1..<4)` 后 `isDirty(row: 2) == true`、`isDirty(row: 5) == false`。
     - 测试 `merge` 两个不连续 `DirtyRegion`。
   - `ScreenPartialSnapshotTests.swift`：
     - 模拟输入两个不连续字符（跳行），验证 `snapshot.dirtyRows` 包含对应行、`partialRows` 数量正确。
     - 验证 `markFull()` 后 `isPartial == false`。
   - `MetalRendererBackingCellsTests.swift`：
     - 构造 partial snapshot（只更新第 3 和第 7 行），调用 `setContent()`，验证 `backingCells` 中仅这两行变化。
     - 构造全量 snapshot 调用 `setContent()`，验证 `backingCells` 被完整替换。

**人工验证方式**：
1. 运行测试：
   ```bash
   xcodebuild test -scheme TongYou -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:TongYouTests
   ```
2. **预期结果**：所有新增和现有测试全部通过。
3. 手动回归测试：`vim`/`nano`、resize、scrollback，画面正确。
4. 开启 `debugMetrics`，观察 HUD 中的 `snapshotCellCopyCount`：
   - 流式输出时约为 `columns × 1~3`。
   - 清屏、resize、滚动时跳变为 `columns × rows`。

---

## 设计要点总结（与 Ghostty 的对应关系）

| Ghostty 概念 | TongYou 等价实现 |
|-------------|------------------|
| `terminal.RenderState.Row.dirty` | `DirtyRegion.lineBits[row]` |
| `RenderState.update` 拷贝脏行 | `Screen.snapshot()` 的 `partialRows` + `setContent()` 按行合并到 `backingCells` |
| `Dirty` 枚举 (`.false`/`.partial`/`.full`) | `DirtyRegion` (`isDirty` + `fullRebuild`) |
| `rebuildCells` 中 `if (!dirty) continue` | `fillBgInstanceBuffer` 和 `fillTextInstanceBuffer` 中逐行检查 `isDirty(row:)` |
| `Contents.clear(y)` | `bgInstanceBuffer` 直接覆盖 dirty rows；`textInstanceBuffer` 通过 CPU 侧 `staged*` + compact 实现等价效果 |
| `rebuildRow` | 提取的 `rebuildTextRow(row:...)` 辅助函数 |

---

## 参考实现

- `/Users/fanrenhao/work/ghostty/src/terminal/render.zig`（`RenderState.Row.dirty`、`update` 按行拷贝）
- `/Users/fanrenhao/work/ghostty/src/renderer/generic.zig`（`rebuildCells` 遍历 `row_dirty`、跳过 clean rows、`clear(y)` + `rebuildRow`）
