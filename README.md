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

## License

MIT
