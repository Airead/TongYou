import Testing
import Foundation
@testable import TYConfig

@Suite("ProfileMerger", .serialized)
struct ProfileMergerTests {

    // MARK: - Scalars

    @Test func scalarOverrideAcrossLayers() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            font-size = 14
            theme = base-theme
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            font-size = 20
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        #expect(resolved.live.scalars["font-size"] == "20")
        #expect(resolved.live.scalars["theme"] == "base-theme")
    }

    @Test func scalarEmptyValueClears() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", "font-size = 14")
            try self.write(dir: dir, id: "leaf", """
            extends = base
            font-size =
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        #expect(resolved.live.scalars["font-size"] == nil)
    }

    @Test func startupScalarsLandOnStartupStruct() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            command = /usr/bin/ssh
            cwd = /tmp
            close-on-exit = true
            initial-x = 100
            initial-y = 200
            initial-width = 800
            initial-height = 600
            """)
        }

        let resolved = try env.merger.resolve(profileID: "p")
        #expect(resolved.startup.command == "/usr/bin/ssh")
        #expect(resolved.startup.cwd == "/tmp")
        #expect(resolved.startup.closeOnExit == "true")
        #expect(resolved.startup.initialX == "100")
        #expect(resolved.startup.initialY == "200")
        #expect(resolved.startup.initialWidth == "800")
        #expect(resolved.startup.initialHeight == "600")
    }

    // MARK: - Lists

    @Test func listReplacedAcrossLayers() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            args = a
            args = b
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            args = x
            args = y
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        #expect(resolved.startup.args == ["x", "y"])
    }

    @Test func listInheritedWhenNotTouched() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            args = a
            args = b
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            font-size = 14
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        #expect(resolved.startup.args == ["a", "b"])
    }

    @Test func listEmptyValueClears() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            args = a
            args = b
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            args =
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        #expect(resolved.startup.args == [])
    }

    @Test func listClearThenAccumulateWithinLayer() throws {
        // Plan's `fresh.txt` pattern but for the list type.
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            args = a
            args = b
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            args =
            args = only
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        #expect(resolved.startup.args == ["only"])
    }

    @Test func listAccumulatesWithinSameLayer() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            args = one
            args = two
            args = three
            """)
        }

        let resolved = try env.merger.resolve(profileID: "p")
        #expect(resolved.startup.args == ["one", "two", "three"])
    }

    // MARK: - Maps (env)

    @Test func envMapMergesSubKeysAcrossLayers() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            env = LANG=en_US.UTF-8
            env = PATH=/usr/bin:/bin
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            env = DEBUG=1
            env = PATH=/opt/bin:/usr/bin
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        let dict = Dictionary(uniqueKeysWithValues: resolved.startup.env.map { ($0.key, $0.value) })
        #expect(dict["LANG"] == "en_US.UTF-8")
        #expect(dict["PATH"] == "/opt/bin:/usr/bin")
        #expect(dict["DEBUG"] == "1")
    }

    @Test func envMapExplicitClearMatchesPlanExample() throws {
        // Plan section "显式清零": fresh extends base, clears env, then adds ONLY=this.
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            env = LANG=en_US.UTF-8
            env = PATH=/usr/bin:/bin
            """)
            try self.write(dir: dir, id: "fresh", """
            extends = base
            env =
            env = ONLY=this
            """)
        }

        let resolved = try env.merger.resolve(profileID: "fresh")
        #expect(resolved.startup.env.count == 1)
        #expect(resolved.startup.env.first?.key == "ONLY")
        #expect(resolved.startup.env.first?.value == "this")
    }

    @Test func envMapSubKeyEmptyValueSetsEmptyString() throws {
        // `env = FOO=` is a normal env assignment with an empty value — it
        // sets FOO to "" rather than removing it from the map. The full-clear
        // form is `env =` (tested in `envMapExplicitClearMatchesPlanExample`).
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            env = KEEP=yes
            env = OVERRIDE=original
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            env = OVERRIDE=
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        let dict = Dictionary(uniqueKeysWithValues: resolved.startup.env.map { ($0.key, $0.value) })
        #expect(dict["KEEP"] == "yes")
        #expect(dict["OVERRIDE"] == "")
    }

    @Test func envMalformedValueRecordsWarning() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            env = not-a-kv-pair
            """)
        }

        let resolved = try env.merger.resolve(profileID: "p")
        #expect(resolved.startup.env.isEmpty)
        #expect(resolved.warnings.contains { $0.contains("env") })
    }

    // MARK: - Maps (palette)

    @Test func paletteMergesBySubKey() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            palette-0 = 000000
            palette-1 = cd3131
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            palette-0 = 1d1f21
            palette-2 = 00ff00
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        let palette = try #require(resolved.live.maps["palette"])
        #expect(palette["0"] == "1d1f21")
        #expect(palette["1"] == "cd3131")
        #expect(palette["2"] == "00ff00")
    }

    @Test func paletteExplicitClearWipesTable() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            palette-0 = 000000
            palette-1 = cd3131
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            palette =
            palette-5 = ffffff
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        let palette = try #require(resolved.live.maps["palette"])
        #expect(palette == ["5": "ffffff"])
    }

    @Test func paletteSubKeyEmptyRemovesOnlyThatEntry() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            palette-0 = 000000
            palette-1 = cd3131
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            palette-0 =
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        let palette = try #require(resolved.live.maps["palette"])
        #expect(palette["0"] == nil)
        #expect(palette["1"] == "cd3131")
    }

    // MARK: - Overrides layer

    @Test func overridesApplyAsTopLayer() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            font-size = 14
            env = LANG=en_US.UTF-8
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            font-size = 18
            env = DEBUG=1
            """)
        }

        let resolved = try env.merger.resolve(
            profileID: "leaf",
            overrides: [
                "font-size = 20",
                "env = EXTRA=1"
            ]
        )
        #expect(resolved.live.scalars["font-size"] == "20")
        let dict = Dictionary(uniqueKeysWithValues: resolved.startup.env.map { ($0.key, $0.value) })
        #expect(dict["LANG"] == "en_US.UTF-8")
        #expect(dict["DEBUG"] == "1")
        #expect(dict["EXTRA"] == "1")
    }

    @Test func overridesCanReplaceList() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            args = a
            args = b
            """)
        }

        let resolved = try env.merger.resolve(
            profileID: "p",
            overrides: ["args = x", "args = y"]
        )
        #expect(resolved.startup.args == ["x", "y"])
    }

    @Test func overrideBlankOrCommentLinesSkipped() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", "font-size = 14")
        }

        let resolved = try env.merger.resolve(
            profileID: "p",
            overrides: [
                "",
                "# comment",
                "font-size = 22"
            ]
        )
        #expect(resolved.live.scalars["font-size"] == "22")
    }

    @Test func invalidOverrideLineThrows() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", "font-size = 14")
        }

        #expect(throws: ProfileResolveError.self) {
            try env.merger.resolve(
                profileID: "p",
                overrides: ["this has no equals"]
            )
        }
    }

    @Test func extendsInOverridesRejected() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", "font-size = 14")
            try self.write(dir: dir, id: "other", "font-size = 22")
        }

        #expect(throws: ProfileResolveError.self) {
            try env.merger.resolve(
                profileID: "p",
                overrides: ["extends = other"]
            )
        }
    }

    // MARK: - Chain errors

    @Test func circularExtendsDetected() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "a", "extends = b")
            try self.write(dir: dir, id: "b", "extends = a")
        }

        #expect(throws: ProfileResolveError.self) {
            try env.merger.resolve(profileID: "a")
        }
    }

    @Test func missingExtendsParent() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "leaf", "extends = nope")
        }

        #expect(throws: ProfileResolveError.self) {
            try env.merger.resolve(profileID: "leaf")
        }
    }

    @Test func unknownProfileIDThrows() throws {
        let env = try makeEnv { _ in }
        #expect(throws: ProfileResolveError.self) {
            try env.merger.resolve(profileID: "does-not-exist")
        }
    }

    @Test func extendsDepthExceeded() throws {
        let env = try makeEnv { dir in
            // Build a longer chain than ProfileMerger.maxExtendsDepth (10).
            for i in 0..<12 {
                let parent = i == 0 ? "" : "extends = p\(i - 1)\n"
                try self.write(dir: dir, id: "p\(i)", "\(parent)font-size = \(i)")
            }
        }

        #expect(throws: ProfileResolveError.self) {
            try env.merger.resolve(profileID: "p11")
        }
    }

    // MARK: - Unknown key

    @Test func expandVariablesFalsePreservesPlaceholders() throws {
        // Rendering-time callers ask for a profile's resolved fields without
        // having ${HOST} etc. available. They opt out of substitution by
        // passing `expandVariables: false`; undefined ${NAME} is not an
        // error in that mode, the literal stays intact, and unrelated live
        // fields (like `background`) come through cleanly.
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            command = /usr/bin/ssh
            args = ${HOST}
            description = SSH to ${HOST}
            """)
            try self.write(dir: dir, id: "dev", """
            extends = base
            background = 0a1a2e
            description = SSH dev: ${HOST}
            """)
        }

        let resolved = try env.merger.resolve(
            profileID: "dev",
            expandVariables: false
        )
        #expect(resolved.live.scalars["background"] == "0a1a2e")
        #expect(resolved.live.scalars["description"] == "SSH dev: ${HOST}")
        #expect(resolved.startup.args == ["${HOST}"])
    }

    @Test func descriptionIsRecognisedLiveScalar() throws {
        // Phase 9 seeds ssh / ssh-dev / ssh-prod profiles with a
        // `description` line. The parser must accept it without warning and
        // stash the value on the live scalars so future UI can read it.
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            description = SSH to ${HOST}
            """)
        }

        let resolved = try env.merger.resolve(
            profileID: "p",
            variables: ["HOST": "db1"]
        )
        #expect(resolved.warnings.isEmpty)
        #expect(resolved.live.scalars["description"] == "SSH to db1")
    }

    @Test func unknownKeyRecordsWarningAndIsIgnored() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            font-size = 14
            this-key-does-not-exist = whatever
            """)
        }

        let resolved = try env.merger.resolve(profileID: "p")
        #expect(resolved.live.scalars["font-size"] == "14")
        #expect(resolved.live.scalars["this-key-does-not-exist"] == nil)
        #expect(resolved.warnings.contains { $0.contains("this-key-does-not-exist") })
    }

    // MARK: - Default chain

    @Test func extendsDefaultWorksWithBuiltInDefault() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "custom", """
            extends = default
            font-size = 22
            """)
        }

        let resolved = try env.merger.resolve(profileID: "custom")
        #expect(resolved.live.scalars["font-size"] == "22")
    }

    @Test func userDefaultFileIsInChainRoot() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: ProfileLoader.defaultProfileID, """
            font-size = 14
            theme = base-theme
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = default
            font-size = 20
            """)
        }

        let resolved = try env.merger.resolve(profileID: "leaf")
        #expect(resolved.live.scalars["font-size"] == "20")
        #expect(resolved.live.scalars["theme"] == "base-theme")
    }

    // MARK: - Variable expansion

    @Test func variablesExpandInScalars() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            command = /usr/bin/${TOOL}
            cwd = /home/${USER}
            """)
        }

        let resolved = try env.merger.resolve(
            profileID: "p",
            variables: ["TOOL": "ssh", "USER": "alice"]
        )
        #expect(resolved.startup.command == "/usr/bin/ssh")
        #expect(resolved.startup.cwd == "/home/alice")
    }

    @Test func variablesExpandInLiveScalars() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            background = ${BG}
            """)
        }

        let resolved = try env.merger.resolve(
            profileID: "p",
            variables: ["BG": "1a0a0a"]
        )
        #expect(resolved.live.scalars["background"] == "1a0a0a")
    }

    @Test func variablesExpandInListItems() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            args = -t
            args = ${USER}@${HOST}
            """)
        }

        let resolved = try env.merger.resolve(
            profileID: "p",
            variables: ["USER": "bob", "HOST": "db1.example.com"]
        )
        #expect(resolved.startup.args == ["-t", "bob@db1.example.com"])
    }

    @Test func variablesExpandInEnvValues() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            env = HOSTNAME=${HOST}
            env = ${HOST}=literal-key
            """)
        }

        let resolved = try env.merger.resolve(
            profileID: "p",
            variables: ["HOST": "db1.example.com"]
        )
        let dict = Dictionary(uniqueKeysWithValues: resolved.startup.env.map { ($0.key, $0.value) })
        #expect(dict["HOSTNAME"] == "db1.example.com")
        // Env keys are not expanded — the literal `${HOST}` key stays as-is.
        #expect(dict["${HOST}"] == "literal-key")
    }

    @Test func undefinedVariableThrows() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            command = /usr/bin/ssh
            args = ${HOST}
            """)
        }

        #expect(throws: ProfileResolveError.self) {
            try env.merger.resolve(profileID: "p", variables: [:])
        }
    }

    @Test func dollarEscape() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            command = $$HOME/bin/run
            args = cost: $$5
            args = ${VAL}
            args = $5
            args = ${
            args = ${}
            """)
        }

        let resolved = try env.merger.resolve(
            profileID: "p",
            variables: ["VAL": "ok"]
        )
        #expect(resolved.startup.command == "$HOME/bin/run")
        #expect(resolved.startup.args == ["cost: $5", "ok", "$5", "${", "${}"])
    }

    @Test func variableNameIsCaseSensitive() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", "command = ${HOST}")
        }

        // Only lowercase `host` is defined — uppercase `HOST` must throw.
        #expect(throws: ProfileResolveError.self) {
            try env.merger.resolve(profileID: "p", variables: ["host": "foo"])
        }
    }

    @Test func extendsChainVariables() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "base", """
            command = /usr/bin/ssh
            args = -t
            args = ${HOST}
            """)
            try self.write(dir: dir, id: "leaf", """
            extends = base
            env = HOSTNAME=${HOST}
            """)
        }

        let resolved = try env.merger.resolve(
            profileID: "leaf",
            variables: ["HOST": "db1.example.com"]
        )
        #expect(resolved.startup.command == "/usr/bin/ssh")
        #expect(resolved.startup.args == ["-t", "db1.example.com"])
        let dict = Dictionary(uniqueKeysWithValues: resolved.startup.env.map { ($0.key, $0.value) })
        #expect(dict["HOSTNAME"] == "db1.example.com")
    }

    @Test func overrideCanReferenceVariable() throws {
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", "args = placeholder")
        }

        let resolved = try env.merger.resolve(
            profileID: "p",
            overrides: ["args = ${HOST}"],
            variables: ["HOST": "db1.example.com"]
        )
        #expect(resolved.startup.args == ["db1.example.com"])
    }

    @Test func noVariablesUsedKeepsExistingBehavior() throws {
        // Resolving without passing `variables:` (default empty) must not
        // throw for profiles that happen to contain no `${…}` placeholders.
        let env = try makeEnv { dir in
            try self.write(dir: dir, id: "p", """
            command = /usr/bin/ssh
            args = -t
            args = db1.example.com
            """)
        }

        let resolved = try env.merger.resolve(profileID: "p")
        #expect(resolved.startup.command == "/usr/bin/ssh")
        #expect(resolved.startup.args == ["-t", "db1.example.com"])
    }

    // MARK: - Helpers

    private struct Env {
        let loader: ProfileLoader
        let merger: ProfileMerger
    }

    private func makeEnv(_ setup: (URL) throws -> Void) throws -> Env {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tongyou-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        try setup(dir)
        let loader = ProfileLoader(directory: dir)
        try loader.reload()
        return Env(loader: loader, merger: ProfileMerger(loader: loader))
    }

    private func write(dir: URL, id: String, _ content: String) throws {
        let url = dir.appendingPathComponent("\(id).txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
