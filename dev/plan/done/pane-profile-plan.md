# TongYou Pane Profile 分阶段实施计划

为每个 pane 引入 "profile" 概念，让不同 pane 可以按命名配置集启动和渲染。本文档按**可独立实现、可人工验证**的粒度拆分阶段，便于逐步推进。

---

## 总体设计

### 1. Profile 是什么

Profile 是一组命名的配置集合，涵盖 pane 的**启动参数**（命令、cwd、env 等）和**外观行为**（主题、字体、调色板等）。创建 pane 时可指定 `profileID`，未指定则继承父 pane（split 场景）或使用 `default`（新建 tab/session 场景）。

### 2. 字段分两层（生效时机不同）

- **Startup 字段（创建时快照）**：`command / args / cwd / env / close-on-exit / initial-x / initial-y / initial-width / initial-height`。创建 pane 时读取一次，之后修改 profile 文件**不影响**已存在 pane。
- **Live 字段（运行时热重载）**：`theme / font-family / font-size / palette-N / cursor-* / scrollback-limit / option-as-alt / tab-width / bell / background / foreground / ...`。pane 通过 `profileID` 实时从 `ProfileLoader` 查，profile 文件改了所有引用该 profile 的 pane 立即生效。

### 3. 文件格式

- 扩展名 `.txt`，路径 `~/.config/tongyou/profiles/<id>.txt`
- **复用现有 `ConfigParser`**，不引入新语法
- 顶层关键字 `extends = <profile-id>` 声明继承，单链，DFS 检测循环，内建 `default` 不可删
- palette 沿用现有 `palette-0 = ...` 扁平风格
- env 用重复 key：`env = KEY=VALUE`（每行一条）
- list 字段（`args`）用重复 key 累积成数组

示例：

```ini
# ~/.config/tongyou/profiles/prod-ssh.txt
extends = default

# Startup
command = ssh
args = -p
args = 2222
args = deploy@prod-01
cwd = ~
close-on-exit = false
env = LANG=en_US.UTF-8
env = DEBUG=1

# Live
theme = iterm2-dark-background
font-size = 14
palette-0 = 1d1f21
palette-1 = cc6666
```

### 4. 合并规则（跨层，从低到高）

合并优先级：内建默认 → `SystemConfig.txt`/`user_config.txt` → `extends` 链（根→叶）→ profile 自身 → 调用点 overrides。

按字段类型处理：

| 类型 | 举例 | 跨层规则 |
|---|---|---|
| 标量 | `theme`, `font-size`, `command`, `cwd`, `close-on-exit` | 下层整体替换上层 |
| list | `args` | 下层整体替换上层 |
| map | `env`, `palette-*` 整体视为一张表 | 按子 key 浅合并，下层子 key 覆盖上层同名 |

**显式清零**：写空值行 `env =` 或 `args =`，清空从继承链带下来的那份，再继续累加。标量 `key =` 重置为内建默认（延用 `ConfigParser` 已有语义）。

**同层内**重复 key 累积成 list/map。

### 5. 自动化 overrides 传输格式

JSON-RPC payload 的 `overrides` 字段类型是 `[String]`，每个元素是一行合法的 `key = value`：

```json
{
  "cmd": "pane.split",
  "paneRef": "s1",
  "direction": "horizontal",
  "focus": true,
  "profile": "prod-ssh",
  "overrides": [
    "font-size = 16",
    "palette-0 = ffffff",
    "args = deploy@staging-02",
    "env = HTTP_PROXY=http://x"
  ]
}
```

服务端把数组 `join("\n")` 喂给 `ConfigParser`，得到 `[Entry]`，按同一套合并规则叠加。**profile 文件 / CLI `--set` / JSON overrides / 系统 config 全走同一个 parser 同一套语义**。

### 6. CLI 新增 flag

在所有创建 pane 的 CLI 命令（`tongyou app new-tab / split / float-pane create`）增加：

