/// A point in the terminal buffer, using absolute line numbers
/// (scrollback + visible area combined).
public struct SelectionPoint: Equatable, Sendable {
    /// Absolute line index: 0 = oldest scrollback line,
    /// scrollbackCount + row = visible area.
    public var line: Int
    /// Column (0-based).
    public var col: Int

    public init(line: Int, col: Int) {
        self.line = line
        self.col = col
    }
}

/// Selection granularity.
public enum SelectionMode: UInt8, Sendable {
    /// Character-by-character selection (drag).
    case character = 0
    /// Select whole words (double-click).
    case word = 1
    /// Select whole lines (triple-click).
    case line = 2
}

/// Represents a text selection in the terminal buffer.
public struct Selection: Equatable, Sendable {
    public var start: SelectionPoint
    public var end: SelectionPoint
    public var mode: SelectionMode = .character

    public init(start: SelectionPoint, end: SelectionPoint, mode: SelectionMode = .character) {
        self.start = start
        self.end = end
        self.mode = mode
    }

    /// Normalized selection with start <= end.
    public var ordered: (start: SelectionPoint, end: SelectionPoint) {
        if start.line < end.line || (start.line == end.line && start.col <= end.col) {
            return (start, end)
        }
        return (end, start)
    }

    /// Check if a given cell (absolute line, column) is within this selection.
    public func contains(line: Int, col: Int) -> Bool {
        Self.contains(ordered: ordered, line: line, col: col)
    }

    /// Hit-test using precomputed ordered bounds (avoids recomputing `ordered` per call).
    public static func contains(
        ordered bounds: (start: SelectionPoint, end: SelectionPoint),
        line: Int, col: Int
    ) -> Bool {
        let (s, e) = bounds
        if line < s.line || line > e.line { return false }
        if s.line == e.line { return col >= s.col && col <= e.col }
        if line == s.line { return col >= s.col }
        if line == e.line { return col <= e.col }
        return true
    }
}
