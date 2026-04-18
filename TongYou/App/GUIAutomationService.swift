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
            },
            handleTabCreate: { [weak self] ref in
                let service = self
                return service?.handleTabCreate(ref: ref)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleTabSelect: { [weak self] ref in
                let service = self
                return service?.handleTabSelect(ref: ref)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleTabClose: { [weak self] ref in
                let service = self
                return service?.handleTabClose(ref: ref)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handlePaneSplit: { [weak self] ref, direction in
                let service = self
                return service?.handlePaneSplit(ref: ref, direction: direction)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handlePaneFocus: { [weak self] ref in
                let service = self
                return service?.handlePaneFocus(ref: ref)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handlePaneClose: { [weak self] ref in
                let service = self
                return service?.handlePaneClose(ref: ref)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handlePaneResize: { [weak self] ref, ratio in
                let service = self
                return service?.handlePaneResize(ref: ref, ratio: ratio)
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

    // MARK: - tab / pane structure commands (Phase 5)
    //
    // Only `pane.focus` is in the focus whitelist — it actively brings the
    // GUI to the foreground on success. All other tab/pane commands here
    // mutate model state without activating the window.

    nonisolated private func handleTabCreate(ref: String) -> Result<TabCreateResponse, AutomationError> {
        let remote: RemoteTabCreateRequest?
        switch (Self.runOnMain { self.resolveTabCreateTarget(ref: ref) }) {
        case .failure(let err): return .failure(err)
        case .success(let decision):
            switch decision {
            case .local(let response): return .success(response)
            case .failed(let err): return .failure(err)
            case .remote(let req): remote = req
            }
        }
        guard let remote else { return .failure(.internal("tab.create decision missing")) }
        return createRemoteTabBlocking(request: remote)
    }

    nonisolated private func handleTabSelect(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain { self.tabSelectOnMain(ref: ref) }
    }

    nonisolated private func handleTabClose(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain { self.tabCloseOnMain(ref: ref) }
    }

    nonisolated private func handlePaneSplit(
        ref: String,
        direction: SplitDirection
    ) -> Result<PaneSplitResponse, AutomationError> {
        let remote: RemotePaneSplitRequest?
        switch (Self.runOnMain { self.resolvePaneSplitTarget(ref: ref, direction: direction) }) {
        case .failure(let err): return .failure(err)
        case .success(let decision):
            switch decision {
            case .local(let response): return .success(response)
            case .failed(let err): return .failure(err)
            case .remote(let req): remote = req
            }
        }
        guard let remote else { return .failure(.internal("pane.split decision missing")) }
        return splitRemotePaneBlocking(request: remote)
    }

    nonisolated private func handlePaneFocus(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain { self.paneFocusOnMain(ref: ref) }
    }

    nonisolated private func handlePaneClose(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain { self.paneCloseOnMain(ref: ref) }
    }

    nonisolated private func handlePaneResize(
        ref: String,
        ratio: Double
    ) -> Result<Void, AutomationError> {
        Self.runOnMain { self.paneResizeOnMain(ref: ref, ratio: ratio) }
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

    // MARK: - Phase 5 main-actor operations

    /// Outcome of `resolveTabCreateTarget` — either the operation fully
    /// completed locally, or a remote request is ready to dispatch.
    private enum TabCreateDecision {
        case local(TabCreateResponse)
        case remote(RemoteTabCreateRequest)
        case failed(AutomationError)
    }

    /// Parameters threaded to the connection-thread blocking waiter.
    private struct RemoteTabCreateRequest {
        let originalRef: String
        let sessionID: UUID
    }

    /// Parse/resolve the ref and, for local sessions, perform the tab
    /// create inline. For remote sessions, fall through to the caller so
    /// it can dispatch a blocking wait without holding the main actor.
    private func resolveTabCreateTarget(ref: String) -> Result<TabCreateDecision, AutomationError> {
        let snapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: snapshots)

        let parsed: AutomationRef
        do {
            parsed = try AutomationRef.parse(ref)
        } catch let err as AutomationError {
            return .failure(err)
        } catch {
            return .failure(.internal("ref parse failed: \(error)"))
        }
        guard case .session = parsed else {
            return .failure(.invalidParams("tab.create requires a session ref"))
        }

        let target: GUIAutomationRefStore.ResolvedTarget
        do {
            target = try refStore.resolve(parsed)
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

        if session.source.serverSessionID != nil {
            // Remote session: the server owns tab allocation. Verify it's
            // attached — sending createTab to the daemon for a detached
            // session would silently no-op, so report it explicitly.
            if let serverID = session.source.serverSessionID,
               !manager.attachedRemoteSessionIDs.contains(serverID) {
                return .failure(.unsupportedOperation(
                    "session is detached; attach it first with 'tongyou app attach'"
                ))
            }
            return .success(.remote(RemoteTabCreateRequest(
                originalRef: ref, sessionID: target.sessionID
            )))
        }

        guard let newTabID = manager.createTab(inSessionID: target.sessionID) else {
            return .success(.failed(.internal("tab.create failed")))
        }
        let postSnapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: postSnapshots)
        guard let newRef = refStore.tabRef(sessionID: target.sessionID, tabID: newTabID) else {
            return .success(.failed(.internal("ref allocation failed for new tab")))
        }
        return .success(.local(TabCreateResponse(ref: newRef)))
    }

    private func tabSelectOnMain(ref: String) -> Result<Void, AutomationError> {
        switch resolveTabTarget(ref: ref) {
        case .failure(let err): return .failure(err)
        case .success(let (manager, sessionID, tabIndex)):
            manager.selectTab(inSessionID: sessionID, at: tabIndex)
            return .success(())
        }
    }

    private func tabCloseOnMain(ref: String) -> Result<Void, AutomationError> {
        switch resolveTabTarget(ref: ref) {
        case .failure(let err): return .failure(err)
        case .success(let (manager, sessionID, tabIndex)):
            guard manager.closeTab(inSessionID: sessionID, at: tabIndex) else {
                return .failure(.tabNotFound(ref))
            }
            return .success(())
        }
    }

    /// Outcome of `resolvePaneSplitTarget` — either the split fully
    /// completed locally, or a remote request is ready to dispatch.
    private enum PaneSplitDecision {
        case local(PaneSplitResponse)
        case remote(RemotePaneSplitRequest)
        case failed(AutomationError)
    }

    /// Parameters threaded to the connection-thread blocking waiter.
    private struct RemotePaneSplitRequest {
        let originalRef: String
        let sessionID: UUID
        let paneID: UUID
        let direction: SplitDirection
    }

    /// Parse/resolve the ref and pick the target pane. For local sessions,
    /// run the split inline. For remote, package the request so the caller
    /// can block-wait on the server's layoutUpdate.
    private func resolvePaneSplitTarget(
        ref: String,
        direction: SplitDirection
    ) -> Result<PaneSplitDecision, AutomationError> {
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
        // Float panes cannot be split.
        if target.floatID != nil {
            return .failure(.unsupportedOperation("cannot split a floating pane"))
        }
        // Resolve the pane to split: explicit pane ref, else focused pane of
        // the session/tab-level ref, falling back to the first tree pane.
        let paneID: UUID
        if let explicit = target.paneID {
            paneID = explicit
        } else {
            let tab: TerminalTab?
            if let tabID = target.tabID {
                tab = session.tabs.first(where: { $0.id == tabID })
            } else {
                tab = session.activeTab
            }
            guard let resolvedTab = tab else { return .failure(.paneNotFound(ref)) }
            if let focused = resolvedTab.focusedPaneID, resolvedTab.paneTree.contains(paneID: focused) {
                paneID = focused
            } else {
                paneID = resolvedTab.paneTree.firstPane.id
            }
        }

        if session.source.serverSessionID != nil {
            if let serverID = session.source.serverSessionID,
               !manager.attachedRemoteSessionIDs.contains(serverID) {
                return .failure(.unsupportedOperation(
                    "session is detached; attach it first with 'tongyou app attach'"
                ))
            }
            return .success(.remote(RemotePaneSplitRequest(
                originalRef: ref,
                sessionID: target.sessionID,
                paneID: paneID,
                direction: direction
            )))
        }

        let newPane = TerminalPane()
        guard manager.splitPane(
            inSessionID: target.sessionID,
            id: paneID,
            direction: direction,
            newPane: newPane
        ) else {
            return .success(.failed(.paneNotFound(ref)))
        }
        let postSnapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: postSnapshots)
        guard let newRef = refStore.paneRef(sessionID: target.sessionID, paneID: newPane.id) else {
            return .success(.failed(.internal("ref allocation failed for new pane")))
        }
        return .success(.local(PaneSplitResponse(ref: newRef)))
    }

    private func paneFocusOnMain(ref: String) -> Result<Void, AutomationError> {
        switch resolveStrictPaneTarget(ref: ref) {
        case .failure(let err): return .failure(err)
        case .success(let (manager, sessionID, paneID, tabID, _)):
            // Bring the owning session / tab forward so the pane actually
            // becomes visible once focus lands on it.
            if let idx = manager.sessions.firstIndex(where: { $0.id == sessionID }),
               idx != manager.activeSessionIndex {
                manager.selectSession(at: idx)
            }
            if let tabID,
               let session = manager.sessions.first(where: { $0.id == sessionID }),
               let tabIdx = session.tabs.firstIndex(where: { $0.id == tabID }),
               session.activeTabIndex != tabIdx {
                manager.selectTab(inSessionID: sessionID, at: tabIdx)
            }
            manager.onFocusPaneRequest?(paneID)
            manager.notifyPaneFocused(paneID)
            Self.activateApp()
            return .success(())
        }
    }

    private func paneCloseOnMain(ref: String) -> Result<Void, AutomationError> {
        switch resolveStrictPaneTarget(ref: ref) {
        case .failure(let err): return .failure(err)
        case .success(let (manager, sessionID, paneID, _, isFloat)):
            if isFloat {
                return .failure(.unsupportedOperation(
                    "use floatPane.close for floating panes"
                ))
            }
            _ = manager.closePane(inSessionID: sessionID, id: paneID)
            return .success(())
        }
    }

    private func paneResizeOnMain(
        ref: String,
        ratio: Double
    ) -> Result<Void, AutomationError> {
        switch resolveStrictPaneTarget(ref: ref) {
        case .failure(let err): return .failure(err)
        case .success(let (manager, sessionID, paneID, _, isFloat)):
            if isFloat {
                return .failure(.unsupportedOperation(
                    "floating panes cannot be resized via pane.resize"
                ))
            }
            guard let session = manager.sessions.first(where: { $0.id == sessionID }) else {
                return .failure(.sessionNotFound(ref))
            }
            if let serverID = session.source.serverSessionID,
               !manager.attachedRemoteSessionIDs.contains(serverID) {
                return .failure(.unsupportedOperation(
                    "session is detached; attach it first with 'tongyou app attach'"
                ))
            }
            guard manager.updateSplitRatio(
                inSessionID: sessionID,
                paneID: paneID,
                newRatio: CGFloat(ratio)
            ) else {
                return .failure(.paneNotFound(ref))
            }
            return .success(())
        }
    }

    // MARK: - Phase 5 resolution helpers

    /// Resolve a tab-level ref to `(manager, sessionID, tabIndex)`.
    private func resolveTabTarget(
        ref: String
    ) -> Result<(SessionManager, UUID, Int), AutomationError> {
        let snapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: snapshots)

        let parsed: AutomationRef
        do {
            parsed = try AutomationRef.parse(ref)
        } catch let err as AutomationError {
            return .failure(err)
        } catch {
            return .failure(.internal("ref parse failed: \(error)"))
        }
        guard case .tab = parsed else {
            return .failure(.invalidParams("expected a tab ref like 'session/tab:N'"))
        }

        let target: GUIAutomationRefStore.ResolvedTarget
        do {
            target = try refStore.resolve(parsed)
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
        guard let tabID = target.tabID,
              let tabIndex = session.tabs.firstIndex(where: { $0.id == tabID }) else {
            return .failure(.tabNotFound(ref))
        }
        return .success((manager, target.sessionID, tabIndex))
    }

    /// Resolve a pane-or-float ref to `(manager, sessionID, paneID, tabID, isFloat)`.
    /// Rejects session/tab-level refs — callers needing those must handle them directly.
    private func resolveStrictPaneTarget(
        ref: String
    ) -> Result<(SessionManager, UUID, UUID, UUID?, Bool), AutomationError> {
        let snapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: snapshots)

        let parsed: AutomationRef
        do {
            parsed = try AutomationRef.parse(ref)
        } catch let err as AutomationError {
            return .failure(err)
        } catch {
            return .failure(.internal("ref parse failed: \(error)"))
        }
        let isFloat: Bool
        switch parsed {
        case .pane: isFloat = false
        case .float: isFloat = true
        default:
            return .failure(.invalidParams("expected a pane or float ref"))
        }

        let target: GUIAutomationRefStore.ResolvedTarget
        do {
            target = try refStore.resolve(parsed)
        } catch let err as AutomationError {
            return .failure(err)
        } catch {
            return .failure(.internal("ref resolution failed: \(error)"))
        }

        guard let manager = SessionManagerRegistry.shared.manager(owning: target.sessionID) else {
            return .failure(.sessionNotFound(ref))
        }
        guard let paneID = target.paneID ?? target.floatID else {
            return .failure(.paneNotFound(ref))
        }
        return .success((manager, target.sessionID, paneID, target.tabID, isFloat))
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

    // MARK: - Remote tab.create / pane.split: blocking wait
    //
    // Same pattern as `createRemoteSessionBlocking`: hop to MainActor,
    // register a one-shot layoutUpdate listener, fire the RPC to the
    // daemon, then block the connection thread on a semaphore until the
    // next layoutUpdate materializes the new entity.

    nonisolated private func createRemoteTabBlocking(
        request: RemoteTabCreateRequest
    ) -> Result<TabCreateResponse, AutomationError> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<TabCreateResponse>()

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.startRemoteTabCreate(request: request, box: box, signal: { semaphore.signal() })
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + Self.blockingWaitTimeout)
        if waitResult == .timedOut { return .failure(.mainThreadTimeout) }
        if let success = box.success { return .success(success) }
        if let error = box.error { return .failure(error) }
        return .failure(.internal("remote tab.create completed with no result"))
    }

    private func startRemoteTabCreate(
        request: RemoteTabCreateRequest,
        box: ResultBox<TabCreateResponse>,
        signal: @escaping @Sendable () -> Void
    ) {
        guard let manager = SessionManagerRegistry.shared.manager(owning: request.sessionID) else {
            box.error = .sessionNotFound(request.originalRef)
            signal()
            return
        }
        let sessionID = request.sessionID
        manager.onNextRemoteTabCreated(inSessionID: sessionID) { [weak self] newTabID in
            guard let self else {
                box.error = .internal("GUIAutomationService deallocated")
                signal()
                return
            }
            guard let newTabID else {
                box.error = .internal("remote tab.create failed or connection dropped")
                signal()
                return
            }
            let snapshots = Self.collectSnapshots()
            self.refStore.refreshRefs(snapshots: snapshots)
            if let ref = self.refStore.tabRef(sessionID: sessionID, tabID: newTabID) {
                box.success = TabCreateResponse(ref: ref)
            } else {
                box.error = .internal("ref allocation failed for new tab")
            }
            signal()
        }
        _ = manager.createTab(inSessionID: sessionID)
    }

    nonisolated private func splitRemotePaneBlocking(
        request: RemotePaneSplitRequest
    ) -> Result<PaneSplitResponse, AutomationError> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<PaneSplitResponse>()

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.startRemotePaneSplit(request: request, box: box, signal: { semaphore.signal() })
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + Self.blockingWaitTimeout)
        if waitResult == .timedOut { return .failure(.mainThreadTimeout) }
        if let success = box.success { return .success(success) }
        if let error = box.error { return .failure(error) }
        return .failure(.internal("remote pane.split completed with no result"))
    }

    private func startRemotePaneSplit(
        request: RemotePaneSplitRequest,
        box: ResultBox<PaneSplitResponse>,
        signal: @escaping @Sendable () -> Void
    ) {
        guard let manager = SessionManagerRegistry.shared.manager(owning: request.sessionID) else {
            box.error = .sessionNotFound(request.originalRef)
            signal()
            return
        }
        let sessionID = request.sessionID
        manager.onNextRemotePaneCreated(inSessionID: sessionID) { [weak self] newPaneID in
            guard let self else {
                box.error = .internal("GUIAutomationService deallocated")
                signal()
                return
            }
            guard let newPaneID else {
                box.error = .internal("remote pane.split failed or connection dropped")
                signal()
                return
            }
            let snapshots = Self.collectSnapshots()
            self.refStore.refreshRefs(snapshots: snapshots)
            if let ref = self.refStore.paneRef(sessionID: sessionID, paneID: newPaneID) {
                box.success = PaneSplitResponse(ref: ref)
            } else {
                box.error = .internal("ref allocation failed for new pane")
            }
            signal()
        }
        // `newPane` is ignored on the remote path (server owns allocation).
        _ = manager.splitPane(
            inSessionID: sessionID,
            id: request.paneID,
            direction: request.direction,
            newPane: TerminalPane()
        )
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
