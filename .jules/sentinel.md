## 2024-05-24 - [Command Injection via String Interpolation in Shell Wrappers]
**Vulnerability:** Found a command injection vulnerability where a dynamic variable was interpolated into a shell wrapper command string: `shell("/usr/bin/which \(tool)")`.
**Learning:** Using string interpolation inside shell commands (`/bin/bash -c "..."`) allows user-supplied data containing shell metacharacters (e.g., `;`, `&`, `|`) to execute arbitrary commands.
**Prevention:** Always use direct process invocation (`Foundation.Process`) without shell wrappers, passing dynamic user input strictly as isolated elements in the `process.arguments` array.
