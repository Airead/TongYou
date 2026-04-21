import simd

/// Terminal color packed into a UInt32 for zero-allocation, trivially-copyable storage.
///
/// Layout: `[tag:8][r_or_index:8][g:8][b:8]`
/// - Tag 0: default color (payload ignored)
/// - Tag 1: indexed color (r_or_index = palette index 0-255)
/// - Tag 2: direct RGB color
public struct PackedColor: Equatable, Sendable {
    public var raw: UInt32 = 0

    public init(raw: UInt32 = 0) {
        self.raw = raw
    }

    public static let `default` = PackedColor()

    public static func indexed(_ index: UInt8) -> PackedColor {
        PackedColor(raw: (1 << 24) | UInt32(index) << 16)
    }

    public static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> PackedColor {
        PackedColor(raw: (2 << 24) | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
    }

    public var tag: UInt8 { UInt8(raw >> 24) }
    public var isIndexed: Bool { tag == 1 }

    /// Palette index (valid when isIndexed).
    public var index: UInt8 { UInt8((raw >> 16) & 0xFF) }

    /// RGB components (valid when isRGB).
    public var r: UInt8 { UInt8((raw >> 16) & 0xFF) }
    public var g: UInt8 { UInt8((raw >> 8) & 0xFF) }
    public var b: UInt8 { UInt8(raw & 0xFF) }
}

/// Text style flags packed into a UInt16 bitfield.
public struct StyleFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let bold          = StyleFlags(rawValue: 1 << 0)
    public static let dim           = StyleFlags(rawValue: 1 << 1)
    public static let italic        = StyleFlags(rawValue: 1 << 2)
    public static let underline     = StyleFlags(rawValue: 1 << 3)
    public static let blink         = StyleFlags(rawValue: 1 << 4)
    public static let inverse       = StyleFlags(rawValue: 1 << 5)
    public static let hidden        = StyleFlags(rawValue: 1 << 6)
    public static let strikethrough = StyleFlags(rawValue: 1 << 7)
}

/// Per-cell text attributes: style flags + foreground/background colors.
public struct CellAttributes: Equatable, Sendable {
    public var flags: StyleFlags = []
    public var fgColor: PackedColor = .default
    public var bgColor: PackedColor = .default
    /// Hyperlink ID for OSC 8 support. 0 means no hyperlink.
    public var hyperlinkId: UInt16 = 0

    public static let `default` = CellAttributes()

    public init(
        flags: StyleFlags = [],
        fgColor: PackedColor = .default,
        bgColor: PackedColor = .default,
        hyperlinkId: UInt16 = 0
    ) {
        self.flags = flags
        self.fgColor = fgColor
        self.bgColor = bgColor
        self.hyperlinkId = hyperlinkId
    }

    public mutating func reset() {
        self = .default
    }
}

// MARK: - Cursor Shape

public enum CursorShape: UInt8, Sendable {
    case block = 0
    case underline = 1
    case bar = 2
}

// MARK: - Color Palette

/// RGB color for palette overrides.
public struct RGBColor: Equatable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// X11 rgb:RRRR/GGGG/BBBB format string (16-bit per component).
    public var xtermRGBString: String {
        let rh = String(format: "%04X", (UInt16(r) << 8) | UInt16(r))
        let gh = String(format: "%04X", (UInt16(g) << 8) | UInt16(g))
        let bh = String(format: "%04X", (UInt16(b) << 8) | UInt16(b))
        return "rgb:\(rh)/\(gh)/\(bh)"
    }
}

/// Standard xterm-256color palette.
/// Entries 0-7: standard colors, 8-15: bright colors,
/// 16-231: 6×6×6 color cube, 232-255: grayscale ramp.
public struct ColorPalette: Sendable {

    /// RGBA values for all 256 palette entries.
    public private(set) var entries: [SIMD4<UInt8>]

    /// Default fg/bg colors used when PackedColor is `.default`.
    public var defaultFg: SIMD4<UInt8>
    public var defaultBg: SIMD4<UInt8>

    /// Cursor colors. When nil, cursor uses inverted fg/bg.
    public let cursorColor: SIMD4<UInt8>?
    public let cursorText: SIMD4<UInt8>?

    /// Selection colors. When nil, selection uses inverted fg/bg.
    public let selectionBg: SIMD4<UInt8>?
    public let selectionFg: SIMD4<UInt8>?

    public init(
        defaultFg: SIMD4<UInt8> = SIMD4<UInt8>(220, 220, 220, 255),
        defaultBg: SIMD4<UInt8> = SIMD4<UInt8>(30, 30, 38, 255),
        cursorColor: SIMD4<UInt8>? = nil,
        cursorText: SIMD4<UInt8>? = nil,
        selectionBg: SIMD4<UInt8>? = nil,
        selectionFg: SIMD4<UInt8>? = nil
    ) {
        self.defaultFg = defaultFg
        self.defaultBg = defaultBg
        self.cursorColor = cursorColor
        self.cursorText = cursorText
        self.selectionBg = selectionBg
        self.selectionFg = selectionFg
        self.entries = Self.buildStandardPalette()
    }

