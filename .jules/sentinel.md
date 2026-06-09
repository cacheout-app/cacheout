## 2026-04-30 - Command Injection Vulnerability via String Interpolation in Custom Shell Methods
**Vulnerability:** Found `let result = shell("/usr/bin/which \(tool)")` and `runCleanCommand(command)` executing commands using `/bin/bash -c` with raw string interpolation.
**Learning:** This exposes the app to command injection if `tool` or `command` is influenced by user input or malformed configurations.
**Prevention:** Avoid custom `shell(_:)` methods passing raw strings to `/bin/bash -c`. Instead, prefer direct `Foundation.Process` instantiation with an arguments array and check `process.terminationStatus == 0` for tool existence.

## 2026-05-01 - Command Execution via Hardcoded Path Assumption
**Vulnerability:** Assumed a tool (e.g. `docker`) was located at a specific hardcoded absolute path like `/usr/local/bin/docker`.
**Learning:** Hardcoded binary paths break cross-platform execution (e.g., Apple Silicon vs Intel) and ignore configured environment `PATH` overrides.
**Prevention:** When converting shell commands to direct `Foundation.Process` execution in Swift, use `URL(fileURLWithPath: "/usr/bin/env")` and pass the target tool as the first argument (e.g., `["docker", ...]`) to safely resolve it via the environment's `PATH`.

## 2024-04-22 - [Defense-in-depth] Process execution hang and pipe reading
**Vulnerability:** A process can block (deadlock) when its stdout/stderr pipe fills before the parent reads it, because the child blocks on `write()` while the parent blocks on `waitUntilExit()`.
**Learning:** `pipe.fileHandleForReading.readDataToEndOfFile()` after `process.waitUntilExit()` is the deadlock pattern. Default macOS pipe buffer is ~64KB.
**Prevention:** Read the pipe before/concurrently-with waiting for exit. The simplest pattern is to perform the read inside the same background queue that calls `waitUntilExit()`, capturing the bytes for the caller to use after the dispatch group resolves.

## 2024-05-17 - Enforce HTTPS for Webhook URLs
**Vulnerability:** Webhook configuration allowed unencrypted `http` URLs, exposing sensitive system metrics and alerts to interception.
**Learning:** Validation in `StatusSocket.swift` permitted both `http` and `https`, and `WebhookAlerter.swift` didn't validate the scheme at all during parsing, potentially allowing insecure data transmission.
**Prevention:** Consistently enforce the `https` scheme requirement in both configuration validation (`AutopilotConfigValidator`) and active parsing (`WebhookConfig.parse`) to ensure secure data transit.

## 2024-05-18 - Process Deadlock in CacheoutViewModel.runCleanCommand
**Vulnerability:** `process.waitUntilExit()` was called before reading `pipe.fileHandleForReading` when executing `docker system prune` in `CacheoutViewModel.swift`. A specific instance of the 2024-04-22 pattern.
**Prevention:** Same as 2024-04-22 — read the pipe before calling `waitUntilExit()`, or prefer `try fileHandle.readToEnd()`.

## 2024-05-08 - File Descriptor Leak and Unsafe Path Bridging
**Vulnerability:** Calling `open(2)` without `O_CLOEXEC` causes the file descriptor to leak to child processes, and passing Swift `String` paths implicitly to C functions can result in unsafe filesystem representations.
**Learning:** Child processes inheriting the PID lock file descriptor could prevent the lock from being released. Using `withUnsafeFileSystemRepresentation` is the only safe way to bridge file paths to POSIX APIs.
**Prevention:** Always include `O_CLOEXEC` when opening files with POSIX APIs, and use `URL(fileURLWithPath:).withUnsafeFileSystemRepresentation` to obtain the correct C-string pointer.

## 2024-05-20 - Process Deadlock via Pipe Buffers
**Vulnerability:** External shell command executed in `listLocalSnapshots()` triggered a deadlock when `tmutil` output exceeded 64KB, because stdout and stderr were read synchronously inside the process termination handler.
**Learning:** In Swift, reading from a process pipe synchronously inside a `terminationHandler` can result in a permanent deadlock if the child blocks writing to a full pipe, preventing it from exiting.
**Prevention:** Asynchronously drain pipes continuously while the process is running using background queues.
## 2026-05-21 - TOCTOU Symlink Vulnerability in Logging
**Vulnerability:** Found `FileHandle(forWritingTo:)` and `String.write(to:atomically:)` being used for writing to a log file, which follow symlinks by default.
**Learning:** High-level Swift file APIs follow symlinks by default, making them vulnerable to Time-of-Check to Time-of-Use (TOCTOU) symlink attacks if the directory is potentially untrusted.
**Prevention:** To securely create or append to files in potentially untrusted directories, use POSIX `open(2)` with flags such as `O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC` to explicitly refuse symlinks, then wrap the resulting file descriptor in a `FileHandle`.
