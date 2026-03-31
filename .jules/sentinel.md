## 2024-05-18 - Prevent Command Injection via String Interpolation in shell wrappers
**Vulnerability:** A command injection risk existed in `CacheCategory.swift` within `toolExists` where `shell("/usr/bin/which \(tool)")` directly interpolated the dynamic `tool` string into a `/bin/bash -c` executed command string.
**Learning:** Naively passing concatenated or interpolated strings to shell wrappers opens the door for command injection if the input ever becomes dynamic or user-controlled.
**Prevention:** Always invoke external executables directly (e.g., using `Process` with `/usr/bin/env`) and pass dynamic inputs exclusively as elements in the `process.arguments` array rather than executing a concatenated shell string.
