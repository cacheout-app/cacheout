## 2024-04-15 - Command injection in CacheCategory probes
**Vulnerability:** `CacheCategory.toolExists` passes user-supplied input to a shell via `/usr/bin/which \(tool)`, introducing command injection if the category allows dynamic inputs.
**Learning:** Shell evaluation with string interpolation `\()` is unsafe. Passing dynamic inputs through `/bin/bash -c` risks evaluating shell operators.
**Prevention:** Avoid shell evaluations where direct execution of `Process` with structured `arguments` is possible.
