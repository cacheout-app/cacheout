## 2024-03-24 - Use lazy collections for chained sequence operations
**Learning:** For performance-sensitive collection transformations involving chained operations like `filter` and `map` on large datasets, utilize the `.lazy` property to create a lazy sequence and avoid the creation of intermediate arrays. However, applying `.lazy` to small collections yields negligible gains and is considered an unmeasurable micro-optimization to avoid.
**Action:** Apply `.lazy` when chaining `.filter` and `.reduce` on potentially large collections like node_modules items.
