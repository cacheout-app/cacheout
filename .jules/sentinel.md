## 2024-05-20 - Command Injection via String Interpolation in Shell Wrappers
**Vulnerability:** String interpolation used to inject dynamic variables into shell wrapper commands (`shell("/usr/bin/which \(tool)")`), leading to severe command injection vulnerabilities.
**Learning:** Shell wrapper functions (like those calling `/bin/bash -c`) inherently trust the entire string passed to them, meaning any dynamically injected content can break out of the intended command structure if it contains shell metacharacters.
**Prevention:** Avoid string interpolation in shell wrappers entirely. When dynamic inputs are required, execute the command directly using `Foundation.Process` (e.g., via `/usr/bin/env`) and pass the dynamic inputs strictly as elements in the `process.arguments` array.
