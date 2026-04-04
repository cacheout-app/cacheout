## 2024-04-04 - Fix Path Traversal in Config Validation
**Vulnerability:** User-controlled socket path passed to `expandingTildeInPath` without verifying it remains within the `~/.cacheout/` boundary.
**Learning:** Resolving a path does not natively sandbox it against traversal attacks (e.g., passing `../../etc/passwd`).
**Prevention:** Securely validate user-supplied file paths by resolving them, standardizing, and enforcing directory boundaries using `.hasPrefix()` against a canonical allowed absolute path with a trailing slash.
