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
    let rootRecords: [RootScanRecord]
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
| `rootRecords` | `[RootScanRecord]` | Per-root capture, populated by `CacheScanner` AT SCAN TIME (root-capture invariant): one record for every root the scan resolved. `CategoryScanner` carries these onto the aggregate item verbatim; clean-time dispatch deletes only `.measured` records. Empty for `.missing` |
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

Summary of a cleanup operation over `ReclaimableItem`s, with split byte
components per entry. Since the scanner unification every entry carries its
item's ownership identity (`itemID`/`scannerID`/`displayName`), errors are
self-contained `ItemError` records keyed by `ItemKey`, and per-scanner
rollups are pure derivations over the entries. The pre-split surface
(`cleaned` / `totalFreed` / `formattedTotal`) was retired in v2.2.0.

```swift
struct CleanupReport {
    enum Disposal: Equatable { case permanent, trash }

    struct Entry {
        let itemID: String
        let scannerID: String
        let displayName: String
        let exactBytes: Int64
        let estimatedUpToBytes: Int64
        let disposal: Disposal       // what ACTUALLY happened to this entry
        var bytesFreed: Int64        // compatibility sum (computed)
        var key: ItemKey             // composite identity (computed)
        var componentSummary: String // component-derived row text (computed)
    }

    struct ItemError: Equatable {
        let key: ItemKey
        let displayName: String
        let message: String
    }

    struct ScannerRollup: Equatable {
        let scannerID: String
        let exactBytes: Int64
        let estimatedUpToBytes: Int64
        let entryCount: Int
    }

    struct ScannerSection {
        let rollup: ScannerRollup
        let entries: [Entry]
    }

    let disposal: Disposal
    let entries: [Entry]
    let errors: [ItemError]
}
```

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `disposal` | `Disposal` | The REQUESTED mode for the run — entries carry what actually happened |
| `entries` | `[Entry]` | One entry per cleaned item; a partially-failed item yields ONE entry carrying only the bytes its successful children measured |
| `entries[].itemID` | `String` | The cleaned item's scanner-scoped id: category slug for aggregates, full-hash stable id for per-item scanners |
| `entries[].scannerID` | `String` | The owning scanner's registered id |
| `entries[].displayName` | `String` | Presentation identity, sourced from the cleaned item's REQUIRED ownership fields — never looked up against state that may have been rescanned since |
| `entries[].exactBytes` | `Int64` | Measured unique-inode bytes — deletion verifiably freed them |
| `entries[].estimatedUpToBytes` | `Int64` | Hardlinked bytes (freed only if every other link goes too) and command-category bytes (nothing measures what a command frees) |
| `entries[].disposal` | `Disposal` | What ACTUALLY happened to this entry's bytes — command-backed categories run their argv regardless of the Move-to-Trash toggle, so their entries stay `.permanent` even in a Trash run |
| `entries[].bytesFreed` | `Int64` | Compatibility sum of the entry components (computed) |
| `entries[].key` | `ItemKey` | The composite cross-scanner identity (computed) |
| `entries[].componentSummary` | `String` | Component-derived row text via `componentPhrase` (computed) |
| `errors` | `[ItemError]` | SELF-CONTAINED failure records: a failed item may not exist in any post-clean rescan, so rendering never looks the item up — `key` correlates, `displayName` + `message` carry everything a report line needs |
| `totalFreedExact` | `Int64` | Pure sum of entry `exactBytes` — no other math |
| `totalEstimatedUpTo` | `Int64` | Pure sum of entry `estimatedUpToBytes` — no other math |
| `scannerRollups` | `[ScannerRollup]` | Per-scanner sums over `entries`, grouped by `scannerID` in first-appearance order — pure derivation, nothing stored twice |
| `scannerSections` | `[ScannerSection]` | Each scanner's rollup paired with its entries in report order — the report sheet's sectioned rendering |
| `errorLines` | `[String]` | Report error lines rendered from the `ItemError` records ALONE |
| `headline` | `String` | Entry-disposal-driven summary: permanent entries → "Freed …"; trashed entries → "Moved … to Trash — empty Trash to reclaim"; a mixed run renders both parts; never a success claim when nothing succeeded |

**Methods:**

