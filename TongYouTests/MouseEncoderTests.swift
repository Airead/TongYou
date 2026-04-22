import Foundation
import Testing
@testable import TongYou

struct MouseEncoderTests {

    // MARK: - Helpers

    private func press(
        _ button: MouseEncoder.Button,
        col: Int, row: Int,
        shift: Bool = false, option: Bool = false, control: Bool = false
    ) -> MouseEncoder.Event {
        MouseEncoder.Event(
            action: .press, button: button, col: col, row: row,
            modifiers: .init(shift: shift, option: option, control: control)
        )
    }

    private func release(
        _ button: MouseEncoder.Button,
        col: Int, row: Int
    ) -> MouseEncoder.Event {
        MouseEncoder.Event(action: .release, button: button, col: col, row: row)
    }

    private func motion(
        col: Int, row: Int,
        button: MouseEncoder.Button? = nil
    ) -> MouseEncoder.Event {
        MouseEncoder.Event(action: .motion, button: button, col: col, row: row)
    }

    // MARK: - No Tracking

    @Test func noTrackingReturnsNil() {
        let event = press(.left, col: 5, row: 10)
        let result = MouseEncoder.encode(event: event, trackingMode: .none, format: .x10)
        #expect(result == nil)
    }

    // MARK: - X10 Tracking Mode

    @Test func x10OnlyReportsPresses() {
        let rel = release(.left, col: 5, row: 10)
        #expect(MouseEncoder.encode(event: rel, trackingMode: .x10, format: .x10) == nil)

        let mov = motion(col: 5, row: 10, button: .left)
        #expect(MouseEncoder.encode(event: mov, trackingMode: .x10, format: .x10) == nil)
    }

    @Test func x10LeftClickAtOrigin() {
        let event = press(.left, col: 0, row: 0)
        let result = MouseEncoder.encode(event: event, trackingMode: .x10, format: .x10)
        // ESC[M <button+32=32> <col+33=33> <row+33=33>
        #expect(result == Data([0x1B, 0x5B, 0x4D, 32, 33, 33]))
    }

    @Test func x10RightClick() {
        let event = press(.right, col: 10, row: 5)
        let result = MouseEncoder.encode(event: event, trackingMode: .x10, format: .x10)
        // button=2, col=10+33=43, row=5+33=38
        #expect(result == Data([0x1B, 0x5B, 0x4D, 34, 43, 38]))
    }

    @Test func x10CoordinateLimit() {
        // X10 can't encode coords > 222
        let event = press(.left, col: 223, row: 0)
        let result = MouseEncoder.encode(event: event, trackingMode: .x10, format: .x10)
        #expect(result == nil)
    }

    @Test func x10ScrollUpIgnored() {
        // X10 only reports left/middle/right
        let event = press(.scrollUp, col: 0, row: 0)
        let result = MouseEncoder.encode(event: event, trackingMode: .x10, format: .x10)
        #expect(result == nil)
    }

    // MARK: - Normal Tracking Mode

