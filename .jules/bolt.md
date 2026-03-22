## 2024-05-15 - Use `.lazy` with `Set` initialization
**Learning:** Initializing a `Set` from a collection transformation (like `.filter().map()`) creates intermediate arrays, which impacts performance, especially in frequently called code paths.
**Action:** When creating a `Set` from chained operations, insert `.lazy` before the first operation (e.g., `collection.lazy.filter().map()`) to avoid allocating temporary arrays.
