## 2026-05-04 - Fix Actor Serialization in TaskGroup
**Learning:** When an actor creates a `TaskGroup` and its subtasks call an `isolated` method on the same actor, execution is silently serialized on the actor's executor, destroying intended parallelism. Additionally, separate `FileManager.fileExists` and `attributesOfItem` calls create redundant syscalls.
**Action:** Mark computationally intensive or state-independent methods as `nonisolated` so they run on the global concurrent pool. Use `URL.resourceValues(forKeys:)` for combined file existence and attribute checking in a single syscall.
