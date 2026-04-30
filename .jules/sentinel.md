## 2024-04-03 - Shell Wrapper Vulnerability
**Vulnerability:** Use of `/bin/bash -c` in `Process` invocations creates latent command injection vulnerabilities and decreases security.
**Learning:** Shell redirections like `2>&1` tempt developers to use shell wrappers, but these can be securely replicated natively in Swift using identical `Pipe()` instances.
**Prevention:** Use `/usr/bin/env <tool>` with explicitly defined arguments instead of a shell wrapper. To redirect `stderr` to `stdout`, assign the same `Pipe()` to `process.standardOutput` and `process.standardError`.
