# CommandPalette 历史记录 - 实现方案

让 CommandPalette 的所有 scope（ssh、command、profile、tab、session）都能记录最近使用过的操作，空查询时优先展示历史记录，减少重复输入。

核心理念：**统一 SQLite 存储，替代原有 SSHHistory TSV 文件**。所有 scope 共用一张表，按 MRU（Most Recently Used）排序；历史记录仅作为 palette 的快捷入口，不影响各 scope 的原有数据源逻辑。

---

## 总体设计

### 核心概念

1. **PaletteHistory**。统一的 SQLite actor，管理所有 scope 的操作历史。表结构简单，只有 `scope` + `identifier` + `display` + `timestamp` + `metadata`。
2. **INSERT OR REPLACE 去重**。同一 scope + identifier 重复使用时只更新时间戳，不新增记录。
3. **空查询注入历史**。`CommandPaletteController` 在 `refreshRows` 时，当 `query.isEmpty` 从 `PaletteHistory` 读取最近 5 条该 scope 的历史记录，去重后插入候选列表顶部。
4. **SSH 历史迁移**。原有 `SSHHistory`（TSV 文件）完全删除，SSH 连接历史改由 `PaletteHistory` 记录。`SSHLauncher` 不再直接读写历史文件，改为通过回调通知外部记录。
5. **session / tab 动态性**。session 和 tab 是运行时动态列表，历史记录只记录 UUID。如果打开 palette 时该 session/tab 已关闭，则历史记录跳过不显示（不保留死链接）。

### 文件与路径

| 用途 | 路径 | 说明 |
|---|---|---|
| 历史数据库 | `~/.cache/tongyou/palette-history.db` | SQLite 单文件；测试注入临时目录 |
| SSH 规则 | `~/.config/tongyou/ssh-rules.txt` | 不变 |
| SSH profile 模板 | `~/.config/tongyou/profiles/ssh*.txt` | 不变 |

### 交互总览

- **空查询时**：列表顶部显示最多 5 条该 scope 的最近历史记录，左侧带 `clock` 图标，与常规候选视觉区分。
- **非空查询时**：不显示历史记录，避免干扰 fuzzy match 的精确搜索。
- **回车执行**：commit 成功后自动记录到 `PaletteHistory`（`INSERT OR REPLACE`）。
- **⌘⌫**：在历史记录行上按 ⌘⌫，从历史中删除该条记录（不删除实际资源）。在其他 scope 保持原有行为（SSH 删除历史、session 关闭 session 等）。

### 各 scope 的 identifier 与 display

| Scope | Identifier 示例 | Display 示例 | metadata |
|---|---|---|---|
| ssh | `alice@db-prod-1` | `db-prod-1` | `{"template":"ssh-prod"}` |
| command | `newTab` | `New Tab` | `{}` |
| profile | `dev-server` | `dev-server` | `{}` |
| session | `session-uuid-string` | `Session Name` | `{}` |
| tab | `tab-uuid-string` | `Tab Title` | `{}` |

---

## Phase 分解

每个 Phase 一次 commit，严格独立编译、独立测试。

---

## Phase 1：PaletteHistory 数据层

### 目标

新建 `PaletteHistory` actor，SQLite 持久化，支持增删查、去重、容量管理。

### 涉及文件

- 新增 `TongYou/Config/PaletteHistory.swift`
- 新增 `TongYouTests/PaletteHistoryTests.swift`

### 实现要点

1. **Schema**：
   ```sql
   CREATE TABLE palette_history (
       id          INTEGER PRIMARY KEY AUTOINCREMENT,
       scope       TEXT    NOT NULL,
       identifier  TEXT    NOT NULL,
       display     TEXT    NOT NULL,
       metadata    TEXT    NOT NULL DEFAULT '{}',
       timestamp   REAL    NOT NULL
   );
   CREATE UNIQUE INDEX idx_scope_identifier ON palette_history(scope, identifier);
   CREATE INDEX idx_scope_time ON palette_history(scope, timestamp DESC);
   ```
