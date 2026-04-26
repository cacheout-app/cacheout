## 2026-04-26 - Shell Injection Risk via String Interpolation
**Vulnerability:** Found string interpolation being used directly inside a shell command (`shell("/usr/bin/which \(tool)")`). If `tool` came from user input, this could lead to command injection.
**Learning:** Avoid passing variables directly into shell commands via string interpolation, as it bypasses proper argument escaping.
**Prevention:** Use `Foundation.Process` directly and pass arguments via the `arguments` array, which avoids a shell interpreter entirely and prevents injection risks.
