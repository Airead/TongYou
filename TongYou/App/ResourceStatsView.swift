import SwiftUI

/// Resource usage stats window content.
struct ResourceStatsView: View {
    @State private var config: Config = .default
    private let configLoader = ConfigLoader()

    private var summary: (paneCount: Int, metalBytes: UInt64, rssBytes: UInt64, physFootprintBytes: UInt64) {
        let views = MetalViewRegistry.shared.allViews
        let paneCount = views.count
        let metalBytes = views.compactMap { $0.renderer?.currentResourceMetrics.metalAllocatedSize }.reduce(0, +)
        let rssBytes = ProcessMemoryInfo.currentRSS()
        let physFootprintBytes = ProcessMemoryInfo.currentPhysFootprint()
        return (paneCount, metalBytes, rssBytes, physFootprintBytes)
    }

    var body: some View {
        let bgColor = Color(nsColor: config.background.nsColor)
        let fgColor = Color(nsColor: config.foreground.nsColor)

        ZStack {
            bgColor
                .ignoresSafeArea()

            TimelineView(.animation(minimumInterval: 0.5, paused: false)) { _ in
                Group {
                    if summary.paneCount == 0 {
                        ContentUnavailableView("No active panes", systemImage: "rectangle.on.rectangle")
                            .foregroundStyle(fgColor)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Summary")
                                .font(.headline)
                                .foregroundStyle(fgColor)

                            VStack(alignment: .leading, spacing: 8) {
                                labelRow("Panes", "\(summary.paneCount)", fgColor: fgColor)
                                labelRow("Metal Memory", ByteFormatter.string(from: summary.metalBytes), fgColor: fgColor)
                                labelRow("Process Memory (RSS)", ByteFormatter.string(from: summary.rssBytes), fgColor: fgColor)
                                labelRow("Physical Footprint", ByteFormatter.string(from: summary.physFootprintBytes), fgColor: fgColor)
                            }
                        }
                    }
                }
                .frame(minWidth: 280, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(fgColor)
        .onAppear {
            configLoader.onConfigChanged = { newConfig in
                config = newConfig
            }
            configLoader.load()
            config = configLoader.config
        }
    }

    private func labelRow(_ title: String, _ value: String, fgColor: Color) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(fgColor.opacity(0.8))
            Spacer()
            Text(value)
                .foregroundStyle(fgColor)
                .font(.system(.body, design: .monospaced))
        }
    }
}

#Preview {
    ResourceStatsView()
}
