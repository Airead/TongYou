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
        // 1. Production: load from the app bundle.
        if let bundleURL = Bundle.main.url(forResource: "DefaultConfig", withExtension: "txt") {
            if let content = try? String(contentsOf: bundleURL, encoding: .utf8) {
                return content
            }
        }

        // 2. Development / tests: load from the source directory adjacent to this file.
        let sourceFile = URL(fileURLWithPath: #file)
        let devURL = sourceFile.deletingLastPathComponent().appendingPathComponent("DefaultConfig.txt")
        if let content = try? String(contentsOf: devURL, encoding: .utf8) {
            return content
        }

        fatalError("DefaultConfig.txt is missing from the bundle and source directory.")
    }

    /// Write the default sample config to the XDG config path if no config files exist.
    private func generateDefaultConfigIfNeeded() {
        let paths = Self.configFilePaths()
        let anyExists = paths.contains { FileManager.default.fileExists(atPath: $0.path) }
        guard !anyExists else { return }

        // Use the first path (XDG)
        guard let target = paths.first else { return }
        Self.ensureDefaultConfigExists(at: target)
    }

    /// Ensure the default config file exists at the given URL, generating it if needed.
    static func ensureDefaultConfigExists(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            let dir = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try generateDefaultConfig().write(to: url, atomically: true, encoding: .utf8)
                print("[config] generated default config at \(url.path)")
            } catch {
                print("[config] warning: could not generate default config: \(error)")
            }
        }
    }

    /// Open the default config file with TextEdit, generating it if needed.
    static func openDefaultConfigFile() {
        let paths = configFilePaths()
        guard let target = paths.first else { return }
        ensureDefaultConfigExists(at: target)
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