| Method | Returns | Description |
|--------|---------|-------------|
| `rowAnnotation(for:)` | `String?` | Trash-run honesty marker: for an entry whose bytes were erased permanently in a Trash-mode run, returns "erased permanently — not in Trash"; `nil` when the entry's actual disposal matches the requested mode |
| `componentPhrase(exact:estimatedUpTo:)` (static) | `String` | The amount phrase all rendering derives from: `"X"` (no estimates), `"X + up to Y more"` (both), `"up to Z"` (exact zero) — estimates are always hedged, never laundered into certainty |

---

## Scanner Registry (SpaceScanner)

**File:** `Sources/Cacheout/Scanner/SpaceScanner.swift`

The unified scanner abstraction: every space scanner — the category registry
(via `CategoryScanner`) and every per-item scanner — implements `SpaceScanner`
and emits `ReclaimableItem`s, the one currency the GUI, CLI, and cleaner all
consume. The registry stays `[any SpaceScanner]` with NO downcasting:
scanner-specific knobs cross the protocol boundary via `ScanContext` or not
at all.

### `ScanTrigger`

What set a scan in motion. TCC-protected search roots (Documents, Desktop, …)
are enumerated ONLY for `.userInitiated` scans — a background refresh must
never be the thing that fires a macOS privacy prompt.

```swift
enum ScanTrigger: Equatable, Sendable {
    case userInitiated  // protected roots included; macOS may prompt once
    case automatic      // protected roots skipped entirely
}
```

### `ScanContext`

The generic per-scan parameter every `SpaceScanner` receives.

```swift
struct ScanContext: Equatable, Sendable {
    let trigger: ScanTrigger
    let categoryFilter: Set<String>?   // nil = all

    var includeProtectedRoots: Bool { trigger == .userInitiated }
}
```

| Member | Description |
|--------|-------------|
| `trigger` | `CategoryScanner` ignores it; per-item scanners consume the derived flag |
| `categoryFilter` | Category slugs to scan. `CategoryScanner` is the ONLY scanner that honors it — with a filter, unrequested categories' resolvers/probes are never invoked. Every other scanner ignores it |
| `includeProtectedRoots` | DERIVED TCC gate — protected search roots are walked only when the user explicitly asked |

### `RootScanStatus` / `RootScanRecord`

The per-root capture (FROZEN truth table — this IS the deletability boundary).

```swift
enum RootScanStatus: Equatable, Sendable {
    case refusedAdmission  // PathGuard refused at scan time. NEVER deletable
    case deniedUnmeasured  // admitted, sizing denied before ANY measurement. NOT deletable
    case measured          // admitted and walked (incl. clean-empty walks). Deletable
}

struct RootScanRecord: Equatable, Sendable {
    let requestedURL: URL   // the UNRESOLVED spelling — the one deletion uses
    let resolvedURL: URL?   // canonical spelling containment compares against
    let status: RootScanStatus
}
```

Clean-time contracts: `.removeContents` deletes only `.measured` records;
`.commands` re-admits every record's `requestedURL` at delete time and any
refusal blocks the entire command set.

### `ItemKey`

The composite cross-scanner identity: selection sets, progressive-publish
reconciliation, `CleanupReport` error keying, and SwiftUI list identity all
use it. A bare item id is meaningful only in scanner scope.

```swift
struct ItemKey: Hashable, Sendable {
    let scannerID: String
    let itemID: String
}
```

### `ReclaimAction`

How an item's bytes are reclaimed. Dispatch with EXHAUSTIVE switches (no
`default:`) — a future case must be a compile-time-visible change.

```swift
enum ReclaimAction: Equatable, Sendable {
    case removeContents        // delete children of every .measured root record
    case removeItem            // delete the item's own tree
    case commands([[String]])  // run argv arrays via /usr/bin/env
}
```

| Member | Description |
|--------|-------------|
| `wireString` | FROZEN wire strings: `remove_contents` \| `remove_item` \| `commands`. `.commands` serializes ONLY its kind — argv arrays are NEVER exposed on any wire surface |

### `AdmissionDescriptor`

Which PathGuard admission mode applies at the cleaner's chokepoint.
Provenance is a CLAIM the runtime validates and the cleaner independently
re-checks — items can never widen admission.

