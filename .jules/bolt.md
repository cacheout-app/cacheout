## 2024-05-24 - Batching @Published Array Updates
**Learning:** Mutating elements of a `@Published` array of structs in a `for` loop (e.g. `for i in array.indices { array[i].prop = val }`) inside an `ObservableObject` triggers a separate UI update for every single iteration, causing severe UI unresponsiveness and thrashing when dealing with many items (like `nodeModulesItems`).
**Action:** Always use `.map` to create a new array and assign it back to the `@Published` property in a single operation, batching the UI updates.
