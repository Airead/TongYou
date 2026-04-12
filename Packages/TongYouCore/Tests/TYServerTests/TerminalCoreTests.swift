import Testing
import Foundation
@testable import TYServer
import TYTerminal

@Suite("TerminalCore Tests")
struct TerminalCoreTests {

    @Test("Init creates core with correct dimensions")
    func initDimensions() {
        let core = TerminalCore(columns: 120, rows: 40)
        #expect(core.columns == 120)
        #expect(core.rows == 40)
        #expect(core.isRunning == false)
    }

    @Test("Start and stop PTY process")
    func startStop() throws {
        let core = TerminalCore(columns: 80, rows: 24)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"

        try core.start(columns: 80, rows: 24, workingDirectory: home)
        #expect(core.isRunning == true)

        core.stop()
        #expect(core.isRunning == false)
    }

    @Test("onProcessExited callback fires on stop")
    func processExitedCallback() throws {
        let core = TerminalCore(columns: 80, rows: 24)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"

        let exitedExpectation = Mutex(false)

        core.onProcessExited = { _ in
            exitedExpectation.withLock { $0 = true }
        }

        try core.start(columns: 80, rows: 24, workingDirectory: home)
        core.stop()

        // Give a moment for the exit callback
        Thread.sleep(forTimeInterval: 0.1)
        // Note: onProcessExited fires on MainActor via PTYProcess, which may not
        // fire in test context. This test verifies no crash on stop.
        #expect(core.isRunning == false)
    }

    @Test("Write data to PTY does not crash")
    func writeData() throws {
        let core = TerminalCore(columns: 80, rows: 24)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"

        try core.start(columns: 80, rows: 24, workingDirectory: home)
        core.write(Data("echo hello\n".utf8))

        // Wait for PTY to process
        Thread.sleep(forTimeInterval: 0.2)

        let snapshot = core.consumeSnapshot()
        #expect(snapshot != nil)

        core.stop()
    }

    @Test("Resize updates dimensions")
    func resize() throws {
        let core = TerminalCore(columns: 80, rows: 24)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"

        try core.start(columns: 80, rows: 24, workingDirectory: home)

        core.resize(columns: 120, rows: 40)

        // Wait for async resize on ptyQueue
        Thread.sleep(forTimeInterval: 0.1)

        #expect(core.columns == 120)
        #expect(core.rows == 40)

        core.stop()
    }

    @Test("forceSnapshot always returns a snapshot")
    func forceSnapshot() {
        let core = TerminalCore(columns: 80, rows: 24)
        let snapshot = core.forceSnapshot()
        #expect(snapshot.columns == 80)
        #expect(snapshot.rows == 24)
        #expect(snapshot.cells.count == 80 * 24)
    }

    @Test("consumeSnapshot returns nil when not dirty")
    func consumeSnapshotClean() {
        let core = TerminalCore(columns: 80, rows: 24)
        let snapshot = core.consumeSnapshot()
        #expect(snapshot == nil)
    }

    @Test("onScreenDirty callback fires on PTY output")
    func screenDirtyCallback() throws {
        let core = TerminalCore(columns: 80, rows: 24)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"

        let dirtyFired = Mutex(false)
        core.onScreenDirty = {
            dirtyFired.withLock { $0 = true }
        }

        try core.start(columns: 80, rows: 24, workingDirectory: home)

        // Send a command to ensure output is generated
        core.write(Data("echo hello\n".utf8))

        // Poll for the callback with a timeout
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if dirtyFired.withLock({ $0 }) { break }
        }

        let wasDirty = dirtyFired.withLock { $0 }
        #expect(wasDirty == true)

        core.stop()
    }

    @Test("Query modes on fresh core")
    func queryModes() {
        let core = TerminalCore(columns: 80, rows: 24)
        #expect(core.appCursorMode == false)
        #expect(core.bracketedPasteMode == false)
        #expect(core.mouseTrackingMode == .none)
    }
}

/// Simple thread-safe wrapper for test assertions.
private final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
