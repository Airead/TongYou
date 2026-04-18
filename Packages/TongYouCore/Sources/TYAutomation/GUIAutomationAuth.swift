#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import Foundation
import Security

/// Errors raised by GUI automation auth helpers.
public enum GUIAutomationAuthError: Error {
    case randomGenerationFailed(OSStatus)
    case writeFailed(path: String, underlying: Error)
}

/// Generates, persists, and removes the random token used by the GUI
/// automation server to authenticate clients.
public enum GUIAutomationAuth {
    /// Generate a 32-byte hex-encoded token and write it to `tokenPath`
    /// with 0600 permissions. Returns the token string.
    @discardableResult
    public static func generate(tokenPath: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw GUIAutomationAuthError.randomGenerationFailed(status)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            try token.write(toFile: tokenPath, atomically: true, encoding: .utf8)
        } catch {
            throw GUIAutomationAuthError.writeFailed(path: tokenPath, underlying: error)
        }
        chmod(tokenPath, 0o600)
        return token
    }

    /// Read the token from `tokenPath`, trimming whitespace. Returns nil on I/O failure.
    public static func read(tokenPath: String) -> String? {
        guard let raw = try? String(contentsOfFile: tokenPath, encoding: .utf8) else {
            return nil
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove the token file. Silently ignores missing files.
    public static func remove(tokenPath: String) {
        try? FileManager.default.removeItem(atPath: tokenPath)
    }
}
