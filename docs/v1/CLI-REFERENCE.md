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
  "schema_version": 4,
  "version": "2.2.0"
}
```

`schema_version >= 3` means `clean` and `smart-clean` require `--confirm`;
`schema_version >= 4` means `scan` emits the envelope (not an array), clean
targets follow the address grammar, and clean/smart-clean rows carry
`scanner_id`/`item_id` (see below and PROTOCOL.md).

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

Run every registered scanner (the built-in cache categories plus the
per-item scanners `build_artifacts` and `orphaned_caches`) and report the
schema-4 envelope. The
registry in `Sources/Cacheout/Scanner/Categories.swift` is the source of
truth for which categories exist — see [CATEGORIES.md](CATEGORIES.md) for
the full list.

```bash
Cacheout --cli scan
Cacheout --cli scan --orphan-size-floor-mb 100 --orphan-stale-days 30
Cacheout --cli scan --dev-root ~/dev --dev-root /Volumes/Work/code
```

**Options:**

| Flag | Description |
|------|-------------|
| `--orphan-size-floor-mb N` | Orphaned-caches sweep: stale-large size floor in DECIMAL megabytes (positive integer) for this invocation only — overrides the persisted `cacheout.orphanedCaches.sizeFloorMB`, never persisted. Default 50 |
| `--orphan-stale-days N` | Orphaned-caches sweep: stale-large age in days (positive integer) for this invocation only — overrides the persisted `cacheout.orphanedCaches.staleAgeDays`, never persisted. Default 60 |
| `--dev-root PATH` | REPEATABLE. The dev roots the `build_artifacts` scanner walks, for this invocation only — see the precedence and path-form rules below. Never persisted |

Zero, negative, non-numeric, or overflowing flag values are refused with
`INVALID_ARGUMENTS`. The two sweep flags are accepted by `scan` and `clean`
only; every other command refuses them with `INVALID_ARGUMENTS` rather than
silently ignoring them.

#### `--dev-root` (build-artifacts dev roots)

**Precedence.** When one or more `--dev-root` flags are present their values
are the ENTIRE effective root set for that invocation: the persisted
`cacheout.buildArtifacts.devRoots` list (and its seeds) is not consulted, and
nothing is written back. Without the flag, the persisted list resolves exactly
as it does for the app.

**Path forms (pinned).** An ABSOLUTE path (`/Volumes/Work/code`) and a
`~`-expanded path (`~/dev`, `~`) are accepted. ANY other relative path
(`projects/x`) is refused with `INVALID_ARGUMENTS` naming the value — a
cwd-relative dev root would silently depend on the directory you happened to
run from. (The persisted list's home-relative names, e.g. `Documents`, are a
store-internal spelling and are not a CLI input form.)

**Same policy as the persisted list.** Values run the shared container-root
admission policy: the filesystem root `/`, any volume root or mount point,
and `$HOME` itself — in canonical AND symlink-alias spellings — are refused
with `INVALID_ARGUMENTS` naming the offending root, and nothing is scanned.
Protected children such as `~/Documents` remain legal dev roots. Exact
canonical duplicates collapse (declared spellings preserved); NESTED roots
are kept and walked INDEPENDENTLY.

**Ordering.** Like every flag, `--dev-root` comes AFTER any positional
targets (`Cacheout --cli clean build_artifacts --confirm --dev-root ~/dev`).
See [Argument ordering](#argument-ordering) for the rule that governs every
command.

**Output (schema 4 envelope):**
```json
{
  "categories": [
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
  ],
  "scanner_errors": [],
  "scanner_items": [
    {
      "action": "remove_item",
      "estimated_up_to_bytes": 0,
      "evidence": "node_modules/ beside package.json; last build 94 days ago",
      "exact_bytes": 1200000000,
      "item_count": 40231,
      "item_id": "0d3a9ab9a662fb335a6803cccf0e8a73dd5f1f2a36965334d7f3f5742caeec0e",
      "name": "node_modules",
      "path": "/Users/you/Projects/myapp/node_modules",
      "risk_level": "review",
      "scanner_id": "build_artifacts",
      "size_bytes": 1200000000,
      "state": "measured"
    }
  ],
  "schema_version": 4
}
```

`categories` rows are field-for-field the schema-3 rows, sorted by
`size_bytes` descending. `scanner_items` lists per-item scanner findings —
`item_id` is an OPAQUE 64-char stable id you echo back as a clean target
(`build_artifacts:<item_id>`), never parse or derive. `scanner_errors`
carries root/scanner-level problems (`scanner_id`, `kind`, `detail`, and
`path` for the FILESYSTEM kinds; the NON-filesystem kinds carry no `path`
because none honestly exists — `malformed_outcome` means that scanner's
items were excluded fail-closed, and `config_invalid` means a persisted
config value could not be parsed, so the defaults are in effect and the
stored value was left untouched).

A `build_artifacts` row may additionally carry two ADDITIVE keys:
`logical_bytes` (apparent size, present only when it materially exceeds
`size_bytes` — the sparse-`target/` case where deletion frees LESS than the
apparent size) and `valuables` (release artifacts detected inside the
directory). A row with `valuables` needs an `--acknowledge-valuables` entry
before `clean --confirm` will delete it — see
[Release-artifact acknowledgement](#release-artifact-acknowledgement).

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

Clean addressed targets. **Destructive — requires `--confirm` (schema 3).**

A target (schema 4 address grammar) is one of:

| Form | Meaning |
|------|---------|
| `<category-slug>` | One category aggregate (unchanged from schema 3), e.g. `npm_cache` |
| `<scanner-slug>` | ALL items of a per-item scanner, e.g. `build_artifacts` |
| `<scanner-slug>:<item-id>` | One item — the opaque 64-char id echoed from `scan`'s `scanner_items` |

The frozen aggregate scanner id `categories` is NOT a valid target; address
category aggregates by their category slug.

```bash
# Clean specific categories
Cacheout --cli clean xcode_derived_data npm_cache yarn_cache --confirm

