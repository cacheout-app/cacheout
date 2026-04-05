## 2024-11-20 - Command Injection in Tool Validation
**Vulnerability:** Found a command injection vulnerability in `toolExists` within `Sources/Cacheout/Models/CacheCategory.swift` where user-controlled input (`tool`) was interpolated into a shell wrapper: `shell("/usr/bin/which \(tool)")`.
**Learning:** String interpolation in shell commands (`bash -c`) evaluates variables dynamically in the shell, opening severe command injection vectors if the input contains spaces, pipelines, or glob characters.
**Prevention:** Always avoid shell wrappers (`bash -c`) when possible. Use direct `Process` execution (e.g., `/usr/bin/env` with `arguments = ["which", tool]`) where dynamic arguments are passed safely as an array, entirely bypassing the shell's evaluation step.
