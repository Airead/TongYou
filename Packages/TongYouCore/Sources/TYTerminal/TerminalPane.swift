import Foundation
import TYConfig

/// The smallest terminal unit — one PTY process rendered by one MetalView.
public struct TerminalPane: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let initialWorkingDirectory: String?

    /// ID of the profile this pane was created from. Immutable for the life
    /// of the pane; Startup fields have already been snapshot-ed into
    /// `startupSnapshot`, and Live fields are resolved by profile id on
    /// demand (Phase 3+).
    public let profileID: String

    /// Startup parameters (command/args/cwd/env/close-on-exit/initial-*)
    /// resolved at pane-creation time. The PTY-launching layer reads these
    /// directly; it does not re-resolve the profile.
    public let startupSnapshot: StartupSnapshot

    /// Default profile id used when a caller does not specify one.
    public static let defaultProfileID = "default"

    /// Preferred init: fully specifies profile + snapshot.
    public init(
        profileID: String = TerminalPane.defaultProfileID,
        startupSnapshot: StartupSnapshot = StartupSnapshot(),
        initialWorkingDirectory: String? = nil
    ) {
        self.id = UUID()
        self.profileID = profileID
        self.startupSnapshot = startupSnapshot
        self.initialWorkingDirectory = initialWorkingDirectory
            ?? startupSnapshot.cwd
    }

    /// Legacy init used by call sites that don't yet know about profiles
    /// (session restoration, remote-pane reconstruction, simple tests).
    /// Synthesises an empty snapshot carrying only the cwd so PTY launch
    /// still has somewhere to start.
    public init(initialWorkingDirectory: String? = nil) {
        self.init(
            profileID: TerminalPane.defaultProfileID,
            startupSnapshot: StartupSnapshot(cwd: initialWorkingDirectory),
            initialWorkingDirectory: initialWorkingDirectory
        )
    }

    /// Create a pane with a specific ID (used to reconstruct from server state).
    public init(id: UUID, initialWorkingDirectory: String? = nil) {
        self.id = id
        self.profileID = TerminalPane.defaultProfileID
        self.startupSnapshot = StartupSnapshot(cwd: initialWorkingDirectory)
        self.initialWorkingDirectory = initialWorkingDirectory
    }

    /// Full init including an explicit id (used by the server path / restore).
    public init(
        id: UUID,
        profileID: String,
        startupSnapshot: StartupSnapshot,
        initialWorkingDirectory: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.startupSnapshot = startupSnapshot
        self.initialWorkingDirectory = initialWorkingDirectory
            ?? startupSnapshot.cwd
    }
}
