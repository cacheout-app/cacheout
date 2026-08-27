# Changelog

All notable changes to Cacheout will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Scanner unification (`SpaceScanner` protocol) plus the project
build-artifacts and stale-git-worktree scanners. Breaking CLI release for
JSON consumers: `schema_version` is now 4 and `--cli scan` emits an envelope
instead of a top-level array. Coordinate MCP updates with `cacheout-mcp` (see
PROTOCOL.md and docs/v1/CLI-REFERENCE.md) — the pre-release `node_modules` →
`build_artifacts` slug rename and the `git_worktrees` no-client-timeout rule
below are both part of that coordination, and the latter BLOCKS this release.

### Added

- **Stale git worktrees in the GUI and the CLI.** A `git_worktrees` per-item
  scanner walks your configured dev roots for LINKED git worktrees whose work
  is finished — the field case being 23 GB of merged worktrees under a hidden
  `.claude/worktrees/` directory. A worktree is offered only when all four
  gates pass: linked (not the main checkout, not bare), clean (`git status`
  with submodules and untracked files forced on, so a repository cannot
  configure its way to a false "clean"), merged into the repository's default
  branch by local ancestry, and not locked. Every gate fails CLOSED — a
  command that fails, times out or cannot be answered never passes — and each
  row carries all four clauses as evidence, with the merge clause hedged
  because `--is-ancestor` structurally misses squash and rebase merges. A
  worktree that fails a gate is omitted rather than listed as an undeletable
  row, and so is one whose git admin directory cannot be identified at scan
  time — the check that later proves it is still the same checkout cannot be
  armed without that, so the scan reports the problem instead of offering the
  row. Separately, each repository whose registered checkouts no longer exist
  on disk gets ONE item for its orphaned worktree registry, disclosing exactly
  the set it will remove — unless one of those registrations was DETACHED at a
  commit no branch, tag or other ref reaches. That registration's admin data
  is the only name the commit has, so removing it would leave your work
  unreachable and a later `git gc` could delete it; Cacheout then offers
  nothing for that repository and tells you which commit to name. Naming it
  (`git branch`, `git tag`, a merge or a push) clears the refusal on the next
  scan, and the check runs again at clean time. `--cli scan` reports both as `scanner_items` rows
  and `--cli clean` accepts `git_worktrees` or `git_worktrees:<item-id>` —
  destructive runs still require `--confirm`. Nothing here is ever
  auto-selected, Quick-Cleaned, or reached by `smart-clean`. The macOS
  privacy prompts for Documents and Desktop now name worktree discovery
  alongside build artifacts, in all three build paths — the prompt describes
  every scanner that actually walks those roots.
