## 2024-05-24 - Process execution defense-in-depth

**Vulnerability:** Shell-based command execution via `Process()` with string interpolation.
**Learning:** Found multiple usages where `Process()` is used to invoke `bash -c` which internally calls a hardcoded shell string or a string that contains a variable, presenting a command injection risk.
**Prevention:** Avoid shell wrapper commands with string interpolation or variables. Instead, use `Process().arguments` array to separate the executable and its arguments, or pass explicit argument arrays to the executable directly.
