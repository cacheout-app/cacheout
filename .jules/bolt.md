## 2024-04-30 - Foundation Formatter Allocation Overhead
**Learning:** Allocating `ByteCountFormatter` and `ISO8601DateFormatter` repeatedly causes performance degradation.
**Action:** Extracted and reused static instances to avoid overhead.
