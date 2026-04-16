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

1. `~/.config/tongyou/config`
2. `~/Library/Application Support/io.github.airead.tongyou/config`
3. Files included via `config-file = ?path`

On first run, if no config file exists, TongYou generates a default one at `~/.config/tongyou/config` from the bundled template.

**Default config template**: [TongYou/Config/DefaultConfig.txt](TongYou/Config/DefaultConfig.txt)

Use **Cmd + ,** (Preferences) to open the default config in TextEdit.

## License

MIT
