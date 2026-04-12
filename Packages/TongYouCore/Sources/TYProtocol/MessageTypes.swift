import Foundation
import TYTerminal

// MARK: - Debug Helpers

private func truncate(_ string: String, maxLength: Int) -> String {
    if string.count <= maxLength { return string }
    return "\(string.prefix(maxLength))... (len=\(string.count))"
}

// MARK: - Message Type Codes

/// Wire type codes for server-to-client messages (0x01xx).
public enum ServerMessageType: UInt16, Sendable {
    // Session lifecycle
    case sessionList     = 0x0100
    case sessionCreated  = 0x0101
    case sessionClosed   = 0x0102

    // Screen updates (hot path)
    case screenFull      = 0x0110
    case screenDiff      = 0x0111

    // Events
    case titleChanged    = 0x0120
    case bell            = 0x0121
    case paneExited      = 0x0122
    case layoutUpdate    = 0x0130
    case clipboardSet    = 0x0131
}

/// Wire type codes for client-to-server messages (0x02xx).
public enum ClientMessageType: UInt16, Sendable {
    // Session management
    case listSessions    = 0x0200
    case createSession   = 0x0201
    case attachSession   = 0x0202
    case detachSession   = 0x0203
    case closeSession    = 0x0204

    // Terminal I/O (hot path)
    case input           = 0x0210
    case resize          = 0x0211

    // Tab/Pane operations
    case createTab       = 0x0220
    case closeTab        = 0x0221
    case splitPane       = 0x0222
    case closePane       = 0x0223
    case focusPane       = 0x0224
}

// MARK: - Server Messages

/// Messages sent from server (tyd) to client (GUI).
public enum ServerMessage: Sendable {
    // Session lifecycle
    case sessionList([SessionInfo])
    case sessionCreated(SessionInfo)
    case sessionClosed(SessionID)

    // Screen updates (hot path)
    case screenFull(SessionID, PaneID, ScreenSnapshot)
    case screenDiff(SessionID, PaneID, ScreenDiff)

    // Events
    case titleChanged(SessionID, PaneID, String)
    case bell(SessionID, PaneID)
    case paneExited(SessionID, PaneID, exitCode: Int32)
    case layoutUpdate(SessionID, LayoutTree)
    case clipboardSet(String)

    /// Whether this message is a screen update (screenFull or screenDiff).
    /// Screen updates are high-frequency and can be safely dropped under backpressure
    /// since the next timer tick will send fresh data.
    public var isScreenUpdate: Bool {
        switch self {
        case .screenFull, .screenDiff: return true
        default: return false
        }
    }

    /// Human-readable summary for debug logging. Long payloads are truncated.
    public var debugDescription: String {
        switch self {
        case .sessionList(let sessions):
            return "sessionList(count=\(sessions.count))"
        case .sessionCreated(let info):
            return "sessionCreated(id=\(info.id))"
        case .sessionClosed(let id):
            return "sessionClosed(id=\(id))"
        case .screenFull(let sid, let pid, let snap):
            return "screenFull(session=\(sid), pane=\(pid), \(snap.columns)x\(snap.rows), cells=\(snap.cells.count))"
        case .screenDiff(let sid, let pid, let diff):
            return "screenDiff(session=\(sid), pane=\(pid), dirtyRows=\(diff.dirtyRows.count), cells=\(diff.cellData.count))"
        case .titleChanged(let sid, let pid, let title):
            return "titleChanged(session=\(sid), pane=\(pid), title=\(truncate(title, maxLength: 80)))"
        case .bell(let sid, let pid):
            return "bell(session=\(sid), pane=\(pid))"
        case .paneExited(let sid, let pid, let exitCode):
            return "paneExited(session=\(sid), pane=\(pid), exitCode=\(exitCode))"
        case .layoutUpdate(let sid, _):
            return "layoutUpdate(session=\(sid))"
        case .clipboardSet(let text):
            return "clipboardSet(text=\(truncate(text, maxLength: 80)))"
        }
    }

    /// The wire type code for this message.
    public var typeCode: ServerMessageType {
        switch self {
        case .sessionList:    return .sessionList
        case .sessionCreated: return .sessionCreated
        case .sessionClosed:  return .sessionClosed
        case .screenFull:     return .screenFull
        case .screenDiff:     return .screenDiff
        case .titleChanged:   return .titleChanged
        case .bell:           return .bell
        case .paneExited:     return .paneExited
        case .layoutUpdate:   return .layoutUpdate
        case .clipboardSet:   return .clipboardSet
        }
    }
}

// MARK: - Client Messages

/// Messages sent from client (GUI) to server (tyd).
public enum ClientMessage: Sendable {
    // Session management
    case listSessions
    case createSession(name: String?)
    case attachSession(SessionID)
    case detachSession(SessionID)
    case closeSession(SessionID)

    // Terminal I/O (hot path)
    case input(SessionID, PaneID, [UInt8])
    case resize(SessionID, PaneID, cols: UInt16, rows: UInt16)

    // Tab/Pane operations
    case createTab(SessionID)
    case closeTab(SessionID, TabID)
    case splitPane(SessionID, PaneID, SplitDirection)
    case closePane(SessionID, PaneID)
    case focusPane(SessionID, PaneID)

    /// Human-readable summary for debug logging. Long payloads are truncated.
    public var debugDescription: String {
        switch self {
        case .listSessions:
            return "listSessions"
        case .createSession(let name):
            return "createSession(name=\(name ?? "nil"))"
        case .attachSession(let id):
            return "attachSession(id=\(id))"
        case .detachSession(let id):
            return "detachSession(id=\(id))"
        case .closeSession(let id):
            return "closeSession(id=\(id))"
        case .input(let sid, let pid, let bytes):
            let preview = bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            let suffix = bytes.count > 32 ? "... (len=\(bytes.count))" : ""
            return "input(session=\(sid), pane=\(pid), data=[\(preview)\(suffix)])"
        case .resize(let sid, let pid, let cols, let rows):
            return "resize(session=\(sid), pane=\(pid), \(cols)x\(rows))"
        case .createTab(let sid):
            return "createTab(session=\(sid))"
        case .closeTab(let sid, let tid):
            return "closeTab(session=\(sid), tab=\(tid))"
        case .splitPane(let sid, let pid, let dir):
            return "splitPane(session=\(sid), pane=\(pid), dir=\(dir))"
        case .closePane(let sid, let pid):
            return "closePane(session=\(sid), pane=\(pid))"
        case .focusPane(let sid, let pid):
            return "focusPane(session=\(sid), pane=\(pid))"
        }
    }

    /// The wire type code for this message.
    public var typeCode: ClientMessageType {
        switch self {
        case .listSessions:   return .listSessions
        case .createSession:  return .createSession
        case .attachSession:  return .attachSession
        case .detachSession:  return .detachSession
        case .closeSession:   return .closeSession
        case .input:          return .input
        case .resize:         return .resize
        case .createTab:      return .createTab
        case .closeTab:       return .closeTab
        case .splitPane:      return .splitPane
        case .closePane:      return .closePane
        case .focusPane:      return .focusPane
        }
    }
}
