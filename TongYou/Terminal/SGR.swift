/// SGR (Select Graphic Rendition) parameter parser.
///
/// Iterates over CSI params and updates CellAttributes accordingly.
/// Supports 8-color, 256-color, and TrueColor (24-bit) modes,
/// with both semicolon-separated and colon-separated forms.
///
/// Reference: Ghostty `src/terminal/sgr.zig`.
enum SGRParser {

    /// Parse all SGR parameters and apply them to the given attributes.
    static func parse(_ params: CSIParams, into attrs: inout CellAttributes) {
        // SGR with no params is equivalent to SGR 0 (reset)
        if params.count == 0 {
            attrs.reset()
            return
        }

        var i = 0
        while i < params.count {
            let p = params[i]

            switch p {
            case 0:
                attrs.reset()

            // Text style on
            case 1: attrs.flags.insert(.bold)
            case 2: attrs.flags.insert(.dim)
            case 3: attrs.flags.insert(.italic)
            case 4: attrs.flags.insert(.underline)
            case 5, 6: attrs.flags.insert(.blink)
            case 7: attrs.flags.insert(.inverse)
            case 8: attrs.flags.insert(.hidden)
            case 9: attrs.flags.insert(.strikethrough)

            // Text style off
            case 22: attrs.flags.remove(.bold); attrs.flags.remove(.dim)
            case 23: attrs.flags.remove(.italic)
            case 24: attrs.flags.remove(.underline)
            case 25: attrs.flags.remove(.blink)
            case 27: attrs.flags.remove(.inverse)
            case 28: attrs.flags.remove(.hidden)
            case 29: attrs.flags.remove(.strikethrough)

            // Standard foreground colors (8 colors)
            case 30...37:
                attrs.fgColor = .indexed(UInt8(p - 30))

            // Extended foreground color
            case 38:
                i = parseExtendedColor(params, from: i, into: &attrs.fgColor)

            // Default foreground
            case 39:
                attrs.fgColor = .default

            // Standard background colors (8 colors)
            case 40...47:
                attrs.bgColor = .indexed(UInt8(p - 40))

            // Extended background color
            case 48:
                i = parseExtendedColor(params, from: i, into: &attrs.bgColor)

            // Default background
            case 49:
                attrs.bgColor = .default

            // Bright foreground colors
            case 90...97:
                attrs.fgColor = .indexed(UInt8(p - 90 + 8))

            // Bright background colors
            case 100...107:
                attrs.bgColor = .indexed(UInt8(p - 100 + 8))

            default:
                break
            }

            i += 1
        }
    }

    // MARK: - Extended Color Parsing

    /// Parse extended color (256 or TrueColor) starting at param index `from`.
    /// Returns the index of the last consumed param (caller will +1).
    ///
    /// Formats:
    /// - `38;5;N` — 256-color indexed (semicolon separated)
    /// - `38:5:N` — 256-color indexed (colon separated)
    /// - `38;2;R;G;B` — TrueColor RGB (semicolon separated)
    /// - `38:2;R;G;B` or `38:2:R:G:B` — TrueColor RGB (colon separated)
    /// - `38:2:CS:R:G:B` — TrueColor RGB with colorspace (colon, 6 values)
    private static func parseExtendedColor(
        _ params: CSIParams,
        from start: Int,
        into color: inout PackedColor
    ) -> Int {
        guard start + 1 < params.count else { return start }

        let subType = params[start + 1]
        let isColon = params.isColon(at: start)

        switch subType {
        case 5:
            // 256-color: need at least 3 values (38;5;N or 38:5:N)
            guard start + 2 < params.count else { return start + 1 }
            color = .indexed(UInt8(clamping: params[start + 2]))
            return start + 2

        case 2:
            if isColon {
                // Colon-separated: count remaining colons to detect colorspace
                let remaining = countColons(params, from: start + 1)
                if remaining >= 4, start + 5 < params.count {
                    // 38:2:CS:R:G:B (with colorspace, skip CS)
                    let r = UInt8(clamping: params[start + 3])
                    let g = UInt8(clamping: params[start + 4])
                    let b = UInt8(clamping: params[start + 5])
                    color = .rgb(r, g, b)
                    return start + 5
                } else if remaining >= 3, start + 4 < params.count {
                    // 38:2:R:G:B
                    let r = UInt8(clamping: params[start + 2])
                    let g = UInt8(clamping: params[start + 3])
                    let b = UInt8(clamping: params[start + 4])
                    color = .rgb(r, g, b)
                    return start + 4
                }
                return start + 1
            } else {
                // Semicolon-separated: 38;2;R;G;B (5 values total)
                guard start + 4 < params.count else { return start + 1 }
                let r = UInt8(clamping: params[start + 2])
                let g = UInt8(clamping: params[start + 3])
                let b = UInt8(clamping: params[start + 4])
                color = .rgb(r, g, b)
                return start + 4
            }

        default:
            return start
        }
    }

    /// Count consecutive colon separators starting from index.
    private static func countColons(_ params: CSIParams, from start: Int) -> Int {
        var count = 0
        var i = start
        while i < params.count - 1 {
            if params.isColon(at: i) {
                count += 1
                i += 1
            } else {
                break
            }
        }
        return count
    }
}
