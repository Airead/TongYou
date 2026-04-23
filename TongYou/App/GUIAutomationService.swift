import AppKit
import Foundation
import TYAutomation
import TYConfig
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
            handleSessionCreate: { [weak self] name, type, focus in
                let service = self
                return service?.handleSessionCreate(name: name, type: type, focus: focus)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleSessionClose: { [weak self] ref in
                let service = self
                return service?.handleSessionClose(ref: ref)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleSessionAttach: { [weak self] ref, focus in
                let service = self
                return service?.handleSessionAttach(ref: ref, focus: focus)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleSessionDetach: { [weak self] ref in
                let service = self
                return service?.handleSessionDetach(ref: ref)
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
            handleTabCreate: { [weak self] ref, focus, profile, overrides in
                let service = self
                return service?.handleTabCreate(
                    ref: ref, focus: focus, profile: profile, overrides: overrides
                ) ?? .failure(.internal("GUIAutomationService deallocated"))
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
            handlePaneSplit: { [weak self] ref, direction, focus, profile, overrides in
                let service = self
                return service?.handlePaneSplit(
                    ref: ref,
                    direction: direction,
                    focus: focus,
                    profile: profile,
                    overrides: overrides
                ) ?? .failure(.internal("GUIAutomationService deallocated"))
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
            },
            handleFloatPaneCreate: { [weak self] ref, focus, profile, overrides in
                let service = self
                return service?.handleFloatPaneCreate(
                    ref: ref, focus: focus, profile: profile, overrides: overrides
                ) ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleFloatPaneFocus: { [weak self] ref in
                let service = self
                return service?.handleFloatPaneFocus(ref: ref)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleFloatPaneClose: { [weak self] ref in
                let service = self
                return service?.handleFloatPaneClose(ref: ref)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleFloatPanePin: { [weak self] ref in
                let service = self
                return service?.handleFloatPanePin(ref: ref)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleFloatPaneMove: { [weak self] ref, frame in
                let service = self
                return service?.handleFloatPaneMove(ref: ref, frame: frame)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleWindowFocus: { [weak self] in
                let service = self
                return service?.handleWindowFocus()
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleSSHList: { [weak self] in
                let service = self
                return service?.handleSSHList()
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleSSHSearch: { [weak self] queries, profile in
                let service = self
                return service?.handleSSHSearch(queries: queries, profile: profile)
                    ?? .failure(.internal("GUIAutomationService deallocated"))
            },
            handleSSHBatch: { [weak self] targets, profile, overrides in
                let service = self
                return service?.handleSSHBatch(targets: targets, profile: profile, overrides: overrides)
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

    /// Validate a profile id + overrides combination against the
    /// SessionManager-owned `ProfileMerger`. Returns the mapped
    /// `AutomationError` on failure, or nil when the profile resolves.
    /// Callers invoke this inside `resolve*Target` so the CLI receives
    /// `PROFILE_NOT_FOUND` / `INVALID_PARAMS` before the actual create
    /// call (which would otherwise silently fall back to `default`).
    @MainActor
    private static func validateProfile(
        manager: SessionManager,
        id: String,
        overrides: [String]
    ) -> AutomationError? {
        do {
            try manager.tryResolveProfile(id: id, overrides: overrides)
            return nil
        } catch let err as ProfileResolveError {
            switch err {
            case .profileNotFound(let profileID):
                return .profileNotFound(profileID)
            case .circularExtends(let chain):
                return .invalidParams("circular profile extends: \(chain.joined(separator: " -> "))")
            case .extendsDepthExceeded(let chain):
                return .invalidParams("profile extends depth exceeded: \(chain.joined(separator: " -> "))")
            case .invalidOverrideLine(let index, let line):
                return .invalidParams("overrides[\(index)] invalid: '\(line)'")
            case .undefinedVariable(let name):
                return .invalidParams("undefined profile variable: '${\(name)}'")
            }
        } catch {
            return .internal("profile resolve failed: \(error)")
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
    // These commands mutate session state but are **not** on the Phase 7
    // focus whitelist — they must not bring the GUI to the foreground. The
    // rule is enforced by routing all activation attempts through
    // `GUIAutomationPolicy.activateIfAllowed(command:)`; passing a non-
    // whitelisted command is a silent no-op.

    nonisolated private func handleSessionCreate(
        name: String?,
        type: AutomationSessionType,
        focus: Bool
    ) -> Result<SessionCreateResponse, AutomationError> {
        switch type {
        case .local:
            return Self.runOnMain {
                GUIAutomationPolicy.withAutomationRequest(command: .sessionCreate, viewFocus: focus) {
                    self.createLocalSessionOnMain(name: name)
                }
            }
        case .remote:
            return createRemoteSessionBlocking(name: name, focus: focus)
        }
    }

    nonisolated private func handleSessionClose(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .sessionClose) {
                self.closeSessionOnMain(ref: ref)
            }
        }
    }

    nonisolated private func handleSessionAttach(ref: String, focus: Bool) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .sessionAttach, viewFocus: focus) {
                self.attachSessionOnMain(ref: ref)
            }
        }
    }

    nonisolated private func handleSessionDetach(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .sessionDetach) {
                self.detachSessionOnMain(ref: ref)
            }
        }
    }

    // MARK: - pane.sendText / pane.sendKey
    //
    // These are **not** in the focus whitelist — they must never bring the
    // window to the foreground. That rule is enforced here by simply not
    // calling `GUIAutomationPolicy.activateIfAllowed` in the main-actor
    // paths below.

    nonisolated private func handlePaneSendText(ref: String, text: String) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .paneSendText) {
                self.sendTextOnMain(ref: ref, text: text)
            }
        }
    }

    nonisolated private func handlePaneSendKey(
        ref: String,
        input: KeyEncoder.KeyInput
    ) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .paneSendKey) {
                self.sendKeyOnMain(ref: ref, input: input)
            }
        }
    }

    // MARK: - tab / pane structure commands (Phase 5)
    //
    // Only `pane.focus` is in the focus whitelist — it actively brings the
    // GUI to the foreground on success. All other tab/pane commands here
    // mutate model state without activating the window.

    nonisolated private func handleTabCreate(
        ref: String,
        focus: Bool,
        profile: String?,
        overrides: [String]?
    ) -> Result<TabCreateResponse, AutomationError> {
        let remote: RemoteTabCreateRequest?
        switch (Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .tabCreate, viewFocus: focus) {
                self.resolveTabCreateTarget(ref: ref, profile: profile, overrides: overrides)
            }
        }) {
        case .failure(let err): return .failure(err)
        case .success(let decision):
            switch decision {
            case .local(let response): return .success(response)
            case .failed(let err): return .failure(err)
            case .remote(let req): remote = req
            }
        }
        guard let remote else { return .failure(.internal("tab.create decision missing")) }
        return createRemoteTabBlocking(request: remote, focus: focus)
    }

    nonisolated private func handleTabSelect(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .tabSelect) {
                self.tabSelectOnMain(ref: ref)
            }
        }
    }

    nonisolated private func handleTabClose(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .tabClose) {
                self.tabCloseOnMain(ref: ref)
            }
        }
    }

    nonisolated private func handlePaneSplit(
        ref: String,
        direction: SplitDirection,
        focus: Bool,
        profile: String?,
        overrides: [String]?
    ) -> Result<PaneSplitResponse, AutomationError> {
        let remote: RemotePaneSplitRequest?
        switch (Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .paneSplit, viewFocus: focus) {
                self.resolvePaneSplitTarget(
                    ref: ref,
                    direction: direction,
                    profile: profile,
                    overrides: overrides
                )
            }
        }) {
        case .failure(let err): return .failure(err)
        case .success(let decision):
            switch decision {
            case .local(let response): return .success(response)
            case .failed(let err): return .failure(err)
            case .remote(let req): remote = req
            }
        }
        guard let remote else { return .failure(.internal("pane.split decision missing")) }
        return splitRemotePaneBlocking(request: remote, focus: focus)
    }

    nonisolated private func handlePaneFocus(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .paneFocus) {
                self.paneFocusOnMain(ref: ref)
            }
        }
    }

    nonisolated private func handlePaneClose(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .paneClose) {
                self.paneCloseOnMain(ref: ref)
            }
        }
    }

    nonisolated private func handlePaneResize(
        ref: String,
        ratio: Double
    ) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .paneResize) {
                self.paneResizeOnMain(ref: ref, ratio: ratio)
            }
        }
    }

    // MARK: - floatPane.* (Phase 6)
    //
    // Only `floatPane.focus` is focus-whitelisted — it actively brings the
    // GUI to the foreground on success. The rest mutate model state without
    // activating the window.
    //
    // For remote sessions, `floatPane.create` follows the same blocking-
    // semaphore pattern as `tab.create` / `pane.split`: we register a
    // one-shot listener on `SessionManager`, send the RPC, then wait for
    // the server's layoutUpdate to materialize the new float.

    nonisolated private func handleFloatPaneCreate(
        ref: String,
        focus: Bool,
        profile: String?,
        overrides: [String]?
    ) -> Result<FloatPaneCreateResponse, AutomationError> {
        let remote: RemoteFloatCreateRequest?
        switch (Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .floatPaneCreate, viewFocus: focus) {
                self.resolveFloatCreateTarget(
                    ref: ref,
                    profile: profile,
                    overrides: overrides
                )
            }
        }) {
        case .failure(let err): return .failure(err)
        case .success(let decision):
            switch decision {
            case .local(let response): return .success(response)
            case .failed(let err): return .failure(err)
            case .remote(let req): remote = req
            }
        }
        guard let remote else { return .failure(.internal("floatPane.create decision missing")) }
        return createRemoteFloatBlocking(request: remote, focus: focus)
    }

    nonisolated private func handleFloatPaneFocus(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .floatPaneFocus) {
                self.floatPaneFocusOnMain(ref: ref)
            }
        }
    }

    nonisolated private func handleFloatPaneClose(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .floatPaneClose) {
                self.floatPaneCloseOnMain(ref: ref)
            }
        }
    }

    nonisolated private func handleFloatPanePin(ref: String) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .floatPanePin) {
                self.floatPanePinOnMain(ref: ref)
            }
        }
    }

    nonisolated private func handleFloatPaneMove(
        ref: String,
        frame: FloatPaneFrame
    ) -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .floatPaneMove) {
                self.floatPaneMoveOnMain(ref: ref, frame: frame)
            }
        }
    }

    // MARK: - window.focus
    //
    // Focus-whitelisted: unconditionally brings the GUI to the foreground
    // without changing which pane is focused. Used by scripts that want to
    // surface the window after a batch of non-whitelisted mutations.

    nonisolated private func handleWindowFocus() -> Result<Void, AutomationError> {
        Self.runOnMain {
            GUIAutomationPolicy.withAutomationRequest(command: .windowFocus) {
                GUIAutomationPolicy.activateIfAllowed(command: .windowFocus)
                return .success(())
            }
        }
    }

    // MARK: - SSH Commands

    nonisolated private func handleSSHList() -> Result<GUIAutomationServer.SSHListResponse, AutomationError> {
        Self.runOnMain {
            self.buildSSHList()
        }
    }

    @MainActor
    private func buildSSHList() -> Result<GUIAutomationServer.SSHListResponse, AutomationError> {
        // Synchronously load ssh_config without history
        let configHosts: [SSHConfigHost]
        do {
            configHosts = try SSHConfigHosts.load(from: SSHConfigHosts.defaultURL).hosts
        } catch {
            configHosts = []
        }
        
        let candidates = configHosts.map { host in
            SSHCandidate(
                target: host.alias,
                hostname: host.hostname,
                isAdHoc: false
            )
        }
        
        let response = GUIAutomationServer.SSHListResponse(
            candidates: candidates.map { c in
                GUIAutomationServer.SSHListCandidate(
                    target: c.target,
                    hostname: c.hostname
                )
            }
        )
        return .success(response)
    }

    nonisolated private func handleSSHSearch(
        queries: [String],
        profile: String?
    ) -> Result<GUIAutomationServer.SSHSearchResponse, AutomationError> {
        Self.runOnMain {
            self.searchSSH(queries: queries, profile: profile)
        }
    }

    @MainActor
    private func searchSSH(
        queries: [String],
        profile: String?
    ) -> Result<GUIAutomationServer.SSHSearchResponse, AutomationError> {
        // Synchronously load ssh_config without history
        let configHosts: [SSHConfigHost]
        do {
            configHosts = try SSHConfigHosts.load(from: SSHConfigHosts.defaultURL).hosts
        } catch {
            configHosts = []
        }

        // Check if any query contains glob meta characters
        let hasGlob = queries.contains { $0.contains(where: { SSHGlobMatcher.metaCharacters.contains($0) }) }

        var matchedCandidates: [SSHCandidate]
        if hasGlob {
            matchedCandidates = []
            for query in queries {
                guard let patterns = SSHGlobMatcher.parse(query) else { continue }
                for host in configHosts {
                    let candidate = SSHCandidate(target: host.alias, hostname: host.hostname, isAdHoc: false)
                    if SSHGlobMatcher.match(text: candidate.target, patterns: patterns) != nil {
                        if !matchedCandidates.contains(where: { $0.target == candidate.target }) {
                            matchedCandidates.append(candidate)
                        }
                    }
                }
            }
        } else {
            // Exact match
            matchedCandidates = []
            for query in queries {
                if let host = configHosts.first(where: { $0.alias == query }) {
                    let candidate = SSHCandidate(target: host.alias, hostname: host.hostname, isAdHoc: false)
                    if !matchedCandidates.contains(where: { $0.target == candidate.target }) {
                        matchedCandidates.append(candidate)
                    }
                }
            }
        }

        let launcher = createSSHLauncher(sshConfigHosts: configHosts)
        let matches = matchedCandidates.map { candidate in
            let resolution = launcher.resolve(candidate: candidate)
            let template = profile ?? resolution.templateID
            return GUIAutomationServer.SSHSearchMatch(
                target: candidate.target,
                template: template,
                variables: resolution.variables
            )
        }

        return .success(GUIAutomationServer.SSHSearchResponse(matches: matches))
    }

    nonisolated private func handleSSHBatch(
        targets: [String],
        profile: String?,
        overrides: [String]?
    ) -> Result<GUIAutomationServer.SSHBatchResponse, AutomationError> {
        Self.runOnMain {
            self.batchSSH(targets: targets, profile: profile, overrides: overrides)
        }
    }

    @MainActor
    private func batchSSH(
        targets: [String],
        profile: String?,
        overrides: [String]?
    ) -> Result<GUIAutomationServer.SSHBatchResponse, AutomationError> {
        // Synchronously load ssh_config without history
        let configHosts: [SSHConfigHost]
        do {
            configHosts = try SSHConfigHosts.load(from: SSHConfigHosts.defaultURL).hosts
        } catch {
            configHosts = []
        }

        let launcher = createSSHLauncher(sshConfigHosts: configHosts)

        // Resolve all targets
        var resolutions: [SSHResolution] = []
        for target in targets {
            let candidate: SSHCandidate
            if let host = configHosts.first(where: { $0.alias == target }) {
                candidate = SSHCandidate(target: host.alias, hostname: host.hostname, isAdHoc: false)
            } else {
                candidate = SSHCandidate(target: target, hostname: nil, isAdHoc: true)
            }
            let resolution = launcher.resolve(candidate: candidate)
            let finalResolution = SSHResolution(
                candidate: resolution.candidate,
                target: resolution.target,
                templateID: profile ?? resolution.templateID,
                variables: resolution.variables
            )
            resolutions.append(finalResolution)
        }

        // Validate batch
        switch launcher.validateBatch(resolutions: resolutions) {
        case .failure(let failure):
            return .failure(.invalidParams("\(failure.target): \(failure.error.localizedDescription)"))
        case .success(let resolved):
            let requests = resolved.map { resolution in
                SessionManager.GridPaneRequest(
                    profileID: resolution.templateID,
                    variables: resolution.variables
                )
            }

            guard let manager = SessionManagerRegistry.shared.primaryManager else {
                return .failure(.internal("no SessionManager available"))
            }

            guard let tabID = manager.createTabWithGridPanes(requests: requests) else {
                return .failure(.internal("failed to create tab with grid panes"))
            }

            // Build ref for the new tab
            let snapshots = Self.collectSnapshots()
            refStore.refreshRefs(snapshots: snapshots)
            guard let tabRef = refStore.tabRef(sessionID: manager.activeSession?.id ?? tabID, tabID: tabID) else {
                return .failure(.internal("ref allocation failed for new tab"))
            }

            // Do NOT record history

            return .success(GUIAutomationServer.SSHBatchResponse(
                tabRef: tabRef,
                paneCount: requests.count
            ))
        }
    }

    @MainActor
    private func createSSHLauncher(sshConfigHosts: [SSHConfigHost] = []) -> SSHLauncher {
        let matcher: SSHRuleMatcher
        do {
            matcher = try SSHRuleMatcher.load(from: ConfigLoader.sshRulesPath())
        } catch {
            matcher = SSHRuleMatcher()
        }
        return SSHLauncher(
            matcher: matcher,
            sshConfigHosts: sshConfigHosts,
            validateProfile: { [weak self] id, variables in
                guard self != nil else { return }
                guard let manager = SessionManagerRegistry.shared.primaryManager else { return }
                _ = Self.validateProfile(manager: manager, id: id, overrides: [])
            },
            spawn: { _, _, _ in nil }
        )
    }

    // MARK: - MainActor operations

    private func createLocalSessionOnMain(name: String?) -> Result<SessionCreateResponse, AutomationError> {
        GUILog.debug("createLocalSessionOnMain ENTER name=\(name ?? "<nil>") appActive=\(NSApp.isActive) keyWin=\(NSApp.keyWindow?.title ?? "<none>")", category: .session)
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
        GUILog.debug("createLocalSessionOnMain EXIT ref=\(ref) appActive=\(NSApp.isActive) keyWin=\(NSApp.keyWindow?.title ?? "<none>")", category: .session)
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
        // When the caller opted into view focus, jump to the attached
        // session so they can start working in it. Otherwise leave the
        // user's active view alone.
        if GUIAutomationPolicy.shouldTakeViewFocus(),
           let idx = manager.sessions.firstIndex(where: { $0.id == target.sessionID }),
           idx != manager.activeSessionIndex {
            manager.selectSession(at: idx)
        }
        return .success(())
    }

    private func detachSessionOnMain(ref: String) -> Result<Void, AutomationError> {
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
        // Not in the focus whitelist — must not activate the window.
        if let serverSessionID = session.source.serverSessionID {
            manager.detachRemoteSession(serverSessionID: serverSessionID)
        } else {
            manager.detachLocalSession(sessionID: session.id)
        }
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
        let profile: String?
        let overrides: [String]
    }

    /// Parse/resolve the ref and, for local sessions, perform the tab
    /// create inline. For remote sessions, fall through to the caller so
    /// it can dispatch a blocking wait without holding the main actor.
    ///
    /// `profile` / `overrides` are validated here (unknown profile →
    /// `PROFILE_NOT_FOUND`, malformed override → `INVALID_PARAMS`) for both
    /// local *and* remote sessions; Phase 7.3 introduced client-side
    /// resolution so the daemon never sees the profile name, only the
    /// resolved `StartupSnapshot`.
    private func resolveTabCreateTarget(
        ref: String,
        profile: String?,
        overrides: [String]?
    ) -> Result<TabCreateDecision, AutomationError> {
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

        // Pre-flight the profile (for both local and remote) so callers
        // get PROFILE_NOT_FOUND / INVALID_PARAMS *before* the create call,
        // which would otherwise silently rewrite an unknown profile to
        // `default`. For remote sessions this also means we never ship a
        // bad profile name over the wire.
        if let profile = profile {
            if let err = Self.validateProfile(
                manager: manager, id: profile, overrides: overrides ?? []
            ) {
                return .failure(err)
            }
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
                originalRef: ref,
                sessionID: target.sessionID,
                profile: profile,
                overrides: overrides ?? []
            )))
        }

        guard let newTabID = manager.createTab(
            inSessionID: target.sessionID,
            profileID: profile,
            overrides: overrides ?? []
        ) else {
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
        let profile: String?
        let overrides: [String]
    }

    /// Parse/resolve the ref and pick the target pane. For local sessions,
    /// run the split inline. For remote, package the request so the caller
    /// can block-wait on the server's layoutUpdate.
    private func resolvePaneSplitTarget(
        ref: String,
        direction: SplitDirection,
        profile: String?,
        overrides: [String]?
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

        if let profile = profile {
            if let err = Self.validateProfile(
                manager: manager, id: profile, overrides: overrides ?? []
            ) {
                return .failure(err)
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
                direction: direction,
                profile: profile,
                overrides: overrides ?? []
            )))
        }

        guard let newPaneID = manager.splitPane(
            inSessionID: target.sessionID,
            parentPaneID: paneID,
            direction: direction,
            profileID: profile,
            overrides: overrides ?? []
        ) else {
            return .success(.failed(.paneNotFound(ref)))
        }
        let postSnapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: postSnapshots)
        guard let newRef = refStore.paneRef(sessionID: target.sessionID, paneID: newPaneID) else {
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
            GUIAutomationPolicy.activateIfAllowed(command: .paneFocus)
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

    /// Outcome of `resolveFloatCreateTarget` — either the operation fully
    /// completed locally, or a remote request is ready to dispatch.
    private enum FloatCreateDecision {
        case local(FloatPaneCreateResponse)
        case remote(RemoteFloatCreateRequest)
        case failed(AutomationError)
    }

    /// Parameters threaded to the connection-thread blocking waiter.
    private struct RemoteFloatCreateRequest {
        let originalRef: String
        let sessionID: UUID
        let profile: String?
        let overrides: [String]
    }

    /// Parse/resolve the session ref and, for local sessions, create the
    /// float inline. Remote sessions fall through so the caller can block-
    /// wait on the server's layoutUpdate without holding the main actor.
    private func resolveFloatCreateTarget(
        ref: String,
        profile: String?,
        overrides: [String]?
    ) -> Result<FloatCreateDecision, AutomationError> {
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
            return .failure(.invalidParams("floatPane.create requires a session ref"))
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

        if let profile = profile {
            if let err = Self.validateProfile(
                manager: manager, id: profile, overrides: overrides ?? []
            ) {
                return .failure(err)
            }
        }

        if session.source.serverSessionID != nil {
            if let serverID = session.source.serverSessionID,
               !manager.attachedRemoteSessionIDs.contains(serverID) {
                return .failure(.unsupportedOperation(
                    "session is detached; attach it first with 'tongyou app attach'"
                ))
            }
            return .success(.remote(RemoteFloatCreateRequest(
                originalRef: ref,
                sessionID: target.sessionID,
                profile: profile,
                overrides: overrides ?? []
            )))
        }

        // Local: createFloatingPane operates on the active session — make
        // sure the target session is active so the new float lands in the
        // right tab. If the automation caller didn't ask to take view focus,
        // restore the previous active index once the float is in place so
        // the user's current view stays put.
        let prevActiveIndex = manager.activeSessionIndex
        if let idx = manager.sessions.firstIndex(where: { $0.id == target.sessionID }),
           idx != manager.activeSessionIndex {
            manager.selectSession(at: idx)
        }
        guard let newPaneID = manager.createFloatingPane(
            profileID: profile,
            overrides: overrides ?? []
        ) else {
            return .success(.failed(.internal("floatPane.create failed")))
        }
        if !GUIAutomationPolicy.shouldTakeViewFocus(),
           manager.activeSessionIndex != prevActiveIndex {
            manager.selectSession(at: prevActiveIndex)
        }
        let postSnapshots = Self.collectSnapshots()
        refStore.refreshRefs(snapshots: postSnapshots)
        guard let newRef = refStore.floatRef(sessionID: target.sessionID, floatID: newPaneID) else {
            return .success(.failed(.internal("ref allocation failed for new float pane")))
        }
        return .success(.local(FloatPaneCreateResponse(ref: newRef)))
    }

    private func floatPaneFocusOnMain(ref: String) -> Result<Void, AutomationError> {
        switch resolveFloatTarget(ref: ref) {
        case .failure(let err): return .failure(err)
        case .success(let (manager, sessionID, paneID, tabID)):
            // Bring the owning session / tab forward so the float is on-screen.
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
            // Raise the z-index so this float renders above any peers.
            manager.bringFloatingPaneToFront(paneID: paneID)
            manager.onFocusPaneRequest?(paneID)
            manager.notifyPaneFocused(paneID)
            GUIAutomationPolicy.activateIfAllowed(command: .floatPaneFocus)
            return .success(())
        }
    }

    private func floatPaneCloseOnMain(ref: String) -> Result<Void, AutomationError> {
        switch resolveFloatTarget(ref: ref) {
        case .failure(let err): return .failure(err)
        case .success(let (manager, _, paneID, _)):
            guard manager.closeFloatingPane(paneID: paneID) else {
                return .failure(.paneNotFound(ref))
            }
            return .success(())
        }
    }

    private func floatPanePinOnMain(ref: String) -> Result<Void, AutomationError> {
        switch resolveFloatTarget(ref: ref) {
        case .failure(let err): return .failure(err)
        case .success(let (manager, sessionID, paneID, _)):
            // `toggleFloatingPanePin` only touches the *active* session's
            // floats. Make the owning session active first so the toggle
            // lands on the right float; restore the user's view afterwards
            // if the caller isn't asking to take focus.
            let prevActiveIndex = manager.activeSessionIndex
            if let idx = manager.sessions.firstIndex(where: { $0.id == sessionID }),
               idx != manager.activeSessionIndex {
                manager.selectSession(at: idx)
            }
            manager.toggleFloatingPanePin(paneID: paneID)
            if !GUIAutomationPolicy.shouldTakeViewFocus(),
               manager.activeSessionIndex != prevActiveIndex {
                manager.selectSession(at: prevActiveIndex)
            }
            return .success(())
        }
    }

    private func floatPaneMoveOnMain(
        ref: String,
        frame: FloatPaneFrame
    ) -> Result<Void, AutomationError> {
        switch resolveFloatTarget(ref: ref) {
        case .failure(let err): return .failure(err)
        case .success(let (manager, sessionID, paneID, _)):
            // `updateFloatingPaneFrame` operates on the active session only.
            // Same save/restore as `floatPanePinOnMain`.
            let prevActiveIndex = manager.activeSessionIndex
            if let idx = manager.sessions.firstIndex(where: { $0.id == sessionID }),
               idx != manager.activeSessionIndex {
                manager.selectSession(at: idx)
            }
            let cgFrame = CGRect(
                x: CGFloat(frame.x),
                y: CGFloat(frame.y),
                width: CGFloat(frame.width),
                height: CGFloat(frame.height)
            )
            manager.updateFloatingPaneFrame(paneID: paneID, frame: cgFrame)
            if !GUIAutomationPolicy.shouldTakeViewFocus(),
               manager.activeSessionIndex != prevActiveIndex {
                manager.selectSession(at: prevActiveIndex)
            }
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

    /// Resolve a float-only ref to `(manager, sessionID, paneID, tabID)`.
    /// `paneID` is the inner TerminalPane UUID — the identifier used by
    /// `SessionManager.closeFloatingPane(paneID:)` and friends. Rejects
    /// session/tab/tree-pane refs.
    private func resolveFloatTarget(
        ref: String
    ) -> Result<(SessionManager, UUID, UUID, UUID?), AutomationError> {
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
        guard case .float = parsed else {
            return .failure(.invalidParams("expected a float ref like 'session/float:N'"))
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
        guard let paneID = target.floatID else {
            return .failure(.floatNotFound(ref))
        }
        // Block float operations on detached remote sessions — the daemon
        // owns the authoritative state, and local mutations would be
        // discarded on the next layoutUpdate.
        if let session = manager.sessions.first(where: { $0.id == target.sessionID }),
           let serverID = session.source.serverSessionID,
           !manager.attachedRemoteSessionIDs.contains(serverID) {
            return .failure(.unsupportedOperation(
                "session is detached; attach it first with 'tongyou app attach'"
            ))
        }
        return .success((manager, target.sessionID, paneID, target.tabID))
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
    nonisolated private func createRemoteSessionBlocking(name: String?, focus: Bool) -> Result<SessionCreateResponse, AutomationError> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<SessionCreateResponse>()

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GUIAutomationPolicy.withAutomationRequest(command: .sessionCreate, viewFocus: focus) {
                    self.startRemoteCreate(name: name, box: box, signal: { semaphore.signal() })
                }
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
        // Thread the caller's view-focus preference through to
        // `handleRemoteSessionCreated` so it knows whether to switch
        // `activeSessionIndex` when the daemon confirms the session.
        let takeFocus = GUIAutomationPolicy.shouldTakeViewFocus()
        manager.createRemoteSession(name: name, takeViewFocus: takeFocus) { [weak self] localID in
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
        request: RemoteTabCreateRequest,
        focus: Bool
    ) -> Result<TabCreateResponse, AutomationError> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<TabCreateResponse>()

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GUIAutomationPolicy.withAutomationRequest(command: .tabCreate, viewFocus: focus) {
                    self.startRemoteTabCreate(request: request, box: box, signal: { semaphore.signal() })
                }
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
        _ = manager.createTab(
            inSessionID: sessionID,
            profileID: request.profile,
            overrides: request.overrides
        )
    }

    nonisolated private func splitRemotePaneBlocking(
        request: RemotePaneSplitRequest,
        focus: Bool
    ) -> Result<PaneSplitResponse, AutomationError> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<PaneSplitResponse>()

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GUIAutomationPolicy.withAutomationRequest(command: .paneSplit, viewFocus: focus) {
                    self.startRemotePaneSplit(request: request, box: box, signal: { semaphore.signal() })
                }
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
        // Remote path: SessionManager.splitPane returns nil immediately
        // after dispatching the RPC. The actual new pane id arrives via
        // `onNextRemotePaneCreated` above.
        _ = manager.splitPane(
            inSessionID: sessionID,
            parentPaneID: request.paneID,
            direction: request.direction,
            profileID: request.profile,
            overrides: request.overrides
        )
    }

    // MARK: - Remote floatPane.create: blocking wait

    nonisolated private func createRemoteFloatBlocking(
        request: RemoteFloatCreateRequest,
        focus: Bool
    ) -> Result<FloatPaneCreateResponse, AutomationError> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<FloatPaneCreateResponse>()

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GUIAutomationPolicy.withAutomationRequest(command: .floatPaneCreate, viewFocus: focus) {
                    self.startRemoteFloatCreate(request: request, box: box, signal: { semaphore.signal() })
                }
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + Self.blockingWaitTimeout)
        if waitResult == .timedOut { return .failure(.mainThreadTimeout) }
        if let success = box.success { return .success(success) }
        if let error = box.error { return .failure(error) }
        return .failure(.internal("remote floatPane.create completed with no result"))
    }

    private func startRemoteFloatCreate(
        request: RemoteFloatCreateRequest,
        box: ResultBox<FloatPaneCreateResponse>,
        signal: @escaping @Sendable () -> Void
    ) {
        guard let manager = SessionManagerRegistry.shared.manager(owning: request.sessionID) else {
            box.error = .sessionNotFound(request.originalRef)
            signal()
            return
        }
        let sessionID = request.sessionID
        manager.onNextRemoteFloatCreated(inSessionID: sessionID) { [weak self] newFloatPaneID in
            guard let self else {
                box.error = .internal("GUIAutomationService deallocated")
                signal()
                return
            }
            guard let newFloatPaneID else {
                box.error = .internal("remote floatPane.create failed or connection dropped")
                signal()
                return
            }
            let snapshots = Self.collectSnapshots()
            self.refStore.refreshRefs(snapshots: snapshots)
            if let ref = self.refStore.floatRef(sessionID: sessionID, floatID: newFloatPaneID) {
                box.success = FloatPaneCreateResponse(ref: ref)
            } else {
                box.error = .internal("ref allocation failed for new float pane")
            }
            signal()
        }
        // `createFloatingPane` on a remote session sends the RPC to the
        // daemon; the local state mutates only when the layoutUpdate
        // arrives and our listener above fires. Save/restore active index
        // so non-focus callers don't see their view jump.
        let prevActiveIndex = manager.activeSessionIndex
        if let idx = manager.sessions.firstIndex(where: { $0.id == sessionID }),
           idx != manager.activeSessionIndex {
            manager.selectSession(at: idx)
        }
        _ = manager.createFloatingPane(
            profileID: request.profile,
            overrides: request.overrides
        )
        if !GUIAutomationPolicy.shouldTakeViewFocus(),
           manager.activeSessionIndex != prevActiveIndex {
            manager.selectSession(at: prevActiveIndex)
        }
    }

}

/// Mutable result slot shared between the connection thread (waiter) and
/// the MainActor (producer). Access is serialized by the semaphore: the
/// main-actor closure writes before signalling; the waiter reads after.
nonisolated private final class ResultBox<Value>: @unchecked Sendable {
    nonisolated(unsafe) var success: Value?
    nonisolated(unsafe) var error: AutomationError?
}
