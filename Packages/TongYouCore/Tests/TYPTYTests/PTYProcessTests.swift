import Foundation
import Testing
@testable import TYPTY

@Suite("PTYProcess Tests", .serialized)
struct PTYProcessTests {

    @Test
    func startWithCommandOutputsCorrectResult() async throws {
        let pty = PTYProcess(readQueue: .global(qos: .userInitiated))
        var outputData = Data()
        let semaphore = DispatchSemaphore(value: 0)

        pty.onRead = { bytes in
            outputData.append(contentsOf: bytes)
        }

        pty.onExit = { _ in
            semaphore.signal()
        }

        try pty.start(command: "/bin/echo", arguments: ["hello_from_pty"], columns: 80, rows: 24)

        await waitForSemaphore(semaphore)

        let output = String(data: outputData, encoding: .utf8) ?? ""
        #expect(output.contains("hello_from_pty"), "Expected output to contain 'hello_from_pty', got: \(output)")
    }

    @Test
    func startWithCommandSupportsBidirectionalCommunication() async throws {
        let pty = PTYProcess(readQueue: .global(qos: .userInitiated))
        var outputData = Data()
        let semaphore = DispatchSemaphore(value: 0)

        pty.onRead = { bytes in
            outputData.append(contentsOf: bytes)
            semaphore.signal()
        }

        try pty.start(command: "/bin/cat", columns: 80, rows: 24)

        let input = Data("echo_test\n".utf8)
        pty.write(input)

        await waitForSemaphore(semaphore)

        let output = String(data: outputData, encoding: .utf8) ?? ""
        #expect(output.contains("echo_test"), "Expected echo output to contain 'echo_test', got: \(output)")

        pty.stop()
    }

    @Test
    func startWithDefaultShellStillWorks() async throws {
        let pty = PTYProcess(readQueue: .global(qos: .userInitiated))
        var outputData = Data()
        let semaphore = DispatchSemaphore(value: 0)

        pty.onRead = { bytes in
            outputData.append(contentsOf: bytes)
            semaphore.signal()
        }

        try pty.start(columns: 80, rows: 24)

        let input = Data("echo shell_ok\n".utf8)
        pty.write(input)

        await waitForSemaphore(semaphore)

        let output = String(data: outputData, encoding: .utf8) ?? ""
        #expect(output.contains("shell_ok"), "Expected shell output to contain 'shell_ok', got: \(output)")

        pty.stop()
    }

    // MARK: - Environment preparation

    /// Regression guard: the host terminal's TERM_PROGRAM / LC_TERMINAL must
    /// be stripped before the child shell sees them. Leaving them in place
    /// made claude code pick a ghostty-specific render path that relied on
    /// synchronized-output (mode 2026) and produced a split-pane rendering
    /// corruption bug.
    @Test
    func prepareEnvironmentAdvertisesTongYouAndStripsHostHints() {
        let hostEnv: [String: String] = [
            "TERM": "xterm-ghostty",
            "TERM_PROGRAM": "ghostty",
            "TERM_PROGRAM_VERSION": "1.3.1",
            "COLORTERM": "truecolor",
            "LC_TERMINAL": "iTerm2",
            "LC_TERMINAL_VERSION": "3.4.19",
            "PATH": "/usr/bin:/bin",
        ]
        let result = PTYProcess.prepareEnvironment(
            shellPath: "/bin/bash",
            baseEnvironment: hostEnv
        )

        #expect(result["TERM"] == "xterm-256color")
        #expect(result["TERM_PROGRAM"] == "TongYou")
        #expect(result["COLORTERM"] == "truecolor")
        #expect(result["TERM_PROGRAM_VERSION"] == nil)
        #expect(result["LC_TERMINAL"] == nil)
        #expect(result["LC_TERMINAL_VERSION"] == nil)
        // Unrelated variables pass through untouched.
        #expect(result["PATH"] == "/usr/bin:/bin")
    }

    @Test
    func prepareEnvironmentFillsLangWhenMissing() {
        let result = PTYProcess.prepareEnvironment(
            shellPath: "/bin/bash",
            baseEnvironment: [:]
        )
        #expect(result["LANG"] == "en_US.UTF-8")
    }

    @Test
    func prepareEnvironmentPreservesExistingLang() {
        let result = PTYProcess.prepareEnvironment(
            shellPath: "/bin/bash",
            baseEnvironment: ["LANG": "zh_CN.UTF-8"]
        )
        #expect(result["LANG"] == "zh_CN.UTF-8")
    }

    @Test
    func prepareEnvironmentAppliesExtraEnvLast() {
        let result = PTYProcess.prepareEnvironment(
            shellPath: "/bin/bash",
            baseEnvironment: ["FOO": "base"],
            extraEnv: [("FOO", "override"), ("BAR", "added")]
        )
        #expect(result["FOO"] == "override")
        #expect(result["BAR"] == "added")
    }

    /// extraEnv must be able to override the TongYou-advertised TERM_PROGRAM
    /// when a caller (e.g. a profile, a test) explicitly asks for a different
    /// value. Without this guarantee, snapshot-driven PTY launches couldn't
    /// customize terminal identity.
    @Test
    func prepareEnvironmentExtraEnvCanOverrideTermProgram() {
        let result = PTYProcess.prepareEnvironment(
            shellPath: "/bin/bash",
            baseEnvironment: [:],
            extraEnv: [("TERM_PROGRAM", "MyCustomTerm")]
        )
        #expect(result["TERM_PROGRAM"] == "MyCustomTerm")
    }
}

private func waitForSemaphore(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 5) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let result = semaphore.wait(timeout: .now() + timeout)
            #expect(result == .success)
            continuation.resume()
        }
    }
}
