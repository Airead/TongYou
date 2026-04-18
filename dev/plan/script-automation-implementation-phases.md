# TongYou 脚本自动化分阶段实施计划

本文档将 [script-automation-plan.md](./script-automation-plan.md) 中的设计方案拆分为**可独立实现、可人工验证**的多个阶段，便于逐步推进和迭代。

---

## Phase 1：GUI Socket 基础设施

### 目标
建立 GUI App 侧的自动化控制服务器与 CLI 侧的基础连接能力，确保两者能正常通信，并参照 daemon 侧的三层安全加固（commit `4c6537b`）完成 GUI Socket 的安全基线。

### 涉及文件
- `Packages/TongYouCore/Sources/TYAutomation/GUIAutomationServer.swift`（新建核心逻辑，含连接状态机；新模块 `TYAutomation`）
- `Packages/TongYouCore/Sources/TYAutomation/GUIAutomationAuth.swift`（新建，token 生成/持久化/清理）
- `Packages/TongYouCore/Sources/TYAutomation/GUIAutomationPaths.swift`（新建，运行时目录与 per-PID 路径助手）
- `Packages/TongYouCore/Sources/TYClient/AppControlClient.swift`（新建客户端，含握手逻辑）
- `Packages/TongYouCore/Sources/TYProtocol/TYSocket.swift`（复用已有 `listen()` 和 `peerCredentials()`）
- `TongYou/App/GUIAutomationService.swift`（新建 App 级服务门面）
- `TongYou/TongYouApp.swift`（启动时初始化 GUIAutomationServer，退出时清理 socket/token）

### 路径约定
与 daemon 共享运行时目录，避免运行时文件散落：
- Socket：`<runtime-dir>/gui-<pid>.sock`（runtime-dir 在 macOS 为 `~/Library/Caches/tongyou/`，否则为 `$XDG_RUNTIME_DIR/tongyou/`）
- Token：`<runtime-dir>/gui-<pid>.token`
- 通过 PID 后缀支持多个 GUI 实例并存

### 实现要点
1. `GUIAutomationServer` 在 App 启动时绑定 `<runtime-dir>/gui-<pid>.sock`
2. Accept loop 跑在独立 `DispatchQueue`，派生独立任务处理每个客户端
3. 实现 JSON/Line 基础解析（按 `\n` 分帧）
4. 注册一个 `server.ping` 内部命令，返回 `{"ok":true,"result":"pong"}`
5. CLI 侧实现 `tongyou app ping`，连接 GUI Socket 并发送握手 + ping

### 安全加固（参照 daemon 三层方案）

**Layer 1 — 文件权限**
- 运行时目录强制为 `0o700`：复用 `ServerConfig.ensureParentDirectory`
- socket 文件 bind 后立即 `chmod 0o600`（由 `TYSocket.listen()` 自动完成）
- GUI 正常退出时删除自己 PID 对应的 socket 与 token 文件，避免孤儿文件残留

**Layer 2 — Peer credential 校验**
- 每个 accept 到的连接调用 `getpeereid()` 获取对端 UID/GID
- 若对端 UID ≠ `getuid()`，立即关闭连接并记录日志（不返回错误体，避免探测）
- 复用 `TYSocket` 中 daemon 侧已有的 `peerCredentials()` 实现，避免重复代码

**Layer 3 — Token 握手认证**
- GUI 启动时生成 32 字节随机 token（`SecRandomCopyBytes`），写入 `~/.tongyou/tongyou-gui-<pid>.token`，权限 `0o600`
- 连接状态机：`awaitingHandshake → authenticated`
- 客户端首条消息必须是 `handshake { token }`，token 不匹配则返回 `UNAUTHENTICATED` 并关闭
- 在 `authenticated` 之前，除 `handshake` 外所有命令（含 `server.ping`）都返回 `UNAUTHENTICATED`
- CLI 侧：连接建立后先读取 token 文件、发送握手，成功后才执行用户命令
- GUI 退出时删除 token 文件；Phase 8 的 `SocketPathResolver` 需同步读取 token

