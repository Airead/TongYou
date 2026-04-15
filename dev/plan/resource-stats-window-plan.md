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

### Phase 1: 数据层基础

**文件**：`TongYou/Renderer/ResourceMetrics.swift`

- [ ] 定义 `ResourceMetrics` 结构体
- [ ] 实现 `ProcessMemoryInfo` 辅助类，通过 Mach API 读取进程 RSS
- [ ] 添加字节格式化工具（`ByteCountFormatter` 风格）用于 UI 展示

**文件**：`TongYou/Renderer/MetalViewRegistry.swift`

- [ ] 创建 `MetalViewRegistry` 单例（或全局 actor 隔离对象）
- [ ] 使用 `NSHashTable<MetalView>.weakObjects()` 存储活跃视图引用
- [ ] 在 `MetalView.commonInit()` 中注册，`deinit` / `tearDown()` 中移除

**验收标准**：
- 创建 3 个 pane 后 `registry.count == 3`
- 关闭 tab 后对应引用自动释放

### Phase 2: 渲染器暴露数据

**文件**：`TongYou/Renderer/MetalRenderer.swift`

- [ ] 新增 `currentResourceMetrics: ResourceMetrics` 计算属性
- [ ] 汇总当前活跃 `FrameState` 的 buffer capacity / count
- [ ] 读取 `glyphAtlas.textureSize`、`emojiAtlas.textureSize` 和 `activeEntryCount`
- [ ] 读取 `gridSize`
- [ ] 调用 `device.currentAllocatedSize` 获取 Metal 总分配
- [ ] 计算估算内存（buffer 总大小 + atlas 大小）

**文件**：`TongYou/Renderer/MetalView.swift`

- [ ] 将 `private var renderer: MetalRenderer?` 改为 `private(set)` 只读暴露
- [ ] 确保 `renderer` 的访问在主线程安全

**验收标准**：
- 每个 pane 的 `renderer.currentResourceMetrics` 返回合理非零值
- `metalAllocatedSize` 随窗口放大而增长

### Phase 3: UI 窗口

**文件**：`TongYou/App/ResourceStatsView.swift`

- [ ] 使用 `TimelineView(.animation(minimumInterval: 0.5, paused: false))` 驱动刷新
- [ ] 通过 `MetalViewRegistry` 读取所有 pane，为每个 pane 生成 `PaneResourceSnapshot`
- [ ] 顶部展示聚合摘要：总 pane 数、Metal 总分配、进程 RSS
- [ ] 下方 `List` 按 pane 分组，每个 pane 用 `DisclosureGroup` 展开/折叠
- [ ] 分组内用 `Form` / `LabeledContent` 展示 Performance / Buffers / Atlas / Grid / Memory

**文件**：`TongYou/TongYouApp.swift`

- [ ] 在 `@main` 的 `Scene` 中添加：
  ```swift
  Window("Resource Stats", id: "resource-stats") {
      ResourceStatsView()
  }
  .defaultPosition(.topTrailing)
  ```

**文件**：`TongYou/TongYouApp.swift`（Commands 部分）

- [ ] 在 `TongYouCommands` 的 `.windowMenu` 组中添加按钮
- [ ] 通过 `NotificationCenter` 或 `openWindow` 环境值打开窗口（视 SwiftUI 可用 API 而定）

**验收标准**：
- 菜单 `Window → Resource Stats` 可打开独立窗口
- 窗口内容每 0.5 秒刷新
- 关闭 pane 后列表项自动消失

### Phase 4: 测试

**文件**：`TongYouTests/ResourceMetricsTests.swift`

- [ ] 测试 `ProcessMemoryInfo` 返回非零且稳定的 RSS 值
- [ ] 测试 `ResourceMetrics` 的格式化输出（如 `estimatedBufferBytes` 计算正确）
- [ ] 测试 `MetalViewRegistry` 的注册/移除逻辑
- [ ] 测试 `MetalRenderer.currentResourceMetrics` 默认值（使用现有测试用的 mock device 或跳过真机）

**验收标准**：
- 所有新测试通过
- 整体测试覆盖率不下降

### Phase 5: 代码审查与收尾

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
- `TongYou/Font/GlyphAtlas.swift`
- `TongYou/Font/ColorEmojiAtlas.swift`
- `TongYou/App/TerminalWindowView.swift`
- `TongYou/TongYouApp.swift`
