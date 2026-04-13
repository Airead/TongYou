import Foundation

/// Detected URL with its position in the terminal grid.
public struct DetectedURL: Equatable, Sendable {
    public let url: String
    /// Row in the viewport (0-based).
    public let row: Int
    /// Start column (inclusive).
    public let startCol: Int
    /// End column (inclusive).
    public let endCol: Int

    public init(url: String, row: Int, startCol: Int, endCol: Int) {
        self.url = url
        self.row = row
        self.startCol = startCol
        self.endCol = endCol
    }

    /// Check if a viewport position (row, col) falls within this URL.
    public func contains(row: Int, col: Int) -> Bool {
        self.row == row && col >= startCol && col <= endCol
    }
}

/// Scans visible terminal text for URLs.
///
/// The detector works on a ScreenSnapshot, matching URLs per-row.
/// Results are cached and only recomputed when content changes.
public struct URLDetector: Sendable {

    nonisolated(unsafe) private static let urlRegex: Regex<Substring> = {
        try! Regex(#"https?://[^\s<>"'`\{\}\|\\\^\[\]]+"#)
    }()

    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)>]}")

    /// Detect all URLs in the given snapshot's visible area.
    public static func detect(in snapshot: ScreenSnapshot) -> [DetectedURL] {
        var results: [DetectedURL] = []
        let cols = snapshot.columns
        let rows = snapshot.rows

        for row in 0..<rows {
            let rowBase = row * cols
            // Build a string for this row
            var lineChars: [Character] = []
            lineChars.reserveCapacity(cols)
            for col in 0..<cols {
                lineChars.append(Character(snapshot.cells[rowBase + col].codepoint))
            }
            let line = String(lineChars)

            // Strip trailing spaces for matching
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let matches = line.matches(of: urlRegex)

            for match in matches {
                let matchStr = String(match.output)
                // Remove trailing punctuation that's likely not part of the URL
                let cleaned = matchStr.trimmingCharacters(in: trailingPunctuation)
                guard !cleaned.isEmpty else { continue }

                // Calculate column positions from the match range
                let startCol = line.distance(from: line.startIndex, to: match.range.lowerBound)
                let endCol = startCol + cleaned.count - 1
                results.append(DetectedURL(url: cleaned, row: row, startCol: startCol, endCol: endCol))
            }
        }

        return results
    }

    /// Find the URL at a specific viewport position, if any.
    public static func url(at row: Int, col: Int, in urls: [DetectedURL]) -> DetectedURL? {
        urls.first { $0.contains(row: row, col: col) }
    }
}
