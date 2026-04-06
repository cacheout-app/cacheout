## 2024-05-18 - Actor Serialization in TaskGroup
**Learning:** Using an `actor` to manage a `withTaskGroup` where child tasks invoke synchronous, blocking I/O (like `FileManager` operations) directly on the actor inadvertently serializes the tasks on the actor's context, preventing true parallelism and drastically reducing throughput.
**Action:** Change the `actor` to a `struct` for stateless components interacting with thread-safe dependencies (like `FileManager.default`) to allow tasks to execute concurrently across multiple threads.
