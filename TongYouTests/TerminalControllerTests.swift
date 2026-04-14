import Foundation
import Testing
import TYTerminal
@testable import TongYou

@Suite("TerminalController", .serialized)
struct TerminalControllerTests {

    @Test
    @MainActor
    func startWithCommandRendersOutput() async throws {
        let controller = TerminalController(columns: 80, rows: 24)
        let semaphore = DispatchSemaphore(value: 0)

        controller.onProcessExited = {
            semaphore.signal()
        }

        controller.start(command: "/bin/echo", arguments: ["controller_hello"])

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let result = semaphore.wait(timeout: .now() + 5)
                #expect(result == .success, "Process did not exit in time")
                continuation.resume()
            }
        }

        // Give a moment for the final bytes to be processed
        try await Task.sleep(for: .milliseconds(100))

        let snapshot = controller.consumeSnapshot()
        #expect(snapshot != nil, "Expected a snapshot")
        let text = extractText(from: snapshot)
        #expect(text.contains("controller_hello"), "Expected screen to contain 'controller_hello', got: \(text)")
    }

    @Test
    @MainActor
    func startWithCommandSupportsBidirectionalCommunication() async throws {
        let controller = TerminalController(columns: 80, rows: 24)
        let semaphore = DispatchSemaphore(value: 0)
        var capturedSnapshot: ScreenSnapshot?

        controller.onNeedsDisplay = {
            // onNeedsDisplay is called on ptyQueue; avoid calling consumeSnapshot
            // directly because it uses ptyQueue.sync. Bounce to main queue.
            DispatchQueue.main.async {
                if let s = controller.consumeSnapshot() {
                    capturedSnapshot = s
                    let text = extractText(from: s)
                    if text.contains("cat_echo") {
                        semaphore.signal()
                    }
                }
            }
        }

        controller.start(command: "/bin/cat")
        controller.sendText("cat_echo\n")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let result = semaphore.wait(timeout: .now() + 5)
                #expect(result == .success, "Did not receive echoed output in time")
                continuation.resume()
            }
        }

        let text = extractText(from: capturedSnapshot)
        #expect(text.contains("cat_echo"), "Expected screen to contain 'cat_echo', got: \(text)")

        controller.stop()
    }

    @Test
    @MainActor
    func startWithDefaultShellStillWorks() async throws {
        let controller = TerminalController(columns: 80, rows: 24)
        let semaphore = DispatchSemaphore(value: 0)
        var capturedSnapshot: ScreenSnapshot?

        controller.onNeedsDisplay = {
            DispatchQueue.main.async {
                if let s = controller.consumeSnapshot() {
                    capturedSnapshot = s
                    let text = extractText(from: s)
                    if text.contains("shell_works") {
                        semaphore.signal()
                    }
                }
            }
        }

        controller.start()
        controller.sendText("echo shell_works\n")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let result = semaphore.wait(timeout: .now() + 5)
                #expect(result == .success, "Did not receive shell output in time")
                continuation.resume()
            }
        }

        let text = extractText(from: capturedSnapshot)
        #expect(text.contains("shell_works"), "Expected screen to contain 'shell_works', got: \(text)")

        controller.stop()
    }
}

private func extractText(from snapshot: ScreenSnapshot?) -> String {
    guard let snapshot = snapshot else { return "" }
    var lines: [String] = []
    for row in 0..<snapshot.rows {
        var line = ""
        for col in 0..<snapshot.columns {
            let cell = snapshot.cell(at: col, row: row)
            if cell.width.isRenderable {
                line.append(cell.content.string)
            }
        }
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}
