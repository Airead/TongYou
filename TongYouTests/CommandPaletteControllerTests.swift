import AppKit
import Foundation
import SwiftUI
import Testing
import TYConfig
import TYTerminal
@testable import TongYou

@MainActor
@Suite("CommandPaletteController")
struct CommandPaletteControllerTests {

    // MARK: - Scope parsing

    @Test func paletteScopeFromPrefix() {
        // Default scope is session — an empty input (or any unprefixed text)
        // fuzzy-matches against the open sessions list.
        #expect(PaletteScope.parse(input: "").scope == .session)
        #expect(PaletteScope.parse(input: "work").scope == .session)

        // Recognised prefixes switch scope.
        #expect(PaletteScope.parse(input: "> restart").scope == .command)
        #expect(PaletteScope.parse(input: "p home").scope == .profile)
        #expect(PaletteScope.parse(input: "t 2").scope == .tab)
        #expect(PaletteScope.parse(input: "s work").scope == .session)
        #expect(PaletteScope.parse(input: "ssh db").scope == .ssh)
    }

    @Test func paletteScopeRemovesPrefixForFuzzy() {
        // The query fed to fuzzy matching must have the prefix stripped so
        // "ssh db" filters SSH hosts by "db", not by the literal "ssh db".
        #expect(PaletteScope.parse(input: "s db").query == "db")
        #expect(PaletteScope.parse(input: "> restart").query == "restart")
        #expect(PaletteScope.parse(input: "p home").query == "home")
        #expect(PaletteScope.parse(input: "t 2").query == "2")
        #expect(PaletteScope.parse(input: "ssh host1").query == "host1")

        // Unprefixed session scope passes the query through verbatim.
        #expect(PaletteScope.parse(input: "work").query == "work")
    }

    @Test func paletteBareSshWordStaysInSessionScope() {
        // Only `ssh ` (with trailing space) flips the palette to SSH scope.
        // Typing the bare word `ssh` should keep the session list in view
        // — so the user's in-progress typing doesn't yank the candidates
        // before they've committed to the SSH prefix.
        #expect(PaletteScope.parse(input: "ssh").scope == .session)
        #expect(PaletteScope.parse(input: "ssh").query == "ssh")
    }

    @Test func paletteScopeRecognisesLoneCommandSigil() {
        // "> " alone (no trailing query) opens command scope with empty query.
        // The bare ">" (no trailing space) should also be treated as scope
        // entry so the hint UI can flip instantly.
        #expect(PaletteScope.parse(input: ">").scope == .command)
        #expect(PaletteScope.parse(input: ">").query == "")
    }

    // MARK: - Open / close / escape

    @Test func paletteClosesOnEscape() {
        let controller = CommandPaletteController()
        controller.sessionCandidates = [
            PaletteCandidate(primaryText: "work", scope: .session),
        ]

        controller.open()
        #expect(controller.isOpen)
        #expect(controller.rows.isEmpty)

        controller.close()
        #expect(!controller.isOpen)
        #expect(controller.input == "")
        #expect(controller.rows.isEmpty)
    }

    @Test func paletteOpensInSessionScopeByDefault() {
        // ⌘P lands in session scope with an empty input; the first keystroke
        // filters by session name unless the user types a scope prefix.
        let controller = CommandPaletteController()
        controller.open()
        #expect(controller.isOpen)
        #expect(controller.input == "")
        #expect(controller.scope == .session)
        #expect(controller.query == "")
    }

    // MARK: - Session scope (Phase 8)

    @Test func sessionScopeListsAllOpenSessions() {
        // Typing a space lists every injected candidate in session scope.
        let controller = CommandPaletteController()
        controller.sessionCandidates = [
            PaletteCandidate(primaryText: "work", scope: .session),
            PaletteCandidate(primaryText: "home", scope: .session),
            PaletteCandidate(primaryText: "lab", scope: .session),
        ]
        controller.open()
        controller.input = " "

        #expect(controller.rows.count == 3)
        #expect(controller.rows.map(\.candidate.primaryText) == ["work", "home", "lab"])
    }

