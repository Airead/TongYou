import AppKit
import TYTerminal
import Testing
@testable import TongYou

// MARK: - Mock Controller

private final class MockMouseController: TerminalControlling {
    var contentGeneration: UInt64 = 0
    var selection: Selection?
    var detectedURLs: [DetectedURL] = []
    var mouseTrackingMode: TerminalModes.MouseTrackingMode = .none
    var windowTitle: String = ""
    var runningCommand: String?
    var currentWorkingDirectory: String?
    var foregroundProcessName: String?
    var onNeedsDisplay: (() -> Void)?
    var onProcessExited: (() -> Void)?
    var onTitleChanged: ((String) -> Void)?

    struct Call {
        var name: String
        var col: Int?
        var row: Int?
        var mode: SelectionMode?
    }

    private(set) var calls: [Call] = []

    func consumeSnapshot() -> ScreenSnapshot? { nil }
    func handleKeyDown(_ event: NSEvent) {}
    func sendText(_ text: String) {}
    func scrollUp(lines: Int) {}
    func scrollDown(lines: Int) {}

    func startSelection(col: Int, row: Int, mode: SelectionMode) {
        calls.append(Call(name: "startSelection", col: col, row: row, mode: mode))
    }

    func updateSelection(col: Int, row: Int) {
        calls.append(Call(name: "updateSelection", col: col, row: row))
    }

    func updateSelectionWithAutoScroll(col: Int, viewportRow: Int) {
        calls.append(Call(name: "updateSelectionWithAutoScroll", col: col, row: viewportRow))
    }

    @discardableResult
    func copySelection() -> Bool { false }

    func setCommandKeyHeld(_ held: Bool) {}
    func openURL(at row: Int, col: Int) -> Bool { false }
    func urlAt(row: Int, col: Int) -> DetectedURL? { nil }
    func handleMouseEvent(_ event: MouseEncoder.Event) {
        calls.append(Call(name: "handleMouseEvent"))
    }

    func resize(columns: Int, rows: Int, cellWidth: UInt32, cellHeight: UInt32) {}
    func search(query: String) -> SearchResult { .empty }
    func scrollToLine(_ absoluteLine: Int) {}
    func handlePaste(_ text: String) {}
    func applyConfig(_ config: Config) {}
    func stop() {}
    func forceFullRedraw() {}
}

// MARK: - Helpers

private func makeEvent(
    type: NSEvent.EventType,
    location: NSPoint = NSPoint(x: 0, y: 0),
    modifierFlags: NSEvent.ModifierFlags = [],
    clickCount: Int = 1
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
        pressure: 1.0
    )
}

// MARK: - Tests

struct AltMouseSelectionTests {

    private func makeView(controller: MockMouseController) -> MetalView {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.bindController(controller)
        return view
    }

    // MARK: mouseDown

    @Test func altMouseDownBypassesMouseTrackingAndStartsSelection() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .button
        let view = makeView(controller: controller)

        let event = makeEvent(type: .leftMouseDown, modifierFlags: .option)
        #expect(event != nil)

        view.mouseDown(with: event!)

        #expect(controller.calls.contains(where: { $0.name == "startSelection" }))
        #expect(!controller.calls.contains(where: { $0.name == "handleMouseEvent" }))
    }

    @Test func mouseDownWithoutAltSendsMouseEventInTrackingMode() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .button
        let view = makeView(controller: controller)

        let event = makeEvent(type: .leftMouseDown)
        #expect(event != nil)

        view.mouseDown(with: event!)

        #expect(controller.calls.contains(where: { $0.name == "handleMouseEvent" }))
        #expect(!controller.calls.contains(where: { $0.name == "startSelection" }))
    }

    @Test func mouseDownWithoutTrackingModeStillSelects() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .none
        let view = makeView(controller: controller)

        let event = makeEvent(type: .leftMouseDown)
        #expect(event != nil)

        view.mouseDown(with: event!)

        #expect(controller.calls.contains(where: { $0.name == "startSelection" }))
        #expect(!controller.calls.contains(where: { $0.name == "handleMouseEvent" }))
    }

    // MARK: mouseDragged

    @Test func altMouseDraggedBypassesMouseTrackingAndUpdatesSelection() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .button
        let view = makeView(controller: controller)

        let event = makeEvent(type: .leftMouseDragged, modifierFlags: .option)
        #expect(event != nil)

        view.mouseDragged(with: event!)

        #expect(controller.calls.contains(where: { $0.name == "updateSelection" }))
        #expect(!controller.calls.contains(where: { $0.name == "handleMouseEvent" }))
    }

    @Test func mouseDraggedWithoutAltSendsMouseEventInTrackingMode() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .button
        let view = makeView(controller: controller)

        let event = makeEvent(type: .leftMouseDragged)
        #expect(event != nil)

        view.mouseDragged(with: event!)

        #expect(controller.calls.contains(where: { $0.name == "handleMouseEvent" }))
        #expect(!controller.calls.contains(where: { $0.name == "updateSelection" }))
    }

    // MARK: mouseUp

    @Test func altMouseUpDoesNotSendReleaseInTrackingMode() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .button
        let view = makeView(controller: controller)

        let event = makeEvent(type: .leftMouseUp, modifierFlags: .option)
        #expect(event != nil)

        view.mouseUp(with: event!)

        #expect(!controller.calls.contains(where: { $0.name == "handleMouseEvent" }))
    }

    @Test func mouseUpWithoutAltSendsReleaseInTrackingMode() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .button
        let view = makeView(controller: controller)

        let event = makeEvent(type: .leftMouseUp)
        #expect(event != nil)

        view.mouseUp(with: event!)

        #expect(controller.calls.contains(where: { $0.name == "handleMouseEvent" }))
    }
}
