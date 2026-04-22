# Terminal Modes 覆盖度审计计划

## 背景

排查一起 claude code 渲染错位 bug 时发现，我们的 `StreamHandler.setDECMode`
对 silent-drop 的 DEC private modes 比预期多：日志里 claude code 一人就
发了 `1004` / `2026` / `2031` 三个未知 mode，另外 `47` / `1047` / `1048`
也都会被静默丢弃。虽然这次只专门评估了 claude code 触发到的 mode，TongYou
作为一个终端模拟器对"常用 TUI 依赖哪些 mode"的整体支持情况其实从未系统
调查过。

本计划做一次**主动**的兼容性审计：跑一遍日常使用的 TUI，抓所有
`handled=unknown` 的 mode，对比现代终端（ghostty、wezterm、kitty、
microsoft terminal）的实现水平，产出一份"TongYou 应支持 vs 可以不支持"
的清单。

**非目标**：本计划只产出清单和优先级建议，**不实现**任何新 mode。实现
各自开 plan。

## 验收标准

- 一份 Markdown 清单：每个 TongYou 当前 unsupported 的 DEC mode 都有
  条目，包含 ID / 名称 / 语义一句话 / 调查观察到的触发者 / 建议优先级 /
  参考实现链接。
- 三档优先级：**建议实现** / **按需实现** / **不实现**。每档不超过一
  行理由。
- 归档到 `dev/plan/done/terminal-modes-audit-result.md`（或类似命名）。

## Phase 1：抓取真实 TUI 发送的 DECSET/DECRST 样本

### 目标

获取一份真实样本，而不是"按规范列表挨个评估"。样本越贴近 TongYou 实际
用户行为，优先级判断越可信。

### 待采集的 TUI 清单

必跑：

- `vim`（主流文本编辑器基线）
- `nvim`（大概率是 mode 2026 的主要消费者）
- `tmux`（终端复用 TUI 的典型）
- `htop` / `btop`（高频增量更新的 TUI）
- `lazygit`（popular git TUI）
- `claude code`（CLI agent，本次 bug 源头）

可选：

- `k9s`（Kubernetes TUI，依赖 Kitty keyboard protocol 等新 mode）
- `bat` / `less`（翻页器）
- `ranger` / `yazi`（文件管理 TUI）
- `neovide` 或 `wezterm` 自带的 overlay（如在 TongYou 里能跑）

### 方法

1. 保留本次调查引入的 `[MODE]` trace（commit `152c913`）；开启
   `daemon-debug-log-categories = cursorTrace`。
2. 对每个 TUI：
   - 打开一个新 pane
   - 启动该 TUI，做典型操作（滚动、搜索、窗口 resize、退出等）
   - 记录 `[MODE] ... handled=unknown` 的 raw 值集合 + 发送次数
3. 把每个 TUI 的 unknown mode 清单整理到 `docs/terminal-modes-observed.md`
   （中间文件，审计完可删）。

### 产出

形如：

```
## claude code v2.1.113
- raw=1004 value=true (1 次)
- raw=2026 value=true/false (总 4 次开关)
- raw=2031 value=true (1 次)

## nvim 0.11.x
- raw=1004 value=true/false
- raw=2026 value=true/false (高频，滚动时每帧一次)
- raw=2027 value=true (Extended mouse coordinates)
- raw=2048 value=true (Kitty keyboard protocol)
...
```

## Phase 2：对标现代终端的实现水平

### 目标

对 Phase 1 抓到的每个 mode，调研主流现代终端的实现情况，形成
"不实装会兼容 80% 还是 20% 用户"的判断依据。

### 对照目标

- **xterm**（规范事实标准，ctlseqs.html）
- **wezterm**（新一代 terminal 的功能覆盖上限参考）
- **kitty**（另一个功能激进的 terminal）
- **microsoft terminal / conhost**（主流程度参考）
- **ghostty**（和我们用户群重合度最高的 mac 原生 terminal）
- **iTerm2**（mac 老牌 terminal）

### 每个 mode 记录

- ID / 官方名
- 简短语义（≤ 1 行）
- 对照终端是否支持（Y / 部分 / N）
- 一条参考链接（规范或 PR）

### 工具

每个 mode 一次 `WebSearch` + 必要时 `WebFetch` 读 xterm ctlseqs 对应段落。
整个 Phase 估算 15–25 个 mode × 每个 3 分钟 ≈ 1 小时。

## Phase 3：优先级定级与清单产出

### 目标

综合 Phase 1（触发频率）和 Phase 2（生态支持度），给每个 mode 打一档：

- **建议实现**：命中多数高频 TUI、主流终端普遍支持、实装成本可控
- **按需实现**：只有小众 TUI 依赖、或实装成本高、或 TongYou 暂无对应
  能力可触发（例：需要 sixel 显示基础才实现 sixel 相关 mode）
- **不实现**：已被新 mode 取代（如 `1000` → `1006`）、或过于历史
  （xterm 祖宗版本遗留，现代 TUI 不再用）

### 判定准则

一个 mode 进入 **建议实现** 当且仅当满足至少两条：

1. 本次样本里 ≥ 2 个 TUI 触发
2. ghostty / wezterm / kitty 三者中 ≥ 2 实装了
3. 实装 API 面积小（< 50 行代码，不涉及新渲染能力）
4. 不实装时观察到明显的用户可见 bug

只满足一条 → **按需实现**。
零条或已被废弃 → **不实现**。

### 产出格式

```markdown
| Mode | 名称 | 触发者 | xterm | ghostty | wezterm | 建议 | 理由 |
|---|---|---|---|---|---|---|---|
| 2026 | Synchronized Output | nvim, tmux, claude | ✓ | ✓ | ✓ | 建议实现 | 高频 + 全部终端支持 + 已知 bug |
| 1004 | Focus Events | vim, nvim, claude | ✓ | ✓ | ✓ | 建议实现 | 简单实装 |
| 2031 | Color palette notif | claude, nvim | – | ✓ | ✓ | 按需 | 我们主题不跟随系统，实装无触发点 |
...
```

## Phase 4：归档

1. 把最终清单写入 `dev/plan/done/terminal-modes-audit-result.md`。
2. 为每个"建议实现"的 mode 单独开 implementation plan（小的 mode 可以
   合并，例如"焦点相关" / "鼠标相关" / "色彩相关"各一份）。
3. 删除中间产出 `docs/terminal-modes-observed.md`。
4. 归档本 plan 到 `dev/plan/done/`。

## 不做清单

- **不改代码**：本 plan 结束时 TongYou 代码不应有任何生产改动。
- **不囤积实装**：不把"建议实现"的所有 mode 一次性 plan 完——每个
  mode 单独判断实装方案，避免一个超长 plan 拖着进度。
- **不做 terminfo / termcap 测试**：本次调查聚焦**实际被发送**的
  escape，不研究 terminfo 数据库里声称支持什么——那是另一层问题。

## 时间估算

- Phase 1 抓样本：1–2 小时（取决于 TUI 数量）
- Phase 2 对照调研：1 小时
- Phase 3 定级 + 输出：30 分钟
- Phase 4 归档：15 分钟

总计约半个工作日，单人可完成，不阻塞其他开发。
