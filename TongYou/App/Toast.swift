import SwiftUI

/// A single transient toast message.
struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// Drives a short in-window notification. Callers obtain the presenter via
/// `@Environment(\.toastPresenter)` and invoke `show(_:)`; the current
/// message is rendered by `ToastOverlay` attached near the root of the
/// window view.
@MainActor
@Observable
final class ToastPresenter {

    private(set) var current: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, duration: TimeInterval = 2.0) {
        current = ToastMessage(text: text)
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

private struct ToastPresenterKey: EnvironmentKey {
    @MainActor static let defaultValue: ToastPresenter = ToastPresenter()
}

extension EnvironmentValues {
    var toastPresenter: ToastPresenter {
        get { self[ToastPresenterKey.self] }
        set { self[ToastPresenterKey.self] = newValue }
    }
}

/// Bottom-centered translucent banner that animates in and out. Stateless —
/// renders whatever `presenter.current` currently holds.
struct ToastOverlay: View {
    @Bindable var presenter: ToastPresenter

    var body: some View {
        VStack {
            Spacer()
            if let message = presenter.current {
                Text(message.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5)
                    )
                    .shadow(radius: 8, y: 2)
                    .padding(.bottom, 20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(message.id)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: presenter.current)
        .allowsHitTesting(false)
    }
}