- **Worktree removal is Cacheout's own, and git is only asked questions.**
  It used to be `git worktree remove`, and the entry that described it
  measured the wrong thing: it called the moment git was LAUNCHED "the
  destructive call". It is not. git then starts up, reads its registry, runs
  its own status walk over the whole tree, and only then unlinks — and it
  never re-reads the facts the checks just established. Measured on git
  2.50.1: **14.9 ms** (median of ten) between launching git and the first
  file being gone, on a worktree holding a single tracked file, and the gap
  GROWS with the tree because git's status walk sits inside it. Cacheout
  removes the checkout itself now, with the identity, lock and HEAD re-proof
  immediately in front of it — **0.03 ms** (permanent) and **0.004 ms**
  (Trash) before the destruction, both with the queue that runs it held busy —
  and it does not grow. The cleanliness answer is not in that re-proof and
  cannot be — it runs `git` — and its own distance from the destruction is
  given, with its load condition, in the "permanent delete now does the same
  across its own hop" entry below. Nothing became
  removable that was not removable before — every case where git refused
  already ended in this same delete. What is new is the refusals that gap
  used to swallow.

  Before the removal, the gates the scan used are re-established against the
  live repository: which repository the parent path actually resolves to, and
  whether the worktree is still registered, still linked, still unlocked and
  still merged. Anything that changed since the scan refuses, names the
  action that clears it ("run `git worktree unlock …`", "merge, rebase or
  push that commit"), and deletes nothing. The tree is re-checked for
  cleanliness LAST, immediately before deleting — so work you save while the
  checks are running is found, not destroyed — and the delete is followed by
  a narrowly gated removal of that worktree's own admin entry. A tree that
  went dirty in that window is refused; commit, stash or stop writing,
  re-scan, and it is offered again.

  The re-establishment also proves WHICH worktree it is about, by identity
  and not by path: the checkout at the assessed path must still back-link to
  the admin directory the scan resolved AND that directory must be the same
  object the scan saw. So a checkout you moved onto that path, and equally
  one you removed and re-created there, is refused rather than removed — the
  replacement is judged on its own merits by the next scan. That identity is
  taken when the scan first WALKS onto the checkout, before it asks git for
  the repository's list of worktrees, and it is taken a second time once
  that list comes back and a third time before the row is armed. All three
  must agree, so a checkout replaced at any point after the scan walked onto
  it — including while git was producing the list itself — is refused with a
  visible reason rather than offered, because the row's evidence would
  describe a checkout that is already gone.

  A worktree the walk never reaches is offered too, and its identity is read
  straight out of the repository's own worktree registry immediately before
  that list is asked for. For one release it was not: such a worktree was
  refused by every scan, with a message saying the next scan would clear it.
  Nothing could. The walk stops at a fixed depth below each of your dev
  roots, no setting changes it, and a checkout registered deeper than that —
  or under a directory the walk cannot read — was invisible to the walk on
  every future scan just as it was on the first, while git listed it every
  time. What can still refuse a row for want of an identity is a read that
  FAILS on both paths — a permission blip, an entry that vanished — and that
  one a re-scan genuinely can clear.
  (Two earlier drafts of this entry were wrong about where that identity was
  taken, each in the same direction. The first said it was taken before the
  worktree was examined; the second said it was taken at the repository
  listing. Both were still taken AFTER the read that produced the row's
  evidence, so a checkout replaced the instant the listing returned was
  offered anyway — silently, with no reason shown at all, armed with the
  REPLACEMENT's identity, and destroyed by the clean that followed. Both
  drafts also said the remaining gap was answered at delete time by this
  same identity. IT WAS NOT, and that claim is withdrawn: the delete-time
  check compares against the very identity that had been poisoned, so both
  sides of it were the replacement and it agreed with itself. The window was
  also larger than the second draft said — it grew with the number of
  worktrees in the repository. All of this was measured, and is now
  refused. A THIRD correction, to the entry that reported the second: it said
  the identity was taken when the scan walks onto the checkout, and for one
  release the code did not do that — it took it once the whole walk had
  finished, for every checkout in the tree at once. So a checkout replaced
  after the scan had walked onto it but before that pass reached it was
  offered silently, armed with the replacement's identity, and destroyed by
  the clean that followed; and the window grew with the size of your tree and
  with the number of worktrees in the repository, rather than being the fixed
  thing that entry described. The identity is now taken where the entry always
  said — the moment the scan sees the checkout's `.git` — and what is left
  uncovered is one step of the scan's own directory read, which does not grow
  with anything. A related message correction rides with it: a checkout whose admin
  directory could not be stat'd for a moment — a permission blip, an entry
  that vanished and came back — used to be reported as one that "was replaced
  while this scan was running". It now says the identity could not be read
  and the gate could not be armed, which is what actually happened; either
  way the row is not offered.) (This window is
  the desktop app's, where one scan's results stay on screen across your
  click. An earlier draft of this entry said `--cli clean` was protected
  because its re-scan answers a replacement with "unknown item id — rescan
  and retry"; that was WRONG and is corrected here. Item ids are derived from
  the scanner and the path, so a replacement at the same path has the same
  id, and candidacy has no age term — the CLI's re-scan re-judges whatever is
  at the path, and removes it if all four gates pass on its own merits. It
  does not detect the substitution.)

  Immediately before the delete, three further facts are re-read straight
  from the filesystem — that the checkout is still the assessed one, that
  nobody has locked it, and that its HEAD has not moved — which costs
  microseconds rather than further git commands. What that cannot cover is
  stated rather than implied: cleanliness is git's answer and is the last
  command run; and on a branch, a commit made while the checks run does not
  move HEAD — that commit survives on the branch, which no removal here
  touches. A DETACHED worktree whose HEAD cannot be re-read from disk is
  refused outright rather than removed, because a commit lost there would be
  reachable from nothing; put the work on a branch and re-scan.

  A correction to the previous entry, which said repositories using the
  `reftable` ref format "keep no per-worktree HEAD file". They keep one.
  Measured on git 2.50.1, `git init --ref-format=reftable` followed by
  `git worktree add --detach` leaves a `HEAD` file that reads
  `ref: refs/heads/.invalid`, unchanged in bytes across a detached commit,
  while git reports a real commit id. The file is there and readable; what it
  cannot do is corroborate anything. Those repositories are now checked
  through the worktree's own ref stack instead, which moves on every ref
  write — and that catches a commit made on an ATTACHED branch too, which the
  ordinary HEAD file cannot. Through the previous release an attached
  worktree in such a repository had no HEAD check at all.

  **Files your `.gitignore` hides are now accounted for honestly.** `git
  status` reports nothing about an ignored path, so the previous entry's
  promise that "work you save while the checks are running is found" was
  false for anything ignored — measured, a `secret.env` written in that
  window was destroyed with the tree and the report showed a plain success.
  The ignored list is now read before the checks and again immediately before
  the delete, and a path that APPEARED refuses the removal by name. Ignored
  content that was ALREADY there is still destroyed with the worktree — that
  is the point of the feature — and two limits are stated rather than
  implied: a file created inside a directory that is itself ignored is not
  detected, and a change to an ignored file that already existed is not
  detected.

  The repository-level item removes exactly the admin directories it
  disclosed, one at a time — no repository-wide `git worktree prune` runs,
  because git recomputes that command's set for itself after every check has
  already answered, and a second checkout of the same repository that
  vanished in between would be swept without ever having been listed.
  **No branch is ever deleted and repository objects are never touched.**

  **Move to Trash now applies to the checkout.** It did not before: git
  unlinked the tree whatever the toggle said, and the app ships with Move to
  Trash ON, so the most common worktree removal was unconditionally
  unrecoverable. The `worktrees/<id>` registry directory that follows the
  checkout is still removed permanently, as is a repository prune, and the
  confirmation sheet discloses exactly that split per selected item. The
  cleanup report records which disposal ran. A removal that succeeded but
  left admin data behind reports a `warning` on its row (the bytes were still
  freed) and the next scan offers the leftovers.

  **And the last check before a Trash move now runs on the same thread the
  move does.** Moving an item to the Trash has to happen on the app's main
  thread — that is macOS's rule, not ours — while every safety check ran just
  before hopping onto it. The gap between the two was therefore however long
  the main thread was busy, not a fraction of a millisecond: measured through
  the shipping code with the main thread held for 120 ms, **175.7 ms** passed
  between the last check and the move. Both the checks and the move now happen
  on the far side of that hop, with nothing in between: **0.004 ms** under the
  identical load. This affects every Trash disposal in the app, not only
  worktrees.
- **And permanent delete now does the same across its own hop.** Permanent
  delete runs on a background queue, so it never waited on the main thread —
  but it waits on that queue, and the check it re-ran on the far side proved
  only which FOLDER it was deleting in, never which checkout stood there,
  whether it had been locked, or whether its HEAD had moved. With the
  background pool held busy, **242.7 ms** passed between the last of those
  three checks and the delete; they now run on the far side of that hop too,
  leaving **0.03 ms**. What still does not cross either hop is the
  cleanliness check: it runs `git`, and starting a program there would be a
  worse trade than the gap it closes. Under a busy queue that gap is
  185.9 ms (Trash) and 241.2 ms (permanent), and work saved into the worktree
  inside it is still destroyed with the tree — re-scan and the item is judged
  afresh.
- **`tool_unavailable` scan errors.** When a scanner cannot run an external
  tool it depends on — today `git` for `git_worktrees` — the scan publishes a
  `tool_unavailable` row in `scanner_errors` and withdraws every item that
  scan had built, instead of reporting an empty result that would be
  indistinguishable from a machine with nothing to clean. Like
  `malformed_outcome` and `config_invalid` it carries no `path`: the problem
  is the toolchain, not a location.
- **Project build artifacts in the GUI and the CLI.** A `build_artifacts`
  per-item scanner walks your configured dev roots for build output PROVEN by
  an ecosystem marker — `target/` beside `Cargo.toml`, `node_modules/` beside
  `package.json`, any directory containing `pyvenv.cfg`, and the rest of the
  rule table in `docs/v1/CATEGORIES.md`. Sizes are allocated and
  sparse-aware, with the apparent size reported separately
  (`logical_bytes`) when it materially exceeds what deletion would free.
  `--cli scan` reports each find as a `scanner_items` row and `--cli clean`
  accepts `build_artifacts` (every find) or `build_artifacts:<item-id>` (one)
  as targets — destructive runs still require `--confirm`. Item ids are
  opaque, stable across rescans, and echoed back exactly as scan printed
  them. No per-item row is ever part of smart-clean or any automatic clean
  path.
- **Release artifacts are protected from build-artifact cleans.** Before
  deleting an artifact directory, Cacheout inspects it for `.dmg`, `.pkg`,
  `.ipa` files and `.app` / `.xcarchive` / `.dSYM` bundles above 5 MB. Any
  hit is disclosed on the scan row, forces the item off "safe" and out of
  default selection, and blocks deletion until it is acknowledged — in the
  GUI by confirming a sheet that lists exactly what is there, in the CLI with
  the repeatable, item-bound
  `--acknowledge-valuables <scanner-slug>:<item-id>:<token>`. The inspection
  runs AGAIN immediately before deletion, so an artifact produced after the
  scan still stops the delete, and any change to the set rotates the token.
  An inspection that could not finish is treated exactly like a change:
  refused, tokenless, re-scan required. Full contract in PROTOCOL.md and
  `docs/v1/CLI-REFERENCE.md`.
- **Ephemeral temp files in the GUI and the CLI.** An `ephemeral_tmp`
  per-item scanner lists STALE first-level entries in the ephemeral
  locations macOS does not reliably prune: `/private/tmp` and the per-user
  temp (`…/T`) and cache (`…/C`) containers, resolved from the OS rather
  than hardcoded. Those three DECLARED locations can resolve to fewer roots:
  one the OS does not name, or that is missing at scan time, is skipped
  silently, and one that turns out to be a symlink NAMING another declared
  root is dropped at resolution with a `symlink_root` issue naming the
  dropped spelling — the ALIAS goes, never the real root, and the drop is
  never silent. Resolution reads such a link but never follows it, so nothing
  a replaced temp root points at is touched while the app is starting up; a
  link spelled so that Cacheout cannot match it to a declared root is kept
  instead of dropped, and the scan then refuses it with the same
  `symlink_root` issue. A MEASURED entry qualifies when its OWN timestamp and its
  newest REGULAR FILE are both older than the age threshold (default 7 days)
  and it meets the size floor (default 10 MB) — a directory holding one fresh
  file deep inside is not stale, so a workspace whose files are still being
  written, including the running session's own scratch directory, is not
  listed. Those thresholds gate the MEASURED entries only: a denied or
  mount-boundary entry is listed as an explicit not-measured row regardless of
  the floor (D6 — an unverified zero must not render as empty). A NESTED DIRECTORY's own timestamp is deliberately not an input
  (the same blind spot the sizer accepts) on either side: the inputs are the
  entry's own mtime and the mtimes of the REGULAR FILES below it. That is a
  claim about the TIMESTAMP and not about the operations that move one — a
  nested change can still trip a gate that is not a timestamp: unlinking a
  file inside a nested directory can take the entry below the SIZE FLOOR, and
  creating enough subdirectories inside one can push its contents past the
  INSPECTION BUDGET, and either of those both keeps the entry off the list
  and refuses it at delete time. An entry a process merely holds open for
  reading is NOT detected: age is the protection, and every gate is
  re-established from a held descriptor immediately before deletion.
  Findings are Review risk, never default-selected, and never part
  of Quick Clean or `smart-clean`. An ordinary entry another user owns is
  skipped — sticky-directory rules make them undeletable, so claiming their
  bytes would be false; the one exception is a mounted volume, whose refusal
  arm runs ahead of the ownership probe by design and reports the row without
  entering it. Anything unreadable is reported instead of silently
  counted as empty. `--cli scan` reports each find as a `scanner_items` row
  and `--cli clean` accepts `ephemeral_tmp` or `ephemeral_tmp:<item-id>`,
  with `--confirm` required as everywhere else. **These locations are
  scanned only on EXPLICIT user-initiated scans** — the app's automatic
  background refreshes never enumerate them, and a CLI scan is always
  user-initiated. Until you run one, the app SAYS SO: the section shows
  "Not yet scanned" instead of a size and a count, so a location nobody has
  looked at never reads as a location with nothing in it. (Any per-item
  scanner in that state says the same; a scanner that HAS run and found
  nothing keeps its section hidden, as before.) That row now appears on a
  machine where the automatic scan found NOTHING, which is where it matters
  most — the results list is built whenever some scanner has yet to run, not
  only when something was found or something went wrong. Previously a clean
  machine went straight to the window's "Click Scan to find caches" screen
  and the row was never built at all.
  Thresholds persist as `cacheout.ephemeralTmp.ageDays` /
  `cacheout.ephemeralTmp.minSizeMB` and take invocation-scoped
  `--tmp-age-days` / `--tmp-min-size-mb` overrides on `scan` and `clean`
  (never persisted; refused on every other command, `smart-clean`
  included). No schema change: `schema_version` stays 4 and every addition
  is additive. **A temp entry is re-inspected immediately before it is
  deleted**, from a descriptor held open for the check, and the check begins
  by proving the object IS the one the scan inspected: the scan records the
  entry's filesystem identity and the re-check compares it, so an entry
  renamed away and replaced under the same name is refused even when the
  replacement is itself old and idle. If the entry has been replaced, its own
  directory has changed, a fresh REGULAR FILE has appeared anywhere inside it,
  it is locked by a running process, it has shrunk below the size threshold
  since the scan, or its contents could not be re-inspected in full within the
  entry budget, the deletion is refused
  with nothing removed and nothing reported freed — re-scan to see its current
  state. Under the world-writable shared root (`/tmp`) an entry that has
  changed owner since the scan is refused too; the per-user containers are not
  owner-checked at delete time, because their `0700` mode leaves no way for
  another user to place an entry there in the first place. Anything that is no
  longer a directory or a regular file at that name is refused outright,
  including a named pipe or socket planted mid-scan — which can no longer stall
  the scan or the clean either. The check runs on both
  disposals, and on the Move-to-Trash default it refuses before the item is
  moved, so a refusal never disturbs your Trash. The proven identity also
  travels INTO each disposal — for directories and for regular files alike —
  so a replacement that lands even after the re-check itself is refused at
  the destructive call: the permanent delete re-proves the object under the
  folder it verified, and the Trash move proves it on both sides of the move.
  (Before this, that late window was covered for directories only: a FILE
  swapped in after the re-check was disposed of with success reported.)
  **How DEEP a temp entry is costs the re-inspection nothing.** It walks by
  descriptor, one level at a time, climbing back with `..` and proving at
  every step that it landed where it left — so its descriptor and stack cost
  are the same at 320 levels as at one. Before this, the walk recursed and
  held one open descriptor and one stack frame per level: measured through
  this path, a valid stale tree 96 levels deep was refused "Too many open
  files … re-scan required" under a 96-descriptor limit (the kind of limit a
  launchd-started app runs with), and one 260 levels deep crashed the
  process outright. The first was worse than it looked — depth does not
  change between scans, so the re-scan that refusal prescribed produced the
  identical refusal, for ever, while the scan kept offering the row.
  A directory MOVED to a different parent while its contents are being
  re-inspected is now refused (nothing deleted, re-scan to see where it
  went) instead of having the rest of its level read out of its new home.
  **Mounted volumes inside temp roots are never entered.** The scan decides
  from the kernel's own mount table before touching the entry at all — so a
  dead network volume can no longer wedge the whole scan at first contact —
  stops its content walk at any mounted boundary it knows of, and shows the
  entry as a visible not-measured row whose message names the remedy: eject
  or unmount the volume, then re-scan. Previously the staleness walk
  descended mounted volumes (measured: 19,545 + 19,500 reads below one
  22,545-entry mount) and whether a mounted entry appeared at all depended
  on the volume's own contents. The delete-time re-check likewise refuses
  to descend onto another filesystem. A volume mounted in the instant
  between the table read and the walk is still read (metadata only) and is
  refused by the sizing and delete-time mount gates that always stood.
  **A volume mounted exactly AT a temp root is refused the same way**: the
  scan answers from the mount table before any syscall touches the root and
  reports it as a visible row that names the condition and the remedy —
  "mounted volume; eject or unmount it, then re-scan" (previously the
  refusal happened only after several syscalls served by the mounted volume
  — a hang on an unresponsive hard mount — and never named the remedy).
  That row is its OWN classification: `scanner_errors[].kind` is
  `"mounted_volume_root"`, an ADDITION to an enumeration the protocol has
  always declared extensible (`schema_version` stays 4). It was
  `"container_refused"` until PR #459 review r11, which made the app's
  visible label — derived from the kind alone — read "not a configured
  search root" for a root that IS configured, with the real explanation
  reachable only by hovering. Consumers keying on `"container_refused"` for
  this case must add the new string; every other producer of
  `"container_refused"` is unchanged. The same table read now guards the scan session's
  container-identity capture and container admission, so a mounted
  registered root no longer has its identity read at session start or its
  path resolved when a healthy sibling root is admitted; a root skipped
  this way stays fail-closed at delete time. A mount landing in the
  instant between the table read and those steps can still be touched.
  **A volume already mounted at a temp root when Cacheout STARTS is now
  refused before the app finishes launching.** Which temp roots exist is
  decided once, while the app builds itself, on the main thread — and that
  step used to `lstat` each declared root, a call the mounted volume itself
  serves, so an unresponsive hard mount could freeze the window before it
  ever appeared. The same kernel mount table is read first now, and such a
  root is not registered at all: nothing under it is scanned and no item can
  claim it. The refusal is a visible row of its own kind,
  `scanner_errors[].kind == "mounted_volume_root_at_registration"`, reading
  "mounted volume at launch; unmount it, then relaunch". It is a separate
  kind from `"mounted_volume_root"` only because the remedy differs: that
  one is re-decided from a fresh table read on every scan, so unmounting and
  re-scanning clears it, while this one is decided once per launch and
  clears only when Cacheout is started again. Another ADDITION to the same
  extensible enumeration (`schema_version` stays 4). Measured with a
  table-injected fixture: calls naming the mounted root across app
  construction went from 5 to 0. Still touched: a volume mounted at a temp
  root's PARENT directory, and a temp root that is a symlink pointing at a
  mounted volume.
  **Two more temp-root refusals get their own classifications** — the same
  defect shape as `"mounted_volume_root"` above, swept in PR #459 codex r13:
  the app's visible row label is derived from the kind alone, so a kind
  shared with a different condition prints a false diagnosis. A temp root
  the search-root safety policy refuses (`/`, a volume root, or `$HOME`) is
  now `scanner_errors[].kind == "policy_refused_root"` and reads "refused by
  the search-root safety policy"; it was `"container_refused"`, whose label
  "not a configured search root" was false for every firing, since a scanner
  builds its guard from its own roots. A temp root replaced by a regular
  file, FIFO, socket or device is now `"non_directory_root"` and reads "not
  a directory — not searched"; it was `"symlink_root"`, whose label
  "symlinked — not searched" sent the user hunting for a link that was not
  there. Both are ADDITIONS to the same extensible enumeration
  (`schema_version` stays 4). Consumers keying on `"container_refused"` or
  `"symlink_root"` for these `ephemeral_tmp` cases must add the new strings;
  a temp root that really IS a symlink still reports `"symlink_root"`, and
  every producer in every other scanner is unchanged.
  **The root listing's entry cap now holds on every path.** When the
  bounded directory read fails, it is retried once (a transiently cleared
  failure recovers through the same capped read), and the Foundation
  fallback that classifies a persistent failure now reads lazily and stops
  at the cap — previously that fallback materialized the entire directory
  whenever the failure cleared between the two reads.
