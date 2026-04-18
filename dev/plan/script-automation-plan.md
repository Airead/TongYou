# TongYou 脚本自动化设计方案

## 概述

本文档描述 TongYou 终端模拟器的脚本自动化体系设计。该方案基于 Unix domain socket 控制平面，外部 CLI 工具 `tongyou` 通过 socket 与运行中的 TongYou GUI App 建立连接，发送命令并接收响应；GUI App 内部通过独立的控制服务器监听 socket、解析命令，并直接操作窗口 / 会话 / 标签页 / 面板等 UI 状态。

---

## 1. 架构总览

```
外部脚本 / CLI
      │
      v
  tongyou CLI
      │
      ├──► tongyou daemon <cmd>  ──────► Daemon Socket (二进制协议 TYProtocol)
      │
      └──► tongyou app <cmd>  ─────────► GUI Socket (JSON/Line)
                                          │
                                          ├── Local Session: SessionManager 直接处理
                                          └── Remote Session: RemoteSessionClient 代理转发
```

### 核心设计原则

1. **GUI Socket 是统一自动化入口**：所有终端交互类命令均通过 `tongyou app` 子命令走 GUI Socket。GUI App 既可直接处理 local session，也可代理转发 remote session 的指令。
2. **不 fallback 到 Daemon**：一旦使用 `app` 子命令，严格绑定 GUI。若 GUI 未运行，直接返回 `GUI_NOT_RUNNING` 错误。
3. **Daemon 子命令保持独立**：`tongyou daemon` 仅用于守护进程生命周期管理和 detached remote session 操作。
4. **多实例共存**：通过 pid-based socket 路径避免多个 GUI 实例之间的冲突。

---

## 2. CLI 子命令结构

### 2.1 `tongyou daemon` — 守护进程管理

```bash
tongyou daemon status
tongyou daemon start [--daemonize]
tongyou daemon stop

tongyou daemon list [--json]
tongyou daemon create [name]
tongyou daemon close <session>
```

### 2.2 `tongyou app` — 通过 GUI 自动化

```bash
# Session 生命周期
tongyou app list [--json]
tongyou app create [name] [--local] [--remote] [--json]
tongyou app close <session> [--json]
tongyou app attach <session> [--json]

# 终端交互
tongyou app send <session> <text> [--json]
tongyou app key <session> <key> [--json]

# Tab / Pane 结构
tongyou app new-tab <session> [--json]
tongyou app select-tab <session> <index> [--json]
tongyou app close-tab <session> <index> [--json]
tongyou app split <session> [--vertical|--horizontal] [--json]
tongyou app focus-pane <ref> [--json]
tongyou app close-pane <ref> [--json]
tongyou app resize-pane <ref> --ratio 0.3 [--json]

# Float Pane
tongyou app float-pane create <session> [--profile <name>] [--json]
tongyou app float-pane focus <ref> [--json]
tongyou app float-pane close <ref> [--json]
tongyou app float-pane pin <ref> [--json]
tongyou app float-pane move <ref> --x 0.0 --y 0.0 --width 0.5 --height 0.5 [--json]

# GUI 状态
tongyou app window-focus [--json]
```

### 2.3 `--json` 全局标志

`--json` 作为 `app` 和 `daemon` 子命令级别的全局标志，放置在子命令之后、动作之前：

```bash
tongyou app --json list
tongyou daemon --json list
```

- 默认输出：人类可读的文本格式
- `--json` 输出：统一的 JSON 响应包装，便于脚本解析

---

## 3. JSON/Line 协议规范（GUI Socket）

GUI Socket 采用基于行的 JSON 协议，与 cmux v2 协议对齐。

### 3.1 请求格式

```json
{"id":"1","method":"pane.sendText","params":{"session":"dev","pane":"dev/pane:1","text":"ls\n"}}
```

### 3.2 响应格式

**成功：**

```json
{"id":"1","ok":true,"result":{}}
```

**错误：**

```json
{"id":"1","ok":false,"error":{"code":"SESSION_NOT_FOUND","message":"No session matches 'dev'"}}
```

### 3.3 关键约定

