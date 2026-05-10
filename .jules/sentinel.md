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
