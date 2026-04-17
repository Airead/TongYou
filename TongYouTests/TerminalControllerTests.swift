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

        controller.onProcessExited = { _ in
            semaphore.signal()
        }

        controller.start(command: "/bin/echo", arguments: ["controller_hello"])

        await waitForSemaphore(semaphore)

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

        await waitForSemaphore(semaphore)

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

        await waitForSemaphore(semaphore)

        let text = extractText(from: capturedSnapshot)
        #expect(text.contains("shell_works"), "Expected screen to contain 'shell_works', got: \(text)")

        controller.stop()
    }

    @Test
    @MainActor
    func suspendAndResumeAccumulatesOutput() async throws {
        let controller = TerminalController(columns: 80, rows: 24)
        var displayCallCount = 0
        var capturedRows: [Int: String] = [:]

        controller.onNeedsDisplay = {
            displayCallCount += 1
            DispatchQueue.main.async {
                if let s = controller.consumeSnapshot() {
                    for (row, line) in extractRows(from: s) {
                        capturedRows[row] = line
                    }
                }
            }
        }

        controller.start(command: "/bin/cat")

        // Wait for initial display callback to settle
        try await Task.sleep(for: .milliseconds(50))
        let callCountAfterStart = displayCallCount

        controller.sendText("before_suspend\n")
        try await Task.sleep(for: .milliseconds(100))
        #expect(displayCallCount > callCountAfterStart, "Expected onNeedsDisplay after writing")

        controller.suspend()
        let callCountAfterSuspend = displayCallCount

        controller.sendText("during_suspend\n")
        try await Task.sleep(for: .milliseconds(100))
        #expect(displayCallCount == callCountAfterSuspend, "Expected no onNeedsDisplay while suspended")

        controller.resume()
        try await Task.sleep(for: .milliseconds(50))
        #expect(displayCallCount > callCountAfterSuspend, "Expected onNeedsDisplay immediately after resume")

        let text = capturedRows.sorted { $0.key < $1.key }.map { $0.value }.joined(separator: "\n")
        #expect(text.contains("before_suspend"), "Expected screen to contain 'before_suspend', got: \(text)")
        #expect(text.contains("during_suspend"), "Expected screen to contain 'during_suspend', got: \(text)")

        controller.stop()
    }

    @Test
    @MainActor
    func paneNotificationBridgeFires() async throws {
        let controller = TerminalController(columns: 80, rows: 24)
        let semaphore = DispatchSemaphore(value: 0)
        var captured: (title: String, body: String)?

        controller.onPaneNotification = { title, body in
            captured = (title, body)
            semaphore.signal()
        }

        controller.start(command: "/bin/bash", arguments: ["-c", "printf '\\e]9;Build;Done\\a'"])

        await waitForSemaphore(semaphore)

        #expect(captured?.title == "Build")
        #expect(captured?.body == "Done")

        controller.stop()
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

private func extractRows(from snapshot: ScreenSnapshot) -> [Int: String] {
    if snapshot.isPartial {
        var rows: [Int: String] = [:]
        for (row, cells) in snapshot.partialRows {
            var line = ""
            for cell in cells {
                if cell.width.isRenderable {
                    line.append(cell.content.string)
                }
            }
            rows[row] = line
        }
        return rows
    } else {
        var rows: [Int: String] = [:]
        for row in 0..<snapshot.rows {
            var line = ""
            for col in 0..<snapshot.columns {
                let cell = snapshot.cell(at: col, row: row)
                if cell.width.isRenderable {
                    line.append(cell.content.string)
                }
            }
            rows[row] = line
        }
        return rows
    }
}

private func extractText(from snapshot: ScreenSnapshot?) -> String {
    guard let snapshot = snapshot else { return "" }
    let rows = extractRows(from: snapshot)
    return rows.sorted { $0.key < $1.key }.map { $0.value }.joined(separator: "\n")
}
