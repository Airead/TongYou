# TongYou 终端 CPU 性能优化计划

## 背景

当前 TongYou 在 macOS 上的 CPU 占用约为 Ghostty 的 2 倍。通过对核心代码（`MetalRenderer`、`Screen`、`TerminalController`、`PTYProcess`、`ShapedRowCache`）的分析，已定位 5 个明确的性能瓶颈。本计划按**风险从低到高、收益从高到低**排序，分为 5 个可独立实施、可人工验证的阶段。

---

## 通用验证工具与基准

| 工具/方法 | 用途 |
|-----------|------|
| **Activity Monitor** | 快速对比 TongYou 与 Ghostty 在相同操作下的 CPU% |
| **Instruments → Time Profiler** | 定位具体热点函数及占比 |
| **终端内运行 `cat large-file.txt`** | 标准压力测试（推荐 10MB+ 文本） |
| **光标静止观察** | 验证 idle CPU 是否接近 0% |
| **Frame Metrics（`debug-metrics` 配置项）** | 观察 `instanceBuildTimeMs`、`dedupedFrameCount` 等内部指标 |

**基准操作流程（每阶段验证时复用）**：
1. 启动 TongYou，窗口大小固定为 **180×60 列行**（或全屏）。
2. 执行 `cat /usr/share/dict/words`（约 2-3MB 文本）或更大文件。
3. 同时打开 Ghostty（同尺寸、同字体、同 shell）。
4. 用 Activity Monitor 观察两者 CPU%；必要时用 Time Profiler 采样 5 秒。
5. 观察光标 idle 时的 CPU（应接近 0%）。

---

## Phase 1：消除 `setContent` 无条件三帧全量重建

**目标**：让 `MetalRenderer` 只在真正需要时才触发 3 帧全量 rebuild，普通增量更新仅标记 1 帧脏区。

**预期收益**：**最大**，预计可降低 30–50% 的主线程 CPU。

### 问题分析

`MetalRenderer.setContent()` 第 439 行无条件调用 `markAllFramesDirty()`：

```swift
func setContent(_ snapshot: ScreenSnapshot) {
    // ... 合并 backingCells ...
    markAllFramesDirty()  // ← 总是设为 3 帧
}
```

这导致：
- 即使 PTY 只输出 **1 个字符**，主线程也要连续 **3 帧** 全量遍历 `rows × columns` 个 cell，重建 bg/underline/text instance buffers。
- 对于 180×60 的窗口，每帧要处理约 10,800 个 cell，做 3 次。

Ghostty 的 `RenderState` 是持久化的，只 patch 脏行，不会强制 3 帧全量 rebuild。

### 改动范围

- `TongYou/Renderer/MetalRenderer.swift`
  - 修改 `setContent()`：仅在 `snapshot.dirtyRegion.fullRebuild == true` 时调用 `markAllFramesDirty()`。
  - 对于 partial snapshot，仅将 `instanceRebuildCounter` 和 `textContentDirtyCounter` 设为 `1`。
  - 确保 `fillBgInstanceBuffer` / `fillTextInstanceBuffer` 能正确利用 `dirtyRegion` 只处理脏行（当前已有 `dirtyRegion` 参数，但需检查是否被充分利用）。

### 验证方法

1. **Activity Monitor 对比**：
   - 优化前：`cat large-file` 时 TongYou CPU 约 80–120%。
   - 优化后：应降至 **40–70%** 区间，接近 Ghostty。
2. **Frame Metrics**：
   - 开启 `debug-metrics: true`，在 `cat` 过程中观察 `instanceBuildTimeMs` 明显下降。
   - 每秒 `dedupedFrameCount` 应显著减少（因为不再需要 dedupe 3 帧中的 2 帧无效重建）。
3. **Time Profiler**：
   - 优化前：`fillBgInstanceBuffer` + `fillTextInstanceBuffer` 合计占主线程 40%+。
   - 优化后：两者合计占比应 **< 20%**。

---

## Phase 2：ShapedRowCache 命中判断优化（纯 Hash 比较）

**目标**：消除缓存命中时的 O(n) 数组逐元素比较，降低 `cat` 大文件时的主线程 shaping 开销。

**预期收益**：中等，预计可降低 10–20% 的 `cat` 场景 CPU。

### 问题分析

`ShapedRowCache.get(cells:)` 第 49 行：

```swift
guard Array(cells) == slots[slot].cells else { ... }
```

- 每行 180 个 cell，每次缓存命中都要做一次 180 元素的数组比较。
- `hashCells` 中对每个 cell 访问 `content.string`，可能触发 `GraphemeCluster` 的动态字符串构建。

