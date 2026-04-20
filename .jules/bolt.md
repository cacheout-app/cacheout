## $(date +%Y-%m-%d) - Array Mutations in SwiftUI ObservableObjects
**Learning:** Mutating an array of structs inside a loop on a `@Published` property in SwiftUI triggers a UI update (Combine `objectWillChange` emission) for every single mutation in the loop. This can cause massive performance degradation (O(N) rendering cycles) during bulk operations like "Select All".
**Action:** Always use functional mapping (e.g., `.map`) to generate a new array and assign it back to the `@Published` property just once to batch UI updates.