- **Configurable dev roots.** Settings gains a dev-roots editor and the CLI a
  repeatable `--dev-root PATH` (invocation-scoped, never persisted). The
  filesystem root, any volume root or mount point, and `$HOME` itself are
  refused as dev roots in canonical and symlink-alias spellings alike;
  protected children such as `~/Documents` remain legal. A persisted value
  that cannot be parsed falls back to the seeds WITHOUT rewriting the stored
  value and surfaces a `config_invalid` row in `scanner_errors` on every scan
  — the fallback is never silent.
- **Per-item evidence in the confirmation sheet.** Every row of the clean
  confirmation states what the item is and where it lives, and
  command-cleaned categories are named in a disclosure: their bytes are
  erased permanently by the command and never land in the Trash, even in a
  Move-to-Trash run.
- **Per-scanner report rollups.** The cleanup report groups entries into
  per-scanner sections with component-derived sums; per-item failures are
  reported from self-contained error records, so a failed item that no
  longer exists still renders an honest error line.
- **Stable selection across rescans.** Selection is keyed by scanner-scoped
  stable item ids: a rescan preserves both selections and explicit
  deselections. Per-item selection previously reset on every rescan.

### Security

- **The build-artifacts walks are descriptor-anchored: no path resolution
  below a scan root.** The valuables probe and the project-tree walker used
  to re-resolve every child by absolute path — a kind `lstat`, a metadata
  `lstat`, then an open. Any of those could be redirected by a concurrent
  writer replacing an ANCESTOR directory with a symlink, and neither
  `O_NOFOLLOW` (which guards only the last component) nor an inode re-proof
  (whose "vetted" value was itself read through the swapped ancestor) could
  see it. Both walks now open their root once and derive every child from the
  descriptor they already hold — `fstatat`/`openat` by single-component
  basename — so a child's safety is established by containment in a held,
  vetted parent inode. This matters most on the valuables probe, whose output
  feeds the acknowledgement token that authorizes a deletion. Live
  descriptors are bounded (the probe holds at most `clamp((RLIMIT_NOFILE −
  64)/4, 4, 64)` anchors plus two transients; the tree walker holds at most
  its depth budget), and exceeding that bound is never a refusal — anchors
  are released and restored with an identity-verified `..` step, so
  exceeding it can never strand an item the way the retired depth cap did.
  That is a claim about THIS bound — the anchors a walk holds open — and not
  about every depth limit in the product; it has since been read wider than
  it was written, so the scope is now explicit. The project tree walk still
  carries a fixed per-root depth budget, and a directory beyond it is never
  visited at all.
- **The post-walk pass re-proves CONTAINMENT instead of re-resolving a
  path.** Anchoring the walks was not enough on its own: the scanner threw the
  walker's vetted descriptor away and kept a bare URL, then re-resolved that
  absolute path after the whole walk had finished — for the kind gate, the
  sizing, the valuables probe and the delete-time re-probe. A writer inside
  the user's own dev root (a `build.rs`, an npm postinstall) that replaced an
  intermediate directory with a symlink in that window sent all of them
  somewhere else, and because the valuables probe's output is the
  acknowledgement token's only preimage, the result was a valid-looking token
  minted over a tree the artifact directory does not contain. The scan now
  RETAINS each admitted dev root's descriptor and re-reaches every candidate
  by single-component `openat` from it, so the artifact directory is proven
  reachable by containment before one byte of it is read. A component swapped
  for a symlink, a file, or nothing at all is simply not offered (the same
  answer a re-scan gives); anything else — permissions, a mount that appeared
  over the path — becomes a classified, denied, tokenless row rather than a
  silent drop or a silent trust. Cost: one descriptor per configured dev root,
  held for the duration of a scan.
- **Mount boundaries are now discriminated by `f_fsid`.** Every path on an
  APFS volume group reports the same `st_dev` (measured: `/` and
  `/System/Volumes/Data` both report 16777230), so the device comparison was
  blind to exactly the firmlink split it was meant to catch. The descriptor's
  own `f_fsid` is now the primary signal; the previous path-based signals are
  kept as an additional, refusal-only backstop.
