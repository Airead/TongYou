import Foundation

/// Detected URL with its position in the terminal grid.
struct DetectedURL: Equatable {
    let url: String
    /// Row in the viewport (0-based).
    let row: Int
    /// Start column (inclusive).
    let startCol: Int
    /// End column (inclusive).
    let endCol: Int

    /// Check if a viewport position (row, col) falls within this URL.
    func contains(row: Int, col: Int) -> Bool {
        self.row == row && col >= startCol && col <= endCol
    }
}

/// Scans visible terminal text for URLs.
///
/// The detector works on a ScreenSnapshot, matching URLs per-row.
/// Results are cached and only recomputed when content changes.
struct URLDetector {

    private static let urlPattern: NSRegularExpression = {
        let pattern = #"https?://[^\s<>"'`\{\}\|\\\^\[\]]+"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)>]}")

    /// Detect all URLs in the given snapshot's visible area.
    static func detect(in snapshot: ScreenSnapshot) -> [DetectedURL] {
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

            let nsLine = line as NSString
            let matches = urlPattern.matches(
                in: line, options: [],
                range: NSRange(location: 0, length: nsLine.length)
            )

            for match in matches {
                let range = match.range
                let urlString = nsLine.substring(with: range)
                // Remove trailing punctuation that's likely not part of the URL
                let cleaned = urlString.trimmingCharacters(in: trailingPunctuation)
                guard !cleaned.isEmpty else { continue }

                let startCol = range.location
                let endCol = startCol + cleaned.count - 1
                results.append(DetectedURL(url: cleaned, row: row, startCol: startCol, endCol: endCol))
            }
        }

        return results
    }

    /// Find the URL at a specific viewport position, if any.
    static func url(at row: Int, col: Int, in urls: [DetectedURL]) -> DetectedURL? {
        urls.first { $0.contains(row: row, col: col) }
    }
}
