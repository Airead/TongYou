import Foundation

/// A rectangular segment within a cell, in physical pixels relative to cell origin.
struct BoxDrawSegmentRect {
    var x: UInt16
    var y: UInt16
    var width: UInt16
    var height: UInt16
}

/// Decompose a box-drawing codepoint (U+2500-U+257F) into rectangular segments.
///
/// Returns `nil` for arc corners (U+256D-U+2570) and out-of-range codepoints,
/// signaling fallback to the font rendering path.
func boxDrawingSegments(
    codepoint: UInt32,
    cellWidth: UInt32,
    cellHeight: UInt32
) -> [BoxDrawSegmentRect]? {
    guard codepoint >= 0x2500 && codepoint <= 0x257F else { return nil }

    let w = Float(cellWidth)
    let h = Float(cellHeight)

    // Line thicknesses — uniform for both directions, based on cell width
    // (cells are taller than wide, so width is the constraining dimension)
    let light = max(1, round(w / 8))
    let heavy = max(2, round(w / 4))

    // Center coordinates
    let cx = floor(w / 2)
    let cy = floor(h / 2)

    // Double-line offsets: two parallel thin lines separated by a gap
    let dblGap = light
    let dblOff = light + dblGap  // offset from center to each parallel line

    // Helper to create a rect from Float values
    func rect(_ x: Float, _ y: Float, _ rw: Float, _ rh: Float) -> BoxDrawSegmentRect {
        BoxDrawSegmentRect(
            x: UInt16(max(0, x)),
            y: UInt16(max(0, y)),
            width: UInt16(max(1, rw)),
            height: UInt16(max(1, rh))
        )
    }

    // Segment primitives — half-lines from center to each edge
    // Horizontal segments
    func hLeft(_ t: Float) -> BoxDrawSegmentRect {
        rect(0, cy - floor(t / 2), cx + ceil(t / 2), t)
    }
    func hRight(_ t: Float) -> BoxDrawSegmentRect {
        rect(cx - floor(t / 2), cy - floor(t / 2), w - cx + floor(t / 2), t)
    }
    func hFull(_ t: Float) -> BoxDrawSegmentRect {
        rect(0, cy - floor(t / 2), w, t)
    }

    // Vertical segments
    func vUp(_ t: Float) -> BoxDrawSegmentRect {
        rect(cx - floor(t / 2), 0, t, cy + ceil(t / 2))
    }
    func vDown(_ t: Float) -> BoxDrawSegmentRect {
        rect(cx - floor(t / 2), cy - floor(t / 2), t, h - cy + floor(t / 2))
    }
    func vFull(_ t: Float) -> BoxDrawSegmentRect {
        rect(cx - floor(t / 2), 0, t, h)
    }

    // Double-line horizontal segments (two parallel thin lines)
    func dblHLeft() -> [BoxDrawSegmentRect] {
        [rect(0, cy - dblOff - floor(light / 2), cx + ceil(light / 2), light),
         rect(0, cy + dblOff - floor(light / 2), cx + ceil(light / 2), light)]
    }
    func dblHRight() -> [BoxDrawSegmentRect] {
        [rect(cx - floor(light / 2), cy - dblOff - floor(light / 2), w - cx + floor(light / 2), light),
         rect(cx - floor(light / 2), cy + dblOff - floor(light / 2), w - cx + floor(light / 2), light)]
    }
    func dblHFull() -> [BoxDrawSegmentRect] {
        [rect(0, cy - dblOff - floor(light / 2), w, light),
         rect(0, cy + dblOff - floor(light / 2), w, light)]
    }

    // Double-line vertical segments
    func dblVUp() -> [BoxDrawSegmentRect] {
        [rect(cx - dblOff - floor(light / 2), 0, light, cy + ceil(light / 2)),
         rect(cx + dblOff - floor(light / 2), 0, light, cy + ceil(light / 2))]
    }
    func dblVDown() -> [BoxDrawSegmentRect] {
        [rect(cx - dblOff - floor(light / 2), cy - floor(light / 2), light, h - cy + floor(light / 2)),
         rect(cx + dblOff - floor(light / 2), cy - floor(light / 2), light, h - cy + floor(light / 2))]
    }
    func dblVFull() -> [BoxDrawSegmentRect] {
        [rect(cx - dblOff - floor(light / 2), 0, light, h),
         rect(cx + dblOff - floor(light / 2), 0, light, h)]
    }

    // Dashed horizontal: n equal-width dashes across full cell width
    func dashedH(_ n: Int, _ t: Float) -> [BoxDrawSegmentRect] {
        let totalGap = w / Float(2 * n)
        let dashW = (w - totalGap * Float(n - 1)) / Float(n)
        return (0..<n).map { i in
            let x0 = Float(i) * (dashW + totalGap)
            return rect(x0, cy - floor(t / 2), dashW, t)
        }
    }

    // Dashed vertical: n equal-height dashes across full cell height
    func dashedV(_ n: Int, _ t: Float) -> [BoxDrawSegmentRect] {
        let totalGap = h / Float(2 * n)
        let dashH = (h - totalGap * Float(n - 1)) / Float(n)
        return (0..<n).map { i in
            let y0 = Float(i) * (dashH + totalGap)
            return rect(cx - floor(t / 2), y0, t, dashH)
        }
    }

    let idx = codepoint - 0x2500

    switch idx {
    // ─ Light horizontal
    case 0x00: return [hFull(light)]
    // ━ Heavy horizontal
    case 0x01: return [hFull(heavy)]
    // │ Light vertical
    case 0x02: return [vFull(light)]
    // ┃ Heavy vertical
    case 0x03: return [vFull(heavy)]

    // ┄ Light triple dash horizontal
    case 0x04: return dashedH(3, light)
    // ┅ Heavy triple dash horizontal
    case 0x05: return dashedH(3, heavy)
    // ┆ Light triple dash vertical
    case 0x06: return dashedV(3, light)
    // ┇ Heavy triple dash vertical
    case 0x07: return dashedV(3, heavy)

    // ┈ Light quadruple dash horizontal
    case 0x08: return dashedH(4, light)
    // ┉ Heavy quadruple dash horizontal
    case 0x09: return dashedH(4, heavy)
    // ┊ Light quadruple dash vertical
    case 0x0A: return dashedV(4, light)
    // ┋ Heavy quadruple dash vertical
    case 0x0B: return dashedV(4, heavy)

    // ┌ Light down and right
    case 0x0C: return [hRight(light), vDown(light)]
    // ┍ Down light and right heavy
    case 0x0D: return [hRight(heavy), vDown(light)]
    // ┎ Down heavy and right light
    case 0x0E: return [hRight(light), vDown(heavy)]
    // ┏ Heavy down and right
    case 0x0F: return [hRight(heavy), vDown(heavy)]

    // ┐ Light down and left
    case 0x10: return [hLeft(light), vDown(light)]
    // ┑ Down light and left heavy
    case 0x11: return [hLeft(heavy), vDown(light)]
    // ┒ Down heavy and left light
    case 0x12: return [hLeft(light), vDown(heavy)]
    // ┓ Heavy down and left
    case 0x13: return [hLeft(heavy), vDown(heavy)]

    // └ Light up and right
    case 0x14: return [hRight(light), vUp(light)]
    // ┕ Up light and right heavy
    case 0x15: return [hRight(heavy), vUp(light)]
    // ┖ Up heavy and right light
    case 0x16: return [hRight(light), vUp(heavy)]
    // ┗ Heavy up and right
    case 0x17: return [hRight(heavy), vUp(heavy)]

    // ┘ Light up and left
    case 0x18: return [hLeft(light), vUp(light)]
    // ┙ Up light and left heavy
    case 0x19: return [hLeft(heavy), vUp(light)]
    // ┚ Up heavy and left light
    case 0x1A: return [hLeft(light), vUp(heavy)]
    // ┛ Heavy up and left
    case 0x1B: return [hLeft(heavy), vUp(heavy)]

    // ├ Light vertical and right
    case 0x1C: return [vFull(light), hRight(light)]
    // ┝ Vertical light and right heavy
    case 0x1D: return [vFull(light), hRight(heavy)]
    // ┞ Up heavy and right down light
    case 0x1E: return [vUp(heavy), vDown(light), hRight(light)]
    // ┟ Down heavy and right up light
    case 0x1F: return [vUp(light), vDown(heavy), hRight(light)]

    // ┠ Vertical heavy and right light
    case 0x20: return [vFull(heavy), hRight(light)]
    // ┡ Down light and right up heavy
    case 0x21: return [vUp(heavy), vDown(light), hRight(heavy)]
    // ┢ Up light and right down heavy
    case 0x22: return [vUp(light), vDown(heavy), hRight(heavy)]
    // ┣ Heavy vertical and right
    case 0x23: return [vFull(heavy), hRight(heavy)]

    // ┤ Light vertical and left
    case 0x24: return [vFull(light), hLeft(light)]
    // ┥ Vertical light and left heavy
    case 0x25: return [vFull(light), hLeft(heavy)]
    // ┦ Up heavy and left down light
    case 0x26: return [vUp(heavy), vDown(light), hLeft(light)]
    // ┧ Down heavy and left up light
    case 0x27: return [vUp(light), vDown(heavy), hLeft(light)]

    // ┨ Vertical heavy and left light
    case 0x28: return [vFull(heavy), hLeft(light)]
    // ┩ Down light and left up heavy
    case 0x29: return [vUp(heavy), vDown(light), hLeft(heavy)]
    // ┪ Up light and left down heavy
    case 0x2A: return [vUp(light), vDown(heavy), hLeft(heavy)]
    // ┫ Heavy vertical and left
    case 0x2B: return [vFull(heavy), hLeft(heavy)]

    // ┬ Light down and horizontal
    case 0x2C: return [hFull(light), vDown(light)]
    // ┭ Left heavy and right down light
    case 0x2D: return [hLeft(heavy), hRight(light), vDown(light)]
    // ┮ Right heavy and left down light
    case 0x2E: return [hLeft(light), hRight(heavy), vDown(light)]
    // ┯ Down light and horizontal heavy
    case 0x2F: return [hFull(heavy), vDown(light)]

    // ┰ Down heavy and horizontal light
    case 0x30: return [hFull(light), vDown(heavy)]
    // ┱ Right light and left down heavy
    case 0x31: return [hLeft(heavy), hRight(light), vDown(heavy)]
    // ┲ Left light and right down heavy
    case 0x32: return [hLeft(light), hRight(heavy), vDown(heavy)]
    // ┳ Heavy down and horizontal
    case 0x33: return [hFull(heavy), vDown(heavy)]

    // ┴ Light up and horizontal
    case 0x34: return [hFull(light), vUp(light)]
    // ┵ Left heavy and right up light
    case 0x35: return [hLeft(heavy), hRight(light), vUp(light)]
    // ┶ Right heavy and left up light
    case 0x36: return [hLeft(light), hRight(heavy), vUp(light)]
    // ┷ Up light and horizontal heavy
    case 0x37: return [hFull(heavy), vUp(light)]

    // ┸ Up heavy and horizontal light
    case 0x38: return [hFull(light), vUp(heavy)]
    // ┹ Right light and left up heavy
    case 0x39: return [hLeft(heavy), hRight(light), vUp(heavy)]
    // ┺ Left light and right up heavy
    case 0x3A: return [hLeft(light), hRight(heavy), vUp(heavy)]
    // ┻ Heavy up and horizontal
    case 0x3B: return [hFull(heavy), vUp(heavy)]

    // ┼ Light vertical and horizontal
    case 0x3C: return [hFull(light), vFull(light)]
    // ┽ Left heavy and right vertical light
    case 0x3D: return [hLeft(heavy), hRight(light), vFull(light)]
    // ┾ Right heavy and left vertical light
    case 0x3E: return [hLeft(light), hRight(heavy), vFull(light)]
    // ┿ Vertical light and horizontal heavy
    case 0x3F: return [hFull(heavy), vFull(light)]

    // ╀ Up heavy and down horizontal light
    case 0x40: return [hFull(light), vUp(heavy), vDown(light)]
    // ╁ Down heavy and up horizontal light
    case 0x41: return [hFull(light), vUp(light), vDown(heavy)]
    // ╂ Vertical heavy and horizontal light
    case 0x42: return [hFull(light), vFull(heavy)]
    // ╃ Left up heavy and right down light
    case 0x43: return [hLeft(heavy), hRight(light), vUp(heavy), vDown(light)]
    // ╄ Right up heavy and left down light
    case 0x44: return [hLeft(light), hRight(heavy), vUp(heavy), vDown(light)]
    // ╅ Left down heavy and right up light
    case 0x45: return [hLeft(heavy), hRight(light), vUp(light), vDown(heavy)]
    // ╆ Right down heavy and left up light
    case 0x46: return [hLeft(light), hRight(heavy), vUp(light), vDown(heavy)]
    // ╇ Down light and up horizontal heavy
    case 0x47: return [hFull(heavy), vUp(heavy), vDown(light)]
    // ╈ Up light and down horizontal heavy
    case 0x48: return [hFull(heavy), vUp(light), vDown(heavy)]
    // ╉ Right light and left vertical heavy
    case 0x49: return [hLeft(heavy), hRight(light), vFull(heavy)]
    // ╊ Left light and right vertical heavy
    case 0x4A: return [hLeft(light), hRight(heavy), vFull(heavy)]
    // ╋ Heavy vertical and horizontal
    case 0x4B: return [hFull(heavy), vFull(heavy)]

    // ╌ Light double dash horizontal
    case 0x4C: return dashedH(2, light)
    // ╍ Heavy double dash horizontal
    case 0x4D: return dashedH(2, heavy)
    // ╎ Light double dash vertical
    case 0x4E: return dashedV(2, light)
    // ╏ Heavy double dash vertical
    case 0x4F: return dashedV(2, heavy)

    // ═ Double horizontal
    case 0x50: return dblHFull()
    // ║ Double vertical
    case 0x51: return dblVFull()

    // ╒ Down single and right double
    case 0x52: return dblHRight() + [vDown(light)]
    // ╓ Down double and right single
    case 0x53: return [hRight(light)] + dblVDown()
    // ╔ Double down and right
    case 0x54: return dblHRight() + dblVDown()

    // ╕ Down single and left double
    case 0x55: return dblHLeft() + [vDown(light)]
    // ╖ Down double and left single
    case 0x56: return [hLeft(light)] + dblVDown()
    // ╗ Double down and left
    case 0x57: return dblHLeft() + dblVDown()

    // ╘ Up single and right double
    case 0x58: return dblHRight() + [vUp(light)]
    // ╙ Up double and right single
    case 0x59: return [hRight(light)] + dblVUp()
    // ╚ Double up and right
    case 0x5A: return dblHRight() + dblVUp()

    // ╛ Up single and left double
    case 0x5B: return dblHLeft() + [vUp(light)]
    // ╜ Up double and left single
    case 0x5C: return [hLeft(light)] + dblVUp()
    // ╝ Double up and left
    case 0x5D: return dblHLeft() + dblVUp()

    // ╞ Vertical single and right double
    case 0x5E: return [vFull(light)] + dblHRight()
    // ╟ Vertical double and right single
    case 0x5F: return dblVFull() + [hRight(light)]
    // ╠ Double vertical and right
    case 0x60: return dblVFull() + dblHRight()

    // ╡ Vertical single and left double
    case 0x61: return [vFull(light)] + dblHLeft()
    // ╢ Vertical double and left single
    case 0x62: return dblVFull() + [hLeft(light)]
    // ╣ Double vertical and left
    case 0x63: return dblVFull() + dblHLeft()

    // ╤ Down single and horizontal double
    case 0x64: return dblHFull() + [vDown(light)]
    // ╥ Down double and horizontal single
    case 0x65: return [hFull(light)] + dblVDown()
    // ╦ Double down and horizontal
    case 0x66: return dblHFull() + dblVDown()

    // ╧ Up single and horizontal double
    case 0x67: return dblHFull() + [vUp(light)]
    // ╨ Up double and horizontal single
    case 0x68: return [hFull(light)] + dblVUp()
    // ╩ Double up and horizontal
    case 0x69: return dblHFull() + dblVUp()

    // ╪ Vertical single and horizontal double
    case 0x6A: return dblHFull() + [vFull(light)]
    // ╫ Vertical double and horizontal single
    case 0x6B: return [hFull(light)] + dblVFull()
    // ╬ Double vertical and horizontal
    case 0x6C: return dblHFull() + dblVFull()

    // ╭╮╯╰ Arc corners — handled by SDF shader, not rectangular segments
    case 0x6D, 0x6E, 0x6F, 0x70: return nil

    // ╱ Light diagonal upper right to lower left
    // ╲ Light diagonal upper left to lower right
    // ╳ Light diagonal cross
    // Diagonals cannot be rendered as axis-aligned rectangles; fall back to font.
    case 0x71, 0x72, 0x73: return nil

    // ╴ Light left
    case 0x74: return [hLeft(light)]
    // ╵ Light up
    case 0x75: return [vUp(light)]
    // ╶ Light right
    case 0x76: return [hRight(light)]
    // ╷ Light down
    case 0x77: return [vDown(light)]

    // ╸ Heavy left
    case 0x78: return [hLeft(heavy)]
    // ╹ Heavy up
    case 0x79: return [vUp(heavy)]
    // ╺ Heavy right
    case 0x7A: return [hRight(heavy)]
    // ╻ Heavy down
    case 0x7B: return [vDown(heavy)]

    // ╼ Light left and heavy right
    case 0x7C: return [hLeft(light), hRight(heavy)]
    // ╽ Light up and heavy down
    case 0x7D: return [vUp(light), vDown(heavy)]
    // ╾ Heavy left and light right
    case 0x7E: return [hLeft(heavy), hRight(light)]
    // ╿ Heavy up and light down
    case 0x7F: return [vUp(heavy), vDown(light)]

    default: return nil
    }
}
