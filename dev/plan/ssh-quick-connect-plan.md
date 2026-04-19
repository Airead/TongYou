# TongYou SSH 快速连接 + 命令面板 实施计划

让 TongYou 通过 ⌘P 命令面板快速 fuzzy 搜索并连接 SSH 服务器；支持一次性打开多个
host（默认在当前 tab 里分屏，便于同时操作）；按"环境"自动切换 pane 背景色
（local 默认、dev 暗蓝、prod 暗红），防止误操作生产。

核心理念：**不发明新的 SSH 配置格式**。SSH 参数的真相源仍然是 `~/.ssh/config`，
TongYou 只做"环境分组 + 快速搜索 + 批量打开 + 视觉警示"。一台服务器 = 模板
profile + host 变量；template 选择由 glob 规则基于 hostname 自动完成，无需
逐台登记。

---

## 总体设计

### 核心概念

1. **SSH = profile**。一次连接 = 一个 profile（通常是 `ssh` / `ssh-dev` /
   `ssh-prod`）+ `${HOST}` / `${USER}` 变量。复用现有 `ProfileLoader` /
   `ProfileMerger` / `StartupSnapshot` / 远程 session wire 协议（见
   `pane-profile-remote-plan.md` Phase 7）。

2. **Template 自动选择**。不维护"host → template"清单。写一个 glob 规则文件，
   match 到哪条就用哪条 template，命中不到用 fallback `ssh`。

3. **候选源**。面板 fuzzy 匹配的候选 = `~/.ssh/config` 的 `Host` alias（去掉
   带通配符的）∪ 连接历史。不维护独立 host 清单。

4. **Per-pane 环境上色**。`ssh-prod` 等 profile 在 `extends = ssh` 基础上
   覆盖 `background`。Phase 3 的 live field 热重载已经能让 pane 当场变色，
   无需新渲染代码。

### 文件与路径

| 用途 | 路径 | 由谁管 |
|---|---|---|
| Profile 基础模板 | `~/.config/tongyou/profiles/ssh.txt` | 用户可编辑；首次启动由 `ConfigLoader` 写入默认样例 |
| Dev / prod 覆盖层 | `~/.config/tongyou/profiles/ssh-dev.txt` / `ssh-prod.txt` | 同上 |
| Template 规则 | `~/.config/tongyou/ssh-rules.txt` | 用户编辑；首次启动写入带注释的空模板 |
| 连接历史 | `~/.cache/tongyou/ssh-history.txt` | 运行时维护；用户可随时删除 |
| 候选源（只读） | `~/.ssh/config` | 标准 SSH 配置，TongYou 不写 |

### 交互总览

- **⌘P** 打开命令面板，空输入。前缀分 scope：
  - 无前缀 / `ssh ` — SSH 连接（默认 scope）
  - `>` — 命令模式（枚举所有 `Keybinding.Action`）
  - `p ` — 直接搜 profile
  - `t ` — 跳转已打开 tab
  - `s ` — 搜 session（`⌘R` 的 alias，等价于用 `⌘P` 后敲 `s `）
- **⌘R** 打开命令面板并预填 `s ` 前缀。
- **候选行为**：
  - 输入命中历史 / `~/.ssh/config` alias → fuzzy 列出
  - 输入完全不匹配任何候选 → 显示一条动态 "Connect ad-hoc: <input>" 条目
  - 规则命中的 template 在条目副文本显示：`ssh-prod · background #1a0a0a`
- **多选**：`Tab` 把当前行加入篮子，再输入继续选。
- **回车动作**：
  - `Enter` — **默认**：如果篮子里 1 项 → 新 tab；多项 → **当前 tab 里依次分屏**
  - `⌘Enter` — 右 split（多项时全部右 split 到当前 pane）
  - `⇧Enter` — 下 split
  - `⌥Enter` — float pane

### 客户端 / 服务端分工

所有 profile 解析、规则匹配、变量展开都在 **client** 进行。wire 上走的仍然是
已有的 `profileID` + `StartupSnapshot`（Phase 7.2 已落地）。daemon 零改动。

---

## Phase 分解

每个 Phase 一次 commit，严格独立编译、独立测试。

---

## Phase 1：profile variables 机制

### 目标

