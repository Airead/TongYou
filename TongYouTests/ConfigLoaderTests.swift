import AppKit
import Testing
import Foundation
import TYTerminal
@testable import TongYou

@Suite("Config")
struct ConfigTests {

    // MARK: - Config.from(entries:)

    @Test func defaultConfig() {
        let config = Config.default
        #expect(config.fontFamily == "Menlo")
        #expect(config.fontSize == 14)
        #expect(config.background == RGBColor(0x1e, 0x1e, 0x26))
        #expect(config.foreground == RGBColor(0xdc, 0xdc, 0xdc))
        #expect(config.scrollbackLimit == 10000)
        #expect(config.tabWidth == 8)
        #expect(config.cursorStyle == .block)
        #expect(config.cursorBlink == false)
        #expect(config.bell == .audible)
        #expect(config.optionAsAlt == true)
    }

    @Test func fontConfig() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "font-family", value: "JetBrains Mono"),
            .init(key: "font-size", value: "16"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.fontFamily == "JetBrains Mono")
        #expect(config.fontSize == 16)
    }

    @Test func quotedFontFamily() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "font-family", value: "\"Fira Code\""),
        ]
        let config = Config.from(entries: entries)
        #expect(config.fontFamily == "Fira Code")
    }

    @Test func colorConfig() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "background", value: "282c34"),
            .init(key: "foreground", value: "abb2bf"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.background == RGBColor(0x28, 0x2c, 0x34))
        #expect(config.foreground == RGBColor(0xab, 0xb2, 0xbf))
    }

    @Test func paletteOverrides() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "palette-0", value: "282c34"),
            .init(key: "palette-1", value: "e06c75"),
        ]
        let config = Config.from(entries: entries)
        // Explicit overrides take effect on top of default theme palette
        #expect(config.palette[0] == RGBColor(0x28, 0x2c, 0x34))
        #expect(config.palette[1] == RGBColor(0xe0, 0x6c, 0x75))
        // Non-overridden entries come from default theme (iterm2-dark-background)
        let theme = BuiltinTheme.named("iterm2-dark-background")!
        #expect(config.palette[2] == theme.palette[2])
    }

    @Test func behaviorConfig() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "cursor-style", value: "bar"),
            .init(key: "cursor-blink", value: "false"),
            .init(key: "scrollback-limit", value: "5000"),
            .init(key: "tab-width", value: "4"),
            .init(key: "bell", value: "none"),
            .init(key: "option-as-alt", value: "false"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.cursorStyle == .bar)
        #expect(config.cursorBlink == false)
        #expect(config.scrollbackLimit == 5000)
        #expect(config.tabWidth == 4)
        #expect(config.bell == .none)
        #expect(config.optionAsAlt == false)
    }

    @Test func emptyValueResetsToDefault() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "font-size", value: "20"),
            .init(key: "font-size", value: ""),
        ]
        let config = Config.from(entries: entries)
        #expect(config.fontSize == Config.default.fontSize)
    }

    @Test func laterEntriesOverride() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "font-size", value: "14"),
            .init(key: "font-size", value: "18"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.fontSize == 18)
    }

    @Test func invalidValuesSkipped() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "font-size", value: "abc"),
            .init(key: "background", value: "xyz"),
            .init(key: "cursor-style", value: "triangle"),
        ]
        let config = Config.from(entries: entries)
        // All invalid — should remain at defaults
        #expect(config.fontSize == Config.default.fontSize)
        #expect(config.background == Config.default.background)
        #expect(config.cursorStyle == Config.default.cursorStyle)
    }

    @Test func unknownKeysIgnored() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "unknown-key", value: "whatever"),
            .init(key: "font-size", value: "14"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.fontSize == 14)
    }

    @Test func keybindingsAccumulate() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "keybind", value: "cmd+t=new_tab"),
            .init(key: "keybind", value: "alt+g=list_remote_sessions"),
        ]
        let config = Config.from(entries: entries)
        // Keybindings are defined solely by the config file.
        #expect(config.keybindings.count == 2)
        #expect(config.keybindings.first { $0.key == "t" && $0.modifiers == .command }?.action == .newTab)
        #expect(config.keybindings.first { $0.key == "g" && $0.modifiers == .option }?.action == .listRemoteSessions)
    }

    @Test func customKeybindingsOverrideDefaults() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "keybind", value: "cmd+t=close_tab"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.keybindings.count == 1)
        #expect(config.keybindings.first { $0.key == "t" && $0.modifiers == .command }?.action == .closeTab)
    }

    @Test func keybindingRunInPlaceParsing() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "keybind", value: "alt+m=run_in_place:lazygit"),
            .init(key: "keybind", value: "alt+g=run_in_place:git:log,--oneline"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.keybindings.count == 2)
        #expect(config.keybindings.first { $0.key == "m" && $0.modifiers == .option }?.action == .runInPlace(command: "lazygit", arguments: []))
        #expect(config.keybindings.first { $0.key == "g" && $0.modifiers == .option }?.action == .runInPlace(command: "git", arguments: ["log", "--oneline"]))
    }

    @Test func noKeybindsResultsInEmptyBindings() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "font-size", value: "14"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.keybindings.isEmpty)
    }

    @Test func invalidFontSizeRange() {
        // Negative
        let entries1: [ConfigParser.Entry] = [.init(key: "font-size", value: "-1")]
        let config1 = Config.from(entries: entries1)
        #expect(config1.fontSize == Config.default.fontSize)

        // Zero
        let entries2: [ConfigParser.Entry] = [.init(key: "font-size", value: "0")]
        let config2 = Config.from(entries: entries2)
        #expect(config2.fontSize == Config.default.fontSize)

        // Too large
        let entries3: [ConfigParser.Entry] = [.init(key: "font-size", value: "999")]
        let config3 = Config.from(entries: entries3)
        #expect(config3.fontSize == Config.default.fontSize)
    }

    @Test func colorWithHashPrefix() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "background", value: "#282c34"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.background == RGBColor(0x28, 0x2c, 0x34))
    }

    @Test func invalidPaletteIndex() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "palette-256", value: "ffffff"),
            .init(key: "palette--1", value: "000000"),
        ]
        let config = Config.from(entries: entries)
        // Invalid indices are ignored; palette only contains default theme entries (0-15)
        #expect(config.palette[256] == nil)
        #expect(config.palette.keys.allSatisfy { (0...15).contains($0) })
    }

    @Test func debugMetrics() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "debug-metrics", value: "true"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.debugMetrics == true)
    }

    @Test func draftEnabledDefault() {
        let config = Config.default
        #expect(config.draftEnabled == true)
    }

    @Test func draftEnabledDisabled() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "draft-enabled", value: "false"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.draftEnabled == false)
    }

    @Test func autoConnectDaemonDefault() {
        let config = Config.default
        #expect(config.autoConnectDaemon == false)
    }

    @Test func autoConnectDaemonEnabled() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "auto-connect-daemon", value: "true"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.autoConnectDaemon == true)
    }
}

