# Changelog

All notable changes to Cacheout will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.2.0] - 2026-08-06

Disk-path safety hardening (D1–D8). Breaking CLI release: `schema_version` is
now 3 and destructive commands require `--confirm`. Coordinate MCP updates with
`cacheout-mcp` (see PROTOCOL.md and docs/v1/CLI-REFERENCE.md).

### Changed

- **BREAKING: `--cli clean` and `--cli smart-clean` require `--confirm`.** An
  unconfirmed, non-dry-run invocation deletes nothing: stdout is empty, the exit
  code is 1, and stderr carries a `CONFIRMATION_REQUIRED` error whose
  `details.plan` lists the same per-category decisions the confirmed run would
  take (`clean`, `clean_with_warning`, `refuse`, `skip`, and — smart-clean only —
  `clean_if_needed` for eligible fallback candidates past the projected
  target-met point). Preview with `--dry-run` (non-destructive,
  schema-compatible stdout, no `--confirm` needed). `schema_version` bumps
  2 → 3; there is no environment-variable bypass.
- **BREAKING: clean totals are split by certainty.** `total_freed_bytes` now
  sums exact bytes only (unique-inode bytes whose deletion verifiably freed
  them); the additive `total_estimated_up_to_bytes` carries hardlinked and
  command-freed bytes that MAY be freed. Per-entry `exact_bytes` /
  `estimated_up_to_bytes` components replace the single mixed number, and
  `results[].category` now carries the slug (v2 emitted the display name).
- **Exit-code policy (schema 3).** A clean where every item failed exits 1 with
  `CLEAN_FAILED`; a partial clean stays exit 0 and reports per-item `success`
  flags. Running destructive commands as root is refused outright
  (`ROOT_REFUSED`).
- **`smart-clean` validates its target strictly.** An absent target still
  defaults to 5 GB, but a *present* target that is non-numeric, non-finite,
  non-positive, over 10^9, or too small to convert to a whole byte is an
  `INVALID_ARGUMENTS` error — malformed input is never silently defaulted.
- **Sizes are bigger — and truthful.** Sizing no longer skips package
  descendants or hidden files, so `.app`/bundle contents and dot-directories
  now count (D2/D3). Xcode DerivedData and Simulator categories in particular
  report larger, accurate totals, and unreadable subtrees are recorded instead
  of silently skipped.

### Added

- **PathGuard + FileSystemIdentityProvider (D4).** Every deletion root,
  contained child, cleanCommand root, and node_modules item passes a single
  admission chokepoint before anything is removed: category-scoped root
  admission with a constrained version-drift rule (one-component sibling or
  pure-version child of a declared root), a deny list
  (`/`, volume roots, `$HOME`, protected first-level home children),
  inode-identity checks, two-signal mount-boundary detection, and cross-device
  refusal. Refusals are reported and logged, never silently skipped.
- **Scan states + visible failures (D6).** Scan JSON entries carry `state`
  (`missing` / `empty` / `measured` / `partiallyDenied` / `denied`) and
  `scan_error` (`{kind, message}`); TCC denials additionally carry `grant_hint`
  with the Full Disk Access remedy, because macOS denies a CLI process
  silently. The cleaner refuses a `denied` category even when named explicitly;
  `partiallyDenied` proceeds with a warning and measured bytes only.
- **Split byte components end-to-end.** Scan entries expose `exact_bytes` /
  `estimated_up_to_bytes` (`size_bytes` retained as their sum); clean entries
  and dry-run plans reuse the same components; smart-clean target math consumes
  scan-time exact components only, so estimates never advance `target_met`.
- **Overcount disclosure.** Recoverable-bytes totals and the clean-confirmation
  sheet disclose that APFS clones and files hardlinked across categories can
  make actual freed space less than reported.
- **TCC usage strings.** `NSDocumentsFolderUsageDescription`,
  `NSDesktopFolderUsageDescription`, and `NSDownloadsFolderUsageDescription`
  ship in all three build paths (bundle.sh heredoc, Info.plist, project.yml).
  Protected roots (Documents / Desktop / Downloads) are enumerated only on
  user-initiated scans, so a background rescan never fires a macOS privacy
  prompt.
- **`spotlight` pre-write admission gate.** The Spotlight rebuild command
  admits its target before any write and reports a `refused` array instead of
  touching unadmitted paths.

### Fixed

- **Freed-bytes over-report (D1).** Freed bytes were assumed from pre-scan
  totals even when deletion partially failed. Every deletion target is now
  measured immediately before deletion and settled through claim-based
  two-phase inode accounting: only successfully deleted bytes are reported,
  hardlinked bytes are always estimates, and command categories report exact 0
  plus an estimated pre-scan size (nothing measures what a command frees).
- **Silent scan failures (D6).** A TCC or permission denial used to read as
  "0 bytes found" — indistinguishable from an empty cache. Denials now surface
  as distinct states in the GUI ("Access denied — not scanned", with a System
  Settings link) and in CLI JSON (`denied` state + `scan_error`).
