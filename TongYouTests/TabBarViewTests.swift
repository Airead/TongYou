import Testing
@testable import TongYou

@Suite("NotificationStore Badge Text")
struct BadgeTextTests {

    @Test func badgeTextForSmallCount() {
        #expect(NotificationStore.badgeText(for: 2) == "2")
        #expect(NotificationStore.badgeText(for: 3) == "3")
    }

    @Test func badgeTextCapsAtNinePlus() {
        #expect(NotificationStore.badgeText(for: 10) == "9+")
        #expect(NotificationStore.badgeText(for: 99) == "9+")
        #expect(NotificationStore.badgeText(for: 100) == "9+")
    }
}