@Suite("RGBColor")
struct RGBColorTests {

    @Test func validHex() throws {
        let color = try RGBColor(hex: "ff8800")
        #expect(color.r == 0xff)
        #expect(color.g == 0x88)
        #expect(color.b == 0x00)
    }

    @Test func invalidHex() {
        #expect(throws: ConfigError.self) { try RGBColor(hex: "xyz") }
        #expect(throws: ConfigError.self) { try RGBColor(hex: "ff88") }
        #expect(throws: ConfigError.self) { try RGBColor(hex: "ff880011") }
    }
}

@Suite("AutoPassthroughPrograms")
struct AutoPassthroughProgramsTests {

    @Test func parsedFromConfig() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "auto-passthrough-programs", value: "zellij, tmux, Vim"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.autoPassthroughPrograms == ["zellij", "tmux", "vim"])
    }

    @Test func emptyValueClearsPrograms() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "auto-passthrough-programs", value: "zellij"),
            .init(key: "auto-passthrough-programs", value: ""),
        ]
        let config = Config.from(entries: entries)
        #expect(config.autoPassthroughPrograms.isEmpty)
    }

    @Test func defaultHasNoPassthroughPrograms() {
        #expect(Config.default.autoPassthroughPrograms.isEmpty)
    }

    @Test func singleProgram() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "auto-passthrough-programs", value: "zellij"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.autoPassthroughPrograms == ["zellij"])
    }

    @Test func trailingCommaIgnored() {
        let entries: [ConfigParser.Entry] = [
            .init(key: "auto-passthrough-programs", value: "zellij,tmux,"),
        ]
        let config = Config.from(entries: entries)
        #expect(config.autoPassthroughPrograms == ["zellij", "tmux"])
    }
}

@Suite("Keybinding")
struct KeybindingTests {

    @Test func parseSimple() throws {
        let kb = try Keybinding.parse("cmd+t=new_tab")
        #expect(kb.modifiers == .command)
        #expect(kb.key == "t")
        #expect(kb.action == .newTab)
    }

