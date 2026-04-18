# TongYou Notification Rings 实现计划

> 文档状态：设计定稿，待实现  
> 范围：MVP 仅支持 **local session** 的 pane/tab/session 三级通知。Remote session 二期扩展。

---

## 一、已确认的设计决策

| 项 | 决策 |
|----|------|
| **视觉反馈** | Pane 蓝环（持久）+ 到达时 Flash（仅 focused pane）+ Tab Badge + Session Sidebar Badge |
| **蓝环实现层** | `MetalView` 内嵌 `CAShapeLayer`，不走 SwiftUI overlay，避免触发 re-render |
| **蓝环颜色** | 固定 `NSColor.systemBlue`，硬编码 |
| **Badge 样式** | 圆点 + 数字（>9 显示 `9+`），背景 systemBlue，白字，字号 9pt |
| **系统 Banner** | **不**使用 macOS 系统通知 |
| **通知音效 / Hook** | MVP **不**加 |
| **清除策略** | 仅当用户 **focus 到具体 pane** 时清除该 pane 通知；切换 tab / session **不**级联清除；App 获得焦点仅清除当前 focused pane |
| **关闭清理** | 关闭 pane/tab/session 时，清除对应 scope 的所有通知 |
| **历史列表 UI** | MVP **不**做，但 `NotificationStore` 保留数据 |
| **Remote Session** | MVP **不**支持，二期通过 server 协议扩展 |

---

## 二、OSC 触发规范（MVP）

`TerminalController` 的 VT Parser 识别以下序列即触发通知：

| 序列 | title | body |
|------|-------|------|
| `OSC 9 ; <body> ST` | `""` | `<body>` |
| `OSC 99 ; ... ST` | 提取或 `""` | 提取或完整内容 |
| `OSC 777 ; notify ; <title> ; <body> ST` | `<title>` | `<body>` |

解析后通过 `controller.onNotification?(title, body)` 上抛。

---

## 三、分阶段实现计划

每个阶段可独立开发、编译、人工验证。建议按顺序执行，但 Phase 1/2 可并行（若两人协作）。

---

### Phase 1：数据模型与基础设施

**目标**：搭建 `NotificationStore`、扩展 `TabAction`、补充 `SessionManager` 的 pane 查找能力。

**涉及文件**：
- 新建 `TongYou/App/NotificationStore.swift`
- 修改 `TongYou/App/TabManager.swift`
- 修改 `TongYou/App/SessionManager.swift`

**实现要点**：
1. `NotificationStore`（`@MainActor @Observable`）：
   - `struct Item`（含 `sessionID/tabID/paneID/title/body/createdAt/isRead`）
   - `add(..., cooldownKey:cooldownInterval:)`
   - `markRead(paneID:)`、`clearAll(forPaneID:)`、`clearAll(forTabID:)`、`clearAll(forSessionID:)`
   - 发布 derived 属性：`unreadPaneIDs: Set<UUID>`、`unreadCountByTabID: [UUID: Int]`、`unreadCountBySessionID: [UUID: Int]`
2. `TabAction` 新增 case：`case paneNotification(UUID, String, String)` // paneID, title, body
3. `SessionManager` 新增方法：
   ```swift
   func paneOwnerIDs(paneID: UUID) -> (sessionID: UUID, tabID: UUID)?
   ```
   遍历所有 session/tab 的 pane tree 与 floating panes，返回匹配结果。

**人工验证步骤**：
1. 运行 `make test`
2. 确认 `NotificationStoreTests` 全部通过（测试覆盖 add、markRead、cooldown、clearAll）

**通过标准**：
- 编译通过，新增单元测试绿灯。

---

### Phase 2：终端触发层（Local Only）

**目标**：让 local pane 中的 OSC 序列能够上抛到 `TerminalWindowView`。

