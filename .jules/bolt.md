
## 2024-03-24 - Avoid `.lazy` on slice-to-array conversions
**Learning:** In Swift, applying `.lazy` to an `ArraySlice` immediately inside an `Array()` initializer (e.g., `Array(slice.lazy.filter)`) does not prevent intermediate array allocation and provides no performance benefit.
**Action:** The `.lazy` property is effective for continuous chained operations (like `.lazy.filter { ... }.reduce()`) where the intermediate collection can be completely bypassed.
