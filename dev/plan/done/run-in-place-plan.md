# In-Place 命令运行器实现计划

## 目标

实现通过快捷键在当前 pane 下快速运行一个命令，使用该命令的输出替换当前 pane 的内容，之后可以与新命令交互。当新命令退出后恢复之前 pane 的内容。例如通过 `alt+m` 运行 `lazygit`。

参考 Zellij 的 `in_place` 配置设计，但利用 TongYou 轻量 pane + 重 controller 的架构，采用 **Pane-Level Controller 栈** 方案，无需改动 `PaneNode` 布局树。

---

## 总体策略

按自底向上的顺序逐步叠加功能：
1. 让底层 `PTYProcess` 和 `TerminalController` 支持执行任意命令
2. 实现 Controller 的 **Suspend/Resume** 与 **Overlay Stack**
3. 最后接入 UI 绑定和快捷键配置

每个阶段都有明确的编译/运行验证点。

---

## Phase 1：PTYProcess 支持自定义命令

### 目标
让 `PTYProcess` 能够执行用户指定的命令（而不仅是默认 shell）。

### 具体改动
1. **修改 `PTYProcess.start()`**
   增加重载：
   `start(command: String, arguments: [String], columns: UInt16, rows: UInt16, ...)`
2. **修改 `forkAndExec()`**
   当提供了 `command` 时，将 `argv[0]` 设为命令名，后续追加参数；否则保持现有 shell 行为。

### 验证方式
- 编写临时测试，创建 `PTYProcess`，调用 `start(command: "echo", arguments: ["hello_from_pty"])`。
- 在 `onRead` 中检查输出包含 `"hello_from_pty"`。
- 再测试 `start(command: "lazygit", arguments: [])` 能正常启动进程（验证非 shell 程序也能拿到 PTY）。

### 输出标志
`PTYProcess` 拥有 `start(command:arguments:...)` API，单元测试通过。

---

## Phase 2：TerminalController 支持启动指定命令

### 目标
`TerminalController` 作为 `PTYProcess` 的封装层，能够按需启动自定义命令。

### 具体改动
1. **修改 `TerminalController.start()`**
   签名改为：
   `func start(workingDirectory: String? = nil, command: String? = nil, arguments: [String] = [])`
2. 在内部根据 `command` 决定调用 `process.start(columns:rows:workingDirectory:)` 或新的 `process.start(command:arguments:columns:rows:workingDirectory:)`。

### 验证方式
- 单元测试：创建 `TerminalController`，启动 `command: "echo"` / `arguments: ["hi"]`，验证 `consumeSnapshot()` 最终能读到包含 `"hi"` 的屏幕内容。
- 单元测试：启动 `command: "cat"`，写入数据后验证能回显（确认 PTY 双向通信正常）。
- 手动验证：临时修改 `SessionManager.ensureLocalController(for:)`，把某个 pane 的启动命令换成 `lazygit`，确认窗口能显示 lazygit 界面。

### 输出标志
`TerminalController.start` 支持自定义命令参数，测试通过。

---

## Phase 3：Controller 的 Suspend/Resume 机制

### 目标
原 pane 被覆盖时，停止其画面渲染回调，但**保持 PTY 进程和后台读取 alive**，以便恢复时状态完整。

### 具体改动
1. **`TerminalController` 新增状态**：
   ```swift
   private(set) var isSuspended: Bool = false
   ```
2. **新增方法**：
   ```swift
   func suspend() { isSuspended = true }
   func resume() { isSuspended = false; markScreenDirty() }
   ```
3. **修改 `markScreenDirty()`**：
   当 `isSuspended == true` 时，仅设置 `screenDirty = true`，但不调用 `onNeedsDisplay?()`。
4. **修改 `consumeSnapshot()`**：
   照常返回 snapshot（这样恢复后的第一帧就能拿到最新内容），不影响 suspend。

### 验证方式
- 单元测试：
  1. 启动一个 `cat` controller，向其 PTY 写入数据。
  2. 调用 `suspend()`，再写入更多数据。
  3. 验证 `onNeedsDisplay` 在 suspend 期间不再被调用。
  4. 调用 `resume()`，验证 `onNeedsDisplay` 立即触发，且 `consumeSnapshot()` 包含 suspend 期间累积的所有新内容。

### 输出标志
`suspend()` / `resume()` 工作正常，原 pane 在后台能继续接收输出。

