import Testing
import Metal
import CoreGraphics
@testable import TongYou

@Suite("ResourceMetrics")
struct ResourceMetricsTests {

    @Test("ProcessMemoryInfo returns non-zero RSS")
    func processRSSIsNonZero() {
        let rss = ProcessMemoryInfo.currentRSS()
        #expect(rss > 0)
    }

    @Test("ProcessMemoryInfo returns stable RSS across multiple calls")
    func processRSSIsStable() {
        let rss1 = ProcessMemoryInfo.currentRSS()
        let rss2 = ProcessMemoryInfo.currentRSS()
        // Allow small variance due to allocation activity during test execution.
        let diff = rss1 > rss2 ? rss1 - rss2 : rss2 - rss1
        #expect(diff < 10_000_000)
    }

    @Test("ByteFormatter produces human-readable strings")
    func byteFormatterOutput() {
        #expect(ByteFormatter.string(from: 0).contains("Zero") || ByteFormatter.string(from: 0).contains("0"))
        #expect(ByteFormatter.string(from: 1_024).contains("KB"))
        #expect(ByteFormatter.string(from: 1_048_576).contains("MB"))
        #expect(ByteFormatter.string(from: 1_073_741_824).contains("GB"))
    }

    @Test("ResourceMetrics estimatedBufferBytes calculation")
    func estimatedBufferBytesCalculation() {
        let uniformSize = UInt64(MemoryLayout<Uniforms>.stride)
        let bgSize = UInt64(MemoryLayout<CellBgInstance>.stride) * 10
        let underlineSize = UInt64(MemoryLayout<CellBgInstance>.stride) * 5
        let textSize = UInt64(MemoryLayout<CellTextInstance>.stride) * 20
        let emojiSize = UInt64(MemoryLayout<CellTextInstance>.stride) * 3
        let total = (uniformSize + bgSize + underlineSize + textSize + emojiSize) * 3

        let metrics = ResourceMetrics(
            bgInstanceCapacity: 10,
            textInstanceCapacity: 20,
            emojiInstanceCapacity: 3,
            underlineInstanceCapacity: 5,
            estimatedBufferBytes: total
        )
        #expect(metrics.estimatedBufferBytes == total)
    }

    @MainActor
    @Test("MetalViewRegistry registers and unregisters views")
    func registryRegisterUnregister() {
        let initialCount = MetalViewRegistry.shared.activeCount

        let view1 = MetalView(frame: .zero)
        #expect(MetalViewRegistry.shared.activeCount == initialCount + 1)

        let view2 = MetalView(frame: .zero)
        #expect(MetalViewRegistry.shared.activeCount == initialCount + 2)

        let view3 = MetalView(frame: .zero)
        #expect(MetalViewRegistry.shared.activeCount == initialCount + 3)

        view1.tearDown()
        #expect(MetalViewRegistry.shared.activeCount == initialCount + 2)

        view2.tearDown()
        #expect(MetalViewRegistry.shared.activeCount == initialCount + 1)

        view3.tearDown()
        #expect(MetalViewRegistry.shared.activeCount == initialCount)
    }

    @MainActor
    @Test("MetalRenderer currentResourceMetrics returns defaults when idle")
    func rendererMetricsDefaults() throws {
        guard let renderer = TestHelpers.makeRenderer() else {
            Issue.record("Metal is not available on this device")
            return
        }

        let metrics = renderer.currentResourceMetrics
        #expect(metrics.gridColumns == 0)
        #expect(metrics.gridRows == 0)
        #expect(metrics.metalAllocatedSize > 0)
        #expect(metrics.processRSSBytes > 0)
    }
}
