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
    var onProcessExited: ((Int32) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onPaneNotification: ((String, String) -> Void)?
    var onDynamicColorChanged: ((Int, TYTerminal.RGBColor) -> Void)?
    var onPaletteColorChanged: ((Int, TYTerminal.RGBColor) -> Void)?
    var pointerShape: String?
    var onPointerShapeChanged: ((String) -> Void)?

    struct Call {
        var name: String
        var col: Int?
        var row: Int?
        var mode: SelectionMode?
    }

    var calls: [Call] = []

    func consumeSnapshot() -> ScreenSnapshot? { nil }
    func handleKeyDown(_ event: NSEvent) {}
    func sendText(_ text: String) {}
    func sendKey(_ input: KeyEncoder.KeyInput) {}
    func receiveUserInput(_ data: Data) {}
    var onUserInputDispatched: (@MainActor (Data) -> Void)?
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
    func copySelection() -> Bool {
        calls.append(Call(name: "copySelection"))
        return selection != nil
    }

    func clearSelection() {
        calls.append(Call(name: "clearSelection"))
        selection = nil
    }

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

    @Test func altMouseDownBypassesMouseTrackingAndClearsSelection() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .button
        let view = makeView(controller: controller)

        let event = makeEvent(type: .leftMouseDown, modifierFlags: .option)
        #expect(event != nil)

        view.mouseDown(with: event!)

        // Single click clears selection and defers creation to drag
        #expect(controller.calls.contains(where: { $0.name == "clearSelection" }))
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

    @Test func mouseDownWithoutTrackingModeClearsSelection() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .none
        let view = makeView(controller: controller)

        let event = makeEvent(type: .leftMouseDown)
        #expect(event != nil)

        view.mouseDown(with: event!)

        // Single click clears selection and defers creation to drag
        #expect(controller.calls.contains(where: { $0.name == "clearSelection" }))
        #expect(!controller.calls.contains(where: { $0.name == "handleMouseEvent" }))
    }

    // MARK: mouseDragged

    @Test func altMouseDraggedBypassesMouseTrackingAndUpdatesSelection() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .button
        let view = makeView(controller: controller)

        // mouseDown first to set pending drag origin
        let downEvent = makeEvent(
            type: .leftMouseDown, location: NSPoint(x: 10, y: 10),
            modifierFlags: .option)
        #expect(downEvent != nil)
        view.mouseDown(with: downEvent!)

        controller.calls.removeAll()

        // Drag far enough to exceed the 3-pixel threshold
        let dragEvent = makeEvent(
            type: .leftMouseDragged, location: NSPoint(x: 20, y: 10),
            modifierFlags: .option)
        #expect(dragEvent != nil)
        view.mouseDragged(with: dragEvent!)

        // First drag creates the selection, then updates it
        #expect(controller.calls.contains(where: { $0.name == "startSelection" }))
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

    // MARK: Deferred selection (single click does not create selection)

    @Test func singleClickDoesNotCreateSelection() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .none
        let view = makeView(controller: controller)

        let event = makeEvent(type: .leftMouseDown)
        #expect(event != nil)
        view.mouseDown(with: event!)

        #expect(controller.calls.contains(where: { $0.name == "clearSelection" }))
        #expect(!controller.calls.contains(where: { $0.name == "startSelection" }))
    }

    @Test func dragAfterSingleClickCreatesAndUpdatesSelection() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .none
        let view = makeView(controller: controller)

        let downEvent = makeEvent(type: .leftMouseDown, location: NSPoint(x: 10, y: 10))
        #expect(downEvent != nil)
        view.mouseDown(with: downEvent!)
        controller.calls.removeAll()

        // Drag far enough to exceed the 3-pixel threshold
        let dragEvent = makeEvent(type: .leftMouseDragged, location: NSPoint(x: 20, y: 10))
        #expect(dragEvent != nil)
        view.mouseDragged(with: dragEvent!)

        #expect(controller.calls.contains(where: { $0.name == "startSelection" }))
        #expect(controller.calls.contains(where: { $0.name == "updateSelection" }))
    }

    @Test func dragBelowThresholdDoesNotCreateSelection() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .none
        let view = makeView(controller: controller)

        let downEvent = makeEvent(type: .leftMouseDown, location: NSPoint(x: 10, y: 10))
        #expect(downEvent != nil)
        view.mouseDown(with: downEvent!)
        controller.calls.removeAll()

        // Drag only 1 pixel — below the 3-pixel threshold
        let dragEvent = makeEvent(type: .leftMouseDragged, location: NSPoint(x: 11, y: 10))
        #expect(dragEvent != nil)
        view.mouseDragged(with: dragEvent!)

        #expect(!controller.calls.contains(where: { $0.name == "startSelection" }))
        #expect(!controller.calls.contains(where: { $0.name == "updateSelection" }))
    }

    // MARK: Auto-copy on mouse up

    @Test func mouseUpAutoCopiesWhenSelectionExists() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .none
        let view = makeView(controller: controller)

        // Simulate an active selection with different start/end
        controller.selection = Selection(
            start: SelectionPoint(line: 0, col: 0),
            end: SelectionPoint(line: 0, col: 5)
        )

        let event = makeEvent(type: .leftMouseUp)
        #expect(event != nil)
        view.mouseUp(with: event!)

        #expect(controller.calls.contains(where: { $0.name == "copySelection" }))
    }

    @Test func mouseUpDoesNotCopyWhenNoSelection() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .none
        let view = makeView(controller: controller)

        let event = makeEvent(type: .leftMouseUp)
        #expect(event != nil)
        view.mouseUp(with: event!)

        #expect(!controller.calls.contains(where: { $0.name == "copySelection" }))
    }

    @Test func mouseUpDoesNotCopyWhenSelectionIsZeroLength() {
        let controller = MockMouseController()
        controller.mouseTrackingMode = .none
        let view = makeView(controller: controller)

        // Same start and end = zero-length selection (e.g. after click without drag)
        controller.selection = Selection(
            start: SelectionPoint(line: 0, col: 3),
            end: SelectionPoint(line: 0, col: 3)
        )

        let event = makeEvent(type: .leftMouseUp)
        #expect(event != nil)
        view.mouseUp(with: event!)

        #expect(!controller.calls.contains(where: { $0.name == "copySelection" }))
    }
}
