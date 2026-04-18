# TongYou Pane Profile 远程会话支持实施计划

让 `tongyou app new-tab / split / float-pane create` 在 **remote session**（GUI 连接 `tyd` daemon 而非自己本地托管的会话）上也能接受 `--profile` / `--set`。当前 GUI 会在这个路径显式抛 `UNSUPPORTED_OPERATION: profile/overrides not yet supported for remote sessions`（见 `TongYou/App/GUIAutomationService.swift:716 / 846 / 981`）。

本文档延续 `pane-profile-plan.md` 的 Phase 1–6。依赖它们的全部产物（`ProfileLoader` / `ProfileMerger` / `StartupSnapshot` / JSON-RPC `profile+overrides` / CLI flag）。

---

## 总体设计

### 核心约束（用户确认）

1. **daemon 不读任何 profile 文件**。`tyd` 将来可能部署在远程服务器上，profile 文件只在客户端文件系统里存在。所有 profile 相关信息必须由客户端解析完成后通过 wire 协议送达 daemon。
2. **不考虑向后兼容**。wire opcode、消息布局、结构体字段可自由改动；不做版本协商、不保留兼容旁路。
3. **`createFloatingPaneWithCommand`（opcode `0x022D`）删除**。所有带命令的 float 创建统一走 `createFloatingPane` + `profileID` + `StartupSnapshot`。
4. **客户端整包序列化**。GUI 用本地 `ProfileMerger.resolve(profileID:, overrides:)` 得到 `StartupSnapshot`，然后把 **完整 snapshot**（不是 profileID + overrides 字符串）序列化过去。daemon 拿到 snapshot 就直接启动 PTY，不再做任何合并。

### 传输模型

- Client → Daemon 的 wire 消息体里，create 类消息带两个可选字段：
  - `profileID: String?` — 仅作为**字符串标签**由 daemon 原样存在 `TerminalPane.profileID` 上并回显给客户端；daemon **不解析、不加载、不用它做任何决策**。用途：client 收到 layout update 后知道这个 pane 是哪个 profile 创建的，从而在本地做 Live 字段热重载（Phase 3 已实现）和日后的"重启命令"路径。
  - `snapshot: StartupSnapshot?` — 当非 nil 时，daemon 用它启动 PTY（command/args/env/cwd/close-on-exit/initial-*）。当 nil 时，保留当前"继承"行为（split 继承父 pane 的 snapshot、new-tab 用空 snapshot + 焦点 cwd）。

- Daemon → Client 的 layout update 已经携带 `profileID`（`ServerSessionManager.swift:69/82/671`），不变。

### 客户端 vs 服务端的职责分工

| 能力 | 客户端 (GUI) | 服务端 (tyd) |
|---|---|---|
| 读 profile 文件 | ✅ | ❌ |
| 合并 profile + overrides | ✅ | ❌ |
| 验证 profile 存在、语法合法 | ✅ | ❌ |
| Live 字段热重载（theme/font/palette） | ✅（已存在） | ❌ |
| 按 `StartupSnapshot` 启动 PTY | ❌ | ✅ |
| 存 `profileID` 字符串在 TerminalPane 上 | — | ✅ |
| 存 `startupSnapshot` 在 TerminalPane 上（用于 rerun） | — | ✅ |

### 错误码边界

- `PROFILE_NOT_FOUND` / `INVALID_PARAMS` / 循环继承 / 非法字段值 — 全部由客户端解析时抛出，**不走 wire**；错误码与 local 路径完全一致。
- Wire 层只可能有 `TRANSPORT` / `SESSION_NOT_FOUND` / `PANE_NOT_FOUND` 之类的会话层错误。

---

## Phase 7.1：StartupSnapshot 的二进制编解码

### 目标

让 `TYProtocol` 的 `BinaryEncoder` / `BinaryDecoder` 能序列化 / 反序列化 `StartupSnapshot`（目前它是纯 Swift 结构体，只在进程内传递）。

### 涉及文件

- `Packages/TongYouCore/Sources/TYProtocol/BinaryEncoder.swift`
- `Packages/TongYouCore/Sources/TYProtocol/BinaryDecoder.swift`
- `Packages/TongYouCore/Sources/TYProtocol/MessageTypes.swift` — 如有需要加 `import TYConfig`
- `Packages/TongYouCore/Package.swift` — 确认 `TYProtocol` 依赖 `TYConfig`（`StartupSnapshot` 所在）。如果还没依赖，加上
- `Packages/TongYouCore/Tests/TYProtocolTests/BinaryCoderTests.swift`

