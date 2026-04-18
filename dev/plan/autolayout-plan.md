# 终端模拟器自动布局引擎 (Auto Layout Engine) 架构设计

为了实现一个高度可扩展、支持任意布局策略的终端布局引擎，我们需要将系统的职责清晰划分。本设计采用面向对象的思想，主要分为三个核心模块：**数据模型 (Data Model)**、**布局策略 (Layout Strategies)** 和 **引擎核心 (Engine Core)**。

在深入架构细节之前，我们先梳理现代终端模拟器的布局流派与底层原理。

## 一、 现代终端常见布局流派 (Common Layout Paradigms)

现代终端（如 iTerm2, tmux, Kitty, WezTerm, Zellij）处理窗格布局的方式通常分为以下几种，我们的引擎设计必须能够兼容这些流派：

1. **二叉空间分割 (BSP - Binary Space Partitioning)**

    - **特点**：纯手动布局（iTerm2 和 tmux 的默认行为）。每一次分割都在现有的某个矩形区域内“一分为二”（水平或垂直），形成树状嵌套结构。

2. **主次布局 (Master & Stack / Main-Vertical)**

    - **特点**：平铺式窗口管理器和 Kitty 中流行。屏幕一侧保留一个巨大的“主窗格”（如写代码），剩余新窗格在另一侧垂直或水平堆叠排列（如查看日志）。自动管理位置，突出核心焦点。

3. **网格与均等布局 (Grid / Even)**

    - **特点**：同时监控多个地位平等的任务时使用。系统自动计算最优的行数和列数（如 $2 \times 2$ 或 $3 \times 2$ 的矩阵），让所有窗格面积尽可能大且均匀分布。

4. **螺旋 / 斐波那契布局 (Spiral / Fibonacci)**

    - **特点**：每次新建窗格时，系统自动寻找当前面积最大的窗格并对其对半切分，呈现出向内卷曲的视觉效果。适合大量临时终端的紧凑排布。

5. **堆叠 / 聚焦模式 (Monocle / Zoom)**

    - **特点**：临时让一个窗格全屏显示，其他窗格隐藏或挂起（如 tmux 的 `Prefix + z`）。


## 二、 自动布局引擎的核心实现原理

实现一个布局引擎本质上是在编写一个微型的**平铺式窗口管理器 (Tiling Window Manager)**。它的运作流转如下：

1. **数据结构维护**：不直接记录绝对坐标，而是使用**抽象语法树 (AST)** 记录相对关系（如“水平分割容器”包含 A 和 B）。

2. **算法计算**：当触发布局变动时，自顶向下（从拥有全局宽高 $W \times H$ 的根节点开始），根据各节点的权重或预设规则，递归分配具体的 $(x, y, width, height)$。

3. **渲染与系统调用**：将计算好的几何数据转化为 UI 上的分割线绘制，并通过系统调用向每个底层的 PTY 发送 `SIGWINCH`（Window Change）信号，令终端内运行的程序（如 Vim）重排版。


## 三、 核心概念与数据模型 (Data Model)

引擎的数据结构基于**抽象语法树 (AST)** 或**容器树 (Container Tree)**。与传统的严格二叉树 (BSP) 不同，我们设计一种更通用的节点结构。

### 1. 节点抽象 (Node)

所有屏幕上的元素都是一个节点，它们都具有基本的几何属性。由于终端是以字符网格为单位的，坐标和尺寸均为**整数**。

- `id`: 节点的唯一标识符 (UUID)。

- `rect`: 节点占据的矩形区域，包含 `{x, y, width, height}`（单位：字符列/行）。

- `type`: 节点类型（`Pane` 或 `Container`）。

- `weight` / `flex`: 权重或比例（默认值为 1）。用于在同级节点间非均等地分配剩余空间。

- `isFloating`: 标识该节点是否脱离平铺层，作为悬浮窗口存在。

- `zIndex`: 渲染层级，主要用于悬浮窗口或全屏放大的窗格。


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


## 四、 布局策略接口 (Layout Strategies - 核心扩展点)

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


