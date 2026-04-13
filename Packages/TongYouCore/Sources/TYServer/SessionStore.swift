import Foundation
import TYProtocol

/// Per-pane context saved for restoration.
struct PersistedPaneContext: Codable, Sendable {
    let cwd: String

    init(cwd: String) {
        self.cwd = cwd
    }
}

/// Persistent representation of a server session.
struct PersistedSession: Codable, Sendable {
    let sessionInfo: SessionInfo
    let paneContexts: [PaneID: PersistedPaneContext]

    init(sessionInfo: SessionInfo, paneContexts: [PaneID: PersistedPaneContext]) {
        self.sessionInfo = sessionInfo
        self.paneContexts = paneContexts
    }
}

/// Manages reading and writing session persistence files.
final class SessionStore: Sendable {
    let directory: String
    private let fileExtension = ".json"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: String) {
        self.directory = directory
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = .sortedKeys
        self.decoder = JSONDecoder()
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
    }

    func loadAll() -> [PersistedSession] {
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

    func save(_ session: PersistedSession) {
        let fileName = "\(session.sessionInfo.id.uuid.uuidString)\(fileExtension)"
        let path = (directory as NSString).appendingPathComponent(fileName)
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    func delete(sessionID: SessionID) {
        let fileName = "\(sessionID.uuid.uuidString)\(fileExtension)"
        let path = (directory as NSString).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(atPath: path)
    }
}
