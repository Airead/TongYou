import AppKit
import Testing
import Metal
@testable import TongYou

@Suite("MetalRenderer IME marked-text overlay")
struct MetalRendererMarkedTextTests {

    private func makeRenderer() -> MetalRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal device not available")
        }
        let fontSystem = FontSystem(scaleFactor: 2.0)
        return MetalRenderer(device: device, fontSystem: fontSystem)
    }

    @Test func overlayDefaultsToNil() {
        let renderer = makeRenderer()
        #expect(renderer.markedTextOverlay == nil)
    }

    @Test func settingOverlayMarksRendererDirty() {
        let renderer = makeRenderer()
        renderer.clearPendingDirtyRegionForTesting()
        // needsRender may already be true from construction defaults; baseline
        // check is that setting the overlay keeps it true regardless.
        renderer.markedTextOverlay = MetalRenderer.MarkedTextOverlay(
            text: "ni", row: 0, col: 3
        )
        #expect(renderer.needsRender == true)
        #expect(renderer.markedTextOverlay?.text == "ni")
        #expect(renderer.markedTextOverlay?.row == 0)
        #expect(renderer.markedTextOverlay?.col == 3)
    }

    @Test func clearingOverlayMarksRendererDirty() {
        let renderer = makeRenderer()
        renderer.markedTextOverlay = MetalRenderer.MarkedTextOverlay(
            text: "你", row: 2, col: 5
        )
        renderer.clearPendingDirtyRegionForTesting()
        renderer.markedTextOverlay = nil
        #expect(renderer.needsRender == true)
        #expect(renderer.markedTextOverlay == nil)
    }

    @Test func assigningEqualOverlayIsIdempotent() {
        let renderer = makeRenderer()
        let overlay = MetalRenderer.MarkedTextOverlay(text: "hao", row: 1, col: 0)
        renderer.markedTextOverlay = overlay
        renderer.clearPendingDirtyRegionForTesting()
        // Same value — didSet should no-op, leaving pendingDirtyRegion clean.
        renderer.markedTextOverlay = overlay
        #expect(renderer.pendingDirtyRegion.isDirty == false)
    }

    @Test func updatingOverlayTextTriggersRerender() {
        let renderer = makeRenderer()
        renderer.markedTextOverlay = MetalRenderer.MarkedTextOverlay(text: "n", row: 0, col: 0)
        renderer.clearPendingDirtyRegionForTesting()
        renderer.markedTextOverlay = MetalRenderer.MarkedTextOverlay(text: "ni", row: 0, col: 0)
        #expect(renderer.pendingDirtyRegion.isDirty == true)
    }
}

@Suite("MetalView IME overlay safety")
struct MetalViewIMEOverlaySafetyTests {

    private func makeView() -> MetalView {
        MetalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test func setMarkedTextWithoutRendererDoesNotCrash() {
        let view = makeView()
        // No window attached → renderer is nil. Must not crash.
        view.setMarkedText(
            "你好", selectedRange: NSRange(location: 0, length: 2),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.hasMarkedText() == true)
    }

    @Test func unmarkTextWithoutRendererDoesNotCrash() {
        let view = makeView()
        view.setMarkedText(
            "拼", selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        view.unmarkText()
        #expect(view.hasMarkedText() == false)
    }
}