**涉及文件**：
- `TongYou/Terminal/TerminalControlling.swift`
- `TongYou/Terminal/TerminalController.swift`
- `TongYou/Terminal/ClientTerminalController.swift`（透传协议变更，但本期不实现 remote 触发逻辑）
- `TongYou/Renderer/MetalView.swift`
- `TongYou/App/TerminalPaneContainerView.swift`（如有必要透传 closure）
- `TongYou/App/PaneSplitView.swift`
- `TongYou/App/FloatingPaneOverlay.swift`

**实现要点**：
1. `TerminalControlling` 增加 `var onNotification: ((String, String) -> Void)? { get set }`
2. `TerminalController` VT Parser 识别 `OSC 9`、`OSC 99`、`OSC 777 notify`，触发 `onNotification`
3. `MetalView.wireControllerCallbacks` 中绑定 `controller.onNotification`，将其转换为 `onTabAction?(.paneNotification(paneID, title, body))`
4. `PaneSplitView` 与 `FloatingPaneOverlay` 确保 `onTabAction` 管道贯通（无需改动签名，因为已存在 `onTabAction`）

**人工验证步骤**：
1. 启动 App，创建一个 local session
2. 在 pane A 中执行：
   ```bash
   printf '\e]9;hello world\e\\'
   ```
3. 在 `TerminalWindowView.handleTabAction` 内加断点或 `print`
4. 确认控制台输出类似：
   ```
   paneNotification(<paneA-uuid>, "", "hello world")
   ```

**通过标准**：
- 输入 OSC 序列后，`TerminalWindowView` 能收到 `TabAction.paneNotification`，且能正确解析出 paneID。

---

### Phase 3：MetalView 蓝环

**目标**：通知到达后，非 focus pane 显示持久蓝环。

**涉及文件**：
- `TongYou/Renderer/MetalView.swift`
- `TongYou/App/TerminalWindowView.swift`

**实现要点**：
1. `MetalView` 新增：
   - `private let notificationRingLayer: CAShapeLayer`
   - `func setNotificationRing(visible: Bool)`（`CATransaction` 禁用动画即时切换 opacity）
   - `private func updateNotificationRingPath()`（bounds 变化时更新 path，inset 2pt，corner radius 6pt）
   - 在 `commonInit` 中添加 sublayer，在 `setFrameSize` / `layout` 中更新 path
2. `TerminalWindowView`：
   - 持有 `@State private var notificationStore = NotificationStore.shared`
   - 监听：
     ```swift
     .onChange(of: notificationStore.unreadPaneIDs) { _, newIDs in
         for (paneID, view) in viewStore.allViews {
             view.setNotificationRing(visible: newIDs.contains(paneID))
         }
     }
     ```
   - 在 `handleTabAction(.paneNotification(...))` 中：
     - 查 `SessionManager.paneOwnerIDs` 得 `sessionID/tabID`
     - `notificationStore.add(sessionID:tabID:paneID:title:body:)`

**人工验证步骤**：
1. 创建一个 local session，split 出两个 pane：A（focus）和 B（非 focus）
2. 在 pane B 中执行 `printf '\e]9;test\e\\'`
3. 观察 pane B 边框出现蓝色细环
4. 在 pane A 中执行同样命令，观察 pane A **不**出现蓝环（因为下一步是 Flash，但本期可暂不做 Flash，只需确认不显示蓝环即可）

**通过标准**：
- 非 focus pane 收到通知后，边框显示 systemBlue 蓝环。
- focus pane 收到通知后，蓝环保持隐藏。

---

### Phase 4：Flash 动画

**目标**：当通知到达的 pane 恰好是当前 focus pane 时，播放一次蓝色闪光。

**涉及文件**：
- `TongYou/Renderer/MetalView.swift`
- `TongYou/App/TerminalWindowView.swift`

**实现要点**：
1. `MetalView` 新增 `func flashNotificationRing()`：
   - 创建临时 `CALayer`，fill 为 `NSColor.systemBlue`
   - 覆盖全 bounds
   - 添加 `CAKeyframeAnimation`（opacity: `[0, 0.6, 0, 0.6, 0]`，duration 0.9s）
   - 动画结束 `removeFromSuperlayer`