### 改动范围

- `TongYou/Font/ShapedRowCache.swift`
  - 修改 `Entry` 结构：不再存储完整 `[Cell]`，只存储 **hash + 一个极小的校验摘要**（如前 4 个 cell 的 hash）。
  - `get(cells:)`：先比 hash，hash 命中后再比校验摘要；只有摘要冲突时才做全量回退比较。
  - `set(cells:)`：同理，只存 hash + 摘要。
  - 缓存淘汰时无需释放大数组，内存占用也会略微下降。

### 验证方法

1. **Time Profiler**：
   - 优化前：`ShapedRowCache.get` 及 `Array(cells) ==` 合计占主线程 5–10%。
   - 优化后：该热点应 **< 1%**。
2. **缓存命中率统计**：
   - `ShapedRowCache` 已暴露 `hits` / `misses`，可在测试或日志中打印 `hits / (hits + misses)`。
   - 优化后命中率不应下降（若下降说明摘要冲突过多，需调整摘要策略）。
3. **Activity Monitor**：
   - `cat` 场景下整体 CPU 应再下降约 5–10%。

---

## Phase 3：Instance Buffer 的逐行增量填充

**目标**：`fillBgInstanceBuffer` 和 `fillTextInstanceBuffer` 只写入脏行对应的 buffer 区域，而不是每帧遍历全屏。

**预期收益**：中等偏高，窗口越大收益越明显（全屏 4K 窗口收益显著）。

### 问题分析

当前 `fillBgInstanceBuffer` 虽然会 `continue` 非脏行，但仍然会：
- 遍历 `0..<rows` 的外层循环。
- 对每一行判断 `dirtyRegion.isDirty(row: row)`。

更重要的是：对于**不是全屏 rebuild** 的情况，当前实现仍然会把**所有行**的 instance 数据写入 GPU buffer（`ptr[idx] = ...` 覆盖全屏）。

理想情况下，如果只有第 5 行脏了，我们只需要：
- 更新第 5 行的 bg instance 和 text instance。
- 其他行的 buffer 数据保持不变，GPU draw call 的 `instanceCount` 虽然仍是全屏，但 CPU 写 buffer 的工作量大幅减少。

### 改动范围

- `TongYou/Renderer/MetalRenderer.swift`
  - `fillBgInstanceBuffer`：当 `!fullRebuild` 时，只遍历 `dirtyRegion.dirtyRows`，只写这些行对应的 buffer slice。
  - `fillTextInstanceBuffer`：同理，只在脏行上调用 `rebuildTextRow`，并将结果写入 buffer 的对应偏移位置。
  - 需要保留一个**持久化的 staging buffer**（而非每帧重新 compact 所有行），以便非脏行数据可以直接复用。

### 验证方法

1. **Frame Metrics**：
   - 观察 `instanceBuildTimeMs`：在 partial update 场景（如逐字符输入）中应降至 **< 0.3ms**。
2. **Instruments → Time Profiler**：
   - 优化前：`fillBgInstanceBuffer` 在部分脏场景仍会遍历全屏。
   - 优化后：在 partial 场景下，`fillBgInstanceBuffer` 的采样点应主要集中在脏行对应的小范围内。
3. **行为正确性**：
   - 快速输入字符、滚动、选中文字，确保屏幕无残留/撕裂/缺失。

---

## Phase 4：`consumeSnapshot` 从 `ptyQueue.sync` 改为异步推送

**目标**：消除主线程 `CADisplayLink` 对 PTY 读取队列的同步阻塞，降低 IO jitter 和整体 CPU 波动。

**预期收益**：中等，主要改善 `cat` 时的帧平滑度和 tail latency。

### 问题分析

`TerminalController.consumeSnapshot()`：

```swift
func consumeSnapshot() -> ScreenSnapshot? {
    let (snapshot, gen, urls) = ptyQueue.sync {
        // URLDetector.detect 也在里面
        return (snap, _contentGeneration, urls)
    }
}
```

- 主线程每次 display link 触发都要 `sync` 进 `ptyQueue`。
- 如果 `URLDetector.detect` 正在扫描全屏（Command 键按住时），PTY 的读取和 VT 解析会被暂停。
- Ghostty 使用专门的 IO Thread，snapshot 传递是 lock-free 的。

### 改动范围

