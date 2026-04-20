import AppKit
import Foundation
import TYConfig
import TYServer

/// Loads configuration from disk and watches for changes.
///
/// Load order (later overrides earlier):
/// 1. Built-in defaults (`Config.default`)
/// 2. `~/.config/tongyou/system_config.txt` (path resolved via `ConfigPaths`)
/// 3. Files referenced by `config-file` directives (including `user_config.txt`)
///
/// `system_config.txt` is auto-generated on every launch from the bundled template.
/// Users should edit `user_config.txt` in the same directory to override system defaults.
///
/// Hot reload: watches config files via DispatchSource with 200ms debounce.
final class ConfigLoader {

    /// Current loaded configuration.
    private(set) var config: Config = .default

    /// Last parsed key-value entries that produced `config`. Exposed so
    /// profile-aware consumers (MetalView) can append profile Live-field
    /// entries on top and build a per-pane `Config` without losing the
    /// global settings.
    private(set) var globalEntries: [ConfigParser.Entry] = []

    /// Legacy single-subscriber config change hook. Retained for call sites
    /// (TerminalWindowView, ResourceStatsView) that treat ConfigLoader as a
    /// per-view instance. When ConfigLoader is shared across multiple
    /// subscribers (MetalView panes + the window view), each subscriber
    /// should use `addConfigChangeObserver` instead.
    var onConfigChanged: ((Config) -> Void)?

    /// Shared profile loader, watched alongside the global config files.
    /// The app creates exactly one; SessionManager and MetalView both read
    /// from it so startup resolution and live-field resolution stay in sync.
    let profileLoader: ProfileLoader

    /// Multi-subscriber observer table for config hot-reload events.
    private var configObservers: [UUID: (Config) -> Void] = [:]
    /// Multi-subscriber observer table for profile change events.
    private var profileObservers: [UUID: (Set<String>) -> Void] = [:]

    /// File system watchers for open config files.
    // nonisolated(unsafe) because deinit must cancel without actor hop.
    nonisolated(unsafe) private var watchers: [FileWatcher] = []
    /// File system watchers for the profile directory and its .txt files.
    nonisolated(unsafe) private var profileWatchers: [FileWatcher] = []

    /// Debounce work item for hot reload.
    private var reloadWorkItem: DispatchWorkItem?
    /// Debounce work item for profile reload.
    private var profileReloadWorkItem: DispatchWorkItem?

    /// Debounce interval for hot reload (200ms).
    private static let debounceInterval: TimeInterval = 0.2

    private let parser = ConfigParser()

    init(profileLoader: ProfileLoader? = nil) {
        let loader = profileLoader ?? ProfileLoader(
            directory: Self.profileDirectory()
        )
        self.profileLoader = loader
        // Forward profile-change notifications from the loader to every
        // registered observer.
        loader.onProfilesChanged = { [weak self] ids in
            self?.notifyProfileObservers(ids)
        }
    }

    // MARK: - Observer API

    /// Register a handler for config hot-reload events. Returns a token; call
    /// `removeConfigChangeObserver(_:)` to unsubscribe (e.g. from deinit).
    @discardableResult
    func addConfigChangeObserver(_ handler: @escaping (Config) -> Void) -> UUID {
        let token = UUID()
        configObservers[token] = handler
        return token
    }

    func removeConfigChangeObserver(_ token: UUID) {
        configObservers.removeValue(forKey: token)
    }

    /// Register a handler for profile change events. Returns a token; call
    /// `removeProfileChangeObserver(_:)` to unsubscribe.
    @discardableResult
    func addProfileChangeObserver(_ handler: @escaping (Set<String>) -> Void) -> UUID {
        let token = UUID()
        profileObservers[token] = handler
        return token
    }

    func removeProfileChangeObserver(_ token: UUID) {
        profileObservers.removeValue(forKey: token)
    }

    private func notifyConfigObservers(_ config: Config) {
        for handler in configObservers.values {
            handler(config)
        }
    }

    private func notifyProfileObservers(_ ids: Set<String>) {
        for handler in profileObservers.values {
            handler(ids)
        }
    }

