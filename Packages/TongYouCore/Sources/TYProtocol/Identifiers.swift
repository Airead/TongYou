import Foundation

/// Type-safe session identifier.
public struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID

    public init() { self.uuid = UUID() }
    public init(_ uuid: UUID) { self.uuid = uuid }

    public var description: String { uuid.uuidString }
}

/// Type-safe tab identifier.
public struct TabID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID

    public init() { self.uuid = UUID() }
    public init(_ uuid: UUID) { self.uuid = uuid }

    public var description: String { uuid.uuidString }
}

/// Type-safe pane identifier.
public struct PaneID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID

    public init() { self.uuid = UUID() }
    public init(_ uuid: UUID) { self.uuid = uuid }

    public var description: String { uuid.uuidString }
}
