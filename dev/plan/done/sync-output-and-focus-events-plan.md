# Terminal Mode 补齐实施计划：Synchronized Output (2026) + Focus Events (1004)

## 背景

排查远程模式下 claude code 渲染错位时发现，daemon 的 `StreamHandler.setDECMode`
对多个 DECSET/DECRST mode 做了 silent drop。根因是宿主终端（ghostty）环境变量
泄漏让 claude code 走了依赖 mode 2026 的渲染路径。当前临时 fix 通过
`TERM_PROGRAM=TongYou` 让 claude code 退化到不依赖 2026 的路径，但根本问题
没解决：

- 只要换成会**主动**发 mode 2026 的 TUI（neovim、tmux、btop、textual
  应用），问题会重现。
- Mode 1004 focus events 也是一并在日志里出现的 `handled=unknown`，虽然
  不导致错位，但会让现代 TUI 无法感知窗口 focus 变化、错过必要的重绘。

本计划把这两个高价值 mode 的支持补齐。2031 / 47 / 1047 / 1048 经调研
已决定暂不实现（详见调研结论，不在本 plan 范围）。

## 总体设计

### Mode 2026 核心语义

应用发 `CSI ? 2026 h`（BSU, Begin Synchronized Update）开始一批更新，发
`CSI ? 2026 l`（ESU, End Synchronized Update）结束。在 BSU..ESU 期间，
**terminal 内部 Screen 仍然实时处理 escape sequences**——只是**不把中间
状态推给 client 渲染**。ESU 或超时（业界通用 150–200ms）后，把累积的最终
状态**一次性**推给 client。

关键理解：2026 是**发送侧去抖动**，不是 escape sequence 的缓冲。我们的
daemon → client 的 snapshot 推送就是发送侧。

DECRQM 查询（`CSI ? 2026 $ p`）应返回 `CSI ? 2026 ; 2 $ y`，表示"支持，
当前未激活"（state=2 = reset）。

### Mode 1004 核心语义

应用发 `CSI ? 1004 h` 订阅 focus 事件。订阅期间，窗口/pane 获得焦点时
terminal 向 PTY 写入 `CSI I`，失去焦点时写入 `CSI O`。

TongYou 已经在 `FocusManager` 维护每个 session/tab 的 focused pane，接上即可。

### 影响面

| 组件 | 2026 改动 | 1004 改动 |
|---|---|---|
| `TerminalModes` | 加 case 2026 | 加 case 1004 |
| `Screen` | 记录 sync 状态 + 起始时间 | - |
| `StreamHandler` | 拦截 2026 DECSET/DECRST、处理 DECRQM | 拦截 1004、`onFocusReportingChanged` 回调 |
| `TerminalCore` | 透传 sync 状态给 SocketServer 判断是否 defer flush | 收到 focus in/out 时 PTY write |
| `SocketServer.performFlush` | 对 sync 中的 pane 跳过推送 + 超时兜底 | - |
| GUI 侧 focus manager | - | pane 切换 focus 时通知 TerminalCore |
| 本地模式 | - | 本地也要接（MetalView 焦点变化时通知 controller） |

两个 mode 互相独立，可以分别实现独立提交。

## Phase 1：实现 DECSET 1004 Focus Event Reporting

先做 1004，因为实现简单、风险低，先把 plumbing（pane → 外部事件）跑通，
再做更复杂的 2026。

### 目标

- `TerminalModes` 识别 mode 1004。
- StreamHandler 在 1004 开启/关闭时通过回调通知上层。
- 本地模式：MetalView focus in/out 时调用 controller 的 focus 报告接口。
- 远程模式：GUI 侧 focus 通知 daemon（复用 `.focusPane` RPC 的路径，或
  单独加一条轻量 `focusState` 事件），daemon 对应 pane 的 TerminalCore
  写入 `\e[I` / `\e[O`。

### 涉及文件