`ProfileMerger.resolve(profileID:, overrides:, variables:)` 新增 `variables`
参数。解析完 extends 链、叠完 overrides 之后，对所有 scalar / list item /
env value 做 `${NAME}` 字符串替换。

### 涉及文件

- `Packages/TongYouCore/Sources/TYConfig/ProfileMerger.swift`
- `Packages/TongYouCore/Sources/TYConfig/StartupSnapshot.swift`（`ResolvedLiveFields`
  也要 walk）
- `Packages/TongYouCore/Tests/TYConfigTests/ProfileMergerTests.swift`

### 实现要点

1. **展开时机**：merge 完成后、返回 `ResolvedProfile` 之前做替换。保证
   overrides 里的值也会被展开（`--set args=${HOST}` 合法）。
2. **占位符语法**：只做 `${NAME}`。`NAME` 限定 `[A-Za-z_][A-Za-z0-9_]*`。
3. **未定义变量**：返回 `ProfileResolveError.undefinedVariable(name)`，不静默留
   原串（避免 SSH 到字面 `${HOST}` 这种灾难性行为）。
4. **转义**：`$$` 展开为字面 `$`。其他 `$` 开头但不合法的保持原样（如 `$5`）。
5. **大小写敏感**。`${host}` ≠ `${HOST}`。

### 测试

- `variablesExpandInScalars` — `command = /usr/bin/${TOOL}` + `TOOL=ssh`
- `variablesExpandInListItems` — `args = ${USER}@${HOST}`
- `variablesExpandInEnvValues` — `env = HOSTNAME=${HOST}`
- `undefinedVariableThrows` — 未定义变量抛错
- `dollarEscape` — `$$` → `$`
- `extendsChainVariables` — 子 profile 引用的变量和父 profile 引用的都展开
- `overrideCanReferenceVariable` — `overrides = args=${HOST}` 也展开

### 完成标准

- API 新签名上线，现有调用方（传 `variables: [:]`）行为不变。
- 单测全绿。

---

## Phase 2：ssh-rules.txt 加载器 + glob 匹配

### 目标

定义规则文件格式；加载并在 client 侧提供 `SSHRuleMatcher.match(hostname:) -> String?`
返回 template profileID。

### 文件格式（类 /etc/hosts 风格）

```
# ~/.config/tongyou/ssh-rules.txt
#
# Format: <template>  <glob> [<glob> ...]
# 第一条命中生效。glob 以空格分隔，支持 * 和 ?。
# 没有任何规则命中时，面板 fallback 到 "ssh" 模板。

ssh-prod    *.prod.example.com  *-prod-*  db*.internal
ssh-dev     *.dev.example.com   *.staging.*
```

- 空行、`#` 注释忽略。
- 一行一条规则，首 token = template profileID，后续 token 全部是 glob。
- glob 使用 POSIX `fnmatch`（`*` / `?` / `[abc]`），**不做 regex**。
- 文件不存在或空 → matcher 对任意 hostname 都返回 `nil`（fallback 由调用方决定）。

### 涉及文件

- 新增 `Packages/TongYouCore/Sources/TYConfig/SSHRules.swift`（`SSHRule`、
  `SSHRuleMatcher`、parser）
- `Packages/TongYouCore/Sources/TYConfig/ProfileLoader.swift`（如果和 profile
  文件同目录共享解析 helper）
- `Packages/TongYouCore/Tests/TYConfigTests/SSHRulesTests.swift`

### 实现要点

1. **解析**：纯文本 parser，不依赖 `ConfigParser`（规则不是 key=value 语法）。
   行首/行尾空白剥离，`#` 后到行尾为注释。token 用空白分隔。
2. **匹配**：外层 for over rules，内层 for over globs，任一 glob 命中即返
   `rule.template`。
3. **Glob 实现**：用 `fnmatch(3)`（Darwin 标准库提供）或 Swift 内手写一个简单
   `*`/`?` 匹配器。手写 30 行以内，不引入依赖。
4. **大小写**：hostname 大小写不敏感匹配（`Db1.Prod.Example.com` 匹配
   `*.prod.example.com`）。
5. **规则优先级**：**文件顺序即优先级**。不做"更具体的 glob 优先"这种魔法，
   用户自己排序。
6. **错误宽容**：单行解析失败（tokens 不够、template 名为空）→ 跳过 + warning
   附加到返回的 warnings 数组，不让一行错误废掉整个文件。

