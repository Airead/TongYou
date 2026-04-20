#if canImport(Darwin)
import Darwin
private let sysClose = Darwin.close
private let sysListen = Darwin.listen
private let sysAccept = Darwin.accept
private let sysConnect = Darwin.connect
private let sysSend = Darwin.send
private let sysRecv = Darwin.recv
#elseif canImport(Glibc)
import Glibc
private let sysClose = Glibc.close
private let sysListen = Glibc.listen
private let sysAccept = Glibc.accept
private let sysConnect = Glibc.connect
private let sysSend = Glibc.send
private let sysRecv = Glibc.recv
#endif

import Foundation

/// Errors from socket operations.
public enum TYSocketError: Error, Sendable {
    case socketCreationFailed(errno: Int32)
    case bindFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)
    case connectFailed(path: String, errno: Int32)
    case acceptFailed(errno: Int32)
    case sendFailed(errno: Int32)
    case receiveFailed(errno: Int32)
    case connectionClosed
    case pathTooLong(path: String, maxLength: Int)
    case peerCredentialsFailed(errno: Int32)
}

/// Unix domain socket wrapper for TongYou protocol communication.
///
/// Provides frame-level send/receive over a Unix domain socket.
/// Use `listen(path:)` on the server side and `connect(path:)` on the client side.
///
/// Thread safety:
/// - `closeSocket()` may race with `accept()` / `send` / `recv` /
///   `peerCredentials` on different threads (e.g. a shutdown on the main
///   queue while `acceptLoop()` blocks in `accept()`). `_fileDescriptor`
///   is guarded by `fdLock`; each method captures the fd into a local
///   under the lock and runs the syscall outside it, so close races
///   deterministically produce `EBADF` rather than a torn read.
public final class TYSocket: @unchecked Sendable {
    /// Backing storage for the fd. Always accessed under `fdLock`.
    private nonisolated(unsafe) var _fileDescriptor: Int32
    private let fdLock = NSLock()

    /// The underlying file descriptor, for integration with DispatchSource.
    /// Returns the current fd, or `-1` if the socket has been closed.
    public var fileDescriptor: Int32 {
        fdLock.withLock { _fileDescriptor }
    }

    private init(fileDescriptor: Int32) {
        self._fileDescriptor = fileDescriptor
    }

    deinit {
        // Safe to read without the lock: refcount has reached zero, so no
        // other thread holds a reference to `self`.
        if _fileDescriptor >= 0 {
            _ = sysClose(_fileDescriptor)
        }
    }

    // MARK: - Factory Methods

