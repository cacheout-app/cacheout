## 2024-05-24 - Formatter Instantiation Bottleneck
**Learning:** Instantiating `DateFormatter`, `ISO8601DateFormatter`, and `ByteCountFormatter` in Foundation is computationally expensive. Calling `ByteCountFormatter.string(fromByteCount:countStyle:)` creates a new instance internally on every call.
**Action:** Store and reuse these formatters as static properties (e.g., in a `Formatters` enum) to avoid the overhead of repeated allocations in high-frequency methods like loops or UI updates.