### 实现要点

1. **编码格式**（决策：count 用 UInt16 与 `writeStringArray` 风格一致；`args` / `env` 实际条数远低于 65k 上限）：

   ```
   StartupSnapshot {
     u8       has_command
     [string  command]        (if has_command)
     u16      args_count
     [string] args            (u16 count + length-prefixed strings, 复用 writeStringArray)
     u8       has_cwd
     [string  cwd]            (if has_cwd)
     u16      env_count
     [ { string key; string value } ] env  (repeated)
     u8       close_on_exit   (0 = nil, 1 = false, 2 = true)
     u8       has_initial_x
     [i32     initial_x]      (if has_initial_x)
     ... same for initial_y / initial_width / initial_height
   }
   ```
   全部可选字段用 leading `u8` 指示是否存在。`closeOnExit: Bool?` 用 trinary（0/1/2）节省一个字节。
   注意：`initial_*` 在 Phase 7.1 保留 `Int?` 语义只做编解码；Phase 7.3 会根据"选 C"从 snapshot 剥离到独立的 float frame hint（见 7.3）。

2. **便捷 API**：
   ```swift
   // BinaryEncoder
   func writeStartupSnapshot(_ s: StartupSnapshot)
   func writeOptionalStartupSnapshot(_ s: StartupSnapshot?)  // 前缀 1 byte has-flag
   // BinaryDecoder
   func readStartupSnapshot() throws -> StartupSnapshot
   func readOptionalStartupSnapshot() throws -> StartupSnapshot?
   ```

3. **非 ASCII** `env` value（比如 `LANG=zh_CN.UTF-8`、环境变量里有中文）要能完整往返 — 因为 wire 的 string 走 UTF-8 length-prefix，本应已支持，加测试确认。

### 测试（`BinaryCoderTests`）

- `startupSnapshotRoundTripEmpty` — 所有字段 nil / 空数组 → decode 回原样
- `startupSnapshotRoundTripFull` — 全部字段填满，包括多个 `EnvVar`、多 `args`、非 ASCII value
- `startupSnapshotCloseOnExitTrinary` — 三种状态都能往返
- `optionalSnapshotNil` / `optionalSnapshotPresent` — `writeOptional` / `readOptional` 配对

### 完成标准

- 新 API 公开于 `TYProtocol`，对 `StartupSnapshot` 的往返保真。
- 单测全绿。

---

## Phase 7.2：扩展 create 类 opcode，删除 createFloatingPaneWithCommand

### 目标

让 `createTab` / `splitPane` / `createFloatingPane` 的 wire 消息携带 `profileID: String?` + `snapshot: StartupSnapshot?`；删除 `createFloatingPaneWithCommand`（及 opcode `0x022D`）；服务端把 snapshot / profileID 一路透传到 `createAndStartPane`。

### 涉及文件

- `Packages/TongYouCore/Sources/TYProtocol/MessageTypes.swift`
- `Packages/TongYouCore/Sources/TYProtocol/BinaryEncoder.swift`
- `Packages/TongYouCore/Sources/TYProtocol/BinaryDecoder.swift`
- `Packages/TongYouCore/Sources/TYServer/SocketServer.swift`（`:478 / :487 / :511 / :549`）
- `Packages/TongYouCore/Sources/TYServer/ServerSessionManager.swift`（`createTab` `:254`、`splitPane` `:320`、`createFloatingPane` `:490`、`createAndStartPane` `:1003`）
- `Packages/TongYouCore/Tests/TYProtocolTests/BinaryCoderTests.swift`
- `Packages/TongYouCore/Tests/TYProtocolTests/WireFormatTests.swift`
- `Packages/TongYouCore/Tests/TYServerTests/ServerSessionManagerTests.swift`

### 实现要点

1. **`MessageTypes.swift` 修改 case**：

   ```swift
   case createTab(SessionID, profileID: String?, snapshot: StartupSnapshot?)
   case splitPane(SessionID, PaneID, SplitDirection,
                  profileID: String?, snapshot: StartupSnapshot?)
   case createFloatingPane(SessionID, TabID,
                           profileID: String?, snapshot: StartupSnapshot?)
   ```

   **删除**：
   ```swift
   case createFloatingPaneWithCommand(...)     // 删除
   // ControlOpcode.createFloatingPaneWithCommand = 0x022D    // 删除
   ```

