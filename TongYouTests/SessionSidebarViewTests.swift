import Testing
@testable import TongYou

@Suite("SessionSidebarView")
struct SessionSidebarViewTests {

    @Test func badgeTextForSmallCount() {
        #expect(SessionSidebarView.badgeText(for: 2) == "2")
    }

    @Test func badgeTextCapsAtNinePlus() {
        #expect(SessionSidebarView.badgeText(for: 12) == "9+")
        #expect(SessionSidebarView.badgeText(for: 100) == "9+")
    }
}
