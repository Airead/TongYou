import SwiftUI
import TYTerminal

/// Resource usage stats window content.
struct ResourceStatsView: View {
    @State private var config: Config = .default
    private let configLoader = ConfigLoader()
    @State private var expandedSessionIDs: Set<String> = []
    @State private var expandedTabIDs: Set<String> = []
    @State private var expandedPaneIDs: Set<UUID> = []
    @State private var isWindowActive = true

    private final class TabGroup: Identifiable {
        let id: String
        let tabID: UUID
        let title: String
        var displayTitle: String
        var panes: [PaneResourceSnapshot]

        init(tabID: UUID, title: String, displayTitle: String, panes: [PaneResourceSnapshot]) {
            self.tabID = tabID
            self.title = title
            self.id = tabID.uuidString
            self.displayTitle = displayTitle
            self.panes = panes
        }
    }

    private final class SessionGroup: Identifiable {
        let id: String
        let name: String
        var tabs: [TabGroup]

        init(name: String, tabs: [TabGroup]) {
            self.name = name
            self.id = name
            self.tabs = tabs
        }
    }

    private var groupedSnapshots: [SessionGroup] {
        let views = MetalViewRegistry.shared.allViews
        var sessionMap: [String: SessionGroup] = [:]

        for view in views {
            guard let paneID = view.paneID,
                  let metrics = view.renderer?.currentResourceMetrics else {
                continue
            }
            let snapshot = PaneResourceSnapshot(paneID: paneID, metrics: metrics)

            let metadata = SessionManagerRegistry.shared.allManagers
                .compactMap { $0.metadata(for: paneID) }
                .first

            let sessionName = metadata?.sessionName ?? "Unknown Session"
            let tabID = metadata?.tabID ?? UUID()
            let tabTitle = metadata?.tabTitle ?? "Unknown Tab"

            if sessionMap[sessionName] != nil {
                if let tabIndex = sessionMap[sessionName]!.tabs.firstIndex(where: { $0.tabID == tabID }) {
                    sessionMap[sessionName]!.tabs[tabIndex].panes.append(snapshot)
                } else {
                    let index = sessionMap[sessionName]!.tabs.count + 1
                    sessionMap[sessionName]!.tabs.append(TabGroup(tabID: tabID, title: tabTitle, displayTitle: "\(index). \(tabTitle)", panes: [snapshot]))
                }
            } else {
                sessionMap[sessionName] = SessionGroup(
                    name: sessionName,
                    tabs: [TabGroup(tabID: tabID, title: tabTitle, displayTitle: "1. \(tabTitle)", panes: [snapshot])]
                )
            }
        }

        return sessionMap.values.sorted { $0.name < $1.name }.map { session in
            session.tabs.sort { $0.title < $1.title }
            for (index, tab) in session.tabs.enumerated() {
                tab.displayTitle = "\(index + 1). \(tab.title)"
            }
            return session
        }
    }

    private var summary: (paneCount: Int, metalBytes: UInt64, rssBytes: UInt64, physFootprintBytes: UInt64) {
        let views = MetalViewRegistry.shared.allViews
        let paneCount = views.count
        let metalBytes = views.compactMap { $0.renderer?.currentResourceMetrics.metalAllocatedSize }.reduce(0, +)
        let rssBytes = ProcessMemoryInfo.currentRSS()
        let physFootprintBytes = ProcessMemoryInfo.currentPhysFootprint()
        return (paneCount, metalBytes, rssBytes, physFootprintBytes)
    }

    private var baseFont: Font {
        Font.custom(config.fontFamily, size: CGFloat(config.fontSize))
    }

    private var smallFont: Font {
        Font.custom(config.fontFamily, size: CGFloat(config.fontSize) * 0.85)
    }

