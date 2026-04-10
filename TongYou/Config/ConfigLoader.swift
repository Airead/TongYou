import AppKit
import Foundation

/// Loads configuration from disk and watches for changes.
///
/// Load order (later overrides earlier):
/// 1. Built-in defaults (`Config.default`)
/// 2. `$XDG_CONFIG_HOME/tongyou/config` (default `~/.config/tongyou/config`)
/// 3. `~/Library/Application Support/io.github.airead.tongyou/config`
/// 4. Files referenced by `config-file` directives
///
/// Hot reload: watches config files via DispatchSource with 200ms debounce.
final class ConfigLoader {

    /// Current loaded configuration.
    private(set) var config: Config = .default

    /// Called on the main thread when configuration changes after a hot reload.
    var onConfigChanged: ((Config) -> Void)?

    /// File system watchers for open config files.
    // nonisolated(unsafe) because deinit must cancel without actor hop.
    nonisolated(unsafe) private var watchers: [FileWatcher] = []

    /// Debounce work item for hot reload.
    private var reloadWorkItem: DispatchWorkItem?

    /// Debounce interval for hot reload (200ms).
    private static let debounceInterval: TimeInterval = 0.2

    private let parser = ConfigParser()

    // MARK: - Lifecycle

    /// Load configuration from standard locations and start watching.
    /// On first run, generates a commented-out sample config file.
    func load() {
        generateDefaultConfigIfNeeded()
        let (newConfig, paths) = loadFromDisk()
        config = newConfig
        setupWatchers(for: paths)
    }

    deinit {
        reloadWorkItem?.cancel()
        for watcher in watchers {
            watcher.cancel()
        }
        watchers.removeAll()
    }

    // MARK: - Config File Paths

    /// Returns the ordered list of config file paths that exist.
    static func configFilePaths() -> [URL] {
        var paths: [URL] = []

        // XDG_CONFIG_HOME/tongyou/config (default ~/.config/tongyou/config)
        let xdgHome: String
        if let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !env.isEmpty {
            xdgHome = env
        } else {
            xdgHome = NSString(string: "~/.config").expandingTildeInPath
        }
        let xdgPath = URL(fileURLWithPath: xdgHome)
            .appendingPathComponent("tongyou")
            .appendingPathComponent("config")
        paths.append(xdgPath)

        // ~/Library/Application Support/io.github.airead.tongyou/config
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            let libraryPath = appSupport
                .appendingPathComponent("io.github.airead.tongyou")
                .appendingPathComponent("config")
            paths.append(libraryPath)
        }

