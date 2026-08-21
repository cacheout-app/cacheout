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
│  SpaceScannerRuntime (registry + validated scan stream)     │
│    CategoryScanner ──► CacheScanner (actor)                 │
│    BuildArtifactsScanner │ OrphanedCachesScanner            │
│    EphemeralTempScanner                                     │
│    CacheCleaner (actor)                                     │
├─────────────────────────────────────────────────────────────┤
│                     Data Models                             │
│  ReclaimableItem │ ItemKey │ ScanOutcome │ ScanIssue        │
│  CacheCategory │ ScanResult │ DiskInfo │ CleanupReport      │
│  RiskLevel │ PathDiscovery │ ReclaimAction │ ValuablesDisclosure│
└─────────────────────────────────────────────────────────────┘
```

Every space scanner — the category registry (via the `CategoryScanner`
adapter) and every per-item scanner — implements one `SpaceScanner` protocol
and registers with the `SpaceScannerRuntime`. Scanners emit `ReclaimableItem`s,
the one currency the GUI, CLI, and cleaner all consume.

## File Organization

```
Sources/Cacheout/
├── main.swift                          # Entry point: CLI vs GUI routing
├── CacheoutApp.swift                   # SwiftUI App struct with 3 scenes
├── CLIHandler.swift                    # Headless CLI handler
├── Models/
│   ├── CacheCategory.swift             # Category definition + path discovery
│   ├── DiskInfo.swift                  # Disk space reading
│   └── ScanResult.swift                # Scan result + cleanup report
├── Scanner/
│   ├── CacheScanner.swift              # Parallel category scanner (actor)
│   ├── Categories.swift                # Category definitions (data-driven registry)
│   ├── CategoryScanner.swift           # SpaceScanner adapter over the category registry
│   ├── DirectorySizer.swift            # Single sizing routine (split components + inode claims)
│   ├── ProjectTreeWalker.swift         # Reusable consumer-prunable dev-root walker
│   ├── BuildArtifactRules.swift        # Build-artifact rule table + dev-roots store/policy
│   ├── BuildArtifactsScanner.swift     # Project build-artifact scanner (SpaceScanner)
│   ├── ValuablesDetector.swift         # Release-artifact probe + acknowledgement tokens
│   ├── OrphanedCachesScanner.swift     # First-level ~/Library/Caches sweep (SpaceScanner)
│   ├── EphemeralTempRoots.swift        # confstr-resolved temp roots + their sweep config
│   ├── EphemeralTempScanner.swift      # First-level ephemeral temp sweep (SpaceScanner)
│   └── SpaceScanner.swift              # SpaceScanner protocol, ReclaimableItem model, SpaceScannerRuntime
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
│   ├── ScannerItemSection.swift        # Generic per-item scanner section + rows
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

These actors provide thread-safe business logic:

| Actor | Purpose | Key Methods |
|-------|---------|-------------|
| `CacheScanner` | Parallel category scanning (sizing delegated to `DirectorySizer`) | `scanAll()`, `scanCategory()` |
| `BuildArtifactsScanner` | Project build-artifact discovery over the dev roots (a `SpaceScanner`; a value type, listed here beside its peers) | `scan(context:)`, `preDeleteRevalidator` |
| `EphemeralTempScanner` | Stale first-level entries in the three ephemeral temp roots (a `SpaceScanner`; a value type, listed here beside its peers). Runs on user-initiated scans only | `participates(in:)`, `scan(context:)`, `preDeleteRevalidator` |
| `CacheCleaner` | Guarded deletion, freed-bytes accounting, logging | `clean(items:moveToTrash:)`, `runCleanCommand()` |
| `InodeAccountingRegistry` | Per-operation claim-based freed-bytes settlement | `registerObservations(_:)`, `acceptSuccessful(_:)` |

(`CategoryScanner` and `SpaceScannerRuntime` are value types — the runtime
owns orchestration, not state.)

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

### Runtime-Owned Scan Orchestration

The top-level scan `TaskGroup` lives inside
`SpaceScannerRuntime.scanValidated(scannerIDs:context:)`, which returns a
progressive `AsyncStream<ValidatedScannerEvent>`:

```swift
// CacheoutViewModel.scan(trigger:)
let stream = runtime.scanValidated(
    context: ScanContext(trigger: trigger)
)
for await event in stream {
    handle(event)   // reconcile one scanner's validated outcome
}
```

Registered scanners run in parallel across the group (and stay internally
parallel as above); each outcome is ownership- and structure-validated before
it is yielded, and events arrive in completion order. That is the
progressive-publishing contract: category results appear in seconds
(typically 2-5s) while the dev-root project walk keeps running (10-30s). The
ViewModel consumes events as they arrive; the CLI collects the same stream to
completion. Consumers pick scope (a scanner subset and/or a category filter),
never validation.

