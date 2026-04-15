import Foundation
import TYShell
import TYPTYC

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Manages a pseudo-terminal and child shell process.
///
/// Creates a PTY pair via `openpty()`, spawns a shell via the C helper
/// `pty_fork_exec()` (fork + setsid + TIOCSCTTY + dup2 + execve),
/// and provides async read (via DispatchSourceRead) and async write
/// (via a dedicated serial `writeQueue` that handles `EAGAIN` with `poll()`).
///
/// Thread safety:
/// - `start()`, `write()`, `resize()`, `stop()` are called from MainActor.
/// - The read source fires on the provided `readQueue`.
/// - Writes are dispatched to `writeQueue` to avoid blocking MainActor.
/// - Properties accessed in `deinit` are marked `nonisolated(unsafe)`.
public final class PTYProcess {

    /// Callback invoked on `readQueue` when bytes arrive from the shell.
    public var onRead: ((_ bytes: UnsafeBufferPointer<UInt8>) -> Void)?

    /// Callback invoked on the main thread when the child process exits.
    /// The parameter is the exit code (0 = normal, >0 = error, -N = killed by signal N).
    public var onExit: ((_ exitCode: Int32) -> Void)?

    nonisolated(unsafe) private var masterFD: Int32 = -1
    nonisolated(unsafe) private var childPID: pid_t = -1
    nonisolated(unsafe) private var readSource: DispatchSourceRead?
    nonisolated(unsafe) private var processSource: DispatchSourceProcess?
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue

    private static let readBufSize = 65536
    /// Time budget per event handler invocation (milliseconds).
    /// Balances throughput vs. main-thread responsiveness.
    /// Adaptive: uses bulkBudgetMs when sustained full-buffer reads are detected.
    private static let readBudgetMs = 8
    private static let bulkBudgetMs = 16
    /// Number of consecutive full-buffer reads before switching to bulk budget.
    private static let bulkReadThreshold = 3

    /// Maximum time (ms) to wait for the PTY to become writable per poll call.
    private static let writePollTimeoutMs: Int32 = 1000

    public init(readQueue: DispatchQueue) {
        self.readQueue = readQueue
        self.writeQueue = DispatchQueue(
            label: "io.github.airead.tongyou.pty.write",
            qos: .userInitiated
        )
    }

    deinit {
        cleanup()
    }

    // MARK: - Start

    /// Open a PTY, fork a child shell process, and start reading.
    public func start(columns: UInt16, rows: UInt16, cellWidth: UInt16 = 0, cellHeight: UInt16 = 0, workingDirectory: String? = nil) throws {
        let shellPath = Self.resolveShell()
        let env = Self.buildEnvironment(shellPath: shellPath)
        try start(
            executablePath: shellPath,
            arguments: [],
            environment: env,
            columns: columns,
            rows: rows,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            workingDirectory: workingDirectory
        )
    }

    /// Open a PTY, fork a child process running the given command, and start reading.
    public func start(command: String, arguments: [String] = [], columns: UInt16, rows: UInt16, cellWidth: UInt16 = 0, cellHeight: UInt16 = 0, workingDirectory: String? = nil) throws {
        let shellPath = Self.resolveShell()
        let env = Self.buildEnvironment(shellPath: shellPath)
        try start(
            executablePath: command,
            arguments: arguments,
            environment: env,
            columns: columns,
            rows: rows,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            workingDirectory: workingDirectory
        )
    }

