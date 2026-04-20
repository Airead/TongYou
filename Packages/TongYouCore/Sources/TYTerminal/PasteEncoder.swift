import Foundation

/// Encodes a paste payload for PTY delivery, applying bracketed-paste
/// wrapping (DEC mode 2004) or newline conversion based on the terminal's
/// current mode state.
///
/// Mirrors the logic historically inlined in `TerminalController.handlePaste`
/// so that local (in-process) and remote (server-side) paste paths stay in
/// sync. The pure byte transformation lives here so `TYServer` can call it
/// after receiving a `.paste` message without pulling in GUI code.
public enum PasteEncoder {
    /// ESC [ 2 0 0 ~
    public static let bracketStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    /// ESC [ 2 0 1 ~
    public static let bracketEnd: [UInt8]   = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    /// Wrap `bytes` for PTY delivery.
    ///
    /// - When `bracketed` is true (pane has DECSET 2004 active), the payload
    ///   is surrounded by `ESC[200~` / `ESC[201~` and sent verbatim so
    ///   programs like vim can distinguish it from typed input.
    /// - Otherwise, every `\n` (0x0A) is rewritten to `\r` (0x0D) — shells
    ///   treat line feeds as Enter but not as paste boundaries, so without
    ///   this the first line would be executed mid-paste.
    public static func wrap(_ bytes: [UInt8], bracketed: Bool) -> [UInt8] {
        if bracketed {
            var out = [UInt8]()
            out.reserveCapacity(bracketStart.count + bytes.count + bracketEnd.count)
            out.append(contentsOf: bracketStart)
            out.append(contentsOf: bytes)
            out.append(contentsOf: bracketEnd)
            return out
        }
        var out = bytes
        for i in out.indices where out[i] == 0x0A {
            out[i] = 0x0D
        }
        return out
    }
}
