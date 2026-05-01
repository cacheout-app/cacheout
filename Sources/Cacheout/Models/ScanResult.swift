/// # ScanResult & CleanupReport — Scan and Cleanup Data Models
///
/// ## ScanResult
///
/// Represents the result of scanning a single cache category. Contains the category
/// definition, discovered size in bytes, file count, whether the path exists, and
/// the user's selection state. The `id` is shared with the category for stable identity
/// in SwiftUI lists.
///
/// Selection defaults to the category's `defaultSelected` flag, but only if the
/// category exists and has non-zero size.
///
/// ## CleanupReport
///
/// Returned by `CacheCleaner.clean()` after a cleanup operation. Contains two arrays:
/// - `cleaned`: Successfully cleaned items with bytes freed per category.
/// - `errors`: Failed items with error descriptions per category.
///
/// Provides `totalFreed` (sum of all freed bytes) and a formatted string version.

import Foundation

struct ScanResult: Identifiable {
    let id: UUID
    let category: CacheCategory
    let sizeBytes: Int64
    let itemCount: Int
    let exists: Bool
    var isSelected: Bool

    init(category: CacheCategory, sizeBytes: Int64, itemCount: Int, exists: Bool) {
        self.id = category.id
        self.category = category
        self.sizeBytes = sizeBytes
        self.itemCount = itemCount
        self.exists = exists
        self.isSelected = category.defaultSelected && exists && sizeBytes > 0
    }

    var formattedSize: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: sizeBytes)
    }

    var isEmpty: Bool { !exists || sizeBytes == 0 }
}

struct CleanupReport {
    let cleaned: [(category: String, bytesFreed: Int64)]
    let errors: [(category: String, error: String)]
    var totalFreed: Int64 { cleaned.reduce(0) { $0 + $1.bytesFreed } }
    var formattedTotal: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: totalFreed)
    }
}
