import Testing
@testable import TongYou

@Suite("TabBarView")
struct TabBarViewTests {

    @Test func badgeTextForSmallCount() {
        #expect(TabBarView.badgeText(for: 3) == "3")
    }

    @Test func badgeTextCapsAtNinePlus() {
        #expect(TabBarView.badgeText(for: 10) == "9+")
        #expect(TabBarView.badgeText(for: 99) == "9+")
    }
}
