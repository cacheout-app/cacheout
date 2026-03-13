# CacheOut CLI Protocol

**Version:** 1.0.0
**Schema Version:** 2
**Last Updated:** 2026-03-10

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
  "version": "2.0.0",
  "schema_version": 2,
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
| `clean <slugs...>` | Delete specific cache categories | Existing | No |
| `smart-clean <gb>` | Auto-clean safe categories to free target GB | Existing | No |
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

Scans all cache categories and returns results.

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
    "rebuild_note": "Xcode rebuilds automatically"
  }
]
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `slug` | string | yes | Machine-readable category identifier |
| `name` | string | yes | Human-readable category name |
| `size_bytes` | integer | yes | Size in bytes |
| `size_human` | string | yes | Human-readable size |
| `item_count` | integer | yes | Number of items found |
| `exists` | boolean | yes | Whether the cache directory exists |
| `risk_level` | string | yes | One of: `"safe"`, `"review"`, `"caution"` |
| `description` | string | yes | What this cache category contains |
| `rebuild_note` | string | yes | How this cache is regenerated |

---

### `--cli clean <slugs...> [--dry-run]`

Cleans the specified cache categories by slug.

**Arguments:**
- `<slugs...>` -- One or more category slugs (from `scan` output)
- `--dry-run` -- Preview what would be cleaned without deleting

**Output schema:**

```json
{
  "dry_run": false,
  "total_freed_bytes": 13204889600,
  "total_freed": "13.2 GB",
  "results": [
    {
      "category": "xcode_derived_data",
      "bytes_freed": 13204889600,
      "freed_human": "13.2 GB",
      "success": true
    }
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `dry_run` | boolean | yes | Whether this was a dry run |
| `total_freed_bytes` | integer | yes | Total bytes freed (0 if dry run) |
| `total_freed` | string | yes | Human-readable total freed |
| `results` | object[] | yes | Per-category results |
| `results[].category` | string | yes | Category slug |
| `results[].bytes_freed` | integer | yes | Bytes freed for this category |
| `results[].freed_human` | string | yes | Human-readable bytes freed |
| `results[].success` | boolean | yes | Whether the clean succeeded |
| `results[].error` | string | no | Error message if `success` is false |

**Dry run output** uses `bytes_would_free` instead of `bytes_freed`:

```json
{
  "dry_run": true,
  "total_would_free": 13204889600,
  "results": [
    {
      "slug": "xcode_derived_data",
      "name": "Xcode Derived Data",
      "bytes_would_free": 13204889600,
      "freed_human": "13.2 GB"
    }
  ]
}
```

---

### `--cli smart-clean <gb> [--dry-run]`

Automatically cleans safe categories until the target GB of free space is reclaimed.

**Arguments:**
- `<gb>` -- Target gigabytes to free (floating point)
- `--dry-run` -- Preview what would be cleaned without deleting

**Output schema:**

```json
{
  "target_gb": 10.0,
  "target_met": true,
  "total_freed_bytes": 13204889600,
  "total_freed": "13.2 GB",
  "dry_run": false,
  "cleaned": [
    {
      "name": "Xcode Derived Data",
      "bytes_freed": 13204889600,
      "freed_human": "13.2 GB"
    }
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `target_gb` | number | yes | Requested target in GB |
| `target_met` | boolean | yes | Whether the target was met |
| `total_freed_bytes` | integer | yes | Total bytes freed |
| `total_freed` | string | yes | Human-readable total freed |
| `dry_run` | boolean | yes | Whether this was a dry run |
| `cleaned` | object[] | yes | Per-category cleaning details |
| `cleaned[].name` | string | yes | Category name |
| `cleaned[].bytes_freed` | integer | yes | Bytes freed |
| `cleaned[].freed_human` | string | yes | Human-readable bytes freed |

---

### `--cli spotlight`

Tags discovered cache directories with Spotlight metadata for `mdfind` discovery.

**Output schema:**

```json
{
  "tagged_count": 5,
  "directories": [
    {
      "slug": "xcode_derived_data",
      "path": "/Users/user/Library/Developer/Xcode/DerivedData",
      "size": "15 GB"
    }
  ],
  "query_hint": "mdfind 'kMDItemFinderComment == \"cacheout-managed*\"'",
  "marker_hint": "mdfind -name .cacheout-managed"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `tagged_count` | integer | yes | Number of directories tagged |
| `directories` | object[] | yes | List of tagged directories |
| `directories[].slug` | string | yes | Category slug |
| `directories[].path` | string | yes | Absolute filesystem path |
| `directories[].size` | string | yes | Human-readable size |
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
| `CONFIRMATION_REQUIRED` | Tier 2/3 intervention invoked without `--confirm` or `--dry-run` |
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
| `CLEAN_FAILED` | Cache cleaning failed |

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

1. **`schema_version`** is an integer that starts at 1 and increments monotonically. Current version: **2** (added `intervene` with all tiers, `purge` deprecated).

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
