## 2024-04-06 - Avoid string interpolation in shell wrappers
**Vulnerability:** Using string interpolation (`\(variable)`) in shell commands (e.g., `/bin/bash -c`).
**Learning:** Even if the input is currently static or tightly controlled, interpolating strings into shell wrappers creates a fragile pattern susceptible to severe command injection if the input ever becomes dynamic or user-controlled.
**Prevention:** Use direct binary execution via `Process` and pass dynamic inputs securely as elements in the `process.arguments` array.
