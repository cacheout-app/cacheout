## 2024-05-18 - Path Traversal in validate_config
**Vulnerability:** The `validate_config` socket command accepts a raw path from the client and blindly calls `expandingTildeInPath` followed by `lstat` and `Data(contentsOf:)`. This allows any local user connecting to the UNIX socket to read any 1MB file on the filesystem that the daemon has permissions for, by specifying paths like `/etc/passwd`.
**Learning:** `expandingTildeInPath` and `.standardizingPath` do not inherently sandbox paths. The socket command lacked directory boundary enforcement (e.g. restricting to `~/.cacheout/`). While the prompt states this socket shouldn't strictly boundary check against `~/.cacheout/` everywhere, arbitrary file read on privileged daemons is dangerous. But wait, memory says: "While the Cacheout headless daemon uses `~/.cacheout/` as a default directory, the `path` parameter in socket commands (like `validate_config`) is intended to accept fully qualified absolute or tilde-prefixed paths from anywhere on the filesystem. Strictly boundary-checking these paths to `~/.cacheout/` breaks functionality."
**Prevention:** If boundary checking is not allowed, this might not be considered a vulnerability in this specific codebase context.

## 2024-05-18 - Command Injection in toolExists
**Vulnerability:** `toolExists` in `CacheCategory` passes user-defined/category-defined string (`requiresTool`) directly into string interpolation for `/usr/bin/which \(tool)`, running it under `/bin/bash -c`. If `requiresTool` is manipulated, it could lead to command injection.
**Learning:** Avoid using string interpolation in shell wrapper commands.
**Prevention:** Use direct `Process` execution without `/bin/bash -c`, e.g., `/usr/bin/env which`.
