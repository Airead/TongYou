#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import Foundation
import TYServer

/// Runtime paths for the GUI automation socket and auth token.
///
/// Reuses the daemon's runtime directory convention so all TongYou
/// runtime artifacts live in one place. Per-PID filenames allow multiple
/// GUI instances to coexist.
public enum GUIAutomationPaths {
    /// Socket path for a GUI process with the given PID.
    public static func socketPath(pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String {
        runtimeDirectory().appending("/gui-\(pid).sock")
    }

    /// Token file path for a GUI process with the given PID.
    public static func tokenPath(pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String {
        runtimeDirectory().appending("/gui-\(pid).token")
    }

    /// The runtime directory holding all GUI socket/token files.
    /// Matches `ServerConfig`'s runtime directory (XDG_RUNTIME_DIR or
    /// ~/Library/Caches/tongyou).
    public static func runtimeDirectory() -> String {
        // Derive from a known file in the same directory.
        (ServerConfig.defaultSocketPath() as NSString).deletingLastPathComponent
    }

    /// Ensure the runtime directory exists with 0700 permissions.
    public static func ensureRuntimeDirectory() throws {
        let dir = runtimeDirectory()
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(dir, 0o700)
    }

    /// Scan runtime directory for `gui-*.sock` files.
    /// Returned paths are sorted by modification time, newest first.
    public static func discoverSocketPaths(in dir: String? = nil) -> [String] {
        let directory = dir ?? runtimeDirectory()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else {
            return []
        }
        let candidates = entries
            .filter { $0.hasPrefix("gui-") && $0.hasSuffix(".sock") }
            .map { (directory as NSString).appendingPathComponent($0) }

        return candidates.sorted { lhs, rhs in
            let lhsDate = (try? fm.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
            let rhsDate = (try? fm.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    /// Given a socket path like `<dir>/gui-<pid>.sock`, return the matching token path.
    /// Returns nil if the path doesn't follow the expected naming convention.
    public static func tokenPath(forSocketPath socketPath: String) -> String? {
        let name = (socketPath as NSString).lastPathComponent
        guard name.hasPrefix("gui-"), name.hasSuffix(".sock") else { return nil }
        let dir = (socketPath as NSString).deletingLastPathComponent
        let base = String(name.dropLast(".sock".count))
        return (dir as NSString).appendingPathComponent("\(base).token")
    }
}
