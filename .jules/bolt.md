## 2024-05-18 - Sliding Window Concurrency
**Learning:** In Swift structured concurrency, when processing high-volume tasks using `withTaskGroup`, static chunking (e.g., `stride(from:to:by:)`) limits throughput due to tail latency (waiting for the slowest task in a chunk).
**Action:** Use a sliding window approach with an iterator instead to maintain maximum concurrent execution limits continuously.