- `--profile <name>`：指定 profile，未传则继承父 pane 或用 default
- `--set key=value`：可重复，每次一条 override，CLI 原样拼成 `"key = value"` 塞进 JSON `overrides` 数组，不在 CLI 侧做类型推断

示例：

```bash
tongyou app split s1 --horizontal --focus \
  --profile prod-ssh \
  --set font-size=16 \
  --set palette-0=ffffff \
  --set args=deploy@staging-02 \
  --set env=HTTP_PROXY=http://x
```

### 7. 运行期不允许切换 pane 的 profile

`TerminalPane` 一旦创建，`profileID` 不可变。Startup 字段已落地成快照，后续无法回溯；Live 字段通过 profile 文件热重载已能满足外观调整需求。不新增 `pane.setProfile` 命令。

### 8. SSH 继承（方案 A）

不做运行时探测。用户在 profile 里显式声明 `command = ssh / args = user@host`，split 时继承父 pane 的 `profileID` 即自动重新 ssh。更精细的场景（带 remote cwd 等）由用户写脚本通过 `--set` 传入。

---

## Phase 1：Profile 基础设施与合并引擎

### 目标
建立 profile 的数据模型、加载器和合并算法，能从磁盘读取 profile 文件、解析 `extends` 链、执行三类字段的合并，并有单元测试保障合并语义。此阶段不与任何 pane 实际打通，纯库代码 + 测试。

### 涉及文件
- `Packages/TongYouCore/Sources/TYConfig/Profile.swift`（新建）— `Profile` struct、字段定义、分层标签
- `Packages/TongYouCore/Sources/TYConfig/ProfileLoader.swift`（新建）— 目录扫描、文件解析、`extends` 解析、循环检测
- `Packages/TongYouCore/Sources/TYConfig/ProfileMerger.swift`（新建）— 合并算法（标量/list/map 三类、空值清零语义）
- `Packages/TongYouCore/Sources/TYConfig/ConfigParser.swift`（复用，不改）
- `Packages/TongYouCore/Tests/TYConfigTests/ProfileLoaderTests.swift`（新建）
- `Packages/TongYouCore/Tests/TYConfigTests/ProfileMergerTests.swift`（新建）

### 实现要点
1. `Profile` 使用两个嵌套 struct：`StartupFields`（快照用）和 `LiveFields`（渲染用），避免字段语义混淆。
2. `ProfileLoader`：
   - 内建 `default` profile 用代码里的硬编码默认值构造，不需要实体文件；用户新建 `profiles/default.txt` 时覆盖相应 key。
   - 扫描 `~/.config/tongyou/profiles/*.txt`，每个文件解析成 `[ConfigParser.Entry]` 后构造一个 `RawProfile`（含 `extends`、原始 entries）。
   - 解析某 profile 时沿 `extends` 链 DFS，遇到重复 id 报错（循环）；深度上限 10。
3. `ProfileMerger.resolve(profileID) -> ResolvedProfile`：
   - 按根→叶顺序依次 apply 每层 entries。
   - 遇到空值行 `key =`：若 key 是 list/map 类型，清空该字段的继承部分；若是标量，重置为内建默认。
   - 标量：下层直接覆盖。
   - list：同层重复 key 累积；跨层下层整体替换上层。
   - map：同层重复 key 按子 key 累积；跨层按子 key 浅合并。
4. 合并入口额外接受一个 `[String]` 参数代表调用点 overrides，join `"\n"` 后 parse 成 entries，作为最高优先层参与合并。
5. 字段白名单与类型映射集中写在 `Profile.swift` 里一张表（key → 类型枚举 scalar/list/map），`ProfileMerger` 读这张表分发处理，未知 key 记录警告并忽略。

