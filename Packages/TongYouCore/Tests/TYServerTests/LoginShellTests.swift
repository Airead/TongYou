import Testing
import Foundation
@testable import TYServer

@Suite("LoginShell Tests")
struct LoginShellTests {

    @Test func escapeWrapsInSingleQuotes() {
        #expect(LoginShell.escape("hello") == "'hello'")
        #expect(LoginShell.escape("") == "''")
    }

    @Test func escapeHandlesEmbeddedSingleQuote() {
        // 'it'\''s' is the canonical POSIX-safe encoding for it's.
        #expect(LoginShell.escape("it's") == #"'it'\''s'"#)
    }

    @Test func escapePreservesShellMetacharacters() {
        // Single-quoting disables shell interpretation — these stay literal.
        #expect(LoginShell.escape("$HOME && rm -rf /") == "'$HOME && rm -rf /'")
    }

    @Test func wrapUsesLoginShellFlagsAndEscapesCommand() {
        let wrapped = LoginShell.wrap(
            command: "/bin/ls",
            arguments: ["-la", "/tmp"],
            expandTilde: false
        )
        #expect(wrapped.arguments.count == 3)
        #expect(wrapped.arguments[0] == "-l")
        #expect(wrapped.arguments[1] == "-c")
        #expect(wrapped.arguments[2] == "exec '/bin/ls' '-la' '/tmp'")
    }

    @Test func wrapExpandsTildeWhenRequested() {
        let wrapped = LoginShell.wrap(command: "~/bin/tool", expandTilde: true)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        #expect(wrapped.arguments[2] == "exec '\(home)/bin/tool'")
    }

    @Test func wrapLeavesTildeAloneWhenDisabled() {
        let wrapped = LoginShell.wrap(command: "~/bin/tool", expandTilde: false)
        #expect(wrapped.arguments[2] == "exec '~/bin/tool'")
    }

    @Test func wrapRespectsDefaultShellWhenEnvUnset() {
        // We can't safely unset $SHELL at test time, so exercise the API
        // shape only: when $SHELL is set (the common case), the default
        // shell argument is ignored.
        let wrapped = LoginShell.wrap(
            command: "/bin/echo",
            expandTilde: false,
            defaultShell: "/does-not-exist"
        )
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/does-not-exist"
        if let envShell = ProcessInfo.processInfo.environment["SHELL"], !envShell.isEmpty {
            #expect(wrapped.command == shell)
        } else {
            #expect(wrapped.command == "/does-not-exist")
        }
    }

    @Test func workingDirectoryPrefersExplicit() {
        let cwd = WorkingDirectory.resolved(preferred: "/explicit", defaultCwd: "/config")
        #expect(cwd == "/explicit")
    }

    @Test func workingDirectoryFallsBackToDefault() {
        let cwd = WorkingDirectory.resolved(preferred: nil, defaultCwd: "/config")
        #expect(cwd == "/config")
    }

    @Test func workingDirectoryFallsBackToHomeThenRoot() {
        // HOME is set in nearly every test environment; ensure we either
        // land on HOME or (if unset) on "/".
        let cwd = WorkingDirectory.resolved(preferred: nil, defaultCwd: nil)
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            #expect(cwd == home)
        } else {
            #expect(cwd == "/")
        }
    }
}
