import Foundation
import Testing
import TYConfig
import TYServer
import TYTerminal
@testable import TongYou

@Suite("SessionManager Profile", .serialized)
struct SessionManagerProfileTests {

    // MARK: - Test harness

    private func makeStore() -> SessionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        return SessionStore(directory: dir)
    }

    /// Creates an isolated profiles directory, writes the given `<id>.txt`
    /// files into it, and returns a `SessionManager` wired to a loader
    /// pointed at that directory. No real-user paths are touched.
    private func makeManager(profiles: [String: String] = [:]) throws -> SessionManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tongyou-profile-sm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        for (id, content) in profiles {
            let url = dir.appendingPathComponent("\(id).txt")
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let loader = ProfileLoader(directory: dir)
        return SessionManager(
            localSessionStore: makeStore(),
            profileLoader: loader
        )
    }

    // MARK: - Default

    @Test func createPaneWithNoProfileProducesEmptySnapshot() throws {
        let mgr = try makeManager()
        let pane = mgr.createPane()
        #expect(pane.profileID == TerminalPane.defaultProfileID)
        #expect(pane.startupSnapshot.command == nil)
        #expect(pane.startupSnapshot.args.isEmpty)
        #expect(pane.startupSnapshot.env.isEmpty)
        #expect(pane.startupSnapshot.closeOnExit == nil)
    }

    @Test func callerCwdFillsWhenProfileMissesIt() throws {
        let mgr = try makeManager()
        let pane = mgr.createPane(initialWorkingDirectory: "/tmp/test")
        #expect(pane.startupSnapshot.cwd == "/tmp/test")
        #expect(pane.initialWorkingDirectory == "/tmp/test")
    }

    // MARK: - Explicit profile

    @Test func explicitProfilePopulatesSnapshot() throws {
        let mgr = try makeManager(profiles: [
            "ssh-box": """
            command = /usr/bin/ssh
            args = -p
            args = 2222
            args = user@host
            env = TY_MARKER=ssh-box
            close-on-exit = false
            """
        ])
        let pane = mgr.createPane(profileID: "ssh-box")
        #expect(pane.profileID == "ssh-box")
        #expect(pane.startupSnapshot.command == "/usr/bin/ssh")
        #expect(pane.startupSnapshot.args == ["-p", "2222", "user@host"])
        let env = Dictionary(uniqueKeysWithValues: pane.startupSnapshot.envTuples)
        #expect(env["TY_MARKER"] == "ssh-box")
        #expect(pane.startupSnapshot.closeOnExit == false)
    }

    @Test func overridesAppliedOnTop() throws {
        let mgr = try makeManager(profiles: [
            "base": """
            command = /bin/bash
            env = FOO=1
            """
        ])
        let pane = mgr.createPane(
            profileID: "base",
            overrides: [
                "env = BAR=2",
                "args = -l"
            ]
        )
        let env = Dictionary(uniqueKeysWithValues: pane.startupSnapshot.envTuples)
        #expect(env["FOO"] == "1")
        #expect(env["BAR"] == "2")
        #expect(pane.startupSnapshot.args == ["-l"])
    }

    // MARK: - Unknown profile fallback

    @Test func unknownProfileFallsBackToDefault() throws {
        let mgr = try makeManager()
        let pane = mgr.createPane(profileID: "does-not-exist")
        // Fallback resolves `default`, which yields an empty snapshot.
        #expect(pane.profileID == TerminalPane.defaultProfileID)
        #expect(pane.startupSnapshot.command == nil)
    }

    // MARK: - TY_TEST_PROFILE override

    @Test func testProfileEnvForcesProfile() throws {
        // The env var must be set in the current process so
        // ProcessInfo.processInfo.environment sees it. Setenv is per-process.
        setenv("TY_TEST_PROFILE", "forced", 1)
        defer { unsetenv("TY_TEST_PROFILE") }

        let mgr = try makeManager(profiles: [
            "forced": """
            command = /bin/echo
            args = forced
            """,
            "other": """
            command = /bin/bash
            """
        ])

        // Caller asks for "other" but the env var should win.
        let pane = mgr.createPane(profileID: "other")
        #expect(pane.profileID == "forced")
        #expect(pane.startupSnapshot.command == "/bin/echo")
        #expect(pane.startupSnapshot.args == ["forced"])
    }

    @Test func emptyTestProfileEnvIgnored() throws {
        setenv("TY_TEST_PROFILE", "", 1)
        defer { unsetenv("TY_TEST_PROFILE") }

        let mgr = try makeManager(profiles: [
            "real": "command = /bin/zsh"
        ])
        let pane = mgr.createPane(profileID: "real")
        #expect(pane.profileID == "real")
        #expect(pane.startupSnapshot.command == "/bin/zsh")
    }

    // MARK: - Integration: session + tab + floating pane

    @Test func createSessionFirstPaneHasSnapshot() throws {
        setenv("TY_TEST_PROFILE", "marked", 1)
        defer { unsetenv("TY_TEST_PROFILE") }

        let mgr = try makeManager(profiles: [
            "marked": """
            command = /bin/bash
            env = TY_CI=1
            """
        ])

        let sessionID = mgr.createSession(name: "t")
        let session = try #require(mgr.sessions.first(where: { $0.id == sessionID }))
        let rootPane = session.tabs.first?.paneTree.firstPane
        #expect(rootPane?.profileID == "marked")
        #expect(rootPane?.startupSnapshot.command == "/bin/bash")
        let env = Dictionary(uniqueKeysWithValues: rootPane?.startupSnapshot.envTuples ?? [])
        #expect(env["TY_CI"] == "1")
    }

    @Test func createTabFirstPaneHasSnapshot() throws {
        setenv("TY_TEST_PROFILE", "marked", 1)
        defer { unsetenv("TY_TEST_PROFILE") }

        let mgr = try makeManager(profiles: [
            "marked": "command = /bin/bash"
        ])
        _ = mgr.createSession(name: "s")
        _ = mgr.createTab(title: "t2")

        let tabs = mgr.sessions[0].tabs
        #expect(tabs.count == 2)
        #expect(tabs.last?.paneTree.firstPane.profileID == "marked")
        #expect(tabs.last?.paneTree.firstPane.startupSnapshot.command == "/bin/bash")
    }
}