- `Packages/TongYouCore/Sources/TYTerminal/TerminalModes.swift`
- `Packages/TongYouCore/Sources/TYTerminal/StreamHandler.swift`
- `Packages/TongYouCore/Sources/TYServer/TerminalCore.swift`
  （加 `reportFocus(_ focused: Bool)` 接口，仅在 mode 1004 开启时 write）
- `Packages/TongYouCore/Sources/TYServer/ServerSessionManager.swift`
  （把 focus 事件路由到对应 core）
- `Packages/TongYouCore/Sources/TYServer/SocketServer.swift`
  （dispatch 新的 focus event 消息，或在现有 `focusPane` 里附带 bool）
- `Packages/TongYouCore/Sources/TYProtocol/MessageTypes.swift` +
  `BinaryEncoder.swift` / `BinaryDecoder.swift`
  （若新增 wire 消息）
- `Packages/TongYouCore/Sources/TYClient/RemoteSessionClient.swift`
- `TongYou/App/SessionManager.swift`
  （`notifyPaneFocused` 扩展）
- `TongYou/Renderer/MetalView.swift`
  （本地路径也要产生焦点事件）
- `TongYou/Terminal/TerminalController.swift`
  （本地路径透传给 TerminalCore）

### 协议决策（二选一）

**方案 A（推荐）**：扩展现有 `.focusPane(sessionID, paneID)` 消息，改成
`.focusPane(sessionID, paneID, focused: Bool)`。但这会改 wire format，
对 client 升级有兼容压力。

**方案 B**：新增 `.paneFocusEvent(sessionID, paneID, focused: Bool)`。
老的 `.focusPane` 仍只是"把谁设为 focused pane"的状态通知，不负责发
CSI I/O。**优点**：语义不混；老 client 不用改就能继续工作。**建议走 B。**

### 实现要点

1. `TerminalModes.Mode` 新增 `focusEvents = 1004`，在 `bit` 表里分配新位。
2. `StreamHandler.setDECMode` 新 case：
   ```swift
   case .focusEvents:
       onFocusReportingChanged?(value)
   ```
   `StreamHandler` 新 public 字段 `var onFocusReportingChanged: ((Bool) -> Void)?`。
3. `TerminalCore` 内维护 `focusReportingEnabled: Bool`（ptyQueue 独占），
   提供 `reportFocus(_ focused: Bool)` 方法：仅在 `focusReportingEnabled = true`
   时 PTY write `\x1b[I` 或 `\x1b[O`；否则什么都不做。
4. `ServerSessionManager` 新方法 `reportFocus(paneID:focused:)`，转发给对应
   `TerminalCore`。
5. `SocketServer`：收到新的 wire 消息时调用上面那个方法。
6. `SessionManager`（GUI）在 `notifyPaneFocused` 里：
   - **状态变化时**（旧 focused pane → 失去 focus，新 pane → 获得 focus）
     各发一次 `focusEvent(..., focused: false/true)`。
   - 注意：本地模式不走网络；直接调 `TerminalController.reportFocus(_:)`。
7. 窗口级 focus（整个 app inactive / active）也应触发对**当前 focused pane**
   发事件。`NSApplication.didResignActive` / `didBecomeActive` 已有观察者
   （`TongYouApp.installFocusTraceObservers`），在那里顺带触发。

### 测试

`Packages/TongYouCore/Tests/TYTerminalTests/StreamHandlerTests.swift`
（如不存在则新建）：

- `focusReportingModeToggles` — 发 `\e[?1004h` / `\e[?1004l`，验证
  `onFocusReportingChanged` 按预期回调。
- `focusReportingInitiallyOff` — 默认为 false。

`Packages/TongYouCore/Tests/TYServerTests/TerminalCoreTests.swift`：

- `reportFocusWritesCSIWhenEnabled` — 开启 1004 后调 `reportFocus(true)`
  应向 PTY 写入 `\x1b[I`。
- `reportFocusNoOpWhenDisabled` — 默认不发任何字节。

协议层 roundtrip test（如采用方案 B）：
- `roundTripPaneFocusEvent`