## 五、 引擎控制器 (Engine Core)

引擎是与用户交互的中心，负责维护根节点 (Root Node)，接收指令并触发重排。

### 1. 核心状态与基础操作

- `rootContainer`: 整个屏幕的平铺根容器。

- `floatingNodes`: 独立于平铺树的悬浮节点列表。

- `activePane`: 当前获得键盘输入的活跃窗格。

- `zoomedPane`: 当前处于临时全屏放大状态的窗格引用。如果为 `null` 则代表正常平铺状态。

- `screenRect`: 整个终端窗口当前的行数和列数。


### 2. 交互与高级控制 API (API)

- `addPane(pane: PaneNode, targetContainer?: ContainerNode)`:

    插入新窗格，并触发 `layoutStrategy.applyLayout` 重新计算。

- `removePane(pane: PaneNode)`:

    从树中移除该窗格，随后触发**树的修剪逻辑 (Pruning)**，并重新排版剩余节点。

- `resizeNode(node: Node, deltaX: number, deltaY: number)`:

    **响应鼠标拖拽或快捷键调宽/窄**。引擎不直接修改 `rect`，而是根据 `delta` 将变化转换为同级相邻节点的 `weight` 比例增减，然后触发 `applyLayout`。

- `MapsFocus(direction: 'up'|'down'|'left'|'right')`:

    **方向性焦点切换**。引擎以当前 `activePane.rect` 的几何边界为基准，向指定方向发射射线 (Ray-casting)，寻找在该方向上几何距离最近且边缘相交的 Pane，将其设为新的 `activePane`。_(如果在全屏态下触发焦点切换，引擎可以选择拦截并提示，或者自动取消全屏态。)_

- `swapPanes(paneA: PaneNode, paneB: PaneNode)`:

    **位置交换 (Swap)**。不改变树的拓扑结构，直接在 AST 中交换这两个节点的位置。

- `movePane(pane: PaneNode, targetNode: Node, direction: 'up'|'down'|'left'|'right')`:

    **结构性迁移 (Relocate)**。将窗格从当前位置拔出（触发原父节点的修剪逻辑），然后移动到 `targetNode` 的指定方向。

- `toggleZoom(pane: PaneNode)`:

    **临时全屏/取消全屏 (Monocle/Zoom)**。

    - **进入 Zoom**：设置 `zoomedPane = pane`。引擎停止平铺树的渲染绘制。直接将 `pane.rect` 覆盖为当前的 `screenRect`，并单独向其底层 PTY 发送 `SIGWINCH`。其他所有 Pane 进入休眠/挂起状态（保留内存，停止渲染）。

    - **退出 Zoom**：设置 `zoomedPane = null`。引擎恢复平铺树的渲染，触发一次全局的 `applyLayout`，让该窗格缩回原本在树中的几何位置。

- `changeLayout(container: ContainerNode, newStrategy: ILayoutStrategy)`:

    **动态切换布局**。替换策略，立即调用新策略重新排版。

- `serialize() / deserialize(json)`:

    **会话状态持久化**。将当前 AST 树（包含每个节点的 `weight`、`type`、`strategy`、关联的执行命令/工作目录等）导出为 JSON。


## 六、 树的生命周期与自清理机制 (Tree Lifecycle)

由于动态布局会导致树结构的频繁变动，引擎必须具备“垃圾回收”和层级扁平化的能力，防止 AST 过度嵌套。在每次 `removePane` 或跨容器移动 Pane 后，引擎自动执行自底向上的检查：

- **规则 1 - 修剪 (Pruning)**: 任何子节点数量为 0 的 `ContainerNode`（即空容器），将被立刻销毁，并从它的父节点中移除。

- **规则 2 - 降级与折叠 (Collapsing)**: 如果一个 `ContainerNode` 在删除子节点后，只剩下 **1 个** 子节点，那么这个容器就失去了存在的意义。引擎会将该容器销毁，并用这**唯一的一个子节点**直接替换掉该容器在父节点中的位置。


## 七、 深入：技术难点与常见“坑点” (Difficulties & Pitfalls)

