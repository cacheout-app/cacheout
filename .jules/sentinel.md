## 2026-04-30 - Command Injection Vulnerability via String Interpolation in Custom Shell Methods
**Vulnerability:** Found `let result = shell("/usr/bin/which \(tool)")` and `runCleanCommand(command)` executing commands using `/bin/bash -c` with raw string interpolation.
**Learning:** This exposes the app to command injection if `tool` or `command` is influenced by user input or malformed configurations.
**Prevention:** Avoid custom `shell(_:)` methods passing raw strings to `/bin/bash -c`. Instead, prefer direct `Foundation.Process` instantiation with an arguments array and check `process.terminationStatus == 0` for tool existence.

## 2026-05-02 - Sentinel: Fix shell injection in dockerPrune
**Vulnerability:** Found `dockerPrune()` executing commands using `/bin/bash -c "docker system prune -f 2>&1"` which is an insecure shell method pattern.
**Learning:** This exposes the app to potential command injection or unexpected shell behaviour.
**Prevention:** Avoid custom shell methods passing raw strings to `/bin/bash -c`. Instead, prefer direct `Foundation.Process` instantiation with an arguments array using `/usr/bin/env` and the exact target tool as the first argument, and assigning the same `Pipe` to both standardOutput and standardError.
