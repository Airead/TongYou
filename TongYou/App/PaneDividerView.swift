import SwiftUI
import TYTerminal

/// A draggable divider between two split panes.
struct PaneDividerView: View {

    let direction: SplitDirection
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void

    @State private var isHovered = false

    /// Width/height of the interactive drag area.
    static let thickness: CGFloat = 6

    /// Width/height of the visible line.
    private static let lineThickness: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black
                .frame(
                    width: direction == .vertical ? Self.thickness : nil,
                    height: direction == .horizontal ? Self.thickness : nil
                )

            Rectangle()
                .fill(Color.white.opacity(isHovered ? 0.3 : 0.15))
                .frame(
                    width: direction == .vertical ? Self.lineThickness : nil,
                    height: direction == .horizontal ? Self.lineThickness : nil
                )
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                let cursor: NSCursor = direction == .vertical
                    ? .resizeLeftRight : .resizeUpDown
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovered {
                NSCursor.pop()
            }
        }
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

