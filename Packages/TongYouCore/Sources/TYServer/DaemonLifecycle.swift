#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import Foundation

// fork() is marked unavailable in Swift's Darwin overlay.
// We call it via @_silgen_name to bypass the restriction for daemon mode.
@_silgen_name("fork")
private func cFork() -> pid_t

/// Manages PID file, signal handling, and daemon lifecycle for tyd.
public final class DaemonLifecycle {

    private let pidPath: String
    private let socketPath: String

    /// Callback invoked when SIGTERM/SIGINT is received. The server should shut down gracefully.
    public var onShutdown: (() -> Void)?

    private var signalSources: [DispatchSourceSignal] = []

    public init(pidPath: String? = nil, socketPath: String? = nil) {
        self.pidPath = pidPath ?? ServerConfig.defaultPIDPath()
        self.socketPath = socketPath ?? ServerConfig.defaultSocketPath()
    }

    // MARK: - PID File

    /// Write the current process PID to the PID file.
    /// Creates the parent directory if needed.
    public func writePIDFile() throws {
        try ServerConfig.ensureParentDirectory(for: pidPath)
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(toFile: pidPath, atomically: true, encoding: .utf8)
    }

    /// Remove the PID file on shutdown.
    public func removePIDFile() {
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// Remove the socket file on shutdown.
    public func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Read the PID from an existing PID file, or nil if not found.
    public static func readPID(from path: String? = nil) -> pid_t? {
        let pidPath = path ?? ServerConfig.defaultPIDPath()
        guard let contents = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    /// Check if another tyd process is already running.
    /// Returns the PID if running, nil otherwise.
    public static func checkExistingProcess(pidPath: String? = nil) -> pid_t? {
        guard let pid = readPID(from: pidPath) else { return nil }
        // Check if process exists (signal 0 = check only, no signal sent)
        if kill(pid, 0) == 0 {
            return pid
        }
        // Process doesn't exist — stale PID file
        let path = pidPath ?? ServerConfig.defaultPIDPath()
        try? FileManager.default.removeItem(atPath: path)
        return nil
    }

    /// Send SIGTERM to a running tyd process.
    public static func stopRunningDaemon(pidPath: String? = nil) -> Bool {
        guard let pid = checkExistingProcess(pidPath: pidPath) else {
            return false
        }
        kill(pid, SIGTERM)
        return true
    }

    /// Check if tyd is running and return status info.
    public static func status(pidPath: String? = nil) -> (running: Bool, pid: pid_t?) {
        let pid = checkExistingProcess(pidPath: pidPath)
        return (pid != nil, pid)
    }

    // MARK: - Signal Handling

    /// Install signal handlers for graceful shutdown (SIGTERM, SIGINT).
    public func installSignalHandlers() {
        // Ignore default signal behavior
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [weak self] in
            self?.handleShutdown()
        }
        termSource.resume()
        signalSources.append(termSource)

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [weak self] in
            self?.handleShutdown()
        }
        intSource.resume()
        signalSources.append(intSource)
    }

    /// Clean up on shutdown: remove PID file, socket file, cancel signal sources.
    public func cleanup() {
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()
        removePIDFile()
        removeSocketFile()
    }

    // MARK: - Daemon Mode

    /// Daemonize the process (fork, setsid, close stdio).
    /// Returns true in the child (daemon) process.
    /// The parent process exits with code 0.
    public static func daemonize() -> Bool {
        let pid = cFork()
        if pid < 0 {
            fputs("tyd: fork failed: \(String(cString: strerror(errno)))\n", stderr)
            exit(1)
        }
        if pid > 0 {
            // Parent — exit
            exit(0)
        }
        // Child — become session leader
        if setsid() < 0 {
            fputs("tyd: setsid failed: \(String(cString: strerror(errno)))\n", stderr)
            exit(1)
        }
        // Close standard file descriptors
        close(STDIN_FILENO)
        close(STDOUT_FILENO)
        close(STDERR_FILENO)
        // Redirect to /dev/null
        _ = open("/dev/null", O_RDWR) // stdin  = fd 0
        _ = dup(0)                     // stdout = fd 1
        _ = dup(0)                     // stderr = fd 2
        return true
    }

    // MARK: - Private

    private func handleShutdown() {
        cleanup()
        onShutdown?()
    }
}