### 人工验证步骤
```bash
# 1. 创建测试 profile
mkdir -p ~/.config/tongyou/profiles
cat > ~/.config/tongyou/profiles/base.txt <<'EOF'
env = LANG=en_US.UTF-8
env = PATH=/usr/bin:/bin
palette-0 = 000000
palette-1 = cd3131
font-size = 14
EOF

cat > ~/.config/tongyou/profiles/prod-ssh.txt <<'EOF'
extends = base
command = ssh
args = deploy@prod-01
env = DEBUG=1
palette-0 = 1d1f21
font-size = 16
EOF

# 2. 跑单元测试，覆盖以下场景
cd Packages/TongYouCore && swift test --filter ProfileLoaderTests --filter ProfileMergerTests
# 期望：全部通过

# 3. 手工场景（用一个临时 debug 子命令或 XCTest 打印）
#    验证 resolve("prod-ssh") 的输出：
#    - env: { LANG, PATH, DEBUG } 三条全在
#    - palette-0 = 1d1f21（覆盖），palette-1 = cd3131（保留）
#    - font-size = 16（覆盖）
#    - command = ssh, args = [deploy@prod-01]

# 4. 循环引用检测
cat > ~/.config/tongyou/profiles/a.txt <<'EOF'
extends = b
EOF
cat > ~/.config/tongyou/profiles/b.txt <<'EOF'
extends = a
EOF
# 期望：resolve("a") 报循环错误，不崩溃

# 5. 显式清零
cat > ~/.config/tongyou/profiles/fresh.txt <<'EOF'
extends = base
env =
env = ONLY=this
EOF
# 期望：resolve("fresh") 的 env 只有 ONLY=this，LANG/PATH 被清空

# 6. overrides 参与合并
# 单测里调 merger.resolve("prod-ssh", overrides: ["font-size = 20", "env = EXTRA=1"])
# 期望：font-size = 20，env 包含 LANG/PATH/DEBUG/EXTRA
```

### 完成标准
- `ProfileLoader` 能从目录加载 profile，未找到指定 id 时报明确错误。
- `ProfileMerger` 对三类字段（标量/list/map）的跨层合并、同层累积、空值清零语义全部正确，单测覆盖。
- 循环继承被检测并报错，深度超限被截断。
- 未知 key 不影响已知 key 的解析。

---

## Phase 2：Pane 启动走 Profile（Startup 字段）

### 目标
让新创建的 pane 按 profile 的 Startup 字段启动（命令、参数、cwd、env、close-on-exit），此阶段先不处理 Live 字段的热重载——渲染仍沿用全局 `Config`。只跑通"指定 profile 能改变 pane 启动命令和环境"。

### 涉及文件
- `Packages/TongYouCore/Sources/TYTerminal/TerminalPane.swift` — 新增 `profileID: String`、`startupSnapshot: StartupSnapshot`
- `Packages/TongYouCore/Sources/TYTerminal/StartupSnapshot.swift`（新建）— profile Startup 字段解析后的具体快照
- `TongYou/App/SessionManager.swift` — `splitPane`、`createFloatingPane`、新建 tab 时查 profile、填充 snapshot
- `TongYou/App/TabManager.swift` — `createTab` 同理
- `Packages/TongYouCore/Sources/TYServer/ServerSessionManager.swift` — `createAndStartPane` 按 snapshot 启动 PTY
- `TongYou/App/SessionManager.swift` 里 `ensureLocalController` — 本地 controller 启动命令用 snapshot

### 实现要点
1. `TerminalPane` 改动保持向后兼容：`profileID` 默认 `"default"`，`startupSnapshot` 在创建时必填（从 `ProfileMerger` 解析得到）。
2. pane 创建的**唯一入口**是 `SessionManager.createPane(profileID:overrides:)`，内部完成 profile resolve + snapshot 构造 + Pane 实例化，现有 `splitPane` / `createFloatingPane` / `createTab` 都改为走这个入口。
3. PTY 启动逻辑（本地 `TerminalController.start`、服务端 `createAndStartPane`）从 `startupSnapshot` 读 command/args/cwd/env/close-on-exit，不再散落读取全局默认。
4. 如果 snapshot 的 `command` 为空，fallback 到 user 默认 shell（`$SHELL` 或 `/bin/zsh`），保留现有行为。
5. 此阶段暂不让调用方传 profileID，先把内部管道打通：全部 pane 都按 `default` profile 创建，仍然复用旧行为；再加一个**临时硬编码测试开关**（例如 env var `TY_TEST_PROFILE=prod-ssh`）让 `SessionManager.createPane` 在开关存在时强制用该 profile。这样无需等 Phase 5 就能验证 Startup 字段生效。

