import SwiftUI

/// Placeholder view shown when the active session is a detached or pending-attach remote session.
/// Displays the session name and either a hint to press Enter (detached) or a connecting indicator (pending).
struct DetachedSessionPlaceholderView: View {

    let sessionName: String
    /// True when attach has been sent but layoutUpdate hasn't arrived yet.
    let isPending: Bool
    let onAttach: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isPending ? "antenna.radiowaves.left.and.right" : "rectangle.dashed")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text(sessionName)
                .font(.title3)
                .foregroundStyle(.secondary)

            if isPending {
                Text("Connecting...")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Press Enter to attach")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onKeyPress(.return) {
            if !isPending {
                onAttach()
            }
            return .handled
        }
        .focusable()
    }
}
