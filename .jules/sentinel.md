## 2024-04-25 - Prevented Insecure Shell Execution
**Vulnerability:** Insecure shell execution via string interpolation in `toolExists` helper function (`shell("/usr/bin/which \(tool)")`).
**Learning:** Checking for the existence of tools using the shell allows potential command injection if the tool name is externally controlled. Even when the tool name is hardcoded currently, this pattern is dangerous and should be avoided for defense-in-depth.
**Prevention:** Use `Foundation.Process` directly to launch the binary instead of `/bin/bash -c`. Pass arguments directly via `process.arguments` array to prevent shell parsing and injection.
