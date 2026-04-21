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

    /// Detect all URLs using a cell provider closure.
    public static func detect(
        rows: Int,
        cols: Int,
        cellAt: (Int, Int) -> Cell,
        hyperlinkRegistry: HyperlinkRegistry? = nil
    ) -> [DetectedURL] {
        var results: [DetectedURL] = []

        for row in 0..<rows {
            // First pass: detect OSC 8 hyperlinks
            if let registry = hyperlinkRegistry {
                var col = 0
                while col < cols {
                    let cell = cellAt(row, col)
                    let linkId = cell.attributes.hyperlinkId
                    if linkId != 0, let url = registry.url(for: linkId) {
                        let startCol = col
                        while col < cols && cellAt(row, col).attributes.hyperlinkId == linkId {
                            col += 1
                        }
                        results.append(DetectedURL(
                            url: url,
                            row: row,
                            startCol: startCol,
                            endCol: col - 1
                        ))
                    } else {
                        col += 1
                    }
                }
            }

            // Second pass: detect plain text URLs
            var lineChars: [Character] = []
            lineChars.reserveCapacity(cols)
            for col in 0..<cols {
                lineChars.append(Character(cellAt(row, col).codepoint))
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

                // Skip if this range overlaps with an OSC 8 hyperlink
                let overlaps = results.contains { detected in
                    detected.row == row && detected.startCol <= endCol && detected.endCol >= startCol
                }
                if overlaps { continue }

                results.append(DetectedURL(url: cleaned, row: row, startCol: startCol, endCol: endCol))
            }
        }

        return results
    }

    /// Detect all URLs in the given snapshot's visible area.
    /// Returns empty array for partial snapshots because `cells` is unavailable.
    public static func detect(
        in snapshot: ScreenSnapshot,
        hyperlinkRegistry: HyperlinkRegistry? = nil
    ) -> [DetectedURL] {
        guard !snapshot.isPartial else { return [] }
        return detect(
            rows: snapshot.rows,
            cols: snapshot.columns,
            cellAt: { snapshot.cell(at: $1, row: $0) },
            hyperlinkRegistry: hyperlinkRegistry
        )
    }

    /// Find the URL at a specific viewport position, if any.
    public static func url(at row: Int, col: Int, in urls: [DetectedURL]) -> DetectedURL? {
        urls.first { $0.contains(row: row, col: col) }
    }
}