2. **去重**：`INSERT OR REPLACE INTO palette_history (scope, identifier, display, metadata, timestamp) VALUES (?, ?, ?, ?, ?)`。同 scope + identifier 自动覆盖旧记录，实现 MRU。
3. **容量**：总量超 200 条时，删除最旧的 50 条（按 timestamp ASC）。
4. **文件位置**：`~/.cache/tongyou/palette-history.db`。构造函数接受 `directoryURL` 注入，测试用临时目录。
5. **并发**：actor 隔离，SQLite C API 直接操作（macOS 自带 `sqlite3`，零依赖）。
6. **metadata**：JSON 字符串，SSH scope 用来存 templateID，其他 scope 空对象 `{}`。

### Public API

```swift
actor PaletteHistory {
    init(directoryURL: URL = PaletteHistory.defaultDirectory)
    
    func record(scope: PaletteScope, identifier: String, display: String, metadata: [String: String] = [:])
    func recent(scope: PaletteScope, limit: Int) -> [PaletteHistoryEntry]
    func remove(scope: PaletteScope, identifier: String) -> Bool
    func clear(scope: PaletteScope)
}

struct PaletteHistoryEntry: Sendable, Equatable {
    let id: Int
    let scope: PaletteScope
    let identifier: String
    let display: String
    let metadata: [String: String]
    let timestamp: Date
}
```

### 测试

- **全部使用临时目录**，禁止触碰 `~/.cache`（CLAUDE.md 测试隔离规则）。
- `recordInsertsNewEntry`
- `recordUpdatesExistingEntry` — 同 scope + identifier 再次 record，timestamp 更新，id 可能变（INSERT OR REPLACE）
- `recentReturnsMRUOrder`
- `recentLimitsResults`
- `recentFiltersByScope`
- `removeDeletesSpecificEntry`
- `clearEmptiesScope`
- `capacityTruncatesOldest`
- `missingDBStartsEmpty`

### 完成标准

- API 完整；独立测试全绿；不触碰用户真实缓存。

---

## Phase 2：删除 SSHHistory，迁移 SSHLauncher

### 目标

删除原有 `SSHHistory`（TSV 文件），`SSHLauncher` 不再直接管理历史文件，改为通过回调通知外部记录历史。

### 涉及文件

- **删除** `TongYou/Config/SSHHistory.swift`
- **删除** `TongYouTests/SSHHistoryTests.swift`
- 修改 `TongYou/App/SSHLauncher.swift`
- 修改 `TongYouTests/SSHLauncherTests.swift`
- 修改 `TongYou/App/TerminalWindowView.swift`（移除 `sshHistory` state，改为 `paletteHistory`）

### 实现要点

1. **删除 `SSHHistory` 类型**：包括 `SSHHistoryRecord`、`SSHHistoryEntry`、`actor SSHHistory` 全部删除。
2. **`SSHLauncher` 移除 `history` 依赖**：
   - `init` 移除 `history: SSHHistory` 参数
   - 移除 `deleteHistory(target:)` 方法
   - 移除 `rebuildCandidates()` 中对 `history.entries()` 的调用
3. **`SSHLauncher` 新增历史回调**：
   ```swift
   var onRecordHistory: ((SSHCandidate, String) -> Void)?
   ```
   `commit()` 和 `recordBatchHistory()` 成功后调用 `onRecordHistory?(candidate, templateID)`，由外部（`TerminalWindowView`）写入 `PaletteHistory`。
4. **`reload()` 签名变更**：
   ```swift
   func reload(
       historyCandidates: [String] = [],
       ruleFileURL: URL = URL(fileURLWithPath: "/dev/null"),
       sshConfigURL: URL = SSHConfigHosts.defaultURL
   ) async
   ```
   历史候选由外部传入，launcher 只负责合并 + 去重。
