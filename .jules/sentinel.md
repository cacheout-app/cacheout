## 2024-04-17 - Command Injection Risk via String Interpolation
**Vulnerability:** Defense-in-depth command injection risk where dynamic variables (`tool`) were interpolated into a shell wrapper command (`shell("/usr/bin/which \(tool)")`).
**Learning:** Using string interpolation to inject variables into shell commands introduces severe command injection vulnerabilities.
**Prevention:** Always use direct `Process()` execution and pass dynamic inputs strictly as elements in the `process.arguments` array.
