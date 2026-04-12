import SwiftUI

/// Recursively renders a `PaneNode` tree.
///
/// In phase 1, only `.leaf` is used (one pane per tab).
/// Phase 2 will add `.split` rendering with draggable dividers.
struct PaneSplitView: View {

    let node: PaneNode
    let viewStore: MetalViewStore
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (String) -> Void

    var body: some View {
        switch node {
        case .leaf(let pane):
            TerminalPaneContainerView(
                paneID: pane.id,
                viewStore: viewStore,
                initialWorkingDirectory: pane.initialWorkingDirectory,
                onTabAction: onTabAction,
                onTitleChanged: onTitleChanged
            )
            .id(pane.id)

        case .split(let direction, let ratio, let first, let second):
            GeometryReader { geometry in
                switch direction {
                case .vertical:
                    HStack(spacing: 0) {
                        childView(node: first)
                            .frame(width: geometry.size.width * ratio)
                        Divider()
                        childView(node: second)
                    }
                case .horizontal:
                    VStack(spacing: 0) {
                        childView(node: first)
                            .frame(height: geometry.size.height * ratio)
                        Divider()
                        childView(node: second)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func childView(node: PaneNode) -> some View {
        PaneSplitView(
            node: node,
            viewStore: viewStore,
            onTabAction: onTabAction,
            onTitleChanged: onTitleChanged
        )
    }
}
