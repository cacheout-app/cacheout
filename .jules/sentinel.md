## 2024-04-03 - Path Traversal in Config Validation
**Vulnerability:** Arbitrary file read in daemon UNIX socket via path traversal
**Learning:** `expandingTildeInPath` alone does not sandbox against path traversal sequences (like `../../etc/shadow`).
**Prevention:** Always use `.standardized` to resolve traversal sequences and validate boundaries using `.hasPrefix()` with a trailing slash against the allowed canonical directory.
