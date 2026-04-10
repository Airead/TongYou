/// Terminal display width for Unicode scalars.
///
/// Based on Unicode 16.0 East Asian Width property:
/// - W (Wide) and F (Fullwidth) → 2 cells
/// - Everything else → 1 cell
///
/// Zero-width characters (combining marks, etc.) are NOT handled here;
/// they are treated as width 1 for now. A future update can add ZWJ / combining support.
extension Unicode.Scalar {

    /// The number of terminal cells this character occupies (1 or 2).
    var terminalWidth: UInt8 {
        let v = self.value
        // Fast path: ASCII and Latin-1 Supplement are always narrow
        if v < 0x1100 { return 1 }
        return Self.isWide(v) ? 2 : 1
    }

    /// Check whether a code point is Wide (W) or Fullwidth (F) per UAX #11.
    ///
    /// Ranges derived from Unicode 16.0 EastAsianWidth.txt.
    /// Only W and F categories are included; Ambiguous (A) is treated as narrow.
    /// Ranges ordered by frequency: CJK Unified Ideographs first (covers ~99% of Chinese text),
    /// then Kana, Hangul, and less common blocks last.
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

        // SMP blocks (v > 0xFFFF) — less common, check last
        guard v > 0xFFFF else { return false }

        // Common wide emoji ranges
        if v >= 0x1F300 && v <= 0x1F64F { return true }
        if v >= 0x1F680 && v <= 0x1F6FF { return true }
        if v >= 0x1F900 && v <= 0x1F9FF { return true }
        if v >= 0x1FA00 && v <= 0x1FA6F { return true }
        if v >= 0x1FA70 && v <= 0x1FAFF { return true }
        if v >= 0x1F200 && v <= 0x1F2FF { return true }
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