# Clean every discovered build-artifact directory
Cacheout --cli clean build_artifacts --confirm

# Clean ONE build-artifact item (id from scan output)
Cacheout --cli clean build_artifacts:0d3a9ab9a662fb335a6803cccf0e8a73dd5f1f2a36965334d7f3f5742caeec0e --confirm

# Preview without deleting (no --confirm needed)
Cacheout --cli clean xcode_derived_data --dry-run
```

**Options:**

| Flag | Description |
|------|-------------|
| `--confirm` | Actually delete. Without it (and without `--dry-run`) the command refuses: exit 1, empty stdout, `CONFIRMATION_REQUIRED` on stderr with the cleaning plan in `details` |
| `--dry-run` | Preview what would be cleaned without deleting (wins even beside `--confirm`) |
| `--orphan-size-floor-mb N` / `--orphan-stale-days N` | Invocation-scoped orphaned-caches sweep thresholds (same semantics as on `scan`; never persisted). Accepted by `scan` and `clean` ONLY — every other command (including `smart-clean`, which is category-only) refuses them with `INVALID_ARGUMENTS` |
| `--dev-root PATH` | REPEATABLE. Invocation-scoped dev roots for the `build_artifacts` scanner (same precedence, path-form and policy rules as on [`scan`](#-dev-root-build-artifacts-dev-roots); never persisted). Accepted by `scan` and `clean` ONLY — every other command refuses it with `INVALID_ARGUMENTS` |
| `--acknowledge-valuables SLUG:ITEM_ID:TOKEN` | REPEATABLE, one entry per item. Authorizes deleting an item that discloses release artifacts. Accepted by `clean` ONLY — every other command refuses it with `INVALID_ARGUMENTS`. See [Release-artifact acknowledgement](#release-artifact-acknowledgement) |

Running as root (euid 0) is refused with `ROOT_REFUSED`, flags or not.
Calling `clean` with no targets is a `MISSING_ARGUMENT` usage error; unknown
or invalid targets (unknown slugs, unknown item ids, the excluded
`categories` token) are `INVALID_ARGUMENTS`.

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
        "item_id": "xcode_derived_data",
        "name": "Xcode DerivedData",
        "scanner_id": "categories",
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

**Output (confirmed clean, schema 4):**
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
      "item_id": "xcode_derived_data",
      "name": "Xcode DerivedData",
      "scanner_id": "categories",
      "success": true
    }
  ],
  "scanner_rollups": [
    {
      "bytes_freed": 5368709120,
      "entry_count": 1,
      "estimated_up_to_bytes": 0,
      "exact_bytes": 5368709120,
      "scanner_id": "categories"
    }
  ],
  "schema_version": 4,
  "total_estimated_up_to_bytes": 0,
  "total_freed": "5 GB",
  "total_freed_bytes": 5368709120
}
```

