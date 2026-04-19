import Foundation
import TYConfig
import TYTerminal

// MARK: - Debug Helpers

private func truncate(_ string: String, maxLength: Int) -> String {
    if string.count <= maxLength { return string }
    return "\(string.prefix(maxLength))... (len=\(string.count))"
}

// MARK: - Message Type Codes

/// Wire type codes for server-to-client messages (0x01xx).
public enum ServerMessageType: UInt16, Sendable {
    // Authentication
    case handshakeResult = 0x0180

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
    case cwdChanged      = 0x0123
    case layoutUpdate    = 0x0130
    case clipboardSet    = 0x0131
}

/// Wire type codes for client-to-server messages (0x02xx).
public enum ClientMessageType: UInt16, Sendable {
    // Authentication
    case handshake       = 0x0280

    // Session management
    case listSessions    = 0x0200
    case createSession   = 0x0201
    case attachSession   = 0x0202
    case detachSession   = 0x0203
    case closeSession    = 0x0204
    case renameSession   = 0x0205

    // Terminal I/O (hot path)
    case input           = 0x0210
    case resize          = 0x0211
    case scrollViewport  = 0x0212
    case extractSelection = 0x0213
    case mouseEvent      = 0x0214

    // Tab/Pane operations
    case createTab       = 0x0220
    case closeTab        = 0x0221
    case splitPane       = 0x0222
    case closePane       = 0x0223
    case focusPane       = 0x0224

    case selectTab       = 0x022A
    case setSplitRatio   = 0x022F

    // Floating pane operations
    case createFloatingPane       = 0x0225
    case closeFloatingPane        = 0x0226
    case updateFloatingPaneFrame  = 0x0227
    case bringFloatingPaneToFront = 0x0228
    case toggleFloatingPanePin    = 0x0229

    // Command execution (daemon-side)
    case runInPlace               = 0x022B
    case runRemoteCommand         = 0x022C
    // 0x022D was createFloatingPaneWithCommand; removed in Phase 7.2. Decoders
    // receiving this opcode must report it as an unknown message type.
    case restartFloatingPaneCommand    = 0x022E
    /// Rerun a tree pane's command in place, reusing the pane's
    /// `StartupSnapshot`. The server keeps the `PaneID` stable; the
    /// existing `TerminalCore` is stopped and replaced. Phase 8.2.
    case rerunPane                     = 0x0230
    /// Move a pane within its tab's tree, landing on a specific side of
    /// the target pane. Plan §P4.3.
    case movePane                      = 0x0231
    /// Rewrite the tab that owns a given pane into a single flat
    /// container using the requested strategy (plan §P4.5). The pane
    /// identifies which tab to rewrite; every leaf is re-parented under
    /// one new container with equal weights.
    case changeStrategy                = 0x0232
}

// MARK: - Server Messages

/// Messages sent from server to client (GUI).
public enum ServerMessage: Sendable {
    // Authentication
    case handshakeResult(success: Bool)

    // Session lifecycle
    case sessionList([SessionInfo])
    case sessionCreated(SessionInfo)
    case sessionClosed(SessionID)

    // Screen updates (hot path)
    case screenFull(SessionID, PaneID, ScreenSnapshot, mouseTrackingMode: UInt8)
    case screenDiff(SessionID, PaneID, ScreenDiff)