### 人工验证步骤
```bash
# 运行时目录（macOS 默认）
RT=~/Library/Caches/tongyou

# 1. 启动 TongYou GUI App
# 2. 确认 socket 与 token 文件已创建且权限正确
ls -ld "$RT"
# 期望：drwx------（0700）

ls -l "$RT"/gui-*.sock "$RT"/gui-*.token
# 期望：两者均为 -rw-------（0600）

# 3. 执行 ping 命令
./tongyou app ping
# 期望输出：pong

# 4. 关闭 GUI App 后确认 socket/token 已清理
ls "$RT"/gui-*.sock "$RT"/gui-*.token 2>&1
# 期望：No such file or directory

# 5. GUI 未运行时执行 ping
./tongyou app ping
# 期望输出：TongYou GUI not running（或类似提示）

# 6. 跳过握手直接发命令（用 nc 或自定义脚本）
echo '{"cmd":"server.ping"}' | nc -U "$RT"/gui-*.sock
# 期望：返回 {"ok":false,"error":{"code":"UNAUTHENTICATED",...}} 并关闭连接

# 7. 使用错误 token 握手
echo '{"cmd":"handshake","token":"wrong"}' | nc -U "$RT"/gui-*.sock
# 期望：UNAUTHENTICATED，连接关闭

# 8. 跨 UID 访问（需 sudo 或切换用户）
sudo -u nobody ./tongyou app ping
# 期望：连接被服务端关闭，客户端报错
```

### 完成标准
- GUI 运行时 `tongyou app ping` 成功返回
- GUI 关闭后 `tongyou app ping` 提示未运行，且 socket/token 文件被清理
- 运行时目录为 `0o700`，socket/token 文件为 `0o600`
- 同 UID 进程可连接，不同 UID 在 `getpeereid()` 阶段即被拒绝
- 未完成握手或 token 错误的连接无法执行任何业务命令

---

## Phase 2：Ref 映射系统与 Session 查询

### 目标
实现稳定的 Ref 句柄分配和映射，支持 `session.list` 命令查询当前 GUI 中的所有会话。

### 涉及文件
- `TongYou/App/GUIAutomationRefStore.swift`（新建）
- `GUIAutomationServer.swift`（新增 list 处理）
- `AppControlClient.swift`（新增 list 命令）

### 实现要点
1. `GUIAutomationRefStore` 维护 `ref → UUID` 和 `UUID → ref` 双向映射
2. 分配规则：
   - Session：用户命名优先，未命名则 `sess:1`, `sess:2`...
   - Tab：`<session>/tab:1`, `tab:2`...
   - Tree Pane：`<session>/pane:1`, `pane:2`...
   - Float Pane：`<session>/float:1`, `float:2`...
3. `refreshRefs()` 遍历 `SessionManager.sessions` 及其 tabs/panes/floatingPanes
4. Ref 一旦分配**永不回收**
5. `session.list` 返回所有 session 的名称/类型/tabs/panes 数量
6. CLI 侧实现 `tongyou app list`

### 人工验证步骤
```bash
# 1. 启动 GUI App，手动创建：
#    - 1 个未命名 local session
#    - 1 个命名为 "dev" 的 local session（含 2 个 tab，第 2 个 tab 分屏为 2 个 pane）
#    - 1 个 remote session（如果环境支持）

# 2. 执行查询
./tongyou app list

# 期望输出包含类似：
# NAME    TYPE    TABS    PANES
# dev     local   2       3
# sess:1  local   1       1
# prod    remote  1       1
```

### 完成标准
- `list` 输出与 GUI 当前状态一致
- Ref 在 session 重命名后仍保持稳定
- 多次调用 `list` 结果一致，Ref 编号不跳跃

---

## Phase 3：Session 生命周期命令

### 目标
支持通过 CLI 创建和关闭 session，包括 local 和 remote 两种类型。

### 涉及文件
- `GUIAutomationServer.swift`（新增 create/close/attach 处理）
- `AppControlClient.swift`（新增 create/close/attach 命令）
- `SessionManager.swift`（可能需要暴露创建 local session 的公共方法）

