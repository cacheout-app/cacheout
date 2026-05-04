## 2024-05-04 - TaskGroup Serialization in Actors
**Learning:** In Swift Concurrency, when an actor creates a `TaskGroup` and its subtasks call an `isolated` method on the same actor, execution is serialized on the actor's executor, destroying parallelism.
**Action:** Mark computationally intensive or state-independent methods called from `TaskGroup` subtasks as `nonisolated` (like `NodeModulesScanner.findNodeModules`) so they run concurrently on the global pool.
