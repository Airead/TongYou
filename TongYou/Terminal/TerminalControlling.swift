import AppKit
import TYTerminal

/// Common interface for terminal controllers (local PTY or remote server).
///
/// MetalView works with this protocol so it doesn't need to know whether
/// the terminal is running locally or on a tongyou server.
protocol TerminalControlling: AnyObject {

    // MARK: - Snapshot

    /// Returns a snapshot if screen content changed since the last call. Nil if idle.
    func consumeSnapshot() -> ScreenSnapshot?

    /// Monotonically-increasing generation counter for snapshot deduplication.
    var contentGeneration: UInt64 { get }

    // MARK: - Keyboard & Text Input

    func handleKeyDown(_ event: NSEvent)
    func sendText(_ text: String)
    /// Send a pre-composed key event (produced by `AutomationKeySpec`) to the PTY.
    /// Bypasses NSEvent so automation callers don't need an AppKit event stream.
    func sendKey(_ input: KeyEncoder.KeyInput)

    /// Replay `data` as if the user had typed it. Used by the broadcast-input
    /// dispatcher to mirror input across sibling panes in the same tab.
    /// Routes through the same clear-selection / scroll-to-bottom / write path
    /// as `handleKeyDown`.
    func receiveUserInput(_ data: Data)

    /// Optional dispatcher invoked with the already-encoded bytes of a user
    /// keystroke (keyDown or IME commit). When non-nil it replaces the
    /// direct write so the caller (SessionManager) can fan out to other
    /// panes. When nil, input is written to this controller only.
    var onUserInputDispatched: (@MainActor (Data) -> Void)? { get set }

    // MARK: - Scrollback

    func scrollUp(lines: Int)
    func scrollDown(lines: Int)

    // MARK: - Selection

    var selection: Selection? { get }
    func startSelection(col: Int, row: Int, mode: SelectionMode)
    func updateSelection(col: Int, row: Int)
    /// Update selection and auto-scroll when dragging outside viewport.
    /// `viewportRow` may be negative (above) or >= rows (below).
    func updateSelectionWithAutoScroll(col: Int, viewportRow: Int)
    @discardableResult func copySelection() -> Bool
    func clearSelection()

    // MARK: - URL Detection

    var detectedURLs: [DetectedURL] { get }
    func setCommandKeyHeld(_ held: Bool)
    @discardableResult func openURL(at row: Int, col: Int) -> Bool
    func urlAt(row: Int, col: Int) -> DetectedURL?

    // MARK: - Mouse

    var mouseTrackingMode: TerminalModes.MouseTrackingMode { get }
    func handleMouseEvent(_ event: MouseEncoder.Event)

    // MARK: - Resize

    func resize(columns: Int, rows: Int, cellWidth: UInt32, cellHeight: UInt32)

    // MARK: - Search

    func search(query: String) -> SearchResult
    func scrollToLine(_ absoluteLine: Int)

    // MARK: - Paste

    func handlePaste(_ text: String)

    /// Dispatcher for paste events. When non-nil it replaces the direct
    /// paste so the caller (SessionManager) can fan out to other panes.
    var onUserPasteDispatched: (@MainActor (String) -> Void)? { get set }

    /// Replay paste content to this controller. Used by the broadcast
    /// dispatcher to mirror paste across sibling panes.
    func receiveUserPaste(_ text: String)

    // MARK: - Config

    func applyConfig(_ config: Config)

    // MARK: - State

    var windowTitle: String { get }
    var runningCommand: String? { get }
    var currentWorkingDirectory: String? { get }
    var foregroundProcessName: String? { get }

    // MARK: - Lifecycle

    func stop()
    func forceFullRedraw()

    // MARK: - Callbacks

    var onNeedsDisplay: (() -> Void)? { get set }
    var onProcessExited: ((Int32) -> Void)? { get set }
    var onTitleChanged: ((String) -> Void)? { get set }
    var onPaneNotification: ((String, String) -> Void)? { get set }
    var onDynamicColorChanged: ((Int, RGBColor?) -> Void)? { get set }
    var onPaletteColorChanged: ((Int, RGBColor) -> Void)? { get set }

    // MARK: - Pointer Shape (OSC 22)

    /// Current pointer shape set by the application via OSC 22.
    /// nil means no shape has been set.
    var pointerShape: String? { get }
    /// Called when the pointer shape changes via OSC 22.
    var onPointerShapeChanged: ((String) -> Void)? { get set }

    // MARK: - Cursor Blink (DECSET 12)

    /// Called when blinking cursor mode changes via DECSET 12.
    var onCursorBlinkingChanged: ((Bool) -> Void)? { get set }
}

/// Control characters unsafe to paste — could trigger shell signals or control sequences.
let unsafePasteBytes: Set<UInt8> = [
    0x00, 0x08, 0x05, 0x04, 0x1B, 0x7F, // NUL, BS, ENQ, EOT, ESC, DEL
    0x03, 0x1C, 0x15, 0x1A, 0x11, 0x13,  // VINTR, VQUIT, VKILL, VSUSP, VSTART, VSTOP
    0x17, 0x16, 0x12, 0x0F,               // VWERASE, VLNEXT, VREPRINT, VDISCARD
]

extension TerminalControlling {
    func resize(columns: Int, rows: Int) {
        resize(columns: columns, rows: rows, cellWidth: 0, cellHeight: 0)
    }
}

extension KeyEncoder.KeyInput {
    init(event: NSEvent) {
        self.init(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            shift: event.modifierFlags.contains(.shift),
            control: event.modifierFlags.contains(.control),
            option: event.modifierFlags.contains(.option),
            command: event.modifierFlags.contains(.command)
        )
    }
}
