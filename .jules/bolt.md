## 2024-05-24 - Swift Collection Operations
**Learning:** Chaining eager collection operations like `.filter` and `.map` creates intermediate arrays, adding memory overhead. This can be especially impactful when the goal is to initialize a different collection type (e.g., `Set`).
**Action:** Use `.lazy` before chaining operations to construct a sequence directly when generating values for a new collection instance without intermediate allocations.
