# TongYou - Terminal Emulator for macOS

A GPU-accelerated terminal emulator built with Metal and SwiftUI.

## Build Commands

```bash
make build          # Debug build
make build-release  # Release build
make test           # Run unit tests
make clean          # Clean build artifacts
make run            # Build and launch app
```

## Architecture

- **SwiftUI** manages window lifecycle via `@main` app entry
- **NSViewRepresentable** bridges `MetalView` (NSView subclass) into SwiftUI
- **Metal** renders directly to `CAMetalLayer` with instanced draw calls
- **CADisplayLink** drives the frame loop synced to display refresh rate

## Coding Conventions

- All CPU-side sizes use integer types (UInt32/UInt16); convert to Float only when filling GPU Uniforms
- Triple-buffered rendering with DispatchSemaphore(value: 3)
- Premultiplied alpha blending for all render pipelines
- `floor()` pixel alignment in shaders to avoid subpixel gaps

## Bundle ID

The app bundle identifier is `io.github.airead.tongyou`. Use `io.github.airead.tongyou.*` as the prefix for DispatchQueue labels and other reverse-DNS identifiers.

## Concurrency

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — all code runs on MainActor by default.
- Use `@concurrent` for async work that should run off the main actor (network, IO, heavy computation).
- Mark pure data functions as `nonisolated`.
- Prefer Swift actor over manual locking (NSLock, DispatchQueue) for thread-safe shared state.

## Testing

Run unit tests with parallel testing disabled and skip UI tests:

```bash
xcodebuild test -scheme TongYou -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:TongYouTests
```

**Avoid running multiple `xcodebuild` processes concurrently** — they compete for DerivedData and CodeSign, causing hangs or build failures. Always wait for the previous build/test to finish before starting a new one.

**Never use real user data in tests.** Use isolated/mock resources instead of the real system state. For example, use a custom `NSPasteboard(name:)` instead of `.general`, use a temporary directory instead of `~/Desktop`, and use in-memory `UserDefaults` instead of `.standard`.

## Actor Pitfalls

- `deinit` is nonisolated. Accessing actor-isolated stored properties from `deinit` will deadlock. Use `nonisolated(unsafe)` for properties that must be read/cancelled in `deinit` (e.g. `DispatchSource`, `Task`).

## Reference

- Review [dev/ai-swift-macos-best-practices.md](dev/ai-swift-macos-best-practices.md) for AI-assisted Swift macOS development best practices including Swift 6.2 concurrency, SwiftUI architecture, and testing strategy.
