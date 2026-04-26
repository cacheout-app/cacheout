## 2024-04-26 - Command Injection via Shell Interpolation
**Vulnerability:** `toolExists` in `CacheCategory.swift` used shell interpolation (`shell("/usr/bin/which \(tool)")`) to check for the existence of tools, which could lead to command injection if `tool` was user-controlled.
**Learning:** Shell interpolation is inherently insecure and can lead to command injection even when the input is assumed to be safe. Direct execution of binaries with structured arguments avoids this class of vulnerabilities entirely.
**Prevention:** Avoid `/bin/bash -c` and shell interpolation whenever possible. Use `Foundation.Process` with direct `executableURL` and structured `arguments` arrays instead.
