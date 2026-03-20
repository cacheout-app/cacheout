## 2024-03-20 - Avoid Intermediate Arrays in Swift Set Initialization
**Learning:** Chaining `.filter` and `.map` on collections like `NSWorkspace.shared.runningApplications` before initializing a `Set` creates unnecessary intermediate arrays. This is particularly inefficient for operations that are called frequently or process large collections.
**Action:** Always append `.lazy` to the collection before applying chained operations like `.filter` and `.map` when the result is being consumed directly into a `Set` or another container initialization.