### 测试

- `matchFirstRuleWins` — 前两条都能匹配，取第一条的 template
- `matchGlobStar` — `*.prod.example.com` 匹配 `db1.prod.example.com`
- `matchGlobMultiple` — 同一规则有多个 glob，任一命中即可
- `matchCaseInsensitive`
- `noMatchReturnsNil`
- `emptyFileReturnsNil`
- `commentAndBlankLinesIgnored`
- `malformedLineSkippedWithWarning`

### 完成标准

- Matcher API 可用；规则文件存在时正确命中；不存在时返回 nil 且不报错。
- 单测全绿。

---

## Phase 3：~/.ssh/config 读取器（候选源之一）

### 目标

解析 `~/.ssh/config`，枚举顶层 `Host` 条目作为候选列表。**仅作为 UI 的 fuzzy
候选源，不影响 ssh 进程行为**（连接时 ssh 二进制自己再读一次 ssh_config）。

### 涉及文件

- 新增 `Packages/TongYouCore/Sources/TYConfig/SSHConfigHosts.swift`
- `Packages/TongYouCore/Tests/TYConfigTests/SSHConfigHostsTests.swift`

### 实现要点

1. **解析范围（MVP 极小子集）**：
   - 只识别 `Host` 和 `Hostname` 两个关键字，大小写不敏感
   - 一个 `Host` 行支持多个 alias（`Host db01 db01.corp`），全部展开为候选
   - **带通配符的 Host 行跳过**（`Host *`, `Host *.internal`）——它们是规则，
     不是具体机器
   - 忽略 `Match`、`Include`、任何其他关键字
2. **数据结构**：
   ```swift
   struct SSHConfigHost {
       let alias: String        // panel 里显示/搜索的主 key
       let hostname: String?    // 如果 ssh_config 里写了 Hostname，拿来跑规则
   }
   ```
3. **文件不存在**：返回空数组，不报错。
4. **刷新时机**：启动时加载一次 + 面板打开时检查文件 mtime，变了才重读
   （避免每次敲键重读）。
5. **路径**：用 `FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")`。

### 测试

- `parseSimpleHost` — 一个 Host db01 → 一条记录，hostname nil
- `parseHostWithHostname` — Host db01 + Hostname db1.internal → alias=db01, hostname=db1.internal
- `parseMultipleAliasesOnOneLine` — Host db01 db01-b → 两条记录
- `wildcardHostSkipped`
- `caseInsensitiveKeywords`
- `missingFileReturnsEmpty`
- `commentsAndBlanksIgnored`
- `unknownKeywordsIgnored`（IdentityFile/Port/Match 全忽略，不报错）

### 完成标准

- 能从真实 `~/.ssh/config` 枚举出至少 `Host` 列表；alias / hostname 正确。
- 单测全绿。

---

## Phase 4：连接历史存储

### 目标

记录最近 N 条 SSH 连接（target host + template + 时间戳），面板打开时作为
默认候选。

### 涉及文件

- 新增 `TongYou/Config/SSHHistory.swift`（GUI 侧；actor 或 MainActor class）
- `TongYouTests/SSHHistoryTests.swift`

### 实现要点

1. **路径**：`~/.cache/tongyou/ssh-history.txt`。父目录不存在时创建。
2. **格式**：每行 `<timestamp-iso8601>\t<template>\t<target>`，追加写入。
   `target` 是用户实际输入的串（可能带 `user@`）。
3. **上限**：500 条。写入时超限就把最旧 100 条批量截掉（摊销 I/O）。
4. **排序**：面板默认按 **最近使用** 降序，再按 **频率** 降序（2 层 key）。
5. **去重**：相同 `target` 只保留一条记录（最新的那条）。`target` 比较大小
   写敏感（SSH alias 可能有大小写差异，不擅自合并）。
6. **删除**：提供 `clearAll()` 方法；用户也可以直接删文件。启动时缺失 → 从
   空开始。
7. **并发**：用 `actor` 隔离，I/O 走 `@concurrent`（遵循 CLAUDE.md 的并发
   约定）。

### 测试

- **用临时目录隔离**，禁止触碰真实 `~/.cache`（见 CLAUDE.md 测试隔离规则）。
  构造函数接受 `directoryURL: URL` 依赖注入。
