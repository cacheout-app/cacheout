## 2026-04-04 - Actor Isolation Blocking Parallelism in TaskGroups
**Learning:** Using an `actor` to manage a `withTaskGroup` where child tasks invoke synchronous, blocking operations directly on the actor (`await self.method()`) inadvertently serializes the tasks on the actor's executor, preventing parallelism.
**Action:** For stateless components interacting with thread-safe dependencies (like `FileManager`), use `struct`s or `nonisolated` methods instead of `actor`s to allow tasks to execute concurrently across threads.
