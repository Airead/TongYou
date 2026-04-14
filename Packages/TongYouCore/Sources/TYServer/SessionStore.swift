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
        for file in files where file.hasSuffix(fileExtension) && file != orderFileName {
            guard let data = try? Data(contentsOf: fileURL(named: file)) else { continue }
            guard let session = try? decoder.decode(PersistedSession.self, from: data) else { continue }
            sessions.append(session)
        }
        return sessions
    }

    public func save(_ session: PersistedSession) {
        let fileName = "\(session.sessionInfo.id.uuid.uuidString)\(fileExtension)"
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: fileURL(named: fileName))
    }

    public func delete(sessionID: SessionID) {
        let fileName = "\(sessionID.uuid.uuidString)\(fileExtension)"
        try? FileManager.default.removeItem(at: fileURL(named: fileName))
    }

    private var orderFileName: String { "order\(fileExtension)" }

    public func saveOrder(_ order: [UUID]) {
        guard let data = try? encoder.encode(order) else { return }
        try? data.write(to: fileURL(named: orderFileName))
    }

    public func loadOrder() -> [UUID] {
        guard let data = try? Data(contentsOf: fileURL(named: orderFileName)) else { return [] }
        return (try? decoder.decode([UUID].self, from: data)) ?? []
    }

    private func fileURL(named fileName: String) -> URL {
        URL(fileURLWithPath: (directory as NSString).appendingPathComponent(fileName))
    }
}
