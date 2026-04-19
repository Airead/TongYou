import Foundation
import TYTerminal

/// Per-tab pane selection + broadcast-input state.
///
/// `selections[tabID]` is the set of panes the user has marked as a group;
/// `broadcasting` tracks which tabs are currently forwarding keystrokes to
/// every pane in their selection. The two are intentionally orthogonal so a
/// Cmd+Alt+click-driven selection can persist even when broadcasting is off
/// (and so future batch operations can reuse the same data).
@MainActor
@Observable
final class PaneSelectionManager {

    private(set) var selections: [UUID: Set<UUID>] = [:]
    private(set) var broadcasting: Set<UUID> = []

    // MARK: - Queries

    func isBroadcasting(tab tabID: UUID) -> Bool {
        broadcasting.contains(tabID)
    }

    func isSelected(pane paneID: UUID, inTab tabID: UUID) -> Bool {
        selections[tabID]?.contains(paneID) ?? false
    }

    func selection(inTab tabID: UUID) -> Set<UUID> {
        selections[tabID] ?? []
    }

    /// Whether the pane should receive input when `sourcePaneID` is typed in
    /// during broadcast. Returns true for every pane in the same tab's
    /// selection when broadcasting is enabled. The source pane itself is
    /// always included so typing path is identical across selected panes.
    func broadcastTargets(from sourcePaneID: UUID, inTab tabID: UUID) -> Set<UUID>? {
        guard isBroadcasting(tab: tabID) else { return nil }
        let sel = selection(inTab: tabID)
        guard sel.contains(sourcePaneID), sel.count >= 2 else { return nil }
        return sel
    }

    // MARK: - Mutations

    /// Toggle whether `paneID` is part of the selection in `tabID`. Used by
    /// Cmd+Alt+click. Leaves broadcasting untouched so the user can curate
    /// the group before flipping the switch (or mid-broadcast).
    func togglePane(_ paneID: UUID, inTab tabID: UUID) {
        var set = selections[tabID] ?? []
        if set.contains(paneID) {
            set.remove(paneID)
        } else {
            set.insert(paneID)
        }
        if set.isEmpty {
            selections.removeValue(forKey: tabID)
        } else {
            selections[tabID] = set
        }
    }

    /// Replace the selection with `paneIDs` (used for "select all" logic).
    func setSelection(_ paneIDs: Set<UUID>, inTab tabID: UUID) {
        if paneIDs.isEmpty {
            selections.removeValue(forKey: tabID)
        } else {
            selections[tabID] = paneIDs
        }
    }

    /// Drop the selection for `tabID` and turn off broadcasting for that tab.
    /// Returns whether any state actually changed, so callers can skip the
    /// "cleared" toast when there was nothing to clear.
    @discardableResult
    func clearSelection(inTab tabID: UUID) -> Bool {
        let hadSelection = selections.removeValue(forKey: tabID) != nil
        let wasBroadcasting = broadcasting.remove(tabID) != nil
        return hadSelection || wasBroadcasting
    }

    /// Attempt to toggle broadcasting for `tab`. Returns the resulting state:
    /// - `.enabled`: broadcasting is now on; selection contains `selected`.
    /// - `.disabled`: broadcasting is now off; selection retained verbatim.
    /// - `.rejectedTooFewPanes`: caller should show a toast; no state changed.
    ///
    /// When the tab has no existing selection (or fewer than 2 panes selected)
    /// this method implicitly adopts `candidatePanes` as the target group —
    /// the common path is "user hits the shortcut without curating a
    /// selection, we broadcast to every pane in the tab".
    @discardableResult
    func toggleBroadcast(
        tab tabID: UUID,
        candidatePanes: [UUID]
    ) -> ToggleBroadcastResult {
        if broadcasting.contains(tabID) {
            broadcasting.remove(tabID)
            return .disabled
        }
        let existing = selections[tabID] ?? []
        let target: Set<UUID>
        if existing.count >= 2 {
            target = existing
        } else {
            target = Set(candidatePanes)
        }
        guard target.count >= 2 else {
            return .rejectedTooFewPanes
        }
        selections[tabID] = target
        broadcasting.insert(tabID)
        return .enabled
    }

    enum ToggleBroadcastResult: Equatable {
        case enabled
        case disabled
        case rejectedTooFewPanes
    }

    // MARK: - Cleanup

    /// Forget any state tied to a tab that is being closed.
    func didRemoveTab(_ tabID: UUID) {
        selections.removeValue(forKey: tabID)
        broadcasting.remove(tabID)
    }

    /// Drop a pane ID from every tab's selection. Called when a pane is
    /// closed so stale UUIDs don't linger. If the drop empties a tab's
    /// selection, broadcasting for that tab is also turned off — no point
    /// broadcasting to a group that no longer has anyone in it.
    func didRemovePane(_ paneID: UUID) {
        for (tabID, var set) in selections {
            guard set.remove(paneID) != nil else { continue }
            if set.isEmpty {
                selections.removeValue(forKey: tabID)
                broadcasting.remove(tabID)
            } else {
                selections[tabID] = set
            }
        }
    }
}
