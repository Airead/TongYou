import Foundation
import TYProtocol
import TYTerminal

/// Represents a single connected client.
///
/// Runs a read loop on a dedicated queue. Sending is serialized via writeQueue.
/// Screen update distribution is handled by SocketServer's single update timer,
/// not per-client timers (avoids snapshot consumption races).
///
/// Backpressure: screen update messages (.screenFull, .screenDiff) are dropped
/// when the writeQueue has more than `maxPendingScreenUpdates` such messages
/// pending. Non-screen messages are always delivered.
public final class ClientConnection: @unchecked Sendable {

    let id: UUID
    private let socket: TYSocket
    private let maxPendingScreenUpdates: Int

    private var attachedSessions: Set<SessionID> = []
    private let sessionsLock = NSLock()
    nonisolated(unsafe) private var disconnected = false

    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue

    /// Number of screen update messages currently queued in writeQueue.
    private var pendingScreenCount: Int = 0
    private let pendingLock = NSLock()

    var onMessage: ((ClientMessage) -> Void)?
    var onDisconnect: (() -> Void)?

    init(socket: TYSocket, maxPendingScreenUpdates: Int = 3) {
        self.id = UUID()
        self.socket = socket
        self.maxPendingScreenUpdates = maxPendingScreenUpdates
        self.readQueue = DispatchQueue(
            label: "io.github.airead.tongyou.client.\(id.uuidString.prefix(8)).read",
            qos: .userInteractive
        )
        self.writeQueue = DispatchQueue(
            label: "io.github.airead.tongyou.client.\(id.uuidString.prefix(8)).write",
            qos: .userInteractive
        )
        Log.info("Client connected: \(id.uuidString.prefix(8))", category: .client)
    }

    // MARK: - Lifecycle

    func startReadLoop() {
        readQueue.async { [weak self] in
            self?.readLoop()
        }
    }

    func stop() {
        socket.closeSocket()
        Log.info("Client stopped: \(id.uuidString.prefix(8))", category: .client)
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
    ///
    /// Screen update messages are subject to backpressure: if more than
    /// `maxPendingScreenUpdates` are already queued, the message is dropped.
    /// Non-screen messages (session lifecycle, layout, etc.) are always sent.
    func send(_ message: ServerMessage) {
        Log.debug("SEND [\(id.uuidString.prefix(8))] \(message.debugDescription)", category: .client)
        let isScreen = message.isScreenUpdate
        if isScreen {
            pendingLock.lock()
            if pendingScreenCount >= maxPendingScreenUpdates {
                pendingLock.unlock()
                Log.debug(
                    "Dropping screen update for client \(id.uuidString.prefix(8)): \(pendingScreenCount) pending",
                    category: .client
                )
                return
            }
            pendingScreenCount += 1
            pendingLock.unlock()
        }

        writeQueue.async { [weak self] in
            guard let self else { return }
            if isScreen {
                self.pendingLock.lock()
                self.pendingScreenCount -= 1
                self.pendingLock.unlock()
            }
            do {
                try self.socket.send(message)
            } catch {
                Log.error(
                    "Send failed for client \(self.id.uuidString.prefix(8)): \(error)",
                    category: .client
                )
                self.handleDisconnect()
            }
        }
    }

    // MARK: - Stats

    /// Current number of screen update messages pending in the write queue.
    var pendingScreenUpdateCount: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingScreenCount
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
        Log.info("Client disconnected: \(id.uuidString.prefix(8))", category: .client)
        onDisconnect?()
    }
}

// MARK: - ScreenDiff Conversion

extension ScreenDiff {
    /// Convert a ScreenSnapshot into a ScreenDiff using its dirty region.
    public init(from snapshot: ScreenSnapshot, mouseTrackingMode: UInt8 = 0) {
        let rows: [UInt16]
        let cells: [Cell]

        if snapshot.isPartial {
            rows = snapshot.partialRows.map { UInt16($0.row) }
            var buf: [Cell] = []
            buf.reserveCapacity(rows.count * snapshot.columns)
            for (_, rowCells) in snapshot.partialRows {
                buf.append(contentsOf: rowCells)
            }
            cells = buf
        } else {
            let dirty = snapshot.dirtyRegion.dirtyRows
            if !dirty.isEmpty {
                rows = dirty.map { UInt16($0) }
                var buf: [Cell] = []
                buf.reserveCapacity(rows.count * snapshot.columns)
                for row in dirty {
                    let offset = row * snapshot.columns
                    buf.append(contentsOf: snapshot.cells[offset..<(offset + snapshot.columns)])
                }
                cells = buf
            } else {
                // fullRebuild or no dirty info — send all rows.
                rows = (0..<UInt16(snapshot.rows)).map { $0 }
                cells = snapshot.cells
            }
        }

        self.init(
            dirtyRows: rows,
            cellData: cells,
            columns: UInt16(snapshot.columns),
            cursorCol: UInt16(snapshot.cursorCol),
            cursorRow: UInt16(snapshot.cursorRow),
            cursorVisible: snapshot.cursorVisible,
            cursorShape: snapshot.cursorShape,
            scrollbackCount: snapshot.scrollbackCount,
            viewportOffset: snapshot.viewportOffset,
            mouseTrackingMode: mouseTrackingMode,
            scrollDelta: Int16(clamping: snapshot.dirtyRegion.scrollDelta)
        )
    }
}