    @Test func parseMultipleModifiers() throws {
        let kb = try Keybinding.parse("cmd+shift+left=previous_tab")
        #expect(kb.modifiers == [.command, .shift])
        #expect(kb.key == "left")
        #expect(kb.action == .previousTab)
    }

    @Test func parseCmdH() throws {
        let kb = try Keybinding.parse("cmd+h=previous_tab")
        #expect(kb.modifiers == .command)
        #expect(kb.key == "h")
        #expect(kb.action == .previousTab)
    }

    @Test func parseCmdL() throws {
        let kb = try Keybinding.parse("cmd+l=next_tab")
        #expect(kb.modifiers == .command)
        #expect(kb.key == "l")
        #expect(kb.action == .nextTab)
    }

    @Test func parseCmdY() throws {
        let kb = try Keybinding.parse("cmd+y=list_remote_sessions")
        #expect(kb.modifiers == .command)
        #expect(kb.key == "y")
        #expect(kb.action == .listRemoteSessions)
    }

    @Test func parseCtrl() throws {
        let kb = try Keybinding.parse("ctrl+c=copy")
        #expect(kb.modifiers == .control)
        #expect(kb.key == "c")
        #expect(kb.action == .copy)
    }

    @Test func parseAlt() throws {
        let kb = try Keybinding.parse("alt+v=paste")
        #expect(kb.modifiers == .option)
        #expect(kb.key == "v")
        #expect(kb.action == .paste)
    }

    @Test func parseUnbind() throws {
        let kb = try Keybinding.parse("opt+f=unbind")
        #expect(kb.modifiers == .option)
        #expect(kb.key == "f")
        #expect(kb.action == .unbind)
        #expect(kb.action.tabAction == nil)
    }

    @Test func parseDetachSession() throws {
        let kb = try Keybinding.parse("cmd+shift+k=detach_session")
        #expect(kb.modifiers == [.command, .shift])
        #expect(kb.key == "k")
        #expect(kb.action == .detachSession)
        #expect(kb.action.tabAction != nil)
    }

    @Test func matchShiftedBracketSymbols() throws {
        // charactersIgnoringModifiers returns "{" for cmd+shift+[, but the config uses "[".
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "{",
            charactersIgnoringModifiers: "{",
            isARepeat: false,
            keyCode: 33
        )!
        let binding = try Keybinding.parse("cmd+shift+[=previous_tab")
        #expect(Keybinding.match(event: event, in: [binding]) == .previousTab)
    }

    @Test func parseNamedKeyEqual() throws {
        let kb = try Keybinding.parse("cmd+equal=increase_font_size")
        #expect(kb.modifiers == .command)
        #expect(kb.key == "=")
        #expect(kb.action == .increaseFontSize)
    }

    @Test func parseNamedKeyPlus() throws {
        let kb = try Keybinding.parse("cmd+plus=increase_font_size")
        #expect(kb.modifiers == .command)
        #expect(kb.key == "+")
        #expect(kb.action == .increaseFontSize)
    }

    @Test func parseGrowPane() throws {
        let kb = try Keybinding.parse("alt+equal=grow_pane")
        #expect(kb.modifiers == .option)
        #expect(kb.key == "=")
        #expect(kb.action == .growPane)
    }

    @Test func parseShrinkPane() throws {
        let kb = try Keybinding.parse("alt+-=shrink_pane")
        #expect(kb.modifiers == .option)
        #expect(kb.key == "-")
        #expect(kb.action == .shrinkPane)
    }

    @Test func parseEqualKeyViaLastEquals() throws {
        // cmd+==increase_font_size: lastIndex splits on the second '='
        let kb = try Keybinding.parse("cmd+==increase_font_size")
        #expect(kb.modifiers == .command)
        #expect(kb.key == "=")
        #expect(kb.action == .increaseFontSize)
    }

    @Test func parseRunCommandWithFrameOptions() throws {
        let kb = try Keybinding.parse("alt+s=run_command[remote,local,pane,x=0.1,y=0.2,w=0.8,h=0.6]:git:status")
        #expect(kb.modifiers == .option)
        #expect(kb.key == "s")
        if case .runCommand(let cmd, let args, let opts) = kb.action {
            #expect(cmd == "git")
            #expect(args == ["status"])
            #expect(opts.runsRemote)
            #expect(opts.runsLocal)
            #expect(opts.showInPane)
            let frame = opts.paneFrame
            #expect(frame != nil)
            #expect(frame!.origin.x == 0.1)
            #expect(frame!.origin.y == 0.2)
            #expect(frame!.width == 0.8)
            #expect(frame!.height == 0.6)
        } else {
            Issue.record("Expected .runCommand")
        }
    }

    @Test func invalidAction() {
        #expect(throws: ConfigError.self) {
            try Keybinding.parse("cmd+t=nonexistent_action")
        }
    }

    @Test func noEquals() {
        #expect(throws: ConfigError.self) {
            try Keybinding.parse("cmd+t")
        }
    }

    @Test func noKey() {
        #expect(throws: ConfigError.self) {
            try Keybinding.parse("cmd+=new_tab")
        }
    }
}

