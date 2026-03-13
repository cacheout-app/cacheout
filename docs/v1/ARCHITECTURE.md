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
│   └── NodeModulesScanner.swift        # Recursive node_modules finder (actor)
├── Cleaner/
│   └── CacheCleaner.swift              # File deletion/trash handler (actor)
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
| `CacheScanner` | Parallel category scanning | `scanAll()`, `scanCategory()`, `directorySize()` |
| `NodeModulesScanner` | Recursive node_modules discovery | `scan()`, `findNodeModules()` |
| `CacheCleaner` | File deletion and logging | `clean()`, `runCleanCommand()` |

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
    ├── For each selected category:
    │   ├── Has cleanCommand? ──► runCleanCommand() via /bin/bash
    │   └── No cleanCommand?
    │       ├── moveToTrash? ──► FileManager.trashItem()
    │       └── permanent?   ──► FileManager.removeItem()
    │   └── logCleanup() ──► ~/.cacheout/cleanup.log
    │
    ├── For each selected node_modules:
    │   ├── moveToTrash? ──► FileManager.trashItem()
    │   └── permanent?   ──► FileManager.removeItem()
    │   └── logCleanup()
    │
    ▼
CleanupReport { cleaned: [...], errors: [...] }
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
- **Sandboxed shell commands**: Probe commands run with a restricted PATH and 2s timeout
- **Clean commands**: Run with 30s timeout and restricted PATH
- **Notification guard**: UNUserNotificationCenter calls guarded by bundleIdentifier check