---

## Phase 4：SessionManager 的 Overlay Stack 架构

### 目标
为每个 pane 维护一个 `TerminalController` 栈，支持 push（运行 in-place 命令）和 pop（命令退出后恢复）。

### 具体改动
1. **`SessionManager` 新增属性**：
   ```swift
   private var overlayStacks: [UUID: [TerminalController]] = [:]
   ```
2. **新增辅助方法**：
   ```swift
   func activeController(for paneID: UUID) -> TerminalController? {
       overlayStacks[paneID]?.last ?? localControllers[paneID]
   }
   ```
3. **新增 `runInPlace(at:command:arguments:)`**：
   - 获取 `activeController(for:)`，调用其 `suspend()`。
   - 创建新 `TerminalController`，继承当前 pane 的 `columns/rows`，启动指定命令。
   - 设置 `onProcessExited`：调用 `restoreFromInPlace(at:)`。
   - 将新 controller push 进 `overlayStacks[paneID]`。
4. **新增 `restoreFromInPlace(at:)`**：
   - pop 栈顶 controller，调用 `stop()`。
   - 如果栈变空，移除该 key。
   - 调用新的 `activeController` 的 `resume()`。
5. **修改关闭 pane 的逻辑**：
   - 关闭 pane 时，先停止其 overlay stack 中所有 controller，再停止底层 controller。

### 验证方式
- 单元测试（使用 mock 或真实 PTY）：
  1. `ensureLocalController(for: pane1)` 创建基础 shell。
  2. 调用 `runInPlace(at: pane1, command: "echo", arguments: ["overlay"])`。
  3. 验证 `activeController(for: pane1)` 返回 overlay controller。
  4. 模拟 overlay 进程退出，验证 `activeController` 恢复为基础 controller，且基础 controller `isSuspended == false`。
  5. 验证基础 shell 的 PTY 仍在运行（可向其中写入并收到回调）。
- 手动验证：临时在 `SessionManager` 中硬编码某个 pane 创建 3 秒后自动 `runInPlace("top")`，观察 3 秒后 UI 是否切换，关闭 top 后是否恢复。

### 输出标志
`SessionManager` 支持 push/pop overlay controller，进程生命周期管理正确。

---

## Phase 5：MetalView 动态绑定 Active Controller

### 目标
当 pane 的 active controller 切换时，UI 能无缝渲染新的内容。

### 具体改动
1. **`MetalView` 新增 `bindController(_:)`**：
   - 解绑旧 controller 的 `onNeedsDisplay`。
   - 设置 `terminalController = newController`。
   - 绑定新 controller 的 `onNeedsDisplay` 到 `wakeDisplayLink()`。
   - 调用 `setNeedsDisplay()` 或 `wakeDisplayLink()` 强制刷新。
2. **修改 `TerminalPaneContainerView.updateNSView(...)`**：
   - 从 `sessionManager.activeController(for: paneID)` 获取当前 active controller。
   - 如果 `metalView.terminalController !== activeController`，调用 `metalView.bindController(activeController)`。
3. **确保 `TerminalControlling` 协议暴露 `onNeedsDisplay` 的 settable 能力**（本地和远程 controller 都需要支持重新绑定）。

### 验证方式
- 手动验证：
  1. 打开一个 pane，运行 `vim` 或 `top`。
  2. 临时在代码中触发 `sessionManager.runInPlace(at: ..., command: "lazygit")`（例如通过一个调试菜单项）。
  3. 观察画面是否立即变为 lazygit，且键盘输入能操作 lazygit。
  4. 按 `q` 退出 lazygit，观察画面是否恢复为之前的 `vim`/`top`，且键盘输入重新路由到底层进程。

### 输出标志
UI 能实时切换 in-place 命令，退出后无缝恢复。

---

## Phase 6：快捷键与配置集成

### 目标
让用户可以通过类似 `alt+m` 的快捷键触发 in-place 命令，并在配置文件中定义映射。

### 具体改动
1. **`Keybinding.Action` 新增**：
   ```swift
   case runInPlace(command: String, arguments: [String])
   ```
2. **`TabAction` 镜像新增**：
   ```swift
   case runInPlace(command: String, arguments: [String])
   ```
