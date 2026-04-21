import Testing
import Foundation
@testable import TYTerminal

@Suite("OSC 8 URL Detection Tests", .serialized)
struct OSC8URLDetectionTests {

    @Test("detects OSC 8 hyperlink")
    func detectsOSC8Hyperlink() {
        let registry = HyperlinkRegistry()
        let url = "https://example.com"
        let linkId = registry.register(url: url)

        var cells = [Cell](repeating: .empty, count: 20)
        for i in 0..<5 {
            cells[i] = Cell(
                content: GraphemeCluster("a"),
                attributes: CellAttributes(hyperlinkId: linkId),
                width: .normal
            )
        }

        let urls = URLDetector.detect(
            rows: 1,
            cols: 20,
            cellAt: { row, col in cells[col] },
            hyperlinkRegistry: registry
        )

        #expect(urls.count == 1)
        #expect(urls.first?.url == url)
        #expect(urls.first?.row == 0)
        #expect(urls.first?.startCol == 0)
        #expect(urls.first?.endCol == 4)
    }

    @Test("detects multiple OSC 8 hyperlinks in same row")
    func detectsMultipleOSC8Hyperlinks() {
        let registry = HyperlinkRegistry()
        let url1 = "https://example.com"
        let url2 = "https://github.com"
        let id1 = registry.register(url: url1)
        let id2 = registry.register(url: url2)

        var cells = [Cell](repeating: .empty, count: 30)
        // First link at cols 0-4
        for i in 0..<5 {
            cells[i] = Cell(
                content: GraphemeCluster("a"),
                attributes: CellAttributes(hyperlinkId: id1),
                width: .normal
            )
        }
        // Gap at cols 5-9
        // Second link at cols 10-14
        for i in 10..<15 {
            cells[i] = Cell(
                content: GraphemeCluster("b"),
                attributes: CellAttributes(hyperlinkId: id2),
                width: .normal
            )
        }

        let urls = URLDetector.detect(
            rows: 1,
            cols: 30,
            cellAt: { row, col in cells[col] },
            hyperlinkRegistry: registry
        )

        #expect(urls.count == 2)
        #expect(urls[0].url == url1)
        #expect(urls[1].url == url2)
    }

    @Test("prioritizes OSC 8 over regex URLs")
    func prioritizesOSC8OverRegex() {
        let registry = HyperlinkRegistry()
        let url = "https://explicit.com"
        let linkId = registry.register(url: url)

        var cells = [Cell](repeating: .empty, count: 25)
        // Put a regex-detectable URL in cells, but mark as OSC 8
        let text = "https://example.com"
        for (i, char) in text.enumerated() {
            cells[i] = Cell(
                content: GraphemeCluster(char),
                attributes: CellAttributes(hyperlinkId: linkId),
                width: .normal
            )
        }

        let urls = URLDetector.detect(
            rows: 1,
            cols: 25,
            cellAt: { row, col in cells[col] },
            hyperlinkRegistry: registry
        )

        #expect(urls.count == 1)
        #expect(urls.first?.url == url)
    }

    @Test("detects plain text URLs when no registry provided")
    func detectsPlainTextURLs() {
        var cells = [Cell](repeating: .empty, count: 30)
        let text = "Visit https://example.com here"
        for (i, char) in text.enumerated() {
            cells[i] = Cell(
                content: GraphemeCluster(char),
                attributes: .default,
                width: .normal
            )
        }

        let urls = URLDetector.detect(
            rows: 1,
            cols: 30,
            cellAt: { row, col in cells[col] },
            hyperlinkRegistry: nil  // No registry provided
        )

        #expect(urls.count == 1)
        #expect(urls.first?.url == "https://example.com")
    }

    @Test("handles OSC 8 hyperlink with zero ID")
    func handlesZeroLinkId() {
        let registry = HyperlinkRegistry()

        var cells = [Cell](repeating: .empty, count: 10)
        for i in 0..<5 {
            cells[i] = Cell(
                content: GraphemeCluster("a"),
                attributes: CellAttributes(hyperlinkId: 0),  // No hyperlink
                width: .normal
            )
        }

        let urls = URLDetector.detect(
            rows: 1,
            cols: 10,
            cellAt: { row, col in cells[col] },
            hyperlinkRegistry: registry
        )

        #expect(urls.isEmpty)
    }

    @Test("detects URLs across multiple rows")
    func detectsURLsAcrossRows() {
        let registry = HyperlinkRegistry()
        let url = "https://example.com"
        let linkId = registry.register(url: url)

        // 2 rows, 10 columns each
        var cells = [Cell](repeating: .empty, count: 20)
        // Row 0 has link at cols 0-4
        for i in 0..<5 {
            cells[i] = Cell(
                content: GraphemeCluster("a"),
                attributes: CellAttributes(hyperlinkId: linkId),
                width: .normal
            )
        }
        // Row 1 has link at cols 3-7
        for i in 3..<8 {
            cells[10 + i] = Cell(
                content: GraphemeCluster("b"),
                attributes: CellAttributes(hyperlinkId: linkId),
                width: .normal
            )
        }

        let urls = URLDetector.detect(
            rows: 2,
            cols: 10,
            cellAt: { row, col in cells[row * 10 + col] },
            hyperlinkRegistry: registry
        )

        #expect(urls.count == 2)
        #expect(urls[0].row == 0)
        #expect(urls[0].startCol == 0)
        #expect(urls[1].row == 1)
        #expect(urls[1].startCol == 3)
    }
}
