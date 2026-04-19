import SwiftUI
import TYTerminal

/// Pure helper: compute per-child rects for 2D container strategies
/// (`.grid` / `.masterStack` / `.fibonacci`). Lives outside the SwiftUI view
/// so it can be unit-tested without spinning up a view hierarchy.
enum ContainerLayout {
    /// Forward `container` to `LayoutDispatch` with `size` as the parent rect.
    /// Returns rects in local coordinates (origin at 0,0).
    static func rects(for container: Container, in size: CGSize) -> [CGRect] {
        let w = max(0, Int(size.width.rounded()))
        let h = max(0, Int(size.height.rounded()))
        let parentRect = Rect(x: 0, y: 0, width: w, height: h)
        let result = LayoutDispatch.solve(
            kind: container.strategy,
            parentRect: parentRect,
            childCount: container.children.count,
            weights: container.weights,
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        return result.rects.map {
            CGRect(
                x: CGFloat($0.x),
                y: CGFloat($0.y),
                width: CGFloat($0.width),
                height: CGFloat($0.height)
            )
        }
    }
}

/// Recursively renders a `PaneNode` tree with draggable dividers and focus highlighting.
struct PaneSplitView: View {

    let node: PaneNode
    let viewStore: MetalViewStore
    let focusManager: FocusManager
    let focusColor: Color
    let configLoader: ConfigLoader
    /// Returns a pre-built controller for remote panes, or nil for local panes.
    let controllerForPane: (UUID) -> (any TerminalControlling)?
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (String) -> Void
    let onNodeChanged: (PaneNode) -> Void
    let onUserInteraction: ((UUID) -> Void)?
    /// Whether a tree pane's PTY process has exited (zombie state). Drives
    /// ESC-to-dismiss / Enter-to-rerun key handling inside the MetalView.
    let isTreePaneExited: (UUID) -> Bool

    var body: some View {
        switch node {
        case .leaf(let pane):
            leafView(pane: pane)

        case .container(let container):
            ContainerView(
                container: container,
                viewStore: viewStore,
                focusManager: focusManager,
                focusColor: focusColor,
                configLoader: configLoader,
                controllerForPane: controllerForPane,
                onTabAction: onTabAction,
                onTitleChanged: onTitleChanged,
                onNodeChanged: onNodeChanged,
                onUserInteraction: onUserInteraction,
                isTreePaneExited: isTreePaneExited
            )
        }
    }

