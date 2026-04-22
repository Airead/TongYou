# TongYou Release 版本 SIGSEGV 崩溃调查

## 事件概要

| 项目 | 详情 |
|------|------|
| 崩溃类型 | `SIGSEGV`（段错误 / 空指针访问）|
| 崩溃时间 | 2026-04-22 21:51:57 |
| 进程 PID | 74300 |
| 运行时长 | ~1.9 小时（6,910,205ms）|
| 启动时间 | 2026-04-22 19:56:46 |
| 崩溃日志 | **无 `.ips` 文件生成**（~DiagnosticReports 目录中无对应时间点的记录）|
| 触发方式 | 正常使用（`launch job demand`），非 Xcode 测试 |

## 调查结果

### 1. 系统日志确认

在 `/var/log/com.apple.xpc.launchd/launchd.log` 中发现崩溃记录：

```
exited due to SIGSEGV | sent by exc handler[74300], ran for 6910205ms
service has crashed 1 times in a row (last was not dirty)
```

确认是应用自身代码触发的段错误，非系统强制终止（如内存压力、看门狗超时）。

### 2. 为什么没有 `.ips` 文件

- 崩溃发生时 crash reporter 未能捕获（可能发生在信号处理过程中）
- 符号化或写入过程失败
- 应用可能使用了自定义信号处理，覆盖了默认崩溃报告机制

---

## 高风险代码区域

### 🔴 最高风险：MetalRenderer.swift

这是**最可能的崩溃源**，包含大量直接内存操作：

#### a) `backingCells` 数组越界访问

多处直接索引访问 `backingCells[rowBase + col]`，部分路径缺乏完善的边界验证：

| 行号 | 代码 | 风险 |
|------|------|------|
| 1152 | `backingCells[rowBase + col].attributes` | resize 后 backingCells 未同步 |
| 1237 | `backingCells[row * backingColumns + col]` | 乘法溢出或越界 |
| 1271 | `backingCells[url.row * backingColumns + clampedStart]` | url.row 可能超出 backingRows |
| 1406 | `backingCells[rowBase + col]` | buildRuns 中未检查边界 |
| 1594 | `backingCells[rowBase + col + 1]` | `col + 1` 可能越界 |
| 1635 | `backingCells[rowBase + col]` | rebuildTextRow 中未检查边界 |

**关键场景：** `resize()` 更新了 `backingColumns/backingRows`，但 `backingCells` 数组在 `setContent()` 的 else 分支才更新。在此期间如果触发 render，可能导致数组越界。

#### b) Metal 缓冲区指针操作

```swift
let ptr = frame.pointee.bgInstanceBuffer.contents()
    .bindMemory(to: CellBgInstance.self, capacity: count)
```

`ensureBufferCapacity` 在分配失败时直接 `return`（第1028行），但调用者继续写入 `ptr`，此时 `ptr` 指向旧的、可能已释放的缓冲区。

#### c) 指针索引越界写入

```swift
textPtr[tOff + i] = inst
emojiPtr[eOff + i] = inst
boxDrawPtr[bOff + i] = inst
arcCornerPtr[acOff + i] = inst
```

如果 `ensureBufferCapacity` 分配失败（返回 nil 但被忽略），或 `tOff + i` 计算错误，会导致堆外写入。

#### d) `withUnsafeMutablePointer` 与 `frameStates`

```swift
withUnsafeMutablePointer(to: &frameStates[frameIndex]) { frame in
```

虽然代码在 `MainActor` 上运行，但如果 `frameIndex` 在 `render()` 执行期间被异常修改（例如通过 `CADisplayLink` 回调的重入），可能导致访问无效的 `FrameState`。

### 🔴 高风险：VTAction.swift

```swift
buf.baseAddress!.advanced(by: destOffset)
    .copyMemory(from: src.baseAddress!.advanced(by: srcOffset), byteCount: count)
```

- `baseAddress!` 强制解包：在极端内存压力下可能为 nil
- `copyMemory` 无边界检查：如果 `srcOffset + count` 超过源缓冲区大小，或 `destOffset + count` 超过目标容量，会直接触发 SIGSEGV

### 🟡 中等风险

#### PTYProcess.swift

```swift
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.readBufSize)
```

如果在 `startReadSource` 被重复调用时（例如 fd 重新打开），旧的 `readSource` 被覆盖但未正确取消，可能导致：
- 缓冲区泄漏
- 双重释放（cancel handler 执行两次）

#### TYSocket.swift / LineIO.swift

