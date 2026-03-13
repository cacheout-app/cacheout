# CLI Reference

Cacheout includes a headless CLI mode for scripting, automation, and MCP server integration.

## Invocation

```bash
Cacheout --cli <command> [options]
```

All output is JSON (pretty-printed with sorted keys) to stdout. Errors go to stderr.

## Commands

### `version`

Print version information.

```bash
Cacheout --cli version
```

**Output:**
```json
{
  "app": "Cacheout",
  "mode": "cli",
  "version": "1.0.0"
}
```

---

### `disk-info`

Show current disk space information.

```bash
Cacheout --cli disk-info
```

**Output:**
```json
{
  "free": "120.5 GB",
  "free_bytes": 129395425280,
  "free_gb": 120.5,
  "total": "500 GB",
  "total_bytes": 536870912000,
  "used": "379.5 GB",
  "used_bytes": 407475486720,
  "used_percent": 75.9
}
```

---

### `scan`

Scan all cache categories and report sizes.

```bash
Cacheout --cli scan
```

**Output:**
```json
[
  {
    "description": "Build artifacts and indexes. Xcode rebuilds automatically.",
    "exists": true,
    "item_count": 15234,
    "name": "Xcode DerivedData",
    "rebuild_note": "Xcode rebuilds on next build",
    "risk_level": "safe",
    "size_bytes": 5368709120,
    "size_human": "5 GB",
    "slug": "xcode_derived_data"
  }
]
```

Results are sorted by `size_bytes` descending.

---

### `clean`

Clean specific categories by slug.

```bash
# Clean specific categories
Cacheout --cli clean xcode_derived_data npm_cache yarn_cache

# Preview without deleting
Cacheout --cli clean xcode_derived_data --dry-run
```

**Options:**

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview what would be cleaned without deleting |

**Output (actual clean):**
```json
{
  "dry_run": false,
  "results": [
    {
      "bytes_freed": 5368709120,
      "category": "Xcode DerivedData",
      "freed_human": "5 GB",
      "success": true
    }
  ],
  "total_freed": "5 GB",
  "total_freed_bytes": 5368709120
}
```

**Output (dry run):**
```json
{
  "dry_run": true,
  "results": [
    {
      "bytes_would_free": 5368709120,
      "freed_human": "5 GB",
      "name": "Xcode DerivedData",
      "slug": "xcode_derived_data"
    }
  ],
  "total_would_free": 5368709120
}
```

---

### `smart-clean`

Automatically clean safe categories until a target amount of space is freed.

```bash
# Free up to 5 GB (default)
Cacheout --cli smart-clean

# Free up to 10 GB
Cacheout --cli smart-clean 10.0

# Preview without deleting
Cacheout --cli smart-clean 10.0 --dry-run
```

**Behavior:**
1. Scans all categories
2. Sorts by risk level (Safe first), then by size descending
3. Skips Caution-level categories entirely
4. Cleans categories until target bytes are freed or all eligible categories are exhausted

**Options:**

| Argument | Description | Default |
|----------|-------------|---------|
| `<targetGB>` | Amount of space to free in GB | `5.0` |
| `--dry-run` | Preview without deleting | Off |

**Output:**
```json
{
  "cleaned": [
    {
      "bytes_freed": 5368709120,
      "freed_human": "5 GB",
      "name": "Xcode DerivedData"
    }
  ],
  "dry_run": false,
  "target_gb": 10.0,
  "target_met": false,
  "total_freed": "5 GB",
  "total_freed_bytes": 5368709120
}
```

---

### `spotlight`

Tag all discovered cache directories with Spotlight metadata for system-wide discovery.

```bash
Cacheout --cli spotlight
```

**What it does:**
1. Sets `com.apple.metadata:kMDItemFinderComment` xattr on each cache directory
2. Writes a `.cacheout-managed` marker file inside each cache directory

**Output:**
```json
{
  "directories": [
    {
      "path": "/Users/you/Library/Developer/Xcode/DerivedData",
      "size": "5 GB",
      "slug": "xcode_derived_data"
    }
  ],
  "marker_hint": "mdfind -name .cacheout-managed",
  "query_hint": "mdfind 'kMDItemFinderComment == \"cacheout-managed*\"'",
  "tagged_count": 15
}
```