```swift
enum AdmissionDescriptor: Equatable, Sendable {
    case category(CacheCategory)
    case containerItem(originContainer: URL, requestedTargetURL: URL)
}
```

`requestedTargetURL` is the UNRESOLVED deletion target — leaf never resolved
(dual-canonicalization doctrine). `ReclaimableItem.url` is display state and
NEVER an admission or deletion input.

### `ReclaimableItem`

The ONE unified item model.

```swift
struct ReclaimableItem: Equatable, Sendable {
    let id: String
    let scannerID: String
    let displayName: String
    let exactBytes: Int64
    let estimatedUpToBytes: Int64
    let logicalBytes: Int64?
    let itemCount: Int
    let url: URL?
    let declaredDisplayPath: String
    let rootRecords: [RootScanRecord]
    let state: ScanState
    let scanError: ScanError?
    let risk: RiskLevel
    let evidence: String
    let rebuildNote: String?
    let action: ReclaimAction
    let admission: AdmissionDescriptor
    let defaultSelected: Bool
    let automaticCleanEligible: Bool
    let isStale: Bool?

    var key: ItemKey { get }
    var allocatedBytes: Int64 { get }  // computed: exactBytes + estimatedUpToBytes
}
```

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `id` | `String` | Scanner-DEFINED under three invariants: stable across rescans for the same logical item, unique within its scanner, CLI-safe opaque string. Category aggregates use the category SLUG; per-item scanners derive ids via `stableID` |
| `scannerID` / `displayName` | `String` | Ownership and presentation ride ON the item — `clean(items:)` receives bare items, so nothing may need to be looked up (and race a rescan) at clean time |
| `exactBytes` | `Int64` | Bytes on unique inodes — deletion verifiably frees these |
| `estimatedUpToBytes` | `Int64` | Hardlinked/command bytes that MAY be freed |
| `logicalBytes` | `Int64?` | Logical (apparent) bytes; nil unless materially diverging from allocated (sparse files) |
| `url` | `URL?` | DISPLAY ONLY — first root record with a non-nil `resolvedURL` regardless of status; nil only for `.missing` items or when no root resolved. NEVER an admission or deletion input |
| `declaredDisplayPath` | `String` | The declared spelling, for presenting unresolved/missing items honestly without a fake resolution |
| `rootRecords` | `[RootScanRecord]` | The scan's per-root capture, carried verbatim. Empty for `.missing`; single-element for per-item scanners |
| `state` / `scanError` | `ScanState` / `ScanError?` | Item-level error surface — never flatten `denied` into `empty` (D6) |
| `risk` | `RiskLevel` | Evidence confidence, not clean eligibility. `build_artifacts` items carry the matched RULE ROW's risk, narrowed to `.review` by the valuables gate |
| `evidence` | `String` | Renders in the confirmation sheet per item (aggregates: the category description) |
| `action` | `ReclaimAction` | How the cleaner reclaims this item's bytes |
| `admission` | `AdmissionDescriptor` | Which PathGuard mode applies at the chokepoint |
| `defaultSelected` | `Bool` | GUI initial selection — applied ONLY when a key is emitted for the first time |
| `automaticCleanEligible` | `Bool` | `false` excludes the item from Quick Clean AND CLI smart-clean (every per-item scanner row ships `false` — CLI-visible is not auto-cleanable) |
| `isStale` | `Bool?` | nil = staleness not applicable OR unknowable ("Select Stale" operates on `isStale == true`); the threshold is per-scanner — build artifacts use the fixed 30-day `ReclaimableItem.isStale(daysSinceModified:)` helper, orphaned caches a 60-day default, ephemeral temp a 7-day default |
| `valuablesDisclosure` | `ValuablesDisclosure?` | ADDITIVE. What the release-artifact probe SAW, plus its completeness flag. DISCLOSURE, never consent — acknowledgement lives only in the per-clean authorization context |
| `requiresPreDeleteRevalidation` | `Bool` | ADDITIVE, scanner-agnostic. `true` means the item MUST be re-inspected immediately before deletion; a cleaner holding no revalidator for its scanner refuses it fail-closed |
| `artifactProof` | `BuildArtifactProof?` | ADDITIVE. The structural property that made this item a candidate, so the OWNING scanner's revalidator can re-prove it rather than trust the scan. nil for every scanner but `build_artifacts`. Never on any wire |
| `scannedTargetIdentity` | `Identity?` | ADDITIVE. The (device, inode) the SCAN saw at the deletion target, so the owning scanner's revalidator can prove the object it opens IS the one that was scanned rather than whatever now answers to the name. nil for every scanner but `ephemeral_tmp`; a revalidator that requires it fails closed on nil. Never on any wire |
| `key` | `ItemKey` | Computed composite identity |
| `allocatedBytes` | `Int64` | COMPUTED component sum — display convenience only, never stored |

