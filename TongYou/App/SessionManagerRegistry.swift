import Foundation
import TYTerminal

/// Global weak-object registry for all active SessionManager instances.
final class SessionManagerRegistry {
    static let shared = SessionManagerRegistry()

    private let table = NSHashTable<SessionManager>.weakObjects()
    private let lock = NSLock()

    private init() {}

    var allManagers: [SessionManager] {
        lock.lock()
        defer { lock.unlock() }
        return table.allObjects
    }

    func register(_ manager: SessionManager) {
        lock.lock()
        table.add(manager)
        lock.unlock()
    }

    func unregister(_ manager: SessionManager) {
        lock.lock()
        table.remove(manager)
        lock.unlock()
    }
}