Byte totals are exact-only (verifiably freed unique-inode bytes);
hardlinked/command-freed bytes ride in `estimated_up_to_bytes` /
`total_estimated_up_to_bytes` and are never folded into the totals. Every
requested slug gets a result row with a `success` flag; naming a `denied`
category or item yields a per-item error, naming a `partiallyDenied`
category proceeds with a `warning` field. Every row carries
`scanner_id`/`item_id` (schema 4); an aggregate row's `category` value is
the category slug, a per-item row's is the composite address
`<scanner_id>:<item_id>` — reusable directly as a clean target. A per-item
target whose scan state was `empty` is skipped silently: nothing deleted,
no result row.

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
      "item_id": "xcode_derived_data",
      "name": "Xcode DerivedData",
      "scanner_id": "categories",
      "slug": "xcode_derived_data",
      "state": "measured"
    }
  ],
  "schema_version": 4,
  "total_estimated_up_to_bytes": 0,
  "total_would_free": 5368709120
}
```

#### Release-artifact acknowledgement

A build-artifact directory is usually rebuild-able noise — until a release
build left a `.dmg`, `.pkg`, `.ipa`, `.app`, `.xcarchive` or `.dSYM` inside
it. `scan` DISCLOSES those on the item's `valuables` array; `clean --confirm`
**refuses to delete such an item until you acknowledge it by token**.
Disclosure is not acknowledgement: an unacknowledged confirmed clean of an
item you just scanned is refused exactly as if you had never scanned it.

```
--acknowledge-valuables <scanner-slug>:<item-id>:<token>
```

REPEATABLE (one entry per item), item-bound, and accepted by `clean` only —
every other command refuses it with `INVALID_ARGUMENTS` naming the flag.
Like every flag it comes after the positional targets.

**Learning the token before you are refused.** Plan surfaces carry it: the
unconfirmed `CONFIRMATION_REQUIRED` `details.plan[]` rows and the
`--dry-run` `results[]` rows both add

- `valuables` — the disclosed artifacts (name, canonical path,
  allocated bytes, device, inode, `modified_at_ns`), omitted when none;
- `acknowledgement_token` — emitted ONLY when the scan-time inspection
  COMPLETED and the disclosed set is NON-EMPTY;
- `acknowledgement_note` — present exactly when the scan-time inspection did
  NOT finish, so an absent token is never read as "nothing to acknowledge".

**The token** is the full lowercase-hex SHA-256 (64 chars) over
`scannerID NUL itemID NUL` followed, for each disclosed artifact in canonical
order, by `path NUL allocated_bytes NUL device NUL inode NUL
modified_seconds NUL modified_nanoseconds NUL`. It therefore rotates on any
change to set membership, path, allocated size, no-follow identity
(device/inode) or mtime — a rebuild or even a `touch` invalidates a token you
were holding, which is the point. It does not guard content mutation that
preserves all of those; that is the documented accepted residual. Because
the preimage starts with the full `<scanner>:<item>` key, a token pasted
against the wrong item can never match. PROTOCOL.md carries the byte-level
definition.

**Refusal output.** The refused item deletes nothing and reports a per-item
error carrying `valuables` and `acknowledgement_token` on the SAME result row
shape — on the partial-success payload's `results[]` (exit 0, other targets
still cleaned) and on `CLEAN_FAILED`'s `details.results[]` (exit 1, nothing
cleaned) alike. Read the token from the JSON; never parse it out of the
message.

Two refusals are deliberately **TOKENLESS**:

- the inspection could not finish (caps, an unreadable subtree) — re-scan
  and retry once it can;
- every disclosed artifact has VANISHED since the scan — refused once, then
  re-scan and clean again *without* any acknowledgement, because the item is
  now artifact-free.

**Per item, not per run.** One invocation can mix authorized deletes,
unauthorized refusals and ordinary items; each is decided on its own entry.

**Rejected up front** (`INVALID_ARGUMENTS`, nothing deleted): an entry that
is not exactly `slug:id:token`; a token that is not exactly 64 lowercase hex
characters; the same item named twice; an item outside this clean's
selection; an item proven to disclose nothing. Entry FORM is validated on
`--dry-run`, unconfirmed and confirmed runs alike; token MATCHING happens
only on the confirmed run, against a fresh inspection taken immediately
before deletion.

**Worked retry:**

```bash
# 1. Refused — nothing deleted. The token is in the JSON on stderr.
Cacheout --cli clean build_artifacts:8f14e45f... --confirm