**Static Methods:**

| Method | Returns | Description |
|--------|---------|-------------|
| `stableID(scannerID:canonicalPath:)` | `String` | The shared per-item id derivation with the EXACT frozen preimage: full lowercase-hex SHA-256 (64 chars) over the UTF-8 bytes of `scannerID + "\0" + canonicalPath`. No truncation, ever. Every per-item scanner calls this instead of re-implementing; the derivation is documented in PROTOCOL.md |

### `ScanIssue` / `ScanOutcome`

```swift
struct ScanIssue: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case containerRefused, symlinkRoot, tccDenied,
             permissionDenied, unreadable, malformedOutcome
    }
    let url: URL?      // required by convention for filesystem kinds;
                       // nil for .malformedOutcome (no fake paths)
    let kind: Kind
    let detail: String
}

struct ScanOutcome: Sendable {
    var items: [ReclaimableItem]
    var errors: [ScanIssue]
}
```

Two-surface rule: impediments attributable to an emitted item ride the item's
`state`/`scanError`; only root/scanner-level problems with no recognized
candidate land in `ScanOutcome.errors`. `Kind` is EXTENSIBLE — never write
consumers that assume the case list is closed. Wire strings (frozen):
`container_refused`, `mounted_volume_root`, `policy_refused_root`,
`symlink_root`, `non_directory_root`, `tcc_denied`,
`permission_denied`,
`unreadable`, `enumeration_truncated`, `config_invalid`, `malformed_outcome`. `.malformedOutcome` is
synthesized ONLY by the runtime's validation, never by scanners.
`mounted_volume_root` is a registered root with another volume mounted at
it — NOT a refusal of the root, and clearable by unmounting (added PR #459
review r11; the GUI's visible row label is derived from the kind alone, so
reporting it as `container_refused` printed "not a configured search root"
for a root that IS configured).
`policy_refused_root` and `non_directory_root` (added PR #459 codex r13)
close the two siblings of that same defect on `ephemeral_tmp`: a scanner
builds its `PathGuard` from its own roots, so a root the policy refuses was
configured and `container_refused`'s label was false for every firing; and
`symlink_root`'s label ("symlinked — not searched") was false for a root
replaced by a regular file, FIFO, socket or device.
`config_invalid` was missing from this list while the binary could emit it
(fixed in PR #459 review r2; `DocumentedContractTests` only reads
PROTOCOL.md, which did list it, so nothing caught the drift).

### `SpaceScanner` (protocol)

```swift
protocol SpaceScanner: Sendable {
    var id: String { get }                       // stable slug, [a-z0-9_]+
    var displayName: String { get }
    var trustedContainerRoots: [URL] { get }     // declared at REGISTRATION
    var preDeleteRevalidator: PreDeleteRevalidator? { get }  // default nil
    func participates(in context: ScanContext) -> Bool       // default true
    func scan(context: ScanContext) async -> ScanOutcome
}
```

`preDeleteRevalidator` and `participates(in:)` carry protocol-extension
defaults, so a scanner that wants neither implements neither.

`participates(in:)` is how a scanner declines a whole session — never by
returning an empty `ScanOutcome`, which asserts "I looked and there is nothing
there" and makes the consumer replace the scanner's rows, issues and the user's
selections. `SpaceScannerRuntime.scanValidatedSession` filters on it, so a
declining scanner produces no task and no event at all: every caller of a
session (the ViewModel, `CLIHandler.collectValidatedScan`, and any future one)
gets the deferral without opting in.

Adding a scanner = implement this + register with the runtime — nothing else:
the runtime derives delete-time admission from registration. Conformers:
`CategoryScanner` (id `categories`), `BuildArtifactsScanner`
(id `build_artifacts`), `OrphanedCachesScanner` (id `orphaned_caches`),
`EphemeralTempScanner` (id `ephemeral_tmp`).

### `ValidatedScannerEvent` / `SpaceScannerRegistrationError`

```swift
enum ValidatedScannerEvent: Sendable {
    case outcome(scannerID: String, ScanOutcome)
    case malformed(scannerID: String, ScanIssue)
}

enum SpaceScannerRegistrationError: Error, Equatable {
    case malformedScannerID(String)
    case duplicateScannerID(String)
    case malformedCategorySlug(String)
    case namespaceCollision(String)
}
```

### `SpaceScannerRuntime`

The ONE trusted composition source: scanner instances + the cleaner
configuration DERIVED from them. The production `CacheCleaner` is constructed
FROM the runtime, so "implement protocol + register" automatically extends
delete-time admission — and NOTHING else does.

```swift
struct SpaceScannerRuntime {
    let scanners: [any SpaceScanner]
    let trustedContainerRoots: [URL]  // union of scanner declarations

    init(scanners:categories:home:provider:) throws
    static func production(home:provider:orphanedCachesThresholds:devRoots:
                           ephemeralTempThresholds:) -> SpaceScannerRuntime
    func makeCleaner(snapshot: ContainerSnapshot? = nil,
                     trashHandler:) -> CacheCleaner
    func scanValidated(scannerIDs: Set<String>? = nil,
                       context: ScanContext) -> AsyncStream<ValidatedScannerEvent>
    func scanValidatedSession(scannerIDs: Set<String>? = nil,
                              context: ScanContext) -> ValidatedScanSession
    static func isValidSlug(_ slug: String) -> Bool
}
```

| Member | Description |
|--------|-------------|
| `init` | Registration + FOLDED validation as one check: scanner-id slug syntax, scanner-id uniqueness, category-slug syntax, and the combined category-slug/scanner-slug namespace collision check (covers the frozen `categories` id). Injectable for tests — registering a fixture scanner requires zero production edits |
| `production()` | The production registry — the single place scanners are registered (`CategoryScanner` + `BuildArtifactsScanner` + `OrphanedCachesScanner` + `EphemeralTempScanner`, in that order). `orphanedCachesThresholds` threads the sweep's invocation-scoped config, `devRoots` the build-artifact roots, and `ephemeralTempThresholds` the temp scanner's (nil resolves defaults → UserDefaults inside the factory). The temp scanner's ROOTS are not a parameter: `EphemeralTempRoots.resolve(provider:)` is the closed declaration |
| `makeCleaner(snapshot:trashHandler:)` | Builds the `CacheCleaner` whose PathGuard container roots are the runtime union — delete-time container admission covers exactly what registration declared, never anything an item claims. `snapshot` is the producing scan session's `ContainerSnapshot` (`ValidatedScanSession.snapshot`); nil FAIL-CLOSES every `.removeItem` deletion (`container-unavailable`) — items must be cleaned with the session that produced them |
| `scanValidatedSession(scannerIDs:context:)` | The scan-and-validate entry point returning one SESSION: the progressive validated event stream, the producer handle (`untilProducerFinishes()`), and the session's `ContainerSnapshot` — every registered container root's no-follow (device, inode), captured BEFORE any scanner task launches (absent roots omitted). Delete-time `.removeItem` admission is identity-bound to this snapshot |
| `scanValidated(scannerIDs:context:)` | Thin wrapper over `scanValidatedSession` returning just the event stream. The scan `TaskGroup` and ALL validation live inside; each event is one scanner's validated outcome or its synthesized `malformedOutcome` issue, yielded in completion order. `scannerIDs` scopes to a scanner subset (nil = all); the context's `categoryFilter` gives category-granular scoping inside `CategoryScanner`. Consumers pick scope and consumption style, never validation |
| `isValidSlug(_:)` | `[a-z0-9_]+` — the address grammar's slug alphabet (no colon) |

Validation (applied per event, fail-closed): (a) every item's `scannerID`
equals the producing scanner's id; (b) item ids unique within the outcome;
(c) state-aware structural invariants — `.removeItem` requires the
`.containerItem` descriptor, `.removeContents`/`.commands` require category
provenance, and every non-`.missing` `.removeContents`/`.commands` item
requires at least one root record; (d) category provenance is trusted only
from the registered category adapter, the item id must equal the carried
category's slug, the carried category must BE the registered instance, and a
`.commands` payload must equal the category's declared `cleanCommands` (argv
is registry code, never item input). Any violation replaces the WHOLE outcome
with a synthesized path-less `malformedOutcome` issue. `CacheCleaner`
independently refuses the same shapes at dispatch — defense in depth.