    @Test func sessionFuzzyMatchByDisplayName() {
        // Typing straight into the default session scope (no prefix) drives
        // fuzzy matching across the session list.
        let controller = CommandPaletteController()
        controller.sessionCandidates = [
            PaletteCandidate(primaryText: "work", scope: .session),
            PaletteCandidate(primaryText: "home", scope: .session),
            PaletteCandidate(primaryText: "lab", scope: .session),
        ]
        controller.open()
        controller.input = "hom"

        #expect(controller.rows.count == 1)
        #expect(controller.rows.first?.candidate.primaryText == "home")
    }

    @Test func sessionCommitActionMapsModes() {
        // Plain Enter activates the session; every modifier variant is a
        // no-op in session scope (toast + close in the view).
        let id = UUID()
        let candidate = PaletteCandidate(
            id: id,
            primaryText: "work",
            scope: .session
        )
        let row = PaletteRow(
            candidate: candidate,
            match: FuzzyMatcher.Match(score: 0, matchedIndices: [])
        )
        #expect(
            TerminalWindowView.sessionCommitAction(for: row, mode: .plain)
                == .activate(sessionID: id)
        )
        #expect(
            TerminalWindowView.sessionCommitAction(for: row, mode: .commandEnter)
                == .notApplicable
        )
        #expect(
            TerminalWindowView.sessionCommitAction(for: row, mode: .shiftEnter)
                == .notApplicable
        )
        #expect(
            TerminalWindowView.sessionCommitAction(for: row, mode: .optionEnter)
                == .notApplicable
        )
    }

    // MARK: - Rows + highlight

    @Test func typingFiltersCandidates() {
        let controller = CommandPaletteController()
        controller.sshCandidates = [
            PaletteCandidate(primaryText: "db1", scope: .ssh),
            PaletteCandidate(primaryText: "api1", scope: .ssh),
            PaletteCandidate(primaryText: "db-prod-1", scope: .ssh),
        ]
        controller.open()
        controller.input = "ssh db"

        #expect(controller.rows.count == 2)
        let names = controller.rows.map(\.candidate.primaryText)
        #expect(names.contains("db1"))
        #expect(names.contains("db-prod-1"))
        #expect(!names.contains("api1"))
    }

    @Test func typingResetsHighlightToFirst() {
        let controller = CommandPaletteController()
        controller.sshCandidates = [
            PaletteCandidate(primaryText: "db1", scope: .ssh),
            PaletteCandidate(primaryText: "db2", scope: .ssh),
            PaletteCandidate(primaryText: "db3", scope: .ssh),
        ]
        controller.open()
        controller.input = "ssh db"
        controller.moveHighlight(by: 2)
        #expect(controller.highlightedIndex == 2)

        controller.input = "ssh db1"
        #expect(controller.highlightedIndex == 0)
    }

    @Test func moveHighlightWrapsAround() {
        let controller = CommandPaletteController()
        controller.sshCandidates = (0..<3).map {
            PaletteCandidate(primaryText: "host\($0)", scope: .ssh)
        }
        controller.open()
        controller.input = "ssh host"
        #expect(controller.highlightedIndex == 0)

        controller.moveHighlight(by: -1)   // wraps to last
        #expect(controller.highlightedIndex == 2)
        controller.moveHighlight(by: 1)    // wraps back to 0
        #expect(controller.highlightedIndex == 0)
    }

    @Test func moveHighlightIsNoOpWithEmptyRows() {
        let controller = CommandPaletteController()
        controller.open()
        controller.moveHighlight(by: 1)
        #expect(controller.highlightedIndex == -1)
    }

    // MARK: - Multi-select bag

    @Test func tabTogglesSelection() {
        let controller = CommandPaletteController()
        controller.sshCandidates = (0..<3).map {
            PaletteCandidate(primaryText: "h\($0)", scope: .ssh)
        }
        controller.open()
        controller.input = "ssh h"
        #expect(controller.selection.isEmpty)

        // Highlight row 0, add it.
        controller.toggleSelection()
        #expect(controller.selection.count == 1)
        #expect(controller.selection[0] == controller.rows[0].id)

        // Move to row 2, add it too.
        controller.moveHighlight(by: 2)
        controller.toggleSelection()
        #expect(controller.selection.count == 2)

        // Toggle row 2 off.
        controller.toggleSelection()
        #expect(controller.selection.count == 1)
    }

    @Test func selectionRemovesOnSecondTab() {
        // Re-toggling the same highlighted row removes it — so a user can
        // un-pick a selection without having to clear the whole bag.
        let controller = CommandPaletteController()
        controller.sshCandidates = (0..<3).map {
            PaletteCandidate(primaryText: "h\($0)", scope: .ssh)
        }
        controller.open()
        controller.input = "ssh h"
        controller.toggleSelection()
        #expect(controller.selection.count == 1)

        controller.toggleSelection()
        #expect(controller.selection.isEmpty)
    }

    @Test func commitReturnsHighlightedRowByDefault() {
        let controller = CommandPaletteController()
        controller.sshCandidates = (0..<3).map {
            PaletteCandidate(primaryText: "h\($0)", scope: .ssh)
        }
        controller.open()
        controller.input = "ssh h1"
        controller.moveHighlight(by: 1)

        let commit = controller.commit(mode: .plain)
        #expect(commit != nil)
        #expect(commit?.rows.count == 1)
        #expect(commit?.rows.first?.candidate.primaryText == "h1")
        #expect(commit?.mode == .plain)
    }

    @Test func commitReturnsSelectionWhenPresent() {
        let controller = CommandPaletteController()
        controller.sshCandidates = (0..<3).map {
            PaletteCandidate(primaryText: "h\($0)", scope: .ssh)
        }
        controller.open()
        controller.input = "ssh h"
        // Select row 0 and row 2 (via Tab + arrow).
        controller.toggleSelection()
        controller.moveHighlight(by: 2)
        controller.toggleSelection()

        let commit = controller.commit(mode: .commandEnter)
        #expect(commit?.rows.count == 2)
        #expect(commit?.rows.map(\.candidate.primaryText) == ["h0", "h2"])
        #expect(commit?.mode == .commandEnter)
    }

    @Test func commitWithoutRowsReturnsNil() {
        let controller = CommandPaletteController()
        controller.open()
        #expect(controller.commit(mode: .plain) == nil)
    }

    // MARK: - SSH ad-hoc fallback (Phase 6)

    @Test func sshAdHocAppearsWhenFuzzyIsEmpty() {
        let controller = CommandPaletteController()
        controller.sshCandidates = [
            PaletteCandidate(primaryText: "db1", scope: .ssh),
        ]
        controller.sshAdHocBuilder = { query in
            PaletteCandidate(
                primaryText: "Connect ad-hoc: \(query)",
                scope: .ssh
            )
        }
        controller.open()
        controller.input = "ssh totally-novel"

        #expect(controller.rows.count == 1)
        #expect(controller.rows[0].candidate.primaryText == "Connect ad-hoc: totally-novel")
    }

    @Test func sshAdHocSkippedWhenBuilderReturnsNil() {
        let controller = CommandPaletteController()
        controller.sshCandidates = [
            PaletteCandidate(primaryText: "db1", scope: .ssh),
        ]
        controller.sshAdHocBuilder = { _ in nil }
        controller.open()
        controller.input = "ssh nope"

        #expect(controller.rows.isEmpty)
    }

    // MARK: - SSH glob scope

    @Test func sshGlobRejectsScatteredSubsequenceMatch() {
        // The pre-glob matcher would have accepted "ase1c" against
        // "aws-ase1b-…" because `a` + `se1` can be stitched across the
        // host name. The glob matcher insists on a contiguous substring.
        let controller = CommandPaletteController()
        controller.sshCandidates = [
            PaletteCandidate(primaryText: "aws-ase1c-btc-node-50", scope: .ssh),
            PaletteCandidate(primaryText: "aws-ase1b-btc-node-50", scope: .ssh),
        ]
        controller.sshAdHocBuilder = { _ in nil }
        controller.open()
        controller.input = "ssh ase1c"

        #expect(controller.rows.count == 1)
        #expect(controller.rows.first?.candidate.primaryText == "aws-ase1c-btc-node-50")
    }

    @Test func sshCommaCombinesPatternsWithOr() {
        // `a, b` should surface candidates matching either glob.
        let controller = CommandPaletteController()
        controller.sshCandidates = [
            PaletteCandidate(primaryText: "aws-ase1c-btc-node-50", scope: .ssh),
            PaletteCandidate(primaryText: "aws-ase1b-btc-node-50", scope: .ssh),
            PaletteCandidate(primaryText: "aws-use1-btc-node-50", scope: .ssh),
        ]
        controller.sshAdHocBuilder = { _ in nil }
        controller.open()
        controller.input = "ssh ase1c, ase1b"

        #expect(controller.rows.count == 2)
        let names = controller.rows.map(\.candidate.primaryText)
        #expect(names.contains("aws-ase1c-btc-node-50"))
        #expect(names.contains("aws-ase1b-btc-node-50"))
    }

    @Test func sshWildcardFiltersAcrossNodeLabels() {
        // `aws-*-50` should pick up every aws host ending in -50 without
        // caring about the middle segments.
        let controller = CommandPaletteController()
        controller.sshCandidates = [
            PaletteCandidate(primaryText: "aws-ase1c-btc-node-50", scope: .ssh),
            PaletteCandidate(primaryText: "aws-ase1b-btc-node-50", scope: .ssh),
            PaletteCandidate(primaryText: "gcp-eu-node-50", scope: .ssh),
        ]
        controller.sshAdHocBuilder = { _ in nil }
        controller.open()
        controller.input = "ssh aws-*-50"

        #expect(controller.rows.count == 2)
        let names = controller.rows.map(\.candidate.primaryText)
        #expect(names.allSatisfy { $0.hasPrefix("aws-") })
    }

    @Test func sshAdHocDisabledWhenQueryContainsWildcard() {
        // With `*` in the query the user is filtering, not naming a
        // specific host — synthesising `ssh aws-*-99` would be nonsense.
        let controller = CommandPaletteController()
        controller.sshCandidates = [
            PaletteCandidate(primaryText: "aws-50", scope: .ssh),
        ]
        var adHocQueries: [String] = []
        controller.sshAdHocBuilder = { q in
            adHocQueries.append(q)
            return PaletteCandidate(primaryText: "Connect ad-hoc: \(q)", scope: .ssh)
        }
        controller.open()
        controller.input = "ssh aws-*-99"

        #expect(controller.rows.isEmpty)
        #expect(adHocQueries.isEmpty)
    }

    @Test func sshAdHocDisabledWhenQueryContainsComma() {
        // Same rationale as the wildcard case — a comma-separated list
        // is filtering semantics, not a literal host string.
        let controller = CommandPaletteController()
        controller.sshCandidates = [
            PaletteCandidate(primaryText: "aws-50", scope: .ssh),
        ]
        var adHocQueries: [String] = []
        controller.sshAdHocBuilder = { q in
            adHocQueries.append(q)
            return PaletteCandidate(primaryText: "Connect ad-hoc: \(q)", scope: .ssh)
        }
        controller.open()
        controller.input = "ssh zzz, yyy"

        #expect(controller.rows.isEmpty)
        #expect(adHocQueries.isEmpty)
    }

    // MARK: - ⌘⌫ delete dispatch

    @Test func deleteHighlightedInvokesSSHCallbackWithTarget() {
        let controller = CommandPaletteController()
        let real = SSHCandidate(target: "db1.prod", hostname: nil, isAdHoc: false)
        let realResolution = SSHResolution(
            candidate: real,
            target: SSHTarget.parse("db1.prod"),
            templateID: "ssh",
            variables: [:]
        )
        controller.sshCandidates = [
            PaletteCandidate(
                primaryText: real.target,
                scope: .ssh,
                sshResolution: realResolution
            ),
        ]
        var deleted: [String] = []
        controller.onDeleteHistory = { deleted.append($0) }
        controller.open()
        controller.input = "ssh db"

        let consumed = controller.deleteHighlighted()
        #expect(consumed == true)
        #expect(deleted == ["db1.prod"])
    }

    @Test func deleteHighlightedIgnoresSSHAdHocRow() {
        // Ad-hoc rows have no history to delete — the callback must not fire
        // and the return value must be false so the view falls back to the
        // default text-field behaviour (no-op here, since we want ⌘⌫ on an
        // ad-hoc row to do nothing rather than clear the query).
        let controller = CommandPaletteController()
        controller.sshCandidates = []
        controller.sshAdHocBuilder = { query in
            let cand = SSHCandidate(target: query, hostname: nil, isAdHoc: true)
            let resolution = SSHResolution(
                candidate: cand,
                target: SSHTarget.parse(query),
                templateID: "ssh",
                variables: [:]
            )
            return PaletteCandidate(
                primaryText: "Connect ad-hoc: \(query)",
                scope: .ssh,
                sshResolution: resolution
            )
        }
        var deleted: [String] = []
        controller.onDeleteHistory = { deleted.append($0) }
        controller.open()
        controller.input = "ssh never-seen"

        #expect(controller.rows.count == 1)
        let consumed = controller.deleteHighlighted()
        #expect(consumed == false)
        #expect(deleted.isEmpty)
    }

    @Test func deleteHighlightedInvokesSessionCallbackWithID() {
        let controller = CommandPaletteController()
        let id = UUID()
        controller.sessionCandidates = [
            PaletteCandidate(id: id, primaryText: "work", scope: .session),
        ]
        var deleted: [UUID] = []
        controller.onDeleteSession = { deleted.append($0) }
        controller.open()
        controller.input = "work"

        let consumed = controller.deleteHighlighted()
        #expect(consumed == true)
        #expect(deleted == [id])
    }

    @Test func deleteHighlightedIsNoOpWhenEmpty() {
        let controller = CommandPaletteController()
        var sshCalls = 0
        var sessionCalls = 0
        controller.onDeleteHistory = { _ in sshCalls += 1 }
        controller.onDeleteSession = { _ in sessionCalls += 1 }
        controller.open()

        #expect(controller.deleteHighlighted() == false)
        #expect(sshCalls == 0)
        #expect(sessionCalls == 0)
    }

    @Test func requestRefocusInputBumpsTick() {
        let controller = CommandPaletteController()
        let before = controller.refocusTick
        controller.requestRefocusInput()
        #expect(controller.refocusTick != before)
    }

    @Test func sshAdHocOnlyFiresOnEmptyFuzzy() {
        // Even when the builder is set, a matching candidate suppresses
        // the ad-hoc row — the user should pick the real one.
        let controller = CommandPaletteController()
        controller.sshCandidates = [
            PaletteCandidate(primaryText: "db1", scope: .ssh),
        ]
        controller.sshAdHocBuilder = { q in
            PaletteCandidate(primaryText: "Connect ad-hoc: \(q)", scope: .ssh)
        }
        controller.open()
        controller.input = "ssh db"

        #expect(controller.rows.count == 1)
        #expect(controller.rows[0].candidate.primaryText == "db1")
    }

    // MARK: - Profile scope

    @Test func profileScopeListsCandidatesWithPrefix() {
        let controller = CommandPaletteController()
        controller.profileCandidates = [
            PaletteCandidate(
                primaryText: "ssh-prod",
                secondaryText: "extends ssh · #4a1818",
                scope: .profile,
                accentHex: "4a1818",
                profileID: "ssh-prod"
            ),
            PaletteCandidate(
                primaryText: "default",
                scope: .profile,
                profileID: "default"
            ),
        ]
        controller.open()
        controller.input = "p ssh"

        #expect(controller.rows.count == 1)
        #expect(controller.rows[0].candidate.primaryText == "ssh-prod")
    }

    @Test func profilePaletteCandidateBuildsSubtitle() {
        // Profile with extends + background → "extends X · #bg".
        let withParent = TerminalWindowView.profilePaletteCandidate(
            id: "ssh-prod",
            raw: RawProfile(id: "ssh-prod", extendsID: "ssh", entries: []),
            backgroundHex: "4a1818"
        )
        #expect(withParent.secondaryText == "extends ssh · #4a1818")
        #expect(withParent.accentHex == "4a1818")
        #expect(withParent.profileID == "ssh-prod")

        // Profile with neither extends nor background → nil subtitle.
        let bare = TerminalWindowView.profilePaletteCandidate(
            id: "default",
            raw: RawProfile(id: "default", extendsID: nil, entries: []),
            backgroundHex: nil
        )
        #expect(bare.secondaryText == nil)
        #expect(bare.accentHex == nil)
    }

    // MARK: - Command scope

    @Test func commandScopeListsCandidatesWithSubtitle() {
        let controller = CommandPaletteController()
        controller.commandCandidates = [
            PaletteCandidate(
                primaryText: "Show command palette",
                secondaryText: "⌘P",
                scope: .command,
                commandAction: .showCommandPalette
            ),
            PaletteCandidate(
                primaryText: "New tab",
                secondaryText: "⌘T",
                scope: .command,
                commandAction: .newTab
            ),
        ]
        controller.open()
        controller.input = "> show"

        #expect(controller.scope == .command)
        #expect(controller.rows.count == 1)
        #expect(controller.rows[0].candidate.secondaryText == "⌘P")
    }

    @Test func commandShortcutIndexFormatsGlyphs() {
        let bindings: [Keybinding] = [
            Keybinding(modifiers: .command, key: "p", action: .showCommandPalette),
            Keybinding(modifiers: [.command, .shift], key: "d", action: .splitHorizontal),
            Keybinding(modifiers: [.command, .option], key: "left", action: .focusPane(.left)),
        ]
        let index = TerminalWindowView.shortcutIndex(for: bindings)
        #expect(index[.showCommandPalette] == "⌘P")
        #expect(index[.splitHorizontal] == "⇧⌘D")
        #expect(index[.focusPane(.left)] == "⌥⌘←")
    }

    @Test func commandShortcutIndexPrefersFirstWhenDuplicated() {
        // Two bindings point at the same action — the first wins so the
        // subtitle is deterministic.
        let bindings: [Keybinding] = [
            Keybinding(modifiers: .command, key: "h", action: .previousTab),
            Keybinding(modifiers: [.command, .shift], key: "[", action: .previousTab),
        ]
        let index = TerminalWindowView.shortcutIndex(for: bindings)
        #expect(index[.previousTab] == "⌘H")
    }

    @Test func paletteDisplayTitleOmitsParameterisedActions() {
        // Actions with an associated payload that can't be enumerated at
        // build time must return nil so they never surface in the palette.
        #expect(Keybinding.Action.gotoTab(3).paletteDisplayTitle == nil)
        #expect(Keybinding.Action.runInPlace(command: "x", arguments: []).paletteDisplayTitle == nil)
        #expect(Keybinding.Action.runCommand(command: "x", arguments: [], options: .empty).paletteDisplayTitle == nil)
        #expect(Keybinding.Action.unbind.paletteDisplayTitle == nil)
        // Non-parameterised actions do have a title.
        #expect(Keybinding.Action.newTab.paletteDisplayTitle == "New tab")
    }

    // MARK: - Delete (⌘⌫)

    @Test func deleteHistoryDoesNotAffectRegularCandidates() {
        let controller = CommandPaletteController()
        controller.commandCandidates = [
            PaletteCandidate(primaryText: "cmd", scope: .command),
        ]
        controller.open()
        controller.input = "> c"

        var deleted: [(PaletteScope, String)] = []
        controller.onDeleteHistoryEntry = { scope, id in
            deleted.append((scope, id))
        }

        // Highlighted row is a regular candidate, not history.
        let consumed = controller.deleteHighlighted()
        #expect(consumed == false)
        #expect(deleted.isEmpty)
    }
}

