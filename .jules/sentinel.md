## 2025-01-30 - Prevent Command Injection via Direct Process Execution
**Vulnerability:** Shell wrappers (e.g., `shell("cmd \(variable)")`) relying on `/bin/bash -c` present command injection vulnerabilities when combining static commands with dynamic variables.
**Learning:** Using string interpolation with `/bin/bash -c` allows attackers to bypass intended arguments.
**Prevention:** Avoid shell wrappers completely and execute commands directly using `Process()` where `executableURL` is set to `/usr/bin/env` and parameters are strictly managed via `process.arguments = ["tool", dynamicInput]`.
