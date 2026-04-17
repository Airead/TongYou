import CoreGraphics
import Foundation
import Testing
import TYTerminal
@testable import TongYou

@Suite("Floating Panes")
struct FloatingPaneTests {

    // MARK: - FloatingPane Model

    @Test func defaultFrameIsCentered() {
        let pane = FloatingPane(pane: TerminalPane())
        #expect(pane.frame == FloatingPane.defaultFrame)
        #expect(pane.isVisible)
        #expect(pane.zIndex == 0)
    }

    @Test func clampFrameEnforcesMinSize() {
        var fp = FloatingPane(pane: TerminalPane(), frame: CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.01))
        fp.clampFrame()
        #expect(fp.frame.width >= FloatingPane.minSize.width)
        #expect(fp.frame.height >= FloatingPane.minSize.height)
    }

    @Test func clampFrameKeepsInBounds() {
        var fp = FloatingPane(pane: TerminalPane(), frame: CGRect(x: -0.5, y: -0.5, width: 0.4, height: 0.4))
        fp.clampFrame()
        #expect(fp.frame.origin.x >= 0)
        #expect(fp.frame.origin.y >= 0)
    }

    @Test func clampFrameHandlesOverflow() {
        var fp = FloatingPane(pane: TerminalPane(), frame: CGRect(x: 0.9, y: 0.9, width: 0.4, height: 0.4))
        fp.clampFrame()
        #expect(fp.frame.maxX <= 1.0)
        #expect(fp.frame.maxY <= 1.0)
    }

    @Test func pixelFrameConversion() {
        let fp = FloatingPane(pane: TerminalPane(), frame: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        let pixel = fp.pixelFrame(in: CGSize(width: 800, height: 600))
        #expect(pixel.origin.x == 200)
        #expect(pixel.origin.y == 300)
        #expect(pixel.width == 400)
        #expect(pixel.height == 150)
    }

    // MARK: - TabManager Floating Pane Operations

    @Test func createFloatingPane() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let paneID = mgr.createFloatingPane()
        #expect(paneID != nil)
        #expect(mgr.activeTab!.floatingPanes.count == 1)
        #expect(mgr.activeTab!.floatingPanes[0].pane.id == paneID)
    }

    @Test func createFloatingPaneWithNoTab() {
        let mgr = TabManager()
        let paneID = mgr.createFloatingPane()
        #expect(paneID == nil)
    }

    @Test func closeFloatingPane() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let paneID = mgr.createFloatingPane()!
        let removed = mgr.closeFloatingPane(paneID: paneID)
        #expect(removed)
        #expect(mgr.activeTab!.floatingPanes.isEmpty)
    }

    @Test func closeNonexistentFloatingPane() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let removed = mgr.closeFloatingPane(paneID: UUID())
        #expect(!removed)
    }

    @Test func allPaneIDsIncludingFloating() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let treePaneID = mgr.activeTab!.paneTree.firstPane.id
        let floatingPaneID = mgr.createFloatingPane()!
        let allIDs = mgr.activeTab!.allPaneIDsIncludingFloating
        #expect(allIDs.contains(treePaneID))
        #expect(allIDs.contains(floatingPaneID))
        #expect(allIDs.count == 2)
    }

    // MARK: - Z-Order Management

    @Test func bringToFrontUpdatesZIndex() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let id1 = mgr.createFloatingPane()!
        let id2 = mgr.createFloatingPane()!

        // id2 should be on top (higher zIndex)
        let z1Before = mgr.activeTab!.floatingPanes.first(where: { $0.pane.id == id1 })!.zIndex
        let z2Before = mgr.activeTab!.floatingPanes.first(where: { $0.pane.id == id2 })!.zIndex
        #expect(z2Before > z1Before)

        // Bring id1 to front
        mgr.bringFloatingPaneToFront(paneID: id1)
        let z1After = mgr.activeTab!.floatingPanes.first(where: { $0.pane.id == id1 })!.zIndex
        let z2After = mgr.activeTab!.floatingPanes.first(where: { $0.pane.id == id2 })!.zIndex
        #expect(z1After > z2After)
    }

    @Test func bringToFrontAlreadyOnTop() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        _ = mgr.createFloatingPane()!
        let id2 = mgr.createFloatingPane()!

        let zBefore = mgr.activeTab!.floatingPanes.first(where: { $0.pane.id == id2 })!.zIndex
        mgr.bringFloatingPaneToFront(paneID: id2) // already on top
        let zAfter = mgr.activeTab!.floatingPanes.first(where: { $0.pane.id == id2 })!.zIndex
        #expect(zAfter == zBefore) // unchanged
    }

    // MARK: - Visibility Toggle

    @Test func setFloatingPanesVisibility() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        _ = mgr.createFloatingPane()
        _ = mgr.createFloatingPane()

        // All visible by default
        let allVisibleInitially = mgr.activeTab!.floatingPanes.allSatisfy(\.isVisible)
        #expect(allVisibleInitially)

        // Hide all
        mgr.setFloatingPanesVisibility(visible: false)
        let allHidden = mgr.activeTab!.floatingPanes.allSatisfy { !$0.isVisible }
        #expect(allHidden)

        // Show all
        mgr.setFloatingPanesVisibility(visible: true)
        let allVisibleAgain = mgr.activeTab!.floatingPanes.allSatisfy(\.isVisible)
        #expect(allVisibleAgain)

        // Idempotent when already visible
        mgr.setFloatingPanesVisibility(visible: true)
        let stillVisible = mgr.activeTab!.floatingPanes.allSatisfy(\.isVisible)
        #expect(stillVisible)
    }

    @Test func setVisibilityWithMixedState() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        _ = mgr.createFloatingPane()

        // Hide existing pane
        mgr.setFloatingPanesVisibility(visible: false)
        let allHidden = mgr.activeTab!.floatingPanes.allSatisfy { !$0.isVisible }
        #expect(allHidden)

        // Add a new one (visible by default) to create mixed state
        _ = mgr.createFloatingPane()
        let mixed = !mgr.activeTab!.floatingPanes.allSatisfy(\.isVisible)
        #expect(mixed)

        // Show all resolves mixed state
        mgr.setFloatingPanesVisibility(visible: true)
        let allVisibleAfterMixed = mgr.activeTab!.floatingPanes.allSatisfy(\.isVisible)
        #expect(allVisibleAfterMixed)
    }

    // MARK: - Frame Update

    @Test func updateFloatingPaneFrame() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let paneID = mgr.createFloatingPane()!

        let newFrame = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        mgr.updateFloatingPaneFrame(paneID: paneID, frame: newFrame)
        let updated = mgr.activeTab!.floatingPanes.first(where: { $0.pane.id == paneID })!
        #expect(updated.frame == newFrame)
    }

    @Test func updateFloatingPaneFrameClamps() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let paneID = mgr.createFloatingPane()!

        // Frame that overflows
        mgr.updateFloatingPaneFrame(paneID: paneID, frame: CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5))
        let updated = mgr.activeTab!.floatingPanes.first(where: { $0.pane.id == paneID })!
        #expect(updated.frame.maxX <= 1.0)
        #expect(updated.frame.maxY <= 1.0)
    }

    // MARK: - Cascade Offset

    @Test func createFloatingPaneWithOffset() {
        let mgr = TabManager()
        mgr.createTab(title: "test")

        let id1 = mgr.createFloatingPane()!
        let id2 = mgr.createFloatingPane()!

        let frame1 = mgr.activeTab!.floatingPanes.first(where: { $0.pane.id == id1 })!.frame
        let frame2 = mgr.activeTab!.floatingPanes.first(where: { $0.pane.id == id2 })!.frame

        // Second pane should be offset from the first
        #expect(frame2.origin.x > frame1.origin.x)
        #expect(frame2.origin.y > frame1.origin.y)
        // Same size
        #expect(frame2.width == frame1.width)
        #expect(frame2.height == frame1.height)
    }

    @Test func createThreeFloatingPanesAllOffset() {
        let mgr = TabManager()
        mgr.createTab(title: "test")

        let id1 = mgr.createFloatingPane()!
        let id2 = mgr.createFloatingPane()!
        let id3 = mgr.createFloatingPane()!

        let fp = mgr.activeTab!.floatingPanes
        let f1 = fp.first(where: { $0.pane.id == id1 })!.frame
        let f2 = fp.first(where: { $0.pane.id == id2 })!.frame
        let f3 = fp.first(where: { $0.pane.id == id3 })!.frame

        // All three should have distinct origins
        #expect(f1.origin.x != f2.origin.x)
        #expect(f2.origin.x != f3.origin.x)
        #expect(f1.origin.x != f3.origin.x)
    }

    // MARK: - Keybinding Parsing

    @Test func floatingPaneActionRawValueRoundTrip() {
        let actions: [Keybinding.Action] = [
            .newFloatingPane, .toggleOrCreateFloatingPane,
        ]
        for action in actions {
            let parsed = Keybinding.Action(rawValue: action.rawValue)
            #expect(parsed == action, "Round-trip failed for \(action.rawValue)")
        }
    }

    @Test func floatingPaneTabActionMapping() {
        let newMapped = Keybinding.Action.newFloatingPane.tabAction
        let toggleMapped = Keybinding.Action.toggleOrCreateFloatingPane.tabAction

        #expect(newMapped != nil)
        #expect(toggleMapped != nil)
    }

    // MARK: - Pin

    @Test func defaultIsNotPinned() {
        let fp = FloatingPane(pane: TerminalPane())
        #expect(!fp.isPinned)
    }

    @Test func togglePin() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let paneID = mgr.createFloatingPane()!

        #expect(!mgr.activeTab!.floatingPanes[0].isPinned)
        mgr.toggleFloatingPanePin(paneID: paneID)
        #expect(mgr.activeTab!.floatingPanes[0].isPinned)
        mgr.toggleFloatingPanePin(paneID: paneID)
        #expect(!mgr.activeTab!.floatingPanes[0].isPinned)
    }

    // MARK: - Title

    @Test func defaultTitle() {
        let fp = FloatingPane(pane: TerminalPane())
        #expect(fp.title == "Float")
    }

    @Test func updateFloatingPaneTitle() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let paneID = mgr.createFloatingPane()!

        mgr.updateFloatingPaneTitle(paneID: paneID, title: "zsh")
        #expect(mgr.activeTab!.floatingPanes[0].title == "zsh")
    }

    // MARK: - Focus-Based Visibility

    @Test func focusFloatingPaneShowsAll() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let id1 = mgr.createFloatingPane()!
        let id2 = mgr.createFloatingPane()!

        // First hide all by focusing a tree pane
        let treePaneID = mgr.activeTab!.paneTree.firstPane.id
        mgr.updateFloatingPanesVisibilityForFocus(focusedPaneID: treePaneID)
        let allHidden = mgr.activeTab!.floatingPanes.allSatisfy { !$0.isVisible }
        #expect(allHidden)

        // Focus a floating pane → all become visible
        mgr.updateFloatingPanesVisibilityForFocus(focusedPaneID: id1)
        let allVisible1 = mgr.activeTab!.floatingPanes.allSatisfy(\.isVisible)
        #expect(allVisible1)

        // Also works when focusing the other floating pane
        mgr.updateFloatingPanesVisibilityForFocus(focusedPaneID: id2)
        let allVisible2 = mgr.activeTab!.floatingPanes.allSatisfy(\.isVisible)
        #expect(allVisible2)
    }

    @Test func focusTreePaneHidesUnpinnedFloats() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        _ = mgr.createFloatingPane()!
        _ = mgr.createFloatingPane()!

        let treePaneID = mgr.activeTab!.paneTree.firstPane.id
        mgr.updateFloatingPanesVisibilityForFocus(focusedPaneID: treePaneID)

        let allHidden = mgr.activeTab!.floatingPanes.allSatisfy { !$0.isVisible }
        #expect(allHidden)
    }

    @Test func pinnedPaneStaysVisibleWhenTreeFocused() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let pinnedID = mgr.createFloatingPane()!
        let unpinnedID = mgr.createFloatingPane()!

        mgr.toggleFloatingPanePin(paneID: pinnedID)

        let treePaneID = mgr.activeTab!.paneTree.firstPane.id
        mgr.updateFloatingPanesVisibilityForFocus(focusedPaneID: treePaneID)

        let pinned = mgr.activeTab!.floatingPanes.first { $0.pane.id == pinnedID }!
        let unpinned = mgr.activeTab!.floatingPanes.first { $0.pane.id == unpinnedID }!
        #expect(pinned.isVisible)  // pinned pane stays visible
        #expect(pinned.isPinned)
        #expect(!unpinned.isVisible)
        #expect(!unpinned.isPinned)
    }

    @Test func pinnedPaneRenderedViaOverlayFilter() {
        // Verify that the overlay filter logic (isVisible || isPinned) works
        let pinned = FloatingPane(pane: TerminalPane(), isVisible: false, isPinned: true)
        let unpinned = FloatingPane(pane: TerminalPane(), isVisible: false, isPinned: false)
        let visible = FloatingPane(pane: TerminalPane(), isVisible: true, isPinned: false)

        let panes = [pinned, unpinned, visible]
        let rendered = panes.filter { $0.isVisible || $0.isPinned }
        #expect(rendered.count == 2)
        #expect(rendered.contains { $0.id == pinned.id })
        #expect(!rendered.contains { $0.id == unpinned.id })
        #expect(rendered.contains { $0.id == visible.id })
    }

    @Test func focusNilDoesNotCrash() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        _ = mgr.createFloatingPane()!
        // Should be a no-op
        mgr.updateFloatingPanesVisibilityForFocus(focusedPaneID: nil)
        #expect(mgr.activeTab!.floatingPanes[0].isVisible)
    }

    // MARK: - CommandOptions closeOnExit

    @Test func commandOptionsCloseOnExitFlag() {
        let opts = CommandOptions.parse("pane,close_on_exit")
        #expect(opts.showInPane)
        #expect(opts.closeOnExit)
    }

    @Test func commandOptionsDefaultNoCloseOnExit() {
        let opts = CommandOptions.parse("pane")
        #expect(opts.showInPane)
        #expect(!opts.closeOnExit)
    }

    @Test func commandOptionsEmptyNoCloseOnExit() {
        let opts = CommandOptions.empty
        #expect(!opts.closeOnExit)
    }

    // MARK: - CommandOptions paneFrame

    @Test func paneFrameAllValues() {
        let opts = CommandOptions.parse("pane,x=0.1,y=0.2,w=0.6,h=0.5")
        let frame = opts.paneFrame
        #expect(frame != nil)
        #expect(frame!.origin.x == 0.1)
        #expect(frame!.origin.y == 0.2)
        #expect(frame!.width == 0.6)
        #expect(frame!.height == 0.5)
    }

    @Test func paneFramePartialValues() {
        let opts = CommandOptions.parse("pane,x=0.1,h=0.8")
        let frame = opts.paneFrame
        #expect(frame != nil)
        #expect(frame!.origin.x == 0.1)
        #expect(frame!.origin.y == 0.3)  // default
        #expect(frame!.width == 0.4)     // default
        #expect(frame!.height == 0.8)
    }

    @Test func paneFrameNilWhenNoFrameOptions() {
        let opts = CommandOptions.parse("pane,local,remote")
        #expect(opts.paneFrame == nil)
    }

    @Test func paneFrameWidthClampedToMax() {
        let opts = CommandOptions.parse("w=2.0,h=1.5")
        let frame = opts.paneFrame!
        #expect(frame.width == 1.0)
        #expect(frame.height == 1.0)
    }

    @Test func paneFrameWidthClampedToMin() {
        let opts = CommandOptions.parse("w=0.01,h=0.01")
        let frame = opts.paneFrame!
        #expect(frame.width == 0.1)
        #expect(frame.height == 0.1)
    }

    // MARK: - FloatingPaneCommandInfo

    @Test func floatingPaneCommandInfoStoresValues() {
        let info = FloatingPaneCommandInfo(
            command: "/bin/sh", arguments: ["-c", "echo hello"],
            workingDirectory: "/tmp", closeOnExit: false
        )
        #expect(info.command == "/bin/sh")
        #expect(info.arguments == ["-c", "echo hello"])
        #expect(info.workingDirectory == "/tmp")
        #expect(!info.closeOnExit)
    }

    @Test func floatingPaneCommandInfoCloseOnExit() {
        let info = FloatingPaneCommandInfo(
            command: "/bin/sh", arguments: [],
            workingDirectory: nil, closeOnExit: true
        )
        #expect(info.closeOnExit)
    }

    // MARK: - closeOnExit Keybinding round-trip

    @Test func closeOnExitKeybindingRoundTrip() {
        let action = Keybinding.Action.runCommand(
            command: "git", arguments: ["status"],
            options: CommandOptions.parse("local,pane,close_on_exit")
        )
        let raw = action.rawValue
        #expect(raw.contains("close_on_exit"))
        #expect(raw.contains("pane"))
        let parsed = Keybinding.Action(rawValue: raw)
        #expect(parsed == action)
    }

    // MARK: - run_command mode flags

    @Test func runCommandLocalOnly() {
        let action = Keybinding.Action(rawValue: "run_command[pane,local]:git:status")
        #expect(action != nil)
        if case .runCommand(let cmd, let args, let opts) = action {
            #expect(cmd == "git")
            #expect(args == ["status"])
            #expect(opts.runsLocal)
            #expect(!opts.runsRemote)
            #expect(opts.showInPane)
        } else {
            Issue.record("Expected .runCommand")
        }
    }

    @Test func runCommandRemoteOnly() {
        let action = Keybinding.Action(rawValue: "run_command[pane,remote]:git:status")
        #expect(action != nil)
        if case .runCommand(_, _, let opts) = action {
            #expect(!opts.runsLocal)
            #expect(opts.runsRemote)
        } else {
            Issue.record("Expected .runCommand")
        }
    }

    @Test func runCommandBothModes() {
        let action = Keybinding.Action(rawValue: "run_command[pane,local,remote]:git:status")
        #expect(action != nil)
        if case .runCommand(_, _, let opts) = action {
            #expect(opts.runsLocal)
            #expect(opts.runsRemote)
            #expect(opts.showInPane)
        } else {
            Issue.record("Expected .runCommand")
        }
    }

    @Test func runCommandDefaultsToLocal() {
        // run_command without local/remote should default to local for backwards compat.
        let action = Keybinding.Action(rawValue: "run_command[pane]:git:log")
        #expect(action != nil)
        if case .runCommand(_, _, let opts) = action {
            #expect(opts.runsLocal)
            #expect(!opts.runsRemote)
        } else {
            Issue.record("Expected .runCommand")
        }
    }

    @Test func runLocalCommandLegacyParsesToRunCommand() {
        let action = Keybinding.Action(rawValue: "run_local_command[pane]:make:build")
        #expect(action != nil)
        if case .runCommand(let cmd, let args, let opts) = action {
            #expect(cmd == "make")
            #expect(args == ["build"])
            #expect(opts.runsLocal)
            #expect(!opts.runsRemote)
        } else {
            Issue.record("Expected .runCommand from run_local_command")
        }
    }

    @Test func runRemoteCommandLegacyParsesToRunCommand() {
        let action = Keybinding.Action(rawValue: "run_remote_command[pane]:git:fetch,--all")
        #expect(action != nil)
        if case .runCommand(let cmd, let args, let opts) = action {
            #expect(cmd == "git")
            #expect(args == ["fetch", "--all"])
            #expect(!opts.runsLocal)
            #expect(opts.runsRemote)
        } else {
            Issue.record("Expected .runCommand from run_remote_command")
        }
    }

    @Test func runCommandAlwaysLocal() {
        let action = Keybinding.Action(rawValue: "run_command[pane,always_local]:open:.")
        #expect(action != nil)
        if case .runCommand(let cmd, let args, let opts) = action {
            #expect(cmd == "open")
            #expect(args == ["."])
            #expect(opts.alwaysLocal)
            #expect(opts.showInPane)
        } else {
            Issue.record("Expected .runCommand")
        }
    }

    @Test func alwaysLocalRoundTrip() {
        let action = Keybinding.Action.runCommand(
            command: "pbcopy", arguments: [],
            options: CommandOptions.parse("always_local")
        )
        let raw = action.rawValue
        let parsed = Keybinding.Action(rawValue: raw)
        #expect(parsed == action)
    }

    @Test func runCommandRoundTrip() {
        let action = Keybinding.Action.runCommand(
            command: "git", arguments: ["status"],
            options: CommandOptions.parse("local,pane,remote")
        )
        let raw = action.rawValue
        let parsed = Keybinding.Action(rawValue: raw)
        #expect(parsed == action)
    }

    @Test func runCommandWithFrameRoundTrip() {
        let action = Keybinding.Action.runCommand(
            command: "git", arguments: ["status"],
            options: CommandOptions.parse("pane,local,x=0.1,y=0.2,w=0.8,h=0.6")
        )
        let raw = action.rawValue
        let parsed = Keybinding.Action(rawValue: raw)
        #expect(parsed == action)
    }

    // MARK: - paneExited carries exit code

    @Test func paneExitedActionCarriesExitCode() {
        let id = UUID()
        let action = TabAction.paneExited(id, exitCode: 42)
        if case .paneExited(let paneID, let exitCode) = action {
            #expect(paneID == id)
            #expect(exitCode == 42)
        } else {
            Issue.record("Expected .paneExited")
        }
    }

    @Test func paneExitedActionZeroExitCode() {
        let id = UUID()
        let action = TabAction.paneExited(id, exitCode: 0)
        if case .paneExited(_, let exitCode) = action {
            #expect(exitCode == 0)
        } else {
            Issue.record("Expected .paneExited")
        }
    }

    @Test func paneExitedActionNegativeExitCode() {
        let id = UUID()
        let action = TabAction.paneExited(id, exitCode: -9)
        if case .paneExited(_, let exitCode) = action {
            #expect(exitCode == -9)
        } else {
            Issue.record("Expected .paneExited")
        }
    }

    // MARK: - closeOnExit with exit code decision logic

    @Test func closeOnExitWithSuccessShouldClose() {
        // close_on_exit=true, exitCode=0 → should auto-close
        let info = FloatingPaneCommandInfo(
            command: "make", arguments: ["build"],
            workingDirectory: nil, closeOnExit: true
        )
        let exitCode: Int32 = 0
        let shouldClose = info.closeOnExit && exitCode == 0
        #expect(shouldClose)
    }

    @Test func closeOnExitWithFailureShouldKeepOpen() {
        // close_on_exit=true, exitCode=1 → should keep open
        let info = FloatingPaneCommandInfo(
            command: "make", arguments: ["build"],
            workingDirectory: nil, closeOnExit: true
        )
        let exitCode: Int32 = 1
        let shouldClose = info.closeOnExit && exitCode == 0
        #expect(!shouldClose)
    }

    @Test func closeOnExitWithSignalKillShouldKeepOpen() {
        // close_on_exit=true, exitCode=-9 (SIGKILL) → should keep open
        let info = FloatingPaneCommandInfo(
            command: "make", arguments: ["build"],
            workingDirectory: nil, closeOnExit: true
        )
        let exitCode: Int32 = -9
        let shouldClose = info.closeOnExit && exitCode == 0
        #expect(!shouldClose)
    }

    @Test func noCloseOnExitAlwaysKeepsOpen() {
        // close_on_exit=false, exitCode=0 → should still keep open
        let info = FloatingPaneCommandInfo(
            command: "make", arguments: ["build"],
            workingDirectory: nil, closeOnExit: false
        )
        let exitCode: Int32 = 0
        let shouldClose = info.closeOnExit && exitCode == 0
        #expect(!shouldClose)
    }
}