// MARK: - Keyboard routing (PaletteTextField)

/// Covers the AppKit key path that distinguishes the four Enter variants
/// (plain, ⌘⏎, ⇧⏎, ⌥⏎). Previously ⌘⏎ hit AppKit's no-responder beep and
/// ⇧⏎ / ⌥⏎ inserted a literal newline into the palette search box because
/// the field editor's `insertLineBreak:` / `insertNewlineIgnoringFieldEditor:`
/// dispatches were not intercepted.
@MainActor
@Suite("PaletteTextField keyboard routing")
struct PaletteTextFieldKeyboardTests {

    private func returnEvent(_ modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )
    }

    @Test func enterModeMapsModifierFlags() {
        typealias Coordinator = PaletteTextField.Coordinator
        #expect(Coordinator.enterMode(from: nil) == .plain)
        #expect(Coordinator.enterMode(from: returnEvent([])) == .plain)
        #expect(Coordinator.enterMode(from: returnEvent(.command)) == .commandEnter)
        #expect(Coordinator.enterMode(from: returnEvent(.shift)) == .shiftEnter)
        #expect(Coordinator.enterMode(from: returnEvent(.option)) == .optionEnter)
        // Command takes precedence over other modifiers so ⌘⇧⏎ still
        // reads as a command-enter (split-right) commit, not shift-enter.
        #expect(Coordinator.enterMode(from: returnEvent([.command, .shift])) == .commandEnter)
    }

    @Test func doCommandByRoutesAllNewlineSelectorsToCommit() {
        // Plain ⏎ → `insertNewline:`; ⇧⏎ / ⌥⏎ typically arrive as
        // `insertLineBreak:` or `insertNewlineIgnoringFieldEditor:`.
        // All three must commit so the palette reacts instead of the
        // field editor inserting a literal newline in the search box.
        var commits = 0
        var cancels = 0
        var deletes = 0
        let coordinator = PaletteTextField.Coordinator(
            text: .constant(""),
            onCommit: { _ in commits += 1 },
            onCancel: { cancels += 1 },
            onDelete: { deletes += 1 }
        )
        let control = NSTextField()
        let textView = NSTextView()

        let newlineSelectors: [Selector] = [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertLineBreak(_:)),
            #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
        ]
        for sel in newlineSelectors {
            #expect(
                coordinator.control(control, textView: textView, doCommandBy: sel) == true,
                "selector \(sel) should be claimed"
            )
        }
        #expect(commits == newlineSelectors.count)
        #expect(cancels == 0)
        #expect(deletes == 0)
    }

    @Test func doCommandByRoutesCancelAndDelete() {
        var commits = 0
        var cancels = 0
        var deletes = 0
        let coordinator = PaletteTextField.Coordinator(
            text: .constant(""),
            onCommit: { _ in commits += 1 },
            onCancel: { cancels += 1 },
            onDelete: { deletes += 1 }
        )
        let control = NSTextField()
        let textView = NSTextView()

        #expect(
            coordinator.control(
                control, textView: textView,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))
            ) == true
        )
        #expect(
            coordinator.control(
                control, textView: textView,
                doCommandBy: #selector(NSResponder.deleteToBeginningOfLine(_:))
            ) == true
        )
        #expect(cancels == 1)
        #expect(deletes == 1)
        #expect(commits == 0)
    }

    @Test func doCommandByLetsNavigationBubble() {
        // Up/down/tab must return false so SwiftUI's outer `onKeyPress`
        // handlers move the highlight / toggle selection.
        let coordinator = PaletteTextField.Coordinator(
            text: .constant(""),
            onCommit: { _ in },
            onCancel: {},
            onDelete: {}
        )
        let control = NSTextField()
        let textView = NSTextView()

        let bubbling: [Selector] = [
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.insertBacktab(_:)),
        ]
        for sel in bubbling {
            #expect(
                coordinator.control(control, textView: textView, doCommandBy: sel) == false,
                "selector \(sel) should bubble to SwiftUI"
            )
        }
    }

    @Test func performKeyEquivalentClaimsCommandReturnWhenFocused() {
        // ⌘⏎ is delivered to `performKeyEquivalent` (not `keyDown` on the
        // text field, because the field editor owns first responder once
        // the field is focused). The subclass must claim the event and
        // invoke `onModifiedReturn`, otherwise AppKit emits the
        // no-responder beep.
        let field = ActivatingPaletteField()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(field)
        _ = window.makeFirstResponder(field)

        var receivedMode: PaletteEnterMode?
        field.onModifiedReturn = { event in
            receivedMode = PaletteTextField.Coordinator.enterMode(from: event)
        }

        guard let event = returnEvent(.command) else {
            Issue.record("could not synthesise NSEvent for ⌘⏎")
            return
        }
        #expect(field.performKeyEquivalent(with: event) == true)
        #expect(receivedMode == .commandEnter)
    }

    @Test func performKeyEquivalentIgnoresPlainReturn() {
        // Plain ⏎ must stay on the `keyDown` → `doCommandBy` path; if
        // `performKeyEquivalent` claimed it the palette would double-commit
        // (once here, once from `insertNewline:`).
        let field = ActivatingPaletteField()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(field)
        _ = window.makeFirstResponder(field)

        var called = false
        field.onModifiedReturn = { _ in called = true }

        guard let event = returnEvent([]) else {
            Issue.record("could not synthesise NSEvent for ⏎")
            return
        }
        #expect(field.performKeyEquivalent(with: event) == false)
        #expect(called == false)
    }

    @Test func performKeyEquivalentIgnoresWhenNotFocused() {
        // If another view owns first responder, this field must not eat
        // the ⌘⏎ — otherwise two palettes in the view tree would fight
        // for the event.
        let field = ActivatingPaletteField()
        let sibling = NSTextField()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(sibling)
        _ = window.makeFirstResponder(sibling)

        var called = false
        field.onModifiedReturn = { _ in called = true }

        guard let event = returnEvent(.command) else {
            Issue.record("could not synthesise NSEvent for ⌘⏎")
            return
        }
        #expect(field.performKeyEquivalent(with: event) == false)
        #expect(called == false)
    }

    // MARK: - Query history browsing

    @Test func browseHistoryPreviousWithEmptyInputEntersHistoryMode() {
        let controller = CommandPaletteController()
        controller.queryHistory = ["ssh db1", "p home", "> newTab"]
        controller.open()

        #expect(controller.input == "")
        #expect(controller.isBrowsingHistory == false)

        controller.browseHistoryPrevious()
        #expect(controller.input == "ssh db1")
        #expect(controller.isBrowsingHistory == true)
        #expect(controller.historyBrowsingIndex == 0)
    }

    @Test func browseHistoryPreviousMovesToOlderEntries() {
        let controller = CommandPaletteController()
        controller.queryHistory = ["ssh db1", "p home", "> newTab"]
        controller.open()

        controller.browseHistoryPrevious()
        controller.browseHistoryPrevious()
        #expect(controller.input == "p home")
        #expect(controller.historyBrowsingIndex == 1)

        controller.browseHistoryPrevious()
        #expect(controller.input == "> newTab")
        #expect(controller.historyBrowsingIndex == 2)
    }

    @Test func browseHistoryPreviousStopsAtOldest() {
        let controller = CommandPaletteController()
        controller.queryHistory = ["ssh db1", "p home"]
        controller.open()

        controller.browseHistoryPrevious()
        controller.browseHistoryPrevious()
        controller.browseHistoryPrevious()
        #expect(controller.input == "p home")
        #expect(controller.historyBrowsingIndex == 1)
    }

    @Test func browseHistoryNextMovesToNewerEntries() {
        let controller = CommandPaletteController()
        controller.queryHistory = ["ssh db1", "p home", "> newTab"]
        controller.open()

        controller.browseHistoryPrevious()
        controller.browseHistoryPrevious()
        controller.browseHistoryPrevious()
        #expect(controller.input == "> newTab")

        controller.browseHistoryNext()
        #expect(controller.input == "p home")
        #expect(controller.historyBrowsingIndex == 1)

        controller.browseHistoryNext()
        #expect(controller.input == "ssh db1")
        #expect(controller.historyBrowsingIndex == 0)
    }

    @Test func browseHistoryNextAtMostRecentExitsHistoryMode() {
        let controller = CommandPaletteController()
        controller.queryHistory = ["ssh db1", "p home"]
        controller.open()

        controller.browseHistoryPrevious()
        #expect(controller.input == "ssh db1")
        #expect(controller.isBrowsingHistory == true)

        controller.browseHistoryNext()
        #expect(controller.input == "")
        #expect(controller.isBrowsingHistory == false)
    }

    @Test func editingWhileBrowsingHistoryExitsHistoryMode() {
        let controller = CommandPaletteController()
        controller.queryHistory = ["ssh db1", "p home"]
        controller.open()

        controller.browseHistoryPrevious()
        #expect(controller.input == "ssh db1")
        #expect(controller.isBrowsingHistory == true)

        controller.input = "ssh db1 edited"
        #expect(controller.isBrowsingHistory == false)
        #expect(controller.input == "ssh db1 edited")
    }

    @Test func browseHistoryDoesNothingWhenInputIsNonEmpty() {
        let controller = CommandPaletteController()
        controller.queryHistory = ["ssh db1", "p home"]
        controller.open()
        controller.input = "some query"

        controller.browseHistoryPrevious()
        #expect(controller.input == "some query")
        #expect(controller.isBrowsingHistory == false)
    }

    @Test func browseHistoryDoesNothingWithEmptyHistory() {
        let controller = CommandPaletteController()
        controller.queryHistory = []
        controller.open()

        controller.browseHistoryPrevious()
        #expect(controller.input == "")
        #expect(controller.isBrowsingHistory == false)
    }

    @Test func closeResetsHistoryBrowsingState() {
        let controller = CommandPaletteController()
        controller.queryHistory = ["ssh db1"]
        controller.open()

        controller.browseHistoryPrevious()
        #expect(controller.isBrowsingHistory == true)

        controller.close()
        #expect(controller.isBrowsingHistory == false)
        #expect(controller.input == "")
    }
}
