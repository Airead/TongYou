import Foundation
import TYProtocol

/// Manages reading and writing session persistence files.
public final class SessionStore: Sendable {
    public let directory: String
    private let fileExtension = ".json"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: String) {
        self.directory = directory
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = .sortedKeys
        self.decoder = JSONDecoder()
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
    }

    public func loadAll() -> [PersistedSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }

        var sessions: [PersistedSession] = []
        for file in files where file.hasSuffix(fileExtension) {
            let path = (directory as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            guard let session = try? decoder.decode(PersistedSession.self, from: data) else { continue }
            sessions.append(session)
        }
        return sessions
    }

    public func save(_ session: PersistedSession) {
        let fileName = "\(session.sessionInfo.id.uuid.uuidString)\(fileExtension)"
        let path = (directory as NSString).appendingPathComponent(fileName)
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    public func delete(sessionID: SessionID) {
        let fileName = "\(sessionID.uuid.uuidString)\(fileExtension)"
        let path = (directory as NSString).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(atPath: path)
    }
}
