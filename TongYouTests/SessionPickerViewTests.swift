import AppKit
import SwiftUI
import Testing
@testable import TongYou

@Suite("SessionPickerView")
struct SessionPickerViewTests {

    @Test func searchFieldBecomesFirstResponderOnAppear() async throws {
        var session = TerminalSession(name: "local", source: .local)
        session.tabs = [TerminalTab()]
        let view = SessionPickerView(
            sessions: [session],
            activeSessionIndex: 0,
            attachedSessionIDs: [],
            onSelect: { _ in },
            onDismiss: {}
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.makeKeyAndOrderFront(nil)

        // Ensure another view holds first responder initially.
        let dummyView = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(dummyView)
        window.makeFirstResponder(dummyView)
        #expect(window.firstResponder === dummyView)

        // Trigger layout so onAppear fires.
        hosting.view.layout()

        // Wait for the async DispatchQueue.main.async block inside onAppear.
        try await Task.sleep(for: .milliseconds(50))

        let responder = window.firstResponder
        // When a SwiftUI TextField becomes focused, AppKit creates a field editor (NSTextView).
        #expect(responder is NSTextView || responder is NSTextField)
    }
}
