## 2024-05-28 - Avoid actor for parallel synchronous I/O
**Learning:** Using an `actor` to manage a `withTaskGroup` where tasks invoke synchronous, blocking I/O (like `FileManager` operations) directly on the actor inadvertently serializes the tasks, preventing parallelism.
**Action:** For stateless components interacting with thread-safe dependencies (like `FileManager`), use `struct`s or `nonisolated` methods to allow tasks to execute concurrently across threads.
