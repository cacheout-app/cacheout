## 2024-04-18 - Published Array Mutation
**Learning:** In SwiftUI `ObservableObject` view models, mutating individual elements of a `@Published` array property inside a loop triggers a UI update notification for every single change. For collections of value types, standard `for` loop mutations cause massive unnecessary UI recalculations.
**Action:** Utilize functional methods like `map` to batch updates into a single property assignment instead of mutating individual elements in a loop. Always add comments explaining this optimization to prevent future regressions.
