import Foundation
import TYAutomation
import TYClient
import TYProtocol
import TYServer
import TYTerminal

// MARK: - Argument Parsing

enum Command {
    // Daemon commands
    case daemonRun(daemonize: Bool, debug: Bool)
    case daemonStop
    case daemonStatus

    // Session commands
    case list
    case create(name: String?)
    case close(sessionID: String)

    // GUI app automation commands
    case appPing
    case appList(json: Bool)
    case appCreate(name: String?, type: AutomationSessionType, json: Bool)
    case appClose(ref: String, json: Bool)
    case appAttach(ref: String, json: Bool)
    case appSend(ref: String, text: String, json: Bool)
    case appKey(ref: String, key: String, json: Bool)
    case appNewTab(sessionRef: String, json: Bool)
    case appSelectTab(sessionRef: String, index: UInt, json: Bool)
    case appCloseTab(sessionRef: String, index: UInt, json: Bool)
    case appSplit(ref: String, direction: SplitDirection, json: Bool)
    case appFocusPane(ref: String, json: Bool)
    case appClosePane(ref: String, json: Bool)
    case appResizePane(ref: String, ratio: Double, json: Bool)

    case help
}

func parseArguments() -> Command {
    let args = Array(CommandLine.arguments.dropFirst())

    guard let subcommand = args.first else {
        return .help
    }

    switch subcommand {
    case "daemon":
        return parseDaemonArgs(Array(args.dropFirst()))

    case "list", "ls":
        return .list

    case "create", "new":
        var name: String?
        var i = 1
        while i < args.count {
            if (args[i] == "--name" || args[i] == "-n"), i + 1 < args.count {
                name = args[i + 1]
                i += 2
            } else {
                fputs("tongyou: unknown option '\(args[i])' for create\n", stderr)
                exit(1)
            }
        }
        return .create(name: name)

    case "close", "rm":
        guard args.count >= 2 else {
            fputs("tongyou: close requires a session ID\n", stderr)
            exit(1)
        }
        return .close(sessionID: args[1])

    case "app":
        return parseAppArgs(Array(args.dropFirst()))

    case "help", "--help", "-h":
        return .help

    default:
        fputs("tongyou: unknown command '\(subcommand)'\n", stderr)
        printUsage()
        exit(1)
    }
}

func parseAppArgs(_ args: [String]) -> Command {
    // --json is a global flag on the `app` subcommand; accept it either
    // before or after the action.
    var json = false
    var remaining: [String] = []
    for arg in args {
        if arg == "--json" {
            json = true
        } else {
            remaining.append(arg)
        }
    }

    guard let sub = remaining.first else {
        printAppUsage()
        exit(1)
    }
    let rest = Array(remaining.dropFirst())
    switch sub {
    case "ping":
        return .appPing
    case "list", "ls":
        return .appList(json: json)
    case "create":
        return parseAppCreateArgs(rest, json: json)
    case "close":
        guard let ref = rest.first else {
            fputs("tongyou: app close requires a ref\n", stderr)
            exit(1)
        }
        return .appClose(ref: ref, json: json)
    case "attach":
        guard let ref = rest.first else {
            fputs("tongyou: app attach requires a ref\n", stderr)
            exit(1)
        }
        return .appAttach(ref: ref, json: json)
    case "send":
        guard rest.count >= 2 else {
            fputs("tongyou: app send requires <ref> <text>\n", stderr)
            exit(1)
        }
        // Allow text to contain spaces — remaining args are joined.
        let text = rest.dropFirst().joined(separator: " ")
        return .appSend(ref: rest[0], text: text, json: json)
    case "key":
        guard rest.count >= 2 else {
            fputs("tongyou: app key requires <ref> <key>\n", stderr)
            exit(1)
        }
        return .appKey(ref: rest[0], key: rest[1], json: json)
    case "new-tab":
        guard let ref = rest.first else {
            fputs("tongyou: app new-tab requires a session ref\n", stderr)
            exit(1)
        }
        return .appNewTab(sessionRef: ref, json: json)
    case "select-tab":
        return parseAppTabIndex(.selectTab, rest: rest, json: json)
    case "close-tab":
        return parseAppTabIndex(.closeTab, rest: rest, json: json)
    case "split":
        return parseAppSplit(rest, json: json)
    case "focus-pane":
        guard let ref = rest.first else {
            fputs("tongyou: app focus-pane requires a pane ref\n", stderr)
            exit(1)
        }
        return .appFocusPane(ref: ref, json: json)
    case "close-pane":
        guard let ref = rest.first else {
            fputs("tongyou: app close-pane requires a pane ref\n", stderr)
            exit(1)
        }
        return .appClosePane(ref: ref, json: json)
    case "resize-pane":
        return parseAppResizePane(rest, json: json)
    case "--help", "-h", "help":
        printAppUsage()
        exit(0)
    default:
        fputs("tongyou: unknown subcommand '\(sub)' for app\n", stderr)
        printAppUsage()
        exit(1)
    }
}

