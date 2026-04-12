# tyd-client Communication Protocol

## Architecture Overview

TongYou uses a **client-server architecture** where:

- **`tyd`** (TongYou Daemon) is the server process that manages PTY sessions independently of the GUI
- **Clients** (the TongYou GUI app, or the `tyctl` CLI tool) connect to `tyd` to create/manage/interact with terminal sessions

The module dependency graph is:

```
TYTerminal  (pure terminal state machine)
    ^
TYProtocol  (binary wire protocol + Unix socket)
    ^
TYServer    (server: manages PTY sessions, accepts clients)
TYClient    (client: connects to tyd, maintains screen replicas)
    ^
tyd         (server executable entry point)
tyctl       (CLI client tool)
```

---

## Transport Mechanism

**Unix Domain Sockets** (`AF_UNIX`, `SOCK_STREAM`)

- The server listens on a Unix domain socket at a configurable path, defaulting to:
  - `$XDG_RUNTIME_DIR/tongyou/tyd.sock` (if `XDG_RUNTIME_DIR` is set)
  - `~/Library/Caches/tongyou/tyd.sock` (macOS default)
- The socket file is created when `tyd` starts and removed/replaced on restart
- The underlying socket wrapper is `TYSocket` (a custom class wrapping POSIX socket APIs)

**Key file:** `Packages/TongYouCore/Sources/TYProtocol/TYSocket.swift`

---

## Wire Protocol / Message Format

**Custom binary framing protocol** (not JSON, not protobuf).

Each frame on the wire has this structure:

```
+--------------+--------------+--------------+--------------------+
| Magic (2B)   | Type (2B)    | Length (4B)   | Payload (N bytes)  |
| 0x54 0x59    | LE uint16    | LE uint32     | binary             |
+--------------+--------------+--------------+--------------------+
```

- **Magic bytes:** `0x54 0x59` (ASCII "TY") -- used for frame validation
- **Type code:** Little-endian `UInt16` identifying the message type
- **Payload length:** Little-endian `UInt32`, max 1 MB (`1_048_576`)
- **Payload:** Binary-encoded message body (no framing inside payload)

All multi-byte integers use **little-endian** byte order. Strings are length-prefixed (`UInt32` length + UTF-8 bytes). Byte arrays are similarly length-prefixed.

**Key file:** `Packages/TongYouCore/Sources/TYProtocol/WireFormat.swift`

---

## Message Types

### Server-to-Client Messages (type codes `0x01xx`)

| Type Code | Enum Case | Description |
|-----------|-----------|-------------|
| `0x0100` | `sessionList` | List of all sessions (response to `listSessions`) |
| `0x0101` | `sessionCreated` | A new session was created |
| `0x0102` | `sessionClosed` | A session was closed |
| `0x0110` | `screenFull` | Full screen snapshot (sent on attach/reconnect) |
| `0x0111` | `screenDiff` | Incremental screen update (dirty rows only) |
| `0x0120` | `titleChanged` | Pane title changed |
| `0x0121` | `bell` | Bell event |
| `0x0122` | `paneExited` | Pane process exited with exit code |
| `0x0130` | `layoutUpdate` | Tab/pane layout tree changed |
| `0x0131` | `clipboardSet` | Server sets client clipboard |

### Client-to-Server Messages (type codes `0x02xx`)

| Type Code | Enum Case | Description |
|-----------|-----------|-------------|
| `0x0200` | `listSessions` | Request session list (no payload) |
| `0x0201` | `createSession` | Create a new session (optional name) |
| `0x0202` | `attachSession` | Attach to a session (receive screen updates) |
| `0x0203` | `detachSession` | Detach from a session |
| `0x0204` | `closeSession` | Close a session |
| `0x0210` | `input` | Terminal input bytes (hot path) |
| `0x0211` | `resize` | Resize a pane (cols x rows) |
| `0x0220` | `createTab` | Create a new tab in a session |
| `0x0221` | `closeTab` | Close a tab |
| `0x0222` | `splitPane` | Split a pane (horizontal/vertical) |
| `0x0223` | `closePane` | Close a pane |
| `0x0224` | `focusPane` | Focus a pane |

**Key file:** `Packages/TongYouCore/Sources/TYProtocol/MessageTypes.swift`

---

## Binary Encoding/Decoding

The `BinaryEncoder` and `BinaryDecoder` classes handle serialization:

- **Primitives:** `UInt8`, `Bool` (1B), `UInt16` (2B LE), `UInt32` (4B LE), `Int32` (4B LE), `Float` (4B LE)
- **UUIDs** (identifiers): 16 raw bytes (used for `SessionID`, `TabID`, `PaneID`)
- **Strings:** `UInt32` length prefix + UTF-8 bytes
- **Byte arrays:** `UInt32` length prefix + raw bytes
- **Cells** (terminal): 15 bytes each -- `codepoint (4B) + fgColor (4B) + bgColor (4B) + flags (2B) + width (1B)`
- **Cursor state:** 6 bytes -- `col (2B) + row (2B) + visible (1B) + shape (1B)`
- **LayoutTree:** Recursive tagged union -- `tag 0 = leaf(PaneID)`, `tag 1 = split(direction, ratio, first, second)`
- **ScreenDiff:** `columns (2B) + dirtyRowCount (2B) + dirtyRowIndices (2B each) + cells (15B each, columns * dirtyRowCount) + cursor (6B)`
- **ScreenSnapshot:** `columns (2B) + rows (2B) + cells (15B each, columns * rows) + cursor (6B) + scrollbackCount (4B) + viewportOffset (4B)`

