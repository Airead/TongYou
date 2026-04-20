import Foundation

/// Temporary debug trace hook for investigating why the dirty region
/// sometimes covers the entire viewport. Callers (typically the server)
/// may set `log` to route messages into their preferred logger.
///
/// Intentionally lightweight — avoids making `TYTerminal` depend on
/// `TYServer`'s `Log` type. Remove once the investigation is complete.
public enum DirtyTrace {
    nonisolated(unsafe) public static var log: ((String) -> Void)?

    public static func emit(_ message: @autoclosure () -> String) {
        guard let log else { return }
        log(message())
    }
}
