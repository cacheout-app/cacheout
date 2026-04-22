## 2024-04-22 - Prevent command injection by using structured shell arguments
**Vulnerability:** Shell scripts executed using `/bin/bash -c` can be susceptible to command injection attacks if arguments are dynamically generated in the future.
**Learning:** Shell strings often bundle commands and suppressions together (e.g., `cmd args 2>/dev/null`), which makes it tempting to use bash. However, this allows shell expansion.
**Prevention:** Instead of one large shell script string, use an array of structured arrays (e.g., `[[cmd, args]]`) and execute them directly via `Foundation.Process` (using `/usr/bin/env`), piping standard error/output to `FileHandle.nullDevice` to achieve the same suppression safely.
