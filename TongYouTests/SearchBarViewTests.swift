import AppKit
import Testing
@testable import TongYou

@Suite("SearchBarView")
struct SearchBarViewTests {

    @Test func searchFieldIsEditableAndSelectable() {
        let bar = SearchBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        #expect(bar.query.isEmpty)
        // Access the search field via reflection since it is private.
        let mirror = Mirror(reflecting: bar)
        guard let field = mirror.children.first(where: { $0.label == "searchField" })?.value as? NSTextField else {
            Issue.record("searchField not found")
            return
        }
        #expect(field.isEditable)
        #expect(field.isSelectable)
        #expect(field.acceptsFirstResponder)
    }

    @Test func activateSetsFirstResponderAsync() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let bar = SearchBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        window.contentView?.addSubview(bar)
        window.makeKey()

        // Ensure a different view is first responder before activation.
        window.makeFirstResponder(window.contentView)
        #expect(window.firstResponder !== bar)

        bar.activate()

        // Wait for the async DispatchQueue.main.async block inside activate().
        try? await Task.sleep(for: .milliseconds(50))

        let mirror = Mirror(reflecting: bar)
        guard let field = mirror.children.first(where: { $0.label == "searchField" })?.value as? NSTextField else {
            Issue.record("searchField not found")
            return
        }
        // When an NSTextField becomes first responder, AppKit creates a field editor (NSTextView).
        if let editor = field.currentEditor() {
            #expect(window.firstResponder === editor)
        } else {
            #expect(window.firstResponder === field)
        }
    }

    @Test func activateSelectsAllText() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let bar = SearchBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        window.contentView?.addSubview(bar)
        window.makeKey()

        let mirror = Mirror(reflecting: bar)
        guard let field = mirror.children.first(where: { $0.label == "searchField" })?.value as? NSTextField else {
            Issue.record("searchField not found")
            return
        }
        field.stringValue = "hello"

        bar.activate()
        try? await Task.sleep(for: .milliseconds(50))

        guard let editor = window.fieldEditor(false, for: field) as? NSTextView else {
            // If the field is not yet first responder, the test may fail on very slow machines.
            // We already tested first-responder transition above, so we just record an issue here.
            Issue.record("Field editor not available")
            return
        }
        #expect(editor.selectedRange().length == 5)
    }
}
