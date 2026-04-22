import XCTest
@testable import TongYou

final class PTYWriteTests: XCTestCase {

    // MARK: - Helpers

    /// Create a PTY pair for testing with raw mode enabled.
    /// Returns (master, slave) file descriptors.
    private func openTestPTY() throws -> (master: Int32, slave: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw NSError(domain: "PTYWriteTests", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "openpty failed"])
        }
        // Set raw mode so the line discipline doesn't buffer or transform data.
        var attrs = termios()
        tcgetattr(slave, &attrs)
        cfmakeraw(&attrs)
        tcsetattr(slave, TCSANOW, &attrs)
        return (master, slave)
    }

    /// Write all bytes to a non-blocking fd, using poll to handle EAGAIN.
    /// Mirrors the retry logic in PTYProcess.write().
    private func writeAll(fd: Int32, data: Data) {
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
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ret = poll(&pfd, 1, 1000)
                    if ret > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                        continue
                    }
                    break
                }
                break
            }
        }
    }

    /// Read all available data from a non-blocking fd, retrying on EAGAIN.
    /// Waits up to `timeout` seconds for data to arrive.
    private func readAll(fd: Int32, expected: Int, timeout: TimeInterval = 2.0) -> Data {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var result = Data()
        let deadline = Date().addingTimeInterval(timeout)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }

        while result.count < expected && Date() < deadline {
            let n = Darwin.read(fd, buf, 4096)
            if n > 0 {
                result.append(buf, count: n)
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                poll(&pfd, 1, 50)
            } else {
                break
            }
        }
        return result
    }

    // MARK: - Tests

    /// Verify that the poll-based write loop delivers all bytes, even for large
    /// payloads that exceed the kernel PTY buffer in a single call.
    func testWriteDeliversAllBytes() throws {
        let pty = try openTestPTY()
        defer {
            close(pty.master)
            close(pty.slave)
        }

        let flags = fcntl(pty.master, F_GETFL)
        _ = fcntl(pty.master, F_SETFL, flags | O_NONBLOCK)

        let payloadSize = 128 * 1024
        let payload = Data(repeating: 0x41, count: payloadSize)

        let writeQueue = DispatchQueue(label: "test.pty.write")
        let writeDone = expectation(description: "write completed")

        writeQueue.async {
            self.writeAll(fd: pty.master, data: payload)
            writeDone.fulfill()
        }

        let received = readAll(fd: pty.slave, expected: payloadSize, timeout: 5.0)
        wait(for: [writeDone], timeout: 6.0)

        XCTAssertEqual(received.count, payloadSize,
                       "Expected \(payloadSize) bytes but received \(received.count)")
        XCTAssertEqual(received, payload, "Received data content does not match sent payload")
    }

    /// Verify that bracketed paste sequences survive a large paste intact.
    func testBracketedPasteSequenceIntact() throws {
        let pty = try openTestPTY()
        defer {
            close(pty.master)
            close(pty.slave)
        }

        let flags = fcntl(pty.master, F_GETFL)
        _ = fcntl(pty.master, F_SETFL, flags | O_NONBLOCK)

        let bracketStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC[200~
        let bracketEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]   // ESC[201~
        let innerSize = 64 * 1024
        var payload = Data(bracketStart)
        payload.append(Data(repeating: 0x61, count: innerSize))
        payload.append(Data(bracketEnd))

        let totalSize = payload.count
        let writeQueue = DispatchQueue(label: "test.pty.write")
        let writeDone = expectation(description: "write completed")

        writeQueue.async {
            self.writeAll(fd: pty.master, data: payload)
            writeDone.fulfill()
        }

        let received = readAll(fd: pty.slave, expected: totalSize, timeout: 5.0)
        wait(for: [writeDone], timeout: 6.0)

        XCTAssertEqual(received.count, totalSize,
                       "Expected \(totalSize) bytes but received \(received.count)")
        XCTAssertEqual(received, payload, "Received data content does not match sent payload")

        let receivedStart = Array(received.prefix(bracketStart.count))
        let receivedEnd = Array(received.suffix(bracketEnd.count))
        XCTAssertEqual(receivedStart, bracketStart, "Bracketed paste start sequence missing")
        XCTAssertEqual(receivedEnd, bracketEnd, "Bracketed paste end sequence missing")
    }
}
