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
- **`build_artifacts`, `orphaned_caches`, `git_worktrees` and `ephemeral_tmp`
  are the per-item scanners**, emitting one item per discovered directory,
  entry or worktree. Follow-on scanners drop into the same registry.
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

An **ephemeral temp root** (`/private/tmp`, or the per-user `…/T` and `…/C`
containers) is a legal dev root, and so is any directory inside one. Cacheout
does **not** de-duplicate findings across scanners: a directory two registered
scanners both recognise is listed twice — once per scanner, same path and same
byte figure, different item ids.

Where that can happen: a dev root that IS a temp root (`build_artifacts` and
`ephemeral_tmp`), and a dev root that IS `~/Library/Caches`, which the
orphaned-caches sweep owns (`build_artifacts` and `orphaned_caches`). Each root
is walked independently; neither is refused.

A dev root **nested inside** one of those roots does **not** produce a
duplicate, and that is structural rather than a matter of luck: a
`build_artifacts` item is always a proper DESCENDANT of its dev root — the
scanner never emits the root itself — while `ephemeral_tmp` (and likewise
`orphaned_caches`) emits exactly its root's FIRST-LEVEL entries. At nesting
depth 1 or more the only object both could claim is the dev root, which one of
them structurally cannot emit, so the two sets are disjoint. Measured: a dev
root at `<tempRoot>/outer` yields `ephemeral_tmp` → `<tempRoot>/outer` and
`build_artifacts` → `<tempRoot>/outer/inner-venv`, different paths in an
ancestor/descendant relation, which is ordinary nesting and not a repeated row;
a dev root that is ITSELF a stale venv yields `build_artifacts` → nothing at
all and `ephemeral_tmp` → one item.

Where the exact-root case does overlap it overlaps narrowly, because the
directory must satisfy BOTH scanners' rules at once. Under a temp root,
`build_artifacts` walks to its full 8-level depth budget with no age gate and
no size floor, while `ephemeral_tmp` lists only that root's FIRST-LEVEL entries
that are at least 10 MB and whose own timestamp and newest content are both
older than 7 days. The one artifact shape that can match a first-level entry
without needing a sibling marker in the root itself is a Python venv
(`pyvenv.cfg` inside), so in practice that is what shows up twice.

What the duplication does and does not affect:

- The **Reclaimable** figure is category-scoped and does not count per-item
  scanner bytes at all, so it is unaffected.
- The **selected-size** figure — including the one the clean confirmation
  quotes — spans scanners, so ticking both copies counts the bytes twice.
  Each per-scanner section total counts its own copy once.
- **Cleaning is not doubled.** Selecting both copies deletes the directory
  once; the second row is refused by its scanner's delete-time re-check
  (the folder it was bound to is gone) with nothing removed and nothing
  reported freed, and the cleanup report's freed total counts the bytes once.
  The refusal is **not silent**: the second row appears in the report as a
  failed item with its own message. This holds in either selection order.
- **Cleaning by address is unaffected**: `clean build_artifacts:<id>` runs
  only that scanner, so the duplicate pair is reachable on the clean path
  only if you pass both addresses in one invocation.

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
  metadata only), disclosing the complete set it will remove; if that
  set cannot be proven complete, NO item is offered and the reason is
  reported instead. A worktree that is assessed and fails a gate is OMITTED
  from the results entirely rather than listed as an un-deletable row.
- **Selection.** Nothing here is ever auto-selected or eligible for Quick
  Clean, whatever the risk says — a git subprocess must never run without an
  explicit choice. CLI `smart-clean` never runs this scanner.
