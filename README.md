# TongYou (通幽)

A GPU-accelerated terminal emulator for macOS, built with Metal and SwiftUI.

## Features

- Metal-based rendering with instanced draw calls and triple buffering
- Display-synced frame loop via CADisplayLink
- Line reflow on terminal resize
- URL detection
- Ghostty-like `key = value` configuration with hot-reload

## Build

Requires Xcode and macOS.

```bash
make build          # Debug build
make build-release  # Release build
make run            # Build and launch
make install        # Install to /Applications
make test           # Run tests
```

## Configuration

TongYou uses a `key = value` config file with hot-reload.

**Config load order** (later overrides earlier):

1. `~/.config/tongyou/system_config.txt` (auto-generated on every launch, do not edit)
2. `~/.config/tongyou/user_config.txt` (user customizations, included from system_config.txt)

On every launch, TongYou overwrites `system_config.txt` from the bundled template. To customize settings, edit `user_config.txt` — your values override all system defaults.

**System config template**: [TongYou/Config/SystemConfig.txt](TongYou/Config/SystemConfig.txt)

Use **Cmd + ,** (Preferences) to open `user_config.txt` in TextEdit.

## License

MIT
