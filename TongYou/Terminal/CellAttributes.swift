import simd

/// Terminal color packed into a UInt32 for zero-allocation, trivially-copyable storage.
///
/// Layout: `[tag:8][r_or_index:8][g:8][b:8]`
/// - Tag 0: default color (payload ignored)
/// - Tag 1: indexed color (r_or_index = palette index 0-255)
/// - Tag 2: direct RGB color
struct PackedColor: Equatable {
    var raw: UInt32 = 0

    static let `default` = PackedColor()

    static func indexed(_ index: UInt8) -> PackedColor {
        PackedColor(raw: (1 << 24) | UInt32(index) << 16)
    }

    static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> PackedColor {
        PackedColor(raw: (2 << 24) | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
    }

    var tag: UInt8 { UInt8(raw >> 24) }
    var isIndexed: Bool { tag == 1 }

    /// Palette index (valid when isIndexed).
    var index: UInt8 { UInt8((raw >> 16) & 0xFF) }

    /// RGB components (valid when isRGB).
    var r: UInt8 { UInt8((raw >> 16) & 0xFF) }
    var g: UInt8 { UInt8((raw >> 8) & 0xFF) }
    var b: UInt8 { UInt8(raw & 0xFF) }
}

/// Text style flags packed into a UInt16 bitfield.
struct StyleFlags: OptionSet, Equatable {
    let rawValue: UInt16

    static let bold          = StyleFlags(rawValue: 1 << 0)
    static let dim           = StyleFlags(rawValue: 1 << 1)
    static let italic        = StyleFlags(rawValue: 1 << 2)
    static let underline     = StyleFlags(rawValue: 1 << 3)
    static let blink         = StyleFlags(rawValue: 1 << 4)
    static let inverse       = StyleFlags(rawValue: 1 << 5)
    static let hidden        = StyleFlags(rawValue: 1 << 6)
    static let strikethrough = StyleFlags(rawValue: 1 << 7)
}

/// Per-cell text attributes: style flags + foreground/background colors.
struct CellAttributes: Equatable {
    var flags: StyleFlags = []
    var fgColor: PackedColor = .default
    var bgColor: PackedColor = .default

    static let `default` = CellAttributes()

    mutating func reset() {
        self = .default
    }
}

// MARK: - Cursor Shape

enum CursorShape: UInt8 {
    case block = 0
    case underline = 1
    case bar = 2
}

// MARK: - Color Palette

/// Standard xterm-256color palette.
/// Entries 0-7: standard colors, 8-15: bright colors,
/// 16-231: 6×6×6 color cube, 232-255: grayscale ramp.
struct ColorPalette {

    /// RGBA values for all 256 palette entries.
    private(set) var entries: [SIMD4<UInt8>]

    /// Default fg/bg colors used when PackedColor is `.default`.
    let defaultFg: SIMD4<UInt8>
    let defaultBg: SIMD4<UInt8>

    /// Cursor colors. When nil, cursor uses inverted fg/bg.
    let cursorColor: SIMD4<UInt8>?
    let cursorText: SIMD4<UInt8>?

    /// Selection colors. When nil, selection uses inverted fg/bg.
    let selectionBg: SIMD4<UInt8>?
    let selectionFg: SIMD4<UInt8>?

    init(
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
    func resolve(_ color: PackedColor, isFg: Bool) -> SIMD4<UInt8> {
        switch color.tag {
        case 0: return isFg ? defaultFg : defaultBg
        case 1: return entries[Int(color.index)]
        case 2: return SIMD4<UInt8>(color.r, color.g, color.b, 255)
        default: return isFg ? defaultFg : defaultBg
        }
    }

    /// Resolve foreground color with bold→bright promotion for indexed colors 0-7.
    func resolveFg(_ attrs: CellAttributes) -> SIMD4<UInt8> {
        var color = attrs.fgColor
        if attrs.flags.contains(.bold), color.isIndexed, color.index < 8 {
            color = .indexed(color.index + 8)
        }
        return resolve(color, isFg: true)
    }

    /// Resolve background color.
    func resolveBg(_ attrs: CellAttributes) -> SIMD4<UInt8> {
        resolve(attrs.bgColor, isFg: false)
    }

    /// Resolve a cell's display colors, handling inverse and hidden flags.
    func resolveDisplay(_ attrs: CellAttributes) -> (fg: SIMD4<UInt8>, bg: SIMD4<UInt8>) {
        var fg = resolveFg(attrs)
        var bg = resolveBg(attrs)
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
    mutating func applyOverrides(_ overrides: [Int: RGBColor]) {
        for (index, color) in overrides where (0...255).contains(index) {
            entries[index] = SIMD4<UInt8>(color.r, color.g, color.b, 255)
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