    private func start(executablePath: String, arguments: [String], environment: [String], columns: UInt16, rows: UInt16, cellWidth: UInt16 = 0, cellHeight: UInt16 = 0, workingDirectory: String? = nil) throws {
        var master: Int32 = -1
        var slave: Int32 = -1

        #if os(macOS)
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PTYError.openptyFailed(errno)
        }
        #elseif os(Linux)
        master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else {
            throw PTYError.openptyFailed(errno)
        }
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            close(master)
            throw PTYError.openptyFailed(errno)
        }
        guard let slaveName = ptsname(master) else {
            close(master)
            throw PTYError.openptyFailed(errno)
        }
        slave = open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            throw PTYError.openptyFailed(errno)
        }
        #endif

        let masterFlags = fcntl(master, F_GETFD)
        if masterFlags >= 0 {
            _ = fcntl(master, F_SETFD, masterFlags | FD_CLOEXEC)
        }

        // IUTF8 tells the kernel line discipline we use UTF-8
        var attrs = termios()
        if tcgetattr(slave, &attrs) == 0 {
            attrs.c_iflag |= UInt(IUTF8)
            _ = tcsetattr(slave, TCSANOW, &attrs)
        }

        var winSize = winsize(
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: cellWidth,
            ws_ypixel: cellHeight
        )
        _ = ioctl(slave, TIOCSWINSZ, &winSize)

            let pid = Self.forkAndExec(
                slaveFD: slave, masterFD: master,
                executablePath: executablePath, arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                loginShell: arguments.isEmpty
            )

        guard pid > 0 else {
            close(master)
            close(slave)
            throw PTYError.forkFailed(errno)
        }

        close(slave)
        masterFD = master
        childPID = pid

        let flags = fcntl(master, F_GETFL)
        if flags >= 0 {
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        }

        startReadSource()
        startProcessMonitor()
    }

    // MARK: - Write

    /// Write data to the PTY master fd (sends to the shell's stdin).
    ///
    /// The write is dispatched to a dedicated serial queue so it never blocks
    /// the caller. When the kernel buffer is full (`EAGAIN`), the queue uses
    /// `poll()` to wait for the fd to become writable before retrying, ensuring
    /// large pastes (including the bracketed-paste end sequence) are delivered
    /// in full.
    public func write(_ data: Data) {
        let fd = masterFD
        guard fd >= 0, !data.isEmpty else { return }
        writeQueue.async {
            data.withUnsafeBytes { rawBuf in
                guard let ptr = rawBuf.baseAddress else { return }
                var remaining = data.count
                var offset = 0
                while remaining > 0 {
                    let n = Darwin.write(fd, ptr + offset, remaining)
                    if n >= 0 {
                        offset += n
                        remaining -= n
                        continue
                    }
                    // n < 0
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let ret = poll(&pfd, 1, Self.writePollTimeoutMs)
                        if ret > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                            continue // fd writable — retry
                        }
                        break // timeout or poll error — give up
                    }
                    break // fatal write error
                }
            }
        }
    }

    // MARK: - Resize

    /// Update the PTY window size (sends SIGWINCH to the child).
    public func resize(columns: UInt16, rows: UInt16, pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0) {
        guard masterFD >= 0 else { return }
        var winSize = winsize(
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: pixelWidth,
            ws_ypixel: pixelHeight
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &winSize)
    }

    // MARK: - Stop

    /// Terminate the child process and clean up.
    public func stop() {
        cleanup()
    }

    /// Shared teardown used by both `stop()` and `deinit`.
    nonisolated private func cleanup() {
        readSource?.cancel()
        readSource = nil
        processSource?.cancel()
        processSource = nil

        // Drain pending writes before closing the fd so in-flight data
        // (e.g. the bracketed-paste end sequence) is not lost.
        writeQueue.sync {}

        if childPID > 0 {
            let pid = childPID
            childPID = -1

            kill(pid, SIGHUP)

            // Give the child a brief window to exit gracefully, then force-kill.
            // Use WNOHANG throughout — the processSource may have already reaped
            // this child, so a blocking waitpid would hang forever.
            var status: Int32 = 0
            var reaped = false
            for _ in 0..<20 {
                if waitpid(pid, &status, WNOHANG) != 0 { reaped = true; break }
                usleep(5_000) // 5ms, total up to 100ms
            }
            if !reaped {
                kill(pid, SIGKILL)
                // Brief non-blocking poll after SIGKILL.
                for _ in 0..<10 {
                    if waitpid(pid, &status, WNOHANG) != 0 { break }
                    usleep(5_000)
                }
            }
        }

        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    // MARK: - Private: Fork + Exec

    private static func forkAndExec(
        slaveFD: Int32, masterFD: Int32,
        executablePath: String, arguments: [String] = [], environment: [String],
        workingDirectory: String?,
        loginShell: Bool
    ) -> pid_t {
        let basename = loginShell
            ? "-" + (URL(fileURLWithPath: executablePath).lastPathComponent)
            : URL(fileURLWithPath: executablePath).lastPathComponent

        return executablePath.withCString { execCStr in
            basename.withCString { basenameCStr in
                var argv: [UnsafeMutablePointer<CChar>?] = [
                    UnsafeMutablePointer(mutating: basenameCStr)
                ]
                for arg in arguments {
                    argv.append(strdup(arg))
                }
                argv.append(nil)
                defer {
                    // Don't free basenameCStr (it's a borrowed pointer), but free duplicated argument strings
                    for i in 1..<(argv.count - 1) {
                        free(argv[i])
                    }
                }

                var envpStorage = environment.map { strdup($0) as UnsafeMutablePointer<CChar>? }
                envpStorage.append(nil)
                defer { envpStorage.compactMap({ $0 }).forEach { free($0) } }

                if let cwd = workingDirectory {
                    return cwd.withCString { cwdCStr in
                        pty_fork_exec(slaveFD, masterFD, execCStr, &argv, &envpStorage, cwdCStr)
                    }
                } else {
                    return pty_fork_exec(slaveFD, masterFD, execCStr, &argv, &envpStorage, nil)
                }
            }
        }
    }

    /// Query the current working directory of the child process.
    public var currentWorkingDirectory: String? {
        guard childPID > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard pty_get_cwd(childPID, &buf, Int32(buf.count)) == 0 else { return nil }
        return String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8($0) }, as: UTF8.self)
    }

    /// Query the name of the foreground process running in this PTY.
    public var foregroundProcessName: String? {
        guard masterFD >= 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 17) // MAXCOMLEN + 1
        guard pty_get_foreground_process_name(masterFD, &buf, Int32(buf.count)) == 0 else {
            return nil
        }
        return String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8($0) }, as: UTF8.self)
    }

    // MARK: - Private: Read Source

    private func startReadSource() {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)

        // Allocate read buffer once; freed in cancel handler
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.readBufSize)

        // Track consecutive full-buffer reads to detect bulk output (e.g. cat).
        var consecutiveFullReads = 0

        source.setEventHandler { [weak self] in
            guard let self else { return }

            // Adaptive time budget: use longer budget during sustained bulk output
            // to improve throughput, shorter budget during interactive use to keep
            // main-thread responsive.
            let budgetMs = consecutiveFullReads >= Self.bulkReadThreshold ? Self.bulkBudgetMs : Self.readBudgetMs
            let deadline = DispatchTime.now() + .milliseconds(budgetMs)
            while true {
                let n = Darwin.read(fd, buf, Self.readBufSize)
                if n > 0 {
                    consecutiveFullReads = n >= Self.readBufSize ? consecutiveFullReads + 1 : 0
                    let bufPtr = UnsafeBufferPointer(start: buf, count: n)
                    self.onRead?(bufPtr)
                    if DispatchTime.now() >= deadline { break }
                } else if n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    consecutiveFullReads = 0
                    break
                } else if n == -1 && errno == EINTR {
                    continue  // Interrupted by signal (e.g. SIGWINCH) — retry
                } else {
                    // EOF (n==0) or fatal error — cancel to prevent busy-spin
                    source.cancel()
                    break
                }
            }
        }

        source.setCancelHandler {
            buf.deallocate()
        }

        source.resume()
        readSource = source
    }

    // MARK: - Private: Process Monitor

    private func startProcessMonitor() {
        let pid = childPID
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            // Swift can't call WEXITSTATUS/WTERMSIG C macros directly
            let exitCode: Int32
            if (status & 0x7F) == 0 {
                exitCode = (status >> 8) & 0xFF
            } else {
                exitCode = -(status & 0x7F)
            }
            self.onExit?(exitCode)
        }

        source.resume()
        processSource = source
    }

    // MARK: - Private: Shell & Environment

    private static func resolveShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    private static func buildEnvironment(shellPath: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        if env["LANG"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        if shellPath.hasSuffix("/zsh") || shellPath.hasSuffix("/zsh5") {
            ShellIntegrationInjector.injectZsh(into: &env)
        }
        return env.map { "\($0.key)=\($0.value)" }
    }
}

// MARK: - Errors

public enum PTYError: Error {
    case openptyFailed(Int32)
    case forkFailed(Int32)
}