- `appendRecordsWritten`
- `sortByRecencyThenFrequency`
- `deduplicationKeepsLatest`
- `capAtLimitDropsOldest`
- `clearAllWipesFile`
- `missingFileStartsEmpty`
- `malformedLineSkipped`

### 完成标准

- API 完整；独立测试全绿；不触碰用户真实缓存。

---

## Phase 5：命令面板 UI 骨架

### 目标

做一个可开可关的浮层 UI：输入框 + 候选列表 + 键盘导航。暂不接任何 scope
数据源——Phase 6–8 往里填。

### 涉及文件

- 新增 `TongYou/App/CommandPaletteView.swift`（SwiftUI）
- 新增 `TongYou/App/CommandPaletteController.swift`（`@Observable`，承载
  state、fuzzy 引擎、scope 路由）
- 新增 `TongYou/App/FuzzyMatcher.swift`（子序列 + 间距惩罚，带 highlight）
- `TongYou/App/TerminalWindowView.swift`（挂载 overlay）
- `TongYou/Config/Keybinding.swift`（新增 action case
  `showCommandPalette` / `showSessionPalette`）
- `TongYou/Config/SystemConfig.txt`（默认绑定：`⌘P` → show-command-palette，
  `⌘R` → show-session-palette；文件头部 action 列表同步更新，**按 CLAUDE.md
  Keybindings 章节的要求**）
- `TongYouTests/FuzzyMatcherTests.swift`
- `TongYouTests/CommandPaletteControllerTests.swift`

### 实现要点

1. **渲染**：SwiftUI `ZStack` overlay on TerminalWindowView。顶部中央 600pt 宽
   面板，半透明背景 + blur。输入框 + 候选列表（最多显示 8 行）。ESC 关闭；
   面板外点击也关闭。
2. **Fuzzy 引擎**：VSCode / fzf 风格子序列匹配，记录命中位置用于 highlight。
   输入为空时跳过过滤，按候选自然顺序列出。
3. **Scope 路由**：controller 暴露 `scope: PaletteScope` enum：
   ```swift
   enum PaletteScope { case ssh, command, profile, tab, session }
   ```
   从输入前缀派生：`> ` → command, `p ` → profile, `t ` → tab, `s ` → session,
   其他/空 → ssh。改变 scope 时清空选择高亮，不清空输入。
4. **候选渲染**：每行 = 主文本（带 highlight）+ 副文本（右对齐，灰色）。副
   文本由 scope 决定内容（SSH scope 里显示命中的 template / background 色
   样本）。
5. **键盘**：
   - `↑`/`↓`/`⌃P`/`⌃N` 移动高亮
   - `Enter` / `⌘Enter` / `⇧Enter` / `⌥Enter` 触发动作（具体动作 Phase 7 接）
   - `Tab` 多选切换（Phase 7 实现行为；Phase 5 只占位）
   - `ESC` 关闭
6. **SwiftUI identity**（重要，遵循 CLAUDE.md 规则）：候选行 `ForEach` 用
   稳定 ID（候选自己的 `id` 字段），**绝不**用数组下标。
7. **⌘R**：按下后打开面板并预填 `s `，光标放在 `s ` 之后。

### 测试

- `fuzzyMatcherScoresRelevance` — "dbp" match "db-prod-1" vs "dashboard"，
  前者得分高
- `fuzzyMatcherReturnsHighlightRanges`
- `fuzzyMatcherEmptyQueryReturnsAll`
- `paletteScopeFromPrefix` — 各前缀映射正确
- `paletteScopeRemovesPrefixForFuzzy` — scope 解析出来后，fuzzy 只匹配去除
  前缀后的尾串
- `paletteClosesOnEscape`

### 完成标准

- ⌘P / ⌘R 能打开面板，输入前缀能切 scope，候选列表可上下移动。
- 尚无真实数据，但 UI 框架齐备。
- 单测全绿；SwiftUI preview 跑得起来。

---

## Phase 6：SSH scope 接通数据源

### 目标

把 Phase 2（规则）、Phase 3（ssh_config）、Phase 4（历史）接到 Phase 5 的
面板上。敲字能看到候选，回车能真实 spawn。

### 涉及文件

- `TongYou/App/CommandPaletteController.swift`
- 新增 `TongYou/App/SSHLauncher.swift`（封装 "target string → profile +
  variables → StartupSnapshot → spawn"）
