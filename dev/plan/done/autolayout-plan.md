# TongYou 自动布局引擎实施计划

为 TongYou 引入一个可扩展的自动布局引擎（Tiling Layout Engine），支持多种布局策略（BSP、Grid、MasterStack、Fibonacci 等），并涵盖方向性焦点切换、Zoom、swap/move 等高级交互。

本计划基于 TongYou 现状（严格 BSP 二叉树 + 值类型 `PaneNode`、client/server 双端、SwiftUI + Metal 渲染），将原设计文档（详见本文第六、七章保留内容）映射为可独立实现、可人工验证的分阶段落地方案。

---

## 一、核心决策（已拍板）

| # | 决策 | 说明 |
|---|---|---|
| 1 | **模型 vs 计算分离** | Weight 作为 AST 内状态（可持久化）；Rect 仅为 `solve(...)` 的瞬时输出，**不写回节点**。 |
| 2 | **值语义** | `PaneNode` 继续作为值类型（`indirect enum` + `struct Container`）。所有引擎 API 都是纯函数：输入 `TerminalTab` → 输出新 `TerminalTab`。不引入 reference 类型的 engine 实例。 |
| 3 | **同向连续 split 扁平化** | 向右连续 split 3 次 → 1 个水平 container，4 个同级子节点。符合 iTerm2 / tmux / Kitty 行为，并真正发挥 N-ary 的价值。 |
| 4 | **Weight 语义** | 自由相对值（`[1, 1, 2]` 表示 25% / 25% / 50%）。插入/删除 sibling 不需要重算其他 weight。 |
| 5 | **minWidth / minHeight** | 全局默认 20 列 × 3 行；`TerminalPane` 暂不暴露自定义字段。策略在分配空间时必须尊重该约束。 |
| 6 | **Engine 归属** | 放在 `Packages/TongYouCore/Sources/TYTerminal/Layout/`，纯算法 + `Sendable`，无 UI 依赖。Client 和 Server 共享同一份实现。 |
| 7 | **Floating 归引擎管** | 但仅 P4 阶段纳入；P1–P3 期间 `TerminalTab.floatingPanes` 保持现状。 |
| 8 | **Zoom 状态位置** | 存在 `TerminalTab.zoomedPaneID: UUID?` 上，切 tab 时自然保持。 |
| 9 | **不做向后兼容** | Enum schema 一次性改到位，Swift 穷尽 switch 会引导所有 callsite。 |
| 10 | **旧磁盘 session 丢弃** | 新 schema 直接覆盖；Codable 解旧格式失败时 catch 成空 session list。Wire protocol 同步改，不 bump 版本号。 |

---

## 二、数据模型

### 2.1 `PaneNode`（新）

```swift
// Packages/TongYouCore/Sources/TYTerminal/PaneNode.swift
public indirect enum PaneNode: Equatable, Sendable {
    case leaf(TerminalPane)
    case container(Container)

    public var nodeID: UUID {
        switch self {
        case .leaf(let p):       return p.id
        case .container(let c):  return c.id
        }
    }
}

public struct Container: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var strategy: LayoutStrategyKind
    public var children: [PaneNode]
    public var weights: [CGFloat]       // parallel to children, free relative values

    // Invariant: children.count == weights.count && children.count >= 1
    // collapsing rule will destroy containers with children.count < 2 (see §5)
}
```

### 2.2 `LayoutStrategyKind`

```swift
public enum LayoutStrategyKind: String, Sendable, Codable {
    case horizontal    // horizontal split (top / bottom rows)
    case vertical      // vertical split (left / right columns)
    case grid          // auto-balanced grid (weights ignored)
    case masterStack   // one master + stacked siblings
    case fibonacci     // spiral split (P4+)
}
```

策略通过 enum 派发；新增策略 = 加一个 case + 实现一个 solver 函数。

### 2.3 `Rect`

引入整数字符网格坐标（**不复用 `CGRect`**，CGRect 是 Double，字符网格语义不清晰）：

```swift
public struct Rect: Equatable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
}
```

### 2.4 `TerminalTab` 新增字段

```swift
public struct TerminalTab: Identifiable, Sendable {
    // ... existing fields ...
    public var zoomedPaneID: UUID?   // nil = normal tiled state
}
```

