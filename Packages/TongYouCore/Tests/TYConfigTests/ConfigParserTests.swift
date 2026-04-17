import Testing
import Foundation
@testable import TYConfig

@Suite("ConfigParser")
struct ConfigParserTests {

    private let parser = ConfigParser()

    // MARK: - Basic Parsing

    @Test func emptyFile() throws {
        let url = try writeTempConfig("")
        let entries = try parser.parse(contentsOf: url)
        #expect(entries.isEmpty)
    }

    @Test func commentsAndBlankLines() throws {
        let content = """
        # This is a comment

        # Another comment

        font-size = 14
        """
        let url = try writeTempConfig(content)
        let entries = try parser.parse(contentsOf: url)
        #expect(entries.count == 1)
        #expect(entries[0].key == "font-size")
        #expect(entries[0].value == "14")
    }

    @Test func basicKeyValue() throws {
        let content = """
        font-family = JetBrains Mono
        font-size = 16
        background = 282c34
        cursor-blink = true
        """
        let url = try writeTempConfig(content)
        let entries = try parser.parse(contentsOf: url)
        #expect(entries.count == 4)
        #expect(entries[0].key == "font-family")
        #expect(entries[0].value == "JetBrains Mono")
        #expect(entries[1].key == "font-size")
        #expect(entries[1].value == "16")
        #expect(entries[2].key == "background")
        #expect(entries[2].value == "282c34")
        #expect(entries[3].key == "cursor-blink")
        #expect(entries[3].value == "true")
    }

    @Test func emptyValue() throws {
        let content = "font-family ="
        let url = try writeTempConfig(content)
        let entries = try parser.parse(contentsOf: url)
        #expect(entries.count == 1)
        #expect(entries[0].key == "font-family")
        #expect(entries[0].value == "")
    }

    @Test func whitespaceAroundEquals() throws {
        let content = "  font-size   =   14  "
        let url = try writeTempConfig(content)
        let entries = try parser.parse(contentsOf: url)
        #expect(entries.count == 1)
        #expect(entries[0].key == "font-size")
        #expect(entries[0].value == "14")
    }

    @Test func duplicateKeys() throws {
        let content = """
        keybind = cmd+t=new_tab
        keybind = cmd+w=close_tab
        keybind = cmd+f=search
        """
        let url = try writeTempConfig(content)
        let entries = try parser.parse(contentsOf: url)
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.key == "keybind" })
    }

    @Test func malformedLineSkipped() throws {
        let content = """
        font-size = 14
        this line has no equals sign
        background = 1e1e2e
        """
        let url = try writeTempConfig(content)
        let entries = try parser.parse(contentsOf: url)
        #expect(entries.count == 2)
    }

    @Test func valueContainingEquals() throws {
        let content = "keybind = cmd+t=new_tab"
        let url = try writeTempConfig(content)
        let entries = try parser.parse(contentsOf: url)
        #expect(entries.count == 1)
        #expect(entries[0].key == "keybind")
        #expect(entries[0].value == "cmd+t=new_tab")
    }

    // MARK: - Config-File Include

    @Test func configFileInclude() throws {
        let childContent = "font-size = 16"
        let childURL = try writeTempConfig(childContent, name: "child.config")

        let parentContent = """
        font-family = Menlo
        config-file = \(childURL.path)
        background = 282c34
        """
        let parentURL = try writeTempConfig(parentContent, name: "parent.config")

        let entries = try parser.parse(contentsOf: parentURL)
        #expect(entries.count == 3)
        #expect(entries[0].key == "font-family")
        #expect(entries[1].key == "font-size")
        #expect(entries[1].value == "16")
        #expect(entries[2].key == "background")
    }

    @Test func optionalConfigFileMissing() throws {
        let content = "config-file = ?/nonexistent/file.config\nfont-size = 14"
        let url = try writeTempConfig(content)
        let entries = try parser.parse(contentsOf: url)
        #expect(entries.count == 1)
        #expect(entries[0].key == "font-size")
    }

    @Test func requiredConfigFileMissing() throws {
        let content = "config-file = /nonexistent/file.config"
        let url = try writeTempConfig(content)
        #expect(throws: ConfigError.self) {
            try parser.parse(contentsOf: url)
        }
    }

    @Test func circularIncludeDetected() throws {
        let dir = NSTemporaryDirectory() + "tongyou-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let fileA = URL(fileURLWithPath: dir + "a.config")
        let fileB = URL(fileURLWithPath: dir + "b.config")

        try "config-file = \(fileB.path)".write(to: fileA, atomically: true, encoding: .utf8)
        try "config-file = \(fileA.path)".write(to: fileB, atomically: true, encoding: .utf8)

        #expect(throws: ConfigError.self) {
            try parser.parse(contentsOf: fileA)
        }
    }

    @Test func relativeIncludePath() throws {
        let dir = NSTemporaryDirectory() + "tongyou-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let childURL = URL(fileURLWithPath: dir + "local.config")
        try "font-size = 20".write(to: childURL, atomically: true, encoding: .utf8)

        let parentURL = URL(fileURLWithPath: dir + "config")
        try "config-file = local.config".write(to: parentURL, atomically: true, encoding: .utf8)

        let entries = try parser.parse(contentsOf: parentURL)
        #expect(entries.count == 1)
        #expect(entries[0].value == "20")
    }

    // MARK: - Helpers

    private func writeTempConfig(_ content: String, name: String = "config") throws -> URL {
        let dir = NSTemporaryDirectory() + "tongyou-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir + name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
