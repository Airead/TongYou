import Foundation

/// Thread-safe file log writer with daily rotation.
///
/// All mutable state is protected by an internal serial dispatch queue.
/// Safe to call from any thread.
public final class FileLogWriter: @unchecked Sendable {

    public let filePrefix: String
    public let queue: DispatchQueue

    /// Override for the log directory. When set, logs write here instead of
    /// the default `~/.local/share/TongYou/logs`. Intended for testing.
    public nonisolated(unsafe) var logDirectoryOverride: URL?

    // MARK: - State (queue-protected)

    private nonisolated(unsafe) var fileHandle: FileHandle?
    private nonisolated(unsafe) var currentDateString: String?

    // MARK: - Formatters

    private static let dateOnlyFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    // MARK: - Init

    public init(filePrefix: String, queueLabel: String) {
        self.filePrefix = filePrefix
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
    }

    // MARK: - Public API

    /// Open today's log file asynchronously on the internal queue.
    public func openFile() {
        queue.async { [self] in
            self.openFileSync()
        }
    }

    /// Close the current log file synchronously (blocks until queue drains).
    public func closeFile() {
        queue.sync { [self] in
            self.closeFileSync()
        }
    }

    /// Block until all pending writes are flushed.
    public func flush() {
        queue.sync {}
    }

    /// Write a pre-formatted line to the log file. Automatically rolls to a
    /// new file if the date has changed and lazily opens the file handle.
    public func writeLine(_ line: String, date: Date = Date()) {
        queue.async { [self] in
            self.rollDateIfNeeded(date)
            if self.fileHandle == nil {
                self.openFileSync()
            }
            guard let handle = self.fileHandle else { return }
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        }
    }

    // MARK: - Private

    private func logDirectory() -> URL {
        if let override = logDirectoryOverride {
            return override
        }
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".local/share/TongYou/logs")
    }

    private func logFilePath(for dateString: String) -> URL {
        logDirectory().appendingPathComponent("\(filePrefix)-\(dateString).log")
    }

    private func openFileSync() {
        let dateString = Self.dateOnlyFormatter.string(from: Date())
        let dir = logDirectory()
        let filePath = logFilePath(for: dateString)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: filePath.path) {
                FileManager.default.createFile(atPath: filePath.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: filePath)
            handle.seekToEndOfFile()
            fileHandle = handle
            currentDateString = dateString
        } catch {
            fputs("[\(filePrefix)] Failed to open log file: \(error)\n", stderr)
        }
    }

    private func closeFileSync() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        currentDateString = nil
    }

    private func rollDateIfNeeded(_ now: Date) {
        let dateString = Self.dateOnlyFormatter.string(from: now)
        if dateString != currentDateString {
            closeFileSync()
            openFileSync()
        }
    }
}