### 2.5 Wire 侧镜像：`TYProtocol/SessionInfo.swift::LayoutTree`

同步改成等价结构。`LayoutTree+PaneNode.swift` 保留双向转换。`BinaryEncoder / BinaryDecoder` 的 LayoutTree 段（~20 行）重写。

---

## 三、布局策略接口

### 3.1 Solver 签名

```swift
// 纯函数：给定父矩形和 container 内容，返回每个 child 的 rect
public protocol LayoutSolver {
    static func solve(
        parentRect: Rect,
        children: [PaneNode],
        weights: [CGFloat],
        minSize: Size,
        dividerSize: Int       // reserved cells between siblings; always 0 initially
    ) -> [Rect]
}
```

`dividerSize` 作为**未来预留参数**：目前 TongYou 分隔符是 SwiftUI 画的几像素细线、不占字符格，`LayoutDispatch` 一律传 `0`。将来若改用字符分隔符（`│ ─ ┼`），solver 层签名无需改动，只需 dispatch 时传 `1`，solver 内部把 `(L - (N-1) * dividerSize)` 作为可分配空间即可。

派发入口：

```swift
public enum LayoutDispatch {
    public static func solve(container: Container, in rect: Rect) -> [Rect] {
        switch container.strategy {
        case .horizontal:  return HorizontalSolver.solve(...)
        case .vertical:    return VerticalSolver.solve(...)
        case .grid:        return GridSolver.solve(...)
        case .masterStack: return MasterStackSolver.solve(...)
        case .fibonacci:   return FibonacciSolver.solve(...)
        }
    }
}
```

### 3.2 插入点策略

```swift
public protocol InsertIndexStrategy {
    static func insertIndex(
        children: [PaneNode],
        activePaneID: UUID?
    ) -> Int
}
```

默认实现：**在 active pane 之后插入**。Grid / Fibonacci 会覆盖成"追加到尾"或"切分面积最大者"。

### 3.3 余数分配规则

整数离散空间下，`L × weight_i / sum(weights)` 几乎总有除不尽的余数。规则：

1. 先把每个 child 的份额**向下取整**，得到基础分配。
2. 余数 = `L - sum(基础分配)`（通常是 1~N-1 个单元）。
3. 把余数**按 weight 降序**依次补给各 child，每人 +1 直到分完；weight 相同时**索引较小的优先**（最左 / 最上）。

这样余数始终倾向"看起来更重要"的 pane，避免布局在再 resolve 时发生视觉跳动。

### 3.4 MinSize 冲突处理

两种触发场景，处理方式不同：

| 场景 | 行为 |
|---|---|
| **用户拖分隔符**（`resizePane`） | 检测到至少一个相邻 child 会 `< minSize` → 直接返回 `nil`（本次 resize 不生效），UI 层表现为"拖不动"。 |
| **窗口整体缩小**（`solveRects` 正常调用） | 允许违反。Solver 仍按 weight 比例分配但**不低于视觉最小 1 单元**；PTY 层收到的 cols/rows 取 `max(actualCells, minSize)` —— 物理尺寸保护 PTY 内程序（htop 等）不崩溃，渲染层对溢出部分直接裁剪。 |

两种场景在 solver 层的区分由调用方传入的上下文决定：solver 本身只负责**报告是否违反**（通过返回额外的 `violated: Bool` 或专用类型），具体是"阻止"还是"裁剪"由引擎上层决定。

### 3.5 各策略具体算法

#### `HorizontalSolver` / `VerticalSolver`

1D 按 weight 比例分配主轴长度：
- `.horizontal` 沿**垂直方向**切分父 rect（上/下堆叠），所有 child 共享父 rect 的宽度
- `.vertical` 沿**水平方向**切分（左/右并列），所有 child 共享父 rect 的高度
- 非主轴维度原样继承父 rect
- 主轴维度 = `父 rect 主轴长 × weight_i / sum(weights)`，按 §3.3 余数规则分配

#### `GridSolver`

N 个子节点排在 R×C 网格中（weights 忽略）：

