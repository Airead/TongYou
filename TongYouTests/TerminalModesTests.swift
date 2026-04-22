import Testing
@testable import TongYou

@Suite struct TerminalModesTests {

    @Test func defaults() {
        let modes = TerminalModes()
        #expect(modes.isSet(.cursorVisible))
        #expect(modes.isSet(.autowrap))
        #expect(!modes.isSet(.cursorKeys))
        #expect(!modes.isSet(.altScreen))
        #expect(!modes.isSet(.bracketedPaste))
        #expect(!modes.isSet(.blinkingCursor))
    }

    @Test func setAndReset() {
        var modes = TerminalModes()
        modes.set(.cursorKeys, true)
        #expect(modes.isSet(.cursorKeys))
        modes.set(.cursorKeys, false)
        #expect(!modes.isSet(.cursorKeys))
    }

    @Test func fullReset() {
        var modes = TerminalModes()
        modes.set(.cursorKeys, true)
        modes.set(.cursorVisible, false)
        modes.reset()
        #expect(modes == TerminalModes())
    }

    @Test func fromRawValue() {
        #expect(TerminalModes.from(rawValue: 1) == .cursorKeys)
        #expect(TerminalModes.from(rawValue: 3) == .columnMode)
        #expect(TerminalModes.from(rawValue: 4) == .smoothScroll)
        #expect(TerminalModes.from(rawValue: 5) == .reverseVideo)
        #expect(TerminalModes.from(rawValue: 6) == .originMode)
        #expect(TerminalModes.from(rawValue: 7) == .autowrap)
        #expect(TerminalModes.from(rawValue: 12) == .blinkingCursor)
        #expect(TerminalModes.from(rawValue: 25) == .cursorVisible)
        #expect(TerminalModes.from(rawValue: 1049) == .altScreen)
        #expect(TerminalModes.from(rawValue: 9999) == .keypadApplication)
        #expect(TerminalModes.from(rawValue: 12345) == nil)
    }

    // MARK: - Mouse Tracking Modes

    @Test func mouseTrackingDefaults() {
        let modes = TerminalModes()
        #expect(modes.mouseTracking == .none)
        #expect(modes.mouseFormat == .x10)
    }

    @Test func mouseTrackingSetX10() {
        var modes = TerminalModes()
        let ok = modes.setMouseTracking(rawParam: 9, enabled: true)
        #expect(ok)
        #expect(modes.mouseTracking == .x10)
    }

    @Test func mouseTrackingSetNormal() {
        var modes = TerminalModes()
        let ok = modes.setMouseTracking(rawParam: 1000, enabled: true)
        #expect(ok)
        #expect(modes.mouseTracking == .normal)
    }

    @Test func mouseTrackingSetButton() {
        var modes = TerminalModes()
        let ok = modes.setMouseTracking(rawParam: 1002, enabled: true)
        #expect(ok)
        #expect(modes.mouseTracking == .button)
    }

    @Test func mouseTrackingSetAny() {
        var modes = TerminalModes()
        let ok = modes.setMouseTracking(rawParam: 1003, enabled: true)
        #expect(ok)
        #expect(modes.mouseTracking == .any)
    }

    @Test func mouseTrackingMutuallyExclusive() {
        var modes = TerminalModes()
        modes.setMouseTracking(rawParam: 1000, enabled: true)
        #expect(modes.mouseTracking == .normal)
        modes.setMouseTracking(rawParam: 1003, enabled: true)
        #expect(modes.mouseTracking == .any)
    }

    @Test func mouseTrackingDisable() {
        var modes = TerminalModes()
        modes.setMouseTracking(rawParam: 1000, enabled: true)
        #expect(modes.mouseTracking == .normal)
        modes.setMouseTracking(rawParam: 1000, enabled: false)
        #expect(modes.mouseTracking == .none)
    }

    @Test func mouseTrackingDisableDifferentModeNoOp() {
        var modes = TerminalModes()
        modes.setMouseTracking(rawParam: 1000, enabled: true)
        modes.setMouseTracking(rawParam: 1003, enabled: false)
        #expect(modes.mouseTracking == .normal)
    }

    @Test func mouseTrackingUnknownParam() {
        var modes = TerminalModes()
        let ok = modes.setMouseTracking(rawParam: 999, enabled: true)
        #expect(!ok)
        #expect(modes.mouseTracking == .none)
    }

    @Test func mouseFormatSGR() {
        var modes = TerminalModes()
        let ok = modes.setMouseFormat(rawParam: 1006, enabled: true)
        #expect(ok)
        #expect(modes.mouseFormat == .sgr)
    }

    @Test func mouseFormatResetToX10() {
        var modes = TerminalModes()
        modes.setMouseFormat(rawParam: 1006, enabled: true)
        modes.setMouseFormat(rawParam: 1006, enabled: false)
        #expect(modes.mouseFormat == .x10)
    }

    @Test func mouseFormatUnknownParam() {
        var modes = TerminalModes()
        let ok = modes.setMouseFormat(rawParam: 999, enabled: true)
        #expect(!ok)
        #expect(modes.mouseFormat == .x10)
    }

    @Test func resetClearsMouseModes() {
        var modes = TerminalModes()
        modes.setMouseTracking(rawParam: 1003, enabled: true)
        modes.setMouseFormat(rawParam: 1006, enabled: true)
        modes.reset()
        #expect(modes.mouseTracking == .none)
        #expect(modes.mouseFormat == .x10)
    }

    // Regression: Optional<MouseTrackingMode> `.none` is ambiguous with Optional.none.
    // The safe pattern is guard-let then compare the unwrapped value.
    @Test func defaultTrackingModeDetectedAsInactive() {
        let modes = TerminalModes()
        let tracking: TerminalModes.MouseTrackingMode? = modes.mouseTracking
        // Mirrors the guard-let pattern used in MetalView.isMouseTrackingActive
        guard let mode = tracking else {
            Issue.record("mouseTracking should not be nil")
            return
        }
        #expect(mode == .none, "Default mouse tracking should be .none (inactive)")
    }
}
