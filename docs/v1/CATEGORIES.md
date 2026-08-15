# Cache Categories

Cacheout scans its built-in cache categories, organized into groups. This document
details each category's paths, discovery method, risk level, and behavior. The
registry in `Sources/Cacheout/Scanner/Categories.swift` is the source of truth —
this document deliberately states no category count, because prose counts rot the
moment an entry is added.

## Scanner Registry

Since the scanner unification, every space scanner — the category registry AND
per-item scanners — implements one `SpaceScanner` protocol and registers with the
`SpaceScannerRuntime` (see [ARCHITECTURE.md](ARCHITECTURE.md)):

- **Categories are one aggregate scanner.** The `CategoryScanner` adapter (scanner
  id `categories`) wraps the data-driven registry and emits one aggregate item per
  category. Category behavior is unchanged, and adding a category is still a
  one-line `CacheCategory` entry — no scanner code involved.
- **`build_artifacts`, `orphaned_caches` and `git_worktrees` are the per-item
  scanners**, emitting one item per discovered directory, entry or worktree.
  Follow-on scanners (temp dirs) drop into the same registry.
- The CLI addresses categories by slug and per-item scanners by
  `<scanner-slug>` or `<scanner-slug>:<item-id>` — see
  [CLI-REFERENCE.md](CLI-REFERENCE.md) and the address grammar in PROTOCOL.md.

## Category Overview

| # | Category | Risk | Default Selected | Discovery |
|---|----------|------|------------------|-----------|
| 1 | Xcode DerivedData | Safe | Yes | Static |
| 2 | Xcode Device Support | Review | Yes | Static |
| 3 | Simulator Devices | Review | No | Static + Custom Command |
| 4 | Swift PM Cache | Safe | Yes | Static |
| 5 | CocoaPods Cache | Safe | Yes | Probed |
| 6 | Homebrew Cache | Safe | Yes | Probed |
| 7 | npm Cache | Safe | Yes | Probed |
| 8 | Yarn Cache | Safe | Yes | Probed |
| 9 | pnpm Store | Safe | Yes | Probed |
| 10 | Bun Cache | Safe | Yes | Probed |
| 11 | node-gyp Cache | Safe | Yes | Probed |
| 12 | Playwright Browsers | Safe | Yes | Static |
| 13 | pip Cache | Safe | Yes | Probed |
| 14 | uv Cache | Safe | Yes | Probed |
| 15 | PyTorch Hub Models | Review | No | Static |
| 16 | Gradle Cache | Safe | Yes | Static |
| 17 | Docker Disk Image | Caution | No | Probed |
| 18 | VS Code Cache | Safe | Yes | Static |
| 19 | Electron Cache | Safe | Yes | Static |
| 20 | Browser Caches | Review | Yes | Static |
| 21 | ChatGPT Desktop Cache | Safe | Yes | Static |
| 22 | Prisma Engines | Safe | Yes | Static |
| 23 | TypeScript Build Cache | Safe | Yes | Static |

---

## Size Reporting

Since v2.2.0, category sizes are measured by a single sizing routine
(`DirectorySizer`) and split by certainty:

- **Exact bytes** — allocated bytes on unique inodes; deleting the category
  verifiably frees them.
- **Estimated "up to" bytes** — bytes on hardlinked inodes (freed only if
  every other link goes too) and bytes a custom clean command may free
  (nothing measures what a command frees).

Consequences worth knowing:

- **Sizes are bigger than in v2.1.x — and truthful.** Bundles (`.app`,
  `.framework`) and hidden files/directories are now walked and counted, so
  Xcode DerivedData and Simulator totals in particular grow. Unreadable
  subtrees are recorded as scan errors instead of being silently skipped.
