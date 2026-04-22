import Foundation
import Testing
@testable import TongYou

/// Exercises `ConfigLoader.seedProfiles(into:)` in isolation against
/// a per-test temporary directory, so the user's real `~/.config/tongyou`
/// is never touched (mandatory per CLAUDE.md testing rules).
@Suite("Profile template seeding", .serialized)
struct SSHTemplateSeedingTests {

    @Test func seedsDefaultsWhenMissing() throws {
        let env = makeEnv()
        defer { env.cleanup() }

        ConfigLoader.seedProfiles(into: env.directory)

        // All expected files should now exist under the injected dir.
        for relative in Self.expectedTemplates {
            let url = env.directory.appendingPathComponent(relative)
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "expected seeded file at \(relative)")
        }

        // And they should contain non-empty, real template content —
        // i.e. the bundle / dev-tree lookup actually found something.
        let sshContent = try String(
            contentsOf: env.directory.appendingPathComponent("profiles/ssh.txt"),
            encoding: .utf8
        )
        #expect(sshContent.contains("${CMDPLT_SSH_HOST}"))

        let prodContent = try String(
            contentsOf: env.directory.appendingPathComponent("profiles/ssh-prod.txt"),
            encoding: .utf8
        )
        #expect(prodContent.contains("extends = ssh"))
        #expect(prodContent.contains("background = 4a1818"))

        let rulesContent = try String(
            contentsOf: env.directory.appendingPathComponent("ssh-rules.txt"),
            encoding: .utf8
        )
        #expect(rulesContent.contains("First matching rule wins"))

        // The default profile should also be seeded as a commented skeleton.
        let defaultContent = try String(
            contentsOf: env.directory.appendingPathComponent("profiles/default.txt"),
            encoding: .utf8
        )
        #expect(defaultContent.contains("TongYou default profile"))
        // The skeleton intentionally leaves `command` commented out so the
        // runtime falls back to `$SHELL` — guard against a future edit that
        // accidentally hard-codes a shell path.
        #expect(!defaultContent.contains("\ncommand ="))
    }

    @Test func doesNotOverwriteExistingFiles() throws {
        let env = makeEnv()
        defer { env.cleanup() }

        // Pre-create the profiles dir + user-edited ssh.txt / default.txt / ssh-rules.txt.
        let profilesDir = env.directory.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profilesDir, withIntermediateDirectories: true
        )
        let customSSH = "# user override\ncommand = /usr/local/bin/ssh\n"
        let customDefault = "# user default\ncommand = /bin/fish\n"
        let customRules = "# my rules\nssh-prod *.mine.io\n"
        try customSSH.write(
            to: profilesDir.appendingPathComponent("ssh.txt"),
            atomically: true, encoding: .utf8
        )
        try customDefault.write(
            to: profilesDir.appendingPathComponent("default.txt"),
            atomically: true, encoding: .utf8
        )
        try customRules.write(
            to: env.directory.appendingPathComponent("ssh-rules.txt"),
            atomically: true, encoding: .utf8
        )

        ConfigLoader.seedProfiles(into: env.directory)

        // User-edited files must be preserved verbatim.
        let sshContent = try String(
            contentsOf: profilesDir.appendingPathComponent("ssh.txt"),
            encoding: .utf8
        )
        #expect(sshContent == customSSH)

        let defaultContent = try String(
            contentsOf: profilesDir.appendingPathComponent("default.txt"),
            encoding: .utf8
        )
        #expect(defaultContent == customDefault)

        let rulesContent = try String(
            contentsOf: env.directory.appendingPathComponent("ssh-rules.txt"),
            encoding: .utf8
        )
        #expect(rulesContent == customRules)

        // Missing templates (dev + prod) should still be seeded.
        let devExists = FileManager.default.fileExists(
            atPath: profilesDir.appendingPathComponent("ssh-dev.txt").path
        )
        let prodExists = FileManager.default.fileExists(
            atPath: profilesDir.appendingPathComponent("ssh-prod.txt").path
        )
        #expect(devExists)
        #expect(prodExists)
    }

    @Test func seedingCreatesProfilesSubdirWhenMissing() {
        let env = makeEnv()
        defer { env.cleanup() }

        let profilesDir = env.directory.appendingPathComponent("profiles", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: profilesDir.path))

        ConfigLoader.seedProfiles(into: env.directory)

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: profilesDir.path, isDirectory: &isDir)
        #expect(exists && isDir.boolValue)
    }

    // MARK: - Helpers

    private static let expectedTemplates: [String] = [
        "profiles/default.txt",
        "profiles/ssh.txt",
        "profiles/ssh-dev.txt",
        "profiles/ssh-prod.txt",
        "ssh-rules.txt",
    ]

    private struct Env {
        let directory: URL
        let cleanup: @Sendable () -> Void
    }

    private func makeEnv() -> Env {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tongyou-seed-\(UUID().uuidString)", isDirectory: true)
        return Env(
            directory: dir,
            cleanup: { try? FileManager.default.removeItem(at: dir) }
        )
    }
}
