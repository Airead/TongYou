import Foundation
import Testing
import TYProtocol
import TYServer
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

    // MARK: - TY_TEST_PROFILE fallback (Phase 4 semantics)

    /// Phase 4 changed TY_TEST_PROFILE from an unconditional override to
    /// a fallback that only fires when the caller did not supply a
    /// profileID. Explicit callers always win so inheritance chains
    /// (split, new tab) stay observable under the env var.
    @Test func testProfileEnvIgnoredWhenCallerIsExplicit() throws {
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

        let pane = mgr.createPane(profileID: "other")
        #expect(pane.profileID == "other")
        #expect(pane.startupSnapshot.command == "/bin/bash")
    }

    @Test func testProfileEnvAppliesWhenCallerIsNil() throws {
        setenv("TY_TEST_PROFILE", "forced", 1)
        defer { unsetenv("TY_TEST_PROFILE") }

        let mgr = try makeManager(profiles: [
            "forced": """
            command = /bin/echo
            args = forced
            """
        ])

        let pane = mgr.createPane() // profileID nil → env var fallback
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

    /// Phase 4: new tabs use `default` — they do NOT inherit from the
    /// TY_TEST_PROFILE env var (which only fires on session creation).
    /// This keeps `tongyou new-tab` under a "test-ssh" app launch
    /// producing a default shell rather than another ssh session.
    @Test func createTabIgnoresTestProfileEnv() throws {
        setenv("TY_TEST_PROFILE", "marked", 1)
        defer { unsetenv("TY_TEST_PROFILE") }

        let mgr = try makeManager(profiles: [
            "marked": "command = /bin/bash"
        ])
        _ = mgr.createSession(name: "s")
        _ = mgr.createTab(title: "t2")

        let tabs = mgr.sessions[0].tabs
        #expect(tabs.count == 2)
        // First tab inherits TY_TEST_PROFILE (session-level bootstrap).
        #expect(tabs.first?.paneTree.firstPane.profileID == "marked")
        // Second tab explicitly uses `default`, unaffected by the env.
        #expect(tabs.last?.paneTree.firstPane.profileID == TerminalPane.defaultProfileID)
        #expect(tabs.last?.paneTree.firstPane.startupSnapshot.command == nil)
    }

    @Test func createTabUsesExplicitProfileWhenProvided() throws {
        let mgr = try makeManager(profiles: [
            "custom": "command = /usr/bin/fish"
        ])
        _ = mgr.createSession(name: "s")
        _ = mgr.createTab(title: "t2", profileID: "custom")

        let tab = try #require(mgr.sessions[0].tabs.last)
        #expect(tab.paneTree.firstPane.profileID == "custom")
        #expect(tab.paneTree.firstPane.startupSnapshot.command == "/usr/bin/fish")
    }

    // MARK: - Phase 4: split inherits parent profile

    /// When the session's root pane was bootstrapped from a non-default
    /// profile (here via TY_TEST_PROFILE), splitting it produces a child
    /// carrying the same profileID and startup fields.
    @Test func splitPaneInheritsParentProfile() throws {
        setenv("TY_TEST_PROFILE", "custom", 1)
        defer { unsetenv("TY_TEST_PROFILE") }

        let mgr = try makeManager(profiles: [
            "custom": """
            command = /bin/bash
            env = TY_CUSTOM=1
            """
        ])
        let sessionID = mgr.createSession(name: "s")
        let rootPaneID = try #require(mgr.sessions.first?.tabs.first?.paneTree.firstPane.id)

        let newPaneID = try #require(
            mgr.splitPane(
                inSessionID: sessionID,
                parentPaneID: rootPaneID,
                direction: .vertical
            )
        )
        let child = try #require(mgr.findPane(id: newPaneID))
        #expect(child.profileID == "custom")
        #expect(child.startupSnapshot.command == "/bin/bash")
        let env = Dictionary(uniqueKeysWithValues: child.startupSnapshot.envTuples)
        #expect(env["TY_CUSTOM"] == "1")
    }

    @Test func splitPaneExplicitProfileOverridesInheritance() throws {
        setenv("TY_TEST_PROFILE", "parent", 1)
        defer { unsetenv("TY_TEST_PROFILE") }

        let mgr = try makeManager(profiles: [
            "parent": "command = /bin/bash",
            "child": "command = /usr/bin/fish"
        ])
        let sessionID = mgr.createSession(name: "s")
        let rootPaneID = try #require(mgr.sessions.first?.tabs.first?.paneTree.firstPane.id)

        let newPaneID = try #require(
            mgr.splitPane(
                inSessionID: sessionID,
                parentPaneID: rootPaneID,
                direction: .horizontal,
                profileID: "child"
            )
        )
        let child = try #require(mgr.findPane(id: newPaneID))
        #expect(child.profileID == "child")
        #expect(child.startupSnapshot.command == "/usr/bin/fish")
    }

    // MARK: - Phase 4: floating pane inherits active pane

    // MARK: - Phase 5: tryResolveProfile seam

    @Test func tryResolveProfileSucceedsForKnownProfile() throws {
        let mgr = try makeManager(profiles: [
            "ok": "command = /bin/bash"
        ])
        try mgr.tryResolveProfile(id: "ok")
    }

    @Test func tryResolveProfileThrowsForUnknownProfile() throws {
        let mgr = try makeManager()
        #expect(throws: ProfileResolveError.self) {
            try mgr.tryResolveProfile(id: "does-not-exist")
        }
    }

    @Test func tryResolveProfileThrowsForInvalidOverride() throws {
        let mgr = try makeManager(profiles: [
            "ok": "command = /bin/bash"
        ])
        #expect(throws: ProfileResolveError.self) {
            try mgr.tryResolveProfile(id: "ok", overrides: ["no-equals-sign"])
        }
    }

    @Test func createFloatingPaneInheritsActivePaneProfile() throws {
        setenv("TY_TEST_PROFILE", "custom", 1)
        defer { unsetenv("TY_TEST_PROFILE") }

        let mgr = try makeManager(profiles: [
            "custom": "command = /bin/bash"
        ])
        _ = mgr.createSession(name: "s")

        let floatID = try #require(mgr.createFloatingPane())
        let floatPane = try #require(mgr.findPane(id: floatID))
        #expect(floatPane.profileID == "custom")
        #expect(floatPane.startupSnapshot.command == "/bin/bash")
    }

    // MARK: - Phase 7.3: resolveRemoteStartupBundle

    @Test func remoteBundlePackagesCommandAndEnv() throws {
        let mgr = try makeManager(profiles: [
            "ci": """
            command = /usr/bin/env
            args = -i
            env = TY_CI=1
            close-on-exit = false
            """
        ])
        let bundle = mgr.resolveRemoteStartupBundle(
            profileID: "ci",
            overrides: [],
            initialWorkingDirectory: nil
        )
        #expect(bundle.profileID == "ci")
        #expect(bundle.snapshot?.command == "/usr/bin/env")
        #expect(bundle.snapshot?.args == ["-i"])
        #expect(bundle.snapshot?.closeOnExit == false)
        let env = Dictionary(uniqueKeysWithValues: bundle.snapshot?.envTuples ?? [])
        #expect(env["TY_CI"] == "1")
        #expect(bundle.frameHint == nil)
    }

    @Test func remoteBundleProducesFrameHintFromInitialFields() throws {
        let mgr = try makeManager(profiles: [
            "floaty": """
            command = /bin/bash
            initial-x = 0.1
            initial-y = 0.2
            initial-width = 0.5
            initial-height = 0.3
            """
        ])
        let bundle = mgr.resolveRemoteStartupBundle(
            profileID: "floaty",
            overrides: [],
            initialWorkingDirectory: nil
        )
        #expect(bundle.frameHint == FloatFrameHint(x: 0.1, y: 0.2, width: 0.5, height: 0.3))
    }

    @Test func remoteBundleOverridesFoldIntoSnapshot() throws {
        let mgr = try makeManager(profiles: [
            "ci": "command = /bin/bash"
        ])
        let bundle = mgr.resolveRemoteStartupBundle(
            profileID: "ci",
            overrides: ["env=EXTRA=yes"],
            initialWorkingDirectory: nil
        )
        let env = Dictionary(uniqueKeysWithValues: bundle.snapshot?.envTuples ?? [])
        #expect(env["EXTRA"] == "yes")
    }

    @Test func remoteBundleCwdFallsBackToCallerSupplied() throws {
        let mgr = try makeManager(profiles: [
            "ci": "command = /bin/bash"
        ])
        let bundle = mgr.resolveRemoteStartupBundle(
            profileID: "ci",
            overrides: [],
            initialWorkingDirectory: "/tmp/remote-test"
        )
        #expect(bundle.snapshot?.cwd == "/tmp/remote-test")
    }

    @Test func remoteBundleFallsBackToNilOnUnknownProfile() throws {
        let mgr = try makeManager()
        let bundle = mgr.resolveRemoteStartupBundle(
            profileID: "does-not-exist",
            overrides: [],
            initialWorkingDirectory: nil
        )
        #expect(bundle.profileID == nil)
        #expect(bundle.snapshot == nil)
        #expect(bundle.frameHint == nil)
    }

    // MARK: - Phase 8: remote closeOnExit mirrored onto TerminalPane

    @Test func remoteLayoutUpdateMirrorsCloseOnExitOntoTreePane() throws {
        let mgr = try makeManager()
        let sessionID = SessionID()
        let tabID = TabID()
        let paneID = PaneID()

        mgr.addOrUpdateRemoteSession(SessionInfo(id: sessionID, name: "remote"))

        let info = SessionInfo(
            id: sessionID,
            name: "remote",
            tabs: [TabInfo(id: tabID, title: "t", layout: .leaf(paneID))],
            activeTabIndex: 0,
            paneMetadata: [
                paneID: RemotePaneMetadata(
                    cwd: nil,
                    profileID: "default",
                    closeOnExit: false
                )
            ]
        )
        _ = mgr.handleRemoteLayoutUpdate(info)

        let session = mgr.sessions.first { $0.id == sessionID.uuid }
        #expect(session != nil)
        let mirrored = session?.tabs.first?.paneTree.firstPane
        #expect(mirrored?.startupSnapshot.closeOnExit == false)
    }

    @Test func remoteLayoutUpdateWithoutCloseOnExitLeavesSnapshotUnspecified() throws {
        let mgr = try makeManager()
        let sessionID = SessionID()
        let tabID = TabID()
        let paneID = PaneID()

        mgr.addOrUpdateRemoteSession(SessionInfo(id: sessionID, name: "remote"))

        let info = SessionInfo(
            id: sessionID,
            name: "remote",
            tabs: [TabInfo(id: tabID, title: "t", layout: .leaf(paneID))],
            activeTabIndex: 0,
            paneMetadata: [
                paneID: RemotePaneMetadata(cwd: nil, profileID: "default", closeOnExit: nil)
            ]
        )
        _ = mgr.handleRemoteLayoutUpdate(info)

        let session = mgr.sessions.first { $0.id == sessionID.uuid }
        let mirrored = session?.tabs.first?.paneTree.firstPane
        #expect(mirrored?.startupSnapshot.closeOnExit == nil)
    }
}
