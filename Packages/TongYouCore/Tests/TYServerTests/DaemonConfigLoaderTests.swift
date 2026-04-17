import Testing
import Foundation
@testable import TYServer
@testable import TYConfig

@Suite("DaemonConfigLoader", .serialized)
struct DaemonConfigLoaderTests {

    // MARK: - Basic Loading

    @Test func defaultsWhenNoFile() {
        let loader = DaemonConfigLoader()
        loader.loadOnce()
        let config = loader.config
        #expect(config.maxScrollback == 10000)
        #expect(config.minCoalesceDelay == 0.001)
        #expect(config.maxCoalesceDelay == 0.200)
        #expect(config.maxPendingScreenUpdates == 3)
        #expect(config.statsInterval == 30.0)
        #expect(config.autoExitOnNoSessions == false)
    }

    @Test func loadsScrollbackLimit() throws {
        let url = try writeTempConfig("daemon-scrollback-limit = 3000")
        let loader = DaemonConfigLoader()
        loader.load(from: [url])
        #expect(loader.config.maxScrollback == 3000)
    }

    @Test func loadsCoalesceDelays() throws {
        let content = """
        daemon-min-coalesce-delay = 0.005
        daemon-max-coalesce-delay = 0.5
        """
        let url = try writeTempConfig(content)
        let loader = DaemonConfigLoader()
        loader.load(from: [url])
        #expect(loader.config.minCoalesceDelay == 0.005)
        #expect(loader.config.maxCoalesceDelay == 0.5)
    }

    @Test func loadsMaxPendingScreenUpdates() throws {
        let url = try writeTempConfig("daemon-max-pending-screen-updates = 5")
        let loader = DaemonConfigLoader()
        loader.load(from: [url])
        #expect(loader.config.maxPendingScreenUpdates == 5)
    }

    @Test func loadsStatsInterval() throws {
        let url = try writeTempConfig("daemon-stats-interval = 0")
        let loader = DaemonConfigLoader()
        loader.load(from: [url])
        #expect(loader.config.statsInterval == 0)
    }

    @Test func loadsAutoExit() throws {
        let url = try writeTempConfig("daemon-auto-exit-on-no-sessions = true")
        let loader = DaemonConfigLoader()
        loader.load(from: [url])
        #expect(loader.config.autoExitOnNoSessions == true)
    }

    // MARK: - Empty Value Resets to Default

    @Test func emptyValueResetsToDefault() throws {
        let content = """
        daemon-scrollback-limit = 3000
        daemon-scrollback-limit =
        """
        let url = try writeTempConfig(content)
        let loader = DaemonConfigLoader()
        loader.load(from: [url])
        #expect(loader.config.maxScrollback == ServerConfig.defaultMaxScrollback)
    }

    // MARK: - Invalid Values

    @Test func invalidScrollbackIgnored() throws {
        let url = try writeTempConfig("daemon-scrollback-limit = -1")
        let loader = DaemonConfigLoader()
        loader.load(from: [url])
        // Invalid value is skipped, default remains
        #expect(loader.config.maxScrollback == 10000)
    }

    @Test func invalidBoolIgnored() throws {
        let url = try writeTempConfig("daemon-auto-exit-on-no-sessions = yes")
        let loader = DaemonConfigLoader()
        loader.load(from: [url])
        #expect(loader.config.autoExitOnNoSessions == false)
    }

    @Test func invalidDelayIgnored() throws {
        let url = try writeTempConfig("daemon-min-coalesce-delay = -0.1")
        let loader = DaemonConfigLoader()
        loader.load(from: [url])
        #expect(loader.config.minCoalesceDelay == 0.001)
    }

    // MARK: - Non-daemon Keys Ignored

    @Test func nonDaemonKeysIgnored() throws {
        let content = """
        font-size = 16
        scrollback-limit = 5000
        daemon-scrollback-limit = 3000
        """
        let url = try writeTempConfig(content)
        let loader = DaemonConfigLoader()
        loader.load(from: [url])
        // Only daemon-scrollback-limit is applied
        #expect(loader.config.maxScrollback == 3000)
    }

    // MARK: - Base Config Preserved

    @Test func baseConfigFieldsPreserved() throws {
        let base = ServerConfig(
            socketPath: "/tmp/test.sock",
            persistenceDirectory: "/tmp/persist"
        )
        let url = try writeTempConfig("daemon-scrollback-limit = 2000")
        let loader = DaemonConfigLoader(baseConfig: base)
        loader.load(from: [url])
        #expect(loader.config.socketPath == "/tmp/test.sock")
        #expect(loader.config.persistenceDirectory == "/tmp/persist")
        #expect(loader.config.maxScrollback == 2000)
    }

    // MARK: - Multiple Values (Last Wins)

    @Test func lastValueWins() throws {
        let content = """
        daemon-scrollback-limit = 1000
        daemon-scrollback-limit = 5000
        """
        let url = try writeTempConfig(content)
        let loader = DaemonConfigLoader()
        loader.load(from: [url])
        #expect(loader.config.maxScrollback == 5000)
    }

    // MARK: - Apply Static Method

    @Test func applyEntries() {
        let entries: [ConfigParser.Entry] = [
            ConfigParser.Entry(key: "daemon-scrollback-limit", value: "2000"),
            ConfigParser.Entry(key: "daemon-auto-exit-on-no-sessions", value: "true"),
            ConfigParser.Entry(key: "font-size", value: "16"),  // should be ignored
        ]
        let config = DaemonConfigLoader.apply(entries: entries, to: ServerConfig())
        #expect(config.maxScrollback == 2000)
        #expect(config.autoExitOnNoSessions == true)
    }

    // MARK: - Helpers

    private func writeTempConfig(_ content: String) throws -> URL {
        let dir = NSTemporaryDirectory() + "tongyou-daemon-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir + "user_config.txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
