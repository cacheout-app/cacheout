## 2025-04-02 - Path Traversal in File Validation
**Vulnerability:** Path traversal vulnerability in `StatusSocket.swift`'s `validate_config` socket command.
**Learning:** `expandingTildeInPath` does not resolve `..` or sandbox the path, allowing a malicious user to access files outside the user's home directory.
**Prevention:** Use `.standardizingPath` after `.expandingTildeInPath`, and enforce directory boundaries by verifying the final path `.hasPrefix()` against a canonical allowed path, such as the user's home directory.
