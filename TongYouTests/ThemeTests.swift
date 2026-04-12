import Testing
import TYTerminal
@testable import TongYou

@Suite("Theme")
struct ThemeTests {

    // MARK: - Built-in Theme Lookup

    @Test func lookupValidThemeName() {
        let theme = BuiltinTheme.named("iterm2-default")
        #expect(theme != nil)
        #expect(theme?.foreground == RGBColor(0xff, 0xff, 0xff))
        #expect(theme?.background == RGBColor(0x00, 0x00, 0x00))
    }

    @Test func lookupInvalidThemeNameReturnsNil() {
        #expect(BuiltinTheme.named("nonexistent") == nil)
    }

    @Test func allBuiltinThemesHave16PaletteEntries() {
        for builtin in BuiltinTheme.allCases {
            #expect(builtin.theme.palette.count == 16)
        }
    }

    @Test func allBuiltinThemesAreAccessible() {
        for builtin in BuiltinTheme.allCases {
            let theme = BuiltinTheme.named(builtin.rawValue)
            #expect(theme != nil, "Theme \(builtin.rawValue) should be accessible by name")
        }
    }

    // MARK: - Config Theme Application

    @Test func themeAppliesColorsToConfig() {
        let entries: [ConfigParser.Entry] = [
            ConfigParser.Entry(key: "theme", value: "iterm2-solarized-dark"),
        ]
        let config = Config.from(entries: entries)

        let theme = BuiltinTheme.named("iterm2-solarized-dark")!
        #expect(config.background == theme.background)
        #expect(config.foreground == theme.foreground)
        #expect(config.cursorColor == theme.cursorColor)
        #expect(config.cursorText == theme.cursorText)
        #expect(config.selectionBackground == theme.selectionBackground)
        #expect(config.selectionForeground == theme.selectionForeground)
    }

    @Test func themeAppliesPaletteToConfig() {
        let entries: [ConfigParser.Entry] = [
            ConfigParser.Entry(key: "theme", value: "iterm2-tango-dark"),
        ]
        let config = Config.from(entries: entries)

        let theme = BuiltinTheme.named("iterm2-tango-dark")!
        for i in 0..<16 {
            #expect(config.palette[i] == theme.palette[i],
                    "Palette entry \(i) should match theme")
        }
    }

    @Test func explicitColorsOverrideTheme() {
        let entries: [ConfigParser.Entry] = [
            ConfigParser.Entry(key: "theme", value: "iterm2-default"),
            ConfigParser.Entry(key: "background", value: "ff0000"),
            ConfigParser.Entry(key: "palette-0", value: "aabbcc"),
        ]
        let config = Config.from(entries: entries)

        // Explicit overrides take effect
        #expect(config.background == RGBColor(0xff, 0x00, 0x00))
        #expect(config.palette[0] == RGBColor(0xaa, 0xbb, 0xcc))

        // Theme still applies for non-overridden values
        let theme = BuiltinTheme.named("iterm2-default")!
        #expect(config.foreground == theme.foreground)
        #expect(config.palette[1] == theme.palette[1])
    }

    @Test func themeOrderIndependent() {
        // Theme declared after color — color should still override
        let entries: [ConfigParser.Entry] = [
            ConfigParser.Entry(key: "foreground", value: "123456"),
            ConfigParser.Entry(key: "theme", value: "iterm2-default"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.foreground == RGBColor(0x12, 0x34, 0x56))
    }

    @Test func invalidThemeNameIgnored() {
        let entries: [ConfigParser.Entry] = [
            ConfigParser.Entry(key: "theme", value: "nonexistent"),
        ]
        let config = Config.from(entries: entries)
        // Falls back to defaults
        #expect(config.background == Config.default.background)
        #expect(config.foreground == Config.default.foreground)
    }

    // MARK: - Cursor/Selection Color Config Parsing

    @Test func cursorAndSelectionColorsParsed() {
        let entries: [ConfigParser.Entry] = [
            ConfigParser.Entry(key: "cursor-color", value: "aabbcc"),
            ConfigParser.Entry(key: "cursor-text", value: "112233"),
            ConfigParser.Entry(key: "selection-background", value: "445566"),
            ConfigParser.Entry(key: "selection-foreground", value: "778899"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.cursorColor == RGBColor(0xaa, 0xbb, 0xcc))
        #expect(config.cursorText == RGBColor(0x11, 0x22, 0x33))
        #expect(config.selectionBackground == RGBColor(0x44, 0x55, 0x66))
        #expect(config.selectionForeground == RGBColor(0x77, 0x88, 0x99))
    }

    @Test func cursorAndSelectionColorsDefaultToNil() {
        let config = Config.default
        #expect(config.cursorColor == nil)
        #expect(config.cursorText == nil)
        #expect(config.selectionBackground == nil)
        #expect(config.selectionForeground == nil)
    }

    @Test func emptyValueResetsCursorColor() {
        let entries: [ConfigParser.Entry] = [
            ConfigParser.Entry(key: "cursor-color", value: "aabbcc"),
            ConfigParser.Entry(key: "cursor-color", value: ""),
        ]
        let config = Config.from(entries: entries)
        #expect(config.cursorColor == nil)
    }

    @Test func hexPrefixAccepted() {
        let entries: [ConfigParser.Entry] = [
            ConfigParser.Entry(key: "cursor-color", value: "#aabbcc"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.cursorColor == RGBColor(0xaa, 0xbb, 0xcc))
    }

    // MARK: - ColorPalette Integration

    @Test func colorPaletteUsesConfiguredCursorColors() {
        let palette = ColorPalette(
            cursorColor: SIMD4<UInt8>(0xaa, 0xbb, 0xcc, 255),
            cursorText: SIMD4<UInt8>(0x11, 0x22, 0x33, 255)
        )
        #expect(palette.cursorColor == SIMD4<UInt8>(0xaa, 0xbb, 0xcc, 255))
        #expect(palette.cursorText == SIMD4<UInt8>(0x11, 0x22, 0x33, 255))
    }

    @Test func colorPaletteUsesConfiguredSelectionColors() {
        let palette = ColorPalette(
            selectionBg: SIMD4<UInt8>(0x44, 0x55, 0x66, 255),
            selectionFg: SIMD4<UInt8>(0x77, 0x88, 0x99, 255)
        )
        #expect(palette.selectionBg == SIMD4<UInt8>(0x44, 0x55, 0x66, 255))
        #expect(palette.selectionFg == SIMD4<UInt8>(0x77, 0x88, 0x99, 255))
    }

    @Test func colorPaletteDefaultsToNilForOptionalColors() {
        let palette = ColorPalette()
        #expect(palette.cursorColor == nil)
        #expect(palette.cursorText == nil)
        #expect(palette.selectionBg == nil)
        #expect(palette.selectionFg == nil)
    }
}
