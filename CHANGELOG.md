# Changelog

All notable changes to Cacheout will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.1.7] - 2026-06-20

### Security

- **`DaemonMode` PID file is no longer susceptible to a symlink-swap overwrite.** The daemon created its PID file with `open(O_WRONLY | O_CREAT | O_CLOEXEC)` — without `O_NOFOLLOW`, an attacker with write access to the parent directory could plant a symlink at the PID path and redirect the open to truncate or overwrite an arbitrary file. Now opens with `O_NOFOLLOW` and an explicit `0o600` mode so the kernel refuses to follow a symlink at the final component. (#416)
- **`StatusSocket` POSIX path bridging hardened.** The `open(2)` calls in `StatusSocket.swift` (state-directory hardening and config-validation read) now bridge their paths through `URL(fileURLWithPath:).withUnsafeFileSystemRepresentation` instead of passing Swift `String`s directly, bringing both call sites in line with the project's path-bridging standard. (#417)

### Changed

- **`SysctlJournal` stale-entry and rollback index maps** now build via `reduce(into:)` over `state.entries.indices` instead of incremental `for`-loop mutation. Behavior-preserving cleanup of `revertStaleEntries()` and `performRollback()`. (#414)

### UX / Accessibility

- **Check For Updates button** now carries a `.help()` tooltip that explains why it is disabled when update checking is unavailable (e.g. no appcast), removing ambiguity around the greyed-out control. (#415)

## [2.1.6] - 2026-06-19

### Security

- **`DaemonMode` state-directory permissions are no longer settable via symlink swap.** The daemon hardens its state directory (`~/Library/Application Support/Cacheout` or `--state-dir`) by chmod'ing it to `0o700` after `createDirectory` — but the previous `FileManager.setAttributes(ofItemAtPath:)` follows symlinks, so an attacker with write access to the parent could swap the directory for a symlink between the two calls and redirect the chmod. Now opens the directory with `open(O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)` and applies `fchmod(0o700)` to the resulting descriptor — the kernel can't be tricked into chmod'ing somewhere else. Distinct from v2.1.5's #346, which fixed a different chmod site on the config-reload path. (#410)

### Changed

- **`RecommendationEngine` recommendation loops** now use `for proc in scanResult.processes where condition` instead of `scanResult.processes.filter { ... }.forEach`. Avoids two intermediate array allocations on every recommendation pass — runs on the daemon hot path, so the saving compounds at the long-running-daemon scale. (#407)

### UX / Accessibility

- **Disk-usage bar and MenuBar stat pills** now read as single coherent items in VoiceOver. Added `.accessibilityElement(children: .combine)` at the outermost modifier position on `DiskUsageBar`'s outer frame and on `MenuBarView`'s `statPill` so the entire visible card announces together instead of forcing the user to swipe through each text element. (#409)

## [2.1.5] - 2026-06-16

### Security

- **`DaemonMode` config load no longer susceptible to chmod/read TOCTOU.** The previous path-based `chmod(path, 0o600)` followed by `FileManager.contents(atPath:)` could be redirected by a symlink swap between the two calls — an attacker with write access to the directory could trick the daemon into chmod'ing or reading an arbitrary file. Now opens the config with `open(O_RDONLY | O_NOFOLLOW | O_CLOEXEC)` once, applies `fchmod(0o600)` to the resulting descriptor, and reads via `FileHandle.readToEnd()`. Both the permission change and the read happen on the same fd so the kernel can't be tricked into operating on a substituted path. (#346 — deferred from v2.1.4 due to a release-window merge conflict)

### Changed

- **`CacheoutViewModel.selectedSize`** now uses `scanResults.lazy.filter(\.isSelected)` instead of materializing `selectedResults` to compute a sum — saves the intermediate array allocation on every recomputation.
- **`CacheoutViewModel.hasSelection`** uses `contains(where:)` on both `scanResults` and `nodeModulesItems` instead of comparing `selectedNodeModulesSize > 0`, which previously forced a full `reduce` over `nodeModulesItems` just to check whether *any* item was selected. Now short-circuits on the first match. (#404)

### UX / Accessibility

- **Memory dashboard stat cards** are now read as a single coherent item by VoiceOver. Added `.accessibilityElement(children: .combine)` to the two stat-card views in `MemoryView` so the title and value announce together instead of forcing the user to swipe through each text element separately. (#401)

## [2.1.4] - 2026-06-15

### Security

- **`SysctlJournal` no longer leaves the journal temp file world-readable during the umask window.** The previous `Data.write(to:)` + `setAttributes(0o600)` sequence created the file under the process's default umask before tightening permissions. Now uses POSIX `open(O_CREAT | O_WRONLY | O_EXCL | O_CLOEXEC, 0o600)` so the file is born with the right mode and never observable to other local users. (#396)
- **`CacheCleaner` cleanup log is no longer vulnerable to TOCTOU symlink attacks.** `FileHandle(forWritingTo:)` and the `String.write(to:atomically:)` fallback both follow symlinks. Replaced with `open(O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)`; the log directory is also explicitly created `0o700`. (#391)
- **`StatusSocket` hardened against directory symlink swaps and `validate_config` file swaps.** Directory chmod now uses `open(O_NOFOLLOW | O_DIRECTORY) + fchmod` instead of path-based `setAttributes`. Post-bind verification `lstat`s the socket path and refuses to start if it isn't `S_IFSOCK`. `handleValidateConfig` opens with `O_NOFOLLOW | O_CLOEXEC` once, `fstat`s the fd for type + size, and reads from the fd with a hard byte cap — closes the `lstat → Data(contentsOf:)` window where a swap could bypass the size cap or `S_IFREG` check. (#397)

### Changed

- **Lazy-filter `.count` in MenuBarView and CleanConfirmation** to avoid allocating intermediate arrays just to take a count. Minor allocator pressure win in views that re-render frequently. (#393)

### UX / Accessibility

- **Disabled-state tooltips on MenuBar buttons** (Scan, Quick Clean, Docker Prune) — `.help()` strings explain why each is disabled (in-progress, nothing to clean, etc.) instead of leaving the user to guess. (#379)
- **Docker Prune button** in Settings now shows inline "Pruning…" text alongside the spinner and gets a `.help()` tooltip explaining the action. (#263)
- **`NodeModulesSection` header** announces expanded/collapsed state to VoiceOver via `.accessibilityValue`. (#394)

## [2.1.3] - 2026-05-22

### Fixed

- **Menubar icon now renders correctly on dark and translucent menubars.** v2.1.2 swapped in the master artwork but the icon still read as invisible on dark backgrounds — loose `@1x`/`@2x` PNG pairs loaded via `Bundle.main.image(forResource:)` produce an `NSImage` whose `isTemplate` flag is silently dropped by `NSStatusItem.button`, so AppKit was painting the black master in black on a black menubar. Switched the bundled assets to multi-rep TIFFs (`tiffutil -cathidpicheck`, the same format Xcode's actool emitted for v2.0.0). TIFF-backed `NSImage`s propagate `isTemplate` through to the status button and AppKit tints the icon to match the menubar appearance.

### Changed

- `node_modules` permanent-delete now parallelizes with the same sliding-window `TaskGroup` (max 8) + GCD handoff pattern used by `removeContents(of:)` in #275. Move-to-Trash stays sequential because `trashItem` is `@MainActor` and Finder serializes Trash ops anyway. Per-item failures are isolated — one bad `node_modules` entry no longer poisons the rest of the batch.
- `Tests/CacheoutTests/CacheCleanerTests.swift` added: round-trip tests for the parallel deletion paths (large fan-out, isolated failures, empty-dir no-op, parent-dir preservation, unselected skip).

## [2.1.2] - 2026-05-17

### Fixed

- Menubar icon now uses the correct master artwork. The previous PNGs were a faint outline that effectively rendered invisible at 18×18 in template mode. Re-generated `MenuBarIcon{,@2x,Template,Template@2x}.png` from `Resources/menubar-icon-master.PNG` so the Cacheout "C" actually appears in the menubar.

## [2.1.1] - 2026-05-17

### Fixed

- **Menubar icon now displays again.** The custom `MenuBarIconTemplate.png` resources weren't being copied into `Contents/Resources/` by `scripts/bundle.sh`, so `Bundle.main.image(forResource:)` couldn't find them and the menubar item rendered blank for some users. Bundle script now copies both regular and `@2x` variants for both `MenuBarIcon` and `MenuBarIconTemplate`.
- **Privileged helper daemon is now bundled at `Contents/Library/LaunchDaemons/`.** `scripts/bundle.sh` was not copying the `CacheoutHelper` executable or `com.cacheout.memhelper.plist` into the app, which silently broke the install-helper onboarding flow and `--daemon` autopilot. The helper is now signed before the outer app so `codesign --verify --deep --strict` passes.

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