2. `TerminalWindowView` 在 `handleTabAction(.paneNotification(paneID, ...))` 中：
   - 写入 Store 后，判断 `paneID == focusManager.focusedPaneID`
   - 若是，调用 `viewStore.view(for: paneID)?.flashNotificationRing()`

**人工验证步骤**：
1. 确保只有一个 pane（自动 focus）
2. 执行 `printf '\e]9;flash\e\\'`
3. 观察 pane 边框内闪烁蓝色两次（淡入淡出 x2）

**通过标准**：
- Focus pane 收到通知时，有 0.9s 的蓝色闪光动画。
- 非 focus pane 收到通知时，**只**显示持久蓝环，**不** flash。

---

### Phase 5：Badge UI（Tab + Session）

**目标**：Tab 和 Session Sidebar 显示未读数字 badge。

**涉及文件**：
- `TongYou/App/TabBarView.swift`
- `TongYou/App/SessionSidebarView.swift`
- `TongYou/App/TerminalWindowView.swift`

**实现要点**：
1. `TabBarView`：
   - 新增参数 `tabUnreadCounts: [UUID: Int]`
   - 在 `tabItem` 中，标题右侧渲染 badge（数字 >9 显示 `9+`）
   - 未读时隐藏原有的 tabCount gray capsule，或将其左移并列（建议：未读时优先显示蓝 badge，已读后恢复 gray capsule）
2. `SessionSidebarView`：
   - 新增参数 `sessionUnreadCounts: [UUID: Int]`
   - 在 `sessionRow` 中，session 名称右侧渲染蓝 badge（未读时替代或并列 tabCount）
3. `TerminalWindowView`：
   - 把 `notificationStore.unreadCountByTabID` 和 `notificationStore.unreadCountBySessionID` 注入对应视图
   - 可用 `.onChange(of: notificationStore.unreadCountByTabID)` 等触发，但建议直接作为 plain value 传入（视图不内部观察 Store）

**人工验证步骤**：
1. 创建 local session，新建一个 tab（Tab 1 和 Tab 2）
2. 在 Tab 2 的某个 pane 中执行 OSC 通知
3. 观察 Tab 2 的 tab bar 上出现蓝色 badge（数字 1）
4. 切到别的 session，观察 sidebar 上该 session 名称右侧出现蓝色 badge

**通过标准**：
- Tab 和 Session 的未读 badge 正确显示数字。
- badge 样式为 systemBlue 背景 + 白字 + 圆角。

---

### Phase 6：生命周期与清除策略

**目标**：实现用户交互时的自动清除逻辑。

**涉及文件**：
- `TongYou/App/TerminalWindowView.swift`
- `TongYou/App/FocusManager.swift`（如需扩展）

**实现要点**：
1. `TerminalWindowView.onChange(of: focusManager.focusedPaneID)`：
   ```swift
   if let paneID = newID {
       notificationStore.markRead(paneID: paneID)
   }
   ```
2. App 获得焦点：监听 `NSApplication.didBecomeActiveNotification`，对当前 `focusManager.focusedPaneID` 执行 `markRead`
3. 关闭清理：
   - `removePane(id:)` → `notificationStore.clearAll(forPaneID: paneID)`
   - `closeTab(at:)` → `notificationStore.clearAll(forTabID: tab.id)`
   - `closeSession(at:)` → `notificationStore.clearAll(forSessionID: session.id)`

**人工验证步骤**：
1. 在 pane B 发送通知，确认蓝环存在
2. 鼠标点击 focus pane B，确认蓝环立即消失
3. 在 pane A 发送通知（focus 在 A），切到 Tab 2 再切回 Tab 1，确认 pane A 的蓝环**仍然**存在（因为没 re-focus）
4. 关闭包含未读通知的 tab，确认 badge 消失
5. 关闭包含未读通知的 session，确认 sidebar badge 消失

