# Architecture

## System Overview

Cacheout follows a layered architecture with clear separation between data models,
business logic (scanning/cleaning), state management, and presentation.

```
┌─────────────────────────────────────────────────────────────┐
│                        Entry Point                          │
│                    main.swift (routing)                      │
├──────────────────────┬──────────────────────────────────────┤
│     GUI Mode         │           CLI Mode                   │
│   CacheoutApp        │         CLIHandler                   │
│   (3 scenes)         │       (JSON output)                  │
├──────────────────────┴──────────────────────────────────────┤
│                    State Management                         │
│              CacheoutViewModel (@MainActor)                 │
├─────────────────────────────────────────────────────────────┤
│                    Business Logic                           │
│    CacheScanner (actor) │ NodeModulesScanner (actor)        │
│    CacheCleaner (actor)                                     │
├─────────────────────────────────────────────────────────────┤
│                     Data Models                             │
│  CacheCategory │ ScanResult │ DiskInfo │ NodeModulesItem    │
│  RiskLevel │ PathDiscovery │ CleanupReport                  │
└─────────────────────────────────────────────────────────────┘
```

## File Organization

```
Sources/Cacheout/
├── main.swift                          # Entry point: CLI vs GUI routing
├── CacheoutApp.swift                   # SwiftUI App struct with 3 scenes
├── CLIHandler.swift                    # Headless CLI handler
├── Models/
│   ├── CacheCategory.swift             # Category definition + path discovery
│   ├── DiskInfo.swift                  # Disk space reading
│   ├── ScanResult.swift                # Scan result + cleanup report
│   └── NodeModulesItem.swift           # node_modules directory info
├── Scanner/
│   ├── CacheScanner.swift              # Parallel category scanner (actor)
│   ├── Categories.swift                # 25+ category definitions
│   ├── DirectorySizer.swift            # Single sizing routine (split components + inode claims)
│   └── NodeModulesScanner.swift        # Recursive node_modules finder (actor)
├── Cleaner/
│   ├── CacheCleaner.swift              # Guarded deletion/trash + InodeAccountingRegistry (actors)
│   ├── FileSystemIdentityProvider.swift # realpath/lstat identity: (st_dev, st_ino), st_nlink, mounts
│   └── PathGuard.swift                 # Deletion/container admission chokepoint (D4)
├── ViewModels/
│   └── CacheoutViewModel.swift         # Central @MainActor view model
├── Views/
│   ├── ContentView.swift               # Main window UI
│   ├── MenuBarView.swift               # Menubar popover UI
│   ├── SettingsView.swift              # Settings window (3 tabs)
│   ├── CategoryRow.swift               # Category list row + risk badge
│   ├── NodeModulesSection.swift        # node_modules section + rows
│   ├── CleanConfirmation.swift         # Confirmation + report sheets
│   ├── DiskUsageBar.swift              # Disk usage progress bar
│   └── CheckForUpdatesButton.swift     # Sparkle update button
└── Resources/
    ├── MenuBarIconTemplate.png         # Menubar icon (template mode)
    └── MenuBarIcon.png                 # Alternative menubar icon
```

## Concurrency Model

Cacheout uses Swift's structured concurrency throughout:

### Actor Isolation

Three actors provide thread-safe business logic:

| Actor | Purpose | Key Methods |
|-------|---------|-------------|
| `CacheScanner` | Parallel category scanning (sizing delegated to `DirectorySizer`) | `scanAll()`, `scanCategory()` |
| `NodeModulesScanner` | Recursive node_modules discovery | `scan(maxDepth:includeProtectedRoots:)` |
| `CacheCleaner` | Guarded deletion, freed-bytes accounting, logging | `clean()`, `runCleanCommand()` |
| `InodeAccountingRegistry` | Per-operation claim-based freed-bytes settlement | `registerObservations(_:)`, `acceptSuccessful(_:)` |

### MainActor

`CacheoutViewModel` is `@MainActor` isolated, ensuring all `@Published` property
updates happen on the main thread for safe SwiftUI binding.

### TaskGroup Parallelism

Both scanners use `withTaskGroup` to scan categories/directories concurrently:

```swift
// CacheScanner.scanAll()
await withTaskGroup(of: ScanResult.self) { group in
    for category in categories {
        group.addTask { await self.scanCategory(category) }
    }
    // Collect results...
}
```

### async let Parallelism

The view model runs both scanners simultaneously:

```swift
// CacheoutViewModel.scan()
async let cacheResults = scanner.scanAll(CacheCategory.allCategories)
async let nmResults = nodeModulesScanner.scan()

scanResults = await cacheResults       // Typically 2-5s
nodeModulesItems = await nmResults     // Typically 10-30s
```

