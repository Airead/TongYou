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

    // MARK: - Multi-token (whitespace-AND) matching

    @Test func fuzzyMatcherAndsWhitespaceSeparatedTokens() {
        // Both tokens must match; they may appear in any order and at any
        // position.
        let candidates = ["prod-db-01", "prod-web-02", "stage-db-03"]
        let ranked = FuzzyMatcher.rank(query: "db 01", in: candidates, extract: { $0 })
        #expect(ranked.map(\.candidate) == ["prod-db-01"])
    }

    @Test func fuzzyMatcherMultiTokenIsOrderInsensitive() {
        // Swapping tokens should not change which candidates match.
        let candidates = ["prod-db-01", "prod-web-02"]
        let ab = FuzzyMatcher.rank(query: "db 01", in: candidates, extract: { $0 })
        let ba = FuzzyMatcher.rank(query: "01 db", in: candidates, extract: { $0 })
        #expect(ab.map(\.candidate) == ba.map(\.candidate))
        #expect(ab.map(\.candidate) == ["prod-db-01"])
    }

    @Test func fuzzyMatcherMultiTokenFailsIfAnyTokenMisses() {
        // "01" is present but "zzz" is not — AND requires both to land.
        let ranked = FuzzyMatcher.rank(query: "01 zzz", in: ["prod-db-01"], extract: { $0 })
        #expect(ranked.isEmpty)
    }

    @Test func fuzzyMatcherMultiTokenUnionsHighlightIndices() {
        // Two tokens, two disjoint highlight regions — the union must
        // contain both (de-duplicated + sorted so the view can walk them
        // linearly).
        let text = "prod-db-01"
        let match = FuzzyMatcher.match(query: "db", in: text)
        let extraMatch = FuzzyMatcher.match(query: "01", in: text)
        #expect(match != nil)
        #expect(extraMatch != nil)

        let ranked = FuzzyMatcher.rank(query: "db 01", in: [text], extract: { $0 })
        #expect(ranked.count == 1)
        let indices = ranked[0].match.matchedIndices
        // Indices must be strictly increasing.
        for i in 1..<indices.count {
            #expect(indices[i - 1] < indices[i])
        }
        // And must cover both "db" and "01" spans.
        let matchedChars = indices.map { text[$0] }
        #expect(matchedChars.contains("d"))
        #expect(matchedChars.contains("b"))
        #expect(matchedChars.contains("0"))
        #expect(matchedChars.contains("1"))
    }

    @Test func fuzzyMatcherSingleTokenUnchanged() {
        // Regression guard: single-token queries must still work exactly
        // like the original subsequence matcher — same score, same
        // highlight indices.
        let single = FuzzyMatcher.match(query: "db", in: "prod-db-01")
        let ranked = FuzzyMatcher.rank(query: "db", in: ["prod-db-01"], extract: { $0 })
        #expect(ranked.count == 1)
        #expect(ranked[0].match.score == single?.score)
        #expect(ranked[0].match.matchedIndices == single?.matchedIndices)
    }

    @Test func fuzzyMatcherExtraneousWhitespaceIgnored() {
        // Leading / trailing / doubled whitespace between tokens should
        // not turn into empty tokens (which would always fail to match).
        let ranked = FuzzyMatcher.rank(
            query: "  db   01  ",
            in: ["prod-db-01"],
            extract: { $0 }
        )
        #expect(ranked.map(\.candidate) == ["prod-db-01"])
    }
}
