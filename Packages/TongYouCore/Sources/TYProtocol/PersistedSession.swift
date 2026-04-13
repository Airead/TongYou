import Foundation

/// Per-pane context saved for restoration.
public struct PersistedPaneContext: Codable, Sendable {
    public let cwd: String

    public init(cwd: String) {
        self.cwd = cwd
    }
}

/// Persistent representation of a server session.
public struct PersistedSession: Codable, Sendable {
    public let sessionInfo: SessionInfo
    public let paneContexts: [PaneID: PersistedPaneContext]

    public init(sessionInfo: SessionInfo, paneContexts: [PaneID: PersistedPaneContext]) {
        self.sessionInfo = sessionInfo
        self.paneContexts = paneContexts
    }
}
