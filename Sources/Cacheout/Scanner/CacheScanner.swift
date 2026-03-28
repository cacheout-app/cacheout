/// # CacheScanner — Parallel Cache Category Scanner
///
/// An `actor` that scans all registered cache categories concurrently using
/// Swift's structured concurrency (`TaskGroup`). Each category is scanned in
/// its own child task for maximum parallelism.
///
/// ## Thread Safety
///
/// Uses the `actor` isolation model to ensure thread-safe access to internal state.
/// All public methods are `async` and can be called from any concurrency context.
///
/// ## Disk Size Calculation
///
/// Uses `totalFileAllocatedSize` (via `URLResourceValues`) instead of plain file size.
/// This correctly reports actual disk usage for:
/// - **Sparse files**: Docker's disk image can appear as 60GB but only use 20GB on disk.
/// - **Compressed files**: APFS-compressed files report their actual allocation.
///
/// The enumerator skips hidden files and package descendants for performance,
/// which is appropriate since cache directories rarely contain meaningful hidden files.
///
/// ## Results Ordering
///
/// Results are sorted by size descending so the largest categories appear first
/// in the UI, helping users prioritize cleanup.

import Foundation

// Using struct instead of actor to prevent serialization of parallel tasks.
// Since this component is stateless, struct allows true concurrency across threads.
struct CacheScanner {
    private let fileManager = FileManager.default

    func scanAll(_ categories: [CacheCategory]) async -> [ScanResult] {
        await withTaskGroup(of: ScanResult.self) { group in
            for category in categories {
                group.addTask { await self.scanCategory(category) }
            }
            var results: [ScanResult] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    func scanCategory(_ category: CacheCategory) async -> ScanResult {
        let resolvedPaths = category.resolvedPaths
        guard !resolvedPaths.isEmpty else {
            return ScanResult(category: category, sizeBytes: 0, itemCount: 0, exists: false)
        }

        var totalSize: Int64 = 0
        var totalItems = 0

        for url in resolvedPaths {
            let (size, count) = directorySize(at: url)
            totalSize += size
            totalItems += count
        }

        return ScanResult(
            category: category,
            sizeBytes: totalSize,
            itemCount: totalItems,
            exists: true
        )
    }

    private func directorySize(at url: URL) -> (Int64, Int) {
        var totalSize: Int64 = 0
        var itemCount = 0

        // Use allocatedSizeOfDirectory for actual disk usage (handles sparse files)
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return (0, 0)
        }

        for case let fileURL as URL in enumerator {
            do {
                let values = try fileURL.resourceValues(forKeys: [
                    .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey,
                    .isRegularFileKey
                ])
                if values.isRegularFile == true {
                    // totalFileAllocatedSize accounts for sparse files
                    let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                    totalSize += size
                    itemCount += 1
                }
            } catch {
                continue
            }
        }
        return (totalSize, itemCount)
    }
}