## Data Flow

### Scanning Flow

```
User taps "Scan"
    │
    ▼
CacheoutViewModel.scan()
    │
    ├── async let ──► CacheScanner.scanAll()
    │                     │
    │                     ├── TaskGroup ──► scanCategory(Xcode DerivedData)
    │                     ├── TaskGroup ──► scanCategory(npm Cache)
    │                     ├── TaskGroup ──► scanCategory(...)
    │                     │
    │                     ▼
    │                 [ScanResult] sorted by size desc
    │
    ├── async let ──► NodeModulesScanner.scan()
    │                     │
    │                     ├── TaskGroup ──► findNodeModules(~/Documents)
    │                     ├── TaskGroup ──► findNodeModules(~/Developer)
    │                     ├── TaskGroup ──► findNodeModules(...)
    │                     │
    │                     ▼
    │                 [NodeModulesItem] deduplicated, sorted by size desc
    │
    ▼
@Published updates trigger SwiftUI view refresh
```

### Cleaning Flow

```
User taps "Clean Selected"
    │
    ▼
CleanConfirmationSheet (modal)
    │ User confirms
    ▼
CacheoutViewModel.clean()
    │
    ▼
CacheCleaner.clean(results:nodeModules:moveToTrash:)
    │
    ├── Scan-state refusal: `.denied` refused even if force-selected
    │
    ├── For each selected category:
    │   ├── PathGuard.admitDeletionRoot() — refusal ► errors + log, root skipped
    │   ├── Has cleanCommands? ──► admit every resolved root, then
    │   │                          runCleanCommand() argv via /usr/bin/env
    │   └── No cleanCommands? For each child (validateContainedChild):
    │       ├── measure (.deletionTarget) ──► registerObservations(claims)
    │       ├── moveToTrash? ──► FileManager.trashItem()   (unresolved URL)
    │       │   permanent?   ──► FileManager.removeItem()  (unresolved URL)
    │       └── success ──► acceptSuccessful(token) ──► exact/estimated bytes
    │   └── logCleanup() ──► ~/.cacheout/cleanup.log (successes AND refusals)
    │
    ├── For each selected node_modules:
    │   ├── PathGuard.admitContainer() + validateRemovableItem()
    │   └── measure ► register ► delete ► accept (same two-phase settlement)
    │
    ▼
CleanupReport { disposal, entries: [Entry(exact + estimatedUpTo)], errors }
    │
    ▼
CleanupReportSheet (modal)
    │
    ▼
Auto-rescan to update sizes
```

### Path Discovery Flow

```
CacheCategory.resolvedPaths
    │
    ├── .staticPath("Library/Caches/Homebrew")
    │   └── Check: ~/Library/Caches/Homebrew exists? ──► URL
    │
    ├── .probed(command: "brew --cache", requiresTool: "brew", fallbacks: [...])
    │   ├── which brew ──► exists?
    │   ├── Run "brew --cache" with 2s timeout
    │   ├── Output path exists? ──► URL
    │   └── Fallback: try static fallbacks in order
    │
    └── .absolutePath("/tmp/caches")
        └── Check: /tmp/caches exists? ──► URL
```

## Design Decisions

### Why actors instead of classes with locks?

Swift actors provide compile-time guarantees of data race safety. Since scanning
and cleaning involve shared mutable state (file system operations, result
accumulation), actors eliminate entire categories of concurrency bugs without
manual synchronization.

### Why `totalFileAllocatedSize` instead of file size?

Docker's virtual disk image (`Docker.raw`) is a sparse file that can appear as
60+ GB via `stat` but only consumes 15-20 GB on disk. Using `totalFileAllocatedSize`
reports the actual APFS allocation, giving users accurate space readings.

### Why 60-second timer ticks instead of user's interval?

`Timer.publish(every:)` creates a timer with an immutable interval. Since users
can change the scan interval in Settings, we use 60-second ticks and check
elapsed time against the preference. This avoids recreating the timer on every
settings change.

### Why separate CacheScanner and NodeModulesScanner?

They have fundamentally different search strategies:
- `CacheScanner`: Knows exactly where to look (predefined paths per category)
- `NodeModulesScanner`: Must recursively search unknown project directories

Separating them allows the cache scan to complete quickly (2-5s) while the
node_modules scan continues in the background (10-30s), providing faster
initial results to the user.

### Why a single admission chokepoint (PathGuard)?

Every destructive path — category roots, contained children, node_modules
items, cleanCommands roots — asks `PathGuard` "may I delete this URL?" before
anything runs. Guarding each call site separately is how deletion bugs ship:
one forgotten site is enough. The chokepoint also enforces a deny list that no
policy can override (`/`, volume roots, `$HOME`, protected first-level home
children), checked by inode identity rather than string comparison — three
spellings of `$HOME` share one inode, and `hasPrefix` on paths is not
containment.

