# 终端序列支持补齐计划

## 背景

运行日常 TUI（vim、lazygit、claude code）时 `onUnhandledSequence` 日志打印以下未实现序列：

| 序列 | 来源 | 当前状态 |
|------|------|----------|
| `DEC mode bracketedPaste side effects` | DECSET/DECRST 2004 | bit 已存，但 `setDECMode` 无显式 case，走 default 打印日志 |
| `DEC mode cursorKeys side effects` | DECSET/DECRST 1 | 同上，bit 已存但无 case |
| `ESC \` | 字符串终止符 ST (7-bit) | parser 未把 ESC \ 当统一 ST 处理，`\` 被独立 dispatch 到 StreamHandler |
| `ESC =` | DECKPAM (Keypad Application Mode) | 未实现 |
| `ESC >` | DECKPNM (Keypad Numeric Mode) | 未实现 |
| `OSC 1` | Set Icon Name | 未实现 |
| `OSC 7` | Current Working Directory (file://URL) | 未实现 |

## 分析结论

### cursorKeys / bracketedPaste
- 这两个 mode 的 bit 已被 `TerminalModes` 存储，`KeyEncoder`/`PasteEncoder` 已读取并正确工作
- `setDECMode` 的 switch 中走 default 只是因为**本方法内没有额外 side effect 要执行**
- 属于**被动读取模式**（消费者自己读 bitfield），加空 case 即可消除误报

### ESC \ (ST)
- VTParser 的 anywhere transitions 将所有 ESC 都推进 escape 状态，未在字符串状态中将 ESC \ 当作统一 ST
- 结果是：字符串状态收到 ESC → exit dispatch 数据 → 进入 escape；接着 `\` 在 escape 状态被 dispatch
- StreamHandler 应**显式忽略** `ESC \`，因为 ST 不应产生 action

## 实施顺序

### Phase 1：消除误报（10 分钟）

1. `StreamHandler.setDECMode` 中给 `.cursorKeys` 和 `.bracketedPaste` 加空 case
2. `StreamHandler.handleESC` 中给 `0x5C` (ST/ESC \) 加 ignore case
3. 添加/更新对应测试

### Phase 2：ESC 扩展（30 分钟）

4. `TerminalModes` 添加 `keypadApplication` bit
5. `StreamHandler.handleESC` 实现 `ESC =` (set) / `ESC >` (reset)
6. `KeyEncoder` 读取 `keypadApplication` 影响小键盘编码（如果有小键盘支持）

### Phase 3：OSC 扩展（30-60 分钟）

7. `OSC 1`：icon name，可直接忽略或复用 title 逻辑
8. `OSC 7`：cwd URL，解析 `file://hostname/path`，传递到上层存储，支持新 Tab 默认目录等场景

## 验收标准

- [ ] Phase 1 完成后，运行 claude code / vim / lazygit 不再打印上述 3 条 warning
- [ ] 所有改动有单元测试覆盖
- [ ] `make test` 通过

## 参考文件

- `Packages/TongYouCore/Sources/TYTerminal/StreamHandler.swift`
- `Packages/TongYouCore/Sources/TYTerminal/TerminalModes.swift`
- `Packages/TongYouCore/Sources/TYTerminal/VTParser.swift`
- `Packages/TongYouCore/Sources/TYTerminal/KeyEncoder.swift`
- `Packages/TongYouCore/Tests/TYTerminalTests/StreamHandlerTests.swift`
