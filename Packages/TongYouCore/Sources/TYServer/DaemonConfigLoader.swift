import Foundation
import TYConfig

/// Loads daemon-specific configuration from the shared user config file.
///
/// Reads `daemon-` prefixed keys from `~/.config/tongyou/user_config.txt`
/// (resolved via `ConfigPaths`, which is also used by the GUI) and applies
/// them to a `ServerConfig`. Supports hot reload via file system watching.
///
/// Supported keys:
/// - `daemon-scrollback-limit` — max scrollback lines (Int, ≥ 0)
/// - `daemon-min-coalesce-delay` — min screen update delay in seconds (Float, > 0)
/// - `daemon-max-coalesce-delay` — max screen update delay in seconds (Float, > 0)
/// - `daemon-max-pending-screen-updates` — per-client queue limit (Int, > 0)
/// - `daemon-synced-update-timeout` — DECSET 2026 safety timeout in seconds
///   (Float, > 0). Snapshot delivery resumes after this many seconds if the
///   app never closes the sync window (crash protection).
/// - `daemon-stats-interval` — stats logging interval in seconds (Float, ≥ 0; 0 disables)
/// - `daemon-auto-exit-on-no-sessions` — exit when last session closes (Bool)
/// - `daemon-debug-log-level` — file log level: off/debug/info/warning/error (empty = CLI default).
///   File path: `~/.local/share/TongYou/logs/daemon-YYYY-MM-DD.log`.
/// - `daemon-debug-log-categories` — comma-separated category whitelist
///   from {`server`, `session`, `client`, `cursorTrace`} (empty = all).
public final class DaemonConfigLoader: @unchecked Sendable {

    /// Called on the main queue when configuration changes after a hot reload.
    /// The callback receives the new `ServerConfig`.
    public var onConfigChanged: ((ServerConfig) -> Void)?

    /// Current configuration built from file + defaults.
    public private(set) var config: ServerConfig

    /// Base config to merge file values onto (preserves non-file fields like socketPath).
    private let baseConfig: ServerConfig

    private let parser = ConfigParser()

    // File watching state — nonisolated(unsafe) for deinit access.
    nonisolated(unsafe) private var watchers: [FileWatcher] = []
    private var reloadWorkItem: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.2

    public init(baseConfig: ServerConfig = ServerConfig()) {
        self.baseConfig = baseConfig
        self.config = baseConfig
    }

    deinit {
        reloadWorkItem?.cancel()
        for watcher in watchers {
            watcher.cancel()
        }
        watchers.removeAll()
    }

    // MARK: - Public API

    /// Load configuration from disk and start watching for changes.
    public func load() {
        let (newConfig, paths) = loadFromDisk()
        config = newConfig
        setupWatchers(for: paths)
    }

    /// Load configuration once without watching (for testing or one-shot use).
    public func loadOnce() {
        let (newConfig, _) = loadFromDisk()
        config = newConfig
    }

    /// Load from explicit URLs (for testing).
    public func load(from urls: [URL]) {
        let (newConfig, paths) = loadFromDisk(urls: urls)
        config = newConfig
        setupWatchers(for: paths)
    }

    // MARK: - Private: Loading

    private func loadFromDisk(urls: [URL]? = nil) -> (ServerConfig, existingPaths: [String]) {
        let fileURLs = urls ?? [ConfigPaths.userConfigURL]
        var allEntries: [ConfigParser.Entry] = []
        var existingPaths: [String] = []

        for url in fileURLs {
            do {
                let entries = try parser.parse(contentsOf: url)
                allEntries.append(contentsOf: entries)
                existingPaths.append(url.path)
            } catch {
                // File doesn't exist or isn't readable — use defaults silently
                Log.debug("[daemon-config] could not read \(url.path): \(error)")
            }
        }

        let newConfig = Self.apply(entries: allEntries, to: baseConfig)
        return (newConfig, existingPaths)
    }

    /// Apply daemon-prefixed entries onto a base ServerConfig.
    static func apply(entries: [ConfigParser.Entry], to base: ServerConfig) -> ServerConfig {
        var config = base

        for entry in entries {
            do {
                try applyEntry(key: entry.key, value: entry.value, to: &config)
            } catch {
                Log.warning("[daemon-config] \(error)")
            }
        }

        return config
    }

