# Resource Stats 窗口实现计划

## 目标

为 TongYou 添加一个独立的弹出窗口，实时统计并展示应用的资源使用状态，包括：
- 帧性能指标
- Metal 渲染资源（缓冲区、实例数）
- 纹理图集（GlyphAtlas / EmojiAtlas）状态
- 内存使用（Metal 显存分配 + 进程物理内存 RSS）

## 设计原则

- **独立窗口**：不遮挡终端内容，可常驻副屏
- **全局聚合**：读取所有活跃 pane 的数据做汇总和分项展示
- **低开销**：0.5 秒刷新周期，避免主线程压力
- **弱引用解耦**：通过全局注册表避免复杂的窗口到 View 的传递链
- **渐进实现**：每一阶段都能编译运行、人工验证结果

## 数据结构

### ResourceMetrics

```swift
struct ResourceMetrics {
    // Performance
    var frameTimeMs: Double
    var instanceBuildTimeMs: Double
    var gpuSubmitCount: UInt64
    var skippedFrameCount: UInt64

    // Buffers (当前帧状态)
    var bgInstanceCapacity: Int
    var bgInstanceCount: Int
    var textInstanceCapacity: Int
    var textInstanceCount: Int
    var emojiInstanceCapacity: Int
    var emojiInstanceCount: Int
    var underlineInstanceCapacity: Int
    var underlineInstanceCount: Int

    // Atlas
    var glyphAtlasSize: UInt32
    var glyphAtlasEntries: Int
    var emojiAtlasSize: UInt32
    var emojiAtlasEntries: Int

    // Grid
    var gridColumns: UInt32
    var gridRows: UInt32

    // Memory
    var metalAllocatedSize: UInt64
    var estimatedBufferBytes: UInt64
    var estimatedAtlasBytes: UInt64
    var processRSSBytes: UInt64
}
```

### 辅助结构

- `PaneResourceSnapshot`：单个 pane 的资源快照，包含 paneID 和 metrics
- `ProcessMemoryInfo`：封装 `task_info(mach_task_basic_info)` 的 RSS 查询

## 分阶段实现

### Phase 1: 数据层基础（已完成）

**文件**：`TongYou/Renderer/ResourceMetrics.swift`

- [x] 定义 `ResourceMetrics` 结构体
- [x] 实现 `ProcessMemoryInfo` 辅助类，通过 Mach API 读取进程 RSS
- [x] 添加字节格式化工具（`ByteCountFormatter` 风格）用于 UI 展示

**文件**：`TongYou/Renderer/MetalViewRegistry.swift`

- [x] 创建 `MetalViewRegistry` 单例（MainActor 隔离）
- [x] 使用 `NSHashTable<MetalView>.weakObjects()` 存储活跃视图引用
- [x] 在 `MetalView.commonInit()` 中注册，`tearDown()` 中移除

**文件**：`TongYou/Renderer/MetalRenderer.swift`

- [x] 新增 `currentResourceMetrics: ResourceMetrics` 计算属性
- [x] 汇总当前活跃 `FrameState` 的 buffer capacity / count
- [x] 读取 `glyphAtlas.textureSize`、`emojiAtlas.textureSize` 和 `activeEntryCount`
- [x] 读取 `gridSize`
- [x] 调用 `device.currentAllocatedSize` 获取 Metal 总分配
- [x] 计算估算内存（buffer 总大小 + atlas 大小）

**文件**：`TongYou/Renderer/MetalView.swift`

- [x] 将 `private var renderer: MetalRenderer?` 改为 `private(set)` 只读暴露

**验收标准**：
- `make test` 通过
- `ProcessMemoryInfo.currentRSS()` 返回非零值
- 创建 3 个 pane 后 `registry.activeCount == 3`，关闭后自动释放

---

### Phase 2: 窗口与菜单 + 空窗口驱动

**目标**：先让独立窗口能弹出来，并验证 0.5s 刷新在跑。

**文件**：`TongYou/App/TongYouApp.swift`

- [ ] 在 `@main` 的 `Scene` 中添加：
  ```swift
  Window("Resource Stats", id: "resource-stats") {
      ResourceStatsView()
  }
  .defaultPosition(.topTrailing)
  ```

**文件**：`TongYou/App/TongYouCommands.swift`

- [ ] 在 `.windowMenu` 组中添加按钮，通过 `openWindow(id: "resource-stats")` 打开窗口
- [ ] 绑定快捷键（如 `⌘⌥R`）

**文件**：`TongYou/App/ResourceStatsView.swift`

- [ ] 使用 `TimelineView(.animation(minimumInterval: 0.5, paused: false))` 驱动刷新
- [ ] 临时 UI：只显示一行文字，如 `"Active panes: \(MetalViewRegistry.shared.activeCount)"`

**验收标准**：
- 菜单 `Window → Resource Stats` 或快捷键能打开独立窗口
- 文字数字随新开/关闭 pane 实时变化
- 无编译警告或并发隔离错误

---

### Phase 3: 聚合摘要 UI

**目标**：在窗口顶部展示全局汇总数据，暂不需要单个 pane 详情。

**文件**：`TongYou/App/ResourceStatsView.swift`

- [ ] 读取 `MetalViewRegistry.shared.allViews` 的 `renderer?.currentResourceMetrics`
- [ ] 聚合计算：
  - 总 pane 数
  - 所有 pane 的 `metalAllocatedSize` 之和
  - 进程 RSS（取一次即可，全局相同）
- [ ] 用 `VStack` + `LabeledContent` 或 `Form` 展示聚合摘要

