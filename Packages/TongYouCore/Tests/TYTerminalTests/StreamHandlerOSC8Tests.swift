import Testing
import Foundation
@testable import TYTerminal

@Suite("StreamHandler OSC 8 Tests", .serialized)
struct StreamHandlerOSC8Tests {

    /// Helper to parse a string containing OSC sequences
    private func parseOSC8(_ sequence: String) -> (params: String, url: String)? {
        // Remove ESC ]8; prefix (4 characters: ESC, ], 8, ;)
        guard sequence.hasPrefix("\u{001B}]8;") else { return nil }
        let afterPrefix = sequence.dropFirst(4)

        // Find ST terminator (BEL or ESC \)
        let stIndex: String.Index
        if let belIdx = afterPrefix.firstIndex(of: "\u{0007}") {
            stIndex = belIdx
        } else if let escIdx = afterPrefix.firstIndex(of: "\u{001B}") {
            stIndex = escIdx
        } else {
            return nil
        }

        let content = String(afterPrefix[..<stIndex])
        let parts = content.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        return (params: String(parts[0]), url: String(parts[1]))
    }

    @Test("parses OSC 8 open sequence")
    func parsesOSC8Open() {
        let result = parseOSC8("\u{001B}]8;;https://example.com\u{0007}")
        #expect(result?.params == "")
        #expect(result?.url == "https://example.com")
    }

    @Test("parses OSC 8 with explicit ID")
    func parsesOSC8WithId() {
        let result = parseOSC8("\u{001B}]8;id=link1;https://example.com\u{0007}")
        #expect(result?.params == "id=link1")
        #expect(result?.url == "https://example.com")
    }

    @Test("parses OSC 8 close sequence")
    func parsesOSC8Close() {
        let result = parseOSC8("\u{001B}]8;;\u{0007}")
        #expect(result?.params == "")
        #expect(result?.url == "")
    }

    @Test("handles OSC 8 through StreamHandler")
    func handlesOSC8ThroughStreamHandler() {
        let screen = Screen(columns: 20, rows: 5)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Process: OSC 8 open, print text, OSC 8 close
        let input = "\u{001B}]8;;https://example.com\u{0007}Hello\u{001B}]8;;\u{0007}"
        input.utf8.withContiguousStorageIfAvailable { buffer in
            parser.feed(buffer) { action in
                handler.handle(action)
            }
        }
        handler.flush()

        // Check that cells have hyperlinkId
        let cell0 = screen.cell(at: 0, row: 0)
        let cell1 = screen.cell(at: 1, row: 0)
        let cell4 = screen.cell(at: 4, row: 0)

        #expect(cell0.attributes.hyperlinkId != 0)
        #expect(cell1.attributes.hyperlinkId == cell0.attributes.hyperlinkId)
        #expect(cell4.attributes.hyperlinkId == cell0.attributes.hyperlinkId)

        // Verify the link ID is registered
        let linkId = cell0.attributes.hyperlinkId
        let url = handler.hyperlinkRegistry.url(for: linkId)
        #expect(url == "https://example.com")
    }

    @Test("OSC 8 close resets hyperlink")
    func osc8CloseResetsHyperlink() {
        let screen = Screen(columns: 20, rows: 5)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Process: OSC 8 open, print text, OSC 8 close, print more text
        let input = "\u{001B}]8;;https://example.com\u{0007}AB\u{001B}]8;;\u{0007}CD"
        input.utf8.withContiguousStorageIfAvailable { buffer in
            parser.feed(buffer) { action in
                handler.handle(action)
            }
        }
        handler.flush()

        // Cells 0-1 should have hyperlink, cells 2-3 should not
        let cell0 = screen.cell(at: 0, row: 0)
        let cell1 = screen.cell(at: 1, row: 0)
        let cell2 = screen.cell(at: 2, row: 0)
        let cell3 = screen.cell(at: 3, row: 0)

        #expect(cell0.attributes.hyperlinkId != 0)
        #expect(cell1.attributes.hyperlinkId != 0)
        #expect(cell2.attributes.hyperlinkId == 0)
        #expect(cell3.attributes.hyperlinkId == 0)
    }

    @Test("multiple OSC 8 hyperlinks in sequence")
    func multipleOSC8Hyperlinks() {
        let screen = Screen(columns: 40, rows: 5)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Process two hyperlinks in sequence
        let input = "\u{001B}]8;;https://first.com\u{0007}First\u{001B}]8;;\u{0007} \u{001B}]8;;https://second.com\u{0007}Second\u{001B}]8;;\u{0007}"
        input.utf8.withContiguousStorageIfAvailable { buffer in
            parser.feed(buffer) { action in
                handler.handle(action)
            }
        }
        handler.flush()

        // Check first link
        let cell0 = screen.cell(at: 0, row: 0)
        let linkId1 = cell0.attributes.hyperlinkId
        #expect(linkId1 != 0)
        #expect(handler.hyperlinkRegistry.url(for: linkId1) == "https://first.com")

        // Check second link (should have different ID)
        let cell7 = screen.cell(at: 7, row: 0)
        let linkId2 = cell7.attributes.hyperlinkId
        #expect(linkId2 != 0)
        #expect(linkId2 != linkId1)
        #expect(handler.hyperlinkRegistry.url(for: linkId2) == "https://second.com")
    }

    @Test("RIS clears hyperlink state")
    func risClearsHyperlinkState() {
        let screen = Screen(columns: 20, rows: 5)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Process: OSC 8 open, then RIS (ESC c)
        let input = "\u{001B}]8;;https://example.com\u{0007}\u{001B}c"
        input.utf8.withContiguousStorageIfAvailable { buffer in
            parser.feed(buffer) { action in
                handler.handle(action)
            }
        }
        handler.flush()

        // Registry should be empty after RIS
        // (The cell content is also cleared by RIS, but let's verify registry)
        // After RIS, new registrations should start from ID 1 again
        let newId = handler.hyperlinkRegistry.register(url: "https://new.com")
        #expect(newId == 1)
    }
}
