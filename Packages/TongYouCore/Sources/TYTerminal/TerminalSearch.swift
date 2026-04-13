/// A single search match in the terminal buffer.
public struct SearchMatch: Equatable, Sendable {
    /// Absolute line number (scrollback + screen combined).
    public let line: Int
    /// Start column (inclusive).
    public let startCol: Int
    /// End column (inclusive).
    public let endCol: Int

    public init(line: Int, startCol: Int, endCol: Int) {
        self.line = line
        self.startCol = startCol
        self.endCol = endCol
    }
}

/// Result of a search operation, including all matches and the focused index.
public struct SearchResult: Equatable, Sendable {
    /// All matches found, ordered from top to bottom.
    public let matches: [SearchMatch]
    /// The query that produced these matches.
    public let query: String
    /// Index of the currently focused match (nil if no matches).
    public var focusedIndex: Int?

    public init(matches: [SearchMatch], query: String, focusedIndex: Int?) {
        self.matches = matches
        self.query = query
        self.focusedIndex = focusedIndex
    }

    /// The currently focused match.
    public var focusedMatch: SearchMatch? {
        guard let idx = focusedIndex, idx < matches.count else { return nil }
        return matches[idx]
    }

    /// Total number of matches.
    public var count: Int { matches.count }

    /// Whether there are any matches.
    public var isEmpty: Bool { matches.isEmpty }

    public static let empty = SearchResult(matches: [], query: "", focusedIndex: nil)

    /// Move focus to the next match (wraps around).
    public mutating func focusNext() {
        guard !matches.isEmpty else { return }
        if let idx = focusedIndex {
            focusedIndex = (idx + 1) % matches.count
        } else {
            focusedIndex = 0
        }
    }

    /// Move focus to the previous match (wraps around).
    public mutating func focusPrevious() {
        guard !matches.isEmpty else { return }
        if let idx = focusedIndex {
            focusedIndex = (idx - 1 + matches.count) % matches.count
        } else {
            focusedIndex = matches.count - 1
        }
    }

    /// Find the match closest to the given absolute line and set it as focused.
    public mutating func focusNearest(toAbsoluteLine line: Int) {
        guard !matches.isEmpty else { return }
        var bestIdx = 0
        var bestDist = Int.max
        for (i, m) in matches.enumerated() {
            let dist = abs(m.line - line)
            if dist < bestDist {
                bestDist = dist
                bestIdx = i
            }
        }
        focusedIndex = bestIdx
    }
}
