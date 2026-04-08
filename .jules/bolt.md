## 2024-04-08 - Batch UI updates in ObservableObject
**Learning:** Mutating individual elements of a `@Published` array property (containing structs) inside a loop triggers a UI update notification for every change, causing unnecessary re-renders.
**Action:** Use functional methods like `map` to batch updates into a single array reassignment, significantly reducing UI recalculations.
