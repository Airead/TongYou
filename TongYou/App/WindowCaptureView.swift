import SwiftUI

/// A lightweight NSViewRepresentable that captures the hosting NSWindow
/// and writes it into the provided binding.
struct WindowCaptureView: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        CaptureView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CaptureView else { return }
        view.onWindowChanged = { [self] newWindow in
            window = newWindow
        }
    }

    private class CaptureView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}