    // Events
    case titleChanged(SessionID, PaneID, String)
    case cwdChanged(SessionID, PaneID, String)
    case bell(SessionID, PaneID)
    case paneExited(SessionID, PaneID, exitCode: Int32)
    case layoutUpdate(SessionInfo)
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
        case .handshakeResult(let success):
            return "handshakeResult(success=\(success))"
        case .sessionList(let sessions):
            return "sessionList(count=\(sessions.count))"
        case .sessionCreated(let info):
            return "sessionCreated(id=\(info.id))"
        case .sessionClosed(let id):
            return "sessionClosed(id=\(id))"
        case .screenFull(let sid, let pid, let snap, let mtm):
            return "screenFull(session=\(sid), pane=\(pid), \(snap.columns)x\(snap.rows), cells=\(snap.cells.count), mouse=\(mtm))"
        case .screenDiff(let sid, let pid, let diff):
            return "screenDiff(session=\(sid), pane=\(pid), dirtyRows=\(diff.dirtyRows.count), cells=\(diff.cellData.count), mouse=\(diff.mouseTrackingMode))"
        case .titleChanged(let sid, let pid, let title):
            return "titleChanged(session=\(sid), pane=\(pid), title=\(truncate(title, maxLength: 80)))"
        case .cwdChanged(let sid, let pid, let cwd):
            return "cwdChanged(session=\(sid), pane=\(pid), cwd=\(truncate(cwd, maxLength: 80)))"
        case .bell(let sid, let pid):
            return "bell(session=\(sid), pane=\(pid))"
        case .paneExited(let sid, let pid, let exitCode):
            return "paneExited(session=\(sid), pane=\(pid), exitCode=\(exitCode))"
        case .layoutUpdate(let info):
            return "layoutUpdate(session=\(info.id), tabs=\(info.tabs.count))"
        case .clipboardSet(let text):
            return "clipboardSet(text=\(truncate(text, maxLength: 80)))"
        }
    }

    /// The wire type code for this message.
    public var typeCode: ServerMessageType {
        switch self {
        case .handshakeResult: return .handshakeResult
        case .sessionList:    return .sessionList
        case .sessionCreated: return .sessionCreated
        case .sessionClosed:  return .sessionClosed
        case .screenFull:     return .screenFull
        case .screenDiff:     return .screenDiff
        case .titleChanged:   return .titleChanged
        case .cwdChanged:     return .cwdChanged
        case .bell:           return .bell
        case .paneExited:     return .paneExited
        case .layoutUpdate:   return .layoutUpdate
        case .clipboardSet:   return .clipboardSet
        }
    }
}

// MARK: - Client Messages

/// Messages sent from client (GUI) to server.
public enum ClientMessage: Sendable {
    // Authentication
    case handshake(token: String)

    // Session management
    case listSessions
    case createSession(name: String?)
    case attachSession(SessionID)
    case detachSession(SessionID)
    case closeSession(SessionID)
    case renameSession(SessionID, name: String)

    // Terminal I/O (hot path)
    case input(SessionID, PaneID, [UInt8])
    case resize(SessionID, PaneID, cols: UInt16, rows: UInt16)
    /// Scroll viewport: positive = up (older), negative = down (newer), Int32.max = jump to bottom.
    case scrollViewport(SessionID, PaneID, delta: Int32)
    /// Extract selected text from a pane (server replies with .clipboardSet).
    case extractSelection(SessionID, PaneID, Selection)
    /// Mouse event forwarded to the server for encoding and PTY delivery.
    case mouseEvent(SessionID, PaneID, MouseEncoder.Event)

    // Tab/Pane operations
    /// Create a new tab. If `profileID` and `snapshot` are nil the server
    /// inherits the focused pane's cwd (current behavior). When non-nil,
    /// `snapshot` fully drives PTY launch and `profileID` is stored as a label.
    case createTab(SessionID, profileID: String?, snapshot: StartupSnapshot?)
    case closeTab(SessionID, TabID)
    /// Split a pane. Same semantics as `createTab`: when `snapshot` is non-nil
    /// the new pane ignores parent inheritance and uses the snapshot directly.
    case splitPane(SessionID, PaneID, SplitDirection, profileID: String?, snapshot: StartupSnapshot?)
    case closePane(SessionID, PaneID)
    case focusPane(SessionID, PaneID)
    case selectTab(SessionID, tabIndex: UInt16)
    /// Adjust the split ratio at the node directly containing `paneID` as a
    /// leaf child. `ratio` is the target pane's share in `(0.0, 1.0)`.
    case setSplitRatio(SessionID, PaneID, ratio: Float)

