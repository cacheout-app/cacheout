## 2024-04-28 - Cache Formatters to Prevent Performance Overhead
**Learning:** Instantiating `DateFormatter`, `ISO8601DateFormatter`, and `ByteCountFormatter` in Foundation or using their class methods is computationally expensive because they create a new instance internally on every call.
**Action:** Store and reuse these formatters as private static (for structs/views) or instance (for actors/classes) properties to avoid the overhead of repeated allocations in high-frequency methods. For views, use `fileprivate` if accessed by sibling views.