1. **求最优 R、C**：枚举 `R ∈ [1, N]`，`C = ceil(N / R)`，对每个组合计算单 pane 宽高比 `(W/C) / (H/R)`，选最接近父 rect 宽高比 `W/H` 的那组。
2. **填入顺序**：按行优先。`child[i]` 的 row = `i / C`，col = `i % C`。
3. **最后一行不足时（拉伸填满）**：若最后一行只有 `k < C` 个 pane，该行所有 pane **重新按 `W/k` 分配宽度**（等分整行）；非最后一行维持 `W/C` 宽度。行高对所有行一律 `H/R`。

#### `MasterStackSolver`（二维 solver）

Flat 结构：`children = [master, stack_0, stack_1, ...]`，`weights = [masterWeight, s_0, s_1, ...]`。

- `weights[0] / sum(weights)` 沿**水平方向**给 master（master 永远在左，占宽度 `W × weights[0] / sum`）
- `weights[1..]` 沿**垂直方向**分配给 stack 子节点（按 §3.3 规则切分剩余宽度区域的高度）
- 初始值约定：新建 MasterStack container 时 `weights[0]` 设为**其他 weights 之和的 1.5 倍**，使 master 约占 60%；后续用户拖动 master/stack 边界时更新 `weights[0]`，**不锁定**
- 拖动 stack 内两个相邻 pane 之间的水平分隔条 → 改对应两个 `weights[i]`

未来若需 "main-horizontal"（主在上）变体，新增 `.masterStackTop` kind，不改本策略语义。

### 3.6 拖分隔符的 weight 更新

用户在 HContainer / VContainer / MasterStack 里拖动任意相邻分隔符，**只改相邻两个的 weight**：

1. 根据拖动 delta 像素 → 换算成主轴字符单元 delta
2. 按"当前总主轴长度对应的 weight 总和"比例，把字符 delta 换算成 weight delta
3. 更新 `weights[i] += Δw, weights[i+1] -= Δw`
4. 其他 weight 一律不动

这保证拖一条分隔符不会牵动整行，和 iTerm2 / tmux 行为一致。

### 3.7 扁平化规则（决策 #3 的实现）

`splitPane(tab, targetPaneID, direction, newPane)` 的行为：

```
let targetParent = parent container of targetPaneID
let newStrategy = (direction == .vertical) ? .vertical : .horizontal

if targetParent.strategy == newStrategy:
    // 同方向：直接插入同级（扁平化）
    children.insert(newPane, after: targetPaneID)
    weights.insert(1.0, at: same index)   // 新 child 默认 weight = 1
else:
    // 异方向：创建新 container 替换 target
    let newContainer = Container(
        strategy: newStrategy,
        children: [leaf(target), leaf(newPane)],
        weights: [1.0, 1.0]
    )
    replace target with container(newContainer)
```

---

## 四、引擎 API（`LayoutEngine`）

全部是 `TYTerminal/Layout/LayoutEngine.swift` 下的 `public static` 纯函数。

| 方法 | 签名（简写） | 阶段 |
|---|---|---|
| `splitPane` | `(tab, targetPaneID, direction, newPane) -> TerminalTab?` | P3 |
| `closePane` | `(tab, paneID) -> (TerminalTab, promotedFocusID: UUID?)?` | P3 |
| `resizePane` | `(tab, paneID, edge, deltaCells: Int) -> TerminalTab?` | P3 |
| `solveRects` | `(tab, screenRect) -> [UUID: Rect]` | P1 |
| `focusNeighbor` | `(tab, fromPaneID, direction) -> UUID?` | P4 |
| `swapPanes` | `(tab, paneA, paneB) -> TerminalTab?` | P4 |
| `movePane` | `(tab, paneID, targetPaneID, side) -> TerminalTab?` | P4 |
| `toggleZoom` | `(tab, paneID) -> TerminalTab` | P4 |
| `changeStrategy` | `(tab, containerID, newKind) -> TerminalTab?` | P4 |

`SessionManager` 的原 `splitPane / closePane / updateSplitRatio / updateActivePaneTree` 将在 P3 变成对这些函数的薄包装。

---

## 五、树的自清理规则

每次 `closePane` / `movePane` 后自底向上修剪（复用现有 BSP 的同名规则，只是扩展到 N-ary）：

