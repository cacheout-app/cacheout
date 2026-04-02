## 2023-10-24 - TaskGroup Serialization in Actors
**Learning:** Using an `actor` to isolate a type that runs parallel I/O tasks via `withTaskGroup` inadvertently serializes the execution if the tasks call methods on that same actor. The tasks queue up on the actor's executor instead of running concurrently across threads.
**Action:** For stateless scanning/processing objects that use `withTaskGroup` for heavy I/O operations (like `FileManager` calls) but don't need mutable state protection, use a `struct` or `nonisolated` methods to allow true concurrency.
