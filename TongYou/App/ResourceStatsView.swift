import SwiftUI

/// Resource usage stats window content.
struct ResourceStatsView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: false)) { _ in
            VStack {
                Text("Active panes: \(MetalViewRegistry.shared.activeCount)")
                    .font(.title2)
                    .padding()
            }
            .frame(minWidth: 240, minHeight: 120)
        }
    }
}

#Preview {
    ResourceStatsView()
}
