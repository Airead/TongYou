import Foundation
import Testing
import TYServer
@testable import TongYou

@Suite("GUILog", .serialized)
struct GUILogTests {

    @Test func disabledByDefault() {
        #expect(GUILog.isEnabled == false)
    }

    @Test func enableAndDisable() {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guilog-test-\(UUID().uuidString)")
        GUILog.logDirectoryOverride = tmpDir
        defer {
            GUILog.logDirectoryOverride = nil
            try? FileManager.default.removeItem(at: tmpDir)
        }

        GUILog.enable()
        #expect(GUILog.isEnabled == true)

        GUILog.disable()
        GUILog.flush()
        #expect(GUILog.isEnabled == false)
    }

    @Test func writesLogToFile() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guilog-test-\(UUID().uuidString)")
        GUILog.logDirectoryOverride = tmpDir
        defer {
            GUILog.logDirectoryOverride = nil
            try? FileManager.default.removeItem(at: tmpDir)
        }

        GUILog.enable()
        GUILog.flush()  // ensure file handle is open
        GUILog.info("test message from GUILogTests", category: .general)
        GUILog.disable()
        GUILog.flush()  // ensure all writes are flushed and file is closed

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = fmt.string(from: Date())

        let logFile = tmpDir.appendingPathComponent("gui-\(dateStr).log")
        let content = try String(contentsOf: logFile, encoding: .utf8)

        #expect(content.contains("test message from GUILogTests"))
        #expect(content.contains("[INFO]"))
        #expect(content.contains("[general]"))
        // Verify UTC timestamp format (YYYY-MM-DDTHH:MM:SS.mmmZ)
        #expect(content.contains("Z]"))
    }

    @Test func autoclosureNotEvaluatedWhenDisabled() {
        #expect(GUILog.isEnabled == false)

        var evaluated = false
        GUILog.debug({
            evaluated = true
            return "should not be evaluated"
        }())
        #expect(evaluated == false)
    }

    @Test func configParsesDebugLogLevel() {
        let config = Config.from(entries: [
            .init(key: "debug-log-level", value: "debug"),
        ])
        #expect(config.debugLogLevel == "debug")

        let config2 = Config.from(entries: [
            .init(key: "debug-log-level", value: "info"),
        ])
        #expect(config2.debugLogLevel == "info")

        let config3 = Config.from(entries: [
            .init(key: "debug-log-level", value: "off"),
        ])
        #expect(config3.debugLogLevel == "off")
    }

    @Test func configParsesDebugLogCategories() {
        let config = Config.from(entries: [
            .init(key: "debug-log-categories", value: "renderer,input"),
        ])
        #expect(config.debugLogCategories == ["renderer", "input"])

        let config2 = Config.from(entries: [
            .init(key: "debug-log-categories", value: ""),
        ])
        #expect(config2.debugLogCategories.isEmpty)
    }

    @Test func configDebugLogDefaults() {
        #expect(Config.default.debugLogLevel == "off")
        #expect(Config.default.debugLogCategories.isEmpty)
    }

    @Test func levelFiltering() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guilog-test-\(UUID().uuidString)")
        GUILog.logDirectoryOverride = tmpDir
        defer {
            GUILog.logDirectoryOverride = nil
            try? FileManager.default.removeItem(at: tmpDir)
        }

        GUILog.enable(level: .warning)
        GUILog.flush()
        GUILog.debug("should-not-appear", category: .general)
        GUILog.info("should-not-appear-either", category: .general)
        GUILog.warning("visible-warning", category: .general)
        GUILog.error("visible-error", category: .general)
        GUILog.disable()
        GUILog.flush()

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = fmt.string(from: Date())
        let logFile = tmpDir.appendingPathComponent("gui-\(dateStr).log")
        let content = try String(contentsOf: logFile, encoding: .utf8)

        #expect(!content.contains("should-not-appear"))
        #expect(content.contains("visible-warning"))
        #expect(content.contains("visible-error"))
    }

    @Test func categoryFiltering() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guilog-test-\(UUID().uuidString)")
        GUILog.logDirectoryOverride = tmpDir
        defer {
            GUILog.logDirectoryOverride = nil
            try? FileManager.default.removeItem(at: tmpDir)
        }

        GUILog.enable(level: .debug, categories: [.renderer])
        GUILog.flush()
        GUILog.debug("renderer-msg", category: .renderer)
        GUILog.debug("input-msg", category: .input)
        GUILog.debug("general-msg", category: .general)
        GUILog.disable()
        GUILog.flush()

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = fmt.string(from: Date())
        let logFile = tmpDir.appendingPathComponent("gui-\(dateStr).log")
        let content = try String(contentsOf: logFile, encoding: .utf8)

        #expect(content.contains("renderer-msg"))
        #expect(!content.contains("input-msg"))
        #expect(!content.contains("general-msg"))
    }
}
