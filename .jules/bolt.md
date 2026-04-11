## 2024-04-11 - [Batch @Published Array Mutations]
**Learning:** Mutating individual elements of a `@Published` array inside a loop triggers a UI update for each change.
**Action:** For collections of value types, use functional methods like `.map` to batch updates into a single assignment, significantly reducing unnecessary UI recalculations.
