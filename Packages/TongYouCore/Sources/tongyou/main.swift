import Foundation
import TYAutomation
import TYClient
import TYProtocol
import TYServer

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
    switch sub {
    case "ping":
        return .appPing
    case "list", "ls":
        return .appList(json: json)
    case "--help", "-h", "help":
        printAppUsage()
        exit(0)
    default:
        fputs("tongyou: unknown subcommand '\(sub)' for app\n", stderr)
        printAppUsage()
        exit(1)
    }
}

func printAppUsage() {
    let usage = """
    Usage: tongyou app [--json] <subcommand>

    Control the running TongYou GUI app via the automation socket.

    Subcommands:
      ping        Verify the GUI is running and reachable.
      list (ls)   List all sessions in the GUI.
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
      app ping                  Check whether the TongYou GUI is running
      app list [--json]         List all sessions in the GUI

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
case .help:
    printUsage()
}