2. **`BinaryEncoder` / `BinaryDecoder`**：对应三个 case 的 write/read 后面追加 `writeOptionalString(profileID)` + `writeOptionalStartupSnapshot(snapshot)`（解码侧对称）。`createFloatingPaneWithCommand` 整段删除。

3. **`SocketServer.swift`** 三处 handler 解出新字段：

   ```swift
   case .createTab(let sessionID, let profileID, let snapshot):
       sessionManager.createTab(sessionID: sessionID,
                                profileID: profileID,
                                snapshot: snapshot)
   case .splitPane(let sessionID, let paneID, let direction,
                   let profileID, let snapshot):
       sessionManager.splitPane(sessionID: sessionID,
                                paneID: paneID,
                                direction: direction,
                                profileID: profileID,
                                snapshot: snapshot)
   case .createFloatingPane(let sessionID, let tabID,
                            let profileID, let snapshot):
       sessionManager.createFloatingPane(sessionID: sessionID,
                                         tabID: tabID,
                                         profileID: profileID,
                                         snapshot: snapshot)
   // .createFloatingPaneWithCommand 分支删除
   ```

4. **`ServerSessionManager.swift`** 公共入口改签名：

   ```swift
   public func createTab(sessionID: SessionID,
                         profileID: String? = nil,
                         snapshot: StartupSnapshot? = nil) -> TabID?
   public func splitPane(sessionID: SessionID, paneID: PaneID,
                         direction: SplitDirection,
                         profileID: String? = nil,
                         snapshot: StartupSnapshot? = nil) -> PaneID?
   public func createFloatingPane(sessionID: SessionID, tabID: TabID,
                                  profileID: String? = nil,
                                  snapshot: StartupSnapshot? = nil) -> PaneID?
   ```

   内部行为：
   - `snapshot == nil`：保留当前继承行为（`splitPane` 继承父 profile；`createTab` 继承焦点 cwd；`createFloatingPane` 继承 tab 的 profile）
   - `snapshot != nil`：**完全按 snapshot 启动 PTY**（command/args/cwd/env/close-on-exit 全部来自 snapshot），忽略父继承
   - `profileID` 照原样写入 `TerminalPane.profileID`（如果 nil 则按继承规则填）
   - `createAndStartPane(..., profileID: profileID, snapshot: snapshot)` 已经就绪，直接传

5. **删除所有 `createFloatingPaneWithCommand` 代码路径**（`RemoteSessionClient` / `SessionManager` 里的调用方在 Phase 7.3 一起迁移，本阶段先解决协议和服务端）。

6. **设计决策**：**daemon 不校验 profileID 内容**。哪怕 client 传了一个 daemon 没见过的名字（eg `"ci"` 不存在于 daemon 侧），daemon 也照样接受；因为它只当标签存。校验责任 100% 在 client。

### 测试

- `BinaryCoderTests` / `WireFormatTests`：
  - 三个扩展 case 的 round-trip，覆盖四种组合：
    - `profileID=nil, snapshot=nil`
    - `profileID=非空, snapshot=nil`
    - `profileID=nil, snapshot=非空`
    - 两者都非空
  - 确认 `createFloatingPaneWithCommand` 不再存在（`#expect(throws:)` 解一个旧 opcode 字节流应报未知 opcode）
- `ServerSessionManagerTests`：
  - `createTabWithSnapshotLaunchesPTYWithCommand` — 传入 `snapshot(command: /usr/bin/env, env: [TY_TEST=1])`，断言产生的 pane 的 core 启动命令 / 环境变量正确
  - `splitPaneWithSnapshotOverridesParentInheritance` — 父 pane 有 profile A，split 时传 snapshot/profileID = B，新 pane 的 profileID = B、PTY 用 B 的 command
  - `splitPaneWithoutSnapshotInheritsParent` — 不传 snapshot 时保留继承（当前行为不回归）
  - `createFloatingPaneWithSnapshotAppliesGeometry` — snapshot 里的 `initialX/Y/Width/Height` 被正确应用到 float frame（见 Phase 7.3 的几何语义决策）