5. **`mergeCandidates` 静态方法保留**：参数改为 `history: [String], sshHosts: [SSHConfigHost]`，返回 `[SSHCandidate]`。
6. **`TerminalWindowView`**：
   - `@State private var sshHistory = SSHHistory()` 改为 `@State private var paletteHistory = PaletteHistory()`
   - `openCommandPalette()` 中 `await sshLauncher.reload()` 改为传入 `paletteHistory.recent(scope: .ssh)` 的历史 target 列表
   - `deleteSSHHistoryFromPalette()` 改为调用 `paletteHistory.remove(scope: .ssh, identifier: target)`

### 测试

- `SSHLauncherTests`：
  - `historyAppendedOnSuccess` → 改为验证 `onRecordHistory` 回调被调用，参数正确
  - `historyNotAppendedOnFailure` → 改为验证 `onRecordHistory` 未被调用
  - `recordBatchHistoryAppendsEveryResolution` → 同上，验证回调
  - 移除所有直接操作 `SSHHistory` 的测试逻辑
  - `makeEnv()` 移除 `history` 参数和相关清理逻辑

### 完成标准

- `SSHHistory` 文件彻底删除；`SSHLauncher` 编译通过；单测全绿；SSH 连接仍能记录历史（通过回调到 `PaletteHistory`）。

---

## Phase 3：CommandPaletteController 集成历史

### 目标

`CommandPaletteController` 支持注入历史候选，空查询时自动合并到列表顶部。

### 涉及文件

- 修改 `TongYou/App/CommandPaletteController.swift`
- 修改 `TongYou/App/CommandPaletteView.swift`
- 修改 `TongYouTests/CommandPaletteControllerTests.swift`

### 实现要点

1. **`PaletteCandidate` 扩展**：
   ```swift
   struct PaletteCandidate {
       // ... existing fields ...
       let historyIdentifier: String? = nil  // nil = 正常候选；非 nil = 历史记录
   }
   ```
2. **`CommandPaletteController` 新增属性**：
   ```swift
   /// 历史候选。外部在 open 前注入。
   var historyCandidates: [PaletteCandidate] = []
   
   /// ⌘⌫ 删除历史记录回调
   var onDeleteHistoryEntry: ((PaletteScope, String) -> Void)?
   ```
3. **`refreshRows` 逻辑变更**：
   - 空查询时：从 `historyCandidates` 中过滤出当前 `scope` 的候选，去重（identifier 不在常规 pool 中的才显示），插入 `rows` 顶部
   - 非空查询时：不显示历史候选，只 fuzzy match 常规 pool
   - 历史候选最多显示 5 条
4. **`deleteHighlighted()` 逻辑变更**：
   ```swift
   func deleteHighlighted() -> Bool {
       guard rows.indices.contains(highlightedIndex) else { return false }
       let candidate = rows[highlightedIndex].candidate
       
       // 历史记录优先处理
       if let identifier = candidate.historyIdentifier {
           onDeleteHistoryEntry?(candidate.scope, identifier)
           return true
       }
       
       // 原有 scope 逻辑不变
       switch candidate.scope {
       case .ssh:
           // ... existing logic ...
       case .session:
           // ... existing logic ...
       case .command, .profile, .tab:
           return false
       }
   }
   ```
5. **`CommandPaletteView` 视觉区分**：
   - `paletteRowView` 中，当 `row.candidate.historyIdentifier != nil` 时，左侧显示 `clock` 图标（替换默认空白占位）
   - 图标颜色：`fgColor.opacity(0.55)`，与 scope 图标一致

### 测试

- `CommandPaletteControllerTests`：
  - `emptyQueryShowsHistoryFirst` — 空查询时历史候选排在常规候选前面
  - `historyDedupedAgainstRegularPool` — 历史候选的 identifier 已在常规 pool 中时，不显示该历史记录
  - `nonEmptyQueryHidesHistory` — 有查询文本时不显示历史候选
  - `historyLimitedToFivePerScope` — 每 scope 最多 5 条历史
  - `deleteHistoryEntryCallsCallback` — ⌘⌫ 在历史行上触发 `onDeleteHistoryEntry`
  - `deleteHistoryDoesNotAffectRegularCandidates` — 删除历史不影响常规候选列表

