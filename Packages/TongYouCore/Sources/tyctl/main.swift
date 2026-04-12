import Foundation
import TYClient
import TYProtocol
import TYServer

// MARK: - Argument Parsing

enum Command {
    case list
    case create(name: String?)
    case close(sessionID: String)
    case help
}

func parseArguments() -> Command {
    let args = Array(CommandLine.arguments.dropFirst())

    guard let subcommand = args.first else {
        return .help
    }

    switch subcommand {
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
                fputs("tyctl: unknown option '\(args[i])' for create\n", stderr)
                exit(1)
            }
        }
        return .create(name: name)

    case "close", "rm":
        guard args.count >= 2 else {
            fputs("tyctl: close requires a session ID\n", stderr)
            exit(1)
        }
        return .close(sessionID: args[1])

    case "help", "--help", "-h":
        return .help

    default:
        fputs("tyctl: unknown command '\(subcommand)'\n", stderr)
        printUsage()
        exit(1)
    }
}

func printUsage() {
    let usage = """
    Usage: tyctl <command> [options]

    Commands:
      list (ls)                 List all sessions on the tyd server
      create (new) [--name N]   Create a new session
      close (rm) <session-id>   Close a session by ID (prefix match supported)
      help                      Show this help message

    Options:
      --socket <path>     Path to tyd socket (default: auto-detect)

    The tyd server is auto-started if not running.
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

    // tyd not running — try to auto-start it.
    if DaemonLifecycle.checkExistingProcess() == nil {
        fputs("tyctl: tyd not running, starting...\n", stderr)
        if let tydPath = try? TYDConnectionManager.findTYD() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tydPath)
            process.arguments = ["--daemon"]
            process.standardOutput = nil
            process.standardError = nil
            do {
                try process.run()
            } catch {
                fputs("tyctl: failed to start tyd at \(tydPath): \(error)\n", stderr)
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
        fputs("tyctl: failed to connect to tyd: \(error)\n", stderr)
        fputs("tyctl: is tyd running? Start it with: tyd\n", stderr)
        exit(1)
    }
}

// MARK: - Commands

func listSessions() {
    let conn = connectToServer()
    do {
        try conn.sendSync(ClientMessage.listSessions)
        let response = try conn.receiveSync()

        guard case .sessionList(let sessions) = response else {
            fputs("tyctl: unexpected response from server\n", stderr)
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
        fputs("tyctl: communication error: \(error)\n", stderr)
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
            fputs("tyctl: unexpected response from server\n", stderr)
            exit(1)
        }
    } catch {
        fputs("tyctl: communication error: \(error)\n", stderr)
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
            fputs("tyctl: unexpected response from server\n", stderr)
            exit(1)
        }

        let prefix = idPrefix.lowercased()
        let matches = sessions.filter {
            $0.id.uuid.uuidString.lowercased().hasPrefix(prefix)
        }

        guard matches.count == 1, let session = matches.first else {
            if matches.isEmpty {
                fputs("tyctl: no session matching '\(idPrefix)'\n", stderr)
            } else {
                fputs("tyctl: ambiguous session ID '\(idPrefix)' — matches \(matches.count) sessions\n", stderr)
                for m in matches {
                    fputs("  \(m.id.uuid.uuidString.prefix(8))  \(m.name)\n", stderr)
                }
            }
            exit(1)
        }

        try conn.sendSync(ClientMessage.closeSession(session.id))
        print("Closed session: \(session.id.uuid.uuidString.prefix(8))  \(session.name)")
    } catch {
        fputs("tyctl: communication error: \(error)\n", stderr)
        exit(1)
    }
    conn.close()
}

// MARK: - Entry Point

let command = parseArguments()

switch command {
case .list:
    listSessions()
case .create(let name):
    createSession(name: name)
case .close(let sessionID):
    closeSession(idPrefix: sessionID)
case .help:
    printUsage()
}