**通过标准**：
- Focus pane 切换后，该 pane 的蓝环和对应 badge 数字立即更新。
- 切换 tab/session 不级联清除未读。
- 关闭 pane/tab/session 后，对应 scope 的通知被清理。

---

### Phase 7：测试补全与验收

**目标**：补全单元测试，全量运行测试套件。

**涉及文件**：
- 新建 `TongYouTests/NotificationStoreTests.swift`
- 修改 `TongYouTests/VTParserTests.swift`
- 可选新建 `TongYouTests/TabBarViewTests.swift` / `TongYouTests/SessionSidebarViewTests.swift`

**测试清单**：
1. `NotificationStoreTests`：
   - `testAddNotification()` — 添加后 unread counts 正确
   - `testCooldown()` — 相同 cooldownKey 在间隔内被去重
   - `testMarkReadPane()` — markRead 后该 pane 从 unread 集合移除
   - `testClearAllForTab()` — 关闭 tab 后该 tab 所有通知清除
2. `VTParserTests`：
   - `testOSC9()`、`testOSC777()` — 确认解析后触发 `onNotification`
3. UI 测试（可选，可用 `ViewInspector` 或 host 测试）：
   - TabBarView 给定 unreadCounts 后 badge 存在且数字正确
   - SessionSidebarView 给定 unreadCounts 后 badge 存在

**人工验证步骤**：
```bash
make test
```

**通过标准**：
- 所有测试绿灯。
- 无编译警告新增。

---

## 四、附录：NotificationStore API 草案

```swift
@MainActor
@Observable
final class NotificationStore {
    static let shared = NotificationStore()

    struct Item: Identifiable, Hashable {
        let id: UUID
        let sessionID: UUID
        let tabID: UUID
        let paneID: UUID?
        let title: String
        let body: String
        let createdAt: Date
        var isRead: Bool
    }

    private(set) var items: [Item] = []

    // MARK: Derived indexes
    private(set) var unreadPaneIDs: Set<UUID> = []
    private(set) var unreadCountByTabID: [UUID: Int] = [:]
    private(set) var unreadCountBySessionID: [UUID: Int] = [:]

    func add(
        sessionID: UUID,
        tabID: UUID,
        paneID: UUID?,
        title: String,
        body: String,
        cooldownKey: String? = nil,
        cooldownInterval: TimeInterval = 5
    )

    func markRead(paneID: UUID)
    func clearAll(forPaneID: UUID)
    func clearAll(forTabID: UUID)
    func clearAll(forSessionID: UUID)
}
```

---

## 五、附录：数据流图（Text）

```
┌─────────────────────┐
│  TerminalController │  VT Parser 识别 OSC 9/99/777
│  (local session)    │  → onNotification?(title, body)
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│      MetalView      │  → onTabAction(.paneNotification(paneID, title, body))
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ TerminalWindowView  │  → 查 SessionManager 得 sessionID/tabID
│                     │  → NotificationStore.shared.add(...)
└──────────┬──────────┘
           │
     ┌─────┴─────┐
     ▼           ▼
┌──────────┐ ┌──────────────┐
│MetalView │ │ TabBarView   │
│蓝环 Layer│ │ Badge        │
└──────────┘ └──────────────┘
     │           │
     └─────┬─────┘
           ▼
┌─────────────────────┐
│ SessionSidebarView  │  Badge
└─────────────────────┘
```

---

## 六、风险与后续扩展

| 风险 | 缓解措施 |
|------|---------|
| `MetalView` 的 `CAShapeLayer` 与 Metal 渲染层级冲突 | 作为 `self.layer` 的 sublayer（在 CAMetalLayer 之上），SwiftUI overlay 不经过该路径 |
| Remote session 不支持 | 已在文档中明确排除，二期通过 server 协议增加 `paneNotification` 消息类型即可 |
| Badge 挤压 Tab 标题空间 | 数字上限 `9+`，字号 9pt，避免三位数 |
| SwiftUI `.onChange` 导致高频刷新 | Store 只暴露 `unreadPaneIDs` 等 coarse-grained 集合，不是数组 diff |
