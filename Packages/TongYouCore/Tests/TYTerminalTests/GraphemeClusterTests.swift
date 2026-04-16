import Testing
@testable import TYTerminal

@Suite("GraphemeCluster tests")
struct GraphemeClusterTests {

    @Test func initializesFromScalar() {
        let cluster = GraphemeCluster(Unicode.Scalar("A"))
        #expect(cluster.scalarCount == 1)
        #expect(cluster.firstScalar == Unicode.Scalar("A"))
        #expect(cluster.scalars == [Unicode.Scalar("A")])
        #expect(!cluster.isEmojiSequence)
    }

    @Test func initializesFromCharacter() {
        let cluster = GraphemeCluster(Character("👨‍👩‍👧‍👦"))
        #expect(cluster.scalarCount == 7)
        #expect(cluster.isEmojiSequence)
    }

    @Test func zwjSequenceProperties() {
        let family = GraphemeCluster(Character("👨‍👩‍👧‍👦"))
        #expect(family.scalarCount == 7)
        #expect(family.isEmojiSequence)
        #expect(family.firstScalar == Unicode.Scalar(0x1F468))
        #expect(family.string == "👨‍👩‍👧‍👦")
    }

    @Test func skinToneModifierProperties() {
        let wave = GraphemeCluster(Character("👋🏻"))
        #expect(wave.scalarCount == 2)
        #expect(wave.isEmojiSequence)
        #expect(wave.firstScalar == Unicode.Scalar(0x1F44B))
    }

    @Test func flagEmojiProperties() {
        let flag = GraphemeCluster(Character("🇨🇳"))
        #expect(flag.scalarCount == 2)
        #expect(flag.isEmojiSequence)
        #expect(flag.firstScalar == Unicode.Scalar(0x1F1E8))
    }

    @Test func simpleAsciiProperties() {
        let a = GraphemeCluster(Character("A"))
        #expect(a.scalarCount == 1)
        #expect(!a.isEmojiSequence)
        #expect(a.terminalWidth == 1)
    }

    @Test func singleEmojiNotSequence() {
        let smiley = GraphemeCluster(Character("😀"))
        #expect(smiley.scalarCount == 1)
        #expect(!smiley.isEmojiSequence)
    }

    @Test func emptyCluster() {
        let empty = GraphemeCluster()
        #expect(empty.scalarCount == 0)
        #expect(empty.firstScalar == nil)
        #expect(empty.string == "")
    }

    @Test func initializesFromScalarArray() {
        let scalars = [Unicode.Scalar(0x1F468)!, Unicode.Scalar(0x200D)!, Unicode.Scalar(0x1F469)!]
        let cluster = GraphemeCluster(scalars: scalars)
        #expect(cluster.scalarCount == 3)
        #expect(cluster.isEmojiSequence)
    }

    @Test func equality() {
        let family1 = GraphemeCluster(Character("👨‍👩‍👧‍👦"))
        let family2 = GraphemeCluster(Character("👨‍👩‍👧‍👦"))
        let wave = GraphemeCluster(Character("👋🏻"))
        #expect(family1 == family2)
        #expect(family1 != wave)
    }

    @Test func terminalWidthForEmojiSequences() {
        #expect(GraphemeCluster(Character("👨‍👩‍👧‍👦")).terminalWidth == 2)
        #expect(GraphemeCluster(Character("👋🏻")).terminalWidth == 2)
        #expect(GraphemeCluster(Character("🇨🇳")).terminalWidth == 2)
        #expect(GraphemeCluster(Character("A")).terminalWidth == 1)
    }

    @Test func threeScalarHeapFallback() {
        // 👨‍🔬 = U+1F468 U+200D U+1F52C (3 scalars, exceeds inlineCapacity=2)
        let scientist = GraphemeCluster(Character("👨‍🔬"))
        #expect(scientist.scalarCount == 3)
        #expect(scientist.isEmojiSequence)
        #expect(scientist.firstScalar == Unicode.Scalar(0x1F468))
        #expect(scientist.string == "👨‍🔬")
        #expect(scientist.terminalWidth == 2)

        // Round-trip: Character → GraphemeCluster → string → Character → GraphemeCluster
        let roundTripped = GraphemeCluster(Character(scientist.string))
        #expect(roundTripped == scientist)
        #expect(roundTripped.hashValue == scientist.hashValue)
    }

    @Test func fourScalarHeapFallback() {
        // 👨‍👩‍👦 = U+1F468 U+200D U+1F469 U+200D U+1F466 — actually 5 scalars
        // Use a 4-scalar sequence: 🏳️‍🌈 is flag + VS16 + ZWJ + rainbow = 4 scalars
        let scalars: [Unicode.Scalar] = [
            Unicode.Scalar(0x1F3F3)!,  // white flag
            Unicode.Scalar(0xFE0F)!,   // VS16
            Unicode.Scalar(0x200D)!,   // ZWJ
            Unicode.Scalar(0x1F308)!,  // rainbow
        ]
        let cluster = GraphemeCluster(scalars: scalars)
        #expect(cluster.scalarCount == 4)
        #expect(cluster.isEmojiSequence)
        #expect(cluster.firstScalar == Unicode.Scalar(0x1F3F3))

        // Equality with identical construction
        let cluster2 = GraphemeCluster(scalars: scalars)
        #expect(cluster == cluster2)
        #expect(cluster.hashValue == cluster2.hashValue)
    }

    @Test func stringRoundTrip() {
        let clusters = [
            GraphemeCluster(Character("👨‍👩‍👧‍👦")),
            GraphemeCluster(Character("👋🏻")),
            GraphemeCluster(Character("🇨🇳")),
            GraphemeCluster(Character("A"))
        ]
        for cluster in clusters {
            #expect(GraphemeCluster(Character(cluster.string)) == cluster)
        }
    }
}

@Suite("Cell with GraphemeCluster tests")
struct CellGraphemeClusterTests {

    @Test func cellBackwardCompatibleInit() {
        let cell = Cell(codepoint: Unicode.Scalar("A"), attributes: .default, width: .normal)
        #expect(cell.content.scalarCount == 1)
        #expect(cell.codepoint == Unicode.Scalar("A"))
    }

    @Test func cellWithMultiScalarContent() {
        let cluster = GraphemeCluster(Character("👨‍👩‍👧‍👦"))
        let cell = Cell(content: cluster, attributes: .default, width: .wide)
        #expect(cell.content.scalarCount == 7)
        #expect(cell.codepoint == Unicode.Scalar(0x1F468))
        #expect(cell.width == .wide)
    }

    @Test func cellCodepointSetterUpdatesContent() {
        var cell = Cell.empty
        cell.codepoint = Unicode.Scalar("X")
        #expect(cell.content == GraphemeCluster(Unicode.Scalar("X")))
    }

    @Test func emptyCellIsEmpty() {
        let cell = Cell.empty
        #expect(cell.content.firstScalar == Unicode.Scalar(" "))
        #expect(cell.width == .normal)
    }
}
