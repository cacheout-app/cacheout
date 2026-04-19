## 2025-02-14 - Batch @Published array updates to reduce re-renders and Reuse ByteCountFormatter
**Learning:** Mutating individual elements of a `@Published` array property inside a loop triggers a UI update notification for every change. Instantiating `ByteCountFormatter` repeatedly is computationally expensive.
**Action:** Use functional methods like `.map` to batch updates into a single property assignment for arrays. Store and reuse formatters like `ByteCountFormatter` as private properties to avoid the overhead of repeated allocations.
