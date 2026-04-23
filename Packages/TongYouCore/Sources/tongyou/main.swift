import Foundation
import TYAutomation
import TYCLIUtils
import TYClient
import TYProtocol
import TYServer
import TYTerminal

// MARK: - Helper Functions

/// Check if a string is a valid UUID
func isValidUUID(_ string: String) -> Bool {
    return UUID(uuidString: string) != nil
}

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
    case appCreate(name: String?, type: AutomationSessionType, focus: Bool, json: Bool)
    case appClose(ref: String, json: Bool)
    case appAttach(ref: String, focus: Bool, json: Bool)
    case appDetach(ref: String, json: Bool)
    case appSend(ref: String, text: String, json: Bool)
    case appKey(ref: String, key: String, json: Bool)
    case appNewTab(sessionRef: String, focus: Bool, profile: String?, overrides: [String], json: Bool)
    case appSelectTab(sessionRef: String, index: UInt, json: Bool)
    case appCloseTab(sessionRef: String, index: UInt, json: Bool)
    case appSplit(ref: String, direction: SplitDirection, focus: Bool, profile: String?, overrides: [String], json: Bool)
    case appFocusPane(ref: String, json: Bool)
    case appClosePane(ref: String, json: Bool)
    case appResizePane(ref: String, ratio: Double, json: Bool)
    case appFloatPaneCreate(sessionRef: String, focus: Bool, profile: String?, overrides: [String], json: Bool)
    case appFloatPaneFocus(ref: String, json: Bool)
    case appFloatPaneClose(ref: String, json: Bool)
    case appFloatPanePin(ref: String, json: Bool)
    case appFloatPaneMove(ref: String, x: Double, y: Double, width: Double, height: Double, json: Bool)
    case appWindowFocus(json: Bool)
    case appSSH(targets: [String], open: Bool, profile: String?, overrides: [String], json: Bool)
    case appNotify(ref: String?, title: String, body: String?, json: Bool)

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
        return parseAppAttach(rest, json: json)
    case "detach":
        guard let ref = rest.first else {
            fputs("tongyou: app detach requires a ref\n", stderr)
            exit(1)
        }
        return .appDetach(ref: ref, json: json)
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
    case "notify":
        // Parse: [ref] title [body]
        // If first arg looks like a ref (contains '/' or is a UUID), treat as ref.
        // Otherwise use TONGYOU_PANE_ID from environment.
        if rest.isEmpty {
            fputs("tongyou: app notify requires at least a title\n", stderr)
            exit(1)
        }
        let ref: String?
        let title: String
        let body: String?
        if rest.count >= 2 && (rest[0].contains("/") || isValidUUID(rest[0])) {
            ref = rest[0]
            title = rest[1]
            body = rest.count >= 3 ? rest.dropFirst(2).joined(separator: " ") : nil
        } else {
            ref = nil
            title = rest[0]
            body = rest.count >= 2 ? rest.dropFirst().joined(separator: " ") : nil
        }
        return .appNotify(ref: ref, title: title, body: body, json: json)
    case "new-tab":
        return parseAppNewTab(rest, json: json)
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
    case "float-pane":
        return parseAppFloatPane(rest, json: json)
    case "window-focus":
        return .appWindowFocus(json: json)
    case "ssh":
        return parseAppSSH(rest, json: json)
    case "--help", "-h", "help":
        printAppUsage()
        exit(0)
    default:
        fputs("tongyou: unknown subcommand '\(sub)' for app\n", stderr)
        printAppUsage()
        exit(1)
    }
}

