# Hierarchical Terminal Management Implementation Plan

## Background

TongYou's current window structure is flat: `TerminalWindowView` holds one `TabManager`, each Tab maps 1:1 to a `MetalView` (one PTY). The goal is to implement three-level hierarchy (Session → Tab → Pane) plus floating panes, similar to Zellij.

## Target Architecture

```
Window
 ├─ Sidebar: Session list (collapsible)
 └─ Detail:
     ├─ TabBar: tabs of active session
     └─ ZStack:
         ├─ PaneSplitView (binary tree of fixed panes)
         └─ FloatingPaneView × N (draggable, resizable, z-ordered)
```

---

## Phase 1: Introduce Pane Abstraction (No Behavior Change)

**Goal**: Introduce `TerminalPane` and `PaneNode` types, migrate `MetalViewStore` key from Tab ID to Pane ID. Visible behavior stays identical (one pane per tab).

### New Files
| File | Description |
|------|-------------|
| `TongYou/App/TerminalPane.swift` | `TerminalPane` struct: `id: UUID`, `initialWorkingDirectory: String?` |
| `TongYou/App/PaneNode.swift` | `PaneNode` indirect enum: `.leaf(TerminalPane)` / `.split(direction, ratio, first, second)` with helpers: `allPanes`, `findPane(id:)` |
| `TongYou/App/PaneSplitView.swift` | Recursive SwiftUI view rendering `PaneNode`; phase 1 handles `.leaf` only |
| `TongYou/App/TerminalPaneContainerView.swift` | Extracted from `TerminalTabContainerView`; `NSViewRepresentable` keyed by `paneID` |
| `TongYouTests/PaneNodeTests.swift` | Unit tests for `PaneNode` tree operations |

### Modified Files
| File | Change |
|------|--------|
| `App/TabManager.swift` | `TerminalTab` gains `paneTree: PaneNode`; init creates `.leaf(TerminalPane(...))`; add `allPaneIDs` computed property |
| `App/TerminalWindowView.swift` | `MetalViewStore` key: tab ID → pane ID; replace `TerminalTabContainerView` with `PaneSplitView`; `closeTab` iterates `allPaneIDs` to tear down; remove old `TerminalTabContainerView` |

### Verification
- `make build` compiles, `make run` behaves identically to current version
- Tab create, switch, close all work
- `PaneNodeTests` pass: `allPanes`, `findPane`, tree traversal
- `make test` passes

---

## Phase 2: Pane Splitting + Focus Management

**Goal**: Split active pane horizontally/vertically, render binary tree recursively, drag to resize, track focused pane.

### New Files
| File | Description |
|------|-------------|
| `TongYou/App/FocusManager.swift` | `@Observable` class tracking `focusedPaneID: UUID?` with focus switching logic |
| `TongYou/App/PaneDividerView.swift` | Draggable divider view using `DragGesture` to adjust ratio (0.1~0.9) |
| `TongYouTests/PaneSplitTests.swift` | Tests for split, remove, nested split scenarios |

### Modified Files
| File | Change |
|------|--------|
| `App/PaneNode.swift` | Add `split(paneID:direction:)`, `removePane(id:)`, `updateRatio(...)` mutation methods |
| `App/PaneSplitView.swift` | Implement `.split` branch: `GeometryReader` + manual frame calculation; focused pane gets border highlight |
| `App/TabManager.swift` | Add `splitActivePane(direction:)`, `closePane(id:)` methods |
| `App/TerminalWindowView.swift` | Instantiate `FocusManager`, pass to `PaneSplitView`, handle new actions |
| `App/TerminalPaneContainerView.swift` | Add click-to-focus: `onFocused` callback updates `FocusManager` |
| `Config/Keybinding.swift` | New actions: `.splitHorizontal`, `.splitVertical`, `.closePane`, `.focusPaneLeft/Right/Up/Down` |
| `Renderer/MetalView.swift` | `performAction` gains new action branches |
| `Config/Config.swift` | Append default keybindings |

### New Keybindings
| Keybinding | Action |
|------------|--------|
| `Cmd+D` | Split vertically |
| `Cmd+Shift+D` | Split horizontally |
| `Cmd+Shift+W` | Close current pane |
| `Cmd+Option+Arrow` | Directional focus navigation |

### Verification
- `Cmd+D` splits into two terminals with independent shells
- Drag divider to resize proportionally
- `Cmd+Shift+W` closes pane, sibling promoted to parent
- Last pane close → tab close → last tab close → window close
- Click pane to focus (border highlight), keyboard input goes to focused pane only
- Directional focus navigation works
- `make test` passes

---

## Phase 3: Floating Panes

**Goal**: Per-tab multiple floating panes that are draggable, resizable, z-ordered, auto-hide on tab switch.

### New Files
| File | Description |
|------|-------------|
| `TongYou/App/FloatingPane.swift` | `FloatingPane` struct: `id`, `pane: TerminalPane`, `frame: CGRect` (ratios 0~1), `isVisible`, `zIndex` |
| `TongYou/App/FloatingPaneView.swift` | Single floating pane view: title bar (drag to move) + edge drag resize + close button |
| `TongYou/App/FloatingPaneOverlay.swift` | Container: `ZStack` rendering all visible floating panes sorted by `zIndex` |
| `TongYouTests/FloatingPaneTests.swift` | z-order, visibility toggle, frame clamping tests |

