import SwiftUI
import TYTerminal

/// Renders a single floating pane with a title bar (drag to move),
/// edge handles (drag to resize), and a close button.
struct FloatingPaneView: View {

    let floatingPane: FloatingPane
    let containerSize: CGSize
    let viewStore: MetalViewStore
    let focusManager: FocusManager
    let focusColor: Color
    let configLoader: ConfigLoader
    let controllerForPane: (UUID) -> (any TerminalControlling)?
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (String) -> Void
    let onFrameChanged: (UUID, CGRect) -> Void
    let onBringToFront: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onTogglePin: (UUID) -> Void
    let onUserInteraction: ((UUID) -> Void)?
    let isProcessExited: (UUID) -> Bool

    private static let titleBarHeight: CGFloat = 24
    private static let resizeHandleSize: CGFloat = 6
    private static let cornerRadius: CGFloat = 6

    /// Local frame used during drag. Nil when not dragging (uses model frame).
    @State private var liveFrame: CGRect?

    private var effectiveFrame: CGRect {
        liveFrame ?? floatingPane.frame
    }

    private var pixelFrame: CGRect {
        FloatingPane.pixelFrame(for: effectiveFrame, in: containerSize)
    }

    private var isFocused: Bool {
        focusManager.focusedPaneID == floatingPane.pane.id
    }

    var body: some View {
        let frame = pixelFrame

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                titleBar
                terminalContent
            }
            resizeHandles(frame: frame)
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .stroke(isFocused ? focusColor : Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
        .position(x: frame.midX, y: frame.midY)
        .onChange(of: floatingPane.frame) { _, _ in
            // Model caught up from server — drop local override.
            if dragStartFrame == nil {
                liveFrame = nil
            }
        }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 4) {
            Button(action: { onClose(floatingPane.pane.id) }) {
                Circle()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 10, height: 10)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(floatingPane.title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)

            Spacer()

            Button(action: { onTogglePin(floatingPane.pane.id) }) {
                Image(systemName: floatingPane.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 9))
                    .foregroundStyle(floatingPane.isPinned ? focusColor : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(floatingPane.isPinned ? "Unpin" : "Pin")
        }
        .padding(.horizontal, 8)
        .frame(height: Self.titleBarHeight)
        .background(Color.black.opacity(0.9))
        .gesture(moveGesture)
    }

    // MARK: - Terminal Content

    private var terminalContent: some View {
        TerminalPaneContainerView(
            paneID: floatingPane.pane.id,
            profileID: floatingPane.pane.profileID,
            viewStore: viewStore,
            initialWorkingDirectory: floatingPane.pane.initialWorkingDirectory,
            configLoader: configLoader,
            externalController: controllerForPane(floatingPane.pane.id),
            onTabAction: onTabAction,
            onTitleChanged: onTitleChanged,
            onFocused: { bringToFrontAndFocus() },
            onUserInteraction: { onUserInteraction?(floatingPane.pane.id) },
            isProcessExited: { isProcessExited(floatingPane.pane.id) }
        )
        .id(floatingPane.pane.id)
    }

    // MARK: - Resize Handles

    private func resizeHandles(frame: CGRect) -> some View {
        ZStack {
            edgeHandle(.trailing, size: CGSize(width: Self.resizeHandleSize, height: frame.height),
                       cursor: .resizeLeftRight, edge: .right)
            edgeHandle(.leading, size: CGSize(width: Self.resizeHandleSize, height: frame.height),
                       cursor: .resizeLeftRight, edge: .left)
            edgeHandle(.bottom, size: CGSize(width: frame.width, height: Self.resizeHandleSize),
                       cursor: .resizeUpDown, edge: .bottom)
            edgeHandle(.top, size: CGSize(width: frame.width, height: Self.resizeHandleSize),
                       cursor: .resizeUpDown, edge: .top)
        }
    }

    @State private var hoveredEdge: ResizeEdge?

    private func edgeHandle(
        _ alignment: Alignment,
        size: CGSize,
        cursor: NSCursor,
        edge: ResizeEdge
    ) -> some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .onHover { hovering in
                if hovering {
                    hoveredEdge = edge
                    cursor.push()
                } else {
                    hoveredEdge = nil
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if hoveredEdge == edge {
                    NSCursor.pop()
                }
            }
            .gesture(resizeGesture(edge: edge))
    }

    // MARK: - Gestures

    @State private var dragStartFrame: CGRect?

    private func beginDrag() -> CGRect {
        let start = dragStartFrame ?? floatingPane.frame
        if dragStartFrame == nil { dragStartFrame = floatingPane.frame }
        return start
    }

    private func normalizedDelta(_ translation: CGSize) -> (dx: CGFloat, dy: CGFloat) {
        (translation.width / containerSize.width, translation.height / containerSize.height)
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let startFrame = beginDrag()
                let (dx, dy) = normalizedDelta(value.translation)
                liveFrame = FloatingPane.clamped(CGRect(
                    x: startFrame.origin.x + dx,
                    y: startFrame.origin.y + dy,
                    width: startFrame.width,
                    height: startFrame.height
                ))
            }
            .onEnded { _ in commitDrag() }
    }

    private func resizeGesture(edge: ResizeEdge) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let startFrame = beginDrag()
                let (dx, dy) = normalizedDelta(value.translation)
                var newFrame = startFrame

                switch edge {
                case .right:
                    newFrame.size.width = max(startFrame.width + dx, FloatingPane.minSize.width)
                case .left:
                    let newWidth = max(startFrame.width - dx, FloatingPane.minSize.width)
                    newFrame.origin.x = startFrame.maxX - newWidth
                    newFrame.size.width = newWidth
                case .bottom:
                    newFrame.size.height = max(startFrame.height + dy, FloatingPane.minSize.height)
                case .top:
                    let newHeight = max(startFrame.height - dy, FloatingPane.minSize.height)
                    newFrame.origin.y = startFrame.maxY - newHeight
                    newFrame.size.height = newHeight
                }
                liveFrame = FloatingPane.clamped(newFrame)
            }
            .onEnded { _ in commitDrag() }
    }


    private func commitDrag() {
        guard let frame = liveFrame else {
            dragStartFrame = nil
            return
        }
        dragStartFrame = nil
        // Send frame before bringToFront so the server has the new position
        // before broadcasting layoutUpdate. liveFrame persists until onChange.
        onFrameChanged(floatingPane.pane.id, frame)
        bringToFrontAndFocus()
    }

    // MARK: - Helpers

    private func bringToFrontAndFocus() {
        guard !isFocused else { return }
        onBringToFront(floatingPane.pane.id)
        focusManager.focusPane(id: floatingPane.pane.id)
    }
}

private enum ResizeEdge {
    case left, right, top, bottom
}
