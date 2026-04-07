## 2024-04-07 - Functional Updates for Published Arrays
**Learning:** In SwiftUI `ObservableObject` view models, mutating individual elements of a `@Published` array property inside a loop triggers a UI update notification for every change. For collections of value types (structs), utilize functional methods like `map` to batch updates into a single property assignment, significantly reducing unnecessary UI recalculations and improving responsiveness.
**Action:** Replace `for` loop mutations on `@Published` array properties with functional transformations like `map`.
