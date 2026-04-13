import SwiftUI

/// A full-window overlay that shows daemon connection status and blocks user interaction.
struct DaemonConnectingOverlayView: View {

    let status: SessionManager.DaemonConnectionStatus
    let onDismiss: () -> Void

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                if isFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.red)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(statusText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                if case .failed(let message) = status {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .frame(maxWidth: 300)
                }

                if isFailed {
                    Button("Close") {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360)
            .overlayPanelStyle(cornerRadius: 10)
        }
    }

    private var statusText: String {
        switch status {
        case .idle:
            return ""
        case .connecting:
            return "Connecting to daemon..."
        case .failed:
            return "Failed to connect"
        }
    }
}