- **行级协议**：每行一个完整 JSON，换行符 `\n` 作为帧分隔符
- **内部转义**：JSON 序列化后，字符串中的 `\n` 强制转义为 `\\n`，确保不会破坏帧分隔
- **`id`** 由客户端生成，服务端原样返回
- **请求-响应模型**：每个请求对应一个响应，CLI 侧设置默认 10 秒超时

---

## 4. Ref 句柄系统

### 4.1 分配规则

| 对象 | Ref 格式 | 分配方式 |
|------|----------|----------|
| Session | `name` 或 `sess:<n>` | 用户命名优先；未命名则按创建顺序递增 `sess:1`, `sess:2`... |
| Tab | `<session>/tab:<n>` | 按 tab 创建顺序递增，不回收 |
| Tree Pane | `<session>/pane:<n>` | 全局 pane 计数器递增，不回收 |
| Float Pane | `<session>/float:<n>` | 独立计数器递增，不回收 |

### 4.2 示例

```
dev
dev/tab:1
dev/pane:3
dev/float:1
```

### 4.3 引用解析

- CLI 和 GUI Socket 都支持**模糊匹配**：前缀匹配 session 名称（唯一时成功，冲突时报错）
- Ref 一旦分配**永不回收**，保证脚本缓存的引用稳定
- 内部维护 `ref → UUID` 双向映射表，每次命令执行前调用 `refreshRefs()` 同步

### 4.4 为什么选择扁平 pane 编号

TongYou 内部 `PaneNode` 是二分树结构，但所有查找均通过 `UUID` 扫描，不存在 index path 概念。引入树形路径（如 `1.2.1`）需要额外维护一套与 UI 同步的索引逻辑，而扁平 `pane:<n>` 直接映射 `UUID`，更简单稳定。

---

## 5. GUI Socket 生命周期与安全

### 5.1 Socket 路径

- **路径**：`~/.tongyou/tongyou-gui-<pid>.sock`
- **权限**：`0o600`（仅 owner 可访问）
- **多实例**：每个 GUI 实例绑定各自 pid 的 socket；CLI 扫描目录并按修改时间探测可用 socket

### 5.2 连接源校验

- 使用 `LOCAL_PEERCRED` 检查 peer UID 与 socket owner 一致
- 不同 UID 直接拒绝连接

### 5.3 认证

- **Phase 1 不实现认证**
- 协议解析层预留 `auth.login` 方法入口，未来 Phase 2 可直接扩展

### 5.4 生命周期

- 随 App 启动 bind，随 App 退出自动释放
- Accept loop 跑在独立的 `DispatchQueue` 上
- 每个客户端连接派发独立任务处理
- 无需 cmux 级别的 rearm 故障恢复逻辑（进程结束 socket 自然消失）

---

## 6. 焦点策略（不偷焦点）

### 6.1 白名单机制

只有以下命令允许触发窗口激活（`NSApp.activate`）：

- `pane.focus`
- `window.focus`

### 6.2 行为规则

- 非焦点命令（`send`、`key`、`split`、`close-pane`、`resize-pane` 等）**只修改状态或发送数据**
- 即使目标 session 在后台，也禁止将 TongYou 提到前台
- 实现方式：GUI Socket 处理请求时传递 `isAutomationRequest = true`，`SessionManager` / `FocusManager` 在激活前检查命令是否在白名单中

---

## 7. 统一 Error Code 规范

| Code | 场景 |
|------|------|
| `SESSION_NOT_FOUND` | 目标 session 不存在 |
| `TAB_NOT_FOUND` | 目标 tab 不存在 |
| `PANE_NOT_FOUND` | 目标 pane / float 不存在 |
| `INVALID_REF` | ref 格式错误或已失效 |
| `GUI_NOT_RUNNING` | GUI socket 无法连接（`app` 命令专属） |
| `FOCUS_DENIED` | 非焦点命令试图激活窗口 |
| `MAIN_THREAD_TIMEOUT` | GUI 主线程同步超时 |
| `UNSUPPORTED_OPERATION` | session 类型不支持此操作（如对 local session 执行 `attach`） |
| `INVALID_PARAMS` | 参数缺失或类型错误 |
| `INTERNAL_ERROR` | 未预期的内部错误 |

---

## 8. 线程模型

### 8.1 GUI Socket 服务端

