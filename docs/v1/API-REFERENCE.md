# API Reference

Complete reference for all public types, methods, and properties in Cacheout v1.

---

## Models

### `RiskLevel`

**File:** `Sources/Cacheout/Models/CacheCategory.swift`

An enum indicating how safe it is to delete a cache category.

```swift
enum RiskLevel: String, CaseIterable {
    case safe = "Safe"
    case review = "Review"
    case caution = "Caution"
}
```

| Case | Description | UI Color |
|------|-------------|----------|
| `.safe` | System auto-rebuilds. No user action needed. | Green |
| `.review` | May require re-download. Generally harmless. | Yellow/Orange |
| `.caution` | Destructive. May lose data permanently. | Red |

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `icon` | `String` | SF Symbol name for the risk level |
| `color` | `String` | Color name string (green/yellow/red) |

---

### `PathDiscovery`

**File:** `Sources/Cacheout/Models/CacheCategory.swift`

Describes how to locate a cache directory on the filesystem.

```swift
enum PathDiscovery: Hashable {
    case staticPath(String)
    case probed(command: String, requiresTool: String?, fallbacks: [String])
    case absolutePath(String)
}
```

| Case | Description | Example |
|------|-------------|---------|
| `.staticPath(String)` | Path relative to `$HOME` | `"Library/Caches/Homebrew"` |
| `.probed(...)` | Dynamic discovery via shell command | `command: "brew --cache"` |
| `.absolutePath(String)` | Absolute filesystem path | `"/tmp/caches"` |

**Probed discovery parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `command` | `String` | Shell command that outputs the cache path to stdout |
| `requiresTool` | `String?` | Binary name checked via `which` before running command |
| `fallbacks` | `[String]` | Static paths tried if the probe fails (home-relative or absolute) |

---

### `CacheCategory`

**File:** `Sources/Cacheout/Models/CacheCategory.swift`

Defines a single cache type with metadata, filesystem paths, and cleanup behavior.

```swift
struct CacheCategory: Identifiable, Hashable {
    let id: UUID
    let name: String
    let slug: String
    let description: String
    let icon: String
    let discovery: [PathDiscovery]
    let riskLevel: RiskLevel
    let rebuildNote: String
    let defaultSelected: Bool
    let cleanCommands: [[String]]?
}
```

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `id` | `UUID` | Auto-generated unique identifier |
| `name` | `String` | Display name (e.g., "Xcode DerivedData") |
| `slug` | `String` | Machine-readable identifier (e.g., "xcode_derived_data") |
| `description` | `String` | Short explanation shown in the UI |
| `icon` | `String` | SF Symbol name for display |
| `discovery` | `[PathDiscovery]` | How to find this category's paths |
| `riskLevel` | `RiskLevel` | Safety classification |
| `rebuildNote` | `String` | What happens after cleaning |
| `defaultSelected` | `Bool` | Whether selected by default on scan |
| `cleanCommands` | `[[String]]?` | Optional argv arrays for cleanup (instead of file deletion), run directly via `/usr/bin/env` — never a shell |

**Computed Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `resolvedPaths` | `[URL]` | Filesystem URLs after resolving all discovery entries |

**Initializers:**

```swift
// Legacy init (static paths only)
init(name:slug:description:icon:paths:[String]:riskLevel:rebuildNote:defaultSelected:)

// Full init (discovery + optional clean commands)
init(name:slug:description:icon:discovery:[PathDiscovery]:riskLevel:rebuildNote:defaultSelected:cleanCommands:)
```

**Static Properties:**

| Property | Type | Source |
|----------|------|--------|
| `allCategories` | `[CacheCategory]` | Defined in `Categories.swift` |

---

### `DiskInfo`

**File:** `Sources/Cacheout/Models/DiskInfo.swift`

Disk space information for the root volume.