- **规则 1（Pruning）**：`children.isEmpty` 的 Container 立即销毁，从父节点移除。
- **规则 2（Collapsing）**：`children.count == 1` 的 Container 销毁，用唯一子节点原地替换。
- **规则 3（Merge）**：移除节点后，若父 Container 与祖父 Container 策略相同，可合并同级（例如 `HContainer[A, HContainer[B, C]]` → `HContainer[A, B, C]`）。P3 阶段暂不实现规则 3（先确保正确性，扁平化由 splitPane 前置保证）；P4 的 `movePane` 引入后再加。

---

## 六、分阶段实施

### P1｜接口定稿 + 纯算法层（`TYTerminal/Layout/`）

**目标**：把 §二 / §三 / §四 的接口草案直接落地成代码并实现所有 solver，通过单测。**不动数据模型、不动 SessionManager、不动渲染**。接口和实现一起写——对着 §三 的算法描述边写边调签名，不做独立的"header-only 定稿"阶段（YAGNI）。

**交付物**：
- `TYTerminal/Layout/Rect.swift`（`Rect` / `Size` 整数类型）
- `TYTerminal/Layout/LayoutStrategyKind.swift`
- `TYTerminal/Layout/LayoutSolver.swift`（§3.1 协议 + `dividerSize` 参数）
- `TYTerminal/Layout/Solvers/HorizontalSolver.swift`
- `TYTerminal/Layout/Solvers/VerticalSolver.swift`
- `TYTerminal/Layout/Solvers/GridSolver.swift`（含 §3.5 的 R×C 最优求解 + 最后一行拉伸填满）
- `TYTerminal/Layout/Solvers/MasterStackSolver.swift`（二维 solver，master 比例初值为 stack weight 之和 × 1.5，≈60%）
- `TYTerminal/Layout/LayoutDispatch.swift`（kind → solver 派发，`dividerSize` 一律传 0）
- `TongYouCoreTests/LayoutTests/` — 每个 solver 至少 10 个 case，覆盖：
  - 均匀 weight / 极端 weight（99:1）
  - 余数分配规则（§3.3，验证余数按 weight 降序补 1）
  - minSize 冲突两种场景（§3.4，resize 场景返回 nil / 窗口缩小场景允许降级）
  - Grid R×C 最优求解（6 个 pane 在不同宽高比父 rect 下选择不同组合）
  - Grid 最后一行拉伸填满（5 pane 排 2×3，第二行每个占 50% 宽度）
  - MasterStack 初始比例 ≈60% + 拖动后可任意调整
  - `dividerSize` 传 0 vs 传 1 的对比验证（确认预留参数生效）

**验证**：`swift test --filter LayoutTests` 全绿；人工 review solver 算法与 §三 描述一致。

**风险**：零——新增独立模块，不影响现有代码。

**不做**：数据模型迁移（P2）、`LayoutEngine` 高层 API（P3）、扁平化 `splitPane` 逻辑（P3）、渲染层接入（P2）。

---

### P2｜数据模型迁移（一次性）

**目标**：`PaneNode` enum 从 BSP 二叉树迁移到 N-ary Container 模型；`LayoutTree`、`BinaryEncoder/Decoder`、所有 callsite 同步改到位；磁盘 schema 改版、旧 session 文件丢弃。

**步骤**：

1. 改 `TYTerminal/PaneNode.swift`：
   - 旧：`case split(direction, ratio, first, second)`
   - 新：`case container(Container)`
   - `TerminalTab` 新增 `zoomedPaneID: UUID?`
2. 改 `TYProtocol/SessionInfo.swift::LayoutTree` 镜像。
3. 改 `TYProtocol/BinaryEncoder.swift / BinaryDecoder.swift`：LayoutTree 段重写（weights 作为 `[Float]` 编码）。
4. 改 `TYProtocol/LayoutTree+PaneNode.swift`：双向转换。
5. 让编译器找剩余 callsite：跑 `swift build`，修到 0 error。预计涉及：
   - `App/SessionManager.swift`（Pane Operations 区段 762–979）
   - `App/PaneSplitView.swift`（渲染递归）
   - `App/FocusManager.swift`
   - `App/TabManager.swift`（如仍有引用）
   - `App/TerminalWindowView.swift`
   - `Config/Keybinding.swift`
   - `TYServer/ServerSessionManager.swift` + `SocketServer.swift`
   - `TYAutomation/GUIAutomationRefStore.swift`