@Suite("ConfigLoader")
struct ConfigLoaderTests {

    @Test func configFilePathsNotEmpty() {
        let paths = ConfigLoader.configFilePaths()
        #expect(paths.count >= 1)
    }

    @Test func loadWithNoConfigFiles() {
        let loader = ConfigLoader()
        // Use a non-existent temp path so the test never depends on the real filesystem state.
        let tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config")
        loader.load(from: [tempPath])
        #expect(loader.config.fontFamily.isEmpty == false)
    }

    @Test func generatedSystemConfigIsValid() throws {
        let content = ConfigLoader.generateSystemConfig()

        // Should not be empty
        #expect(!content.isEmpty)

        // Parsing the file should produce all default entries.
        let dir = NSTemporaryDirectory() + "tongyou-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let url = URL(fileURLWithPath: dir + "system_config.txt")
        try content.write(to: url, atomically: true, encoding: .utf8)

        let entries = try ConfigParser().parse(contentsOf: url)
        #expect(!entries.isEmpty, "System config should produce active entries")

        // Spot-check a few expected defaults
        let keybinds = entries.filter { $0.key == "keybind" }.map { $0.value }
        #expect(keybinds.contains("cmd+t=new_tab"))
        #expect(keybinds.contains("cmd+d=split_vertical"))

        let fontFamily = entries.first { $0.key == "font-family" }?.value
        #expect(fontFamily == "Menlo")

        let theme = entries.first { $0.key == "theme" }?.value
        #expect(theme == "iterm2-dark-background")
    }

    @Test func generatedConfigDocumentsAllKeys() {
        let content = ConfigLoader.generateSystemConfig()

        // Verify key configuration options are documented
        let expectedKeys = [
            "font-family", "font-size",
            "background", "foreground", "palette-0",
            "cursor-style", "cursor-blink",
            "option-as-alt", "scrollback-limit", "tab-width", "bell",
            "keybind", "config-file", "debug-metrics",
            "draft-enabled", "auto-connect-daemon",
        ]
        for key in expectedKeys {
            #expect(content.contains(key),
                    "System config should document '\(key)'")
        }
    }

    @Test func systemConfigIncludesUserConfig() {
        let content = ConfigLoader.generateSystemConfig()
        #expect(content.contains("config-file = ?user_config.txt"),
                "System config should include user_config.txt at the end")
    }

    @Test func fullIntegrationParse() throws {
        let content = """
        # TongYou test config
        font-family = SF Mono
        font-size = 15
        background = 1a1b26
        foreground = c0caf5

        palette-0 = 15161e
        palette-1 = f7768e

        cursor-style = underline
        cursor-blink = false
        scrollback-limit = 20000
        tab-width = 4
        bell = visual
        option-as-alt = true

        keybind = cmd+t=new_tab
        keybind = cmd+w=close_tab

        debug-metrics = true
        """
        let dir = NSTemporaryDirectory() + "tongyou-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let url = URL(fileURLWithPath: dir + "config")
        try content.write(to: url, atomically: true, encoding: .utf8)

        let parser = ConfigParser()
        let entries = try parser.parse(contentsOf: url)
        let config = Config.from(entries: entries)

        #expect(config.fontFamily == "SF Mono")
        #expect(config.fontSize == 15)
        #expect(config.background == RGBColor(0x1a, 0x1b, 0x26))
        #expect(config.foreground == RGBColor(0xc0, 0xca, 0xf5))
        #expect(config.palette[0] == RGBColor(0x15, 0x16, 0x1e))
        #expect(config.palette[1] == RGBColor(0xf7, 0x76, 0x8e))
        #expect(config.cursorStyle == .underline)
        #expect(config.cursorBlink == false)
        #expect(config.scrollbackLimit == 20000)
        #expect(config.tabWidth == 4)
        #expect(config.bell == .visual)
        #expect(config.optionAsAlt == true)
        #expect(config.keybindings.count == 2)
        #expect(config.debugMetrics == true)
    }
}
