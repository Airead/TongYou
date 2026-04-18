import Foundation
import TYAutomation

/// App-level facade over `GUIAutomationServer`.
///
/// Owns the server instance, wires start/stop to the app lifecycle, and
/// logs failures without aborting app launch (the GUI should remain
/// usable even if the automation socket fails to bind).
@MainActor
final class GUIAutomationService {
    static let shared = GUIAutomationService()

    private var server: GUIAutomationServer?

    private init() {}

    func start() {
        guard server == nil else { return }
        let instance = GUIAutomationServer()
        do {
            try instance.start()
            server = instance
        } catch {
            NSLog("[TongYou] failed to start GUI automation server: \(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }
}
