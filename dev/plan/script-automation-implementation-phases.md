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
建立稳定的 Ref 句柄分配、反查和生命周期机制，支持 `session.list` 命令返回 GUI 当前完整的会话/tab/pane/float 结构，供后续所有命令消费。

### 涉及文件
- `Packages/TongYouCore/Sources/TYAutomation/GUIAutomationRefStore.swift`（新建，MainActor，ref ↔ UUID 双向映射）
- `Packages/TongYouCore/Sources/TYAutomation/GUIAutomationRef.swift`（新建，ref 字符串解析/拼装、合法性校验）
- `Packages/TongYouCore/Sources/TYAutomation/GUIAutomationSchema.swift`（新建，`session.list` 请求/响应的 Codable 结构）
- `Packages/TongYouCore/Sources/TYAutomation/GUIAutomationServer.swift`（Phase 1 文件，新增 `session.list` handler、命令执行前统一调用 `refreshRefs()`）
- `Packages/TongYouCore/Sources/TYClient/AppControlClient.swift`（Phase 1 文件，新增 `list` 命令及文本/JSON 渲染）
- `Packages/TongYouCore/Tests/TYAutomationTests/GUIAutomationRefStoreTests.swift`（新建，单元测试）

### Ref 格式规范

**Session ref 选择规则**（按顺序尝试，首个满足即采用）：
1. `name` 非空、不包含 `/`、`:`、空白字符、不匹配 `^(sess|tab|pane|float):\d+$`、且在当前活跃 session 中唯一 → 使用 `name` 作为 ref
2. 否则回退到 `sess:<n>`，`<n>` 为 session 级全局单调计数器

**子对象 ref 固定为扁平形式**：
- Tab：`<session-ref>/tab:<n>`
- Tree Pane：`<session-ref>/pane:<n>`（n 在 session 内部全局计数，不区分 tab）
- Float Pane：`<session-ref>/float:<n>`（n 在 session 内部全局计数，不区分 tab）

**命名空间说明**：
- Tab / Pane / Float 三个计数器互相独立：同一 session 下可以同时存在 `tab:1`、`pane:1`、`float:1`
- Float pane 实际归属某个 tab（见 `TerminalTab.floatingPanes`），但 ref 只挂在 session 下；RefStore 内部同时记录 `(sessionID, tabID, floatID)` 三元组供 Phase 6 定位

### Ref 生命周期与稳定性

**稳定性保证**（以下操作不改变已分配 ref）：
- Session 重命名（即使改名后符合"name 作为 ref"的条件，已分配的 `sess:<n>` 也不升级，避免脚本缓存失效）
- Tab 重排序、切换 active tab
- Pane 树结构调整（split 子节点、修改 ratio）
- Float pane 移动/调整大小/pin toggle
- Remote session 在 `ready ⇄ detached ⇄ pendingAttach` 之间切换（UUID 不变则 ref 不变）

**以下操作会导致 ref 失效**：
- Session / tab / pane / float 关闭 → 对应 UUID 被 SessionManager 移除，下次 `refreshRefs()` 时 RefStore 同步标记失效，后续命令查询返回 `SESSION_NOT_FOUND` / `TAB_NOT_FOUND` / `PANE_NOT_FOUND`
- **无墓碑机制**：失效的 ref 不出现在 `session.list` 响应中，但 ref 本身不会被新对象复用（计数器单调递增）
- GUI 进程重启：所有计数器、映射全部重置，脚本必须重新调用 `list` 获取新 ref

**计数器单调递增保证**：
- `sess:<n>` / `tab:<n>` / `pane:<n>` / `float:<n>` 的 `<n>` 仅递增不回收
- 例：创建 `sess:1`、`sess:2`，关闭 `sess:1`，再创建新 session 得到 `sess:3`（不复用 `sess:1`）

**Remote session 的特殊处理**：
- Remote session 的 ref 以 GUI 本地 `TerminalSession.id` 为键，与 daemon 侧的 `serverSessionID` 解耦
- detach 后的 remote session 仍保留在 `SessionManager.sessions` 中，ref 持续有效

### 并发模型与刷新策略

