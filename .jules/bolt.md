## 2024-05-23 - Centralize Date/Byte Formatters
**Learning:** Instantiating `ByteCountFormatter` and `ISO8601DateFormatter` in Foundation is computationally expensive. Repeating `ByteCountFormatter.string(...)` creates a new instance internally every time.
**Action:** Centralize shared Foundation formatters (such as `ByteCountFormatter` and `ISO8601DateFormatter`) in a `Formatters` enum located at `Sources/Cacheout/Models/Formatters.swift` to avoid performance overhead from repeated instantiations.
