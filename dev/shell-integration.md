# Shell Integration

TongYou uses zsh shell integration to detect which command is running in the terminal. This enables features like **auto-passthrough**: when a program in the passthrough list (e.g. `zellij`) is running, TongYou forwards non-Cmd keybindings directly to the program instead of handling them locally.

## How It Works

TongYou installs zsh `preexec`/`precmd` hooks that send custom OSC 7727 escape sequences:

- **`preexec`** — fires before a command executes, sends `\e]7727;running-command=<cmd>\a`
- **`precmd`** — fires when the shell returns to the prompt, sends `\e]7727;shell-prompt\a`

On the local machine, these hooks are injected automatically via the ZDOTDIR override technique. No manual setup is needed.

## Remote Server Setup

When you SSH to a remote server, the local hooks report `running-command=ssh`. To detect programs running **inside** the SSH session (e.g. `zellij` on the remote server), add the following to the remote server's `~/.zshrc`:

```zsh
# TongYou shell integration
__tongyou_preexec() {
    local cmd="${1%% *}"
    printf '\e]7727;running-command=%s\a' "$cmd"
}
__tongyou_precmd() {
    printf '\e]7727;shell-prompt\a'
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec __tongyou_preexec
add-zsh-hook precmd __tongyou_precmd
```

This works because the OSC escape sequences travel through the SSH byte stream back to TongYou on your local machine.

## Configuration

Control which programs trigger passthrough mode in TongYou's config file (`~/.config/tongyou/config`):

```
# Default: zellij
auto-passthrough-programs = zellij

# Add aliases or other programs as needed
auto-passthrough-programs = zellij, zj, tmux, vim
```

You can also manually unbind specific keybindings regardless of the running program:

```
keybind = opt+f=unbind
```

## Supported Shells

| Shell | Local (automatic) | Remote (manual setup) |
|-------|-------------------|-----------------------|
| zsh   | ✓                 | ✓ (add snippet to `~/.zshrc`) |
| bash  | —                 | — |
| fish  | —                 | — |
