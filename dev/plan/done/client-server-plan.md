# TongYou Client/Server Architecture Plan

## Overview

Refactor TongYou into a client/server architecture where a daemon process (`tyd`) manages PTY sessions independently of the GUI. The GUI becomes a client that connects/disconnects via Unix domain socket without interrupting running programs.

Similar to: zellij, tmux, screen.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Protocol format | Custom binary framing | Best latency; no external deps |
| Transport | Unix domain socket | Cross-platform (macOS + Linux); no TCP needed |
| Socket path | `$XDG_RUNTIME_DIR/tongyou/tyd.sock` | XDG standard on all platforms |
| Auto-start | GUI auto-starts tyd (configurable) | Zero-config UX for most users |
| Screen transfer | Incremental diffs + full snapshot on attach | Leverage existing DirtyRegion |

## Current State (Phase 4 Complete)

```
TongYou/
├── Packages/TongYouCore/          # Cross-platform Swift Package
│   ├── Sources/TYTerminal/        # Screen, VTParser, StreamHandler, data models
│   ├── Sources/TYPTY/             # PTYProcess (macOS + Linux)
│   ├── Sources/TYPTYC/            # C helpers: pty_fork, cwd/fg process query
│   └── Sources/TYShell/           # Shell integration scripts + injector
├── TongYou/                       # macOS GUI app
│   ├── Terminal/TerminalController.swift  # Orchestrator (still in app, has AppKit deps)
│   ├── App/SessionManager.swift          # Session/tab/pane management (@Observable)
│   ├── Renderer/                         # Metal rendering
│   └── ...
└── TongYouTests/
```

**What moved to TongYouCore:** Screen, VTParser, StreamHandler, Cell/CellAttributes, Selection, KeyEncoder, MouseEncoder, TerminalModes, URLDetector, PTYProcess, ShellIntegration, session/tab/pane data models (TerminalSession, TerminalTab, TerminalPane, PaneNode, FloatingPane).

**What remains in App:** TerminalController (AppKit clipboard/URL/bell), SessionManager (@Observable), MetalView/MetalRenderer, SwiftUI views, Config/Theme.

---

## Phase 2: Protocol Layer (TYProtocol)

### Goal
Define the binary wire protocol and socket abstraction in a new `TYProtocol` module.

### Wire Format

```
┌──────────────┬──────────────┬──────────────┬────────────────────┐
│ Magic (2B)   │ Type (2B)    │ Length (4B)   │ Payload (N bytes) │
│ 0x54 0x59    │ LE uint16    │ LE uint32     │ Codable binary    │
└──────────────┴──────────────┴──────────────┴────────────────────┘
```

- Magic bytes `TY` for frame alignment / corruption detection.
- Max payload: 1 MB (reject larger frames).
- Payload encoding: custom binary (avoid Codable JSON overhead for hot path).

### Message Types

```swift
// Server → Client
public enum ServerMessage {
    // Session lifecycle
    case sessionList([SessionInfo])
    case sessionCreated(SessionInfo)
    case sessionClosed(SessionID)

    // Screen updates (hot path — must be fast)
    case screenFull(SessionID, PaneID, ScreenSnapshot)
    case screenDiff(SessionID, PaneID, ScreenDiff)

    // Events
    case titleChanged(SessionID, PaneID, String)
    case bell(SessionID, PaneID)
    case paneExited(SessionID, PaneID, exitCode: Int32)
    case layoutUpdate(SessionID, LayoutTree)
    case clipboardSet(String)  // OSC 52
}

// Client → Server
public enum ClientMessage {
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
}
```

### ScreenDiff Design

```swift
public struct ScreenDiff {
    /// Row indices that changed (relative to viewport).
    let dirtyRows: [UInt16]
    /// Flattened cell data for dirty rows only (cols × dirtyRows.count cells).
    let cellData: [Cell]
    /// Cursor state (always included).
    let cursorCol: UInt16
    let cursorRow: UInt16
    let cursorVisible: Bool
    let cursorShape: CursorShape
}
```

- Full snapshot on attach/reconnect (~20KB for 120×40).
- Incremental diffs during normal operation (typically 1-3 dirty rows, ~500B).
- Use existing `DirtyRegion` from Screen to determine which rows to send.

### Socket Abstraction

```swift
public final class TYSocket {
    /// Connect to a Unix domain socket.
    static func connect(path: String) throws -> TYSocket

    /// Listen on a Unix domain socket, accept connections.
    static func listen(path: String) throws -> TYSocket

    /// Send a framed message.
    func send(_ message: some TYMessage) throws

    /// Receive a framed message (blocking).
    func receive() throws -> (type: UInt16, payload: Data)

    /// File descriptor for integration with DispatchSource.
    var fileDescriptor: Int32 { get }
}
```

### Files to Create

