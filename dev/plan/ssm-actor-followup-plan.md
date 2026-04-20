# ServerSessionManager actor 化 后续计划

P1（actor 化主改造）已在 commit `2c93f53` 落地，解决了 2026-04-20 `tongyou`
daemon 的 `EXC_BAD_ACCESS` 崩溃——`coreLookup` Dictionary 的并发读写，
`performFlush`（`server.message` queue）和 PTY exit on main 上的
`restoreFromInPlace` 之间的数据竞争。

本文档记录剩余工作：验证手段、P2（Sendable / TSan 审计）、P3（设计清理）。

---

## 1. 为什么难稳定复现

原崩溃是两个线程在同一时刻对 `[PaneID: TerminalCore]` 字典做读/写，
撞上 PAC（指针签名）校验失败才被 kernel 杀掉。条件：

- 至少一个 overlay pane（`runInPlace`）在运行，其 PTY 进程退出；
- 且同一时刻 `performFlush` 恰好在迭代 dirty pane 调 `coreLookup[paneID]?`；
- 且两次字典访问在 Swift COW 结构上时序重叠到触发 corruption。

真实使用中这个时间窗可能每天出现几次到几十次；大部分重叠只是读到不一致
的字段、并不立刻崩（silent corruption），PAC 只是概率性兜底。所以
"手动复现"在人肉操作下基本靠运气。

---

## 2. 好的验证手段

### 2.1 TSan（Thread Sanitizer，最推荐）

TSan 不需要崩溃，能在并发访问非线程安全结构时直接报告 data race。

```bash
cd Packages/TongYouCore
swift test -c debug --sanitize=thread
# 或对 daemon 跑一段时间：
swift build -c debug --sanitize=thread
# 启 daemon，正常连一个 GUI client 使用 10~30 分钟，触发各种 runInPlace /
# PTY exit / resize / 多 pane 场景
```

TSan 会把线程 A、线程 B 的调用栈一起报出来。actor 化后跑 TSan 应当对
`coreLookup` / `sessions` / `overlayStacks` 等字段 **零报告**。如果还有报
告——要么是 P2 漏掉的 callback 路径，要么是我们在 SocketServer 侧新引入
的、非 actor 保护的状态。

> 注意：TSan 与 `@unchecked Sendable` 不冲突。它检测实际 runtime 行为，
> 不读类型标注。

### 2.2 针对 race pattern 的单元测试

在 `ServerSessionManagerTests` 加一个压力测试，模拟原崩溃的并发场景：

```swift
@Test("coreLookup is safe against concurrent overlay-exit and performFlush",
      .timeLimit(.minutes(1)))
func coreLookupConcurrencyStress() async {
    let manager = ServerSessionManager()
    let session = await manager.createSession(name: "stress")
    guard case .leaf(let paneID) = session.tabs[0].layout else { return }

    // 循环 N 次：开一个 overlay → 让它立即退出；与此同时主线程在 flush 路径
    // 上反复读 coreLookup。actor 化前这会撞到 TSan；之后应当安静。
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for _ in 0..<200 {
                await manager.runInPlace(
                    sessionID: session.id, paneID: paneID,
                    command: "/usr/bin/true", arguments: []
                )
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        group.addTask {
            for _ in 0..<2_000 {
                _ = await manager.isSyncedUpdateActive(paneID: paneID)
                _ = await manager.consumeSnapshot(paneID: paneID)
            }
        }
    }
    await manager.closeSession(id: session.id)
}
```

actor 化之后这个测试只是"跑得完"没什么戏剧性。价值在**配合 TSan**：同一
个测试套件在 TSan 下跑，任何未来的回归（有人加了新的绕过 actor 的路径）
都会被第一时间报出来。建议加 `@Suite(..., .serialized)` 或在 CI 单独一
个 TSan job 里跑。

### 2.3 长跑 daemon + 高频 runInPlace

如果还是想做端到端验证，写个小脚本让 GUI 客户端在 10 分钟内连续调
`runInPlace` + 快速命令退出（`echo`, `true`），同时另一个 pane 持续
输出（`yes`）。崩溃在 P1 前大概几分钟内必挂，P1 后应当平稳。

---

## 3. P2 — Strict concurrency / Sendable 审计

P1 已经让编译干净、测试全绿，但项目的 Swift concurrency checking 级别
不一定是 `complete`。P2 目标：把所有 Sendable / data race 静态信号打开
到最严格，把剩下的 warning 一次性收拾掉。

### 步骤

