#if canImport(Darwin)
import Darwin
private let sysRecv = Darwin.recv
private let sysSend = Darwin.send
#elseif canImport(Glibc)
import Glibc
private let sysRecv = Glibc.recv
private let sysSend = Glibc.send
#endif

import Foundation

/// Newline-delimited I/O over a raw file descriptor.
///
/// The GUI automation protocol is line-based JSON: each request/response is
/// one UTF-8 JSON object terminated by `\n`. `LineIO` buffers partial reads
/// and yields a complete line at a time.
public final class LineIO {
    public enum IOError: Error {
        case recvFailed(errno: Int32)
        case sendFailed(errno: Int32)
        case connectionClosed
        case invalidUTF8
    }

    private let fd: Int32
    private var pending: [UInt8] = []

    public init(fd: Int32) {
        self.fd = fd
    }

    /// Read a single line (without the trailing `\n`). Returns nil on EOF.
    public func readLine() throws -> String? {
        if let line = try drainLineFromBuffer() { return line }

        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { buf in
                sysRecv(fd, buf.baseAddress, buf.count, 0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw IOError.recvFailed(errno: errno)
            }
            if n == 0 {
                // EOF — if buffer has leftover bytes, surface them as the last line.
                if pending.isEmpty { return nil }
                let tail = pending
                pending.removeAll(keepingCapacity: false)
                guard let line = String(bytes: tail, encoding: .utf8) else {
                    throw IOError.invalidUTF8
                }
                return line
            }
            pending.append(contentsOf: chunk[..<n])
            if let line = try drainLineFromBuffer() { return line }
        }
    }

    /// Write a full line followed by `\n`. Blocks until complete or throws.
    public func writeLine(_ line: String) throws {
        var data = Array(line.utf8)
        data.append(0x0A)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBufferPointer { buf in
                sysSend(fd, buf.baseAddress! + offset, buf.count - offset, 0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw IOError.sendFailed(errno: errno)
            }
            if n == 0 {
                throw IOError.connectionClosed
            }
            offset += n
        }
    }

    private func drainLineFromBuffer() throws -> String? {
        guard let newlineIdx = pending.firstIndex(of: 0x0A) else { return nil }
        let lineBytes = pending[..<newlineIdx]
        guard let line = String(bytes: lineBytes, encoding: .utf8) else {
            pending.removeSubrange(...newlineIdx)
            throw IOError.invalidUTF8
        }
        pending.removeSubrange(...newlineIdx)
        return line
    }
}
