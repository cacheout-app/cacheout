# Disk Scanner Roadmap — closing Cacheout's blind spots

Anchored to **v2.1.9, commit `d747412`, written 2026-08-06**. Every file/line
reference below was verified on that commit. If you are reading this later,
grep before you trust a line number — code moves, this document does not.

Companion document: **FIELD-EVIDENCE-2026-08-06.md** (repo root) — the real
disk triage that motivated this roadmap, including exact failure modes new
code must handle. Read both before starting any epic.

The work is tracked as flow-next epics in `.flow/` (see `CLAUDE.md`). Order:

```
E1 safety hardening → E2 SpaceScanner protocol → E3 orphaned-caches sweep
                                               → E4 project build artifacts
                                               → E5 git worktrees
                                               → E6 ephemeral temp dirs
```

E3–E6 all depend on E2 only; the serial order above is the recommended
priority (biggest surprise-catcher first), not a hard dependency.

## Why: ~87GB was invisible

A single machine triage on 2026-08-06 recovered ~87GB that Cacheout v2.1.9
could not see:

| Space hog | Allocated size | Blind-spot class |
|---|---|---|
| Rust `target/` in a Tauri project | 31G (57.1G logical) | No per-project build-artifact scanning beyond node_modules |
| Stale git worktrees under `.claude/worktrees/` | 23G | No worktree concept + hidden dirs skipped |
| `~/Library/Caches/com.apple.SwiftUI.Drag-<UUID>/` | 31G | Category allowlist can't see novel/leaked cache dirs |
| Session scratchpads in `/private/tmp/` | 2.4G | Nothing scans outside `$HOME` |

The structural lesson: an **allowlist cleaner only reclaims what its authors
have already seen leak**. The roadmap adds one enumerate-and-explain sweep
(E3) plus three rule-driven per-item scanners (E4–E6), on top of a unified
scanner abstraction (E2) and safety fixes (E1).

## Current architecture (what you will touch)

Disk-cleaning code lives entirely in `Sources/Cacheout/`; the memory-pressure
subsystem (`Intervention/`, `Memory/`, `Helper/`, `CacheoutHelper*`,
`Headless/`) is disjoint — **do not touch it** in these epics.

- **Category registry** — `Scanner/Categories.swift`: `CacheCategory.allCategories`,
  a flat `static let` array of 23 data-only entries. There is no scanner
  protocol; a "category" is data (name, slug, icon, discovery, risk, rebuild
  note) resolved to URLs elsewhere.
- **Discovery** — `Models/CacheCategory.swift` (`PathDiscovery`, ~:57-70):
  `.staticPath` (relative to `$HOME`), `.probed(command:requiresTool:fallbacks:)`
  (`/bin/bash -c`, 2s timeout, fixed PATH), `.absolutePath` (**defined but
  unused by any real category** — only tests use it). Resolution in
  `resolvedPaths` (~:131-179), always relative to `homeDirectoryForCurrentUser`
  for static paths.
- **Aggregate scanner** — `Scanner/CacheScanner.swift` (actor): TaskGroup over
  categories. `directorySize(at:)` (~:68-100) enumerates with
  `[.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]`
  and options `[.skipsHiddenFiles, .skipsPackageDescendants]`, summing
  allocated size of regular files only.
- **Per-item scanner (the only one)** — `Scanner/NodeModulesScanner.swift`
  (actor): hardcoded `$HOME`-relative roots (~:35-46), skip list
  `build, dist, .build, Pods, .next, Library, .cache, .git` (~:49-53),
  `maxDepth: 6`, stops descending at the first `node_modules` (~:100-102),
  and has its **own** `directorySize` (~:122-137) that differs from
  CacheScanner's (no `isRegularFile` filter). Produces `NodeModulesItem`,
  not `ScanResult`.
- **Cleaner** — `Cleaner/CacheCleaner.swift` (actor), entry
  `clean(results:nodeModules:moveToTrash:)` ~:42. Three strategies:
  `cleanCommands` argv arrays via `/usr/bin/env` (never a shell, 30s timeout,
  ~:115-147); trash-per-child (~:246-254); permanent delete per-child with an
  8-wide TaskGroup (~:149-177). Category cleans preserve the parent dir;
  node_modules cleans remove the dir itself. Logs to `~/.cacheout/cleanup.log`
  (`openat` + `O_NOFOLLOW`, 0700/0600).
- **Orchestration** — `ViewModels/CacheoutViewModel.swift`: `scan()` (~:151-170)
  runs the two scanners via parallel `async let`; separate selection helpers
  for categories vs node_modules (~:178-221). `moveToTrash` defaults `true`
  in GUI.
- **CLI** — `CLIHandler.swift`: `scan`/`clean`/`smart-clean`/`spotlight`.
  node_modules is **absent from the CLI**. `clean` and `smart-clean` hardcode
  `moveToTrash: false` (permanent) with **no confirmation flag** (~:292, ~:353).