### `CategoryScanner`

**File:** `Sources/Cacheout/Scanner/CategoryScanner.swift`

The `SpaceScanner` adapter over the data-driven `CacheCategory` registry —
one aggregate `ReclaimableItem` per category, current behavior preserved with
zero churn to the category entries (scanning delegates to the existing
`CacheScanner` actor).

| Member | Description |
|--------|-------------|
| `registeredID` (static) | The FROZEN aggregate scanner id `categories`. NOT a valid bare CLI address token — category aggregates are addressed by category slug only |
| `trustedContainerRoots` | Empty — aggregate admission is category-policy, not container-based |
| `scan(context:)` | Honors `categoryFilter` BEFORE any resolver/probe runs; ignores the trigger (category scans never touch TCC-prompting roots) |
| `item(from:rootRecords:)` (static) | The one place aggregate items are built: id = category slug, byte components/state/error/root records straight from the `ScanResult` — no re-measurement, no re-evaluation of `resolvedPaths` |
| `declaredDisplayPath(of:)` (static) | The category's declared spelling for honest missing/unresolved presentation |

### `EphemeralTempScanner`

**Files:** `Sources/Cacheout/Scanner/EphemeralTempScanner.swift`,
`Sources/Cacheout/Scanner/EphemeralTempRoots.swift`

