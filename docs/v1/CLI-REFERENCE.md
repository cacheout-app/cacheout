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
  "schema_version": 3,
  "version": "2.2.0"
}
```

`schema_version >= 3` means `clean` and `smart-clean` require `--confirm`
(see below and PROTOCOL.md).

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
    "estimated_up_to_bytes": 0,
    "exact_bytes": 5368709120,
    "exists": true,
    "item_count": 15234,
    "name": "Xcode DerivedData",
    "rebuild_note": "Xcode rebuilds on next build",
    "risk_level": "safe",
    "size_bytes": 5368709120,
    "size_human": "5 GB",
    "slug": "xcode_derived_data",
    "state": "measured"
  }
]
```

Results are sorted by `size_bytes` descending.

**Split components + scan state (schema 3):**

- `state` — one of `missing`, `empty`, `measured`, `partiallyDenied`,
  `denied`. A `denied` category was NOT measured; its zero size never means
  "nothing there".
- `exact_bytes` — bytes on unique inodes; deletion verifiably frees them.
- `estimated_up_to_bytes` — hardlinked bytes that MAY be freed.
  `size_bytes` stays the compatibility sum of both.
- `scan_error` (`{kind, message}`) appears on `denied`/`partiallyDenied`
  entries; `grant_hint` appears when `kind` is `tcc_denied` — a CLI process
  is denied silently by macOS, so the JSON carries the Full Disk Access
  remedy.

---

### `clean`

Clean specific categories by slug. **Destructive — requires `--confirm`
(schema 3).**

```bash
# Clean specific categories
Cacheout --cli clean xcode_derived_data npm_cache yarn_cache --confirm

# Preview without deleting (no --confirm needed)
Cacheout --cli clean xcode_derived_data --dry-run
```

**Options:**

| Flag | Description |
|------|-------------|
| `--confirm` | Actually delete. Without it (and without `--dry-run`) the command refuses: exit 1, empty stdout, `CONFIRMATION_REQUIRED` on stderr with the cleaning plan in `details` |
| `--dry-run` | Preview what would be cleaned without deleting (wins even beside `--confirm`) |

Running as root (euid 0) is refused with `ROOT_REFUSED`, flags or not.
Calling `clean` with no slugs is a `MISSING_ARGUMENT` usage error; unknown
slugs are `INVALID_ARGUMENTS`.

**Output (unconfirmed — stderr, exit 1; stdout stays empty):**
```json
{
  "details": {
    "command": "clean",
    "plan": [
      {
        "action": "clean",
        "estimated_up_to_bytes": 0,
        "exact_bytes": 5368709120,
        "name": "Xcode DerivedData",
        "slug": "xcode_derived_data",
        "state": "measured"
      }
    ],
    "total_estimated_up_to_bytes": 0,
    "total_exact_bytes": 5368709120
  },
  "error": {
    "code": "CONFIRMATION_REQUIRED",
    "message": "clean deletes cache contents and requires --confirm (preview with --dry-run)"
  },
  "ok": false
}
```

`plan[].action` mirrors what the confirmed run would do: `clean`,
`clean_with_warning` (a `partiallyDenied` scan — measured bytes only),
`refuse` (a `denied` scan), or `skip` (missing/empty).

**Output (confirmed clean):**
```json
{
  "dry_run": false,
  "results": [
    {
      "bytes_freed": 5368709120,
      "category": "xcode_derived_data",
      "estimated_up_to_bytes": 0,
      "exact_bytes": 5368709120,
      "freed_human": "5 GB",
      "name": "Xcode DerivedData",
      "success": true
    }
  ],
  "total_estimated_up_to_bytes": 0,
  "total_freed": "5 GB",
  "total_freed_bytes": 5368709120
}
```

Byte totals are exact-only (verifiably freed unique-inode bytes);
hardlinked/command-freed bytes ride in `estimated_up_to_bytes` /
`total_estimated_up_to_bytes` and are never folded into the totals. Every
requested slug gets a result row with a `success` flag; naming a `denied`
category yields a per-item error, naming a `partiallyDenied` category
proceeds with a `warning` field.

**Output (dry run):** same shape as the plan, plus exact-only
`bytes_would_free`/`total_would_free`:
```json
{
  "dry_run": true,
  "results": [
    {
      "action": "clean",
      "bytes_would_free": 5368709120,
      "estimated_up_to_bytes": 0,
      "exact_bytes": 5368709120,
      "freed_human": "5 GB",
      "name": "Xcode DerivedData",
      "slug": "xcode_derived_data",
      "state": "measured"
    }
  ],
  "total_estimated_up_to_bytes": 0,
  "total_would_free": 5368709120
}
```