- **Deletion sequence.** Cacheout removes the checkout itself; git is asked
  only questions. Every gate the scan used is re-established against the live
  repository first (which repository the parent path resolves to; still
  registered, still linked, still unlocked, still merged), and anything that
  changed since the scan refuses with the action that clears it named. The
  re-establishment binds the checkout by IDENTITY, not by path: the tree at
  the assessed path must still back-link to the admin directory the scan
  resolved, and that directory must still be the same object — so a checkout
  moved onto that path, or removed and re-created there, is refused rather
  than removed. The identity it compares against is captured when the scan
  WALKS onto the checkout — before it asks git for the repository's worktree
  list — captured again as soon as that list returns, and re-proved
  immediately before the row is armed. All three must agree, so the binding
  spans the scan's own window as well as the scan-to-click one, and it spans
  the listing command itself: git reads those admin directories inside that
  command, and a replacement while it does so shows up as a disagreement
  between the first two captures. A checkout replaced at any point after
  this scan walked onto it is never offered, and the reason is shown rather
  than the row simply vanishing.
  What that does not cover is stated rather than implied: a checkout already
  replaced before the walk reached it is not a substitution this scan can
  see — it is simply the checkout the scan finds, judged on its own evidence
  — and a read that fails on a worktree's admin directory leaves it with no
  identity at all, so it is refused with that reason instead of being
  offered, and a later scan that can read it offers it again.
  A worktree the walk never reached (below the walk's depth budget, or under
  a directory it could not read) is NOT in that population: its identity is
  read directly out of the repository's worktree registry, immediately
  before the list is asked for, so the walk's reach does not decide what can
  be reclaimed. A previous revision of this page described those worktrees
  as refused for want of an identity; that refusal was permanent, because
  the depth budget is fixed and every re-scan reproduced it, and it has been
  removed rather than re-worded. An earlier
  revision of this page said the uncovered part was answered at delete time
  by this same identity; that was wrong and is withdrawn — the delete-time
  check re-stats against the identity the scan carried, so a poisoned one
  simply agrees with itself.
  (That scan-to-click window is the desktop app's, where one
  scan's results stay on screen across your click. `--cli clean` re-scans
  in-process first, so what it removes is what a fresh scan just judged — but
  a replacement checkout at the same path inherits the same item id and is
  removed if it passes all four gates on its own merits. The re-scan
  re-judges the path; it does not detect the substitution.) The cleanliness
  re-check runs LAST, immediately before the delete, so work saved while the
  checks were running is caught rather than destroyed; a tree that went dirty
  in that window is refused and is offered again after a re-scan. The delete
  is then followed by a narrowly-gated removal of nothing but that worktree's
  own admin entry. The repository-level item removes exactly the admin
  directories the scan disclosed, one by one — no repository-wide
  `git worktree prune` runs, because git would re-enumerate its own set after
  every gate had answered. **Branch refs and repository objects are never
  touched** — no branch is ever deleted.
- **Why `git worktree remove` no longer does the removing.** It used to, and
  it was measured to the wrong thing. Handing the removal to git means the
  destruction happens inside git's process, after git has started up, read
  its registry and run its own status walk — and git never re-reads the facts
  Cacheout's gates established. Measured on git 2.50.1: **14.9 ms** between
  the moment git is launched and the moment the first file is gone, on a
  worktree containing a single tracked file, and that gap grows with the tree
  because git's own status walk is inside it. Cacheout's own removal has no
  program to start: the last thing in front of it is a re-proof taken from
  the filesystem on the far side of the disposal hop — **0.03 ms** (permanent
  delete) and **0.004 ms** (Move to Trash) before the destruction, both
  measured with the queue that runs it held busy — and it does not grow. The
  cleanliness answer is not in that re-proof; it is a `git` command, it is
  the last one run, and what its distance from the destruction actually
  measures is in the next bullet. Nothing became removable that was not
  removable before: every case where git refused already ended in this same
  delete. What is new is the refusals that gap used to swallow.
