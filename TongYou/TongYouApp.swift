import AppKit
import SwiftUI
import TYServer
import TYTerminal

@main
struct TongYouApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup {
            if Self.isTesting {
                Color.clear
            } else {
                TerminalWindowView()
            }
        }
        .commands {
            TongYouCommands()
        }

        Window("Resource Stats", id: "resource-stats") {
            ResourceStatsView()
        }
        .defaultPosition(.topTrailing)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Retained so the local event monitor is not released.
    private var debugMarkerMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GUIAutomationService.shared.start()
        installFocusTraceObservers()
        installDebugMarkerMonitor()
        installLocalDirtyTraceHook()
    }

    /// Route `DirtyTrace` messages through `GUILog` in local mode so
    /// `[ALT]` / `[MODE]` / `[RESIZE server]` / `[ENV]` traces show up alongside
    /// the `[RECV]` / `[DRAW]` entries we already have. In remote mode the
    /// hook is installed by `SocketServer`; in local mode there's no socket
    /// server, so without this call DirtyTrace messages are silently
    /// dropped. Temporary — remove with the cursorTrace category.
    private func installLocalDirtyTraceHook() {
        DirtyTrace.log = { msg in
            GUILog.debug(msg, category: .cursorTrace)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GUIAutomationService.shared.stop()
        if let monitor = debugMarkerMonitor {
            NSEvent.removeMonitor(monitor)
            debugMarkerMonitor = nil
        }
    }

    /// Cmd+. inserts a MARKER line into the GUI log. Used to bracket the
    /// moment the user observes a rendering glitch so the surrounding
    /// `[ATLAS]` / `[RENDER]` traces can be located.
    private func installDebugMarkerMonitor() {
        debugMarkerMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command && event.charactersIgnoringModifiers == "." {
                GUILog.debug(
                    "[MARKER] user pressed cmd+. t=\(Date().timeIntervalSince1970)",
                    category: .renderer
                )
                return nil
            }
            return event
        }
    }

    /// Phase 7 debug: log every app/window activation with a short stack.
    /// Helps find the real source when a non-whitelisted automation command
    /// appears to steal focus.
    private func installFocusTraceObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                       object: nil, queue: .main) { _ in
            GUILog.debug(
                "NSApplication.didBecomeActive fired",
                category: .session
            )
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification,
                       object: nil, queue: .main) { _ in
            GUILog.debug("NSApplication.didResignActive fired", category: .session)
        }
        // NSWindow notifications: we log an ObjectIdentifier rather than the
        // window's title to avoid crossing `note` into a MainActor context
        // (Notification is not Sendable under Swift 6 strict concurrency).
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification,
                       object: nil, queue: .main) { note in
            let windowID = (note.object as AnyObject?).map { ObjectIdentifier($0) }
            GUILog.debug(
                "NSWindow.didBecomeKey window=\(windowID.map { String(describing: $0) } ?? "<nil>")",
                category: .session
            )
        }
        nc.addObserver(forName: NSWindow.didResignKeyNotification,
                       object: nil, queue: .main) { note in
            let windowID = (note.object as AnyObject?).map { ObjectIdentifier($0) }
            GUILog.debug(
                "NSWindow.didResignKey window=\(windowID.map { String(describing: $0) } ?? "<nil>")",
                category: .session
            )
        }
    }
}

struct TongYouCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @State private var isInstalling = false
    @State private var daemonRunning = false

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Preferences...") {
                ConfigLoader.openUserConfigFile()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .appSettings) {
            Button(CLIInstaller.isInstalled
                   ? "Uninstall Command Line Tool..."
                   : "Install Command Line Tool...") {
                installOrUninstallCLI()
            }
            .disabled(CLIInstaller.bundledCLIPath == nil || isInstalling)

            Divider()

            Button {
                if DaemonLifecycle.stopRunningDaemon() {
                    daemonRunning = false
                }
            } label: {
                Text(daemonRunning ? "Stop Daemon" : "Daemon Not Running")
                    .onAppear {
                        daemonRunning = DaemonLifecycle.checkExistingProcess() != nil
                    }
            }
            .disabled(!daemonRunning)
        }

        CommandGroup(after: .windowList) {
            Button("Resource Stats") {
                openWindow(id: "resource-stats")
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }
    }

    private func installOrUninstallCLI() {
        let wasInstalled = CLIInstaller.isInstalled
        isInstalling = true
        Task {
            defer { isInstalling = false }
            do {
                if wasInstalled {
                    try await CLIInstaller.uninstall()
                } else {
                    try await CLIInstaller.install()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = wasInstalled
                    ? "Failed to Uninstall CLI"
                    : "Failed to Install CLI"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
