## 2024-05-18 - Avoid shell wrappers for command execution
**Vulnerability:** Command execution via `/bin/bash -c` wrappers.
**Learning:** Shell wrappers like `/bin/bash -c` can be vulnerable to command injection if un-sanitized parameters are included.
**Prevention:** Always prefer using `/usr/bin/env` or direct paths to binaries in `Process` configurations and pass parameters directly using `process.arguments` arrays to bypass the shell.