**Finding tagged directories:**
```bash
# Via Finder comment
mdfind 'kMDItemFinderComment == "cacheout-managed*"'

# Via marker file
mdfind -name .cacheout-managed
```

---

### `memory-stats`

Show system memory statistics including pressure level, memory tier, and compressor health.

```bash
Cacheout --cli memory-stats
```

**Output:**
```json
{
  "active_mb": 4096.0,
  "compressed_mb": 512.0,
  "compressor_ratio": 3.2,
  "estimated_available_mb": 2048.0,
  "free_mb": 1024.0,
  "inactive_mb": 1024.0,
  "memory_tier": "moderate",
  "pressure_level": 1,
  "swap_used_mb": 0.0,
  "total_physical_mb": 8192.0,
  "wired_mb": 2048.0
}
```

**Fields:**

| Field | Description |
|-------|-------------|
| `total_physical_mb` | Total physical RAM (MiB) |
| `free_mb` | Free pages (MiB) |
| `active_mb` | Active pages (MiB) |
| `inactive_mb` | Inactive pages (MiB) |
| `wired_mb` | Wired (non-evictable) pages (MiB) |
| `compressed_mb` | Compressor-occupied memory (MiB) |
| `compressor_ratio` | Ratio of original data to compressed size (>3.0 = good, <1.5 = thrashing) |
| `swap_used_mb` | Swap space in use (MiB) |
| `pressure_level` | macOS memory pressure (1=normal, 2=warn, 4=critical) |
| `memory_tier` | Derived tier: `abundant`, `comfortable`, `moderate`, `constrained`, `critical` |
| `estimated_available_mb` | Free + inactive pages (MiB) — memory available without eviction |

---

### `purge`

Run `/usr/sbin/purge` to flush inactive memory and report before/after delta.

```bash
Cacheout --cli purge
```

**Output:**
```json
{
  "after": {
    "compressed_mb": 480.0,
    "free_mb": 2048.0,
    "inactive_mb": 256.0
  },
  "before": {
    "compressed_mb": 512.0,
    "free_mb": 1024.0,
    "inactive_mb": 1024.0
  },
  "duration_seconds": 1.2,
  "exit_status": 0,
  "reclaimed_mb": 1024.0,
  "success": true
}
```

**Notes:**
- Requires no special privileges (runs as current user)
- 30-second timeout — process is terminated if exceeded
- `reclaimed_mb` = max(0, after.free_mb − before.free_mb)

---

## Category Slugs

Use these slugs with the `clean` command:

| Slug | Category |
|------|----------|
| `xcode_derived_data` | Xcode DerivedData |
| `xcode_device_support` | Xcode Device Support |
| `simulator_devices` | Simulator Devices |
| `swift_pm_cache` | Swift PM Cache |
| `cocoapods_cache` | CocoaPods Cache |
| `homebrew_cache` | Homebrew Cache |
| `npm_cache` | npm Cache |
| `yarn_cache` | Yarn Cache |
| `pnpm_store` | pnpm Store |
| `bun_cache` | Bun Cache |
| `node_gyp_cache` | node-gyp Cache |
| `playwright_browsers` | Playwright Browsers |
| `pip_cache` | pip Cache |
| `uv_cache` | uv Cache |
| `torch_hub` | PyTorch Hub Models |
| `gradle_cache` | Gradle Cache |
| `docker_disk` | Docker Disk Image |
| `vscode_cache` | VS Code Cache |
| `electron_cache` | Electron Cache |
| `browser_caches` | Browser Caches |
| `chatgpt_desktop_cache` | ChatGPT Desktop Cache |
| `prisma_engines` | Prisma Engines |
| `typescript_cache` | TypeScript Build Cache |

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Usage error (bad command or missing arguments) |

## Notes

- CLI mode runs headlessly — no SwiftUI app, no window, no menubar
- Cleanup in CLI mode always uses permanent delete (not Trash)
- JSON output uses `JSONSerialization` with `.prettyPrinted` and `.sortedKeys`