### 完成标准

- 三个 opcode 携带新字段端到端编解码正确。
- `createFloatingPaneWithCommand` 在 `TYProtocol` / `TYServer` 中被完全删除。
- 服务端 `snapshot != nil` 时严格按 snapshot 启动 PTY。
- 测试全绿。

---

## Phase 7.3：客户端 + GUI 透传，统一 float 创建路径

### 目标

1. `RemoteSessionClient` 新签名通过 `profileID` + `snapshot`。
2. GUI `SessionManager` 的 remote 路径调用本地 `ProfileMerger.resolve(...)` 得到 `StartupSnapshot` 后发到 wire。
3. 现有调 `createFloatingPaneWithCommand` 的所有 GUI 路径（"命令面板 → run command in new float"）迁移到**构造 snapshot → 统一 `createFloatingPane`**。
4. 移除 `GUIAutomationService.swift` 三处 `UNSUPPORTED_OPERATION` guard。

### 涉及文件

- `Packages/TongYouCore/Sources/TYClient/RemoteSessionClient.swift`（`:171 createTab` / `:179 splitPane` / `:204 createFloatingPane` / 旧 `createFloatingPaneWithCommand`）
- `TongYou/App/SessionManager.swift`（远程路径 + `:2301 / :2347 / :2362` 的 `createFloatingPaneWithCommand` 调用者 + `:2368 private func createFloatingPaneWithCommand(...)` 本体）
- `TongYou/App/GUIAutomationService.swift`（删除 `:716 / :846 / :981` 的 guard；让 remote 也调 `validateProfile`）
- `Packages/TongYouCore/Sources/TYConfig/StartupSnapshot.swift` — **可能需要修改字段类型**，见下面的设计决策
- 相关 GUI 调用路径（命令面板、`runCommand` action 等 —— 用 Grep `createFloatingPaneWithCommand` 全局查）
- `TongYouTests/SessionManagerTests.swift` / `SessionManagerProfileTests.swift`

### 设计决策：float 几何走"选 C"（已定）

**`createFloatingPaneWithCommand` 的几何参数（`frameX/Y/Width/Height: Float?`）使用归一化 0–1 坐标**；而 `StartupSnapshot.initialX/Y/Width/Height` 当前是 `Int?`，没写单位语义。

- **选择 A（已放弃）**：把 `StartupSnapshot.initial*` 改为 `Float?` 归一化。缺点：profile 文件 `initial-x = 0.25` 语义别扭；且这些字段对 tree pane 完全无用，混在 PTY 启动参数里职责不清。

- **选择 B（已放弃）**：保留 `Int?` 做像素，float 创建后再单独发 `updateFloatingPaneFrame`。缺点：两步创建有视觉抖动窗口。

- **选择 C（采用）**：**从 `StartupSnapshot` 里剥离 `initialX/Y/Width/Height`**（它们本来就是 float-only 的 UI 几何，不是 PTY 启动参数）。在 Phase 7.3 的 wire 层给 `createFloatingPane` 加一个独立的可选 `FloatFrameHint { x, y, w, h: Float }`（归一化，与 `updateFloatingPaneFrame` 单位一致）。`ProfileMerger` 产出 snapshot + 可选 frameHint 两个结构。
  - 好处：snapshot 纯粹化为 PTY 启动参数；float 几何由专属类型承载；profile 文件里的 `initial-x = 0.25` 可以明确标注"float-only, 归一化"。
  - Phase 7.1 仍按 `StartupSnapshot` 当前形状（含 `Int?` initial*）做编解码；Phase 7.3 再定义 `FloatFrameHint`、从 `StartupSnapshot` 删掉 `initial*`、并更新 `ResolvedStartupFields → …` 的组装。

### 实现要点

1. **`RemoteSessionClient`** 新签名：
   ```swift
   public func createTab(sessionID: SessionID,
                         profileID: String?,
                         snapshot: StartupSnapshot?)
   public func splitPane(sessionID: SessionID, paneID: PaneID,
                         direction: SplitDirection,
                         profileID: String?,
                         snapshot: StartupSnapshot?)
   public func createFloatingPane(sessionID: SessionID, tabID: TabID,
                                  profileID: String?,
                                  snapshot: StartupSnapshot?)
   // 旧 createFloatingPaneWithCommand 删除
   ```

