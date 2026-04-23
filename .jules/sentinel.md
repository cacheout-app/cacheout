## 2024-05-24 - Command Injection Risk in Cache Cleanup

**Vulnerability:** Execution of custom cleanup commands via string interpolation in `/bin/bash -c`.
**Learning:** Using a single string `cleanCommand` passed to the shell opens up a defense-in-depth risk of command injection, even if the paths seem static.
**Prevention:** Use structured arguments (e.g., `[[String]]` for `cleanSteps`) and execute them directly via `Process` with `/usr/bin/env` without going through a shell, and suppress output securely with `FileHandle.nullDevice`.