    private static func applyEntry(key: String, value: String, to config: inout ServerConfig) throws {
        switch key {
        case "daemon-scrollback-limit":
            if value.isEmpty {
                config.maxScrollback = ServerConfig.defaultMaxScrollback
            } else {
                guard let v = Int(value), v >= 0 else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                config.maxScrollback = v
            }

        case "daemon-min-coalesce-delay":
            if value.isEmpty {
                config.minCoalesceDelay = ServerConfig.defaultMinCoalesceDelay
            } else {
                guard let v = Double(value), v > 0 else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                config.minCoalesceDelay = v
            }

        case "daemon-max-coalesce-delay":
            if value.isEmpty {
                config.maxCoalesceDelay = ServerConfig.defaultMaxCoalesceDelay
            } else {
                guard let v = Double(value), v > 0 else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                config.maxCoalesceDelay = v
            }

        case "daemon-max-pending-screen-updates":
            if value.isEmpty {
                config.maxPendingScreenUpdates = ServerConfig.defaultMaxPendingScreenUpdates
            } else {
                guard let v = Int(value), v > 0 else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                config.maxPendingScreenUpdates = v
            }

        case "daemon-synced-update-timeout":
            if value.isEmpty {
                config.syncedUpdateTimeout = ServerConfig.defaultSyncedUpdateTimeout
            } else {
                guard let v = Double(value), v > 0 else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                config.syncedUpdateTimeout = v
            }

        case "daemon-stats-interval":
            if value.isEmpty {
                config.statsInterval = ServerConfig.defaultStatsInterval
            } else {
                guard let v = Double(value), v >= 0 else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                config.statsInterval = v
            }

        case "daemon-auto-exit-on-no-sessions":
            if value.isEmpty {
                config.autoExitOnNoSessions = ServerConfig.defaultAutoExitOnNoSessions
            } else {
                guard let v = parseBool(value) else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                config.autoExitOnNoSessions = v
            }

        case "daemon-debug-log-level":
            if value.isEmpty {
                config.debugLogLevel = ServerConfig.defaultDebugLogLevel
            } else {
                let v = value.lowercased()
                guard ["off", "debug", "info", "warning", "warn", "error"].contains(v) else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                config.debugLogLevel = v == "warn" ? "warning" : v
            }

        case "daemon-debug-log-categories":
            if value.isEmpty {
                config.debugLogCategories = ServerConfig.defaultDebugLogCategories
            } else {
                config.debugLogCategories = Set(
                    value.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                )
            }

        default:
            // Non-daemon keys are silently ignored.
            break
        }
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    // MARK: - Private: Hot Reload

    private func setupWatchers(for paths: [String]) {
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

        // Watch the config directory so we detect file creation
        let dir = ConfigPaths.configDirectory.path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
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

        setupWatchers(for: paths)

        onConfigChanged?(newConfig)

        logConfigDiff(old: oldConfig, new: newConfig)
    }

    private func logConfigDiff(old: ServerConfig, new: ServerConfig) {
        var changes: [String] = []
        if old.maxScrollback != new.maxScrollback {
            changes.append("daemon-scrollback-limit=\(new.maxScrollback)")
        }
        if old.minCoalesceDelay != new.minCoalesceDelay {
            changes.append("daemon-min-coalesce-delay=\(new.minCoalesceDelay)")
        }
        if old.maxCoalesceDelay != new.maxCoalesceDelay {
            changes.append("daemon-max-coalesce-delay=\(new.maxCoalesceDelay)")
        }
        if old.maxPendingScreenUpdates != new.maxPendingScreenUpdates {
            changes.append("daemon-max-pending-screen-updates=\(new.maxPendingScreenUpdates)")
        }
        if old.syncedUpdateTimeout != new.syncedUpdateTimeout {
            changes.append("daemon-synced-update-timeout=\(new.syncedUpdateTimeout)")
        }
        if old.statsInterval != new.statsInterval {
            changes.append("daemon-stats-interval=\(new.statsInterval)")
        }
        if old.autoExitOnNoSessions != new.autoExitOnNoSessions {
            changes.append("daemon-auto-exit-on-no-sessions=\(new.autoExitOnNoSessions)")
        }
        if old.debugLogLevel != new.debugLogLevel {
            changes.append("daemon-debug-log-level=\(new.debugLogLevel.isEmpty ? "<unset>" : new.debugLogLevel)")
        }
        if old.debugLogCategories != new.debugLogCategories {
            let list = new.debugLogCategories.sorted().joined(separator: ",")
            changes.append("daemon-debug-log-categories=\(list.isEmpty ? "<all>" : list)")
        }
        if !changes.isEmpty {
            Log.info("[daemon-config] reloaded: \(changes.joined(separator: ", "))")
        }
    }
}

// MARK: - FileWatcher

/// Watches a single file or directory for changes using DispatchSource.
final class FileWatcher: @unchecked Sendable {
    // nonisolated(unsafe) because deinit must cancel without actor hop.
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    private let fd: Int32

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