private enum TabIndexAction { case selectTab, closeTab }

private func parseAppTabIndex(_ action: TabIndexAction, rest: [String], json: Bool) -> Command {
    let label = action == .selectTab ? "select-tab" : "close-tab"
    guard rest.count >= 2, let index = UInt(rest[1]) else {
        fputs("tongyou: app \(label) requires <session-ref> <index>\n", stderr)
        exit(1)
    }
    switch action {
    case .selectTab:
        return .appSelectTab(sessionRef: rest[0], index: index, json: json)
    case .closeTab:
        return .appCloseTab(sessionRef: rest[0], index: index, json: json)
    }
}

func parseAppSplit(_ args: [String], json: Bool) -> Command {
    var ref: String?
    var direction: SplitDirection = .vertical
    for arg in args {
        switch arg {
        case "--vertical":
            direction = .vertical
        case "--horizontal":
            direction = .horizontal
        default:
            if arg.hasPrefix("--") {
                fputs("tongyou: unknown option '\(arg)' for app split\n", stderr)
                exit(1)
            }
            if ref != nil {
                fputs("tongyou: app split takes a single ref argument\n", stderr)
                exit(1)
            }
            ref = arg
        }
    }
    guard let ref else {
        fputs("tongyou: app split requires a ref\n", stderr)
        exit(1)
    }
    return .appSplit(ref: ref, direction: direction, json: json)
}

func parseAppResizePane(_ args: [String], json: Bool) -> Command {
    var ref: String?
    var ratio: Double?
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--ratio", i + 1 < args.count {
            guard let v = Double(args[i + 1]) else {
                fputs("tongyou: --ratio requires a number\n", stderr)
                exit(1)
            }
            ratio = v
            i += 2
        } else if arg.hasPrefix("--") {
            fputs("tongyou: unknown option '\(arg)' for app resize-pane\n", stderr)
            exit(1)
        } else {
            if ref != nil {
                fputs("tongyou: app resize-pane takes a single ref argument\n", stderr)
                exit(1)
            }
            ref = arg
            i += 1
        }
    }
    guard let ref, let ratio else {
        fputs("tongyou: app resize-pane requires <pane-ref> --ratio <value>\n", stderr)
        exit(1)
    }
    return .appResizePane(ref: ref, ratio: ratio, json: json)
}

func parseAppCreateArgs(_ args: [String], json: Bool) -> Command {
    var name: String?
    var type: AutomationSessionType = .local
    for arg in args {
        switch arg {
        case "--local":
            type = .local
        case "--remote":
            type = .remote
        default:
            if arg.hasPrefix("--") {
                fputs("tongyou: unknown option '\(arg)' for app create\n", stderr)
                exit(1)
            }
            if name != nil {
                fputs("tongyou: app create takes at most one name argument\n", stderr)
                exit(1)
            }
            name = arg
        }
    }
    return .appCreate(name: name, type: type, json: json)
}