    var body: some View {
        let bgColor = Color(nsColor: config.background.nsColor)
        let fgColor = Color(nsColor: config.foreground.nsColor)

        ZStack {
            bgColor
                .ignoresSafeArea()

            TimelineView(.animation(minimumInterval: 0.5, paused: !isWindowActive)) { _ in
                List {
                    Section {
                        HStack(spacing: 12) {
                            compactMetric("Panes", "\(summary.paneCount)", fgColor)
                            compactMetric("Metal", ByteFormatter.string(from: summary.metalBytes), fgColor)
                            compactMetric("RSS", ByteFormatter.string(from: summary.rssBytes), fgColor)
                            compactMetric("Footprint", ByteFormatter.string(from: summary.physFootprintBytes), fgColor)
                            Spacer(minLength: 0)
                        }
                    } header: {
                        Text("Summary")
                            .font(baseFont)
                            .foregroundStyle(fgColor.opacity(0.7))
                            .textCase(nil)
                    }
                    .listRowBackground(bgColor)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))

                    if summary.paneCount == 0 {
                        Section {
                            HStack {
                                Spacer()
                                ContentUnavailableView("No active panes", systemImage: "rectangle.on.rectangle")
                                    .foregroundStyle(fgColor)
                                Spacer()
                            }
                        }
                        .listRowBackground(bgColor)
                    } else {
                        ForEach(groupedSnapshots) { session in
                            let sessionExpanded = expandedSessionIDs.contains(session.id)
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: {
                                        if expandedSessionIDs.contains(session.id) { return true }
                                        if session.id == groupedSnapshots.first?.id && expandedSessionIDs.isEmpty { return true }
                                        return false
                                    },
                                    set: { isExpanded in
                                        if isExpanded {
                                            expandedSessionIDs.insert(session.id)
                                        } else {
                                            expandedSessionIDs.remove(session.id)
                                        }
                                    }
                                )
                            ) {
                                ForEach(session.tabs) { tab in
                                    let tabExpanded = expandedTabIDs.contains(tab.id)
                                    DisclosureGroup(
                                        isExpanded: Binding(
                                            get: {
                                                if expandedTabIDs.contains(tab.id) { return true }
                                                if tab.id == session.tabs.first?.id && expandedTabIDs.isEmpty { return true }
                                                return false
                                            },
                                            set: { isExpanded in
                                                if isExpanded {
                                                    expandedTabIDs.insert(tab.id)
                                                } else {
                                                    expandedTabIDs.remove(tab.id)
                                                }
                                            }
                                        )
                                    ) {
                                        ForEach(tab.panes) { snapshot in
                                            let paneExpanded = expandedPaneIDs.contains(snapshot.paneID)
                                            DisclosureGroup(
                                                isExpanded: Binding(
                                                    get: {
                                                        if expandedPaneIDs.contains(snapshot.paneID) { return true }
                                                        if snapshot.paneID == tab.panes.first?.paneID && expandedPaneIDs.isEmpty { return true }
                                                        return false
                                                    },
                                                    set: { isExpanded in
                                                        if isExpanded {
                                                            expandedPaneIDs.insert(snapshot.paneID)
                                                        } else {
                                                            expandedPaneIDs.remove(snapshot.paneID)
                                                        }
                                                    }
                                                )
                                            ) {
                                                paneCompactDetail(snapshot.metrics, fgColor: fgColor)
                                                    .padding(.top, 2)
                                            } label: {
                                                Button {
                                                    withAnimation(.easeInOut(duration: 0.15)) {
                                                        if paneExpanded {
                                                            expandedPaneIDs.remove(snapshot.paneID)
                                                        } else {
                                                            expandedPaneIDs.insert(snapshot.paneID)
                                                        }
                                                    }
                                                } label: {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: paneExpanded ? "chevron.down" : "chevron.right")
                                                            .foregroundStyle(fgColor.opacity(0.7))
                                                            .font(smallFont)
                                                        Text(snapshot.paneID.uuidString.prefix(8).uppercased())
                                                            .font(baseFont)
                                                            .foregroundStyle(fgColor)
                                                        Spacer()
                                                    }
                                                    .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    } label: {
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                if tabExpanded {
                                                    expandedTabIDs.remove(tab.id)
                                                } else {
                                                    expandedTabIDs.insert(tab.id)
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: tabExpanded ? "chevron.down" : "chevron.right")
                                                    .foregroundStyle(fgColor.opacity(0.7))
                                                    .font(smallFont)
                                                Text(tab.displayTitle)
                                                    .font(baseFont)
                                                    .foregroundStyle(fgColor)
                                                Spacer()
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            } label: {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if sessionExpanded {
                                            expandedSessionIDs.remove(session.id)
                                        } else {
                                            expandedSessionIDs.insert(session.id)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: sessionExpanded ? "chevron.down" : "chevron.right")
                                            .foregroundStyle(fgColor.opacity(0.7))
                                            .font(smallFont)
                                        Text(session.name)
                                            .font(baseFont)
                                            .foregroundStyle(fgColor)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .listRowBackground(bgColor)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(fgColor)
        .onAppear {
            isWindowActive = true
            configLoader.onConfigChanged = { newConfig in
                config = newConfig
            }
            configLoader.load()
            config = configLoader.config
        }
        .onDisappear {
            isWindowActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            isWindowActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            isWindowActive = true
        }
    }

    private func paneCompactDetail(_ metrics: ResourceMetrics, fgColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                compactMetric("Frame", String(format: "%.2f ms", metrics.frameTimeMs), fgColor)
                compactMetric("Build", String(format: "%.2f ms", metrics.instanceBuildTimeMs), fgColor)
                compactMetric("GPU", "\(metrics.gpuSubmitCount)", fgColor)
                compactMetric("Skip", "\(metrics.skippedFrameCount)", fgColor)
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                compactMetric("BG", "\(metrics.bgInstanceCount)/\(metrics.bgInstanceCapacity)", fgColor)
                compactMetric("Txt", "\(metrics.textInstanceCount)/\(metrics.textInstanceCapacity)", fgColor)
                compactMetric("Emj", "\(metrics.emojiInstanceCount)/\(metrics.emojiInstanceCapacity)", fgColor)
                compactMetric("Und", "\(metrics.underlineInstanceCount)/\(metrics.underlineInstanceCapacity)", fgColor)
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                compactMetric("Glyph", "\(metrics.glyphAtlasSize)×\(metrics.glyphAtlasSize) (\(metrics.glyphAtlasEntries))", fgColor)
                compactMetric("Emoji", "\(metrics.emojiAtlasSize)×\(metrics.emojiAtlasSize) (\(metrics.emojiAtlasEntries))", fgColor)
                Spacer(minLength: 0)
            }

            compactMetric("Grid", "\(metrics.gridColumns) × \(metrics.gridRows)", fgColor)

            HStack(spacing: 12) {
                compactMetric("Metal", ByteFormatter.string(from: metrics.metalAllocatedSize), fgColor)
                compactMetric("Buf", ByteFormatter.string(from: metrics.estimatedBufferBytes), fgColor)
                compactMetric("Atlas", ByteFormatter.string(from: metrics.estimatedAtlasBytes), fgColor)
                Spacer(minLength: 0)
            }
        }
    }

    private func compactMetric(_ title: String, _ value: String, _ fgColor: Color) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(smallFont)
                .foregroundStyle(fgColor.opacity(0.6))
            Text(value)
                .font(baseFont)
                .foregroundStyle(fgColor)
        }
    }
}

extension PaneResourceSnapshot: Identifiable {
    var id: UUID { paneID }
}

#Preview {
    ResourceStatsView()
}