    /// Resolve a PackedColor to concrete RGBA.
    public func resolve(_ color: PackedColor, isFg: Bool) -> SIMD4<UInt8> {
        switch color.tag {
        case 0: return isFg ? defaultFg : defaultBg
        case 1: return entries[Int(color.index)]
        case 2: return SIMD4<UInt8>(color.r, color.g, color.b, 255)
        default: return isFg ? defaultFg : defaultBg
        }
    }

    /// Resolve foreground color with bold→bright promotion for indexed colors 0-7.
    public func resolveFg(_ attrs: CellAttributes) -> SIMD4<UInt8> {
        var color = attrs.fgColor
        if attrs.flags.contains(.bold), color.isIndexed, color.index < 8 {
            color = .indexed(color.index + 8)
        }
        return resolve(color, isFg: true)
    }

    /// Resolve background color.
    public func resolveBg(_ attrs: CellAttributes) -> SIMD4<UInt8> {
        resolve(attrs.bgColor, isFg: false)
    }

    /// Resolve a cell's display colors, handling dim, inverse, and hidden flags.
    public func resolveDisplay(_ attrs: CellAttributes) -> (fg: SIMD4<UInt8>, bg: SIMD4<UInt8>) {
        var fg = resolveFg(attrs)
        var bg = resolveBg(attrs)
        if attrs.flags.contains(.dim) {
            fg = SIMD4<UInt8>(fg.x / 2, fg.y / 2, fg.z / 2, fg.w)
        }
        if attrs.flags.contains(.inverse) {
            swap(&fg, &bg)
        }
        if attrs.flags.contains(.hidden) {
            fg = bg
        }
        return (fg, bg)
    }

    /// Apply palette overrides from configuration.
    /// - Parameter overrides: Map of palette index (0-255) to RGB color.
    public mutating func applyOverrides(_ overrides: [Int: RGBColor]) {
        for (index, color) in overrides where (0...255).contains(index) {
            entries[index] = SIMD4<UInt8>(color.r, color.g, color.b, 255)
        }
    }

    /// Update default foreground and/or background colors (OSC 10/11 dynamic colors).
    public mutating func updateDynamicColors(
        foreground: SIMD4<UInt8>? = nil,
        background: SIMD4<UInt8>? = nil
    ) {
        if let fg = foreground {
            self.defaultFg = fg
        }
        if let bg = background {
            self.defaultBg = bg
        }
    }

    // MARK: - Private

    private static func buildStandardPalette() -> [SIMD4<UInt8>] {
        var palette = [SIMD4<UInt8>](repeating: .zero, count: 256)

        // 0-7: Standard colors
        let standard: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0),       // black
            (205, 49, 49),   // red
            (13, 188, 121),  // green
            (229, 229, 16),  // yellow
            (36, 114, 200),  // blue
            (188, 63, 188),  // magenta
            (17, 168, 205),  // cyan
            (229, 229, 229), // white
        ]
        for (i, c) in standard.enumerated() {
            palette[i] = SIMD4<UInt8>(c.0, c.1, c.2, 255)
        }

        // 8-15: Bright colors
        let bright: [(UInt8, UInt8, UInt8)] = [
            (102, 102, 102), // bright black (gray)
            (241, 76, 76),   // bright red
            (35, 209, 139),  // bright green
            (245, 245, 67),  // bright yellow
            (59, 142, 234),  // bright blue
            (214, 112, 214), // bright magenta
            (41, 184, 219),  // bright cyan
            (255, 255, 255), // bright white
        ]
        for (i, c) in bright.enumerated() {
            palette[8 + i] = SIMD4<UInt8>(c.0, c.1, c.2, 255)
        }

        // 16-231: 6×6×6 color cube
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    let index = 16 + r * 36 + g * 6 + b
                    let rv: UInt8 = r == 0 ? 0 : UInt8(55 + r * 40)
                    let gv: UInt8 = g == 0 ? 0 : UInt8(55 + g * 40)
                    let bv: UInt8 = b == 0 ? 0 : UInt8(55 + b * 40)
                    palette[index] = SIMD4<UInt8>(rv, gv, bv, 255)
                }
            }
        }

        // 232-255: Grayscale ramp
        for i in 0..<24 {
            let v = UInt8(8 + i * 10)
            palette[232 + i] = SIMD4<UInt8>(v, v, v, 255)
        }

        return palette
    }
}
