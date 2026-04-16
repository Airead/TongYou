import SwiftUI
import TYServer

@main
struct TongYouApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            TerminalWindowView()
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct TongYouCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @State private var isInstalling = false
    @State private var daemonRunning = false

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Preferences...") {
                ConfigLoader.openDefaultConfigFile()
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