```swift
struct DiskInfo {
    let totalSpace: Int64
    let freeSpace: Int64
    let usedSpace: Int64
}
```

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `totalSpace` | `Int64` | Total volume capacity in bytes |
| `freeSpace` | `Int64` | Available space in bytes (important usage) |
| `usedSpace` | `Int64` | Used space in bytes (`total - free`) |
| `usedPercentage` | `Double` | Fraction used (0.0–1.0) |
| `formattedTotal` | `String` | Human-readable total (e.g., "500 GB") |
| `formattedFree` | `String` | Human-readable free (e.g., "120 GB") |
| `formattedUsed` | `String` | Human-readable used (e.g., "380 GB") |

**Static Methods:**

| Method | Returns | Description |
|--------|---------|-------------|
| `current()` | `DiskInfo?` | Read current disk info from root volume. Returns nil on failure. |

---

### `ScanState`

**File:** `Sources/Cacheout/Models/ScanResult.swift`

What a category scan actually established about its tree (D6: a TCC denial
must never read as "0 bytes found").

```swift
enum ScanState: String, Equatable {
    case missing          // No resolved path exists on this machine
    case empty            // Resolved and walked cleanly; nothing there
    case measured         // Fully walked and measured
    case partiallyDenied  // Some bytes measured, parts of the tree denied
    case denied           // Nothing measurable: admission refusal or root-level denial
}
```

---

### `ScanError`

**File:** `Sources/Cacheout/Models/ScanResult.swift`

The classified reason a scan is `denied`/`partiallyDenied`.

```swift
struct ScanError: Equatable {
    enum Kind: Equatable {
        case admissionRefused   // PathGuard refused the root — tree never walked
        case tccDenied          // macOS TCC (privacy) denial — EPERM
        case permissionDenied   // BSD permission denial — EACCES
        case other
    }
    let kind: Kind
    let message: String
}
```

| Member | Type | Description |
|--------|------|-------------|
| `Kind.wireString` | `String` | Stable CLI wire mapping for `scan_error.kind`: `admission_refused`, `tcc_denied`, `permission_denied`, `other`. Hand-written — renaming a case must not silently change the wire format. |
| `ScanError.fullDiskAccessSettingsURL` | `URL` (static) | Deep link to System Settings → Privacy & Security → Full Disk Access — the user-side remedy for TCC denials (also emitted as the CLI `grant_hint`). |

---

### `DiskSpaceCaveat`

**File:** `Sources/Cacheout/Models/ScanResult.swift`

D8 honesty disclosure shown beside every recoverable-bytes total and in the
clean-confirmation sheet.

| Member | Type | Description |
|--------|------|-------------|
| `overcount` | `String` (static) | Discloses both overcount mechanisms: APFS clones (invisible to any public API) and files hardlinked across categories — actual space freed may be less than reported. |

---

### `ScanResult`

**File:** `Sources/Cacheout/Models/ScanResult.swift`

Result of scanning a single cache category, carrying the full scan-state model
and split byte components.

```swift
struct ScanResult: Identifiable {
    let id: UUID
    let category: CacheCategory
    let state: ScanState
    let exactBytes: Int64
    let estimatedUpToBytes: Int64
    let itemCount: Int
    let scanError: ScanError?
    var isSelected: Bool
}
```

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `id` | `UUID` | Same as `category.id` for stable SwiftUI identity |
| `category` | `CacheCategory` | The scanned category definition |
| `state` | `ScanState` | What the scan established (see above) |
| `exactBytes` | `Int64` | Bytes on unique inodes — deletion verifiably frees these |
| `estimatedUpToBytes` | `Int64` | Bytes on hardlinked inodes — freed only if every other link goes too |
| `itemCount` | `Int` | Number of regular files found |
| `scanError` | `ScanError?` | Why the scan is `denied`/`partiallyDenied`; `nil` for clean states |
| `isSelected` | `Bool` | User selection state (mutable) |

**Computed Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `sizeBytes` | `Int64` | Compatibility sum: `exactBytes + estimatedUpToBytes` |
| `exists` | `Bool` | Computed as `state != .missing` (no stored flag) |
| `formattedSize` | `String` | Human-readable `sizeBytes` |
| `isEmpty` | `Bool` | `!exists || sizeBytes == 0` |
| `statusLabel` | `String?` | Presentation label for non-measured states; `nil` for `.measured` (the row shows the category description instead). The four labels are pairwise distinct — "Access denied — not scanned" must never read as "Not found". |

