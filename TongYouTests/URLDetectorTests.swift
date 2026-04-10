import Testing
@testable import TongYou

struct URLDetectorTests {

    // MARK: - Helpers

    private func makeSnapshot(lines: [String], cols: Int = 40) -> ScreenSnapshot {
        TestHelpers.makeSnapshot(lines: lines, cols: cols)
    }

    // MARK: - Tests

    @Test func detectsHttpURL() {
        let snap = makeSnapshot(lines: ["Visit http://example.com today"])
        let urls = URLDetector.detect(in: snap)
        #expect(urls.count == 1)
        #expect(urls[0].url == "http://example.com")
        #expect(urls[0].row == 0)
        #expect(urls[0].startCol == 6)
        #expect(urls[0].endCol == 23)
    }

    @Test func detectsHttpsURL() {
        let snap = makeSnapshot(lines: ["Go to https://github.com/foo/bar"])
        let urls = URLDetector.detect(in: snap)
        #expect(urls.count == 1)
        #expect(urls[0].url == "https://github.com/foo/bar")
    }

    @Test func detectsMultipleURLs() {
        let snap = makeSnapshot(lines: [
            "A: http://a.com B: https://b.org/path",
        ], cols: 60)
        let urls = URLDetector.detect(in: snap)
        #expect(urls.count == 2)
        #expect(urls[0].url == "http://a.com")
        #expect(urls[1].url == "https://b.org/path")
    }

    @Test func noURLsInPlainText() {
        let snap = makeSnapshot(lines: ["Hello, world!"])
        let urls = URLDetector.detect(in: snap)
        #expect(urls.isEmpty)
    }

    @Test func stripTrailingPunctuation() {
        let snap = makeSnapshot(lines: [
            "See https://example.com/page.",
        ], cols: 50)
        let urls = URLDetector.detect(in: snap)
        #expect(urls.count == 1)
        #expect(urls[0].url == "https://example.com/page")
    }

    @Test func urlWithQueryAndFragment() {
        let snap = makeSnapshot(lines: [
            "https://example.com/search?q=test&lang=en#top",
        ], cols: 60)
        let urls = URLDetector.detect(in: snap)
        #expect(urls.count == 1)
        #expect(urls[0].url == "https://example.com/search?q=test&lang=en#top")
    }

    @Test func urlContainsPosition() {
        let snap = makeSnapshot(lines: ["Visit https://example.com today"])
        let urls = URLDetector.detect(in: snap)
        #expect(urls.count == 1)

        // "https://example.com" starts at col 6
        #expect(URLDetector.url(at: 0, col: 6, in: urls) != nil)
        #expect(URLDetector.url(at: 0, col: 15, in: urls) != nil)
        #expect(URLDetector.url(at: 0, col: 5, in: urls) == nil)
    }

    @Test func multipleRows() {
        let snap = makeSnapshot(lines: [
            "Line 1 with http://first.com",
            "Line 2 with no url",
            "Line 3 https://third.com/path",
        ], cols: 40)
        let urls = URLDetector.detect(in: snap)
        #expect(urls.count == 2)
        #expect(urls[0].row == 0)
        #expect(urls[1].row == 2)
    }

    @Test func emptySnapshot() {
        let snap = makeSnapshot(lines: ["", "", ""], cols: 10)
        let urls = URLDetector.detect(in: snap)
        #expect(urls.isEmpty)
    }
}
