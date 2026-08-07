# CacheOut CLI Protocol

**Version:** 1.1.0
**Schema Version:** 3
**Last Updated:** 2026-08-06

This document defines the interface contract between the CacheOut macOS application (`cacheout`) and the MCP server (`cacheout-mcp`). Both repositories reference this protocol. Changes must be coordinated across both repos.

---

## Table of Contents

1. [Version Negotiation](#version-negotiation)
2. [CLI Commands](#cli-commands)
3. [CLI Error Contract](#cli-error-contract)
4. [Alert Schema](#alert-schema)
5. [Socket Protocol](#socket-protocol)
6. [Schema Versioning Strategy](#schema-versioning-strategy)

---

## Version Negotiation

The MCP server discovers CacheOut capabilities before invoking commands. This enables graceful degradation when the CLI version does not support a given feature.

### `--cli version`

**Output:**

```json
{
  "version": "2.2.0",
  "schema_version": 3,
  "mode": "cli",
  "app": "Cacheout",
  "helper_installed": true,
  "helper_enabled": true,
  "capabilities": [
    "version",
    "disk-info",
    "scan",
    "clean",
    "smart-clean",
    "spotlight",
    "memory-stats",
    "purge",
    "top-processes",
    "memory-pressure",
    "intervene"
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | string | yes | SemVer application version (e.g. `"2.0.0"`) |
| `schema_version` | integer | yes | Protocol schema version. Bumped on breaking changes. |
| `mode` | string | yes | Always `"cli"` when invoked via `--cli` |
| `app` | string | yes | Application identifier (`"Cacheout"`) |
| `helper_installed` | boolean | yes | Backward-compat alias for `helper_enabled` (schema v1) |
| `helper_enabled` | boolean | yes | Whether the privileged helper daemon is registered and enabled (via SMAppService) |
| `capabilities` | string[] | yes | List of supported `--cli` subcommands |

**MCP server behavior:** Before calling any CLI command, check that the command name appears in `capabilities`. If absent, skip the call and return a user-friendly message indicating the feature requires a newer CacheOut version.

**Schema 3 gate:** When `schema_version >= 3`, `clean` and `smart-clean` are gated behind `--confirm` — an invocation without it exits 1 with a `CONFIRMATION_REQUIRED` error carrying the cleaning plan in `details`. Callers that intend to delete MUST pass `--confirm`; callers that only want a preview MUST pass `--dry-run`. There is no environment-variable bypass.

---

## CLI Commands

All commands are invoked as:

```
Cacheout --cli <command> [arguments] [flags]
```

### Command Summary

| Command | Description | Phase | Requires Helper |
|---------|-------------|-------|-----------------|
| `version` | Application version and capabilities | Existing | No |
| `disk-info` | Boot volume disk space | Existing | No |
| `scan` | Scan all cache categories | Existing | No |
| `clean <slugs...> [--confirm\|--dry-run]` | Delete specific cache categories (destructive — requires `--confirm` since schema 3) | Existing | No |
| `smart-clean <gb> [--confirm\|--dry-run]` | Auto-clean safe categories to free target GB (destructive — requires `--confirm` since schema 3) | Existing | No |
| `spotlight` | Tag cache directories with Spotlight metadata | Existing | No |
| `memory-stats` | System memory statistics | Existing | No |
| `purge` | Run `/usr/sbin/purge` and report delta | Existing | No |
| `top-processes [--top N]` | Top N processes by memory footprint | Phase 2 | Yes |
| `memory-pressure` | Current memory pressure level | Phase 2 | No |
| `intervene <name> [--dry-run] [--confirm] [--target-pid N]` | Execute a memory intervention | Phase 3 | Per-intervention |

---

### `--cli disk-info`

Returns boot volume disk space information.

**Output schema:**

```json
{
  "total": "500.1 GB",
  "free": "23.4 GB",
  "used": "476.7 GB",
  "total_bytes": 500068036608,
  "free_bytes": 25127321600,
  "used_bytes": 474940715008,
  "free_gb": 23.4,
  "used_percent": 94.97
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `total` | string | yes | Human-readable total disk space |
| `free` | string | yes | Human-readable free disk space |
| `used` | string | yes | Human-readable used disk space |
| `total_bytes` | integer | yes | Total disk space in bytes |
| `free_bytes` | integer | yes | Free disk space in bytes |
| `used_bytes` | integer | yes | Used disk space in bytes |
| `free_gb` | number | yes | Free disk space in GB (floating point) |
| `used_percent` | number | yes | Percentage of disk used (0-100) |

---

### `--cli scan`

Scans all cache categories and returns results. Since schema 3 every entry
carries the scan STATE and the SPLIT byte components (additive on the v2
shape): `exact_bytes` are bytes on unique inodes whose deletion verifiably
frees them; `estimated_up_to_bytes` are hardlinked bytes that MAY be freed.
`size_bytes` remains their compatibility sum.

**Output schema (array):**

```json
[
  {
    "slug": "xcode_derived_data",
    "name": "Xcode Derived Data",
    "size_bytes": 15032000000,
    "size_human": "15.03 GB",
    "item_count": 42,
    "exists": true,
    "risk_level": "safe",
    "description": "Build artifacts regenerated on next build",
    "rebuild_note": "Xcode rebuilds automatically",
    "state": "measured",
    "exact_bytes": 15000000000,
    "estimated_up_to_bytes": 32000000
  }
]
```

A category whose scan was impeded additionally carries `scan_error` (and,
for TCC denials only, `grant_hint`):

```json
{
  "slug": "browser_caches",
  "state": "denied",
  "exact_bytes": 0,
  "estimated_up_to_bytes": 0,
  "size_bytes": 0,
  "scan_error": {
    "kind": "tcc_denied",
    "message": "Operation not permitted"
  },
  "grant_hint": "macOS denied access without prompting (TCC). Grant Full Disk Access to this binary (or your terminal) in System Settings > Privacy & Security > Full Disk Access, then rescan."
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `slug` | string | yes | Machine-readable category identifier |
| `name` | string | yes | Human-readable category name |
| `size_bytes` | integer | yes | Compatibility sum: `exact_bytes + estimated_up_to_bytes` |
| `size_human` | string | yes | Human-readable size |
| `item_count` | integer | yes | Number of items found |
| `exists` | boolean | yes | Compatibility: `state != "missing"` — a `"denied"` category still "exists" |
| `risk_level` | string | yes | One of: `"safe"`, `"review"`, `"caution"` |
| `description` | string | yes | What this cache category contains |
| `rebuild_note` | string | yes | How this cache is regenerated |
| `state` | string | yes | One of: `"missing"`, `"empty"`, `"measured"`, `"partiallyDenied"`, `"denied"`. A `"denied"` category was NOT measured — its zero size must never be read as "nothing there" |
| `exact_bytes` | integer | yes | Bytes on unique inodes — deletion verifiably frees them |
| `estimated_up_to_bytes` | integer | yes | Bytes on hardlinked inodes — freed only if every other link goes too |
| `scan_error` | object | no | Present only for `"denied"`/`"partiallyDenied"`. `kind` is one of `"admission_refused"`, `"tcc_denied"`, `"permission_denied"`, `"other"`; `message` is human-readable |
| `grant_hint` | string | no | Present only when `scan_error.kind == "tcc_denied"` — the user-side remedy (Full Disk Access), since macOS denies CLI processes silently |

---

### `--cli clean <slugs...> [--confirm|--dry-run]`

Cleans the specified cache categories by slug. **Destructive — since schema 3
it requires `--confirm`.**

**Arguments:**
- `<slugs...>` -- One or more category slugs (from `scan` output)
- `--confirm` -- Actually delete. Without it the command refuses (below)
- `--dry-run` -- Preview without deleting (needs no `--confirm`; wins even beside it)

Slugs that do not match any known category cause an `INVALID_ARGUMENTS` error
naming the unknown slug(s); no cleaning is performed in that case. Running as
root (euid 0) is refused outright with a `ROOT_REFUSED` error, `--confirm` or
not.

#### Confirmation gate (schema 3)

An unconfirmed, non-dry-run invocation deletes NOTHING: **stdout is empty**,
the exit code is 1, and stderr carries the standard error envelope with the
cleaning plan — the same per-category decisions the confirmed run would take —
under `details`:

```json
{
  "ok": false,
  "error": {
    "code": "CONFIRMATION_REQUIRED",
    "message": "clean deletes cache contents and requires --confirm (preview with --dry-run)"
  },
  "details": {
    "command": "clean",
    "plan": [
      {
        "slug": "npm_cache",
        "name": "npm Cache",
        "state": "measured",
        "action": "clean",
        "exact_bytes": 2035888128,
        "estimated_up_to_bytes": 0
      }
    ],
    "total_exact_bytes": 2035888128,
    "total_estimated_up_to_bytes": 0
  }
}
```

| Details field | Type | Description |
|---------------|------|-------------|
| `command` | string | `"clean"` or `"smart-clean"` |
| `plan` | object[] | One entry per requested slug (scan-time components — no re-walk) |
| `plan[].state` | string | The scan state (see `scan`) |
| `plan[].action` | string | What the confirmed run would do: `"clean"`, `"clean_with_warning"` (`partiallyDenied` — measured bytes only), `"refuse"` (`denied`), or `"skip"` (missing/empty). Smart-clean plans additionally use `"clean_if_needed"` for eligible fallback candidates past the projected target-met point — deleted only if earlier categories free fewer delete-time bytes than their scan-time exact components |
| `plan[].exact_bytes` | integer | Scan-time exact component |
| `plan[].estimated_up_to_bytes` | integer | Scan-time estimated component |
| `plan[].warning` | string | Present for `partiallyDenied` entries |
| `plan[].scan_error` | object | Present when the scan was impeded (same shape as `scan`) |
| `total_exact_bytes` | integer | Sum of exact bytes over entries that would clean |
| `total_estimated_up_to_bytes` | integer | Sum of estimated bytes over entries that would clean |

#### Confirmed output (schema 3)

Byte totals are **exact-only**: `total_freed_bytes` counts delete-time
measured unique-inode bytes; hardlinked/command-freed bytes appear in the
additive `total_estimated_up_to_bytes` and are never folded into the total.
`results` carries one entry per requested slug — including slugs that had
nothing to do (`success: true`, zero bytes).

```json
{
  "dry_run": false,
  "total_freed_bytes": 13204889600,
  "total_estimated_up_to_bytes": 32000000,
  "total_freed": "13.2 GB + up to 32 MB more",
  "results": [
    {
      "category": "xcode_derived_data",
      "name": "Xcode Derived Data",
      "bytes_freed": 13204889600,
      "exact_bytes": 13204889600,
      "estimated_up_to_bytes": 32000000,
      "freed_human": "13.2 GB + up to 32 MB more",
      "success": true
    }
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `dry_run` | boolean | yes | Whether this was a dry run |
| `total_freed_bytes` | integer | yes | **Exact bytes only** (schema 3 — was the mixed sum in v2) |
| `total_estimated_up_to_bytes` | integer | yes | Hardlinked/command bytes that MAY have been freed |
| `total_freed` | string | yes | Human-readable component phrase (e.g. `"13.2 GB + up to 32 MB more"`) |
| `results` | object[] | yes | One entry per requested slug |
| `results[].category` | string | yes | Category **slug** (schema 3 — v2 emitted the display name here despite this document) |
| `results[].name` | string | yes | Human-readable category name |
| `results[].bytes_freed` | integer | yes | Exact bytes freed for this category (== `exact_bytes`) |
| `results[].exact_bytes` | integer | yes | Delete-time measured unique-inode bytes |
| `results[].estimated_up_to_bytes` | integer | yes | Delete-time hardlinked / command-category bytes |
| `results[].freed_human` | string | yes | Human-readable component phrase |
| `results[].success` | boolean | yes | `false` iff the category reported at least one error |
| `results[].error` | string | no | Error message(s), `"; "`-joined, when `success` is false |
| `results[].warning` | string | no | Present when the category scanned `partiallyDenied` — only measured bytes were cleaned/reported |

**Denied-state slugs:** naming a `denied` category is a per-item error
(`success: false`, `error` explains the scan-time refusal — TCC, permissions,
or admission), never a silent skip. Naming a `partiallyDenied` category
proceeds but carries `warning`. The `smart-clean` auto path skips both.

#### Exit-code policy (schema 3)

| Outcome | Exit | stdout | stderr |
|---------|------|--------|--------|
| Everything succeeded (or nothing to do) | 0 | result JSON | empty |
| PARTIAL failure — some slugs errored, or some bytes freed despite errors | 0 | result JSON with per-item `success` flags | empty |
| TOTAL failure — every requested slug errored and nothing was freed | 1 | empty | `CLEAN_FAILED` envelope; `details.results` carries the per-item errors |
| Unconfirmed (no `--confirm`, no `--dry-run`) | 1 | empty | `CONFIRMATION_REQUIRED` envelope with `details.plan` |
| Running as root (euid 0) | 1 | empty | `ROOT_REFUSED` envelope |
| Unknown slug | 1 | empty | `INVALID_ARGUMENTS` envelope |
| No slugs given | 1 | empty | `MISSING_ARGUMENT` envelope (an empty list is never a successful no-op) |

#### Dry run (schema 3)

Non-destructive; built from the SCAN-TIME split components (no re-walk).
`bytes_would_free`/`total_would_free` count **exact bytes only**; estimated
bytes ride in the additive fields. Entries reuse the plan shape (`state`,
`action`, components):

```json
{
  "dry_run": true,
  "total_would_free": 13204889600,
  "total_estimated_up_to_bytes": 32000000,
  "results": [
    {
      "slug": "xcode_derived_data",
      "name": "Xcode Derived Data",
      "state": "measured",
      "action": "clean",
      "bytes_would_free": 13204889600,
      "exact_bytes": 13204889600,
      "estimated_up_to_bytes": 32000000,
      "freed_human": "13.2 GB + up to 32 MB more"
    }
  ]
}
```

---

### `--cli smart-clean <gb> [--confirm|--dry-run]`

Automatically cleans safe categories until the target GB of free space is
reclaimed. **Destructive — since schema 3 it requires `--confirm`**, with the
same confirmation gate, `ROOT_REFUSED` euid-0 refusal, and exit-code policy
as `clean` (the `CONFIRMATION_REQUIRED` details carry `"command":
"smart-clean"`, `target_gb`, the `plan`, and the projected `target_met`).

**Arguments:**
- `<gb>` -- Target gigabytes to free (floating point). ABSENT defaults to
  5.0; a PRESENT but non-numeric value is refused with `INVALID_ARGUMENTS`
  (never silently defaulted). Must be finite, non-negative, and at most
  10^9 — anything else (including `nan` and `inf`) is refused with
  `INVALID_ARGUMENTS` before any scan or gate
- `--confirm` -- Actually delete
- `--dry-run` -- Preview without deleting (needs no `--confirm`)

**Candidate policy (schema 3):** only cleanly-`measured` categories with
bytes qualify. Categories that scanned `denied` or `partiallyDenied` are
skipped (the auto path never rides on a floor measurement), as are
caution-risk categories. Safe risk sorts before review; larger first within a
tier.

**Target semantics (schema 3):** only EXACT bytes advance `target_met` —
delete-time measured unique-inode bytes on a real run, scan-time exact
components on a dry run (no re-walk). A hardlink-heavy category may be
cleaned, but its `estimated_up_to_bytes` never mark the target met.

**Fallback disclosure (schema 3):** because the real loop advances on
DELETE-TIME bytes, an early category that shrinks or partially fails causes
later candidates to be cleaned too. The plan and dry-run output therefore
list EVERY eligible candidate: entries past the projected target-met point
carry `action: "clean_if_needed"` with projected `bytes_freed` 0 and their
would-free components intact. Projected totals and `target_met` count the
unconditional (`"clean"`) entries only.

**Output schema:**

```json
{
  "target_gb": 10.0,
  "target_met": true,
  "total_freed_bytes": 13204889600,
  "total_estimated_up_to_bytes": 0,
  "total_freed": "13.2 GB",
  "dry_run": false,
  "cleaned": [
    {
      "slug": "xcode_derived_data",
      "name": "Xcode Derived Data",
      "bytes_freed": 13204889600,
      "exact_bytes": 13204889600,
      "estimated_up_to_bytes": 0,
      "freed_human": "13.2 GB",
      "success": true
    }
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `target_gb` | number | yes | Requested target in GB |
| `target_met` | boolean | yes | Whether EXACT freed bytes met the target |
| `total_freed_bytes` | integer | yes | **Exact bytes only** (schema 3) |
| `total_estimated_up_to_bytes` | integer | yes | Hardlinked/command bytes that MAY have been freed |
| `total_freed` | string | yes | Human-readable component phrase |
| `dry_run` | boolean | yes | Whether this was a dry run |
| `cleaned` | object[] | yes | Per-category details, in cleaning order |
| `cleaned[].slug` | string | yes | Category slug |
| `cleaned[].name` | string | yes | Category name |
| `cleaned[].state` | string | dry run only | Scan state (plan shape — always `"measured"`, candidates are filtered to it) |
| `cleaned[].action` | string | dry run only | Plan action: `"clean"`, or `"clean_if_needed"` for fallback candidates past the projected target-met point |
| `cleaned[].bytes_freed` | integer | yes | Exact bytes freed (== `exact_bytes`) |
| `cleaned[].exact_bytes` | integer | yes | Exact component |
| `cleaned[].estimated_up_to_bytes` | integer | yes | Estimated component |
| `cleaned[].freed_human` | string | yes | Human-readable component phrase |
| `cleaned[].success` | boolean | real run only | `false` iff the category reported errors (absent on dry run) |
| `cleaned[].error` | string | no | Error message(s) when `success` is false |

Total failure — at least one category attempted, every attempt errored,
nothing freed — exits 1 `CLEAN_FAILED` with empty stdout (details carry the
per-category attempts). An empty candidate list is a success with
`target_met: false`.

---

### `--cli spotlight`

Tags discovered cache directories with Spotlight metadata for `mdfind`
discovery. Since schema 3 every root is admitted through the deletion-path
guard BEFORE any xattr/marker write, and roots whose scan was denied are
never written to; refusals are reported in the additive `refused` array.

**Output schema:**

```json
{
  "tagged_count": 5,
  "directories": [
    {
      "slug": "xcode_derived_data",
      "path": "/Users/user/Library/Developer/Xcode/DerivedData",
      "size": "15 GB",
      "xattr_written": true,
      "marker_written": true
    }
  ],
  "refused_count": 1,
  "refused": [
    {
      "slug": "browser_caches",
      "path": "/Users/user/Library/Caches/Google/Chrome",
      "reason": "scan denied (tcc_denied): Operation not permitted"
    }
  ],
  "query_hint": "mdfind 'kMDItemFinderComment == \"cacheout-managed*\"'",
  "marker_hint": "mdfind -name .cacheout-managed"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `tagged_count` | integer | yes | Number of directories tagged (at least one metadata write landed) |
| `directories` | object[] | yes | List of tagged directories |
| `directories[].slug` | string | yes | Category slug |
| `directories[].path` | string | yes | Absolute filesystem path |
| `directories[].size` | string | yes | Human-readable size |
| `directories[].xattr_written` | boolean | yes | Whether the Finder-comment xattr write succeeded (schema 3) |
| `directories[].marker_written` | boolean | yes | Whether the `.cacheout-managed` marker write succeeded (schema 3) |
| `refused_count` | integer | yes | Number of roots refused (schema 3) |
| `refused` | object[] | yes | Roots that got no effective write: guard refusals, scan-denied roots, and roots where BOTH metadata writes failed (schema 3) |
| `refused[].slug` | string | yes | Category slug |
| `refused[].path` | string | yes | Refused root path |
| `refused[].reason` | string | yes | Why — a guard refusal message, `scan denied (<kind>): <message>`, or `metadata writes failed: ...` |
| `query_hint` | string | yes | Example mdfind query for xattr-based discovery |
| `marker_hint` | string | yes | Example mdfind query for marker-file discovery |

---

### `--cli memory-stats`

Returns system memory statistics as a raw `SystemStatsDTO` snapshot. Does not require the privileged helper. All memory sizes are in bytes; page counts are raw kernel values (multiply by `pageSize` to convert to bytes).

**Output schema:**

```json
{
  "timestamp": "2026-03-10T12:00:00Z",
  "freePages": 131072,
  "activePages": 393216,
  "inactivePages": 196608,
  "wiredPages": 262144,
  "compressorPageCount": 65536,
  "compressedBytes": 2147483648,
  "compressorBytesUsed": 1073741824,
  "compressionRatio": 2.0,
  "pageSize": 16384,
  "purgeableCount": 8192,
  "externalPages": 32768,
  "internalPages": 524288,
  "compressions": 500000,
  "decompressions": 450000,
  "pageins": 100000,
  "pageouts": 5000,
  "swapUsedBytes": 536870912,
  "swapTotalBytes": 4294967296,
  "pressureLevel": 0,
  "memoryTier": "moderate",
  "totalPhysicalMemory": 17179869184
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `timestamp` | string | yes | ISO 8601 timestamp of when this snapshot was captured |
| `freePages` | integer | yes | Free pages available for immediate use |
| `activePages` | integer | yes | Pages currently in active use |
| `inactivePages` | integer | yes | Pages recently used but candidates for reclaim |
| `wiredPages` | integer | yes | Pages wired into memory (cannot be paged out) |
| `compressorPageCount` | integer | yes | Pages held by the in-memory compressor |
| `compressedBytes` | integer | yes | Logical (uncompressed) size of data in the compressor, in bytes |
| `compressorBytesUsed` | integer | yes | Physical storage used by the compressor, in bytes |
| `compressionRatio` | number | yes | `compressedBytes / compressorBytesUsed`. Values > 1.0 indicate effective compression. 0.0 if compressor is empty. |
| `pageSize` | integer | yes | Kernel page size in bytes (typically 16384 on Apple Silicon) |
| `purgeableCount` | integer | yes | Pages marked as purgeable (can be reclaimed without I/O) |
| `externalPages` | integer | yes | File-backed (external) pages |
| `internalPages` | integer | yes | Anonymous (internal) pages |
| `compressions` | integer | yes | Total compression operations since boot |
| `decompressions` | integer | yes | Total decompression operations since boot |
| `pageins` | integer | yes | Total page-in operations since boot |
| `pageouts` | integer | yes | Total page-out operations since boot |
| `swapUsedBytes` | integer | yes | Swap space currently in use, in bytes |
| `swapTotalBytes` | integer | yes | Total swap space available, in bytes |
| `pressureLevel` | integer | yes | Raw kernel memory pressure level from `kern.memorystatus_vm_pressure_level` (0=normal, 1=warn, 2=critical, 4=urgent) |
| `memoryTier` | string | yes | Static hardware memory tier classification from `MemoryTier.detect()`. One of: `"constrained"`, `"moderate"`, `"comfortable"`, `"abundant"`. Based on installed physical RAM (`hw.memsize`), not runtime conditions. |
| `totalPhysicalMemory` | integer | yes | Total installed physical memory in bytes |

> **Note:** This is the raw `SystemStatsDTO` from CacheoutShared, serialized directly via `JSONEncoder`. Field names use camelCase (Swift default). All sizes are in bytes or raw page counts — callers must convert using `pageSize` for display. For runtime pressure classification, use `--cli memory-pressure` which applies the `PressureTier` mapping.

---

### `--cli purge` (Deprecated)

> **Deprecated in schema v2.** Use `--cli intervene pressure-trigger` instead. The `purge` command now redirects to `intervene pressure-trigger` internally. A deprecation warning is emitted to stderr. Output follows the `intervene` JSON schema (not the legacy v1 purge schema).

Internally redirects to `--cli intervene pressure-trigger`. Output follows the `intervene` JSON schema documented below. A deprecation warning is printed to stderr.

See [`--cli intervene`](#--cli-intervene-name---dry-run---confirm---target-pid-n---target-name-name-phase-3) for the output schema.

---

### `--cli top-processes [--top N]` (Phase 2)

Returns the top N processes sorted by physical memory footprint. Uses `proc_pid_rusage` for per-process metrics; falls back to the privileged helper when EPERM failures exceed 50%.

**Arguments:**
- `--top N` -- Number of processes to return (default: 10)

**Output schema:**

```json
{
  "source": "proc_pid_rusage",
  "partial": false,
  "results": [
    {
      "pid": 1234,
      "name": "Safari",
      "physFootprint": 2147483648,
      "lifetimeMaxFootprint": 3221225472,
      "pageins": 50000,
      "jetsamPriority": 10,
      "jetsamLimit": -1,
      "isRosetta": false,
      "leakIndicator": 1.5
    }
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | string | yes | Data source: `"proc_pid_rusage"` or `"privileged_helper"` |
| `partial` | boolean | yes | Whether results are incomplete (e.g., EPERM on some processes without helper). A stderr warning is emitted when `true`. |
| `results` | object[] | yes | `ProcessEntryDTO` entries sorted by footprint descending |
| `results[].pid` | integer | yes | Process ID |
| `results[].name` | string | yes | Process name (from `proc_name`, truncated to MAXCOMLEN) |
| `results[].physFootprint` | integer | yes | Current physical footprint in bytes |
| `results[].lifetimeMaxFootprint` | integer | yes | Lifetime peak physical footprint in bytes |
| `results[].pageins` | integer | yes | Cumulative page-in count |
| `results[].jetsamPriority` | integer | yes | Jetsam priority band (-1 if not in priority list) |
| `results[].jetsamLimit` | integer | yes | Jetsam memory limit in MB (-1 if not in priority list) |
| `results[].isRosetta` | boolean | yes | Whether process runs under Rosetta 2 translation |
| `results[].leakIndicator` | number | yes | Ratio of lifetime max to current footprint. Values near 1.0 suggest a possible leak. |

---

### `--cli memory-pressure` (Phase 2)

Returns current memory pressure classification using `PressureTier`. Combines the raw kernel pressure level with available memory to produce a more nuanced classification than the raw kernel value alone.

**Output schema:**

```json
{
  "pressure_tier": "warning",
  "numeric": 2,
  "available_mb": 1234.5
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `pressure_tier` | string | yes | Runtime pressure classification from `PressureTier.from(pressureLevel:availableMB:)`. One of: `"normal"`, `"elevated"`, `"warning"`, `"critical"`. |
| `numeric` | integer | yes | Raw integer from `kern.memorystatus_vm_pressure_level` (0=normal, 1=warn, 2=critical, 4=urgent) |
| `available_mb` | number | yes | Estimated available memory in MB: `(freePages + inactivePages) * pageSize / 1048576` |

**`pressure_tier` mapping:**

| `pressure_tier` | Conditions | Description |
|-----------------|------------|-------------|
| `"critical"` | `pressureLevel >= 4` OR `available < 512 MB` | Critical pressure, Jetsam kills imminent |
| `"warning"` | `pressureLevel >= 2` OR `available < 1500 MB` | System under memory pressure |
| `"elevated"` | `pressureLevel >= 1` OR `available < 4000 MB` | Slightly elevated pressure |
| `"normal"` | otherwise | Normal operating conditions |

---

### `--cli intervene <name> [--dry-run] [--confirm] [--target-pid N] [--target-name NAME]` (Phase 3)

Executes a named memory intervention. Requires the privileged helper for XPC-backed
interventions; local interventions (flush-windowserver, delete-snapshot) run in-process.

**Arguments:**
- `<name>` -- Intervention name (see table below). Both hyphenated (`pressure-trigger`) and underscored (`pressure_trigger`) forms are accepted; the canonical form is hyphenated.
- `--dry-run` -- Preview the intervention without executing (reads still execute)
- `--confirm` -- Required for Tier 2 and Tier 3 interventions (unless `--dry-run`)
- `--target-pid N` -- Target a specific PID (jetsam-limit and signal interventions)
- `--target-name NAME` -- Target process name (signal interventions only; required with `--target-pid`)

**Available interventions:**

| Name | Description | Tier | Notes |
|------|-------------|------|-------|
| `pressure-trigger` | Trigger memory purge via `kern.memorypressure_manual_trigger` | 1 (safe) | Requires helper |
| `reduce-transparency` | Enable Reduce Transparency accessibility setting | 1 (safe) | |
| `jetsam-limit` | Set Jetsam memory limit for top processes | 2 (requires `--confirm`) | `--target-pid` for manual override |
| `flush-windowserver` | Flush WindowServer display caches | 2 (requires `--confirm`) | Skipped if headless |
| `compressor-tuning` | Tune VM compressor mode on <= 8 GB machines | 2 (requires `--confirm`) | Skipped on > 8 GB |
| `delete-snapshot` | Clean up local APFS Time Machine snapshots | 2 (requires `--confirm`) | Lists snapshots in dry-run |
| `sigterm-cascade` | Send SIGTERM to target process (single PID, escalates to SIGKILL) | 3 (destructive, requires `--confirm`) | Requires `--target-pid` and `--target-name` |
| `sigstop-freeze` | Freeze target process via SIGSTOP (default 20s, max 120s) | 3 (destructive, requires `--confirm`) | Requires `--target-pid` and `--target-name`; CLI blocks for freeze duration, callers must set timeout > freeze duration |
| `sleep-image-delete` | Delete `/var/vm/sleepimage` via helper | 3 (destructive, requires `--confirm`) | Requires helper |

**Name aliases:** Both hyphenated (CLI) and underscore (spec) forms are accepted. Additionally, these epic naming aliases are supported: `jetsam-hwm` → `jetsam-limit`, `windowserver-flush` → `flush-windowserver`, `snapshot-cleanup` → `delete-snapshot`.

**Output schema:**

```json
{
  "success": true,
  "intervention": "pressure-trigger",
  "reclaimed_bytes": 471859200,
  "reclaimed_mb": 450,
  "dry_run": false,
  "duration_seconds": 3.2,
  "details": {},
  "before": {
    "free_mb": 1024.0,
    "inactive_mb": 2048.0,
    "compressed_mb": 512.0,
    "purgeable_mb": 128.0
  },
  "after": {
    "free_mb": 1474.2,
    "inactive_mb": 2048.0,
    "compressed_mb": 512.0,
    "purgeable_mb": 64.0
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `success` | boolean | yes | Whether the intervention succeeded |
| `intervention` | string | yes | Canonical (hyphenated) name of the intervention executed |
| `reclaimed_bytes` | integer | yes | Bytes reclaimed (0 if not measurable) |
| `reclaimed_mb` | number | yes | MB reclaimed |
| `dry_run` | boolean | yes | Whether this was a dry run |
| `duration_seconds` | number | yes | Wall-clock duration |
| `details` | object | yes | Intervention-specific details (varies by intervention) |
| `before` | object | no | Memory snapshot before intervention (absent on snapshot failure) |
| `after` | object | no | Memory snapshot after intervention (absent on snapshot failure) |
| `error` | string | no | Error message if `success` is false |

---

### `--cli system-health` (Phase 4)

Returns a combined health report covering disk, memory, swap, and active alerts.

**Output schema:**

```json
{
  "disk": {
    "total_bytes": 500068036608,
    "free_bytes": 25127321600,
    "free_gb": 23.4,
    "used_percent": 94.97
  },
  "memory": {
    "total_physical_mb": 16384.0,
    "estimated_available_mb": 5120.6,
    "pressure_level": "nominal",
    "pressure_level_numeric": 1,
    "memory_tier": "moderate",
    "compressor_ratio": 2.3
  },
  "swap": {
    "used_mb": 512.0,
    "total_mb": 4096.0
  },
  "alerts": []
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `disk` | object | yes | Disk space summary |
| `memory` | object | yes | Memory summary |
| `swap` | object | yes | Swap summary |
| `alerts` | object[] | yes | Active alerts (same schema as alert.json entries) |

---

## CLI Error Contract

All CLI commands follow a consistent error reporting contract.

### Success

- **Exit code:** 0
- **stdout:** JSON output (command-specific schema as documented above). CLI success output is **not** wrapped in an `{"ok": true, "data": ...}` envelope -- the raw schema is emitted directly. The `{"ok": true, "data": ...}` envelope is used only by the [Socket Protocol](#socket-protocol).
- **stderr:** Empty (or human-readable diagnostics/warnings, never machine-parsed)

### Failure

- **Exit code:** Non-zero (typically 1)
- **stderr:** JSON error object (structured, machine-parseable):

```json
{
  "ok": false,
  "error": {
    "code": "HELPER_UNREACHABLE",
    "message": "Privileged helper not responding via XPC (timeout)"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `ok` | boolean | yes | Always `false` for errors |
| `error` | object | yes | Error details |
| `error.code` | string | yes | Machine-readable error code (UPPER_SNAKE_CASE) |
| `error.message` | string | yes | Human-readable error description |

- **stdout:** Empty on failure.

> **Migration note (v1 to v2):** The error envelope format is gated by `schema_version`, the same mechanism used for `pressure_level` migration. When `schema_version` is absent or 1 (v1 CLI), stderr may contain ad-hoc JSON (e.g. `{"success": false, "error": "..."}`). When `schema_version >= 2` (v2 CLI), stderr uses the standardized `{"ok": false, "error": {"code": "...", "message": "..."}}` envelope above. MCP server callers should: (1) check exit code, (2) check `schema_version` from cached `--cli version` output, (3) parse stderr accordingly. If `schema_version` is unknown or 1, fall back to legacy parsing: look for a `"success": false` key or treat the entire stderr string as the error message. Non-JSON stderr content should always be ignored gracefully.

### Error Codes

| Code | Description |
|------|-------------|
| `UNKNOWN_COMMAND` | Unrecognized CLI subcommand |
| `USAGE_ERROR` | Malformed CLI invocation (missing subcommand) |
| `MISSING_ARGUMENT` | Required positional argument not provided |
| `INVALID_ARGUMENTS` | Missing, malformed, or out-of-range arguments (e.g. `--target-pid`) |
| `SYSCTL_FAILED` | A sysctl query failed (OS-level error) |
| `HELPER_NOT_INSTALLED` | Privileged helper not installed |
| `HELPER_UNREACHABLE` | Privileged helper not responding via XPC |
| `PURGE_FAILED` | _(Legacy, schema v1 only)_ `/usr/sbin/purge` exited with non-zero status |
| `PURGE_TIMEOUT` | _(Legacy, schema v1 only)_ `/usr/sbin/purge` timed out |
| `PURGE_LAUNCH_FAILED` | _(Legacy, schema v1 only)_ `/usr/sbin/purge` could not be launched |
| `PURGE_NOT_FOUND` | _(Legacy, schema v1 only)_ `/usr/sbin/purge` binary not found |
| `PURGE_NOT_EXECUTABLE` | _(Legacy, schema v1 only)_ `/usr/sbin/purge` binary not executable |
| `UNKNOWN_INTERVENTION` | Unrecognized intervention name |
| `CONFIRMATION_REQUIRED` | Destructive command invoked without `--confirm` or `--dry-run`: `clean`/`smart-clean` (schema 3 — `details` carries the cleaning plan) and tier 2/3 interventions |
| `ROOT_REFUSED` | `clean`/`smart-clean` invoked with root privileges (euid 0) — refused regardless of flags (schema 3) |
| `INTERVENTION_FAILED` | A named intervention failed during execution |
| `PERMISSION_DENIED` | Insufficient privileges for the requested operation |
| `DISK_INFO_FAILED` | Failed to read disk information |
| `SNAPSHOT_FAILED` | Failed to capture memory snapshot (before or after) |
| `MEMORY_STATS_TIMEOUT` | Memory stats capture timed out |
| `ENCODING_FAILED` | JSON encoding failed |
| `TEMP_FILE_FAILED` | Failed to create temporary file |
| `PAGE_SIZE_QUERY_FAILED` | Failed to query VM page size |
| `VM_STATS_QUERY_FAILED` | Failed to query host_statistics64 |
| `SCAN_FAILED` | Cache scan failed |
| `CLEAN_FAILED` | TOTAL clean failure: every requested/attempted category errored and nothing was freed (partial failures exit 0 with per-item `success` flags — schema 3) |

### Subprocess Timeout

MCP server callers should enforce a **30-second subprocess timeout** when invoking any CLI command. If the process does not exit within 30 seconds, send SIGTERM, wait 2 seconds, then SIGKILL.

---

## Alert Schema

Alerts are written to `~/.cacheout/alert.json` by the watchdog process. The MCP server reads this file to surface memory/disk warnings to the user.

### Schema

```json
{
  "schema_version": 1,
  "triggered_at": "2026-03-09T14:22:00Z",
  "level": "warning",
  "triggers": ["swap_velocity:4.2gb_per_5m", "compressor_thrashing"],
  "disk_free_gb": 45.2,
  "swap_used_mb": 8499.2,
  "pressure_level": "warn",
  "pressure_level_numeric": 2,
  "compressor_ratio": 1.4,
  "compressor_trend": "degrading",
  "swap_velocity_gb_per_5m": 4.2,
  "recommended_action": "smart_clean",
  "recommended_target_gb": 15.0,
  "cleanup_performed": false
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | integer | yes | Alert schema version (currently 1) |
| `triggered_at` | string | yes | ISO 8601 timestamp in UTC (e.g. `"2026-03-09T14:22:00Z"`) |
| `level` | string | yes | Alert severity: `"info"`, `"warning"`, `"critical"` |
| `triggers` | string[] | yes | List of trigger conditions that fired |
| `disk_free_gb` | number | yes | Free disk space at alert time in GB |
| `swap_used_mb` | number | yes | Swap used at alert time in MB (consistent with CLI `memory-stats` output) |
| `pressure_level` | string | yes | Standardized pressure enum: `"nominal"`, `"warn"`, `"critical"` |
| `pressure_level_numeric` | integer | yes | Raw integer from `kern.memorystatus_vm_pressure_level` |
| `compressor_ratio` | number | yes | Compression ratio at alert time. Values > 1.0 = effective compression. |
| `compressor_trend` | string | no | Trend direction: `"improving"`, `"stable"`, `"degrading"`. Requires multiple samples; omitted from single-sample alerts. |
| `swap_velocity_gb_per_5m` | number | no | Rate of swap growth in GB per 5 minutes. Requires historical samples; omitted from single-sample alerts. |
| `recommended_action` | string | yes | Suggested action: `"smart_clean"`, `"purge"`, `"intervene"`, `"none"` |
| `recommended_target_gb` | number | no | Target GB to free (only present when `recommended_action` is `"smart_clean"`) |
| `cleanup_performed` | boolean | yes | Whether automated cleanup was executed |

### Trigger Strings

Trigger strings use the format `<metric>:<value>`. Examples:

| Trigger | Description |
|---------|-------------|
| `swap_velocity:4.2gb_per_5m` | Swap growing at 4.2 GB per 5 minutes |
| `compressor_thrashing` | Compression ratio degrading rapidly |
| `pressure_critical` | Memory pressure at critical level |
| `disk_low:5.2gb` | Free disk space below threshold |
| `jetsam_kills:3_in_5m` | Multiple Jetsam kills detected |

### Timestamps

All timestamps in alert.json and CLI output use **ISO 8601 format in UTC** (e.g. `"2026-03-09T14:22:00Z"`). Fractional seconds are optional. Consumers must parse both `"2026-03-09T14:22:00Z"` and `"2026-03-09T14:22:00.123Z"` formats.

---

## Socket Protocol

The daemon mode exposes a Unix domain socket at `~/.cacheout/status.sock` for real-time communication.

### Transport

- **Path:** `~/.cacheout/status.sock`
- **Encoding:** UTF-8
- **Framing:** Newline-delimited JSON (one JSON object per line, terminated by `\n`)
- **Direction:** Request-response. Client sends one request line, server sends one response line.
- **Max message size:** 64 KB. Messages exceeding this limit are rejected with an error response.
- **Client read timeout:** 30 seconds. If the server does not respond within 30 seconds, the client should close the connection and retry.

### Request Format

```json
{"cmd": "<command_name>", ...optional_params}
```

### Response Format

**Success:**

```json
{"ok": true, "data": { ... }}
```

**Error:**

```json
{"ok": false, "error": {"code": "UNKNOWN_COMMAND", "message": "Unknown command: foo"}}
```

### Commands

#### `stats`

Returns full system memory statistics.

```
-> {"cmd": "stats"}\n
<- {"ok": true, "data": { ...same schema as --cli memory-stats... }}\n
```

#### `processes`

Returns top processes by memory footprint.

```
-> {"cmd": "processes", "top_n": 10}\n
<- {"ok": true, "data": { ...same schema as --cli top-processes... }}\n
```

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `top_n` | integer | no | 10 | Number of top processes to return |

#### `health`

Returns health score, active alerts, and helper availability.

```
-> {"cmd": "health"}\n
<- {"ok": true, "data": {"health_score": 75, "alerts": [...], "helper_available": true}}\n
```

| Field | Type | Description |
|-------|------|-------------|
| `health_score` | integer | 0-100 health score, or -1 if no data |
| `alerts` | array | Active `DaemonAlert` objects |
| `helper_available` | boolean | Whether the XPC helper is registered |

#### `compressor`

Returns compressor statistics from the latest snapshot.

```
-> {"cmd": "compressor"}\n
<- {"ok": true, "data": {"compressed_bytes": ..., "compressor_bytes_used": ..., "compression_ratio": ..., "compressor_page_count": ...}}\n
```

#### `config_status`

Returns autopilot config generation and load status.

```
-> {"cmd": "config_status"}\n
<- {"ok": true, "data": {"generation": 0, "last_reload": null, "status": "no_config", "error": null}}\n
```

| Field | Type | Description |
|-------|------|-------------|
| `generation` | integer | Config generation counter (0 = never loaded) |
| `last_reload` | string? | ISO 8601 timestamp of last reload attempt |
| `status` | string | `"no_config"`, `"ok"`, or `"error"` |
| `error` | string? | Error message if last load failed |

#### `validate_config`

Dry-run validation of an autopilot config file.

```
-> {"cmd": "validate_config", "path": "/path/to/config.json"}\n
<- {"ok": true, "data": {"valid": true, "errors": []}}\n
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | yes | Absolute path to config file to validate |

---

## Schema Versioning Strategy

### Version Fields

| Field | Location | Purpose |
|-------|----------|---------|
| `version` | `--cli version` output | Application SemVer version |
| `schema_version` | `--cli version` output, `alert.json` | Protocol schema version |
| `capabilities` | `--cli version` output | Feature discovery array |

### Versioning Rules

1. **`schema_version`** is an integer that starts at 1 and increments monotonically. Current version: **3** (`clean`/`smart-clean` require `--confirm`; clean byte totals became exact-only with additive `*_estimated_up_to_bytes`; `results[].category` emits the slug; total clean failure exits 1 `CLEAN_FAILED`). Version 2 added `intervene` with all tiers and deprecated `purge`.

   **`schema_version >= 3` ⇒ `clean` and `smart-clean` require `--confirm`.** MCP servers upgrading past this version MUST add `--confirm` to destructive invocations and treat a `CONFIRMATION_REQUIRED` stderr envelope as "re-invoke with --confirm after user consent", not as a failure.

2. **Additive changes** (new optional fields, new commands) do NOT bump `schema_version`. The MCP server discovers new commands via the `capabilities` array.

3. **Breaking changes** (removing fields, changing field types, renaming fields) MUST bump `schema_version`. Both repos must coordinate the version bump.

4. **`capabilities` array** is the primary mechanism for feature discovery. The MCP server checks this array before calling any CLI command.

5. **Forward compatibility:** Consumers must ignore unknown JSON keys. New fields may appear in any response without a schema version bump.

6. **Backward compatibility:** Required fields documented in this protocol will not be removed without a `schema_version` bump. Optional fields may be omitted in older versions.

### Pressure Level Standardization

`pressure_level` is always a **string enum** with three values:

| Value | Description |
|-------|-------------|
| `"nominal"` | Normal operating conditions |
| `"warn"` | System under memory pressure |
| `"critical"` | Critical memory pressure |

When a numeric representation is needed, it is provided as a separate field named `pressure_level_numeric` (integer). Both fields are always present together. This avoids ambiguity between the raw kernel integer and the standardized string.

### Required vs Optional Fields and Nullability

- Fields marked "Required: yes" in this document are guaranteed to be present in the response.
- Fields marked "Required: no" may be absent from the response.
- **OS-dependent sysctls:** Some fields depend on sysctl values that may not be available on all macOS versions. When a sysctl is unavailable:
  - Numeric fields default to `0` or `0.0`
  - The CLI logs a warning to stderr
  - The field remains present in the output (never null for required fields)
- Required fields are never `null`. If a value cannot be determined, a sensible default is used (0 for numbers, `""` for strings, `[]` for arrays).

### Units Documentation

All numeric fields follow these conventions:

| Suffix | Unit | Example |
|--------|------|---------|
| `_bytes` | Bytes (integer) | `phys_footprint_bytes: 2147483648` |
| `_mb` | Megabytes (floating point, 1 MB = 1048576 bytes) | `free_mb: 2048.5` |
| `_gb` | Gigabytes (floating point, 1 GB = 1073741824 bytes) | `free_gb: 23.4` |
| `_seconds` | Seconds (floating point) | `duration_seconds: 3.5` |
| `_per_5m` | Rate per 5 minutes | `swap_velocity_gb_per_5m: 4.2` |
| (no suffix) | Context-dependent (documented per field) | `compressor_ratio: 2.3` |
