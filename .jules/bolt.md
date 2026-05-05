## 2024-05-24 - Swift Actor TaskGroup Serialization
**Learning:** In Swift Concurrency, when an actor creates a TaskGroup and its subtasks call an isolated method on the same actor, execution is serialized on the actor's executor, destroying parallelism.
**Action:** Mark computationally intensive or state-independent methods as `nonisolated` (and pass injected dependencies like `FileManager`) to ensure they run on the global concurrent pool.

## 2024-05-24 - Single Syscall File Attributes
**Learning:** Using separate `FileManager.fileExists` and `FileManager.attributesOfItem` calls is inefficient.
**Action:** Use `URL.resourceValues(forKeys:)` to perform a single optimized syscall for retrieving directory existence and modification dates simultaneously.