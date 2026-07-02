# ⚡ Bolt — performance learning log

Read `.jules/README.md` first. Then re-read the **FIXED SITES** and
**ANTI-PATTERNS** sections below before considering any PR. Performance is
the highest-noise category here — over 40 Bolt PRs have been closed as
duplicates or as not-recommended in the last 60 days.

## ✅ FIXED SITES — do not re-propose

| File | What was done | By |
|---|---|---|
| `Sources/Cacheout/Cleaner/CacheCleaner.swift` `removeContents(of:)` | Parallelized via sliding-window `withThrowingTaskGroup` (max 8) + GCD handoff to avoid cooperative-pool starvation | #275 |
| `Sources/Cacheout/Cleaner/CacheCleaner.swift` `permanentDeleteNodeModules` | Same parallel pattern as above | #282 |
| `Sources/Cacheout/Views/MenuBarView.swift` `statPill` Categories count | `.lazy.filter { !$0.isEmpty }.count` | #393 |
| `Sources/Cacheout/Views/MenuBarView.swift` `topCategories` | `.lazy.filter.sorted.prefix(5)` chain | #393 |
| `Sources/Cacheout/Views/CleanConfirmation.swift` selected count | `nodeModulesItems.lazy.filter(\.isSelected).count` | #393 |
| `Sources/Cacheout/ViewModels/CacheoutViewModel.swift` `selectedSize` | `scanResults.lazy.filter(\.isSelected).reduce` | #404 |
| `Sources/Cacheout/ViewModels/CacheoutViewModel.swift` `hasSelection` | `contains(where: \.isSelected)` on both arrays — short-circuits | #404 |
| `Sources/Cacheout/Memory/RecommendationEngine.swift` Rosetta/agent loops | `for proc in arr where condition` instead of `arr.filter { … }.forEach` | #407 |

**Before opening any Bolt PR**, grep the candidate file:

```sh
# Already lazy?
grep -n "\.lazy\." <candidate-file>
# Already for-where?
grep -nE "for .+ where " <candidate-file>
# Already contains(where:)?
grep -n "contains(where:" <candidate-file>
```

If your candidate site already uses any of these, the issue is fixed.

## 🚫 ANTI-PATTERNS — these PRs will be rejected

1. **Replacing `firstIndex(where:)` with a dictionary index map on a
   `@Published` array.** This was tried in #229 and closed by the
   maintainer because:
   - `scanResults` and `nodeModulesItems` are validated small (typically
     10–30 items).
   - The map has to be rebuilt on every scan, which itself is O(n).
   - User-triggered toggles are infrequent compared to scans.
   - The original O(n) `firstIndex` is faster in practice for these
     workloads.
   Do not re-propose this for the same `@Published` arrays. See the 2024-05-18
   learning below.

2. **Adding `.lazy` before `.sorted()`.** `.sorted()` materializes to an
   array regardless — putting `.lazy` in front saves nothing. Only chain
   `.lazy` ahead of operations that genuinely consume it (`.count`,
   `.reduce`, `.first`, `.contains`, `.prefix` of a lazy sequence).

3. **`.lazy.filter` inside a SwiftUI `ForEach`.** `ForEach` requires
   `RandomAccessCollection`; a lazy filter doesn't satisfy that. See the
   2024-05-30 learning below.

4. **`Task.detached` to "escape" the cooperative pool for blocking I/O.**
   Detached tasks still run on the cooperative pool. The correct pattern
   is `withCheckedThrowingContinuation` + `DispatchQueue.global(...).async`.
   See the 2025-10-24 learning below.

5. **Any PR whose body lacks an array-size estimate or measurement.**
   Performance PRs without "this array is ~N items in practice; this fix
   saves X allocations per Y" are speculative. Speculative perf PRs that
   add complexity get rejected.

6. **Generic "Optimize SwiftUI computed properties" titles with no
   measurement.** Title must name the specific property and what the win
   is (e.g., "Optimize hasSelection to short-circuit instead of summing").

## Quality requirements for performance PRs

- Title format: `⚡ Bolt: <specific-symbol> <verb> <what-improves> in <File.swift>`
- Body must include: the specific property/function, an estimate of the
  array size in practice (e.g., "typical run: ~20 items, worst case ~200"),
  and the qualitative benefit (avoid allocation, short-circuit, etc.).
  If you can't justify the change at the typical size, don't open the PR.
- Match existing idioms (e.g., keypath `\.isSelected` over closure
  `{ $0.isSelected }` in this codebase).
- Always update this file with an entry under `## Learning log`.

---

## Learning log

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

## 2024-05-18 - Dictionary overhead vs O(n) array lookups (NEGATIVE result)
**Learning:** Replacing O(n) `firstIndex(where:)` searches with O(1) dictionary-based index maps for SwiftUI `@Published` arrays is a NET LOSS when the collection is small (~10–30 items), the interaction is infrequent (user-driven toggles), or the map requires frequent reconstruction (e.g., on every scan). The O(n) map construction overhead (allocating memory and hashing every UUID) outweighs the lookup benefits.
**Action:** Do not propose this optimization for `scanResults` or `nodeModulesItems` in `CacheoutViewModel`. Use index maps only for large (>1000 items), long-lived datasets with extremely frequent, hot-path lookups.

## 2025-04-13 - Loop Filtering and Intermediate Allocations
**Learning:** In Swift, using `.filter` before a `for` loop eagerly allocates a new intermediate array, causing unnecessary memory churn and processing overhead, especially during frequent operations like system monitoring.
**Action:** Use `for ... where` clauses instead of eagerly filtering the collection prior to the loop (e.g., `for item in array where condition { ... }`). This prevents the allocation of intermediate arrays and improves efficiency.

## 2025-05-15 - Array Materialization via sorted() on Lazy Sequences
**Learning:** `LazyFilterSequence` does not have a custom `sorted()` implementation. Calling `sorted()` on a `LazyFilterSequence` relies on the default `Sequence` extension, which completely consumes the sequence and materializes it into an array immediately. While chaining `.lazy.filter` before `.sorted()` avoids allocating a separate intermediate array just for the filtered results, `sorted()` itself forces array materialization regardless. Adding `.lazy` specifically *just* before `.sorted()` creates confusion because it suggests the sort operation itself is lazy (which is impossible, sorting requires the whole collection). The codebase considers `.lazy.filter.sorted` an anti-pattern.
**Action:** Do not propose adding `.lazy` before `.sorted()`. Ensure `.lazy` is only proposed when preceding operations that natively support lazy consumption like `.reduce`, `.count`, `.first`, `.contains`, or lazy `prefix`.
## 2025-05-16 - Refactoring Filter Methods for Iteration Optimization
**Learning:** Functions that encapsulate `.filter` logic and return a filtered array force intermediate array allocation when called within a loop, especially for potentially large datasets like process lists (~400-600 items). The `for ... where` idiom cannot be applied when the condition logic is hidden inside a method that returns the already filtered array.
**Action:** When a method exists purely to filter an array for subsequent iteration, refactor the method into a `static func` (or regular function) that returns a `Bool` evaluating a single element. This allows the caller to use an efficient `for element in collection where isCondition(element)` pattern, avoiding intermediate memory allocations.