**Selection defaults (init):** `.denied` is unselectable; `.partiallyDenied`
is never auto-selected (its size is a floor, not a promise) but stays manually
toggleable; the clean states auto-select per `category.defaultSelected` when
non-missing and non-zero.

---

### `CleanupReport`

**File:** `Sources/Cacheout/Models/ScanResult.swift`

Summary of a cleanup operation, with split byte components per entry. The
pre-split surface (`cleaned` / `totalFreed` / `formattedTotal`) was retired in
v2.2.0 — every consumer derives from the components.

```swift
struct CleanupReport {
    enum Disposal: Equatable { case permanent, trash }

    struct Entry {
        let category: String
        let exactBytes: Int64
        let estimatedUpToBytes: Int64
        var bytesFreed: Int64        // compatibility sum
        var componentSummary: String // component-derived row text
    }

    let disposal: Disposal
    let entries: [Entry]
    let errors: [(category: String, error: String)]
}
```

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `disposal` | `Disposal` | `.permanent` or `.trash` — rendering must never claim "Freed" for a Trash run |
| `entries` | `[Entry]` | One entry per cleaned category/item; a partially-failed category yields ONE entry carrying only the bytes its successful children measured |
| `entries[].exactBytes` | `Int64` | Measured unique-inode bytes — deletion verifiably freed them |
| `entries[].estimatedUpToBytes` | `Int64` | Hardlinked bytes (freed only if every other link goes too) and command-category bytes (nothing measures what a command frees) |
| `entries[].bytesFreed` | `Int64` | Compatibility sum of the entry components (computed) |
| `entries[].componentSummary` | `String` | Component-derived row text via `componentPhrase` (computed) |
| `errors` | `[(String, String)]` | Failed items with error messages |
| `totalFreedExact` | `Int64` | Pure sum of entry `exactBytes` — no other math |
| `totalEstimatedUpTo` | `Int64` | Pure sum of entry `estimatedUpToBytes` — no other math |
| `headline` | `String` | Mode-driven summary: permanent → "Freed …"; trash → "Moved … to Trash — empty Trash to reclaim"; never a success claim when nothing succeeded |

**Static Methods:**

| Method | Returns | Description |
|--------|---------|-------------|
| `componentPhrase(exact:estimatedUpTo:)` | `String` | The amount phrase all rendering derives from: `"X"` (no estimates), `"X + up to Y more"` (both), `"up to Z"` (exact zero) — estimates are always hedged, never laundered into certainty |

---

### `NodeModulesItem`

**File:** `Sources/Cacheout/Models/NodeModulesItem.swift`

A discovered `node_modules` directory.

```swift
struct NodeModulesItem: Identifiable, Hashable {
    let id: UUID
    let projectName: String
    let projectPath: URL
    let nodeModulesPath: URL
    let sizeBytes: Int64
    let lastModified: Date?
    var isSelected: Bool
}
```

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `projectName` | `String` | Parent directory name (project name) |
| `projectPath` | `URL` | Path to the project root |
| `nodeModulesPath` | `URL` | Path to the node_modules directory |
| `sizeBytes` | `Int64` | Total allocated size in bytes |
| `lastModified` | `Date?` | Modification date of the node_modules directory |
| `isSelected` | `Bool` | User selection state (mutable) |
| `formattedSize` | `String` | Human-readable size |
| `daysSinceModified` | `Int?` | Calendar days since last modification |
| `isStale` | `Bool` | True if >30 days old |
| `staleBadge` | `String?` | Age label (e.g., "3mo old", "1y old") or nil |

---

## Actors

### `CacheScanner`

**File:** `Sources/Cacheout/Scanner/CacheScanner.swift`

Thread-safe scanner that discovers and measures cache categories in parallel.

**Methods:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `scanAll` | `func scanAll(_ categories: [CacheCategory]) async -> [ScanResult]` | Scan all categories concurrently. Returns results sorted by size descending. |
| `scanCategory` | `func scanCategory(_ category: CacheCategory) async -> ScanResult` | Scan a single category. Admits each resolved root before sizing (refusal = scan error, never a walk); returns state, split components, and count. |

