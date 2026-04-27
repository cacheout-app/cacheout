## 2024-05-14 - Expensive Formatter Allocations
**Learning:** Found multiple instances of `ByteCountFormatter.string(fromByteCount:countStyle:)` and `ISO8601DateFormatter()` being instantiated on the fly in `CacheoutViewModel`, models, and views. In Swift, these formatters are computationally expensive to create and should be cached to prevent performance overhead, especially in UI properties accessed frequently.
**Action:** Replace on-the-fly formatter instantiation with cached, static/fileprivate properties for `ByteCountFormatter` and `ISO8601DateFormatter`.
