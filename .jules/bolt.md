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

## 2024-05-25 - Efficient Dictionary Initialization
**Learning:** Building a dictionary via a standard `for` loop by inserting elements one by one can cause unnecessary overhead due to repeated mutations. `reduce(into: [:])` is highly optimized in Swift to build collections without creating intermediate copies.
**Action:** Use `reduce(into: [:])` when constructing a dictionary from an array, particularly when uniqueness checks or transformations are required.
## 2024-05-20 - Parallelizing bulk I/O operations with TaskGroup
**Learning:** To optimize bulk I/O operations (e.g., FileManager.removeItem loops) in Swift, parallelizing them using Task.detached is not enough as it does NOT escape the cooperative thread pool.
**Action:** Use withThrowingTaskGroup combined with a sliding window iterator and to prevent thread pool exhaustion/deadlock, wrap synchronous blocking calls in withCheckedThrowingContinuation and explicitly dispatch them to a background GCD queue (e.g., DispatchQueue.global(qos: .userInitiated).async).