- **Views** — `ContentView` (results list ~:152-172), `CategoryRow`,
  `NodeModulesSection`, `CleanConfirmation` (itemization ~:59-71).
- **Size formatting** — `ByteCountFormatter` via `Helper/Formatters.swift`
  (base-10 `.file` style). Disk totals: `Models/DiskInfo.swift` (~:46-59).
- App is **not sandboxed**; hardened runtime only; the bundled Info.plist
  (written by `scripts/bundle.sh` ~:135-163) has **no TCC usage strings**,
  which matters for anything reading `~/Documents`/`~/Desktop` (see D6).

## Known defects — fix in E1, because every new scanner inherits them

| # | Defect | Where (v2.1.9) |
|---|---|---|
| D1 | Freed-bytes over-report: the per-category loop adds the whole category total once **per resolved path** — a 4-path category reports up to 4× | `CacheCleaner.swift:63-73` |
| D2 | `.skipsPackageDescendants` makes every `.app`/`.xcarchive`/bundle count as **0 bytes** (bundle dir is not a regular file) — guts DerivedData/Products and Simulator sizes | `CacheScanner.swift:77` |
| D3 | `.skipsHiddenFiles` in both size walks: undercounts `node_modules/.pnpm` (where pnpm puts ~all bytes) and hides projects under hidden dirs entirely | `CacheScanner.swift:77`, `NodeModulesScanner.swift:108,127` |
| D4 | No protected-path guard anywhere: nothing validates a resolved deletion target is not `/`, not `$HOME` itself, not a symlink escaping an approved root; `.probed` stdout is trusted wholesale | `CacheCleaner.swift`, `CacheCategory.resolvedPaths` |
| D5 | CLI `clean`/`smart-clean` permanently delete with no `--confirm` gate (the memory subsystem's `intervene` already requires `--confirm` — match it) | `CLIHandler.swift:292,353` |
| D6 | Silent failure: enumerator nil → `(0,0)`; throws → `continue`; TCC denial reads as "0 bytes found" instead of an error state | `CacheScanner.swift:79,95`, `NodeModulesScanner.swift:105-109` |
| D7 | Two divergent `directorySize` implementations (regular-file filter vs none) | see above |
| D8 | APFS clones/hardlinks counted at full size per link → cross-category double count (pnpm store ↔ project node_modules); headline total overstates | `CacheoutViewModel.swift:117-119` |

> **Reading the "Where" column.** Those line numbers are `d747412`'s, per the
> header rule — `git show d747412:<path>` reads them, HEAD does not.
> `NodeModulesScanner.swift` (rows D3 and D6) has since been RETIRED along
> with the `node_modules` scanner slug (see CHANGELOG.md, `[Unreleased]`,
> PRE-RELEASE RENAME); per-project `node_modules` is now scanned by
> `BuildArtifactsScanner`. `SourceAnchorIntegrityTests` enforces both halves
> of this paragraph: a Markdown file that cites a Swift line must declare the
> commit it was verified at, and every file it cites must exist or be
> accounted for.

Size math is otherwise **correct**: `totalFileAllocatedSize` (on-disk blocks)
is the right key. Field evidence: a Rust target dir was 57.1G logical but 31G
allocated (sparse incremental files). Any new scanner must use allocated size;
show logical alongside only when they diverge materially.

## E2 — the SpaceScanner protocol (target architecture)

The model gap: `CacheCategory` supports only one aggregate row per category;
per-item categories require replicating NodeModulesScanner across ~6 files
(model, scanner, view model, cleaner, two views) — and it still never reached
the CLI. Introduce the missing abstraction; suggested shape (adapt as the
code demands, this is not a frozen API):

```swift
protocol SpaceScanner: Sendable {
    var id: String { get }            // stable slug, CLI-addressable
    var displayName: String { get }
    func scan() async -> ScanOutcome  // items + non-fatal errors, never traps
}

struct ReclaimableItem {              // ONE unified currency for GUI+CLI+cleaner
    let id: String
    let url: URL
    let allocatedBytes: Int64
    let logicalBytes: Int64?          // only when it diverges (sparse)
    let itemCount: Int
    let risk: RiskLevel
    let evidence: String              // human-readable WHY it is reclaimable
    let action: ReclaimAction         // .removeContents | .removeItem | .commands([[String]]) | .composite
    let rebuildNote: String?
}
```

- `CategoryScanner` wraps `allCategories` (one aggregate item per category) —
  existing behavior preserved, zero category churn.
- `NodeModulesScanner` ports to the protocol → per-item rows, and thereby
  reaches the CLI for free.
- ViewModel/CLI/confirmation sheet consume a `[any SpaceScanner]` registry;
  selection, totals, and cleaning are written **once** against
  `ReclaimableItem`.
- `evidence` is a first-class field: E4/E5 safety rests on showing the user
  *why* something is deletable ("clean, merged into main, last commit
  2026-06-27"), not just a size.

## E3 — orphaned-caches sweep (`~/Library/Caches`)

Enumerate-and-explain, the counterpart to the curated allowlist:

- Enumerate `~/Library/Caches/*` (one level), computing allocated size + last
  content mtime per entry. **Always** surface the top-N by size, classified
  or not — nothing 31GB-shaped may hide again.
- Classification tiers → risk + evidence:
  1. **Known leak globs** → safe: `com.apple.SwiftUI.Drag-*` (SwiftUI drag
     flattening leaks entire payload trees; field case was a 31G Photos
     library copy). Requires a new `.glob(pattern:)` discovery kind or
     scanner-local matching — the existing `PathDiscovery` has none.
  2. **Orphans** → review: reverse-DNS entries whose bundle id matches no
     installed app (`LSCopyApplicationURLsForBundleIdentifier` /
     `NSWorkspace.urlForApplication(withBundleIdentifier:)`, plus existence
     checks in `/Applications`, `~/Applications`, Homebrew caskroom).
  3. **Stale + large** → review: over a size floor and untouched > 60 days.
- Skip entries already owned by an existing category (Homebrew, pip, browser
  caches…) to avoid double listing — match by resolved path prefix.
- Deletion: contents-preserving (`.removeContents`) like other categories.

## E4 — project build artifacts (generalizes NodeModulesScanner)

- **Dev roots must be configurable** (UserDefaults + Settings UI + CLI flag),
  seeded with the current hardcoded list + `~/Documents/GitHub`. The field
  machine keeps everything under `~/Documents/GitHub` — the hardcoded list
  misses it today.
- One walk, a **marker-sibling rule table** — a directory is only ever
  reclaimable when its marker file sits beside it (this is the safety
  property):

| Artifact dir | Required sibling | Risk |
|---|---|---|
| `target/` | `Cargo.toml` | safe |
| `node_modules/` | `package.json` | safe |
| `.build/` | `Package.swift` | safe |
| `build/` | `build.gradle`/`build.gradle.kts`/`settings.gradle` | review |
| `.venv/`, `__pycache__/` | `pyproject.toml`/`setup.py`/`requirements.txt` | safe |
| `Pods/` | `Podfile` | review |
| `dist/`, `.next/` | `package.json` | review |

- **Valuables gate** (field lesson — a notarized DMG existed *only* in
  `target/release/bundle/dmg/`): before offering an artifact dir, scan it for
  `*.dmg`, `*.pkg`, `*.ipa`, `*.app` bundles above a size floor; if found,
  attach a warning to `evidence` and offer a rescue (reveal in Finder /
  skip-by-default), never silently include them in a wipe.
- Report last-build age (newest mtime within, bounded scan) and sort
  stale-first. Walk fixes over the old scanner: do **not** prune on
  directories merely *named* `build`/`dist` (kills monorepo packages) — prune
  only when the dir itself matched a rule; include hidden files in sizing
  (D3); do not stop at the first hit — nested workspaces are real.
- Deletion: `.removeItem` (the artifact dir itself), matching node_modules
  semantics.

## E5 — stale git worktrees

- Discover repos during the E4 walk (share it): a `.git` **directory** is a
  main checkout; a `.git` **file** is a linked worktree. The walk must
  traverse hidden directories (field case: 23G under `.claude/worktrees/` was
  invisible purely because the dir is hidden).
- Per main repo: `git worktree list --porcelain`. A linked worktree is a
  candidate only when ALL hold (each check is `evidence`):
  1. not the main worktree;
  2. `git -C <wt> status --porcelain` is empty (no dirty/untracked files);
  3. its HEAD is an ancestor of the repo's default branch
     (`git merge-base --is-ancestor HEAD <default>`; resolve default via
     `origin/HEAD` with local-`main`/`master` fallback);
  4. (tiebreaker for display) last commit age.
- Also list orphaned admin dirs from `git worktree list --porcelain` /
  `prune --dry-run` (checkout already gone) — those are pure metadata,
  safe tier.
- **Deletion semantics (field-proven):** try `git worktree remove <path>`
  first; on failure — git fails with `Directory not empty` when the worktree
  contains large ignored trees like nested `target/` — fall back to deleting
  the tree (`.removeItem`, honoring trash setting) followed by
  `git worktree prune` in the parent repo. Branch refs live in the main
  repo's `.git` and **survive removal by construction**; say so in
  `evidence`.
  - **CORRECTED AS BUILT (PR #460 codex r1).** Two claims in the bullet above
    are wrong as written, and both had shipped. (a) "Branch refs survive by
    construction" holds only for a worktree checked out ON A BRANCH: a
    DETACHED worktree has no branch ref, so removal leaves whatever HEAD
    names reachable from nothing — the evidence now says that instead for
    that shape. (b) `git worktree prune` accepts no path and no set; it
    re-enumerates the admin container itself, after every gate has already
    answered. The shipped code therefore removes exactly the admin
    directories it disclosed and runs no repository-wide prune.
  - **CORRECTED AS BUILT AGAIN (PR #460 codex r5/r6).** The bullet's whole
    "try `git worktree remove` first, fall back to deleting the tree" shape is
    retired. There is no first arm and no fallback: git is READ-ONLY on the
    delete path (`rev-parse --git-common-dir`, `worktree list --porcelain`,
    `status --porcelain --ignored`, the ancestry ladder), and Cacheout removes
    the checkout itself under `DepthSafeRemoval` — or moves it to the Trash
    under `TrashDisposal`, which the git arm could never do — with the
    filesystem re-proved at the last instant. MEASURED (git 2.50.1, macOS 15,
    APFS), and each figure with its own endpoint and load condition — r5's
    whole correction was that these differ: `git worktree remove` takes
    14.87 ms (1 tracked file) / 156.8 ms (2001) between its SPAWN and its
    first destruction, NOT between the last gate and it. The corresponding
    interval for the shipped removal is the last identity/lock/HEAD proof →
    the destruction, which since r6/r7 runs on the far side of each arm's
    hop: 0.032 ms (permanent, global pool saturated) / 0.004 ms (Trash,
    120 ms main-thread work items). The cleanliness answer cannot cross that
    hop, and its own window under those same loads is 241.2 ms / 185.9 ms
    (0.373 ms / 0.674 ms on an idle main thread) — that is the figure this
    bullet used to print as "0.373 ms constant". The tables and their
    caveats are in `WorktreeReclaimPerformer`'s header, including that its
    0.417 ms `removefile` row is a PROXY harness rather than this code.
    The `Directory not empty` field class the bullet was written around is now
    REFUSED rather than routed: the last gate runs `status --porcelain
    --ignored`, so an ignored tree that appeared since the scan aborts the
    removal.
- Risk: review; `defaultSelected: false`. Never touch a worktree that fails
  any gate; never run `git branch -d`.
- Run git binary via argv (`/usr/bin/env git …`), no shell, bounded timeout —
  reuse the `runCleanCommand` pattern.

## E6 — ephemeral temp dirs

- Roots: `/private/tmp` and the per-user darwin dirs — resolve
  `NSTemporaryDirectory()`/`confstr(_CS_DARWIN_USER_TEMP_DIR)` (`…/T`) and
  `_CS_DARWIN_USER_CACHE_DIR` (`…/C`) rather than hardcoding `/var/folders`
  paths.
- Candidate = top-level entry older than a threshold (default 7 days, config)
  by newest-content mtime, above a size floor. Field case: agent-session
  scratchpads under `/private/tmp/claude-501/` survived a month and reboots.
- Exclusions: sockets/FIFOs/anything currently open (best-effort `lsof`-style
  check is optional; at minimum skip entries with mtime < threshold), and the
  currently-running Cacheout's own temp. Risk: review, `defaultSelected:
  false` — other apps' live state can look stale.
- This is where the **unused `.absolutePath` discovery kind** (or the new
  scanner protocol directly) finally earns its keep; everything today
  resolves relative to `$HOME` and never sees these roots.

## Cross-cutting requirements (all epics)

- **Protected-path guard (D4), enforced in the cleaner, not per-scanner:**
  canonicalize (resolve symlinks) every deletion target and refuse unless it
  is strictly inside an approved root set (`~/Library/Caches`, configured dev
  roots, temp roots, …); refuse `/`, any volume root, `$HOME`, and any
  first-level `$HOME` child (`~/Documents`, `~/Pictures`, …) as a whole.
  Depth alone is not safety — the rule is "inside an approved root AND not a
  protected ancestor".
- **TCC reality:** reading `~/Documents`/`~/Desktop` triggers consent; denial
  must surface as a visible "couldn't scan X" state, never silent 0 (D6).
  `scripts/bundle.sh` must gain the relevant usage strings. Note: even `du`
  under `~/Pictures` returns garbage without consent — tests must not assume
  TCC grants.
- **Tests:** SwiftPM (`swift test`, `Tests/CacheoutTests/`). Every scanner
  takes an injectable root (like `CacheCleanerTests` uses temp dirs) — no
  test may scan the real `$HOME`. E5 tests build throwaway git repos in a
  temp dir (`git init`, `git worktree add`) — git is available on CI/macOS.
- **Docs:** README claims "15 categories", `docs/v1/CATEGORIES.md` says
  "25+"; actual is 23. Whoever ships E2 should replace hardcoded counts with
  a derived number or delete the claims (censuses rot).