The `SpaceScanner` over the three ephemeral temp roots — one item per STALE
first-level entry, `risk: .review`, `defaultSelected: false`,
`automaticCleanEligible: false`, `action: .removeItem`.

| Member | Description |
|--------|-------------|
| `registeredID` (static) | The scanner slug `ephemeral_tmp` — the CLI address prefix and the GUI section key |
| `trustedContainerRoots` | The declared root spellings, fixed at REGISTRATION — what registration hands delete-time admission. One spelling per root, resolved once by `EphemeralTempRoots.resolve`: canonical parent chain, leaf left UNRESOLVED, so a root whose own leaf is a symlink is NOT canonical |
| `participates(in:)` | Where the trigger policy lives: `true` only for `.userInitiated`. On `.automatic` the runtime leaves the scanner OUT of the session entirely — no task, no event, so previously displayed temp rows, their issues and the user's ticks all survive the refresh |
| `scan(context:)` | Ignores `categoryFilter`. Repeats the trigger gate as defense in depth for a caller that constructs a scanner and bypasses the runtime; that arm returns an empty outcome, which is why it is a last resort and not the policy |
| `preDeleteRevalidator` | Declared for EVERY temp item. Re-inspects the entry from one held descriptor immediately before deletion: it proves the object is the one the scan inspected (device+inode), refuses anything that is no longer a directory or regular file, re-checks staleness and the advisory lock, and re-checks ownership only under a `.worldWritable` root |
| `EphemeralTempRoots.resolve(provider:confstrPath:)` | The closed 3-root declaration resolved once, returning `EphemeralTempRootsResolution { roots, issues }`: `/private/tmp` plus the `confstr(3)` temp/cache containers, trailing slash normalized, PARENT CHAIN canonicalized with the leaf left unresolved (a symlink standing at a container's own name must stay visible to the scanner's no-follow root gate, not be replaced by its destination — closed AT THE LEAF only; intermediate components are still resolved, a residual ARCHITECTURE.md records at measured scope). Real-directory spellings of one location de-dupe by inode identity of a fully canonical comparison key; a non-directory spelling that aliases one of them is DROPPED with a `symlinkRoot` issue rather than kept ahead of it, and the scanner rides those issues on every inspecting outcome. A failed lookup drops that root silently — never a hardcoded `/var/folders` guess |
| `EphemeralTempSweepConfig` | Keys `cacheout.ephemeralTmp.ageDays` / `cacheout.ephemeralTmp.minSizeMB`, defaults 7 days / 10 MB, layered defaults → UserDefaults → CLI override; an invalid persisted value falls back WITHOUT being rewritten |

