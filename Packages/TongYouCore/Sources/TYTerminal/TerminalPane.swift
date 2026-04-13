import Foundation

/// The smallest terminal unit — one PTY process rendered by one MetalView.
public struct TerminalPane: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let initialWorkingDirectory: String?

    public init(initialWorkingDirectory: String? = nil) {
        self.id = UUID()
        self.initialWorkingDirectory = initialWorkingDirectory
    }

    /// Create a pane with a specific ID (used to reconstruct from server state).
    public init(id: UUID, initialWorkingDirectory: String? = nil) {
        self.id = id
        self.initialWorkingDirectory = initialWorkingDirectory
    }
}
