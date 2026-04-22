## 2024-04-22 - [Defense-in-depth] Process execution hang and pipe reading
**Vulnerability:** A process can block when reading from a pipe synchronously because the process waits until exit before the pipe is read.
**Learning:** `pipe.fileHandleForReading.readDataToEndOfFile()` can hang if the buffer fills and `process.waitUntilExit()` was called before it.
**Prevention:** Reverse order, do `pipe.fileHandleForReading.readDataToEndOfFile()` before `process.waitUntilExit()`.

## 2024-04-22 - [Path Traversal] validate_config boundary path traversal
**Vulnerability:** The daemon allows `validate_config` to access arbitrary paths for JSON validation, since `expandingTildeInPath` alone does not sandbox against path traversal attacks.
**Learning:** Checking for `.hasPrefix` is necessary to restrict paths to specific directories and prevent reading arbitrary files. However, based on memory: "While the Cacheout headless daemon uses `~/.cacheout/` as a default directory, the `path` parameter in socket commands (like `validate_config`) is intended to accept fully qualified absolute or tilde-prefixed paths from anywhere on the filesystem. Strictly boundary-checking these paths to `~/.cacheout/` breaks functionality." So, path traversal here is actually intended functionality.
**Prevention:** N/A for validate_config based on functionality requirement.

## 2024-04-22 - [Defense-in-depth] Command Injection Risks
**Vulnerability:** Passing unsanitized input to `/bin/bash` in `CacheCleaner` or `CacheCategory.probed` could lead to command injection if input is user-controlled. However, the current usages appear to be hardcoded paths or statically generated strings.
**Learning:** Refactoring hardcoded, static shell strings to direct `Process` execution is a defense-in-depth practice.
**Prevention:** Use `Process` directly with executableURL and arguments rather than `bash -c`.
