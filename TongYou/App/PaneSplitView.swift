import SwiftUI

/// Recursively renders a `PaneNode` tree with draggable dividers and focus highlighting.
struct PaneSplitView: View {

    let node: PaneNode
    let viewStore: MetalViewStore
    let focusManager: FocusManager
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (String) -> Void
    let onNodeChanged: (PaneNode) -> Void

    var body: some View {
        switch node {
        case .leaf(let pane):
            leafView(pane: pane)

        case .split(let direction, let ratio, let first, let second):
            SplitContainerView(
                direction: direction,
                modelRatio: ratio,
                first: first,
                second: second,
                viewStore: viewStore,
                focusManager: focusManager,
                onTabAction: onTabAction,
                onTitleChanged: onTitleChanged,
                onNodeChanged: onNodeChanged
            )
        }
    }

    @ViewBuilder
    private func leafView(pane: TerminalPane) -> some View {
        let isFocused = focusManager.focusedPaneID == pane.id
        TerminalPaneContainerView(
            paneID: pane.id,
            viewStore: viewStore,
            initialWorkingDirectory: pane.initialWorkingDirectory,
            onTabAction: onTabAction,
            onTitleChanged: onTitleChanged,
            onFocused: {
                focusManager.focusPane(id: pane.id)
            }
        )
        .id(pane.id)
        .overlay(
            Rectangle()
                .stroke(Color.accentColor, lineWidth: 1)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Split Container

/// Renders a split node with local drag state to avoid re-render jitter.
///
/// During a divider drag, only local `@State liveRatio` is updated (no model round-trip).
/// On drag end, the final ratio is committed to the model via `onNodeChanged`.
private struct SplitContainerView: View {

    let direction: SplitDirection
    let modelRatio: CGFloat
    let first: PaneNode
    let second: PaneNode
    let viewStore: MetalViewStore
    let focusManager: FocusManager
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (String) -> Void
    let onNodeChanged: (PaneNode) -> Void

    /// Local ratio used during drag. Nil when not dragging (uses modelRatio).
    @State private var liveRatio: CGFloat?
    /// The ratio at the moment the drag started.
    @State private var dragStartRatio: CGFloat?

    private var effectiveRatio: CGFloat { liveRatio ?? modelRatio }

    private var layout: AnyLayout {
        direction == .vertical
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
    }

    var body: some View {
        GeometryReader { geometry in
            let totalSize = direction == .vertical ? geometry.size.width : geometry.size.height
            let available = totalSize - PaneDividerView.thickness
            let firstSize = available * effectiveRatio

            layout {
                firstChild
                    .frame(
                        width: direction == .vertical ? firstSize : nil,
                        height: direction == .horizontal ? firstSize : nil
                    )
                PaneDividerView(direction: direction, onDrag: { delta in
                    handleDrag(delta: delta, available: available)
                }, onDragEnd: {
                    commitDrag()
                })
                secondChild
            }
        }
        .onChange(of: modelRatio) { _, _ in
            if dragStartRatio == nil {
                liveRatio = nil
            }
        }
    }

    private func handleDrag(delta: CGFloat, available: CGFloat) {
        if dragStartRatio == nil {
            dragStartRatio = modelRatio
        }
        guard available > 0, let startRatio = dragStartRatio else { return }
        let newRatio = min(max(startRatio + delta / available, 0.1), 0.9)
        liveRatio = newRatio
    }

    private func commitDrag() {
        guard let ratio = liveRatio else { return }
        dragStartRatio = nil
        liveRatio = nil
        onNodeChanged(.split(direction: direction, ratio: ratio, first: first, second: second))
    }

    // MARK: - Child Views

    private var firstChild: some View {
        PaneSplitView(
            node: first,
            viewStore: viewStore,
            focusManager: focusManager,
            onTabAction: onTabAction,
            onTitleChanged: onTitleChanged,
            onNodeChanged: { newFirst in
                onNodeChanged(.split(direction: direction, ratio: effectiveRatio, first: newFirst, second: second))
            }
        )
    }

    private var secondChild: some View {
        PaneSplitView(
            node: second,
            viewStore: viewStore,
            focusManager: focusManager,
            onTabAction: onTabAction,
            onTitleChanged: onTitleChanged,
            onNodeChanged: { newSecond in
                onNodeChanged(.split(direction: direction, ratio: effectiveRatio, first: first, second: newSecond))
            }
        )
    }
}
