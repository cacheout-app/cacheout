## 2024-04-01 - Command Injection in toolExists
**Vulnerability:** Command injection via `shell("/usr/bin/which \(tool)")` where `tool` could contain shell metacharacters.
**Learning:** Naively interpolating dynamic variables into shell wrapper commands (`/bin/bash -c`) introduces command injection. While currently hardcoded, if `tool` was user-controlled or fetched dynamically, this would be highly exploitable.
**Prevention:** Always use direct executable invocation via `Process()` and pass dynamic inputs explicitly in the `arguments` array instead of using string interpolation in a shell wrapper.
