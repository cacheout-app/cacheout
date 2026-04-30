## 2024-05-20 - [Performance Issue] ByteCountFormatter allocation overhead
**Learning:** `ByteCountFormatter.string(fromByteCount:countStyle:)` class method instantiates a new `ByteCountFormatter` on every call, leading to expensive memory allocations in loops and UI updates.
**Action:** Always create a shared `ByteCountFormatter` instance and use the instance method `.string(fromByteCount:)` instead of the static class method. I have created `Sources/Cacheout/Helper/Formatters.swift` with `ByteCountFormatter.sharedFile`.
