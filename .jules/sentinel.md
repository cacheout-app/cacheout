## 2024-03-22 - Secure Process Execution and Standard Error Redirection
**Vulnerability:** Command injection risk from using `/bin/bash -c` to execute shell commands like `docker system prune -f 2>&1` in Swift.
**Learning:** Using `Process` to directly invoke `/usr/bin/env` with arguments like `["docker", "system", "prune", "-f"]` mitigates injection risks by bypassing the shell entirely. Bash syntax like `2>&1` needs to be securely replicated by assigning the same `Pipe()` instance to both `process.standardOutput` and `process.standardError`.
**Prevention:** Always favor direct executable invocation with `process.arguments` instead of using a shell wrapper. Handle stream redirection directly in Swift instead of relying on shell operators.
