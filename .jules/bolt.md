## 2024-05-05 - TaskGroup parallelism and URL.resourceValues
**Learning:** In Swift Concurrency, when an actor creates a `TaskGroup` and its subtasks call an `isolated` method on the same actor, execution is serialized on the actor's executor, destroying parallelism. Also, `URL.resourceValues(forKeys:)` can perform a single optimized syscall instead of separate `FileManager.fileExists` and `FileManager.attributesOfItem` calls.
**Action:** Mark computationally intensive or state-independent methods as `static` or `nonisolated` so they run on the global concurrent pool, and pass dependencies (like `FileManager` and `skipDirs`) as arguments. Use `URL.resourceValues(forKeys:)` for checking directory existence and attributes simultaneously.

## 2025-04-12 - TaskGroup Sliding Window Concurrency Optimization
**Learning:** When using Swift's `withTaskGroup` for high-volume concurrent processing (e.g., scanning hundreds of PIDs), grouping tasks into static chunks and waiting for the chunk to finish causes tail latency. The entire chunk waits for the slowest task to complete, temporarily dropping concurrency to 1.
**Action:** Always use a sliding window approach with an iterator (e.g., `makeIterator()`). Seed the group up to the `maxConcurrency` limit, and within the `for await result in group` loop, immediately add a new task using `iterator.next()`. This ensures the worker pool stays consistently saturated at max concurrency.

## 2024-05-02 - Batched Updates to @Published Arrays
**Learning:** In SwiftUI `ObservableObject` view models, mutating individual elements of a `@Published` array property inside a loop triggers a UI update notification (`objectWillChange.send()`) for every change.
**Action:** Batch updates by modifying a local copy of the array and reassigning it to the `@Published` property (e.g., `var copy = items; for i in copy.indices { ... }; items = copy`), producing only a single update.

## 2025-05-01 - Shared Formatters
**Learning:** `ByteCountFormatter` and `ISO8601DateFormatter` allocation inside computed properties and loops creates unnecessary overhead — `ByteCountFormatter.string(fromByteCount:countStyle:)` (class method) also allocates a new instance per call. The `.filter { ... }.reduce(0) { ... }` pattern creates an intermediate array.
**Action:** Use shared cached formatter instances (`ByteCountFormatter.sharedFile.string(fromByteCount:)`, `ISO8601DateFormatter.shared.string(from:)`). Use `.lazy.filter` to avoid intermediate arrays before `.reduce`.

## 2024-05-28 - Main Thread Blocking in async @MainActor methods
**Learning:** `async` methods on a `@MainActor` class execute on the main thread. Synchronous blocking operations inside them (`DiskInfo.current()`'s `URLResourceValues` I/O, `Foundation.Process.waitUntilExit()`, `readDataToEndOfFile()`) block the UI even though the function is `async`.
**Action:** Wrap blocking calls in `await Task.detached { ... }.value` to offload the work to a background executor while keeping the main-actor-isolated assignment.

## 2026-03-19 - FileManager Enumerator Pre-fetching
**Learning:** Any property requested via `resourceValues(forKeys:)` inside a `FileManager.enumerator` loop must also be in `includingPropertiesForKeys` — otherwise `URL.resourceValues` falls back to a synchronous `stat()` per file, turning bulk reads into O(N) disk I/O.
**Action:** Keep the keys array passed to `resourceValues(forKeys:)` a subset of the prefetch list passed to `FileManager.enumerator(at:includingPropertiesForKeys:)`.

## 2024-06-25 - O(1) Index Maps for @Published Array Toggles
**Learning:** When toggling the selection state of an item within a massive `@Published` array (like `nodeModulesItems`), sequentially searching for the element's index via `firstIndex(where:)` causes O(n) CPU latency on every user click.
**Action:** Replace `firstIndex(where:)` with an O(1) dictionary-based index map (`[UUID: Int]`). Rebuild the dictionary via `enumerated().reduce(into: [:])` immediately after the main array is fully populated (e.g., after a scan operation completes), and include a defensive boundary and ID check fallback for robustness.
