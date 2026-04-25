## 2026-04-25 - [Cache formatters to prevent allocation overhead]
**Learning:** Instantiating `DateFormatter`, `ISO8601DateFormatter`, and `ByteCountFormatter` is computationally expensive. The class method `ByteCountFormatter.string(fromByteCount:countStyle:)` creates a new instance internally on every call.
**Action:** Store and reuse these formatters as private properties (instance for actors/classes, static for structs) to avoid overhead, especially in loops and UI updates.
