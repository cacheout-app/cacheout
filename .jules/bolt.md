## 2026-04-05 - Optimize ProcessMemoryScanner concurrency with sliding window
**Learning:** In Swift structured concurrency, when processing high-volume tasks using `withTaskGroup`, static chunking limits throughput due to tail latency (waiting for the slowest task in a chunk). A sliding window with an iterator maintains maximum concurrent execution limits continuously.
**Action:** Always use an iterator-based sliding window in `withTaskGroup` instead of static chunking for processing large collections to avoid tail latency bottlenecks.