        return paths
    }

    // MARK: - Default Config Generation

    /// Generate a commented-out sample config listing all available options.
    static func generateDefaultConfig() -> String {
        return """
        # TongYou Configuration
        #
        # This file was auto-generated with all options commented out.
        # Uncomment and modify lines to customize your terminal.
        #
        # Config file locations (loaded in order, later overrides earlier):
        #   1. ~/.config/tongyou/config
        #   2. ~/Library/Application Support/io.github.airead.tongyou/config
        #
        # Syntax:
        #   key = value       Set an option
        #   key =             Reset to default (empty value)
        #   # comment         Comment (must be on its own line)
        #   config-file = ?path   Include another file (? = optional)

        # ── Font ─────────────────────────────────────────────────────────
        # Font family name. Use the PostScript name or family name.
        # font-family = Menlo

        # Font size in points.
        # font-size = 14

        # ── Theme ────────────────────────────────────────────────────────
        # Use a built-in theme. Explicit color settings below override theme colors.
        # Available themes:
        #   iterm2-dark-background, iterm2-default, iterm2-light-background,
        #   iterm2-pastel-dark-background, iterm2-smoooooth,
        #   iterm2-solarized-dark, iterm2-solarized-light,
        #   iterm2-tango-dark, iterm2-tango-light
        # theme = iterm2-dark-background

        # ── Colors ───────────────────────────────────────────────────────
        # Background and foreground colors (6-digit hex, with or without # prefix).
        # background = 1e1e26
        # foreground = dcdcdc
        # cursor-color = e5e5e5
        # cursor-text = 000000
        # selection-background = c1deff
        # selection-foreground = 000000

        # Override individual palette colors (0-255).
        # Standard colors: 0-7, bright colors: 8-15,
        # 216-color cube: 16-231, grayscale ramp: 232-255.
        # palette-0 = 000000
        # palette-1 = cd3131
        # palette-2 = 0dbc79
        # palette-3 = e5e510
        # palette-4 = 2472c8
        # palette-5 = bc3fbc
        # palette-6 = 11a8cd
        # palette-7 = e5e5e5
        # palette-8 = 666666
        # palette-9 = f14c4c
        # palette-10 = 23d18b
        # palette-11 = f5f543
        # palette-12 = 3b8eea
        # palette-13 = d670d6
        # palette-14 = 29b8db
        # palette-15 = ffffff

        # ── Cursor ───────────────────────────────────────────────────────
        # Cursor shape: block, underline, bar
        # cursor-style = block

        # Enable cursor blinking.
        # cursor-blink = false

        # ── Behavior ─────────────────────────────────────────────────────
        # Treat Option key as Alt (sends ESC prefix).
        # option-as-alt = true

        # Maximum number of scrollback lines to keep.
        # scrollback-limit = 10000

        # Tab stop width in columns.
        # tab-width = 8

        # Bell mode: audible, visual, none
        # bell = audible

        # ── Keybindings ──────────────────────────────────────────────────
        # Format: keybind = modifiers+key=action
        # Modifiers: cmd, shift, ctrl, alt (combinable with +)
        # Setting any keybind replaces ALL defaults. To keep defaults,
        # list them explicitly.
        #
        # Available actions:
        #   new_tab, close_tab, previous_tab, next_tab,
        #   copy, paste, search,
        #   reset_font_size, increase_font_size, decrease_font_size
        #
        # keybind = cmd+t=new_tab
        # keybind = cmd+w=close_tab
        # keybind = cmd+shift+left=previous_tab
        # keybind = cmd+shift+right=next_tab
        # keybind = cmd+c=copy
        # keybind = cmd+v=paste
        # keybind = cmd+f=search
        # keybind = cmd+0=reset_font_size
        # keybind = cmd++=increase_font_size
        # keybind = cmd+-=decrease_font_size

        # ── File Include ─────────────────────────────────────────────────
        # Include another config file. Prefix path with ? to make it optional
        # (no error if the file doesn't exist). Relative paths are resolved
        # against this file's directory.
        # config-file = ?local.config

        # ── Debug ────────────────────────────────────────────────────────
        # Show frame time metrics overlay.
        # debug-metrics = false
        """
    }

    /// Write the default sample config to the XDG config path if no config files exist.
    private func generateDefaultConfigIfNeeded() {
        let paths = Self.configFilePaths()
        let anyExists = paths.contains { FileManager.default.fileExists(atPath: $0.path) }
        guard !anyExists else { return }

        // Use the first path (XDG)
        guard let target = paths.first else { return }
        let dir = target.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.generateDefaultConfig().write(to: target, atomically: true, encoding: .utf8)
            print("[config] generated default config at \(target.path)")
        } catch {
            print("[config] warning: could not generate default config: \(error)")
        }
    }

    // MARK: - Private

    private func loadFromDisk() -> (Config, existingPaths: [String]) {
        var allEntries: [ConfigParser.Entry] = []
        var existingPaths: [String] = []

        for url in Self.configFilePaths() {
            do {
                let entries = try parser.parse(contentsOf: url)
                allEntries.append(contentsOf: entries)
                existingPaths.append(url.path)
            } catch {
                // File doesn't exist or isn't readable — skip silently
            }
        }

        let config = Config.from(entries: allEntries)
        return (config, existingPaths)
    }

    // MARK: - Hot Reload

    private func setupWatchers(for paths: [String]) {
        // Cancel existing watchers
        for watcher in watchers {
            watcher.cancel()
        }
        watchers.removeAll()

        // Watch existing config files
        for path in paths {
            if let watcher = FileWatcher(path: path, handler: { [weak self] in
                self?.scheduleReload()
            }) {
                watchers.append(watcher)
            }
        }

        // Also watch the parent directories of all potential config paths
        // so we detect file creation.
        var watchedDirs: Set<String> = []
        for url in Self.configFilePaths() {
            let dir = url.deletingLastPathComponent().path
            guard !watchedDirs.contains(dir) else { continue }
            watchedDirs.insert(dir)
            // Only watch directories that exist
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if let watcher = FileWatcher(path: dir, handler: { [weak self] in
                self?.scheduleReload()
            }) {
                watchers.append(watcher)
            }
        }
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performReload()
        }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.debounceInterval,
            execute: item
        )
    }

    private func performReload() {
        let (newConfig, paths) = loadFromDisk()
        guard newConfig != config else { return }
        let oldConfig = config
        config = newConfig

        // Re-setup watchers in case new files appeared
        setupWatchers(for: paths)

        onConfigChanged?(newConfig)

        logConfigDiff(old: oldConfig, new: newConfig)
    }

    private func logConfigDiff(old: Config, new: Config) {
        var changes: [String] = []
        if old.fontFamily != new.fontFamily { changes.append("font-family") }
        if old.fontSize != new.fontSize { changes.append("font-size") }
        if old.background != new.background { changes.append("background") }
        if old.foreground != new.foreground { changes.append("foreground") }
        if old.palette != new.palette { changes.append("palette") }
        if old.cursorStyle != new.cursorStyle { changes.append("cursor-style") }
        if old.cursorBlink != new.cursorBlink { changes.append("cursor-blink") }
        if old.scrollbackLimit != new.scrollbackLimit { changes.append("scrollback-limit") }
        if old.bell != new.bell { changes.append("bell") }
        if old.keybindings != new.keybindings { changes.append("keybind") }
        if old.debugMetrics != new.debugMetrics { changes.append("debug-metrics") }
        if !changes.isEmpty {
            print("[config] reloaded: \(changes.joined(separator: ", ")) changed")
        }
    }
}

// MARK: - FileWatcher

/// Watches a single file or directory for changes using DispatchSource.
private final class FileWatcher {
    // nonisolated(unsafe) because deinit must cancel without actor hop.
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    private let fd: Int32

    /// Create a watcher for the given path.
    /// - Parameters:
    ///   - path: File or directory path to watch.
    ///   - handler: Called when changes are detected (on an arbitrary queue).
    init?(path: String, handler: @escaping () -> Void) {
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit {
        cancel()
    }
}
