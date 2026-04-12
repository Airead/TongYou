import Testing
import TYTerminal
@testable import TongYou

@Suite struct SGRTests {

    // MARK: - Helpers

    /// Parse an SGR sequence from raw CSI params and return the resulting attributes.
    private func parseSGR(_ values: [UInt16], colons: Set<Int> = []) -> CellAttributes {
        var params = CSIParams()
        for (i, v) in values.enumerated() {
            params.finalizeParam(v)
            if colons.contains(i) {
                params.markColon()
            }
        }
        var attrs = CellAttributes.default
        SGRParser.parse(params, into: &attrs)
        return attrs
    }

    // MARK: - Reset

    @Test func resetAll() {
        var attrs = CellAttributes.default
        attrs.flags.insert(.bold)
        attrs.fgColor = .indexed(1)
        var params = CSIParams()
        params.finalizeParam(0)
        SGRParser.parse(params, into: &attrs)
        #expect(attrs == .default)
    }

    @Test func emptyParamsReset() {
        var attrs = CellAttributes.default
        attrs.flags.insert(.italic)
        let params = CSIParams()
        SGRParser.parse(params, into: &attrs)
        #expect(attrs == .default)
    }

    // MARK: - Text Styles

    @Test func boldOnOff() {
        let on = parseSGR([1])
        #expect(on.flags.contains(.bold))
        let off = parseSGR([22])
        #expect(!off.flags.contains(.bold))
    }

    @Test func dimOnOff() {
        let on = parseSGR([2])
        #expect(on.flags.contains(.dim))
        let off = parseSGR([22])
        #expect(!off.flags.contains(.dim))
    }

    @Test func italicOnOff() {
        let on = parseSGR([3])
        #expect(on.flags.contains(.italic))
        let off = parseSGR([23])
        #expect(!off.flags.contains(.italic))
    }

    @Test func underlineOnOff() {
        let on = parseSGR([4])
        #expect(on.flags.contains(.underline))
        let off = parseSGR([24])
        #expect(!off.flags.contains(.underline))
    }

    @Test func inverseOnOff() {
        let on = parseSGR([7])
        #expect(on.flags.contains(.inverse))
        let off = parseSGR([27])
        #expect(!off.flags.contains(.inverse))
    }

    @Test func strikethroughOnOff() {
        let on = parseSGR([9])
        #expect(on.flags.contains(.strikethrough))
        let off = parseSGR([29])
        #expect(!off.flags.contains(.strikethrough))
    }

    // MARK: - Standard Colors

    @Test func standardFgColors() {
        for i: UInt16 in 30...37 {
            let attrs = parseSGR([i])
            #expect(attrs.fgColor == .indexed(UInt8(i - 30)))
        }
    }

    @Test func standardBgColors() {
        for i: UInt16 in 40...47 {
            let attrs = parseSGR([i])
            #expect(attrs.bgColor == .indexed(UInt8(i - 40)))
        }
    }

    @Test func brightFgColors() {
        for i: UInt16 in 90...97 {
            let attrs = parseSGR([i])
            #expect(attrs.fgColor == .indexed(UInt8(i - 90 + 8)))
        }
    }

    @Test func brightBgColors() {
        for i: UInt16 in 100...107 {
            let attrs = parseSGR([i])
            #expect(attrs.bgColor == .indexed(UInt8(i - 100 + 8)))
        }
    }

    @Test func defaultFgReset() {
        let attrs = parseSGR([31, 39])
        #expect(attrs.fgColor == .default)
    }

    @Test func defaultBgReset() {
        let attrs = parseSGR([42, 49])
        #expect(attrs.bgColor == .default)
    }

    // MARK: - 256-Color

    @Test func fg256Color() {
        // 38;5;196 = bright red
        let attrs = parseSGR([38, 5, 196])
        #expect(attrs.fgColor == .indexed(196))
    }

    @Test func bg256Color() {
        // 48;5;22 = dark green
        let attrs = parseSGR([48, 5, 22])
        #expect(attrs.bgColor == .indexed(22))
    }

    // MARK: - TrueColor

    @Test func fgTrueColor() {
        // 38;2;255;128;0
        let attrs = parseSGR([38, 2, 255, 128, 0])
        #expect(attrs.fgColor == .rgb(255, 128, 0))
    }

    @Test func bgTrueColor() {
        // 48;2;10;20;30
        let attrs = parseSGR([48, 2, 10, 20, 30])
        #expect(attrs.bgColor == .rgb(10, 20, 30))
    }

    // MARK: - Multiple Attributes

    @Test func multipleSGRInOneSequence() {
        // 1;31;42 = bold + red fg + green bg
        let attrs = parseSGR([1, 31, 42])
        #expect(attrs.flags.contains(.bold))
        #expect(attrs.fgColor == .indexed(1))  // red
        #expect(attrs.bgColor == .indexed(2))  // green
    }

    @Test func trueColorFollowedByStyle() {
        // 38;2;100;200;50;1 = truecolor fg + bold
        let attrs = parseSGR([38, 2, 100, 200, 50, 1])
        #expect(attrs.fgColor == .rgb(100, 200, 50))
        #expect(attrs.flags.contains(.bold))
    }

    // MARK: - Colon-separated

    @Test func colon256Color() {
        // 38:5:196 (colon separated)
        let attrs = parseSGR([38, 5, 196], colons: [0, 1])
        #expect(attrs.fgColor == .indexed(196))
    }

    @Test func colonTrueColor() {
        // 38:2:255:128:0 (colon separated)
        let attrs = parseSGR([38, 2, 255, 128, 0], colons: [0, 1, 2, 3])
        #expect(attrs.fgColor == .rgb(255, 128, 0))
    }
}
