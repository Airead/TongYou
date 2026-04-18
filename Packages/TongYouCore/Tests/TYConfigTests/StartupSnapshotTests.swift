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
        #expect(snap.initialX == nil)
        #expect(snap.initialY == nil)
        #expect(snap.initialWidth == nil)
        #expect(snap.initialHeight == nil)
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

    // MARK: - Int parsing

    @Test func initialGeometryParsedAsInt() {
        var warnings: [String] = []
        let resolved = ResolvedStartupFields(
            initialX: "100",
            initialY: "-50",
            initialWidth: "800",
            initialHeight: "600"
        )
        let snap = StartupSnapshot(from: resolved, warnings: &warnings)
        #expect(snap.initialX == 100)
        #expect(snap.initialY == -50)
        #expect(snap.initialWidth == 800)
        #expect(snap.initialHeight == 600)
        #expect(warnings.isEmpty)
    }

    @Test func nonIntegerInitialValuesProduceWarnings() {
        var warnings: [String] = []
        let resolved = ResolvedStartupFields(
            initialX: "wide",
            initialWidth: "12.5"
        )
        let snap = StartupSnapshot(from: resolved, warnings: &warnings)
        #expect(snap.initialX == nil)
        #expect(snap.initialWidth == nil)
        #expect(warnings.contains { $0.contains("initial-x") && $0.contains("wide") })
        #expect(warnings.contains { $0.contains("initial-width") && $0.contains("12.5") })
    }

    // MARK: - Equality

    @Test func equalityCheckCoversAllFields() {
        let a = StartupSnapshot(
            command: "bash", args: ["-c", "echo"], cwd: "/tmp",
            env: [EnvVar(key: "K", value: "v")],
            closeOnExit: true,
            initialX: 1, initialY: 2, initialWidth: 3, initialHeight: 4
        )
        var b = a
        #expect(a == b)
        b.args = ["-c"]
        #expect(a != b)
    }

    // MARK: - Combined end-to-end

    @Test func endToEndFromResolvedProfile() throws {
        // Simulate what ProfileMerger.resolve would return.
        let resolved = ResolvedStartupFields(
            command: "/bin/bash",
            args: ["-l"],
            cwd: "~",
            env: [(key: "LANG", value: "en_US.UTF-8")],
            closeOnExit: "false",
            initialX: "10",
            initialY: "20",
            initialWidth: "100",
            initialHeight: "200"
        )
        var warnings: [String] = []
        let snap = StartupSnapshot(from: resolved, warnings: &warnings)

        #expect(snap.command == "/bin/bash")
        #expect(snap.args == ["-l"])
        #expect(snap.cwd == "~")
        #expect(snap.env == [EnvVar(key: "LANG", value: "en_US.UTF-8")])
        #expect(snap.closeOnExit == false)
        #expect(snap.initialX == 10)
        #expect(snap.initialY == 20)
        #expect(snap.initialWidth == 100)
        #expect(snap.initialHeight == 200)
        #expect(warnings.isEmpty)
    }
}
