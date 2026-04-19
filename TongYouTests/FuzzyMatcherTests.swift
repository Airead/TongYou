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

/// Unit tests for the SSH-scope glob matcher. The matcher is intentionally
/// narrower than ``FuzzyMatcher``: each comma-separated glob must match as
/// a contiguous substring (with `*` / `?` wildcards), and the set of
/// patterns combines with OR semantics.
@Suite("SSHGlobMatcher")
struct SSHGlobMatcherTests {

    // MARK: - Parsing

    @Test func parseSplitsOnCommaAndTrimsWhitespace() {
        let patterns = SSHGlobMatcher.parse("aws-*,  btc-node  ,  *-50")
        #expect(patterns?.count == 3)
        #expect(patterns?[0] == SSHGlobMatcher.compile(glob: "aws-*"))
        #expect(patterns?[1] == SSHGlobMatcher.compile(glob: "btc-node"))
        #expect(patterns?[2] == SSHGlobMatcher.compile(glob: "*-50"))
    }

    @Test func parseIgnoresEmptyPieces() {
        // Trailing / doubled commas should not produce empty patterns
        // that would otherwise match everything.
        #expect(SSHGlobMatcher.parse("aws-*,")?.count == 1)
        #expect(SSHGlobMatcher.parse(",,aws-*,,")?.count == 1)
        #expect(SSHGlobMatcher.parse("   ,  , ") == nil)
        #expect(SSHGlobMatcher.parse("") == nil)
    }

    @Test func compileNormalisesLeadingTrailingAndRepeatedWildcards() {
        // Substring matching is implicit, so **/leading/trailing wildcards
        // carry no signal — they're stripped so the match loop doesn't
        // have to special-case them.
        let pattern = SSHGlobMatcher.compile(glob: "**a*b**")
        #expect(pattern.segments == [
            .literal("a"),
            .anyRun,
            .literal("b"),
        ])
    }

    @Test func compileLowercasesLiterals() {
        // Matching is case-insensitive — compile-time lower-casing keeps
        // the hot loop allocation-free.
        let pattern = SSHGlobMatcher.compile(glob: "AWS")
        #expect(pattern.segments == [.literal("aws")])
    }

    // MARK: - Matching

    @Test func singleLiteralGlobIsSubstring() {
        // A plain token (no wildcards) matches anywhere in the candidate.
        let patterns = SSHGlobMatcher.parse("ase1c")!
        let hit = SSHGlobMatcher.match(text: "aws-ase1c-btc-node-50", patterns: patterns)
        #expect(hit != nil)
        // All five literal characters get highlighted.
        let chars = (hit?.matchedIndices ?? []).map { "aws-ase1c-btc-node-50"[$0] }
        #expect(String(chars) == "ase1c")
    }

    @Test func singleLiteralGlobIsCaseInsensitive() {
        let patterns = SSHGlobMatcher.parse("AWS")!
        #expect(SSHGlobMatcher.match(text: "aws-a", patterns: patterns) != nil)
    }

    @Test func starWildcardSpansAnyRun() {
        // `aws*50` should skip across arbitrary characters between the
        // two literals — both `aws-ase1c-btc-node-50` and `aws-50` match.
        let patterns = SSHGlobMatcher.parse("aws*50")!
        #expect(SSHGlobMatcher.match(text: "aws-ase1c-btc-node-50", patterns: patterns) != nil)
        #expect(SSHGlobMatcher.match(text: "aws-50", patterns: patterns) != nil)
        // But the order matters — `50-aws` must not match.
        #expect(SSHGlobMatcher.match(text: "50-aws", patterns: patterns) == nil)
    }

    @Test func questionWildcardMatchesExactlyOneChar() {
        let patterns = SSHGlobMatcher.parse("a?e1c")!
        #expect(SSHGlobMatcher.match(text: "ase1c", patterns: patterns) != nil)
        #expect(SSHGlobMatcher.match(text: "axe1c", patterns: patterns) != nil)
        // ? is not optional — `ae1c` has no character to consume.
        #expect(SSHGlobMatcher.match(text: "ae1c", patterns: patterns) == nil)
    }

    @Test func highlightSkipsWildcardCharacters() {
        // Highlight indices point only at *literal* characters — `*` and
        // `?` contribute nothing, otherwise the view would underline
        // characters the user didn't type.
        let patterns = SSHGlobMatcher.parse("a*c")!
        let hit = SSHGlobMatcher.match(text: "abc", patterns: patterns)
        let chars = (hit?.matchedIndices ?? []).map { "abc"[$0] }
        #expect(String(chars) == "ac")
    }

    @Test func multipleGlobsCombineWithOr() {
        // `ase1c, ase1b` should match both AZ-specific hosts.
        let patterns = SSHGlobMatcher.parse("ase1c, ase1b")!
        #expect(SSHGlobMatcher.match(text: "aws-ase1c-btc-node-50", patterns: patterns) != nil)
        #expect(SSHGlobMatcher.match(text: "aws-ase1b-btc-node-50", patterns: patterns) != nil)
        // A host that matches neither token must be dropped.
        #expect(SSHGlobMatcher.match(text: "aws-use1-btc-node-50", patterns: patterns) == nil)
    }

    @Test func multipleGlobsUnionHighlights() {
        // When more than one glob matches the same candidate, the
        // view should underline every literal character any of them
        // touched (union, not just the first winner).
        let patterns = SSHGlobMatcher.parse("aws, 50")!
        let text = "aws-ase1c-btc-node-50"
        let hit = SSHGlobMatcher.match(text: text, patterns: patterns)
        let chars = (hit?.matchedIndices ?? []).map { text[$0] }
        // Both "aws" at the start and "50" at the end must be covered.
        #expect(String(chars).contains("aws"))
        #expect(String(chars).contains("50"))
    }

    @Test func nonMatchReturnsNil() {
        let patterns = SSHGlobMatcher.parse("zzz")!
        #expect(SSHGlobMatcher.match(text: "aws-50", patterns: patterns) == nil)
    }
}