### 完成标准

- 运行 vim 后在 pane 间切换 focus，vim 的 focus events autocommand 被触发
  （`autocmd FocusGained` / `FocusLost`）。
- 远程模式和本地模式行为一致。
- 现有 focus 相关测试无 regression。

---

## Phase 2：实现 DECSET 2026 Synchronized Output

### 目标

- `Screen` 维护 sync 状态（active + 起始时间）。
- StreamHandler 处理 2026 DECSET/DECRST 和 DECRQM 查询。
- `SocketServer.performFlush` 对 sync 中的 pane 跳过推送，但保留 dirty 标记。
- 超时兜底：200ms 强制退出 sync 并 flush，避免应用崩溃导致屏幕永远冻结。

### 涉及文件

- `Packages/TongYouCore/Sources/TYTerminal/TerminalModes.swift`
- `Packages/TongYouCore/Sources/TYTerminal/Screen.swift`
- `Packages/TongYouCore/Sources/TYTerminal/StreamHandler.swift`
- `Packages/TongYouCore/Sources/TYServer/TerminalCore.swift`
- `Packages/TongYouCore/Sources/TYServer/ServerSessionManager.swift`
- `Packages/TongYouCore/Sources/TYServer/SocketServer.swift`

### 实现要点

#### 2.1 Screen / StreamHandler 层面

1. `TerminalModes.Mode` 新增 `syncedUpdate = 2026`。
2. `Screen` 加字段：
   ```swift
   public private(set) var syncedUpdateActive: Bool = false
   public private(set) var syncedUpdateStartedAt: Date?
   ```
   以及方法：
   ```swift
   public func beginSyncedUpdate()   // 置 true、记录时间、返回
   public func endSyncedUpdate()     // 置 false、清时间
   public func expireSyncedUpdateIfStale(timeout: TimeInterval) -> Bool
       // 超时自动清除，返回是否发生过期
   ```
3. `StreamHandler.setDECMode` 新 case：
   - `value = true` → `screen.beginSyncedUpdate()`
   - `value = false` → `screen.endSyncedUpdate()`
4. **DECRQM 查询响应**：`CSI ? 2026 $ p` 请求 mode 状态。当前 `StreamHandler`
   已有 `handleDSR`，需要扩展一套 DECRQM 处理（走 `?` private + `$` 中间
   字节）。返回：
   - 当前 `syncedUpdateActive = true` → `CSI ? 2026 ; 1 $ y`
   - 当前 `syncedUpdateActive = false` → `CSI ? 2026 ; 2 $ y`
   - 没实现 → `CSI ? 2026 ; 0 $ y`（不走这条路径，我们实现了）

#### 2.2 SocketServer.performFlush 层面

1. 在 flush loop 开头对每个 pane：
   ```swift
   // 先让 Screen 自己判断是否该 expire（避免应用崩溃永久冻结）
   if sessionManager.expireStaleSyncedUpdate(paneID: key.paneID, timeout: 0.2) {
       Log.debug("Synced update expired for pane \(paneShort)", category: ...)
   }

   if sessionManager.isSyncedUpdateActive(paneID: key.paneID) {
       // defer: 保留 pane 在 dirtyPanes 里，下次 flush 再试
       deferred.insert(key)
       continue
   }

   // 正常 consumeSnapshot + send 流程
   ```
2. flush 结束时把 `deferred` 重新合并回 `dirtyPanes`。
3. **调度下次 flush**：如果本次有 deferred，用一个较小的 tick 间隔（例如
   20ms）定期重试，直到所有 pane 要么退出 sync，要么被 expire 强制 flush。
   这一行为不能和现有的 coalesce 调度逻辑冲突——deferred 的重试是
   **独立计时器**，不增加 `consecutiveFlushCount`。

#### 2.3 兼容性与边界

- **cmd+shift+l / refreshPane 诊断路径**：应无视 sync 状态，强制推。
- **首次 attach**：client attach 时拉 full snapshot，也无视 sync 状态（避免
  client 卡在空画面上）。