/// Run `extractProfileAndSet` against a command's arg slice; on failure
/// print a stderr message in the form `tongyou: app <command>: …` and exit.
private func runExtractProfileAndSet(
    _ args: [String],
    command: String
) -> ParsedProfileAndSet {
    do {
        return try extractProfileAndSet(args)
    } catch ArgParseError.profileFlagMissingValue {
        fputs("tongyou: app \(command): --profile expects a name\n", stderr)
        exit(1)
    } catch ArgParseError.setFlagMissingValue {
        fputs("tongyou: app \(command): --set expects key=value\n", stderr)
        exit(1)
    } catch ArgParseError.setFlagMissingEquals(let value) {
        fputs("tongyou: app \(command): --set expects key=value (got '\(value)')\n", stderr)
        exit(1)
    } catch {
        fputs("tongyou: app \(command): \(error)\n", stderr)
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
    let parsed = runExtractProfileAndSet(args, command: "split")
    var ref: String?
    var direction: SplitDirection = .vertical
    var focus = false
    for arg in parsed.remaining {
        switch arg {
        case "--vertical":
            direction = .vertical
        case "--horizontal":
            direction = .horizontal
        case "--focus":
            focus = true
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
    return .appSplit(
        ref: ref,
        direction: direction,
        focus: focus,
        profile: parsed.profile,
        overrides: parsed.overrides,
        json: json
    )
}

func parseAppAttach(_ args: [String], json: Bool) -> Command {
    var ref: String?
    var focus = false
    for arg in args {
        switch arg {
        case "--focus":
            focus = true
        default:
            if arg.hasPrefix("--") {
                fputs("tongyou: unknown option '\(arg)' for app attach\n", stderr)
                exit(1)
            }
            if ref != nil {
                fputs("tongyou: app attach takes a single ref argument\n", stderr)
                exit(1)
            }
            ref = arg
        }
    }
    guard let ref else {
        fputs("tongyou: app attach requires a ref\n", stderr)
        exit(1)
    }
    return .appAttach(ref: ref, focus: focus, json: json)
}

func parseAppNewTab(_ args: [String], json: Bool) -> Command {
    let parsed = runExtractProfileAndSet(args, command: "new-tab")
    var ref: String?
    var focus = false
    for arg in parsed.remaining {
        switch arg {
        case "--focus":
            focus = true
        default:
            if arg.hasPrefix("--") {
                fputs("tongyou: unknown option '\(arg)' for app new-tab\n", stderr)
                exit(1)
            }
            if ref != nil {
                fputs("tongyou: app new-tab takes a single session ref argument\n", stderr)
                exit(1)
            }
            ref = arg
        }
    }
    guard let ref else {
        fputs("tongyou: app new-tab requires a session ref\n", stderr)
        exit(1)
    }
    return .appNewTab(
        sessionRef: ref,
        focus: focus,
        profile: parsed.profile,
        overrides: parsed.overrides,
        json: json
    )
}

func parseAppFloatPane(_ args: [String], json: Bool) -> Command {
    guard let sub = args.first else {
        fputs("tongyou: app float-pane requires a subcommand (create|focus|close|pin|move)\n", stderr)
        exit(1)
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "create":
        return parseAppFloatPaneCreate(rest, json: json)
    case "focus":
        guard let ref = rest.first else {
            fputs("tongyou: app float-pane focus requires a float ref\n", stderr)
            exit(1)
        }
        return .appFloatPaneFocus(ref: ref, json: json)
    case "close":
        guard let ref = rest.first else {
            fputs("tongyou: app float-pane close requires a float ref\n", stderr)
            exit(1)
        }
        return .appFloatPaneClose(ref: ref, json: json)
    case "pin":
        guard let ref = rest.first else {
            fputs("tongyou: app float-pane pin requires a float ref\n", stderr)
            exit(1)
        }
        return .appFloatPanePin(ref: ref, json: json)
    case "move":
        return parseAppFloatPaneMove(rest, json: json)
    default:
        fputs("tongyou: unknown subcommand '\(sub)' for app float-pane\n", stderr)
        exit(1)
    }
}

func parseAppFloatPaneCreate(_ args: [String], json: Bool) -> Command {
    let parsed = runExtractProfileAndSet(args, command: "float-pane create")
    var ref: String?
    var focus = false
    for arg in parsed.remaining {
        switch arg {
        case "--focus":
            focus = true
        default:
            if arg.hasPrefix("--") {
                fputs("tongyou: unknown option '\(arg)' for app float-pane create\n", stderr)
                exit(1)
            }
            if ref != nil {
                fputs("tongyou: app float-pane create takes a single session ref argument\n", stderr)
                exit(1)
            }
            ref = arg
        }
    }
    guard let ref else {
        fputs("tongyou: app float-pane create requires a session ref\n", stderr)
        exit(1)
    }
    return .appFloatPaneCreate(
        sessionRef: ref,
        focus: focus,
        profile: parsed.profile,
        overrides: parsed.overrides,
        json: json
    )
}

func parseAppFloatPaneMove(_ args: [String], json: Bool) -> Command {
    var ref: String?
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
    var i = 0
    while i < args.count {
        let arg = args[i]
        func takeNumber(_ flag: String) -> Double {
            guard i + 1 < args.count, let v = Double(args[i + 1]) else {
                fputs("tongyou: \(flag) requires a number\n", stderr)
                exit(1)
            }
            return v
        }
        switch arg {
        case "--x":
            x = takeNumber("--x"); i += 2
        case "--y":
            y = takeNumber("--y"); i += 2
        case "--width":
            width = takeNumber("--width"); i += 2
        case "--height":
            height = takeNumber("--height"); i += 2
        default:
            if arg.hasPrefix("--") {
                fputs("tongyou: unknown option '\(arg)' for app float-pane move\n", stderr)
                exit(1)
            }
            if ref != nil {
                fputs("tongyou: app float-pane move takes a single ref argument\n", stderr)
                exit(1)
            }
            ref = arg
            i += 1
        }
    }
    guard let ref, let x, let y, let width, let height else {
        fputs("tongyou: app float-pane move requires <ref> --x <v> --y <v> --width <v> --height <v>\n", stderr)
        exit(1)
    }
    return .appFloatPaneMove(ref: ref, x: x, y: y, width: width, height: height, json: json)
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

func parseAppSSH(_ args: [String], json: Bool) -> Command {
    var targets: [String] = []
    var open = false
    var profile: String?
    var overrides: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--list" || arg == "-l" {
            return .appSSH(targets: ["--list"], open: false, profile: nil, overrides: [], json: json)
        } else if arg == "--open" || arg == "-o" {
            open = true
            i += 1
        } else if arg == "--profile" || arg == "-p" {
            if i + 1 < args.count {
                profile = args[i + 1]
                i += 2
            } else {
                fputs("tongyou: app ssh: --profile requires a value\n", stderr)
                exit(1)
            }
        } else if arg == "--set" {
            if i + 1 < args.count {
                overrides.append(args[i + 1])
                i += 2
            } else {
                fputs("tongyou: app ssh: --set expects key=value\n", stderr)
                exit(1)
            }
        } else if arg == "--help" || arg == "-h" {
            printAppSSHUsage()
            exit(0)
        } else if arg.hasPrefix("-") {
            fputs("tongyou: app ssh: unknown option '\(arg)'\n", stderr)
            exit(1)
        } else {
            targets.append(arg)
            i += 1
        }
    }
    return .appSSH(targets: targets, open: open, profile: profile, overrides: overrides, json: json)
}

func printAppSSHUsage() {
    let usage = """
    Usage: tongyou app ssh [OPTIONS] [<target>...]

    List, search, or open SSH connections via the GUI.

    Options:
      --list, -l                    List all available SSH servers (from ssh_config)
      --open, -o                    Open the matched SSH servers in the GUI
      --profile <name>              Force a specific SSH profile
      --set key=value               Pass variable overrides (repeatable)
      --help, -h                    Show this help message

    Examples:
      tongyou app ssh --list
      tongyou app ssh "*btc-node*"
      tongyou app ssh "*btc-node*" -o
      tongyou app ssh host1 user@host2 -o --profile ssh-prod
    """
    print(usage)
}

func parseAppCreateArgs(_ args: [String], json: Bool) -> Command {
    var name: String?
    var type: AutomationSessionType = .local
    var focus = false
    for arg in args {
        switch arg {
        case "--local":
            type = .local
        case "--remote":
            type = .remote
        case "--focus":
            focus = true
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
    return .appCreate(name: name, type: type, focus: focus, json: json)
}

func printAppUsage() {
    let usage = """
    Usage: tongyou app [--json] <subcommand>

    Control the running TongYou GUI app via the automation socket.

    Subcommands:
      ping                                 Verify the GUI is running and reachable.
      list (ls)                            List all sessions in the GUI.
      create [name] [--local|--remote] [--focus]
                                           Create a new session; --local is default. Pass --focus to switch the
                                           active session to the new one (default: leave current view alone).
      close <ref>                          Close the session identified by ref.
      attach <ref> [--focus]               Attach a detached remote session. --focus also switches to it.
      detach <ref>                         Detach the session identified by ref (stops rendering / receiving input).
      send <ref> <text>                    Send raw UTF-8 text to the target pane (no trailing newline).
      key <ref> <key>                      Send a key event (e.g. Enter, Ctrl+C, Alt+Left) to the target pane.
      notify [<ref>] <title> [<body>]      Send a notification from the target pane.
                                             If <ref> is omitted, uses TONGYOU_PANE_ID from environment
                                             (requires running inside a TongYou pane).
      new-tab <session-ref> [--focus] [--profile <name>] [--set key=value ...]
                                           Create a new tab. --focus switches to the new tab.
                                           --profile picks a profile for the tab's root pane;
                                           --set layers on inline overrides (repeatable).
      select-tab <session-ref> <index>     Select the tab at the given 0-based position.
      close-tab <session-ref> <index>      Close the tab at the given 0-based position.
      split <ref> [--vertical|--horizontal] [--focus] [--profile <name>] [--set key=value ...]
                                           Split the target pane (default: vertical). --focus focuses new pane.
                                           --profile picks a profile for the new pane;
                                           --set layers on inline overrides (repeatable).
      focus-pane <pane-ref>                Focus the given pane (brings window forward).
      close-pane <pane-ref>                Close the given pane.
      resize-pane <pane-ref> --ratio <v>   Resize the pane by setting its parent split ratio (0 < v < 1).
      float-pane create <session-ref> [--focus] [--profile <name>] [--set key=value ...]
                                           Create a new floating pane. --focus switches to the host session.
                                           --profile picks a profile for the float;
                                           --set layers on inline overrides (repeatable).
      float-pane focus <float-ref>         Focus a floating pane (brings window forward).
      float-pane close <float-ref>         Close a floating pane.
      float-pane pin <float-ref>           Toggle the pinned flag on a floating pane.
      float-pane move <float-ref> --x <v> --y <v> --width <v> --height <v>
                                           Move / resize a floating pane (normalized 0–1 coords).
      window-focus                         Bring the GUI window to the foreground (no focus change).
      ssh [--list|-l] [<target>...] [--open|-o] [--profile <name>] [--set k=v ...]
                                           List/search SSH servers or open connections.
                                           --list shows all servers from ssh_config.
                                           Without --open, searches and shows matches.
                                           With --open, creates tabs for the targets.
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
      app create [name] [--remote] [--focus]   Create a new session; --focus to switch to it
      app close <ref>                Close a session in the GUI by ref
      app attach <ref> [--focus]     Attach a remote session (and optionally switch to it)
      app detach <ref>               Detach a session by ref (stop rendering / receiving input)
      app send <ref> <text>          Send text to the target pane (no trailing newline)
      app key <ref> <key>            Send a key event (Enter, Ctrl+C, …) to the target pane
      app notify [<ref>] <title> [<body>]
                                     Send a notification from the target pane.
                                     Omit <ref> to use current pane (inside TongYou only).
      app new-tab <session-ref> [--focus] [--profile <name>] [--set k=v ...]
                                     Create a new tab; --profile/--set layer profile + inline overrides
      app select-tab <ref> <index>   Select a tab by 0-based position
      app close-tab <ref> <index>    Close a tab by 0-based position
      app split <ref> [--horizontal] [--focus] [--profile <name>] [--set k=v ...]
                                     Split the target pane; --profile/--set layer profile + inline overrides
      app focus-pane <pane-ref>      Focus a pane (brings window forward)
      app close-pane <pane-ref>      Close a pane
      app resize-pane <pane-ref> --ratio <v>  Resize a pane by setting its parent split ratio (0 < v < 1)
      app float-pane create <session-ref> [--focus] [--profile <name>] [--set k=v ...]
                                     Create a floating pane; --profile/--set layer profile + inline overrides
      app float-pane focus <float-ref>     Focus a floating pane (brings window forward)
      app float-pane close <float-ref>     Close a floating pane
      app float-pane pin <float-ref>       Toggle the pinned flag on a floating pane
      app float-pane move <float-ref> --x <v> --y <v> --width <v> --height <v>
                                           Move / resize a floating pane (normalized 0–1 coords)
      app window-focus               Bring the GUI window to the foreground (no focus change)

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

/// Apply `daemon-debug-log-level` and `daemon-debug-log-categories` to the
/// file logger. Empty-level means "inherit the CLI-driven default"; "off"
/// disables file logging entirely.
func applyDaemonLogConfig(_ config: ServerConfig, cliDefault: Log.Level) {
    let categories: Set<Log.Category>?
    if config.debugLogCategories.isEmpty {
        categories = nil
    } else {
        categories = Set(config.debugLogCategories.compactMap { Log.Category(rawValue: $0) })
    }

    let raw = config.debugLogLevel
    if raw.isEmpty {
        Log.updateFileLogging(level: cliDefault, categories: categories)
    } else if raw == "off" {
        Log.updateFileLogging(level: nil, categories: nil)
    } else if let level = Log.Level(configValue: raw) {
        Log.updateFileLogging(level: level, categories: categories)
    } else {
        // Parsing already rejected invalid values in DaemonConfigLoader; fall
        // back to the CLI default just to be safe.
        Log.updateFileLogging(level: cliDefault, categories: categories)
    }
}

func runServer(daemonize: Bool, debug: Bool) {
    if let existingPID = DaemonLifecycle.checkExistingProcess() {
        fputs("tongyou: server already running (pid \(existingPID))\n", stderr)
        exit(1)
    }

    if daemonize {
        _ = DaemonLifecycle.daemonize()
    }

    // Configure logging AFTER daemonize() — `Log`'s file backend uses a GCD
    // serial queue, and GCD worker threads do not survive fork(). Creating
    // the queue in the parent leaves the child with a dead queue whose async
    // writes never run. Defer queue creation to the post-fork child.
    Log.configure(daemonize: daemonize, minLevel: debug ? .debug : .info)

    let baseConfig = ServerConfig(persistenceDirectory: ServerConfig.defaultPersistenceDirectory())
    let configLoader = DaemonConfigLoader(baseConfig: baseConfig)
    configLoader.load()

    let config = configLoader.config
    applyDaemonLogConfig(config, cliDefault: debug ? .debug : .info)
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

    // Persisted sessions used to restore during `init`, but the
    // actor-ized SSM can't call isolated methods synchronously from a
    // nonisolated init. Load them here before wiring the server so any
    // connected client immediately sees the restored layout.
    let restoreSem = DispatchSemaphore(value: 0)
    Task {
        await sessionManager.loadPersistedSessions()
        restoreSem.signal()
    }
    restoreSem.wait()

    let server = SocketServer(config: config, sessionManager: sessionManager, authToken: authToken)

    let cliDefaultLevel: Log.Level = debug ? .debug : .info
    configLoader.onConfigChanged = { [weak server] newConfig in
        server?.updateConfig(newConfig)
        applyDaemonLogConfig(newConfig, cliDefault: cliDefaultLevel)
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

func appCreate(name: String?, type: AutomationSessionType, focus: Bool, json: Bool) {
    let client = connectToGUIOrExit()
    let ref: String
    do {
        ref = try client.createSession(name: name, type: type, focus: focus)
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

func appAttach(ref: String, focus: Bool, json: Bool) {
    let client = connectToGUIOrExit()
    do {
        try client.attachSession(ref: ref, focus: focus)
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

func appDetach(ref: String, json: Bool) {
    let client = connectToGUIOrExit()
    do {
        try client.detachSession(ref: ref)
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: detach failed: \(error)\n", stderr)
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

func appNotify(ref: String?, title: String, body: String?, json: Bool) {
    let effectiveRef: String
    if let ref = ref {
        effectiveRef = ref
    } else if let paneID = ProcessInfo.processInfo.environment["TONGYOU_PANE_ID"] {
        effectiveRef = paneID
    } else {
        fputs("tongyou: notify requires a ref when not running inside a TongYou pane\n", stderr)
        exit(1)
    }
    
    let client = connectToGUIOrExit()
    handleCommandResult({
        try client.notify(ref: effectiveRef, title: title, body: body)
    }, json: json, verb: "notify")
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

func appNewTab(sessionRef: String, focus: Bool, profile: String?, overrides: [String], json: Bool) {
    let client = connectToGUIOrExit()
    let ref: String
    do {
        ref = try client.createTab(
            sessionRef: sessionRef,
            focus: focus,
            profile: profile,
            overrides: overrides.isEmpty ? nil : overrides
        )
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

func appSplit(
    ref: String,
    direction: SplitDirection,
    focus: Bool,
    profile: String?,
    overrides: [String],
    json: Bool
) {
    let client = connectToGUIOrExit()
    let newRef: String
    do {
        newRef = try client.splitPane(
            ref: ref,
            direction: direction,
            focus: focus,
            profile: profile,
            overrides: overrides.isEmpty ? nil : overrides
        )
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

func appFloatPaneCreate(sessionRef: String, focus: Bool, profile: String?, overrides: [String], json: Bool) {
    let client = connectToGUIOrExit()
    let ref: String
    do {
        ref = try client.createFloatingPane(
            sessionRef: sessionRef,
            focus: focus,
            profile: profile,
            overrides: overrides.isEmpty ? nil : overrides
        )
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: float-pane create failed: \(error)\n", stderr)
        exit(1)
    }
    if json {
        printJSONResult(#"{"ref":\#(jsonEscaped(ref))}"#)
    } else {
        print(ref)
    }
}

func appFloatPaneFocus(ref: String, json: Bool) {
    let client = connectToGUIOrExit()
    handleCommandResult({ try client.focusFloatingPane(ref: ref) }, json: json, verb: "float-pane focus")
}

func appFloatPaneClose(ref: String, json: Bool) {
    let client = connectToGUIOrExit()
    handleCommandResult({ try client.closeFloatingPane(ref: ref) }, json: json, verb: "float-pane close")
}

func appFloatPanePin(ref: String, json: Bool) {
    let client = connectToGUIOrExit()
    handleCommandResult({ try client.pinFloatingPane(ref: ref) }, json: json, verb: "float-pane pin")
}

func appFloatPaneMove(ref: String, x: Double, y: Double, width: Double, height: Double, json: Bool) {
    let client = connectToGUIOrExit()
    handleCommandResult(
        { try client.moveFloatingPane(ref: ref, x: x, y: y, width: width, height: height) },
        json: json,
        verb: "float-pane move"
    )
}

func appWindowFocus(json: Bool) {
    let client = connectToGUIOrExit()
    handleCommandResult({ try client.focusWindow() }, json: json, verb: "window-focus")
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
case .appCreate(let name, let type, let focus, let json):
    appCreate(name: name, type: type, focus: focus, json: json)
case .appClose(let ref, let json):
    appClose(ref: ref, json: json)
case .appAttach(let ref, let focus, let json):
    appAttach(ref: ref, focus: focus, json: json)
case .appDetach(let ref, let json):
    appDetach(ref: ref, json: json)
case .appSend(let ref, let text, let json):
    appSend(ref: ref, text: text, json: json)
case .appKey(let ref, let key, let json):
    appKey(ref: ref, key: key, json: json)
case .appNotify(let ref, let title, let body, let json):
    appNotify(ref: ref, title: title, body: body, json: json)
case .appNewTab(let sessionRef, let focus, let profile, let overrides, let json):
    appNewTab(sessionRef: sessionRef, focus: focus, profile: profile, overrides: overrides, json: json)
case .appSelectTab(let sessionRef, let index, let json):
    appSelectTab(sessionRef: sessionRef, index: index, json: json)
case .appCloseTab(let sessionRef, let index, let json):
    appCloseTab(sessionRef: sessionRef, index: index, json: json)
case .appSplit(let ref, let direction, let focus, let profile, let overrides, let json):
    appSplit(ref: ref, direction: direction, focus: focus, profile: profile, overrides: overrides, json: json)
case .appFocusPane(let ref, let json):
    appFocusPane(ref: ref, json: json)
case .appClosePane(let ref, let json):
    appClosePane(ref: ref, json: json)
case .appResizePane(let ref, let ratio, let json):
    appResizePane(ref: ref, ratio: ratio, json: json)
case .appFloatPaneCreate(let sessionRef, let focus, let profile, let overrides, let json):
    appFloatPaneCreate(sessionRef: sessionRef, focus: focus, profile: profile, overrides: overrides, json: json)
case .appFloatPaneFocus(let ref, let json):
    appFloatPaneFocus(ref: ref, json: json)
case .appFloatPaneClose(let ref, let json):
    appFloatPaneClose(ref: ref, json: json)
case .appFloatPanePin(let ref, let json):
    appFloatPanePin(ref: ref, json: json)
case .appFloatPaneMove(let ref, let x, let y, let width, let height, let json):
    appFloatPaneMove(ref: ref, x: x, y: y, width: width, height: height, json: json)
case .appWindowFocus(let json):
    appWindowFocus(json: json)
case .appSSH(let targets, let open, let profile, let overrides, let json):
    appSSH(targets: targets, open: open, profile: profile, overrides: overrides, json: json)
case .help:
    printUsage()
}

// MARK: - SSH Commands

func appSSH(targets: [String], open: Bool, profile: String?, overrides: [String], json: Bool) {
    let client = connectToGUIOrExit()
    
    // Handle --list first
    if targets == ["--list"] {
        do {
            let response = try client.sshList()
            if json {
                printJSONResult(response.jsonString())
            } else {
                if response.candidates.isEmpty {
                    print("No SSH servers configured in ~/.ssh/config")
                } else {
                    print("SSH servers:")
                    for candidate in response.candidates {
                        let hostname = candidate.hostname ?? "-"
                        print("  \(candidate.target)\t\(hostname)")
                    }
                }
            }
        } catch AppControlError.serverError(let code, let message) {
            if json {
                printJSONError(code: code, message: message)
            } else {
                fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
            }
            exit(1)
        } catch {
            fputs("tongyou: ssh list failed: \(error)\n", stderr)
            exit(1)
        }
        return
    }
    
    // Validate that we have targets
    if targets.isEmpty {
        if json {
            printJSONError(code: "MISSING_ARGUMENTS", message: "expected target(s) or --list")
        } else {
            fputs("tongyou: expected target(s) or --list\n", stderr)
        }
        exit(1)
    }
    
    // If not opening, perform search
    if !open {
        do {
            let response = try client.sshSearch(queries: targets, profile: profile)
            if json {
                printJSONResult(response.jsonString())
            } else {
                if response.matches.isEmpty {
                    print("No matches found for: \(targets.joined(separator: ", "))")
                } else {
                    print("Matching SSH servers:")
                    for match in response.matches {
                        print("  \(match.target)\t\(match.template)")
                    }
                }
            }
        } catch AppControlError.serverError(let code, let message) {
            if json {
                printJSONError(code: code, message: message)
            } else {
                fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
            }
            exit(1)
        } catch {
            fputs("tongyou: ssh search failed: \(error)\n", stderr)
            exit(1)
        }
        return
    }
    
    // Open mode: check if targets contain glob patterns
    let hasGlob = targets.contains { target in
        target.contains(where: { $0 == "*" || $0 == "?" || $0 == "," })
    }
    
    let batchTargets: [String]
    if hasGlob {
        // Need to search first to resolve glob patterns
        do {
            let searchResponse = try client.sshSearch(queries: targets, profile: profile)
            if searchResponse.matches.isEmpty {
                if json {
                    printJSONError(code: "NO_MATCHES", message: "No SSH servers matched the query: \(targets.joined(separator: ", "))")
                } else {
                    fputs("tongyou: No SSH servers matched the query: \(targets.joined(separator: ", "))\n", stderr)
                }
                exit(1)
            }
            batchTargets = searchResponse.matches.map { $0.target }
        } catch AppControlError.serverError(let code, let message) {
            if json {
                printJSONError(code: code, message: message)
            } else {
                fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
            }
            exit(1)
        } catch {
            fputs("tongyou: ssh search failed: \(error)\n", stderr)
            exit(1)
        }
    } else {
        // Exact targets
        batchTargets = targets
    }
    
    // Execute batch
    do {
        let response = try client.sshBatch(targets: batchTargets, profile: profile, overrides: overrides.isEmpty ? nil : overrides)
        if json {
            printJSONResult(response.jsonString())
        } else {
            print("Opened \(response.paneCount) SSH connection(s) in tab \(response.tabRef)")
        }
    } catch AppControlError.serverError(let code, let message) {
        if json {
            printJSONError(code: code, message: message)
        } else {
            fputs("tongyou: GUI returned error: \(code): \(message)\n", stderr)
        }
        exit(1)
    } catch {
        fputs("tongyou: ssh open failed: \(error)\n", stderr)
        exit(1)
    }
}
