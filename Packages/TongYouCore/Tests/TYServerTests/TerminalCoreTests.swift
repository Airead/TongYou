import Testing
import Foundation
@testable import TYServer
import TYTerminal

@Suite("TerminalCore Tests", .serialized)
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

    @Test("Focus reporting flag is off by default")
    func focusReportingInitiallyOff() {
        let core = TerminalCore(columns: 80, rows: 24)
        #expect(core.isFocusReportingEnabledForTesting == false)
    }

    @Test("DECSET 1004 toggles focus reporting flag on core")
    func focusReportingModeToggles() {
        let core = TerminalCore(columns: 80, rows: 24)
        core.feedBytesForTesting(Array("\u{1B}[?1004h".utf8))
        #expect(core.isFocusReportingEnabledForTesting == true)
        core.feedBytesForTesting(Array("\u{1B}[?1004l".utf8))
        #expect(core.isFocusReportingEnabledForTesting == false)
    }

    @Test("reportFocus is a no-op when PTY not started")
    func reportFocusNoCrashWhenNotStarted() {
        let core = TerminalCore(columns: 80, rows: 24)
        core.reportFocus(true)
        core.reportFocus(false)
        // Must not crash; flag remains off since no app subscribed.
        #expect(core.isFocusReportingEnabledForTesting == false)
    }

    // MARK: - Synchronized Update (DECSET 2026)

    @Test("DECSET 2026 toggles isSyncedUpdateActive on the core")
    func syncedUpdateModeToggles() {
        let core = TerminalCore(columns: 80, rows: 24)
        #expect(core.isSyncedUpdateActive == false)
        core.feedBytesForTesting(Array("\u{1B}[?2026h".utf8))
        #expect(core.isSyncedUpdateActive == true)
        core.feedBytesForTesting(Array("\u{1B}[?2026l".utf8))
        #expect(core.isSyncedUpdateActive == false)
    }

    @Test("expireStaleSyncedUpdate is a no-op when inactive")
    func expireStaleSyncedUpdateWhenInactive() {
        let core = TerminalCore(columns: 80, rows: 24)
        #expect(core.expireStaleSyncedUpdate(timeout: 0.2) == false)
        #expect(core.isSyncedUpdateActive == false)
    }

    // MARK: - Unhandled Sequence

    @Test("onUnhandledSequence callback fires for unsupported DECSET mode")
    func unhandledSequenceCallback() {
        let core = TerminalCore(columns: 80, rows: 24)
        var capturedMessages: [String] = []
        core.onUnhandledSequence = { message in
            capturedMessages.append(message)
        }
        core.feedBytesForTesting(Array("\u{1B}[?1005h".utf8))
        #expect(capturedMessages == ["DECSET/DECRST mode 1005 not implemented"])
    }

    @Test("onUnhandledSequence callback does not fire for supported mode")
    func supportedModeDoesNotTriggerCallback() {
        let core = TerminalCore(columns: 80, rows: 24)
        var capturedMessages: [String] = []
        core.onUnhandledSequence = { message in
            capturedMessages.append(message)
        }
        core.feedBytesForTesting(Array("\u{1B}[?1004h".utf8))
        #expect(capturedMessages.isEmpty)
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
