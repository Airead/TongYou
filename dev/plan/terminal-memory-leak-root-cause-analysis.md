# TongYou 内存泄漏根因分析报告

## 摘要

通过对 `TongYou` 项目全量 Swift 代码的逐行审查，本文档确认了 **4 个真实存在的内存泄漏点**。其中 3 个为强引用循环（retain cycle），全部位于 `TerminalWindowView` 中；另 1 个为 `ColorEmojiAtlas` 的无界缓存增长。

**关键纠正**：此前 `terminal-architecture-memory-leak-analysis.md` 将高风险归因于 `MetalView` 的 `CADisplayLink` retain cycle。代码分析表明，`MetalView` 的 `viewDidMoveToWindow(window == nil)` 已自动调用 `stopDisplayLink()` 打破该循环。**真正的根因是上层 `TerminalWindowView` 的 retain cycle 导致整个窗口状态（含 `MetalViewStore`）无法释放**，进而像“锚”一样拖住 `MetalView` → `MetalRenderer` → `TerminalController` → `Screen` 的整棵重型对象树。

---

## 目录

1. [泄漏点 1：configLoader.onConfigChanged 强引用循环](#泄漏点-1configloaderonconfigchanged-强引用循环)
2. [泄漏点 2：sessionManager.onRemoteSessionEmpty 强引用循环](#泄漏点-2sessionmanageronremotesessionempty-强引用循环)
3. [泄漏点 3：sessionManager.onRemoteLayoutChanged 强引用循环](#泄漏点-3sessionmanageronremotelayoutchanged-强引用循环)
4. [泄漏点 4：ColorEmojiAtlas.emojiFontCache 无界增长](#泄漏点-4coloremojiatlasemojifontcache-无界增长)
5. [为什么 CADisplayLink 不是根因](#为什么-cadisplaylink-不是根因)
6. [级联泄漏效应](#级联泄漏效应)
7. [修复建议](#修复建议)
8. [附录：已确认安全的模块清单](#附录已确认安全的模块清单)

---

## 泄漏点 1：`configLoader.onConfigChanged` 强引用循环

**文件位置**：`TongYou/App/TerminalWindowView.swift:772`

**问题代码**：

```swift
configLoader.onConfigChanged = { newConfig in
    windowBackgroundColor = newConfig.background.nsColor
}
```

**泄漏逻辑**：

1. `configLoader` 是 `@State private var configLoader = ConfigLoader()`。由于 `ConfigLoader` 是 `final class`，`@State` 的存储（state storage）强引用持有该实例。
2. 上述闭包修改了 `windowBackgroundColor`（另一个 `@State` 属性），因此 Swift 编译器会让该闭包**强引用**整个 View 的 state storage。
3. 形成循环：
   ```
   State Storage → configLoader (强引用)
   configLoader → onConfigChanged 闭包 (强引用)
   闭包 → State Storage (强引用，因为捕获了 self 的存储)
   ```
4. 当窗口关闭时，`TerminalWindowView` 本应被释放，但此循环阻止了 `@State` 存储的 deallocation。`TerminalWindowView` 连带其下的 `viewStore`、`sessionManager` 等全部泄漏。

**影响评级**：**高**。每次打开并关闭一个窗口，就有一个完整的 `TerminalWindowView` 对象图被钉在内存里。

---

## 泄漏点 2：`sessionManager.onRemoteSessionEmpty` 强引用循环

**文件位置**：`TongYou/App/TerminalWindowView.swift:712`

**问题代码**：

```swift
sessionManager.onRemoteSessionEmpty = { [viewStore, focusManager, sessionManager] sessionID, removedPaneIDs in
    for paneID in removedPaneIDs {
        viewStore.tearDown(for: paneID)
        focusManager.removeFromHistory(id: paneID)
    }
    // ...
    if let index = sessionManager.sessions.firstIndex(where: { $0.id == sessionID }) {
        let paneIDs = sessionManager.closeSession(at: index)
        for paneID in paneIDs {
            viewStore.tearDown(for: paneID)
            focusManager.removeFromHistory(id: paneID)
        }
    }
    if sessionManager.sessions.isEmpty {
        NSApp.keyWindow?.close()
    }
}
```

**泄漏逻辑**：

1. `sessionManager` 是 `final class`（`@State private var sessionManager = SessionManager()`）。
2. 该闭包被赋值给 `sessionManager.onRemoteSessionEmpty` 属性，因此 `sessionManager` **强引用**该闭包。
3. 闭包的 capture list 中显式写了 `[sessionManager]`，没有 `weak` 或 `unowned`，因此闭包**强引用** `sessionManager`。
4. 形成最直接的循环：
   ```
   sessionManager → onRemoteSessionEmpty 闭包 → sessionManager
   ```
5. 这导致 `sessionManager` 本身永远不会释放；而由于 `TerminalWindowView` 的 `@State` 也持有 `sessionManager`，整个窗口视图一起泄漏。

**影响评级**：**高**。只要窗口创建后 `wireRemoteLayoutCallback()` 被调用（即 `onAppear` 时），该循环就必定存在。远程 session 触发 `onRemoteSessionEmpty` 与否不影响循环的形成。

---

## 泄漏点 3：`sessionManager.onRemoteLayoutChanged` 强引用循环

**文件位置**：`TongYou/App/TerminalWindowView.swift:731`

**问题代码**：

```swift
sessionManager.onRemoteLayoutChanged = { [viewStore, focusManager, sessionManager] sessionID, removedPaneIDs, addedPaneIDs in
    // Tear down MetalViews for removed panes.
    for paneID in removedPaneIDs {
        viewStore.tearDown(for: paneID)
        focusManager.removeFromHistory(id: paneID)
    }
    // ...
}
```

**泄漏逻辑**：

与泄漏点 2 **完全相同的模式**：

```
sessionManager → onRemoteLayoutChanged 闭包 → sessionManager
```

**注意**：同文件第 705 行的 `onRemoteDetached` 是安全的，因为它没有捕获 `sessionManager`：

```swift
sessionManager.onRemoteDetached = { [viewStore, focusManager] paneIDs in
    // safe: no sessionManager in capture list
}
```

**影响评级**：**高**。

---

## 泄漏点 4：`ColorEmojiAtlas.emojiFontCache` 无界增长

**文件位置**：`TongYou/Font/ColorEmojiAtlas.swift:58` 及 `:245-252`

**问题代码**：

```swift
// Line 58
private var emojiFontCache: [CGFloat: CTFont] = [:]

// Line 245-252
private func getEmojiFont(size: CGFloat) -> CTFont {
    if let cached = emojiFontCache[size] {
        return cached
    }
    let font = CTFontCreateWithName("Apple Color Emoji" as CFString, size, nil)
    emojiFontCache[size] = font
    return font
}
```

**泄漏逻辑**：

1. `emojiFontCache` 是一个普通 `Dictionary`，永远不会被主动清空。`reset()` 只在字体变更时调用，而字体变更频率极低。
2. `CTFont` 是 Core Foundation 对象，Swift ARC 会自动管理其生命周期，但字典对值是**强引用**。
3. 若用户频繁调整字体大小（`Cmd + +/-`），或在不同 Retina 屏幕间移动窗口导致 `scaleFactor` 变化，`fontSystem.pointSize * fontSystem.scaleFactor` 会产生新的 `CGFloat` key，字典不断插入新的 `CTFont`。
4. 虽然单个 `CTFont` 引用占用内存不大，但这是**确定性、无界增长**的泄漏。

**影响评级**：**中低**。长会话下内存会缓慢增长，但不会瞬间造成 OOM。

---

## 为什么 CADisplayLink 不是根因

此前文档认为 `MetalView` 的 `CADisplayLink` 是“架构层面的固有风险”，理由是：

```swift
// MetalView.swift:789
let link = self.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
```

`CADisplayLink` 确实会强引用其 `target`（`MetalView`），而 `MetalView` 也强引用 `displayLink`，这构成了一个局部 retain cycle。

**但是**，代码中已经存在有效的自救机制：

```swift
// MetalView.swift:632-654
override func viewDidMoveToWindow() {
    MainActor.assumeIsolated {
        if self.window != nil {
            self.startDisplayLink()
        } else {
            self.stopDragAutoScrollTimer()
            self.stopDisplayLink()          // ← 自动 invalidate
            self.removeWindowActivationObservers()
        }
    }
}
```

当 `MetalView` 从窗口层级移除时（tab 切换、窗口关闭、pane 移除），`displayLink` 会被自动 `invalidate()`，retain cycle 随之打破。`MetalView` 自身因此可以被 ARC 回收。

**只有当 `MetalView` 被其他对象强引用时，`displayLink` 才无法释放**。在项目中，这个“其他对象”正是 **`MetalViewStore.views` 字典**和**上层 `TerminalWindowView` 的 retain cycle**。所以 `CADisplayLink` 是**次生现象**，不是根因。

---

## 级联泄漏效应

一旦 `TerminalWindowView` 因上述 3 个 retain cycle 无法释放，会产生恐怖的级联效应：

```
TerminalWindowView @State Storage (leaked)
├── sessionManager (leaked)
├── configLoader (leaked)
├── viewStore: MetalViewStore (leaked)
│   └── views: [UUID: MetalView]  ← 强引用字典
│       └── MetalView (leaked)
│           ├── renderer: MetalRenderer (leaked)
│           │   ├── glyphAtlas: GlyphAtlas
│           │   │   └── texture: MTLTexture (R8, up to 8192×8192)
│           │   ├── emojiAtlas: ColorEmojiAtlas
│           │   │   └── texture: MTLTexture (RGBA, up to 4096×4096)
│           │   ├── frameStates: [FrameState] × 3
│           │   │   ├── uniformBuffer (MTLBuffer, storageModeShared)
│           │   │   ├── bgInstanceBuffer / textInstanceBuffer / emojiInstanceBuffer
│           │   │   └── stagedRowInstances / textRowOffsets / emojiRowOffsets
│           │   ├── backingCells: [Cell] (columns × rows)
│           │   ├── currentSnapshot: ScreenSnapshot
│           │   └── shapedRowCache: ShapedRowCache
│           ├── terminalController: TerminalController (leaked)
│           │   ├── ptyProcess: PTYProcess (leaked)
│           │   ├── screen: Screen (leaked)
│           │   │   ├── cells: [Cell]
│           │   │   ├── scrollbackBuffer: [Cell] (up to 10000 行)
│           │   │   └── altCells: [Cell]
│           │   └── streamHandler: StreamHandler (leaked)
│           └── displayLink (已 stop，但随 view 一起不释放)
```

在高分屏、大窗口（如 300×100 网格）下，`backingCells` + `Screen.cells` + `scrollbackBuffer` + 3 套 Metal shared buffers + atlas textures 的总内存可以轻松达到 **数十 MB 到数百 MB**。**每泄漏一个窗口，内存就固定增长一块**。多 tab / 多 pane 频繁切换时，内存会线性增长，极易触发系统 OOM。

---

## 修复建议

### 高优先级：修复 TerminalWindowView 的 Retain Cycles

**修复方式 1（推荐）**：将 `sessionManager` 捕获改为 `weak`。

对于 `onRemoteSessionEmpty` 和 `onRemoteLayoutChanged`：

```swift
sessionManager.onRemoteSessionEmpty = { [viewStore, focusManager, weak sessionManager] sessionID, removedPaneIDs in
    guard let sessionManager else { return }
    // ... 后续逻辑不变
}
```

```swift
sessionManager.onRemoteLayoutChanged = { [viewStore, focusManager, weak sessionManager] sessionID, removedPaneIDs, addedPaneIDs in
    guard let sessionManager else { return }
    // ... 后续逻辑不变
}
```

**修复方式 2（推荐）**：将 `configLoader.onConfigChanged` 的闭包改为 `[weak self]` 风格，或显式清空回调。

由于闭包内修改的是 `@State` 属性，无法直接使用 `[weak self]`（因为 SwiftUI View 是 value type）。更安全的方式是在 `TerminalWindowView` 的 `onWindowClose` 或视图销毁时显式置空：

```swift
configLoader.onConfigChanged = { [weak configLoader] newConfig in
    // 不可行：无法从外部直接修改 @State
}
```

**更实际的修复**：在 `WindowConfigurator` 的 `windowWillClose` 回调中（或 `TerminalWindowView.onWindowClose` 等价位置）添加：

```swift
configLoader.onConfigChanged = nil
sessionManager.onRemoteSessionEmpty = nil
sessionManager.onRemoteLayoutChanged = nil
sessionManager.onRemoteDetached = nil
```

> 注：`SessionManager` 的这些 callback 属性应允许设为 `nil`。如果当前类型是非 optional，需要改成 `((...) -> Void)?`。

### 中优先级：修复 emojiFontCache 无界增长

**方案 A**：使用 `NSCache<NSNumber, CTFont>` 替代字典，利用其自动 eviction：

```swift
private var emojiFontCache = NSCache<NSNumber, CTFont>()

private func getEmojiFont(size: CGFloat) -> CTFont {
    let key = NSNumber(value: Double(size))
    if let cached = emojiFontCache.object(forKey: key) {
        return cached
    }
    let font = CTFontCreateWithName("Apple Color Emoji" as CFString, size, nil)
    emojiFontCache.setObject(font, forKey: key)
    return font
}
```

**方案 B**：在 `reset()` 之外，为 `applyConfig` 或窗口 DPI 变化等场景增加缓存清理逻辑。

### 低优先级：增加显式 tearDown 兜底

即使修复了 retain cycle，仍建议在窗口关闭时显式清理 `viewStore`：

```swift
// 在 TerminalWindowView 的窗口关闭回调中
for (_, view) in viewStore.allViews {
    view.tearDown()
}
// 或增加 viewStore.tearDownAll() 方法
```

这可以在未来某个代码路径遗漏 `tearDown` 时提供最后一道防线。

---

## 附录：已确认安全的模块清单

| 模块 | 文件 | 状态 | 说明 |
|---|---|---|---|
| `PTYProcess` | `Packages/TongYouCore/Sources/TYPTY/PTYProcess.swift` | ✅ 安全 | `cleanup()` 在 `stop()`/`deinit` 中调用；`[weak self]` 回调 |
| `VTParser` | `Packages/TongYouCore/Sources/TYTerminal/VTParser.swift` | ✅ 安全 | `Sendable struct`，无堆分配资源 |
| `Screen` / `Grid` | `Packages/TongYouCore/Sources/TYTerminal/Screen.swift` | ✅ 安全 | 工作集内存，`maxScrollback` 受控 |
| `GlyphAtlas` | `TongYou/Font/GlyphAtlas.swift` | ✅ 安全 | 有 LRU eviction，缓存有界 |
| `ShapedRowCache` | `TongYou/Font/ShapedRowCache.swift` | ✅ 安全 | 容量固定 300，有 LRU 淘汰 |
| `MetalViewRegistry` | `TongYou/Renderer/MetalViewRegistry.swift` | ✅ 安全 | `NSHashTable<MetalView>.weakObjects()` |
| `SessionManagerRegistry` | `TongYou/App/SessionManagerRegistry.swift` | ✅ 安全 | `NSHashTable<SessionManager>.weakObjects()` |
| `MetalView` Timer | `TongYou/Renderer/MetalView.swift` | ✅ 安全 | `[weak self]` + `invalidate()` |
| `MetalView` observers | `TongYou/Renderer/MetalView.swift` | ✅ 安全 | `removeWindowActivationObservers()` 正确移除 |
| `FileWatcher` | `TongYou/Config/ConfigLoader.swift` | ✅ 安全 | `cancel()` 在 `deinit` 中调用 |
| `SessionManager` client callbacks | `TongYou/App/SessionManager.swift` | ✅ 安全 | 均使用 `[weak self]` |
| `TerminalController` callbacks | `Packages/TongYouCore/Sources/TYTerminal/TerminalController.swift` | ✅ 安全 | 均使用 `[weak self]` |

---

*文档创建时间：2026-04-16*
