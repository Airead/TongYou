import Foundation
import TYTerminal

// MARK: - Input snapshot (from GUI → RefStore / server)

/// Display state of a session, mirroring `SessionManager.SessionDisplayState`.
public enum AutomationSessionState: String, Codable, Sendable {
    case ready
    case detached
    case pendingAttach
}

/// Session kind, mirroring `SessionSource`.
public enum AutomationSessionType: String, Codable, Sendable {
    case local
    case remote
}

/// A point-in-time view of a session passed from the GUI to the automation
/// layer. Wraps a `TerminalSession` (immutable value type) alongside the
/// attachment state and active flag that live on `SessionManager`.
public struct SessionSnapshot: Sendable {
    public let session: TerminalSession
    public let state: AutomationSessionState
    public let isActive: Bool

    public init(session: TerminalSession, state: AutomationSessionState, isActive: Bool) {
        self.session = session
        self.state = state
        self.isActive = isActive
    }
}

// MARK: - session.list response

/// A single tab entry in the `session.list` response.
public struct TabDescriptor: Codable, Sendable, Equatable {
    public let ref: String
    public let title: String
    public let active: Bool
    public let panes: [String]
    public let floats: [String]

    public init(ref: String, title: String, active: Bool, panes: [String], floats: [String]) {
        self.ref = ref
        self.title = title
        self.active = active
        self.panes = panes
        self.floats = floats
    }
}

/// A single session entry in the `session.list` response.
public struct SessionDescriptor: Codable, Sendable, Equatable {
    public let ref: String
    public let name: String
    public let type: AutomationSessionType
    public let state: AutomationSessionState
    public let active: Bool
    public let tabs: [TabDescriptor]

    public init(
        ref: String,
        name: String,
        type: AutomationSessionType,
        state: AutomationSessionState,
        active: Bool,
        tabs: [TabDescriptor]
    ) {
        self.ref = ref
        self.name = name
        self.type = type
        self.state = state
        self.active = active
        self.tabs = tabs
    }
}

/// The full `session.list` response body (goes under `result`).
public struct SessionListResponse: Codable, Sendable, Equatable {
    public let sessions: [SessionDescriptor]

    public init(sessions: [SessionDescriptor]) {
        self.sessions = sessions
    }
}
