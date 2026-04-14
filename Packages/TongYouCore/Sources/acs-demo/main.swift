import Foundation
import TYTerminal

func process(_ input: String, columns: Int, rows: Int) -> Screen {
    let screen = Screen(columns: columns, rows: rows)
    var handler = StreamHandler(screen: screen)
    var parser = VTParser()
    let bytes = Array(input.utf8)
    bytes.withUnsafeBufferPointer { ptr in
        parser.feed(ptr) { action in
            handler.handle(action)
        }
    }
    handler.flush()
    return screen
}

let acs = "\u{1B}(0"  // Enter DEC Special Graphics (ACS)
let ascii = "\u{1B}(B" // Return to ASCII

// Draw a simple box similar to what tig/ncurses would emit:
// ┌────────┐
// │  tig   │
// └────────┘
let border = """
\(acs)lqqqqqqqqk\(ascii)\r
\(acs)x\(ascii)  tig   \(acs)x\(ascii)\r
\(acs)mqqqqqqqqj\(ascii)\r
"""

let screen = process(border, columns: 12, rows: 5)

print("=== ACS Demo Output ===")
for row in 0..<screen.rows {
    var line = ""
    for col in 0..<screen.columns {
        let cell = screen.cell(at: col, row: row)
        if cell.width == .continuation || cell.width == .spacer {
            continue
        }
        if let scalar = cell.content.firstScalar {
            line.append(String(scalar))
        } else if cell.content.scalarCount > 1 {
            line.append(cell.content.string)
        } else {
            line.append(" ")
        }
    }
    print(line.trimmingCharacters(in: .whitespaces))
}
print("=== End ===")

// Quick assertion for CI-like usage
let topLeft = screen.cell(at: 0, row: 0).content.firstScalar
let expectedTopLeft = Unicode.Scalar(0x250C) // ┌
if topLeft != expectedTopLeft {
    print("FAILED: expected top-left corner to be ┌, got \(topLeft.map(String.init) ?? "nil")")
    exit(1)
}

let horizontal = screen.cell(at: 1, row: 0).content.firstScalar
let expectedHorizontal = Unicode.Scalar(0x2500) // ─
if horizontal != expectedHorizontal {
    print("FAILED: expected horizontal line to be ─, got \(horizontal.map(String.init) ?? "nil")")
    exit(1)
}

let vertical = screen.cell(at: 0, row: 1).content.firstScalar
let expectedVertical = Unicode.Scalar(0x2502) // │
if vertical != expectedVertical {
    print("FAILED: expected vertical line to be │, got \(vertical.map(String.init) ?? "nil")")
    exit(1)
}

print("All assertions passed.")