    // MARK: - Lifecycle

    /// Load configuration from standard locations and start watching.
    /// Always overwrites `system_config.txt` with the bundled template.
    func load() {
        writeSystemConfig()
        Self.seedProfiles(into: ConfigPaths.configDirectory)
        let (newConfig, entries, paths) = loadFromDisk()
        config = newConfig
        globalEntries = entries
        setupWatchers(for: paths)

        // Apply initial GUILog state from config
        applyGUILogConfig(newConfig)

        // Load profiles from disk and start watching their directory.
        loadProfilesFromDisk()
        setupProfileWatchers()
    }

    deinit {
        reloadWorkItem?.cancel()
        profileReloadWorkItem?.cancel()
        for watcher in watchers {
            watcher.cancel()
        }
        watchers.removeAll()
        for watcher in profileWatchers {
            watcher.cancel()
        }
        profileWatchers.removeAll()
    }

    // MARK: - Config File Paths
    //
    // All paths now come from `TYConfig.ConfigPaths` — the same source the
    // daemon uses — so GUI and daemon always look at the same files.

    /// Returns the ordered list of config file paths to load.
    static func configFilePaths() -> [URL] {
        [ConfigPaths.systemConfigURL]
    }

    /// Returns the path to user_config.txt.
    static func userConfigPath() -> URL {
        ConfigPaths.userConfigURL
    }

    /// Returns the profile directory (`~/.config/tongyou/profiles/`).
    static func profileDirectory() -> URL {
        ConfigPaths.profileDirectory
    }

    /// Returns the SSH template rules path (`~/.config/tongyou/ssh-rules.txt`).
    /// The file is optional; `SSHRuleMatcher.load` returns an empty matcher
    /// when it doesn't exist (see plan Phase 2 / Phase 9).
    static func sshRulesPath() -> URL {
        ConfigPaths.sshRulesURL
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

    /// Seed the bundled profile templates (default + SSH variants + rules)
    /// into the user's config directory the first time they are missing.
    /// Unlike `system_config.txt`, these files are **not** overwritten on
    /// subsequent launches — the user is expected to customise them.
    ///
    /// Each template is resolved from the app bundle first, then from the
    /// adjacent source directory (dev / unit-test fallback, mirroring
    /// `generateSystemConfig()`). A missing template logs a warning but
    /// never aborts launch.
    static func seedProfiles(into directory: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let profilesDir = directory.appendingPathComponent("profiles", isDirectory: true)
            try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        } catch {
            print("[config] warning: could not create profile directories: \(error)")
            return
        }

        let targets: [(resource: String, subpath: String)] = [
            ("default", "profiles/default.txt"),
            ("ssh", "profiles/ssh.txt"),
            ("ssh-dev", "profiles/ssh-dev.txt"),
            ("ssh-prod", "profiles/ssh-prod.txt"),
            ("ssh-rules", "ssh-rules.txt"),
        ]

        for (resource, subpath) in targets {
            let target = directory.appendingPathComponent(subpath)
            // Respect any user-authored version — never overwrite.
            if fm.fileExists(atPath: target.path) { continue }
            guard let contents = loadBundledProfileTemplate(resource: resource) else {
                print("[config] warning: bundled template '\(resource).txt' missing; skipping seed")
                continue
            }
            do {
                try contents.write(to: target, atomically: true, encoding: .utf8)
            } catch {
                print("[config] warning: could not seed \(subpath): \(error)")
            }
        }
    }

