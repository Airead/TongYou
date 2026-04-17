import Testing
@testable import TongYou

@Suite("BoxDrawingTable")
struct BoxDrawingTableTests {

    // MARK: - Range and fallback

    @Test func outOfRangeReturnsNil() {
        #expect(boxDrawingSegments(codepoint: 0x2499, cellWidth: 16, cellHeight: 32) == nil)
        #expect(boxDrawingSegments(codepoint: 0x2580, cellWidth: 16, cellHeight: 32) == nil)
    }

    @Test func arcCornersReturnNil() {
        // Arc corners are rendered via SDF shader, not rectangular segments
        for cp: UInt32 in 0x256D...0x2570 {
            #expect(boxDrawingSegments(codepoint: cp, cellWidth: 16, cellHeight: 32) == nil)
        }
    }

    @Test func diagonalsReturnNil() {
        for cp: UInt32 in 0x2571...0x2573 {
            #expect(boxDrawingSegments(codepoint: cp, cellWidth: 16, cellHeight: 32) == nil)
        }
    }

    // MARK: - Basic lines

    @Test func lightHorizontalLine() {
        // U+2500 ─
        let segs = boxDrawingSegments(codepoint: 0x2500, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 1)
        let s = segs[0]
        // Full width
        #expect(s.x == 0)
        #expect(s.width == 16)
        // Centered vertically
        #expect(s.y > 0)
        #expect(s.y + s.height <= 32)
    }

    @Test func lightVerticalLine() {
        // U+2502 │
        let segs = boxDrawingSegments(codepoint: 0x2502, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 1)
        let s = segs[0]
        // Full height
        #expect(s.y == 0)
        #expect(s.height == 32)
        // Centered horizontally
        #expect(s.x > 0)
        #expect(s.x + s.width <= 16)
    }

    @Test func heavyHorizontalLine() {
        // U+2501 ━
        let segs = boxDrawingSegments(codepoint: 0x2501, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 1)
        let lightSegs = boxDrawingSegments(codepoint: 0x2500, cellWidth: 16, cellHeight: 32)!
        // Heavy should be thicker than light
        #expect(segs[0].height >= lightSegs[0].height)
    }

    // MARK: - Corners

    @Test func lightTopLeftCorner() {
        // U+250C ┌ — right and down segments
        let segs = boxDrawingSegments(codepoint: 0x250C, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 2)
        // One segment should extend to right edge, one to bottom edge
        let extendsRight = segs.contains { $0.x + $0.width == 16 }
        let extendsDown = segs.contains { $0.y + $0.height == 32 }
        #expect(extendsRight)
        #expect(extendsDown)
    }

    @Test func lightBottomRightCorner() {
        // U+2518 ┘ — left and up segments
        let segs = boxDrawingSegments(codepoint: 0x2518, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 2)
        let extendsLeft = segs.contains { $0.x == 0 }
        let extendsUp = segs.contains { $0.y == 0 }
        #expect(extendsLeft)
        #expect(extendsUp)
    }

    // MARK: - Crossings

    @Test func lightCross() {
        // U+253C ┼ — full horizontal + full vertical
        let segs = boxDrawingSegments(codepoint: 0x253C, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 2)
        let hasFullH = segs.contains { $0.x == 0 && $0.width == 16 }
        let hasFullV = segs.contains { $0.y == 0 && $0.height == 32 }
        #expect(hasFullH)
        #expect(hasFullV)
    }

    // MARK: - T-junctions

    @Test func lightVerticalAndRight() {
        // U+251C ├ — full vertical + right half horizontal
        let segs = boxDrawingSegments(codepoint: 0x251C, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 2)
        let hasFullV = segs.contains { $0.y == 0 && $0.height == 32 }
        let hasRightH = segs.contains { $0.x + $0.width == 16 && $0.x > 0 }
        #expect(hasFullV)
        #expect(hasRightH)
    }

    // MARK: - Dashed lines