1. **Accept Loop**：独立 `DispatchQueue`，负责 `accept()` 和派发客户端 handler
2. **Client Handler**：后台线程中解析 JSON、校验参数、解析 Ref
3. **主线程同步**：
   - 读状态（如 `session.list`）：尽可能在后台读取已发布状态
   - 写 UI / 操作 PTY（如 `send`、`split`）：`DispatchQueue.main.sync`
   - 高频 telemetry 禁止走 sync 路径（本方案不涉及）

### 8.2 CLI 侧

- `tongyou app` 命令：连接 GUI socket，发送 JSON，等待单行响应，默认 10 秒超时
- `tongyou daemon` 命令：复用现有的 `TYConnection` 二进制协议逻辑

---

## 9. 命令细节补充

### 9.1 `key` 命令的键值表示法

支持组合键编码规范，采用 `+` 连接修饰符与主键：

```bash
tongyou app key dev Enter
tongyou app key dev "Ctrl+C"
tongyou app key dev "Cmd+T"
tongyou app key dev "Alt+Left"
```

解析规则：
- 修饰符：`Ctrl`、`Cmd`、`Alt`、`Shift`
- 主键：字母、数字、`Enter`、`Escape`、`Tab`、`Backspace`、`Delete`、`Arrow*`、`F1`~`F12`
- 大小写不敏感，标准化为内部 VT 序列或 NSEvent 处理

### 9.2 `resize-pane` 命令

- 传入 pane ref（如 `dev/pane:1`）
- 内部自动找到该 pane 的**父 split node**，修改其 `ratio`
- 如果 pane 不存在或无法找到父 split，返回 `PANE_NOT_FOUND` 或 `UNSUPPORTED_OPERATION`

### 9.3 `list` 默认输出字段

默认文本格式显示以下列：

```
NAME    TYPE    TABS    PANES
```

- `TYPE`：`local` 或 `remote`
- `TABS`：标签页数量
- `PANES`：树形 pane + 浮动 pane 总数

### 9.4 `send` 命令

严格按用户传入的原始字符串发送，**不自动追加 `\n`**。用户需要显式包含换行：

```bash
tongyou app send dev "ls\n"
```

### 9.5 `create --remote` 时 GUI 的行为

GUI 通过 `RemoteSessionClient` 请求 daemon 创建 session，然后立即 `attachSession` 到当前 GUI。如果 daemon 返回失败，直接透传错误给 CLI。若 GUI 未运行，直接返回 `GUI_NOT_RUNNING`。

---

## 10. 实现范围（Phase 1）

### 包含内容

1. GUI App 侧 `GUIAutomationServer`（socket 监听 + JSON/Line 解析）
2. `tongyou` CLI 侧的 `AppControlClient`（命令解析 + socket 连接）
3. Ref 映射系统（`refreshRefs` + `ref → UUID` 查询）
4. 焦点策略白名单与线程同步策略
5. 完整命令集：session / tab / pane / float-pane / window-focus
6. `--json` 全局标志支持
7. Socket 路径自动发现（CLI 侧）

### 不包含内容

1. 认证机制（`auth.login` 仅预留接口位置）
2. TCP relay / 远程 SSH 控制
3. 屏幕截图 / `capture` 类查询命令
4. Daemon Socket 的 JSON/Line 网关（daemon 保持现有二进制协议不变）

---

## 11. 关键文件预期

| 文件 | 职责 |
|------|------|
| `TongYou/App/GUIAutomationServer.swift` | GUI Socket 服务端、accept loop、JSON 解析、命令分发 |
| `TongYou/App/GUIAutomationRefStore.swift` | Ref 映射管理、refreshRefs |
| `TongYou/App/GUIAutomationPolicy.swift` | 焦点策略白名单、主线程同步封装 |
| `Packages/TongYouCore/tongyou/AppControlClient.swift` | CLI 侧 `app` 子命令实现 |
| `Packages/TongYouCore/tongyou/SocketPathResolver.swift` | GUI socket 自动发现逻辑 |

---

## 结语

本方案在保持 TongYou 现有架构（Local Session 绑定 GUI、Remote Session 托管 Daemon）不变的前提下，通过 GUI Socket 提供统一的脚本自动化入口。外部脚本无需关心 session 是 local 还是 remote，只需与运行中的 GUI App 通信即可。安全、焦点策略、多实例隔离等设计均借鉴了 cmux 的工程实践经验。