- `TongYou/App/SessionManager.swift`（提供 `spawnWithProfile(profileID:, variables:, placement:)`
  入口；内部复用 `createTab` / `splitPane` / `createFloatingPane`）

### 实现要点

1. **候选合并**：
   ```swift
   candidates = (
       history.recent(limit: 50) +
       sshConfigHosts.map { $0.alias }
   ).uniqued()          // 保序去重，history 在前
   ```
2. **Ad-hoc 兜底条目**：当 `fuzzy(query, candidates)` 返回空、且 `query` 非空，
   额外拼一条 `.adHoc(query)` 放到候选列表首位。
3. **Target parse**：`parseTarget("foo@bar.prod.example.com")` →
   `(user: "foo", host: "bar.prod.example.com")`。没 `@` 时 user = nil（profile
   里 `${USER}` 未定义时报错的行为见 Phase 1）。
4. **Template 选择**：
   - 对候选项：同时拿 alias 和 ssh_config 的 `Hostname`（若有）跑规则，任一
     命中即用该 template；都没命中用 fallback `ssh`。
   - 对 ad-hoc：只跑一次规则（输入里的 host 部分）。
5. **副文本**：`ssh-prod · ■ #1a0a0a`（色块用 SwiftUI `Rectangle().fill`
   占 12pt）。让用户在回车前就看到"这会变红"。
6. **Spawn 入口**：
   ```swift
   // SessionManager
   enum Placement { case newTab, splitRight, splitBelow, floatPane, currentTab }
   func spawnWithProfile(
       profileID: String,
       variables: [String: String],
       placement: Placement
   ) throws
   ```
   - `.newTab` / `.splitRight(paneID)` / `.splitBelow(paneID)` / `.floatPane` 对应
     wire 操作
   - `.currentTab` 在 Phase 7 用于多选展开
   - 内部：`ProfileMerger.resolve(profileID:, variables:)` → `StartupSnapshot`
     → 调已有 create API
   - 错误：`PROFILE_NOT_FOUND` / `UNDEFINED_VARIABLE` / `INVALID_PROFILE` 都
     以 `throws` 抛到面板，面板用红色 toast 显示，不关闭面板
7. **历史写入**：spawn 成功后 append 一条历史记录。ad-hoc 和命中都写。
8. **⌘P 回车默认动作（单选）**：新 tab（符合用户偏好）。

### 测试

- `candidatesMergeHistoryBeforeSshConfig`
- `adHocEntryAppearsWhenNoMatch`
- `parseTargetWithUserAtHost` / `parseTargetWithoutUser`
- `ruleHitsTemplateForAlias` / `ruleHitsTemplateForHostname`
- `spawnResolvesProfileWithVariables` — mock manager, 验证最终 snapshot 里
  `args` 带展开后的 hostname
- `spawnUndefinedVariableShowsError`
- `historyAppendedOnSuccess`
- `historyNotAppendedOnFailure`

### 完成标准

- ⌘P 空查询看到历史 / ssh_config 候选。
- 输入 fuzzy 过滤。
- 没命中时有 ad-hoc 条目。
- 回车在当前 session 开新 tab 成功 SSH。
- SSH 成功后 pane 底色按 template 变色（已有机制，仅需验证）。

---

## Phase 7：多选 + 批量 spawn + split 快捷键

### 目标

实现 `Tab` 多选、回车变体（`⌘Enter` / `⇧Enter` / `⌥Enter`），以及"多选时默认
在当前 tab 分屏"的行为。

### 涉及文件

- `TongYou/App/CommandPaletteController.swift`
- `TongYou/App/SessionManager.swift`（批量 spawn 辅助）

### 实现要点

1. **多选状态**：`controller.selection: OrderedSet<CandidateID>`。`Tab` 切换
   当前高亮项的 in/out。面板底部显示 `3 selected` 的 chip。
2. **回车决策树（单选 vs 多选）**：
   ```
             Enter          ⌘Enter         ⇧Enter        ⌥Enter
   单选      newTab         splitRight     splitBelow    floatPane
                            (on current)   (on current)
   多选      currentTab     splitRight ×N  splitBelow×N  floatPane×N
            (依次分屏)
   ```
   `currentTab` 行为：第一项在当前 tab 第一个"可分"的 pane 上右 split；之后
   每一项在上一个新开 pane 上再次右 split（形成纵列）。最后一项 focus。
