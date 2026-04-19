import Testing
@testable import TongYou

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {

    @Test func fuzzyMatcherScoresRelevance() {
        // Plan: "dbp" should rank "db-prod-1" higher than a scattered match.
        // The plan mentions "dashboard" but that candidate has no "p" so
        // it cannot match at all — we substitute another real host-style
        // string that *does* match but without the consecutive-run and
        // word-boundary bonuses that "db-prod-1" earns.
        let candidates = ["dashboard-plus", "db-prod-1"]
        let ranked = FuzzyMatcher.rank(query: "dbp", in: candidates, extract: { $0 })
        #expect(ranked.count == 2)
        #expect(ranked[0].candidate == "db-prod-1")
        #expect(ranked[1].candidate == "dashboard-plus")
    }

    @Test func fuzzyMatcherReturnsHighlightRanges() {
        let match = FuzzyMatcher.match(query: "dbp", in: "db-prod-1")
        #expect(match != nil)
        // Three matched characters → three highlight indices.
        #expect(match?.matchedIndices.count == 3)

        // The three indices should map back to "d", "b", "p" in that order.
        let text = "db-prod-1"
        let chars = match?.matchedIndices.map { text[$0] } ?? []
        #expect(chars == ["d", "b", "p"])
    }

    @Test func fuzzyMatcherEmptyQueryReturnsAll() {
        let candidates = ["alpha", "beta", "gamma"]
        let ranked = FuzzyMatcher.rank(query: "", in: candidates, extract: { $0 })
        #expect(ranked.count == 3)
        #expect(ranked.map(\.candidate) == candidates)
        // Empty query produces zero-score, no-highlight matches.
        for row in ranked {
            #expect(row.match.score == 0)
            #expect(row.match.matchedIndices.isEmpty)
        }
    }

    @Test func fuzzyMatcherNonMatchDropsCandidate() {
        // Query characters must all be consumed in order; "xyz" does not
        // appear as a subsequence of "alpha".
        let ranked = FuzzyMatcher.rank(query: "xyz", in: ["alpha"], extract: { $0 })
        #expect(ranked.isEmpty)
    }

    @Test func fuzzyMatcherCaseInsensitive() {
        #expect(FuzzyMatcher.match(query: "db", in: "DB1") != nil)
        #expect(FuzzyMatcher.match(query: "DB", in: "db1") != nil)
    }

    @Test func fuzzyMatcherPreservesStableOrderForTies() {
        // With an empty query every candidate scores zero; order must match
        // the input order (used by the palette to keep history-recency sort).
        let candidates = ["first", "second", "third"]
        let ranked = FuzzyMatcher.rank(query: "", in: candidates, extract: { $0 })
        #expect(ranked.map(\.candidate) == candidates)
    }
}
