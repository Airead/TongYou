import Foundation
import TYAutomation
import TYTerminal

/// App-level facade over `GUIAutomationServer`.
///
/// Owns the server instance, wires start/stop to the app lifecycle, and
/// logs failures without aborting app launch (the GUI should remain
/// usable even if the automation socket fails to bind).
@MainActor
final class GUIAutomationService {
    static let shared = GUIAutomationService()

    private var server: GUIAutomationServer?
    private let refStore = GUIAutomationRefStore()

    private init() {}

    func start() {
        guard server == nil else { return }
        let config = GUIAutomationServer.Configuration(
            handleSessionList: { [weak self] in
                Self.runOnMain { self?.buildSessionList() ?? SessionListResponse(sessions: []) }
            }
        )
        let instance = GUIAutomationServer(configuration: config)
        do {
            try instance.start()
            server = instance
        } catch {
            NSLog("[TongYou] failed to start GUI automation server: \(error)")
        }
    }

    /// Synchronously run a closure on the main actor from any thread.
    /// If we're already on main, run inline to avoid deadlock.
    nonisolated private static func runOnMain<T: Sendable>(_ work: @MainActor @Sendable () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(work)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(work)
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    // MARK: - Session list builder

    /// Aggregate sessions from every registered `SessionManager`, compute
    /// snapshot state, and produce a `SessionListResponse`. Called on
    /// MainActor from `GUIAutomationServer` via `DispatchQueue.main.sync`.
    private func buildSessionList() -> SessionListResponse {
        let snapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: snapshots)
        return refStore.describeSessions(snapshots: snapshots)
    }

    private static func collectSnapshots() -> [SessionSnapshot] {
        var result: [SessionSnapshot] = []
        for manager in SessionManagerRegistry.shared.allManagers {
            let activeID = manager.activeSession?.id
            for session in manager.sessions {
                let state = Self.state(of: session, in: manager)
                result.append(SessionSnapshot(
                    session: session,
                    state: state,
                    isActive: session.id == activeID
                ))
            }
        }
        return result
    }

    private static func state(of session: TerminalSession, in manager: SessionManager) -> AutomationSessionState {
        if let serverID = session.source.serverSessionID {
            if manager.pendingAttachSessionIDs.contains(serverID) { return .pendingAttach }
            if !manager.attachedRemoteSessionIDs.contains(serverID) { return .detached }
            return .ready
        }
        if session.source == .local, !manager.attachedLocalSessionIDs.contains(session.id) {
            return .detached
        }
        return .ready
    }
}