3. **配置解析**：
   - 在 `Keybinding.parse(...)` 中支持类似如下 TOML：
     ```toml
     [[keybindings]]
     key = "m"
     modifiers = ["alt"]
     action = { runInPlace = { command = "lazygit" } }
     ```
   - 也支持带参数：`{ runInPlace = { command = "git", args = ["log"] } }`
4. **`TerminalWindowView.handleTabAction(_:)`**：
   ```swift
   case .runInPlace(let cmd, let args):
       if let paneID = focusManager.focusedPaneID {
           sessionManager.runInPlace(at: paneID, command: cmd, arguments: args)
       }
   ```
5. **`MetalView` 快捷键拦截**：
   - 在 `performKeyEquivalent` 或 `keyDown` 中匹配到 `runInPlace` action 时，将其转换为 `TabAction` 向上分发。

### 验证方式
- 在默认配置中加入 `alt+m -> runInPlace("lazygit")`。
- 启动应用，按 `Alt+M`，验证 lazygit 在聚焦 pane 中打开。
- 退出 lazygit，验证原内容恢复。
- 验证未聚焦 pane 不会响应此快捷键。
- 单元测试：解析配置字符串并断言能正确生成 `runInPlace` action。

### 输出标志
快捷键可触发 in-place 运行，配置解析正确。

---

## Phase 7：边界情况与完善

### 目标
处理 resize、标题更新、嵌套 overlay、异常退出等边界场景。

### 具体改动
1. **Resize 同步到整个 Stack**
   在 `SessionManager` resize 逻辑中，找到 pane 对应的所有 overlay controller + 底层 controller，全部调用 `resize(columns:rows:cellWidth:cellHeight:)`。
2. **标题更新**
   overlay controller 的 `onTitleChanged` 需要被转发到 UI，以便用户知道当前在运行什么。当恢复底层 controller 时，恢复其标题。
3. **嵌套支持**
   `overlayStacks[paneID]` 是数组，天然支持多层嵌套（lazygit 里再按 alt+n 打开 fzf）。验证 `runInPlace` 在已有 overlay 的 pane 上能继续 push。
4. **快速连击保护**
   在 `runInPlace` 中加入防抖：若栈顶 controller 的进程刚启动、尚未稳定，忽略重复请求。
5. **Pane 关闭时清理 Stack**
   确保 `closePane` / `closeTab` 会遍历并 stop 所有 overlay controller。
6. **（可选）`close_on_exit` 行为**
   若用户配置 `close_on_exit = true`，则 overlay 退出时不仅 pop，还连带关闭底层 pane。

### 验证方式
- **Resize**：打开 lazygit（in-place），调整窗口大小，确认 lazygit 界面正确重排；退出后确认底层 shell 也重排。
- **嵌套**：在 lazygit 中再触发另一个 in-place 命令（如 `htop`），确认能进入；退出 htop 回到 lazygit；退出 lazygit 回到 shell。
- **标题**：观察窗口标题随 in-place 命令变化，恢复后标题还原。
- **关闭**：在 in-place 命令运行时直接关闭 tab，确认所有进程被 kill，无泄漏。

### 输出标志
所有边界场景行为正确，功能达到生产可用。

---

## 快速启动建议（MVP 路径）

如果希望尽快看到效果，可以跳过配置解析的完整实现，走 **硬编码快捷键 → 硬编码命令** 的捷径：

1. **Phase 1 → Phase 2 → Phase 3 → Phase 4**：完成底层和 UI 支持。
2. 在 `MetalView.performKeyEquivalent` 中临时硬编码：
   ```swift
   if event.keyCode == /* m */ 46, event.modifierFlags.contains(.option) {
       sessionManager.runInPlace(at: paneID, command: "lazygit", arguments: [])
       return true
   }
   ```
3. 验证效果后，再进入 **Phase 5** 做成可配置的。

这种方式能在 1-2 天内跑通完整交互闭环。

---

## 附录：与 Zellij 的对比

| 维度 | Zellij | TongYou 方案 |
|------|--------|--------------|
| 实现层级 | 替换 `PaneNode` 树中的 pane 对象 | 在单个 pane 内切换 `TerminalController` |
| 原 pane 保存 | `suppressed_panes` 旁路表 | `overlayStacks` controller 栈 |
| 布局影响 | 需要修改 `TiledPanes`/`FloatingPanes` | **无需改动 `PaneNode` 布局树** |
| 恢复 | 把原 pane 插回布局 | 把原 controller 恢复为栈顶 |
