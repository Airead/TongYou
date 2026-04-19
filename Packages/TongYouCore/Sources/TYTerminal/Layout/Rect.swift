import Foundation

/// Integer character-grid size. Used to express per-pane minimum sizes and
/// auxiliary dimensions that are always measured in cells, never in pixels.
public struct Size: Equatable, Sendable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)

    /// Default minimum pane size as declared in the autolayout plan (§一, row 5).
    public static let defaultMin = Size(width: 20, height: 3)
}

/// Integer character-grid rectangle. Origin is top-left; `x`/`y` count cells
/// from the terminal tab's top-left corner, `width`/`height` count cells.
///
/// Deliberately not `CGRect` — `CGRect` uses `Double`, which is ambiguous for
/// discrete character coordinates and invites subpixel drift when a layout is
/// re-solved repeatedly.
public struct Rect: Equatable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var size: Size { Size(width: width, height: height) }
}
