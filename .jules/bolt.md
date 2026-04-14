## 2024-05-23 - Batch UI Updates for Published Arrays
**Learning:** Mutating individual elements of a @Published array inside a loop triggers a UI update for every change, leading to O(N) re-renders.
**Action:** For collections of value types, use functional methods like .map to batch updates into a single property assignment, significantly reducing unnecessary UI recalculations.
