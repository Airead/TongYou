import Testing
import Foundation
@testable import TYConfig

@Suite("ProfileLoader", .serialized)
struct ProfileLoaderTests {

    // MARK: - Loading

    @Test func loadsSingleProfile() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: "solo", """
        font-size = 14
        command = /bin/zsh
        """)

        let loader = ProfileLoader(directory: dir)
        try loader.reload()

        let raw = try #require(loader.rawProfile(id: "solo"))
        #expect(raw.id == "solo")
        #expect(raw.extendsID == nil)
        #expect(raw.entries.count == 2)
        #expect(raw.entries.contains { $0.key == "font-size" && $0.value == "14" })
        #expect(raw.entries.contains { $0.key == "command" && $0.value == "/bin/zsh" })
    }

    @Test func extractsExtendsAndStripsIt() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: "child", """
        extends = parent
        font-size = 18
        """)

        let loader = ProfileLoader(directory: dir)
        try loader.reload()

        let raw = try #require(loader.rawProfile(id: "child"))
        #expect(raw.extendsID == "parent")
        #expect(raw.entries.count == 1)
        #expect(raw.entries[0].key == "font-size")
        #expect(!raw.entries.contains { $0.key == FieldRegistry.extendsKey })
    }

    @Test func lastExtendsWins() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: "child", """
        extends = first
        font-size = 14
        extends = second
        """)

        let loader = ProfileLoader(directory: dir)
        try loader.reload()

        let raw = try #require(loader.rawProfile(id: "child"))
        #expect(raw.extendsID == "second")
    }

    @Test func emptyExtendsClearsParent() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: "child", """
        extends = parent
        extends =
        """)

        let loader = ProfileLoader(directory: dir)
        try loader.reload()

        let raw = try #require(loader.rawProfile(id: "child"))
        #expect(raw.extendsID == nil)
    }

    @Test func builtInDefaultPresentWhenNoFile() throws {
        let dir = try makeTempProfilesDir()
        let loader = ProfileLoader(directory: dir)
        try loader.reload()

        let raw = try #require(loader.rawProfile(id: ProfileLoader.defaultProfileID))
        #expect(raw.entries.isEmpty)
        #expect(raw.extendsID == nil)
    }

    @Test func userDefaultFileOverridesBuiltIn() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: ProfileLoader.defaultProfileID, """
        font-size = 16
        """)

        let loader = ProfileLoader(directory: dir)
        try loader.reload()

        let raw = try #require(loader.rawProfile(id: ProfileLoader.defaultProfileID))
        #expect(raw.entries.count == 1)
        #expect(raw.entries[0].value == "16")
    }

    @Test func missingDirectoryTolerated() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tongyou-missing-\(UUID().uuidString)")
        let loader = ProfileLoader(directory: dir)
        try loader.reload()
        // Built-in default still available.
        #expect(loader.rawProfile(id: ProfileLoader.defaultProfileID) != nil)
        #expect(loader.rawProfile(id: "anything") == nil)
    }

    @Test func nonTxtFilesIgnored() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: "good", "font-size = 14")

        let noise = dir.appendingPathComponent("README.md")
        try "not a profile".write(to: noise, atomically: true, encoding: .utf8)

        let loader = ProfileLoader(directory: dir)
        try loader.reload()
        #expect(loader.rawProfile(id: "good") != nil)
        #expect(loader.rawProfile(id: "README") == nil)
    }

    @Test func reloadRefreshesContents() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: "x", "font-size = 14")
        let loader = ProfileLoader(directory: dir)
        try loader.reload()
        #expect(loader.rawProfile(id: "x")?.entries.first?.value == "14")

        try writeProfile(dir: dir, id: "x", "font-size = 22")
        try loader.reload()
        #expect(loader.rawProfile(id: "x")?.entries.first?.value == "22")
    }

    @Test func allRawProfilesLists() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: "a", "font-size = 12")
        try writeProfile(dir: dir, id: "b", "font-size = 14")

        let loader = ProfileLoader(directory: dir)
        try loader.reload()

        let all = loader.allRawProfiles
        // `default` is auto-synthesised on top of the two files.
        #expect(Set(all.keys) == Set(["a", "b", ProfileLoader.defaultProfileID]))
    }

    // MARK: - Live field cache + invalidation (Phase 3)

    @Test func resolvedLiveCachesByProfileID() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: "a", """
        font-size = 18
        palette-0 = ffffff
        """)
        let loader = ProfileLoader(directory: dir)
        try loader.reload()

        let first = loader.resolvedLive(id: "a")
        let second = loader.resolvedLive(id: "a")
        #expect(first == second)
        #expect(first.scalars["font-size"] == "18")
        #expect(first.maps["palette"]?["0"] == "ffffff")
    }

    @Test func invalidatePropagatesToExtendsDownstream() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: "base", "font-size = 12")
        try writeProfile(dir: dir, id: "mid", """
        extends = base
        theme = iterm2-dark-background
        """)
        try writeProfile(dir: dir, id: "leaf", """
        extends = mid
        palette-0 = 111111
        """)

        let loader = ProfileLoader(directory: dir)
        try loader.reload()
        _ = loader.resolvedLive(id: "base")
        _ = loader.resolvedLive(id: "mid")
        _ = loader.resolvedLive(id: "leaf")

        let affected = loader.invalidate(profileIDs: ["base"])
        #expect(affected.contains("base"))
        #expect(affected.contains("mid"))
        #expect(affected.contains("leaf"))
    }

    @Test func onProfilesChangedFiresWithFullDownstream() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: "base", "font-size = 12")
        try writeProfile(dir: dir, id: "mid", """
        extends = base
        font-size = 14
        """)
        try writeProfile(dir: dir, id: "leaf", """
        extends = mid
        font-size = 16
        """)

        let loader = ProfileLoader(directory: dir)
        try loader.reload()

        var received: Set<String>?
        loader.onProfilesChanged = { ids in
            received = ids
        }

        _ = loader.invalidate(profileIDs: ["base"])

        let got = try #require(received)
        #expect(got == Set(["base", "mid", "leaf"]))
    }

    @Test func invalidatedProfileResolvesFreshAfterReload() throws {
        let dir = try makeTempProfilesDir()
        try writeProfile(dir: dir, id: "x", "font-size = 14")
        let loader = ProfileLoader(directory: dir)
        try loader.reload()
        #expect(loader.resolvedLive(id: "x").scalars["font-size"] == "14")

        try writeProfile(dir: dir, id: "x", "font-size = 22")
        try loader.reload()
        // reload() clears the cache; the next lookup should see the new value
        // without needing an explicit invalidate call.
        #expect(loader.resolvedLive(id: "x").scalars["font-size"] == "22")
    }

    @Test func resolvedLiveReturnsEmptyForUnknownProfile() throws {
        let dir = try makeTempProfilesDir()
        let loader = ProfileLoader(directory: dir)
        try loader.reload()

        let live = loader.resolvedLive(id: "never-existed")
        #expect(live.scalars.isEmpty)
        #expect(live.lists.isEmpty)
        #expect(live.maps.isEmpty)
    }

    @Test func liveFieldsAsEntriesRoundTripsScalarsAndPalette() throws {
        let live = ResolvedLiveFields(
            scalars: ["font-size": "18", "theme": "iterm2-dark-background"],
            lists: [:],
            maps: ["palette": ["0": "111111", "1": "222222"]]
        )
        let entries = live.asEntries()

        #expect(entries.contains { $0.key == "font-size" && $0.value == "18" })
        #expect(entries.contains { $0.key == "theme" && $0.value == "iterm2-dark-background" })
        #expect(entries.contains { $0.key == "palette-0" && $0.value == "111111" })
        #expect(entries.contains { $0.key == "palette-1" && $0.value == "222222" })
    }

    // MARK: - Helpers

    private func makeTempProfilesDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tongyou-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    private func writeProfile(dir: URL, id: String, _ content: String) throws {
        let url = dir.appendingPathComponent("\(id).txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
