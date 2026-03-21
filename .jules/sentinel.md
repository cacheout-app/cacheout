## 2024-05-24 - Command Injection Prevention
**Vulnerability:** Execution of shell commands via `/bin/bash -c` wrapper.
**Learning:** Using shell wrappers for command execution introduces potential command injection vectors and relies on shell parsing logic.
**Prevention:** Prefer direct execution of binaries using `Process` with explicit arguments. Replicate shell redirections (like `2>&1`) securely by assigning the same `Pipe()` instance to both `standardOutput` and `standardError` in Swift.