3. **交替分屏方向**：多选 `currentTab` 时是否纵列还是棋盘式？**MVP 就纵列**。
   以后要 auto-layout 可以叠在 auto-layout Phase 5 上。
4. **错误中断策略**：批量 spawn 里某一项失败 → 停在失败项，面板弹 toast 显示
   `2/5 opened, "foo.bar": UNDEFINED_VARIABLE`。已开的不回滚。
5. **焦点**：批量打开完成后，焦点切到**最后一个成功开的 pane**。
6. **Keybinding**：`split-pane-with-profile` action **不在本阶段加**（面板本
   身已提供替代路径："选中当前 pane → ⌘P → 选 profile → ⌘Enter"）。

### 测试

- `tabTogglesSelection`
- `selectionRemovesOnSecondTab`
- `enterWithMultiSelectionUsesCurrentTab`
- `cmdEnterWithMultiSelectionSplitsRight`
- `batchSpawnStopsOnFirstFailure`
- `focusGoesToLastPane`

### 完成标准

- 多选 UX 可用；四种回车变体行为正确；错误有可见反馈。

---

## Phase 8：Session scope（⌘R 预填 + `s ` 前缀）

### 目标

按 session 名字 fuzzy 搜索已打开 session；回车激活该 session 并聚焦。

### 涉及文件

- `TongYou/App/CommandPaletteController.swift`（新增 `sessionScopeCandidates()`）
- 不需要改 `SessionManager`，读 `sessions` 只读属性即可

### 实现要点

1. **候选**：`sessions.map { (id: $0.id, title: $0.displayName, subtitle: ...) }`
2. **副文本**：`local` / `remote (tyd)` / tab count，方便区分
3. **回车**：`manager.activateSession(id:)` + 关闭面板
4. **⌘Enter**：无效（session 没有 split 语义）；⇧Enter / ⌥Enter 同理 no-op
   + toast 提示 "not applicable in session scope"。
5. **⌘R**：`showSessionPalette` action 打开面板，controller 预填 `s `，cursor
   在 `s ` 之后，保持 SSH scope 逻辑不变（只是初始 scope 不同）。

### 测试

- `sessionScopeListsAllOpenSessions`
- `sessionFuzzyMatchByDisplayName`
- `cmdREntersSessionScopeWithPrefix`
- `nonApplicableModifiersAreNoOp`

### 完成标准

- ⌘R 打开并预填；按 session 名字能找到；回车切换成功。

---

## Phase 9：默认模板 profile + 示例 ssh-rules.txt

### 目标

首次启动（或配置目录缺失时）由 `ConfigLoader` 把默认模板写入用户目录，
保证开箱即用。

### 涉及文件

- `TongYou/Config/SystemConfig.txt`（已存在；更新 action 列表注释）
- 新增 bundle 资源 `TongYou/Config/Profiles/ssh.txt` / `ssh-dev.txt` /
  `ssh-prod.txt`
- 新增 bundle 资源 `TongYou/Config/ssh-rules.txt`（带注释的空模板）
- `TongYou/Config/ConfigLoader.swift`：扩展
  `writeSystemConfig()` 或新增 `seedDefaultProfiles()`，
  **仅在文件不存在时**写入（不像 system_config.txt 那样每次覆盖）

### 默认内容

`profiles/ssh.txt`：
```
# SSH base template.
# Variables available: ${HOST}, ${USER} (optional).
command = /usr/bin/ssh
args = -t
args = ${HOST}
close-on-exit = false
description = SSH to ${HOST}
```

`profiles/ssh-dev.txt`：
```
extends = ssh
background = 0a1a2e
description = SSH dev: ${HOST}
```

`profiles/ssh-prod.txt`：
```
extends = ssh
background = 1a0a0a
description = SSH prod: ${HOST}
```

`ssh-rules.txt`（注释为主，无生效规则）：
```
# TongYou SSH template rules.
#
# Format: <template>  <glob> [<glob> ...]
# First matching rule wins. Unmatched hostnames fall back to the
# "ssh" template.
#
# Example:
# ssh-prod    *.prod.example.com   *-prod-*
# ssh-dev     *.dev.example.com    *.staging.*
```

### 实现要点

