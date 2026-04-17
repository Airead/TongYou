import Foundation
import Testing
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

    @Test func configParsesDebugLog() {
        let config = Config.from(entries: [
            .init(key: "debug-log", value: "true"),
        ])
        #expect(config.debugLog == true)

        let config2 = Config.from(entries: [
            .init(key: "debug-log", value: "false"),
        ])
        #expect(config2.debugLog == false)
    }

    @Test func configDebugLogDefaultIsFalse() {
        #expect(Config.default.debugLog == false)
    }
}
