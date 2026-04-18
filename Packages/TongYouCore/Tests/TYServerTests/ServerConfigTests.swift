import Testing
import Foundation
@testable import TYServer

@Suite("ServerConfig Tests")
struct ServerConfigTests {

    @Test func ensureParentDirectorySetsOwnerOnlyPermissions() throws {
        let baseDir = NSTemporaryDirectory() + "tytest_config_\(UUID().uuidString)"
        let fakePath = baseDir + "/tongyou/test.sock"
        defer {
            try? FileManager.default.removeItem(atPath: baseDir)
        }

        try ServerConfig.ensureParentDirectory(for: fakePath)

        let dir = (fakePath as NSString).deletingLastPathComponent
        let attrs = try FileManager.default.attributesOfItem(atPath: dir)
        let perms = (attrs[.posixPermissions] as! NSNumber).uint16Value
        #expect(perms == 0o700, "Runtime directory should have 0700 permissions, got \(String(perms, radix: 8))")
    }

    @Test func ensureParentDirectoryEnforcesPermissionsOnExisting() throws {
        let baseDir = NSTemporaryDirectory() + "tytest_config_\(UUID().uuidString)"
        let dir = baseDir + "/tongyou"
        let fakePath = dir + "/test.sock"
        defer {
            try? FileManager.default.removeItem(atPath: baseDir)
        }

        // Create directory with loose permissions first
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        chmod(dir, 0o755)

        // ensureParentDirectory should tighten permissions
        try ServerConfig.ensureParentDirectory(for: fakePath)

        let attrs = try FileManager.default.attributesOfItem(atPath: dir)
        let perms = (attrs[.posixPermissions] as! NSNumber).uint16Value
        #expect(perms == 0o700, "Existing directory should be tightened to 0700, got \(String(perms, radix: 8))")
    }
}
