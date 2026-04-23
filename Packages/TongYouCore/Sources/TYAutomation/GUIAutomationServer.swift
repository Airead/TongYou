#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import Foundation
import TYProtocol
import TYServer
import TYTerminal

/// Errors raised during server startup.
public enum GUIAutomationServerError: Error {
    case alreadyRunning
    case socketBindFailed(underlying: Error)
    case tokenGenerationFailed(underlying: Error)
    case runtimeDirectorySetupFailed(underlying: Error)
}

/// JSON-line Unix-socket server used by the GUI app to expose script
/// automation commands. Mirrors the daemon's three-layer security:
/// file perms (0700 dir / 0600 sock+token), `getpeereid()` UID check,
/// and token-based handshake.
public final class GUIAutomationServer: @unchecked Sendable {

    /// Runtime configuration for the server.
    public struct Configuration: Sendable {
        public let socketPath: String
        public let tokenPath: String
        public let allowedPeerUID: uid_t
        /// Produces the current session list. The closure runs on the
        /// connection's handler queue (not main); callers that touch
        /// main-actor state (e.g. `SessionManager`) must hop to MainActor
        /// themselves. If nil, `session.list` returns an empty result —
        /// useful for tests that don't exercise the GUI path.
        public let handleSessionList: (@Sendable () -> SessionListResponse)?
        /// Creates a session of the given type, returning the allocated ref.
        /// The third parameter is the caller's view-focus preference
        /// (Phase 7): when true, the GUI switches its active session to the
        /// newly created one; when false (default), the user's current view
        /// stays put. Not focus-whitelisted at the app level regardless.
        public let handleSessionCreate: (@Sendable (String?, AutomationSessionType, Bool) -> Result<SessionCreateResponse, AutomationError>)?
        /// Closes the session named by the ref. Not focus-whitelisted.
        public let handleSessionClose: (@Sendable (String) -> Result<Void, AutomationError>)?
        /// Attaches a detached remote session by ref. Local sessions must
        /// return `.unsupportedOperation`. Not focus-whitelisted at the
        /// app level; the second `Bool` parameter is the caller's view-
        /// focus preference (switch to the attached session on success).
        public let handleSessionAttach: (@Sendable (String, Bool) -> Result<Void, AutomationError>)?
        /// Detaches an attached session by ref. Works for both local and
        /// remote sessions — the session remains in the sidebar but stops
        /// rendering / receiving input. Not focus-whitelisted.
        public let handleSessionDetach: (@Sendable (String) -> Result<Void, AutomationError>)?
        /// Writes raw UTF-8 text to the pane resolved from `ref`. Ref may
        /// refer to a session (→ focused pane), tab (→ focused pane), pane,
        /// or float. Not focus-whitelisted — must not activate the window.
        public let handlePaneSendText: (@Sendable (String, String) -> Result<Void, AutomationError>)?
        /// Sends a parsed key input (already run through `AutomationKeySpec`)
        /// to the pane resolved from `ref`. Not focus-whitelisted.
        public let handlePaneSendKey: (@Sendable (String, KeyEncoder.KeyInput) -> Result<Void, AutomationError>)?
        /// Displays a system notification from the pane resolved from `ref`.
        /// Not focus-whitelisted — must not activate the window.
        /// The fourth parameter is `noNotifyIfVisible`: when true, the
        /// implementation should skip the macOS notification if the target
        /// pane's tab is currently visible.
        public let handlePaneNotify: (@Sendable (String, String, String?, Bool) -> Result<Void, AutomationError>)?
        /// Creates a new tab in the session resolved from `ref`. Returns the
        /// newly allocated tab ref. Not focus-whitelisted at the app level;
        /// the second `Bool` parameter is the caller's view-focus preference
        /// (switch the session's active tab to the new one on success).
        /// The trailing `profile` / `overrides` parameters carry the Phase 5
        /// automation fields: `profile` picks the starting profile for the
        /// tab's root pane (nil means inherit / default); `overrides` is a
        /// list of `"key = value"` lines applied on top of the profile.
        public let handleTabCreate: (@Sendable (String, Bool, String?, [String]?) -> Result<TabCreateResponse, AutomationError>)?
        /// Selects (makes active) the tab resolved from `ref`. Not focus-whitelisted.
        public let handleTabSelect: (@Sendable (String) -> Result<Void, AutomationError>)?
        /// Closes the tab resolved from `ref`. Not focus-whitelisted.
        public let handleTabClose: (@Sendable (String) -> Result<Void, AutomationError>)?
        /// Splits the pane resolved from `ref` in the given direction. Returns
        /// the newly allocated pane ref. Not focus-whitelisted at the app
        /// level; the third `Bool` parameter is the caller's view-focus
        /// preference (focus the new pane on success).
        /// The trailing `profile` / `overrides` parameters carry the Phase 5
        /// automation fields (see `handleTabCreate`).
        public let handlePaneSplit: (@Sendable (String, SplitDirection, Bool, String?, [String]?) -> Result<PaneSplitResponse, AutomationError>)?
        /// Focuses the pane resolved from `ref`. Focus-whitelisted —
        /// implementations bring the GUI to the foreground on success.
        public let handlePaneFocus: (@Sendable (String) -> Result<Void, AutomationError>)?
        /// Closes the pane resolved from `ref`. Not focus-whitelisted.
        public let handlePaneClose: (@Sendable (String) -> Result<Void, AutomationError>)?
        /// Resizes the pane resolved from `ref` by updating the split ratio
        /// at its parent split. `ratio` is a value in `(0.0, 1.0)`. Not
        /// focus-whitelisted.
        public let handlePaneResize: (@Sendable (String, Double) -> Result<Void, AutomationError>)?
        /// Creates a new floating pane in the session resolved from `ref`.
        /// The session ref determines which tab hosts the new float (server
        /// uses the active tab). Returns the newly allocated float ref.
        /// Not focus-whitelisted at the app level; the second `Bool`
        /// parameter is the caller's view-focus preference (switch the
        /// active session to the new float's session on success).
        /// The trailing `profile` / `overrides` parameters carry the Phase 5
        /// automation fields (see `handleTabCreate`).
        public let handleFloatPaneCreate: (@Sendable (String, Bool, String?, [String]?) -> Result<FloatPaneCreateResponse, AutomationError>)?
        /// Focuses the floating pane resolved from `ref`. Focus-whitelisted —
        /// implementations bring the GUI to the foreground on success.
        public let handleFloatPaneFocus: (@Sendable (String) -> Result<Void, AutomationError>)?
        /// Closes the floating pane resolved from `ref`. Not focus-whitelisted.
        public let handleFloatPaneClose: (@Sendable (String) -> Result<Void, AutomationError>)?
        /// Toggles the `isPinned` state on the floating pane resolved from
        /// `ref`. Not focus-whitelisted.
        public let handleFloatPanePin: (@Sendable (String) -> Result<Void, AutomationError>)?
        /// Moves / resizes the floating pane resolved from `ref`. Frame uses
        /// normalized (0–1) coordinates. Not focus-whitelisted.
        public let handleFloatPaneMove: (@Sendable (String, FloatPaneFrame) -> Result<Void, AutomationError>)?
        /// Brings the GUI to the foreground without mutating focus.
        /// Focus-whitelisted.
        public let handleWindowFocus: (@Sendable () -> Result<Void, AutomationError>)?
        /// Lists available SSH servers from ssh_config (no history).
        public let handleSSHList: (@Sendable () -> Result<SSHListResponse, AutomationError>)?
        /// Searches SSH servers with glob queries (no history).
        public let handleSSHSearch: (@Sendable ([String], String?) -> Result<SSHSearchResponse, AutomationError>)?
        /// Opens SSH connections for the given targets (no history).
        public let handleSSHBatch: (@Sendable ([String], String?, [String]?) -> Result<SSHBatchResponse, AutomationError>)?

