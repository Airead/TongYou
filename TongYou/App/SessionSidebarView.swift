import SwiftUI
import TYTerminal

/// Sidebar view showing the list of terminal sessions.
/// Supports selection, new session, rename via context menu, and close.
/// Remote sessions show attach/detach state and offer corresponding context actions.
struct SessionSidebarView: View {

    let sessions: [TerminalSession]
    let activeSessionIndex: Int
    let attachedSessionIDs: Set<UUID>
    let themeForeground: RGBColor
    let themeBackground: RGBColor
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    let onNew: () -> Void
    let onRenameRequest: (Int) -> Void
    let onAttach: (Int) -> Void
    let onDetach: (Int) -> Void
    let onDoubleClick: (Int) -> Void

    @State private var lastClickTime: Date = .distantPast
    @State private var lastClickIndex: Int = -1

    static let sidebarWidth: CGFloat = 180

    var body: some View {
        let fgColor = Color(nsColor: themeForeground.nsColor)
        let bgColor = Color(nsColor: themeBackground.nsColor)

        VStack(spacing: 0) {
            // Session list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        sessionRow(session, index: index, fgColor: fgColor)
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
                .foregroundStyle(fgColor.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Session (Cmd+I)")
        }
        .frame(width: Self.sidebarWidth)
        .background(bgColor.opacity(0.5))
    }

    @ViewBuilder
    private func sessionRow(_ session: TerminalSession, index: Int, fgColor: Color) -> some View {
        let isActive = index == activeSessionIndex
        let isRemote = session.source.isRemote
        let isAttached = session.source.serverSessionID.map { attachedSessionIDs.contains($0) } ?? false

        HStack(spacing: 4) {
            sessionIcon(isRemote: isRemote, isAttached: isAttached, fgColor: fgColor)

            Text(session.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .foregroundStyle(isActive ? fgColor : fgColor.opacity(0.6))
        .contentShape(Rectangle())
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(lastClickTime) < 0.3 && lastClickIndex == index {
                onDoubleClick(index)
                lastClickTime = .distantPast
            } else {
                onSelect(index)
            }
            lastClickTime = now
            lastClickIndex = index
        }
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
}