- **Sparse files report allocated size.** `totalFileAllocatedSize` is used
  throughout, so sparse files (Docker's disk image, simulator disk images)
  report actual disk usage, not their inflated logical size.
- **Totals can still overcount.** APFS clones share storage invisibly to any
  public API, and files hardlinked *across* categories are counted in each —
  actual space freed may be less. The UI discloses this next to every
  recoverable-bytes total.
- **Command-cleaned categories report "up to \<pre-scan size\>".** A category
  cleaned by a command (e.g., Simulator Devices) frees bytes no file walk can
  attribute, so its report entry carries exact 0 and an estimated component
  equal to the pre-scan size.

The CLI wire fields (`exact_bytes`, `estimated_up_to_bytes`, `state`,
`scan_error`) are documented in [CLI-REFERENCE.md](CLI-REFERENCE.md).

---

## Xcode & Apple Development

### Xcode DerivedData
- **Slug:** `xcode_derived_data`
- **Risk:** Safe
- **Path:** `~/Library/Developer/Xcode/DerivedData`
- **Discovery:** Static
- **After cleaning:** Xcode rebuilds on next build
- **Typical size:** 2–20 GB
- **Notes:** Contains build artifacts, indexes, and module caches. Completely safe to delete — Xcode regenerates everything on next build.

### Xcode Device Support
- **Slug:** `xcode_device_support`
- **Risk:** Review
- **Path:** `~/Library/Developer/Xcode/iOS DeviceSupport`
- **Discovery:** Static
- **After cleaning:** Re-downloads when you connect a device
- **Typical size:** 2–15 GB
- **Notes:** Contains debug symbols for each iOS version you've connected. Accumulates across iOS updates.

### Simulator Devices
- **Slug:** `simulator_devices`
- **Risk:** Review
- **Path:** `~/Library/Developer/CoreSimulator/Devices`
- **Discovery:** Static
- **Clean commands:** `xcrun simctl shutdown all`, `xcrun simctl delete unavailable`, `xcrun simctl erase all` (run as separate argv commands via `/usr/bin/env`, never a shell)
- **After cleaning:** Recreated when you use Simulator
- **Typical size:** 5–30 GB
- **Notes:** Uses custom clean commands instead of file deletion. Shuts down running simulators, deletes unavailable ones, and erases all data. Because a command frees the bytes (no file walk can attribute them), the cleanup report shows this category as freeing **"up to \<pre-scan size\>"** — exact 0 plus an estimated component equal to the size the scan measured.

### Swift PM Cache
- **Slug:** `swift_pm_cache`
- **Risk:** Safe
- **Path:** `~/Library/Caches/org.swift.swiftpm`
- **Discovery:** Static
- **After cleaning:** SPM re-resolves on next build

### CocoaPods Cache
- **Slug:** `cocoapods_cache`
- **Risk:** Safe
- **Probe command:** `pod cache list --short 2>/dev/null | head -1 | sed 's|/[^/]*$||'`
- **Requires tool:** `pod`
- **Fallback:** `~/Library/Caches/CocoaPods`
- **After cleaning:** `pod install` re-downloads

---

## Package Managers

### Homebrew Cache
- **Slug:** `homebrew_cache`
- **Risk:** Safe
- **Probe command:** `brew --cache 2>/dev/null`
- **Requires tool:** `brew`
- **Fallback:** `~/Library/Caches/Homebrew`
- **After cleaning:** Equivalent to `brew cleanup`
- **Typical size:** 1–10 GB

---

## JavaScript / Node.js

### npm Cache
- **Slug:** `npm_cache`
- **Risk:** Safe
- **Probe command:** `npm config get cache 2>/dev/null`
- **Requires tool:** `npm`
- **Fallbacks:** `~/.npm/_cacache`, `~/.npm`
- **After cleaning:** npm re-downloads packages as needed

### Yarn Cache
- **Slug:** `yarn_cache`
- **Risk:** Safe
- **Probe command:** `yarn cache dir 2>/dev/null`
- **Requires tool:** `yarn`
- **Fallback:** `~/Library/Caches/Yarn`
- **After cleaning:** Yarn re-downloads packages as needed

### pnpm Store
- **Slug:** `pnpm_store`
- **Risk:** Safe
- **Probe command:** `pnpm store path 2>/dev/null`
- **Requires tool:** `pnpm`
- **Fallbacks:** `~/Library/pnpm/store`, `~/.local/share/pnpm/store`
- **After cleaning:** pnpm re-downloads packages as needed

### Bun Cache
- **Slug:** `bun_cache`
- **Risk:** Safe
- **Requires tool:** `bun`
- **Fallback:** `~/.bun/install/cache`
- **After cleaning:** Bun re-downloads packages as needed
- **Notes:** Bun doesn't have a cache-dir command, so discovery uses a dummy probe with tool check + fallback.

### node-gyp Cache
- **Slug:** `node_gyp_cache`
- **Risk:** Safe
- **Requires tool:** `node`
- **Fallback:** `~/Library/Caches/node-gyp`
- **After cleaning:** Re-downloads when native modules are built

### Playwright Browsers
- **Slug:** `playwright_browsers`
- **Risk:** Safe
- **Paths:** `~/Library/Caches/ms-playwright`, `~/Library/Caches/ms-playwright-go`
- **Discovery:** Static
- **After cleaning:** Reinstall with `npx playwright install`

---

## Python

### pip Cache
- **Slug:** `pip_cache`
- **Risk:** Safe
- **Probe command:** `pip3 cache dir 2>/dev/null || python3 -m pip cache dir 2>/dev/null`
- **Requires tool:** None (python3 ships with macOS)
- **Fallbacks:** `~/Library/Caches/pip`, `~/Library/Caches/pip-tools`
- **After cleaning:** pip re-downloads packages as needed

### uv Cache
- **Slug:** `uv_cache`
- **Risk:** Safe
- **Probe command:** `uv cache dir 2>/dev/null`
- **Requires tool:** `uv`
- **Fallback:** `~/.cache/uv`
- **After cleaning:** uv re-downloads packages as needed. Also: `uv cache clean`.

### PyTorch Hub Models
- **Slug:** `torch_hub`
- **Risk:** Review
- **Path:** `~/.cache/torch`
- **Discovery:** Static
- **After cleaning:** Models re-download on next use (can be slow for large models)
- **Notes:** Not selected by default because large model downloads can be very slow.

---

## JVM / Build Systems

### Gradle Cache
- **Slug:** `gradle_cache`
- **Risk:** Safe
- **Path:** `~/.gradle/caches`
- **Discovery:** Static
- **After cleaning:** Gradle re-downloads on next build

---

## Containers

### Docker Disk Image
- **Slug:** `docker_disk`
- **Risk:** Caution
- **Requires tool:** `docker`
- **Fallbacks:** `~/Library/Containers/com.docker.docker/Data/vms/0/data`, `~/Library/Containers/com.docker.docker/Data`
- **After cleaning:** Removes ALL Docker data. Run `docker system prune -a` first.
- **Typical size:** 5–60 GB
- **Notes:** This is Docker's virtual disk containing all images, containers, and volumes. Deleting it is equivalent to a full Docker reset. Not selected by default. Uses sparse file — `totalFileAllocatedSize` reports actual disk usage correctly.

---

## Editors & Desktop Apps

### VS Code Cache
- **Slug:** `vscode_cache`
- **Risk:** Safe
- **Paths:** `~/Library/Caches/com.microsoft.VSCode.ShipIt`, `~/Library/Caches/com.microsoft.VSCode`
- **Discovery:** Static
- **After cleaning:** VS Code re-downloads as needed

### Electron Cache
- **Slug:** `electron_cache`
- **Risk:** Safe
- **Path:** `~/Library/Caches/electron`
- **Discovery:** Static
- **After cleaning:** Re-downloads when Electron apps need it

### Browser Caches
- **Slug:** `browser_caches`
- **Risk:** Review
- **Paths:** `~/Library/Caches/BraveSoftware`, `~/Library/Caches/Google`, `~/Library/Caches/com.brave.Browser`, `~/Library/Caches/com.google.Chrome`
- **Discovery:** Static
- **After cleaning:** Browsers rebuild caches as you browse

---

## AI / LLM

### ChatGPT Desktop Cache
- **Slug:** `chatgpt_desktop_cache`
- **Risk:** Safe
- **Path:** `~/Library/Caches/com.openai.atlas`
- **Discovery:** Static
- **After cleaning:** ChatGPT re-creates cache on next launch

---

## Misc Development

### Prisma Engines
- **Slug:** `prisma_engines`
- **Risk:** Safe
- **Path:** `~/.cache/prisma`
- **Discovery:** Static
- **After cleaning:** Re-downloads on next `prisma generate`

### TypeScript Build Cache
- **Slug:** `typescript_cache`
- **Risk:** Safe
- **Paths:** `~/Library/Caches/typescript`, `~/Library/Caches/next-swc`
- **Discovery:** Static
- **After cleaning:** Regenerated on next build

---

## Project Build Artifacts

In addition to cache categories, Cacheout runs a `build_artifacts` per-item
`SpaceScanner` over your configured DEV ROOTS. It is a RULE TABLE, not a name
list: a directory is reported only when an ecosystem MARKER proves what it
is, so `build/` in a project with no build system is invisible.

| Artifact | Proven by | Risk |
|----------|-----------|------|
| `target/` | sibling `Cargo.toml` | Safe |
| `.build/` | sibling `Package.swift` | Safe |
| `node_modules/` | sibling `package.json` | Review |
| `build/` | sibling `build.gradle` / `build.gradle.kts` / `settings.gradle` / `settings.gradle.kts` | Review |
| `.gradle/` | the same Gradle marker set | Review |
| any directory containing `pyvenv.cfg` | its own entries (PEP 405 — `.venv`, `venv`, `env`, any name) | Review |
| `Pods/` | sibling `Podfile` | Review |
| `dist/` | sibling `package.json` | Review |
| `.next/` | sibling `package.json` | Review |
| `.turbo/` | sibling `turbo.json` | Review |

(The registry in `Sources/Cacheout/Scanner/BuildArtifactRules.swift` is the
source of truth; rows are evaluated in that order, first match wins.)

- **CLI-visible.** `--cli scan` lists each find as a `scanner_items` row;
  `--cli clean build_artifacts --confirm` cleans all of them,
  `--cli clean build_artifacts:<item-id> --confirm` cleans one. Item ids are
  opaque, stable across rescans, and echoed back exactly as scan printed them
  (see [CLI-REFERENCE.md](CLI-REFERENCE.md)).
- **Risk is per RULE ROW, and it narrows.** A `target/` proven by
  `Cargo.toml` is Safe; `node_modules/` and `Pods/` are Review. Whatever the
  row says, an
  artifact directory holding release artifacts is forced to Review and
  deselected. Risk here means evidence confidence — NOT clean eligibility: no
  build-artifact item is ever part of smart-clean or Quick Clean, so every
  deletion is an explicit selection (GUI) or an explicit target with
  `--confirm` (CLI).
- **Release artifacts are protected.** A bounded, no-follow inspection inside
  each matched directory looks for `.dmg`, `.pkg`, `.ipa` files and `.app`,
  `.xcarchive`, `.dSYM` bundles above 5 MB. Anything found is disclosed on
  the row, the item is deselected, and deleting it requires an explicit
  acknowledgement of exactly that set — re-verified immediately before
  deletion, so an artifact produced AFTER the scan still stops the delete.
  See [Release-artifact acknowledgement](CLI-REFERENCE.md#release-artifact-acknowledgement).
- **Selection survives rescans.** Items carry stable ids, so a rescan
  preserves both selections and explicit deselections.

### Dev Roots

Seeded under `$HOME` with: Documents, Developer, Projects, Code, Sites,
Desktop, Dropbox, repos, src, work. Editable in Settings (persisted at
`cacheout.buildArtifacts.devRoots`) and overridable per invocation with the
repeatable `--dev-root` CLI flag. The filesystem root, any volume root or
mount point, and `$HOME` itself are refused as dev roots — in canonical and
symlink-alias spellings alike; protected children such as `~/Documents`
remain legal.

### Scanning Behavior

- Maximum walk depth: 8 levels below each dev root
- Matched artifact directories are PRUNED — nothing beneath a reported
  directory is walked or reported separately
- No name-based skip list, so a nested `packages/build/pkg/node_modules` in a
  monorepo stays reachable; `.git` is the one hard prune
- Nested dev roots walk INDEPENDENTLY (an ancestor's depth budget does not
  cover what a nested root's own budget reaches); overlapping finds collapse
  to one item by canonical identity
- Sizes are allocated and sparse-aware; `logical_bytes` is reported
  separately when the apparent size materially exceeds it
- Results ordered by allocated size descending, then name, then identity

### Staleness

A build-artifact directory is **stale** if its newest content is older than
30 days. Stale directories show an age badge (e.g. "3mo old", "1y old") in
the UI. A directory whose walk dated no content has UNKNOWN staleness — never
a false "fresh".

---

## Orphaned Caches Sweep

Beyond the fixed category allowlist, the `orphaned_caches` scanner sweeps the
FIRST-LEVEL entries of `~/Library/Caches` and explains what it finds — an
allowlist only reclaims what its authors have already seen leak (the field
case: a 31 GB `com.apple.SwiftUI.Drag-<UUID>` directory holding a complete
Photos-library copy, invisible to every category).

- **Tiers.** Known leaks (glob table, e.g. `com.apple.SwiftUI.Drag-*`) are
  Safe; orphaned caches (reverse-DNS name with positively NO installed app)
  and stale-large entries are Review; the largest remaining unclassified
  entries are listed for visibility only. Denied or mount-boundary entries
  are always listed, never hidden by the size cut.
- **Selection.** Only clean known leaks (no user-data-shaped content, fully
  inspected, no denials, no mount boundaries) are ever auto-selected or
  eligible for Quick Clean. Everything else is an explicit user choice.
  CLI `smart-clean` never runs this scanner (it is frozen category-only).
- **Deletion.** Cleaning deletes the entry directory itself (Trash-compatible
  in the GUI). macOS apps recreate their cache directories on demand.
- **Config.** Size floor (default 50 MB, decimal) and stale age (default
  60 days) persist as `cacheout.orphanedCaches.sizeFloorMB` /
  `cacheout.orphanedCaches.staleAgeDays` and can be overridden per
  invocation with `--orphan-size-floor-mb` / `--orphan-stale-days` on
  `scan` and `clean` (see [CLI-REFERENCE.md](CLI-REFERENCE.md)).
- **Entries owned by a registered category** (e.g. `~/Library/Caches/Homebrew`)
  are excluded — they are the category's row, not the sweep's.

**Out of scope: `~/Library/Containers`.** Sandboxed apps keep their caches
inside their app containers (`~/Library/Containers/<bundle-id>/Data/Library/
Caches`); the sweep deliberately does not enter them. `/Library/Caches`
(the system domain) is likewise out of scope.

---

## Stale Git Worktrees

The `git_worktrees` scanner walks the same DEV ROOTS as `build_artifacts`
and finds linked git worktrees whose work is finished — the field case being
23 GB of merged worktrees under a hidden `.claude/worktrees/` directory, each
carrying its own multi-gigabyte build tree. Nothing is name-matched: every
worktree is attributed to its parent repository through git's own registry
and a bidirectional `gitdir` back-link check, and every removal runs through
git.

- **Gates (all four must pass; each fails CLOSED).** A worktree is offered
  only when it is (1) a LINKED worktree, not the main checkout and not bare;
  (2) CLEAN — `git status` with submodules and untracked files forced ON, so
  a repository cannot configure its way to a false "clean"; (3) MERGED — its
  HEAD is a local ancestor of the repository's default branch; (4) NOT
  LOCKED. A command that fails, times out, or cannot be answered fails its
  gate — it never passes silently. Every worktree's evidence names all four
  clauses, and the merge clause is hedged: `--is-ancestor` structurally
  misses squash and rebase merges, so the evidence never claims "not merged"
  as fact. There is no network access anywhere — no `fetch`, no
  `remote prune`.
- **Tiers.** Stale candidates are one item each (Review). Separately, each
  repository with registered checkouts that no longer exist on disk gets ONE
  repository-level item for its orphaned worktree registry (Safe — it removes
  metadata only). A worktree that is assessed and fails a gate is OMITTED
  from the results entirely rather than listed as an un-deletable row.
- **Selection.** Nothing here is ever auto-selected or eligible for Quick
  Clean, whatever the risk says — a git subprocess must never run without an
  explicit choice. CLI `smart-clean` never runs this scanner.
- **Deletion sequence.** A stale worktree is removed with
  `git worktree remove` — never `--force`, because git's own refusal of a
  dirty tree is a safety check worth keeping. If git refuses, the tree is
  re-checked for cleanliness and only then deleted directly, followed by a
  narrowly-gated `git worktree prune --expire=now` that may remove nothing
  but that worktree's own admin entry. The repository-level item runs
  `git worktree prune --expire=now` over exactly the set the scan disclosed.
  **Branch refs and repository objects are never touched** — no branch is
  ever deleted.
- **Move to Trash does not apply.** git unlinks and prunes; it does not
  trash. The confirmation sheet says so per selected item, and the cleanup
  report records what actually happened. If a removal succeeded but left
  admin data behind, the entry carries a warning and the next scan offers the
  leftovers.
- **Timeouts.** A worktree removal is unbounded work. The CLI bounds each git
  invocation itself; MCP callers must apply NO client-side timeout to a
  confirmed clean of `git_worktrees` targets (PROTOCOL.md, "Subprocess
  Timeout").

**Out of scope:** submodules (attributed to nothing and never offered),
locked worktrees, bare repositories as removal targets, anything outside the
configured dev roots, and any worktree whose parent repository, admin data or
tree do not all sit inside ONE declared dev root — git mutates the parent's
admin data, so the whole mutation scope must share a root or nothing is
offered.

---

## Adding a New Category

1. Edit `Sources/Cacheout/Scanner/Categories.swift`
2. Add a new `CacheCategory(...)` entry in the appropriate MARK section
3. Choose the right `PathDiscovery`:
   - Static path: `paths: ["Library/Caches/YourApp"]`
   - Probed: `discovery: [.probed(command: "your-tool --cache-dir", requiresTool: "your-tool", fallbacks: ["Library/Caches/YourTool"])]`
4. Set `riskLevel` conservatively
5. Write a clear `rebuildNote`
6. Set `defaultSelected: true` only for `.safe` categories

Adding a new **per-item scanner** (as opposed to a category) is a different path:
implement the `SpaceScanner` protocol and register it in
`SpaceScannerRuntime.production()` — the ViewModel, cleaner, CLI, and views need
zero edits. See [ARCHITECTURE.md](ARCHITECTURE.md).