Sizing is delegated to `DirectorySizer` (`Sources/Cacheout/Scanner/DirectorySizer.swift`) —
the single sizing routine shared with delete-time measurement.

---

### `NodeModulesScanner`

**File:** `Sources/Cacheout/Scanner/NodeModulesScanner.swift`

Thread-safe scanner that recursively finds `node_modules` directories.

**Methods:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `scan` | `func scan(maxDepth: Int = 6, includeProtectedRoots: Bool = true) async -> NodeModulesScanOutcome` | Scan all search roots for node_modules. Returns discovered items (each carrying `originContainer` provenance) plus classified `NodeModulesScanIssue` errors. With `includeProtectedRoots: false` (automatic/background scans), TCC-prompting roots (Documents / Desktop / Downloads) are skipped so a background rescan never fires a macOS privacy prompt. |

**Search Roots:** Documents, Developer, Projects, Code, Sites, Desktop, Dropbox, repos, src, work

**Skip Directories:** .Trash, .git, .hg, node_modules, .build, DerivedData, Pods, .next, dist, build, Library, .cache, .npm, .yarn

---

### `CacheCleaner`

**File:** `Sources/Cacheout/Cleaner/CacheCleaner.swift`

Thread-safe cleaner that handles guarded file deletion, trashing, freed-bytes
accounting, and cleanup logging. Every deletion target passes `PathGuard`
admission (a `.denied` scan state is refused even when force-selected), and
freed bytes are measured at delete time and settled through the claim-based
`InodeAccountingRegistry` — see [ARCHITECTURE.md](ARCHITECTURE.md) for the
safety model and accounting design.

**Methods:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `clean` | `func clean(results: [ScanResult], nodeModules: [NodeModulesItem] = [], moveToTrash: Bool) async -> CleanupReport` | Clean selected items. Returns a report with split-component entries and errors. |

**Private Methods:**

| Method | Description |
|--------|-------------|
| `runCleanCommand(_:)` | Execute a custom clean command argv directly via `/usr/bin/env` (never a shell) with 30s timeout and restricted `PATH`, after every resolved root passes admission |
| `removeContents(of:)` | Remove all items inside a directory (preserving the directory) |
| `trashItem(_:)` | Move a single item to Trash (`@MainActor`) |
| `trashDirectory(_:)` | Move all contents of a directory to Trash (`@MainActor`) |
| `logCleanup(category:bytesFreed:)` | Append entry to `<home>/.cacheout/cleanup.log` (successes AND refusals) |

---

## View Model

### `CacheoutViewModel`

**File:** `Sources/Cacheout/ViewModels/CacheoutViewModel.swift`

Central `@MainActor` `ObservableObject` managing all application state.

**Published Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `scanResults` | `[ScanResult]` | Current scan results |
| `isScanning` | `Bool` | Whether a scan is in progress |
| `isCleaning` | `Bool` | Whether cleanup is in progress |
| `diskInfo` | `DiskInfo?` | Current disk space info |
| `showCleanConfirmation` | `Bool` | Controls confirmation sheet |
| `showCleanupReport` | `Bool` | Controls report sheet |
| `lastReport` | `CleanupReport?` | Most recent cleanup report |
| `moveToTrash` | `Bool` | Deletion mode preference |
| `nodeModulesItems` | `[NodeModulesItem]` | Discovered node_modules |
| `isNodeModulesScanning` | `Bool` | Whether NM scan is in progress |
| `scanGeneration` | `Int` | Monotonic counter for reactive updates |
| `lastScanDate` | `Date?` | When the last scan completed |
| `scanIntervalMinutes` | `Double` | Auto-scan interval (persisted) |
| `lowDiskThresholdGB` | `Double` | Notification threshold (persisted) |
| `launchAtLogin` | `Bool` | Launch at login preference (persisted) |
| `isDockerPruning` | `Bool` | Whether Docker prune is in progress |
| `lastDockerPruneResult` | `String?` | Docker prune output message |