1. **只种子一次**：检测文件存在即不覆盖，避免用户改了之后启动又被还原。
2. **测试**：`ConfigLoaderTests` 增加
   - `seedsDefaultsWhenMissing`
   - `doesNotOverwriteExistingFiles`
   - 测试用临时目录注入，不触碰 `~/.config`（CLAUDE.md 规则）

### 完成标准

- 新装用户首次启动后 `~/.config/tongyou/profiles/` 下有 3 个 ssh*.txt，
  `~/.config/tongyou/ssh-rules.txt` 存在。
- 已有用户升级：这些文件不被覆盖（即便存在 stale 版本）。
- 单测全绿。

---

## Phase 10：端到端手工验证 + 文档

### 人工验证脚本

```bash
# 1. 删掉历史,保证空状态
rm -f ~/.cache/tongyou/ssh-history.txt

# 2. 冷启动 GUI
open -a TongYou.app

# 3. ⌘P → 应看到 ~/.ssh/config 里的所有 Host alias
# 4. 敲部分字符 → fuzzy 过滤正确
# 5. 回车 → 新 tab 开 ssh, 底色默认

# 6. ⌘P → 敲一个 prod 机器 → 副文本显示 "ssh-prod · #1a0a0a"
# 7. 回车 → 新 tab 开 ssh, 底色变红

# 8. 在上面的 prod tab 里 ⌘D 默认 split → 新 pane 仍然走 prod template + 红底
#    (走的是"继承父 pane snapshot"路径, 现有行为, Phase 7 远程计划已覆盖)

# 9. ⌘P → 敲 2 个 host → Tab + Tab + Enter → 当前 tab 里依次分屏开 2 个 ssh

# 10. ⌘P → 敲任意字符串 → 不匹配任何候选 → 应看到 "Connect ad-hoc: ..."
#     回车 → ssh 过去 (hostname 跑规则, 命中对应 template)

# 11. ⌘R → 面板打开, 输入框里是 "s "
# 12. 敲 session 名 → 定位, 回车 → 激活

# 13. 退出前再开一次 ⌘P → 历史记录在最上面

# 14. rm ~/.cache/tongyou/ssh-history.txt → 重启 → 历史清空但 ssh_config 候选仍在
```

### 完成标准

- 以上 14 步全通过
- `make build` 绿
- `xcodebuild test -only-testing:TongYouTests` + `cd Packages/TongYouCore && swift test` 全绿
- 无并发 build / test（遵循 CLAUDE.md 规则）

---

## 已完成本计划后可以做但暂不列入

- **`~/.ssh/config` 自动导入作为虚拟 profile**：当前只把 Host alias 当 fuzzy
  候选，template 通过规则选。如果想让每台机器"就是一个 profile"从而可以
  `--profile db01` CLI 用，得合成虚拟 profile。等有人需求再做。
- **Tag 过滤**：规则行带 tag 列、hosts.txt 式 tag、或从 ssh_config 注释里
  提取 tag。先靠 hostname pattern 代替。
- **`tongyou ssh resolve <host>`** CLI 调试工具：规则命中预览、展开后的 snapshot
  预览。规则多起来再加。
- **边框高亮**：prod pane 边框更醒目（除了底色）。需要 render 层读新的 live
  field `border-color`。
- **Per-tab 统一色**：当前是 per-pane。如果要改成"整 tab 取第一 pane 色"，
  需 tab bar 读取并上色。

---

## 每阶段独立提交

按现有计划文档的惯例，一个 sub-phase 一个 commit：

- `feat(profile): expand ${NAME} variables in resolved profiles (Phase 1)`
- `feat(ssh): glob-based template rule matcher (Phase 2)`
- `feat(ssh): read ~/.ssh/config Host aliases as fuzzy source (Phase 3)`
- `feat(ssh): persisted connection history under XDG cache (Phase 4)`
- `feat(palette): command palette shell with scope prefixes (Phase 5)`
- `feat(palette): wire ssh scope to rules + history + ssh_config (Phase 6)`
- `feat(palette): multi-select and split variants on Enter (Phase 7)`
- `feat(palette): session scope via ⌘R prefix (Phase 8)`
- `feat(ssh): seed default templates and rules on first launch (Phase 9)`
- `chore(ssh): end-to-end verification + plan docs (Phase 10)`
