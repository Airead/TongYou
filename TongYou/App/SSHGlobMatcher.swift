import Foundation

/// Glob-based matcher used exclusively by the SSH palette scope. Replaces
/// the whitespace-AND fuzzy matcher on the SSH pool because host names
/// are structurally homogeneous (`env-az-role-idx`) and subsequence
/// matches produce too much noise.
///
/// Query grammar
/// -------------
///   input := glob (`,` glob)*
///   glob  := one or more characters where `*` and `?` are wildcards
///
/// Each glob is case-insensitively matched against the candidate text with
/// **implicit substring** semantics — it doesn't need to span the full
/// text. A candidate matches if **any** glob matches (OR).
///
/// Highlight indices point only at positions covered by literal (non-
/// wildcard) characters, so the view underlines the same letters the user
/// actually typed.
nonisolated enum SSHGlobMatcher {

    /// Which characters activate glob/multi-pattern mode. When *none* of
    /// these appear in the SSH query, the caller should fall back to its
    /// plain-text behaviour (e.g. the ad-hoc `ssh <literal>` row).
    static let metaCharacters: Set<Character> = ["*", "?", ","]

    /// One element of a parsed glob.
    enum Segment: Equatable {
        /// A literal run. Lower-cased at parse time so per-candidate
        /// matching is a simple substring compare against a lower-cased
        /// candidate without re-lowercasing on every attempt.
        case literal(String)
        /// `?` — matches exactly one character.
        case anyChar
        /// `*` — matches zero or more characters.
        case anyRun
    }

    /// A single parsed glob. `segments` is normalised so that:
    /// - consecutive `.anyRun` collapse to one (`**` ≡ `*`);
    /// - leading/trailing `.anyRun` are dropped because matching is
    ///   already substring (implicit `*` on both ends), keeping the
    ///   matcher's loop simpler.
    struct Pattern: Equatable {
        let segments: [Segment]
    }

    /// Split the raw SSH query into one or more patterns. Commas separate
    /// alternatives; each piece is trimmed and empty pieces are dropped.
    /// Returns `nil` when the query reduces to nothing (treat as
    /// "match all" upstream).
    static func parse(_ input: String) -> [Pattern]? {
        let pieces = input.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return nil }
        return pieces.map(compile(glob:))
    }

    /// Compile a single raw glob string into a sequence of segments.
    /// Normalisation rules (see ``Pattern``) apply here so the match
    /// loop doesn't have to worry about degenerate inputs.
    static func compile(glob: String) -> Pattern {
        var segments: [Segment] = []
        var literalBuffer = ""
        for ch in glob {
            switch ch {
            case "*":
                if !literalBuffer.isEmpty {
                    segments.append(.literal(literalBuffer.lowercased()))
                    literalBuffer = ""
                }
                if segments.last != .anyRun {
                    segments.append(.anyRun)
                }
            case "?":
                if !literalBuffer.isEmpty {
                    segments.append(.literal(literalBuffer.lowercased()))
                    literalBuffer = ""
                }
                segments.append(.anyChar)
            default:
                literalBuffer.append(ch)
            }
        }
        if !literalBuffer.isEmpty {
            segments.append(.literal(literalBuffer.lowercased()))
        }
        // Trim leading/trailing `.anyRun` — matching is already implicitly
        // substring, so leading `*` adds nothing; trailing `*` adds
        // nothing either.
        while segments.first == .anyRun { segments.removeFirst() }
        while segments.last == .anyRun { segments.removeLast() }
        return Pattern(segments: segments)
    }

    /// A match hit. Mirrors ``FuzzyMatcher/Match`` so the palette view
    /// can render both matcher families without branching.
    struct Match: Equatable {
        let matchedIndices: [String.Index]
    }

    /// Match `text` against `patterns` with OR semantics. Returns the
    /// first-matching pattern's highlight union-ed with any other
    /// matching pattern so the view shows every literal the user typed.
    /// Returns `nil` when no pattern matches.
    static func match(text: String, patterns: [Pattern]) -> Match? {
        let lowered = text.lowercased()
        // Build an Int-offset → String.Index lookup once. `String.Index`
        // can't be arithmetic'd directly, so the matcher works in Int
        // offsets and maps back at the end. `lowered` has the same
        // length as `text` as long as no Unicode case-folding changes
        // the character count — for ASCII host names this holds, and
        // callers already constrain SSH candidates to ASCII-ish forms.
        let textChars = Array(lowered)
        var unionIndices: Set<Int> = []
        var anyMatched = false
        for pattern in patterns {
            if let hits = matchOne(pattern: pattern, in: textChars) {
                anyMatched = true
                unionIndices.formUnion(hits)
            }
        }
        guard anyMatched else { return nil }
        let sorted = unionIndices.sorted()
        // Map back using the original string so highlight points at the
        // user-visible characters.
        let stringIndices = sorted.map { text.index(text.startIndex, offsetBy: $0) }
        return Match(matchedIndices: stringIndices)
    }

    /// Greedy left-to-right match of a single pattern against a
    /// lower-cased character array. Returns the set of literal-segment
    /// character positions on success, `nil` when the pattern can't be
    /// placed. Implicit substring: the first literal may start at any
    /// position, every subsequent literal follows its `*` / `?` slack.
    private static func matchOne(pattern: Pattern, in text: [Character]) -> [Int]? {
        if pattern.segments.isEmpty {
            // Empty after normalisation (e.g. raw input was `*` / `?*?`
            // with no literals). Treat as "matches anywhere, highlights
            // nothing". Callers that don't want this should filter at
            // parse time.
            return []
        }

        var cursor = 0
        var indices: [Int] = []
        var i = 0
        while i < pattern.segments.count {
            let segment = pattern.segments[i]
            switch segment {
            case .literal(let needle):
                // Next segment is an anyRun → literal may start at any
                // cursor-or-later position. Otherwise (leading or
                // after .anyChar) the literal must start exactly at
                // `cursor`.
                let prevIsWildcard = i == 0 || pattern.segments[i - 1] == .anyRun
                guard let hit = findLiteral(needle, in: text, from: cursor, anywhere: prevIsWildcard) else {
                    return nil
                }
                for offset in 0..<needle.count {
                    indices.append(hit + offset)
                }
                cursor = hit + needle.count
            case .anyChar:
                guard cursor < text.count else { return nil }
                cursor += 1
            case .anyRun:
                // Slack is consumed implicitly by the next literal's
                // search window — no cursor movement here.
                break
            }
            i += 1
        }
        return indices
    }

    /// Find `needle` in `text[from...]`. When `anywhere` is true, scan
    /// forward from `from` and report the first hit. Otherwise the
    /// needle must sit exactly at `from`.
    private static func findLiteral(
        _ needle: String,
        in text: [Character],
        from: Int,
        anywhere: Bool
    ) -> Int? {
        let needleChars = Array(needle)
        guard !needleChars.isEmpty else { return from }
        if anywhere {
            let maxStart = text.count - needleChars.count
            guard maxStart >= from else { return nil }
            for start in from...maxStart {
                if matches(needleChars, in: text, at: start) { return start }
            }
            return nil
        } else {
            guard from + needleChars.count <= text.count else { return nil }
            return matches(needleChars, in: text, at: from) ? from : nil
        }
    }

    private static func matches(_ needle: [Character], in text: [Character], at start: Int) -> Bool {
        for (offset, ch) in needle.enumerated() where text[start + offset] != ch {
            return false
        }
        return true
    }
}