    @Test func normalTrackingReportsRelease() {
        let event = release(.left, col: 5, row: 10)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .x10)
        // Release in X10 format: button code = 3 (release)
        // ESC[M <3+32=35> <5+33=38> <10+33=43>
        #expect(result == Data([0x1B, 0x5B, 0x4D, 35, 38, 43]))
    }

    @Test func normalTrackingIgnoresMotion() {
        let event = motion(col: 5, row: 10, button: .left)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .x10)
        #expect(result == nil)
    }

    // MARK: - Button Tracking Mode

    @Test func buttonTrackingReportsMotionWithButton() {
        let event = motion(col: 5, row: 10, button: .left)
        let result = MouseEncoder.encode(event: event, trackingMode: .button, format: .x10)
        // motion adds 32 to code: left=0 + motion=32 = 32
        // ESC[M <32+32=64> <5+33=38> <10+33=43>
        #expect(result == Data([0x1B, 0x5B, 0x4D, 64, 38, 43]))
    }

    @Test func buttonTrackingIgnoresMotionWithoutButton() {
        let event = motion(col: 5, row: 10)
        let result = MouseEncoder.encode(event: event, trackingMode: .button, format: .x10)
        #expect(result == nil)
    }

    // MARK: - Any Tracking Mode

    @Test func anyTrackingReportsMotionWithoutButton() {
        let event = motion(col: 5, row: 10)
        let result = MouseEncoder.encode(event: event, trackingMode: .any, format: .x10)
        // no button + motion: code = 3 + 32 = 35
        // ESC[M <35+32=67> <5+33=38> <10+33=43>
        #expect(result == Data([0x1B, 0x5B, 0x4D, 67, 38, 43]))
    }

    // MARK: - SGR Format

    @Test func sgrLeftPress() {
        let event = press(.left, col: 10, row: 20)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgr)
        // ESC[<0;11;21M
        #expect(result == Data("\u{1B}[<0;11;21M".utf8))
    }

    @Test func sgrLeftRelease() {
        let event = release(.left, col: 10, row: 20)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgr)
        // ESC[<0;11;21m  (lowercase 'm' for release)
        #expect(result == Data("\u{1B}[<0;11;21m".utf8))
    }

    @Test func sgrRightRelease() {
        let event = release(.right, col: 5, row: 3)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgr)
        // SGR preserves button on release: button=2
        #expect(result == Data("\u{1B}[<2;6;4m".utf8))
    }

    @Test func sgrScrollUp() {
        let event = press(.scrollUp, col: 0, row: 0)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgr)
        // scrollUp = 64
        #expect(result == Data("\u{1B}[<64;1;1M".utf8))
    }

    @Test func sgrScrollDown() {
        let event = press(.scrollDown, col: 0, row: 0)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgr)
        // scrollDown = 65
        #expect(result == Data("\u{1B}[<65;1;1M".utf8))
    }

    @Test func sgrLargeCoordinates() {
        // SGR has no coordinate limit
        let event = press(.left, col: 300, row: 500)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgr)
        #expect(result == Data("\u{1B}[<0;301;501M".utf8))
    }

    // MARK: - Modifiers

    @Test func shiftModifier() {
        let event = press(.left, col: 0, row: 0, shift: true)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgr)
        // left=0 + shift=4 → code=4
        #expect(result == Data("\u{1B}[<4;1;1M".utf8))
    }

    @Test func altModifier() {
        let event = press(.left, col: 0, row: 0, option: true)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgr)
        // left=0 + alt=8 → code=8
        #expect(result == Data("\u{1B}[<8;1;1M".utf8))
    }

    @Test func ctrlModifier() {
        let event = press(.left, col: 0, row: 0, control: true)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgr)
        // left=0 + ctrl=16 → code=16
        #expect(result == Data("\u{1B}[<16;1;1M".utf8))
    }

    @Test func combinedModifiers() {
        let event = press(.left, col: 0, row: 0, shift: true, option: true, control: true)
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgr)
        // left=0 + shift=4 + alt=8 + ctrl=16 → code=28
        #expect(result == Data("\u{1B}[<28;1;1M".utf8))
    }

    // MARK: - Motion with Modifiers

    @Test func motionWithButtonAndShift() {
        let event = MouseEncoder.Event(
            action: .motion, button: .left, col: 5, row: 3,
            modifiers: .init(shift: true)
        )
        let result = MouseEncoder.encode(event: event, trackingMode: .any, format: .sgr)
        // left=0 + shift=4 + motion=32 → code=36
        #expect(result == Data("\u{1B}[<36;6;4M".utf8))
    }

    // MARK: - SGR Pixel Format

    @Test func sgrPixelsLeftPress() {
        let event = MouseEncoder.Event(
            action: .press, button: .left, col: 10, row: 20, x: 150, y: 300
        )
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgrPixels)
        // ESC[<0;150;300M
        #expect(result == Data("\u{1B}[<0;150;300M".utf8))
    }

    @Test func sgrPixelsLeftRelease() {
        let event = MouseEncoder.Event(
            action: .release, button: .left, col: 10, row: 20, x: 150, y: 300
        )
        let result = MouseEncoder.encode(event: event, trackingMode: .normal, format: .sgrPixels)
        // ESC[<0;150;300m (lowercase 'm' for release)
        #expect(result == Data("\u{1B}[<0;150;300m".utf8))
    }

    @Test func sgrPixelsUsesPixelCoordinatesNotCell() {
        // Same cell, different pixels
        let event1 = MouseEncoder.Event(
            action: .press, button: .left, col: 5, row: 10, x: 80, y: 160
        )
        let event2 = MouseEncoder.Event(
            action: .press, button: .left, col: 5, row: 10, x: 95, y: 175
        )
        let result1 = MouseEncoder.encode(event: event1, trackingMode: .normal, format: .sgrPixels)
        let result2 = MouseEncoder.encode(event: event2, trackingMode: .normal, format: .sgrPixels)
        #expect(result1 == Data("\u{1B}[<0;80;160M".utf8))
        #expect(result2 == Data("\u{1B}[<0;95;175M".utf8))
    }
}