### 实现要点
1. `session.create`：
   - 默认 `--local`：调用 `SessionManager` 创建 local session
   - `--remote`：通过 `RemoteSessionClient` 请求 daemon 创建并 attach
2. `session.close`：根据 ref 找到 session ID，调用 `SessionManager.closeSession`
3. `session.attach`：仅对 detached remote session 有效，local session 返回 `UNSUPPORTED_OPERATION`
4. 创建成功后返回分配的 session ref
5. CLI 侧实现 `tongyou app create [name] [--local] [--remote]`、`close`、`attach`

### 人工验证步骤
```bash
# 1. 创建 local session
./tongyou app create test --local
# 期望：返回 test（或分配的名称）

# 2. 确认 GUI 中出现了新 session
./tongyou app list

# 3. 关闭 session
./tongyou app close test

# 4. 确认 session 已消失
./tongyou app list

# 5. remote 环境支持时
./tongyou app create prod --remote
# 期望：GUI 中立即出现并 attach 该 remote session
```

### 完成标准
- 能成功创建和关闭 local session
- `--remote` 时 GUI 自动 attach 新 session
- local session 上执行 `attach` 返回 `UNSUPPORTED_OPERATION`
- GUI 未运行时返回 `GUI_NOT_RUNNING`

---

## Phase 4：终端交互命令（send / key）

### 目标
支持向指定 session 发送文本和按键事件。

### 涉及文件
- `GUIAutomationServer.swift`（新增 send/key 处理）
- `AppControlClient.swift`（新增 send/key 命令）
- `FocusManager` / `SessionManager`（路由输入到目标 pane）

### 实现要点
1. `pane.sendText`：找到 session 的 focused pane 或指定 pane，调用 `TerminalController.sendText`
2. `pane.sendKey`：
   - 支持组合键编码规范（`Ctrl+C`、`Cmd+T`、`Alt+Left`、`Enter`）
   - 解析为内部 `NSEvent` 或 VT 序列，发送到目标 pane
3. `send` 严格按原始字符串发送，**不自动追加 `\n`**
4. 焦点策略：这两个命令**不在白名单**，禁止引起窗口激活
5. CLI 侧实现 `tongyou app send <session> <text>` 和 `key <session> <key>`

### 人工验证步骤
```bash
# 1. 在 GUI 中准备一个 local session（如 test），焦点在 pane 上

# 2. 发送普通文本（注意这里没有 \n，只是输入不会执行）
./tongyou app send test "echo hello"
# 期望：GUI 中该 pane 显示 "echo hello"

# 3. 发送回车
./tongyou app key test Enter
# 期望：命令执行，输出 "hello"

# 4. 测试组合键
./tongyou app key test "Ctrl+C"
# 期望：发送中断信号（如果之前有运行的进程）

# 5. 焦点策略验证
# 将 TongYou 窗口放到后台，执行：
./tongyou app send test "background test"
# 期望：文本确实发送到 pane，但 TongYou 窗口**不会**跳到前台
```

### 完成标准
- `send` 和 `key` 能正确驱动终端输入
- 窗口在后台时执行命令不会偷焦点
- 组合键解析覆盖常见场景

---

## Phase 5：Tab / Pane 结构命令

### 目标
支持标签页和树形面板的创建、切换、关闭、分屏及比例调整。

### 涉及文件
- `GUIAutomationServer.swift`（新增 tab/pane 结构命令）
- `AppControlClient.swift`（新增对应 CLI 命令）
- `TerminalWindowView.swift` / `SessionManager.swift`（可能需要暴露 tab/pane 操作方法）

### 实现要点
1. `tab.create` / `tab.select` / `tab.close`：操作 `SessionManager.tabs` 和 `activeTabIndex`
2. `pane.split`：调用 `SessionManager.splitPane`，支持 `--vertical` / `--horizontal`
3. `pane.focus`：调用 `FocusManager.focusPane`，**在白名单中**，允许窗口激活
4. `pane.close`：调用 `SessionManager.closePane`
5. `pane.splitRatio`：根据 pane ref 找到其父 `PaneNode.split`，修改 `ratio`
6. 焦点策略：`focus-pane` 在白名单，其他不在

