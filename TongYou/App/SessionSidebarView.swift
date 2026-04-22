import SwiftUI
import TYTerminal
import UniformTypeIdentifiers

/// Sidebar view showing the list of terminal sessions.
/// Supports selection, new session, rename via context menu, and close.
/// Remote sessions show attach/detach state and offer corresponding context actions.
/// Sessions are grouped into attached and detached sections with a divider in between.
/// Drag-and-drop reordering is supported within each group (only on drop, no local state).
struct SessionSidebarView: View {

    let sessions: [TerminalSession]
    let activeSessionIndex: Int
    let attachedSessionIDs: Set<UUID>
    let sessionUnreadCounts: [UUID: Int]
    let activeSessionIDs: Set<UUID>
    let themeForeground: RGBColor
    let themeBackground: RGBColor
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    let onNew: () -> Void
    let onRenameRequest: (Int) -> Void
    let onAttach: (Int) -> Void
    let onDetach: (Int) -> Void
    let onDoubleClick: (Int) -> Void
    let onMoveSession: (Int, Int) -> Void

    static let sidebarWidth: CGFloat = 180

    private struct Item: Identifiable {
        let id: String
        let index: Int
        let session: TerminalSession
    }

    private var attachedItems: [Item] {
        sessions.enumerated().compactMap { idx, session in
            attachedSessionIDs.contains(session.id)
                ? Item(id: "\(session.id.uuidString)-attached", index: idx, session: session)
                : nil
        }
    }

    private var detachedItems: [Item] {
        sessions.enumerated().compactMap { idx, session in
            attachedSessionIDs.contains(session.id)
                ? nil
                : Item(id: "\(session.id.uuidString)-detached", index: idx, session: session)
        }
    }

    var body: some View {
        let fgColor = Color(nsColor: themeForeground.nsColor)
        let bgColor = Color(nsColor: themeBackground.nsColor)

        VStack(spacing: 0) {
            // Header: SESSIONS label + new session button
            HStack(spacing: 4) {
                Text("SESSIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(fgColor.opacity(0.5))
                Spacer()
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(fgColor.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Session (Cmd+I)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            // Session list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(attachedItems) { item in
                        draggableSessionRow(item, fgColor: fgColor)
                    }

                    if !attachedItems.isEmpty && !detachedItems.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }

                    ForEach(detachedItems) { item in
                        draggableSessionRow(item, fgColor: fgColor)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
        .frame(width: Self.sidebarWidth)
        .background(bgColor.opacity(0.5))
    }

    @ViewBuilder
    private func sessionRow(
        _ session: TerminalSession,
        index: Int,
        fgColor: Color
    ) -> some View {
        let isActive = index == activeSessionIndex
        let isRemote = session.source.isRemote
        let isAttached = attachedSessionIDs.contains(session.id)

        HStack(spacing: 4) {
            sessionIcon(isRemote: isRemote, isAttached: isAttached, fgColor: fgColor)

            Text(session.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let count = sessionUnreadCounts[session.id], count > 0 {
                UnreadBadge(count: count)
            }

            if !isActive, activeSessionIDs.contains(session.id) {
                ActivityPulseDot()
                    .padding(.trailing, 2)
            }

            if !(sessionUnreadCounts[session.id] ?? 0 > 0) {
                Text("\(session.tabCount)")
                    .font(.system(size: 10))
                    .foregroundStyle(fgColor.opacity(0.3))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(fgColor.opacity(0.08))
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .foregroundStyle(isActive ? fgColor : fgColor.opacity(0.6))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(index)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onDoubleClick(index)
            }
        )
        .contextMenu {
            Button("Rename") {
                onRenameRequest(index)
            }
            if isRemote {
                if isAttached {
                    Button("Detach") {
                        onDetach(index)
                    }
                } else {
                    Button("Attach") {
                        onAttach(index)
                    }
                }
            }
            Divider()
            Button("Close Session") {
                onClose(index)
            }
        }
    }

    private func sessionIcon(isRemote: Bool, isAttached: Bool, fgColor: Color) -> some View {
        let name = isRemote
            ? (isAttached ? "rectangle.connected.to.line.below" : "rectangle.dashed")
            : "terminal"
        let color: Color = isRemote ? (isAttached ? .blue : fgColor.opacity(0.4)) : fgColor.opacity(0.6)
        return Image(systemName: name)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .frame(width: 14)
    }

    private func draggableSessionRow(_ item: Item, fgColor: Color) -> some View {
        sessionRow(item.session, index: item.index, fgColor: fgColor)
            .onDrag {
                NSItemProvider(object: item.session.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: SessionDropDelegate(
                targetIndex: item.index,
                sessions: sessions,
                attachedSessionIDs: attachedSessionIDs,
                onMove: onMoveSession
            ))
    }
}

// MARK: - Drag & Drop

private struct SessionDropDelegate: DropDelegate {

    let targetIndex: Int
    let sessions: [TerminalSession]
    let attachedSessionIDs: Set<UUID>
    let onMove: (Int, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { data, _ in
            let string: String?
            if let s = data as? String {
                string = s
            } else if let d = data as? Data {
                string = String(data: d, encoding: .utf8)
            } else {
                string = nil
            }
            guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let draggedUUID = UUID(uuidString: s) else {
                return
            }
            DispatchQueue.main.async {
                guard let fromIndex = sessions.firstIndex(where: { $0.id == draggedUUID }),
                      sessions.indices.contains(targetIndex),
                      fromIndex != targetIndex,
                      attachedSessionIDs.contains(sessions[fromIndex].id) == attachedSessionIDs.contains(sessions[targetIndex].id) else {
                    return
                }
                onMove(fromIndex, targetIndex)
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