多处使用 `buf.baseAddress! + offset`，存在同样的强制解包风险。

#### PaletteQueryHistory.swift / PaletteHistory.swift

```swift
unsafeBitCast(-1, to: sqlite3_destructor_type.self)
```

这是 SQLite 的标准用法，但 `unsafeBitCast` 本身属于不安全操作。

---

## 根因假设（按可能性排序）

### 假设 1：`backingCells` 数组越界（最可能）

**依据：**
- 崩溃发生在运行 1.9 小时后，说明是累积状态或边界条件触发
- `resize()` 和 `setContent()` 的同步机制存在时间窗口
- `backingCells` 的多处访问缺乏统一的边界 guard

**具体场景：**
1. 用户调整窗口大小触发 `resize()`
2. `resize()` 更新了 `gridSize` 和 `backingColumns/backingRows`
3. 但 `backingCells` 数组仍保持旧大小
4. `render()` 被 `CADisplayLink` 触发，调用 `fillBgInstanceBuffer`
5. `rowBase + col >= backingCells.count`，触发 SIGSEGV

### 假设 2：Metal 缓冲区使用已释放内存

**依据：**
- `shrinkBuffersIfNeeded()` 可能在 GPU 仍在使用旧缓冲区时释放它们
- `ensureBufferCapacity` 分配失败后继续写入旧指针

### 假设 3：VTAction.copyFrom 越界拷贝

**依据：**
- `copyMemory` 是底层的内存拷贝，无 Swift 边界检查
- 如果调用者传入错误的 `count` 或 `offset`，直接导致 SIGSEGV

---

## 建议修复措施

### 立即行动（高优先级）

1. **为 `backingCells` 访问添加统一边界检查**
   - 在 `MetalRenderer.swift` 中所有 `backingCells[...]` 访问前添加 `guard index < backingCells.count`
   - 或封装一个 `safeCell(atRow:col:)` 方法，返回 `Cell?`

2. **修复 `resize()` 与 `setContent()` 的同步**
   - 考虑在 `resize()` 中立即调整 `backingCells` 大小，而不是延迟到 `setContent()`
   - 或使用可选绑定/默认值处理不匹配的 partial snapshot

3. **验证 `ensureBufferCapacity` 的调用链**
   - 如果 `makeBuffer` 返回 nil，应返回错误/跳过渲染，而不是继续写入旧缓冲区

### 短期行动（中优先级）

4. **替换 `baseAddress!` 为安全访问**
   - 在 `VTAction.swift`、`TYSocket.swift`、`LineIO.swift` 中使用 `guard let addr = buf.baseAddress else { return }`

5. **为 `VTAction.copyFrom` 添加上下文校验**
   - 在 `copyMemory` 前验证 `srcOffset + count <= src.count` 和 `destOffset + count <= Self.capacity`

6. **检查 PTYProcess 的重复启动保护**
   - 确保 `startReadSource` 在 fd 不变时不会被重复调用
   - 旧的 `readSource` 必须先 `cancel()` 再重新创建

### 诊断增强

7. **添加崩溃报告收集**
   - 集成 `NSSetUncaughtExceptionHandler` 或 Sentry
   - 在 Release 构建中保留 dSYM

8. **添加断言和日志**
   - 在 `render()` 的入口检查 `backingCells.count == backingColumns * backingRows`
   - 在 `fillBgInstanceBuffer` 等关键函数中添加 `precondition` 或 `assert`

---

## 相关文件

- `TongYou/Renderer/MetalRenderer.swift`（最可能的崩溃源）
- `Packages/TongYouCore/Sources/TYTerminal/VTAction.swift`（copyMemory 风险）
- `Packages/TongYouCore/Sources/TYPTY/PTYProcess.swift`（缓冲区管理）
- `Packages/TongYouCore/Sources/TYProtocol/TYSocket.swift`（baseAddress! 风险）
- `Packages/TongYouCore/Sources/TYAutomation/LineIO.swift`（baseAddress! 风险）
- `TongYou/Config/PaletteQueryHistory.swift`（unsafeBitCast）
- `TongYou/Config/PaletteHistory.swift`（unsafeBitCast）

---

## 复现建议

由于崩溃发生在长时间运行后，建议：
1. 在 Release 模式下运行应用，频繁调整窗口大小（触发 resize/render 竞争）
2. 使用 `cat` 大文件产生快速滚动（触发 scrollDelta 和 partial snapshot 路径）
3. 监控 `backingCells.count` 和 `backingColumns * backingRows` 的一致性

*Created: 2026-04-22*