### 人工验证步骤
```bash
# 1. 基于一个已有 session（如 dev）

# 2. 新建 tab
./tongyou app new-tab dev

# 3. 分屏
./tongyou app split dev --vertical

# 4. 调整分屏比例
./tongyou app split-ratio dev/pane:1 --ratio 0.3
# 期望：GUI 中分屏比例变为 30%/70%

# 5. 焦点切换
./tongyou app focus-pane dev/pane:2
# 期望：焦点移动到 pane:2，若窗口在后台则 TongYou 被激活

# 6. 关闭 tab
./tongyou app close-tab dev 1

# 7. 关闭 pane
./tongyou app close-pane dev/pane:2
```

### 完成标准
- Tab 和 Pane 的增删改查均通过 CLI 正常驱动
- `focus-pane` 能正确激活窗口
- `split-ratio` 能准确调整比例，无效 pane 返回合理错误

---

## Phase 6：Float Pane 命令

### 目标
支持浮动面板的创建、焦点切换、关闭、固定状态和位置/大小调整。

### 涉及文件
- `GUIAutomationServer.swift`（新增 float-pane 命令）
- `AppControlClient.swift`（新增 float-pane CLI 命令）
- `SessionManager.swift`（可能需要暴露 float pane 操作方法）

### 实现要点
1. `floatPane.create`：调用 `SessionManager.createFloatingPane`，可选 `--profile`
2. `floatPane.focus`：调用 `FocusManager.focusPane`（float pane 的 UUID 也在 FocusManager 中管理），**在白名单**
3. `floatPane.close`：调用 `SessionManager.closeFloatingPane`
4. `floatPane.pin`：toggle `FloatingPane.isPinned`
5. `floatPane.move`：修改 `FloatingPane.frame`（normalized 0-1 坐标）
6. Float Pane 使用独立的 `float:<n>` ref 命名空间

### 人工验证步骤
```bash
# 1. 基于 session dev

# 2. 创建浮动面板
./tongyou app float-pane create dev --profile default
# 期望：GUI 中出现一个新的浮动终端窗口

# 3. 移动位置和调整大小
./tongyou app float-pane move dev/float:1 --x 0.1 --y 0.1 --width 0.4 --height 0.4
# 期望：浮动面板位置和大小改变

# 4. 固定
./tongyou app float-pane pin dev/float:1
# 期望：toggle pin 状态

# 5. 焦点切换
./tongyou app float-pane focus dev/float:1

# 6. 关闭
./tongyou app float-pane close dev/float:1
```

### 完成标准
- Float Pane 的创建、移动、固定、焦点、关闭均正常
- `move` 使用归一化坐标生效
- `focus` 能正确激活窗口并聚焦到对应浮动面板

---

## Phase 7：焦点策略与 GUI 状态命令

### 目标
完整实现焦点策略白名单机制，以及 `window-focus` 命令。

### 涉及文件
- `GUIAutomationPolicy.swift`（新建）
- `GUIAutomationServer.swift`（整合焦点策略检查）
- `SessionManager.swift` / `FocusManager.swift`（增加自动化来源标记判断）

### 实现要点
1. `GUIAutomationPolicy` 维护白名单：
   - 允许激活的命令：`pane.focus`、`floatPane.focus`、`window.focus`
2. 所有命令执行前设置 `isAutomationRequest = true`
3. `SessionManager` / `FocusManager` 在调用 `NSApp.activate` 前检查：
   - 若 `isAutomationRequest == true` 且命令不在白名单 → 跳过激活
4. `window.focus` 命令：直接调用 `NSApp.activate`
5. CLI 侧实现 `tongyou app window-focus`