func printAppUsage() {
    let usage = """
    Usage: tongyou app [--json] <subcommand>

    Control the running TongYou GUI app via the automation socket.

    Subcommands:
      ping                                 Verify the GUI is running and reachable.
      list (ls)                            List all sessions in the GUI.
      create [name] [--local|--remote]     Create a new session; --local is default.
      close <ref>                          Close the session identified by ref.
      attach <ref>                         Attach a detached remote session.
      send <ref> <text>                    Send raw UTF-8 text to the target pane (no trailing newline).
      key <ref> <key>                      Send a key event (e.g. Enter, Ctrl+C, Alt+Left) to the target pane.
      new-tab <session-ref>                Create a new tab in the given session.
      select-tab <session-ref> <index>     Select the tab at the given 0-based position.
      close-tab <session-ref> <index>      Close the tab at the given 0-based position.
      split <ref> [--vertical|--horizontal] Split the target pane (default: vertical).
      focus-pane <pane-ref>                Focus the given pane (brings window forward).
      close-pane <pane-ref>                Close the given pane.
      resize-pane <pane-ref> --ratio <v>   Resize the pane by setting its parent split ratio (0 < v < 1).
    """
    print(usage)
}

func parseDaemonArgs(_ args: [String]) -> Command {
    var daemonize = false
    var debug = false

    for arg in args {
        switch arg {
        case "stop":
            return .daemonStop
        case "status":
            return .daemonStatus
        case "--daemonize", "-d":
            daemonize = true
        case "--debug":
            debug = true
        case "--help", "-h":
            printDaemonUsage()
            exit(0)
        default:
            fputs("tongyou: unknown option '\(arg)' for daemon\n", stderr)
            printDaemonUsage()
            exit(1)
        }
    }

    return .daemonRun(daemonize: daemonize, debug: debug)
}

func printUsage() {
    let usage = """
    Usage: tongyou <command> [options]

    TongYou terminal — GPU-accelerated terminal emulator.

    Daemon:
      daemon                    Start server in foreground (for development)
      daemon --daemonize        Start server as background daemon
      daemon stop               Stop a running server
      daemon status             Check if server is running

    Session:
      list (ls)                 List all sessions
      create (new) [--name N]   Create a new session
      close (rm) <session-id>   Close a session by ID (prefix match supported)

    App (GUI automation):
      app ping                       Check whether the TongYou GUI is running
      app list [--json]              List all sessions in the GUI
      app create [name] [--remote]   Create a new session in the GUI
      app close <ref>                Close a session in the GUI by ref
      app attach <ref>               Attach a detached remote session by ref
      app send <ref> <text>          Send text to the target pane (no trailing newline)
      app key <ref> <key>            Send a key event (Enter, Ctrl+C, …) to the target pane
      app new-tab <session-ref>      Create a new tab in the given session
      app select-tab <ref> <index>   Select a tab by 0-based position
      app close-tab <ref> <index>    Close a tab by 0-based position
      app split <ref> [--horizontal] Split the target pane (default vertical)
      app focus-pane <pane-ref>      Focus a pane (brings window forward)
      app close-pane <pane-ref>      Close a pane
      app resize-pane <pane-ref> --ratio <v>  Resize a pane by setting its parent split ratio (0 < v < 1)

    Other:
      help                      Show this help message
    """
    print(usage)
}

func printDaemonUsage() {
    let usage = """
    Usage: tongyou daemon [OPTIONS|COMMAND]

    Manage the TongYou server daemon.

    Commands:
      stop               Stop a running server
      status             Check if server is running

    Options:
      --daemonize, -d    Start as background daemon
      --debug            Enable debug logging
      --help             Show this help message

    Without options, starts in foreground mode (for development).
    """
    print(usage)
}

// MARK: - Connection

