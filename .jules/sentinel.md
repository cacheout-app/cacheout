## 2026-04-16 - Command Injection Defense-in-Depth via Process.arguments
**Vulnerability:** Defense-in-depth against command injection in shell wrappers (e.g., `shell("which \(tool)")`).
**Learning:** Using string interpolation to inject dynamic variables into shell wrapper commands introduces severe command injection vulnerabilities if user-controlled input ever reaches the context.
**Prevention:** Pass dynamic inputs strictly as elements in the `Process().arguments` array using direct binary execution instead of relying on shell wrappers.