    /// Create a listening socket on a Unix domain socket path.
    /// Removes any existing socket file at the path before binding.
    public static func listen(path: String, backlog: Int32 = 5) throws -> TYSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TYSocketError.socketCreationFailed(errno: errno)
        }

        var addr = try makeUnixAddr(path: path)

        // Remove stale socket file if it exists.
        unlink(path)

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            _ = sysClose(fd)
            throw TYSocketError.bindFailed(path: path, errno: errno)
        }

        // Restrict socket file to owner-only access (0600).
        chmod(path, 0o600)

        guard sysListen(fd, backlog) == 0 else {
            _ = sysClose(fd)
            throw TYSocketError.listenFailed(errno: errno)
        }

        return TYSocket(fileDescriptor: fd)
    }

    /// Accept a new client connection from a listening socket (blocking).
    public func accept() throws -> TYSocket {
        let fd = fdLock.withLock { _fileDescriptor }
        let clientFD = sysAccept(fd, nil, nil)
        guard clientFD >= 0 else {
            throw TYSocketError.acceptFailed(errno: errno)
        }
        return TYSocket(fileDescriptor: clientFD)
    }

    /// Connect to a Unix domain socket at the given path.
    public static func connect(path: String) throws -> TYSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TYSocketError.socketCreationFailed(errno: errno)
        }

        var addr = try makeUnixAddr(path: path)

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                sysConnect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            _ = sysClose(fd)
            throw TYSocketError.connectFailed(path: path, errno: errno)
        }

        return TYSocket(fileDescriptor: fd)
    }

    // MARK: - Frame I/O

    /// Send a complete frame (header + payload) over the socket.
    public func sendFrame(_ frameBytes: [UInt8]) throws {
        try sendAll(frameBytes)
    }

    /// Send a `ServerMessage` as a framed message.
    public func send(_ message: ServerMessage) throws {
        let frame = WireFormat.encodeServerMessage(message)
        try sendFrame(frame)
    }

    /// Send a `ClientMessage` as a framed message.
    public func send(_ message: ClientMessage) throws {
        let frame = WireFormat.encodeClientMessage(message)
        try sendFrame(frame)
    }

    /// Receive a raw frame from the socket (blocking).
    public func receiveFrame() throws -> RawFrame {
        let headerBytes = try recvAll(count: WireFormat.headerSize)
        let (typeCode, payloadLength) = try WireFormat.parseHeader(headerBytes)

        let payload: [UInt8]
        if payloadLength > 0 {
            payload = try recvAll(count: Int(payloadLength))
        } else {
            payload = []
        }

        return RawFrame(typeCode: typeCode, payload: payload)
    }

    /// Receive and decode a `ServerMessage` (blocking).
    public func receiveServerMessage() throws -> ServerMessage {
        let frame = try receiveFrame()
        return try WireFormat.decodeServerMessage(frame)
    }

    /// Receive and decode a `ClientMessage` (blocking).
    public func receiveClientMessage() throws -> ClientMessage {
        let frame = try receiveFrame()
        return try WireFormat.decodeClientMessage(frame)
    }

    /// Return the effective UID and GID of the connected peer.
    /// Only valid on accepted client sockets (Unix domain).
    public func peerCredentials() throws -> (uid: uid_t, gid: gid_t) {
        let fd = fdLock.withLock { _fileDescriptor }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw TYSocketError.peerCredentialsFailed(errno: errno)
        }
        return (uid, gid)
    }

    /// Close the socket. Safe to call multiple times.
    public func closeSocket() {
        // Atomically swap out the fd so concurrent readers either see a
        // valid fd or `-1` — never a torn value. `sysClose` runs outside
        // the lock to keep the critical section minimal.
        let oldFD = fdLock.withLock { () -> Int32 in
            let fd = _fileDescriptor
            if fd >= 0 { _fileDescriptor = -1 }
            return fd
        }
        if oldFD >= 0 {
            _ = sysClose(oldFD)
        }
    }

    // MARK: - Internal Helpers

    private func sendAll(_ data: [UInt8]) throws {
        let fd = fdLock.withLock { _fileDescriptor }
        var totalSent = 0
        while totalSent < data.count {
            let sent = data.withUnsafeBufferPointer { buf in
                sysSend(
                    fd,
                    buf.baseAddress! + totalSent,
                    data.count - totalSent,
                    0
                )
            }
            if sent <= 0 {
                if sent == 0 { throw TYSocketError.connectionClosed }
                if errno == EINTR { continue }
                throw TYSocketError.sendFailed(errno: errno)
            }
            totalSent += sent
        }
    }

    private func recvAll(count: Int) throws -> [UInt8] {
        let fd = fdLock.withLock { _fileDescriptor }
        var buffer = [UInt8](repeating: 0, count: count)
        var totalRead = 0
        while totalRead < count {
            let n = buffer.withUnsafeMutableBufferPointer { buf in
                sysRecv(
                    fd,
                    buf.baseAddress! + totalRead,
                    count - totalRead,
                    0
                )
            }
            if n <= 0 {
                if n == 0 { throw TYSocketError.connectionClosed }
                if errno == EINTR { continue }
                throw TYSocketError.receiveFailed(errno: errno)
            }
            totalRead += n
        }
        return buffer
    }

    private static func makeUnixAddr(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else {
            throw TYSocketError.pathTooLong(path: path, maxLength: maxLen)
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: UInt8.self, capacity: maxLen + 1) { dst in
                for (i, byte) in path.utf8.enumerated() {
                    dst[i] = byte
                }
                dst[path.utf8.count] = 0
            }
        }

        return addr
    }
}