---

## Actors

### `CacheScanner`

**File:** `Sources/Cacheout/Scanner/CacheScanner.swift`

Thread-safe scanner that discovers and measures cache categories in parallel.

**Methods:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `scanAll` | `func scanAll(_ categories: [CacheCategory]) async -> [ScanResult]` | Scan all categories concurrently. Returns results sorted by size descending, ties broken by category slug ascending — a TOTAL order, so two scans of the same input never disagree (every missing and every empty category ties at 0 bytes). |
| `scanCategory` | `func scanCategory(_ category: CacheCategory) async -> ScanResult` | Scan a single category. Admits each resolved root before sizing (refusal = scan error, never a walk); returns state, split components, and count. |

Sizing is delegated to `DirectorySizer` (`Sources/Cacheout/Scanner/DirectorySizer.swift`) —
the single sizing routine shared with delete-time measurement.

---

### `CacheCleaner`

**File:** `Sources/Cacheout/Cleaner/CacheCleaner.swift`

Thread-safe cleaner that handles guarded file deletion, trashing, freed-bytes
accounting, and cleanup logging. Constructed FROM the runtime
(`SpaceScannerRuntime.makeCleaner()`) so its PathGuard container roots are
the registration-derived union. Every deletion target passes `PathGuard`
admission (a `.denied` scan state is refused even when force-selected), and
freed bytes are measured at delete time and settled through the claim-based
`InodeAccountingRegistry` — see [ARCHITECTURE.md](ARCHITECTURE.md) for the
safety model and accounting design.

**Methods:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `clean` | `func clean(items: [ReclaimableItem], moveToTrash: Bool, authorization: PreDeleteAuthorizationContext = [:]) async -> CleanupReport` | THE one and only clean path (the pre-unification `clean(results:nodeModules:)` adapter was deleted in fn-4.7). Dispatches on `ReclaimAction` at the chokepoint with a FROZEN check order: (1) structural action/descriptor/provenance compatibility on every item regardless of state, (2) well-formed `.missing` skip, (3) non-`.missing` zero-root-record refusal, (4) state eligibility (`.denied` refused even when selected; `.empty` no-op; `.commands` zero-measured skip), (5) dispatch. Independently refuses the same malformed shapes the runtime validator rejects — the chokepoint never assumes validation ran. |

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

Central `@MainActor` `ObservableObject` managing all application state — one
selection/totals/clean model over `ReclaimableItem`, written once for every
scanner. Constructed from a `SpaceScannerRuntime` (injectable for hermetic
tests; production uses `.production()`); the runtime owns scan orchestration
and validation, the view model owns reconciliation and presentation.

**Published Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `outcomesByScannerID` | `[String: ScanOutcome]` | Each scanner's latest VALIDATED outcome. A malformed event never lands here — the previous outcome is retained (fail-closed) |
| `selectedItemKeys` | `Set<ItemKey>` | THE selection surface — composite keys only. Selections AND explicit deselections survive rescans; `defaultSelected` applies only to first-ever emissions; vanished keys are pruned when the stream completes, never mid-scan |
| `scanningScannerIDs` | `Set<String>` | Scanners whose event has not arrived in the current scan (replaces the pre-unification split per-scanner `isScanning` flags) |
| `malformedIssuesByScannerID` | `[String: ScanIssue]` | The synthesized path-less issue for a scanner whose last event was malformed, surfaced beside the retained previous items |
| `isCleaning` | `Bool` | Whether cleanup is in progress |
| `diskInfo` | `DiskInfo?` | Current disk space info |
| `showCleanConfirmation` | `Bool` | Controls confirmation sheet |
| `showCleanupReport` | `Bool` | Controls report sheet |
| `lastReport` | `CleanupReport?` | Most recent cleanup report |
| `moveToTrash` | `Bool` | Deletion mode preference |
| `scanGeneration` | `Int` | Monotonic counter for reactive updates |
| `hasScanned` | `Bool` | Whether at least one scan completed (stays true on zero items) |
| `lastScanDate` | `Date?` | When the last scan completed |
| `scanIntervalMinutes` | `Double` | Auto-scan interval (persisted) |
| `lowDiskThresholdGB` | `Double` | Notification threshold (persisted) |
| `launchAtLogin` | `Bool` | Launch at login preference (persisted) |
| `isDockerPruning` | `Bool` | Whether Docker prune is in progress |
| `lastDockerPruneResult` | `String?` | Docker prune output message |

