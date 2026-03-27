## 2024-05-24 - Process execution via shell wrapper
**Vulnerability:** Execution of command `docker system prune -f 2>&1` via `/bin/bash -c` in `CacheoutViewModel.swift`. Although there wasn't dynamic input here, using shell wrappers is a systemic risk for command injection in Swift.
**Learning:** Shell redirections like `2>&1` can be replicated securely in Swift by assigning the same `Pipe()` instance to both `process.standardOutput` and `process.standardError` without needing `/bin/bash`.
**Prevention:** Avoid shell wrappers (`/bin/bash -c`). Use direct executable invocation (e.g., `/usr/bin/env` with binary name) with an explicitly defined `arguments` array. Set stdout and stderr to the same `Pipe()` instance to capture combined output instead of relying on shell operators.