### 完成标准

- 空查询时历史候选正确显示在列表顶部；非空查询时不显示；⌘⌫ 能删除历史记录；单测全绿。

---

## Phase 4：TerminalWindowView 连接所有 scope

### 目标

在 `TerminalWindowView` 中统一连接 `PaletteHistory`，处理所有 scope 的历史注入、记录和删除。

### 涉及文件

- 修改 `TongYou/App/TerminalWindowView.swift`
- 修改 `TongYou/App/CommandPaletteController.swift`（如果需要调整 `historyCandidates` 的注入时机）

### 实现要点

1. **`TerminalWindowView` 状态变更**：
   - 移除 `@State private var sshHistory = SSHHistory()`
   - 新增 `@State private var paletteHistory = PaletteHistory()`
2. **`openCommandPalette()` 注入历史**：
   ```swift
   private func openCommandPalette() {
       Task { @MainActor in
           // 1. 获取 SSH 历史并传给 launcher
           let sshHistoryEntries = await paletteHistory.recent(scope: .ssh, limit: 50)
           let sshHistoryTargets = sshHistoryEntries.map { $0.identifier }
           await sshLauncher.reload(historyCandidates: sshHistoryTargets, ...)
           
           // 2. 为所有 scope 注入历史候选
           commandPalette.historyCandidates = await buildHistoryCandidates()
           
           // 3. 设置删除回调
           commandPalette.onDeleteHistoryEntry = { scope, identifier in
               await paletteHistory.remove(scope: scope, identifier: identifier)
               // 刷新列表
               commandPalette.historyCandidates = await self.buildHistoryCandidates()
               commandPalette.requestRefocusInput()
           }
           
           commandPalette.open()
       }
   }
   ```
3. **`buildHistoryCandidates()`**：
   ```swift
   private func buildHistoryCandidates() async -> [PaletteCandidate] {
       var candidates: [PaletteCandidate] = []
       for scope in PaletteScope.allCases {
           let entries = await paletteHistory.recent(scope: scope, limit: 5)
           for entry in entries {
               if let candidate = buildHistoryCandidate(entry, scope: scope) {
                   candidates.append(candidate)
               }
           }
       }
       return candidates
   }
   ```
4. **各 scope 的 `buildHistoryCandidate`**：
   - **ssh**：从 `sshLauncher.candidates` 查找 target = `entry.identifier`，找到则构造完整 `PaletteCandidate`（含 `sshResolution`）；找不到则构造 ad-hoc candidate
   - **command**：`Keybinding.Action(rawValue: entry.identifier)` 恢复 action，构造 `PaletteCandidate`
   - **profile**：直接构造（`profileID = entry.identifier`）
   - **session**：从 `sessionManager.sessions` 查找 UUID，找到则构造；找不到则返回 nil（跳过不显示）
   - **tab**：从 `sessionManager.activeTab` 查找，找到则构造；找不到则返回 nil（跳过不显示）
5. **各 scope 的 commit 后记录历史**：
   - `handleSSHCommit()`：commit 成功后 `await paletteHistory.record(scope: .ssh, identifier: target, display: target, metadata: ["template": templateID])`
   - `handleCommandCommit()`：`await paletteHistory.record(scope: .command, identifier: action.rawValue, display: title)`
   - `handleProfileCommit()`：`await paletteHistory.record(scope: .profile, identifier: profileID, display: profileID)`
   - `handleSessionCommit()`：`await paletteHistory.record(scope: .session, identifier: sessionID.uuidString, display: session.name)`
   - `handleTabCommit()`（未来实现）：`await paletteHistory.record(scope: .tab, identifier: tabID.uuidString, display: tab.title)`
6. **删除历史**：
   - `deleteSSHHistoryFromPalette(target:)` 改为 `await paletteHistory.remove(scope: .ssh, identifier: target)`

### 测试