```
Packages/TongYouCore/Sources/TYProtocol/
├── WireFormat.swift         # Frame encoding/decoding, magic validation
├── MessageTypes.swift       # ServerMessage, ClientMessage enums
├── ScreenDiff.swift         # ScreenDiff struct + binary serialization
├── BinaryEncoder.swift      # Custom binary encoder for Cell/ScreenSnapshot
├── BinaryDecoder.swift      # Custom binary decoder
├── TYSocket.swift           # Unix domain socket wrapper
├── SessionInfo.swift        # SessionID, PaneID, SessionInfo, LayoutTree types
└── Identifiers.swift        # UUID-based type-safe IDs
```

### Validation

- Unit tests for round-trip encode/decode of all message types.
- Benchmark: encode/decode a 120×40 ScreenSnapshot under 1ms.
- Benchmark: encode a typical ScreenDiff (3 dirty rows) under 100μs.

---

## Phase 3: Server (tyd)

### Goal
Implement the server daemon that manages PTY processes, terminal state, and sessions. Clients connect via Unix socket.

### Architecture

```
┌──────────────────────────────────────────────────┐
│  tyd (daemon process)                            │
│                                                  │
│  ┌─────────────┐   ┌─────────────────────┐       │
│  │ SocketServer │──▶│ ClientConnection[N] │       │
│  └─────────────┘   └────────┬────────────┘       │
│                              │                    │
│  ┌───────────────────────────▼──────────────────┐ │
│  │ ServerSessionManager                         │ │
│  │  ├─ Session[1]: tabs, panes, layout          │ │
│  │  │   ├─ TerminalCore (Screen+VTParser+PTY)   │ │
│  │  │   └─ TerminalCore (Screen+VTParser+PTY)   │ │
│  │  └─ Session[2]: ...                          │ │
│  └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘
```

### TerminalCore (New — Package Module)

Extract the platform-independent core of TerminalController into a new class:

```swift
/// Platform-independent terminal session core.
/// Manages PTY + VTParser + StreamHandler + Screen lifecycle.
/// No AppKit, no UI — pure backend logic.
public final class TerminalCore {
    private let screen: Screen
    private var vtParser: VTParser
    private var streamHandler: StreamHandler
    private let ptyProcess: PTYProcess
    private let ptyQueue: DispatchQueue

    // Callbacks for server to wire up
    public var onScreenDirty: (() -> Void)?
    public var onTitleChanged: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onClipboardSet: ((String) -> Void)?
    public var onProcessExited: ((Int32) -> Void)?

    public func start(columns:rows:workingDirectory:) throws
    public func stop()
    public func write(_ data: Data)
    public func resize(columns:rows:)
    public func consumeSnapshot(selection:) -> ScreenSnapshot?
    public func search(query:) -> SearchResult
    // ... other Screen/StreamHandler pass-through methods
}
```

**Migration from TerminalController:**
- Move all platform-independent logic from `TerminalController.swift` into `TerminalCore`.
- `TerminalController` becomes a thin wrapper: `TerminalCore` + AppKit (clipboard, URL open, NSSound.beep).
- In C/S mode, GUI uses `ClientTerminalController` instead, which talks to tyd.

### ServerSessionManager

```swift
/// Server-side session/tab/pane manager.
/// Similar to SessionManager but non-@Observable, and includes TerminalCore instances.
public final class ServerSessionManager {
    private var sessions: [SessionID: ServerSession]

    func createSession(name:) -> SessionInfo
    func closeSession(id:)
    func createTab(sessionID:) -> TabID
    func splitPane(sessionID:paneID:direction:) -> PaneID
    func closePane(sessionID:paneID:)
    // ...
}

struct ServerSession {
    var info: SessionInfo
    var tabs: [ServerTab]
    var activeTabIndex: Int
}

struct ServerTab {
    var id: TabID
    var title: String
    var paneTree: PaneNode  // Reuse from TYTerminal
    var terminalCores: [PaneID: TerminalCore]
}
```

### Daemon Lifecycle

```
tyd                              # Start foreground (for development)
tyd --daemon                     # Start background (detach from terminal)
tyd --stop                       # Signal running tyd to shut down
tyd --status                     # Print whether tyd is running
```

- PID file at `$XDG_RUNTIME_DIR/tongyou/tyd.pid`.
- On start: check PID file, refuse if another tyd is running.
- On all sessions closed: configurable auto-exit (default: keep running).
- Signal handling: SIGTERM → graceful shutdown (SIGHUP all children).

### Screen Update Flow

```
PTY bytes arrive on ptyQueue
  → VTParser.feed() → StreamHandler.handle() → Screen mutation
  → Screen.dirtyRegion tracks changed rows
  → onScreenDirty() callback

Server main loop (per connected client):
  → Timer fires (e.g. 16ms = 60fps cap)
  → For each pane attached to this client:
      → consumeSnapshot() or consumeDirtyRegion()
      → Encode ScreenDiff (only dirty rows)
      → Send over socket
```

### Files to Create

```
Packages/TongYouCore/Sources/TYServer/
├── TerminalCore.swift           # Platform-independent PTY+Screen orchestrator
├── ServerSessionManager.swift   # Session/tab/pane management
├── SocketServer.swift           # Listen, accept, manage ClientConnections
├── ClientConnection.swift       # Per-client state, message dispatch
├── ServerConfig.swift           # Daemon configuration
└── DaemonLifecycle.swift        # PID file, signal handling, auto-exit

tyd/                             # Executable target
├── main.swift                   # Entry point, argument parsing, start server
```