    /// Read a bundled profile template file (without the `.txt` suffix) from
    /// the app bundle or, when running from SwiftPM / tests, from the source
    /// tree next to this file. Returns nil when neither location has it so
    /// callers can log and continue.
    ///
    /// Profile templates live under `TongYou/Config/Profiles/` in source;
    /// inside the built .app they land at the bundle root (the synchronized
    /// file system group flattens the directory structure). The lookup
    /// tries the bundle-flat name first, then the source-tree subdirectory.
    private static func loadBundledProfileTemplate(resource: String) -> String? {
        let profileResources: Set<String> = ["default", "ssh", "ssh-dev", "ssh-prod"]
        let bundleSubdir: String? = profileResources.contains(resource) ? "Profiles" : nil

        let bundleCandidates: [URL] = [
            Bundle.main.url(forResource: resource, withExtension: "txt"),
            bundleSubdir.flatMap { Bundle.main.url(forResource: resource, withExtension: "txt", subdirectory: $0) },
        ].compactMap { $0 }

        for url in bundleCandidates {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }

        // Dev / test fallback: walk up from this source file.
        let sourceFile = URL(fileURLWithPath: #file)
        let configDir = sourceFile.deletingLastPathComponent()
        let devCandidates: [URL] = profileResources.contains(resource)
            ? [configDir.appendingPathComponent("Profiles/\(resource).txt")]
            : [configDir.appendingPathComponent("\(resource).txt")]
        for url in devCandidates {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }
        return nil
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
        let (newConfig, entries, existingPaths) = loadFromDisk(paths: paths)
        config = newConfig
        globalEntries = entries
        setupWatchers(for: existingPaths, potentialDirs: paths)
    }

    private func loadFromDisk(
        paths: [URL]? = nil
    ) -> (Config, entries: [ConfigParser.Entry], existingPaths: [String]) {
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
        return (config, allEntries, existingPaths)
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
        let (newConfig, entries, paths) = loadFromDisk()
        guard newConfig != config else { return }
        let oldConfig = config
        config = newConfig
        globalEntries = entries

        // Re-setup watchers in case new files appeared
        setupWatchers(for: paths)

        // Toggle GUILog on config hot-reload
        if oldConfig.debugLogLevel != newConfig.debugLogLevel
            || oldConfig.debugLogCategories != newConfig.debugLogCategories {
            applyGUILogConfig(newConfig)
        }

        onConfigChanged?(newConfig)
        notifyConfigObservers(newConfig)

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

    // MARK: - Profile Hot Reload

    private func loadProfilesFromDisk() {
        do {
            try profileLoader.reload()
        } catch {
            print("[config] warning: could not load profiles: \(error)")
        }
    }

    private func setupProfileWatchers() {
        for watcher in profileWatchers {
            watcher.cancel()
        }
        profileWatchers.removeAll()

        let dir = profileLoader.directoryURL
        let fm = FileManager.default

        // Watch the profile directory itself to catch file creation/deletion.
        var isDir: ObjCBool = false
        let dirExists = fm.fileExists(atPath: dir.path, isDirectory: &isDir)
        if dirExists, isDir.boolValue,
           let watcher = FileWatcher(path: dir.path, handler: { [weak self] in
               self?.scheduleProfileReload()
           }) {
            profileWatchers.append(watcher)
        }

        // Also watch every existing *.txt so in-place edits are detected.
        if dirExists, isDir.boolValue,
           let contents = try? fm.contentsOfDirectory(
               at: dir,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ) {
            for url in contents where url.pathExtension == ProfileLoader.profileFileExtension {
                if let watcher = FileWatcher(path: url.path, handler: { [weak self] in
                    self?.scheduleProfileReload()
                }) {
                    profileWatchers.append(watcher)
                }
            }
        }
    }

    private func scheduleProfileReload() {
        profileReloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performProfileReload()
        }
        profileReloadWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.debounceInterval,
            execute: item
        )
    }

    private func performProfileReload() {
        let previousIDs = Set(profileLoader.allRawProfiles.keys)
        loadProfilesFromDisk()
        let currentIDs = Set(profileLoader.allRawProfiles.keys)

        // Invalidate every currently-known and previously-known id. Reverse-dep
        // fan-out happens inside ProfileLoader.invalidate, and the resulting
        // onProfilesChanged callback is forwarded through `self.onProfilesChanged`.
        profileLoader.invalidate(profileIDs: currentIDs.union(previousIDs))

        // Re-setup watchers so newly-added .txt files are watched too.
        setupProfileWatchers()
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