- `GUIAutomationRefStore` 标注为 `@MainActor`，与 `SessionManager`（`@Observable final class`）共享同一 actor，避免跨线程同步
- **懒触发刷新**：每条命令进入 handler 时，服务端先 `await MainActor.run { refStore.refreshRefs(from: sessionManager) }`，再解析 ref 参数
- 不订阅 `@Observable` 变更：`refreshRefs()` 是 idempotent 的纯扫描（已存在的 UUID 保留原 ref，新增 UUID 分配下一个编号），每次命令前跑一次开销可接受
- RefStore 内部用 `[String: UUID]` + `[UUID: String]` 双字典，天然线程安全（MainActor 隔离）
- `refreshRefs()` 遍历顺序：session 按 `SessionManager.sessions` 数组顺序；tab 按 `TerminalSession.tabs` 数组顺序；pane 按 `PaneNode` DFS（left-first）顺序；float 按 `TerminalTab.floatingPanes` 数组顺序

### `session.list` 响应 Schema

```json
{
  "id": "1",
  "ok": true,
  "result": {
    "sessions": [
      {
        "ref": "dev",
        "name": "dev",
        "type": "local",
        "state": "ready",
        "active": true,
        "tabs": [
          {
            "ref": "dev/tab:1",
            "title": "Shell",
            "active": true,
            "panes": ["dev/pane:1", "dev/pane:2"],
            "floats": []
          },
          {
            "ref": "dev/tab:2",
            "title": "Logs",
            "active": false,
            "panes": ["dev/pane:3"],
            "floats": ["dev/float:1"]
          }
        ]
      },
      {
        "ref": "sess:1",
        "name": "",
        "type": "local",
        "state": "ready",
        "active": false,
        "tabs": [
          {"ref": "sess:1/tab:1", "title": "Shell", "active": true, "panes": ["sess:1/pane:1"], "floats": []}
        ]
      },
      {
        "ref": "prod",
        "name": "prod",
        "type": "remote",
        "state": "detached",
        "active": false,
        "tabs": []
      }
    ]
  }
}
```

字段说明：
- `type`：`local` / `remote`
- `state`：`ready` / `detached` / `pendingAttach`（映射自 `SessionDisplayState`）
- `active`：session 级表示是否为当前 active session；tab 级表示是否为 `activeTabIndex` 对应 tab
- `name`：原始 session 名（可能为空字符串，用户展示用；ref 才是命令引用的唯一标识）
- Remote session 在 `detached` 状态下 `tabs` 可为空（未 attach 时无本地 tab 数据）

CLI 默认文本输出保持 `script-automation-plan.md §9.3` 约定，扩展 REF/STATE 列：

```
REF      NAME    TYPE    STATE      TABS  PANES
dev      dev     local   ready      2     3
sess:1           local   ready      1     1
prod     prod    remote  detached   0     0
```

### 实现要点

1. **`GUIAutomationRef` 值类型**
   - 提供 `parse(_ string: String) throws -> Ref` 和 `description: String`
   - `Ref` 用 enum 区分 `session(String)` / `tab(String, UInt)` / `pane(String, UInt)` / `float(String, UInt)`
   - 非法格式（含非法字符、缺少计数器、session 段为空）抛 `INVALID_REF`
2. **`GUIAutomationRefStore`**
   - `refreshRefs(from: SessionManager)`：扫描并同步映射，纯读不触发副作用
   - `resolve(_ ref: Ref) throws -> ResolvedTarget`：返回 `(sessionID: UUID, tabID: UUID?, paneID: UUID?, floatID: UUID?)`
   - `sessionRef(for id: UUID) -> String?` 等反查接口（命令响应拼装用）
   - 内部计数器：`sessionCounter: UInt` 全局；`tabCounter / paneCounter / floatCounter: [UUID: UInt]` per-session
3. **`session.list` handler**
   - 纯读操作，无 UI 写入，直接在 MainActor 上执行
   - 输出 schema 由 `GUIAutomationSchema` 定义（Codable），server 和 client 共用
4. **CLI `tongyou app list`**
   - 默认文本输出按上表格式，列宽按实际内容自适应
   - `--json` 透传服务端响应

### 单元测试要点

`GUIAutomationRefStoreTests.swift` 至少覆盖：

1. **命名规则**
   - 纯字母 name 采用 name 作为 ref
   - 包含 `/` / `:` / 空格的 name 回退到 `sess:<n>`
   - name 匹配 `sess:42` pattern 的 session 强制回退
   - 空 name 回退到 `sess:<n>`
2. **冲突处理**
   - 两个 session 都叫 `dev`：先创建的拿到 `dev`，后创建的回退到 `sess:<n>`
