import Testing
import Foundation
@testable import TYTerminal

@Suite("HyperlinkRegistry Tests", .serialized)
struct HyperlinkRegistryTests {

    @Test("registers URL and returns numeric ID")
    func registersURL() {
        let registry = HyperlinkRegistry()
        let id1 = registry.register(url: "https://example.com")
        let id2 = registry.register(url: "https://github.com")

        #expect(id1 != 0)
        #expect(id2 != 0)
        #expect(id1 != id2)
    }

    @Test("returns same ID for same URL")
    func returnsSameIDForSameURL() {
        let registry = HyperlinkRegistry()
        let id1 = registry.register(url: "https://example.com")
        let id2 = registry.register(url: "https://example.com")

        #expect(id1 == id2)
    }

    @Test("looks up URL by ID")
    func looksUpURL() {
        let registry = HyperlinkRegistry()
        let url = "https://example.com"
        let id = registry.register(url: url)

        #expect(registry.url(for: id) == url)
        #expect(registry.url(for: 999) == nil)
    }

    @Test("handles explicit ID mapping")
    func handlesExplicitId() {
        let registry = HyperlinkRegistry()
        let id1 = registry.register(url: "https://example.com", explicitId: "link1")
        let id2 = registry.register(url: "https://example.com", explicitId: "link1")

        #expect(id1 == id2)
    }

    @Test("explicit ID can update URL")
    func explicitIdUpdatesURL() {
        let registry = HyperlinkRegistry()
        let id1 = registry.register(url: "https://example.com", explicitId: "link1")
        let id2 = registry.register(url: "https://github.com", explicitId: "link1")

        #expect(id1 == id2)
        #expect(registry.url(for: id1) == "https://github.com")
    }

    @Test("clears all registrations")
    func clearsAllRegistrations() {
        let registry = HyperlinkRegistry()
        let id = registry.register(url: "https://example.com")
        registry.clear()

        #expect(registry.url(for: id) == nil)
        #expect(registry.register(url: "https://new.com") == 1)
    }
}