### 人工验证步骤
```bash
# 1. 正常启动，验证不回退
#    （没有 TY_TEST_PROFILE 时所有 pane 行为和原来一致）
make run
# 期望：打开 pane、split、new tab 都能正常工作，命令为默认 shell

# 2. 准备 ssh profile
cat > ~/.config/tongyou/profiles/test-ssh.txt <<'EOF'
extends = default
command = /bin/bash
args = -c
args = echo "hello from profile" && sleep 999
env = TY_PROFILE_MARKER=test-ssh
EOF

# 3. 设置测试开关后启动
TY_TEST_PROFILE=test-ssh make run
# 期望：新建 pane 立即打印 "hello from profile"，sleep 保持 pane 不关闭

# 4. 验证 env 生效
#    在另一个 pane 或 debugger 里观察 PTY 子进程环境变量
#    期望：TY_PROFILE_MARKER=test-ssh 存在，LANG/PATH 等继承自 default 也存在

# 5. close-on-exit 生效
cat > ~/.config/tongyou/profiles/quick-exit.txt <<'EOF'
extends = default
command = /bin/echo
args = done
close-on-exit = true
EOF
TY_TEST_PROFILE=quick-exit make run
# 期望：新 pane 打印 done 后自动关闭

# 6. 未知 profile id
TY_TEST_PROFILE=nonexistent make run
# 期望：启动时报错或 fallback 到 default 并日志告警（二选一，方案里定）

# 7. 还原：清理 TY_TEST_PROFILE 后 split/new-tab 不受影响
```

### 完成标准
- `SessionManager.createPane(profileID:overrides:)` 是唯一 pane 创建入口，所有旧调用点改造完毕。
- 指定 profile 后 PTY 按 profile 的 command/args/cwd/env/close-on-exit 启动。
- 未指定时行为与改造前完全一致（全量回归通过）。
- 单元测试覆盖 `createPane` 的 snapshot 构造逻辑（mock `ProfileMerger`）。

---

## Phase 3：Pane 渲染走 Profile（Live 字段 + 热重载）

### 目标
让 pane 的外观（主题、字体、调色板等 Live 字段）按 profile 生效，且 profile 文件改动能热重载到所有引用该 profile 的 pane。

### 涉及文件
- `Packages/TongYouCore/Sources/TYConfig/ProfileLoader.swift` — 文件变更监听（复用 `DispatchSource`，风格对齐现有 `ConfigLoader`）
- `TongYou/Config/ConfigLoader.swift` — 注入 `ProfileLoader`，`applyConfigChange` 扩展为"某 profile 变更"通知
- `TongYou/Renderer/MetalView.swift` — `configureController()` 按 pane.profileID 从 `ProfileLoader` 解析 Live 字段组成 `Config`，替代原来读全局 `Config`
- `Packages/TongYouCore/Sources/TYTerminal/TerminalController.swift` — 暴露 `applyConfig(Config)` 作为运行期重新应用入口（已存在，确认接口对齐）

