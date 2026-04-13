## 2024-05-13 - Batching @Published Array Mutations
**Learning:** In SwiftUI ObservableObject view models, mutating individual elements of a @Published array property inside a loop triggers a UI update notification for every change. For collections of value types (structs), functional methods like map batch updates into a single property assignment, significantly reducing unnecessary UI recalculations.
**Action:** Replace for loop mutations on @Published array collections with .map re-assignments to batch updates, and document this with comments to prevent future reversions.