- 集成测试在 `CommandPaletteControllerTests` 中通过 mock 验证：
  - `sshScopeRecordsHistoryOnCommit` — SSH commit 后 `paletteHistory.recent` 包含该 target
  - `commandScopeRecordsHistoryOnCommit`
  - `profileScopeRecordsHistoryOnCommit`
  - `sessionScopeRecordsHistoryOnCommit`
  - `deletedSessionNotShownInHistory` — session 关闭后，历史记录不再显示

### 完成标准

- 所有 scope 的 commit 都能正确记录历史；空查询时历史候选正确显示；session/tab 关闭后对应历史记录不显示；单测全绿。

---

## Phase 5：端到端手工验证 + 清理

### 人工验证脚本

```bash
# 1. 清理历史，保证空状态
rm -f ~/.cache/tongyou/palette-history.db
rm -f ~/.cache/tongyou/ssh-history.txt

# 2. 冷启动 GUI
open -a TongYou.app

# 3. ⌘P → ssh scope 空查询 → 应只看到 ssh_config 候选，无历史记录

# 4. 连接一台 SSH 机器 → 成功

# 5. ⌘P → ssh scope 空查询 → 顶部出现刚连接的机器，带 clock 图标

# 6. 输入模糊搜索 → 历史记录消失，只显示 fuzzy match 结果

# 7. 清空输入 → 历史记录重新出现在顶部

# 8. ⌘P → > scope → 执行一个命令（如 New Tab）

# 9. ⌘P → > scope 空查询 → 顶部出现 "New Tab"，带 clock 图标

# 10. ⌘P → p scope → 选择一个 profile 打开

# 11. ⌘P → p scope 空查询 → 顶部出现刚选的 profile，带 clock 图标

# 12. 在历史记录行上按 ⌘⌫ → 记录消失，面板保持打开

# 13. 清空输入 → 被删除的记录不再出现

# 14. 退出再启动 → 历史记录仍然保留（SQLite 持久化）
```

### 完成标准

- 以上 14 步全通过
- `make build` 绿
- `xcodebuild test -only-testing:TongYouTests` + `cd Packages/TongYouCore && swift test` 全绿
- 无并发 build / test（遵循 CLAUDE.md 规则）

---

## 文件变更清单

| 操作 | 文件 | 说明 |
|---|---|---|
| **新建** | `TongYou/Config/PaletteHistory.swift` | 统一历史存储 actor |
| **新建** | `TongYouTests/PaletteHistoryTests.swift` | 数据层单元测试 |
| **删除** | `TongYou/Config/SSHHistory.swift` | 原有 TSV 历史，被 PaletteHistory 替代 |
| **删除** | `TongYouTests/SSHHistoryTests.swift` | 原有测试 |
| **修改** | `TongYou/App/CommandPaletteController.swift` | 集成 historyCandidates、onDeleteHistoryEntry |
| **修改** | `TongYou/App/CommandPaletteView.swift` | 历史记录行 clock 图标 |
| **修改** | `TongYou/App/SSHLauncher.swift` | 移除 SSHHistory 依赖，改为回调 |
| **修改** | `TongYou/App/TerminalWindowView.swift` | 统一连接 PaletteHistory，所有 scope 记录 |
| **修改** | `TongYouTests/SSHLauncherTests.swift` | 适配 SSHLauncher 变更 |
| **修改** | `TongYouTests/CommandPaletteControllerTests.swift` | 添加历史相关测试 |

---

## 每阶段独立提交

按现有计划文档的惯例，一个 Phase 一个 commit：

- `feat(history): unified PaletteHistory SQLite storage (Phase 1)`
- `refactor(ssh): remove SSHHistory TSV, migrate SSHLauncher to callbacks (Phase 2)`
- `feat(palette): inject history candidates into CommandPaletteController (Phase 3)`
- `feat(palette): wire all scopes to PaletteHistory in TerminalWindowView (Phase 4)`
- `chore(palette): end-to-end verification + plan docs (Phase 5)`
