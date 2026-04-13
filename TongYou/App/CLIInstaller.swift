import Foundation

/// Handles installing and uninstalling the tongyou CLI tool as a symlink in /usr/local/bin.
enum CLIInstaller {

    /// Path where the symlink will be created.
    static let installPath = "/usr/local/bin/tongyou"

    /// Path to the CLI binary bundled inside the app.
    static var bundledCLIPath: String? {
        let resourcePath = Bundle.main.resourceURL?
            .appendingPathComponent("app/bin/tongyou").path
        guard let path = resourcePath,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    /// Whether the CLI is currently installed (symlink exists and points to our bundle).
    static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: installPath) else { return false }
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: installPath) else {
            return false
        }
        return dest == bundledCLIPath
    }

    /// Install the CLI by creating a symlink at /usr/local/bin/tongyou.
    /// Uses AppleScript to request admin privileges (single prompt).
    static func install() throws {
        guard let source = bundledCLIPath else {
            throw CLIInstallerError.cliNotFoundInBundle
        }

        let escaped = shellEscape(source)
        try runPrivileged(
            "mkdir -p /usr/local/bin && rm -f \(shellEscape(installPath)) && ln -s \(escaped) \(shellEscape(installPath))"
        )
    }

    /// Uninstall the CLI by removing the symlink.
    static func uninstall() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: installPath) else { return }
        try runPrivileged("rm -f \(shellEscape(installPath))")
    }

    /// Escape a string for safe use inside a single-quoted shell argument.
    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Execute a shell command with administrator privileges via AppleScript.
    private static func runPrivileged(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: script) else {
            throw CLIInstallerError.scriptCreationFailed
        }
        var errorDict: NSDictionary?
        appleScript.executeAndReturnError(&errorDict)
        if let error = errorDict {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            throw CLIInstallerError.privilegedCommandFailed(message)
        }
    }
}

enum CLIInstallerError: LocalizedError {
    case cliNotFoundInBundle
    case scriptCreationFailed
    case privilegedCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFoundInBundle:
            "The tongyou CLI binary was not found in the application bundle."
        case .scriptCreationFailed:
            "Failed to create the privilege escalation script."
        case .privilegedCommandFailed(let message):
            "Privileged command failed: \(message)"
        }
    }
}