- **The final check before the delete reads the filesystem, not git.**
  Immediately before the removal Cacheout re-reads three things it can answer
  without running a command: that the checkout at that path is still the one
  that was assessed, that nobody has locked it, and that its HEAD has not
  moved. Those cost microseconds, so nothing meaningful happens between them
  and the removal. What they cannot answer honestly: **cleanliness is git's
  answer**. It is the last command run, and it cannot be moved next to the
  destruction, because running a program there would cost more than the gap
  it closes. So work saved after that answer and before the tree goes is not
  seen — and that window is the disposal queue's depth, not a fraction of a
  millisecond. Measured through the shipping code: **185.9 ms** with the main
  thread carrying 120 ms work items (Move to Trash) and **241.2 ms** with the
  background pool saturated (permanent delete). On an idle machine it is a
  fraction of a millisecond. It is a fact about a concurrent writer, not a
  fixed limit: a re-scan judges the worktree afresh. And on a BRANCH, a
  commit made while the checks run does not move HEAD — that commit is not lost, because removing a worktree
  never touches the branch or the repository's objects. A DETACHED worktree,
  where such a commit would be reachable from nothing afterwards, is refused
  outright whenever its HEAD cannot be re-read; put the work on a branch and
  re-scan. Repositories using the `reftable` ref format keep a per-worktree
  HEAD file too, but it is a fixed placeholder rather than the real HEAD, so
  the check reads that worktree's ref stack instead — which also catches a
  commit made on an attached branch, something the ordinary HEAD file cannot.
- **Files your `.gitignore` hides.** `git status` reports nothing at all
  about an ignored path, so this is stated exactly. Ignored content that was
  already in the worktree when the checks began — `node_modules`, `.build`,
  and the rest of what makes a stale worktree worth reclaiming — **is
  destroyed with it**. An ignored file that appears while the GATES are
  running is caught: the ignored list is read once as a witness before them
  and again by the last `git status`, and anything new refuses the removal by
  name. That second reading is the last GIT COMMAND, not the last thing
  before the delete: an ignored file appearing after it sits in exactly the
  same window as any other late save described above, and is destroyed with
  the tree. Two more limits worth knowing: a file created inside a directory
  that is
  itself ignored is inside a collapsed entry and is not detected, and a
  CHANGE to an ignored file that already existed is not detected either. If a
  worktree holds the only copy of something, move it out rather than relying
  on this.
- **Move to Trash covers the checkout, not the registry.** The checkout
  follows the toggle — through the previous release it did not, because git
  did the removing and git unlinks whatever you set. Cacheout does the
  removing now, so Move to Trash applies to the checkout. The `worktrees/<id>`
  registry directory that follows it is removed permanently either way, and a
  repository prune removes admin directories permanently as well. The
  confirmation sheet says exactly that per selected item, and the cleanup
  report records which disposal ran. If a removal succeeded but left admin
  data behind, the entry carries a warning and the next scan offers the
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

## Ephemeral Temp Files

The `ephemeral_tmp` scanner lists stale FIRST-LEVEL entries in the three
ephemeral locations macOS does not reliably prune. Long-lived scratch
directories accumulate there unnoticed — a month-old build sandbox or agent
scratchpad survives reboots and shows up in no cache category.

**Roots (three DECLARED, resolved at runtime).** `/private/tmp`, plus the
per-user temp (`…/T`) and cache (`…/C`) containers under
`/private/var/folders`, whose machine-specific paths come from the OS rather
than being hardcoded. Three declarations can resolve to fewer roots — the
three dispositions that reduce them are:

- a root the OS does not name, or that is **missing** at scan time, is
  skipped **silently**;
- a root that is present but **unreadable** is reported as a **scan issue**,
  never a silent zero;
- a root that is a **symlink naming** another declared root — a `…/C` that is
  a link onto `…/T`, say — is dropped at RESOLUTION time with a
  `symlink_root` issue naming the dropped spelling, so the covering root is
  scanned once instead of twice and the drop is never silent. The ALIAS is
  what goes; the real root always survives. Resolution READS the link and
  never follows it, so a replaced root cannot make Cacheout touch whatever it
  points at while the app is starting up — and a link spelled so that it
  cannot be matched to a declared root is therefore kept rather than dropped,
  and the scan refuses it with the same `symlink_root` issue.

Nothing below the first level is listed: the entry itself is the unit.

**Per-root note on OS cleanup**, shown as item evidence:

| Root | Note |
|------|------|
| `/private/tmp` | no periodic reaper on modern macOS |
| `…/C` (per-user cache container) | macOS does not routinely prune this location during normal operation |
| `…/T` (per-user temp container) | macOS may reap older untouched files here; this age gate is more conservative |