6. 磁盘层：`PersistedSession` 解旧格式会失败，在读取入口 try? 后当 nil 处理。用户首次运行新版 session list 为空。
7. 渲染层接入 `LayoutEngine.solveRects(tab, screenRect)`：`PaneSplitView` 不再递归计算比例，而是读取 rect 字典并直接布局子 view。
8. 测试改写：`PaneNodeTests / PaneSplitTests / FocusManagerTests / WireFormatTests / BinaryCoderTests / ServerSessionManagerTests / IntegrationTests / GUIAutomationRefStoreTests` 全部适配新模型。

**验证**：
- `swift build` 全过
- `swift test`（TongYouCore 包）全绿
- `xcodebuild test`（TongYouTests target）全绿
- 手动：新建 session、split 几次、拖动分隔条、重启应用（session list 为空正常）、连 tyd 创建 remote session 并正确渲染

**风险**：
- 高。这是整个计划最重的阶段。
- 缓解：开 feature branch，先把 P1 的 solver 打桩进 PaneSplitView（这样 P2 只需换 AST，不用同时换算法）。
- 不在此阶段实现扁平化的 `splitPane` 逻辑——先让新 AST 跑起来，行为与旧 BSP 等价（每次 split 都建新 container）。**扁平化留给 P3**。

---

### P3｜`LayoutEngine` 引入 + SessionManager 薄化

**目标**：把 SessionManager 里 pane 树的算法部分全部搬进 `LayoutEngine` 纯函数；实现扁平化 splitPane 与正确的 resize/close。

**步骤**：

1. 新建 `TYTerminal/Layout/LayoutEngine.swift`，实现 §四 表中 P3 栏的 5 个函数。
2. `SessionManager.splitPane`（825 行起）→ 调用 `LayoutEngine.splitPane` 并处理 controller 创建。
3. `SessionManager.closePane`（896 行起）→ 调用 `LayoutEngine.closePane`，同时处理 controller 清理和 focus 转移（`promotedFocusID`）。
4. `SessionManager.updateSplitRatio`（939 行起）→ 调用 `LayoutEngine.resizePane`。
5. `SessionManager.updateActivePaneTree`（971 行起）→ 保留（外部更新树的快速路径），但内部走 engine 做一次自清理（pruning + collapsing）。
6. 实现扁平化：`splitPane` 按 §3.3 规则。
7. 补测：`LayoutEngineTests`，覆盖扁平化、pruning、collapsing 各类情况。

**验证**：
- `swift test` 全绿
- 手动：连续向右 split 5 次 → 观察树结构应该是 1 个 HContainer + 6 个 leaf（而非深嵌套）
- 手动：关闭中间 pane → sibling weight 不变，总和重新占满
- 手动：拖动分隔条 → 只有相邻两个 weight 变动
- SessionManager 行数预期瘦身 500–800 行

**风险**：中等。算法集中，测试好写。

---

### P4｜高级功能

以下各子项可**独立合并、独立发版**，顺序按实现成本从低到高：

#### P4.1 Zoom / Monocle

- `TerminalTab.zoomedPaneID` 已在 P2 引入；`LayoutEngine.toggleZoom(tab, paneID)` 写入/清除该字段。
- 渲染层：`solveRects` 看见 `zoomedPaneID != nil` 时返回 `{zoomedID: screenRect}` 单项，其他 pane 不出现。
- PTY 层：仅向 zoomed pane 发 SIGWINCH；其他 pane PTY 尺寸冻结，直到退出 zoom。
- 退出 zoom：清 `zoomedPaneID` + 触发全局 resolve + 向所有 pane 发 SIGWINCH。

#### P4.2 方向性焦点切换

- `LayoutEngine.focusNeighbor(tab, from, direction) -> UUID?`。
- 算法：以当前 pane 的 rect 中心为原点，沿方向查找共享边界最长的邻居（比 ray-casting 简单且足够）。
- 需要 `solveRects` 先跑一次，所以签名可能变成 `(tab, screenRect, from, direction)`。
- 接入 `FocusManager` / `Keybinding`。

#### P4.3 Swap / Move