1. 在 `Packages/TongYouCore/Package.swift` 里对 `TYServer` target 加：
   ```swift
   .target(
       name: "TYServer",
       swiftSettings: [
           .enableUpcomingFeature("StrictConcurrency"),
           // 或 Swift 6 模式：.swiftLanguageVersion(.v6)
       ]
   )
   ```
2. `swift build` 收所有 warning / error。重点关注：
   - `onScreenDirty` 等 `nonisolated(unsafe) var` 的 call site（理论上
     `@Sendable` 闭包已经约束好，但 strict 模式可能要求 callback
     签名加 `@Sendable`——当前已加，复核即可）；
   - `overlayCore.onProcessExited = { [weak self] _ in Task { ... } }`
     等 closure 是否满足 `@Sendable`；
   - `TerminalCore` `@unchecked Sendable` 下游使用是否有意外裂缝。
3. 所有剩余警告清干净，或明确标注 `@preconcurrency` / `nonisolated(unsafe)`
   并加注释解释原因。

### 交付

- P2 PR：`chore(concurrency): enable strict concurrency checks on TYServer`
- 含最小的代码调整 + 可能的几个 Sendable 注解补齐。

---

## 4. P3 — 设计清理（非紧急）

### 4.1 `messageQueue` 的角色重新审视

P1 保留了 `SocketServer.messageQueue` 作为：
1. SocketServer 自身状态（`dirtyPanes`、`lastSentState`、`flushTimer`、
   `consecutiveFlushCount`）的串行锁；
2. Flush / stats timer 的 callback queue；
3. 客户端消息的全局顺序串行点（`connection.onMessage` → `messageQueue.async`）。

以及 `blockingAwait` helper 把这几个同步入口桥接到 SSM actor。桥是正确的
但丑陋，并且"同一线程 sem.wait 等 Task"是 Swift concurrency 反模式。

长期更好的形态（二选一）：

- **SocketServer 也变成 actor**：把 `dirtyPanes` / `lastSentState` 等状态
  迁到 actor 里；`performFlush`、`handleClientMessage` 等直接 `async`；
  `connection.onMessage` 用 per-connection 的消息串行器（actor 或
  `AsyncChannel`）保证顺序。`blockingAwait` 删除。改动面大，但这是
  最"Swift-idiomatic"的终态。

- **AsyncChannel / AsyncStream-based message pump**：仅消息分发部分改，
  `messageQueue` 瘦身到只管定时器。血量介于上面两者之间。

### 4.2 `TerminalCore` 的 `@unchecked Sendable` 审视

`TerminalCore` 用 `@unchecked Sendable` 让 SSM actor 能跨边界传引用。
但它内部是否真的线程安全没有独立证明：

- `Screen` 是 class，有可变状态；`StreamHandler` 触发 `onScreenDirty`
  时正在持有 Screen 的写入权；
- 同时 SSM actor 可能 `await` 一个 `snapshot(paneID:)` → 里面读 Screen
  状态；
- 目前在实际运行中"因为 PTY 读总在 ptyQueue + 回调通过 actor 中转"所以
  没炸，但这是运气。

P3 任务：要么把 `TerminalCore` 也改成 actor（连带 `Screen`/`StreamHandler`
的访问都 await 化）；要么显式在 TerminalCore 内部文档它的线程规则，
并用锁/queue 保证 `@unchecked` 承诺真实成立。

### 4.3 `flushPendingSaves` 当前行为

P1 为避免死锁，`flushPendingSaves` 改成"刷所有 session"而不是"只刷
pending"。语义上对 shutdown 更安全，但 I/O 成本略增。如果后面 session
数很多这条成本要关注，可以让 `DebouncedSaver` 暴露 `pendingKeys()`
接口，精确 flush。

---

## 5. 顺手 follow-up

- PTY exit 路径现在是 `queue: .main` → `onProcessExited` →
  `Task { await restoreFromInPlace }`。多 tab 大量进程同时退出时会瞬时
  产生很多 Task 排队进 actor。应该没问题，但建议 TSan + 压测时观察。
- `restoreFromInPlace` 的 Task 是 fire-and-forget，如果中间 SSM 被意外
  deinit 而 Task 还没跑会 silently drop。daemon 生命周期里 SSM 一直活
  着，实操无影响，但写个 assert/log 有助将来排查。
- 现有 `onScreenDirty` callback 在 PTY 读线程上直接触发 `@Sendable`
  闭包（nonisolated(unsafe) 属性）。如果未来 GUI 客户端也直接拿这个
  callback 在主线程做渲染，注意并发边界。
