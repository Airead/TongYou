/// Shell integration scripts sent to the child shell via environment variables.
///
/// The shell sources a small hook script that reports lifecycle events
/// back to TongYou using OSC 7727 escape sequences:
///   - `\e]7727;running-command=<cmd>\a`  — a command is about to execute
///   - `\e]7727;shell-prompt\a`           — the shell is back at a prompt
///
/// This works across SSH because the escape sequences travel through
/// the byte stream from remote shell → SSH → local PTY → TongYou.
public enum ShellIntegration {

    /// Zsh integration script.
    ///
    /// Written to disk by `ShellIntegrationInjector` and sourced
    /// via a ZDOTDIR `.zshenv` wrapper.
    public static let zsh = #"""
    # TongYou shell integration for zsh
    # Sends OSC 7727 sequences to report command lifecycle.

    __tongyou_preexec() {
        # $1 is the command string about to be executed.
        # Extract the first word (the program name).
        local cmd="${1%% *}"
        printf '\e]7727;running-command=%s\a' "$cmd"
    }

    __tongyou_precmd() {
        printf '\e]7727;shell-prompt\a'
    }

    autoload -Uz add-zsh-hook
    add-zsh-hook preexec __tongyou_preexec
    add-zsh-hook precmd __tongyou_precmd
    """#
}
