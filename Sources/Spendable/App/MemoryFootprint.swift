import Darwin
import Foundation

/// The process's physical memory footprint, the same number Xcode's memory gauge, `footprint(1)`
/// and the jetsam limits use. Used by the measurement scripts and the memory test.
enum MemoryFootprint {
    /// `phys_footprint` in bytes, or nil if the kernel refuses.
    static func physicalBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Megabytes with one decimal, for logs and reports.
    static func physicalMegabytesText() -> String {
        guard let bytes = physicalBytes() else { return "unavailable" }
        let tenths = (bytes * 10 + 524_288) / 1_048_576
        return "\(tenths / 10).\(tenths % 10) MB"
    }
}
