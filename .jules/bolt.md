## YYYY-MM-DD - Sliding Window Concurrency
**Learning:** In Swift structured concurrency, when processing high-volume tasks using `withTaskGroup`, utilize a sliding window approach with an iterator instead of static chunking. Static chunking limits throughput due to tail latency (waiting for the slowest task in a chunk), whereas a sliding window maintains maximum concurrent execution limits continuously.
**Action:** Use an iterator inside `withTaskGroup` to add tasks up to the concurrency limit, then add new tasks as previous ones complete.