## Data Flow

### Scanning Flow

```
User taps "Scan"
    │
    ▼
CacheoutViewModel.scan(trigger:)
    │
    ▼
SpaceScannerRuntime.scanValidated(context:)
    │
    ├── TaskGroup ──► CategoryScanner.scan(context:)
    │                     │ delegates to CacheScanner.scanAll()
    │                     │ (internally parallel per category)
    │                     ▼
    │                 ScanOutcome — one aggregate ReclaimableItem per category
    │
    ├── TaskGroup ──► BuildArtifactsScanner.scan(context:)
    │                     │ (walk → rule match → prune → dedupe → size)
    │                     ▼
    │                 ScanOutcome — one ReclaimableItem per artifact dir
    │
    ▼
validatedOutcome() per event: ownership, id uniqueness, structural invariants
(a malformed outcome is replaced by a path-less `malformed_outcome` issue)
    │
    ▼
AsyncStream<ValidatedScannerEvent> — events yield in completion order
    │
    ▼
ViewModel reconciles each event: defaultSelected applies only to first-ever
emissions; prior selections AND deselections survive by ItemKey
    │
    ▼
@Published updates trigger SwiftUI view refresh
```

### Cleaning Flow

```
User taps "Clean Selected"
    │
    ▼
CleanConfirmationSheet (modal — unified per-item rows, each with evidence)
    │ User confirms
    ▼
CacheoutViewModel.clean()
    │
    ▼
CacheCleaner.clean(items:moveToTrash:)        ◄── selected [ReclaimableItem]
    │
    ├── (1) Structural refusal FIRST, every item, every state:
    │       action/descriptor/provenance compatibility — the chokepoint never
    │       assumes runtime validation ran
    ├── (2) Well-formed `.missing` skip (no entry, no error)
    ├── (3) Non-`.missing` zero-root-record refusal
    ├── (4) State eligibility: `.denied` refused even when selected;
    │       `.empty` no-op; `.commands` zero-measured skip
    │
    ├── (5) Dispatch on ReclaimAction:
    │   ├── .removeContents (category aggregates):
    │   │   ├── admit each `.measured` RootScanRecord.requestedURL
    │   │   │   (PathGuard.admitDeletionRoot, category policy)
    │   │   └── per child (validateContainedChild):
    │   │       measure (.deletionTarget) ► registerObservations(claims)
    │   │       ► trash/remove (unresolved URL) ► acceptSuccessful(token)
    │   ├── .commands (Simulator Devices):
    │   │   ├── re-admit EVERY record's requestedURL — ANY refusal blocks
    │   │   │   the ENTIRE command set
    │   │   └── runCleanCommand() argv via /usr/bin/env
    │   └── .removeItem (per-item scanners, e.g. build_artifacts):
    │       ├── per-scanner pre-delete revalidation (fail-closed) when the
    │       │   item is marked — release-artifact re-inspection lives here
    │       ├── PathGuard.admitContainer() against the RUNTIME's declared
    │       │   roots (never the item's claim) + validateRemovableItem()
    │       └── measure ► register ► delete ► accept (same settlement)
    │
    └── logCleanup() ──► ~/.cacheout/cleanup.log (successes AND refusals)
    │
    ▼
CleanupReport { disposal, entries (itemID/scannerID/displayName + split
                components), errors: [ItemError], scannerRollups derived }
    │
    ▼
CleanupReportSheet (modal, per-scanner sections)
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

### Why a registry of protocol conformers instead of a third bespoke stack?

Cacheout used to have two parallel scanning stacks: the data-driven
`CacheCategory` aggregate registry and a bespoke node_modules scanner (own
item model, own views, own cleaner branch — and absent from the CLI
entirely). The per-item scanners (build artifacts, orphaned caches,
ephemeral temp files, and git worktrees still to come) are all per-item by
nature; replicating that pattern for
each would mean ~6 touch-points per scanner and guaranteed drift — the
pre-unification CLI gap (node_modules was never wired into the CLI at all)
is the proof. The bespoke scanner has since been subsumed by
`BuildArtifactsScanner`, whose `node_modules/` rule row covers everything it
found, and its source deleted.

Instead, every scanner implements the `SpaceScanner` protocol and registers
with `SpaceScannerRuntime`; selection, totals, cleaning, and rendering are
written ONCE against `ReclaimableItem`. Adding a scanner = implement the
protocol + register — zero edits to the ViewModel, cleaner, CLI, or views.
Aggregate categories stay data-driven behind the `CategoryScanner` adapter,
so the cheap one-line-category path is preserved.

Registration is also the trust boundary: the runtime derives the cleaner's
container-root admission from the union of what registered scanners DECLARE
(`trustedContainerRoots`), and scan outcomes are ownership- and
structure-validated fail-closed before any surface can address them — an
item's claimed provenance can never widen admission, and a malformed
scanner's items cannot be listed, selected, addressed, or deleted through
any path.

### Why separate CacheScanner and the project scanners?

They have fundamentally different search strategies:
- `CacheScanner`: Knows exactly where to look (predefined paths per category)
- `BuildArtifactsScanner`: Must walk unknown project trees under the
  configured dev roots and PROVE each find with an ecosystem marker

Both now sit behind the `SpaceScanner` protocol (`CacheScanner` via the
`CategoryScanner` adapter), but the split survives: the runtime's event
stream yields each scanner's outcome as it completes, so the cache scan
lands quickly (2-5s) while the dev-root project walk continues (10-30s),
providing faster initial results to the user.

### Why a single admission chokepoint (PathGuard)?

Every destructive path — category roots, contained children, per-item
scanner targets, cleanCommands roots — asks `PathGuard` "may I delete this
URL?" before
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

Full `realpath(3)` resolution is used where the result feeds a **deny check**
— `admitDeletionRoot`, `matchConfiguredRoot`, alias-shadow keys — so an
inadmissible target can't hide behind a link, and two spellings of one
location collapse onto one comparison value.

It is **not** used where the result becomes a **trusted container root**.
There, only the deepest existing ancestor is canonicalized and the leaf is
appended unresolved (`resolveTargetKeepingLeaf`). The deny list refuses `/`,
volume roots and `$HOME` itself, but not their children — `~/Documents` is a
legal container — so resolving a symlink leaf would register the link's
destination as a trusted root and admit an arbitrary directory. Keeping the
leaf means the declared spelling stays the link, which the scanners' no-follow
(`lstat`) root gates see and refuse with a visible `symlinkRoot` issue, and
which `ContainerSnapshot.capture` binds by the link's own identity at delete
time. On stock macOS the two rules agree for every shipped root: the symlinks
into `/var/folders/…/{C,T}` are ancestors (`/var` → `private/var`), which the
parent chain still resolves.

Deletion-target *leaves* follow the same rule and for the same reason:
deletion uses the unresolved URL, so removing a symlink child deletes the
link, never its target. (`URL.resolvingSymlinksInPath()` is not used for
admission decisions: it is lexically wrong past a symlink and misses
`/private` aliasing.)

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

- **No admin privileges**: everything runs as the invoking user, with no
  helper and no elevation on any scan or clean path. The reach is user-space
  caches (`~/Library/`, `~/.`), the configured dev roots, and — since the
  ephemeral temp scanner — the world-writable `/private/tmp` plus this
  user's own `…/T` and `…/C` containers under `/private/var/folders`. Those
  temp roots are read only on user-initiated scans, and an entry another
  user owns is never listed (sticky-directory rules make it undeletable, so
  claiming its bytes would be a lie)
- **No network access**: No analytics, telemetry, or phoning home
- **PathGuard admission on every destructive path**: category roots, contained
  children, per-item scanner targets, and cleanCommands roots are admitted against
  category-scoped policies plus an inode-identity deny list (`/`, volume
  roots, `$HOME`, protected first-level home children) before anything is
  deleted; the parent chain is re-validated immediately before each
  destructive call, and refusals are reported and logged
- **Registration-derived container admission**: delete-time container roots
  for per-item scanners come from the union the registered scanners DECLARE
  (`SpaceScannerRuntime.trustedContainerRoots`), never from scanned items — a
  buggy or hostile item claiming a novel container gains nothing; scan
  outcomes are additionally ownership- and structure-validated fail-closed
  before any surface can address their items, and the cleaner independently
  refuses the same malformed shapes at dispatch (defense in depth)
- **TCC-respecting scans**: privacy-protected roots (Documents / Desktop /
  Downloads) — and the ephemeral temp roots, which are same-user-writable and
  therefore cannot honor the background no-prompt guarantee — are enumerated
  only on user-initiated scans, with usage strings
  in the Info.plist; the CLI surfaces denials as `scan_error` + `grant_hint`
  instead of reading zero
- **Sandboxed shell commands**: Probe commands run with a restricted PATH and 2s timeout
- **Clean commands**: argv arrays run directly via `/usr/bin/env` (never a shell) with 30s timeout and restricted PATH, after every resolved root passes admission
- **Notification guard**: UNUserNotificationCenter calls guarded by bundleIdentifier check
