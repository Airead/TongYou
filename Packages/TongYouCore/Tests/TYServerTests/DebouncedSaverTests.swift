import Testing
import Foundation
@testable import TYServer

/// Helper: drop a few scheduler ticks so a DispatchQueue.asyncAfter
/// with a very short delay has definitely fired.
private func waitForDispatch(delay: TimeInterval, margin: TimeInterval = 0.15) {
    Thread.sleep(forTimeInterval: delay + margin)
}

@Suite("DebouncedSaver Tests", .serialized)
final class DebouncedSaverTests {

    /// Capture that counts body invocations per key. Wrapped in a class
    /// so the test can mutate through a @Sendable reference.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int: Int] = [:]
        private var order: [Int] = []

        func record(_ key: Int) {
            lock.lock()
            counts[key, default: 0] += 1
            order.append(key)
            lock.unlock()
        }

        func count(_ key: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[key, default: 0]
        }

        var total: Int {
            lock.lock(); defer { lock.unlock() }
            return order.count
        }
    }

    @Test func rapidSchedulesDebounceToSingleFire() throws {
        let counter = Counter()
        let saver = DebouncedSaver<Int>(delay: 0.05) { counter.record($0) }

        // Fire three times in the same debounce window for the same key.
        saver.schedule(42)
        saver.schedule(42)
        saver.schedule(42)

        waitForDispatch(delay: 0.05)
        #expect(counter.count(42) == 1, "debounce should collapse rapid schedules")
    }

    @Test func differentKeysFireIndependently() throws {
        let counter = Counter()
        let saver = DebouncedSaver<Int>(delay: 0.05) { counter.record($0) }

        saver.schedule(1)
        saver.schedule(2)
        saver.schedule(3)

        waitForDispatch(delay: 0.05)
        #expect(counter.count(1) == 1)
        #expect(counter.count(2) == 1)
        #expect(counter.count(3) == 1)
    }

    @Test func cancelPreventsFiring() throws {
        let counter = Counter()
        let saver = DebouncedSaver<Int>(delay: 0.1) { counter.record($0) }

        saver.schedule(7)
        saver.cancel(7)

        waitForDispatch(delay: 0.1)
        #expect(counter.count(7) == 0)
        #expect(saver.pendingCount == 0)
    }

    @Test func cancelAllDropsEveryPendingItem() throws {
        let counter = Counter()
        let saver = DebouncedSaver<Int>(delay: 0.1) { counter.record($0) }

        saver.schedule(1)
        saver.schedule(2)
        saver.schedule(3)
        #expect(saver.pendingCount == 3)

        saver.cancelAll()
        #expect(saver.pendingCount == 0)

        waitForDispatch(delay: 0.1)
        #expect(counter.total == 0)
    }

    @Test func flushAllRunsEachKeyOnce() throws {
        let counter = Counter()
        let saver = DebouncedSaver<Int>(delay: 1.0) { counter.record($0) }

        saver.schedule(1)
        saver.schedule(2)
        saver.schedule(3)
        saver.flushAll()

        #expect(counter.count(1) == 1)
        #expect(counter.count(2) == 1)
        #expect(counter.count(3) == 1)
        #expect(saver.pendingCount == 0)

        // Pending work items should have been cancelled — nothing more fires.
        waitForDispatch(delay: 1.0, margin: 0.2)
        #expect(counter.total == 3)
    }

    @Test func reschedulingExtendsDebounceWindow() throws {
        let counter = Counter()
        let saver = DebouncedSaver<Int>(delay: 0.12) { counter.record($0) }

        saver.schedule(9)
        Thread.sleep(forTimeInterval: 0.06)
        saver.schedule(9) // resets the window

        // At original-fire-time the body must NOT have run yet.
        Thread.sleep(forTimeInterval: 0.08)
        #expect(counter.count(9) == 0)

        // After the new window expires, the body runs exactly once.
        Thread.sleep(forTimeInterval: 0.12)
        #expect(counter.count(9) == 1)
    }

    @Test func weakOwnerReleaseAllowsDealloc() throws {
        final class Owner: @unchecked Sendable {
            var saves: Int = 0
            func flush(_ key: Int) { saves += 1 }
        }

        weak var weakOwner: Owner?

        do {
            let owner = Owner()
            weakOwner = owner
            let saver = DebouncedSaver<Int>(delay: 0.2) { [weak owner] key in
                owner?.flush(key)
            }
            saver.schedule(1)
            saver.cancelAll()
            _ = saver // keep saver alive until end of scope
        }

        // Both owner and saver went out of scope; weakOwner must be nil.
        #expect(weakOwner == nil, "weakly-captured owner must deallocate")
    }

    @Test func deinitCancelsPendingItems() throws {
        let counter = Counter()

        do {
            let saver = DebouncedSaver<Int>(delay: 0.1) { counter.record($0) }
            saver.schedule(1)
            saver.schedule(2)
            // saver goes out of scope here → deinit runs → items cancelled.
            _ = saver
        }

        waitForDispatch(delay: 0.1)
        #expect(counter.total == 0, "deinit must cancel in-flight items")
    }
}
