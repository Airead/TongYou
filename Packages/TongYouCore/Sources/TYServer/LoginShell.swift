import Foundation

/// Shared helpers for launching user commands through a login shell.
///
/// Both the server's `ServerSessionManager` (authoritative PTY owner) and
/// the GUI client's local `SessionManager` build identical
/// `/bin/sh -l -c "exec <escaped>"` invocations for "run a command in
/// this pane" paths. Keeping the pure string manipulation in one place
/// removes two copies that had already drifted in small ways (default
/// shell, tilde expansion).
public enum LoginShell {

    /// Resolve the user's login shell from `$SHELL`, falling back to
    /// `defaultShell` when the variable is missing or empty.
    public static func userShell(default defaultShell: String = "/bin/sh") -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return defaultShell
    }

    /// Single-quote a value for safe inclusion in a POSIX shell command.
    public static func escape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Build a `(shell, ["-l", "-c", "exec <escaped>"])` invocation that
    /// runs `command` with `arguments` inside a login shell.
    ///
    /// - Parameters:
    ///   - command: The command to run. When `expandTilde` is true the
    ///     leading `~` is expanded via `NSString.expandingTildeInPath`
    ///     before quoting.
    ///   - arguments: Extra arguments appended after the command.
    ///   - expandTilde: Whether to expand a leading `~` in `command`.
    ///     The server path launches raw user commands and wants this;
    ///     the GUI path pre-resolves command paths via `which` and
    ///     passes `false` to avoid double-expansion.
    ///   - defaultShell: Fallback shell when `$SHELL` is unset.
    public static func wrap(
        command: String,
        arguments: [String] = [],
        expandTilde: Bool = true,
        defaultShell: String = "/bin/sh"
    ) -> (command: String, arguments: [String]) {
        let shell = userShell(default: defaultShell)
        let head = expandTilde ? (command as NSString).expandingTildeInPath : command
        let parts = [head] + arguments
        let escaped = parts.map(escape).joined(separator: " ")
        return (shell, ["-l", "-c", "exec \(escaped)"])
    }
}

/// Shared fallback chain for "which cwd should a new pane start in?".
///
/// Server + local client both walk the same preference order
/// (explicit → config default → `$HOME` → `"/"`); extracting keeps the
/// chain in one place so additions (e.g. a user-configured default)
/// only need to be made once.
public enum WorkingDirectory {

    /// Resolve the working directory to use for a new process.
    ///
    /// - Parameters:
    ///   - preferred: Caller-supplied cwd (e.g. inherited from a parent
    ///     pane). Returned verbatim when non-nil.
    ///   - defaultCwd: Configured default (e.g.
    ///     `ServerConfig.defaultWorkingDirectory`).
    /// - Returns: `preferred ?? defaultCwd ?? $HOME ?? "/"`.
    public static func resolved(
        preferred: String? = nil,
        defaultCwd: String? = nil
    ) -> String {
        preferred
            ?? defaultCwd
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? "/"
    }
}
