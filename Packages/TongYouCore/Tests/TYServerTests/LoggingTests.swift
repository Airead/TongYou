import Testing
import Foundation
@testable import TYServer

@Suite("Log file backend", .serialized)
struct LoggingTests {

    @Test func daemonModeWritesToFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        Log.logDirectoryOverride = dir
        Log.configure(daemonize: true, minLevel: .debug)
        defer {
            Log.updateFileLogging(level: nil, categories: nil)
            Log.configure(daemonize: false, minLevel: .info)
            Log.logDirectoryOverride = nil
        }

        Log.debug("hello-daemon", category: .cursorTrace)
        Log.flush()

        let contents = try readSingleLogFile(in: dir)
        #expect(contents.contains("hello-daemon"))
        #expect(contents.contains("[cursorTrace]"))
    }

    @Test func foregroundModeDoesNotWriteFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        Log.logDirectoryOverride = dir
        Log.configure(daemonize: false, minLevel: .debug)
        defer {
            Log.logDirectoryOverride = nil
        }

        Log.debug("should-not-be-in-file")
        Log.flush()

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.isEmpty)
    }

    @Test func updateFileLoggingOffDisablesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        Log.logDirectoryOverride = dir
        Log.configure(daemonize: true, minLevel: .debug)
        defer {
            Log.updateFileLogging(level: nil, categories: nil)
            Log.configure(daemonize: false, minLevel: .info)
            Log.logDirectoryOverride = nil
        }

        Log.debug("first-line", category: .server)
        Log.flush()

        Log.updateFileLogging(level: nil, categories: nil)
        Log.debug("after-disable", category: .server)
        Log.flush()

        let contents = try readSingleLogFile(in: dir)
        #expect(contents.contains("first-line"))
        #expect(!contents.contains("after-disable"))
    }

    @Test func categoryFilterSuppressesOthers() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        Log.logDirectoryOverride = dir
        Log.configure(daemonize: true, minLevel: .debug)
        Log.updateFileLogging(level: .debug, categories: [.cursorTrace])
        defer {
            Log.updateFileLogging(level: nil, categories: nil)
            Log.configure(daemonize: false, minLevel: .info)
            Log.logDirectoryOverride = nil
        }

        Log.debug("in-scope", category: .cursorTrace)
        Log.debug("out-of-scope", category: .server)
        Log.flush()

        let contents = try readSingleLogFile(in: dir)
        #expect(contents.contains("in-scope"))
        #expect(!contents.contains("out-of-scope"))
    }

    @Test func levelFilterSuppressesBelow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        Log.logDirectoryOverride = dir
        Log.configure(daemonize: true, minLevel: .debug)
        Log.updateFileLogging(level: .warning, categories: nil)
        defer {
            Log.updateFileLogging(level: nil, categories: nil)
            Log.configure(daemonize: false, minLevel: .info)
            Log.logDirectoryOverride = nil
        }

        Log.debug("dropped-debug")
        Log.warning("kept-warning")
        Log.flush()

        let contents = try readSingleLogFile(in: dir)
        #expect(!contents.contains("dropped-debug"))
        #expect(contents.contains("kept-warning"))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tongyou-log-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readSingleLogFile(in dir: URL) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("daemon-") }
        guard let file = files.first else {
            Issue.record("expected a daemon-*.log file in \(dir.path)")
            return ""
        }
        return try String(contentsOf: file, encoding: .utf8)
    }
}
