import Foundation
import TYTerminal

func check(_ name: String, _ screen: Screen) {
    let region = screen.consumeDirtyRegion()
    let rowsStr = region.dirtyRows.count <= 10 ? "\(region.dirtyRows)" : "count:\(region.dirtyRows.count)"
    print("\(name): full=\(region.fullRebuild) rows=\(rowsStr)")
}

func writeString(_ screen: Screen, _ text: String) {
    for scalar in text.unicodeScalars { screen.write(scalar) }
}

print("Test 1: Basic writing")
let screen = Screen(columns: 80, rows: 24)
_ = screen.consumeDirtyRegion() // consume initial full dirty
writeString(screen, "a")
check("write 'a'", screen)

writeString(screen, "bc")
check("write 'bc' same line", screen)

print("\nTest 2: Cursor movement")
screen.setCursorPos(row: 5, col: 0)
_ = screen.consumeDirtyRegion() // consume move dirty
writeString(screen, "x")
check("write at row 5", screen)

screen.setCursorPos(row: 3, col: 0)
_ = screen.consumeDirtyRegion()
writeString(screen, "y")
check("write at row 3", screen)

print("\nTest 3: Discontiguous lines")
screen.setCursorPos(row: 10, col: 0)
writeString(screen, "A")
screen.setCursorPos(row: 12, col: 0)
writeString(screen, "B")
screen.setCursorPos(row: 8, col: 0)
writeString(screen, "C")
check("discontiguous 8,10,12", screen)

print("\nTest 4: CursorUp dirty")
screen.setCursorPos(row: 5, col: 10)
_ = screen.consumeDirtyRegion()
screen.cursorUp(2)
check("cursorUp(2) from row 5", screen)

print("\nTest 5: lineFeed at bottom (scroll)")
screen.setCursorPos(row: 23, col: 0)
_ = screen.consumeDirtyRegion()
screen.lineFeed()
check("lineFeed at bottom", screen)

print("\nTest 6: scrollUp")
screen.scrollUp(count: 1)
check("scrollUp(1)", screen)

print("\nTest 7: scrollDown")
screen.scrollDown(count: 1)
check("scrollDown(1)", screen)

print("\nTest 8: eraseDisplay below")
screen.setCursorPos(row: 5, col: 10)
_ = screen.consumeDirtyRegion()
screen.eraseDisplay(mode: 0)
check("eraseDisplay below", screen)

print("\nTest 9: eraseDisplay above")
screen.setCursorPos(row: 5, col: 10)
_ = screen.consumeDirtyRegion()
screen.eraseDisplay(mode: 1)
check("eraseDisplay above", screen)

print("\nTest 10: eraseDisplay all")
screen.eraseDisplay(mode: 2)
check("eraseDisplay all", screen)

print("\nTest 11: eraseLine")
screen.setCursorPos(row: 5, col: 0)
_ = screen.consumeDirtyRegion()
screen.eraseLine(mode: 2)
check("eraseLine", screen)

print("\nTest 12: insertCharacters")
screen.setCursorPos(row: 3, col: 5)
_ = screen.consumeDirtyRegion()
screen.insertCharacters(count: 2)
check("insertCharacters(2)", screen)

print("\nTest 13: deleteCharacters")
screen.deleteCharacters(count: 3)
check("deleteCharacters(3)", screen)

print("\nTest 14: insertLines")
screen.insertLines(count: 1)
check("insertLines(1)", screen)

print("\nTest 15: deleteLines")
screen.deleteLines(count: 1)
check("deleteLines(1)", screen)

print("\nTest 16: clear")
screen.clear()
check("clear()", screen)

print("\nTest 17: fullReset")
_ = screen.consumeDirtyRegion()
screen.fullReset()
check("fullReset()", screen)

print("\nTest 18: resize")
_ = screen.consumeDirtyRegion()
screen.resize(columns: 100, rows: 30)
check("resize(100x30)", screen)

print("\nTest 19: viewport scroll with scrollback")
let screen2 = Screen(columns: 80, rows: 24)
for _ in 0..<30 { screen2.newline() }
_ = screen2.consumeDirtyRegion()
screen2.scrollViewportUp(lines: 3)
check("scrollViewportUp(3)", screen2)

print("\nTest 20: batch write")
let screen3 = Screen(columns: 80, rows: 24)
_ = screen3.consumeDirtyRegion()
for scalar in "hello world".unicodeScalars { screen3.write(scalar) }
check("batch 'hello world'", screen3)

print("\nTest 21: lineFeed non-scroll")
let screen4 = Screen(columns: 80, rows: 24)
_ = screen4.consumeDirtyRegion()
screen4.setCursorPos(row: 5, col: 0)
_ = screen4.consumeDirtyRegion()
screen4.lineFeed()
check("lineFeed non-scroll", screen4)

print("\n========================================")
print("VALIDATION COMPLETE")
print("========================================")
print("Key expectations:")
print("- Basic writes: specific row index (e.g., [0])")
print("- Discontiguous: MUST be [8, 10, 12] (not 8..<13)")
print("- Scroll/clear/reset/resize: full=true")
print("- eraseDisplay all: full=true")
print("- eraseDisplay below/above: contiguous ranges")
