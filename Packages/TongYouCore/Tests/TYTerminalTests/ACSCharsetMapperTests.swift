import Foundation
import Testing
@testable import TYTerminal

@Suite("ACS charset mapper tests", .serialized)
struct ACSCharsetMapperTests {

    @Test func decSpecialMapping() {
        let state = CharsetState()

        // Default is ASCII
        #expect(state.map(0x71) == Unicode.Scalar("q"))

        var acsState = CharsetState()
        acsState.configure(slot: .g0, set: .decSpecial)
        acsState.invokeGL(.g0)

        #expect(acsState.map(0x71) == Unicode.Scalar(0x2500)) // q -> ─
        #expect(acsState.map(0x78) == Unicode.Scalar(0x2502)) // x -> │
        #expect(acsState.map(0x6A) == Unicode.Scalar(0x2518)) // j -> ┘
        #expect(acsState.map(0x6D) == Unicode.Scalar(0x2514)) // m -> └
        #expect(acsState.map(0x60) == Unicode.Scalar(0x25C6)) // ` -> ◆
    }

    @Test func g1WithShiftOut() {
        var state = CharsetState()
        state.configure(slot: .g1, set: .decSpecial)
        state.invokeGL(.g0)

        #expect(state.map(0x71) == Unicode.Scalar("q")) // G0 is ascii

        state.invokeGL(.g1)
        #expect(state.map(0x71) == Unicode.Scalar(0x2500)) // G1 is decSpecial
    }
}
