# TongYou 终端模拟器五层架构内存泄漏风险分析

## 分析范围

基于 `dev/plan/terminal-architecture-five-layers-analysis-plan.md` 中的五层划分，逐层审查各模块的对象持有关系、闭包捕获、资源生命周期及 GPU/Metal 内存管理，定位最容易产生内存泄漏的层级与根因。

---

## 1. PTY 与 I/O 交互层

**核心文件**
- `Packages/TongYouCore/Sources/TYPTY/PTYProcess.swift`

**风险评级：低**

`PTYProcess` 的生命周期管理相对规范：
- `onRead` / `onExit` 回调内部均使用 `[weak self]`，避免反向强引用。
- `cleanup()` 在 `stop()` 与 `deinit` 中被调用，显式取消 `DispatchSourceRead` / `DispatchSourceProcess`，并通过 `writeQueue.sync {}` 排空待写数据。
- `readSource` 的 `setCancelHandler` 负责释放 `UnsafeMutablePointer<UInt8>` 读取缓冲区。

**潜在问题**
- 若外部持有者（如 `TerminalController`）未调用 `stop()` 且自身因循环引用无法释放，则 `PTYProcess` 会跟随泄漏。但这不是 PTY 层自身的问题，而是上层引用链断裂的次生灾害。

---

## 2. 状态机与序列解析器（VT Parser）

**核心文件**
- `Packages/TongYouCore/Sources/TYTerminal/VTParser.swift`
- `Packages/TongYouCore/Sources/TYTerminal/VTAction.swift`

**风险评级：极低**

`VTParser` 是纯 `Sendable struct`，不持有任何堆分配资源（无引用类型、无闭包、无文件描述符）。每次 `feed` 仅操作栈上状态机和临时数组，不存在泄漏可能。

---

## 3. 终端模型与网格状态（Screen / Grid）

**核心文件**
- `Packages/TongYouCore/Sources/TYTerminal/Screen.swift`
- `Packages/TongYouCore/Sources/TYTerminal/StreamHandler.swift`

**风险评级：中低**

`Screen` 确实持有大量内存（`cells`、`scrollbackBuffer`、`altCells`、临时 reflow 数组），但均为功能所需的工作集：
- `scrollbackBuffer` 上限由 `maxScrollback` 控制（默认 10000 行），属于正常内存占用。
- `reflowResize` 中会产生 `logicalLines`、`newAllCells` 等临时大数组，但都在函数作用域内释放。
- `resetScrollback(deallocate: false)` 保留内存池以减少重复分配，是性能优化而非泄漏。

**潜在问题**
- `StreamHandler` 通过多个闭包（`onWriteBack`、`onTitleChanged`、`onBell` 等）与外部交互，但源码中均使用了 `[weak self]` 或纯值捕获，未形成循环引用。
- 若 `TerminalController` 被异常保留，`Screen` 会跟随存活，但这同样是上层引用链问题。

---

## 4. 字体排版与缓存子系统

**核心文件**
- `TongYou/Font/GlyphAtlas.swift`
- `TongYou/Font/ColorEmojiAtlas.swift`
- `TongYou/Font/ShapedRowCache.swift`

**风险评级：中**

### 4.1 确定性小泄漏：`ColorEmojiAtlas.emojiFontCache` 无界增长

```swift
private var emojiFontCache: [CGFloat: CTFont] = [:]

private func getEmojiFont(size: CGFloat) -> CTFont {
    if let cached = emojiFontCache[size] { return cached }
    let font = CTFontCreateWithName("Apple Color Emoji" as CFString, size, nil)
    emojiFontCache[size] = font
    return font
}
```

**问题**：该字典永远不会被清空。若用户频繁调整字体大小（如连续按放大/缩小快捷键），`emojiFontCache` 会不断插入新的 `CGFloat → CTFont` 条目。`CTFont` 是 Core Foundation 对象，字典持有强引用，导致内存持续增长。虽然单次泄漏量不大，但在长会话中属于确定性泄漏。

### 4.2 Atlas 纹理的动态扩容