    @Test func tripleDashHorizontal() {
        // U+2504 ┄ — 3 dashes
        let segs = boxDrawingSegments(codepoint: 0x2504, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 3)
        // All dashes should be at similar Y (centered)
        let ys = Set(segs.map { $0.y })
        #expect(ys.count == 1)
    }

    @Test func quadrupleDashVertical() {
        // U+250A ┊ — 4 dashes
        let segs = boxDrawingSegments(codepoint: 0x250A, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 4)
        // All dashes should be at similar X (centered)
        let xs = Set(segs.map { $0.x })
        #expect(xs.count == 1)
    }

    // MARK: - Double lines

    @Test func doubleHorizontal() {
        // U+2550 ═ — 2 parallel horizontal segments
        let segs = boxDrawingSegments(codepoint: 0x2550, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 2)
        // Both full width
        for s in segs {
            #expect(s.x == 0)
            #expect(s.width == 16)
        }
        // Different Y positions
        #expect(segs[0].y != segs[1].y)
    }

    @Test func doubleVertical() {
        // U+2551 ║ — 2 parallel vertical segments
        let segs = boxDrawingSegments(codepoint: 0x2551, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 2)
        // Both full height
        for s in segs {
            #expect(s.y == 0)
            #expect(s.height == 32)
        }
        // Different X positions
        #expect(segs[0].x != segs[1].x)
    }

    @Test func doubleCross() {
        // U+256C ╬ — double horizontal + double vertical = 4 segments
        let segs = boxDrawingSegments(codepoint: 0x256C, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 4)
    }

    // MARK: - Half lines

    @Test func lightLeft() {
        // U+2574 ╴ — left half only
        let segs = boxDrawingSegments(codepoint: 0x2574, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 1)
        #expect(segs[0].x == 0)
        #expect(segs[0].width < 16) // doesn't extend full width
    }

    @Test func lightRight() {
        // U+2576 ╶ — right half only
        let segs = boxDrawingSegments(codepoint: 0x2576, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 1)
        #expect(segs[0].x > 0) // starts from center
        #expect(segs[0].x + segs[0].width == 16) // extends to right edge
    }

    // MARK: - Mixed heavy/light

    @Test func lightLeftHeavyRight() {
        // U+257C ╼ — light left + heavy right
        let segs = boxDrawingSegments(codepoint: 0x257C, cellWidth: 16, cellHeight: 32)!
        #expect(segs.count == 2)
        // The two segments should have different thicknesses
        #expect(segs[0].height != segs[1].height)
    }

    // MARK: - Segment validity

    @Test func allSupportedCodepointsProduceValidSegments() {
        let cellW: UInt32 = 16
        let cellH: UInt32 = 32
        for cp: UInt32 in 0x2500...0x257F {
            guard let segs = boxDrawingSegments(codepoint: cp, cellWidth: cellW, cellHeight: cellH) else {
                continue // nil = fallback to font, which is fine
            }
            #expect(!segs.isEmpty, "Codepoint U+\(String(cp, radix: 16)) returned empty segments")
            for s in segs {
                #expect(s.width > 0, "Zero-width segment for U+\(String(cp, radix: 16))")
                #expect(s.height > 0, "Zero-height segment for U+\(String(cp, radix: 16))")
                #expect(s.x + s.width <= UInt16(cellW),
                        "Segment overflows cell width for U+\(String(cp, radix: 16)): x=\(s.x) w=\(s.width)")
                #expect(s.y + s.height <= UInt16(cellH),
                        "Segment overflows cell height for U+\(String(cp, radix: 16)): y=\(s.y) h=\(s.height)")
            }
        }
    }

    @Test func segmentsScaleWithCellSize() {
        // Verify that segments scale proportionally with cell size
        let small = boxDrawingSegments(codepoint: 0x2500, cellWidth: 8, cellHeight: 16)!
        let large = boxDrawingSegments(codepoint: 0x2500, cellWidth: 32, cellHeight: 64)!
        #expect(large[0].width > small[0].width)
        #expect(large[0].height >= small[0].height)
    }
}
