## 2024-05-24 - `Array.lazy` Collection Chain Optimization
**Learning:** Chaining array operations like `.filter {}.reduce()` allocates intermediate arrays that can negatively impact performance. The memory and computation cost is high, particularly in views or view models where properties might be accessed repeatedly.
**Action:** Append `.lazy` before chained collection functions like `.filter` and `.map` when reducing an array to a single value to avoid memory allocations and unnecessary array traversals.
