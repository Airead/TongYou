/// SGR (Select Graphic Rendition) parameter parser.
///
/// Iterates over CSI params and updates CellAttributes accordingly.
/// Supports 8-color, 256-color, and TrueColor (24-bit) modes,
/// with both semicolon-separated and colon-separated forms.
///
/// Reference: Ghostty `src/terminal/sgr.zig`.
public enum SGRParser {

    /// Parse all SGR parameters and apply them to the given attributes.
    public static func parse(_ params: CSIParams, into attrs: inout CellAttributes) {
        // SGR with no params is equivalent to SGR 0 (reset)
        if params.count == 0 {
            attrs.reset()
            return
        }

        var i = 0
        while i < params.count {
            let p = params[i]
            let colon = params.isColon(at: i)

            // Guard: only 4, 38, 48, 58 accept colon sub-parameters.
            // For any other param with a colon, consume the sub-params and skip.
            if colon {
                switch p {
                case 4, 38, 48, 58:
                    break // handled below
                default:
                    i = consumeColonGroup(params, from: i)
                    i += 1
                    continue
                }
            }

            switch p {
            case 0:
                attrs.reset()

            // Text style on
            case 1: attrs.flags.insert(.bold)
            case 2: attrs.flags.insert(.dim)
            case 3: attrs.flags.insert(.italic)
            case 4:
                if colon {
                    // Colon sub-parameter: 4:0=none, 4:1=single, 4:2=double, 4:3=curly, etc.
                    if i + 1 < params.count {
                        let sub = params[i + 1]
                        if sub == 0 {
                            attrs.flags.remove(.underline)
                        } else {
                            attrs.flags.insert(.underline)
                        }
                        i += 1
                        // Consume any extra colon sub-params (e.g. 4:3:extra)
                        while i < params.count - 1 && params.isColon(at: i) {
                            i += 1
                        }
                    }
                    // Trailing colon with no sub-param: ignore
                } else {
                    attrs.flags.insert(.underline)
                }
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

            // Underline color (58:2:r:g:b or 58:5:n) — consume and ignore for now
            case 58:
                i = consumeColonGroup(params, from: i)

            // Reset underline color
            case 59:
                break

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

    /// Consume all colon-connected sub-parameters starting at `from`.
    /// Returns the index of the last consumed param (caller will +1).
    private static func consumeColonGroup(_ params: CSIParams, from start: Int) -> Int {
        var i = start
        while i < params.count - 1 && params.isColon(at: i) {
            i += 1
        }
        return i
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
