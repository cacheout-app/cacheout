## 2024-05-18 - Fix actor serialization to enable true parallel scanning
**Learning:** In Swift structured concurrency, using an `actor` to manage a `withTaskGroup` where tasks invoke synchronous, blocking I/O (like `FileManager` operations) directly on the actor inadvertently serializes the tasks, preventing parallelism.
**Action:** For stateless components interacting with thread-safe dependencies (like `FileManager.default`), use `struct`s or `nonisolated` methods to allow tasks to execute concurrently across threads and unlock true parallel scanning.
