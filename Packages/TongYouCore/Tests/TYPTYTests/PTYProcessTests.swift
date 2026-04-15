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
