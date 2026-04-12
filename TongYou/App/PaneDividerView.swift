import SwiftUI

/// A draggable divider between two split panes.
struct PaneDividerView: View {

    let direction: SplitDirection
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void

    /// Width/height of the interactive drag area.
    static let thickness: CGFloat = 6

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(
                width: direction == .vertical ? Self.thickness : nil,
                height: direction == .horizontal ? Self.thickness : nil
            )
            .contentShape(Rectangle())
            .cursor(direction == .vertical ? .resizeLeftRight : .resizeUpDown)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let delta = direction == .vertical
                            ? value.translation.width
                            : value.translation.height
                        onDrag(delta)
                    }
                    .onEnded { _ in
                        onDragEnd()
                    }
            )
    }
}

// MARK: - Cursor Helper

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