- **Hidden-directory discovery.** The node_modules scanner no longer skips
  hidden directories (a 23 GB hidden-worktrees field case), still bounded by
  the skip list and recursion depth limit.
- **Hardlink double-count (within walk).** Hardlinked inodes are deduplicated
  within each category walk and reported as estimated bytes instead of being
  counted once per link. Cross-category hardlinks remain disclosed via the
  overcount caveat (D8 is mitigated, not closed — cross-walk accounting is
  deferred to the scanner-expansion epic).

## [2.1.9] - 2026-07-20

### Fixed

- **`--cli memory-stats` and `--cli recommendations` no longer hang.** CLI mode parked the main thread on a `DispatchSemaphore` and never drained the main dispatch queue, so the `MainActor.run` hop inside `MemoryMonitor.start()` could never execute — a mutual deadlock present since v2.0.0. CLI mode now uses the same `dispatchMain()` pattern as daemon mode.
- **`--cli version` reports the real app version.** The handler emitted a hardcoded `"2.0.0"`; it now reads `CFBundleShortVersionString` (stamped from the `VERSION` file by `bundle.sh`), with a compiled fallback for unbundled binaries.
- **`--cli install-helper` works on a first-time install.** Modern macOS reports `SMAppService.Status.notFound` for a daemon that has simply never been registered (no BackgroundTaskManagement record), even when the helper plist is embedded — the CLI treated that as "plist missing" and refused to call `register()`, so a first install could never succeed. The status check now verifies the embedded plist on disk and treats "plist present, no BTM record" as not-registered. Additionally, when invoked via the Homebrew symlink (`/opt/homebrew/bin/cacheout`), the process re-execs through the resolved bundle binary so `Bundle.main` points at the real app bundle.
- **`--daemon` startup failures are no longer silent.** State-directory hardening failures, PID-lock conflicts, and status-socket errors printed only to the unified log and exited 1 with no terminal output; they now emit actionable messages to stderr — including a hint when the socket path exceeds the 104-byte `sockaddr_un` limit.
- **`--cli clean` rejects unknown slugs.** Unknown category slugs previously produced a silent empty success; they now return an `INVALID_ARGUMENTS` error naming the bad slug(s). Documented in PROTOCOL.md.

## [2.1.8] - 2026-07-20

### Security

- **`SysctlJournal.loadState` no longer susceptible to a check/read symlink swap.** The journal load used `FileManager.fileExists` followed by `Data(contentsOf:)` — both path-based and symlink-following, leaving a TOCTOU window where an attacker with write access to the state directory could swap in a symlink and have the helper read an arbitrary file. Now opens once with `open(O_RDONLY | O_NOFOLLOW | O_CLOEXEC)` and reads from the descriptor. (#445)
- **`CacheCleaner.logCleanup` writes are anchored to a verified directory descriptor.** The `~/.cacheout` log directory is now opened with `O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC` and hardened with `fchmod(0o700)`, and `cleanup.log` is created via `openat` relative to that same descriptor — so a rename/symlink swap of the directory between verification and append can no longer redirect the log write. (#423)
- **POSIX permission calls now fail closed.** The `fchmod` in `DaemonMode.loadConfig` and the defense-in-depth `fchmodat` in `StatusSocket.start()` had their return values ignored — a silent failure left the file at its prior mode. Both are now checked and abort their operation (nil config / socket teardown + throw) on failure. (#422)
- **`StatusSocket` `fchmodat` and `SysctlJournal` `rename(2)` bridge paths safely.** Both call sites now pass their paths through `URL(fileURLWithPath:).withUnsafeFileSystemRepresentation` instead of implicit Swift `String` bridging, in line with the project's path-bridging standard. (#433, #444)
- **`SysctlJournal.flushState` temp-file open adds `O_NOFOLLOW`.** Defense-in-depth alongside the existing `O_CREAT | O_EXCL`, which already refuses symlinks at the final component. (#427)

### Changed

- **High-growth process detection is now a reusable predicate.** `PredictiveEngine.detectHighGrowthProcesses(from:)` became `isHighGrowthProcess(_:)`, the `high_growth_process` recommendation loop uses `for-where` instead of building an intermediate filtered array, and the dead `AgentDetector.agentProcesses(from:)` was removed. Tests updated to exercise the new surface. (#440)
- **`MenuBarView.topCategories` drops a pointless `.lazy`.** Sorting materializes the sequence anyway; filtering eagerly first is clearer and no slower. (#420)

### UX / Accessibility

- **Empty states read as one coherent announcement in VoiceOver.** Added `.accessibilityElement(children: .combine)` to the empty-state stacks in `ContentView`, `NodeModulesSection`, and `ProcessesView`, so the icon and explanatory text announce together instead of as disjointed swipe stops. (#419)
- **Clean-confirmation rows announce coherently.** The caption rows in `CleanConfirmationSheet` (selected results, node_modules items) and `CleanupReportSheet` (cleaned entries) are combined into single accessibility elements. (#418)

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
