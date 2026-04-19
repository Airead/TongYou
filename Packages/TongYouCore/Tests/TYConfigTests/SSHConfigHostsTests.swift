import Testing
import Foundation
@testable import TYConfig

@Suite("SSHConfigHosts", .serialized)
struct SSHConfigHostsTests {

    // MARK: - Parsing

    @Test func parseSimpleHost() {
        let result = SSHConfigHosts.parse("Host db01")
        #expect(result.hosts.count == 1)
        #expect(result.hosts[0].alias == "db01")
        #expect(result.hosts[0].hostname == nil)
    }

    @Test func parseHostWithHostname() {
        let result = SSHConfigHosts.parse("""
        Host db01
            Hostname db1.internal
        """)
        #expect(result.hosts.count == 1)
        #expect(result.hosts[0].alias == "db01")
        #expect(result.hosts[0].hostname == "db1.internal")
    }

    @Test func parseMultipleAliasesOnOneLine() {
        let result = SSHConfigHosts.parse("Host db01 db01-b")
        #expect(result.hosts.count == 2)
        #expect(result.hosts.map(\.alias) == ["db01", "db01-b"])
        #expect(result.hosts.allSatisfy { $0.hostname == nil })
    }

    @Test func hostnameSharedAcrossMultipleAliases() {
        // A Hostname directive in a multi-alias block applies to every alias.
        let result = SSHConfigHosts.parse("""
        Host db01 db01-b
            Hostname db1.internal
        """)
        #expect(result.hosts.count == 2)
        #expect(result.hosts.map(\.alias) == ["db01", "db01-b"])
        #expect(result.hosts.allSatisfy { $0.hostname == "db1.internal" })
    }

    @Test func wildcardHostSkipped() {
        let result = SSHConfigHosts.parse("""
        Host *
            User admin

        Host *.internal
            Port 22

        Host db1 *.prod
            Hostname db1.internal

        Host db01
            Hostname db1.internal
        """)
        // `Host *`, `Host *.internal`, and the mixed `Host db1 *.prod`
        // are all treated as rule blocks → only `db01` comes through.
        #expect(result.hosts.count == 1)
        #expect(result.hosts[0].alias == "db01")
        #expect(result.hosts[0].hostname == "db1.internal")
    }

    @Test func caseInsensitiveKeywords() {
        let result = SSHConfigHosts.parse("""
        HOST db01
            HOSTNAME db1.internal
        host db02
            hostname db2.internal
        Host db03
            HostName db3.internal
        """)
        #expect(result.hosts.count == 3)
        #expect(result.hosts.map(\.alias) == ["db01", "db02", "db03"])
        #expect(result.hosts.map(\.hostname) == [
            "db1.internal",
            "db2.internal",
            "db3.internal"
        ])
    }

    @Test func commentsAndBlanksIgnored() {
        let result = SSHConfigHosts.parse("""
        # Top comment

        Host db01   # inline comment
            # inline block comment
            Hostname db1.internal

        # blank block
        """)
        #expect(result.hosts.count == 1)
        #expect(result.hosts[0].alias == "db01")
        #expect(result.hosts[0].hostname == "db1.internal")
    }

    @Test func unknownKeywordsIgnored() {
        let result = SSHConfigHosts.parse("""
        Host db01
            User root
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
            ForwardAgent yes
            Hostname db1.internal
            ServerAliveInterval 60
        """)
        #expect(result.hosts.count == 1)
        #expect(result.hosts[0].alias == "db01")
        #expect(result.hosts[0].hostname == "db1.internal")
    }

    @Test func equalsSeparatorSupported() {
        // ssh_config allows `Keyword=value`; a rare style, but we shouldn't
        // drop aliases just because the user used that form.
        let result = SSHConfigHosts.parse("""
        Host=db01
            Hostname=db1.internal
        """)
        #expect(result.hosts.count == 1)
        #expect(result.hosts[0].alias == "db01")
        #expect(result.hosts[0].hostname == "db1.internal")
    }

    @Test func matchBlockDoesNotLeakHostname() {
        // A Match block must not make a later Hostname directive apply to
        // the preceding Host block.
        let result = SSHConfigHosts.parse("""
        Host db01

        Match host *.prod
            Hostname should-not-attach-to-db01
        """)
        #expect(result.hosts.count == 1)
        #expect(result.hosts[0].alias == "db01")
        #expect(result.hosts[0].hostname == nil)
    }

    @Test func firstHostnameWins() {
        // Unusual but ssh_config's documented behavior: first set wins.
        let result = SSHConfigHosts.parse("""
        Host db01
            Hostname primary.internal
            Hostname secondary.internal
        """)
        #expect(result.hosts.count == 1)
        #expect(result.hosts[0].hostname == "primary.internal")
    }

    @Test func multipleHostBlocks() throws {
        let result = SSHConfigHosts.parse("""
        Host db01
            Hostname db1.internal

        Host web01 web02
            Hostname webpool.internal

        Host jumpbox
        """)
        #expect(result.hosts.count == 4)
        #expect(result.hosts.first(where: { $0.alias == "db01" })?.hostname == "db1.internal")
        #expect(result.hosts.first(where: { $0.alias == "web01" })?.hostname == "webpool.internal")
        #expect(result.hosts.first(where: { $0.alias == "web02" })?.hostname == "webpool.internal")
        let jumpbox = try #require(result.hosts.first(where: { $0.alias == "jumpbox" }))
        #expect(jumpbox.hostname == nil)
    }

    // MARK: - File I/O

    @Test func missingFileReturnsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nonexistent-config")
        let result = try SSHConfigHosts.load(from: url)
        #expect(result.hosts.isEmpty)
    }

    @Test func loadFromFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        try """
        Host db01
            Hostname db1.internal
        Host web01 web02
        """.write(to: url, atomically: true, encoding: .utf8)

        let result = try SSHConfigHosts.load(from: url)
        #expect(result.hosts.count == 3)
        #expect(result.hosts.map(\.alias) == ["db01", "web01", "web02"])
        #expect(result.hosts[0].hostname == "db1.internal")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tongyou-ssh-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }
}
