import Foundation
import TYProtocol
import TYTerminal

/// Represents a single connected client.
///
/// Runs a read loop on a dedicated queue. Sending is serialized via writeQueue.
/// Screen update distribution is handled by SocketServer's single update timer,
/// not per-client timers (avoids snapshot consumption races).
public final class ClientConnection: @unchecked Sendable {

    let id: UUID
    private let socket: TYSocket

    private var attachedSessions: Set<SessionID> = []
    private let sessionsLock = NSLock()
    nonisolated(unsafe) private var disconnected = false

    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue

    var onMessage: ((ClientMessage) -> Void)?
    var onDisconnect: (() -> Void)?

    init(socket: TYSocket) {
        self.id = UUID()
        self.socket = socket
        self.readQueue = DispatchQueue(
            label: "io.github.airead.tongyou.client.\(id.uuidString.prefix(8)).read",
            qos: .userInteractive
        )
        self.writeQueue = DispatchQueue(
            label: "io.github.airead.tongyou.client.\(id.uuidString.prefix(8)).write",
            qos: .userInteractive
        )
    }

    // MARK: - Lifecycle

    func startReadLoop() {
        readQueue.async { [weak self] in
            self?.readLoop()
        }
    }

    func stop() {
        socket.closeSocket()
    }

    // MARK: - Session Attachment

    func attach(sessionID: SessionID) {
        sessionsLock.lock()
        attachedSessions.insert(sessionID)
        sessionsLock.unlock()
    }

    func detach(sessionID: SessionID) {
        sessionsLock.lock()
        attachedSessions.remove(sessionID)
        sessionsLock.unlock()
    }

    func isAttached(to sessionID: SessionID) -> Bool {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return attachedSessions.contains(sessionID)
    }

    // MARK: - Send

    /// Send a server message to this client. Thread-safe (serialized via writeQueue).
    func send(_ message: ServerMessage) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.socket.send(message)
            } catch {
                self.handleDisconnect()
            }
        }
    }

    // MARK: - Private

    private func readLoop() {
        while true {
            do {
                let message = try socket.receiveClientMessage()
                onMessage?(message)
            } catch {
                handleDisconnect()
                return
            }
        }
    }

    private func handleDisconnect() {
        sessionsLock.lock()
        let alreadyDisconnected = disconnected
        disconnected = true
        sessionsLock.unlock()
        guard !alreadyDisconnected else { return }
        onDisconnect?()
    }
}

// MARK: - ScreenDiff Conversion

extension ScreenDiff {
    /// Convert a ScreenSnapshot into a ScreenDiff using its dirty region.
    public init(from snapshot: ScreenSnapshot) {
        let rows: [UInt16]
        let cells: [Cell]

        if let range = snapshot.dirtyRegion.lineRange {
            let lower = max(0, range.lowerBound)
            let upper = min(snapshot.rows, range.upperBound)
            rows = (lower..<upper).map { UInt16($0) }

            var buf: [Cell] = []
            buf.reserveCapacity(rows.count * snapshot.columns)
            for row in rows {
                let offset = Int(row) * snapshot.columns
                buf.append(contentsOf: snapshot.cells[offset..<(offset + snapshot.columns)])
            }
            cells = buf
        } else {
            rows = (0..<UInt16(snapshot.rows)).map { $0 }
            cells = snapshot.cells
        }

        self.init(
            dirtyRows: rows,
            cellData: cells,
            columns: UInt16(snapshot.columns),
            cursorCol: UInt16(snapshot.cursorCol),
            cursorRow: UInt16(snapshot.cursorRow),
            cursorVisible: snapshot.cursorVisible,
            cursorShape: snapshot.cursorShape
        )
    }
}
