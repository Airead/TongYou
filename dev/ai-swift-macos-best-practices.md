# Best Practices for AI-Assisted Swift macOS App Development (2026)

> Last updated: April 2026

This document provides coding best practices for developing macOS applications with Swift and SwiftUI, covering concurrency, architecture, and testing.

---

## Table of Contents

1. [Swift 6.2 Concurrency Best Practices](#1-swift-62-concurrency-best-practices)
2. [SwiftUI macOS Architecture](#2-swiftui-macos-architecture)
3. [Testing Strategy](#3-testing-strategy)
4. [Common Pitfalls and How to Avoid Them](#4-common-pitfalls-and-how-to-avoid-them)
5. [Sources](#5-sources)

---

## 1. Swift 6.2 Concurrency Best Practices

Swift 6.2 (released with Xcode 26) introduced **Approachable Concurrency**, fundamentally changing the default concurrency model.

### Default MainActor Isolation

New Xcode projects have **Approachable Concurrency** turned on with `Default Actor Isolation` set to `MainActor`. This means:

- Everything runs on the `@MainActor` by default — no more accidental data races for simple code.
- You opt *out* into concurrency when needed, rather than opting *in* to thread safety.

**Enable it** via:
- Build setting: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- Or compiler flag: `-default-isolation MainActor`
- Or in Package.swift: `defaultIsolation(MainActor.self)`

### When to Use `@concurrent`

Use the new `@concurrent` attribute for functions that should explicitly run off the main actor:

```swift
// Runs on MainActor by default (Swift 6.2)
func updateUI() {
    // Safe to touch UI directly
}

// Explicitly concurrent — runs off MainActor
@concurrent
func fetchData() async throws -> [Item] {
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode([Item].self, from: data)
}
```

### `nonisolated` for Caller-Inherited Isolation

Use `nonisolated` when a function should inherit the caller's actor context:

```swift
nonisolated func process(_ data: Data) -> Result {
    // Inherits caller's isolation
}
```

### Actor for Shared Mutable State

Prefer Swift `actor` over manual locking (`NSLock`, `DispatchQueue`) for thread-safe shared state:

```swift
actor DataStore {
    private var items: [Item] = []

    func add(_ item: Item) {
        items.append(item)
    }

    func getAll() -> [Item] {
        items
    }
}
```

### Library / SPM Package Considerations

For SPM packages (especially networking or utility packages), **do not** default to MainActor isolation. Libraries should remain `nonisolated` by default and let the app layer decide isolation.

---

## 2. SwiftUI macOS Architecture

### Modern MVVM with @Observable

The `@Observable` macro (introduced in iOS 17 / macOS 14) replaces the older `ObservableObject` + `@Published` pattern:

```swift
@Observable
final class ItemListViewModel {
    var items: [Item] = []
    var isLoading = false
    var errorMessage: String?

    private let repository: ItemRepository

    init(repository: ItemRepository) {
        self.repository = repository
    }

    func loadItems() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await repository.fetchItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

### macOS-Specific Considerations

Desktop apps have unique requirements beyond mobile:

- **Multiple windows**: Use `WindowGroup`, `Window`, and `Settings` scenes.
- **Menu bar**: Define menus with `CommandGroup` and `CommandMenu`.
- **Keyboard shortcuts**: Add `.keyboardShortcut()` modifiers liberally.
- **Drag and drop**: Implement `onDrop`, `draggable`, and `transferable`.
- **System services**: Integrate with Spotlight, Shortcuts, and system notifications.
- **Performance**: SwiftUI lists on macOS can now handle 10,000+ items responsively (as of 2025).

---

## 3. Testing Strategy

### Swift Testing Framework (Preferred for New Tests)

Apple's Swift Testing framework (introduced at WWDC 2024) simplifies test writing:

```swift
import Testing

@Suite("ItemStore Tests")
struct ItemStoreTests {
    @Test("Adding an item increases count")
    func addItem() async {
        let store = ItemStore()
        await store.add(Item(name: "Test"))
        let count = await store.items.count
        #expect(count == 1)
    }

    @Test("Empty store returns no items")
    func emptyStore() async {
        let store = ItemStore()
        let items = await store.items
        #expect(items.isEmpty)
    }
}
```

Key advantages over XCTest:
- Single `#expect` macro replaces dozens of `XCTAssert*` methods.
- Supports structs, classes, and actors as test suites.
- Built-in tagging system for organizing tests.
- Native async/await support.

### Migration Strategy

- Write **new tests** with Swift Testing.
- **Gradually migrate** existing XCTest cases — both frameworks coexist in the same target.
- Keep UI tests in XCTest/XCUITest for now (Swift Testing doesn't cover UI automation yet).

### Testing Best Practices

1. **Isolate view logic from business rules** — extract state management into dedicated ViewModels or actors.
2. **Test actors directly** — actors are first-class testable units with async interfaces.
3. **Use async/await in tests** — aligns test flow with modern app code.
4. **Cover both happy paths and edge cases** — especially for concurrency-related code.
5. **Prefer real implementations over mocks** for storage/database tests when feasible.

---

## 4. Common Pitfalls and How to Avoid Them

| Pitfall | Solution |
|---|---|
| AI generates iOS-only code for macOS | Explicitly state "macOS" in prompts; review for `UIKit` references |
| Outdated concurrency patterns (`DispatchQueue.main.async`) | Use Swift 6.2 with `@MainActor` default isolation |
| Over-mocking in tests | Prefer real implementations; use actors for testable boundaries |
| AI generates `ObservableObject` instead of `@Observable` | Specify "use @Observable macro" in prompts or instruction files |
| Xcode agent misconfigures concurrency settings | Verify `SWIFT_DEFAULT_ACTOR_ISOLATION` build setting after agent edits |
| Library code inheriting MainActor default | Set SPM packages to `nonisolated` default explicitly |

---

## 5. Sources

- [Approachable Concurrency in Swift 6.2 — SwiftLee](https://www.avanderlee.com/concurrency/approachable-concurrency-in-swift-6-2-a-clear-guide/)
- [Should you opt-in to Swift 6.2's Main Actor isolation? — Donny Wals](https://www.donnywals.com/should-you-opt-in-to-swift-6-2s-main-actor-isolation/)
- [Exploring concurrency changes in Swift 6.2 — Donny Wals](https://www.donnywals.com/exploring-concurrency-changes-in-swift-6-2/)
- [Swift 6.2 Released — Swift.org](https://www.swift.org/blog/swift-6.2-released/)
- [SwiftUI for Mac 2025 — TrozWare](https://troz.net/post/2025/swiftui-mac-2025/)
- [How to Build macOS Applications with SwiftUI — OneUptime](https://oneuptime.com/blog/post/2026-02-02-swiftui-macos-applications/view)
- [Modern MVVM in SwiftUI 2025 — Medium](https://medium.com/@minalkewat/modern-mvvm-in-swiftui-2025-the-clean-architecture-youve-been-waiting-for-72a7d576648e)
- [Mastering the Swift Testing Framework — Fatbobman](https://fatbobman.com/en/posts/mastering-the-swift-testing-framework/)
- [Swift Testing: Writing a Modern Unit Test — SwiftLee](https://www.avanderlee.com/swift-testing/modern-unit-test/)
- [Embracing Swift concurrency — WWDC25 — Apple Developer](https://developer.apple.com/videos/play/wwdc2025/268/)
