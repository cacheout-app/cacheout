## 2024-05-14 - Sliding Window Concurrency
**Learning:** In Swift structured concurrency, static chunking in a withTaskGroup limits throughput due to tail latency (waiting for the slowest task in a chunk).
**Action:** Use a sliding window approach with an iterator instead to maintain maximum concurrent execution limits continuously.
