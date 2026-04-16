import SwiftUI

/// Stores notification items triggered by terminal OSC sequences.
@MainActor
@Observable
final class NotificationStore {
    static let shared = NotificationStore()

    /// Format an unread count for badge display (caps at "9+").
    static func badgeText(for count: Int) -> String {
        count > 9 ? "9+" : "\(count)"
    }

    struct Item: Identifiable, Hashable {
        let id: UUID
        let sessionID: UUID
        let tabID: UUID
        let paneID: UUID
        let title: String
        let body: String
        let createdAt: Date
        var isRead: Bool

        init(
            id: UUID = UUID(),
            sessionID: UUID,
            tabID: UUID,
            paneID: UUID,
            title: String,
            body: String,
            createdAt: Date = Date(),
            isRead: Bool = false
        ) {
            self.id = id
            self.sessionID = sessionID
            self.tabID = tabID
            self.paneID = paneID
            self.title = title
            self.body = body
            self.createdAt = createdAt
            self.isRead = isRead
        }
    }

    private(set) var items: [Item] = []

    // MARK: Derived indexes
    private(set) var unreadPaneIDs: Set<UUID> = []
    private(set) var unreadCountByTabID: [UUID: Int] = [:]
    private(set) var unreadCountBySessionID: [UUID: Int] = [:]

    private var lastCooldownTimestamps: [String: Date] = [:]

    // MARK: - Reset (for tests)

    func reset() {
        items.removeAll()
        unreadPaneIDs.removeAll()
        unreadCountByTabID.removeAll()
        unreadCountBySessionID.removeAll()
        lastCooldownTimestamps.removeAll()
    }

    // MARK: - Add

    func add(
        sessionID: UUID,
        tabID: UUID,
        paneID: UUID,
        title: String,
        body: String,
        cooldownKey: String? = nil,
        cooldownInterval: TimeInterval = 5
    ) {
        if let key = cooldownKey {
            let now = Date()
            if let last = lastCooldownTimestamps[key],
               now.timeIntervalSince(last) < cooldownInterval {
                return
            }
            lastCooldownTimestamps[key] = now
        }

        let item = Item(
            sessionID: sessionID,
            tabID: tabID,
            paneID: paneID,
            title: title,
            body: body
        )
        items.append(item)
        rebuildIndexes()
    }

    // MARK: - Mark Read / Clear

    func markRead(paneID: UUID) {
        guard unreadPaneIDs.contains(paneID) else { return }
        var changed = false
        for i in items.indices where items[i].paneID == paneID && !items[i].isRead {
            items[i].isRead = true
            changed = true
        }
        if changed {
            rebuildIndexes()
        }
    }

    func clearAll(forPaneID paneID: UUID) {
        clearItems { $0.paneID == paneID }
    }

    func clearAll(forTabID tabID: UUID) {
        clearItems { $0.tabID == tabID }
    }

    func clearAll(forSessionID sessionID: UUID) {
        clearItems { $0.sessionID == sessionID }
    }

    private func clearItems(where predicate: (Item) -> Bool) {
        let before = items.count
        items.removeAll(where: predicate)
        if items.count != before {
            rebuildIndexes()
        }
    }

    // MARK: - Index Rebuild

    private func rebuildIndexes() {
        var panes: Set<UUID> = []
        var tabs: [UUID: Int] = [:]
        var sessions: [UUID: Int] = [:]

        for item in items where !item.isRead {
            panes.insert(item.paneID)
            tabs[item.tabID, default: 0] += 1
            sessions[item.sessionID, default: 0] += 1
        }

        unreadPaneIDs = panes
        unreadCountByTabID = tabs
        unreadCountBySessionID = sessions
    }
}

/// Blue capsule badge showing an unread notification count.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(NotificationStore.badgeText(for: count))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(Color(nsColor: .systemBlue))
            )
    }
}
