## 2026-05-02 - Avoid mutating `@Published` arrays in loops
**Learning:** Mutating elements of a `@Published` array inside a loop triggers a UI update notification for every single change, causing excessive redraws and performance degradation in SwiftUI.
**Action:** Always batch updates by creating a local copy, applying mutations to the copy, and then assigning the result back to the `@Published` property.