- `swapPanes`：交换两个 pane 在各自 container 中的位置（不改拓扑）。
- `movePane`：从原 container 拔出（触发 pruning/collapsing），插入到 target 的指定方向。
- 需要同时实现 §五 规则 3（同策略相邻 container 合并）。

#### P4.4 Floating 纳入引擎

- `TerminalTab.floatingPanes` 保留字段，但新增 `layoutStrategy: FloatingLayoutKind`（初始两种：`.free` 保持现状、`.tile` 网格自动排列）。
- `LayoutEngine.solveFloatingRects(tab, screenRect) -> [UUID: Rect]` 分开求解。
- Floating pane 的拖拽/pin/visibility 已有逻辑保留，只是 rect 来源改为引擎输出。

#### P4.5 策略切换

- `changeStrategy(tab, containerID, newKind)`：替换 container 的 `strategy`；`weights` 保持（grid 会忽略）。
- 接入菜单或键位：让用户能把一个 container 从 BSP 切到 Grid / MasterStack。

---

### P5｜坑点处理（原设计文档 §七 对应）

以下每项都可与 P4 并行，或放到 P4 之后：

| 坑点 | 处理位置 | 说明 |
|---|---|---|
| **字符网格离散化** | `Rect: Int` 已强制整数 | P1 已解决 |
| **边框与余数** | 每个 solver 内部 | P1 solver 实现时必须处理：显式扣除分隔符列/行；余数优先分给 weight 最大的 child |
| **最小尺寸坍缩** | solver 内部 + UI 层 | solver 无法满足 minSize 时：(a) resize 场景回滚（拖不动），(b) 窗口缩小场景抛异常→UI 层显示提示 |
| **SIGWINCH 风暴** | 渲染/PTY 层 | 拖拽期间只改 weight + 重绘分隔符；停止拖拽后 debounce 50ms 再向所有 PTY 发 SIGWINCH |
| **Zoom 渲染泄漏** | `solveRects` 已处理 | P4.1 自然满足：zoom 态只返回 zoomed pane 的 rect |
| **双宽字符截断** | 渲染层（MetalView） | 已有双宽字符处理逻辑，只需要在计算终端 col count 时按字符单元而非像素 |

---

## 七、Blast Radius 清单（P2 参考）

一次性要改的文件（Swift 穷尽 switch 会帮你找全遗漏）：

**L1 模型层**
- `Packages/TongYouCore/Sources/TYTerminal/PaneNode.swift`
- `Packages/TongYouCore/Sources/TYTerminal/TerminalTab.swift`（新增 `zoomedPaneID`）

**L2 协议层**
- `Packages/TongYouCore/Sources/TYProtocol/SessionInfo.swift`（`LayoutTree` 镜像）
- `Packages/TongYouCore/Sources/TYProtocol/BinaryEncoder.swift`
- `Packages/TongYouCore/Sources/TYProtocol/BinaryDecoder.swift`
- `Packages/TongYouCore/Sources/TYProtocol/LayoutTree+PaneNode.swift`

**L3 调用层（客户端）**
- `TongYou/App/SessionManager.swift`
- `TongYou/App/PaneSplitView.swift`
- `TongYou/App/FocusManager.swift`
- `TongYou/App/TabManager.swift`（如仍在用）
- `TongYou/App/TerminalWindowView.swift`
- `TongYou/Config/Keybinding.swift`

**L3 调用层（服务端）**
- `Packages/TongYouCore/Sources/TYServer/ServerSessionManager.swift`
- `Packages/TongYouCore/Sources/TYServer/SocketServer.swift`
- `Packages/TongYouCore/Sources/TYAutomation/GUIAutomationRefStore.swift`

**测试**
- `TongYouTests/PaneNodeTests.swift`
- `TongYouTests/PaneSplitTests.swift`
- `TongYouTests/FocusManagerTests.swift`
- `Packages/TongYouCore/Tests/TYProtocolTests/WireFormatTests.swift`
- `Packages/TongYouCore/Tests/TYProtocolTests/BinaryCoderTests.swift`
- `Packages/TongYouCore/Tests/TYServerTests/ServerSessionManagerTests.swift`
- `Packages/TongYouCore/Tests/TYServerTests/IntegrationTests.swift`
- `Packages/TongYouCore/Tests/TYAutomationTests/GUIAutomationRefStoreTests.swift`

