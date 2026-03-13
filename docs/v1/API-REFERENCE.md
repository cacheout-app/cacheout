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
    let cleanCommand: String?
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
| `cleanCommand` | `String?` | Optional shell command for cleanup (instead of file deletion) |

**Computed Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `resolvedPaths` | `[URL]` | Filesystem URLs after resolving all discovery entries |

**Initializers:**

```swift
// Legacy init (static paths only)
init(name:slug:description:icon:paths:[String]:riskLevel:rebuildNote:defaultSelected:)

// Full init (discovery + optional clean command)
init(name:slug:description:icon:discovery:[PathDiscovery]:riskLevel:rebuildNote:defaultSelected:cleanCommand:)
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

### `ScanResult`

**File:** `Sources/Cacheout/Models/ScanResult.swift`

Result of scanning a single cache category.

```swift
struct ScanResult: Identifiable {
    let id: UUID
    let category: CacheCategory
    let sizeBytes: Int64
    let itemCount: Int
    let exists: Bool
    var isSelected: Bool
}
```

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `id` | `UUID` | Same as `category.id` for stable SwiftUI identity |
| `category` | `CacheCategory` | The scanned category definition |
| `sizeBytes` | `Int64` | Total size in bytes (using allocated size) |
| `itemCount` | `Int` | Number of regular files found |
| `exists` | `Bool` | Whether any resolved paths exist |
| `isSelected` | `Bool` | User selection state (mutable) |
| `formattedSize` | `String` | Human-readable size |
| `isEmpty` | `Bool` | `!exists || sizeBytes == 0` |

---

### `CleanupReport`

**File:** `Sources/Cacheout/Models/ScanResult.swift`

Summary of a cleanup operation.

```swift
struct CleanupReport {
    let cleaned: [(category: String, bytesFreed: Int64)]
    let errors: [(category: String, error: String)]
}
```

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `cleaned` | `[(String, Int64)]` | Successfully cleaned items with bytes freed |
| `errors` | `[(String, String)]` | Failed items with error messages |
| `totalFreed` | `Int64` | Sum of all `bytesFreed` values |
| `formattedTotal` | `String` | Human-readable total freed |

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
| `scanCategory` | `func scanCategory(_ category: CacheCategory) async -> ScanResult` | Scan a single category. Returns result with size, count, and existence. |

**Private Methods:**

| Method | Description |
|--------|-------------|
| `directorySize(at:)` | Enumerate files and sum `totalFileAllocatedSize`. Returns `(Int64, Int)` tuple of (size, count). |

---

### `NodeModulesScanner`

**File:** `Sources/Cacheout/Scanner/NodeModulesScanner.swift`

Thread-safe scanner that recursively finds `node_modules` directories.

**Methods:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `scan` | `func scan(maxDepth: Int = 6) async -> [NodeModulesItem]` | Scan all search roots for node_modules. Returns deduplicated results sorted by size descending. |

**Search Roots:** Documents, Developer, Projects, Code, Sites, Desktop, Dropbox, repos, src, work

**Skip Directories:** .Trash, .git, .hg, node_modules, .build, DerivedData, Pods, .next, dist, build, Library, .cache, .npm, .yarn

---

### `CacheCleaner`

**File:** `Sources/Cacheout/Cleaner/CacheCleaner.swift`

Thread-safe cleaner that handles file deletion, trashing, and cleanup logging.

**Methods:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `clean` | `func clean(results: [ScanResult], nodeModules: [NodeModulesItem] = [], moveToTrash: Bool) async -> CleanupReport` | Clean selected items. Returns report with successes and errors. |

**Private Methods:**

| Method | Description |
|--------|-------------|
| `runCleanCommand(_:)` | Execute a custom shell command via `/bin/bash -c` with 30s timeout |
| `removeContents(of:)` | Remove all items inside a directory (preserving the directory) |
| `trashItem(_:)` | Move a single item to Trash (`@MainActor`) |
| `trashDirectory(_:)` | Move all contents of a directory to Trash (`@MainActor`) |
| `logCleanup(category:bytesFreed:)` | Append entry to `~/.cacheout/cleanup.log` |

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
