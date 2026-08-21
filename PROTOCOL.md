# CacheOut CLI Protocol

**Version:** 1.2.0
**Schema Version:** 4
**Last Updated:** 2026-08-14

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
  "schema_version": 4,
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

**Schema 4 changes:** When `schema_version >= 4`:

- `scan` output changes from a top-level array to the **scan envelope**
  (`{schema_version, categories, scanner_items, scanner_errors}`). The
  `categories` rows are field-for-field the schema-3 rows; the other keys
  are additive (per-item scanners — `build_artifacts`, `orphaned_caches`
  and `ephemeral_tmp` today — become visible for the first time).
- `clean` accepts the **target address grammar** (`<category-slug>` |
  `<scanner-slug>` | `<scanner-slug>:<item-id>`) — bare category slugs work
  exactly as in schema 3.
- Every `clean`/`smart-clean` row gains `scanner_id`/`item_id` identity
  fields, and EVERY payload (scan envelope, clean result, smart-clean
  result, both dry-run payloads) self-describes with a top-level
  `schema_version` — consumers can branch on one field regardless of which
  command produced the payload.
- The `--confirm` gate is unchanged and covers the new per-item targets:
  deleting a `build_artifacts` item requires `--confirm` exactly like a
  category clean. A `build_artifacts` item that discloses RELEASE ARTIFACTS
  additionally requires an item-bound `--acknowledge-valuables` entry — see
  [the acknowledgement contract](#valuables-acknowledgement-contract-schema-4).

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
| `scan` | Run every registered scanner; emit the schema-4 envelope (categories + per-item scanner items + scanner errors) | Existing | No |
| `clean <targets...> [--confirm\|--dry-run]` | Delete addressed targets — category slugs, per-item scanner slugs, or `<scanner-slug>:<item-id>` addresses (destructive — requires `--confirm` since schema 3; items disclosing release artifacts additionally require `--acknowledge-valuables`) | Existing | No |
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

Runs every registered scanner and returns the **schema-4 envelope**. The
`categories` key preserves schema 3's category rows EXACTLY field-for-field
(same keys, same values, size-descending order); `scanner_items` and
`scanner_errors` are additive. Since schema 3 every category entry carries
the scan STATE and the SPLIT byte components: `exact_bytes` are bytes on
unique inodes whose deletion verifiably frees them; `estimated_up_to_bytes`
are hardlinked bytes that MAY be freed. `size_bytes` remains their
compatibility sum.

**Arguments:**
- `--orphan-size-floor-mb N` / `--orphan-stale-days N` -- invocation-scoped
  orphaned-caches sweep thresholds (positive integers; decimal MB / days).
  They override the persisted `cacheout.orphanedCaches.*` values for this
  invocation and are never persisted
- `--tmp-age-days N` / `--tmp-min-size-mb N` -- invocation-scoped ephemeral
  temp-scanner thresholds (positive integers; days / decimal MB). They
  override the persisted `cacheout.ephemeralTmp.*` values for this
  invocation and are never persisted
- `--dev-root <path>` -- REPEATABLE, invocation-scoped REPLACEMENT of the dev
  roots the build-artifacts scanner walks (never persisted)

Each threshold flag is a SCANNER-THRESHOLD FLAG: accepted by `scan` and
`clean` only, and refused pre-dispatch everywhere else — see
[Scanner-threshold flags](#scanner-threshold-flags). A zero, negative,
non-numeric, missing, repeated, or overflowing value is `INVALID_ARGUMENTS`
naming the flag; nothing is scanned.

**Trigger.** A CLI scan is always an explicit user act, so it runs with the
user-initiated trigger: `--cli scan` covers every registered scanner,
including `ephemeral_tmp`, which defers entirely on the app's background
refreshes.

**Output schema (envelope):**

```json
{
  "schema_version": 4,
  "categories": [
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
  ],
  "scanner_items": [
    {
      "scanner_id": "build_artifacts",
      "item_id": "0d3a9ab9a662fb335a6803cccf0e8a73dd5f1f2a36965334d7f3f5742caeec0e",
      "path": "/Users/dev/project/node_modules",
      "name": "node_modules",
      "state": "measured",
      "exact_bytes": 1200000000,
      "estimated_up_to_bytes": 0,
      "size_bytes": 1200000000,
      "item_count": 40231,
      "risk_level": "review",
      "evidence": "node_modules/ beside package.json; last build 94 days ago",
      "action": "remove_item"
    },
    {
      "scanner_id": "build_artifacts",
      "item_id": "8f14e45fceea167a5a36dedd4bea2543f5eec9d6a0f4c2fca3b2e0c2a4c33ab1",
      "path": "/Users/dev/rustapp/target",
      "name": "target",
      "state": "measured",
      "exact_bytes": 33285996544,
      "estimated_up_to_bytes": 0,
      "size_bytes": 33285996544,
      "logical_bytes": 61312450560,
      "item_count": 128442,
      "risk_level": "review",
      "evidence": "target/ beside Cargo.toml; last build 12 days ago; contains release artifacts",
      "action": "remove_item",
      "valuables": [
        {
          "name": "Murmur_0.1.7_aarch64.dmg",
          "path": "/Users/dev/rustapp/target/release/bundle/dmg/Murmur_0.1.7_aarch64.dmg",
          "allocated_bytes": 44040192,
          "device": 16777232,
          "inode": 12345678,
          "modified_at_ns": 1755057600123456789
        }
      ]
    }
  ],
  "scanner_errors": [
    {
      "scanner_id": "build_artifacts",
      "kind": "container_refused",
      "detail": "dev root is not a usable container: the filesystem root",
      "path": "/"
    },
    {
      "scanner_id": "build_artifacts",
      "kind": "config_invalid",
      "detail": "cacheout.buildArtifacts.devRoots is not an array of strings — the seed roots are in effect and the stored value was left untouched"
    }
  ]
}
```

**Envelope keys:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | integer | yes | Always present — every schema-4 payload self-describes |
| `categories` | object[] | yes | Schema 3's category rows, field-for-field (table below). NO `scanner_id`/`item_id` here — identity fields live on `scanner_items` and the clean/smart-clean rows only |
| `scanner_items` | object[] | yes | One row per PER-ITEM scanner item (`build_artifacts`, `orphaned_caches` and `ephemeral_tmp` today; git worktrees to follow). Empty array when no per-item scanner found anything |
| `scanner_errors` | object[] | yes | Root/scanner-level problems that produced NO item (refused search roots, traversal failures, malformed outcomes). Empty array when clean |

**`scanner_items` rows:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `scanner_id` | string | yes | Owning scanner's registered slug (`[a-z0-9_]+`) |
| `item_id` | string | yes | OPAQUE stable item id — the full 64-char lowercase-hex SHA-256 over the UTF-8 bytes of `scannerID + "\0" + canonicalPath` (NUL separator; no truncation, ever). Consumers NEVER parse or derive ids — echo back exactly what scan printed. Always adjacent to its `scanner_id` sibling: a bare item id row without `scanner_id` is malformed by definition |
| `path` | string | yes | The item's resolved location (the declared spelling when unresolved — never a fake resolution) |
| `name` | string | yes | Display name (`build_artifacts`: the artifact directory's own name — `target`, `node_modules`, `.venv`) |
| `state` | string | yes | Same state machine as category rows |
| `exact_bytes` / `estimated_up_to_bytes` / `size_bytes` | integer | yes | Split components + compatibility sum (same semantics as category rows) |
| `item_count` | integer | yes | Files/items inside |
| `risk_level` | string | yes | One of `"safe"`, `"review"`, `"caution"`. There is no per-SCANNER constant: `build_artifacts` rows carry the risk of the RULE ROW that matched (a `target/` proven by `Cargo.toml` is `safe`; `node_modules/` stays `review`), and the valuables gate NARROWS a `safe` row to `review` when the artifact directory contains — or could not be fully inspected for — release artifacts. Risk is evidence confidence, NOT clean eligibility: no per-item row is auto-cleaned today (see `automatic_clean_eligible` in the model; smart-clean is category-only) |
| `logical_bytes` | integer | no | ADDITIVE. Apparent (non-allocated) size, present ONLY when it materially exceeds `size_bytes` — the sparse-file case where deletion frees LESS than the apparent size (a 57.1 GB-logical Rust `target/` occupying 31 GB). Absent for ordinary trees, where block rounding makes logical *smaller* than allocated and the divergence is noise. NEVER a reclaimable figure: budget against `exact_bytes` |
| `valuables` | object[] | no | ADDITIVE. Release artifacts detected INSIDE this item, in the ONE canonical order (byte-wise ascending `path`). Omitted entirely when none were disclosed. Element shape is pinned below and is shared byte-for-byte with clean plan rows and refusal rows |
| `evidence` | string | yes | Human-readable provenance rendered in confirmation UIs |
| `action` | string | yes | Reclaim action wire string: `"remove_contents"`, `"remove_item"`, or `"commands"`. For `"commands"` ONLY the kind is serialized — **the argv arrays are NEVER exposed anywhere in CLI output** (the JSON is a reporting surface, not an execution contract) |
| `scan_error` | object | no | Same conditional shape as category rows |
| `grant_hint` | string | no | Same conditional TCC remedy as category rows |

**`scanner_errors` rows:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `scanner_id` | string | yes | Which scanner reported (or failed validation) |
| `kind` | string | yes | One of: `"container_refused"`, `"mounted_volume_root"`, `"symlink_root"`, `"tcc_denied"`, `"permission_denied"`, `"unreadable"`, `"enumeration_truncated"`, `"config_invalid"`, `"malformed_outcome"`. The list is EXTENSIBLE — consumers must tolerate unknown kinds |
| `detail` | string | yes | Human-readable description |
| `path` | string | conditional | Present for the FILESYSTEM kinds; ABSENT for the NON-FILESYSTEM kinds — `"malformed_outcome"` and `"config_invalid"` — where no filesystem location exists and a fake path is therefore never invented |
| `grant_hint` | string | no | Present only when `kind == "tcc_denied"` — the same user-side remedy (Full Disk Access) as category and `scanner_items` rows, since macOS denies CLI processes silently |

A `malformed_outcome` row means that scanner's ENTIRE outcome failed
fail-closed validation: its items are excluded from `scanner_items` AND from
clean addressability, and the remaining valid scanners' rows are unaffected.

A `config_invalid` row means a PERSISTED configuration value could not be
parsed by this build (today: `cacheout.buildArtifacts.devRoots` holding
anything other than an array of strings). The scanner fell back to its
defaults **without rewriting the stored value**, and the row rides EVERY
scan outcome while the corrupt value persists — the fallback is never
silent. It carries no `path` because a config parse failure has no honest
filesystem location. A configured root that was REJECTED by policy (the
filesystem root, a volume root/mount point, `$HOME`) is a different thing
and reports honestly under `container_refused` WITH its offending path.

A `mounted_volume_root` row means a REGISTERED root has another volume
mounted exactly at its path, so whatever is there belongs to that volume
rather than to the root. It is deliberately NOT `container_refused`: the
root is configured and admissible, nothing rejected it, and the condition is
one the user clears — eject or unmount the volume, then re-scan. Emitted
today by `ephemeral_tmp`, which answers from the kernel's mount table before
any syscall touches the root.

**Per-item valuables element (pinned, shared by three surfaces):** the same
six-field object appears in `scanner_items[].valuables`, in clean plan rows
(`details.plan[].valuables`), and in clean refusal rows
(`results[].valuables`) — one builder, so the surfaces cannot drift.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Basename as discovered (`Murmur_0.1.7_aarch64.dmg`) |
| `path` | string | yes | The artifact's CANONICAL IDENTITY path (canonical parent chain, leaf never resolved). This exact string is what the acknowledgement-token preimage consumes; display spellings never serialize |
| `allocated_bytes` | integer | yes | Leaf allocation for a regular file; BOUNDED SUBTREE allocation for a directory bundle (`.app`, `.xcarchive`, `.dSYM`) |
| `device` | integer | yes | `st_dev` of the artifact's root, as an UNSIGNED decimal integer |
| `inode` | integer | yes | `st_ino` of the artifact's root, as an UNSIGNED decimal integer |
| `modified_at_ns` | integer | yes | Modification time in nanoseconds since the epoch — `modifiedSeconds * 1_000_000_000 + modifiedNanoseconds`, derived with checked arithmetic from the same two integers everything else uses |

**Category row fields (unchanged from schema 3):**

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

### `--cli clean <targets...> [--confirm|--dry-run]`

Cleans the addressed targets. **Destructive — since schema 3 it requires
`--confirm`.**

#### Target address grammar (schema 4 — permanent contract)

A positional target token is ONE of:

| Form | Meaning |
|------|---------|
| `<category-slug>` | One category aggregate — unchanged from schema 3 (e.g. `npm_cache`) |
| `<scanner-slug>` | ALL items of that per-item scanner (e.g. `build_artifacts`) |
| `<scanner-slug>:<item-id>` | One item of that scanner, by the opaque id echoed from `scan`'s `scanner_items` |

- Category slugs and scanner slugs match `[a-z0-9_]+` — no colon — so the
  FIRST `:` splits scanner slug from item id unambiguously. The combined
  category-slug/scanner-slug namespace is collision-free (enforced at
  registration), so a bare token resolves to whichever exists.
- **Aggregate-scanner exclusion:** the frozen aggregate scanner id
  `categories` is NOT a valid target token in any form (`categories` and
  `categories:<x>` are both refused with `INVALID_ARGUMENTS`) — category
  aggregates are addressed by category slug only. A scanner-wide token over
  every category would be a mass-clean footgun.
- **Item-id opacity:** item ids are opaque, CLI-safe strings with a frozen
  derivation — the FULL lowercase-hex SHA-256 (64 chars) over the UTF-8
  bytes of `scannerID + "\0" + canonicalPath` (the NUL separator prevents
  ambiguous concatenations; no truncation, ever, so stability is
  unconditional). Consumers NEVER parse or derive ids — they echo back
  exactly what `scan` printed. Ids are stable across rescans of the same
  logical item.

**Arguments:**
- `<targets...>` -- One or more targets per the grammar above
- `--confirm` -- Actually delete. Without it the command refuses (below).
  Required for per-item targets too: `build_artifacts` deletion honors the
  same gate as category cleans
- `--dry-run` -- Preview without deleting (needs no `--confirm`; wins even beside it)
- `--acknowledge-valuables <scanner-slug>:<item-id>:<token>` -- REPEATABLE,
  one entry per item. Authorizes deletion of an item that discloses release
  artifacts. Accepted by `clean` ONLY — see
  [the acknowledgement contract](#valuables-acknowledgement-contract-schema-4)
- `--orphan-size-floor-mb N` / `--orphan-stale-days N` -- invocation-scoped
  orphaned-caches sweep thresholds (same semantics as on `scan`; never
  persisted). `clean` re-scans before it deletes, so these decide which
  entries a bare `orphaned_caches` target covers
- `--tmp-age-days N` / `--tmp-min-size-mb N` -- invocation-scoped ephemeral
  temp-scanner thresholds (same semantics as on `scan`; never persisted).
  They likewise decide which entries a bare `ephemeral_tmp` target covers
- `--dev-root <path>` -- REPEATABLE, invocation-scoped dev-roots REPLACEMENT
  for the build-artifacts scanner (never persisted)

**Argument ordering (schema 4 — frozen):** every command takes its
POSITIONAL targets BEFORE any flag. A positional token appearing after the
first `--`-prefixed token is `INVALID_ARGUMENTS` naming the token, rather
than being silently dropped as it was before schema 4. Flags whose next argv
token is their VALUE (`--acknowledge-valuables`, `--dev-root`,
`--orphan-size-floor-mb`, `--orphan-stale-days`, `--tmp-age-days`,
`--tmp-min-size-mb`, `--format`, `--top`,
`--target-pid`, `--target-name`) consume that token, so it is never mistaken
for a positional; every documented shape — including a trailing
`--format json` — is already targets-first and keeps its exact meaning.
Unknown flags are tolerated and ignored.

Tokens that match no known category slug, scanner slug, or scanned item id
cause an `INVALID_ARGUMENTS` error naming the invalid token(s); no cleaning
is performed in that case. A target addressing a scanner whose outcome
failed validation (`malformed_outcome` in `scan`'s `scanner_errors`) is
likewise refused — a malformed scanner's items can never be listed,
selected, addressed, or deleted. Running as root (euid 0) is refused
outright with a `ROOT_REFUSED` error, `--confirm` or not.

#### Confirmation gate (schema 3; plan rows extended in schema 4)

An unconfirmed, non-dry-run invocation deletes NOTHING: **stdout is empty**,
the exit code is 1, and stderr carries the standard error envelope with the
cleaning plan — the same per-target decisions the confirmed run would take —
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
        "estimated_up_to_bytes": 0,
        "scanner_id": "categories",
        "item_id": "npm_cache"
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
| `plan` | object[] | One entry per resolved target (scan-time components — no re-walk) |
| `plan[].slug` | string | The retained address key, frozen BY ITEM TYPE (schema 4): the category SLUG for aggregate rows; the composite ADDRESS `<scanner_id>:<item_id>` for per-item rows — directly reusable as a clean target token |
| `plan[].state` | string | The scan state (see `scan`) |
| `plan[].action` | string | What the confirmed run would do: `"clean"`, `"clean_with_warning"` (`partiallyDenied` — measured bytes only), `"refuse"` (`denied`), or `"skip"` (missing/empty). Smart-clean plans additionally use `"clean_if_needed"` for eligible fallback candidates past the projected target-met point — deleted only if earlier categories free fewer delete-time bytes than their scan-time exact components |
| `plan[].exact_bytes` | integer | Scan-time exact component |
| `plan[].estimated_up_to_bytes` | integer | Scan-time estimated component |
| `plan[].scanner_id` / `plan[].item_id` | string | Identity siblings on EVERY row (schema 4) — consumers never parse the composite `slug` value |
| `plan[].warning` | string | Present for `partiallyDenied` entries |
| `plan[].scan_error` | object | Present when the scan was impeded (same shape as `scan`) |
| `plan[].valuables` | object[] | ADDITIVE. The release artifacts this item disclosed, in the pinned element shape and canonical order. OMITTED when the item disclosed none |
| `plan[].acknowledgement_token` | string | ADDITIVE. The 64-char lowercase-hex token a confirmed run would require for this item, so the caller learns it from the PLAN instead of from a refusal. Emitted ONLY when the scan-time inspection was COMPLETE and the disclosed set NON-EMPTY |
| `plan[].acknowledgement_note` | string | ADDITIVE. Present exactly when the scan-time inspection did NOT finish: it says so and points at the confirmed run's re-inspection, so an absent token is never read as "nothing to acknowledge" |
| `total_exact_bytes` | integer | Sum of exact bytes over entries that would clean |
| `total_estimated_up_to_bytes` | integer | Sum of estimated bytes over entries that would clean |
| `scanner_errors` | object[] | Additive, optional: present only when a bare `<scanner-slug>` target's scan reported root/scanner-level issues (same row shape as `scan`'s `scanner_errors`) — the scanner-wide selection was impeded and may be incomplete |

#### Confirmed output (schema 4)

Byte totals are **exact-only**: `total_freed_bytes` counts delete-time
measured unique-inode bytes; hardlinked/command-freed bytes appear in the
additive `total_estimated_up_to_bytes` and are never folded into the total.
`results` carries one entry per resolved aggregate target — including slugs
that had nothing to do (`success: true`, zero bytes) — and one entry per
resolved per-item target that reached the cleaner. A per-item target whose
scan state was `empty` (or `missing`) is the cleaner's silent pre-admission
skip: nothing is deleted, NO result row appears for it, and the run stays a
process-level success.

```json
{
  "schema_version": 4,
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
      "success": true,
      "scanner_id": "categories",
      "item_id": "xcode_derived_data"
    },
    {
      "category": "build_artifacts:0d3a9ab9a662fb335a6803cccf0e8a73dd5f1f2a36965334d7f3f5742caeec0e",
      "name": "node_modules",
      "bytes_freed": 1200000000,
      "exact_bytes": 1200000000,
      "estimated_up_to_bytes": 0,
      "freed_human": "1.2 GB",
      "success": true,
      "scanner_id": "build_artifacts",
      "item_id": "0d3a9ab9a662fb335a6803cccf0e8a73dd5f1f2a36965334d7f3f5742caeec0e"
    }
  ],
  "scanner_rollups": [
    {
      "scanner_id": "categories",
      "exact_bytes": 13204889600,
      "estimated_up_to_bytes": 32000000,
      "bytes_freed": 13236889600,
      "entry_count": 1
    },
    {
      "scanner_id": "build_artifacts",
      "exact_bytes": 1200000000,
      "estimated_up_to_bytes": 0,
      "bytes_freed": 1200000000,
      "entry_count": 1
    }
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | integer | yes | Always `4` — every payload self-describes (schema 4) |
| `dry_run` | boolean | yes | Whether this was a dry run |
| `total_freed_bytes` | integer | yes | **Exact bytes only** (schema 3 — was the mixed sum in v2) |
| `total_estimated_up_to_bytes` | integer | yes | Hardlinked/command bytes that MAY have been freed |
| `total_freed` | string | yes | Human-readable component phrase (e.g. `"13.2 GB + up to 32 MB more"`) |
| `results` | object[] | yes | One entry per resolved target (per-item `empty`/`missing` skips excluded, above) |
| `results[].category` | string | yes | The retained key, frozen BY ITEM TYPE (schema 4): the category **slug** for aggregate rows (unchanged from schema 3); the composite ADDRESS `<scanner_id>:<item_id>` for per-item rows — directly reusable as a clean target token |
| `results[].name` | string | yes | Human-readable display name (category name; per-item: the item's display name) |
| `results[].bytes_freed` | integer | yes | Exact bytes freed for this entry (== `exact_bytes`) |
| `results[].exact_bytes` | integer | yes | Delete-time measured unique-inode bytes |
| `results[].estimated_up_to_bytes` | integer | yes | Delete-time hardlinked / command-category bytes |
| `results[].freed_human` | string | yes | Human-readable component phrase |
| `results[].success` | boolean | yes | `false` iff the entry reported at least one error |
| `results[].scanner_id` | string | yes | Owning scanner id — `"categories"` on aggregate rows (schema 4) |
| `results[].item_id` | string | yes | Scanner-scoped item id — the category slug on aggregate rows, the full-hash id on per-item rows (schema 4) |
| `results[].error` | string | no | Error message(s), `"; "`-joined, when `success` is false |
| `results[].warning` | string | no | Present when the category scanned `partiallyDenied` — only measured bytes were cleaned/reported |
| `results[].valuables` | object[] | no | ADDITIVE. Present only on a VALUABLES REFUSAL row: the release artifacts the DELETE-TIME inspection found, pinned element shape, canonical order. Omitted when the refusal disclosed none (the vanished-set case) |
| `results[].acknowledgement_token` | string | no | ADDITIVE. Present only on a valuables refusal whose delete-time inspection COMPLETED and found a non-empty set — the exact token to pass back in `--acknowledge-valuables`. Vanished-set and incomplete-inspection refusals are deliberately TOKENLESS |
| `scanner_rollups` | object[] | yes | Additive per-scanner sums over the report entries (`scanner_id`, `exact_bytes`, `estimated_up_to_bytes`, `bytes_freed`, `entry_count`), first-appearance order |
| `scanner_errors` | object[] | no | Additive: present only when a bare `<scanner-slug>` target's scan reported root/scanner-level issues — same row shape as `scan`'s `scanner_errors`. Also present on the `CLEAN_FAILED` details when applicable |

**Denied-state targets:** naming a `denied` category or item is a per-entry
error (`success: false`, `error` explains the scan-time refusal — TCC,
permissions, or admission), never a silent skip. Naming a `partiallyDenied`
category proceeds but carries `warning`. The `smart-clean` auto path skips
both.

**Impeded scanner-wide targets:** a bare `<scanner-slug>` target selects
whatever the backing scan discovered, so that scan's root/scanner-level
issues (TCC denials, permission denials, refused roots) travel with the
selection: every clean surface — the `CONFIRMATION_REQUIRED` details, the
dry-run payload, and the confirmed payload — carries them as an additive
`scanner_errors` array (same row shape as `scan`'s; the key is present only
when non-empty). With EVERY root denied, the confirmed run exits 0 with
empty `results` and the denial rows: an impeded no-op, never a silent
success. Scan-time impediments never flip the exit code (the `scan`
envelope precedent — a fully-denied `scan` also exits 0 with
`scanner_errors` rows); `CLEAN_FAILED` remains a delete-time verdict.
Explicitly addressed `<scanner-slug>:<item-id>` targets carry no
`scanner_errors`: the addressed item WAS discovered, so root-level issues
did not impede that specific operation.

#### Exit-code policy (schema 3)

| Outcome | Exit | stdout | stderr |
|---------|------|--------|--------|
| Everything succeeded (or nothing to do) | 0 | result JSON | empty |
| PARTIAL failure — some targets errored, or some bytes freed despite errors | 0 | result JSON with per-item `success` flags | empty |
| TOTAL failure — every resolved target errored and nothing was freed | 1 | empty | `CLEAN_FAILED` envelope; `details.results` carries the per-item errors |
| Unconfirmed (no `--confirm`, no `--dry-run`) | 1 | empty | `CONFIRMATION_REQUIRED` envelope with `details.plan` |
| Running as root (euid 0) | 1 | empty | `ROOT_REFUSED` envelope |
| Unknown/invalid target (unknown slug, unknown item id, `categories`, or a malformed scanner's address) | 1 | empty | `INVALID_ARGUMENTS` envelope |
| No targets given | 1 | empty | `MISSING_ARGUMENT` envelope (an empty list is never a successful no-op) |

#### Dry run (schema 4)

Non-destructive; built from the SCAN-TIME split components (no re-walk).
`bytes_would_free`/`total_would_free` count **exact bytes only**; estimated
bytes ride in the additive fields. Entries reuse the plan shape (`state`,
`action`, components, identity fields). A bare `<scanner-slug>` target
whose scan reported root/scanner-level issues additionally carries the
additive `scanner_errors` array (same row shape as `scan`'s; present only
when non-empty — see "Impeded scanner-wide targets" above):

```json
{
  "schema_version": 4,
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
      "freed_human": "13.2 GB + up to 32 MB more",
      "scanner_id": "categories",
      "item_id": "xcode_derived_data"
    }
  ]
}
```

#### Valuables acknowledgement contract (schema 4)

Some deletable items are dangerous *because of what is inside them*. A Rust
`target/` is rebuild-able noise — until a release build left
`target/release/bundle/dmg/App_1.2.3.dmg` in it. The `build_artifacts`
scanner therefore runs a bounded, no-follow inspection INSIDE every matched
artifact directory for release artifacts (`.dmg`, `.pkg`, `.ipa` regular
files and `.app` / `.xcarchive` / `.dSYM` directory bundles above 5 MB) and
**refuses to delete a disclosing item unless the caller acknowledges it by
token**.

Acknowledgement means *the user saw it*. Discovery is never acknowledgement:
the `valuables` array on a scan row is DISCLOSURE, and an unacknowledged
`clean --confirm` of that same scanned item is refused exactly as if it had
never been scanned.

**The flag.**

```
--acknowledge-valuables <scanner-slug>:<item-id>:<token>
```

- **REPEATABLE** — one entry per item; a multi-item clean passes one flag
  occurrence per acknowledged item.
- **ITEM-BOUND** — the address half is the same `<scanner-slug>:<item-id>`
  pair `scan` printed. Slug (`[a-z0-9_]+`), item id (opaque CLI-safe id) and
  token (64 lowercase hex) are colon-free by construction, so the
  colon-joined form parses unambiguously.
- **`clean` ONLY.** Every other command refuses it PRE-DISPATCH with
  `INVALID_ARGUMENTS` naming the flag — the same centralized gate that
  refuses the [scanner-threshold flags](#scanner-threshold-flags) and
  `--dev-root` outside `scan`/`clean`. A destructive
  authorization silently landing on a command that ignores it would be worse
  than a usage error.
- It is a FLAG, so like every flag it comes AFTER the positional targets
  (see "Argument ordering" above).

**Learning the token from the plan.** Both plan surfaces — the
`CONFIRMATION_REQUIRED` `details.plan` rows and the `--dry-run` result rows —
carry the additive `valuables`, `acknowledgement_token` and
`acknowledgement_note` keys documented in the plan table above, so a caller
can prepare the acknowledgement without first provoking a refusal:

| Scan-time inspection | Disclosed set | `valuables` | `acknowledgement_token` | `acknowledgement_note` |
|---|---|---|---|---|
| complete | non-empty | present | present | absent |
| complete | empty | absent | absent | absent |
| INCOMPLETE | any | present if anything was seen | **absent** | present |

The confirmed run ALWAYS recomputes the token from its own delete-time
inspection; a plan token that no longer matches simply yields the standard
fresh refusal below.

**The token.** Full lowercase-hex SHA-256 (64 chars, never truncated) over
the UTF-8 bytes of

```
scannerID NUL itemID NUL
  ( path NUL allocated_bytes NUL device NUL inode NUL
    modified_seconds NUL modified_nanoseconds NUL )*
```

with the valuables in the canonical order the wire prints them, every
numeric written as its decimal integer (`device`/`inode` unsigned), and `NUL`
the single byte `0x00`. `path` is the element's canonical identity path — the
exact string the `valuables` wire field carries; display spellings never
enter the preimage. `modified_seconds`/`modified_nanoseconds` are the two
integers from which the wire's `modified_at_ns` is derived (`seconds *
1_000_000_000 + nanoseconds`, checked arithmetic), so JSON, token and
re-computation consume ONE set of integers and cannot drift on precision.

The leading `scannerID NUL itemID NUL` pair is the canonical `ItemKey`
serialization — the same convention the opaque item id itself uses. Item ids
are scanner-scoped, so only the FULL ItemKey makes a token item-bound: a
token applied to a different item, even one carrying the same item id under
another scanner, can never match.

**A token exists ONLY for a non-empty set from a complete inspection.** There
is no empty-set token and no partial-inspection token on any surface.

**Honest invalidation contract.** The token rotates whenever set membership,
a path, an allocated size, a no-follow identity (device/inode) or an mtime
changes — so an in-place replacement (same path, same size, new inode or new
mtime) invalidates a held token, and any touch or rebuild of a release
artifact does too. That is deliberate and fail-safe. It does **NOT** guard
against content mutation that preserves all of those; that residual is
accepted and stated here rather than papered over.

**Refusal shape.** A `clean --confirm` that reaches an unacknowledged (or
wrongly-acknowledged) valuable-bearing item deletes NOTHING for that item and
reports it as a per-item error. The refusal fields ride the ONE result-row
shape, so they appear identically on BOTH arms:

- the partial-success payload's `results[]` (exit 0 — other targets still
  cleaned), and
- `CLEAN_FAILED`'s `details.results[]` (exit 1 — nothing could be cleaned).

MCP and other JSON consumers read the token from the same envelope either
way; nothing is parsed out of prose.

```json
{
  "category": "build_artifacts:8f14e45fceea167a5a36dedd4bea2543f5eec9d6a0f4c2fca3b2e0c2a4c33ab1",
  "name": "target",
  "bytes_freed": 0,
  "exact_bytes": 0,
  "estimated_up_to_bytes": 0,
  "freed_human": "0 bytes",
  "success": false,
  "scanner_id": "build_artifacts",
  "item_id": "8f14e45fceea167a5a36dedd4bea2543f5eec9d6a0f4c2fca3b2e0c2a4c33ab1",
  "error": "/Users/dev/rustapp/target: release artifacts (Murmur_0.1.7_aarch64.dmg) are inside this directory at delete time and are not covered by an acknowledgement — refused, nothing deleted",
  "valuables": [
    {
      "name": "Murmur_0.1.7_aarch64.dmg",
      "path": "/Users/dev/rustapp/target/release/bundle/dmg/Murmur_0.1.7_aarch64.dmg",
      "allocated_bytes": 44040192,
      "device": 16777232,
      "inode": 12345678,
      "modified_at_ns": 1755057600123456789
    }
  ],
  "acknowledgement_token": "3b1f0a9d2c4e6b8a0d1f3e5c7a9b1d3f5e7c9a1b3d5f7e9c1a3b5d7f9e1c3a5b"
}
```

**Absence rules on refusal rows.** `valuables` is omitted when the refusal
disclosed none. `acknowledgement_token` is omitted unless the delete-time
inspection COMPLETED and found a non-empty set — the uniform rule that both
of these are TOKENLESS:

- **Incomplete inspection** (caps hit, unreadable subtree, undecodable name):
  refused with a "couldn't fully re-inspect … re-scan required" reason, the
  partial sighting carried as a floor, and **no token**. An inspection that
  could not finish cannot authorize anything; re-scan and retry once it can.
- **Vanished set**: the item disclosed artifacts at scan time and the
  delete-time inspection finds NONE. Refused **once**, with no token —
  there is nothing left to acknowledge. Re-scan and clean again *without*
  any acknowledgement: the item is now artifact-free and needs none.

**Multi-item behavior.** Authorization is per item. One invocation can mix
authorized valuable-bearing deletes, unauthorized valuable-bearing refusals
and ordinary deletes; each item is decided on its own entry, the refusals
appear as their own error rows, and the run stays exit 0 as long as anything
succeeded.

**Frozen parsing / rejection rules** (all `INVALID_ARGUMENTS`, pre-flight,
nothing deleted):

| Input | Refused because |
|---|---|
| a bare `--acknowledge-valuables` with no following token | a valueless occurrence would look exactly like an ABSENT flag and run an UNACKNOWLEDGED clean while the caller believes they authorized one |
| not exactly two colons (`slug:id`, `slug:id:tok:extra`) | the entry shape is frozen |
| slug not `[a-z0-9_]+`, or an empty/ill-formed item id | it cannot address an item |
| token not exactly 64 LOWERCASE hex characters | it is compared byte-for-byte; a spelling that can never match is rejected now, not at delete time |
| the same `<scanner-slug>:<item-id>` named twice | first-wins would ignore a contradicting second entry and last-wins the first — either silently drops half of what the caller authorized |
| an item that is NOT part of this clean's resolved selection | an acknowledgement that authorizes nothing this run touches is caller confusion |
| an item PROVEN to disclose nothing (complete inspection, empty set) | there is nothing to acknowledge, and no token exists for it |

An item whose scan-time inspection did NOT finish is *not* proven
artifact-free, so an entry for it is accepted pre-flight and decided at
delete time (where the tokenless rule refuses it if the inspection still
cannot finish).

**Validation timing.** Entry FORM and the pre-flight rules above run on every
path — `--dry-run`, unconfirmed, and confirmed alike — so malformed
authorization input fails fast everywhere. Token MATCHING happens only on the
confirmed path, against the delete-time inspection; `--dry-run` reports what
*would* be required and deletes nothing.

**Worked retry.**

```bash
# 1. Confirmed clean of a disclosing item: refused, nothing deleted.
Cacheout --cli clean build_artifacts:8f14e45f… --confirm
# → exit 1, stderr CLEAN_FAILED; details.results[0] carries
#   "valuables": [...] and
#   "acknowledgement_token": "3b1f0a9d…"

# 2. Read the token out of the SAME envelope (never parsed from prose),
#    show the user what it covers, then re-run with the entry.
Cacheout --cli clean build_artifacts:8f14e45f… --confirm \
  --acknowledge-valuables build_artifacts:8f14e45f…:3b1f0a9d…
# → exit 0; the artifact directory (release artifacts included) is deleted
#   and reported in results[] with success: true.
```

If anything about the disclosed set changed between steps 1 and 2 — a
rebuild, a touch, an added or removed artifact — step 2 refuses again with a
FRESH token and the current `valuables`. Repeat with the new token; the
contract never silently deletes on stale authorization.

---

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
  (never silently defaulted). Must be finite, greater than zero, at most
  10^9, and large enough to convert to at least one byte — anything else
  (including `0`, sub-byte values like `1e-20`, `nan`, and `inf`) is
  refused with `INVALID_ARGUMENTS` before any scan or gate
- `--confirm` -- Actually delete
- `--dry-run` -- Preview without deleting (needs no `--confirm`)

**Candidate policy (schema 3; scope pinned in schema 4):** only
cleanly-`measured` categories with bytes qualify. Categories that scanned
`denied` or `partiallyDenied` are skipped (the auto path never rides on a
floor measurement), as are caution-risk categories. Safe risk sorts before
review; larger first within a tier. Since schema 4 the candidate set is
EXPLICITLY category-aggregates-only: smart-clean scans the aggregate
category scanner exclusively and items that are not eligible for automatic
cleaning (every per-item scanner item today) are excluded by
model policy. Per-item scanners becoming CLI-visible does NOT widen
automatic destruction — that is a deliberate non-goal; per-item deletions
happen only through explicitly addressed `clean` targets.

Since schema 4 the scan runs through the same validated scanner runtime as
`scan`/`clean`/`spotlight`. If the `categories` outcome fails validation
(`malformed_outcome`), the command fails closed with error code
`MALFORMED_SCANNER_OUTPUT` on all three surfaces — the unconfirmed plan,
`--dry-run`, and the confirmed run — candidates are never derived from
unvalidated results, and a rejected scanner is never presented as an empty
plan or a "nothing eligible" success.

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
  "schema_version": 4,
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
      "success": true,
      "scanner_id": "categories",
      "item_id": "xcode_derived_data"
    }
  ]
}
```

Note the deliberate as-built key asymmetry, preserved (not "fixed") across
schema versions: `clean` result rows say `category`, smart-clean rows say
`slug` — consumers read both spellings, and both follow the same by-item-type
value rule.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | integer | yes | Always `4` — result AND dry-run payloads (schema 4) |
| `target_gb` | number | yes | Requested target in GB |
| `target_met` | boolean | yes | Whether EXACT freed bytes met the target |
| `total_freed_bytes` | integer | yes | **Exact bytes only** (schema 3) |
| `total_estimated_up_to_bytes` | integer | yes | Hardlinked/command bytes that MAY have been freed |
| `total_freed` | string | yes | Human-readable component phrase |
| `dry_run` | boolean | yes | Whether this was a dry run |
| `cleaned` | object[] | yes | Per-category details, in cleaning order |
| `cleaned[].slug` | string | yes | Category slug (aggregate rows; a per-item row — none today — would carry the composite address per the by-item-type rule) |
| `cleaned[].name` | string | yes | Category name |
| `cleaned[].scanner_id` | string | yes | Owning scanner id — `"categories"` on every row today (schema 4) |
| `cleaned[].item_id` | string | yes | Scanner-scoped item id — the category slug on aggregate rows (schema 4) |
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

Since schema 4 the discovery pass runs through the same validated scanner
runtime as `scan`/`clean`/`smart-clean`, scoped to the `categories` adapter
(tagging is a category-root side effect). If the `categories` outcome fails
validation (`malformed_outcome`), the command fails closed with error code
`MALFORMED_SCANNER_OUTPUT` — tag targets are never derived from unvalidated
results.

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
| `MALFORMED_SCANNER_OUTPUT` | A scanner's outcome failed runtime validation — `spotlight` and `smart-clean` (all three surfaces) refuse to act on unvalidated results (schema 4) |

### Scanner-threshold flags

A per-item scanner may expose invocation-scoped THRESHOLD flags. Each such
scanner owns a FAMILY of flags, and every family follows the same contract:

| Family | Flags | Overrides |
|--------|-------|-----------|
| Orphaned-caches sweep | `--orphan-size-floor-mb N`, `--orphan-stale-days N` | `cacheout.orphanedCaches.*` |
| Ephemeral temp scanner | `--tmp-age-days N`, `--tmp-min-size-mb N` | `cacheout.ephemeralTmp.*` |

- **`scan` and `clean` ONLY** — the two commands that actually run the
  scanners. EVERY other command refuses a family's flag PRE-DISPATCH with
  `INVALID_ARGUMENTS`, in a message naming the flag, the refusing command,
  and the commands that accept it. `smart-clean` is included: it is frozen
  category-only and runs no per-item scanner at all. Accepting a threshold
  the caller passed and then ignoring it would hide the flag landing on the
  wrong command.
- **Positive integers only.** A zero, negative, non-numeric, missing,
  REPEATED, or unit-overflowing value is `INVALID_ARGUMENTS` naming the
  flag. `INVALID_ARGUMENTS` is the only code these failures produce — a
  malformed threshold is never a `USAGE_ERROR` and never silently defaulted.
  A flag written last with no following value is refused too: reading it as
  an absent flag would scan with the persisted thresholds the caller meant
  to override.
- **Invocation-scoped.** An override wins over the persisted value for that
  invocation only; nothing is ever written back to the defaults suite.

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

1. **`schema_version`** is an integer that starts at 1 and increments monotonically. Current version: **4** (scan output becomes the envelope `{schema_version, categories, scanner_items, scanner_errors}` — a breaking change from schema 3's top-level array; clean targets follow the address grammar; clean/smart-clean rows carry `scanner_id`/`item_id`; every payload self-describes with a top-level `schema_version`). Version 3 gated `clean`/`smart-clean` behind `--confirm` with exact-only totals and `CLEAN_FAILED`; version 2 added `intervene` with all tiers and deprecated `purge`.

   **`schema_version >= 3` ⇒ `clean` and `smart-clean` require `--confirm`.** MCP servers upgrading past this version MUST add `--confirm` to destructive invocations and treat a `CONFIRMATION_REQUIRED` stderr envelope as "re-invoke with --confirm after user consent", not as a failure.

   **`schema_version >= 4` ⇒ `scan` output is the envelope, not an array.** Consumers MUST branch on the payload shape or the cached `schema_version`: a JSON array is schema ≤ 3, an object with a `categories` key is schema 4. Category rows inside the envelope are field-for-field the schema-3 rows.

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
