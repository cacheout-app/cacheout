## 2024-04-20 - Pipe Buffer Deadlock DoS
**Vulnerability:** A Denial of Service (DoS) vulnerability existed due to a pipe buffer deadlock when executing shell commands via `Foundation.Process`.
**Learning:** Calling `process.waitUntilExit()` before reading the output from the pipe via `readDataToEndOfFile()` can cause a deadlock if the child process's output exceeds the operating system's pipe buffer size limit. The child process blocks trying to write to the full pipe, and the parent process blocks waiting for the child to exit, causing the application to hang.
**Prevention:** Always read the standard output and standard error pipes (e.g., using `readDataToEndOfFile()`) *before* calling `waitUntilExit()`, or handle reading in a separate concurrent thread.
