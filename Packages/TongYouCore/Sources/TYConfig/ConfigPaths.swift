import Foundation

/// File-system paths for user-visible TongYou configuration.
///
/// Both the GUI client and the daemon resolve their config files through
/// this single source of truth, so the two processes always read the same
/// files regardless of how each was launched (Dock/Spotlight for the GUI,
/// `tongyou daemon` from a shell for the daemon, etc.).
///
/// `$XDG_CONFIG_HOME` is intentionally **not** honored. GUI apps launched
/// from Finder do not inherit the shell's environment, so honoring XDG
/// would silently desync the daemon (which does see the shell env) from
/// the GUI. Pinning both to `~/.config/tongyou/` avoids that footgun.
public enum ConfigPaths {

    /// Override the config root for tests. Leaving this `nil` uses
    /// `~/.config/tongyou/`. Do not set from production code.
    nonisolated(unsafe) public static var rootOverride: URL?

    /// Root config directory (`~/.config/tongyou/`) unless overridden.
    public static var configDirectory: URL {
        if let override = rootOverride { return override }
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config/tongyou", isDirectory: true)
    }

    /// `user_config.txt` — user-editable settings, shared by GUI and daemon.
    public static var userConfigURL: URL {
        configDirectory.appendingPathComponent("user_config.txt")
    }

    /// `system_config.txt` — regenerated on every GUI launch from the bundled
    /// template. Users should not edit this file directly.
    public static var systemConfigURL: URL {
        configDirectory.appendingPathComponent("system_config.txt")
    }

    /// `profiles/` — per-pane profile overlays.
    public static var profileDirectory: URL {
        configDirectory.appendingPathComponent("profiles", isDirectory: true)
    }

    /// `ssh-rules.txt` — optional glob rules for SSH template resolution.
    public static var sshRulesURL: URL {
        configDirectory.appendingPathComponent("ssh-rules.txt")
    }
}
