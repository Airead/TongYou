/// A point in the terminal buffer, using absolute line numbers
/// (scrollback + visible area combined).
struct SelectionPoint: Equatable {
    /// Absolute line index: 0 = oldest scrollback line,
    /// scrollbackCount + row = visible area.
    var line: Int
    /// Column (0-based).
    var col: Int
}

/// Selection granularity.
enum SelectionMode {
    /// Character-by-character selection (drag).
    case character
    /// Select whole words (double-click).
    case word
    /// Select whole lines (triple-click).
    case line
}

/// Represents a text selection in the terminal buffer.
struct Selection: Equatable {
    var start: SelectionPoint
    var end: SelectionPoint
    var mode: SelectionMode = .character

    /// Normalized selection with start <= end.
    var ordered: (start: SelectionPoint, end: SelectionPoint) {
        if start.line < end.line || (start.line == end.line && start.col <= end.col) {
            return (start, end)
        }
        return (end, start)
    }

    /// Check if a given cell (absolute line, column) is within this selection.
    func contains(line: Int, col: Int) -> Bool {
        Self.contains(ordered: ordered, line: line, col: col)
    }

    /// Hit-test using precomputed ordered bounds (avoids recomputing `ordered` per call).
    static func contains(
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
