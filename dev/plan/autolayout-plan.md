# 终端模拟器自动布局引擎 (Auto Layout Engine) 架构设计

为了实现一个高度可扩展、支持任意布局策略的终端布局引擎，我们需要将系统的职责清晰划分。本设计采用面向对象的思想，主要分为三个核心模块：**数据模型 (Data Model)**、**布局策略 (Layout Strategies)** 和 **引擎核心 (Engine Core)**。

## 一、 核心概念与数据模型 (Data Model)

引擎的数据结构基于**抽象语法树 (AST)** 或**容器树 (Container Tree)**。与传统的严格二叉树 (BSP) 不同，我们设计一种更通用的节点结构。

### 1. 节点抽象 (Node)

所有屏幕上的元素都是一个节点，它们都具有基本的几何属性。由于终端是以字符网格为单位的，坐标和尺寸均为**整数**。

- `id`: 节点的唯一标识符 (UUID)。

- `rect`: 节点占据的矩形区域，包含 `{x, y, width, height}`（单位：字符列/行）。

- `type`: 节点类型（`Pane` 或 `Container`）。

- `weight` / `flex`: **(新增)** 权重或比例（默认值为 1）。用于在同级节点间非均等地分配剩余空间。

- `isFloating`: **(新增)** 标识该节点是否脱离平铺层，作为悬浮窗口存在。

- `zIndex`: **(新增)** 渲染层级，主要用于悬浮窗口或全屏放大的窗格。


### 2. 窗格节点 (Pane Node - 叶子节点)

这是真正运行终端会话的节点。

- 继承自 `Node`。

- `pty`: 关联的底层伪终端 (Pseudo-Terminal) 对象。

- `content`: 终端屏幕缓冲区 (Screen Buffer)。

- `minWidth`, `minHeight`: 该窗格允许的最小尺寸。


### 3. 容器节点 (Container Node - 内部节点)

容器不显示内容，只负责包含和组织其他节点。

- 继承自 `Node`。

- `children`: 一个包含子节点 (Node) 的有序列表。

- `layoutStrategy`: **核心扩展点**。该容器当前应用的布局策略对象（例如 `HorizontalSplit`, `Grid`, `MasterStack`）。容器根据这个策略来决定如何分配空间给它的 `children`。


## 二、 布局策略接口 (Layout Strategies - 核心扩展点)

这是实现“支持所有可用 layout”和“方便扩展”的关键。我们定义一个统一的接口 `ILayoutStrategy`。任何新的布局只需要实现这个接口即可。

### 1. `ILayoutStrategy` 接口定义

```
interface ILayoutStrategy {
    // 标识符，如 "bsp-horizontal", "grid", "master-stack"
    name: string;

    /**
     * 核心计算方法：
     * 根据 parentRect 的可用空间以及子节点的 weight 属性，
     * 为每个子节点计算出新的 rect，并直接更新到子节点对象中。
     */
    applyLayout(parentRect: Rect, children: Node[]): void;

    /**
     * 当新建一个 Pane 时，决定将其插入到 children 列表的哪个位置。
     */
    getInsertIndex(children: Node[], activePane: PaneNode): number;
}
```

### 2. 具体策略实现示例

- **`BSPHorizontalStrategy`**: 根据子节点的 `weight` 比例，将 `parentRect` 的高度分割给不同的子节点。

- **`GridStrategy`**: 根据子节点数量 $N$，计算最优行数 $R$ 和列数 $C$，按网格均分空间，通常忽略 `weight`。

- **`MasterStackStrategy`**: 将第一个子节点视为 Master，分配较大空间（如 60%）；其余放入 Stack，均分剩余的 40%。


## 三、 引擎控制器 (Engine Core)

引擎是与用户交互的中心，负责维护根节点 (Root Node)，接收指令并触发重排。

### 1. 核心状态与基础操作

- `rootContainer`: 整个屏幕的平铺根容器。

- `floatingNodes`: **(新增)** 独立于平铺树的悬浮节点列表。

- `activePane`: 当前获得键盘输入的活跃窗格。

- `screenRect`: 整个终端窗口当前的行数和列数。


### 2. 交互与高级控制 API (API)

- `addPane(pane: PaneNode, targetContainer?: ContainerNode)`:

    插入新窗格，并触发 `layoutStrategy.applyLayout` 重新计算。

- `removePane(pane: PaneNode)`:

    从树中移除该窗格，随后触发**树的修剪逻辑 (Pruning)**，并重新排版剩余节点。

- `resizeNode(node: Node, deltaX: number, deltaY: number)`:

    **响应鼠标拖拽或快捷键调宽/窄**。引擎不直接修改 `rect`，而是根据 `delta` 将变化转换为同级相邻节点的 `weight` 比例增减，然后触发 `applyLayout`。

