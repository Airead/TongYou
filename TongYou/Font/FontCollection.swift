import CoreText
import Foundation
import TYTerminal

/// A collection of fonts organized by style.
/// Used as the backing store for font fallback resolution.
struct FontCollection {
    enum Style: Hashable, Sendable, CaseIterable {
        case regular
        case bold
        case italic
        case boldItalic
    }

    private var fonts: [Style: [CTFont]] = [:]

    mutating func addFont(_ font: CTFont, style: Style) {
        fonts[style, default: []].append(font)
    }

    func fonts(for style: Style) -> [CTFont] {
        fonts[style] ?? []
    }

}

extension FontCollection.Style {
    static func from(attributes: CellAttributes) -> FontCollection.Style {
        let isBold = attributes.flags.contains(.bold)
        let isItalic = attributes.flags.contains(.italic)
        switch (isBold, isItalic) {
        case (true, true): return .boldItalic
        case (true, false): return .bold
        case (false, true): return .italic
        case (false, false): return .regular
        }
    }
}
