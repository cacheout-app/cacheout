// MemorySnapshot.swift
// Lightweight memory state snapshot captured locally via vm_statistics64.

import Foundation
import Darwin

/// A point-in-time snapshot of key memory metrics, captured locally without XPC.
public struct MemorySnapshot: Codable, Sendable {
    /// Free memory in megabytes.
    public let freeMB: UInt64

    /// Inactive memory in megabytes.
    public let inactiveMB: UInt64

    /// Compressor-held memory in megabytes.
    public let compressedMB: UInt64

    /// Purgeable memory in megabytes.
    public let purgeableMB: UInt64

    public init(freeMB: UInt64, inactiveMB: UInt64, compressedMB: UInt64, purgeableMB: UInt64) {
        self.freeMB = freeMB
        self.inactiveMB = inactiveMB
        self.compressedMB = compressedMB
        self.purgeableMB = purgeableMB
    }

    /// Capture current memory state via `host_statistics64(HOST_VM_INFO64)`.
    public static func capture() throws -> MemorySnapshot {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            throw MemorySnapshotError.hostStatisticsFailed(result)
        }

        let pageSize = UInt64(vm_page_size)
        let bytesPerMB: UInt64 = 1024 * 1024

        return MemorySnapshot(
            freeMB: UInt64(info.free_count) * pageSize / bytesPerMB,
            inactiveMB: UInt64(info.inactive_count) * pageSize / bytesPerMB,
            compressedMB: UInt64(info.compressor_page_count) * pageSize / bytesPerMB,
            purgeableMB: UInt64(info.purgeable_count) * pageSize / bytesPerMB
        )
    }
}

/// Errors that can occur when capturing a memory snapshot.
public enum MemorySnapshotError: LocalizedError {
    case hostStatisticsFailed(kern_return_t)

    public var errorDescription: String? {
        switch self {
        case .hostStatisticsFailed(let code):
            return "host_statistics64 failed with kern_return_t \(code)"
        }
    }
}
