import SwiftUI

/// Shared visual style for modal overlay panels (material background, border, shadow).
struct OverlayPanelStyle: ViewModifier {
    var cornerRadius: CGFloat = 8
    var background: Color? = nil

    func body(content: Content) -> some View {
        content
            .background(background ?? Color(nsColor: .init(white: 0.2, alpha: 0.95)))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}

extension View {
    func overlayPanelStyle(cornerRadius: CGFloat = 8, background: Color? = nil) -> some View {
        modifier(OverlayPanelStyle(cornerRadius: cornerRadius, background: background))
    }
}
