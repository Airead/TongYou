import AppKit
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

    /// Timeout for blocking automation handlers that wait on MainActor
    /// work (e.g. remote session creation round-trips through the daemon).
    nonisolated private static let blockingWaitTimeout: DispatchTimeInterval = .seconds(5)

    private init() {}

    func start() {
        guard server == nil else { return }
        // Bind the weak self to a local `let` before forwarding to the
        // inner `@Sendable` closures. The [weak self] capture introduces
        // `self` as a mutable var, which Swift 6 flags when re-captured
        // inside concurrent closures.
        let config = GUIAutomationServer.Configuration(
            handleSessionList: { [weak self] in
                let service = self
                return Self.runOnMain { service?.buildSessionList() ?? SessionListResponse(sessions: []) }
            },
            handleSessionCreate: { [weak self] name, type in
                let service = self
                return service?.handleSessionCreate(name: name, type: type)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleSessionClose: { [weak self] ref in
                let service = self
                return service?.handleSessionClose(ref: ref)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleSessionAttach: { [weak self] ref in
                let service = self
                return service?.handleSessionAttach(ref: ref)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handlePaneSendText: { [weak self] ref, text in
                let service = self
                return service?.handlePaneSendText(ref: ref, text: text)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handlePaneSendKey: { [weak self] ref, input in
                let service = self
                return service?.handlePaneSendKey(ref: ref, input: input)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
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

    // MARK: - session.create / close / attach
    //
    // Phase 7 will introduce a focus whitelist mechanism (`GUIAutomationPolicy`);
    // these three commands belong to the whitelist, so they actively bring the
    // GUI to the foreground via `NSApp.activate(ignoringOtherApps: true)` once
    // the underlying operation succeeds.

    nonisolated private func handleSessionCreate(
        name: String?,
        type: AutomationSessionType
    ) -> Result<SessionCreateResponse, AutomationError> {
        switch type {
        case .local:
            return Self.runOnMain { self.createLocalSessionOnMain(name: name) }
        case .remote:
            return createRemoteSessionBlocking(name: name)
        }
    }

    nonisolated private func handleSessionClose(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain { self.closeSessionOnMain(ref: ref) }
    }

    nonisolated private func handleSessionAttach(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain { self.attachSessionOnMain(ref: ref) }
    }

    // MARK: - pane.sendText / pane.sendKey
    //
    // These are **not** in the focus whitelist — they must never bring the
    // window to the foreground. That rule is enforced here by simply not
    // calling `NSApp.activate` in the main-actor paths below.

    nonisolated private func handlePaneSendText(ref: String, text: String) -> Result<Void, AutomationError> {
        Self.runOnMain { self.sendTextOnMain(ref: ref, text: text) }
    }

    nonisolated private func handlePaneSendKey(
        ref: String,
        input: KeyEncoder.KeyInput
    ) -> Result<Void, AutomationError> {
        Self.runOnMain { self.sendKeyOnMain(ref: ref, input: input) }
    }

    // MARK: - MainActor operations

    private func createLocalSessionOnMain(name: String?) -> Result<SessionCreateResponse, AutomationError> {
        guard let manager = SessionManagerRegistry.shared.primaryManager else {
            return .failure(.internal("no SessionManager available"))
        }
        let sessionID = manager.createSession(name: name)
        // Refresh ref allocation so the new session gets a stable ref.
        let snapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: snapshots)
        guard let ref = refStore.sessionRef(for: sessionID) else {
            return .failure(.internal("ref allocation failed for new session"))
        }
        Self.activateApp()
        return .success(SessionCreateResponse(ref: ref))
    }

    private func closeSessionOnMain(ref: String) -> Result<Void, AutomationError> {
        let snapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: snapshots)

        let target: GUIAutomationRefStore.ResolvedTarget
        do {
            target = try refStore.resolve(refString: ref)
        } catch let err as AutomationError {
            return .failure(err)
        } catch {
            return .failure(.internal("ref resolution failed: \(error)"))
        }

        guard let manager = SessionManagerRegistry.shared.manager(owning: target.sessionID) else {
            return .failure(.sessionNotFound(ref))
        }
        guard let index = manager.sessions.firstIndex(where: { $0.id == target.sessionID }) else {
            return .failure(.sessionNotFound(ref))
        }

        let wasActive = manager.activeSessionIndex == index
        // Signal to view-layer callbacks that this close came from
        // automation — they must not close the hosting window when
        // the session list becomes empty. See TerminalWindowView's
        // `onRemoteSessionEmpty` handler.
        manager.isAutomationClose = true
        manager.closeSession(at: index)
        manager.isAutomationClose = false

        if wasActive, !manager.sessions.isEmpty {
            let nextIndex = manager.sessions.firstIndex(where: {
                manager.allAttachedSessionIDs.contains($0.id)
            }) ?? 0
            manager.selectSession(at: nextIndex)
        }

        Self.activateApp()
        return .success(())
    }

    private func attachSessionOnMain(ref: String) -> Result<Void, AutomationError> {
        let snapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: snapshots)

        let target: GUIAutomationRefStore.ResolvedTarget
        do {
            target = try refStore.resolve(refString: ref)
        } catch let err as AutomationError {
            return .failure(err)
        } catch {
            return .failure(.internal("ref resolution failed: \(error)"))
        }

        guard let manager = SessionManagerRegistry.shared.manager(owning: target.sessionID) else {
            return .failure(.sessionNotFound(ref))
        }
        guard let session = manager.sessions.first(where: { $0.id == target.sessionID }) else {
            return .failure(.sessionNotFound(ref))
        }
        guard let serverSessionID = session.source.serverSessionID else {
            return .failure(.unsupportedOperation("cannot attach a local session"))
        }
        manager.attachRemoteSession(serverSessionID: serverSessionID)
        Self.activateApp()
        return .success(())
    }

    private func sendTextOnMain(ref: String, text: String) -> Result<Void, AutomationError> {
        switch resolvePaneController(ref: ref) {
        case .success(let controller):
            controller.sendText(text)
            return .success(())
        case .failure(let err):
            return .failure(err)
        }
    }

    private func sendKeyOnMain(ref: String, input: KeyEncoder.KeyInput) -> Result<Void, AutomationError> {
        switch resolvePaneController(ref: ref) {
        case .success(let controller):
            controller.sendKey(input)
            return .success(())
        case .failure(let err):
            return .failure(err)
        }
    }

    /// Resolve a ref (session / tab / pane / float) to the `TerminalControlling`
    /// that should receive the input event. Session- and tab-level refs pick
    /// the currently focused pane, falling back to the tab's first tree pane.
    private func resolvePaneController(ref: String) -> Result<any TerminalControlling, AutomationError> {
        let snapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: snapshots)

        let target: GUIAutomationRefStore.ResolvedTarget
        do {
            target = try refStore.resolve(refString: ref)
        } catch let err as AutomationError {
            return .failure(err)
        } catch {
            return .failure(.internal("ref resolution failed: \(error)"))
        }

        guard let manager = SessionManagerRegistry.shared.manager(owning: target.sessionID) else {
            return .failure(.sessionNotFound(ref))
        }
        guard let session = manager.sessions.first(where: { $0.id == target.sessionID }) else {
            return .failure(.sessionNotFound(ref))
        }

        let paneID: UUID
        if let explicit = target.paneID ?? target.floatID {
            paneID = explicit
        } else {
            // Session- or tab-level ref: resolve to the focused pane, fallback first tree pane.
            let tab: TerminalTab?
            if let tabID = target.tabID {
                tab = session.tabs.first(where: { $0.id == tabID })
            } else {
                tab = session.activeTab
            }
            guard let resolvedTab = tab else {
                return .failure(.paneNotFound(ref))
            }
            if let focused = resolvedTab.focusedPaneID, resolvedTab.hasPane(id: focused) {
                paneID = focused
            } else {
                paneID = resolvedTab.paneTree.firstPane.id
            }
        }

        guard let controller = manager.controller(for: paneID) else {
            return .failure(.paneNotFound(ref))
        }
        return .success(controller)
    }

    // MARK: - Remote create: blocking wait

    /// Remote create hops to MainActor, enqueues the create request, then
    /// blocks the caller (the connection thread) on a semaphore until the
    /// daemon round-trips. Timeout returns `MAIN_THREAD_TIMEOUT` so the
    /// CLI gets a definite answer instead of hanging.
    nonisolated private func createRemoteSessionBlocking(name: String?) -> Result<SessionCreateResponse, AutomationError> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<SessionCreateResponse>()

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.startRemoteCreate(name: name, box: box, signal: { semaphore.signal() })
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + Self.blockingWaitTimeout)
        if waitResult == .timedOut {
            return .failure(.mainThreadTimeout)
        }
        if let success = box.success { return .success(success) }
        if let error = box.error { return .failure(error) }
        return .failure(.internal("remote create completed with no result"))
    }

    private func startRemoteCreate(
        name: String?,
        box: ResultBox<SessionCreateResponse>,
        signal: @escaping @Sendable () -> Void
    ) {
        guard let manager = SessionManagerRegistry.shared.primaryManager else {
            box.error = .internal("no SessionManager available")
            signal()
            return
        }
        manager.createRemoteSession(name: name) { [weak self] localID in
            guard let self else {
                box.error = .internal("GUIAutomationService deallocated")
                signal()
                return
            }
            guard let localID else {
                box.error = .internal("remote session creation failed or connection dropped")
                signal()
                return
            }
            let snapshots = Self.collectSnapshots()
            self.refStore.refreshRefs(snapshots: snapshots)
            if let ref = self.refStore.sessionRef(for: localID) {
                box.success = SessionCreateResponse(ref: ref)
                Self.activateApp()
            } else {
                box.error = .internal("ref allocation failed for new session")
            }
            signal()
        }
    }

    @MainActor
    private static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Mutable result slot shared between the connection thread (waiter) and
/// the MainActor (producer). Access is serialized by the semaphore: the
/// main-actor closure writes before signalling; the waiter reads after.
nonisolated private final class ResultBox<Value>: @unchecked Sendable {
    nonisolated(unsafe) var success: Value?
    nonisolated(unsafe) var error: AutomationError?
}