        public init(
            socketPath: String = GUIAutomationPaths.socketPath(),
            tokenPath: String = GUIAutomationPaths.tokenPath(),
            allowedPeerUID: uid_t = getuid(),
            handleSessionList: (@Sendable () -> SessionListResponse)? = nil,
            handleSessionCreate: (@Sendable (String?, AutomationSessionType, Bool) -> Result<SessionCreateResponse, AutomationError>)? = nil,
            handleSessionClose: (@Sendable (String) -> Result<Void, AutomationError>)? = nil,
            handleSessionAttach: (@Sendable (String, Bool) -> Result<Void, AutomationError>)? = nil,
            handleSessionDetach: (@Sendable (String) -> Result<Void, AutomationError>)? = nil,
            handlePaneSendText: (@Sendable (String, String) -> Result<Void, AutomationError>)? = nil,
            handlePaneSendKey: (@Sendable (String, KeyEncoder.KeyInput) -> Result<Void, AutomationError>)? = nil,
            handlePaneNotify: (@Sendable (String, String, String?, Bool) -> Result<Void, AutomationError>)? = nil,
            handleTabCreate: (@Sendable (String, Bool, String?, [String]?) -> Result<TabCreateResponse, AutomationError>)? = nil,
            handleTabSelect: (@Sendable (String) -> Result<Void, AutomationError>)? = nil,
            handleTabClose: (@Sendable (String) -> Result<Void, AutomationError>)? = nil,
            handlePaneSplit: (@Sendable (String, SplitDirection, Bool, String?, [String]?) -> Result<PaneSplitResponse, AutomationError>)? = nil,
            handlePaneFocus: (@Sendable (String) -> Result<Void, AutomationError>)? = nil,
            handlePaneClose: (@Sendable (String) -> Result<Void, AutomationError>)? = nil,
            handlePaneResize: (@Sendable (String, Double) -> Result<Void, AutomationError>)? = nil,
            handleFloatPaneCreate: (@Sendable (String, Bool, String?, [String]?) -> Result<FloatPaneCreateResponse, AutomationError>)? = nil,
            handleFloatPaneFocus: (@Sendable (String) -> Result<Void, AutomationError>)? = nil,
            handleFloatPaneClose: (@Sendable (String) -> Result<Void, AutomationError>)? = nil,
            handleFloatPanePin: (@Sendable (String) -> Result<Void, AutomationError>)? = nil,
            handleFloatPaneMove: (@Sendable (String, FloatPaneFrame) -> Result<Void, AutomationError>)? = nil,
            handleWindowFocus: (@Sendable () -> Result<Void, AutomationError>)? = nil,
            handleSSHList: (@Sendable () -> Result<SSHListResponse, AutomationError>)? = nil,
            handleSSHSearch: (@Sendable ([String], String?) -> Result<SSHSearchResponse, AutomationError>)? = nil,
            handleSSHBatch: (@Sendable ([String], String?, [String]?) -> Result<SSHBatchResponse, AutomationError>)? = nil
        ) {
            self.socketPath = socketPath
            self.tokenPath = tokenPath
            self.allowedPeerUID = allowedPeerUID
            self.handleSessionList = handleSessionList
            self.handleSessionCreate = handleSessionCreate
            self.handleSessionClose = handleSessionClose
            self.handleSessionAttach = handleSessionAttach
            self.handleSessionDetach = handleSessionDetach
            self.handlePaneSendText = handlePaneSendText
            self.handlePaneSendKey = handlePaneSendKey
            self.handlePaneNotify = handlePaneNotify
            self.handleTabCreate = handleTabCreate
            self.handleTabSelect = handleTabSelect
            self.handleTabClose = handleTabClose
            self.handlePaneSplit = handlePaneSplit
            self.handlePaneFocus = handlePaneFocus
            self.handlePaneClose = handlePaneClose
            self.handlePaneResize = handlePaneResize
            self.handleFloatPaneCreate = handleFloatPaneCreate
            self.handleFloatPaneFocus = handleFloatPaneFocus
            self.handleFloatPaneClose = handleFloatPaneClose
            self.handleFloatPanePin = handleFloatPanePin
            self.handleFloatPaneMove = handleFloatPaneMove
            self.handleWindowFocus = handleWindowFocus
            self.handleSSHList = handleSSHList
            self.handleSSHSearch = handleSSHSearch
            self.handleSSHBatch = handleSSHBatch
        }
    }

