import SwiftUI

/// Shared visual style for modal overlay panels (material background, border, shadow).
struct OverlayPanelStyle: ViewModifier {
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}

extension View {
    func overlayPanelStyle(cornerRadius: CGFloat = 8) -> some View {
        modifier(OverlayPanelStyle(cornerRadius: cornerRadius))
    }
}
