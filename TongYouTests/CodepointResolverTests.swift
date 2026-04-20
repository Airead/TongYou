import CoreText
import Testing
import TYTerminal
@testable import TongYou

struct CodepointResolverTests {

    private func makeResolver() -> (resolver: CodepointResolver, baseFont: CTFont) {
        let fontSystem = FontSystem(scaleFactor: 2.0)
        let baseFont = fontSystem.ctFont
        let emojiFont = CTFontCreateWithName("Apple Color Emoji" as CFString, 26.0, nil)
        var collection = FontCollection()
        collection.addFont(baseFont, style: .regular)
        let resolver = CodepointResolver(
            collection: collection,
            baseFont: baseFont,
            emojiFont: emojiFont,
            fontSystem: fontSystem
        )
        return (resolver, baseFont)
    }

    @Test func resolvesAsciiToBaseFont() {
        let (resolver, baseFont) = makeResolver()
        let font = resolver.resolveFont(for: GraphemeCluster("A"), style: .regular)
        let resolvedName = CTFontCopyPostScriptName(font) as String
        let baseName = CTFontCopyPostScriptName(baseFont) as String
        #expect(resolvedName == baseName)
    }

    @Test func resolvesEmojiToEmojiFont() {
        let (resolver, _) = makeResolver()
        let font = resolver.resolveFont(for: GraphemeCluster(Character("👍")), style: .regular)
        let resolvedName = CTFontCopyPostScriptName(font) as String
        #expect(resolvedName.contains("AppleColorEmoji"))
    }

    @Test func resolvesEmojiSequenceToEmojiFont() {
        let (resolver, _) = makeResolver()
        let cluster = GraphemeCluster(Character("👨‍👩‍👧‍👦"))
        let font = resolver.resolveFont(for: cluster, style: .regular)
        let resolvedName = CTFontCopyPostScriptName(font) as String
        #expect(resolvedName.contains("AppleColorEmoji"))
    }

    @Test func cachesResults() {
        let (resolver, _) = makeResolver()
        let cluster = GraphemeCluster("中")
        let font1 = resolver.resolveFont(for: cluster, style: .regular)
        let font2 = resolver.resolveFont(for: cluster, style: .regular)
        #expect(font1 === font2)
    }

    @Test func differentStylesMayResolveDifferently() {
        let fontSystem = FontSystem(scaleFactor: 2.0)
        let baseFont = fontSystem.ctFont
        let boldFont = CTFontCreateWithName("Menlo-Bold" as CFString, 26.0, nil)
        var collection = FontCollection()
        collection.addFont(baseFont, style: .regular)
        collection.addFont(boldFont, style: .bold)
        let resolver = CodepointResolver(
            collection: collection,
            baseFont: baseFont,
            emojiFont: nil,
            fontSystem: fontSystem
        )

        let regularFont = resolver.resolveFont(for: GraphemeCluster("A"), style: .regular)
        let boldResolved = resolver.resolveFont(for: GraphemeCluster("A"), style: .bold)

        let regularName = CTFontCopyPostScriptName(regularFont) as String
        let boldName = CTFontCopyPostScriptName(boldResolved) as String
        #expect(regularName != boldName)
    }

    @Test func fallsBackToRegularWhenStyleMissing() {
        let fontSystem = FontSystem(scaleFactor: 2.0)
        let baseFont = fontSystem.ctFont
        var collection = FontCollection()
        collection.addFont(baseFont, style: .regular)
        let resolver = CodepointResolver(
            collection: collection,
            baseFont: baseFont,
            emojiFont: nil,
            fontSystem: fontSystem
        )

        let font = resolver.resolveFont(for: GraphemeCluster("A"), style: .boldItalic)
        let resolvedName = CTFontCopyPostScriptName(font) as String
        let baseName = CTFontCopyPostScriptName(baseFont) as String
        #expect(resolvedName == baseName)
    }

    @Test func fontCollectionStyleFromAttributes() {
        let regular = CellAttributes()
        let bold = CellAttributes(flags: .bold)
        let italic = CellAttributes(flags: .italic)
        let boldItalic = CellAttributes(flags: [.bold, .italic])

        #expect(FontCollection.Style.from(attributes: regular) == .regular)
        #expect(FontCollection.Style.from(attributes: bold) == .bold)
        #expect(FontCollection.Style.from(attributes: italic) == .italic)
        #expect(FontCollection.Style.from(attributes: boldItalic) == .boldItalic)
    }

    @Test func textPresentationCharacterDoesNotUseEmojiFont() {
        // U+23FA (⏺) has Emoji=Yes but Emoji_Presentation=No → NOT emoji font
        let (resolver, _) = makeResolver()
        let cluster = GraphemeCluster(Unicode.Scalar(0x23FA)!)
        let font = resolver.resolveFont(for: cluster, style: .regular)
        let resolvedName = CTFontCopyPostScriptName(font) as String
        #expect(!resolvedName.contains("AppleColorEmoji"))
    }

    @Test func vs16ForcesEmojiFont() {
        // ⏺ + VS16 → emoji font
        let (resolver, _) = makeResolver()
        let cluster = GraphemeCluster(scalars: [
            Unicode.Scalar(0x23FA)!,  // ⏺
            Unicode.Scalar(0xFE0F)!,  // VS16
        ])
        let font = resolver.resolveFont(for: cluster, style: .regular)
        let resolvedName = CTFontCopyPostScriptName(font) as String
        #expect(resolvedName.contains("AppleColorEmoji"))
    }

    @Test func cacheSizeStaysBoundedUnderManyInserts() {
        let (resolver, _) = makeResolver()
        // Insert well beyond the 512-entry cap using a wide range of CJK scalars.
        for code in 0x4E00..<0x5400 {
            guard let scalar = Unicode.Scalar(code) else { continue }
            _ = resolver.resolveFont(for: GraphemeCluster(scalar), style: .regular)
        }
        #expect(resolver._cacheCount <= 512)
    }

    @Test func touchedEntrySurvivesEvictionPressure() {
        let (resolver, _) = makeResolver()
        let hotCluster = GraphemeCluster(Unicode.Scalar(0x4E00)!)
        let hotFont = resolver.resolveFont(for: hotCluster, style: .regular)

        // Fill past capacity while repeatedly touching the hot entry, so it
        // should remain at the MRU end of the LRU and never be evicted.
        for code in 0x4E01..<0x5200 {
            guard let scalar = Unicode.Scalar(code) else { continue }
            _ = resolver.resolveFont(for: GraphemeCluster(scalar), style: .regular)
            _ = resolver.resolveFont(for: hotCluster, style: .regular)
        }

        // If the hot entry stayed cached, the same CTFont instance is returned.
        let hotAgain = resolver.resolveFont(for: hotCluster, style: .regular)
        #expect(hotFont === hotAgain)
    }
}
