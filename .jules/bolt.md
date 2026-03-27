## 2024-06-18 - Unnecessary blocking operations on @MainActor
**Learning:** In `CacheoutViewModel.swift`, synchronous blocking operations like `DiskInfo.current()`, `process.waitUntilExit()`, and `pipe.fileHandleForReading.readDataToEndOfFile()` are run directly on the `@MainActor` (since the class is marked `@MainActor`). This causes the main thread to block, potentially causing UI hitching during long operations.
**Action:** Use `Task.detached` to offload these blocking operations to a background thread to maintain UI responsiveness.
