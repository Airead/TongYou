import AppKit
import Foundation

/// Loads configuration from disk and watches for changes.
///
/// Load order (later overrides earlier):
/// 1. Built-in defaults (`Config.default`)
/// 2. `$XDG_CONFIG_HOME/tongyou/system_config.txt` (default `~/.config/tongyou/system_config.txt`)
/// 3. Files referenced by `config-file` directives (including `user_config.txt`)
///
/// `system_config.txt` is auto-generated on every launch from the bundled template.
/// Users should edit `user_config.txt` in the same directory to override system defaults.
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
    /// Always overwrites `system_config.txt` with the bundled template.
    func load() {
        writeSystemConfig()
        let (newConfig, paths) = loadFromDisk()
        config = newConfig
        setupWatchers(for: paths)

        // Apply initial GUILog state from config
        applyGUILogConfig(newConfig)
    }

    deinit {
        reloadWorkItem?.cancel()
        for watcher in watchers {
            watcher.cancel()
        }
        watchers.removeAll()
    }

    // MARK: - Config File Paths

    /// Returns the XDG config directory for tongyou.
    static func configDirectory() -> URL {
        let xdgHome: String
        if let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !env.isEmpty {
            xdgHome = env
        } else {
            xdgHome = NSString(string: "~/.config").expandingTildeInPath
        }
        return URL(fileURLWithPath: xdgHome).appendingPathComponent("tongyou")
    }

    /// Returns the ordered list of config file paths to load.
    static func configFilePaths() -> [URL] {
        let dir = configDirectory()
        return [dir.appendingPathComponent("system_config.txt")]
    }

    /// Returns the path to user_config.txt.
    static func userConfigPath() -> URL {
        configDirectory().appendingPathComponent("user_config.txt")
    }

    // MARK: - System Config Generation

    /// Load the system config template from the bundle or source directory.
    static func generateSystemConfig() -> String {
        // 1. Production: load from the app bundle.
        if let bundleURL = Bundle.main.url(forResource: "SystemConfig", withExtension: "txt") {
            if let content = try? String(contentsOf: bundleURL, encoding: .utf8) {
                return content
            }
        }

        // 2. Development / tests: load from the source directory adjacent to this file.
        let sourceFile = URL(fileURLWithPath: #file)
        let devURL = sourceFile.deletingLastPathComponent().appendingPathComponent("SystemConfig.txt")
        if let content = try? String(contentsOf: devURL, encoding: .utf8) {
            return content
        }

        fatalError("SystemConfig.txt is missing from the bundle and source directory.")
    }

    /// Overwrite system_config.txt with the bundled template on every launch.
    private func writeSystemConfig() {
        guard let target = Self.configFilePaths().first else { return }
        let dir = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.generateSystemConfig().write(to: target, atomically: true, encoding: .utf8)
        } catch {
            print("[config] warning: could not write system config: \(error)")
        }
    }

    /// Open the user config file with TextEdit, creating an empty one if needed.
    static func openUserConfigFile() {
        let target = userConfigPath()
        let dir = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                try "".write(to: target, atomically: true, encoding: .utf8)
            }
        } catch {
            print("[config] warning: could not create user config: \(error)")
        }
        guard let textEditURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else { return }
        NSWorkspace.shared.open([target], withApplicationAt: textEditURL, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Private

    /// Load configuration from explicit URLs (for testing).
    func load(from paths: [URL]) {
        let (newConfig, existingPaths) = loadFromDisk(paths: paths)
        config = newConfig
        setupWatchers(for: existingPaths, potentialDirs: paths)
    }

    private func loadFromDisk(paths: [URL]? = nil) -> (Config, existingPaths: [String]) {
        let urls = paths ?? ConfigLoader.configFilePaths()
        var allEntries: [ConfigParser.Entry] = []
        var existingPaths: [String] = []

        for url in urls {
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

    private func setupWatchers(for paths: [String], potentialDirs: [URL]? = nil) {
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
        let dirs = potentialDirs ?? ConfigLoader.configFilePaths()
        for url in dirs {
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

        // Toggle GUILog on config hot-reload
        if oldConfig.debugLogLevel != newConfig.debugLogLevel
            || oldConfig.debugLogCategories != newConfig.debugLogCategories {
            applyGUILogConfig(newConfig)
        }

        onConfigChanged?(newConfig)

        logConfigDiff(old: oldConfig, new: newConfig)
    }

    private func applyGUILogConfig(_ config: Config) {
        guard let level = GUILog.Level(configValue: config.debugLogLevel) else {
            GUILog.disable()
            return
        }
        let categories: Set<GUILog.Category>?
        if config.debugLogCategories.isEmpty {
            categories = nil
        } else {
            categories = Set(config.debugLogCategories.compactMap { GUILog.Category(rawValue: $0) })
        }
        GUILog.enable(level: level, categories: categories)
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
        if old.draftEnabled != new.draftEnabled { changes.append("draft-enabled") }
        if old.autoConnectDaemon != new.autoConnectDaemon { changes.append("auto-connect-daemon") }
        if old.debugMetrics != new.debugMetrics { changes.append("debug-metrics") }
        if old.debugLogLevel != new.debugLogLevel { changes.append("debug-log-level") }
        if old.debugLogCategories != new.debugLogCategories { changes.append("debug-log-categories") }
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
