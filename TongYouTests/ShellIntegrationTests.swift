import Foundation
import Testing
import TYShell
import TYTerminal
@testable import TongYou

@Suite("ShellIntegration")
struct ShellIntegrationTests {

    @Test func zshScriptContainsPreexecHook() {
        let script = ShellIntegration.zsh
        #expect(script.contains("__tongyou_preexec"))
        #expect(script.contains("add-zsh-hook preexec"))
    }

    @Test func zshScriptContainsPrecmdHook() {
        let script = ShellIntegration.zsh
        #expect(script.contains("__tongyou_precmd"))
        #expect(script.contains("add-zsh-hook precmd"))
    }

    @Test func zshScriptSendsOSC7727RunningCommand() {
        let script = ShellIntegration.zsh
        #expect(script.contains("7727;running-command="))
    }

    @Test func zshScriptSendsOSC7727ShellPrompt() {
        let script = ShellIntegration.zsh
        #expect(script.contains("7727;shell-prompt"))
    }

    // MARK: - Injector (uses temp directory)

    private func withTempDir(_ body: (String) throws -> Void) throws {
        let dir = NSTemporaryDirectory() + "tongyou-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try body(dir)
    }

    @Test func injectorSetsZdotdir() throws {
        try withTempDir { dir in
            var env: [String: String] = ["HOME": "/tmp/test-home"]
            ShellIntegrationInjector.injectZsh(into: &env, baseDir: dir)

            #expect(env["ZDOTDIR"] == dir + "/zsh")
            #expect(env["TONGYOU_ORIG_ZDOTDIR"] == "")
        }
    }

    @Test func injectorPreservesOriginalZdotdir() throws {
        try withTempDir { dir in
            var env: [String: String] = [
                "HOME": "/tmp/test-home",
                "ZDOTDIR": "/custom/zdotdir",
            ]
            ShellIntegrationInjector.injectZsh(into: &env, baseDir: dir)

            #expect(env["TONGYOU_ORIG_ZDOTDIR"] == "/custom/zdotdir")
        }
    }

    @Test func injectorWritesIntegrationScript() throws {
        try withTempDir { dir in
            var env: [String: String] = ["HOME": "/tmp/test-home"]
            ShellIntegrationInjector.injectZsh(into: &env, baseDir: dir)

            let content = try String(contentsOfFile: dir + "/shell-integration.zsh", encoding: .utf8)
            #expect(content == ShellIntegration.zsh)
        }
    }

    @Test func injectorWritesZshenvWrapper() throws {
        try withTempDir { dir in
            var env: [String: String] = ["HOME": "/tmp/test-home"]
            ShellIntegrationInjector.injectZsh(into: &env, baseDir: dir)

            let content = try String(contentsOfFile: dir + "/zsh/.zshenv", encoding: .utf8)
            #expect(content.contains("shell-integration.zsh"))
            #expect(content.contains("unset ZDOTDIR"))
        }
    }

    @Test func injectorEscapesSingleQuotesInZdotdir() throws {
        try withTempDir { dir in
            var env: [String: String] = [
                "HOME": "/tmp/test-home",
                "ZDOTDIR": "/path/with'quote",
            ]
            ShellIntegrationInjector.injectZsh(into: &env, baseDir: dir)

            let content = try String(contentsOfFile: dir + "/zsh/.zshenv", encoding: .utf8)
            // Single quote should be escaped as '\''
            #expect(content.contains("'\\''"))
            #expect(!content.contains("with'quote'"))
        }
    }
}