**验收标准**：
- 打开多个 pane 后，"Metal Memory" 数字上升；关闭 pane 后下降
- RSS 值与 Activity Monitor 数量级一致
- 刷新过程中 UI 不卡顿

---

### Phase 4: Pane 详情列表

**目标**：把每个 pane 的完整 metrics 按 pane 分组展开显示。

**文件**：`TongYou/App/ResourceStatsView.swift`

- [ ] 下方用 `List` 遍历所有 pane，每项用 `DisclosureGroup`
- [ ] 默认展开第一个 pane，其余折叠
- [ ] 展开内容按区块展示：
  - **Performance**：`frameTimeMs`、`instanceBuildTimeMs`、`gpuSubmitCount`、`skippedFrameCount`
  - **Buffers**：各类 capacity / count
  - **Atlas**：`glyphAtlasSize` + entries、`emojiAtlasSize` + entries
  - **Grid**：`gridColumns` × `gridRows`
  - **Memory**：`metalAllocatedSize`、`estimatedBufferBytes`、`estimatedAtlasBytes`
- [ ] 所有字节值使用 `ByteFormatter.string(from:)`

**验收标准**：
- 能看到每个 pane 的 grid 尺寸、buffer capacity、atlas 条目数
- 调整终端窗口大小后，grid 数字实时变化
- 关闭 pane 后列表项自动消失（弱引用自然释放）

---

### Phase 5: 生命周期与刷新优化

**目标**：优化性能与边界情况，确保长期运行稳定。

**文件**：`TongYou/App/ResourceStatsView.swift`

- [ ] 视图不可见或窗口关闭时停止 `TimelineView` 刷新（`paused: !windowIsVisible`）
- [ ] 0 pane 时显示友好空状态（如 "No active panes"）
- [ ] 验证 `MetalViewRegistry` 无残留引用（开闭多个 tab 后 `activeCount` 归 0）
- [ ] 窗口只打开一次（`openWindow(id:)` 行为确认）

**文件**：`TongYouTests/ResourceMetricsTests.swift`

- [ ] 补充 `MetalRenderer.currentResourceMetrics` 在空闲态的默认值测试
- [ ] 补充 `ByteFormatter` 边界测试（0 字节、极大值）

**验收标准**：
- Resource Stats 窗口长期打开（>5 分钟）不造成 CPU 占用上升
- `make test` 全绿
- 关闭所有 pane 后空状态显示正确

---

### Phase 6: 代码审查与收尾

- [ ] 确保所有 CPU-side 尺寸使用整数类型（符合项目约定）
- [ ] 检查 `MainActor` 隔离：UI 读取和 registry 操作在主线程
- [ ] 检查 `deinit` 中无 actor 隔离属性访问（`MetalView` 的 `displayLink` 等已标记 `nonisolated(unsafe)`）
- [ ] 运行 `make test` 验证无回归
- [ ] 更新 CLAUDE.md 或 README（如有必要）

## UI 布局草图

```
┌─ Resource Stats ──────────────────┐
│  Panes: 4                         │
│  Metal Memory: 24.5 MB            │
│  Process Memory: 145.2 MB         │
├───────────────────────────────────┤
│  ▼ Pane: A1B2C3...                │
│    Performance                    │
│      Frame Time: 2.1 ms           │
│      Build Time: 0.3 ms           │
│      GPU Submits: 12,304          │
│      Skipped: 2                   │
│    Buffers                        │
│      BG: 8,192 / 7,680            │
│      Text: 4,096 / 3,420          │
│      Emoji: 512 / 12              │
│      Underline: 256 / 3           │
│    Atlas                          │
│      Glyph: 2048×2048 (1,234)     │
│      Emoji: 1024×1024 (56)        │
│    Grid                           │
│      160 × 45                     │
│    Memory                         │
│      Metal Allocated: 6.2 MB      │
│      Estimated Buffers: 1.8 MB    │
│      Estimated Atlas: 4.2 MB      │
│  ▶ Pane: D4E5F6...                │
└───────────────────────────────────┘
```

## 风险与注意事项

1. **Mach API 限制**：`task_info` 只能读取本进程信息，无需额外权限，符合沙盒要求。
2. **Metal `currentAllocatedSize` 精度**：该值是驱动报告的总工作集，包含所有 `MTLDevice` 分配，不仅是纹理和缓冲区。展示时应标注为 "Metal Total"，与分项估算对比。
3. **SwiftUI Window ID**：`Window(id:)` 在 macOS 14+ 可用。TongYou 最低部署版本需确认；如果低于 14，可能需要使用 `WindowGroup` + `handlesExternalEvents` 回退方案。
4. **并发安全**：`MetalViewRegistry` 的读写全部在主线程执行，无需额外锁。
5. **性能影响**：`currentAllocatedSize` 和 `task_info` 调用本身开销极小；0.5 秒周期不会对主线程造成可感知影响。

## 相关文件

- `TongYou/Renderer/MetalRenderer.swift`
- `TongYou/Renderer/MetalView.swift`
- `TongYou/Renderer/FrameMetrics.swift`
- `TongYou/Renderer/ResourceMetrics.swift`
- `TongYou/Renderer/MetalViewRegistry.swift`
- `TongYou/Font/GlyphAtlas.swift`
- `TongYou/Font/ColorEmojiAtlas.swift`
- `TongYou/App/TerminalWindowView.swift`
- `TongYou/App/TongYouApp.swift`
- `TongYou/App/TongYouCommands.swift`
- `TongYouTests/ResourceMetricsTests.swift`
