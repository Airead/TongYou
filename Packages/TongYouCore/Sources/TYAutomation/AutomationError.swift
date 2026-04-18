import Foundation

/// Errors mapped 1:1 to the JSON protocol's `error.code` strings.
/// See `script-automation-plan.md §7`.
public enum AutomationError: Error, Equatable {
    case sessionNotFound(String)
    case tabNotFound(String)
    case paneNotFound(String)
    case floatNotFound(String)
    case invalidRef(String)
    case invalidParams(String)
    case unsupportedOperation(String)
    case focusDenied(String)
    case mainThreadTimeout
    case guiNotRunning
    case `internal`(String)

    /// Stable error code used by the JSON-line protocol.
    public var code: String {
        switch self {
        case .sessionNotFound: return "SESSION_NOT_FOUND"
        case .tabNotFound: return "TAB_NOT_FOUND"
        case .paneNotFound, .floatNotFound: return "PANE_NOT_FOUND"
        case .invalidRef: return "INVALID_REF"
        case .invalidParams: return "INVALID_PARAMS"
        case .unsupportedOperation: return "UNSUPPORTED_OPERATION"
        case .focusDenied: return "FOCUS_DENIED"
        case .mainThreadTimeout: return "MAIN_THREAD_TIMEOUT"
        case .guiNotRunning: return "GUI_NOT_RUNNING"
        case .internal: return "INTERNAL_ERROR"
        }
    }

    /// Human-readable message shown to the CLI user.
    public var message: String {
        switch self {
        case .sessionNotFound(let ref): return "no session matches '\(ref)'"
        case .tabNotFound(let ref): return "no tab matches '\(ref)'"
        case .paneNotFound(let ref): return "no pane matches '\(ref)'"
        case .floatNotFound(let ref): return "no float pane matches '\(ref)'"
        case .invalidRef(let raw): return "invalid ref: '\(raw)'"
        case .invalidParams(let msg): return msg
        case .unsupportedOperation(let msg): return msg
        case .focusDenied(let msg): return msg
        case .mainThreadTimeout: return "main thread synchronization timed out"
        case .guiNotRunning: return "TongYou GUI not running"
        case .internal(let msg): return msg
        }
    }
}