/// Connect directly with a raw TYSocket — no async read loop.
/// CLI tools use synchronous sendSync/receiveSync, so the async
/// read loop from TYDConnectionManager would race and corrupt data.
func connectToServer() -> TYDConnection {
    let socketPath = ServerConfig.defaultSocketPath()

    // Try to connect directly first.
    if let socket = try? TYSocket.connect(path: socketPath) {
        return TYDConnection(socket: socket)
    }

    // Server not running — try to auto-start it.
    if DaemonLifecycle.checkExistingProcess() == nil {
        fputs("tongyou: server not running, starting...\n", stderr)
        if let execPath = try? TYDConnectionManager.findTongYou() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = ["daemon", "--daemonize"]
            process.standardOutput = nil
            process.standardError = nil
            do {
                try process.run()
            } catch {
                fputs("tongyou: failed to start server at \(execPath): \(error)\n", stderr)
            }

            // Wait for socket to appear.
            let deadline = Date().addingTimeInterval(5.0)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: socketPath) {
                    Thread.sleep(forTimeInterval: 0.2)
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    // Retry connection.
    do {
        let socket = try TYSocket.connect(path: socketPath)
        return TYDConnection(socket: socket)
    } catch {
        fputs("tongyou: failed to connect to server: \(error)\n", stderr)
        fputs("tongyou: is the server running? Start it with: tongyou daemon\n", stderr)
        exit(1)
    }
}

// MARK: - Daemon Commands

func runServer(daemonize: Bool, debug: Bool) {
    // Configure logging before anything else.
    Log.configure(useSyslog: daemonize, minLevel: debug ? .debug : .info)

    if let existingPID = DaemonLifecycle.checkExistingProcess() {
        fputs("tongyou: server already running (pid \(existingPID))\n", stderr)
        exit(1)
    }

    if daemonize {
        _ = DaemonLifecycle.daemonize()
    }

    let baseConfig = ServerConfig(persistenceDirectory: ServerConfig.defaultPersistenceDirectory())
    let configLoader = DaemonConfigLoader(baseConfig: baseConfig)
    configLoader.load()

    let config = configLoader.config
    Log.info("Config loaded: scrollback=\(config.maxScrollback), coalesce=\(config.minCoalesceDelay)...\(config.maxCoalesceDelay)s")

    let lifecycle = DaemonLifecycle()

    let authToken: String
    do {
        try lifecycle.writePIDFile()
        authToken = try lifecycle.generateAuthToken()
    } catch {
        Log.error("Failed to write PID/token file: \(error)")
        exit(1)
    }

    let sessionManager = ServerSessionManager(config: config)
    let server = SocketServer(config: config, sessionManager: sessionManager, authToken: authToken)

    configLoader.onConfigChanged = { [weak server] newConfig in
        server?.updateConfig(newConfig)
    }

    lifecycle.onShutdown = {
        server.stop()
        Log.info("Shutting down")
        exit(0)
    }

    lifecycle.installSignalHandlers()

    server.onAllSessionsClosed = {
        Log.info("All sessions closed, exiting")
        lifecycle.cleanup()
        exit(0)
    }

    do {
        try server.start()
    } catch {
        Log.error("Failed to start server: \(error)")
        lifecycle.cleanup()
        exit(1)
    }

    dispatchMain()
}

func stopDaemon() {
    if DaemonLifecycle.stopRunningDaemon() {
        print("tongyou: stop signal sent")
    } else {
        print("tongyou: server not running")
        exit(1)
    }
}

func showStatus() {
    let (running, pid) = DaemonLifecycle.status()
    if running, let pid {
        print("tongyou: server running (pid \(pid))")
    } else {
        print("tongyou: server not running")
    }
}

// MARK: - Session Commands

func listSessions() {
    let conn = connectToServer()
    do {
        try conn.sendSync(ClientMessage.listSessions)
        let response = try conn.receiveSync()

        guard case .sessionList(let sessions) = response else {
            fputs("tongyou: unexpected response from server\n", stderr)
            exit(1)
        }

        if sessions.isEmpty {
            print("No active sessions.")
        } else {
            print("Sessions:")
            for session in sessions {
                let tabCount = session.tabs.count
                let tabSuffix = tabCount == 1 ? "tab" : "tabs"
                print("  \(session.id.uuid.uuidString.prefix(8))  \(session.name)  (\(tabCount) \(tabSuffix))")
            }
        }
    } catch {
        fputs("tongyou: communication error: \(error)\n", stderr)
        exit(1)
    }
    conn.close()
}

func createSession(name: String?) {
    let conn = connectToServer()
    do {
        try conn.sendSync(ClientMessage.createSession(name: name))
        let response = try conn.receiveSync()

        switch response {
        case .sessionCreated(let info):
            print("Created session: \(info.id.uuid.uuidString.prefix(8))  \(info.name)")
        case .sessionList:
            // Server might broadcast session list after create.
            print("Session created.")
        default:
            fputs("tongyou: unexpected response from server\n", stderr)
            exit(1)
        }
    } catch {
        fputs("tongyou: communication error: \(error)\n", stderr)
        exit(1)
    }
    conn.close()
}

func closeSession(idPrefix: String) {
    let conn = connectToServer()
    do {
        // First list sessions to find the matching one.
        try conn.sendSync(ClientMessage.listSessions)
        let listResponse = try conn.receiveSync()

        guard case .sessionList(let sessions) = listResponse else {
            fputs("tongyou: unexpected response from server\n", stderr)
            exit(1)
        }

        let prefix = idPrefix.lowercased()
        let matches = sessions.filter {
            $0.id.uuid.uuidString.lowercased().hasPrefix(prefix)
        }

        guard matches.count == 1, let session = matches.first else {
            if matches.isEmpty {
                fputs("tongyou: no session matching '\(idPrefix)'\n", stderr)
            } else {
                fputs("tongyou: ambiguous session ID '\(idPrefix)' — matches \(matches.count) sessions\n", stderr)
                for m in matches {
                    fputs("  \(m.id.uuid.uuidString.prefix(8))  \(m.name)\n", stderr)
                }
            }
            exit(1)
        }

        try conn.sendSync(ClientMessage.closeSession(session.id))
        print("Closed session: \(session.id.uuid.uuidString.prefix(8))  \(session.name)")
    } catch {
        fputs("tongyou: communication error: \(error)\n", stderr)
        exit(1)
    }
    conn.close()
}

// MARK: - App Automation Commands

func connectToGUIOrExit() -> AppControlClient {
    do {
        return try AppControlClient.connect()
    } catch AppControlError.guiNotRunning {
        fputs("tongyou: TongYou GUI not running\n", stderr)
        exit(1)
    } catch AppControlError.tokenFileMissing(let path) {
        fputs("tongyou: auth token file missing at \(path)\n", stderr)
        exit(1)
    } catch AppControlError.handshakeFailed(let reason) {
        fputs("tongyou: handshake with GUI failed: \(reason)\n", stderr)
        exit(1)
    } catch {
        fputs("tongyou: failed to connect to GUI: \(error)\n", stderr)
        exit(1)
    }
}

func appPing() {
    let client = connectToGUIOrExit()

    do {
        let result = try client.ping()
        print(result)
    } catch AppControlError.serverError(let code, let message) {
        fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        exit(1)
    } catch {
        fputs("tongyou: ping failed: \(error)\n", stderr)
        exit(1)
    }
}

func appList(json: Bool) {
    let client = connectToGUIOrExit()

    if json {
        do {
            let raw = try client.listSessionsRawJSON()
            print(raw)
        } catch AppControlError.serverError(let code, let message) {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
            exit(1)
        } catch {
            fputs("tongyou: list failed: \(error)\n", stderr)
            exit(1)
        }
        return
    }

    let response: SessionListResponse
    do {
        response = try client.listSessions()
    } catch AppControlError.serverError(let code, let message) {
        fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        exit(1)
    } catch {
        fputs("tongyou: list failed: \(error)\n", stderr)
        exit(1)
    }
    renderSessionListText(response)
}

func appCreate(name: String?, type: AutomationSessionType, json: Bool) {
    let client = connectToGUIOrExit()
    let ref: String
    do {
        ref = try client.createSession(name: name, type: type)
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: create failed: \(error)\n", stderr)
        exit(1)
    }
    if json {
        printJSONResult(#"{"ref":"\#(ref)"}"#)
    } else {
        print(ref)
    }
}

func appClose(ref: String, json: Bool) {
    let client = connectToGUIOrExit()
    do {
        try client.closeSession(ref: ref)
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: close failed: \(error)\n", stderr)
        exit(1)
    }
    if json { printJSONResult("null") }
}

func appAttach(ref: String, json: Bool) {
    let client = connectToGUIOrExit()
    do {
        try client.attachSession(ref: ref)
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: attach failed: \(error)\n", stderr)
        exit(1)
    }
    if json { printJSONResult("null") }
}

func appSend(ref: String, text: String, json: Bool) {
    let client = connectToGUIOrExit()
    do {
        try client.sendText(ref: ref, text: text)
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: send failed: \(error)\n", stderr)
        exit(1)
    }
    if json { printJSONResult("null") }
}

func appKey(ref: String, key: String, json: Bool) {
    let client = connectToGUIOrExit()
    do {
        try client.sendKey(ref: ref, key: key)
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: key failed: \(error)\n", stderr)
        exit(1)
    }
    if json { printJSONResult("null") }
}

private func handleCommandResult(
    _ action: () throws -> Void,
    json: Bool,
    verb: String,
    successJSON: String = "null"
) {
    do {
        try action()
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: \(verb) failed: \(error)\n", stderr)
        exit(1)
    }
    if json { printJSONResult(successJSON) }
}

func appNewTab(sessionRef: String, json: Bool) {
    let client = connectToGUIOrExit()
    let ref: String
    do {
        ref = try client.createTab(sessionRef: sessionRef)
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: new-tab failed: \(error)\n", stderr)
        exit(1)
    }
    if json {
        printJSONResult(#"{"ref":\#(jsonEscaped(ref))}"#)
    } else {
        print(ref)
    }
}

func appSelectTab(sessionRef: String, index: UInt, json: Bool) {
    let client = connectToGUIOrExit()
    let tabRef = "\(sessionRef)/tab:\(index + 1)"
    handleCommandResult({ try client.selectTab(ref: tabRef) }, json: json, verb: "select-tab")
}

func appCloseTab(sessionRef: String, index: UInt, json: Bool) {
    let client = connectToGUIOrExit()
    // Resolve position-in-list to a stable tab ref by consulting session.list,
    // so users can pass visual positions without caring about ref numbering.
    let response: SessionListResponse
    do {
        response = try client.listSessions()
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: close-tab failed: \(error)\n", stderr)
        exit(1)
    }
    guard let session = response.sessions.first(where: { $0.ref == sessionRef || $0.name == sessionRef }) else {
        if json {
            printJSONError(code: "SESSION_NOT_FOUND", message: "no session matches '\(sessionRef)'")
        } else {
            fputs("tongyou: no session matches '\(sessionRef)'\n", stderr)
        }
        exit(1)
    }
    guard Int(index) < session.tabs.count else {
        if json {
            printJSONError(code: "TAB_NOT_FOUND", message: "tab index \(index) out of range")
        } else {
            fputs("tongyou: tab index \(index) out of range\n", stderr)
        }
        exit(1)
    }
    let tabRef = session.tabs[Int(index)].ref
    handleCommandResult({ try client.closeTab(ref: tabRef) }, json: json, verb: "close-tab")
}

func appSplit(ref: String, direction: SplitDirection, json: Bool) {
    let client = connectToGUIOrExit()
    let newRef: String
    do {
        newRef = try client.splitPane(ref: ref, direction: direction)
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: split failed: \(error)\n", stderr)
        exit(1)
    }
    if json {
        printJSONResult(#"{"ref":\#(jsonEscaped(newRef))}"#)
    } else {
        print(newRef)
    }
}

func appFocusPane(ref: String, json: Bool) {
    let client = connectToGUIOrExit()
    handleCommandResult({ try client.focusPane(ref: ref) }, json: json, verb: "focus-pane")
}

func appClosePane(ref: String, json: Bool) {
    let client = connectToGUIOrExit()
    handleCommandResult({ try client.closePane(ref: ref) }, json: json, verb: "close-pane")
}

func appResizePane(ref: String, ratio: Double, json: Bool) {
    let client = connectToGUIOrExit()
    handleCommandResult({ try client.resizePane(ref: ref, ratio: ratio) }, json: json, verb: "resize-pane")
}

private func printJSONResult(_ resultFragment: String) {
    print(#"{"ok":true,"result":\#(resultFragment)}"#)
}

private func printJSONError(code: String, message: String) {
    let codeEscaped = jsonEscaped(code)
    let messageEscaped = jsonEscaped(message)
    print(#"{"ok":false,"error":{"code":\#(codeEscaped),"message":\#(messageEscaped)}}"#)
}

private func jsonEscaped(_ s: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
    guard let serialized = String(data: data, encoding: .utf8), serialized.count >= 2 else {
        return "\"\""
    }
    return String(serialized.dropFirst().dropLast())
}

/// Render the `session.list` response as a column-aligned text table.
func renderSessionListText(_ response: SessionListResponse) {
    if response.sessions.isEmpty {
        print("No active sessions.")
        return
    }

    struct Row {
        let ref: String
        let name: String
        let type: String
        let state: String
        let tabs: String
        let panes: String
    }

    let rows: [Row] = response.sessions.map { s in
        let paneCount = s.tabs.reduce(0) { $0 + $1.panes.count + $1.floats.count }
        return Row(
            ref: s.ref,
            name: s.name,
            type: s.type.rawValue,
            state: s.state.rawValue,
            tabs: String(s.tabs.count),
            panes: String(paneCount)
        )
    }

    let headers = Row(ref: "REF", name: "NAME", type: "TYPE", state: "STATE", tabs: "TABS", panes: "PANES")
    let allRows = [headers] + rows

    let refW = allRows.map { $0.ref.count }.max() ?? 3
    let nameW = allRows.map { $0.name.count }.max() ?? 4
    let typeW = allRows.map { $0.type.count }.max() ?? 4
    let stateW = allRows.map { $0.state.count }.max() ?? 5
    let tabsW = allRows.map { $0.tabs.count }.max() ?? 4

    func pad(_ s: String, _ w: Int) -> String {
        s.padding(toLength: w, withPad: " ", startingAt: 0)
    }

    for row in allRows {
        let line = [
            pad(row.ref, refW),
            pad(row.name, nameW),
            pad(row.type, typeW),
            pad(row.state, stateW),
            pad(row.tabs, tabsW),
            row.panes,
        ].joined(separator: "  ")
        print(line)
    }
}

// MARK: - Entry Point

let command = parseArguments()

switch command {
case .daemonRun(let daemonize, let debug):
    runServer(daemonize: daemonize, debug: debug)
case .daemonStop:
    stopDaemon()
case .daemonStatus:
    showStatus()
case .list:
    listSessions()
case .create(let name):
    createSession(name: name)
case .close(let sessionID):
    closeSession(idPrefix: sessionID)
case .appPing:
    appPing()
case .appList(let json):
    appList(json: json)
case .appCreate(let name, let type, let json):
    appCreate(name: name, type: type, json: json)
case .appClose(let ref, let json):
    appClose(ref: ref, json: json)
case .appAttach(let ref, let json):
    appAttach(ref: ref, json: json)
case .appSend(let ref, let text, let json):
    appSend(ref: ref, text: text, json: json)
case .appKey(let ref, let key, let json):
    appKey(ref: ref, key: key, json: json)
case .appNewTab(let sessionRef, let json):
    appNewTab(sessionRef: sessionRef, json: json)
case .appSelectTab(let sessionRef, let index, let json):
    appSelectTab(sessionRef: sessionRef, index: index, json: json)
case .appCloseTab(let sessionRef, let index, let json):
    appCloseTab(sessionRef: sessionRef, index: index, json: json)
case .appSplit(let ref, let direction, let json):
    appSplit(ref: ref, direction: direction, json: json)
case .appFocusPane(let ref, let json):
    appFocusPane(ref: ref, json: json)
case .appClosePane(let ref, let json):
    appClosePane(ref: ref, json: json)
case .appResizePane(let ref, let ratio, let json):
    appResizePane(ref: ref, ratio: ratio, json: json)
case .help:
    printUsage()
}
