import Foundation

/// Coalesces rapid "please save key X" calls into a single debounced
/// write per key.
///
/// Both `ServerSessionManager` (server-side) and the GUI app's
/// `SessionManager` (client-side local sessions) need the same
/// behaviour: every mutation schedules a save, but we only want to
/// hit disk every ~0.5s per session, and we need a way to flush all
/// pending work synchronously at shutdown.
///
/// ## Memory model
///
/// The `flushBody` closure is stored for the saver's lifetime and
/// invoked once per debounced tick. Callers **must** capture their
/// owner weakly (`{ [weak self] key in self?.flush(key) }`) to avoid
/// a retain cycle — the saver is typically a stored property of that
/// same owner.
///
/// `schedule(key:)` cancels the previous `DispatchWorkItem` for the
/// same key before enqueuing a new one, so the pending dictionary
/// never accumulates more than one entry per key. `cancelAll` /
/// `flushAll` cancel every in-flight item before clearing the dict,
/// and `deinit` does the same — so dispatched work items can never
/// outlive the saver and call into a freed closure.
public final class DebouncedSaver<Key: Hashable & Sendable>: @unchecked Sendable {

    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let flushBody: (Key) -> Void

    private var pending: [Key: DispatchWorkItem] = [:]
    private let lock = NSLock()

    /// - Parameters:
    ///   - delay: Debounce window (seconds). Default matches the
    ///     pre-extraction inline callers (0.5s).
    ///   - queue: Queue on which the debounced body runs. Default is
    ///     the utility global queue, matching prior behaviour.
    ///   - flushBody: Work to perform for a given key after debounce.
    ///     Capture your owner weakly.
    ///
    /// `flushBody` is intentionally not `@Sendable`: the existing
    /// inline `DispatchWorkItem { [weak self] in … }` pattern in both
    /// the server and the GUI captures a weak reference to a
    /// non-Sendable manager. Requiring Sendable here would reject
    /// those captures under strict Swift 6. The saver itself is
    /// thread-safe — the pending dict is guarded by an `NSLock`.
    public init(
        delay: TimeInterval = 0.5,
        queue: DispatchQueue = .global(qos: .utility),
        flushBody: @escaping (Key) -> Void
    ) {
        self.delay = delay
        self.queue = queue
        self.flushBody = flushBody
    }

    deinit {
        // Cancel anything still in flight so the dispatched closure
        // can't fire after the saver (and its captured context) has
        // been torn down.
        lock.lock()
        for (_, item) in pending { item.cancel() }
        pending.removeAll()
        lock.unlock()
    }

    /// Schedule (or re-schedule) a save for `key`. A pending work
    /// item for the same key is cancelled before the new one is
    /// enqueued, so the debounce window always reflects the most
    /// recent mutation.
    public func schedule(_ key: Key) {
        let body = flushBody
        let workItem = DispatchWorkItem { body(key) }

        lock.lock()
        pending[key]?.cancel()
        pending[key] = workItem
        lock.unlock()

        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Cancel the pending save (if any) for `key` without running it.
    public func cancel(_ key: Key) {
        lock.lock()
        pending.removeValue(forKey: key)?.cancel()
        lock.unlock()
    }

    /// Cancel every pending save without running any of them.
    public func cancelAll() {
        lock.lock()
        let items = pending
        pending.removeAll()
        lock.unlock()
        for (_, item) in items { item.cancel() }
    }

    /// Cancel every pending save and immediately run `flushBody` for
    /// each affected key on the calling thread. Used at shutdown to
    /// guarantee disk state is up-to-date before the process exits.
    public func flushAll() {
        lock.lock()
        let keys = Array(pending.keys)
        for (_, item) in pending { item.cancel() }
        pending.removeAll()
        lock.unlock()

        for key in keys {
            flushBody(key)
        }
    }

    /// Test-only: number of pending (scheduled, not yet fired/cancelled) keys.
    internal var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }
}
