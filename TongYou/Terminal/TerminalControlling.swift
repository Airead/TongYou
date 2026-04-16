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
    var onProcessExited: (() -> Void)? { get set }
    var onTitleChanged: ((String) -> Void)? { get set }
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
