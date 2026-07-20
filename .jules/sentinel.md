# 🛡️ Sentinel — security learning log

Read `.jules/README.md` first. Then re-read the **FIXED SITES** and
**ANTI-PATTERNS** sections below before considering any PR. Most Sentinel
PRs in the last 60 days have been closed as duplicates of these.

## ✅ FIXED SITES — do not re-propose

Each row is a security finding that has been verified hardened in main.
**If your candidate PR touches the same file:line or the same pattern,
the issue is already fixed.** Stop.

| File | Line(s) | Pattern fixed | By |
|---|---|---|---|
| `Sources/CacheoutHelperLib/SysctlJournal.swift` | journal temp file write | `Data.write` + `setAttributes` → `open(O_CREAT \| O_EXCL \| O_CLOEXEC, 0o600)` | #396 |
| `Sources/Cacheout/Cleaner/CacheCleaner.swift` | `logCleanup` log dir/file | `FileHandle(forWritingTo:)` → `open(O_NOFOLLOW \| O_APPEND \| O_CLOEXEC, 0o600)`, log dir created 0o700 | #391 |
| `Sources/Cacheout/Headless/StatusSocket.swift` | `start()` dir chmod | `setAttributes(stateDir, 0o700)` → `open(O_NOFOLLOW \| O_DIRECTORY) + fchmod` | #397 |
| `Sources/Cacheout/Headless/StatusSocket.swift` | `start()` post-bind verify | path-based `attributesOfItem` → `lstat` + refuse if not `S_IFSOCK`; `fchmodat(AT_SYMLINK_NOFOLLOW)` | #397 |
| `Sources/Cacheout/Headless/StatusSocket.swift` | `handleValidateConfig` | `lstat` + `Data(contentsOf:)` → `open(O_NOFOLLOW \| O_CLOEXEC) + fstat + read(fd)` with byte cap | #397 |
| `Sources/Cacheout/Headless/DaemonMode.swift` | config reload (~ line 972) | `chmod(path, 0o600)` + `FileManager.contents(atPath:)` → `open(O_NOFOLLOW \| O_CLOEXEC) + fchmod + readToEnd` | #346 |
| `Sources/Cacheout/Headless/DaemonMode.swift` | stateDir hardening (~ line 298) | `setAttributes([.posixPermissions: 0o700], ofItemAtPath: config.stateDir.path)` → `open(O_NOFOLLOW \| O_DIRECTORY \| O_CLOEXEC) + fchmod` | #410 |
| `Sources/Cacheout/Intervention/Tier2Interventions.swift` | `listLocalSnapshots()` | pipe-buffer deadlock fix: read pipe concurrently with `waitUntilExit()` | #274 |
| `Sources/Cacheout/Intervention/Tier2Interventions.swift` | `dockerPrune()` | same pipe-buffer pattern as above | #236 |
| `Sources/Cacheout/ViewModels/CacheoutViewModel.swift` | `runCleanCommand` | same pipe-buffer pattern | merged pre-v2.1.0 |
| `Sources/Cacheout/Headless/...` (PID lock fd) | `open(2)` for PID lock | added `O_CLOEXEC`, switched to `withUnsafeFileSystemRepresentation` | #248 |
| `Sources/Cacheout/Headless/...` (webhook URL) | webhook `url` field | `AutopilotConfigValidator` + `WebhookConfig.parse` now require `https` | #260 |

**Before opening any Sentinel PR**, grep the candidate file and confirm
none of these patterns are already present at your candidate site:

```sh
# Generic check — does the file already use fd-based secure I/O?
grep -nE "O_NOFOLLOW|O_CLOEXEC|fchmod|withUnsafeFileSystemRepresentation" <candidate-file>
```

## 🚫 ANTI-PATTERNS — these PRs will be rejected

1. **Raw `open(path, ...)` without `withUnsafeFileSystemRepresentation`.**
   The 2024-05-08 learning below (File Descriptor Leak and Unsafe Path
   Bridging) is non-negotiable. Even a PR that "fixes" a TOCTOU but uses
   `open(config.stateDir.path, …)` will be rejected for violating the
   path-bridging rule.

