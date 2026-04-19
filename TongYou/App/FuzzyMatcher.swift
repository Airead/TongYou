import Foundation

/// VSCode / fzf-style subsequence fuzzy matcher.
///
/// `match(query:in:)` walks the candidate left-to-right, consuming query
/// characters whenever they appear. A match succeeds only if every query
/// character is consumed in order. The returned score rewards:
/// - Consecutive matches (runs are cheaper than scattered hits).
/// - Matches at word boundaries (start of string, after separators,
///   camelCase humps) — these mirror how people usually type an acronym.
/// - Exact case hits (case-insensitive still matches but ranks slightly lower).
///
/// Scores are internal and only meaningful for comparison; higher is better.
enum FuzzyMatcher {

    /// A single hit produced by `match(query:in:)`.
    struct Match: Equatable {
        /// The overall relevance score. Higher means more relevant.
        let score: Int
        /// Indices (into the candidate `String`) of matched characters — used
        /// to draw the highlight underlines in the palette rows.
        let matchedIndices: [String.Index]
    }

    /// Rank all `candidates` against `query`. Empty `query` returns the
    /// candidates in their input order with zero score (no filtering).
    ///
    /// `extract` maps a candidate element to the searchable text. The result
    /// keeps stable sort order for equal scores, matching the caller's input
    /// ordering (which is already sorted by history recency / ssh_config
    /// position upstream).
    static func rank<T>(
        query: String,
        in candidates: [T],
        extract: (T) -> String
    ) -> [(candidate: T, match: Match)] {
        if query.isEmpty {
            return candidates.map { ($0, Match(score: 0, matchedIndices: [])) }
        }
        var scored: [(offset: Int, candidate: T, match: Match)] = []
        for (offset, candidate) in candidates.enumerated() {
            guard let match = self.match(query: query, in: extract(candidate)) else {
                continue
            }
            scored.append((offset, candidate, match))
        }
        // Sort by score desc, then by original offset to preserve input
        // ordering among equally scored candidates (stable, deterministic).
        scored.sort { a, b in
            if a.match.score != b.match.score { return a.match.score > b.match.score }
            return a.offset < b.offset
        }
        return scored.map { ($0.candidate, $0.match) }
    }

    /// Subsequence match of `query` against `text`. Returns nil if any query
    /// character cannot be consumed in order.
    static func match(query: String, in text: String) -> Match? {
        if query.isEmpty { return Match(score: 0, matchedIndices: []) }

        // Case-insensitive walk; exact-case hits get a small bonus.
        let queryChars = Array(query)
        let textChars = Array(text)
        var qi = 0
        var indices: [Int] = []
        var score = 0
        var consecutive = 0
        var lastMatchedPos = -1

        for ti in 0..<textChars.count {
            guard qi < queryChars.count else { break }
            let qc = queryChars[qi]
            let tc = textChars[ti]
            guard charsMatch(qc, tc) else {
                consecutive = 0
                continue
            }

            // Base hit.
            score += 1

            // Case-sensitive bonus.
            if qc == tc { score += 1 }

            // Start-of-string bonus.
            if ti == 0 { score += 8 }

            // Word-boundary bonus (after separator or a camelCase hump).
            if ti > 0 {
                let prev = textChars[ti - 1]
                if Self.isSeparator(prev) { score += 6 }
                else if prev.isLowercase && tc.isUppercase { score += 4 }
            }

            // Consecutive-run bonus: each additional chained match adds more.
            if lastMatchedPos >= 0 && ti == lastMatchedPos + 1 {
                consecutive += 1
                score += 4 + consecutive
            } else {
                consecutive = 0
            }

            indices.append(ti)
            lastMatchedPos = ti
            qi += 1
        }

        guard qi == queryChars.count else { return nil }

        // Small penalty proportional to how far into the text we had to scan
        // to consume the query; ties broken by earlier-starting matches.
        if let first = indices.first { score -= first / 4 }

        // Map Int offsets back to String.Index so callers can build
        // AttributedString ranges without re-walking the text.
        let stringIndices = indices.map { text.index(text.startIndex, offsetBy: $0) }
        return Match(score: score, matchedIndices: stringIndices)
    }

    private static func charsMatch(_ a: Character, _ b: Character) -> Bool {
        if a == b { return true }
        // Character.lowercased() returns a String but for single code points
        // comparing the lowercased forms is the right behaviour here.
        return a.lowercased() == b.lowercased()
    }

    private static func isSeparator(_ c: Character) -> Bool {
        c == " " || c == "-" || c == "_" || c == "." || c == "/" || c == "@" || c == ":"
    }
}
