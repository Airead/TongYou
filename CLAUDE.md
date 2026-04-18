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

TongYouCore package tests (TYProtocolTests, TYServerTests, etc.) are not included in the Xcode TongYouTests target. Run them separately:

```bash
cd Packages/TongYouCore && swift test
```

**Avoid running multiple `xcodebuild` or `swift build`/`swift test` processes concurrently** — they compete for DerivedData / `.build` directory locks, causing hangs or build failures. Always wait for the previous build/test to finish before starting a new one. **Before every build or test, run `pgrep -fl "swift|xcodebuild"` to check for existing processes.** Only proceed when no build/test processes are active (background services like `swift-plugin-server` are fine).

**Never use real user data or system state in tests.** Use isolated/mock resources instead. If the production code doesn't expose a way to inject test doubles (e.g. it reads from a hard-coded default path), change the production code first — add a parameter, accept an injectable dependency, or route through a test-overridable default. Never work around missing seams by letting a test touch a real-user path.

Examples: use a custom `NSPasteboard(name:)` instead of `.general`; a temporary directory instead of `~/Desktop` or `~/Library/Caches/…`; in-memory `UserDefaults` instead of `.standard`; per-test socket / PID / token paths instead of the defaults under `XDG_RUNTIME_DIR`.

**Swift Testing `.serialized` trait:** Swift Testing runs `@Test` cases concurrently by default. For test suites that create real servers, sockets, or PTY processes, add `.serialized` to the `@Suite` to prevent concurrent execution within the suite:

```swift
@Suite("My Tests", .serialized)
struct MyTests { ... }
```

Note: `--no-parallel` only controls process-level parallelism (how many test runner processes are spawned), NOT Swift Testing's internal concurrency. The `.serialized` trait is the only way to serialize tests within a process.

## SwiftUI Identity

- **Never use array indices as `ForEach` `.id()` when the collection can be filtered or reordered.** Using a plain index (`0, 1, 2…`) causes SwiftUI to reuse views by position rather than by model object. When the underlying data changes (e.g. filtering a search result), the UI can end up displaying stale content even though the data is correct. Always use a stable, unique model identifier such as `session.id` for both the `ForEach` `id` parameter and any `ScrollViewReader.scrollTo` calls.

## Actor Pitfalls

- `deinit` is nonisolated. Accessing actor-isolated stored properties from `deinit` will deadlock. Use `nonisolated(unsafe)` for properties that must be read/cancelled in `deinit` (e.g. `DispatchSource`, `Task`).

## Reference

- Review [dev/ai-swift-macos-best-practices.md](dev/ai-swift-macos-best-practices.md) for AI-assisted Swift macOS development best practices including Swift 6.2 concurrency, SwiftUI architecture, and testing strategy.
