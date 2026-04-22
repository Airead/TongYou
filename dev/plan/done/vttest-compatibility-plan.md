# vttest 兼容性支持计划

基于 `vttest` 输出日志评估，当前终端模拟器缺失以下关键序列和模式支持。

## 当前状态

| 功能 | 状态 | 备注 |
|------|------|------|
| `CSI 0c` (DA1) | 未实现 | `StreamHandler` 无 DA1 分支，vttest 会卡死 |
| `ESC # 8` (DECALN) | 未实现 | `handleESCLineSize` 无 `#8` 处理 |
| Delayed Wrap (DECAWM) | **即时换行** | `Screen.writeCluster` 在 `cursorCol >= columns` 时立即换行，无 pending wrap 标志 |
| Reverse Wrap (Mode 45) | 未实现 | `TerminalModes` 无此定义，`cursorBackward` 在 col 0 停止 |
| `ESC %@ / ESC %G` | 未实现 | `handleESC` 无 `%` intermediate 处理 |
| Mode 4 (IRM) | 未实现 | SM/RM 直接报 "not implemented" |
| Mode 20 (LNM) | 未实现 | 同上 |
| Mode 40 (132col 安全锁) | 未实现 | 同上 |
| Mode 8 (Auto Repeat) | 未实现 | 可静默忽略 |

## 实施阶段

### Phase 1 — 立即可见（DA1 + DECALN）

**`CSI 0c` (Send Device Attributes)**
- `StreamHandler.handleCSI` 新增 `case 0x63` 且 `hasQuestion` 为 true 的分支
- 通过 `onWriteBack` 回写 `\033[?62;1;2;4;7;8;9;12;18;21;23;24;42c`
- 伪装为支持高级视频功能的 VT220，让 vttest 继续执行后续测试

**`ESC # 8` (Screen Alignment Pattern)**
- `handleESCLineSize` 新增 `case 0x38`
- `Screen` 新增 `fillWithE()`：用字符 `E` + 默认属性填满所有格子，光标移至 (0,0)

### Phase 2 — 核心改动（Delayed Wrap）

**延迟换行（DECAWM side effects）**
- `Screen` 增加 `pendingWrap: Bool` 标志
- 当光标位于最后一列且写入单宽字符时，**设置 `pendingWrap = true`**，光标停留在最后一列
- 下一个字符写入前，若 `pendingWrap == true`，先执行换行再写入
- 所有光标移动指令（`cursorForward`, `setCursorPos`, `carriageReturn`, `lineFeed`）在移动前检查 `pendingWrap`，为 true 则先换行
- **影响面大**，需全面测试边界场景

### Phase 3 — ANSI 模式与字符集（SM/RM + ESC %）

**ANSI `CSI h` / `CSI l`（不带 `?`）**
- 新增 `setANSIMode` 处理无 `?` 的 mode
- **Mode 4 (IRM)**：`writeCluster` 写入前若 IRM 开启，先右移当前位置及之后的字符
- **Mode 20 (LNM)**：`LF` 行为切换——开启时自动附加 `CR`，关闭时仅下移一行

**`ESC %G` / `ESC %@`**
- `handleESC` 新增 `%` intermediate 处理
- `ESC %G` → 记录 UTF-8 模式（当前默认已是 UTF-8，可识别后静默处理）
- `ESC %@` → 记录返回默认字符集
- 主要目的是避免报 `unhandled sequence`，让 vttest 通过编码切换测试

### Phase 4 — 可选完善

**Reverse Wraparound (Mode 45)**
- `TerminalModes.Mode` 新增 `reverseWrap = 45`
- `cursorBackward` 在 col 0 且 mode 45 开启时，退至上一行最后一列

**Mode 40 (Allow 80/132)**
- `TerminalModes.Mode` 新增 `allow132 = 40`
- 若不实现列数切换功能，可只记录 mode 状态，无副作用（静默忽略）

**Mode 8 (Auto Repeat)**
- 现代操作系统由窗口系统/输入法接管，**直接静默忽略**

## 测试要求

- 每个 Phase 完成后在 `TYTerminalTests` 增加对应测试用例
- DA1：验证 `onWriteBack` 收到正确响应
- DECALN：验证全屏为 `E` 且光标在左上角
- Delayed wrap：构造边界写入序列，验证光标位置和换行时机
- IRM/LNM：验证插入模式和换行模式的切换行为
- **所有测试使用 mock `onWriteBack` 回调，不涉及真实 PTY 或用户数据**

## 优先级

1. **必须**：DA1（否则 vttest 卡住）、Delayed wrap（否则屏幕计算错误）
2. **建议**：DECALN、ANSI SM/RM (mode 4/20)、ESC % 字符集切换
3. **可忽略**：Mode 8、Mode 40（若无列切换功能）