- `TongYou/Terminal/TerminalController.swift`
  - 引入一个**原子引用**或 `actor`-safe 的队列，让 `ptyQueue` 在生成 snapshot 后 **async 推送到主线程**：
    ```swift
    // ptyQueue 内
    let snap = screen.snapshot(selection: sel, allowPartial: true)
    DispatchQueue.main.async { [weak self] in
        self?.pendingSnapshot = snap
        self?.onNeedsDisplay?()
    }
    ```
  - `consumeSnapshot()` 改为从主线程直接取出 `pendingSnapshot` 并清空，无需 `ptyQueue.sync`。
  - `URLDetector.detect` 移出 `ptyQueue`，在主线程拿到 snapshot 后再执行（只对可见行检测即可）。

### 验证方法

1. **Instruments → System Trace**：
   - 优化前：Time Profiler 中能看到 `consumeSnapshot` 调用栈里有 `ptyQueue.sync` 阻塞。
   - 优化后：主线程不应再出现 `ptyQueue.sync` 的调用栈。
2. **流畅度主观测试**：
   - `cat` 大文件时，观察是否有偶发的帧卡顿（stutter）。优化后应更平滑。
3. **Command 键按住测试**：
   - 按住 Cmd 并 `cat` 大文件，优化前可能因 URL 检测导致 CPU 尖峰；优化后 URL 检测在主线程异步进行，不应阻塞 PTY。

---

## Phase 5：DisplayLink Debounce 调优

**目标**：减少 `markScreenDirty()` 的 `asyncAfter` 延迟，让渲染尽快开始，把负载均匀分摊到多帧。

**预期收益**：较小，主要优化 latency 和 idle 响应。

### 问题分析

`TerminalController.markScreenDirty()`：

```swift
DispatchQueue.main.asyncAfter(
    deadline: .now() + Self.displayLinkInterval, // ~16ms
    execute: work
)
```

- PTY 数据到达后总要等约 16ms 才 wake display link。
- 如果这 16ms 内堆积了大量输出，最终启动时会一次性处理所有脏区，造成 CPU 脉冲。

### 改动范围

- `TongYou/Terminal/TerminalController.swift`
  - 将 `asyncAfter` 改为 `async`（0 延迟），或把 debounce 间隔从 16ms 降至 **1–2ms**。
  - 保留 `displayLinkDebounceWork` 机制以防止无限重排，但不要让数据在 main queue 上无谓等待。
  - 结合 Phase 1 的增量更新，即使 display link 更频繁唤醒，也只会处理少量脏行，不会增加总 CPU。

### 验证方法

1. **输入延迟感知**：
   - 快速敲击键盘（如 `while true; do echo x; done`），观察字符出现是否更跟手。
2. **Idle CPU**：
   - 静止光标时，CPU 应仍然接近 0%（因为 display link 在 `needsRender == false` 时会自动 pause）。
3. **Time Profiler**：
   - 优化前：`displayLinkFired` 的调用间隔不均匀，有 16ms 的 burst。
   - 优化后：调用间隔应更均匀，且每帧处理量更小。

---

## 阶段实施路线图

| 阶段 | 改动风险 | 预期 CPU 降幅 | 建议实施顺序 |
|------|----------|---------------|--------------|
| Phase 1：消除三帧全量重建 | 低 | 30–50% | **第 1 步** |
| Phase 2：ShapedRowCache 纯 Hash | 低 | 5–10% | **第 2 步** |
| Phase 3：Buffer 增量填充 | 中 | 10–20%（大窗口） | **第 3 步** |
| Phase 4：`sync` → 异步推送 | 中 | 5–10%（平滑度） | **第 4 步** |
| Phase 5：Debounce 调优 | 低 | 2–5% | **第 5 步** |

---

## 附录：人工验证 Checklist

每阶段完成后，按以下清单逐一勾选：

- [ ] **编译通过**：`make build` 无警告、无错误。
- [ ] **单元测试通过**：`make test` 全部绿色。
- [ ] **基准测试**：同窗口大小、同字体、同 shell 下与 Ghostty 对比 Activity Monitor CPU%。
- [ ] **压力测试**：`cat` 10MB 文本，屏幕无撕裂、无字符缺失、无渲染错误。
- [ ] **交互测试**：快速输入、选中、复制粘贴、resize 窗口，行为正常。
- [ ] **Idle 测试**：光标静止 5 秒，Activity Monitor 中 TongYou CPU 接近 0%。
- [ ] **URL 高亮测试**：按住 Cmd  hover 链接，下划线正确显示。

---

*文档创建时间：2026-04-16*  
*基于 MetalRenderer.swift (v1)、Screen.swift、TerminalController.swift 分析*