    private let config: Configuration
    private let stateLock = NSLock()
    private var listener: TYSocket?
    private var token: String = ""
    private var running = false

    private let acceptQueue = DispatchQueue(
        label: "io.github.airead.tongyou.automation.accept"
    )

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
    }

    // MARK: - Lifecycle

    /// Start the server: ensure runtime dir, generate token, bind socket,
    /// and spawn the accept loop.
    public func start() throws {
        stateLock.lock()
        if running {
            stateLock.unlock()
            throw GUIAutomationServerError.alreadyRunning
        }
        stateLock.unlock()

        do {
            try GUIAutomationPaths.ensureRuntimeDirectory()
        } catch {
            throw GUIAutomationServerError.runtimeDirectorySetupFailed(underlying: error)
        }

        // Sweep gui-*.sock / gui-*.token left over from prior GUI runs
        // that exited without applicationWillTerminate firing (crash,
        // Xcode Stop, SIGKILL). Runs after ensureRuntimeDirectory so
        // the directory exists, and before we create our own artifacts.
        let swept = GUIAutomationPaths.sweepStaleArtifacts()
        if !swept.isEmpty {
            Log.info("GUI automation: removed \(swept.count) stale artifact(s) from prior runs")
        }

        let generatedToken: String
        do {
            generatedToken = try GUIAutomationAuth.generate(tokenPath: config.tokenPath)
        } catch {
            throw GUIAutomationServerError.tokenGenerationFailed(underlying: error)
        }

        let listener: TYSocket
        do {
            // TYSocket.listen() unlinks stale file, binds, chmods 0600, listens.
            listener = try TYSocket.listen(path: config.socketPath)
        } catch {
            GUIAutomationAuth.remove(tokenPath: config.tokenPath)
            throw GUIAutomationServerError.socketBindFailed(underlying: error)
        }

        stateLock.lock()
        self.listener = listener
        self.token = generatedToken
        self.running = true
        stateLock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }

        Log.info("GUI automation server listening at \(config.socketPath)")
    }

    /// Stop the server: close the listener, remove socket/token files.
    public func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        let listenerToClose = listener
        listener = nil
        token = ""
        stateLock.unlock()

        listenerToClose?.closeSocket()

        // Remove socket file (unlink; TYSocket.listen doesn't auto-clean on close).
        try? FileManager.default.removeItem(atPath: config.socketPath)
        GUIAutomationAuth.remove(tokenPath: config.tokenPath)

        if wasRunning {
            Log.info("GUI automation server stopped")
        }
    }

    // MARK: - Accept Loop

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let stillRunning = running
            let activeListener = listener
            stateLock.unlock()
            guard stillRunning, let activeListener else { return }

            let client: TYSocket
            do {
                client = try activeListener.accept()
            } catch {
                // `accept()` returns an error when we close the listener fd.
                stateLock.lock()
                let shouldExit = !running
                stateLock.unlock()
                if shouldExit { return }
                Log.warning("GUI automation accept failed: \(error)")
                continue
            }

            // Layer 2: peer credential check.
            do {
                let peer = try client.peerCredentials()
                if peer.uid != config.allowedPeerUID {
                    Log.warning(
                        "GUI automation: rejecting connection from uid=\(peer.uid) (expected \(config.allowedPeerUID))"
                    )
                    client.closeSocket()
                    continue
                }
            } catch {
                Log.warning("GUI automation: peer credential check failed: \(error)")
                client.closeSocket()
                continue
            }

            let expectedToken = currentToken()
            let cfg = config
            let connQueue = DispatchQueue(
                label: "io.github.airead.tongyou.automation.conn"
            )
            connQueue.async {
                GUIAutomationServer.handleConnection(client, expectedToken: expectedToken, config: cfg)
            }
        }
    }

    private func currentToken() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return token
    }

    // MARK: - Connection Handler

    private enum ConnectionState {
        case awaitingHandshake
        case authenticated
    }

    private static func handleConnection(
        _ socket: TYSocket,
        expectedToken: String,
        config: Configuration
    ) {
        defer { socket.closeSocket() }

        let io = LineIO(fd: socket.fileDescriptor)
        var state: ConnectionState = .awaitingHandshake

        while true {
            let line: String?
            do {
                line = try io.readLine()
            } catch {
                return
            }
            guard let rawLine = line else { return }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let request: ParsedRequest
            switch parseRequest(trimmed) {
            case .success(let req):
                request = req
            case .failure:
                tryWrite(io: io, errorCode: "INVALID_REQUEST", message: "malformed JSON request")
                continue
            }

            switch state {
            case .awaitingHandshake:
                guard request.cmd == "handshake" else {
                    tryWrite(io: io, errorCode: "UNAUTHENTICATED", message: "handshake required")
                    return
                }
                guard let token = request.token, token == expectedToken, !expectedToken.isEmpty else {
                    tryWrite(io: io, errorCode: "UNAUTHENTICATED", message: "invalid token")
                    return
                }
                state = .authenticated
                tryWrite(io: io, success: .string("ok"))

            case .authenticated:
                let response = dispatch(request: request, config: config)
                tryWrite(io: io, response: response)
            }
        }
    }

    private static func dispatch(request: ParsedRequest, config: Configuration) -> JSONResponse {
        switch request.cmd {
        case "handshake":
            // Idempotent: already authenticated.
            return .success(.string("ok"))
        case "server.ping":
            return .success(.string("pong"))
        case "session.list":
            return handleSessionListCommand(config: config)
        case "session.create":
            return handleSessionCreateCommand(request: request, config: config)
        case "session.close":
            return handleSessionCloseCommand(request: request, config: config)
        case "session.attach":
            return handleSessionAttachCommand(request: request, config: config)
        case "session.detach":
            return handleSessionDetachCommand(request: request, config: config)
        case "pane.sendText":
            return handlePaneSendTextCommand(request: request, config: config)
        case "pane.sendKey":
            return handlePaneSendKeyCommand(request: request, config: config)
        case "pane.notify":
            return handlePaneNotifyCommand(request: request, config: config)
        case "tab.create":
            return handleTabCreateCommand(request: request, config: config)
        case "tab.select":
            return handleTabSelectCommand(request: request, config: config)
        case "tab.close":
            return handleTabCloseCommand(request: request, config: config)
        case "pane.split":
            return handlePaneSplitCommand(request: request, config: config)
        case "pane.focus":
            return handlePaneFocusCommand(request: request, config: config)
        case "pane.close":
            return handlePaneCloseCommand(request: request, config: config)
        case "pane.resize":
            return handlePaneResizeCommand(request: request, config: config)
        case "floatPane.create":
            return handleFloatPaneCreateCommand(request: request, config: config)
        case "floatPane.focus":
            return handleFloatPaneFocusCommand(request: request, config: config)
        case "floatPane.close":
            return handleFloatPaneCloseCommand(request: request, config: config)
        case "floatPane.pin":
            return handleFloatPanePinCommand(request: request, config: config)
        case "floatPane.move":
            return handleFloatPaneMoveCommand(request: request, config: config)
        case "window.focus":
            return handleWindowFocusCommand(config: config)
        case "ssh.list":
            return handleSSHListCommand(config: config)
        case "ssh.search":
            return handleSSHSearchCommand(request: request, config: config)
        case "ssh.batch":
            return handleSSHBatchCommand(request: request, config: config)
        default:
            return .error(code: "UNKNOWN_COMMAND", message: "unknown command: \(request.cmd)")
        }
    }

    private static func handleSessionListCommand(config: Configuration) -> JSONResponse {
        guard let producer = config.handleSessionList else {
            return .success(rawJSON(#"{"sessions":[]}"#))
        }
        let response = producer()
        return encodeCodableResult(response)
    }

    private static func handleSessionCreateCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleSessionCreate else {
            return .error(code: "INTERNAL_ERROR", message: "session.create not wired")
        }

        // `name` is optional; when present, must be a non-empty string.
        let name: String?
        if let any = request.params["name"] {
            guard let s = any as? String, !s.isEmpty else {
                return .error(code: "INVALID_PARAMS", message: "`name` must be a non-empty string")
            }
            name = s
        } else {
            name = nil
        }

        // `type` defaults to "local".
        let typeRaw = (request.params["type"] as? String) ?? "local"
        guard let type = AutomationSessionType(rawValue: typeRaw) else {
            return .error(code: "INVALID_PARAMS", message: "`type` must be 'local' or 'remote'")
        }

        let focus = boolParam(request.params["focus"])

        switch handler(name, type, focus) {
        case .success(let payload):
            return encodeCodableResult(payload)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleSessionCloseCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleSessionClose else {
            return .error(code: "INTERNAL_ERROR", message: "session.close not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        switch handler(ref) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleSessionAttachCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleSessionAttach else {
            return .error(code: "INTERNAL_ERROR", message: "session.attach not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        let focus = boolParam(request.params["focus"])
        switch handler(ref, focus) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleSessionDetachCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleSessionDetach else {
            return .error(code: "INTERNAL_ERROR", message: "session.detach not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        switch handler(ref) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handlePaneSendTextCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handlePaneSendText else {
            return .error(code: "INTERNAL_ERROR", message: "pane.sendText not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        // `text` may legitimately be empty (no-op); a missing or non-string value is rejected.
        guard let text = request.params["text"] as? String else {
            return .error(code: "INVALID_PARAMS", message: "`text` must be a string")
        }
        switch handler(ref, text) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handlePaneSendKeyCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handlePaneSendKey else {
            return .error(code: "INTERNAL_ERROR", message: "pane.sendKey not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        guard let key = request.params["key"] as? String, !key.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`key` is required")
        }
        let input: KeyEncoder.KeyInput
        do {
            input = try AutomationKeySpec.parse(key)
        } catch let err as AutomationError {
            return .error(code: err.code, message: err.message)
        } catch {
            return .error(code: "INVALID_PARAMS", message: "failed to parse key: \(error)")
        }
        switch handler(ref, input) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handlePaneNotifyCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handlePaneNotify else {
            return .error(code: "INTERNAL_ERROR", message: "pane.notify not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        guard let title = request.params["title"] as? String, !title.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`title` is required")
        }
        let body = request.params["body"] as? String
        let noNotifyIfVisible = request.params["noNotifyIfVisible"] as? Bool ?? false
        switch handler(ref, title, body, noNotifyIfVisible) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleTabCreateCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleTabCreate else {
            return .error(code: "INTERNAL_ERROR", message: "tab.create not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        let focus = boolParam(request.params["focus"])
        let parsed = parseProfileFields(from: request.params)
        if let error = parsed.error { return error }
        switch handler(ref, focus, parsed.profile, parsed.overrides) {
        case .success(let payload):
            return encodeCodableResult(payload)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleTabSelectCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleTabSelect else {
            return .error(code: "INTERNAL_ERROR", message: "tab.select not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        switch handler(ref) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleTabCloseCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleTabClose else {
            return .error(code: "INTERNAL_ERROR", message: "tab.close not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        switch handler(ref) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handlePaneSplitCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handlePaneSplit else {
            return .error(code: "INTERNAL_ERROR", message: "pane.split not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        let dirRaw = (request.params["direction"] as? String) ?? "vertical"
        let direction: SplitDirection
        switch dirRaw {
        case "vertical": direction = .vertical
        case "horizontal": direction = .horizontal
        default:
            return .error(
                code: "INVALID_PARAMS",
                message: "`direction` must be 'vertical' or 'horizontal'"
            )
        }
        let focus = boolParam(request.params["focus"])
        let parsed = parseProfileFields(from: request.params)
        if let error = parsed.error { return error }
        switch handler(ref, direction, focus, parsed.profile, parsed.overrides) {
        case .success(let payload):
            return encodeCodableResult(payload)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handlePaneFocusCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handlePaneFocus else {
            return .error(code: "INTERNAL_ERROR", message: "pane.focus not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        switch handler(ref) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handlePaneCloseCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handlePaneClose else {
            return .error(code: "INTERNAL_ERROR", message: "pane.close not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        switch handler(ref) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handlePaneResizeCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handlePaneResize else {
            return .error(code: "INTERNAL_ERROR", message: "pane.resize not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        // `ratio` may arrive as Double, Int, or NSNumber depending on the
        // JSON parser's promotion; normalize via NSNumber.
        let ratio: Double
        if let d = request.params["ratio"] as? Double {
            ratio = d
        } else if let n = request.params["ratio"] as? NSNumber {
            ratio = n.doubleValue
        } else {
            return .error(code: "INVALID_PARAMS", message: "`ratio` must be a number")
        }
        guard ratio.isFinite, ratio > 0.0, ratio < 1.0 else {
            return .error(
                code: "INVALID_PARAMS",
                message: "`ratio` must be in the open interval (0, 1)"
            )
        }
        switch handler(ref, ratio) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleFloatPaneCreateCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleFloatPaneCreate else {
            return .error(code: "INTERNAL_ERROR", message: "floatPane.create not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        let focus = boolParam(request.params["focus"])
        let parsed = parseProfileFields(from: request.params)
        if let error = parsed.error { return error }
        switch handler(ref, focus, parsed.profile, parsed.overrides) {
        case .success(let payload):
            return encodeCodableResult(payload)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleFloatPaneFocusCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleFloatPaneFocus else {
            return .error(code: "INTERNAL_ERROR", message: "floatPane.focus not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        switch handler(ref) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleFloatPaneCloseCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleFloatPaneClose else {
            return .error(code: "INTERNAL_ERROR", message: "floatPane.close not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        switch handler(ref) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleFloatPanePinCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleFloatPanePin else {
            return .error(code: "INTERNAL_ERROR", message: "floatPane.pin not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        switch handler(ref) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleFloatPaneMoveCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleFloatPaneMove else {
            return .error(code: "INTERNAL_ERROR", message: "floatPane.move not wired")
        }
        guard let ref = request.params["ref"] as? String, !ref.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`ref` is required")
        }
        // All four components are required and must parse as finite numbers.
        // JSON parser may promote to Double, Int, or NSNumber — normalize.
        func readNumber(_ key: String) -> Double? {
            if let d = request.params[key] as? Double { return d }
            if let n = request.params[key] as? NSNumber { return n.doubleValue }
            return nil
        }
        guard let x = readNumber("x"),
              let y = readNumber("y"),
              let width = readNumber("width"),
              let height = readNumber("height") else {
            return .error(
                code: "INVALID_PARAMS",
                message: "`x`, `y`, `width`, `height` are all required numbers"
            )
        }
        // Range check: origin in [0, 1], size in (0, 1], and origin+size ≤ 1.
        // The GUI side clamps again, but rejecting obvious nonsense here gives
        // the CLI a definite error instead of silent clamping.
        guard [x, y, width, height].allSatisfy({ $0.isFinite }) else {
            return .error(code: "INVALID_PARAMS", message: "frame components must be finite")
        }
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1.0 + 1e-9, y + height <= 1.0 + 1e-9 else {
            return .error(
                code: "INVALID_PARAMS",
                message: "frame must fit within [0, 1] with positive size"
            )
        }
        let frame = FloatPaneFrame(x: x, y: y, width: width, height: height)
        switch handler(ref, frame) {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    /// Parse a boolean parameter from a ParsedRequest params dict. Accepts
    /// JSON `true` / `false` as well as NSNumber-wrapped values; missing
    /// or non-boolean values default to `false`.
    private static func boolParam(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }

    /// Parse the shared Phase 5 `profile` + `overrides` fields out of a
    /// request. `profile` must be a non-empty string (or absent). Each
    /// entry in `overrides` must be a non-empty string containing a `=`
    /// — full key/value semantics are left to `ProfileMerger`, we only
    /// reject malformed shapes here so the CLI gets a definite error
    /// before hitting the GUI side. Returns `nil` on validation failure
    /// and fills in `errorResponse`.
    private static func parseProfileFields(
        from params: [String: Any]
    ) -> (profile: String?, overrides: [String]?, error: JSONResponse?) {
        let profile: String?
        if let any = params["profile"] {
            if any is NSNull {
                profile = nil
            } else if let s = any as? String {
                if s.isEmpty {
                    return (nil, nil, .error(
                        code: "INVALID_PARAMS",
                        message: "`profile` must be a non-empty string"
                    ))
                }
                profile = s
            } else {
                return (nil, nil, .error(
                    code: "INVALID_PARAMS",
                    message: "`profile` must be a string"
                ))
            }
        } else {
            profile = nil
        }

        let overrides: [String]?
        if let any = params["overrides"] {
            if any is NSNull {
                overrides = nil
            } else {
                guard let array = any as? [Any] else {
                    return (nil, nil, .error(
                        code: "INVALID_PARAMS",
                        message: "`overrides` must be an array of strings"
                    ))
                }
                var lines: [String] = []
                lines.reserveCapacity(array.count)
                for (index, element) in array.enumerated() {
                    guard let line = element as? String else {
                        return (nil, nil, .error(
                            code: "INVALID_PARAMS",
                            message: "`overrides[\(index)]` must be a string"
                        ))
                    }
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        return (nil, nil, .error(
                            code: "INVALID_PARAMS",
                            message: "`overrides[\(index)]` must not be empty"
                        ))
                    }
                    // Allow comments; require `=` for everything else so
                    // downstream parsing can't mistake a literal for a key.
                    if !trimmed.hasPrefix("#"), !trimmed.contains("=") {
                        return (nil, nil, .error(
                            code: "INVALID_PARAMS",
                            message: "`overrides[\(index)]` must be 'key = value'"
                        ))
                    }
                    lines.append(line)
                }
                overrides = lines
            }
        } else {
            overrides = nil
        }

        return (profile, overrides, nil)
    }

    private static func handleWindowFocusCommand(config: Configuration) -> JSONResponse {
        guard let handler = config.handleWindowFocus else {
            return .error(code: "INTERNAL_ERROR", message: "window.focus not wired")
        }
        switch handler() {
        case .success:
            return .success(.null)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func encodeCodableResult<T: Encodable>(_ value: T) -> JSONResponse {
        do {
            let data = try JSONEncoder().encode(value)
            guard let fragment = String(data: data, encoding: .utf8) else {
                return .error(code: "INTERNAL_ERROR", message: "failed to encode response")
            }
            return .success(rawJSON(fragment))
        } catch {
            return .error(code: "INTERNAL_ERROR", message: "failed to encode response: \(error)")
        }
    }

    private static func rawJSON(_ fragment: String) -> JSONValue {
        .raw(fragment)
    }

    // MARK: - JSON helpers

    private struct ParsedRequest {
        let cmd: String
        let token: String?
        /// The full decoded JSON object. Command handlers read parameters
        /// from this dict by key; extracting values is each handler's job
        /// so new commands don't require touching the parser.
        let params: [String: Any]
    }

    private enum JSONResponse {
        case success(JSONValue)
        case error(code: String, message: String)
    }

    // MARK: - SSH Response Types

    public struct SSHListCandidate: Codable, Sendable {
        public let target: String
        public let hostname: String?

        public init(target: String, hostname: String?) {
            self.target = target
            self.hostname = hostname
        }
    }

    public struct SSHListResponse: Codable, Sendable {
        public let candidates: [SSHListCandidate]
        
        public init(candidates: [SSHListCandidate]) {
            self.candidates = candidates
        }
    }

    public struct SSHSearchMatch: Codable, Sendable {
        public let target: String
        public let template: String
        public let variables: [String: String]
        
        public init(target: String, template: String, variables: [String: String]) {
            self.target = target
            self.template = template
            self.variables = variables
        }
    }

    public struct SSHSearchResponse: Codable, Sendable {
        public let matches: [SSHSearchMatch]
        
        public init(matches: [SSHSearchMatch]) {
            self.matches = matches
        }
    }

    public struct SSHBatchResponse: Codable, Sendable {
        public let tabRef: String
        public let paneCount: Int
        
        public init(tabRef: String, paneCount: Int) {
            self.tabRef = tabRef
            self.paneCount = paneCount
        }
    }

    // MARK: - SSH Command Handlers

    private static func handleSSHListCommand(config: Configuration) -> JSONResponse {
        guard let handler = config.handleSSHList else {
            return .success(rawJSON(#"{"candidates":[]}"#))
        }
        switch handler() {
        case .success(let response):
            return encodeCodableResult(response)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleSSHSearchCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleSSHSearch else {
            return .error(code: "INTERNAL_ERROR", message: "ssh.search not wired")
        }
        guard let queries = request.params["queries"] as? [String], !queries.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`queries` must be a non-empty array")
        }
        let profile = request.params["profile"] as? String
        switch handler(queries, profile) {
        case .success(let response):
            return encodeCodableResult(response)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    private static func handleSSHBatchCommand(
        request: ParsedRequest,
        config: Configuration
    ) -> JSONResponse {
        guard let handler = config.handleSSHBatch else {
            return .error(code: "INTERNAL_ERROR", message: "ssh.batch not wired")
        }
        guard let targets = request.params["targets"] as? [String], !targets.isEmpty else {
            return .error(code: "INVALID_PARAMS", message: "`targets` must be a non-empty array")
        }
        let profile = request.params["profile"] as? String
        let overrides: [String]?
        if let ov = request.params["overrides"] as? [String], !ov.isEmpty {
            overrides = ov
        } else {
            overrides = nil
        }
        switch handler(targets, profile, overrides) {
        case .success(let response):
            return encodeCodableResult(response)
        case .failure(let error):
            return .error(code: error.code, message: error.message)
        }
    }

    /// Minimal JSON value used for response payloads.
    enum JSONValue {
        case string(String)
        case null
        /// Pre-serialized JSON fragment; spliced into `result` verbatim.
        /// Caller is responsible for ensuring the fragment is valid JSON.
        case raw(String)
    }

    private static func parseRequest(_ line: String) -> Result<ParsedRequest, Error> {
        struct ParseError: Error {}
        guard let data = line.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            return .failure(ParseError())
        }
        let token = obj["token"] as? String
        return .success(ParsedRequest(cmd: cmd, token: token, params: obj))
    }

    private static func encode(response: JSONResponse) -> String {
        switch response {
        case .success(let value):
            let resultFragment: String
            switch value {
            case .null:
                resultFragment = "null"
            case .string(let s):
                resultFragment = jsonEncodeString(s)
            case .raw(let fragment):
                resultFragment = fragment
            }
            return #"{"ok":true,"result":\#(resultFragment)}"#
        case .error(let code, let message):
            return #"{"ok":false,"error":{"code":\#(jsonEncodeString(code)),"message":\#(jsonEncodeString(message))}}"#
        }
    }

    private static func jsonEncodeString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        // JSONSerialization wraps the string in an array; extract the inner form.
        guard let serialized = String(data: data, encoding: .utf8) else { return "\"\"" }
        // Trim leading '[' and trailing ']'.
        guard serialized.count >= 2 else { return "\"\"" }
        return String(serialized.dropFirst().dropLast())
    }

    private static func tryWrite(io: LineIO, response: JSONResponse) {
        let encoded = encode(response: response)
        try? io.writeLine(encoded)
    }

    private static func tryWrite(io: LineIO, success value: JSONValue) {
        tryWrite(io: io, response: .success(value))
    }

    private static func tryWrite(io: LineIO, errorCode: String, message: String) {
        tryWrite(io: io, response: .error(code: errorCode, message: message))
    }
}