开发终端布局引擎时，会遇到比普通 Web GUI 复杂得多的底层限制。以下是系统设计必须处理的核心挑战：

### 1. 离散空间限制 (字符网格 vs 像素)

这是终端布局与普通 GUI 布局最大的不同。GUI 窗口是以像素计算的，而终端是以**字符单元格 (Character Cells)** 计算的。所有的坐标和尺寸必须是整数，且外部窗口字体的缩放会动态改变整个网格的行数和列数，引擎必须实时基于字符重新计算，不能依赖绝对像素。

### 2. 递归缩放与联动调整的复杂度

当用户用鼠标拖动两个窗格之间的分割线时（调用 `resizeNode`），如果拖动的是一个父节点的分割线，那么该节点下的**整棵子树**都需要按 `weight` 比例缩放。要正确地自底向上冒泡拖拽事件，再自顶向下重新分配比例，算法极易出现越界。

### 3. 边框 (Borders) 与余数 (Remainder) 处理

终端中的边框也是由字符（如 `│` 或 `─`）绘制的，**边框本身也会占用 1 行或 1 列的空间**。

- **坑点**：假设 100 列均分为 3 份，$100 \div 3 = 33.33$。因为只能是整数，必定剩下 1 列的余数。

- **解法**：策略在计算时必须显式扣除边框空间。除不尽的像素余数，策略应明确决定分配给最后一行/列，或者按 `weight` 补偿给最大的窗格，绝不能丢弃导致黑边。


### 4. 最小尺寸坍缩 (Minimum Size Collapsing)

当用户疯狂切分，或主窗口缩小到极端情况时。

- **坑点**：如果某些 CLI 程序（如 htop）尺寸被挤压到 $\le 1$，PTY 会陷入异常，文字渲染彻底崩溃。

- **解法**：策略发现无法满足 `minWidth` / `minHeight` 时，必须抛出异常回滚改变（让鼠标“拉不动”边框），或静默裁剪隐藏溢出部分。


### 5. PTY 信号风暴 (`SIGWINCH` Thrashing)

- **坑点**：拖拽改变大小时，网格尺寸在短时间内变化数百次。如果每一帧都向底层程序发送 `SIGWINCH`，会导致程序频繁重绘，消耗大量 CPU 并产生严重的画面撕裂闪烁 (Flickering)。

- **解法**：利用**防抖 (Debouncing)** 机制。拖拽期间只重绘 UI 分割线，停止拖拽后（例如静默 50ms）再统一向 PTY 发送最终的 `SIGWINCH` 信号。


### 6. 全屏态 (Zoom) 的渲染泄漏

引入 `zoomedPane` 后，当外部窗口 Resize 时。

- **解法**：必须拦截全局渲染。只将新的 `screenRect` 和防抖后的 `SIGWINCH` 仅仅发送给当前全屏的那一个 PTY。后台被隐藏的 PTY 不要发送尺寸变更信号，防止其在后台乱排版，直到退出 Zoom 时再统一唤醒重排。


### 7. Unicode 与双宽字符的截断 (Wide Character Truncation)

- **坑点**：当窗格因布局调整被缩窄时，其右边缘正好压住了一个“全角字符”（如中文、Emoji，占 2 个字符宽）。如果硬切断它，该字符后半部分丢失不仅导致乱码，还会破坏光标定位，导致后续输出全部错位。

- **解法**：布局引擎计算边界时，必须结合渲染器判断。如果切割线落在双宽字符中间，必须将该字符整体清除，并使用单宽的空格（Space）字符平滑替换其残余位置。


## 八、 总结与扩展性

通过这种设计，**数据模型**（节点和父子关系）是稳定的，**控制逻辑**（防抖、拖拽、持久化、全屏状态机）是集中的，而**排版算法**是完全开放的。

只需实现一个新的 `ILayoutStrategy` 接口对象并注册，就可以瞬间让终端支持斐波那契、六角形或者任意自定义布局，而无需修改超过 90% 的核心引擎代码。这正是策略模式带来的极致扩展性。
