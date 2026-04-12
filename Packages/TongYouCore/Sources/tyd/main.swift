import Foundation
import TYServer

// MARK: - Argument Parsing

enum Command {
    case run(daemon: Bool, debug: Bool)
    case stop
    case status
}

func parseArguments() -> Command {
    let args = CommandLine.arguments.dropFirst()

    var daemon = false
    var debug = false

    for arg in args {
        switch arg {
        case "--daemon", "-d":
            daemon = true
        case "--debug":
            debug = true
        case "--stop":
            return .stop
        case "--status":
            return .status
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            fputs("tyd: unknown option '\(arg)'\n", stderr)
            printUsage()
            exit(1)
        }
    }

    return .run(daemon: daemon, debug: debug)
}

func printUsage() {
    let usage = """
    Usage: tyd [OPTIONS]

    TongYou terminal daemon — manages PTY sessions independently of the GUI.

    Options:
      (none)       Start in foreground (for development)
      --daemon     Start as background daemon
      --debug      Enable debug logging (prints all messages)
      --stop       Stop a running tyd process
      --status     Check if tyd is running
      --help       Show this help message
    """
    print(usage)
}

// MARK: - Commands

func runServer(daemon: Bool, debug: Bool) {
    // Configure logging before anything else.
    Log.configure(useSyslog: daemon, minLevel: debug ? .debug : .info)

    if let existingPID = DaemonLifecycle.checkExistingProcess() {
        fputs("tyd: already running (pid \(existingPID))\n", stderr)
        exit(1)
    }

    if daemon {
        _ = DaemonLifecycle.daemonize()
    }

    let config = ServerConfig()
    let lifecycle = DaemonLifecycle()
    let sessionManager = ServerSessionManager(config: config)
    let server = SocketServer(config: config, sessionManager: sessionManager)

    do {
        try lifecycle.writePIDFile()
    } catch {
        Log.error("Failed to write PID file: \(error)")
        exit(1)
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
        print("tyd: stop signal sent")
    } else {
        print("tyd: not running")
        exit(1)
    }
}

func showStatus() {
    let (running, pid) = DaemonLifecycle.status()
    if running, let pid {
        print("tyd: running (pid \(pid))")
    } else {
        print("tyd: not running")
    }
}

// MARK: - Entry Point

let command = parseArguments()

switch command {
case .run(let daemon, let debug):
    runServer(daemon: daemon, debug: debug)
case .stop:
    stopDaemon()
case .status:
    showStatus()
}
