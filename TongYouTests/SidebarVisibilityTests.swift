import Testing
@testable import TongYou

@Suite("Sidebar Visibility")
struct SidebarVisibilityTests {

    @Test func autoModeShowsSidebarWhenMultipleSessionsAndNotSuppressed() {
        #expect(TerminalWindowView.shouldShowSidebar(visibility: .auto, sessionCount: 2, suppressAutoSidebar: false) == true)
    }

    @Test func autoModeHidesSidebarWhenSingleSession() {
        #expect(TerminalWindowView.shouldShowSidebar(visibility: .auto, sessionCount: 1, suppressAutoSidebar: false) == false)
    }

    @Test func autoModeHidesSidebarWhenSuppressedEvenWithMultipleSessions() {
        #expect(TerminalWindowView.shouldShowSidebar(visibility: .auto, sessionCount: 2, suppressAutoSidebar: true) == false)
    }

    @Test func alwaysModeShowsSidebarRegardlessOfState() {
        #expect(TerminalWindowView.shouldShowSidebar(visibility: .always, sessionCount: 1, suppressAutoSidebar: true) == true)
        #expect(TerminalWindowView.shouldShowSidebar(visibility: .always, sessionCount: 5, suppressAutoSidebar: false) == true)
    }

    @Test func neverModeHidesSidebarRegardlessOfState() {
        #expect(TerminalWindowView.shouldShowSidebar(visibility: .never, sessionCount: 1, suppressAutoSidebar: true) == false)
        #expect(TerminalWindowView.shouldShowSidebar(visibility: .never, sessionCount: 5, suppressAutoSidebar: false) == false)
    }

    @Test func toggleFromAutoWhenSuppressedShowsSidebar() {
        // Simulate the bug scenario: auto mode, multiple sessions, but suppressed.
        // Before fix this would toggle to .never; after fix it toggles to .always.
        let visibility: SidebarVisibility = .auto
        let suppress = true
        let sessionCount = 2

        let currentlyVisible = TerminalWindowView.shouldShowSidebar(
            visibility: visibility,
            sessionCount: sessionCount,
            suppressAutoSidebar: suppress
        )
        #expect(currentlyVisible == false)

        let newVisibility = currentlyVisible ? SidebarVisibility.never : .always
        #expect(newVisibility == .always)
    }

    @Test func toggleFromAutoWhenVisibleHidesSidebar() {
        let visibility: SidebarVisibility = .auto
        let suppress = false
        let sessionCount = 2

        let currentlyVisible = TerminalWindowView.shouldShowSidebar(
            visibility: visibility,
            sessionCount: sessionCount,
            suppressAutoSidebar: suppress
        )
        #expect(currentlyVisible == true)

        let newVisibility = currentlyVisible ? SidebarVisibility.never : .always
        #expect(newVisibility == .never)
    }

    @Test func toggleFromAlwaysHidesSidebar() {
        let visibility: SidebarVisibility = .always
        let suppress = false
        let sessionCount = 1

        let currentlyVisible = TerminalWindowView.shouldShowSidebar(
            visibility: visibility,
            sessionCount: sessionCount,
            suppressAutoSidebar: suppress
        )
        #expect(currentlyVisible == true)

        let newVisibility = currentlyVisible ? SidebarVisibility.never : .always
        #expect(newVisibility == .never)
    }

    @Test func toggleFromNeverShowsSidebar() {
        let visibility: SidebarVisibility = .never
        let suppress = false
        let sessionCount = 1

        let currentlyVisible = TerminalWindowView.shouldShowSidebar(
            visibility: visibility,
            sessionCount: sessionCount,
            suppressAutoSidebar: suppress
        )
        #expect(currentlyVisible == false)

        let newVisibility = currentlyVisible ? SidebarVisibility.never : .always
        #expect(newVisibility == .always)
    }
}
