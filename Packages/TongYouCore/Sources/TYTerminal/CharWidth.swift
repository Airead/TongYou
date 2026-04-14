/// Terminal display width for Unicode scalars.
///
/// Based on Unicode 16.0 East Asian Width property:
/// - W (Wide) and F (Fullwidth) → 2 cells
/// - A (Ambiguous), symbols, and emoji → 2 cells for emoji compatibility
/// - Everything else → 1 cell
///
/// Zero-width characters (combining marks, etc.) are NOT handled here;
/// they are treated as width 1 for now. A future update can add ZWJ / combining support.
extension Unicode.Scalar {

    /// The number of terminal cells this character occupies (1 or 2).
    public var terminalWidth: UInt8 {
        let v = self.value
        // Fast path: ASCII and Latin-1 Supplement are always narrow
        if v < 0x1100 { return 1 }
        return Self.isWide(v) ? 2 : 1
    }

    /// Check whether a code point is Wide (W), Fullwidth (F), or should be treated as wide.
    ///
    /// Includes:
    /// - W (Wide) and F (Fullwidth) per UAX #11
    /// - A (Ambiguous) - treated as wide for better emoji compatibility
    /// - Miscellaneous Symbols and Dingbats - commonly rendered as color emoji
    /// - Emoji with default emoji presentation
    ///
    /// Ranges derived from Unicode 16.0 EastAsianWidth.txt.
    private static func isWide(_ v: UInt32) -> Bool {
        // CJK Unified Ideographs — by far the most common wide block
        if v >= 0x4E00 && v <= 0x9FFF { return true }
        // Hiragana, Katakana, Bopomofo, Hangul Compat Jamo, Kanbun, etc.
        if v >= 0x3040 && v <= 0x33FF { return true }
        // Hangul Syllables
        if v >= 0xAC00 && v <= 0xD7A3 { return true }
        // CJK Unified Ideographs Extension A
        if v >= 0x3400 && v <= 0x4DBF { return true }
        // CJK Radicals, Kangxi, Ideographic Description, CJK Symbols
        if v >= 0x2E80 && v <= 0x303E { return true }
        // Hangul Jamo
        if v >= 0x1100 && v <= 0x115F { return true }
        // Yi Syllables, Yi Radicals
        if v >= 0xA000 && v <= 0xA4CF { return true }
        // Hangul Jamo Extended-A
        if v >= 0xA960 && v <= 0xA97C { return true }
        // CJK Compatibility Ideographs
        if v >= 0xF900 && v <= 0xFAFF { return true }
        // Vertical Forms
        if v >= 0xFE10 && v <= 0xFE19 { return true }
        // CJK Compatibility Forms, Small Form Variants
        if v >= 0xFE30 && v <= 0xFE6F { return true }
        // Fullwidth Forms (excluding halfwidth block)
        if v >= 0xFF01 && v <= 0xFF60 { return true }
        if v >= 0xFFE0 && v <= 0xFFE6 { return true }

        // Fast path: most common BMP scripts are narrow.
        // Only symbol/emoji blocks below need further checks.
        if v < 0x2100 { return false }

        guard let scalar = Unicode.Scalar(v) else { return false }

        // Emoji with default emoji presentation are wide
        if scalar.isEmojiPresentation {
            return true
        }

        // Miscellaneous Symbols and Dingbats blocks are commonly rendered as color emoji.
        // Treating them as wide prevents squashing when using emoji fonts.
        if v >= 0x2600 && v <= 0x26FF { return true }
        if v >= 0x2700 && v <= 0x27BF { return true }

        // Ambiguous width characters - treated as wide for emoji compatibility
        if scalar.isSymbol {
            return true
        }
        if scalar.isBoxDrawing || scalar.isBlockElement || scalar.isLegacyComputing || scalar.isPowerline {
            return true
        }

        // SMP blocks (v > 0xFFFF) — less common, check last
        guard v > 0xFFFF else { return false }

        // Regional Indicators for flag emoji (individual indicators are narrow,
        // but pairs should be wide - handled by grapheme cluster logic)
        if v >= 0x1F1E6 && v <= 0x1F1FF { return true }
        // CJK Unified Ideographs Extension B..I and Compatibility Supplement
        if v >= 0x20000 && v <= 0x2A6DF { return true }
        if v >= 0x2A700 && v <= 0x2B73F { return true }
        if v >= 0x2B740 && v <= 0x2B81F { return true }
        if v >= 0x2B820 && v <= 0x2CEAF { return true }
        if v >= 0x2CEB0 && v <= 0x2EBEF { return true }
        if v >= 0x2EBF0 && v <= 0x2F73F { return true }
        if v >= 0x2F800 && v <= 0x2FA1F { return true }
        if v >= 0x30000 && v <= 0x3134F { return true }
        if v >= 0x31350 && v <= 0x323AF { return true }

        return false
    }
}
