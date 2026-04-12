import SwiftUI
import TYTerminal

/// Sidebar view showing the list of terminal sessions.
/// Supports selection, new session, rename via context menu, and close.
struct SessionSidebarView: View {

    let sessions: [TerminalSession]
    let activeSessionIndex: Int
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    let onNew: () -> Void
    let onRename: (Int, String) -> Void

    @State private var editingSessionID: UUID?
    @State private var editingName: String = ""

    static let sidebarWidth: CGFloat = 180

    var body: some View {
        VStack(spacing: 0) {
            // Session list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        sessionRow(session, index: index)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }

            Divider()

            // New session button
            Button(action: onNew) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                    Text("New Session")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Session (Cmd+Shift+N)")
        }
        .frame(width: Self.sidebarWidth)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private func sessionRow(_ session: TerminalSession, index: Int) -> some View {
        let isActive = index == activeSessionIndex
        let isEditing = editingSessionID == session.id

        HStack(spacing: 4) {
            if isEditing {
                TextField("", text: $editingName, onCommit: {
                    let trimmed = editingName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onRename(index, trimmed)
                    }
                    editingSessionID = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
            } else {
                Text(session.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("\(session.tabCount)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .foregroundStyle(isActive ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing {
                onSelect(index)
            }
        }
        .contextMenu {
            Button("Rename") {
                editingName = session.name
                editingSessionID = session.id
            }
            Divider()
            Button("Close Session") {
                onClose(index)
            }
        }
    }
}