### 实现要点
1. 保留全局 `Config` 作为**默认 live 字段来源**——当 pane 的 profile resolve 后某字段未设置，就用全局 `Config` 对应值。现有 `SystemConfig.txt`/`user_config.txt` 的语义不变，相当于 `default` profile 的隐式基底。
2. `ProfileLoader` 维护 `[profileID: ResolvedLiveFields]` 缓存；文件变更时重新 resolve 受影响的 profile（考虑 `extends` 的反向依赖图，改 `base.txt` 要触发所有 `extends = base` 的 profile 重刷）。
3. 变更通知通过 `@Published` 或 Combine `PassthroughSubject` 发出 `profileID`；`MetalView` 订阅，找出所有 pane 的 profileID 命中后触发 `applyConfig`。
4. 为避免重复工作：变更节流 200ms（与现有 `ConfigLoader` 一致），合并同一 profile 的连续改动。
5. pane 从 Live 字段生成的 `Config` 结果 memoize 在 controller 里，避免每帧重新合并。

### 人工验证步骤
```bash
# 1. 默认行为不变
#    运行 App，修改 SystemConfig.txt/user_config.txt 仍然生效
make run
# 期望：改 font-size、theme 热生效（回归原有能力）

# 2. 准备不同外观的 profile
cat > ~/.config/tongyou/profiles/red.txt <<'EOF'
extends = default
theme = iterm2-pastel-dark-background
font-size = 18
background = 440000
EOF

# 3. 通过测试开关起带 profile 的 pane
TY_TEST_PROFILE=red make run
# 期望：新 pane 字体 18pt、背景暗红色

# 4. 热重载
#    App 运行中修改 red.txt 的 font-size = 22 并保存
# 期望：对应 pane 立即变为 22pt；未引用 red profile 的其他 pane 不受影响

# 5. 修改 extends 链的父
#    改 default profile 的 cursor-blink = true
# 期望：引用 default 的 pane 立即闪烁；引用 red 的 pane 也继承变化（red 未覆盖 cursor-blink）

# 6. 删除 profile 文件
rm ~/.config/tongyou/profiles/red.txt
# 期望：已存在的 red pane 继续渲染（缓存 fallback），日志告警；新建 pane 指定 red 报错
```

### 完成标准
- pane 的主题/字体/调色板完全由 profile 决定，全局 `Config` 作为隐式 default 基底。
- 修改 profile 文件后引用该 profile 的 pane 热重载，不引用的 pane 不受影响。
- `extends` 链上游改动能传播到下游。
- 同 profile 有 N 个 pane 时，一次变更只做一次 resolve（缓存命中）。

---

## Phase 4：Split 与新建场景继承父 Profile

### 目标
把"continuation 语义"接上：split 出的子 pane 默认继承父 pane 的 `profileID`；new tab / new session 默认用 `default`。此阶段仍通过 Phase 2 的测试开关驱动，不暴露 API。

### 涉及文件
- `TongYou/App/SessionManager.swift` — `splitPane`、`createFloatingPane` 接收可选 `profileID`，为 nil 时取 parent pane 的 profileID
- `TongYou/App/TabManager.swift` — `createTab` 接收可选 `profileID`，为 nil 时用 `default`
- `Packages/TongYouCore/Sources/TYServer/ServerSessionManager.swift` — 服务端对应路径同步

### 实现要点
1. 仅改参数传递链路，不改存储结构。
2. 需要同时考虑 UI 侧的快捷键路径（cmd+d / cmd+shift+d 等）与自动化侧，两者都走 `SessionManager.splitPane(parent:direction:profileID:)`，UI 侧传 nil 让内部默认用 parent。
3. floatPane 创建当前无 parent，用 active pane 的 profileID 作为 parent；active pane 也不存在时（session 级 float）用 default。

### 人工验证步骤
```bash
# 1. UI 回归
make run
# 期望：cmd+d / cmd+shift+d split 出来的 pane 行为和之前一致

# 2. 用 TY_TEST_PROFILE 起一个 ssh-like profile 的 pane，再 split
TY_TEST_PROFILE=test-ssh make run
# 在新 pane 里按 cmd+d split
# 期望：新 split 出来的 pane 也执行了 test-ssh 的 command

# 3. new tab 不继承
# 同一个窗口里按 cmd+t
# 期望：新 tab 用 default profile（跑默认 shell），不再跑 ssh

# 4. float pane 继承 active pane
# 在 test-ssh pane 激活时按 alt+n
# 期望：float pane 也跑 ssh
```

