import Foundation

/// The smallest terminal unit — one PTY process rendered by one MetalView.
struct TerminalPane: Identifiable, Equatable {
    let id: UUID
    let initialWorkingDirectory: String?

    init(initialWorkingDirectory: String? = nil) {
        self.id = UUID()
        self.initialWorkingDirectory = initialWorkingDirectory
    }
}