2. **Replacing `chmod` without also fixing a path-based read that follows.**
   If the original code is `chmod(path); FileManager.contents(atPath: path)`,
   replacing only the chmod leaves the read TOCTOU window open. A correct
   fix uses `open(O_NOFOLLOW)` once, then `fchmod` + `readToEnd` on the
   same fd. (See #346 / #400-#402 closure reasoning.)

3. **Re-fixing the `setAttributes(stateDir, 0o700)` line in DaemonMode.swift.**
   Fixed in #410. Stop opening new PRs for this. If you believe the fix is
   inadequate, comment on the canonical PR rather than opening a new one.

4. **Closing the umask window on socket bind.** `StatusSocket.start()` sets
   `umask(0o077)` *before* `bind()`, so the socket is born 0o600 atomically.
   The trailing chmod is a defensive backstop, not the primary control. PRs
   that propose "fixing" this as if it were a primary vulnerability are
   misreading the code.

5. **Proposing `Data.write(to:)` replacements in files that already use
   `open(O_CREAT | O_EXCL | O_CLOEXEC)`.** Check first.

6. **"Fixed insecure file creation permissions" with no specific file or
   line in the title.** Title must name the file or function. Generic
   titles read as a re-run of an earlier PR template and get closed
   without review.

## Quality requirements for security PRs

- Title format: `🛡️ Sentinel: [SEVERITY] <verb> <specific-issue> in <File.swift>`
- Body must include: the specific call site (`File.swift:line`), the threat
  model (who attacks, what they need, what they get), the patched snippet.
- Use `URL(fileURLWithPath:).withUnsafeFileSystemRepresentation { ptr in ... }`
  for any C-string path argument, **always**.
- Always `defer { close(fd) }` immediately after an `open` that succeeds.
- Always thread errno through to a useful error (`String(cString: strerror(errno))`
  or a typed Error).
- Always update this file with an entry under `## Learning log`.

---

## Learning log

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

## 2024-06-05 - TOCTOU Vulnerability via chmod and symlinks
**Vulnerability:** Used `chmod(path, 0o600)` and `FileManager.default.contents(atPath:)` which follow symlinks, creating a TOCTOU symlink attack vulnerability.
**Learning:** Functions that operate on string paths (like `chmod`) resolve symlinks, which allows attackers to modify the permissions of arbitrary files if the path is swapped for a symlink before execution.
**Prevention:** Always use `open()` with `O_NOFOLLOW | O_CLOEXEC` to get a file descriptor, apply permissions using `fchmod()`, and read from it via `FileHandle`.

## 2026-05-02 - Insecure File Creation and TOCTOU Vulnerability
**Vulnerability:** File creation using `Data.write(to:)` combined with a subsequent `FileManager.default.setAttributes` to secure permissions created a Time-of-Check to Time-of-Use (TOCTOU) vulnerability where the file existed momentarily with default permissions before being locked down.
**Learning:** `Data.write(to:)` creates files using the process's default umask. Restricting permissions after creation leaves a window where unauthorized local users could access or modify the file, which is critical for root-owned temp files or sensitive data.
**Prevention:** Avoid `Data.write(to:)` for sensitive files. Use POSIX `open()` with flags `O_CREAT | O_WRONLY | O_EXCL | O_CLOEXEC` and explicitly specify secure mode permissions (e.g., `0o600`) at the moment of creation. Wrap the resulting file descriptor in a `FileHandle`.

## 2026-05-02 - Insecure File Write TOCTOU Vulnerability via Symlink
**Vulnerability:** `FileHandle(forWritingTo:)` and `String.write(to:atomically:)` follow symlinks by default, making logging susceptible to a Time-of-Check Time-of-Use (TOCTOU) symlink attack.
**Learning:** High-level Swift file writing APIs do not natively protect against malicious symlinks in untrusted directories, potentially allowing unintended files to be overwritten or appended to.
**Prevention:** Always use POSIX `open(2)` with `O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC` to securely refuse symlink traversal, then wrap the resulting file descriptor in a `FileHandle`. Ensure directories are also securely created using `.posixPermissions`.

## 2026-05-03 - TOCTOU Vulnerability via FileManager.setAttributes
**Vulnerability:** Used `FileManager.default.setAttributes` to apply permissions (`0o700`) to the state directory after creation.
**Learning:** High-level Swift APIs like `FileManager.default.setAttributes` operate on string paths and follow symlinks by default. This makes them susceptible to Time-of-Check Time-of-Use (TOCTOU) symlink attacks, similarly to C `chmod()`.
**Prevention:** Avoid `FileManager.default.setAttributes` for securing permissions on directories or sensitive files. Always use `withUnsafeFileSystemRepresentation`, `open()` with `O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC`, and `fchmod()`.
## 2024-05-09 - Missing O_NOFOLLOW in open() Calls
**Vulnerability:** Insecure file creation due to missing O_NOFOLLOW flag.
**Learning:** Using `open()` with `O_CREAT` but without `O_NOFOLLOW` and `O_EXCL` allows an attacker to conduct a TOCTOU symlink attack to truncate or overwrite unintended target files.
**Prevention:** Always combine `O_CREAT` with `O_NOFOLLOW` when creating files, and prefer explicit octal permissions like `0o600` over bitmasks.

## 2024-06-20 - Unsafe Path Bridging in StatusSocket
**Vulnerability:** Calling `open(2)` with raw Swift `String` paths in `StatusSocket.swift` creates an unsafe filesystem representation.
**Learning:** Passing Swift `String` paths implicitly to C functions can result in memory issues or incorrect path resolution if the string is not null-terminated or is moved in memory.
**Prevention:** Always use `URL(fileURLWithPath:).withUnsafeFileSystemRepresentation` to obtain the correct C-string pointer when bridging file paths to POSIX APIs.
## 2024-06-21 - TOCTOU Vulnerability via Data(contentsOf:)
**Vulnerability:** Checked for file existence using `FileManager.default.fileExists(atPath:)` and subsequently read its contents using `Data(contentsOf:)`, which follows symlinks.
**Learning:** High-level Swift APIs like `Data(contentsOf:)` operate on string paths and follow symlinks by default. This creates a TOCTOU (Time-Of-Check Time-Of-Use) window where an attacker could swap the target file for a symlink between the check and read operations.
**Prevention:** Avoid separating file existence checks from read operations. Use a single, secure POSIX `open()` call with `O_RDONLY | O_NOFOLLOW | O_CLOEXEC` to atomically open the file and refuse symlinks, then read from the resulting file descriptor.
