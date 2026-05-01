## 2024-05-01 - Batch Array Updates in ObservableObject
**Learning:** Mutating individual elements of a `@Published` array inside a loop triggers a UI update notification for every change, which can severely impact performance in SwiftUI.
**Action:** Batch updates by mutating a local copy of the array and reassigning it to the `@Published` property, minimizing UI update notifications.
