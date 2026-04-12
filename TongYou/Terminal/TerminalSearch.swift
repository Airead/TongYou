/// A single search match in the terminal buffer.
struct SearchMatch: Equatable {
    /// Absolute line number (scrollback + screen combined).
    let line: Int
    /// Start column (inclusive).
    let startCol: Int
    /// End column (inclusive).
    let endCol: Int
}

/// Result of a search operation, including all matches and the focused index.
struct SearchResult: Equatable {
    /// All matches found, ordered from top to bottom.
    let matches: [SearchMatch]
    /// The query that produced these matches.
    let query: String
    /// Index of the currently focused match (nil if no matches).
    var focusedIndex: Int?

    /// The currently focused match.
    var focusedMatch: SearchMatch? {
        guard let idx = focusedIndex, idx < matches.count else { return nil }
        return matches[idx]
    }

    /// Total number of matches.
    var count: Int { matches.count }

    /// Whether there are any matches.
    var isEmpty: Bool { matches.isEmpty }

    static let empty = SearchResult(matches: [], query: "", focusedIndex: nil)

    /// Move focus to the next match (wraps around).
    mutating func focusNext() {
        guard !matches.isEmpty else { return }
        if let idx = focusedIndex {
            focusedIndex = (idx + 1) % matches.count
        } else {
            focusedIndex = 0
        }
    }

    /// Move focus to the previous match (wraps around).
    mutating func focusPrevious() {
        guard !matches.isEmpty else { return }
        if let idx = focusedIndex {
            focusedIndex = (idx - 1 + matches.count) % matches.count
        } else {
            focusedIndex = matches.count - 1
        }
    }

    /// Find the match closest to the given absolute line and set it as focused.
    mutating func focusNearest(toAbsoluteLine line: Int) {
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