    // Floating pane operations
    /// Create a floating pane. `profileID`/`snapshot` follow the same
    /// semantics as `createTab`. `frameHint` optionally supplies initial
    /// normalized geometry; when nil the server picks a default frame.
    case createFloatingPane(SessionID, TabID, profileID: String?, snapshot: StartupSnapshot?, frameHint: FloatFrameHint?)
    case closeFloatingPane(SessionID, PaneID)
    case updateFloatingPaneFrame(SessionID, PaneID, x: Float, y: Float, width: Float, height: Float)
    case bringFloatingPaneToFront(SessionID, PaneID)
    case toggleFloatingPanePin(SessionID, PaneID)

    // Command execution (daemon-side)
    /// Run a command in-place: suspend the active shell, run command, restore on exit.
    case runInPlace(SessionID, PaneID, command: String, arguments: [String])
    /// Run a command in the background on the daemon (fire-and-forget, output discarded).
    case runRemoteCommand(SessionID, PaneID, command: String, arguments: [String])
    /// Restart a command in an existing (exited) floating pane.
    case restartFloatingPaneCommand(SessionID, PaneID, command: String, arguments: [String])
    /// Re-run the command in a tree pane, reusing the pane's original
    /// `StartupSnapshot`. Pairs with the local `rerunTreePaneCommand`
    /// path; server keeps the `PaneID` stable so the client does not
    /// rebuild the layout.
    case rerunPane(SessionID, PaneID)
    /// Relocate `source` so it sits on `side` of `target` in the same
    /// tab (plan §P4.3). Both panes must already exist in the tab's tree.
    /// The server updates the tree and broadcasts `layoutUpdate`.
    case movePane(SessionID, sourcePaneID: PaneID, targetPaneID: PaneID, side: FocusDirection)
    /// Rewrite the tab that owns `paneID` into a single flat container
    /// using the requested `LayoutStrategyKind` (plan §P4.5). `paneID`
    /// identifies the target tab; the rewrite itself is whole-tree —
    /// every leaf is re-parented under one fresh container with equal
    /// weights. Container identities are not transmitted in
    /// `LayoutTree` messages so this opcode deliberately avoids
    /// referencing specific nested containers.
    case changeStrategy(SessionID, PaneID, LayoutStrategyKind)

