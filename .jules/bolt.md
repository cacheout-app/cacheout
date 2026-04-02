## 2024-04-02 - TaskGroup Sliding Window Concurrency
**Learning:** In Swift structured concurrency, when processing high-volume tasks using `withTaskGroup`, static chunking (e.g., waiting for all tasks in a chunk to finish before spawning the next chunk) limits throughput due to tail latency (waiting for the slowest task in a chunk).
**Action:** Use a sliding window approach with an iterator instead of static chunking to maintain maximum concurrent execution limits continuously and avoid tail latency bottlenecks.