- `MapsFocus(direction: 'up'|'down'|'left'|'right')`:

    **方向性焦点切换**。引擎以当前 `activePane.rect` 的几何边界为基准，向指定方向发射射线 (Ray-casting)，寻找在该方向上几何距离最近且边缘相交的 Pane，将其设为新的 `activePane`。

- `swapPanes(paneA: PaneNode, paneB: PaneNode)`: **(新增)**

    **位置交换 (Swap)**。不改变树的拓扑结构，直接在 AST 中交换这两个节点的位置（或直接互换它们绑定的 `pty` 引用和 `weight`），然后触发重排。常用于将某个普通窗口提升为 Master 窗口。

- `movePane(pane: PaneNode, targetNode: Node, direction: 'up'|'down'|'left'|'right')`: **(新增)**

    **结构性迁移 (Relocate)**。将窗格从当前位置拔出（触发原父节点的修剪逻辑），然后移动到 `targetNode` 的指定方向。

    - _实现细节_：如果目标方向与 `targetNode` 的父容器分割策略一致，则直接插入该父容器的 `children` 数组。如果不一致，则用一个新的 `ContainerNode` 替换掉 `targetNode`，并将 `pane` 和 `targetNode` 作为子节点放入新容器中。

- `toggleZoom(pane: PaneNode)`:

    **全屏聚焦模式 (Monocle/Zoom)**。引擎暂存当前的树结构渲染，将目标 `pane` 的 `isFloating` 设为 true，`rect` 强行设为 `screenRect`，`zIndex` 置顶。其他 PTY 挂起渲染。再次触发则还原。

- `changeLayout(container: ContainerNode, newStrategy: ILayoutStrategy)`:

    **动态切换布局**。替换策略，立即调用新策略重新排版。

- `serialize() / deserialize(json)`:

    **会话状态持久化**。将当前 AST 树（包含每个节点的 `weight`、`type`、`strategy`、关联的执行命令/工作目录等）导出为 JSON。反序列化时重建这棵树并重新孵化 PTY 进程。


## 四、 树的生命周期与自清理机制 (Tree Lifecycle)

由于动态布局会导致树结构的频繁变动，引擎必须具备“垃圾回收”和层级扁平化的能力，防止 AST 过度嵌套。在每次 `removePane` 或跨容器移动 Pane 后，引擎自动执行自底向上的检查：

- **规则 1 - 修剪 (Pruning)**: 任何子节点数量为 0 的 `ContainerNode`（即空容器），将被立刻销毁，并从它的父节点中移除。

- **规则 2 - 降级与折叠 (Collapsing)**: 如果一个 `ContainerNode` 在删除子节点后，只剩下 **1 个** 子节点，那么这个容器就失去了存在的意义。引擎会将该容器销毁，并用这**唯一的一个子节点**直接替换掉该容器在父节点中的位置。


## 五、 解决技术难点与坑的设计细节

### 1. 边框 (Borders) 与余数 (Remainder) 处理

**设计规范**: 这必须是**具体布局策略 (`ILayoutStrategy`) 内部**的责任。

策略在计算时必须显式扣除边框占据的 `1` 字符空间。除不尽的像素余数，策略应明确决定是分配给第一行/列，还是按 `weight` 补偿给最大的窗格，绝不能漏算导致黑边。

### 2. 最小尺寸控制 (Minimum Size)

如果在计算过程中，策略发现无论如何分配都会破坏子节点的 `minWidth` 和 `minHeight` 限制，策略可以选择：

1. **静默压缩**: 暂时不渲染超出边界的部分（隐藏溢出的节点）。

2. **拒绝调整**: 引擎捕获异常后，回滚此次改变（例如拖拽边框时，到了极值鼠标就“拉不动”了）。


### 3. PTY 信号风暴 (`SIGWINCH` Thrashing)

**设计引入生命周期**: 引擎计算与底层渲染必须解耦。

当策略计算完所有节点的新的 `rect` 时，**不要立刻**通知底层的 PTY。

引擎利用防抖 (Debouncing) 函数（例如 `setTimeout` 等待 50ms），当不再有新的布局计算或拖拽事件时，统一向底层 `pty` 发送一次 `SIGWINCH` 信号，避免画面撕裂。

## 六、 总结与扩展性

通过这种设计，**数据模型**（节点和父子关系）是稳定的，**控制逻辑**（防抖、拖拽、持久化）是集中的，而**排版算法**是完全开放的。

只需实现一个新的 `ILayoutStrategy` 接口对象并注册，就可以瞬间让终端支持斐波那契、六角形或者任意自定义布局，而无需修改超过 90% 的核心引擎代码。这正是策略模式带来的极致扩展性。