`GlyphAtlas.grow()` 与 `ColorEmojiAtlas.grow()` 在 atlas 满时会分配更大的 `MTLTexture`，并将旧纹理内容拷贝过去：
- 旧纹理引用被 `texture = newTexture` 覆盖，正常情况下 ARC 会释放。
- 但如果 GPU 仍有未完成的绘制命令引用旧纹理，旧纹理会延迟释放，造成瞬时内存峰值。

### 4.3 ShapedRowCache

容量固定为 300，具备 LRU 淘汰策略，且 `clear()` 在字体变更时被调用。整体可控，不属于泄漏。

---

## 5. GPU 渲染与窗口系统

**核心文件**
- `TongYou/Renderer/MetalRenderer.swift`
- `TongYou/Renderer/MetalView.swift`
- `TongYou/App/TerminalPaneContainerView.swift`

**风险评级：高**

### 5.1 CADisplayLink 强引用 target 形成天然 retain cycle

```swift
// MetalView.swift
nonisolated(unsafe) private var displayLink: CADisplayLink?

private func startDisplayLink() {
    let link = self.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
}
```

`CADisplayLink` 对 **target 是强引用**。因此：
- `MetalView` → 强引用 `displayLink`
- `displayLink` → 强引用 `MetalView`（target）

这是一个经典的 retain cycle。**唯一的打破方式是在 `MetalView` 被销毁前显式调用 `displayLink.invalidate()`。**

`MetalView` 的 `tearDown()` 和 `deinit` 中都调用了 `stopDisplayLink()`，看起来安全。但关键在于：**`tearDown()` 是否一定被调用？**

### 5.2 SwiftUI / NSViewRepresentable 的生命周期分离导致 tearDown 遗漏风险

`TerminalPaneContainerView`（`NSViewRepresentable`）的 `dismantleNSView` 明确不做清理：

```swift
static func dismantleNSView(_ nsView: MetalView, coordinator: ()) {
    // Do NOT tear down here — the MetalView may be reused when switching tabs.
    // Tear down happens in TerminalWindowView.closeTab(at:).
}
```

这意味着 `MetalView` 的销毁完全依赖 `TerminalWindowView` 在关闭 tab/session 时显式调用 `viewStore.tearDown(for: paneID)`。

**如果任何代码路径遗漏了 `tearDown()` 调用**：
- pane 被 server 端关闭但 client 回调未触发
- SwiftUI view identity 变化导致 paneID 与 viewStore 中的键不再匹配
- 远程 session 的 `onRemoteLayoutChanged` / `onRemoteDetached` 等异步回调在 view 已不在窗口层级时执行
- `closeTab` 被异常中断

则 `displayLink` 会继续在主线程 runloop 中运行，`MetalView` 永远不会被 ARC 回收。

### 5.3 泄漏规模巨大

一旦 `MetalView` 泄漏，它会连带拖住整个重型对象图：

```
MetalView
├── renderer: MetalRenderer
│   ├── glyphAtlas: GlyphAtlas (R8 texture, up to 8192×8192)
│   ├── emojiAtlas: ColorEmojiAtlas (RGBA texture, up to 4096×4096)
│   ├── frameStates: [FrameState] × 3
│   │   ├── uniformBuffer (MTLBuffer, storageModeShared)
│   │   ├── bgInstanceBuffer / textInstanceBuffer / emojiInstanceBuffer
│   │   └── stagedRowInstances / textRowOffsets / emojiRowOffsets
│   ├── backingCells: [Cell] (columns × rows)
│   ├── currentSnapshot: ScreenSnapshot (可能包含全部 cells)
│   └── shapedRowCache: ShapedRowCache
├── terminalController: TerminalController
│   ├── ptyProcess: PTYProcess
│   ├── screen: Screen
│   │   ├── cells: [Cell]
│   │   ├── scrollbackBuffer: [Cell] (up to 10000 rows)
│   │   └── altCells: [Cell]
│   └── streamHandler: StreamHandler
├── displayLink: CADisplayLink (retain cycle)
├── cursorBlinkTimer: Timer
└── dragAutoScrollTimer: Timer
```

