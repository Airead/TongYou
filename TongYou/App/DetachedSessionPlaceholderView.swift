import SwiftUI
import TYTerminal

/// Placeholder view shown when the active session is a detached or pending-attach remote session.
/// Displays the session name and either a hint to press Enter (detached) or a connecting indicator (pending).
struct DetachedSessionPlaceholderView: View {

    let sessionName: String
    /// True when attach has been sent but layoutUpdate hasn't arrived yet.
    let isPending: Bool
    let keybindings: [Keybinding]
    let themeForeground: RGBColor
    let themeBackground: RGBColor
    let onAttach: () -> Void
    var onTabAction: ((TabAction) -> Void)?

    var body: some View {
        let fgColor = Color(nsColor: themeForeground.nsColor)
        let bgColor = Color(nsColor: themeBackground.nsColor)

        ZStack {
            PlaceholderResponderView(
                isPending: isPending,
                keybindings: keybindings,
                onAttach: onAttach,
                onTabAction: onTabAction
            )

            VStack(spacing: 16) {
                Image(systemName: isPending ? "antenna.radiowaves.left.and.right" : "rectangle.dashed")
                    .font(.system(size: 48))
                    .foregroundStyle(fgColor.opacity(0.3))

                Text(sessionName)
                    .font(.title3)
                    .foregroundStyle(fgColor.opacity(0.6))

                if isPending {
                    Text("Connecting...")
                        .font(.system(size: 13))
                        .foregroundStyle(fgColor.opacity(0.3))
                } else {
                    Text("Press Enter to attach")
                        .font(.system(size: 13))
                        .foregroundStyle(fgColor.opacity(0.3))
                }
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bgColor)
    }
}

// MARK: - PlaceholderResponderView

/// NSView-based first responder that reliably captures keyboard input
/// when the placeholder is displayed, regardless of SwiftUI focus state.
private struct PlaceholderResponderView: NSViewRepresentable {

    let isPending: Bool
    let keybindings: [Keybinding]
    let onAttach: () -> Void
    let onTabAction: ((TabAction) -> Void)?

    func makeNSView(context: Context) -> ResponderView {
        let view = ResponderView()
        view.isPending = isPending
        view.keybindings = keybindings
        view.onAttach = onAttach
        view.onTabAction = onTabAction
        return view
    }

    func updateNSView(_ nsView: ResponderView, context: Context) {
        nsView.isPending = isPending
        nsView.keybindings = keybindings
        nsView.onAttach = onAttach
        nsView.onTabAction = onTabAction
        // Re-claim first responder whenever the view updates (e.g. session switch).
        DispatchQueue.main.async {
            if let window = nsView.window, window.firstResponder !== nsView {
                window.makeFirstResponder(nsView)
            }
        }
    }

    final class ResponderView: NSView {
        var isPending = false
        var keybindings: [Keybinding] = []
        var onAttach: () -> Void = {}
        var onTabAction: ((TabAction) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 /* Return */ {
                if !isPending {
                    onAttach()
                }
                return
            }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let deviceMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !deviceMods.intersection([.command, .control, .option]).isEmpty else {
                return false
            }

            if let action = Keybinding.match(event: event, in: keybindings),
               let tabAction = action.tabAction {
                onTabAction?(tabAction)
                return true
            }
            return false
        }
    }
}
