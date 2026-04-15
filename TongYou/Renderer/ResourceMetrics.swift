import Foundation
import MachO

/// Resource usage metrics for a single pane.
struct ResourceMetrics {
    // Performance
    var frameTimeMs: Double = 0
    var instanceBuildTimeMs: Double = 0
    var gpuSubmitCount: UInt64 = 0
    var skippedFrameCount: UInt64 = 0
    var dedupedFrameCount: UInt64 = 0

    // Buffers (current frame state)
    var bgInstanceCapacity: Int = 0
    var bgInstanceCount: Int = 0
    var textInstanceCapacity: Int = 0
    var textInstanceCount: Int = 0
    var emojiInstanceCapacity: Int = 0
    var emojiInstanceCount: Int = 0
    var underlineInstanceCapacity: Int = 0
    var underlineInstanceCount: Int = 0

    // Atlas
    var glyphAtlasSize: UInt32 = 0
    var glyphAtlasEntries: Int = 0
    var emojiAtlasSize: UInt32 = 0
    var emojiAtlasEntries: Int = 0

    // Grid
    var gridColumns: UInt32 = 0
    var gridRows: UInt32 = 0

    // Memory
    var metalAllocatedSize: UInt64 = 0
    var estimatedBufferBytes: UInt64 = 0
    var estimatedAtlasBytes: UInt64 = 0

    // Snapshot
    var snapshotCellCopyCount: Int = 0
}

/// Snapshot of a single pane's resources.
struct PaneResourceSnapshot {
    let paneID: UUID
    let metrics: ResourceMetrics
}

/// Reads the current process memory info via Mach task_info.
enum ProcessMemoryInfo {
    /// Returns the resident set size (RSS) in bytes for the current process.
    /// Returns 0 if the query fails.
    static func currentRSS() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { ptr in
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                task_info_t(OpaquePointer(ptr)),
                &count
            )
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    /// Returns the physical footprint in bytes for the current process.
    /// This value aligns closely with Activity Monitor's "Memory" column.
    /// Returns 0 if the query fails.
    static func currentPhysFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { ptr in
            task_info(
                mach_task_self_,
                task_flavor_t(TASK_VM_INFO),
                task_info_t(OpaquePointer(ptr)),
                &count
            )
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}

/// Byte-count formatting for UI display.
enum ByteFormatter {
    /// Formats bytes into a human-readable string (e.g. "24.5 MB").
    static func string(from bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
