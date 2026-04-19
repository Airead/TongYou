import Testing
import Foundation
@testable import TYConfig

@Suite("SSHRuleMatcher", .serialized)
struct SSHRulesTests {

    // MARK: - Matching

    @Test func matchFirstRuleWins() {
        let matcher = SSHRuleMatcher.parse("""
        ssh-prod    *.prod.example.com
        ssh-dev     *.prod.example.com
        """)
        // Both rules' globs match this hostname; the first declared wins.
        #expect(matcher.match(hostname: "db1.prod.example.com") == "ssh-prod")
        #expect(matcher.warnings.isEmpty)
    }

    @Test func matchGlobStar() {
        let matcher = SSHRuleMatcher.parse("""
        ssh-prod    *.prod.example.com
        """)
        #expect(matcher.match(hostname: "db1.prod.example.com") == "ssh-prod")
        #expect(matcher.match(hostname: "api.prod.example.com") == "ssh-prod")
        // Only matches a single "segment" because `*` does not cross dots
        // by our rule intent — but fnmatch `*` does cross dots. Verify the
        // actual behavior matches POSIX fnmatch.
        #expect(matcher.match(hostname: "foo.bar.prod.example.com") == "ssh-prod")
    }

    @Test func matchGlobMultiple() {
        let matcher = SSHRuleMatcher.parse("""
        ssh-prod    *.prod.example.com  *-prod-*  db*.internal
        """)
        #expect(matcher.match(hostname: "api.prod.example.com") == "ssh-prod")
        #expect(matcher.match(hostname: "web-prod-2") == "ssh-prod")
        #expect(matcher.match(hostname: "db17.internal") == "ssh-prod")
        #expect(matcher.match(hostname: "other.example.com") == nil)
    }

    @Test func matchGlobQuestionMark() {
        // `?` is a single-character wildcard in POSIX fnmatch.
        let matcher = SSHRuleMatcher.parse("""
        ssh-dev     db?.dev
        """)
        #expect(matcher.match(hostname: "db1.dev") == "ssh-dev")
        #expect(matcher.match(hostname: "dbx.dev") == "ssh-dev")
        #expect(matcher.match(hostname: "db10.dev") == nil)
    }

    @Test func matchCaseInsensitive() {
        let matcher = SSHRuleMatcher.parse("""
        ssh-prod    *.prod.example.com
        """)
        #expect(matcher.match(hostname: "Db1.Prod.Example.Com") == "ssh-prod")
        #expect(matcher.match(hostname: "DB1.PROD.EXAMPLE.COM") == "ssh-prod")
    }

    @Test func noMatchReturnsNil() {
        let matcher = SSHRuleMatcher.parse("""
        ssh-prod    *.prod.example.com
        """)
        #expect(matcher.match(hostname: "local.box") == nil)
        #expect(matcher.match(hostname: "staging.example.com") == nil)
    }

    @Test func emptyFileReturnsNil() {
        let matcher = SSHRuleMatcher.parse("")
        #expect(matcher.rules.isEmpty)
        #expect(matcher.match(hostname: "anything.example.com") == nil)
    }

    // MARK: - Parsing

    @Test func commentAndBlankLinesIgnored() {
        let matcher = SSHRuleMatcher.parse("""
        # SSH rules.

            # indented comment
        ssh-prod    *.prod.example.com

        ssh-dev     *.dev.example.com   # trailing comment
        """)
        #expect(matcher.rules.count == 2)
        #expect(matcher.rules[0].template == "ssh-prod")
        #expect(matcher.rules[1].template == "ssh-dev")
        // Trailing comment stripped before tokenising → glob list unaffected.
        #expect(matcher.rules[1].globs == ["*.dev.example.com"])
        #expect(matcher.warnings.isEmpty)
    }

    @Test func malformedLineSkippedWithWarning() {
        let matcher = SSHRuleMatcher.parse("""
        ssh-prod    *.prod.example.com
        just-one-token
        ssh-dev     *.dev.example.com
        """)
        #expect(matcher.rules.count == 2)
        #expect(matcher.rules.map(\.template) == ["ssh-prod", "ssh-dev"])
        #expect(matcher.warnings.count == 1)
        #expect(matcher.warnings[0].contains("line 2"))
    }

    @Test func multipleWhitespaceTokensCollapse() {
        // Mixture of tabs and spaces between tokens must parse the same.
        let matcher = SSHRuleMatcher.parse("ssh-prod\t\t*.prod.example.com   *-prod-*")
        #expect(matcher.rules.count == 1)
        #expect(matcher.rules[0].template == "ssh-prod")
        #expect(matcher.rules[0].globs == ["*.prod.example.com", "*-prod-*"])
    }

    // MARK: - File I/O

    @Test func missingFileReturnsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("does-not-exist.txt")
        let matcher = try SSHRuleMatcher.load(from: url)
        #expect(matcher.rules.isEmpty)
        #expect(matcher.warnings.isEmpty)
        #expect(matcher.match(hostname: "anything") == nil)
    }

    @Test func loadFromFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ssh-rules.txt")
        try """
        ssh-prod    *.prod.example.com
        ssh-dev     *.dev.example.com
        """.write(to: url, atomically: true, encoding: .utf8)

        let matcher = try SSHRuleMatcher.load(from: url)
        #expect(matcher.rules.count == 2)
        #expect(matcher.match(hostname: "db1.prod.example.com") == "ssh-prod")
        #expect(matcher.match(hostname: "staging.dev.example.com") == "ssh-dev")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tongyou-ssh-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }
}
