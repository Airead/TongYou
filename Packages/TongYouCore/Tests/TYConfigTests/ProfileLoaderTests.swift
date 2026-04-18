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
