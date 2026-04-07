## 2024-05-15 - Refactoring Shell Wrappers in Swift
**Vulnerability:** Use of `/bin/bash -c` for executing commands like `docker system prune -f 2>&1`.
**Learning:** Using shell wrappers introduces command injection risks if dynamic inputs are added later. Native Swift `Process` handling can accomplish shell-like features securely (e.g., assigning a single `Pipe` to both standard output and standard error handles `2>&1` without shell execution).
**Prevention:** Use direct binary execution via `/usr/bin/env` with explicitly defined arguments and configure I/O pipes directly in Swift.