3. **稳定性**
   - 重命名 session 后 ref 不变
   - 关闭第一个 tab 后其余 tab 的 ref 保持
   - 分屏新增 pane 后已有 pane 的 ref 不变
4. **计数器单调性**
   - 创建 → 关闭 → 再创建，新对象拿到下一个编号而非复用
5. **失效行为**
   - 关闭 session 后 `resolve(.session("dev"))` 抛 `SESSION_NOT_FOUND`
   - 非法 ref 格式抛 `INVALID_REF`
6. **DFS 顺序**
   - 多次分屏后 pane 编号遵循构造时的 DFS(left-first) 顺序

### 人工验证步骤

```bash
# 1. 启动 GUI App，手动创建：
#    - 1 个未命名 local session
#    - 1 个命名为 "dev" 的 local session（2 个 tab；tab 2 纵向分屏为 2 个 pane）
#    - 1 个 remote session（若环境支持）

# 2. 默认文本输出
./tongyou app list
# 期望：
# REF      NAME    TYPE    STATE      TABS  PANES
# dev      dev     local   ready      2     3
# sess:1           local   ready      1     1
# prod     prod    remote  ready      1     1

# 3. JSON 输出结构（Phase 8 完成前可用临时 --json flag 验证）
./tongyou app --json list | jq '.result.sessions[0].tabs[0].panes'
# 期望：["dev/pane:1"]

# 4. 稳定性：在 GUI 中把 "dev" 重命名为 "work"，再次 list
./tongyou app list
# 期望：原 "dev" 行的 REF 仍为 "dev"（不升级、不变），NAME 列变为 "work"

# 5. 计数器单调性：关闭 dev，再新建一个名为 "dev" 的 session
./tongyou app list
# 期望：新 session 的 REF 为 "dev"（旧 ref 已失效，name 不再冲突）
#       已关闭的旧 dev 不在列表中

# 6. 特殊字符命名：在 GUI 中创建名为 "a/b" 的 session
./tongyou app list
# 期望：REF 列为 "sess:<n>"，NAME 列为 "a/b"

# 7. 幂等性
for i in 1 2 3; do ./tongyou app list; done
# 期望：三次输出完全一致

# 8. Remote session detach 后 ref 稳定（若环境支持）
#    在 GUI 中 detach "prod"，再次 list
# 期望：prod 行仍在，STATE 列变为 "detached"，REF 保持 "prod"
```

### 完成标准

- `list` 文本输出与 GUI 状态一致，JSON 输出符合上述 schema
- RefStore 单元测试全部通过（命名规则/冲突/稳定性/单调性/失效/DFS 顺序）
- Session 重命名、tab 重排、pane 分屏均不改变已分配 ref
- 计数器关闭后不回收，新对象必然拿到更大编号
- 特殊字符或与自动编号冲突的 session name 自动回退到 `sess:<n>`，原名保留在 `name` 字段
- GUI 未运行时返回 `GUI_NOT_RUNNING`，并发多次 `list` 结果一致

---

## Phase 3：Session 生命周期命令

### 目标
支持通过 CLI 创建和关闭 session，包括 local 和 remote 两种类型。

### 涉及文件
- `GUIAutomationServer.swift`（新增 create/close/attach/detach 处理）
- `AppControlClient.swift`（新增 create/close/attach/detach 命令）
- `SessionManager.swift`（可能需要暴露创建 local session 的公共方法）

### 实现要点
1. `session.create`：
   - 默认 `--local`：调用 `SessionManager` 创建 local session
   - `--remote`：通过 `RemoteSessionClient` 请求 daemon 创建并 attach
2. `session.close`：根据 ref 找到 session ID，调用 `SessionManager.closeSession`
3. `session.attach`：仅对 detached remote session 有效，local session 返回 `UNSUPPORTED_OPERATION`
4. `session.detach`：对 local 调 `SessionManager.detachLocalSession`，对 remote 调 `detachRemoteSession`；detach 后的 session 仍保留在 sidebar 中，ref 不变
5. 创建成功后返回分配的 session ref
6. CLI 侧实现 `tongyou app create [name] [--local] [--remote]`、`close`、`attach`、`detach`

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

