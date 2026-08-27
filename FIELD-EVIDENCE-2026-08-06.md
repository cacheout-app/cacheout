# Field evidence — the 2026-08-06 disk triage Cacheout missed

This is the primary-source case study behind `SCANNERS-ROADMAP.md`. One
machine (the developer's own, macOS 15.x / Darwin 25.5.0, 460GiB APFS) went
from **8.4GiB free (99% full) to 79GiB free** in one session, entirely by
deleting things Cacheout v2.1.9 could not see. Numbers below are real
measurements, not estimates. Treat each subsection as an acceptance-test
scenario for the corresponding epic.

## What was reclaimed

| # | What | Allocated | Where | Roadmap epic |
|---|---|---|---|---|
| 1 | Rust build cache of one Tauri app | 31G (57.1G logical) | `<repo>/src-tauri/target/` | E4 |
| 2 | 11 stale git worktrees | 23G | `<repo>/.claude/worktrees/` | E5 |
| 3 | Old agent-session scratchpads | 2.4G | `/private/tmp/claude-501/` | E6 |
| 4 | Leaked SwiftUI drag cache | 31G | `~/Library/Caches/com.apple.SwiftUI.Drag-<UUID>/` | E3 |

## Scenario 1 — Rust target/ (E4)

- `du` reported 31G allocated; `cargo clean` then reported **"Removed 101424
  files, 57.1GiB total"** — logical size. Rust incremental-compilation files
  are sparse; Finder had shown the repo as "117GB" for the same reason.
  Consequence: scanners must report **allocated** size (Cacheout's existing
  `totalFileAllocatedSize` choice is correct) and may show logical only as a
  secondary figure when it diverges.
- Split inside: `target/debug` 28G, `target/release` 3.1G.
- **The valuables trap:** `target/release/bundle/dmg/Murmur_0.1.7_aarch64.dmg`
  (42MB) was the *only copy in existence* of the app's notarized release DMG
  (no GitHub releases published; rebuilding requires a full sign+notarize
  pipeline). It had to be moved out **before** `cargo clean`. E4's valuables
  gate exists because of this file. Do not assume build dirs contain only
  regenerable bytes.

## Scenario 2 — stale git worktrees (E5)

- 11 worktrees under `<repo>/.claude/worktrees/` — a **hidden** directory, so
  any walk using `.skipsHiddenFiles` (as NodeModulesScanner does) can never
  find this class. Two of them alone held 21G (14G + 7.2G), almost all of it
  their own nested `target/` dirs.
- Every one was verified before deletion: `git status --porcelain` empty AND
  branch merged into `main`. Those two checks are E5's candidate gates,
  verbatim.
- **Observed failure your code must handle:** `git worktree remove --force`
  succeeded on 9 of 11 but failed on the two big ones with
  `error: failed to delete '<path>': Directory not empty` — git's own
  remover chokes on large ignored subtrees. The working fallback was
  `rm -rf <path>` followed by `git worktree prune` in the parent repo.
- After removal, `git worktree list` showed only the main checkout and **all
  28 branch refs survived**, including one unmerged hotfix branch whose
  worktree lived elsewhere — demonstrating that worktree removal never
  deletes branches. E5's `evidence` string should state this to the user.
- **SCOPE OF THAT OBSERVATION (PR #460 codex r1).** Every worktree in this
  scenario was checked out ON A BRANCH, so "28/28 branch refs survived" says
  nothing about a DETACHED worktree — which has no branch ref at all, and
  whose removal therefore leaves whatever HEAD names reachable from no ref
  (measured on git 2.50.1: the commit becomes a dangling object, surfaced
  only by `git fsck`, and the worktree's `logs/HEAD` — the one reflog that
  named it — is deleted alongside). The shipped `evidence` string carries the
  branch sentence for ATTACHED worktrees only.

## Scenario 3 — /private/tmp scratchpads (E6)

- `/private/tmp/claude-501/<project>/<session-uuid>/` scratchpads from
  agent sessions: 2.4G, oldest from early July — they had survived ~1 month
  and multiple reboots. "tmp gets cleaned automatically" is not a safe
  assumption for sizing purposes.
- One subdirectory belonged to the **currently running session** and had to
  be excluded — age-based filtering (newest-content mtime) is mandatory, not
  cosmetic.

## Scenario 4 — the SwiftUI drag-cache leak (E3)

- `~/Library/Caches/` totaled 34G; **31G was one directory**:
  `com.apple.SwiftUI.Drag-C39B49C5-…/Pictures` — 312,270 files, a complete
  copy of the user's Photos library (`Photos Library.photoslibrary/…`),
  all file dates 2026-03-21…03-31. Mechanism: a drag of the Pictures folder
  in some SwiftUI app made the drag machinery flatten-copy the entire
  payload into its cache, which was never cleaned up. A second, small
  `com.apple.SwiftUI.Drag-<UUID>` dir was also present — the pattern is a
  **glob**, not a single path.
- Cacheout's category list (fixed known paths) cannot represent "a novel
  UUID-named directory that appeared in Caches and got huge" — hence E3's
  enumerate-and-explain sweep with top-N-by-size always shown.
- **Verification before deletion (the part that must not be skipped):** the
  cache contained something *named like user data*. Deletion was approved
  only after confirming the real `~/Pictures/Photos Library.photoslibrary`
  existed and its `database/Photos.sqlite` had a current mtime (written the
  previous day) — proving the cached copy was a stale duplicate. E3 should
  surface a similar caution in `evidence` when a leak candidate contains
  user-data-shaped trees (`*.photoslibrary`, `Documents/`, …): "verify the
  original exists" rather than plain "safe".

## Cross-cutting observations

- **TCC:** `du -sh ~/Pictures` from an unentitled terminal returned **8.0K**
  (exit 1) while the directory actually held a multi-GB Photos library —
  macOS denies enumeration inside TCC-protected locations, and the failure
  mode is *silently tiny numbers*, not an error dialog. A `stat` on a known
  inner file still worked. Scanners must treat permission failure as a
  distinct visible state (roadmap D6), never as "0 bytes".
- **Finder vs reality:** Finder said the repo was "117GB"; `du` said 55GiB
  allocated. Decimal units plus sparse-file logical sizes fully explain the
  gap. Allocated size is the number that predicts freed disk space.
- **Where the freed space went:** 8.4GiB free → 64GiB after scenarios 1–3 →
  79GiB after scenario 4.