**新增文件（P1 + P3）**
- `Packages/TongYouCore/Sources/TYTerminal/Layout/Rect.swift`
- `Packages/TongYouCore/Sources/TYTerminal/Layout/LayoutStrategyKind.swift`
- `Packages/TongYouCore/Sources/TYTerminal/Layout/LayoutDispatch.swift`
- `Packages/TongYouCore/Sources/TYTerminal/Layout/Solvers/*.swift`
- `Packages/TongYouCore/Sources/TYTerminal/Layout/LayoutEngine.swift`
- `Packages/TongYouCore/Tests/TYTerminalTests/LayoutTests/*.swift`

---

## 八、不在本计划范围（Non-Goals）

- **`SessionManager` 拆分**：Remote / Persistence / Command / Floating 四大区段的抽离与本引擎正交，等自然痛点出现再做。P3 后 SessionManager 会因引擎介入自动瘦身 500–800 行，若仍觉庞大再启动独立重构计划。
- **多屏 / 窗口分离**：布局引擎目前只管单个 `TerminalTab` 内部；跨 tab、跨 window 的 pane 迁移不在范围。
- **拖拽交互复杂规则**：如拖 pane 到屏幕边缘自动吸附分组，放到 P4 之后的扩展计划。
- **布局模板库**（"保存当前布局 / 应用布局"）：`serialize / deserialize` 能力已有（Codable），但 UI 层的布局管理器属于独立需求。

---

## 九、原设计文档参考（理论基础）

以下章节的理论讨论已吸收进本计划（§一~八），仅保留作为设计背景参考。

### 9.1 现代终端常见布局流派

1. **BSP (Binary Space Partitioning)**：iTerm2、tmux 默认行为，手动分割形成树状嵌套
2. **Master & Stack**：Kitty、平铺式 WM 风格，主窗格 + 侧边堆叠
3. **Grid / Even**：自动 R×C 均分
4. **Spiral / Fibonacci**：对面积最大者切分，螺旋视觉效果
5. **Monocle / Zoom**：临时全屏一个 pane，其他挂起（tmux `Prefix+z`）

本引擎通过 `LayoutStrategyKind` + solver 抽象，可覆盖以上全部五类（P1 先做 1、2、3；4、5 在 P4）。

### 9.2 核心实现原理

1. **数据结构维护**：AST 记录相对关系（权重 + 容器嵌套），不存绝对坐标
2. **算法计算**：自顶向下递归分配 `(x, y, w, h)`
3. **渲染与系统调用**：UI 绘分隔符 + 向各 PTY 发 `SIGWINCH`

### 9.3 技术难点 & 常见坑点（已在 §P5 中映射到实现位置）

- **离散空间**：字符网格而非像素，全用整数
- **递归缩放**：拖动父容器分割线 → 整棵子树按 weight 缩放
- **边框与余数**：分隔符占 1 列/行；除不尽的余数按策略显式分配
- **最小尺寸坍缩**：`≤ 1` 会让 htop 等崩溃，必须回滚或裁剪
- **SIGWINCH 风暴**：拖拽 debounce 50ms
- **Zoom 渲染泄漏**：只对 zoomed pane 发 SIGWINCH
- **双宽字符截断**：切割线落中间时整体清除并用空格替换

---

## 十、里程碑节奏（建议）

| 阶段 | 预计工作量 | 依赖 |
|---|---|---|
| P1（接口定稿 + 纯算法层） | 3–4 days | — |
| P2（数据模型迁移） | 3–5 days | P1（solver 打桩进 PaneSplitView 做等价验证） |
| P3（LayoutEngine + SessionManager 薄化） | 2–3 days | P2 |
| P4.1 Zoom | 1 day | P3 |
| P4.2 方向焦点 | 1–2 days | P3 |
| P4.3 Swap/Move | 2 days | P3 |
| P4.4 Floating | 2–3 days | P3 |
| P4.5 策略切换 | 1 day | P3 |
| P5 坑点扫尾 | 1–2 days | P4 各项自然包含 |

总计约 **2.5 周**（按全职估）。P2 是单一最大风险点，建议单独一个 branch，完成 + review 后再进 P3。
