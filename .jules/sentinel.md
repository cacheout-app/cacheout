## 2024-04-08 - Prevent command injection by bypassing shell wrapper
**Vulnerability:** Command injection risk via string interpolation into a shell command wrapper.
**Learning:** `toolExists` in `CacheCategory.swift` used `shell("/usr/bin/which \(tool)")`, executing via `/bin/bash -c`. Although the input was currently hardcoded, this pattern creates a severe vulnerability if dynamic inputs are ever passed.
**Prevention:** Always use direct execution via `Process()` and pass inputs inside `process.arguments` instead of interpolating strings into a shell command.