---

### `smart-clean`

Automatically clean safe categories until a target amount of space is freed.
**Destructive — requires `--confirm` (schema 3)**, with the same
confirmation gate, root refusal, and exit-code policy as `clean`.

```bash
# Free up to 5 GB (default)
Cacheout --cli smart-clean --confirm

# Free up to 10 GB
Cacheout --cli smart-clean 10.0 --confirm

# Preview without deleting (no --confirm needed)
Cacheout --cli smart-clean 10.0 --dry-run
```

**Behavior:**
1. Scans all categories
2. Keeps only cleanly-measured categories with bytes — `denied` and
   `partiallyDenied` scans are skipped (the auto path never rides on a
   floor measurement), as are Caution-level categories
3. Sorts by risk level (Safe first), then by size descending
4. Cleans categories until target bytes are freed or all eligible categories
   are exhausted — only EXACT bytes advance the target; estimated
   (hardlinked/command) bytes never mark `target_met`. Because the real loop
   advances on delete-time bytes, plan/dry-run output lists every eligible
   candidate: entries past the projected target-met point carry
   `action: "clean_if_needed"` (cleaned only if earlier categories
   under-deliver) with projected `bytes_freed` 0

**Options:**

| Argument | Description | Default |
|----------|-------------|---------|
| `<targetGB>` | Amount of space to free in GB — must be numeric, finite, non-negative, and at most 10^9; a present but malformed value is refused with `INVALID_ARGUMENTS`, never silently defaulted | `5.0` (when absent) |
| `--confirm` | Actually delete | Off (refuses) |
| `--dry-run` | Preview without deleting (uses scan-time exact components, no re-walk) | Off |

**Output:**
```json
{
  "cleaned": [
    {
      "bytes_freed": 5368709120,
      "estimated_up_to_bytes": 0,
      "exact_bytes": 5368709120,
      "freed_human": "5 GB",
      "name": "Xcode DerivedData",
      "slug": "xcode_derived_data",
      "success": true
    }
  ],
  "dry_run": false,
  "target_gb": 10.0,
  "target_met": false,
  "total_estimated_up_to_bytes": 0,
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
1. Admits each cache root through the deletion-path guard — a refused root
   (or one whose scan was denied) gets NO writes and is reported in
   `refused` (schema 3)
2. Sets `com.apple.metadata:kMDItemFinderComment` xattr on each admitted
   cache directory
3. Writes a `.cacheout-managed` marker file inside each admitted cache
   directory

Write outcomes are captured per directory (`xattr_written` /
`marker_written`); a root where BOTH writes fail is reported in `refused`
(`metadata writes failed: ...`), never claimed as tagged.

**Output:**
```json
{
  "directories": [
    {
      "marker_written": true,
      "path": "/Users/you/Library/Developer/Xcode/DerivedData",
      "size": "5 GB",
      "slug": "xcode_derived_data",
      "xattr_written": true
    }
  ],
  "marker_hint": "mdfind -name .cacheout-managed",
  "query_hint": "mdfind 'kMDItemFinderComment == \"cacheout-managed*\"'",
  "refused": [
    {
      "path": "/Users/you/Library/Caches/SomeDenied",
      "reason": "scan denied (tcc_denied): Operation not permitted",
      "slug": "some_denied"
    }
  ],
  "refused_count": 1,
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
| `0` | Success — including a PARTIAL clean (per-item `success` flags in the JSON) |
| `1` | Usage error, unconfirmed destructive command (`CONFIRMATION_REQUIRED`), root refusal (`ROOT_REFUSED`), or TOTAL clean failure (`CLEAN_FAILED`) |

On exit 1, stdout is empty and stderr carries the structured
`{"ok": false, "error": {"code": ..., "message": ...}}` envelope
(plus `details` where documented). See PROTOCOL.md for the full contract.

## Notes

- CLI mode runs headlessly — no SwiftUI app, no window, no menubar
- Cleanup in CLI mode always uses permanent delete (not Trash)
- `clean`/`smart-clean` refuse to run as root (euid 0)
- JSON output uses `JSONSerialization` with `.prettyPrinted` and `.sortedKeys`
