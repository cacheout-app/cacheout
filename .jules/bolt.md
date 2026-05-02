## 2024-05-05 - TaskGroup parallelism and URL.resourceValues
**Learning:** In Swift Concurrency, when an actor creates a `TaskGroup` and its subtasks call an `isolated` method on the same actor, execution is serialized on the actor's executor, destroying parallelism. Also, `URL.resourceValues(forKeys:)` can perform a single optimized syscall instead of separate `FileManager.fileExists` and `FileManager.attributesOfItem` calls.
**Action:** Mark computationally intensive or state-independent methods as `static` or `nonisolated` so they run on the global concurrent pool, and pass dependencies (like `FileManager` and `skipDirs`) as arguments. Use `URL.resourceValues(forKeys:)` for checking directory existence and attributes simultaneously.

## 2025-04-12 - TaskGroup Sliding Window Concurrency Optimization
**Learning:** When using Swift's `withTaskGroup` for high-volume concurrent processing (e.g., scanning hundreds of PIDs), grouping tasks into static chunks and waiting for the chunk to finish causes tail latency. The entire chunk waits for the slowest task to complete, temporarily dropping concurrency to 1.
**Action:** Always use a sliding window approach with an iterator (e.g., `makeIterator()`). Seed the group up to the `maxConcurrency` limit, and within the `for await result in group` loop, immediately add a new task using `iterator.next()`. This ensures the worker pool stays consistently saturated at max concurrency.

## 2024-05-02 - Batched Updates to @Published Arrays
**Learning:** In SwiftUI `ObservableObject` view models, mutating individual elements of a `@Published` array property inside a loop triggers a UI update notification (`objectWillChange.send()`) for every change.
**Action:** Batch updates by modifying a local copy of the array and reassigning it to the `@Published` property (e.g., `var copy = items; for i in copy.indices { ... }; items = copy`), producing only a single update.
