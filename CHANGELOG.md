# Changelog

All notable changes to Cacheout will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.1.0] - 2026-05-17

### Added

- Sparkle.framework now bundled inside `Cacheout.app/Contents/Frameworks/` with the correct `@executable_path/../Frameworks` rpath — future releases can auto-update via Sparkle without manual reinstall.
- Inner XPC services (`Downloader.xpc`, `Installer.xpc`), `Updater.app`, and `Autoupdate` are re-signed in the correct inner→outer order with `--options runtime`; `Downloader.xpc` re-signs preserve entitlements for Sparkle 2.6+ sandbox compatibility.
- `./scripts/bundle.sh --notarize` (and `--release` alias) now runs the full pipeline: build, sign, DMG, notarize, staple.
- Dynamic button labels on the Scan/Clean buttons (`Scanning…` / `Cleaning…`) with `.help()` tooltips explaining disabled states.
- `.help()` tooltip on the per-process ellipsis menu in the Processes view.
- Visual empty state for the node_modules section (centered icon + callout, replacing the plain text).
- Accessibility labels on icon-only controls so VoiceOver reads meaningful names instead of "Button".
- Empty state for the Processes view.

### Changed

- `runCleanCommand` in `CacheoutViewModel` now reads the process pipe before calling `waitUntilExit()`, eliminating a deadlock when `docker system prune` output exceeds the ~64KB pipe buffer.
- `JetsamHWM` priority map now built with `reduce(into:)` instead of a mutating for-loop, removing copy-on-write overhead.
- `ProcessMemoryScanner` uses a sliding-window TaskGroup for bounded concurrency.
- Scanner TaskGroups marked `nonisolated` so subtasks actually parallelize off the actor executor.
- Shared `ByteCountFormatter` / `ISO8601DateFormatter` instances instead of per-call allocations; `.lazy.filter` before `.reduce` to avoid intermediate arrays.
- Batched `@Published` array mutations to a single assignment so SwiftUI re-renders once per scan.
- `CacheScanner` enumerator now prefetches `.isRegularFileKey` so `URL.resourceValues` avoids a fallback `stat()` per file.
- `NodeModulesScanner` is now truly concurrent and issues fewer syscalls.
- Blocking I/O (process waits, `URLResourceValues` reads) is now offloaded via `Task.detached` so async @MainActor methods no longer stall the UI.
- `runningApplications` filtered with `.lazy` to skip an intermediate array allocation.

### Fixed

- Webhook URLs are now validated as `https` in both `AutopilotConfigValidator` and `WebhookConfig.parse`. `http://` webhooks are rejected.
- PID lock acquisition in daemon mode now opens with `O_CLOEXEC` and uses `withUnsafeFileSystemRepresentation`, preventing the lock fd from leaking into child processes.
- Defense-in-depth fix for process pipe deadlock during process execution (reads pipes before/concurrently-with `waitUntilExit()`).
- Command injection vulnerability in `runCleanCommand`: shell strings replaced with `Foundation.Process` + arguments array.
- Command injection in `CacheCategory.toolExists`: `/bin/bash -c` interpolation replaced with `/usr/bin/env <tool>` invocation, restoring the explicit `PATH`/`HOME` environment so the macOS GUI launch context resolves Homebrew tools correctly.
- Docker pruning refactored to use `/usr/bin/env docker` instead of hardcoded `/usr/local/bin/docker` so Apple Silicon `/opt/homebrew/bin` users actually run it.
- Guard against empty arguments in `runCleanCommand`.
- Process names no longer display as "unknown" in the main process list.

## [1.0.0] - 2026-01-01

### Added

- Initial release
- 25+ cache categories: Xcode, Docker, npm, Yarn, pnpm, Bun, Homebrew, pip, uv, Gradle, CocoaPods, Swift PM, Playwright, VS Code, Electron, browser caches, ChatGPT Desktop, Prisma, TypeScript, node-gyp, PyTorch Hub
- Recursive node_modules finder with staleness detection (30d+)
- Risk-level indicators (Safe / Review / Caution)
- Async parallel scanning via Swift actors and TaskGroups
- Sparse file awareness (accurate Docker disk image sizing)
- Move to Trash option (recoverable deletion)
- Cleanup logging to `~/.cacheout/cleanup.log`
- Main window with full cache management UI
- Menubar popover with disk gauge and quick clean
- Settings window with scan interval, low-disk threshold, and Docker prune
- CLI mode (`--cli`) with scan, clean, smart-clean, disk-info, and spotlight commands
- Dry-run support for CLI clean commands
- Smart clean: auto-select safe categories until target GB freed
- Spotlight tagging for cache directory discovery
- Custom clean commands (e.g., simulator device cleanup via `xcrun simctl`)
- Probed path discovery (dynamic cache location via shell commands)
- Low-disk notifications with 1-hour throttle
- Customizable scan interval (15min–4h)
- Sparkle framework integration for future auto-updates
- Custom menubar icon with disk-full warning badge
- Homebrew formula
- DMG installer with custom background
- Watchdog scripts for background monitoring