- **Client disconnect / session close**：清理该 pane 的 sync 状态，防止
  daemon 端状态残留。`TerminalCore.teardown` 里加 `screen.endSyncedUpdate()`
  的调用（通过一个 public reset 方法）。
- **多 client**：所有 client 看到同样的 deferred 行为。不同 client 独立维护
  `lastSentState` 不受影响。

#### 2.4 超时值选择

文档默认使用 200ms。实测：
- neovim / tmux 的一次 sync 窗口通常 < 50ms，200ms 足够宽裕。
- 再长（例如 500ms）会让应用崩溃后屏幕冻结感知明显。
- 做成可配置：`daemon-synced-update-timeout = 200`（新配置项，毫秒）。

### 测试

`Packages/TongYouCore/Tests/TYTerminalTests/ScreenTests.swift`：

- `syncedUpdateBeginAndEndTogglesFlag` — 开启/关闭切换 `syncedUpdateActive`。
- `expireSyncedUpdateReturnsFalseWhenInactive` — 未开启时 expire no-op。
- `expireSyncedUpdateClearsAfterTimeout` — 时间前进超过 timeout 后 expire
  返回 true 并清零。使用可注入的 `Date` 源（避免 sleep）。

`Packages/TongYouCore/Tests/TYTerminalTests/StreamHandlerTests.swift`：

- `mode2026EnterExitCallsScreen` — 发 `\e[?2026h` / `\e[?2026l` 切换
  Screen 的 sync flag。
- `decrqm2026ReportsReset` — 未激活时 DECRQM `CSI ? 2026 $ p` 回复
  `CSI ? 2026 ; 2 $ y`。
- `decrqm2026ReportsSet` — 激活时回复 `CSI ? 2026 ; 1 $ y`。

`Packages/TongYouCore/Tests/TYServerTests/SocketServerTests.swift`
（如不存在则新建）：

- `performFlushDefersPaneInSyncedUpdate` — pane 处于 sync 时 flush 不发送。
- `performFlushSendsAfterSyncEnd` — sync 结束后 flush 正常发送最终快照。
- `performFlushExpiresStaleSyncAfterTimeout` — 超时后自动 flush，即使应用
  没发 `\e[?2026l`。

### 完成标准

- neovim 开启 `:set cursorline` + 大文件滚动时，远程模式无 tearing。
- 人为在 sync 中杀掉 TUI 进程（模拟崩溃），200ms 后画面恢复更新，不会
  永远冻结。
- 新增的单测 + 回归测试全绿。

---

## Phase 3：验收 + 临时 debug 代码清理

2026 和 1004 都落地后，一并做收尾：

1. 删除这次调查期间加的临时诊断代码（`[ALT]` / `[MODE]` / `[ENV]` trace、
   `Screen.debugPaneTag`、`refreshPane` RPC、`cmd+shift+l` 绑定、
   `debug_refresh_pane` keybinding action）。这些在 commit
   `152c913 debug(cursor-trace)` 中引入，可以整体 revert 或按文件清理。
2. 如果 Phase 2 实装顺利，之前的 workaround（`TERM_PROGRAM=TongYou` 强制
   覆盖）**保留**——它仍然是正确的做法（终端模拟器应该宣告自己身份），
   不要回滚到继承宿主值。
3. 在 `dev/plan/done/` 归档本 plan。

## 风险与不做清单

- **不做**：全局 DECRQM 响应基础设施。只为 2026 实现最小 DECRQM 处理，
  避免扩大范围。
- **不做**：Phase 2 里的 sync defer 不要用复杂的跨线程 condition variable；
  用现有 dirtyPanes + 小 timer tick 重试就够，保持 flush 路径单线程。
- **风险**：超时值设置不当。太短会让正常 sync 也被截断，表现为 tearing；
  太长会让崩溃冻结可见。默认 200ms 参考 wezterm / microsoft terminal 的
  选择。做成可配置以便调优。