### 完成标准
- UI 侧无回归。
- split 在父 pane profile 下始终继承；new tab 不继承；float pane 以 active pane 为继承源。

---

## Phase 5：自动化命令支持 `profile` + `overrides`

### 目标
给 `tab.create` / `pane.split` / `floatPane.create` 三个命令加 `profile` 和 `overrides` 参数，走通 JSON-RPC 全链路。

### 涉及文件
- `Packages/TongYouCore/Sources/TYProtocol/GUIAutomationSchema.swift` — 扩充 request DTO（`TabCreateRequest`、`PaneSplitRequest`、`FloatPaneCreateRequest`）
- `Packages/TongYouCore/Sources/TYAutomation/GUIAutomationServer.swift` — handler 签名增加两个可选参数
- `TongYou/App/GUIAutomationService.swift` — service 层转发
- `Packages/TongYouCore/Sources/TYClient/AppControlClient.swift` — client 请求编码对应字段

### 实现要点
1. 请求体新增字段均为可选：`profile: String?`、`overrides: [String]?`。未传等价于 nil。
2. 服务端 handler 接收后调用 `ProfileMerger.resolve(profileID, overrides:)`，得到 snapshot + liveFields，走 Phase 2/3 的 `createPane` 入口。
3. overrides 解析失败（某行不是合法 `key = value`）返回 `INVALID_ARGUMENT`，message 指出具体哪一行。
4. 对 `profile` 不存在返回 `NOT_FOUND`；其他错误沿用现有 `AutomationError` 类型。
5. 响应体保持不变（只返回 `ref`），不回显 resolved 配置——避免序列化负担，用户想确认可以用单独的 `profile.resolve` debug 命令（本阶段可选）。

### 人工验证步骤
```bash
# 1. 准备 profile
cat > ~/.config/tongyou/profiles/ci.txt <<'EOF'
extends = default
command = /bin/bash
args = -c
args = env | grep TY_
env = TY_CI=1
close-on-exit = false
EOF

# 2. 用裸 socket 发请求（假设已拿到 token）
SOCK=~/Library/Caches/tongyou/gui-$(pgrep -f TongYou.app | head -1).sock
TOKEN=$(cat ~/Library/Caches/tongyou/gui-*.token)

# 先握手
(
  echo "{\"cmd\":\"handshake\",\"token\":\"$TOKEN\"}"
  # 再发 split，指定 profile + overrides
  echo '{"cmd":"pane.split","paneRef":"<现有 pane ref>","direction":"horizontal","focus":true,"profile":"ci","overrides":["env = TY_EXTRA=yes","font-size = 18"]}'
) | nc -U "$SOCK"
# 期望：返回 {"ok":true,"result":{"ref":"..."}}，新 pane 字体 18pt，env 里 TY_CI=1 + TY_EXTRA=yes

# 3. 非法 override
echo '{"cmd":"pane.split",...,"overrides":["this is not valid"]}' | nc -U "$SOCK"
# 期望：INVALID_ARGUMENT，指出第 1 行不合法

# 4. 不存在的 profile
echo '{"cmd":"pane.split",...,"profile":"nonexistent"}' | nc -U "$SOCK"
# 期望：NOT_FOUND

# 5. 不传 profile/overrides（老调用方式）
echo '{"cmd":"pane.split","paneRef":"...","direction":"horizontal"}' | nc -U "$SOCK"
# 期望：行为与改造前一致（继承父 pane 或 default）
```

### 完成标准
- 三个命令接受 `profile` + `overrides` 且行为符合上述规则。
- 老调用方式（不带新字段）完全兼容。
- 服务端输入校验完整，错误码语义准确。

---

## Phase 6：CLI `--profile` 与 `--set`

### 目标
在 `tongyou app new-tab / split / float-pane create` 三个子命令上加 `--profile` 与可重复的 `--set key=value`，把 Phase 5 的能力暴露到命令行。

