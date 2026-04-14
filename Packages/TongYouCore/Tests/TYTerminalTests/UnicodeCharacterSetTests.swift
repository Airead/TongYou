import Testing
import TYTerminal

struct UnicodeCharacterSetTests {

    @Test func symbolCharacters() {
        let symbols: [Unicode.Scalar] = [
            "←", "→", "↑", "↓",    // Arrows
            "✓", "✗", "➜",          // Dingbats
            "😀", "😎",              // Emoticons
            "☀", "★", "☂",           // Miscellaneous Symbols
            "①", "②", "③",           // Enclosed Alphanumerics
            "🄰", "🄱",               // Enclosed Alphanumeric Supplement
            "🚀", "🎉",              // Miscellaneous Symbols and Pictographs
            "🚗", "🚕",              // Transport and Map Symbols
            "\u{E0B0}",              // Powerline (PUA)
        ]

        for scalar in symbols {
            #expect(scalar.isSymbol, "U+\(String(scalar.value, radix: 16, uppercase: true)) should be a symbol")
        }
    }

    @Test func nonSymbolCharacters() {
        let nonSymbols: [Unicode.Scalar] = [
            "A", "a", "1", "!",
            "あ", "中", "한",
        ]

        for scalar in nonSymbols {
            #expect(!scalar.isSymbol, "U+\(String(scalar.value, radix: 16, uppercase: true)) should not be a symbol")
        }
    }

    @Test func graphicsElements() {
        let graphics: [Unicode.Scalar] = [
            "┌", "─", "│", "┐",     // Box Drawing
            "█", "▓", "░",            // Block Elements
            "\u{E0B0}", "\u{E0B1}",  // Powerline
        ]

        for scalar in graphics {
            #expect(scalar.isGraphicsElement, "U+\(String(scalar.value, radix: 16, uppercase: true)) should be a graphics element")
        }
    }

    @Test func boxDrawingCharacters() {
        #expect("─".unicodeScalars.first!.isBoxDrawing)
        #expect("│".unicodeScalars.first!.isBoxDrawing)
        #expect("┌".unicodeScalars.first!.isBoxDrawing)
        #expect("┘".unicodeScalars.first!.isBoxDrawing)
        #expect(!"A".unicodeScalars.first!.isBoxDrawing)
    }

    @Test func blockElementCharacters() {
        #expect("█".unicodeScalars.first!.isBlockElement)
        #expect("▓".unicodeScalars.first!.isBlockElement)
        #expect("░".unicodeScalars.first!.isBlockElement)
        #expect(!"A".unicodeScalars.first!.isBlockElement)
    }

    @Test func powerlineCharacters() {
        #expect("\u{E0B0}".unicodeScalars.first!.isPowerline)
        #expect("\u{E0B1}".unicodeScalars.first!.isPowerline)
        #expect("\u{E0B2}".unicodeScalars.first!.isPowerline)
        #expect("\u{E0D7}".unicodeScalars.first!.isPowerline)
        #expect(!"A".unicodeScalars.first!.isPowerline)
        #expect(!"\u{E0D8}".unicodeScalars.first!.isPowerline)
    }

    @Test func legacyComputingCharacters() {
        #expect("\u{1FB00}".unicodeScalars.first!.isLegacyComputing)
        #expect("\u{1FBFF}".unicodeScalars.first!.isLegacyComputing)
        #expect(!"A".unicodeScalars.first!.isLegacyComputing)
    }

    @Test func emojiPresentation() {
        // Characters with default emoji presentation
        #expect("😀".unicodeScalars.first!.isEmojiPresentation)
        #expect("🚀".unicodeScalars.first!.isEmojiPresentation)
        #expect("🎉".unicodeScalars.first!.isEmojiPresentation)

        // Characters without default emoji presentation
        #expect(!"A".unicodeScalars.first!.isEmojiPresentation)
        #expect(!"1".unicodeScalars.first!.isEmojiPresentation)
        #expect(!"➜".unicodeScalars.first!.isEmojiPresentation)
        #expect(!"✓".unicodeScalars.first!.isEmojiPresentation)
    }
}
