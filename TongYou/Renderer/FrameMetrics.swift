import QuartzCore

/// Tracks per-frame rendering performance metrics.
struct FrameMetrics {
    /// Last frame total time (ms).
    private(set) var frameTimeMs: Double = 0
    /// Last frame instance buffer build time (ms).
    private(set) var instanceBuildTimeMs: Double = 0
    /// Total GPU command buffer submissions.
    private(set) var gpuSubmitCount: UInt64 = 0
    /// Total frames skipped (semaphore timeout or no drawable).
    private(set) var skippedFrameCount: UInt64 = 0

    private var frameStart: UInt64 = 0
    private var buildStart: UInt64 = 0

    /// Call at the beginning of render().
    mutating func beginFrame() {
        frameStart = mach_absolute_time()
    }

    /// Call before filling instance buffers.
    mutating func beginInstanceBuild() {
        buildStart = mach_absolute_time()
    }

    /// Call after filling instance buffers.
    mutating func endInstanceBuild() {
        instanceBuildTimeMs = elapsedMs(since: buildStart)
    }

    /// Call at the end of render() after command buffer commit.
    mutating func endFrame() {
        frameTimeMs = elapsedMs(since: frameStart)
        gpuSubmitCount += 1
    }

    /// Call when a frame is skipped (semaphore timeout, no drawable, etc.).
    mutating func recordSkip() {
        skippedFrameCount += 1
    }

    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private func elapsedMs(since start: UInt64) -> Double {
        let elapsed = mach_absolute_time() - start
        let info = Self.timebaseInfo
        return Double(elapsed) * Double(info.numer) / Double(info.denom) / 1_000_000
    }
}