### 人工验证步骤
```bash
# 1. 将 TongYou 窗口置于后台

# 2. 发送文本（非白名单命令）
./tongyou app send dev "test"
# 期望：窗口**不**跳到前台

# 3. 分屏（非白名单命令）
./tongyou app split dev --vertical
# 期望：窗口**不**跳到前台

# 4. 焦点 pane（白名单命令）
./tongyou app focus-pane dev/pane:1
# 期望：窗口跳到前台，且 pane:1 获得焦点

# 5. 焦点窗口（白名单命令）
./tongyou app window-focus
# 期望：窗口跳到前台，焦点保持在当前 pane
```

### 完成标准
- 只有 `focus-pane`、`float-pane focus`、`window-focus` 能激活窗口
- 其余所有命令均不会引起 `NSApp.activate`
- 焦点策略对 local session 和 remote session 均生效

---

## Phase 8：CLI 完善与端到端整合

### 目标
完善 CLI 的 socket 自动发现、`--json` 输出格式，以及 `daemon` 子命令的 `--json` 支持，完成端到端可用性验证。

### 涉及文件
- `Packages/TongYouCore/tongyou/SocketPathResolver.swift`（新建）
- `AppControlClient.swift`（完善所有命令和错误处理）
- `DaemonClient.swift`（现有 CLI 入口，新增 `--json`）
- `tongyou/main.swift`（顶层参数路由）

### 实现要点
1. `SocketPathResolver`：
   - 扫描 `~/.tongyou/tongyou-gui-*.sock`，按修改时间排序
   - 对每个候选执行 `connect()` 探测，第一个成功的胜出
   - 支持 `--gui-socket` 显式覆盖
2. 所有 `app` 和 `daemon` 命令支持 `--json` 全局标志
3. JSON 输出格式：
   - 成功：`{"ok":true,"result":{...}}`
   - 错误：`{"ok":false,"error":{"code":"...","message":"..."}}`
4. 统一错误处理：GUI 未运行时 `app` 命令返回 `GUI_NOT_RUNNING`
5. `daemon` 命令的 `--json` 输出将现有二进制协议结果转换为 JSON

### 人工验证步骤
```bash
# 1. Socket 自动发现
# 启动 GUI，不指定 socket 路径直接执行：
./tongyou app ping
# 期望：自动发现正确的 GUI socket 并连通

# 2. JSON 输出格式
./tongyou app --json list
# 期望：输出格式化的 JSON 数组

./tongyou app --json send dev "hello"
# 期望：{"ok":true,"result":{}}

# 3. 错误 JSON 格式
./tongyou app --json send nonexistent "hello"
# 期望：{"ok":false,"error":{"code":"SESSION_NOT_FOUND","message":"..."}}

# 4. GUI 未运行
./tongyou app --json list
#（关闭 GUI 后执行）
# 期望：{"ok":false,"error":{"code":"GUI_NOT_RUNNING","message":"..."}}

# 5. Daemon 命令 JSON 输出
./tongyou daemon --json list
# 期望：输出 JSON 格式的 remote session 列表
```

### 完成标准
- `tongyou app` 在无显式 socket 路径时能自动发现 GUI
- 所有命令的 `--json` 输出格式统一且可解析
- 错误码符合规范文档
- `tongyou daemon` 和 `tongyou app` 在 CLI 顶层路由正确

---

## 附录：快速验证检查清单

每个 Phase 完成后，使用以下检查清单确认阶段目标达成：

- [ ] 代码编译通过（`make build`）
- [ ] 新增文件遵循现有代码风格（MainActor、整数尺寸、Premultiplied alpha 等）
- [ ] 至少通过 3 次人工验证步骤中的关键场景
- [ ] 无明显的并发问题（后台线程不直接修改 `@Observable` 状态）
- [ ] 焦点策略未被破坏（非焦点命令不会偷焦点）

---

## 结语

按上述 8 个 Phase 逐步推进，每个阶段均可在 GUI 运行状态下通过 CLI 命令进行独立验证。建议在完成每个 Phase 后回归测试前一阶段的核心命令，确保增量开发不破坏已有功能。
