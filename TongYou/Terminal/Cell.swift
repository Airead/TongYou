import simd

/// Display width of a terminal cell.
enum CellWidth: UInt8, Equatable {
    /// Right half of a wide character (placeholder, not rendered).
    case continuation = 0
    /// Normal single-width character.
    case normal = 1
    /// Left half of a wide character (rendered across two cells).
    case wide = 2
    /// Spacer at the last column when a wide character doesn't fit.
    /// Rendered as blank; skipped during reflow to avoid phantom spaces.
    case spacer = 3

    /// Whether this cell carries its own character (not a continuation or spacer placeholder).
    var isRenderable: Bool { self != .continuation && self != .spacer }
}

/// A single character cell in the terminal grid.
/// Uses `Unicode.Scalar` instead of `Character` to avoid heap allocation
/// and make `[Cell]` array copies trivial (memcpy).
struct Cell: Equatable {
    var codepoint: Unicode.Scalar
    var attributes: CellAttributes
    var width: CellWidth

    static let empty = Cell(
        codepoint: " ",
        attributes: .default,
        width: .normal
    )
}
