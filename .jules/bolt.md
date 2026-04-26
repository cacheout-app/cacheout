## 2024-05-14 - Batch @Published Array Updates
**Learning:** Mutating individual elements of a `@Published` array property inside a loop triggers a UI update notification for every change, causing O(N) re-renders which is a massive performance bottleneck.
**Action:** For collections of value types (structs), use functional methods like `.map` to batch updates and reassign the entire array at once to trigger a single UI update. Add comments explaining the optimization so it doesn't get "optimized" back to a standard loop by others.
