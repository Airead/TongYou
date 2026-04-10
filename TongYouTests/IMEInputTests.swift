import AppKit
import Testing
@testable import TongYou

struct IMEInputTests {

    // MetalView can be instantiated without a window for state management tests.
    private func makeView() -> MetalView {
        MetalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    // MARK: - Marked Text State

    @Test func initiallyHasNoMarkedText() {
        let view = makeView()
        #expect(view.hasMarkedText() == false)
        #expect(view.markedRange().location == NSNotFound)
    }

    @Test func setMarkedTextWithString() {
        let view = makeView()
        view.setMarkedText("你", selectedRange: NSRange(location: 0, length: 1),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText() == true)
        #expect(view.markedRange() == NSRange(location: 0, length: 1))
    }

    @Test func setMarkedTextWithAttributedString() {
        let view = makeView()
        let attrStr = NSAttributedString(string: "拼音")
        view.setMarkedText(attrStr, selectedRange: NSRange(location: 0, length: 2),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText() == true)
        #expect(view.markedRange() == NSRange(location: 0, length: 2))
    }

    @Test func setMarkedTextUpdatesOnSubsequentCalls() {
        let view = makeView()
        view.setMarkedText("你", selectedRange: NSRange(location: 0, length: 1),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.markedRange().length == 1)

        view.setMarkedText("你好", selectedRange: NSRange(location: 0, length: 2),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.markedRange().length == 2)
    }

    @Test func unmarkTextClearsMarkedText() {
        let view = makeView()
        view.setMarkedText("你好", selectedRange: NSRange(location: 0, length: 2),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText() == true)

        view.unmarkText()
        #expect(view.hasMarkedText() == false)
        #expect(view.markedRange().location == NSNotFound)
    }

    // MARK: - insertText

    @Test func insertTextClearsMarkedText() {
        let view = makeView()
        // Simulate IME composing then committing
        view.setMarkedText("你好", selectedRange: NSRange(location: 0, length: 2),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText() == true)

        view.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText() == false)
    }

    @Test func insertTextAcceptsAttributedString() {
        let view = makeView()
        let attrStr = NSAttributedString(string: "世界")
        // Should not crash
        view.insertText(attrStr, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText() == false)
    }

    // MARK: - Other Protocol Methods

    @Test func selectedRangeReturnsNotFound() {
        let view = makeView()
        let range = view.selectedRange()
        #expect(range.location == NSNotFound)
    }

    @Test func validAttributesReturnsEmpty() {
        let view = makeView()
        #expect(view.validAttributesForMarkedText().isEmpty)
    }

    @Test func attributedSubstringReturnsNil() {
        let view = makeView()
        let range = NSRange(location: 0, length: 5)
        #expect(view.attributedSubstring(forProposedRange: range, actualRange: nil) == nil)
    }

    @Test func characterIndexReturnsZero() {
        let view = makeView()
        #expect(view.characterIndex(for: .zero) == 0)
    }
}
