## 2024-05-15 - Batched `@Published` Array Updates
**Learning:** Mutating individual elements of a `@Published` array inside a `for` loop triggers a UI update notification for every single element change. For collections of structs, using `.map` to create a new array and assigning it back batches the UI update into a single event.
**Action:** Always use functional methods like `.map` instead of `for` loops when performing bulk modifications on `@Published` value-type collections in SwiftUI ViewModels, and add explanatory comments to prevent future regressions.
