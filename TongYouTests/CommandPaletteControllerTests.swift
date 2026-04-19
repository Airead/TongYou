import Foundation
import Testing
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
        #expect(controller.rows.count == 1)

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
        // Opening the palette with an empty query (default session scope)
        // should list every injected candidate.
        let controller = CommandPaletteController()
        controller.sessionCandidates = [
            PaletteCandidate(primaryText: "work", scope: .session),
            PaletteCandidate(primaryText: "home", scope: .session),
            PaletteCandidate(primaryText: "lab", scope: .session),
        ]
        controller.open()

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
        controller.input = "ssh "
        controller.moveHighlight(by: 2)
        #expect(controller.highlightedIndex == 2)

        controller.input = "ssh d"
        #expect(controller.highlightedIndex == 0)
    }

    @Test func moveHighlightWrapsAround() {
        let controller = CommandPaletteController()
        controller.sshCandidates = (0..<3).map {
            PaletteCandidate(primaryText: "host\($0)", scope: .ssh)
        }
        controller.open()
        controller.input = "ssh "
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
        controller.input = "ssh "
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
        controller.input = "ssh "
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
        controller.input = "ssh "
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
        controller.input = "ssh "
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
        controller.input = "ssh "

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
}
