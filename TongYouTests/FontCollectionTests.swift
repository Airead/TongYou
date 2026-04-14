import CoreText
import Testing
import TYTerminal
@testable import TongYou

struct FontCollectionTests {

    @Test func emptyCollectionReturnsNoFonts() {
        let collection = FontCollection()
        #expect(collection.fonts(for: .regular).isEmpty)
        #expect(collection.fonts(for: .bold).isEmpty)
    }

    @Test func canAddAndRetrieveFonts() {
        var collection = FontCollection()
        let baseFont = FontSystem(scaleFactor: 2.0).ctFont

        collection.addFont(baseFont, style: .regular)

        let regularFonts = collection.fonts(for: .regular)
        #expect(regularFonts.count == 1)
        #expect(regularFonts.first === baseFont)
        #expect(collection.fonts(for: .bold).isEmpty)
    }

    @Test func multipleFontsPerStyle() {
        var collection = FontCollection()
        let font1 = FontSystem(scaleFactor: 2.0).ctFont
        let font2 = FontSystem(scaleFactor: 2.0).ctFont

        collection.addFont(font1, style: .regular)
        collection.addFont(font2, style: .regular)

        let regularFonts = collection.fonts(for: .regular)
        #expect(regularFonts.count == 2)
        #expect(regularFonts[0] === font1)
        #expect(regularFonts[1] === font2)
    }

    @Test func differentStylesAreIndependent() {
        var collection = FontCollection()
        let regularFont = FontSystem(scaleFactor: 2.0).ctFont
        let emojiFont = CTFontCreateWithName("Apple Color Emoji" as CFString, 26.0, nil)

        collection.addFont(regularFont, style: .regular)
        collection.addFont(emojiFont, style: .boldItalic)

        #expect(collection.fonts(for: .regular).count == 1)
        #expect(collection.fonts(for: .boldItalic).count == 1)
        #expect(collection.fonts(for: .bold).isEmpty)
    }
}
