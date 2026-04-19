## 2024-05-24 - Defense in Depth: Direct Process Execution
**Vulnerability:** Unsafe string interpolation in shell wrapper `shell("/usr/bin/which \(tool)")`.
**Learning:** Although inputs here are statically defined, avoiding string interpolation in shell commands is a critical defense-in-depth practice to prevent future command injection.
**Prevention:** Pass dynamic inputs strictly as elements in the `Process().arguments` array and use `.nullDevice` for unused output streams.
