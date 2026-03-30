## 2024-03-30 - Replace actors with structs for parallel TaskGroups
**Learning:** In Swift structured concurrency, using an `actor` to manage a `withTaskGroup` where tasks invoke synchronous, blocking I/O (like `FileManager` operations) directly on the actor inadvertently serializes the tasks, preventing parallelism.
**Action:** For stateless components interacting with thread-safe dependencies (like `FileManager`), use `struct`s or `nonisolated` methods to allow tasks in a `TaskGroup` to execute concurrently across threads.