- **Resolved consequence.** The probe was made free of `PATH_MAX` — it can
  inspect and certify a tree whose absolute paths exceed the limit — before
  the deleter was, and while that gap existed the build-artifacts scanner
  refused such trees outright so it could not offer a row that only
  half-deleted. Both deletion routes now handle them (see "Build folders
  nested deeper than the system path limit" under Fixed), and that refusal is
  retired.
- **Known residual.** `DirectorySizer` is still a path-based
  `FileManager.enumerator` walk, so an ancestor swap landing after the
  containment descent above can still redirect the SIZING of a build-artifact
  item. What that yields is bytes, dates and denial classifications — figures
  an item displays. It cannot mint an acknowledgement token (that comes solely
  from the descriptor-anchored valuables probe), cannot authorize a deletion,
  and cannot move the deletion target, which stays the unresolved spelling the
  cleaner re-admits and the revalidator re-proves. Converting the sizer is
  tracked separately.
- **Known residual: content created in a folder Cacheout has already looked
  inside can still be swept.** Every safety check that binds an OBJECT —
  the held directory handles, the `..` re-anchors, the final identity
  re-check — answers "is this the same folder?", and when an app ADDS
  something (a `Documents` folder, say) to a folder that was already read,
  the answer is correctly YES: nothing was renamed, nothing was replaced,
  the folder has the same identity it always had. Identity says which object;
  it says nothing about what is now inside it. So the inspection reports no
  user data and no obstruction, and the entry can be moved to the Trash or
  deleted permanently even though the new content was never looked at.
  Retiring the depth cap WIDENED this: folders past the old limit used to
  come back "couldn't finish inspecting" and were therefore never cleanable
  automatically; they now come back clean, which is the point of the fix and
  is also what exposes them. It needs a writer into `~/Library/Caches` whose
  write lands between the pre-delete inspection reading that folder and the
  deletion itself, on an entry already eligible for automatic cleaning. The
  window is measured, not assumed: the tail from inspection to deletion is
  ~0.5 ms and does not grow, but the folder read FIRST stays exposed for the
  rest of the walk — ~23 µs per entry inspected, so ~20 ms on an 840-entry
  tree and ~0.46 s projected on a 20,000-entry one. What limits the damage
  today is that the app's default is Move to Trash, which destroys nothing
  and is undone with one drag; a permanent delete has no such consolation.
  Closing it properly means checking for user data DURING the removal — the
  deletion already walks the tree by open handle and is the only step in a
  position to refuse what it is about to unlink — and that is tracked
  separately.

### Changed

- **BREAKING: CLI JSON `schema_version` bumps 3 → 4.** `--cli scan` output
  is now an envelope `{schema_version, categories, scanner_items,
  scanner_errors}`; the `categories` rows are field-for-field identical to
  schema 3. Clean and smart-clean rows gain `scanner_id`/`item_id` identity
  fields, and for per-item rows the retained `category`/`slug` key carries
  the composite address `<scanner_id>:<item_id>` (directly reusable as a
  clean target). Every payload — scan, clean, smart-clean, and both
  dry-runs — self-describes with a top-level `schema_version`.
- **Unified scanner architecture (internal).** The category registry and
  every per-item scanner now sit behind one `SpaceScanner` protocol with
  a validated registry runtime: scan outcomes are ownership- and
  structure-validated fail-closed before any surface can address them, and
  delete-time container admission derives from scanner registration, never
  from scanned items. Category content and behavior are unchanged. An item
  may additionally declare that it MUST be re-inspected immediately before
  deletion; a cleaner that cannot perform that re-inspection refuses it
  rather than deleting it.
- **Category-count claims removed from docs.** README and docs/v1 no longer
  state a hardcoded number of cache categories — prose counts rot; the
  registry in `Sources/Cacheout/Scanner/Categories.swift` is the source of
  truth.
- **PRE-RELEASE RENAME: the `node_modules` scanner slug is now
  `build_artifacts`.** The `node_modules` per-item scanner landed in this same
  unreleased schema-4 work and never shipped in a release (the last release is
  v2.1.9), so this is a rename with NO alias and no compatibility shim: the
  `build_artifacts` rule table's `node_modules/` row finds everything the old
  scanner found, and registering both would double-list the same directories.
  `--cli clean node_modules` is now an unknown target (`INVALID_ARGUMENTS`),
  no `scanner_items` row carries `scanner_id: "node_modules"`, and the scanner
  plus its GUI-only item model have been deleted. Persisted node_modules
  selections do not survive the rename — selection is session-scoped anyway.
  The `cacheout-mcp` consumer was updated in the same change window (branch
  `fn-1.3-memory-stats-mcp-tool`, commit `c4efd9b`). Its slug sites are
  verifiable with the SOURCE-ONLY semantic gate, which returns zero matches:

  ```
  grep -rnI --exclude-dir=__pycache__ \
    -E '"node_modules"|`node_modules`|node_modules:' src tests
  ```

  The pattern targets slug SITES only — `scanner_id` values, address
  prefixes, backtick slug mentions — so artifact-NAME references that
  legitimately persist under `build_artifacts` do not match and zero is
  reachable. `-I` and `--exclude-dir` keep it scoped to source: a stale or
  freshly written `__pycache__/*.pyc` would otherwise let the gate report on
  build artifacts instead of on the code.
- **BREAKING for MCP callers: NO client-side timeout on a confirmed
  `git_worktrees` clean.** PROTOCOL.md's blanket 30-second subprocess timeout
  now carries one exception, documented in full under "Subprocess Timeout".
  Cleaning a worktree removes a tree that may be gigabytes, so ANY finite
  client-side guess can kill a valid clean mid-removal and leave Cacheout in
  partial state. (This entry originally said "runs `git worktree remove` … with
  an unbounded guarded fallback behind it"; a later entry in this same
  release replaced that architecture entirely. The rule is unchanged — what
  is unbounded is the TREE.) Callers apply NO timeout when
  a clean target token equals `git_worktrees`, starts with `git_worktrees:`,
  or names an item whose preflight `scan` row carries
  `"action": "git_worktree_reclaim"` — and, conservatively, when the target
  is scanner-ambiguous (over-waiting is safe; a premature kill is not).
  Everything else keeps 30 seconds. The CLI bounds itself: 300 s per git
  invocation at delete time plus its own SIGTERM → SIGKILL escalation. If the
  CLI is killed from outside anyway, an orphaned git child and a partially
  removed tree are possible — the next scan recovers both (a partial tree
  reads dirty or unassessable and is never a candidate; an orphaned admin
  directory is offered by the prune tier).

  **RELEASE-BLOCKING cross-repo gate.**
  Status: **SATISFIED at 0b50b62** — cacheout-mcp adopted the rule.

  **To close (ONE edit, one meaning):** run the verification below, then
  replace that status line's `**NOT SATISFIED**` with
  `**SATISFIED at <commit-hash>**` (7-40 hex characters — a commit anyone can
  check out). Nothing else needs editing: the release script keys on the
  `Status:` LINE alone, so this paragraph — and any future entry quoting the
  phrase — never blocks a build. Those two spellings are the ONLY admissible
  statuses: a deleted, duplicated, renamed or hash-less status line is an
  unverifiable gate and blocks exactly like an open one.

  **Deferred to the release path, deliberately — and ENFORCED there.**
  Merging this work with the gate open is intentional: the scanner ships to
  users only at release, and `[Unreleased]` is exactly where an unshipped
  precondition belongs. It is not left to memory —
  `scripts/bundle.sh` runs `check_release_gates` FIRST in EVERY
  distribution-producing mode (`--release`/`--notarize` and `--direct`, which
  also produces a signed DMG), before it builds, signs, packages or
  notarizes anything. A missing or unreadable CHANGELOG aborts too: an
  unverifiable gate is never a passed one. The default no-flag mode builds an
  unsigned .app for local testing and ships nothing, so it is not gated.

  - **Consumer:** `cacheout-mcp` (org `acebytes`), branch
    `fn-1.3-memory-stats-mcp-tool`, PR #1.
  - **Baseline verified at `63edbfc`:** `AppEngine._run`
    (`src/cacheout_mcp/engine.py:465`) wraps EVERY CLI invocation in
    `asyncio.wait_for(proc.communicate(), timeout=120)` (line 475) and raises
    at line 480. A confirmed `git_worktrees` clean therefore gets SIGKILLed
    at 120 s today — mid-removal on any tree that takes longer.
  - **Required change:** derive the timeout per invocation and pass `None`
    when the D18 trigger fires (target token `git_worktrees`, a
    `git_worktrees:` prefix, a preflight row whose `action` is
    `git_worktree_reclaim`, or a scanner-ambiguous target); every other
    command keeps its existing bound.
  - **Owner:** the fn-5.6 implementer, at release time.
  - **Verification**, both parts source-scoped (`-I` and
    `--exclude-dir=__pycache__` keep a stale `.pyc` from deciding the
    verdict), run in the `cacheout-mcp` checkout:

  ```
  # (1) the trigger rule is implemented AND tested — must be NON-ZERO:
  grep -rnI --exclude-dir=__pycache__ -E '"git_worktrees"|git_worktrees:' src tests

  # (2) the blanket CLI timeout is gone — must be ZERO:
  grep -rnI --exclude-dir=__pycache__ -E 'proc\.communicate\(\), timeout=120' src
  ```

  Zero in (2) is reachable and stable: the runner must DERIVE its timeout per
  invocation (`None` for composite-capable cleans) instead of hardcoding one
  for every command. The adopting commit hash going into the status line is
  what closes this gate — and what lets any distribution build run.

### Fixed

- **Every scan-issue row now states a condition that is true for the
  producer that emitted it** (fn-4.12 — the PR #459 codex r13 sweep, run
  over every OTHER scanner's producers; the app's visible row label is
  derived from `scanner_errors[].kind` alone, so a kind shared with a
  different condition prints a false diagnosis). All ADDITIONS to the same
  extensible enumeration (`schema_version` stays 4); no wire STRING is
  renamed, but the kind a given condition reports under moves, so consumers
  keying kinds to conditions must re-key: **(1)** a configured dev root
  refused by the search-root safety policy — persisted, or via `--dev-root`
  — is now `"policy_refused_root"` ("refused by the search-root safety
  policy"); it was `"container_refused"`, whose label "not a configured
  search root" contradicted the row's own detail ("configured dev root
  refused: …"). **(2)** a configured dev root with a volume mounted exactly
  at it is now `"mounted_volume_root"`, whose label names the one remedy a
  re-scan honors (the walk re-reads the kernel mount table every scan).
  **(3)** a dev root or `~/Library/Caches` sweep root standing as a regular
  file, FIFO, socket or device is now `"non_directory_root"`; it was
  `"symlink_root"`, which sent the user hunting for a link that was not
  there — `"symlink_root"` now means a symlink and nothing else, in every
  scanner. **(4)** a git worktree or repository admin directory withheld
  because git's cleanup would modify paths not all inside ONE configured
  dev root is the NEW `"mutation_scope_refused"` ("git cleanup is not
  contained in one dev root — not offered"); it was `"container_refused"`
  while the worktree in question IS inside a configured root. A worktree
  outside EVERY configured root keeps `"container_refused"` — there the
  label is exactly the condition. **(5)** a BARE-errno EPERM (raw
  `lstat`/`open` probes) is now neutral `"unreadable"` everywhere, with the
  detail saying the cause could not be established; it was `"tcc_denied"`
  in the dev-root walk and the orphaned-caches sweep — printing the "Grant
  access…" (Full Disk Access) remedy on a guess — while the temp scanner
  already classified the same errno as unknowable (a bare errno carries no
  provenance; TCC, SIP and other filesystem refusals are indistinguishable
  in it). A chain-proven EPERM — recovered from a Cocoa error's
  `NSUnderlyingErrorKey` chain — still reports `"tcc_denied"` with the
  grant hint, which is the one place the claim is establishable. The two
  scanners that disagreed on bare EPERM now share one recorded rule
  (`DirectorySizer.denial(forFailedProbe:)`).
- **A scan could hang before it started, with the spinner up and no way to
  stop it.** The first thing a scan does after marking itself in progress is
  refresh the free-space figures in the header. That refresh was unbounded:
  it ran on a background worker, and if no worker was free — or the boot
  volume was slow to answer — the scan sat there. Every protection Cacheout
  has for a scan that will not finish is armed by the NEXT step, so none of
  them applied: no timeout fired, no "scan did not finish" row appeared, the
  spinner stayed up, a second scan was refused as already running, and the
  app looked healthy while nothing was happening. Reproduced with the
  background workers held busy: the scan returned after 2.6 s with no problem
  reported, while a complete scan under its own timeout took 0.007 s in the
  same run. The refresh now gives up after two seconds and the scan carries
  on immediately, keeping whatever free-space figures it already had (before
  the first successful reading, the usage bar simply stays hidden, exactly as
  it does when the volume cannot be read at all). Nothing is remembered about
  the failure — the next scan reads the figures again from scratch, and a
  busy moment or a briefly unresponsive volume clears itself. The identical
  refresh after "Prune Docker" is bounded the same way, so a slow volume can
  no longer leave that button disabled.
- **"Move to Trash" could take a file that was never yours, and report your
  folder's bytes as freed.** Before deleting anything Cacheout re-inspects the
  item, and for one kind of answer — "there is no folder of ours at this name
  any more", which is what it records when the thing at the path turns out to
  be a plain file — the Trash disposal checked only that SOMETHING that is not
  a folder answered to that name. It never checked WHICH FOLDER it was looking
  in. So if the cache folder itself was replaced between the safety check and
  the disposal — by a program, an installer, or a synced folder arriving — the
  file that landed at the same name inside a stranger's folder was moved to
  your Trash, and the report said the item had been cleaned and counted its
  bytes as freed. Permanent delete refused the identical event, and said so.
  The Trash disposal now holds the folder it was given, proves it is the same
  folder the safety check admitted, and reads the item INSIDE it — before the
  move and again at the last instant before it — so a swapped folder is
  refused with nothing moved, and a swap that lands inside the Trash system's
  own resolution is caught afterwards and reported honestly: the item is
  refused, nothing is counted as freed, and the message names where the
  wrongly-taken file is so you can put it back in one drag. A folder that
  appeared at that name since the check is refused too, which is what the
  answer meant in the first place.
- **A refusal about your FOLDER no longer reads as a refusal about your item.**
  When Cacheout stops because the folder holding an item was replaced, the
  cleanup log says `container-drift`; when it stops because the item itself
  changed, it says `content-drift`. Two Trash-side refusals about the folder
  were being written down as the item having changed, which sends you to look
  at the wrong thing. They now say what they mean.
- **Cleaning up abandoned git-worktree records no longer counts space
  something else freed.** When Cacheout removes the leftover bookkeeping
  folders of git worktrees you have deleted, it re-checks the list immediately
  before acting, and that list is allowed to SHRINK — an entry that was
  locked, repaired or removed by something else in the meantime is dropped.
  The freed-space total was then computed over the ORIGINAL list, counting any
  entry that was simply no longer there. So a folder another program removed
  while Cacheout was working was billed to Cacheout: measured on a test
  fixture, 450,560 bytes reported where 24,576 were actually this operation's.
  The total now follows the entries Cacheout itself removed.
- **A scan can no longer hang the app forever.** The window showed each
  scanner's progress and stopped when they all reported — and if one of them
  never reported, nothing ever ended it: the spinner ran until the app was
  quit, and while it ran no second scan and no cleanup could start. A scan
  session now runs under a time limit. When it expires, every scanner that has
  not reported is listed with "did not finish in time — nothing from it was
  used; re-scan to try again", nothing that scanner might have found is
  published, whatever it showed before is kept but cannot be cleaned, and
  every scanner that DID finish keeps its results — a partial scan is
  reported as partial, never as complete and never as empty. The limit is far
  above any real scan, and re-scanning genuinely can succeed: it is a limit on
  elapsed time, so a warmer cache, an answered privacy prompt or an unmounted
  volume changes the outcome. `scan --format json` reports it as a
  `scan_did_not_finish` row in `scanner_errors`.
- **"Move to Trash" no longer tells you your folder could not be put back
  while it is sitting in the Trash.** Move to Trash is the shipped default,
  and after moving an item Cacheout re-identifies it where the Trash said it
  put it — the check that catches a folder swapped out from under the
  disposal. That check opened `~/.Trash` itself, and macOS refuses that to
  every app without Full Disk Access, so on an ordinary Mac it could never be
  taken: every trashed item was reported as a refusal with nothing freed, and
  the message said what the Trash took "could not be put back — it is no
  longer at `~/.Trash/<name>`, where the Trash reported putting it" — about a
  folder that was at exactly that path, intact, one drag from recovery. When
  — and ONLY when — macOS answers that open with a permission denial, the
  check now identifies the item the way the permission actually allows, so a
  real disposal is reported as one and a swapped folder is still caught and
  refused. Any OTHER reason the folder cannot be opened is still a refusal:
  in particular a landing folder that turns out to be a symbolic link is
  refused rather than followed, because following it would identify the
  object on the other side of the link and report a move that never
  happened. When such a refusal happens without Full Disk Access the item
  cannot be moved back automatically, and the message now says where it is
  instead of denying it is there. **The same symbolic-link rule now covers
  every kind of item.** Folders whose contents were checked before the move
  were re-identified by their full path instead, which followed a symbolic
  link standing in for the Trash folder just the same — and because such a
  link can be aimed back at the item's own folder, the check could find the
  original item exactly where it started, agree that it was the right one,
  and report the folder as freed when nothing had moved at all. That path is
  now read the same way as the others, so the link is refused rather than
  followed and no disposal can report a move that did not happen.
- **And it no longer abandons a FILE in your Trash while denying it is
  there.** The same message had a second way of being wrong, on the same
  shipped default. When the folder Cacheout was about to trash was swapped
  for a plain file in the instant between the last check and the Trash's own
  move — the window that check exists to catch — the Trash took the file, and
  the undo that should have put it back refused to name it: the identification
  step recognised folders and nothing else, so a file, a symbolic link or a
  pipe sitting in your Trash came back as "nothing found". You were told the
  item "is no longer at `~/.Trash/<name>`, where the Trash reported putting
  it, so nothing was moved" while it was at exactly that path and the
  original name was left empty. The undo now identifies every kind of object,
  so what the Trash took is put back where it came from and the refusal says
  so. When the put-back cannot be performed — the Trash or the destination
  folder cannot be opened — the message gives you the path in the Trash to
  drag it back from, rather than claiming it is not there. **Without Full
  Disk Access that second case is not the exception, it is what happens every
  time**; see the Full Disk Access note two entries below.
- **One disposal path refused to work under a symlinked folder while the
  other four worked.** Cacheout deliberately follows symlinks when it opens
  the folder that HOLDS the item it is about to remove — a cache root reached
  through a link is a real folder, and refusing it would refuse every deletion
  under it. Permanent delete does that, and so do three of the four Move to
  Trash paths. The fourth — the one used when the item's own folder was
  checked before the move — re-opened that holding folder a second time, by
  path, refusing to follow: on a fixture where the item's immediate folder is
  a symbolic link, the other four removed or trashed the item and this one
  refused with "Not a directory" about a directory that plainly is one. It now
  reads the item under the same followed, identity-checked folder the other
  paths use, so all five agree. No scanner Cacheout ships could reach the
  refusal (the items with this kind of check are always direct children of a
  root that is itself checked), so nothing you could clean was affected. The
  Trash side of the same check still refuses to follow a link, because the
  folder the Trash reports is not one anybody proved.
- **And the UNDO under such a folder no longer strands your item in the
  Trash.** Fixing the check above only fixed the way IN. When a Move to Trash
  is undone — Cacheout puts the item straight back if it cannot prove the
  Trash took the right thing — the folder it restores INTO was still opened
  the refusing way. So under a folder reached through a symbolic link, all
  four Move to Trash paths moved the item to the Trash and then could not put
  it back: the put-back was never attempted, your item was left in the Trash
  and the original name was left empty. Under an ordinary folder the identical
  event put the item back every time. That made the fix above strictly worse
  than the refusal it replaced, on that one path — before it, the item was
  refused before the move and your Trash was never touched. The undo now opens
  and identity-checks that folder exactly the way every other removal in the
  app does, so it puts the item back under either spelling; and the refusal
  that says "the folder that holds this item is not the one that was
  admitted", which such a folder could never reach before, is now reached and
  reported. **Both of those need Full Disk Access, and neither sentence
  above said so.** Putting an item back means opening the Trash folder, and macOS
  refuses that to any app without Full Disk Access — which Cacheout does not
  ask for and does not have by default. So for an item on your STARTUP VOLUME
  the undo stops one step earlier than either sentence above describes, under
  EITHER spelling: nothing is put back, the item stays in the Trash, and the
  message is the one that gives you its path so you can drag it back in one
  move. Measured through the shipped Trash seam into the real Trash, on all
  four Move to Trash paths, eight runs out of eight. What is fixed for
  everyone is that the move itself still succeeds and the message names where
  the item is; what is fixed only once you grant Full Disk Access is the
  automatic put-back and the "folder that holds this item" refusal.
  **And that is a fact about the STARTUP VOLUME, not about Cacheout: the
  paragraph above once said it of every item, and for items on any other
  disk it is false.** macOS gives each mounted volume its own Trash, and only
  the one in your home folder is protected. An item cleaned from an external
  drive, a disk image or any other mounted volume goes to that volume's own
  Trash, which any app may open — so on those volumes the automatic put-back
  and the "folder that holds this item" refusal both work with no Full Disk
  Access at all. Measured on a temporary disk image, all four Move to Trash
  paths, eight runs out of eight, with the home Trash still refused in the
  same process.
- **A folder that is simply GONE is no longer reported as one somebody
  replaced.** If an item vanishes between the safety check and the deletion —
  an ordinary race with an installer, an uninstaller or a synced folder —
  permanent delete and three of the four Move to Trash paths say "No such file
  or directory". The fourth said "the folder at this path is no longer the one
  that was inspected — it was replaced between the safety check and the
  deletion", and the cleanup log recorded it as the item having changed.
  Nothing had been replaced: the name was empty. All five now report the
  absence as an absence.
- **Refusal messages no longer tell you your folder was replaced when nothing
  looked at it.** Five of the six Move to Trash refusals opened by asserting
  that the folder at the item's path was no longer the one that was inspected.
  Nothing in the disposal re-reads that path: what it checks after the move is
  what the Trash actually took. On a disposal that moved NOTHING and reported
  a Trash location where nothing stands, the item was still on disk,
  untouched — and you were told it had been replaced AND to go and look in the
  Trash for it. The five now open with what was actually established: the
  disposal could not be proved to have moved the item that was inspected. Each
  one's remaining clauses are unchanged except where they were also stronger
  than the evidence: the message no longer says the item "is no longer at" the
  Trash path it names, only that it cannot be found there now.
- **And two refusals no longer tell you where an item is when nothing
  established it.** The entry above fixed the OPENING of five messages and
  left the ends of two of them saying things no check on those paths
  performs. The first is the same event the entry above describes — the
  disposal moved nothing and your folder never left — and after being told
  correctly that the move could not be proved, you were still told to "look
  in the Trash for it", for an item sitting untouched exactly where it
  started. The second happens when the undo puts something back and the
  object it moved turns out not to be the one the Trash took: you were told
  "the item the Trash took is still in the Trash". Nothing shows that. All
  that was established is that the NAME in the Trash was re-used by something
  else while the undo was running; the item itself may have been moved
  anywhere, and was measured being moved out of the Trash entirely. Both
  messages now say plainly that where the item is was not established, and
  both still name every path they do know. The check that keeps false claims
  out of these messages used to read only their first sentence; it now reads
  the whole message.
- **And the last refusal that claimed something about your disk no longer
  does.** One of the six — the one you see when Cacheout takes something back
  out of the Trash because it could not prove the Trash took the right thing
  — ended "nothing was freed". The other five say "nothing was REPORTED
  freed", which is what Cacheout actually knows: it wrote no entry and
  counted no bytes. Whether anything on the disk was freed is not something
  that check looks at, and on the very event that produces this message
  something else HAD been moved. It now says "nothing was reported freed",
  like its five siblings. The check behind all six changed shape too: it used
  to be a list of sentences that had been caught being wrong, so a NEW way of
  saying the same wrong thing passed it. Each message is now assembled from
  clauses that each name the one thing they claim, and every clause is
  checked against what that refusal's own code path proved.
- **THE ENTRY ABOVE ENDED WITH A CLAIM THAT WAS MEASURED FALSE, and the
  sixth refusal was still sending you to the Trash for an item that never
  left.** That entry used to end "so a false sentence nobody has thought of
  yet fails as well". It does not: eight new false wordings were written
  against that check and all eight passed it, five of them saying the very
  thing the two entries above had just been spent retiring. The check read
  each clause's WORDS — does this name a place, does it claim bytes, is it
  hedged — and every such test is a password rather than a property. The
  messages are no longer WRITTEN at all: each refusal now states exactly the
  set of things its own code path established, one fixed sentence per thing,
  chosen from a closed list, with the next step chosen from a closed list of
  two. A sentence asserting something the check did not establish has nowhere
  to be written, rather than being caught after the fact. What that still
  cannot catch is stated in the code and is worth saying here: someone can
  word one of those fixed sentences to say more than the thing it stands
  for.
- **And the sixth refusal — "the Trash did not report where it put the item"
  — no longer tells you to check your Trash.** It ended "Check the Trash, and
  use permanent delete…", and the check positively endorsed that, on the
  reasoning that a Trash disposal which returns without an error must have
  put the item in the Trash. Measured on all four disposal paths: a disposal
  that moves NOTHING and reports no location produces exactly this refusal,
  and the item is still where it started, same folder, same inode. That was
  the only thing any of these messages claimed on the strength of what a
  component is supposed to do rather than something Cacheout read, and it is
  the same mistake an earlier entry above fixed for a different refusal. The
  message now says what this path does know: no location was reported,
  nothing was reported freed, where the item is now was NOT established, and
  permanent delete is the disposal that does not depend on the Trash naming
  anything.
- **A refusal that leaves your item in the Trash now warns you the put-back
  can collide.** "Move it back from there" is what Cacheout says when it
  could not restore the item itself. One of the three ways that refusal
  arises is the restore failing because something ALREADY occupies the item's
  old name — so the manual move you were told to make walks into the same
  obstacle. The message now says to move whatever is there aside first.
- **A background refresh no longer reads the folders it has already decided
  to skip.** The ephemeral-temp scanner runs only when you ask for a scan, but
  before each scan Cacheout records the identity of every folder it might
  later delete from — and it did that for EVERY registered scanner, including
  ones the refresh had just excluded. So an automatic refresh still made
  filesystem contact with `/private/tmp` and both per-user temp containers,
  where a stalled network or disk-image mount can park the call. It now
  records only the folders belonging to the scanners that session actually
  runs, which also means a scan narrowed to one scanner touches nothing
  outside it. Nothing you can clean is affected: a scanner that did not run in
  the latest scan already could not be cleaned until it runs again.
- **A temp folder stuffed with directories can no longer make a scan crawl.**
  The ephemeral-temp scanner advertised two limits — at most 20,000
  first-level entries per temp folder, and at most 20,000 entries of
  staleness checking per entry — but the second was handed out afresh to
  every entry, so the two multiplied to 400 million filesystem probes for one
  temp folder. `/private/tmp` is writable by anyone on the machine, so any
  local program could stage that. Each temp folder now has ONE staleness
  allowance its entries share; when it runs out the folder says so on the
  results row ("too many entries — partially inspected"), and clearing
  entries — including cleaning the items listed there — lets a later scan get
  further. Cancelling a scan is also honoured while an entry is being
  checked, instead of only between entries.
- **Deleting a folder nested deeper than the system path limit now works.**
  Inspection had been made descriptor-relative and could read such trees;
  permanent deletion still went through `FileManager.removeItem`, which
  builds an absolute path per entry and cannot. The result was a cache
  folder reported as inspected and clean that no route in the app could ever
  remove: it failed instantly, every time, with "the file name is invalid" —
  a message naming a cause that did not exist, since the names were fine and
  the DEPTH was the problem. `rm -rf` removed the identical folder in under a
  second, so the refusal was the app's own. Permanent deletion now traverses
  by open directory handle the same way, with the same no-follow and
  mount-boundary rules as the inspection, and a constant number of open
  handles at any depth. Moving to the Trash was never affected (it is a
  rename). REMAINING, and now said honestly instead of being blamed on a
  file name: the SIZE of such a folder still cannot be measured, so it is
  listed at review risk with "couldn't measure its size: part of it sits
  deeper than an absolute path can address — deleting it still works", and
  the bytes it frees are under-reported.
- **Build folders nested deeper than the system path limit are listed again.**
  They were withheld on purpose: while permanent deletion went through
  `FileManager.removeItem`, such a folder could only ever be HALF deleted —
  the removal unlinked what it reached and then failed (measured: 202 → 181
  entries, and "0 bytes freed" reported to you) — so offering the row would
  have offered something no route could finish. Deletion no longer works that
  way. The permanent route traverses by open directory handle, and Move to
  Trash — the default — is a rename of the top folder, measured on a real
  over-limit tree: every entry arrived, nothing was left behind, nothing was
  half-moved. Both routes remove it whole, so the row is offered again. What
  is left is a MEASUREMENT limit, not a deletion one, and it is all the row
  now claims: the size shown is a FLOOR, the row is listed at review risk and
  never selected automatically, and it says so — "SIZE IS A FLOOR … deleting
  it still removes it whole; shorten or move the tree … to see its full
  size". Shorten the tree and it becomes an ordinary fully measured row.
- **Orphaned-caches delete: a folder replaced after it was inspected is no
  longer deleted.** The pre-delete safety inspection holds the folder open,
  which is what stops it following a swap — and also what pins it to the
  folder it opened. If that folder was renamed away and a NEW one created
  under the same name, the inspection reported "clean" about the folder it
  held while the deletion, which works by path, removed the replacement.
  Every other check in the path (container admission, containment, deny
  list, mount boundary) is satisfied by the replacement. The inspection now
  re-checks its own root before accepting a result, and reports WHICH object
  its verdict is about so the deletion refuses unless that object is still
  the one at the path. Refusals are clearable by re-scanning.
- **Orphaned-caches "Move to Trash": the same replaced folder is no longer
  trashed either.** Move to Trash is ON by default, and it did not go
  through the deletion that was hardened above — it handed the folder's path
  to the system Trash, behind nothing but a check that a swap timed one
  syscall earlier defeats. A folder replaced in that instant was moved to
  the Trash whole, and the app reported success with the byte count of the
  folder it had actually inspected. The system Trash takes a path and
  resolves it itself, so the check cannot be handed the open folder the way
  the permanent deletion now can; what makes this safe instead is that
  moving to the Trash destroys nothing. The app now checks the folder it
  holds open before the move, checks WHAT THE TRASH ACTUALLY TOOK
  afterwards, and PUTS BACK anything that turns out not to be the inspected
  folder — reporting zero bytes freed either way. REMAINING: if the put-back
  cannot be performed because something else has taken the original name,
  the item stays in the Trash and the error names its path so it can be
  restored in one drag; and a Trash that will not say where it put an item
  is refused rather than counted, leaving that item in the Trash too.
- **Deletes now check the FOLDER THAT HOLDS the item, not only the item.**
  Every check above the deletion is about the item itself or about the
  container root you configured; the folder in between — `proj` in
  `~/Projects/proj/node_modules`, or the cache folder a category's contents
  are cleaned out of — was checked by nothing. Deletion runs on a background
  queue and the folder's path is resolved on the far side of that hop, so a
  folder renamed away and replaced in that window (an app reinstalling its
  cache directory does exactly this) sent the whole deletion into the
  replacement: a same-named folder inside it was deleted and the app reported
  success with the replacement's byte count. Cacheout now reads the holding
  folder's identity from an open handle BEFORE handing the deletion a path,
  and the deletion refuses unless the folder it opens is that same one —
  "the folder that holds this item is no longer the one the safety check
  admitted", clearable by re-scanning. This covers permanent deletes, category
  contents cleans, and — see the next entry — Move to Trash. REMAINING: a swap
  that happens BEFORE that reading is invisible, because both sides then see
  the replacement and agree about it.
- **"Move to Trash" now gets that same folder check — including for the items
  that have no content check of their own.** Move to Trash is ON by default, so
  it is the disposal most deletions use, and the folder check above landed on
  permanent deletes only. Two paths still handed the system Trash a bare path:
  EVERY category contents clean (those run no content inspection at all), and
  every item from a scanner that does not offer one. For those, a folder
  renamed away and replaced in that window sent the disposal into the
  replacement — a same-named folder inside it went to the Trash, and the app
  reported success with the byte count of the folder it had actually measured.
  Cacheout now checks the holding folder from an open handle and identifies the
  item under it immediately before the disposal, then checks what the Trash
  actually took afterwards; anything it cannot prove is PUT BACK and reported
  as a refusal, with nothing counted as freed. If the put-back cannot be
  performed the item stays in the Trash and the error names its path, so it is
  recoverable in one drag. The stale-worktree removal added in this same
  release — the disposal the GUI performs on a worktree — goes through the
  identical check, so no Trash disposal in the app is handed a bare path.
  (Originally written as "the stale-worktree fallback … when git refuses to
  remove a worktree"; a later entry in this release made that removal the only
  arm there is, reached unconditionally rather than on a refusal.)
- **"Move to Trash" undo: a put-back will not restore into a folder it cannot
  prove.** When the Trash turns out to have taken the wrong folder, Cacheout
  puts it back. That undo held its destination folder open but never checked
  WHICH folder it was, and the check it ran afterwards went through the same
  unchecked handle — so it confirmed itself. A folder swap in that window
  moved your tree out of the Trash and into a stranger's folder while the app
  reported the item had been PUT BACK. The destination is now checked against
  the identity taken before the disposal, and when it disagrees nothing is
  moved at all: the item stays in the Trash, and the error names both the
  Trash path it is at and the fact that the destination folder changed.
- **Orphaned-caches probe: deep folders no longer burn CPU quadratically.**
  The walk re-scanned its whole open-folder stack on every level it
  descended, so a deeply nested cache close to the inspection budget could
  stall for a long time even though the number of entries inspected was
  capped. The accounting is now incremental and bounded by the number of
  folders held open, never by depth.
- **Orphaned-caches probe: ancestor-swap disclosure.** The bounded
  user-data probe resolved each child by absolute path, so a directory
  replaced by a symlink after its parent had been read (but before the
  child was vetted) redirected the walk outside `~/Library/Caches` — up to
  the full 20,000-entry budget — and attributed what it found there to the
  cache entry. `O_NOFOLLOW` guards only the final component, and the
  identity re-proof could not help because the identity it compared was
  already the foreign object's. The probe now holds each parent open and
  discovers, stats and descends every child relative to that descriptor by
  single-component basename, at a bounded number of live descriptors. Two
  side effects are user-visible: trees whose absolute paths exceed
  `PATH_MAX` are now inspected instead of being refused forever, and mount
  boundaries are detected by filesystem id rather than by path spelling, so
  an aliased path can no longer hide one.


## [2.2.0] - 2026-08-06

Disk-path safety hardening (D1–D8). Breaking CLI release: `schema_version` is
now 3 and destructive commands require `--confirm`. Coordinate MCP updates with
`cacheout-mcp` (see PROTOCOL.md and docs/v1/CLI-REFERENCE.md).

### Changed

- **BREAKING: `--cli clean` and `--cli smart-clean` require `--confirm`.** An
  unconfirmed, non-dry-run invocation deletes nothing: stdout is empty, the exit
  code is 1, and stderr carries a `CONFIRMATION_REQUIRED` error whose
  `details.plan` lists the same per-category decisions the confirmed run would
  take (`clean`, `clean_with_warning`, `refuse`, `skip`, and — smart-clean only —
  `clean_if_needed` for eligible fallback candidates past the projected
  target-met point). Preview with `--dry-run` (non-destructive,
  schema-compatible stdout, no `--confirm` needed). `schema_version` bumps
  2 → 3; there is no environment-variable bypass.
- **BREAKING: clean totals are split by certainty.** `total_freed_bytes` now
  sums exact bytes only (unique-inode bytes whose deletion verifiably freed
  them); the additive `total_estimated_up_to_bytes` carries hardlinked and
  command-freed bytes that MAY be freed. Per-entry `exact_bytes` /
  `estimated_up_to_bytes` components replace the single mixed number, and
  `results[].category` now carries the slug (v2 emitted the display name).
- **Exit-code policy (schema 3).** A clean where every item failed exits 1 with
  `CLEAN_FAILED`; a partial clean stays exit 0 and reports per-item `success`
  flags. Running destructive commands as root is refused outright
  (`ROOT_REFUSED`).
- **`smart-clean` validates its target strictly.** An absent target still
  defaults to 5 GB, but a *present* target that is non-numeric, non-finite,
  non-positive, over 10^9, or too small to convert to a whole byte is an
  `INVALID_ARGUMENTS` error — malformed input is never silently defaulted.
- **Sizes are bigger — and truthful.** Sizing no longer skips package
  descendants or hidden files, so `.app`/bundle contents and dot-directories
  now count (D2/D3). Xcode DerivedData and Simulator categories in particular
  report larger, accurate totals, and unreadable subtrees are recorded instead
  of silently skipped.

### Added

- **PathGuard + FileSystemIdentityProvider (D4).** Every deletion root,
  contained child, cleanCommand root, and node_modules item passes a single
  admission chokepoint before anything is removed: category-scoped root
  admission with a constrained version-drift rule (one-component sibling or
  pure-version child of a declared root), a deny list
  (`/`, volume roots, `$HOME`, protected first-level home children),
  inode-identity checks, two-signal mount-boundary detection, and cross-device
  refusal. Refusals are reported and logged, never silently skipped.
- **Scan states + visible failures (D6).** Scan JSON entries carry `state`
  (`missing` / `empty` / `measured` / `partiallyDenied` / `denied`) and
  `scan_error` (`{kind, message}`); TCC denials additionally carry `grant_hint`
  with the Full Disk Access remedy, because macOS denies a CLI process
  silently. The cleaner refuses a `denied` category even when named explicitly;
  `partiallyDenied` proceeds with a warning and measured bytes only.
- **Split byte components end-to-end.** Scan entries expose `exact_bytes` /
  `estimated_up_to_bytes` (`size_bytes` retained as their sum); clean entries
  and dry-run plans reuse the same components; smart-clean target math consumes
  scan-time exact components only, so estimates never advance `target_met`.
- **Overcount disclosure.** Recoverable-bytes totals and the clean-confirmation
  sheet disclose that APFS clones and files hardlinked across categories can
  make actual freed space less than reported.
- **TCC usage strings.** `NSDocumentsFolderUsageDescription`,
  `NSDesktopFolderUsageDescription`, and `NSDownloadsFolderUsageDescription`
  ship in all three build paths (bundle.sh heredoc, Info.plist, project.yml).
  Protected roots (Documents / Desktop / Downloads) are enumerated only on
  user-initiated scans, so a background rescan never fires a macOS privacy
  prompt.
- **`spotlight` pre-write admission gate.** The Spotlight rebuild command
  admits its target before any write and reports a `refused` array instead of
  touching unadmitted paths.

### Fixed

- **Freed-bytes over-report (D1).** Freed bytes were assumed from pre-scan
  totals even when deletion partially failed. Every deletion target is now
  measured immediately before deletion and settled through claim-based
  two-phase inode accounting: only successfully deleted bytes are reported,
  hardlinked bytes are always estimates, and command categories report exact 0
  plus an estimated pre-scan size (nothing measures what a command frees).
- **Silent scan failures (D6).** A TCC or permission denial used to read as
  "0 bytes found" — indistinguishable from an empty cache. Denials now surface
  as distinct states in the GUI ("Access denied — not scanned", with a System
  Settings link) and in CLI JSON (`denied` state + `scan_error`).
- **Hidden-directory discovery.** The node_modules scanner no longer skips
  hidden directories (a 23 GB hidden-worktrees field case), still bounded by
  the skip list and recursion depth limit.
- **Hardlink double-count (within walk).** Hardlinked inodes are deduplicated
  within each category walk and reported as estimated bytes instead of being
  counted once per link. Cross-category hardlinks remain disclosed via the
  overcount caveat (D8 is mitigated, not closed — cross-walk accounting is
  deferred to the scanner-expansion epic).

## [2.1.9] - 2026-07-20

### Fixed

- **`--cli memory-stats` and `--cli recommendations` no longer hang.** CLI mode parked the main thread on a `DispatchSemaphore` and never drained the main dispatch queue, so the `MainActor.run` hop inside `MemoryMonitor.start()` could never execute — a mutual deadlock present since v2.0.0. CLI mode now uses the same `dispatchMain()` pattern as daemon mode.
- **`--cli version` reports the real app version.** The handler emitted a hardcoded `"2.0.0"`; it now reads `CFBundleShortVersionString` (stamped from the `VERSION` file by `bundle.sh`), with a compiled fallback for unbundled binaries.
- **`--cli install-helper` works on a first-time install.** Modern macOS reports `SMAppService.Status.notFound` for a daemon that has simply never been registered (no BackgroundTaskManagement record), even when the helper plist is embedded — the CLI treated that as "plist missing" and refused to call `register()`, so a first install could never succeed. The status check now verifies the embedded plist on disk and treats "plist present, no BTM record" as not-registered. Additionally, when invoked via the Homebrew symlink (`/opt/homebrew/bin/cacheout`), the process re-execs through the resolved bundle binary so `Bundle.main` points at the real app bundle.
- **`--daemon` startup failures are no longer silent.** State-directory hardening failures, PID-lock conflicts, and status-socket errors printed only to the unified log and exited 1 with no terminal output; they now emit actionable messages to stderr — including a hint when the socket path exceeds the 104-byte `sockaddr_un` limit.
- **`--cli clean` rejects unknown slugs.** Unknown category slugs previously produced a silent empty success; they now return an `INVALID_ARGUMENTS` error naming the bad slug(s). Documented in PROTOCOL.md.

## [2.1.8] - 2026-07-20

### Security

- **`SysctlJournal.loadState` no longer susceptible to a check/read symlink swap.** The journal load used `FileManager.fileExists` followed by `Data(contentsOf:)` — both path-based and symlink-following, leaving a TOCTOU window where an attacker with write access to the state directory could swap in a symlink and have the helper read an arbitrary file. Now opens once with `open(O_RDONLY | O_NOFOLLOW | O_CLOEXEC)` and reads from the descriptor. (#445)
- **`CacheCleaner.logCleanup` writes are anchored to a verified directory descriptor.** The `~/.cacheout` log directory is now opened with `O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC` and hardened with `fchmod(0o700)`, and `cleanup.log` is created via `openat` relative to that same descriptor — so a rename/symlink swap of the directory between verification and append can no longer redirect the log write. (#423)
- **POSIX permission calls now fail closed.** The `fchmod` in `DaemonMode.loadConfig` and the defense-in-depth `fchmodat` in `StatusSocket.start()` had their return values ignored — a silent failure left the file at its prior mode. Both are now checked and abort their operation (nil config / socket teardown + throw) on failure. (#422)
- **`StatusSocket` `fchmodat` and `SysctlJournal` `rename(2)` bridge paths safely.** Both call sites now pass their paths through `URL(fileURLWithPath:).withUnsafeFileSystemRepresentation` instead of implicit Swift `String` bridging, in line with the project's path-bridging standard. (#433, #444)
- **`SysctlJournal.flushState` temp-file open adds `O_NOFOLLOW`.** Defense-in-depth alongside the existing `O_CREAT | O_EXCL`, which already refuses symlinks at the final component. (#427)

### Changed

- **High-growth process detection is now a reusable predicate.** `PredictiveEngine.detectHighGrowthProcesses(from:)` became `isHighGrowthProcess(_:)`, the `high_growth_process` recommendation loop uses `for-where` instead of building an intermediate filtered array, and the dead `AgentDetector.agentProcesses(from:)` was removed. Tests updated to exercise the new surface. (#440)
- **`MenuBarView.topCategories` drops a pointless `.lazy`.** Sorting materializes the sequence anyway; filtering eagerly first is clearer and no slower. (#420)

### UX / Accessibility

- **Empty states read as one coherent announcement in VoiceOver.** Added `.accessibilityElement(children: .combine)` to the empty-state stacks in `ContentView`, `NodeModulesSection`, and `ProcessesView`, so the icon and explanatory text announce together instead of as disjointed swipe stops. (#419)
- **Clean-confirmation rows announce coherently.** The caption rows in `CleanConfirmationSheet` (selected results, node_modules items) and `CleanupReportSheet` (cleaned entries) are combined into single accessibility elements. (#418)

## [2.1.7] - 2026-06-20

### Security

- **`DaemonMode` PID file is no longer susceptible to a symlink-swap overwrite.** The daemon created its PID file with `open(O_WRONLY | O_CREAT | O_CLOEXEC)` — without `O_NOFOLLOW`, an attacker with write access to the parent directory could plant a symlink at the PID path and redirect the open to truncate or overwrite an arbitrary file. Now opens with `O_NOFOLLOW` and an explicit `0o600` mode so the kernel refuses to follow a symlink at the final component. (#416)
- **`StatusSocket` POSIX path bridging hardened.** The `open(2)` calls in `StatusSocket.swift` (state-directory hardening and config-validation read) now bridge their paths through `URL(fileURLWithPath:).withUnsafeFileSystemRepresentation` instead of passing Swift `String`s directly, bringing both call sites in line with the project's path-bridging standard. (#417)

### Changed

- **`SysctlJournal` stale-entry and rollback index maps** now build via `reduce(into:)` over `state.entries.indices` instead of incremental `for`-loop mutation. Behavior-preserving cleanup of `revertStaleEntries()` and `performRollback()`. (#414)

### UX / Accessibility

- **Check For Updates button** now carries a `.help()` tooltip that explains why it is disabled when update checking is unavailable (e.g. no appcast), removing ambiguity around the greyed-out control. (#415)

## [2.1.6] - 2026-06-19

### Security

- **`DaemonMode` state-directory permissions are no longer settable via symlink swap.** The daemon hardens its state directory (`~/Library/Application Support/Cacheout` or `--state-dir`) by chmod'ing it to `0o700` after `createDirectory` — but the previous `FileManager.setAttributes(ofItemAtPath:)` follows symlinks, so an attacker with write access to the parent could swap the directory for a symlink between the two calls and redirect the chmod. Now opens the directory with `open(O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)` and applies `fchmod(0o700)` to the resulting descriptor — the kernel can't be tricked into chmod'ing somewhere else. Distinct from v2.1.5's #346, which fixed a different chmod site on the config-reload path. (#410)

### Changed

- **`RecommendationEngine` recommendation loops** now use `for proc in scanResult.processes where condition` instead of `scanResult.processes.filter { ... }.forEach`. Avoids two intermediate array allocations on every recommendation pass — runs on the daemon hot path, so the saving compounds at the long-running-daemon scale. (#407)

### UX / Accessibility

- **Disk-usage bar and MenuBar stat pills** now read as single coherent items in VoiceOver. Added `.accessibilityElement(children: .combine)` at the outermost modifier position on `DiskUsageBar`'s outer frame and on `MenuBarView`'s `statPill` so the entire visible card announces together instead of forcing the user to swipe through each text element. (#409)

## [2.1.5] - 2026-06-16

### Security

- **`DaemonMode` config load no longer susceptible to chmod/read TOCTOU.** The previous path-based `chmod(path, 0o600)` followed by `FileManager.contents(atPath:)` could be redirected by a symlink swap between the two calls — an attacker with write access to the directory could trick the daemon into chmod'ing or reading an arbitrary file. Now opens the config with `open(O_RDONLY | O_NOFOLLOW | O_CLOEXEC)` once, applies `fchmod(0o600)` to the resulting descriptor, and reads via `FileHandle.readToEnd()`. Both the permission change and the read happen on the same fd so the kernel can't be tricked into operating on a substituted path. (#346 — deferred from v2.1.4 due to a release-window merge conflict)

### Changed

- **`CacheoutViewModel.selectedSize`** now uses `scanResults.lazy.filter(\.isSelected)` instead of materializing `selectedResults` to compute a sum — saves the intermediate array allocation on every recomputation.
- **`CacheoutViewModel.hasSelection`** uses `contains(where:)` on both `scanResults` and `nodeModulesItems` instead of comparing `selectedNodeModulesSize > 0`, which previously forced a full `reduce` over `nodeModulesItems` just to check whether *any* item was selected. Now short-circuits on the first match. (#404)

### UX / Accessibility

- **Memory dashboard stat cards** are now read as a single coherent item by VoiceOver. Added `.accessibilityElement(children: .combine)` to the two stat-card views in `MemoryView` so the title and value announce together instead of forcing the user to swipe through each text element separately. (#401)

## [2.1.4] - 2026-06-15

### Security

- **`SysctlJournal` no longer leaves the journal temp file world-readable during the umask window.** The previous `Data.write(to:)` + `setAttributes(0o600)` sequence created the file under the process's default umask before tightening permissions. Now uses POSIX `open(O_CREAT | O_WRONLY | O_EXCL | O_CLOEXEC, 0o600)` so the file is born with the right mode and never observable to other local users. (#396)
- **`CacheCleaner` cleanup log is no longer vulnerable to TOCTOU symlink attacks.** `FileHandle(forWritingTo:)` and the `String.write(to:atomically:)` fallback both follow symlinks. Replaced with `open(O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)`; the log directory is also explicitly created `0o700`. (#391)
- **`StatusSocket` hardened against directory symlink swaps and `validate_config` file swaps.** Directory chmod now uses `open(O_NOFOLLOW | O_DIRECTORY) + fchmod` instead of path-based `setAttributes`. Post-bind verification `lstat`s the socket path and refuses to start if it isn't `S_IFSOCK`. `handleValidateConfig` opens with `O_NOFOLLOW | O_CLOEXEC` once, `fstat`s the fd for type + size, and reads from the fd with a hard byte cap — closes the `lstat → Data(contentsOf:)` window where a swap could bypass the size cap or `S_IFREG` check. (#397)

### Changed

- **Lazy-filter `.count` in MenuBarView and CleanConfirmation** to avoid allocating intermediate arrays just to take a count. Minor allocator pressure win in views that re-render frequently. (#393)

### UX / Accessibility

- **Disabled-state tooltips on MenuBar buttons** (Scan, Quick Clean, Docker Prune) — `.help()` strings explain why each is disabled (in-progress, nothing to clean, etc.) instead of leaving the user to guess. (#379)
- **Docker Prune button** in Settings now shows inline "Pruning…" text alongside the spinner and gets a `.help()` tooltip explaining the action. (#263)
- **`NodeModulesSection` header** announces expanded/collapsed state to VoiceOver via `.accessibilityValue`. (#394)

## [2.1.3] - 2026-05-22

### Fixed

- **Menubar icon now renders correctly on dark and translucent menubars.** v2.1.2 swapped in the master artwork but the icon still read as invisible on dark backgrounds — loose `@1x`/`@2x` PNG pairs loaded via `Bundle.main.image(forResource:)` produce an `NSImage` whose `isTemplate` flag is silently dropped by `NSStatusItem.button`, so AppKit was painting the black master in black on a black menubar. Switched the bundled assets to multi-rep TIFFs (`tiffutil -cathidpicheck`, the same format Xcode's actool emitted for v2.0.0). TIFF-backed `NSImage`s propagate `isTemplate` through to the status button and AppKit tints the icon to match the menubar appearance.

### Changed

- `node_modules` permanent-delete now parallelizes with the same sliding-window `TaskGroup` (max 8) + GCD handoff pattern used by `removeContents(of:)` in #275. Move-to-Trash stays sequential because `trashItem` is `@MainActor` and Finder serializes Trash ops anyway. Per-item failures are isolated — one bad `node_modules` entry no longer poisons the rest of the batch.
- `Tests/CacheoutTests/CacheCleanerTests.swift` added: round-trip tests for the parallel deletion paths (large fan-out, isolated failures, empty-dir no-op, parent-dir preservation, unselected skip).

## [2.1.2] - 2026-05-17

### Fixed

- Menubar icon now uses the correct master artwork. The previous PNGs were a faint outline that effectively rendered invisible at 18×18 in template mode. Re-generated `MenuBarIcon{,@2x,Template,Template@2x}.png` from `Resources/menubar-icon-master.PNG` so the Cacheout "C" actually appears in the menubar.

## [2.1.1] - 2026-05-17

### Fixed

- **Menubar icon now displays again.** The custom `MenuBarIconTemplate.png` resources weren't being copied into `Contents/Resources/` by `scripts/bundle.sh`, so `Bundle.main.image(forResource:)` couldn't find them and the menubar item rendered blank for some users. Bundle script now copies both regular and `@2x` variants for both `MenuBarIcon` and `MenuBarIconTemplate`.
- **Privileged helper daemon is now bundled at `Contents/Library/LaunchDaemons/`.** `scripts/bundle.sh` was not copying the `CacheoutHelper` executable or `com.cacheout.memhelper.plist` into the app, which silently broke the install-helper onboarding flow and `--daemon` autopilot. The helper is now signed before the outer app so `codesign --verify --deep --strict` passes.

## [2.1.0] - 2026-05-17

### Added

- Sparkle.framework now bundled inside `Cacheout.app/Contents/Frameworks/` with the correct `@executable_path/../Frameworks` rpath — future releases can auto-update via Sparkle without manual reinstall.
- Inner XPC services (`Downloader.xpc`, `Installer.xpc`), `Updater.app`, and `Autoupdate` are re-signed in the correct inner→outer order with `--options runtime`; `Downloader.xpc` re-signs preserve entitlements for Sparkle 2.6+ sandbox compatibility.
- `./scripts/bundle.sh --notarize` (and `--release` alias) now runs the full pipeline: build, sign, DMG, notarize, staple.
- Dynamic button labels on the Scan/Clean buttons (`Scanning…` / `Cleaning…`) with `.help()` tooltips explaining disabled states.
- `.help()` tooltip on the per-process ellipsis menu in the Processes view.
- Visual empty state for the node_modules section (centered icon + callout, replacing the plain text).
- Accessibility labels on icon-only controls so VoiceOver reads meaningful names instead of "Button".
- Empty state for the Processes view.

### Changed

- `runCleanCommand` in `CacheoutViewModel` now reads the process pipe before calling `waitUntilExit()`, eliminating a deadlock when `docker system prune` output exceeds the ~64KB pipe buffer.
- `JetsamHWM` priority map now built with `reduce(into:)` instead of a mutating for-loop, removing copy-on-write overhead.
- `ProcessMemoryScanner` uses a sliding-window TaskGroup for bounded concurrency.
- Scanner TaskGroups marked `nonisolated` so subtasks actually parallelize off the actor executor.
- Shared `ByteCountFormatter` / `ISO8601DateFormatter` instances instead of per-call allocations; `.lazy.filter` before `.reduce` to avoid intermediate arrays.
- Batched `@Published` array mutations to a single assignment so SwiftUI re-renders once per scan.
- `CacheScanner` enumerator now prefetches `.isRegularFileKey` so `URL.resourceValues` avoids a fallback `stat()` per file.
- `NodeModulesScanner` is now truly concurrent and issues fewer syscalls.
- Blocking I/O (process waits, `URLResourceValues` reads) is now offloaded via `Task.detached` so async @MainActor methods no longer stall the UI.
- `runningApplications` filtered with `.lazy` to skip an intermediate array allocation.

### Fixed

- Webhook URLs are now validated as `https` in both `AutopilotConfigValidator` and `WebhookConfig.parse`. `http://` webhooks are rejected.
- PID lock acquisition in daemon mode now opens with `O_CLOEXEC` and uses `withUnsafeFileSystemRepresentation`, preventing the lock fd from leaking into child processes.
- Defense-in-depth fix for process pipe deadlock during process execution (reads pipes before/concurrently-with `waitUntilExit()`).
- Command injection vulnerability in `runCleanCommand`: shell strings replaced with `Foundation.Process` + arguments array.
- Command injection in `CacheCategory.toolExists`: `/bin/bash -c` interpolation replaced with `/usr/bin/env <tool>` invocation, restoring the explicit `PATH`/`HOME` environment so the macOS GUI launch context resolves Homebrew tools correctly.
- Docker pruning refactored to use `/usr/bin/env docker` instead of hardcoded `/usr/local/bin/docker` so Apple Silicon `/opt/homebrew/bin` users actually run it.
- Guard against empty arguments in `runCleanCommand`.
- Process names no longer display as "unknown" in the main process list.

## [1.0.0] - 2026-01-01

### Added

- Initial release
- 25+ cache categories: Xcode, Docker, npm, Yarn, pnpm, Bun, Homebrew, pip, uv, Gradle, CocoaPods, Swift PM, Playwright, VS Code, Electron, browser caches, ChatGPT Desktop, Prisma, TypeScript, node-gyp, PyTorch Hub
- Recursive node_modules finder with staleness detection (30d+)
- Risk-level indicators (Safe / Review / Caution)
- Async parallel scanning via Swift actors and TaskGroups
- Sparse file awareness (accurate Docker disk image sizing)
- Move to Trash option (recoverable deletion)
- Cleanup logging to `~/.cacheout/cleanup.log`
- Main window with full cache management UI
- Menubar popover with disk gauge and quick clean
- Settings window with scan interval, low-disk threshold, and Docker prune
- CLI mode (`--cli`) with scan, clean, smart-clean, disk-info, and spotlight commands
- Dry-run support for CLI clean commands
- Smart clean: auto-select safe categories until target GB freed
- Spotlight tagging for cache directory discovery
- Custom clean commands (e.g., simulator device cleanup via `xcrun simctl`)
- Probed path discovery (dynamic cache location via shell commands)
- Low-disk notifications with 1-hour throttle
- Customizable scan interval (15min–4h)
- Sparkle framework integration for future auto-updates
- Custom menubar icon with disk-full warning badge
- Homebrew formula
- DMG installer with custom background
- Watchdog scripts for background monitoring
