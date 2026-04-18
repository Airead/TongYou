import Testing
import Foundation
@testable import TYConfig

@Suite("StartupSnapshot", .serialized)
struct StartupSnapshotTests {

    // MARK: - Defaults

    @Test func defaultInitProducesEmptySnapshot() {
        let snap = StartupSnapshot()
        #expect(snap.command == nil)
        #expect(snap.args.isEmpty)
        #expect(snap.cwd == nil)
        #expect(snap.env.isEmpty)
        #expect(snap.closeOnExit == nil)
    }

    // MARK: - Factory from ResolvedStartupFields

    @Test func factoryPassesThroughCommandArgsCwd() {
        let resolved = ResolvedStartupFields(
            command: "/usr/bin/ssh",
            args: ["-p", "2222", "deploy@host"],
            cwd: "/tmp"
        )
        let snap = StartupSnapshot(from: resolved)
        #expect(snap.command == "/usr/bin/ssh")
        #expect(snap.args == ["-p", "2222", "deploy@host"])
        #expect(snap.cwd == "/tmp")
    }

    @Test func factoryPreservesEnvOrder() {
        let resolved = ResolvedStartupFields(
            env: [
                (key: "LANG", value: "en_US.UTF-8"),
                (key: "PATH", value: "/usr/bin"),
                (key: "DEBUG", value: "1")
            ]
        )
        let snap = StartupSnapshot(from: resolved)
        #expect(snap.env == [
            EnvVar(key: "LANG", value: "en_US.UTF-8"),
            EnvVar(key: "PATH", value: "/usr/bin"),
            EnvVar(key: "DEBUG", value: "1")
        ])
        #expect(snap.envTuples.map(\.0) == ["LANG", "PATH", "DEBUG"])
    }

    // MARK: - Bool parsing

    @Test func closeOnExitAcceptsTrueForms() {
        for raw in ["true", "True", "TRUE", "yes", "Yes", "1", "on", "ON"] {
            var warnings: [String] = []
            let resolved = ResolvedStartupFields(closeOnExit: raw)
            let snap = StartupSnapshot(from: resolved, warnings: &warnings)
            #expect(snap.closeOnExit == true, "input: \(raw)")
            #expect(warnings.isEmpty)
        }
    }

    @Test func closeOnExitAcceptsFalseForms() {
        for raw in ["false", "False", "no", "NO", "0", "off", "OFF"] {
            var warnings: [String] = []
            let resolved = ResolvedStartupFields(closeOnExit: raw)
            let snap = StartupSnapshot(from: resolved, warnings: &warnings)
            #expect(snap.closeOnExit == false, "input: \(raw)")
            #expect(warnings.isEmpty)
        }
    }

    @Test func closeOnExitRejectsGarbage() {
        var warnings: [String] = []
        let resolved = ResolvedStartupFields(closeOnExit: "maybe")
        let snap = StartupSnapshot(from: resolved, warnings: &warnings)
        #expect(snap.closeOnExit == nil)
        #expect(warnings.contains { $0.contains("close-on-exit") && $0.contains("maybe") })
    }

    @Test func closeOnExitNilStaysNil() {
        var warnings: [String] = []
        let resolved = ResolvedStartupFields(closeOnExit: nil)
        let snap = StartupSnapshot(from: resolved, warnings: &warnings)
        #expect(snap.closeOnExit == nil)
        #expect(warnings.isEmpty)
    }

    // MARK: - Equality

    @Test func equalityCheckCoversAllFields() {
        let a = StartupSnapshot(
            command: "bash", args: ["-c", "echo"], cwd: "/tmp",
            env: [EnvVar(key: "K", value: "v")],
            closeOnExit: true
        )
        var b = a
        #expect(a == b)
        b.args = ["-c"]
        #expect(a != b)
    }

    // MARK: - Combined end-to-end

    @Test func endToEndFromResolvedProfile() throws {
        // Simulate what ProfileMerger.resolve would return for PTY fields;
        // float-only `initial-*` fields no longer land in the snapshot.
        let resolved = ResolvedStartupFields(
            command: "/bin/bash",
            args: ["-l"],
            cwd: "~",
            env: [(key: "LANG", value: "en_US.UTF-8")],
            closeOnExit: "false"
        )
        var warnings: [String] = []
        let snap = StartupSnapshot(from: resolved, warnings: &warnings)

        #expect(snap.command == "/bin/bash")
        #expect(snap.args == ["-l"])
        #expect(snap.cwd == "~")
        #expect(snap.env == [EnvVar(key: "LANG", value: "en_US.UTF-8")])
        #expect(snap.closeOnExit == false)
        #expect(warnings.isEmpty)
    }
}
