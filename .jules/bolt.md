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
## 2025-10-24 - Bulk Disk I/O Parallelization and Thread Pool Starvation
**Learning:** Both `withTaskGroup` and `Task.detached` schedule their work on Swift's cooperative thread pool, which has only as many threads as the CPU has cores. Running synchronous blocking I/O (like `FileManager.removeItem`) directly inside such tasks ties up cooperative threads — when every thread is parked in a syscall there is nothing left to advance other Swift Concurrency work, which manifests as starvation and (with self-referential `await` chains) outright deadlock. `Task.detached` does not help here: "detached" means unstructured/independent, not "off the cooperative pool."
**Action:** To parallelize bulk blocking I/O, combine a sliding-window `withThrowingTaskGroup` (e.g., `maxConcurrency` of 8) with a per-item handoff to a GCD queue: wrap the blocking call in `withCheckedThrowingContinuation` and dispatch it via `DispatchQueue.global(qos: .userInitiated).async { ... continuation.resume(...) }`. The cooperative-pool task only `await`s the continuation, so it never holds a thread while the syscall runs.

## 2024-05-30 - SwiftUI ForEach and Lazy Collections
**Learning:** In SwiftUI, avoid using `.lazy.filter` directly inside a `ForEach` loop, as `ForEach` requires the data to conform to `RandomAccessCollection`, which `LazyFilterSequence` does not. Eagerly compute the filtered array before passing it to the `ForEach` view builder.
**Action:** When optimizing SwiftUI views, only apply `.lazy.filter` to properties where you immediately consume the sequence (e.g., calling `.count`, `.reduce`, or `.sorted()`). For data bound to a `ForEach` list, continue using standard eager `.filter`.
## 2024-05-30 - Short-circuiting Computed Properties in SwiftUI
**Learning:** In SwiftUI ViewModels, calculating boolean properties (like `hasSelection`) eagerly allocated intermediate arrays and evaluated entire sums just to check for emptiness (`!array.filter(...).isEmpty` or `array.reduce(...) > 0`). This causes unnecessary memory churn and O(N) CPU operations during frequent redraws.
**Action:** Replace eager array filtering and full map reductions with `.contains(where:)` to allow short-circuit evaluation. This changes the complexity from O(N) to an O(1) best-case, skipping full traversal as soon as the first match is found.
