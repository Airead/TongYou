import SwiftUI
import TYTerminal

/// A VS Code-style quick picker overlay for selecting and attaching remote sessions.
struct SessionPickerView: View {

    let sessions: [TerminalSession]
    let attachedSessionIDs: Set<UUID>
    let onAttach: (UUID) -> Void
    let onDismiss: () -> Void

    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0

    private var filteredSessions: [TerminalSession] {
        let remoteSessions = sessions.filter { $0.source.isRemote }
        if searchText.isEmpty {
            return remoteSessions
        }
        let query = searchText.lowercased()
        return remoteSessions.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search remote sessions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit {
                        confirmSelection()
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if filteredSessions.isEmpty {
                Text("No remote sessions")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredSessions.enumerated()), id: \.element.id) { index, session in
                                pickerRow(session, index: index)
                                    .id(index)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 240)
                    .onChange(of: selectedIndex) { _, newValue in
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 400)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    @ViewBuilder
    private func pickerRow(_ session: TerminalSession, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let isAttached = session.source.serverSessionID.map { attachedSessionIDs.contains($0) } ?? false

        HStack(spacing: 8) {
            Image(systemName: isAttached
                  ? "rectangle.connected.to.line.below"
                  : "rectangle.dashed")
                .font(.system(size: 11))
                .foregroundStyle(isAttached ? .blue : .gray)
                .frame(width: 14)

            Text(session.name)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer()

            if isAttached {
                Text("attached")
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.12))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedIndex = index
            confirmSelection()
        }
        .onHover { hovering in
            if hovering {
                selectedIndex = index
            }
        }
    }

    private func moveSelection(by delta: Int) {
        let count = filteredSessions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func confirmSelection() {
        guard filteredSessions.indices.contains(selectedIndex) else { return }
        let session = filteredSessions[selectedIndex]
        if let serverID = session.source.serverSessionID {
            onAttach(serverID)
        }
        onDismiss()
    }
}