    @ViewBuilder
    private func leafView(pane: TerminalPane) -> some View {
        let isFocused = focusManager.focusedPaneID == pane.id
        TerminalPaneContainerView(
            paneID: pane.id,
            profileID: pane.profileID,
            viewStore: viewStore,
            initialWorkingDirectory: pane.initialWorkingDirectory,
            configLoader: configLoader,
            externalController: controllerForPane(pane.id),
            onTabAction: onTabAction,
            onTitleChanged: onTitleChanged,
            onFocused: {
                focusManager.focusPane(id: pane.id)
            },
            onUserInteraction: {
                onUserInteraction?(pane.id)
            },
            isProcessExited: { isTreePaneExited(pane.id) }
        )
        .id(pane.id)
        .overlay(
            Rectangle()
                .stroke(focusColor, lineWidth: 1)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Container View

/// Renders a `Container` node with N children separated by draggable dividers.
///
/// During a divider drag, only local `@State liveWeights` is updated (no model
/// round-trip). On drag end, the new weights are committed via `onNodeChanged`.
///
/// Dragging a divider between children `i` and `i+1` preserves
/// `weights[i] + weights[i+1]` and redistributes pixel delta proportionally so
/// neighboring dividers don't move. Weights are clamped to the
/// `[10%, 90%]` share of that pair (BSP-compatible behavior).
private struct ContainerView: View {

    let container: Container
    let viewStore: MetalViewStore
    let focusManager: FocusManager
    let focusColor: Color
    let configLoader: ConfigLoader
    let controllerForPane: (UUID) -> (any TerminalControlling)?
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (String) -> Void
    let onNodeChanged: (PaneNode) -> Void
    let onUserInteraction: ((UUID) -> Void)?
    let isTreePaneExited: (UUID) -> Bool

    /// Local weights used during a divider drag. Nil when not dragging.
    @State private var liveWeights: [CGFloat]?
    /// Snapshot of weights at drag start — anchors the delta computation.
    @State private var dragStartWeights: [CGFloat]?

    private var effectiveWeights: [CGFloat] { liveWeights ?? container.weights }

    /// Whether this container splits along the horizontal (x) axis.
    /// `.vertical` strategy stacks children left/right; `.horizontal` stacks
    /// top/bottom. `.grid` / `.masterStack` / `.fibonacci` are true 2D and
    /// take the absolute-positioning path below instead.
    private var isHorizontalAxis: Bool {
        container.strategy == .vertical
    }

    /// Strategies that cannot be expressed as a single HStack/VStack and must
    /// be rendered via absolute positioning using solver-computed rects.
    private var is2DStrategy: Bool {
        switch container.strategy {
        case .horizontal, .vertical: return false
        case .grid, .masterStack, .fibonacci: return true
        }
    }

    private var layout: AnyLayout {
        isHorizontalAxis
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
    }

    /// Divider visual orientation. The divider sits between two adjacent
    /// children whose axis is `container.strategy`. `PaneDividerView`
    /// interprets `.vertical` as a vertical line (for left/right splits) and
    /// `.horizontal` as a horizontal line (for top/bottom splits).
    private var dividerOrientation: SplitDirection {
        isHorizontalAxis ? .vertical : .horizontal
    }

    var body: some View {
        Group {
            if is2DStrategy {
                twoDimensionalBody
            } else {
                oneDimensionalBody
            }
        }
        .onChange(of: container.weights) { _, _ in
            if dragStartWeights == nil {
                liveWeights = nil
            }
        }
    }

    private var oneDimensionalBody: some View {
        GeometryReader { geometry in
            let axisSize = isHorizontalAxis ? geometry.size.width : geometry.size.height
            let dividerCount = max(0, container.children.count - 1)
            let available = max(0, axisSize - CGFloat(dividerCount) * PaneDividerView.thickness)
            let sizes = computeSizes(available: available)

            layout {
                ForEach(Array(container.children.enumerated()), id: \.element.nodeID) { offset, child in
                    childView(index: offset, child: child)
                        .frame(
                            width: isHorizontalAxis && offset < container.children.count - 1 ? sizes[offset] : nil,
                            height: !isHorizontalAxis && offset < container.children.count - 1 ? sizes[offset] : nil
                        )
                    if offset < container.children.count - 1 {
                        PaneDividerView(
                            direction: dividerOrientation,
                            onDrag: { delta in
                                handleDrag(dividerIndex: offset, delta: delta, available: available)
                            },
                            onDragEnd: {
                                commitDrag()
                            }
                        )
                    }
                }
            }
        }
    }

    /// Absolute-positioning path for true 2D strategies. Dividers are omitted
    /// for now — grid ignores weights entirely, and master-stack divider
    /// dragging will land in a follow-up.
    private var twoDimensionalBody: some View {
        GeometryReader { geometry in
            let rects = ContainerLayout.rects(for: container, in: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(Array(container.children.enumerated()), id: \.element.nodeID) { offset, child in
                    let rect = offset < rects.count ? rects[offset] : .zero
                    childView(index: offset, child: child)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    // MARK: - Child View

    private func childView(index: Int, child: PaneNode) -> some View {
        PaneSplitView(
            node: child,
            viewStore: viewStore,
            focusManager: focusManager,
            focusColor: focusColor,
            configLoader: configLoader,
            controllerForPane: controllerForPane,
            onTabAction: onTabAction,
            onTitleChanged: onTitleChanged,
            onNodeChanged: { newChild in
                var newChildren = container.children
                newChildren[index] = newChild
                onNodeChanged(.container(Container(
                    id: container.id,
                    strategy: container.strategy,
                    children: newChildren,
                    weights: effectiveWeights
                )))
            },
            onUserInteraction: onUserInteraction,
            isTreePaneExited: isTreePaneExited
        )
    }

    // MARK: - Size Computation

    private func computeSizes(available: CGFloat) -> [CGFloat] {
        let n = container.children.count
        guard n > 0 else { return [] }
        let axisLength = Int(available.rounded())
        let parentRect = Rect(
            x: 0,
            y: 0,
            width: isHorizontalAxis ? axisLength : 1,
            height: !isHorizontalAxis ? axisLength : 1
        )
        let result = LayoutDispatch.solve(
            kind: container.strategy,
            parentRect: parentRect,
            childCount: n,
            weights: effectiveWeights,
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        return result.rects.map { CGFloat(isHorizontalAxis ? $0.width : $0.height) }
    }

    // MARK: - Drag Handling

    private func handleDrag(dividerIndex i: Int, delta: CGFloat, available: CGFloat) {
        if dragStartWeights == nil {
            dragStartWeights = container.weights
        }
        guard available > 0, let start = dragStartWeights, i + 1 < start.count else { return }

        // Preserve `weights[i] + weights[i+1]`, remap pixel delta to the full
        // container's weight budget (a pane's share is `weight_i / sum(all)`,
        // so one pixel corresponds to `sum(all) / available` weight units —
        // not the pair sum, which under-counts when there are 3+ children).
        // Clamp to [10%, 90%] of the pair's own share.
        let pairSum = start[i] + start[i + 1]
        guard pairSum > 0 else { return }
        let totalSum = start.reduce(0, +)
        guard totalSum > 0 else { return }
        let weightPerPixel = totalSum / available
        let dw = delta * weightPerPixel
        let rawNew = start[i] + dw
        let clampedI = min(max(rawNew, 0.1 * pairSum), 0.9 * pairSum)
        let actualDelta = clampedI - start[i]

        var newWeights = start
        newWeights[i] = start[i] + actualDelta
        newWeights[i + 1] = start[i + 1] - actualDelta
        liveWeights = newWeights
    }

    private func commitDrag() {
        guard let weights = liveWeights else { return }
        dragStartWeights = nil
        liveWeights = nil
        onNodeChanged(.container(Container(
            id: container.id,
            strategy: container.strategy,
            children: container.children,
            weights: weights
        )))
    }
}