**Key files:**
- `Packages/TongYouCore/Sources/TYProtocol/BinaryEncoder.swift`
- `Packages/TongYouCore/Sources/TYProtocol/BinaryDecoder.swift`

---

## Communication Flow

### Connection Establishment

1. **tyd starts** and listens on `tyd.sock` via `TYSocket.listen()`
2. **Client connects** via `TYSocket.connect(path:)`, or `TYDConnectionManager.connect()` which auto-starts `tyd` if not running
3. On connection, the client immediately sends `listSessions` to discover existing sessions
4. The server responds with `sessionList([SessionInfo])`

### Session Lifecycle

1. Client sends `createSession(name:)`
2. Server creates PTY processes, responds with `sessionCreated(SessionInfo)`, and broadcasts to all connected clients
3. Client sends `attachSession(SessionID)` to start receiving screen updates
4. Server sends `screenFull` for every pane in the session (full snapshots)

### Terminal I/O (Hot Path)

- **Input:** Client sends `input(SessionID, PaneID, [UInt8])` with raw terminal bytes
- **Screen updates:** Server runs a **single global timer** (~60fps / 16ms interval). When panes are dirty, the timer fires `flushDirtyPanes()` which:
  1. Consumes one snapshot per dirty pane
  2. Sends `screenFull` (if full rebuild needed) or `screenDiff` (incremental) to each attached client
- **Backpressure:** Screen update messages are dropped if a client's write queue has > 3 pending screen updates (configurable). Non-screen messages are always delivered.

### Tab/Pane Operations

- Client sends `createTab`, `splitPane`, `closePane`, etc.
- Server performs the operation and broadcasts `layoutUpdate(SessionID, LayoutTree)` to all attached clients

### Events (Server -> Client)

- `titleChanged`: When a pane's terminal title changes
- `bell`: Bell/alert event
- `paneExited`: When a pane's shell process exits (with exit code)
- `clipboardSet`: Server requests the client to set clipboard content (OSC 52)

### Disconnection

- Clients detect disconnection when `recv()` returns 0/error
- The `ClientConnection.readLoop()` catches the error and fires `onDisconnect`
- The `TYDConnectionManager` can optionally reconnect

---

## Concurrency Model (Server Side)

- **Accept loop:** Dedicated `acceptQueue` (serial) for accepting new connections
- **Read loops:** Each client has its own `readQueue` for receiving messages
- **Message handling:** All `sessionManager` mutations and message handling are serialized on a single `messageQueue` to prevent data races
- **Write queues:** Each client has its own `writeQueue` for sending messages
- **Screen update timer:** Single server-wide `DispatchSourceTimer` on `messageQueue` coalesces dirty pane updates

---

## Key File Paths

| Component | File Path |
|-----------|-----------|
| **Wire format** | `Packages/TongYouCore/Sources/TYProtocol/WireFormat.swift` |
| **Message types** | `Packages/TongYouCore/Sources/TYProtocol/MessageTypes.swift` |
| **Binary encoder** | `Packages/TongYouCore/Sources/TYProtocol/BinaryEncoder.swift` |
| **Binary decoder** | `Packages/TongYouCore/Sources/TYProtocol/BinaryDecoder.swift` |
| **Socket wrapper** | `Packages/TongYouCore/Sources/TYProtocol/TYSocket.swift` |
| **Identifiers** | `Packages/TongYouCore/Sources/TYProtocol/Identifiers.swift` |
| **ScreenDiff** | `Packages/TongYouCore/Sources/TYProtocol/ScreenDiff.swift` |
| **SessionInfo** | `Packages/TongYouCore/Sources/TYProtocol/SessionInfo.swift` |
| **Socket server** | `Packages/TongYouCore/Sources/TYServer/SocketServer.swift` |
| **Client connection (server)** | `Packages/TongYouCore/Sources/TYServer/ClientConnection.swift` |
| **Server config** | `Packages/TongYouCore/Sources/TYServer/ServerConfig.swift` |
| **Session manager** | `Packages/TongYouCore/Sources/TYServer/ServerSessionManager.swift` |
| **Daemon lifecycle** | `Packages/TongYouCore/Sources/TYServer/DaemonLifecycle.swift` |
| **tyd entry point** | `Packages/TongYouCore/Sources/tyd/main.swift` |
| **Client connection (client)** | `Packages/TongYouCore/Sources/TYClient/TYDConnection.swift` |
| **Connection manager** | `Packages/TongYouCore/Sources/TYClient/TYDConnectionManager.swift` |
| **Remote session client** | `Packages/TongYouCore/Sources/TYClient/RemoteSessionClient.swift` |
| **Screen replica** | `Packages/TongYouCore/Sources/TYClient/ScreenReplica.swift` |
| **tyctl CLI** | `Packages/TongYouCore/Sources/tyctl/main.swift` |
| **Package manifest** | `Packages/TongYouCore/Package.swift` |
