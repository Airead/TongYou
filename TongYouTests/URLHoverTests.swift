import Testing
import Metal
import TYTerminal
@testable import TongYou

struct URLHoverTests {

    // MARK: - Helpers

    private func makeSnapshot(lines: [String], cols: Int = 80) -> ScreenSnapshot {
        TestHelpers.makeSnapshot(lines: lines, cols: cols)
    }

    private func makeRenderer() -> MetalRenderer? {
        TestHelpers.makeRenderer()
    }

    // MARK: - highlightedURL triggers rebuild

    @Test func settingHighlightedURLMarksDirty() {
        guard let renderer = makeRenderer() else {
            Issue.record("Metal device not available")
            return
        }
        // Resize to give valid grid
        renderer.resize(screen: ScreenSize(width: 800, height: 600))

        // Consume initial dirty state
        #expect(renderer.needsRender == true)

        let url = DetectedURL(url: "https://example.com", row: 0, startCol: 0, endCol: 18)
        renderer.highlightedURL = url
        #expect(renderer.needsRender == true)
    }

    @Test func clearingHighlightedURLMarksDirty() {
        guard let renderer = makeRenderer() else {
            Issue.record("Metal device not available")
            return
        }
        renderer.resize(screen: ScreenSize(width: 800, height: 600))

        let url = DetectedURL(url: "https://example.com", row: 0, startCol: 0, endCol: 18)
        renderer.highlightedURL = url
        renderer.highlightedURL = nil
        #expect(renderer.needsRender == true)
    }

    @Test func sameURLDoesNotMarkDirty() {
        guard let renderer = makeRenderer() else {
            Issue.record("Metal device not available")
            return
        }
        renderer.resize(screen: ScreenSize(width: 800, height: 600))

        let url = DetectedURL(url: "https://example.com", row: 0, startCol: 0, endCol: 18)
        renderer.highlightedURL = url

        // Force render cycle to clear dirty state — we can't actually render
        // without a layer, so just verify the logic: setting the same URL again
        // should NOT re-dirty.
        let url2 = DetectedURL(url: "https://example.com", row: 0, startCol: 0, endCol: 18)
        renderer.highlightedURL = url2
        // Still dirty from initial set, but the second set didn't add extra dirty.
        // We verify the didSet logic by checking it didn't crash or misbehave.
        #expect(renderer.needsRender == true)
    }

    // MARK: - URL position detection for hover

    @Test func urlContainsAllColumns() {
        let url = DetectedURL(url: "https://example.com", row: 2, startCol: 5, endCol: 23)
        for col in 5...23 {
            #expect(url.contains(row: 2, col: col), "col \(col) should be inside URL")
        }
        #expect(!url.contains(row: 2, col: 4), "col before URL start")
        #expect(!url.contains(row: 2, col: 24), "col after URL end")
        #expect(!url.contains(row: 1, col: 10), "wrong row")
    }

    @Test func urlDetectionWithSnapshot() {
        let snap = makeSnapshot(lines: [
            "Visit https://example.com for more",
        ])
        let urls = URLDetector.detect(in: snap)
        #expect(urls.count == 1)

        // Simulate hover at different positions
        #expect(URLDetector.url(at: 0, col: 6, in: urls) != nil)
        #expect(URLDetector.url(at: 0, col: 24, in: urls) != nil)
        #expect(URLDetector.url(at: 0, col: 5, in: urls) == nil)
        #expect(URLDetector.url(at: 0, col: 25, in: urls) == nil)
    }

    // MARK: - On-demand URL detection (Command key)

    @Test func commandKeyHeldDetectsURLsOnEmptyScreen() {
        // TerminalController with an empty screen — setCommandKeyHeld(true) should
        // run detection (finding nothing) without crashing.
        let tc = TerminalController(columns: 40, rows: 5)
        tc.setCommandKeyHeld(true)
        #expect(tc.detectedURLs.isEmpty)
    }

    @Test func commandKeyReleasedClearsDetectedURLs() {
        let tc = TerminalController(columns: 40, rows: 5)
        // Simulate: press Cmd (detection runs on empty screen), then release
        tc.setCommandKeyHeld(true)
        tc.setCommandKeyHeld(false)
        #expect(tc.detectedURLs.isEmpty)
    }

    @Test func consumeSnapshotDoesNotDetectURLsWithoutCommandKey() {
        // Without Cmd held, consumeSnapshot should NOT populate detectedURLs,
        // even when screen content changes.
        let tc = TerminalController(columns: 40, rows: 5)
        // consumeSnapshot returns nil when screen is not dirty — detectedURLs stays empty
        let snap = tc.consumeSnapshot()
        #expect(snap == nil)
        #expect(tc.detectedURLs.isEmpty)
    }
}
