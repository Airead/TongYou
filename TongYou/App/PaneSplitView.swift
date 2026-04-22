import SwiftUI
import TYTerminal

/// Pure helper: compute per-child rects for 2D container strategies
/// (`.grid` / `.masterStack` / `.fibonacci`). Lives outside the SwiftUI view
/// so it can be unit-tested without spinning up a view hierarchy.
enum ContainerLayout {
    /// Absolute per-axis point-space floor applied during a divider drag.
    /// The pre-existing `[10%, 90%]` pair clamp is fraction-based and becomes
    /// trivially tiny in a small window (e.g. 10% of 200pt is 20pt — half a
    /// character row tall). Plan §P5 row 3 calls for a hard "拖不动" at
    /// minSize; this is the point-space equivalent when cell size isn't
    /// reachable from PaneSplitView. Roughly covers `minSize.defaultMin` at
    /// typical monospaced font metrics (~20 cols × 3 rows).
    static let minAxisPoints: CGFloat = 40
    /// Forward `container` to `LayoutDispatch` with `size` as the parent rect.
    /// Returns rects in local coordinates (origin at 0,0). `weights` overrides
    /// `container.weights` during a live divider drag.
    static func rects(
        for container: Container,
        in size: CGSize,
        weights: [CGFloat]? = nil,
        dividerSize: Int = 0
    ) -> [CGRect] {
        let w = max(0, Int(size.width.rounded()))
        let h = max(0, Int(size.height.rounded()))
        let parentRect = Rect(x: 0, y: 0, width: w, height: h)
        let result = LayoutDispatch.solve(
            kind: container.strategy,
            parentRect: parentRect,
            childCount: container.children.count,
            weights: weights ?? container.weights,
            minSize: Size(width: 1, height: 1),
            dividerSize: dividerSize
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

    /// Pure drag math for the master|stack vertical boundary in a master-stack
    /// container. Only `weights[0]` (master) changes; `weights[1...]` (stack
    /// panes) are preserved so the stack's internal heights don't shift when
    /// the user is only moving the master boundary.
    ///
    /// The master column's pixel width is
    /// `availableWidth · m / (m + stackSum)`, which is **non-linear** in `m`
    /// when `stackSum` is held constant, so we solve directly for the weight
    /// that lands the divider at the target pixel. Clamp is applied in pixel
    /// space (10–90% of `availableWidth`) for intuitive mouse tracking and to
    /// keep the `1 − r` denominator safely away from zero.
    /// `availableWidth` is `parentWidth − dividerSize`.
    static func masterStackMasterDragWeights(
        start: [CGFloat],
        delta: CGFloat,
        availableWidth: CGFloat
    ) -> [CGFloat]? {
        guard start.count >= 2, availableWidth > 0 else { return nil }
        let masterW = start[0]
        let stackSum = start[1...].reduce(0, +)
        guard stackSum > 0, masterW + stackSum > 0 else { return nil }

        let currentWidth = availableWidth * masterW / (masterW + stackSum)
        let rawTarget = currentWidth + delta
        let lower = max(0.1 * availableWidth, minAxisPoints)
        let upper = availableWidth - lower
        // Container too narrow to honor both the pct clamp and the absolute
        // floor — center the divider so neither side collapses.
        guard lower < upper else { return nil }
        let targetWidth = min(max(rawTarget, lower), upper)
        let r = targetWidth / availableWidth
        let newMasterWeight = r * stackSum / (1 - r)

        var out = start
        out[0] = newMasterWeight
        return out
    }

    /// Pure drag math for a divider between two adjacent stack panes in a
    /// master-stack container. `stackIndex` is the stack-relative index of the
    /// divider's top pane (container index `stackIndex + 1`). Pair-preserving
    /// on `weights[stackIndex+1]` + `weights[stackIndex+2]`, so `stackSum`
    /// stays constant and the master column width doesn't jump while dragging.
    /// `availableHeight = parentHeight - (stackCount - 1) * dividerSize`.
    static func masterStackStackDragWeights(
        start: [CGFloat],
        stackIndex: Int,
        delta: CGFloat,
        availableHeight: CGFloat
    ) -> [CGFloat]? {
        let ci = stackIndex + 1
        guard availableHeight > 0, ci + 1 < start.count else { return nil }
        let a = start[ci]
        let b = start[ci + 1]
        let pairSum = a + b
        guard pairSum > 0 else { return nil }
        let stackSum = start[1...].reduce(0, +)
        guard stackSum > 0 else { return nil }
        let weightPerPixel = stackSum / availableHeight
        let dw = delta * weightPerPixel
        let rawNew = a + dw
        let minWeight = minAxisPoints * weightPerPixel
        let lower = max(0.1 * pairSum, minWeight)
        let upper = pairSum - lower
        // Pair too thin to honor both the pct clamp and the absolute floor —
        // freeze the divider so the smaller neighbour doesn't crush away.
        guard lower < upper else { return nil }
        let clamped = min(max(rawNew, lower), upper)
        let actualDelta = clamped - a
        var out = start
        out[ci] = a + actualDelta
        out[ci + 1] = b - actualDelta
        return out
    }
}

/// Recursively renders a `PaneNode` tree with draggable dividers and focus highlighting.
struct PaneSplitView: View {

    let node: PaneNode
    let viewStore: MetalViewStore
    let focusManager: FocusManager
    let focusColor: Color
    let configLoader: ConfigLoader
    let toastPresenter: ToastPresenter?
    /// Returns a pre-built controller for remote panes, or nil for local panes.
    let controllerForPane: (UUID) -> (any TerminalControlling)?
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (String) -> Void
    let onNodeChanged: (PaneNode) -> Void
    let onUserInteraction: ((UUID) -> Void)?
    /// Called when a pane's terminal content updates to drive activity indicators.
    let onPaneActivity: ((UUID) -> Void)?
    /// Whether a tree pane's PTY process has exited (zombie state). Drives
    /// ESC-to-dismiss / Enter-to-rerun key handling inside the MetalView.
    let isTreePaneExited: (UUID) -> Bool
    /// Drives the broadcast-input border + Cmd+Alt+click selection toggle.
    let paneSelectionManager: PaneSelectionManager
    /// ID of the tab this tree belongs to. Used as the selection-bucket key.
    let tabID: UUID

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
                toastPresenter: toastPresenter,
                controllerForPane: controllerForPane,
                onTabAction: onTabAction,
                onTitleChanged: onTitleChanged,
                onNodeChanged: onNodeChanged,
                onUserInteraction: onUserInteraction,
                onPaneActivity: onPaneActivity,
                isTreePaneExited: isTreePaneExited,
                paneSelectionManager: paneSelectionManager,
                tabID: tabID
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
            toastPresenter: toastPresenter,
            onTabAction: onTabAction,
            onTitleChanged: onTitleChanged,
            onFocused: {
                focusManager.focusPane(id: pane.id)
            },
            onUserInteraction: {
                onUserInteraction?(pane.id)
            },
            onActivity: {
                onPaneActivity?(pane.id)
            },
            onToggleSelection: {
                paneSelectionManager.togglePane(pane.id, inTab: tabID)
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
        .modifier(PaneSelectionBorder(
            paneID: pane.id,
            tabID: tabID,
            selectionManager: paneSelectionManager
        ))
    }
}

/// Orange dashed/solid border shown on panes in the broadcast-input
/// selection. Dashed while broadcasting is off (the group is curated but
/// inactive); solid once the Cmd+Alt+I shortcut enables broadcasting.
struct PaneSelectionBorder: ViewModifier {
    let paneID: UUID
    let tabID: UUID
    let selectionManager: PaneSelectionManager

    func body(content: Content) -> some View {
        let isSelected = selectionManager.isSelected(pane: paneID, inTab: tabID)
        let isBroadcasting = selectionManager.isBroadcasting(tab: tabID)
        content.overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(
                        Color.orange,
                        style: StrokeStyle(
                            lineWidth: 2,
                            dash: isBroadcasting ? [] : [6, 4]
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
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
    let toastPresenter: ToastPresenter?
    let controllerForPane: (UUID) -> (any TerminalControlling)?
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (String) -> Void
    let onNodeChanged: (PaneNode) -> Void
    let onUserInteraction: ((UUID) -> Void)?
    let onPaneActivity: ((UUID) -> Void)?
    let isTreePaneExited: (UUID) -> Bool
    let paneSelectionManager: PaneSelectionManager
    let tabID: UUID

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

    /// Absolute-positioning path for true 2D strategies. Grid has no dividers
    /// (the solver ignores weights). Master-stack renders one master|stack
    /// vertical divider plus one horizontal divider between each adjacent
    /// stack-pane pair. Fibonacci currently falls back to grid in the solver
    /// and also gets no dividers.
    private var twoDimensionalBody: some View {
        GeometryReader { geometry in
            let thickness = PaneDividerView.thickness
            let dividerPixels = container.strategy == .masterStack
                ? Int(thickness.rounded())
                : 0
            let rects = ContainerLayout.rects(
                for: container,
                in: geometry.size,
                weights: effectiveWeights,
                dividerSize: dividerPixels
            )
            ZStack(alignment: .topLeading) {
                ForEach(Array(container.children.enumerated()), id: \.element.nodeID) { offset, child in
                    let rect = offset < rects.count ? rects[offset] : .zero
                    childView(index: offset, child: child)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                if container.strategy == .masterStack {
                    masterStackDividers(
                        rects: rects,
                        size: geometry.size,
                        thickness: thickness
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func masterStackDividers(
        rects: [CGRect],
        size: CGSize,
        thickness: CGFloat
    ) -> some View {
        if rects.count >= 2 {
            let master = rects[0]
            let availableWidth = max(0, size.width - thickness)
            PaneDividerView(
                direction: .vertical,
                onDrag: { delta in
                    handleMasterStackMasterDrag(delta: delta, availableWidth: availableWidth)
                },
                onDragEnd: { commitDrag() }
            )
            .frame(width: thickness, height: size.height)
            .offset(x: master.maxX, y: 0)

            let stackCount = rects.count - 1
            if stackCount >= 2 {
                let stackAvailable = max(0, size.height - CGFloat(stackCount - 1) * thickness)
                let column = rects[1]
                ForEach(0..<(stackCount - 1), id: \.self) { i in
                    let upper = rects[i + 1]
                    PaneDividerView(
                        direction: .horizontal,
                        onDrag: { delta in
                            handleMasterStackStackDrag(
                                stackIndex: i,
                                delta: delta,
                                availableHeight: stackAvailable
                            )
                        },
                        onDragEnd: { commitDrag() }
                    )
                    .frame(width: column.width, height: thickness)
                    .offset(x: column.minX, y: upper.maxY)
                }
            }
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
            toastPresenter: toastPresenter,
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
            onPaneActivity: onPaneActivity,
            isTreePaneExited: isTreePaneExited,
            paneSelectionManager: paneSelectionManager,
            tabID: tabID
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
        // Clamp to [10%, 90%] of the pair, and to a per-side absolute
        // point-space floor so "拖不动" kicks in before a neighbour collapses
        // below minSize (plan §P5 row 3).
        let pairSum = start[i] + start[i + 1]
        guard pairSum > 0 else { return }
        let totalSum = start.reduce(0, +)
        guard totalSum > 0 else { return }
        let weightPerPixel = totalSum / available
        let dw = delta * weightPerPixel
        let rawNew = start[i] + dw
        let minWeight = ContainerLayout.minAxisPoints * weightPerPixel
        let lower = max(0.1 * pairSum, minWeight)
        let upper = pairSum - lower
        // Pair total is so small that the absolute floor can't be honored on
        // both sides — stop moving the divider so neither neighbour crushes.
        guard lower < upper else { return }
        let clampedI = min(max(rawNew, lower), upper)
        let actualDelta = clampedI - start[i]

        var newWeights = start
        newWeights[i] = start[i] + actualDelta
        newWeights[i + 1] = start[i + 1] - actualDelta
        liveWeights = newWeights
    }

    private func handleMasterStackMasterDrag(delta: CGFloat, availableWidth: CGFloat) {
        if dragStartWeights == nil {
            dragStartWeights = container.weights
        }
        guard let start = dragStartWeights,
              let next = ContainerLayout.masterStackMasterDragWeights(
                  start: start,
                  delta: delta,
                  availableWidth: availableWidth
              )
        else { return }
        liveWeights = next
    }

    private func handleMasterStackStackDrag(
        stackIndex: Int,
        delta: CGFloat,
        availableHeight: CGFloat
    ) {
        if dragStartWeights == nil {
            dragStartWeights = container.weights
        }
        guard let start = dragStartWeights,
              let next = ContainerLayout.masterStackStackDragWeights(
                  start: start,
                  stackIndex: stackIndex,
                  delta: delta,
                  availableHeight: availableHeight
              )
        else { return }
        liveWeights = next
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
