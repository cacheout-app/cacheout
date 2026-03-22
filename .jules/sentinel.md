## 2026-03-22 - Prevent Command Injection in Docker Prune
**Vulnerability:** Execution of `docker system prune -f 2>&1` via `/bin/bash -c` in `CacheoutViewModel.swift`.
**Learning:** Relying on intermediate shell wrappers to execute fixed command strings creates unnecessary attack surface for command injection if dynamic input is ever introduced.
**Prevention:** Use `/usr/bin/env` with `Process` to directly invoke executables (e.g., `docker`) and pass arguments explicitly as an array. Handle stream redirections natively (like assigning the same `Pipe()` to both stdout and stderr instead of using `2>&1`).
