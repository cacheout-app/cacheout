## 2024-04-29 - Prevent Shell Injection in Tool Discovery
**Vulnerability:** Shell injection risk in `toolExists` via string interpolation (`shell("/usr/bin/which \(tool)")`).
**Learning:** Using a custom shell execution wrapper with string interpolation for system paths creates defense-in-depth risks, even if current inputs are hardcoded.
**Prevention:** Use direct `Foundation.Process` instantiation with arguments arrays instead of shell execution wrappers when checking for tools.