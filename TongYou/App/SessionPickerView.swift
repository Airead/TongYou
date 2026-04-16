import SwiftUI
import TYTerminal

/// A VS Code-style quick picker overlay for switching between sessions.
struct SessionPickerView: View {

    let sessions: [TerminalSession]
    let activeSessionIndex: Int
    let attachedSessionIDs: Set<UUID>
    let onSelect: (Int) -> Void
    let onDismiss: () -> Void

    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0

    private var filteredSessions: [(offset: Int, element: TerminalSession)] {
        let indexed = Array(sessions.enumerated())
        if searchText.isEmpty {
            return indexed
        }
        let query = searchText.lowercased()
        return indexed.filter { $0.element.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                SearchTextField(
                    text: $searchText,
                    placeholder: "Search sessions...",
                    onSubmit: { confirmSelection() }
                )
                .frame(maxWidth: .infinity, minHeight: 16)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if filteredSessions.isEmpty {
                Text("No sessions")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredSessions.enumerated()), id: \.element.element.id) { pickerIndex, item in
                                pickerRow(item.element, originalIndex: item.offset, pickerIndex: pickerIndex)
                                    .id(item.element.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 240)
                    .onChange(of: selectedIndex) { _, newValue in
                        if filteredSessions.indices.contains(newValue) {
                            proxy.scrollTo(filteredSessions[newValue].element.id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 400)
        .overlayPanelStyle()
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
    private func pickerRow(_ session: TerminalSession, originalIndex: Int, pickerIndex: Int) -> some View {
        let isSelected = pickerIndex == selectedIndex
        let isCurrent = originalIndex == activeSessionIndex
        let isRemote = session.source.isRemote
        let isAttached = attachedSessionIDs.contains(session.id)

        HStack(spacing: 8) {
            sessionIcon(isRemote: isRemote, isAttached: isAttached)

            Text(session.name)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer()

            if isCurrent {
                Text("current")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.12))
                    )
            } else if isRemote && !isAttached {
                Text("detached")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.gray.opacity(0.12))
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
            selectedIndex = pickerIndex
            confirmSelection()
        }
        .onHover { hovering in
            if hovering {
                selectedIndex = pickerIndex
            }
        }
    }

    private func sessionIcon(isRemote: Bool, isAttached: Bool) -> some View {
        let name = isRemote
            ? (isAttached ? "rectangle.connected.to.line.below" : "rectangle.dashed")
            : "terminal"
        let color: Color = isRemote ? (isAttached ? .blue : .gray) : .secondary
        return Image(systemName: name)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .frame(width: 14)
    }

    private func moveSelection(by delta: Int) {
        let count = filteredSessions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func confirmSelection() {
        guard filteredSessions.indices.contains(selectedIndex) else { return }
        let originalIndex = filteredSessions[selectedIndex].offset
        onSelect(originalIndex)
        onDismiss()
    }
}

// MARK: - SearchTextField

/// AppKit-backed search field that reports live text changes, including IME composition.
private struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = ActivatingTextField()
        field.isBordered = false
        field.isBezeled = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator

        // Capture live edits (including IME marked text) via the field editor.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: nil
        )

        field.onDidMoveToWindow = { [weak field] in
            guard let field, field.window != nil else { return }
            // Defer so AppKit finishes establishing the responder chain.
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }

        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self._text = text
            self.onSubmit = onSubmit
        }

        @objc func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSText else { return }
            let newValue = String(textView.string)
            if newValue != text {
                text = newValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Escape is handled by the view's onKeyPress(.escape).
                return false
            }
            return false
        }
    }
}

/// NSTextField subclass that triggers a callback when it is added to a window.
private final class ActivatingTextField: NSTextField {
    var onDidMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onDidMoveToWindow?()
        }
    }
}