### Validation

- Integration test: start tyd in-process, connect a mock client, create session, send input, receive screen updates.
- Test: client disconnect → sessions persist → client reconnect → full snapshot received.
- Test: multiple clients attach to same session → both receive updates.

---

## Phase 4: GUI as Client

### Goal
Refactor the macOS GUI to operate as a client of tyd, replacing direct PTY management with socket communication.

### ClientTerminalController

Replace `TerminalController` (direct PTY) with `ClientTerminalController` (talks to tyd):

```swift
/// Client-side terminal controller that communicates with tyd.
/// Maintains a local Screen replica, updated from server diffs.
final class ClientTerminalController {
    private let connection: ClientConnection
    private let sessionID: SessionID
    private let paneID: PaneID

    /// Local screen replica for rendering.
    private var screen: Screen
    private(set) var selection: Selection?
    private(set) var detectedURLs: [DetectedURL] = []

    // Same public API as TerminalController:
    func handleKeyDown(_ event: NSEvent)
    func sendText(_ text: String)
    func scrollUp(lines:)
    func scrollDown(lines:)
    func consumeSnapshot() -> ScreenSnapshot?
    func startSelection(col:row:mode:)
    func copySelection() -> Bool
    // ...

    // Server sends screen updates → apply to local replica
    func applyScreenDiff(_ diff: ScreenDiff)
    func applyFullSnapshot(_ snapshot: ScreenSnapshot)
}
```

### Connection Manager

```swift
/// Manages the connection to tyd, including auto-start and reconnection.
final class TYDConnectionManager {
    private var connection: ClientConnection?
    private let socketPath: String

    /// Connect to tyd, starting it if needed.
    func connect() async throws

    /// Disconnect without stopping tyd.
    func disconnect()

    /// Auto-start tyd if not running (configurable).
    private func ensureTYDRunning() throws
}
```

### MetalView Changes

Minimal — MetalView already works with `ScreenSnapshot`. The only change is where snapshots come from:
- Before: `TerminalController.consumeSnapshot()` (local Screen)
- After: `ClientTerminalController.consumeSnapshot()` (local Screen replica, fed by server diffs)

### SessionManager Changes

`SessionManager` currently holds `TerminalSession` data and delegates to `TabManager`. In C/S mode:
- Session list comes from server (`ServerMessage.sessionList`).
- Tab/pane operations become `ClientMessage` sent to server.
- `SessionManager` becomes a thin UI-state holder that mirrors server state.

### Config: Auto-Start Toggle

```
# ~/.config/tongyou/config
auto-start-daemon = true   # default: true
# When false, user must start tyd manually; GUI shows error if not running.
```

### Migration Strategy

Support both modes during transition:
1. **Standalone mode** (default, current behavior): TerminalController + direct PTY. No tyd needed.
2. **Client mode** (opt-in via config): ClientTerminalController + tyd.

This allows incremental migration and easy rollback.

```
# ~/.config/tongyou/config
mode = standalone   # "standalone" (default) or "client"
```

### Files to Create/Modify

```
Packages/TongYouCore/Sources/TYClient/
├── ClientConnection.swift          # Socket connection, send/receive messages
├── TYDConnectionManager.swift      # Auto-start, reconnect logic
└── ClientTerminalController.swift  # Local Screen replica + server communication

TongYou/
├── Terminal/TerminalController.swift   # Keep for standalone mode
├── App/SessionManager.swift            # Add client-mode path
└── Config/Config.swift                 # Add mode, auto-start-daemon options
```

### Validation

- Test: launch GUI → tyd auto-starts → session appears → type commands → output renders.
- Test: close GUI → reopen → reconnect to existing session → content preserved.
- Test: standalone mode still works unchanged.
- Test: tyd not running + auto-start disabled → GUI shows clear error message.

---

## Phase 5: CLI Client + Linux (Future)

### CLI Client (tyctl)

```
tyctl list                    # List sessions
tyctl attach [session-id]     # Attach to session (full terminal UI in current terminal)
tyctl new [--name <name>]     # Create new session
tyctl send <session-id> <text> # Send input to a session
```

- Renders using ANSI escape sequences (no Metal).
- Useful for headless / SSH scenarios.

### Linux Support

- Compile TongYouCore + tyd on Linux (Swift on Linux).
- Test with `swift build` on Ubuntu/Fedora.
- CI: GitHub Actions multi-platform matrix (macOS + Linux).
- Future: Linux GUI client (GTK or other toolkit).

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Protocol overhead on hot path | Binary encoding, dirty-row diffs, benchmark gates |
| Reconnect complexity | Full snapshot on attach; server keeps complete state |
| Dual-mode maintenance burden | Share code via TerminalCore; standalone mode is thin wrapper |
| Linux Swift compatibility | `#if os(Linux)` guards already in place; CI validation |
| Screen replica drift | Periodic full snapshot reconciliation (e.g. every 60s) |