2. **GUI `SessionManager` 远程路径**：Phase 5 JSON-RPC 已经把 profile+overrides 送到 local 路径；remote 路径需要对称处理。关键改动：

   ```swift
   // 伪码
   func createTab(inSessionID sessionID: UUID,
                  profileID: String?,
                  overrides: [String]) -> TabID? {
       if session.source.isRemote {
           let snapshot = try profileMerger.resolve(
               profileID: profileID ?? TerminalPane.defaultProfileID,
               overrides: overrides
           )  // 失败直接抛，不发 wire
           remoteClient?.createTab(
               sessionID: serverSessionID,
               profileID: profileID,
               snapshot: snapshot
           )
       } else {
           // local 路径保持原样
       }
   }
   // splitPane / createFloatingPane 同理
   ```

   错误处理：`ProfileMerger.resolve` 抛出的 `ProfileResolveError` 映射到和 local 一致的 JSON-RPC 错误码（`PROFILE_NOT_FOUND` / `INVALID_PARAMS`）——GUI 里已有 helper，复用。

3. **`GUIAutomationService.swift` guard 删除**：
   - `:716 / :846 / :981` 三处 `.unsupportedOperation("profile/overrides not yet supported for remote sessions")` 删除
   - 在它们的**上方** `if session.source.serverSessionID != nil { ... }` 分支里，加上**本地 validate**（`Self.validateProfile(manager:, id:, overrides:)`）——remote 路径也要先在 client 端解析一次，错误能早返回，不等 daemon round-trip。实际上直接复用 `tryResolveProfile(id:, overrides:)` 逻辑。
   - 然后让 `manager.createTab / splitPane / createFloatingPane` 的 remote 分支接受 `profileID` + `overrides`（或者把 GUIAutomationService 里已经解析好的 snapshot 传进去）。

4. **迁移 `createFloatingPaneWithCommand` 的 GUI 调用者**：
   - 前置：先对 `FloatingPaneCommandInfo` 做 15 分钟 grep 审计（全仓 `grep -r FloatingPaneCommandInfo`），看 UI 侧是否绑了"有命令的 float"条件分支，避免删 wire case 时引发意外的 UI 同步改动。
   - `SessionManager.swift:2301 / :2347 / :2362` 三个调用（"命令面板运行命令" / `runCommand` action / 等）
   - 对每处：构造一个 `StartupSnapshot`（填 command/args/closeOnExit）+ 可选 `FloatFrameHint`，调 `createFloatingPane(..., profileID: nil, snapshot: snapshot, frameHint: hint)`
   - `createFloatingPaneWithCommand` 私有函数删除
   - `FloatingPaneCommandInfo` 根据审计结果处理：若仅被这条路径用，删除并改用 `startupSnapshot.command != nil` 判断；若被 UI 绑定，保留为纯 UI 层类型（不再出现在 wire 上）。

### 测试

- `RemoteSessionClient` round-trip（通过 TYServer 内存测试 fixture）：创建 tab + profile + snapshot → 服务端 PTY 正确启动
- GUI `SessionManager.createTabRemote` 等：传 profileID + overrides → snapshot 解析正确 → wire 消息构造正确（用 mock connection 验证发送的 `ClientMessage` 结构）
- `GUIAutomationService` remote path：
  - `tab.create` / `pane.split` / `floatPane.create` 带 `profile: "ci"` → 成功
  - 带不存在 profile → 客户端 `PROFILE_NOT_FOUND`，不发 wire
  - 带 malformed override → `INVALID_PARAMS`，不发 wire
- 命令面板"run command in new float" 在远程 session 上能正常创建 float 并执行命令（回归测试）

### 完成标准

- Remote session 下 `tongyou app new-tab / split / float-pane create --profile X --set k=v` 行为与 local 一致。
- `createFloatingPaneWithCommand`（wire + server + client + GUI）全部删除，项目里 `grep -r createFloatingPaneWithCommand` 零命中（除了可能的 git history）。
- `GUIAutomationService.swift` 三处 guard 删除，对应错误码类型已从 automation 错误 enum 里移除（如果是 `.unsupportedOperation(...)` case 用于此处专用则删除）。
- 自动化 + 手工验证均通过。

---

## Phase 7.4：端到端回归 + 文档更新

### 目标

