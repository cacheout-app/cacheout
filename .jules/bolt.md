## 2026-04-17 - Batch @Published array updates
**Learning:** Mutating individual elements of a `@Published` array inside a `for` loop triggers a UI update for every change, causing performance bottlenecks.
**Action:** Use `.map` reassignments instead of `for` loops to batch changes into a single assignment. Add a comment explaining this to avoid it being changed back.
