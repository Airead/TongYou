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