    /// Human-readable summary for debug logging. Long payloads are truncated.
    public var debugDescription: String {
        switch self {
        case .handshake:
            return "handshake(token=***)"
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
        case .renameSession(let id, let name):
            return "renameSession(id=\(id), name=\(truncate(name, maxLength: 80)))"
        case .input(let sid, let pid, let bytes):
            let preview = bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            let suffix = bytes.count > 32 ? "... (len=\(bytes.count))" : ""
            return "input(session=\(sid), pane=\(pid), data=[\(preview)\(suffix)])"
        case .resize(let sid, let pid, let cols, let rows):
            return "resize(session=\(sid), pane=\(pid), \(cols)x\(rows))"
        case .scrollViewport(let sid, let pid, let delta):
            return "scrollViewport(session=\(sid), pane=\(pid), delta=\(delta))"
        case .extractSelection(let sid, let pid, let sel):
            let (s, e) = sel.ordered
            return "extractSelection(session=\(sid), pane=\(pid), [\(s.line):\(s.col)..\(e.line):\(e.col)])"
        case .mouseEvent(let sid, let pid, let event):
            return "mouseEvent(session=\(sid), pane=\(pid), action=\(event.action), col=\(event.col), row=\(event.row))"
        case .createTab(let sid, let profileID, let snapshot):
            return "createTab(session=\(sid), profile=\(profileID ?? "nil"), hasSnapshot=\(snapshot != nil))"
        case .closeTab(let sid, let tid):
            return "closeTab(session=\(sid), tab=\(tid))"
        case .splitPane(let sid, let pid, let dir, let profileID, let snapshot):
            return "splitPane(session=\(sid), pane=\(pid), dir=\(dir), profile=\(profileID ?? "nil"), hasSnapshot=\(snapshot != nil))"
        case .closePane(let sid, let pid):
            return "closePane(session=\(sid), pane=\(pid))"
        case .focusPane(let sid, let pid):
            return "focusPane(session=\(sid), pane=\(pid))"
        case .selectTab(let sid, let tabIndex):
            return "selectTab(session=\(sid), tabIndex=\(tabIndex))"
        case .setSplitRatio(let sid, let pid, let ratio):
            return "setSplitRatio(session=\(sid), pane=\(pid), ratio=\(ratio))"
        case .createFloatingPane(let sid, let tid, let profileID, let snapshot, let frameHint):
            return "createFloatingPane(session=\(sid), tab=\(tid), profile=\(profileID ?? "nil"), hasSnapshot=\(snapshot != nil), hasFrameHint=\(frameHint != nil))"
        case .closeFloatingPane(let sid, let pid):
            return "closeFloatingPane(session=\(sid), pane=\(pid))"
        case .updateFloatingPaneFrame(let sid, let pid, let x, let y, let w, let h):
            return "updateFloatingPaneFrame(session=\(sid), pane=\(pid), frame=(\(x),\(y),\(w),\(h)))"
        case .bringFloatingPaneToFront(let sid, let pid):
            return "bringFloatingPaneToFront(session=\(sid), pane=\(pid))"
        case .toggleFloatingPanePin(let sid, let pid):
            return "toggleFloatingPanePin(session=\(sid), pane=\(pid))"
        case .runInPlace(let sid, let pid, let cmd, let args):
            return "runInPlace(session=\(sid), pane=\(pid), cmd=\(truncate(cmd, maxLength: 80)), args=\(args))"
        case .runRemoteCommand(let sid, let pid, let cmd, let args):
            return "runRemoteCommand(session=\(sid), pane=\(pid), cmd=\(truncate(cmd, maxLength: 80)), args=\(args))"
        case .restartFloatingPaneCommand(let sid, let pid, let cmd, let args):
            return "restartFloatingPaneCommand(session=\(sid), pane=\(pid), cmd=\(truncate(cmd, maxLength: 80)), args=\(args))"
        case .rerunPane(let sid, let pid):
            return "rerunPane(session=\(sid), pane=\(pid))"
        case .movePane(let sid, let source, let target, let side):
            return "movePane(session=\(sid), source=\(source), target=\(target), side=\(side))"
        case .changeStrategy(let sid, let pid, let kind):
            return "changeStrategy(session=\(sid), pane=\(pid), kind=\(kind.rawValue))"
        }
    }

    /// The wire type code for this message.
    public var typeCode: ClientMessageType {
        switch self {
        case .handshake:      return .handshake
        case .listSessions:   return .listSessions
        case .createSession:  return .createSession
        case .attachSession:  return .attachSession
        case .detachSession:  return .detachSession
        case .closeSession:   return .closeSession
        case .renameSession:  return .renameSession
        case .input:          return .input
        case .resize:         return .resize
        case .scrollViewport: return .scrollViewport
        case .extractSelection: return .extractSelection
        case .mouseEvent:     return .mouseEvent
        case .createTab:      return .createTab
        case .closeTab:       return .closeTab
        case .splitPane:      return .splitPane
        case .closePane:      return .closePane
        case .focusPane:      return .focusPane
        case .selectTab:      return .selectTab
        case .setSplitRatio:  return .setSplitRatio
        case .createFloatingPane:       return .createFloatingPane
        case .closeFloatingPane:        return .closeFloatingPane
        case .updateFloatingPaneFrame:  return .updateFloatingPaneFrame
        case .bringFloatingPaneToFront: return .bringFloatingPaneToFront
        case .toggleFloatingPanePin:    return .toggleFloatingPanePin
        case .runInPlace:              return .runInPlace
        case .runRemoteCommand:        return .runRemoteCommand
        case .restartFloatingPaneCommand:    return .restartFloatingPaneCommand
        case .rerunPane:                     return .rerunPane
        case .movePane:                      return .movePane
        case .changeStrategy:                return .changeStrategy
        }
    }
}
