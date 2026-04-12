import Foundation
import TYServer

// MARK: - Argument Parsing

enum Command {
    case run(daemon: Bool)
    case stop
    case status
}

func parseArguments() -> Command {
    let args = CommandLine.arguments.dropFirst()

    for arg in args {
        switch arg {
        case "--daemon", "-d":
            return .run(daemon: true)
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

    return .run(daemon: false)
}

func printUsage() {
    let usage = """
    Usage: tyd [OPTIONS]

    TongYou terminal daemon — manages PTY sessions independently of the GUI.

    Options:
      (none)       Start in foreground (for development)
      --daemon     Start as background daemon
      --stop       Stop a running tyd process
      --status     Check if tyd is running
      --help       Show this help message
    """
    print(usage)
}

// MARK: - Commands

func runServer(daemon: Bool) {
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
        fputs("tyd: failed to write PID file: \(error)\n", stderr)
        exit(1)
    }

    lifecycle.onShutdown = {
        server.stop()
        if !daemon {
            print("tyd: shutting down")
        }
        exit(0)
    }

    lifecycle.installSignalHandlers()

    server.onAllSessionsClosed = {
        lifecycle.cleanup()
        if !daemon {
            print("tyd: all sessions closed, exiting")
        }
        exit(0)
    }

    server.onReady = {
        if !daemon {
            print("tyd: listening on \(config.socketPath)")
        }
    }

    do {
        try server.start()
    } catch {
        fputs("tyd: failed to start server: \(error)\n", stderr)
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
case .run(let daemon):
    runServer(daemon: daemon)
case .stop:
    stopDaemon()
case .status:
    showStatus()
}
