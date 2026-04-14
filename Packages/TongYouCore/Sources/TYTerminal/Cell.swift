import simd

/// Display width of a terminal cell.
public enum CellWidth: UInt8, Equatable, Sendable {
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
    public var isRenderable: Bool { self != .continuation && self != .spacer }
}

/// A single character cell in the terminal grid.
/// Uses `GraphemeCluster` to support multi-scalar characters like emoji sequences
/// while maintaining efficient inline storage for common single-scalar characters.
public struct Cell: Equatable, Sendable {
    /// The grapheme cluster content of this cell.
    public var content: GraphemeCluster
    public var attributes: CellAttributes
    public var width: CellWidth

    /// Backward compatibility: access the first scalar of the content.
    /// For single-scalar characters, this is equivalent to the old `codepoint`.
    /// For multi-scalar sequences, returns the first scalar.
    public var codepoint: Unicode.Scalar {
        get { content.firstScalar ?? " " }
        set { content = GraphemeCluster(newValue) }
    }

    public static let empty = Cell(
        content: GraphemeCluster(" "),
        attributes: .default,
        width: .normal
    )

    /// Initialize with a grapheme cluster.
    public init(content: GraphemeCluster, attributes: CellAttributes, width: CellWidth) {
        self.content = content
        self.attributes = attributes
        self.width = width
    }

    /// Initialize with a single Unicode scalar (backward compatible).
    public init(codepoint: Unicode.Scalar, attributes: CellAttributes, width: CellWidth) {
        self.content = GraphemeCluster(codepoint)
        self.attributes = attributes
        self.width = width
    }

    /// Initialize with a Character.
    public init(character: Character, attributes: CellAttributes, width: CellWidth) {
        self.content = GraphemeCluster(character)
        self.attributes = attributes
        self.width = width
    }
}
