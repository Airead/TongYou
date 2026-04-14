/// Unicode character set classification for terminal rendering.
///
/// Based on Ghostty's approach to categorizing characters for proper rendering.
/// This helps determine how characters should be displayed and what constraints
/// should be applied to their glyphs.
extension Unicode.Scalar {

    /// Returns true if the codepoint is a "symbol-like" character.
    ///
    /// This includes:
    /// - Private Use Area (PUA) characters
    /// - Arrows
    /// - Dingbats
    /// - Emoticons
    /// - Miscellaneous Symbols
    /// - Enclosed Alphanumerics
    /// - Enclosed Alphanumeric Supplement
    /// - Miscellaneous Symbols and Pictographs
    /// - Transport and Map Symbols
    public var isSymbol: Bool {
        let v = self.value

        // Private Use Area (PUA)
        if v >= 0xE000 && v <= 0xF8FF { return true }
        if v >= 0xF0000 && v <= 0xFFFFD { return true }
        if v >= 0x100000 && v <= 0x10FFFD { return true }

        // Arrows block
        if v >= 0x2190 && v <= 0x21FF { return true }

        // Dingbats
        if v >= 0x2700 && v <= 0x27BF { return true }

        // Emoticons
        if v >= 0x1F600 && v <= 0x1F64F { return true }

        // Miscellaneous Symbols
        if v >= 0x2600 && v <= 0x26FF { return true }

        // Enclosed Alphanumerics
        if v >= 0x2460 && v <= 0x24FF { return true }

        // Enclosed Alphanumeric Supplement
        if v >= 0x1F100 && v <= 0x1F1FF { return true }

        // Miscellaneous Symbols and Pictographs
        if v >= 0x1F300 && v <= 0x1F5FF { return true }

        // Transport and Map Symbols
        if v >= 0x1F680 && v <= 0x1F6FF { return true }

        return false
    }

    /// Returns true if the codepoint is used for terminal graphics.
    ///
    /// This includes:
    /// - Box drawing characters
    /// - Block elements
    /// - Legacy computing symbols
    /// - Powerline glyphs
    public var isGraphicsElement: Bool {
        isBoxDrawing || isBlockElement || isLegacyComputing || isPowerline
    }

    /// Returns true if the codepoint is a box drawing character.
    ///
    /// Range: U+2500 to U+257F
    public var isBoxDrawing: Bool {
        let v = self.value
        return v >= 0x2500 && v <= 0x257F
    }

    /// Returns true if the codepoint is a block element.
    ///
    /// Range: U+2580 to U+259F
    public var isBlockElement: Bool {
        let v = self.value
        return v >= 0x2580 && v <= 0x259F
    }

    /// Returns true if the codepoint is in the Symbols for Legacy Computing block.
    ///
    /// Ranges:
    /// - U+1FB00 to U+1FBFF (Legacy Computing)
    /// - U+1CC00 to U+1CEBF (Legacy Computing Supplement, Unicode 16.0)
    public var isLegacyComputing: Bool {
        let v = self.value
        return (v >= 0x1FB00 && v <= 0x1FBFF) ||
               (v >= 0x1CC00 && v <= 0x1CEBF)
    }

    /// Returns true if the codepoint is a Powerline glyph.
    ///
    /// Range: U+E0B0 to U+E0D7
    public var isPowerline: Bool {
        let v = self.value
        return v >= 0xE0B0 && v <= 0xE0D7
    }

    /// Returns true if the codepoint should use emoji presentation by default.
    ///
    /// This uses the Unicode Emoji_Presentation property for accurate detection.
    public var isEmojiPresentation: Bool {
        self.properties.isEmojiPresentation
    }

    /// Returns true if the codepoint is an emoji base character.
    ///
    /// These characters can be rendered as color emoji with U+FE0F (VS16).
    /// This uses the Unicode Emoji property for accurate detection.
    public var isEmoji: Bool {
        self.properties.isEmoji
    }

    /// Returns true if this scalar should be treated as a standalone emoji glyph.
    ///
    /// This is used by the renderer to decide whether a scalar (outside of a
    /// known emoji sequence) should be routed to the color emoji atlas.
    public var isEmojiScalar: Bool {
        let v = self.value

        if self.isEmojiPresentation {
            return true
        }

        // ASCII digits 0-9 and #/* can be emoji with variation selector (U+FE0F),
        // but without VS16 they should be treated as text.
        if v == 0x0023 || v == 0x002A || (v >= 0x0030 && v <= 0x0039) {
            return false
        }

        // Regional indicators (flags) are handled via emoji sequences when paired.
        if v >= 0x1F1E6 && v <= 0x1F1FF {
            return false
        }

        if self.isEmoji {
            return true
        }

        return false
    }
}
