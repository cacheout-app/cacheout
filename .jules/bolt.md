## 2024-05-20 - Batching @Published Array Mutations
**Learning:** In SwiftUI ObservableObject view models, mutating individual elements of a @Published array property inside a loop triggers a UI update notification for every change.
**Action:** Use functional methods like `map` to batch updates into a single property assignment, significantly reducing unnecessary UI recalculations. Always add comments explaining this optimization.