# 2. Re-run with the entry the refusal printed.
Cacheout --cli clean build_artifacts:8f14e45f... --confirm \
  --acknowledge-valuables build_artifacts:8f14e45f...:3b1f0a9d...
```

If the directory changed between the two runs, step 2 refuses again with a
FRESH token and the current `valuables` — repeat with the new one.

---

### Argument ordering

Every command takes its POSITIONAL targets **before** any flag:

```bash
Cacheout --cli clean <targets...> [flags]
Cacheout --cli smart-clean <gb> [flags]
```

A positional token appearing after the first `--`-prefixed token is refused
with `INVALID_ARGUMENTS` naming it (before schema 4 it was silently dropped).
Flags whose next token is their VALUE consume that token, so it is never
mistaken for a target: `--acknowledge-valuables`, `--dev-root`,
`--orphan-size-floor-mb`, `--orphan-stale-days`, `--format`, `--top`,
`--target-pid`, `--target-name`. Unknown flags are tolerated and ignored, so
a wrapper appending e.g. `--format json` to every invocation stays valid.

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
1. Scans all categories (the aggregate category scanner ONLY — per-item
   scanners like `build_artifacts` are never part of smart-clean; explicit
   `clean` addressing is the only way to delete their items)
2. Keeps only cleanly-measured categories with bytes — `denied` and
   `partiallyDenied` scans are skipped (the auto path never rides on a
   floor measurement), as are Caution-level categories and items not
   eligible for automatic cleaning
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
| `<targetGB>` | Amount of space to free in GB — must be numeric, finite, greater than zero (at least one byte after conversion), and at most 10^9; a present but malformed, zero, or sub-byte value is refused with `INVALID_ARGUMENTS`, never silently defaulted | `5.0` (when absent) |
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
      "item_id": "xcode_derived_data",
      "name": "Xcode DerivedData",
      "scanner_id": "categories",
      "slug": "xcode_derived_data",
      "success": true
    }
  ],
  "dry_run": false,
  "schema_version": 4,
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

Per-item scanner slugs (usable bare or as `<slug>:<item-id>`):

| Slug | Scanner |
|------|---------|
| `build_artifacts` | Project build-artifact directories under your dev roots — `target/`, `node_modules/`, `.venv/`, `build/`, … each proven by an ecosystem marker file (item ids from `scan`'s `scanner_items`; see [CATEGORIES.md](CATEGORIES.md)) |
| `orphaned_caches` | First-level `~/Library/Caches` sweep — leaked, orphaned, and stale cache entries (item ids from `scan`'s `scanner_items`; see [CATEGORIES.md](CATEGORIES.md)) |

The `node_modules` slug that shipped in unreleased schema-4 work is
**retired**: `build_artifacts` covers every directory it found (and more).
Addressing it is an `INVALID_ARGUMENTS` unknown target.

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