**Item access & computed properties:**

| Member | Type | Description |
|--------|------|-------------|
| `items(forScanner:)` / `issues(forScanner:)` / `item(for:)` | — | Validated-outcome accessors |
| `selectedItems` | `[ReclaimableItem]` | Selected items in presentation order — exactly what `clean()` hands the cleaner |
| `hasResults` / `hasSelection` / `selectedCount` | — | Selection/result predicates |
| `isAnyScanInProgress` | `Bool` | True while ANY scanner's event is pending — clean must never act on a half-built result set |
| `categoryRows` | `[CategoryRowModel]` | Category aggregates presented through the unchanged `CategoryRow` inputs; list identity is the composite key |
| `perItemSections` | `[ScannerSectionModel]` | One generic section per non-category scanner, in registry order |
| `categoryScanIssues` | `[ScanIssue]` | Category-scanner issues incl. a synthesized `malformedOutcome` |
| `confirmationRows` | `[ConfirmationRowModel]` | Unified confirmation-sheet rows — every row carries its item's `evidence` |
| `totalRecoverable` / `totalSelectedSize` / `selectedSize(forScanner:)` / `totalSize(forScanner:)` | `Int64` | Byte totals through one shared aggregation helper with explicit scope/inclusion predicates |
| `automaticCleanableSize` / `hasAutomaticCleanableItems` | — | Bytes Quick Clean would actually act on (policy (b), registry-wide) |
| `hasPartiallyDeniedSelection` / `hasCommandBackedSelection` / `hasCautionSelection` | `Bool` | Confirmation-sheet disclosure predicates |
| `shouldAutoRescan` | `Bool` | Whether data is stale |
| `menuBarTitle` | `String` | Free GB for menubar display |

**Methods:**

| Method | Description |
|--------|-------------|
| `scan(trigger:)` | Consume the runtime's progressive validated event stream (all scanners, nil filter). The trigger is MANDATORY — every caller must classify itself, so a misclassified new call site is a compile error, and TCC-protected roots are walked only for `.userInitiated` |
| `clean()` | Clean `selectedItems` via the runtime-constructed cleaner, show report, then rescan |
| `smartClean()` | GUI Quick Clean — a PURE auto path, strictly policy (b): deselect all, `selectAllSafe()`, clean. CLI smart-clean's safe-then-review policy (c) is exclusively the CLI's |
| `dockerPrune()` | Run `docker system prune -f` |
| `toggleSelection(for:)` | Toggle one `ItemKey`'s selection (unselectable states refused) |
| `selectAllSafe()` | Policy (b): `automaticCleanEligible && risk == .safe`, across every scanner |
| `deselectAll()` | Clear the whole selection |
| `selectStale(inScanner:)` / `selectAll(inScanner:)` / `deselectAll(inScanner:)` | Scanner-scoped batch selection |

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

### `ScannerItemSection`

**File:** `Sources/Cacheout/Views/ScannerItemSection.swift`

Collapsible per-item scanner section:
item list, batch selection buttons ("Select Stale" renders only where
staleness applies), and scan-issue disclosure via `ScanIssuesBlock`.

**Properties:** `section: ScannerSectionModel`

### `ScannerItemRow`

**File:** `Sources/Cacheout/Views/ScannerItemSection.swift`

Single per-item row with checkbox, display name, path, stale badge, and size.

**Properties:** `item: ReclaimableItem`

### `CleanConfirmationSheet`

**File:** `Sources/Cacheout/Views/CleanConfirmation.swift`

Modal sheet confirming cleanup with the unified itemization
(`ConfirmationRowModel` — every row carries its item's evidence string), the
trash toggle, and the command-backed trash disclosure (command-cleaned
categories are named: their bytes are erased permanently, never in the
Trash).

### `CleanupReportSheet`

**File:** `Sources/Cacheout/Views/CleanConfirmation.swift`

Modal sheet showing cleanup results in per-scanner sections
(`CleanupReport.scannerSections`) with component-derived rollup headers.

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