### Why category-scoped admission with a sibling rule, not an allowlist of parents?

A category may delete ONLY its own declared roots (static, probed, and
absolute discovery kinds) plus a constrained version drift: a one-component
sibling whose basename matches a declared stem modulo a trailing version
suffix (`store/v11` is admissible when `v10` is declared — cache directories
version-drift), or a pure-version child directly below a declared root
(`store/v10` when `store` is declared — `pnpm store path` reports the
versioned store below its declared fallback, and the child is strictly inside
a root already admissible in full). There is no recursive parent grant: the
parent of `~/Library/Caches/Homebrew` is the whole cache namespace, and the
parent of `~/.npm` is `$HOME`. A probed path is untrusted stdout and passes
the same admission as everything else.

### Why two canonicalization rules?

Roots are resolved fully with `realpath(3)` — a symlink root is judged and
walked by its real location, so an inadmissible target can't hide behind a
link. Deletion-target *leaves* are never resolved: only the deepest existing
ancestor is canonicalized, and deletion uses the unresolved URL — removing a
symlink child deletes the link, never its target.
(`URL.resolvingSymlinksInPath()` is not used for admission decisions: it is
lexically wrong past a symlink and misses `/private` aliasing.)

### Why does DirectorySizer have two modes?

`.scanRoot` (scan time, post-admission: root fully resolved, then enumerated)
and `.deletionTarget` (delete time: `lstat` the leaf FIRST — symlink → 0 bytes
and never walked; regular file → its own allocated size; directory →
enumerated). One routine serves both so scan and clean can never disagree
about what a byte is (D7), and every walk reports split components: exact
unique-inode bytes vs estimated hardlinked bytes.

### Why two signals for volume-root detection?

A mount boundary is detected by BOTH a device-id change AND a `statfs(2)`
mount-root check. A unified APFS volume group presents ONE `st_dev` across `/`
and `/System/Volumes/Data` (the firmlink), so device comparison alone is blind
to exactly the boundary that matters most on modern macOS. The sizer refuses
to cross detected boundaries; the guard refuses cross-device targets.

### Why claim-based two-phase freed-bytes accounting?

Deleting one hardlink frees nothing while other links survive — and the
deletion *decrements* the survivor's `st_nlink`, so classification observed
after a sibling's deletion lies. The `InodeAccountingRegistry` actor
(`Sources/Cacheout/Cleaner/CacheCleaner.swift`) settles this with two atomic
methods: `registerObservations(_:) -> RegisteredChild` records claims
(canonical byte value + hardlink classification, sticky once observed
hardlinked by anyone) immediately after measurement and BEFORE deletion;
`acceptSuccessful(_:) -> AcceptedByteComponents` transfers each claimed
inode's canonical bytes exactly once, only after successful deletion. Failed
deletions accept nothing, but their registrations remain for successful
siblings to transfer — no ordering of measure/delete/fail across children can
double-count, lose, or reclassify bytes. Hardlinked bytes are always reported
as estimates, never exact.

### Why no Core Data or SQLite?

Scan results are ephemeral — they reflect current filesystem state and become
stale quickly. Persisting them would add complexity without benefit. The only
persisted data is user preferences (UserDefaults) and cleanup history
(append-only log file).

## Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.9.0 | Auto-update framework for macOS apps |

Sparkle is the only external dependency. It's initialized with `startingUpdater: false`
to defer update checks until a signed appcast URL is configured in Info.plist.

## Security Model

- **No admin privileges**: Only accesses user-space directories (`~/Library/`, `~/.`)
- **No network access**: No analytics, telemetry, or phoning home
- **PathGuard admission on every destructive path**: category roots, contained
  children, node_modules items, and cleanCommands roots are admitted against
  category-scoped policies plus an inode-identity deny list (`/`, volume
  roots, `$HOME`, protected first-level home children) before anything is
  deleted; the parent chain is re-validated immediately before each
  destructive call, and refusals are reported and logged
- **TCC-respecting scans**: privacy-protected roots (Documents / Desktop /
  Downloads) are enumerated only on user-initiated scans, with usage strings
  in the Info.plist; the CLI surfaces denials as `scan_error` + `grant_hint`
  instead of reading zero
- **Sandboxed shell commands**: Probe commands run with a restricted PATH and 2s timeout
- **Clean commands**: argv arrays run directly via `/usr/bin/env` (never a shell) with 30s timeout and restricted PATH, after every resolved root passes admission
- **Notification guard**: UNUserNotificationCenter calls guarded by bundleIdentifier check
