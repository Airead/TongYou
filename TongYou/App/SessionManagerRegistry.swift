import Foundation
import TYTerminal

/// Global weak-object registry for all active SessionManager instances.
/// All access is MainActor-isolated.
@MainActor
final class SessionManagerRegistry {
    static let shared = SessionManagerRegistry()

    private let table = NSHashTable<SessionManager>.weakObjects()

    private init() {}

    var allManagers: [SessionManager] {
        table.allObjects
    }

    func register(_ manager: SessionManager) {
        table.add(manager)
    }

    func unregister(_ manager: SessionManager) {
        table.remove(manager)
    }

    /// The manager to use when a command has no session-ref context
    /// (e.g. `session.create`). Returns any live manager — callers that
    /// need per-session routing should use `manager(owning:)` instead.
    var primaryManager: SessionManager? {
        allManagers.first
    }

    /// Return the SessionManager that owns a session with the given UUID.
    /// Used to route ref-scoped commands (`session.close`, `session.attach`)
    /// to the correct window in a multi-window setup.
    func manager(owning sessionID: UUID) -> SessionManager? {
        for manager in allManagers {
            if manager.sessions.contains(where: { $0.id == sessionID }) {
                return manager
            }
        }
        return nil
    }

    /// Builds a lookup table mapping pane IDs to their session/tab metadata.
    var paneMetadataLookup: [UUID: SessionManager.PaneMetadata] {
        var lookup: [UUID: SessionManager.PaneMetadata] = [:]
        for manager in allManagers {
            for session in manager.sessions {
                for tab in session.tabs {
                    for paneID in tab.allPaneIDsIncludingFloating {
                        lookup[paneID] = SessionManager.PaneMetadata(
                            sessionName: session.name,
                            tabID: tab.id,
                            tabTitle: tab.title
                        )
                    }
                }
            }
        }
        return lookup
    }
}