**Scanned only when YOU ask.** This is the one scanner with a trigger
policy: it runs on EXPLICIT user-initiated scans only.
Automatic background refreshes — the scan timer, opening the menubar
popover, switching tabs — never include it, for any root; they enumerate
nothing there at all.
Press Scan (or run `--cli scan`, which is always user-initiated) to see temp
findings. See [CLI-REFERENCE.md](CLI-REFERENCE.md).

**Staleness (the primary shield).** An entry qualifies when its NEWEST
content is older than the age threshold — not the directory's own timestamp
alone. An old directory holding one fresh file deep inside is NOT stale, and
neither is a directory whose own timestamp is fresh. Anything the current
session (Cacheout included) has just written is fresh by construction, which
is exactly what keeps a live session's own scratch directory off the list —
there is no separate exclusion list to fall out of date.

"Content" here means REGULAR FILES. A nested directory's OWN timestamp is
deliberately not an input, at scan time or at delete time — the inputs are the
entry's own timestamp and the mtimes of the regular files below it, so a write
at the top level of the entry is caught while one that only re-stamps a
directory deeper down is not.

That is a claim about the TIMESTAMP, not about the operations that move one.
A nested change can still trip a gate that is not a timestamp: unlinking a
file inside a nested directory can take the entry below the **size floor**
described below, and creating enough subdirectories inside one can push its
contents past the **inspection budget** the staleness walk and the
delete-time re-check are both bounded by. Either of those both keeps the
entry off the list — the
budget arm silently, since a cap denied nothing — and refuses it at delete
time, where the refusal names the budget rather than any timestamp.

**Size floor.** Ordinary small temp files never appear: a MEASURED entry
below the floor is not listed. Denied or mount-boundary entries are always
listed, never hidden by the size cut — the same carve-out the orphaned-caches
scanner states above, and for the same reason: an unverified zero must not
render as "nothing here" (D6).

**Entries other users own are skipped.** `/private/tmp` is shared and
sticky: another user's entry may be readable but is not yours to delete, so
listing it would claim bytes that cannot be freed. Those entries are skipped
silently — that is normal multi-user background noise, not an anomaly. The
per-user `T`/`C` containers are yours by construction, so the rule is
vacuous there. One carve-out, deliberate and measured: the mount-boundary arm
runs BEFORE the ownership probe, so an entry that is a mounted volume is
reported as a refused, not-measured row whoever owns it — the scanner refuses
it without entering, which is precisely why it does not wait to learn the
owner first.

**Entries in use are skipped** when a process holds an advisory lock on the
entry itself. That check is a narrow supplement, not a guarantee: it does
not detect a process merely holding a file open somewhere inside. Age is the
real protection.

**Unreadable entries are reported, not explained away.** If something cannot
be inspected, the scan says so and names it. Cacheout does not claim a
privacy-permission cause it cannot prove from what the filesystem returned —
a bare "operation not permitted" is reported neutrally as unreadable, while a
genuine macOS privacy denial keeps its Full Disk Access remedy hint.

**Selection and deletion.** Every temp item is Review risk, unselected by
default, and never part of Quick Clean or `smart-clean` — deleting one is
always an explicit choice. Cleaning removes the entry directory (or file)
itself; the root is never a target. In the GUI, deletion follows the
Move-to-Trash toggle exactly like every other item, and if a move to Trash
fails, that item is reported as an error and left in place — it is never
silently deleted permanently instead. CLI cleanup is always permanent.

**Config.** Age (default 7 days) and size floor (default 10 MB, decimal)
persist as `cacheout.ephemeralTmp.ageDays` /
`cacheout.ephemeralTmp.minSizeMB` and can be overridden per invocation with
`--tmp-age-days` / `--tmp-min-size-mb` on `scan` and `clean` (see
[CLI-REFERENCE.md](CLI-REFERENCE.md) and
[CONFIGURATION.md](CONFIGURATION.md)).

**Out of scope.** `/var/vm`, swap and sleep-image files, `/Library/Caches`,
and the `…/0` per-user directory are not scanned.

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