### 涉及文件
- `Packages/TongYouCore/Sources/tongyou/main.swift` — 三处 subcommand 的 arg parsing
- `Packages/TongYouCore/Sources/TYClient/AppControlClient.swift` — 客户端方法签名增加 `profile`、`overrides` 参数
- `Packages/TongYouCore/Sources/tongyou/` 新增一个小工具函数 `collectSetFlags(_ argv: [String]) -> [String]`，解析重复 `--set k=v`

### 实现要点
1. `--set key=value`：parser 读整个 value 原样（不 split 等号右边），拼成 `"key = value"` 一行加入 `overrides` 数组。
2. `--set env=KEY=VALUE`：parser 只按**第一个** `=` 分 CLI flag 和 CLI value，因此 CLI value 是 `env=KEY=VALUE`；拼成字符串时还原为 `env = KEY=VALUE`，服务端再按第一个 `=` 分成 key=`env`，value=`KEY=VALUE`。两端语义一致。
3. CLI 侧**不做任何类型推断**——value 永远作为字符串拼接，类型由服务端的 field registry 决定。
4. 错误处理：`--set` 缺少 `=` 时 CLI 直接报错退出，不发请求。
5. Help 文本：每个子命令的 `--help` 列出 `--profile` 和 `--set` 示例。

### 人工验证步骤
```bash
# 1. 基础
./tongyou app split <pane-ref> --vertical --profile ci
# 期望：新 pane 按 ci profile 启动

# 2. 多个 --set
./tongyou app split <pane-ref> --horizontal \
  --profile ci \
  --set font-size=20 \
  --set env=FOO=bar \
  --set env=BAZ=qux
# 期望：新 pane font-size = 20，env 里 FOO=bar、BAZ=qux、TY_CI=1（从 ci profile 继承）

# 3. 重复 args 累积
./tongyou app new-tab <session-ref> \
  --profile ci \
  --set args=--flag1 \
  --set args=--flag2
# 期望：命令最终参数包含 [--flag1, --flag2]（替换 ci 里的 args，因为 args 是 list 类型）

# 4. 显式清零
./tongyou app split <pane-ref> --vertical \
  --profile ci \
  --set env=
# 期望：新 pane env 中 ci profile 的 TY_CI 被清零，只剩 default 继承的基础 env

# 5. 错误 flag
./tongyou app split <pane-ref> --set invalidnoequals
# 期望：CLI 立即退出，提示 "--set expects key=value"

# 6. --help 可读
./tongyou app split --help
# 期望：看到 --profile 与 --set 的说明和示例

# 7. 不传 profile/set（回归）
./tongyou app split <pane-ref> --horizontal
# 期望：行为和改造前完全一致
```

### 完成标准
- 三个创建类 CLI 子命令支持 `--profile` 和可重复 `--set key=value`。
- `--set env=KEY=VALUE` 等带多个 `=` 的场景语义正确。
- 不传新 flag 时行为与改造前一致。
- Help 文本更新。

---

## 已完成 6 个阶段后可以做但暂不列入本计划的后续增强

- **`profile.resolve` debug 命令**：给调用方回显最终 resolved 的字段，便于排查 override 生效情况。
- **SSH 方案 B（运行时探测）**：通过 shell integration / OSC 7 自动捕获远程上下文，split 时复制。依赖 shell-integration 框架先落地。
- **float pane 的 `initial-x/y/width/height`**：Phase 1 的字段表预留，`floatPane.create` 默认取 profile 里这些字段作为初始 frame。可以作为 Phase 5 的小增量或单独阶段。
- **Session/Tab 级默认 profile**：目前只到 pane 粒度，若用户希望"整个 session 默认用 xxx profile"可扩展 `session.create` / `tab.create` 带下游默认值。
- **Pane 运行期切换 profile**：当前明确不支持，若未来真有需求仅对 Live 字段生效（Startup 快照不可改）。
