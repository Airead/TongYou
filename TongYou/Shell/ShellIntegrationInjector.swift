import Foundation

/// Writes shell integration scripts to disk and sets environment variables
/// so the child shell automatically sources them.
///
/// For zsh, uses the ZDOTDIR override technique:
/// 1. Write the integration script to `<supportDir>/shell-integration.zsh`
/// 2. Create a `.zshenv` wrapper in `<supportDir>/zsh/` that:
///    a. Restores the original ZDOTDIR
///    b. Sources the real user `.zshenv`
///    c. Sources TongYou's integration script
/// 3. Set `ZDOTDIR` to `<supportDir>/zsh/` so zsh picks up the wrapper
enum ShellIntegrationInjector {

    static let defaultSupportDir: String = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.path
        return base + "/io.github.airead.tongyou"
    }()

    /// Inject zsh shell integration into the environment.
    /// - Parameter baseDir: Override for tests. Defaults to Application Support.
    static func injectZsh(into env: inout [String: String], baseDir: String? = nil) {
        let dir = baseDir ?? defaultSupportDir
        let integrationPath = dir + "/shell-integration.zsh"
        let zdotdirPath = dir + "/zsh"

        do {
            try ensureDirectory(zdotdirPath)
            try ShellIntegration.zsh.write(
                toFile: integrationPath, atomically: true, encoding: .utf8
            )
            try writeZshenvWrapper(
                to: zdotdirPath + "/.zshenv",
                originalZdotdir: env["ZDOTDIR"],
                integrationScript: integrationPath
            )
        } catch {
            return
        }

        env["TONGYOU_ORIG_ZDOTDIR"] = env["ZDOTDIR"] ?? ""
        env["ZDOTDIR"] = zdotdirPath
    }

    private static func writeZshenvWrapper(
        to path: String,
        originalZdotdir: String?,
        integrationScript: String
    ) throws {
        let restoreZdotdir: String
        if let orig = originalZdotdir {
            restoreZdotdir = "ZDOTDIR='\(shellEscape(orig))'"
        } else {
            restoreZdotdir = "unset ZDOTDIR"
        }

        let realZshenv: String
        if let orig = originalZdotdir, !orig.isEmpty {
            realZshenv = orig + "/.zshenv"
        } else {
            realZshenv = (ProcessInfo.processInfo.environment["HOME"] ?? "~") + "/.zshenv"
        }

        let wrapper = """
        \(restoreZdotdir)
        if [[ -f '\(shellEscape(realZshenv))' ]]; then
            source '\(shellEscape(realZshenv))'
        fi
        source '\(shellEscape(integrationScript))'
        """

        try wrapper.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func ensureDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true
        )
    }

    /// Escape a string for use inside single-quoted shell literals.
    /// Replaces `'` with `'\''` (end quote, escaped quote, reopen quote).
    private static func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }
}
