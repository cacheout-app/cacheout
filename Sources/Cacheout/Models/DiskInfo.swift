/// # DiskInfo — Disk Space Information
///
/// A lightweight value type that reads the current volume's capacity and availability
/// using `URLResourceValues`. Provides formatted strings for display and a percentage
/// for progress bars and gauges.
///
/// ## Usage
///
/// ```swift
/// if let disk = DiskInfo.current() {
///     print("\(disk.formattedFree) available of \(disk.formattedTotal)")
///     print("Used: \(Int(disk.usedPercentage * 100))%")
/// }
/// ```
///
/// ## Notes
///
/// Uses `volumeAvailableCapacityForImportantUsage` instead of `volumeAvailableCapacity`
/// for a more accurate reading that accounts for purgeable space (same value shown in
/// Finder's "Get Info" and Disk Utility).

import Foundation

struct DiskInfo {
    let totalSpace: Int64
    let freeSpace: Int64
    let usedSpace: Int64

    var usedPercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace)
    }

    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalSpace, countStyle: .file)
    }

    var formattedFree: String {
        ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)
    }

    var formattedUsed: String {
        ByteCountFormatter.string(fromByteCount: usedSpace, countStyle: .file)
    }

    static func current() -> DiskInfo? {
        let url = URL(fileURLWithPath: "/")
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            return DiskInfo(totalSpace: total, freeSpace: free, usedSpace: total - free)
        } catch {
            return nil
        }
    }
}