在高分屏、大窗口（如 300×100 网格）下，`backingCells` + `Screen.cells` + `scrollbackBuffer` + 3 套 Metal shared buffers + atlas textures 的总内存可以轻松达到 **数十 MB 到数百 MB**。每泄漏一个 pane，内存就固定增长一块。

### 5.4 Timer 的附加 retain cycle

`cursorBlinkTimer` 和 `dragAutoScrollTimer` 通过闭包捕获 `self`：

```swift
cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
    MainActor.assumeIsolated { ... }
}
```

虽然闭包内部使用了 `[weak self]`，但 `Timer` 对象本身被 `MetalView` 强引用。如果 `MetalView` 已经因为 `displayLink` 无法释放，`timer` 也会继续存在。更糟的是，`timer` 的 fire 会不断触发 `MainActor.assumeIsolated` 闭包执行，即使 `self` 为 nil 时直接返回，也造成了不必要的 CPU 开销。

---

## 结论：最容易产生内存泄漏的部分

**第 5 层 — GPU 渲染与窗口系统（MetalView / MetalRenderer）**

### 根本原因

1. **CADisplayLink 的 target 强引用** 构成了 `MetalView` 自身的 retain cycle，这是架构层面的固有风险。
2. **SwiftUI `NSViewRepresentable` 的生命周期与显式 `tearDown()` 解耦**，使得打破 retain cycle 的主动权不在框架手中，而依赖业务代码在所有销毁路径上正确调用 `viewStore.tearDown(for:)`。
3. **泄漏后果严重**：单个泄漏的 `MetalView` 会拖住 `MetalRenderer`、`TerminalController`、`Screen`、`PTYProcess` 以及大量 GPU/CPU 混合内存，形成“一漏漏一片”的级联效应。

相比之下，第 4 层的 `emojiFontCache` 虽然也是确定性泄漏点，但单次泄漏量小（仅一个 `CTFont` 引用），且触发频率低。第 5 层的泄漏一旦发生在多 pane、多 tab、频繁切换 session 的场景下，会在短时间内造成显著的内存增长，甚至触发系统 OOM。

---

## 改进建议

### 针对第 5 层

1. **为 `MetalView` 添加基于 `viewDidMoveToWindow` 的自救机制**  
   当 `window == nil` 时，除了停止 `displayLink`，还应将 `renderer` 和 `terminalController` 置为 nil，确保即使 `tearDown()` 被上层遗漏，view 脱离窗口后也能尽快释放重型资源：
   ```swift
   override func viewDidMoveToWindow() {
       // ... 现有逻辑 ...
       if self.window == nil {
           self.stopDisplayLink()
           self.renderer = nil
           self.terminalController = nil
       }
   }
   ```

2. **审查所有 `viewStore.tearDown(for:)` 调用路径**  
   对 `TerminalWindowView` 中关闭 tab/session、远程 detach、layout update 移除 pane 等代码路径进行静态审查，确保每个被移除的 `paneID` 都对应一次 `tearDown`。建议将 `tearDown` 逻辑集中到 `MetalViewStore` 的 `deinit` 或 pane 移除的单一入口中。

3. **在 `MetalRenderer` 中添加 `invalidate()` 方法**  
   显式释放 `currentSnapshot`、`backingCells`、`shapedRowCache` 以及标记 `frameStates` 为无效，避免在 `MetalView` 泄漏期间继续累积 GPU 缓冲区和快照数据。

### 针对第 4 层

1. **为 `ColorEmojiAtlas.emojiFontCache` 设置容量上限或 LRU 淘汰**  
   若字体大小变化范围有限，可用 `NSCache<NSNumber, CTFont>` 替代普通字典；或在 `reset()` / `applyConfig` 时清空该缓存。

2. **在 `GlyphAtlas` / `ColorEmojiAtlas` 的 `grow()` 中加入旧纹理释放提示**  
   虽然 ARC 最终会释放旧 `MTLTexture`，但在 `grow()` 后可考虑调用 `texture.setPurgeableState(.empty)`（若 storage mode 支持），主动向系统提示旧纹理可被回收。

---

*文档创建时间：2026-04-16*