用真实的 GUI + tyd daemon 跑一遍回归；更新 `pane-profile-plan.md` 的 Phase 6 完成标准尾部，追加 "Phase 7 完成后 remote 也支持"。

### 人工验证步骤

```bash
# 0. 重启 daemon + GUI 以加载新协议
tongyou daemon stop
open -a TongYou.app  # 或从 Xcode 跑

# 1. 建一个 remote session（由 daemon 托管）
tongyou app create --remote --focus
tongyou app list            # 记下 REF，例如 's3'

# 2. split 远程 pane，用 ci profile
#    ci.txt:
#      command = /bin/bash
#      args = -l
#      args = -c
#      args = echo "hello from ci"; exec /bin/bash -l
#      env = TY_CI=1
#      close-on-exit = false
tongyou app split s3 --vertical --profile ci --focus
# 期望：新 pane 打印 "hello from ci"，env 里有 TY_CI=1

# 3. overrides 叠加
tongyou app split s3 --horizontal --profile ci \
  --set env=EXTRA=yes \
  --set font-size=20
# 期望：新 pane env 同时有 TY_CI=1 + EXTRA=yes

# 4. new-tab
tongyou app new-tab s3 --profile ci --focus
# 期望：新 tab 根 pane 按 ci 启动

# 5. float
tongyou app float-pane create s3 --profile ci --focus
# 期望：新 float 按 ci 启动

# 6. 不存在的 profile
tongyou app split s3 --profile nonexistent 2>&1
# 期望：CLI 退出码非 0，错误码 PROFILE_NOT_FOUND，daemon **没有**收到请求

# 7. 非法 override
tongyou app split s3 --profile ci --set broken-no-equals 2>&1
# 期望：CLI 立即退出（Phase 6 已实现），不发请求

# 8. 不传 profile/overrides（回归：老调用方式）
tongyou app split s3 --vertical
# 期望：行为与 Phase 7 前完全一致（split 继承父 pane profile、cwd）

# 9. Phase 6.B bugfix 回归（zombie pane）
#    用带 close-on-exit=false 的 profile + 瞬退命令
tongyou app split s3 --profile ci-quick --profile-set command=/bin/true
# 等命令结束后：Cmd+W 能关掉、ESC 能关、Enter 能重跑
```

### 文档更新

- `dev/plan/pane-profile-plan.md`：Phase 6 的"已完成 6 个阶段后可以做但暂不列入"列表里把"远程模式支持 profile/overrides"这条挪出来或备注 "见 pane-profile-remote-plan.md"
- 本文档：每个 sub-phase 完成后在对应段落末尾加一行 commit 哈希（便于追溯）

### 完成标准

- 上述 9 步手工验证全部符合预期
- `make build` 绿 + 全部单元测试绿
- 代码里 `grep -E 'createFloatingPaneWithCommand|profile/overrides not yet supported'` 全空

---

## 每阶段独立提交

按 Phase 6 的惯例，每个 sub-phase 一个 commit，commit message 用：

- `feat(profile): encode StartupSnapshot on the wire (Phase 7.1)`
- `feat(profile): remote create ops carry profileID + snapshot (Phase 7.2)`
- `feat(profile): GUI resolves profile client-side for remote sessions (Phase 7.3)`
- `chore(profile): Phase 7 end-to-end verification + plan docs (Phase 7.4)`

---

## 已完成 Phase 7 后可以做但暂不列入本计划

- **远程 zombie pane 的 rerun**：当前 `rerunTreePaneCommand`（`TongYou/App/SessionManager.swift`）是 local 专用。Remote 版需要一个新 wire 消息 `rerunPane(SessionID, PaneID)`，服务端从 `TerminalPane.startupSnapshot` 拉出快照重启 PTY。正交于本计划，可作为 Phase 8 的一个小增量。
- **跨主机 tyd（TCP / SSH 隧道）**：当前假设同机 Unix socket。跨机时要考虑的新问题：token 分发、wire 的 TLS、远程文件路径语义（`cwd = ~` 在 client 和 server 是不同路径）。本计划的设计已为此预留（daemon 不读 profile 文件），但其他各层还需要补。
- **profile 热重载传播到 remote**：目前 Live 字段热重载完全在 GUI 侧，不需要 server 参与。如果将来想让 server 也知道 profile 变化（比如记录日志、在 session restore 时重新解析 Startup 字段），需要单独机制。