# 6. Detach / Re-attach 往返
./tongyou app detach prod
./tongyou app list
# 期望：prod 行仍在，STATE 列变为 "detached"，REF 保持 "prod"
./tongyou app attach prod
# 期望：STATE 回到 "ready"
```

### 完成标准
- 能成功创建和关闭 local session
- `--remote` 时 GUI 自动 attach 新 session
- local session 上执行 `attach` 返回 `UNSUPPORTED_OPERATION`
- `detach` 后 session 保留在 sidebar、ref 不变，`attach` 可恢复
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
支持标签页和树形面板的创建、切换、关闭、分屏及比例调整。命令对 local session 和已 attach 的 remote session 同等生效——所有 tab/pane 操作都通过 GUI 侧的 `SessionManager` 执行，remote 分支把请求转发给 daemon，再由 `layoutUpdate` 回填本地状态。

### 涉及文件
- `GUIAutomationServer.swift`（新增 tab/pane 结构命令）
- `AppControlClient.swift`（新增对应 CLI 命令）
- `TerminalWindowView.swift` / `SessionManager.swift`（可能需要暴露 tab/pane 操作方法）

### 实现要点
1. `tab.create` / `tab.select` / `tab.close`：操作 `SessionManager.tabs` 和 `activeTabIndex`
2. `pane.split`：调用 `SessionManager.splitPane`，支持 `--vertical` / `--horizontal`
3. `pane.focus`：调用 `FocusManager.focusPane`，**在白名单中**，允许窗口激活
4. `pane.close`：调用 `SessionManager.closePane`
5. `pane.resize`：根据 pane ref 找到其父 `PaneNode.split`，修改 `ratio`
6. 焦点策略：`focus-pane` 在白名单，其他不在
7. **Remote session 支持**：
   - `tab.select` / `tab.close` / `pane.focus` / `pane.close`：`SessionManager` 既有远程分支直接转发给 daemon，无需额外工作
   - `tab.create` / `pane.split`：daemon 异步创建后通过 `layoutUpdate` 回填；在 `SessionManager` 暴露 `onNextRemoteTabCreated` / `onNextRemotePaneCreated` FIFO 监听点，`GUIAutomationService` 复用 `createRemoteSessionBlocking` 的信号量 + 超时模式，把下一次 layoutUpdate 出现的新 tab/pane UUID 转换成 ref 同步返回
   - `pane.resize`：新增 `ClientMessage.setSplitRatio`（wire 0x022F）；daemon 在 `ServerSessionManager` 侧应用 `PaneNode.updateRatio` 并广播 `layoutUpdate`；客户端 `SessionManager.updateSplitRatio` 的 remote 分支走 `RemoteSessionClient.setSplitRatio`
   - detached 的 remote session 在 `GUIAutomationService` 侧直接返回 `UNSUPPORTED_OPERATION`（带 "attach it first" 提示），不把请求发给 daemon

### 人工验证步骤
```bash
# 1. 基于一个已有 session（如 dev）

# 2. 新建 tab
./tongyou app new-tab dev

# 3. 分屏
./tongyou app split dev --vertical

# 4. 调整分屏比例
./tongyou app resize-pane dev/pane:1 --ratio 0.3
# 期望：GUI 中分屏比例变为 30%/70%

# 5. 焦点切换
./tongyou app focus-pane dev/pane:2
# 期望：焦点移动到 pane:2，若窗口在后台则 TongYou 被激活

# 6. 关闭 tab
./tongyou app close-tab dev 1

# 7. 关闭 pane
./tongyou app close-pane dev/pane:2

# 8. Remote session 同样支持（若环境可用）
./tongyou app create prod --remote
./tongyou app new-tab prod
./tongyou app split prod --vertical
./tongyou app resize-pane prod/pane:2 --ratio 0.3
./tongyou app focus-pane prod/pane:2
# 期望：行为与 local session 一致；所有变更均由 daemon 的 layoutUpdate 回填

# 9. Detached remote session 拒绝结构性操作
./tongyou app detach prod
./tongyou app new-tab prod
# 期望：UNSUPPORTED_OPERATION，提示需先 attach
```

### 完成标准
- Tab 和 Pane 的增删改查均通过 CLI 正常驱动
- `focus-pane` 能正确激活窗口
- `resize-pane` 能准确调整比例，无效 pane 返回合理错误
- 上述命令对 local session 和已 attach 的 remote session 均正常工作；detached remote session 返回 `UNSUPPORTED_OPERATION` 且不发 RPC 给 daemon

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