### Modified Files
| File | Change |
|------|--------|
| `App/TabManager.swift` | `TerminalTab` gains `floatingPanes: [FloatingPane]`; add `createFloatingPane`, `closeFloatingPane`, `bringToFront`, `updateFrame` methods |
| `App/TerminalWindowView.swift` | Tab content becomes `ZStack { PaneSplitView; FloatingPaneOverlay }`; tab switch auto-hides/shows floating panes |
| `App/FocusManager.swift` | Focus can target fixed or floating pane (unified by paneID) |
| `Config/Keybinding.swift` | New actions: `.newFloatingPane`, `.toggleFloatingPanes` |
| `Renderer/MetalView.swift` | `performAction` gains floating pane actions |

### New Keybindings
| Keybinding | Action |
|------------|--------|
| `Cmd+Shift+F` | New floating pane |
| `Cmd+Shift+G` | Toggle all floating panes visibility |

### Verification
- `Cmd+Shift+F` creates centered floating pane with independent shell
- Drag title bar to move, drag edges to resize
- Click floating pane to bring to front + focus
- Multiple floating panes coexist with correct z-order
- Switch tab → floating panes hide; switch back → restore
- Close floating pane correctly tears down MetalView
- `make test` passes

---

## Phase 4: Session Management + Sidebar

**Goal**: Introduce `TerminalSession` as tab container, add collapsible sidebar for session list and switching.

### New Files
| File | Description |
|------|-------------|
| `TongYou/App/TerminalSession.swift` | `TerminalSession` struct: `id`, `name`, `tabs[]`, `activeTabIndex` |
| `TongYou/App/SessionManager.swift` | `@Observable` class managing `[TerminalSession]` + `activeSessionIndex`; absorbs `TabManager` logic |
| `TongYou/App/SessionSidebarView.swift` | Sidebar view: session list + new button + context menu (rename, close) |
| `TongYouTests/SessionManagerTests.swift` | Session CRUD, switching, tab operations within session |

### Modified Files
| File | Change |
|------|--------|
| `App/TerminalWindowView.swift` | `@State sessionManager` replaces `@State tabManager`; layout becomes `HSplitView { Sidebar; Detail }` or conditional; sidebar hidden with 1 session |
| `App/TabBarView.swift` | Data source from sessionManager's active session |
| `App/TabManager.swift` | Logic absorbed by `SessionManager`; may be removed or kept as internal helper |
| `Config/Keybinding.swift` | New actions: `.newSession`, `.closeSession`, `.previousSession`, `.nextSession`, `.toggleSidebar` |
| `Renderer/MetalView.swift` | `performAction` gains session actions |

### New Keybindings
| Keybinding | Action |
|------------|--------|
| `Cmd+Shift+N` | New session |
| `Cmd+Ctrl+Left` | Previous session |
| `Cmd+Ctrl+Right` | Next session |
| `Cmd+Option+S` | Toggle sidebar visibility |

### Verification
- App starts with 1 session, sidebar hidden
- `Cmd+Shift+N` creates second session, sidebar appears
- Click sidebar to switch session; each session has independent tabs/panes/floating panes
- Session rename via context menu
- Close last session → window close
- All prior functionality works within each session
- `make test` passes

---

## Phase 5: Polish and Edge Cases

**Goal**: Handle edge cases, focus recovery, config options, resource cleanup.

### Modified Files
| File | Change |
|------|--------|
| `Config/Config.swift` | Add `sidebarVisibility: SidebarVisibility` (auto/always/never) |
| `App/FocusManager.swift` | Auto-focus nearest sibling when focused pane closes; restore focus on session/tab switch |
| `App/PaneSplitView.swift` | Minimum size constraints on split; double-click divider to equalize (50:50) |
| `App/FloatingPaneView.swift` | Clamp floating pane frame on window resize |
| `App/TerminalWindowView.swift` | Window close tears down all sessions/tabs/panes; process exit closes pane (not whole tab) |

### New Tests
| File | Description |
|------|-------------|
| `TongYouTests/IntegrationTests.swift` | Cross-hierarchy scenarios: create session → split pane → add floating pane → switch session → switch back → verify state |

### Verification
- Config `sidebar = never` hides sidebar permanently
- Focus auto-moves to valid pane after closing focused one
- Window close stops all PTY processes, no MetalView leaks
- `make test` passes

---

## Key File Index

| File Path | Role |
|-----------|------|
| `TongYou/App/TerminalWindowView.swift` | Core modification point every phase, window root view |
| `TongYou/App/TabManager.swift` | Phases 1-3 extend, phase 4 absorbed by SessionManager |
| `TongYou/Config/Keybinding.swift` | New actions every phase |
| `TongYou/Renderer/MetalView.swift` | `performAction` routes new actions |
| `TongYou/Config/Config.swift` | Default keybindings and new config keys |

## MetalViewStore Migration Path

- **Phase 1**: Key changes from `TerminalTab.id` → `TerminalPane.id` (still one pane per tab, same behavior)
- **Phase 2+**: One tab maps to multiple MetalView entries (each leaf in split tree + each floating pane)
- **Teardown**: Closing a tab iterates `tab.paneTree.allPanes + tab.floatingPanes` pane IDs and calls `viewStore.tearDown(for:)` on each
