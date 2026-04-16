import SwiftUI
import TYTerminal
import UniformTypeIdentifiers

/// Tab bar displayed above the terminal area.
/// Shows tab titles, close buttons, and a new-tab button.
struct TabBarView: View {

    let tabs: [TerminalTab]
    let activeTabIndex: Int
    let tabUnreadCounts: [UUID: Int]
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    let onNew: () -> Void
    let onMove: (Int, Int) -> Void

    /// The tab currently being dragged (for reordering).
    @State private var draggedTab: TerminalTab?

    static let barHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                tabItem(tab, index: index)
                    .onDrag {
                        draggedTab = tab
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: TabDropDelegate(
                        item: tab,
                        items: tabs,
                        draggedItem: $draggedTab,
                        onMove: onMove
                    ))
            }

            // New tab button
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: Self.barHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab (Cmd+T)")

            Spacer()
        }
        .frame(height: Self.barHeight)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
    }

    @ViewBuilder
    private func tabItem(_ tab: TerminalTab, index: Int) -> some View {
        let isActive = index == activeTabIndex

        HStack(spacing: 4) {
            Text(tab.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive ? .primary : .secondary)

            if let count = tabUnreadCounts[tab.id], count > 0 {
                Text(Self.badgeText(for: count))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color(nsColor: .systemBlue))
                    )
            }

            Button {
                onClose(index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.5)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.barHeight)
        .background(isActive
            ? Color(nsColor: .controlBackgroundColor)
            : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(index)
        }
    }
}

extension TabBarView {
    static func badgeText(for count: Int) -> String {
        count > 9 ? "9+" : "\(count)"
    }
}

// MARK: - Drag & Drop

private struct TabDropDelegate: DropDelegate {

    let item: TerminalTab
    let items: [TerminalTab]
    @Binding var draggedItem: TerminalTab?

    let onMove: (Int, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedItem,
              dragged.id != item.id,
              let fromIndex = items.firstIndex(where: { $0.id == dragged.id }),
              let toIndex = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        onMove(fromIndex, toIndex)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
