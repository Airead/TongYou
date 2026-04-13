import SwiftUI

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
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct TongYouCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button(CLIInstaller.isInstalled
                   ? "Uninstall Command Line Tool..."
                   : "Install Command Line Tool...") {
                installOrUninstallCLI()
            }
            .disabled(CLIInstaller.bundledCLIPath == nil)
        }
    }

    private func installOrUninstallCLI() {
        let wasInstalled = CLIInstaller.isInstalled
        do {
            if wasInstalled {
                try CLIInstaller.uninstall()
            } else {
                try CLIInstaller.install()
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