**Computed Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `selectedResults` | `[ScanResult]` | Currently selected scan results |
| `selectedSize` | `Int64` | Total bytes of selected categories |
| `formattedSelectedSize` | `String` | Human-readable selected size |
| `totalRecoverable` | `Int64` | Total bytes across all non-empty categories |
| `hasResults` | `Bool` | Whether any results exist |
| `hasSelection` | `Bool` | Whether anything is selected |
| `nodeModulesTotal` | `Int64` | Total node_modules bytes |
| `selectedNodeModulesSize` | `Int64` | Selected node_modules bytes |
| `totalSelectedSize` | `Int64` | Combined selected size |
| `shouldAutoRescan` | `Bool` | Whether data is stale |
| `menuBarTitle` | `String` | Free GB for menubar display |

**Methods:**

| Method | Description |
|--------|-------------|
| `scan()` | Run full scan (categories + node_modules in parallel) |
| `clean()` | Clean selected items, show report, then rescan |
| `smartClean()` | Select all safe categories and clean |
| `dockerPrune()` | Run `docker system prune -f` |
| `toggleSelection(for:)` | Toggle a category's selection state |
| `selectAllSafe()` | Select all safe, non-empty categories |
| `deselectAll()` | Deselect all categories and node_modules |
| `toggleNodeModulesSelection(for:)` | Toggle a node_modules item's selection |
| `selectStaleNodeModules()` | Select all node_modules >30 days old |
| `selectAllNodeModules()` | Select all node_modules |
| `deselectAllNodeModules()` | Deselect all node_modules |

---

## Views

### `ContentView`

**File:** `Sources/Cacheout/Views/ContentView.swift`

Main window view with header, disk bar, results list, and bottom toolbar.

**Environment:** `@EnvironmentObject var viewModel: CacheoutViewModel`

### `MenuBarView`

**File:** `Sources/Cacheout/Views/MenuBarView.swift`

Compact 300px menubar popover with disk gauge, stats, top categories, and quick actions.

**Environment:** `@EnvironmentObject var viewModel: CacheoutViewModel`, `@Environment(\.openWindow)`

### `SettingsView`

**File:** `Sources/Cacheout/Views/SettingsView.swift`

Three-tab settings window: General, Cleaning, Advanced.

**Properties:** `updater: SPUUpdater`

### `CategoryRow`

**File:** `Sources/Cacheout/Views/CategoryRow.swift`

Single cache category row with checkbox, icon, name, size, and risk badge.

**Properties:** `result: ScanResult`, `onToggle: () -> Void`

### `RiskBadge`

**File:** `Sources/Cacheout/Views/CategoryRow.swift`

Capsule-shaped risk level indicator.

**Properties:** `level: RiskLevel`

### `NodeModulesSection`

**File:** `Sources/Cacheout/Views/NodeModulesSection.swift`

Collapsible section with node_modules list and batch selection buttons.

### `NodeModulesRow`

**File:** `Sources/Cacheout/Views/NodeModulesSection.swift`

Single node_modules row with checkbox, project name, path, stale badge, and size.

**Properties:** `item: NodeModulesItem`, `onToggle: () -> Void`

### `CleanConfirmationSheet`

**File:** `Sources/Cacheout/Views/CleanConfirmation.swift`

Modal sheet confirming cleanup with itemized list and trash toggle.

### `CleanupReportSheet`

**File:** `Sources/Cacheout/Views/CleanConfirmation.swift`

Modal sheet showing cleanup results with per-category breakdown.

**Properties:** `report: CleanupReport`

### `DiskUsageBar`

**File:** `Sources/Cacheout/Views/DiskUsageBar.swift`

Horizontal progress bar with disk space info and color-coded fill.

**Properties:** `diskInfo: DiskInfo`

### `CheckForUpdatesButton`

**File:** `Sources/Cacheout/Views/CheckForUpdatesButton.swift`

Sparkle update check button that disables when updates aren't available.

**Properties:** `updater: SPUUpdater` (via init)

---

## CLI

### `CLIHandler`

**File:** `Sources/Cacheout/CLIHandler.swift`

See [CLI-REFERENCE.md](CLI-REFERENCE.md) for full command documentation.
