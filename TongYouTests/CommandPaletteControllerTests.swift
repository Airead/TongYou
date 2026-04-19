import Foundation
import Testing
@testable import TongYou

@MainActor
@Suite("CommandPaletteController")
struct CommandPaletteControllerTests {

    // MARK: - Scope parsing

    @Test func paletteScopeFromPrefix() {
        // Default scope is SSH.
        #expect(PaletteScope.parse(input: "").scope == .ssh)
        #expect(PaletteScope.parse(input: "db").scope == .ssh)

        // Recognised prefixes switch scope.
        #expect(PaletteScope.parse(input: "> restart").scope == .command)
        #expect(PaletteScope.parse(input: "p home").scope == .profile)
        #expect(PaletteScope.parse(input: "t 2").scope == .tab)
        #expect(PaletteScope.parse(input: "s work").scope == .session)
        #expect(PaletteScope.parse(input: "ssh db").scope == .ssh)
    }

    @Test func paletteScopeRemovesPrefixForFuzzy() {
        // The query fed to fuzzy matching must have the prefix stripped so
        // "s db" filters sessions by "db", not by the literal "s db".
        #expect(PaletteScope.parse(input: "s db").query == "db")
        #expect(PaletteScope.parse(input: "> restart").query == "restart")
        #expect(PaletteScope.parse(input: "p home").query == "home")
        #expect(PaletteScope.parse(input: "t 2").query == "2")
        #expect(PaletteScope.parse(input: "ssh host1").query == "host1")

        // Unprefixed SSH scope passes the query through verbatim.
        #expect(PaletteScope.parse(input: "host1").query == "host1")
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
        controller.sshCandidates = [
            PaletteCandidate(primaryText: "db1", scope: .ssh),
        ]

        controller.open()
        #expect(controller.isOpen)
        #expect(controller.rows.count == 1)

        controller.close()
        #expect(!controller.isOpen)
        #expect(controller.input == "")
        #expect(controller.rows.isEmpty)
    }

    @Test func paletteSessionScopeOpensWithPrefix() {
        // ⌘R pre-fills the input so the panel starts in session scope and
        // the first keystroke filters by session name.
        let controller = CommandPaletteController()
        controller.openSessionScope()
        #expect(controller.isOpen)
        #expect(controller.input == "s ")
        #expect(controller.scope == .session)
        #expect(controller.query == "")
    }

    // MARK: - Session scope (Phase 8)

    @Test func sessionScopeListsAllOpenSessions() {
        // Opening the palette in session scope with an empty query should
        // list every injected candidate (no SSH-style ad-hoc fallback).
        let controller = CommandPaletteController()
        controller.sessionCandidates = [
            PaletteCandidate(primaryText: "work", scope: .session),
            PaletteCandidate(primaryText: "home", scope: .session),
            PaletteCandidate(primaryText: "lab", scope: .session),
        ]
        controller.openSessionScope()

        #expect(controller.rows.count == 3)
        #expect(controller.rows.map(\.candidate.primaryText) == ["work", "home", "lab"])
    }

    @Test func sessionFuzzyMatchByDisplayName() {
        // With the `s ` prefix active, the trailing characters drive fuzzy
        // matching across the session list.
        let controller = CommandPaletteController()
        controller.sessionCandidates = [
            PaletteCandidate(primaryText: "work", scope: .session),
            PaletteCandidate(primaryText: "home", scope: .session),
            PaletteCandidate(primaryText: "lab", scope: .session),
        ]
        controller.openSessionScope()
        controller.input = "s hom"

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
        controller.input = "db"

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
        controller.moveHighlight(by: 2)
        #expect(controller.highlightedIndex == 2)

        controller.input = "d"
        #expect(controller.highlightedIndex == 0)
    }

    @Test func moveHighlightWrapsAround() {
        let controller = CommandPaletteController()
        controller.sshCandidates = (0..<3).map {
            PaletteCandidate(primaryText: "host\($0)", scope: .ssh)
        }
        controller.open()
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
        #expect(controller.selection.isEmpty)

        // Highlight row 0, add it.
        controller.toggleSelection()
        #expect(controller.selection.count == 1)

        // Move to row 1 and add it too.
        controller.moveHighlight(by: 1)
        controller.toggleSelection()
        #expect(controller.selection.count == 2)

        // Toggle row 1 off; row 0 should remain.
        controller.toggleSelection()
        #expect(controller.selection.count == 1)
        #expect(controller.selection.first == controller.rows[0].id)
    }

    @Test func selectionRemovesOnSecondTab() {
        // Re-toggling the same highlighted row removes it — so a user can
        // un-pick a selection without having to clear the whole bag.
        let controller = CommandPaletteController()
        controller.sshCandidates = (0..<3).map {
            PaletteCandidate(primaryText: "h\($0)", scope: .ssh)
        }
        controller.open()
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
        controller.input = "totally-novel"

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
        controller.input = "nope"

        #expect(controller.rows.isEmpty)
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
        controller.input = "db"

        #expect(controller.rows.count == 1)
        #expect(controller.rows[0].candidate.primaryText == "db1")
    }
}
