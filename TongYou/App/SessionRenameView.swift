import SwiftUI

/// A VS Code-style quick input overlay for renaming a session.
struct SessionRenameView: View {

    let currentName: String
    let onConfirm: (String) -> Void
    let onDismiss: () -> Void

    @State private var newName: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Enter new session name...", text: $newName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isTextFieldFocused)
                .onSubmit {
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onConfirm(trimmed)
                    }
                    onDismiss()
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 400)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .onAppear {
            newName = currentName
            isTextFieldFocused = true
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }
}
