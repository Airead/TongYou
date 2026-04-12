import SwiftUI

/// Overlay that renders all visible floating panes sorted by z-order.
///
/// Placed in a ZStack above `PaneSplitView` in `TerminalWindowView`.
struct FloatingPaneOverlay: View {

    let floatingPanes: [FloatingPane]
    let viewStore: MetalViewStore
    let focusManager: FocusManager
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (UUID, String) -> Void
    let onFrameChanged: (UUID, CGRect) -> Void
    let onBringToFront: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onTogglePin: (UUID) -> Void

    private var visiblePanes: [FloatingPane] {
        floatingPanes
            .filter { $0.isVisible || $0.isPinned }
            .sorted { $0.zIndex < $1.zIndex }
    }

    var body: some View {
        let sorted = visiblePanes

        GeometryReader { geometry in
            ZStack {
                // Transparent hit-test passthrough so the ZStack fills the
                // container without blocking clicks to PaneSplitView beneath.
                Color.clear
                    .allowsHitTesting(false)

                ForEach(sorted) { fp in
                    FloatingPaneView(
                        floatingPane: fp,
                        containerSize: geometry.size,
                        viewStore: viewStore,
                        focusManager: focusManager,
                        onTabAction: onTabAction,
                        onTitleChanged: { title in onTitleChanged(fp.pane.id, title) },
                        onFrameChanged: onFrameChanged,
                        onBringToFront: onBringToFront,
                        onClose: onClose,
                        onTogglePin: onTogglePin
                    )
                }
            }
        }
        .allowsHitTesting(!sorted.isEmpty)
    }
}
