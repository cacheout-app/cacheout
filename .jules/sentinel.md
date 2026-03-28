## 2024-03-28 - Command Injection via Shell Wrappers in Swift
**Vulnerability:** Shell wrappers (e.g., `/bin/bash -c`) used in conjunction with string interpolation for dynamic inputs (like `shell("/usr/bin/which \(tool)")`) created command injection vectors.
**Learning:** In Swift, using `Process` with a bash wrapper inherently opens up injection risks if any part of the command string is user-controllable or dynamic, even indirectly.
**Prevention:** Avoid shell wrappers entirely. Always invoke the target binary directly (e.g., `/usr/bin/env`, `/usr/bin/which`) and pass dynamic inputs strictly as elements in the `process.arguments` array. Replicate shell features like `2>&1` by mapping `process.standardError` and `process.standardOutput` to the same `Pipe()` instance.
