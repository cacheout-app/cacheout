## 2024-06-18 - Offload Synchronous Operations from Main Actor
**Learning:** In Swift Concurrency, `Task { ... }` created from within a `@MainActor` inherits that actor's context. To prevent synchronous, blocking operations (like `DiskInfo.current()`, `process.waitUntilExit()`, and `pipe.readDataToEndOfFile()`) from blocking the main thread and freezing the UI, they must be executed outside the actor's context.
**Action:** Use `Task.detached { ... }` which does not inherit the actor context, and `await` its `.value` property to safely return the result without blocking the `@MainActor`.
