import Testing
import Metal
import TYTerminal
@testable import TongYou

struct TextBufferPatchTests {

    // MARK: - Helpers

    private func makeRenderer() -> MetalRenderer? {
        TestHelpers.makeRenderer()
    }

    private func makeSnapshot(
        lines: [String], cols: Int = 80, cursorRow: Int = 0, cursorCol: Int = 0,
        cursorVisible: Bool = true
    ) -> ScreenSnapshot {
        TestHelpers.makeSnapshot(lines: lines, cols: cols,
                                 cursorRow: cursorRow, cursorCol: cursorCol,
                                 cursorVisible: cursorVisible)
    }

    // MARK: - textContentDirtyCounter routing tests

    @Test func resizeSetsTextContentDirty() {
        guard let renderer = makeRenderer() else {
            Issue.record("Metal device not available")
            return
        }
        renderer.resize(screen: ScreenSize(width: 800, height: 600))
        #expect(renderer.textContentDirtyCounter > 0)

        renderer.resize(screen: ScreenSize(width: 1024, height: 768))
        #expect(renderer.textContentDirtyCounter > 0)
    }

    @Test func setContentSetsTextContentDirty() {
        guard let renderer = makeRenderer() else {
            Issue.record("Metal device not available")
            return
        }
        renderer.resize(screen: ScreenSize(width: 800, height: 600))

        let snap = makeSnapshot(lines: ["Hello world"], cursorRow: 0, cursorCol: 5)
        renderer.setContent(snap)
        #expect(renderer.textContentDirtyCounter > 0)
    }

    @Test func markDirtySetsTextContentDirty() {
        guard let renderer = makeRenderer() else {
            Issue.record("Metal device not available")
            return
        }
        renderer.resize(screen: ScreenSize(width: 800, height: 600))
        renderer.markDirty()
        #expect(renderer.textContentDirtyCounter > 0)
    }

    @Test func highlightedURLSetsTextContentDirty() {
        guard let renderer = makeRenderer() else {
            Issue.record("Metal device not available")
            return
        }
        renderer.resize(screen: ScreenSize(width: 800, height: 600))

        let url = DetectedURL(url: "https://example.com", row: 0, startCol: 0, endCol: 18)
        renderer.highlightedURL = url
        #expect(renderer.textContentDirtyCounter > 0)
    }

    @Test func markCursorDirtyDoesNotIncreaseTextContentCounter() {
        guard let renderer = makeRenderer() else {
            Issue.record("Metal device not available")
            return
        }
        renderer.resize(screen: ScreenSize(width: 800, height: 600))

        let snap = makeSnapshot(lines: ["Hello world"], cursorRow: 0, cursorCol: 5)
        renderer.setContent(snap)

        let counterBefore = renderer.textContentDirtyCounter

        renderer.cursorBlinkOn = false
        renderer.markCursorDirty()

        #expect(renderer.textContentDirtyCounter == counterBefore)
        #expect(renderer.needsRender)
    }

    @Test func selectionChangeTriggersFullRebuild() {
        guard let renderer = makeRenderer() else {
            Issue.record("Metal device not available")
            return
        }
        renderer.resize(screen: ScreenSize(width: 800, height: 600))

        let snap1 = makeSnapshot(lines: ["Hello", "World"], cursorRow: 1, cursorCol: 0)
        renderer.setContent(snap1)
        renderer.clearPendingDirtyRegionForTesting()

        let sel = Selection(
            start: SelectionPoint(line: 0, col: 0),
            end: SelectionPoint(line: 1, col: 4)
        )
        let snap2 = TestHelpers.makeSnapshot(
            lines: ["Hello", "World"], cursorRow: 1, cursorCol: 0,
            selection: sel
        )
        renderer.setContent(TestHelpers.withDirtyRegion(.clean, from: snap2))

        #expect(renderer.pendingDirtyRegion.fullRebuild == true)
    }

    @Test func sameSelectionDoesNotTriggerFullRebuild() {
        guard let renderer = makeRenderer() else {
            Issue.record("Metal device not available")
            return
        }
        renderer.resize(screen: ScreenSize(width: 800, height: 600))

        let sel = Selection(
            start: SelectionPoint(line: 0, col: 0),
            end: SelectionPoint(line: 0, col: 4)
        )
        let snap1 = TestHelpers.makeSnapshot(
            lines: ["Hello"], cursorRow: 0, cursorCol: 0, selection: sel
        )
        renderer.setContent(snap1)
        renderer.clearPendingDirtyRegionForTesting()

        renderer.setContent(TestHelpers.withDirtyRegion(.clean, from: snap1))

        #expect(renderer.pendingDirtyRegion.fullRebuild == false)
    }

    @Test func cursorBlinkTriggersRenderWithoutContentDirty() {
        guard let renderer = makeRenderer() else {
            Issue.record("Metal device not available")
            return
        }
        renderer.resize(screen: ScreenSize(width: 800, height: 600))

        let snap = makeSnapshot(lines: ["Test"], cursorRow: 0, cursorCol: 0)
        renderer.setContent(snap)

        renderer.cursorBlinkOn = !renderer.cursorBlinkOn
        renderer.markCursorDirty()
        #expect(renderer.needsRender)
    }
}
