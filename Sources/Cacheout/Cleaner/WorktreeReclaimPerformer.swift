/// # WorktreeReclaimPerformer — git-mediated worktree reclaim (fn-5.4, R5/R6/R8)
///
/// The execution behind the composite `ReclaimAction.gitWorktreeReclaim`, in
/// two modes:
///
/// - **`removeStaleWorktree`** — the scan's four gates re-established, the
///   clean re-check LAST, the filesystem re-proof after it, then THIS
///   process removes the checkout under `DepthSafeRemoval` (or moves it to
///   the Trash), then a GATED removal of that worktree's OWN admin entry.
///   `git worktree remove` does not appear anywhere: see "WHO REMOVES THE
///   TREE" below.
/// - **`pruneOrphanedAdmin`** — a SCOPED removal of exactly the
///   PROVABLY-COMPLETE admin-directory set the scan disclosed (D14), never a
///   repository-wide `git worktree prune` (see `removeAdminDirectories`).
///
/// ## WHO REMOVES THE TREE (PR #460 codex r5, D1)
///
/// Through r4 the DEFAULT path was `git worktree remove`, and the header
/// claimed a 0.16 ms window between the last gate and "the destructive
/// call". The spawn is not the destructive act. git starts up, reads the
/// registry, runs its own `status --porcelain` child over the whole tree,
/// and only then unlinks — and it never re-reads admin-directory identity,
/// HEAD, or ancestry.
///
/// MEASURED THIS ROUND, uninstrumented, with the harness checked in at
/// `scripts/measure/worktree-removal-window.{c,sh}` — it forks and execs the
/// remover while the parent spins on `lstat` of the worktree's only tracked
/// file until ENOENT (git 2.50.1, macOS 15, APFS). The r5 review reported
/// 19.9 ms and 159.5 ms for the git row on the same shapes; these are this
/// round's own runs of the same experiment:
///
/// | arm | 1 tracked file | 2001 tracked files |
/// |---|---|---|
/// | `git worktree remove`, spawn → first destruction | median **14.87 ms**, 14.28–19.84, n=10 | median **156.8 ms**, 117.1–161.7, n=5 |
/// | direct `removefile`, call → first destruction | median **0.417 ms**, 0.361–0.639, n=10 | median 62.5 ms, 39.5–65.9, n=5 |
///
/// The 2001-file column is the same *file*, not the same *position in the
/// walk*, so its two numbers differ mostly by git's own pre-unlink work:
/// ~94 ms of registry read plus a `status` walk that GROWS with the tree.
/// The 1-file column is the honest handoff cost, and it is 35× ours.
///
/// That second row is a PROXY — a C harness calling `removefile` directly,
/// which is not this code. The shipped path was then measured INSTRUMENTED
/// through the production composition (`CacheCleaner` wiring
/// `DepthSafeRemoval` / `TrashDisposal`), timing the LAST GIT COMPLETION
/// BEFORE THE UNLINK against a watcher thread spinning on `lstat` of a
/// tracked file until ENOENT — never simply "the last git call", because the
/// gated prune's own invocations run AFTER the unlink:
///
/// | disposal | last gate answered → the checkout is gone | main thread |
/// |---|---|---|
/// | permanent (`DepthSafeRemoval`) | median **0.373 ms**, 0.315–0.565, n=10 | IDLE |
/// | trash (`TrashDisposal`) | median **0.674 ms**, 0.588–16.152, n=10 | IDLE |
///
/// THE LOAD CONDITION IS PART OF THOSE FIGURES AND WAS OMITTED (PR #460 codex
/// r6, D2). Both rows were taken on an IDLE main thread, and only the
/// permanent row is insensitive to that: it hops to a global CONCURRENT
/// queue. The trash row hops to the MAIN ACTOR, because `trashItem` requires
/// it, so its true width is the main thread's QUEUE DEPTH.
///
/// AND "INSENSITIVE TO THE MAIN THREAD" IS NOT "HAS NO QUEUE" (PR #460 codex
/// r7, D1). r6 drew the second conclusion from the first and left the
/// permanent arm's proofs on the near side of its own hop. Its hop is
/// `DispatchQueue.global(qos: .userInitiated)`, and a queue's depth is not a
/// syscall either. MEASURED through the production composition with the pool
/// saturated microseconds before the hop (32 × 120 ms CPU-bound items,
/// enqueued after the last git call returns, so the removal is behind all of
/// them), n=3, by
/// `testTheWindowsThatRemainAreMeasuredUnderLoadInBothArms`:
///
/// | permanent arm, last identity/lock/HEAD proof → the removal | median |
/// |---|---|
/// | proof on the NEAR side of the hop (through r6) | **242.656 ms**, 240.010–242.738 |
/// | proof INSIDE the hop (r7) | **0.032 ms**, 0.031–0.048 |
///
/// at a measured pool delay of 240.4 ms and 240.2 ms respectively. Under
/// MAIN-THREAD load the same arm measures 0.040 ms and 0.023 ms — it really
/// does not wait on that thread, which is why the load that describes it had
/// to be the one it does wait on.
///
/// AND THE 16.152 ms SAMPLE WAS EXPLAINED AWAY RATHER THAN MEASURED. r5
/// wrote "the trash arm's maximum is one outlier from the mover; its median
/// is the number that describes the arm". That attribution is wrong on its
/// own evidence: the mover is one same-volume `rename(2)` whose measured
/// spread is 262–456 µs (`TrashDisposal`'s header), which cannot produce
/// 16 ms, while the hop demonstrably can — MEASURED THIS ROUND through the
/// production composition with 120 ms work items held on the main thread, the
/// interval between the last filesystem proof and the mover was median
/// **175.736 ms** (n=5, 160.352–184.937) with the proof on r5's side of the
/// hop, against **0.004 ms** (0.004–0.016) with it moved across. A quantity
/// that moves by four orders of magnitude with main-thread scheduling and by
/// none with the mover is a scheduling quantity. The median never described
/// the arm; it described an idle machine.
///
/// r6 does not narrow the trash row by making the mover faster — it moves the
/// PROOF to the far side of the hop (`TrashDisposal.Mover`), and r7 does the
/// same for the permanent arm (`removeTree`'s third argument). What is left
/// between the last proof and the destruction is then the 0.004 ms / 0.032 ms
/// above no matter how deep that arm's queue is.
///
/// FOR THREE PROPOSITIONS, NOT ALL OF THEM (PR #460 codex r7, D2). Those
/// figures cover WHICH CHECKOUT this is, whether it is LOCKED and whether
/// HEAD MOVED — the set `reproveFromTheFilesystem` answers, which is
/// everything the FILESYSTEM can answer. CLEANLINESS is git's answer, costs a
/// subprocess, and does NOT cross either hop; its interval under load is the
/// queue depth, measured at 241.156 ms (permanent, saturated pool) and
/// 185.864 ms (Trash, 120 ms main-thread items) in the same cell. It is
/// disclosed as residual 1 below rather than covered by these numbers.
///
/// Both rows are compared against 14.87 ms, and unlike 14.87 ms neither grows
/// with the tree.
///
/// **That window is IRREDUCIBLE while git performs the removal** — the
/// unlink happens inside git's process, so no re-proof of ours can sit
/// closer. The choice is therefore not "narrow it": it is disclose it, or
/// change who removes the tree. This file changes who.
///
/// WHAT IS LOST. git's `--force`-less dirty refusal is a real gate, run
/// inside git with no window at all. What replaces it is
/// `GitWorktreeCleanCheck` — the SAME `status --porcelain` git runs
/// internally — as the LAST git call, extended with `--ignored` (D2), so it
/// refuses strictly MORE than git's own does. git's `validate_no_submodules`
/// refusal is also lost; it was already lost, because that class routed to
/// the fallback and was deleted there anyway (see the trigger classes
/// below). And git's removal was ATOMIC with the registry cleanup, where
/// ours is two steps: a failure between them leaves admin data behind, which
/// is a WARNING on a successful row and an item the next scan offers.
///
/// WHAT IS GAINED. The residual falls from **14.87 ms** — SPAWN → first
/// destruction on a 1-tracked-file checkout, and it GROWS with the tree
/// (156.8 ms at 2001 files) — to **0.032 ms** in the permanent arm with the
/// global pool saturated and **0.004 ms** in the Trash arm under 120 ms
/// main-thread work items, and neither of those grows with the tree.
/// Everything in that residual is re-proved: which checkout this is, whether
/// it is locked, whether HEAD moved.
///
/// NOT 0.417 ms, which this paragraph published through r8 (PR #460 codex r9,
/// D4). That is the `removefile` row of the table above, which this file's
/// own caveat under it calls "a PROXY — a C harness calling `removefile`
/// directly, which is not this code", and its endpoint is CALL → first
/// destruction on an idle machine. Three intervals, three load conditions:
/// the pair quoted here is the one the three propositions actually sit in,
/// re-derived with its loads under `reproveFromTheFilesystem` below, and it
/// covers those three propositions only — CLEANLINESS is disclosed as
/// residual 1.
///
/// The mount-boundary refusal now covers the actual removal. And **Move to
/// Trash now applies**: the GUI ships `moveToTrash = true` and the primary
/// arm ignored it, so the app's most common worktree removal was
/// unconditionally unrecoverable.
///
/// WHAT DOES NOT CHANGE: every class where git REFUSED already ended in this
/// same removal, so no outcome moves from "kept" to "deleted". The outcomes
/// that move are refusals we can now make and git's success swallowed.
///
/// It is a `struct` of injected seams rather than more `CacheCleaner` body so
/// every gate below is reachable from a test without a real repository: the
/// sizer is a closure (the ADMIT-BEFORE-MEASURE proof is "the spy recorded
/// zero calls"), the runner is fn-5.1's protocol, and deletion/trash/logging
/// are the cleaner's own primitives handed down.
///
/// ## ADMIT BEFORE MEASURE (epic round 4 / F3)
///
/// `removeGuardedItem`'s order is admit → measure → mount-refuse, and this
/// performer keeps it: snapshot-bound `admitContainer` + `validateRemovableItem`
/// + the D13 traversal guard run FIRST, before ANY `.deletionTarget`
/// measurement and before any git. Measuring first would let a forged item
/// drive a `.deletionTarget` walk through a swapped symlink ancestor before
/// the refusal it was always going to earn.
///
/// ## THE D13 SUBPROCESS-TRAVERSAL AUDIT
///
/// WHAT IS ACTUALLY GUARANTEED (rewritten, PR #460 codex r2 — the previous
/// wording, "re-runs IMMEDIATELY before EVERY git invocation", was FALSE, and
/// it is still false at r3. MEASURED (PR #460 codex r4 corrects the evidence
/// sentence, not the count: r3 cited `grep -c 'try guardTraversal('`, which
/// returns 9 on this file because THIS COMMENT contains the search string —
/// the eighth instance of a claim this file could not reproduce):
/// `grep -cE '^ +try guardTraversal\(' Sources/Cacheout/Cleaner/WorktreeReclaimPerformer.swift`
/// returns **7** call sites at r5 (one of which is inside the shared
/// `guardGroup` helper) — it was 8 through r4 and the fallback-entry guard
/// went with the fallback (D1) — against far more git invocations than that,
/// and R0 and R2 are both invoked with no immediately-preceding guard,
/// deliberately — see the table):
///
/// **Every path a git invocation traverses is covered by a
/// `validateSubprocessTraversalDirectory` that ran after admission and
/// before that invocation** — but NOT necessarily one guard per invocation.
/// A guard is a PATH check: at the instant it runs, this spelling is a real,
/// non-symlink, same-device directory canonically inside the admitted
/// container. It is not a lock and not a handle, so it cannot bind what git
/// resolves a microsecond later; re-running it narrows a window, it never
/// closes one. Adding re-runs that no cell can distinguish would only ship
/// unevidenced guards. What actually closes the scan→delete gap is asking
/// GIT (R0) and the REGISTRY (R1/R1b) — a repository can be re-pointed while
/// every path fact above still holds.
///
/// The table below is therefore BY GUARD SITE, not by invocation:
///
/// | guard site                       | paths                  | the invocations it covers |
/// |----------------------------------|------------------------|---------------------------|
/// | admission (both modes)           | parent (or-equal), admin container; stale mode adds the worktree | everything, as the floor |
/// | pre-gates (stale, step 7)        | parent, worktree, admin container | R0, R1b's back-link read, and R2's ladder + ancestry (R1b reads `<wt>/.git`, so the admin container is traversed there too). r5 widened this row from "parent, worktree": it used to be the pre-`worktree remove` guard, and the fallback re-guarded the third path on entry |
/// | inside R1 (PR #460 codex r2)     | parent, admin container | the `worktree list` re-read — it ENUMERATES `$GIT_COMMON_DIR/worktrees` to answer `prunable`, and the step-7 guard cannot bind what a later subprocess resolves |
/// | pre-`status` (PR #460 codex r3, EVIDENCED r4) | worktree, admin container | the clean re-check, which is the LAST git call and is therefore separated from the step-7 guard by five subprocesses — git follows `<wt>/.git` INTO the admin/common git dir, so a swap in EITHER would redirect it (epic round 6). r3 asserted this row without a cell that could tell the guard from its absence, which is the very thing this file's doctrine forbids; `testTheAdminContainerSwappedInsideTheGateWindowIsRefusedBeforeStatus` stages a swap in exactly that window and goes RED when the guard is deleted |
/// | inside the oracle recompute      | parent, admin container | the recompute's `worktree list` — same argv, same two paths |
/// | pre-scoped-removal               | parent, admin container | the scoped admin removal and the R0 immediately before it |
/// | each affected admin dir (prune mode) | the dir itself, strictly | that directory's own removal |
///
/// R2's three subprocesses share one covering guard because
/// `GitWorktreeMergedCheck` is a shared seam this file does not own; there is
/// no honest way to interleave a guard between rungs of its ladder.
///
/// ## THE DELETE-TIME GATE RE-ESTABLISHMENT (PR #460 codex r1)
///
/// The scan authorises a removal with four gates (`WorktreeStalenessAssessor`
/// G1…G4). Until this round the delete path re-established exactly ONE of
/// them (G2, and only on the fallback path), so a worktree that was locked,
/// deregistered, or committed into between the scan and the click was
/// destroyed anyway — with an empty error list. `reestablishStaleGates` now
/// re-proves R0 (repository identity), R1 (G1 + G4 + the registration
/// itself, from the re-read porcelain record), R1b (WHICH worktree that
/// record is about) and R2 (G3, through the shared `GitWorktreeMergedCheck`)
/// immediately before the mutation. Through r4 it ran at BOTH mutating sites
/// — before `worktree remove`, and again inside the fallback — because the
/// two arms were reachable independently. There is ONE mutating site now
/// (r5/D1), so it runs once, five subprocesses earlier than the removal
/// rather than ten.
///
/// ## GATE ORDER (PR #460 codex r3)
///
/// R0/R1/R1b/R2 run FIRST and G2 (the clean re-check) runs LAST, immediately
/// before the disposal. The reverse order shipped in r1/r2 and was a live
/// hole: MEASURED, a file written into the worktree after the clean re-check
/// and before the delete was destroyed while the performer returned a SUCCESS
/// entry, `errors == []`, `warning == nil`. Five git subprocesses and two
/// path re-admissions sat in that window.
///
/// The order is safe both ways round for R0/R1/R2 — they read the PARENT's
/// porcelain record, which the worktree's own contents cannot change — so
/// putting the contents check last costs nothing and closes the window that
/// mattered.
///
/// THAT ENUMERATION WAS INCOMPLETE AND ITS CONCLUSION WAS FALSE (PR #460
/// codex r4). R1b is not in the list, and R1b is precisely the gate that does
/// NOT read the parent's record: it reads `<worktree>/.git` and inodes the
/// admin directory it points at — a fact the worktree's own contents CAN
/// change. Under r3's order R1b sat FIVE subprocesses before the delete, and
/// MEASURED, a `git worktree remove` + `git worktree add` at the SAME PATH
/// staged on the clean re-check destroyed the brand-new checkout with
/// `errors == []`. The sentence "what remains is the disposal call itself"
/// became true only with the section below.
///
/// ## THE LAST-INSTANT RE-PROOF (PR #460 codex r4)
///
/// Immediately before the destructive act — after G2, and since r5 there is
/// only ONE destructive act to be before — every proposition whose AUTHORITY
/// IS THE FILESYSTEM is re-proved from the filesystem: which checkout this is
/// (R1b's own resolver), whether it is locked (`<admin>/locked`), and whether
/// HEAD moved (`<admin>/HEAD`, when that file corroborates the porcelain
/// record, or `<admin>/reftable/tables.list` when it cannot). It spawns
/// nothing, and since r6/r7 it runs on the FAR side of each arm's hop, so the
/// residual it leaves is the pair measured under each arm's OWN load above:
/// **0.032 ms** in the permanent arm with the global pool saturated, and
/// **0.004 ms** in the Trash arm under 120 ms main-thread work items.
///
/// NOT 0.373 ms / 0.674 ms, which this paragraph published through r7 (PR
/// #460 codex r8, D6). Those are a different interval on a different load:
/// the LAST GIT COMPLETION → UNLINK on an IDLE MAIN THREAD — i.e. the
/// CLEANLINESS window, the one proposition that cannot cross the hop — and
/// under the loads above that window is 241.156 ms and 185.864 ms. The
/// 14.87 ms `git worktree remove` figure is a third endpoint again: SPAWN →
/// first destruction. Three intervals, three load conditions; none of them
/// substitutes for another.
///
/// What genuinely needs a subprocess —
/// cleanliness, and
/// ancestry when HEAD did not move but a branch tip did — is enumerated as a
/// RESIDUAL rather than described as closed: see `reproveFromTheFilesystem`
/// and the "What is left, measured" section.
///
/// ## RUNNER-RESULT ROUTING IS TOTAL
///
/// Every `GitCommandOutcome` is switched EXHAUSTIVELY at every call site —
/// there is no "any failure" arm anywhere, because the four classes mean
/// different things: exit 0 is the ONLY signal a gate's answer can be read
/// from; a nonzero exit is git's considered refusal; a TIMEOUT means the
/// question was never answered; `gitUnavailable` executed nothing at all.
/// Since r5 no git invocation on this path MUTATES anything, so none of the
/// four classes can leave partial state — every one of them is a refusal
/// before the removal rather than a decision about a removal already begun.
///
/// ## THE TWO CLASSES GIT WOULD HAVE REFUSED, AND STILL DOES NOT STOP (D4)
///
/// Through r4 these were the "fallback trigger classes": git refused with a
/// nonzero exit and the guarded delete ran anyway. They are named here still,
/// because the OUTCOME is unchanged and pretending otherwise would be the
/// dishonesty this file is about:
/// 1. an ignored-tree "Directory not empty" refusal (the field class:
///    `status --porcelain` omits ignored files, so the re-check passed).
///    THIS ONE IS NOW ACTUALLY GATED — G2 runs with `--ignored` (D2), so an
///    ignored file that is not a git-generated artefact REFUSES rather than
///    routing to a delete;
/// 2. a CLEAN worktree containing a POPULATED SUBMODULE — git's
///    `validate_no_submodules` refuses without `--force`, the re-check
///    passes, and the removal proceeds (the targets are user-owned dev roots
///    and the parent's absorbed `modules/` object store is untouched; refs of
///    an attached branch survive). Unchanged, and unchanged deliberately.
///
/// What SEPARATED the two intended classes from git's own SAFETY refusals was
/// never the wording — a classification derived from git's message text is
/// forbidden here — but the re-established state, and that is still what
/// decides: a lock leaves the porcelain record `locked` (and `<admin>/locked`
/// on disk), a deregistered path leaves no record at all, and both are
/// refused by R1 and by the last-instant re-proof. Before PR #460 the
/// fallback re-checked only cleanliness and therefore achieved `remove -f -f`'s
/// effect on a locked worktree without the flag — measured, with `errors=[]`.
///
/// ## ACCOUNTING (mirrors `removeGuardedItem`; D14's verified-removal for prune)
///
/// Claims are measured and REGISTERED before any git runs, and accepted ONLY
/// after the removal actually succeeded. A failed or aborted removal accepts
/// nothing; its registrations stay transferable by siblings. Prune mode goes
/// further (D14 round 4): it measures the RECOMPUTED set at delete time,
/// never the scan-time disclosed measures, and accepts only the dirs it can
/// VERIFY disappeared — a disclosed entry that became locked or repaired
/// since the scan is not in the final removal set at all, and reporting its
/// bytes as freed would be a lie.
///
/// ## DISPOSAL HONESTY (D16, corrected r5 / D7)
///
/// The stale-removal entry HONOURS the Move-to-Trash toggle, and its
/// `.trash` disposal is reported only when the trash handler ACTUALLY
/// succeeded — a trash failure is an error and yields no entry at all, never
/// a fall-through to a permanent delete. That is new at r5: while
/// `git worktree remove` was the primary arm the entry was `.permanent`
/// ALWAYS, justified in this file by "git unlinks and prunes, it does not
/// trash". `141e3a1` retired that sentence from the docs and left it here,
/// where it was the stated reason for the disposal — the seventh instance of
/// a retired proposition surviving at its DEFINITION site. No git prune runs
/// any more and no git removal runs any more, so the sentence has no subject.
///
/// Every prune-only entry, and the admin-entry removal that follows a
/// successful stale removal, remain `.permanent` unconditionally: those are
/// repository metadata this process deletes directly, and a `worktrees/<id>`
/// directory in the Trash is not something a user restores.

import Foundation

/// The performer's per-item result, in the shape `CacheCleaner.clean(items:)`
/// consumes from every other action.
struct WorktreeReclaimOutcome {
    var entry: CleanupReport.Entry?
    var errors: [CleanupReport.ItemError]

    static let none = WorktreeReclaimOutcome(entry: nil, errors: [])
}

/// A `GateReestablishment.refuse` raised from INSIDE the mover seam (PR #460
/// codex r6, D1), where the only channel out is `throws`.
///
/// It carries the tag and the detail unchanged so the refusal that fires on
/// the far side of the seam's hop is indistinguishable, in the log and in the
/// per-item error, from the same refusal firing on the near side. A bare
/// `Error` would have collapsed both into
/// `failure(item, error.localizedDescription, tag: nil)` — an untagged
/// refusal, which is the shape this branch has spent four rounds removing.
struct LastInstantRefusal: LocalizedError {
    let tag: String
    let detail: String
    var errorDescription: String? { detail }
}

/// A proof a destructive seam must run on the FAR SIDE of its own hop,
/// immediately before the destruction, destroying nothing if it throws
/// (PR #460 codex r7, D1).
///
/// A NOMINAL TYPE RATHER THAN A BARE `() throws -> Void`, AND THE REASON IS A
/// MEASURED CRASH. `removeTree`'s hop resumes its continuation from INSIDE the
/// dispatched block, so the closure outlives the `await` that hands it over:
/// it is genuinely escaping. A closure PARAMETER of a function TYPE is not,
/// and cannot be annotated `@escaping`. The first spelling of this used
/// `withoutActuallyEscaping`, which compiled, passed every filtered run, and
/// trapped under the full suite — "closure argument was escaped in
/// withoutActuallyEscaping block" — because whether the block is released
/// before or after the check is a scheduling race. A struct's stored property
/// is escaping by construction, so the contract is expressible without lying
/// about lifetime.
///
/// `TrashDisposal.Mover` keeps the bare-closure spelling on purpose: its
/// production seam runs the proof inside `MainActor.run`, which does NOT
/// outlive the call.
struct LastInstantProof {
    let run: () throws -> Void

    init(_ run: @escaping () throws -> Void) { self.run = run }

    /// So a seam calls it the same way the mover's closure is called.
    func callAsFunction() throws { try run() }

    /// STATED, never defaulted: an arm whose every proposition is already
    /// re-proved past its own hop by the removal itself.
    static let nothingFurther = LastInstantProof {}
}

struct WorktreeReclaimPerformer {

    // MARK: - Pinned constants

    /// DELETE-TIME budget, PER GIT INVOCATION — minutes-scale on purpose and
    /// never fn-5.1's ~10 s scan default: a mid-removal timeout on a
    /// multi-GB tree leaves partial state, so this caller must be able to buy
    /// patience. Injectable; under D18's no-client-timeout rule this budget
    /// plus the runner's termination protocol is the REAL bound.
    static let deleteTimeGitTimeout: TimeInterval = 300

    /// The D11 warning tail every post-removal prune OUTCOME that left admin
    /// data behind carries — the conservative skip (round 8) and every prune
    /// failure after a successful delete alike. EXCLUSIVE to stale mode:
    /// prune-only failures are ERRORS, never warnings.
    static let orphanedAdminWarning =
        "orphaned admin data remains; next scan will offer it"

    // MARK: - Argv (registry code, built from PLAN FIELDS — never carried)

    // THERE IS NO `removeArguments`, AND THAT IS THE POINT (PR #460 codex r5).
    //
    // `git -C <parent> worktree remove <worktree>` used to be the primary
    // arm. It is gone, argv builder and all, because the ACT it performs is
    // inside git's process and no gate of ours can sit next to it: git
    // starts up, reads the registry, runs its own `status --porcelain` child
    // over the whole tree, and only then unlinks — and it never re-reads
    // admin-directory identity or HEAD. MEASURED (fork + exec, spinning on
    // `lstat` of the worktree's only tracked file until ENOENT, git 2.50.1,
    // macOS 15): spawn → first destruction median **14.87 ms**, range
    // 14.28–19.84 ms, n=10. The same measurement over a 2001-file worktree
    // reaches the same file at median 156.8 ms against 62.5 ms for a direct
    // `removefile` — a ~94 ms git-side excess that is its own `status` walk
    // and therefore GROWS with the tree.
    //
    // The removal is now this process's own, under `DepthSafeRemoval` and a
    // descriptor-captured container binding, with the filesystem re-proof
    // immediately before it. The row measured to the SAME endpoint — call →
    // first destruction — is 0.417 ms median (range 0.361–0.639 ms, n=10),
    // and it is the header table's `removefile` PROXY: a C harness, not this
    // code, and it includes a `fork` the production path does not do (PR
    // #460 codex r9, D4). THIS code's own last-proof → destruction interval
    // is 0.032 ms with the global pool saturated (permanent) and 0.004 ms
    // under 120 ms main-thread work items (Trash), which is the pair the
    // header quotes. See `removeUnderLastInstantProof`.
    //
    // Nothing about `--force` survives either: git's `--force`-less dirty
    // refusal was a free TOCTOU gate, and what replaces it is
    // `GitWorktreeCleanCheck` — the SAME `status --porcelain` git runs
    // internally — as the last git call, now with `--ignored` (D2), which
    // git's own refusal does not have.

    /// `git -C <parent> rev-parse --path-format=absolute --git-common-dir` —
    /// the delete-time question "which repository is this `-C` target
    /// actually about?".
    ///
    /// READ-ONLY by D17 classification (`rev-parse` is in
    /// `GitSafetyProfile.readOnlyCommands`), so the read-only profile rides
    /// it with no change. `--path-format=absolute` needs git ≥ 2.31 and this
    /// epic's floor is 2.39.
    static func commonGitDirArguments(parentRepoWorkingDir: URL) -> [String] {
        [
            "-C", parentRepoWorkingDir.path, "rev-parse",
            "--path-format=absolute", "--git-common-dir",
        ]
    }

    // THERE IS NO `pruneArguments`, AND THAT IS THE POINT (PR #460 codex r1).
    // `git worktree prune` accepts no path, no id and no set — it
    // re-enumerates the admin container itself, AFTER this process has handed
    // control away, so no gate here can bind what it will remove. The
    // repository-level item removes exactly the admin directories it
    // disclosed, admitted, measured and registered
    // (`removeAdminDirectories`). D10's `--expire=now` job moved to where it
    // is now decided: the ORACLE listing pins
    // `-c gc.worktreePruneExpire=now` (`GitWorktreeOracle.listArguments`), so
    // prunability is answered by the oracle and the removal never depends on
    // git honouring an expire policy.

    // MARK: - Injected seams

    let pathGuard: PathGuard
    let provider: FileSystemIdentityProvider
    /// The producing scan session's container snapshot — delete-time
    /// admission is identity-bound to it (fn-3.4, R9).
    let snapshot: ContainerSnapshot
    let runner: any GitCommandRunning
    /// fn-5.1's SHARED oracle→admin mapper — the SAME implementation fn-5.5
    /// discloses with. A second mapping would let detection and execution
    /// disagree about which admin directories the removal destroys.
    let mapper: GitWorktreeAdminMapper
    /// The sizer, as a closure: tests inject a spy and assert ZERO calls on
    /// every refusal path (the admit-before-measure proof).
    let measure: (URL, DirectorySizer.Mode, Set<FileSystemIdentityProvider.Identity>) -> SizeReport
    /// Per-invocation git budget (see `deleteTimeGitTimeout`).
    let gitTimeout: TimeInterval
    /// The run's REQUESTED disposal mode. Only the CHECKOUT removal honours
    /// it (D16).
    let moveToTrash: Bool
    /// The RAW mover, answering WHERE IT LANDED — `nil` when the disposal
    /// would not say. It is never called directly: the removal reaches it
    /// only through `TrashDisposal.dispose(_:containedIn:provider:via:)`,
    /// which binds the leaf under the admitted container on both sides of it.
    ///
    /// IT RETURNS THE LANDING URL RATHER THAN TAKING THE BINDING (the shape
    /// `removeTree` below uses). The two seams differ because what they front
    /// differs: `removeTree` fronts the cleaner's own background-queue
    /// removal, so the proving lives in cleaner code and the binding has to
    /// travel to it; `trash` fronts `FileManager.trashItem`, a bare mover with
    /// no descriptor to give and nothing of its own to prove — so the proving
    /// happens HERE, where the binding and the provider already are, and the
    /// seam's only job is to say where the object went. Wrapping it at the
    /// injection site instead would put the proof in a closure that every
    /// test replaces, which is how a binding becomes a parameter nobody
    /// checks.
    ///
    /// IT TAKES A PROOF AS WELL AS A URL (PR #460 codex r6, D1). It is
    /// `TrashDisposal.Mover`: the seam must run the handed-in proof on the far
    /// side of whatever hop it performs, immediately before the move. The
    /// production seam hops to the main actor (`trashItem` requires it), and
    /// until r6 EVERY gate this file runs — the clean re-check, the ignored
    /// witness, the last-instant filesystem re-proof, the disposal's own leaf
    /// binding — sat on the near side of that hop, so the interval between the
    /// last of them and the move was the MAIN THREAD'S QUEUE DEPTH rather than
    /// the 0.674 ms this file used to publish. MEASURED through the production
    /// composition under 120 ms main-thread work items, n=5: median
    /// **175.736 ms** before, **0.004 ms** after.
    ///
    /// THE PERMANENT ARM HAS THE SAME SHAPE, AND IT IS THE SAME TYPE NOW
    /// (PR #460 codex r7, D1). r6 asserted here that "the permanent arm never
    /// had this shape — it hops to a global concurrent queue, and
    /// `DepthSafeRemoval` re-proves the container from a descriptor on the far
    /// side of that hop". The second clause is true and the first does not
    /// follow from it: WHAT `DepthSafeRemoval` re-proves is the ADMITTED
    /// PARENT and, when a leaf verdict exists, the leaf — never WHICH CHECKOUT
    /// this is, whether it is LOCKED, or whether HEAD MOVED, none of which are
    /// in that file's vocabulary. The permanent arm hops too, and until r7
    /// every one of those three propositions was last proved on the near side
    /// of that hop. `removeTree` therefore takes the same proof argument the
    /// mover does, and the two arms now re-prove the identical set at the
    /// identical distance from their own destruction.
    let trash: TrashDisposal.Mover
    /// The permanent-delete seam. It takes the container binding as a SECOND
    /// argument (fn-6 reconciliation) because the removal it fronts —
    /// `DepthSafeRemoval.remove` — proves the folder it opens against an
    /// identity captured from a descriptor BEFORE the hop onto its background
    /// queue. Passing the binding rather than deriving it inside the seam is
    /// what lets the capture happen at the point the ordering requires (see
    /// the removal's use site), not wherever the closure happens to run.
    ///
    /// AND A PROOF AS A THIRD (PR #460 codex r7, D1) — the same contract
    /// `TrashDisposal.Mover` states: run it on the far side of whatever hop
    /// you perform, immediately before the destruction, and destroy nothing if
    /// it throws. The production seam hops to `DispatchQueue.global`; see
    /// `testTheWindowsThatRemainAreMeasuredUnderLoadInBothArms` for what that
    /// hop measures under main-thread load and under a saturated global queue,
    /// and `testThePermanentArmRefusesACheckoutLockedInsideItsOwnHop` for the
    /// cell that goes red when the proof is deleted. (Both names were wrong
    /// when r7 wrote them — `grep -rn "func <name>" Tests` returned 0 for the
    /// two it printed; PR #460 codex r8, D3.)
    let removeTree: (
        URL, DepthSafeRemoval.AdmittedParent, LastInstantProof
    ) async throws -> Void
    /// The GENERALIZED per-scanner pre-delete revalidator seam (D9), bound to
    /// THIS item's authorization entry by the cleaner. It can only REFUSE,
    /// never widen admission.
    let revalidate: (ReclaimableItem) -> PreDeleteSeamRefusal?
    /// `logRefusal(label:tag:detail:)`, already bound to the item's label.
    let logRefusal: (_ tag: String, _ detail: String) -> Void
    /// `logCleanup(label:bytesFreed:)`, already bound to the item's label.
    let logCleaned: (_ bytesFreed: Int64) -> Void

    // MARK: - Entry point

    /// Reclaim ONE composite item. Never throws: every failure is a per-item
    /// error, exactly like the other actions' performers.
    func perform(
        item: ReclaimableItem,
        plan: GitWorktreeReclaimPlan,
        origin: URL,
        target: URL,
        registry: InodeAccountingRegistry
    ) async -> WorktreeReclaimOutcome {
        // (1) DELETE-TIME ADMISSION — before any measurement, before any git.
        let container: AdmittedContainer
        do {
            container = try pathGuard.admitContainer(origin, snapshot: snapshot)
            try pathGuard.validateRemovableItem(target, inside: container)
        } catch {
            return refusal(item, error, at: target)
        }
        // (2) The D13 traversal guard over every path this mode's git calls
        // will traverse — still before any measurement.
        do {
            try guardTraversal(admissionPaths(for: plan), inside: container)
        } catch {
            return refusal(item, error, at: target)
        }

        switch plan.mode {
        case .removeStaleWorktree:
            return await removeStaleWorktree(
                item: item, plan: plan, origin: origin,
                container: container, registry: registry
            )
        case .pruneOrphanedAdmin:
            return await pruneOrphanedAdmin(
                item: item, plan: plan, container: container, registry: registry
            )
        }
    }

    // MARK: - Stale-worktree removal

    private func removeStaleWorktree(
        item: ReclaimableItem,
        plan: GitWorktreeReclaimPlan,
        origin: URL,
        container: AdmittedContainer,
        registry: InodeAccountingRegistry
    ) async -> WorktreeReclaimOutcome {
        // The shape `GitWorktreeReclaimPlan.violation` already refused at two
        // independent sites; re-deriving it here rather than force-unwrapping
        // keeps the destructive path fail-closed on its own.
        guard let worktreePath = plan.worktreePath,
              let adminEntry = plan.worktreeAdminEntry else {
            return failure(
                item,
                "refused: a stale-removal plan reached execution without its "
                    + "worktree path and admin entry — nothing was reclaimed",
                tag: "malformed-item"
            )
        }

        // (3) MEASURE — only now, after admission passed.
        let report = measure(
            worktreePath, .deletionTarget, await registry.knownIdentities
        )
        // (4) Mount doctrine (`removeGuardedItem` parity): a boundary at the
        // target or nested anywhere beneath it refuses the deletion — the
        // removal would recurse straight through an inner mount.
        if let boundary = report.mountBoundaries.first {
            let detail = "\(worktreePath.path): mount boundary at "
                + "\(boundary.path) — refused, not deleted"
            logRefusal("mount_boundary", detail)
            return failure(item, detail, tag: nil)
        }

        // (5) The revalidator seam — after admission/containment/mount (a
        // revalidation must never inspect a path this performer would refuse
        // to touch) and before ANY registration or mutation, in BOTH modes.
        if let seamRefusal = revalidate(item) {
            logRefusal(seamRefusal.tag, seamRefusal.reason)
            return WorktreeReclaimOutcome(entry: nil, errors: [
                CacheCleaner.itemError(
                    item, seamRefusal.reason, refusal: seamRefusal.payload
                ),
            ])
        }

        // (6) REGISTER before git runs (R8 phase 1).
        let token = await registry.registerObservations(report.claims)

        // (7) The guard re-runs over the three paths the gates below and the
        // removal itself traverse: the PARENT (the registry re-read runs
        // `-C <parent>`), the WORKTREE (the ancestry rung and the clean
        // re-check run `-C <wt>`) and the ADMIN CONTAINER (`<wt>/.git` points
        // INTO it, so `git -C <wt> …` is redirected by a swap in either).
        do {
            try guardTraversal([
                (label: "parent repository", url: plan.parentRepoWorkingDir,
                 containment: .descendantOrEqual),
                (label: "worktree", url: worktreePath,
                 containment: .strictDescendant),
                (label: "admin container", url: plan.parentAdminContainer,
                 containment: .strictDescendant),
            ], inside: container)
        } catch {
            return refusal(item, error, at: worktreePath)
        }

        // (8) THE DELETE-TIME GATE RE-ESTABLISHMENT — R0/R1/R1b/R2, and the
        // HEAD witness R2's answer is conditioned on. It runs its OWN D13
        // guards, per invocation group (PR #460 codex r2), because the guard
        // at (7) is a PATH check and cannot bind what a subprocess spawned
        // later resolves.
        let head: HeadWitness?
        let ignoredWitness: Set<String>
        switch await reestablishStaleGates(
            plan: plan, worktreePath: worktreePath, adminEntry: adminEntry,
            container: container
        ) {
        case .refuse(let tag, let detail):
            return failure(item, detail, tag: tag)
        case .proceed(let witness, let ignored):
            head = witness
            ignoredWitness = ignored
        }

        // (9) THE REMOVAL — G2 last, the filesystem re-proof after it, and the
        // unlink immediately after that. See `removeUnderLastInstantProof`
        // and the "WHO REMOVES THE TREE" section of the file header for why
        // `git worktree remove` is no longer the thing that does it.
        return await removeUnderLastInstantProof(
            item: item, plan: plan, origin: origin, container: container,
            worktreePath: worktreePath, adminEntry: adminEntry,
            registry: registry, token: token, head: head,
            ignoredWitness: ignoredWitness
        )
    }

    /// Re-check CLEAN as the LAST gate, re-prove from the filesystem at the
    /// last instant, then remove the tree under the `removeGuardedItem`
    /// doctrine, then run the GATED prune of its own admin entry.
    ///
    /// The caller has already run the (7) guard and (8) `reestablishStaleGates`
    /// and hands the HEAD witness down; this function owns everything from G2
    /// to the entry.
    private func removeUnderLastInstantProof(
        item: ReclaimableItem,
        plan: GitWorktreeReclaimPlan,
        origin: URL,
        container: AdmittedContainer,
        worktreePath: URL,
        adminEntry: URL,
        registry: InodeAccountingRegistry,
        token: RegisteredChild,
        head: HeadWitness?,
        ignoredWitness: Set<String>
    ) async -> WorktreeReclaimOutcome {
        // The guarded removal, `removeGuardedItem`'s doctrine
        // verbatim: TOCTOU re-admission immediately pre-delete, then the
        // trash toggle (a trash failure is an error, NEVER a fall-through to
        // a permanent delete).
        do {
            // WHICH FOLDER THIS DISPOSAL WILL OPEN, bound from a descriptor —
            // fn-6's doctrine, and its ORDERING verbatim (see the item path in
            // CacheCleaner): taken FIRST, before the rechecks below, because
            // everything after the capture is what the binding covers; taken
            // last it would cover only the hop onto the removal's background
            // queue. Nothing else here binds that folder — `admitContainer`
            // binds the container ROOT and the worktree is a strict descendant
            // of it. It fails closed and costs nothing to do so: the removal
            // performs the identical open a moment later.
            //
            // BOTH DISPOSALS USE IT. It was captured for the permanent one
            // alone and the Trash one — the GUI's default, `moveToTrash` is
            // `true` out of the box — handed the mover a bare URL beside it,
            // which made this the one deletion path in the app with no
            // container binding (fn-5/fn-6 reconciliation). The ordering the
            // capture already had is the ordering Trash needs: the binding
            // covers the two rechecks below, not merely the seam call.
            let admittedParent = try DepthSafeRemoval.admittedParent(
                directory: worktreePath.deletingLastPathComponent(),
                displayPath: worktreePath.path, provider: provider
            )
            let recheck = try pathGuard.admitContainer(origin, snapshot: snapshot)
            try pathGuard.validateRemovableItem(worktreePath, inside: recheck)

            // G2 IS THE LAST GIT CALL, and this ordering is the whole point
            // (PR #460 codex r3).
            //
            // Until r3 the clean re-check ran BEFORE `reestablishStaleGates`,
            // so between "this tree is clean" and "delete this tree" sat FIVE
            // git subprocesses (`rev-parse --git-common-dir`, `worktree list`,
            // `symbolic-ref`, `rev-parse --verify`, `merge-base`) plus two
            // path re-admissions. MEASURED: a file written into the worktree
            // in that window was destroyed and the performer returned a
            // SUCCESS entry with `errors == []` and no warning. The comment
            // above the gate re-establishment made exactly this argument for
            // R0/R1/R2 — "Running the same check only before `worktree
            // remove` would leave the window between that check and this
            // delete open" — and never applied it to G2.
            //
            // G2 is now the last SUBPROCESS before the disposal; only the
            // filesystem re-proof below, which spawns nothing, sits between
            // it and the unlink. `status` is a read, not a lock, so a write
            // landing after it answers is not seen — that residual is stated
            // in "What is left, measured", not described as closed.
            //
            // AND IT IS THE GATE THAT REPLACES GIT'S OWN (PR #460 codex r5).
            // `git worktree remove` without `--force` refuses a dirty tree by
            // running the same `status --porcelain` internally. Since the
            // removal is no longer git's, this call is that refusal — and
            // `--ignored` makes it see MORE than git's does (D2).
            //
            // The guard re-runs here for the same reason it runs at entry:
            // `git -C <wt> status` follows `<wt>/.git` INTO the admin
            // container, and the entry guard is now separated from this
            // invocation by the gate re-establishment's five subprocesses.
            // The parent is not re-guarded — this invocation does not
            // traverse it.
            try guardTraversal([
                (label: "worktree", url: worktreePath,
                 containment: .strictDescendant),
                (label: "admin container", url: plan.parentAdminContainer,
                 containment: .strictDescendant),
            ], inside: container)

            // ONE implementation of the clean check, shared with the G2 gate
            // (fn-5.2) — the scan and the deletion can never disagree about
            // what "clean" means. Its verdict is TOTAL over the runner's four
            // classes, and `.failed` is deliberately distinct from `.dirty`
            // so the abort wording can differ.
            //
            // THE REFUSAL THIS ORDERING INTRODUCES IS RETRYABLE. A tree that
            // was clean at scan time and dirty by the time the gates finished
            // refuses instead of being deleted. That is a fact about a
            // CONCURRENT WRITER, not a fixed property of the input: stop the
            // writer (or commit/stash the work), re-scan, and the same item
            // can succeed. It is the opposite of a deterministic bound, which
            // no re-scan can ever clear.
            let reading = await GitWorktreeCleanCheck.read(
                worktreeAt: worktreePath, using: runner, timeout: gitTimeout
            )
            guard let ignoredNow = reading.ignoredPaths else {
                let detail = Self.uncleanDetail(reading.verdict)
                logRefusal(Self.uncleanTag(reading.verdict), detail)
                return failure(item, detail, tag: nil)
            }

            // D2, THE OTHER HALF OF THE LAST GATE. A path that appeared in
            // the ignored set while the gates ran is work `--porcelain`
            // cannot see and this removal would destroy without a word.
            let appeared = ignoredNow.subtracting(ignoredWitness).sorted()
            if let first = appeared.first {
                let more = appeared.count > 1
                    ? " and \(appeared.count - 1) more" : ""
                let detail = "aborted: a file your `.gitignore` hides appeared "
                    + "in this worktree while the delete-time checks were "
                    + "running (\(first)\(more)) — `git status` reports "
                    + "nothing about ignored paths, so removing the tree "
                    + "would have destroyed it silently. The tree was left "
                    + "untouched. Move that work out of the worktree, or "
                    + "re-scan and remove again once you are done with it."
                logRefusal("worktree-ignored-appeared", detail)
                return failure(item, detail, tag: nil)
            }

            // THE LAST INSTANT (PR #460 codex r4), and since r5 it is the
            // last thing that runs before the ONLY unlink there is.
            //
            // r3 made G2 the last GATE, which narrowed the window from five
            // subprocesses to one. It did not close it, and it moved the
            // propositions rather than closing any: R1b — WHICH checkout this
            // is — then sat FIVE subprocesses before the delete. MEASURED at
            // r3: with a `git worktree remove` + `git worktree add` at the
            // same path staged on the clean re-check, this arm destroyed a
            // brand-new checkout plus a `secret.env` hidden by a committed
            // `.gitignore`, returned `Entry(exactBytes: 49152, .permanent,
            // warning: nil)` and `errors == []`, and the gated prune then
            // deregistered the new checkout as well.
            //
            // The file header's claim that "the order is safe both ways round
            // for R0/R1/R2 — they read the PARENT's porcelain record, which
            // the worktree's own contents cannot change" left R1b out of its
            // enumeration, and R1b is the one gate that reads
            // `<worktree>/.git` — a fact the worktree's own contents CAN
            // change. Its conclusion, "what remains is the disposal call
            // itself", was measured false; it is true only from HERE.
            if case .refuse(let tag, let detail) = reproveFromTheFilesystem(
                worktreePath: worktreePath, adminEntry: adminEntry,
                carriedIdentity: plan.worktreeAdminEntryIdentity, head: head
            ) {
                logRefusal(tag, detail)
                return failure(item, detail, tag: tag)
            }

            if moveToTrash {
                // NO LEAF VERDICT, WHICH IS THE POPULATION THIS OVERLOAD IS
                // FOR: `git_worktrees` registers no `PreDeleteRevalidator`, so
                // there is nothing to bind the leaf's CONTENTS to — but there
                // is an admitted container, and a leaf read under a proved
                // container descriptor is a fact about an OBJECT. The disposal
                // binds it before the move, re-reads it where the mover says
                // it landed, and PUTS BACK anything it cannot prove: no entry,
                // no bytes.
                //
                // AND THE RE-PROOF CROSSES THE MOVER'S HOP WITH IT (PR #460
                // codex r6, D1). `reproveFromTheFilesystem` ran a few lines
                // up, on THIS side of a seam that hops to the main actor
                // before it moves anything — so the interval between the last
                // gate and the destruction was the main thread's queue depth,
                // not the 0.674 ms this file published. It is re-run HERE, in
                // the closure the seam is contractually required to call
                // immediately before the move, together with the disposal's
                // own leaf binding. Identity first, then the leaf: the same
                // order `reproveFromTheFilesystem` gives its own steps, with
                // the binding the mover acts on left closest to the move.
                try await TrashDisposal.dispose(
                    worktreePath, containedIn: admittedParent,
                    provider: provider,
                    via: { url, proveTheLeaf in
                        try await trash(url) {
                            if case .refuse(let tag, let detail) =
                                reproveFromTheFilesystem(
                                    worktreePath: worktreePath,
                                    adminEntry: adminEntry,
                                    carriedIdentity:
                                        plan.worktreeAdminEntryIdentity,
                                    head: head
                                )
                            {
                                throw LastInstantRefusal(
                                    tag: tag, detail: detail
                                )
                            }
                            try proveTheLeaf()
                        }
                    }
                )
            } else {
                // THE SAME RE-PROOF, ON THE FAR SIDE OF THIS ARM'S OWN HOP
                // (PR #460 codex r7, D1). `removeItemConcurrently` hops to
                // `DispatchQueue.global` and `DepthSafeRemoval` then re-proves
                // the ADMITTED PARENT from a descriptor — which is the
                // container, not the checkout. Which checkout this is, whether
                // it is locked and whether HEAD moved are not propositions
                // that file can express, so until r7 all three were last
                // proved on the near side of the hop while the Trash arm's
                // were proved on the far side. Same closure, same order, same
                // refusal type as the mover's above: the two arms differ only
                // in what performs the destruction.
                try await removeTree(
                    worktreePath, admittedParent,
                    LastInstantProof {
                        if case .refuse(let tag, let detail) =
                            reproveFromTheFilesystem(
                                worktreePath: worktreePath,
                                adminEntry: adminEntry,
                                carriedIdentity:
                                    plan.worktreeAdminEntryIdentity,
                                head: head
                            )
                        {
                            throw LastInstantRefusal(tag: tag, detail: detail)
                        }
                    }
                )
            }
        } catch let refusal as LastInstantRefusal {
            // The re-proof that crosses either arm's hop reports through the
            // SAME tag and the SAME detail as the one on this side of it — a
            // user must not be able to tell which of the two fired, because
            // the fact they state is identical.
            //
            // ONE LOG LINE, NOT TWO (PR #460 codex r7, D3). r6 shipped an
            // explicit `logRefusal(refusal.tag, refusal.detail)` here AND
            // `failure(…, tag:)` below, which logs whenever a tag is present:
            // every refusal raised inside a seam was written to
            // `~/.cacheout` twice. Nothing asserted on the log, so nothing
            // caught it — the same gap that left this catch arm itself
            // unevidenced. `failure` is the one place that logs.
            return failure(item, refusal.detail, tag: refusal.tag)
        } catch {
            if error is PathGuardError {
                logRefusal(
                    CacheCleaner.refusalTag(error),
                    "\(worktreePath.path): \(error.localizedDescription)"
                )
            }
            // Nothing accepted — the registrations stay transferable.
            return failure(item, error.localizedDescription, tag: nil)
        }

        // The SAME pre-registered token — never measured or registered twice.
        let accepted = await registry.acceptSuccessful(token)
        let warning = await gatedPostRemovalPrune(
            plan: plan, container: container, adminEntry: adminEntry
        )
        logCleaned(accepted.exactBytes + accepted.estimatedUpToBytes)
        return WorktreeReclaimOutcome(
            entry: entry(
                for: item, accepted: accepted,
                // D16: `.trash` ONLY because the handler actually succeeded
                // above — the throwing path returned before reaching here.
                disposal: moveToTrash ? .trash : .permanent,
                warning: warning
            ),
            errors: []
        )
    }

    /// The GATED post-removal prune (epic round 8 / D14). Returns the D11
    /// warning to attach to the SUCCESS entry, or nil when nothing was left
    /// behind.
    ///
    /// An UNCONDITIONAL repo-wide prune here would sweep OTHER pre-existing
    /// prunable admin directories this stale item never disclosed — the exact
    /// undisclosed side-effect set D14 forbids. So the prunable set is
    /// recomputed and the SCOPED removal runs ONLY when that set is EXACTLY
    /// the just-deleted worktree's own admin entry.
    ///
    /// EVERY failure class here is a WARNING, never an error: the bytes are
    /// already freed and the deletion already succeeded (D11) — and the next
    /// scan's repo-level prune tier is what reclaims the leftover metadata.
    private func gatedPostRemovalPrune(
        plan: GitWorktreeReclaimPlan,
        container: AdmittedContainer,
        adminEntry: URL
    ) async -> String? {
        let recomputed: [URL]
        switch await recomputePrunableSet(plan: plan, container: container) {
        case .set(let directories):
            recomputed = directories
        case .failed(let reason):
            return warning("the prune set could not be recomputed (\(reason))")
        }

        if recomputed.isEmpty {
            // Nothing is prunable. That is the honest no-op UNLESS the admin
            // entry is still on disk (a locked entry is excluded from the
            // prunable set by the mapper, which since the repo-wide prune was
            // retired is the ONLY thing that excludes it — D6) — claiming
            // "orphaned admin data remains" when the directory is gone would
            // be the mirror-image lie.
            guard provider.probeKind(of: adminEntry) != .absent else { return nil }
            return warning(
                "the just-deleted worktree's admin entry "
                    + "\(adminEntry.path) is not prunable"
            )
        }
        guard recomputed.count == 1,
              Self.samePath(recomputed[0], adminEntry) else {
            return warning(
                "the recomputed prunable set is not exactly this worktree's "
                    + "admin entry (\(recomputed.map(\.path).joined(separator: ", "))) "
                    + "— removing it would have swept admin data this item "
                    + "never disclosed"
            )
        }

        // The guard re-runs over both paths the scoped removal covers.
        do {
            try guardTraversal(prunePaths(for: plan), inside: container)
        } catch {
            return warning(
                "the pre-prune traversal guard refused "
                    + "(\(error.localizedDescription))"
            )
        }

        // R0 again — the recompute above asked `-C <parent>` which entries
        // are prunable, so the repository that answered must still be the one
        // whose admin data this plan carries. A WARNING, not an error: the
        // bytes are already freed and the deletion already succeeded (D11).
        if case .refuse(_, let detail) =
            await reestablishParentRepository(plan: plan) {
            return warning(detail)
        }

        // The SCOPED removal (PR #460 codex r1 / C4), over the one directory
        // the gate above proved this set to be. A repo-wide `worktree prune`
        // here would re-enumerate the container after the gate and could
        // sweep a sibling that vanished in between — exactly what the
        // "exactly this worktree's admin entry" gate above exists to prevent.
        if let refusal = await removeAdminDirectories(recomputed) {
            return warning(refusal.detail)
        }
        return nil
    }

    // MARK: - Prune-only mode (repository-level, D14)

    private func pruneOrphanedAdmin(
        item: ReclaimableItem,
        plan: GitWorktreeReclaimPlan,
        container: AdmittedContainer,
        registry: InodeAccountingRegistry
    ) async -> WorktreeReclaimOutcome {
        // (3) FIRST recompute — the oracle re-run whose result must be a
        // SUBSET of what the scan disclosed.
        let recomputed: [URL]
        switch await recomputePrunableSet(plan: plan, container: container) {
        case .set(let directories):
            recomputed = directories
        case .failed(let reason):
            let detail = "refused: the prunable set could not be recomputed at "
                + "clean time (\(reason)) — nothing was pruned"
            logRefusal("prune-recompute-failed", detail)
            return failure(item, detail, tag: nil)
        }

        let disclosed = Set(plan.disclosedAdminDirectories.map(Self.standardPath))
        for directory in recomputed where !disclosed.contains(Self.standardPath(directory)) {
            let detail = "refused: prune set changed since scan — re-scan "
                + "required (\(directory.path) was never disclosed); nothing "
                + "was pruned"
            logRefusal("prune-set-changed", detail)
            return failure(item, detail, tag: nil)
        }

        // (4) ADMIT each RECOMPUTED directory, THEN measure it — per dir, in
        // that order (F3). Measurement is delete-time and over the RECOMPUTED
        // set, never the scan-time disclosed measures.
        var measured: [(directory: URL, report: SizeReport)] = []
        for directory in recomputed {
            do {
                try admitAffectedAdminDirectory(directory, inside: container)
            } catch {
                let detail = "refused: affected admin directory "
                    + "\(directory.path) failed re-admission "
                    + "(\(error.localizedDescription)) — nothing was pruned"
                logRefusal(CacheCleaner.refusalTag(error), detail)
                return failure(item, detail, tag: nil)
            }
            let report = measure(
                directory, .deletionTarget, await registry.knownIdentities
            )
            // (5) MOUNT DOCTRINE (epic round 9): the removal is a
            // RECURSIVE filesystem mutation over these directories, so the
            // boundary-bearing-recursive-delete rule applies exactly as it
            // does to `removeItem` — and it fails CLOSED here, BEFORE any
            // claim is registered and before the removal runs. The D13 guard
            // checks the leaf and the device; only the sizer can see a
            // boundary NESTED inside.
            if report.rootMountBoundary || !report.mountBoundaries.isEmpty {
                let boundary = report.mountBoundaries.first ?? directory
                let detail = "refused: mount boundary at \(boundary.path) "
                    + "inside affected admin directory \(directory.path) — "
                    + "nothing was pruned"
                logRefusal("mount_boundary", detail)
                return failure(item, detail, tag: nil)
            }
            measured.append((directory, report))
        }

        // (6) The revalidator seam — same position as stale mode: after every
        // admission/measurement/mount gate, before any registration.
        if let seamRefusal = revalidate(item) {
            logRefusal(seamRefusal.tag, seamRefusal.reason)
            return WorktreeReclaimOutcome(entry: nil, errors: [
                CacheCleaner.itemError(
                    item, seamRefusal.reason, refusal: seamRefusal.payload
                ),
            ])
        }

        // (7) PER-DIR claims, registered only once every directory passed.
        var registered: [(directory: URL, token: RegisteredChild)] = []
        for measurement in measured {
            registered.append((
                measurement.directory,
                await registry.registerObservations(measurement.report.claims)
            ))
        }

        // (8) The SECOND oracle check (epic round 8), IMMEDIATELY before the
        // mutation: the admission and sizing walks above take time, and an
        // orphan that appeared DURING them would be removed outside every set
        // this item ever checked. Shrinkage stays legal — verified-removal
        // accounting already handles a survivor — and what is REMOVED is this
        // final set, never the earlier one (PR #460 codex r1 / C4): removing
        // a directory the last check no longer calls prunable is exactly the
        // hazard this check exists to name.
        let checked = Set(recomputed.map(Self.standardPath))
        let removalSet: [URL]
        switch await recomputePrunableSet(plan: plan, container: container) {
        case .failed(let reason):
            let detail = "refused: the final pre-prune prunable-set check "
                + "could not be completed (\(reason)) — nothing was pruned"
            logRefusal("prune-final-check-failed", detail)
            return failure(item, detail, tag: nil)
        case .set(let finalSet):
            for directory in finalSet where !checked.contains(Self.standardPath(directory)) {
                let detail = "refused: the prunable set GREW between "
                    + "measurement and execution (\(directory.path) appeared) "
                    + "— re-scan required; nothing was pruned"
                logRefusal("prune-set-grew", detail)
                return failure(item, detail, tag: nil)
            }
            for directory in finalSet {
                do {
                    try admitAffectedAdminDirectory(directory, inside: container)
                } catch {
                    let detail = "refused: affected admin directory "
                        + "\(directory.path) failed the final re-admission "
                        + "(\(error.localizedDescription)) — nothing was pruned"
                    logRefusal(CacheCleaner.refusalTag(error), detail)
                    return failure(item, detail, tag: nil)
                }
            }
            removalSet = finalSet
        }

        // (9) The guard re-runs over the paths the removal traverses.
        do {
            try guardTraversal(prunePaths(for: plan), inside: container)
        } catch {
            return refusal(item, error, at: plan.parentAdminContainer)
        }

        // (9b) R0 — the repository this item IS. A prune item's whole subject
        // is one repository's registry, so a `-C` target that now resolves
        // somewhere else means the recompute above answered about a
        // repository nobody was shown. The path gates cannot see that: a
        // planted `gitdir:` file redirects git while every leaf, canonical
        // spelling, containment and device check still passes.
        if case .refuse(let tag, let detail) =
            await reestablishParentRepository(plan: plan) {
            return failure(item, detail, tag: tag)
        }

        // (9c) THE SCOPED REMOVAL.
        if let refusal = await removeAdminDirectories(removalSet) {
            logRefusal(refusal.tag, refusal.detail)
            return failure(item, refusal.detail, tag: nil)
        }

        // (10) VERIFIED-REMOVAL acceptance: only directories that actually
        // disappeared contribute bytes.
        var accepted = AcceptedByteComponents()
        for claim in registered
        where provider.probeKind(of: claim.directory) == .absent {
            let components = await registry.acceptSuccessful(claim.token)
            accepted.exactBytes += components.exactBytes
            accepted.estimatedUpToBytes += components.estimatedUpToBytes
        }
        logCleaned(accepted.exactBytes + accepted.estimatedUpToBytes)
        // A success entry is emitted EVEN at zero accepted bytes: the
        // execution must stay reportable, never a silent row-less success.
        // Disposal is `.permanent` ALWAYS (D16) — prune is not a trash
        // operation. The D11 `warning` field is never used here: a prune-only
        // failure is an ERROR.
        return WorktreeReclaimOutcome(
            entry: entry(for: item, accepted: accepted, disposal: .permanent),
            errors: []
        )
    }

    // MARK: - The SCOPED admin-directory removal (PR #460 codex r1 / C4)

    /// Why this is a per-directory removal and not
    /// `git worktree prune --expire=now`.
    ///
    /// `worktree prune` takes no path, no id and no set: git RE-ENUMERATES
    /// `$GIT_COMMON_DIR/worktrees` itself, after this process has handed
    /// control away. Every gate above is therefore a SNAPSHOT comparison — it
    /// can reject a set git reported a moment ago, but it cannot bind the set
    /// git will compute later. A second registered checkout of the same
    /// repository that vanishes inside that window is swept undisclosed, and
    /// the accounting never notices: it iterates the REGISTERED directories,
    /// so the extra victim contributes no bytes, no row and no warning
    /// (measured end to end: `errors=[]`, a success entry, and the victim's
    /// detached-HEAD commit left unreachable).
    ///
    /// Removing exactly the directories this item admitted, measured,
    /// mount-gated and registered makes the disclosure true BY CONSTRUCTION
    /// rather than by timing. Equivalence to git's own effect was measured on
    /// git 2.50.1: two identically-built repositories, one pruned by git and
    /// one whose single orphan admin directory was removed directly, produced
    /// structurally IDENTICAL `.git` trees, identical `worktree list
    /// --porcelain`, identical branch lists, a clean `git fsck` on both, and a
    /// subsequent `worktree prune --expire=now` on the scoped repository was a
    /// silent no-op. (git also `rmdir`s an emptied `worktrees/`; leaving it is
    /// harmless — `worktree list`, `status`, `fsck` and a later `worktree add`
    /// all behave.)
    ///
    /// `--expire=now`'s D10 job survives the change: the ORACLE still lists
    /// with `-c gc.worktreePruneExpire=now`, so prunability is decided by the
    /// oracle and the removal no longer depends on git honouring an expire
    /// policy at all.
    ///
    /// The removal itself is `DepthSafeRemoval` through the cleaner's own
    /// seam, under a container binding captured from a DESCRIPTOR immediately
    /// before it — fn-6's primitive, not a hand-rolled deleter.
    private func removeAdminDirectories(
        _ directories: [URL]
    ) async -> (tag: String, detail: String)? {
        for directory in directories {
            if let revived = revivedCheckoutRefusal(for: directory) {
                return ("prune-checkout-revived", revived)
            }
            do {
                let admittedParent = try DepthSafeRemoval.admittedParent(
                    directory: directory.deletingLastPathComponent(),
                    displayPath: directory.path, provider: provider
                )
                // AND THE REVIVAL CHECK CROSSES THE HOP TOO (PR #460 codex r7,
                // D1). The near-side call a few lines up is the cheap refusal;
                // this one is the load-bearing one, because between them sits
                // `removeItemConcurrently`'s hop onto `DispatchQueue.global`
                // and a checkout repaired inside it is live state. It is the
                // SAME function, so the two readings cannot disagree about
                // what "revived" means.
                try await removeTree(
                    directory, admittedParent, LastInstantProof {
                        if let revived = revivedCheckoutRefusal(for: directory) {
                            throw LastInstantRefusal(
                                tag: "prune-checkout-revived", detail: revived
                            )
                        }
                    }
                )
            } catch let refusal as LastInstantRefusal {
                return (refusal.tag, refusal.detail)
            } catch {
                // A mid-loop failure leaves the directories already removed
                // genuinely gone. Their bytes are NOT reported: this returns
                // an error and no entry, which under-reports what was freed
                // rather than over-reporting it. (In practice the set is one
                // directory — the field shape and the only shape the gated
                // post-removal prune can ever have.)
                return (
                    CacheCleaner.refusalTag(error),
                    "refused: the orphaned admin directory \(directory.path) "
                        + "could not be removed (\(error.localizedDescription))"
                        + " — the registry may be PARTIALLY cleaned; re-scan."
                )
            }
        }
        return nil
    }

    /// PER-OBJECT re-establishment of the fact that made this directory
    /// prunable, one syscall before it is destroyed.
    ///
    /// An admin directory is prunable because its `gitdir` back-link names a
    /// `<worktree>/.git` that is not there. If a volume remounted, a backup
    /// was restored, or `git worktree repair` ran between the last oracle
    /// answer and this instant, the checkout is BACK and its per-worktree
    /// index, ORIG_HEAD, reflog and refs are live state.
    ///
    /// IT CAN ONLY ADD A REFUSAL, NEVER GRANT ONE. The authority that the
    /// entry is prunable remains the oracle, re-run twice above; every
    /// ambiguous reading here (an unreadable back-link, a `.git` of the wrong
    /// kind, a pointer that does not point back) proceeds, because refusing
    /// on them would strand the ordinary orphan classes git itself prunes for
    /// reasons other than "the checkout is gone" — a refusal a re-scan could
    /// never clear. Only a LIVE, mutually-consistent registration refuses.
    ///
    /// RETRY: yes, and it clears itself. A revived checkout is no longer
    /// prunable, so the next scan simply stops offering it.
    private func revivedCheckoutRefusal(for adminDirectory: URL) -> String? {
        let backlink = adminDirectory.appendingPathComponent("gitdir")
        guard let backlinkText = try? String(contentsOf: backlink, encoding: .utf8)
        else { return nil }
        guard let dotGit = Self.gitdirTarget(
            backlinkText, relativeTo: adminDirectory, prefixed: false
        ) else { return nil }
        guard provider.probeKind(of: dotGit) == .kind(.regularFile),
              let pointerText = try? String(contentsOf: dotGit, encoding: .utf8),
              let named = Self.gitdirTarget(
                  pointerText, relativeTo: dotGit.deletingLastPathComponent(),
                  prefixed: true
              ),
              provider.sameLocation(named, adminDirectory)
        else { return nil }
        return "refused: the checkout at "
            + "\(dotGit.deletingLastPathComponent().path) is registered again "
            + "and points back at \(adminDirectory.path) — it is no longer "
            + "orphaned, so nothing was pruned. Re-scan; a live worktree is "
            + "never offered here."
    }

    /// Read a worktree back-link. `prefixed` selects the `gitdir: <path>`
    /// spelling of a worktree's `.git` FILE; the admin directory's own
    /// `gitdir` file carries a bare path.
    private static func gitdirTarget(
        _ text: String, relativeTo base: URL, prefixed: Bool
    ) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefixed {
            guard trimmed.hasPrefix("gitdir:") else { return nil }
            trimmed = String(trimmed.dropFirst("gitdir:".count))
                .trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : base.appendingPathComponent(trimmed)
    }

    // MARK: - Delete-time gate re-establishment (PR #460 codex r1)

    /// What one re-establishment answered. There is no "could not tell that
    /// passes" arm anywhere below: every class that is not an affirmative
    /// re-proof is a refusal with its cause NAMED.
    enum GateReestablishment: Equatable {
        case proceed
        case refuse(tag: String, detail: String)
    }

    /// The re-read porcelain record, or the refusal that replaced it.
    private enum WorktreeRecordReestablishment {
        case record(GitWorktreeEntry)
        case refuse(tag: String, detail: String)
    }

    /// What the whole stale-mode re-establishment answered. It carries the
    /// HEAD WITNESS forward rather than just `proceed`, because the value of
    /// R2's answer at the last instant depends on HEAD not having moved
    /// since, and only the site that ran R2 can say what HEAD was then.
    private enum StaleGateReestablishment {
        /// `ignored` is the D2 witness: the worktree's IGNORED path set as it
        /// was when identity had just been proved and R2 had not yet run.
        case proceed(head: HeadWitness?, ignored: Set<String>)
        case refuse(tag: String, detail: String)
    }

    /// THE WHOLE STALE-MODE RE-ESTABLISHMENT, in scan order.
    ///
    /// fn-6 established, for the FILESYSTEM path, that every gate is
    /// re-established immediately before deletion from a HELD DESCRIPTOR and
    /// that the object destroyed is proved to be the object inspected. A
    /// `git` subprocess hands back no descriptor, so that shape cannot be
    /// copied verbatim. The equivalent guarantee for this substrate is to ask
    /// the SAME authority the scan asked, about the SAME repository, one
    /// subprocess before the mutation:
    ///
    /// - **R0 (repository identity)** re-resolves which repository the `-C`
    ///   target names and binds it to the git directory the plan carries —
    ///   the substrate's answer to "prove it is the same object", because git
    ///   resolves the repository from `<parent>/.git` and git is the only
    ///   authority on that resolution.
    /// - **R1 (G1 + G4 + registration)** re-reads the porcelain record and
    ///   re-runs the assessor's OWN gate functions over it. G1 and G4 are not
    ///   properties of file CONTENT — they are structured fields of the
    ///   record — so re-reading the record IS re-establishing them.
    /// - **R1b (WHICH worktree)** binds that record to the plan's carried
    ///   `worktreeAdminEntry` before the record is accepted. See
    ///   `reestablishWorktreeIdentity`.
    /// - **R2 (G3)** re-runs the shared `GitWorktreeMergedCheck`.
    ///
    /// Each step runs the D13 traversal guard over exactly the paths its own
    /// invocation group traverses (PR #460 codex r2). The caller's pre-remove
    /// guard covers the mutation's paths — parent and worktree — and NOT the
    /// admin container, which `worktree list` enumerates.
    ///
    /// G2 is deliberately absent from THIS function and is NOT an omission:
    /// it runs at the last possible instant instead (see below),
    /// and `removeUnderLastInstantProof` runs `GitWorktreeCleanCheck` itself
    /// as its last git call before it deletes anything. Every other scan-time
    /// gate is listed above.
    ///
    /// The "`git worktree remove` WITHOUT `--force`" half of that sentence is
    /// history as of r5/D1: no git removal runs, so the clean check IS the
    /// gate rather than a second opinion beside git's.
    ///
    /// EVERY refusal below is CLEARABLE — none keys on a deterministic limit,
    /// and each message names the action that clears it (this project has
    /// shipped a fail-closed refusal on a fixed cap whose printed remedy was
    /// "re-scan", which could never differ).
    ///
    private func reestablishStaleGates(
        plan: GitWorktreeReclaimPlan,
        worktreePath: URL,
        adminEntry: URL,
        container: AdmittedContainer
    ) async -> StaleGateReestablishment {
        // R0 traverses the `-C` target ONLY, and the caller guarded exactly
        // that path immediately before entering here — step (7), the ONE
        // pre-gates guard site since r5. NO extra guard is added:
        // it would be an unevidenced re-run of a check microseconds old, and
        // an unevidenced guard is a defect this project has shipped before.
        if case .refuse(let tag, let detail) =
            await reestablishParentRepository(plan: plan) {
            return .refuse(tag: tag, detail: detail)
        }

        // R1 IS DIFFERENT, and this guard is the one real gap PR #460 codex
        // r2 found: `worktree list` also ENUMERATES
        // `$GIT_COMMON_DIR/worktrees` to answer `prunable`, and the primary
        // arm's step-(7) guard covers only the parent and the worktree. The
        // admin container is a path this invocation traverses and nothing
        // between admission and here re-proves it.
        if case .refuse(let tag, let detail) = guardGroup(
            [parentGuardPath(plan), adminContainerGuardPath(plan)],
            inside: container, invocation: "the worktree-registry re-read"
        ) {
            return .refuse(tag: tag, detail: detail)
        }
        let record: GitWorktreeEntry
        switch await reestablishWorktreeRecord(
            plan: plan, worktreePath: worktreePath, adminEntry: adminEntry
        ) {
        case .refuse(let tag, let detail):
            return .refuse(tag: tag, detail: detail)
        case .record(let entry):
            record = entry
        }

        // THE HEAD WITNESS, TAKEN BEFORE R2 (PR #460 codex r4).
        //
        // R2 costs three subprocesses and cannot be repeated at the last
        // instant. What CAN be repeated for two `lstat`s and a read is the
        // question its answer depends on: is the same commit still checked
        // out? The witness is taken BEFORE the ladder runs, so the comparison
        // at the last instant spans the WHOLE R2→disposal window rather than
        // starting after it.
        //
        // There is deliberately NO second read after the ladder. One was
        // written and then removed as an unevidenced guard: MEASURED, with
        // the post-read disabled and a commit staged on the ancestry check,
        // the removal was still refused — by this same witness at the last
        // instant — and the only thing that changed was the wording. A guard
        // no cell can distinguish is one this project has shipped before.
        let captured = captureHead(adminEntry: adminEntry, record: record)


        // A DETACHED head with no usable witness is refused rather than
        // proceeded with, and this is the one place availability is spent on
        // purpose: on a branch, a commit made inside the window survives on
        // the branch ref, which no removal here touches; detached, it is
        // reachable from nothing once the admin directory's reflog goes with
        // the worktree. That loss is unrecoverable, so it is the one worth
        // refusing for. The refusal CLEARS — attach the HEAD to a branch and
        // re-scan, and the same worktree is judged with a witness available.
        if record.isDetached, let cause = Self.witnessAbsence(
            captured, adminEntry: adminEntry
        ) {
            return .refuse(
                tag: "worktree-head-unwitnessable",
                detail: "refused: this worktree is on a DETACHED HEAD and its "
                    + "HEAD cannot be re-read from the filesystem (\(cause)), "
                    + "so a commit made while the delete-time checks run "
                    + "could not be detected — and a commit removed with a "
                    + "detached worktree is reachable from no ref at all. "
                    + "Nothing was removed. Put that work on a branch "
                    + "(`git -C \(worktreePath.path) switch -c <name>`), then "
                    + "re-scan."
            )
        }

        // THE IGNORED WITNESS, TAKEN IN THE SAME PLACE AND FOR THE SAME
        // REASON (PR #460 codex r5, D2).
        //
        // `status --porcelain` reports NOTHING about a path a committed
        // `.gitignore` hides, so through r4 the last gate could not see one.
        // MEASURED BY THE r5 REVIEW at c8ab723 (their figures, carried here
        // as the defect this closes): `secret.env` written into the gate
        // window was destroyed with the tree under `Entry(exactBytes: 49152,
        // .permanent, warning: nil)` and `errors == []`, while the same
        // fixture with a NON-ignored file refused with "the delete-time
        // re-check found it DIRTY". `docs/v1/CATEGORIES.md:519` said "work
        // saved while the checks were running is caught rather than
        // destroyed", which was false for exactly that file.
        //
        // What this round measured for itself is the FIX, not the defect:
        // `testAnIgnoredFileThatAppearsInTheGateWindowIsNotDestroyed` stages
        // the same write and goes RED when the comparison is removed.
        //
        // WHY HERE AND NOT EARLIER. It is a reading OF A PATH, and this
        // file's own doctrine is that a reading through a path means nothing
        // until the path's identity is settled — the same argument
        // `reproveFromTheFilesystem` makes for putting identity ahead of the
        // lock and HEAD. R0, R1 and R1b have answered by this line; R2's
        // three-subprocess ladder and the disposal-time re-admissions have
        // not, and that is the window this witness spans (MEASURED at r4:
        // R1b-done → destructive call, median 56.9 ms of the ~78 ms total).
        //
        // What is compared is the SET of ignored paths, never their contents:
        // a path that APPEARED refuses, a path that was already there does
        // not. That is the only rule compatible with the product — an ignored
        // build tree is what this scanner exists to reclaim.
        let witnessReading = await GitWorktreeCleanCheck.read(
            worktreeAt: worktreePath, using: runner, timeout: gitTimeout
        )
        guard let ignoredWitness = witnessReading.ignoredPaths else {
            return .refuse(
                tag: Self.uncleanTag(witnessReading.verdict),
                detail: Self.uncleanDetail(witnessReading.verdict)
            )
        }

        // R2's ladder runs `-C <parent>` and its ancestry runs
        // `-C <worktree>` — the two paths the caller guarded on entry, and
        // no others. Same reasoning as R0: no extra guard.
        if case .refuse(let tag, let detail) = await reestablishAncestry(
            plan: plan, worktreePath: worktreePath, record: record
        ) {
            return .refuse(tag: tag, detail: detail)
        }

        guard case .witness(let witness) = captured else {
            // ATTACHED, and HEAD is not witnessable from the filesystem. The
            // ancestry residual for this item is then the whole R2→disposal
            // window; see "What is left, measured".
            return .proceed(head: nil, ignored: ignoredWitness)
        }
        return .proceed(head: witness, ignored: ignoredWitness)
    }

    /// Why a capture is not a witness, or nil when it IS one.
    private static func witnessAbsence(
        _ capture: HeadWitnessCapture, adminEntry: URL
    ) -> String? {
        let headFile = adminEntry.appendingPathComponent(headFileName)
        let stack = adminEntry.appendingPathComponent(reftableStackPath)
        switch capture {
        case .witness:
            return nil
        case .unreadable:
            return "neither \(headFile.path) nor \(stack.path) is a readable "
                + "regular file"
        case .uncorroborated(let live, let expected):
            // NOT "this backend keeps no HEAD file" — CHANGELOG.md:80-81 and
            // CATEGORIES.md:540-541 said that at r4 and it is false (D6):
            // MEASURED on git 2.50.1, `git init --ref-format=reftable` +
            // `git worktree add --detach` leaves `<admin>/HEAD` present as a
            // regular file reading `ref: refs/heads/.invalid`, byte- and
            // inode-identical across a detached commit, while porcelain
            // reports a real SHA. The file is present and re-readable; what
            // fails is CORROBORATION.
            return "\(headFile.path) reads '\(live)' while git reports HEAD "
                + "as '\(expected)', so that file is not tracking HEAD, and "
                + "\(stack.path) — the per-worktree ref stack that would "
                + "witness it instead — is not a readable regular file either"
        }
    }

    // MARK: - What is left, measured

    // WHAT IS LEFT, MEASURED — the honest half of the last-instant re-proof
    // (PR #460 codex r4).
    //
    // `reproveFromTheFilesystem` closes every proposition the filesystem can
    // answer. These are the ones it cannot, stated rather than described as
    // closed:
    //
    // 1. **CLEANLINESS (G2).** `git status --porcelain` is the only faithful
    //    answer — the index, `.gitignore` rules, submodules and skip-worktree
    //    entries are not readable from metadata — so it stays a subprocess
    //    and stays the LAST git call.
    //
    //    AND IT DOES NOT CROSS EITHER ARM'S HOP (PR #460 codex r7, D2). The
    //    two disposal seams run a proof on the far side of their hops; that
    //    proof is `reproveFromTheFilesystem`, which spawns nothing, and a
    //    `fork`/`exec` cannot be put there — on the Trash arm the far side is
    //    the MAIN ACTOR. So this proposition's interval is NOT the 0.004 ms /
    //    0.032 ms the identity, lock and HEAD propositions enjoy: it is the
    //    disposal queue's depth. MEASURED under load through the production
    //    composition by
    //    `testTheWindowsThatRemainAreMeasuredUnderLoadInBothArms`:
    //    permanent arm with the global pool saturated microseconds before the
    //    hop, median **241.156 ms** (240.360–249.808, n=3); Trash arm with
    //    120 ms main-thread work items, median **185.864 ms**
    //    (185.785–186.442, n=5). On an unloaded queue the same intervals are
    //    0.269 ms and 0.674 ms.
    //
    //    WHAT THAT COSTS, PLAINLY: work saved into the worktree after
    //    `status` answered and before the disposal ran is destroyed with the
    //    tree, and under a loaded queue that interval is hundreds of
    //    milliseconds rather than a fraction of one.
    //
    //    `--ignored` DOES NOT NARROW THAT WINDOW, and r7 said it did (PR
    //    #460 codex r8, D4). The ignored comparison is `appeared =
    //    ignoredNow.subtracting(ignoredWitness)`
    //    (`WorktreeReclaimPerformer.swift:818-830`), computed from the SAME
    //    `status --ignored` reading this proposition is about, and taken
    //    BEFORE `reproveFromTheFilesystem`,
    //    i.e. entirely on the NEAR side of both hops. Nothing re-reads the
    //    ignored set after it, and nothing can: the far side of the Trash
    //    arm's hop is the MAIN ACTOR, which is the same reason this
    //    proposition cannot cross the hop at all. What `--ignored` narrows
    //    is the window BEFORE that reading — the interval the gates
    //    themselves take, where `--porcelain` alone is blind and this
    //    comparison refuses. The post-reading window is the same width for
    //    an ignored file as for a tracked one.
    //
    //    A re-scan clears the residual, because it is a fact about a
    //    concurrent writer and not a deterministic bound.
    //
    //    MEASURED TO THE UNLINK, INSTRUMENTED, ON AN IDLE MAIN THREAD,
    //    through the production composition (`CacheCleaner` wiring
    //    `DepthSafeRemoval` / `TrashDisposal`; the last git completion BEFORE
    //    the unlink against a watcher spinning on `lstat` until ENOENT):
    //    permanent arm median **0.373 ms** (0.315–0.565, n=10), Trash arm
    //    median **0.674 ms** (0.588–16.152, n=10). r4 published 0.163 ms and
    //    0.173 ms for this, but measured to the `worktree remove` SPAWN and
    //    to the disposal CALL — not to the destruction. Measured to the
    //    destruction, r4's primary arm was 14.87 ms on a one-file worktree
    //    and 156.8 ms on a 2001-file one.
    //
    //    THE TRASH ROW'S SPREAD IS MAIN-THREAD SCHEDULING, NOT THE MOVER
    //    (PR #460 codex r6, D2) — see "WHO REMOVES THE TREE" for the
    //    correction and the under-load figures (median 175.736 ms with the
    //    proof on r5's side of the mover's hop, 0.004 ms with it moved
    //    across, n=5 each).
    // 2. **ANCESTRY WHEN HEAD DID NOT MOVE BUT ITS TARGET DID.** For an
    //    ATTACHED worktree on the FILES backend the HEAD file names a branch
    //    and does not change when that branch commits, so a commit made
    //    inside the window is not detected. It is also not LOST: the commit
    //    and the branch ref both live in the common git directory, which
    //    nothing here touches — the removal deletes only the checkout. The
    //    DETACHED case, where the same commit would be unrecoverable, is
    //    fully covered above and refused when it cannot be. The default ref
    //    moving (`git update-ref refs/heads/main <older>`) sits in the same
    //    class and the same reasoning.
    //
    //    NOT A RESIDUAL ON THE REFTABLE BACKEND (r5/D3): `tables.list` moves
    //    on every ref write, including an attached-branch commit, so those
    //    repositories get a strictly stronger guarantee here. The asymmetry
    //    is real and is stated rather than smoothed over.
    // 3. **IGNORED CONTENT THAT WAS ALREADY THERE (r5/D2).** The witness
    //    compares a SET, so a path present in both readings is destroyed with
    //    the tree — which is the product, not a defect. Two narrower limits
    //    ride with it: `--ignored=traditional` collapses an ignored
    //    DIRECTORY to one line, so a file created inside one is not detected,
    //    and the comparison is over PATHS, so a change to an ignored file
    //    that already existed is not detected.
    // 4. **THE DISPOSAL CALL ITSELF.** Once the destruction has been entered,
    //    nothing this process can read changes what it does. That window is
    //    not removable by any ordering, and it is now the same size in both
    //    arms because both re-prove on the far side of their own hop:
    //    **0.004 ms** for the Trash arm, between the re-proof inside the
    //    mover's main-actor hop and the move (r6, D1, measured under 120 ms
    //    main-thread work items), and **0.032 ms** for the permanent arm,
    //    between the re-proof inside `removeItemConcurrently`'s
    //    `DispatchQueue.global` block and `DepthSafeRemoval`'s container open
    //    (r7, D1, measured with the pool saturated microseconds before the
    //    hop).
    //
    //    WHAT USED TO SIT THERE WAS THAT ARM'S WHOLE QUEUE DEPTH — measured
    //    at 175.736 ms for the Trash arm before r6 and 242.656 ms for the
    //    permanent arm before r7. THE SCOPE IS THE THREE FILESYSTEM
    //    PROPOSITIONS ONLY; cleanliness is residual 1 and keeps the queue
    //    depth.
    //
    // The user-facing form of this is in `docs/v1/CATEGORIES.md` and the
    // CHANGELOG: *"The final check before the delete reads the filesystem,
    // not git: which checkout it is, whether it is locked, and whether its
    // HEAD moved. Cleanliness is git's answer and is the last command run, so
    // work saved in the millisecond after it is not seen. On a branch, work
    // committed after the checks still survives on the branch; a detached
    // worktree whose HEAD cannot be re-read is refused instead. Ignored
    // content that was already in the worktree is destroyed with it; an
    // ignored file that appears while the checks run refuses the removal."*

    /// The D13 guard as a `GateReestablishment`, so a refused traversal reads
    /// like every other delete-time refusal instead of throwing through the
    /// re-establishment.
    ///
    /// RETRY: yes — every class the guard refuses (a leaf that became a
    /// symlink, a path that now canonicalizes outside the admitted
    /// container, a different device) is a state a re-scan re-evaluates.
    private func guardGroup(
        _ paths: [GuardedPath],
        inside container: AdmittedContainer,
        invocation: String
    ) -> GateReestablishment {
        do {
            try guardTraversal(paths, inside: container)
            return .proceed
        } catch {
            return .refuse(
                tag: CacheCleaner.refusalTag(error),
                detail: "refused: the traversal guard for \(invocation) "
                    + "rejected a path it must cross "
                    + "(\(error.localizedDescription)) — nothing was removed. "
                    + "Re-scan to rebuild this item."
            )
        }
    }

    private func parentGuardPath(_ plan: GitWorktreeReclaimPlan) -> GuardedPath {
        (label: "parent repository", url: plan.parentRepoWorkingDir,
         containment: .descendantOrEqual)
    }

    private func adminContainerGuardPath(
        _ plan: GitWorktreeReclaimPlan
    ) -> GuardedPath {
        (label: "admin container", url: plan.parentAdminContainer,
         containment: .strictDescendant)
    }

    /// **R0** — the repository behind the `-C` target is still the one whose
    /// admin data this plan carries.
    ///
    /// Every path gate in this file (`admitContainer`,
    /// `validateRemovableItem`, `validateSubprocessTraversalDirectory`) is a
    /// fact about a PATH: a real leaf, a canonical spelling, containment, a
    /// device. A repository can be re-pointed while every one of those still
    /// holds — planting a one-line `gitdir:` file at `<bare>/.git` redirects
    /// `git -C <bare>` at another repository entirely without moving,
    /// replacing or symlinking anything the guards look at (measured, git
    /// 2.50.1). Re-running the scan's own `crossValidate` would NOT catch it
    /// either: its bare branch compares inodes the added file does not
    /// disturb. Only git can answer which repository it resolved.
    private func reestablishParentRepository(
        plan: GitWorktreeReclaimPlan
    ) async -> GateReestablishment {
        let carried = plan.parentAdminContainer.deletingLastPathComponent()
        let resolved = await runner.run(
            Self.commonGitDirArguments(
                parentRepoWorkingDir: plan.parentRepoWorkingDir
            ),
            timeout: gitTimeout
        )
        let stdout: Data
        switch resolved.outcome {
        case .success(let data):
            stdout = data
        case .failure(let exitCode, let stderr):
            return .refuse(
                tag: "parent-repo-unresolvable",
                detail: "refused: the parent repository "
                    + "\(plan.parentRepoWorkingDir.path) could not be "
                    + "re-resolved at clean time "
                    + "(\(GitCommandFailureSummary.describe(exitCode: exitCode, stderr: stderr)))"
                    + " — nothing was removed. Retry once git can read that "
                    + "repository."
            )
        case .timeout:
            return .refuse(
                tag: "parent-repo-unresolvable",
                detail: "refused: re-resolving the parent repository timed out "
                    + "after \(Self.seconds(gitTimeout))s — nothing was "
                    + "removed. Retry when the machine is less busy."
            )
        case .gitUnavailable:
            return .refuse(
                tag: "parent-repo-unresolvable",
                detail: "refused: git became unavailable before the parent "
                    + "repository could be re-resolved — nothing was removed. "
                    + "Retry once git is installed and reachable."
            )
        }
        guard let line = WorktreeStalenessAssessor.firstLine(of: stdout),
              line.hasPrefix("/") else {
            return .refuse(
                tag: "parent-repo-unresolvable",
                detail: "refused: git did not answer with an absolute git "
                    + "directory for \(plan.parentRepoWorkingDir.path) — "
                    + "nothing was removed. Re-scan to rebuild this item."
            )
        }
        // Inode identity when both sides exist, so a different SPELLING of
        // the same git directory passes and only a genuinely different
        // object refuses.
        guard provider.sameLocation(URL(fileURLWithPath: line), carried) else {
            return .refuse(
                tag: "parent-repo-rebound",
                detail: "refused: the parent repository "
                    + "\(plan.parentRepoWorkingDir.path) now resolves to git "
                    + "directory \(line), not the admitted \(carried.path) — "
                    + "the repository was redirected since the scan; nothing "
                    + "was removed. Remove the redirect, then re-scan."
            )
        }
        return .proceed
    }

    /// **R1** — G1 and G4, re-read from the live porcelain record, plus the
    /// registration itself.
    ///
    /// THIS IS WHAT DISCRIMINATES THE CLASSES GIT WOULD HAVE REFUSED, and it does
    /// so from a STRUCTURED signal: a re-read `worktree list --porcelain -z`
    /// record, parsed by fn-5.1's parser, judged by fn-5.2's OWN gate
    /// functions. NOTHING here reads git's stderr — classifying a refusal by
    /// its message text is forbidden house doctrine, and it is also what a
    /// locale or a git upgrade breaks first. The ignored-tree and populated-
    /// submodule refusals leave the record REGISTERED, LINKED and UNLOCKED;
    /// a lock refusal leaves it `locked`; an "is not a working tree" refusal
    /// leaves no record at all.
    private func reestablishWorktreeRecord(
        plan: GitWorktreeReclaimPlan, worktreePath: URL, adminEntry: URL
    ) async -> WorktreeRecordReestablishment {
        let listing = await runner.run(
            GitWorktreeOracle.listArguments(
                forRepositoryAt: plan.parentRepoWorkingDir
            ),
            timeout: gitTimeout
        )
        let stdout: Data
        switch listing.outcome {
        case .success(let data):
            stdout = data
        case .failure(let exitCode, let stderr):
            return .refuse(
                tag: "worktree-registry-unreadable",
                detail: "refused: the worktree registry of "
                    + "\(plan.parentRepoWorkingDir.path) could not be re-read "
                    + "(\(GitCommandFailureSummary.describe(exitCode: exitCode, stderr: stderr)))"
                    + " — nothing was removed. Retry once git can read that "
                    + "repository."
            )
        case .timeout:
            return .refuse(
                tag: "worktree-registry-unreadable",
                detail: "refused: re-reading the worktree registry timed out "
                    + "after \(Self.seconds(gitTimeout))s — nothing was "
                    + "removed. Retry when the machine is less busy."
            )
        case .gitUnavailable:
            return .refuse(
                tag: "worktree-registry-unreadable",
                detail: "refused: git became unavailable before the worktree "
                    + "registry could be re-read — nothing was removed. Retry "
                    + "once git is installed and reachable."
            )
        }
        guard let inventory = GitWorktreeInventory.parse(stdout) else {
            return .refuse(
                tag: "worktree-registry-unreadable",
                detail: "refused: the worktree registry of "
                    + "\(plan.parentRepoWorkingDir.path) could not be parsed "
                    + "— nothing was removed. Re-scan to rebuild this item."
            )
        }
        guard let record = inventory.entries.first(where: {
            provider.sameLocation($0.path, worktreePath)
        }) else {
            return .refuse(
                tag: "worktree-deregistered",
                detail: "refused: \(worktreePath.path) is no longer a "
                    + "registered worktree of "
                    + "\(plan.parentRepoWorkingDir.path) — it was deregistered "
                    + "since the scan, so whatever is at that path now is not "
                    + "the object that was assessed; nothing was removed. "
                    + "Re-scan to see what is actually there."
            )
        }
        // G1, verbatim — the assessor's own function, never a second spelling.
        let linked = WorktreeStalenessAssessor.evaluateNotMainOrBare(record)
        guard linked.passed else {
            return .refuse(
                tag: "worktree-not-linked",
                detail: "refused: \(worktreePath.path) is now the "
                    + "repository's \(linked.reason) record — nothing was "
                    + "removed. Re-scan to rebuild this item."
            )
        }
        // G4, verbatim. A locked worktree is NEVER removed: git's own way to
        // do it is `remove -f -f`, which this epic's Boundaries forbid, and a
        // filesystem removal that ignored the lock would achieve exactly
        // that forbidden effect without the flag.
        let notLocked = WorktreeStalenessAssessor.evaluateNotLocked(record)
        guard notLocked.passed else {
            return .refuse(
                tag: "worktree-locked",
                detail: "refused: this worktree was LOCKED after the scan "
                    + "(\(notLocked.reason)) — nothing was removed. Run "
                    + "`git worktree unlock \(worktreePath.path)` first, then "
                    + "re-scan; a re-scan alone will keep refusing while the "
                    + "lock is held."
            )
        }
        // R1b — LAST, and deliberately after G1/G4. Those two are facts
        // about the RECORD GIT HOLDS FOR THIS PATH and stay true statements
        // about it whatever checkout occupies it ("that path is now the
        // repository's main record" is the precise, actionable message for
        // a plan aimed at a main checkout, and putting R1b first would
        // replace it with a vaguer one and leave G1 unevidenced here).
        // R1b is the condition on ACCEPTING the record, so it runs where
        // the record is accepted.
        if case .refuse(let tag, let detail) = reestablishWorktreeIdentity(
            worktreePath: worktreePath, adminEntry: adminEntry,
            carriedIdentity: plan.worktreeAdminEntryIdentity
        ) {
            return .refuse(tag: tag, detail: detail)
        }
        return .record(record)
    }

    /// **R1b** — WHICH worktree the re-read record is about (PR #460 codex
    /// r2, C-round-2 D1).
    ///
    /// R1 above finds the record by PATH, and a path is not an identity. The
    /// scan authorised destroying ONE checkout, and the plan carries that
    /// checkout's own identity token: `worktreeAdminEntry`, the admin
    /// directory fn-5.1's resolver reached THROUGH the worktree's `.git`
    /// back-link. Until this round that token was carried and never
    /// consulted, so after a user retired the stale worktree themselves and
    /// `git worktree move`d another checkout onto the freed path, the
    /// performer re-proved all four gates against the newcomer's record and
    /// destroyed it — measured, with a SUCCESS entry and `errors=[]`.
    ///
    /// The re-proof is the same resolver, run the other way from
    /// `revivedCheckoutRefusal`: `<worktree>/.git` must still be a regular
    /// FILE, must still point INTO a `worktrees` container, that admin
    /// directory's `gitdir` must still point BACK at this `.git`, and the
    /// directory so reached must be the carried one. Nothing here is a
    /// message match and nothing is a bare spelling comparison —
    /// `sameLocation` is inode identity when both sides exist.
    ///
    /// UNLIKE `revivedCheckoutRefusal` THIS ONE FAILS CLOSED on every
    /// ambiguity, and the asymmetry is deliberate: there the oracle had
    /// already proved the entry prunable and an unreadable back-link could
    /// only ADD a refusal, whereas here an unreadable back-link means the
    /// authorisation cannot be tied to an object at all.
    ///
    /// That sentence was FALSE FOR ONE ARM until PR #460 codex r4 (D6).
    /// `sameLocation` is inode identity only when BOTH sides can be stat'd;
    /// when either cannot it falls back to comparing canonical path
    /// COMPONENTS, so an admin directory that had become unreadable was
    /// answered by a spelling. The live identity is now taken FIRST and its
    /// absence is a refusal, and a plan with no carried identity is a refusal
    /// too — there is no arm left that a spelling alone can satisfy.
    ///
    /// RETRY: yes, and it can differ. Every class refused here is a change a
    /// re-scan re-evaluates from scratch — the checkout now at that path
    /// becomes its own candidate, or fails the four gates on its own merits,
    /// or is not offered at all.
    ///
    /// THE SAME-PATH RE-ADD, CLOSED (PR #460 codex r3, D3). MEASURED on git
    /// 2.50.1: a user who removes the stale worktree and then re-adds one AT
    /// THE SAME PATH gets an admin directory of the SAME NAME back
    /// (`worktrees/<basename>` is freed by the removal and reused by the add)
    /// with a DIFFERENT inode. Both sides of the path comparison below
    /// re-resolve to that same spelling, so it passed — and the brand-new
    /// checkout was destroyed under a SUCCESS entry, together with files
    /// `status --porcelain` never reports (a committed `.gitignore` covering
    /// `secret.env` and `node_modules/` makes such a tree read CLEAN to both
    /// git and this app). The plan now carries the scan-time INODE of that
    /// admin directory and this gate compares it, so the re-created directory
    /// refuses.
    ///
    /// The inode is the right binding because the admin directory is created
    /// once per checkout and outlives everything a user legitimately does to
    /// one: `git worktree move` rewrites its `gitdir` file, `git worktree
    /// repair` rewrites its pointers, and neither replaces the directory.
    ///
    /// WHERE THIS GATE IS REACHABLE FROM — CORRECTED (PR #460 codex r4, D4).
    /// r3 claimed here, in the CHANGELOG, in `docs/v1/CATEGORIES.md` and in
    /// 26e8bdf's own commit message that `Cacheout --cli clean` is protected
    /// by its in-process re-scan because a replacement is answered with
    /// "Unknown item id … rescan and retry". THAT IS FALSE, and a run cell
    /// falsifies it: item ids are `SHA256(scannerID + NUL + canonicalPath)`
    /// (`ReclaimableItem.stableID`), so a replacement checkout AT THE SAME
    /// PATH gets the SAME id; and candidacy is `gates.allSatisfy(\.passed)`
    /// with NO age term (`WorktreeStalenessAssessor`), so a brand-new
    /// `git worktree add` on a merged branch is a candidate the instant it
    /// exists. The CLI's re-scan re-JUDGES what is at the path; it does not
    /// DETECT that the object was substituted.
    ///
    /// What each surface actually gets: the CLI re-scans, so the plan it
    /// executes carries the REPLACEMENT's own admin inode and the removal is
    /// the one a fresh scan authorises — this gate cannot fire there, and the
    /// protection is that a fresh scan judged the replacement (`.review`
    /// risk, never auto-selected, never automatic-clean eligible), not that
    /// the id failed to resolve. The GUI holds a scan session alive across a
    /// user's click, and THAT window — the one where the plan predates the
    /// substitution — is the one this gate closes.
    ///
    /// - Parameter carriedIdentity: the scan-time inode identity of
    ///   `adminEntry`. Optional in the TYPE only, because a plan can be
    ///   hand-built without it; nil is REFUSED here rather than skipped
    ///   (r4/D6). `GitWorktreeScanner` no longer emits an item at all when it
    ///   cannot stat that directory, so a nil arriving here means a plan that
    ///   was not built by a scan.
    private func reestablishWorktreeIdentity(
        worktreePath: URL, adminEntry: URL,
        carriedIdentity: FileSystemIdentityProvider.Identity?
    ) -> GateReestablishment {
        let resolver = GitWorktreeGitdirResolver(identity: provider)
        guard let live = resolver.adminDirectory(forWorktreeAt: worktreePath)
        else {
            return .refuse(
                tag: "worktree-identity-unresolvable",
                detail: "refused: \(worktreePath.path) no longer resolves "
                    + "through its own `.git` back-link to an admin directory "
                    + "— the checkout the scan assessed is not provably the "
                    + "one at that path now; nothing was removed. Re-scan to "
                    + "see what is actually there."
            )
        }
        // THE LIVE IDENTITY IS TAKEN FIRST AND IS MANDATORY (PR #460 codex
        // r4, D6). `sameLocation` compares INODES only when both sides can be
        // stat'd and otherwise falls back to comparing canonical path
        // COMPONENTS (`FileSystemIdentityProvider.sameLocation`) — so making
        // it the first question would have let an unreadable admin directory
        // be answered by a spelling, which is the ambiguity this gate claims
        // not to have.
        guard let liveIdentity = provider.identity(of: live) else {
            return .refuse(
                tag: "worktree-identity-unreadable",
                detail: "refused: the admin directory \(live.path) could not "
                    + "be identified at clean time — the checkout the scan "
                    + "assessed is not provably the one at "
                    + "\(worktreePath.path) now; nothing was removed. "
                    + "Re-scan to see what is actually there."
            )
        }
        guard provider.sameLocation(live, adminEntry) else {
            return .refuse(
                tag: "worktree-identity-rebound",
                detail: "refused: \(worktreePath.path) is now the checkout of "
                    + "admin directory \(live.path), not the assessed "
                    + "\(adminEntry.path) — a DIFFERENT worktree occupies the "
                    + "path this item was authorised against; nothing was "
                    + "removed. Re-scan; whatever is there now is judged on "
                    + "its own merits."
            )
        }
        // THE SAME-PATH RE-ADD. Everything above compares SPELLINGS that
        // survive a remove/add cycle intact; only the inode does not.
        //
        // A MISSING CARRIED IDENTITY IS A REFUSAL, NOT AN INERT GATE (PR #460
        // codex r4, D6). It used to skip the comparison silently, so any plan
        // built without the field — a future construction path that forgot
        // it, or a scan whose `lstat` failed — disabled the only check that
        // can tell a re-created checkout from the assessed one, with no
        // compiler complaint and no runtime signal. The production
        // initializer no longer defaults the field, and this gate no longer
        // proceeds without it.
        guard let carriedIdentity else {
            return .refuse(
                tag: "worktree-identity-unbound",
                detail: "refused: this item carries no scan-time identity for "
                    + "the admin directory of \(worktreePath.path), so a "
                    + "checkout re-created at that path since the scan could "
                    + "not be told from the assessed one — nothing was "
                    + "removed. Re-scan to rebuild this item."
            )
        }
        guard liveIdentity == carriedIdentity else {
            return .refuse(
                tag: "worktree-identity-recreated",
                detail: "refused: \(worktreePath.path) is a DIFFERENT "
                    + "checkout from the one that was assessed — its admin "
                    + "directory \(live.path) has the same name but was "
                    + "re-created since the scan, which is what a "
                    + "`git worktree remove` followed by a fresh "
                    + "`git worktree add` at that path does. Nothing was "
                    + "removed. Re-scan; the checkout there now is judged "
                    + "on its own merits."
            )
        }
        return .proceed
    }

    // MARK: - The LAST-INSTANT re-proof (PR #460 codex r4)

    /// The per-worktree HEAD file — or, for the `reftable` backend, the
    /// per-worktree ref STACK — as R2 saw it: the bytes, and the inode they
    /// were read through.
    ///
    /// The inode matters as much as the bytes: git REPLACES both files rather
    /// than writing them in place, so the inode moves on every write.
    /// MEASURED on git 2.50.1 — `<admin>/HEAD`: a commit on a detached head
    /// took it from 115935185 to 116190333, and a branch switch moved an
    /// attached worktree's from 115935122 to 116190340;
    /// `<admin>/reftable/tables.list`: 117937252 → 117937281 → 117937297 →
    /// 117937323 across an attached commit, a `switch --detach` and a
    /// detached commit, and UNCHANGED across `status` and `worktree list`.
    /// A file re-created with identical bytes is still a different object,
    /// and this catches it.
    struct HeadWitness: Equatable {
        /// WHICH file is the witness. Two backends, two files, and the
        /// comparison at the last instant must re-read the SAME one — a
        /// witness taken from the reftable stack and compared against `HEAD`
        /// would compare two different objects and pass forever.
        enum Substrate: String, Equatable {
            /// `<admin>/HEAD` — the files ref backend.
            case headFile = "HEAD"
            /// `<admin>/reftable/tables.list` — the reftable ref backend's
            /// PER-WORKTREE ref stack.
            case reftableStack = "reftable/tables.list"

            var relativePath: String { rawValue }
        }

        let substrate: Substrate
        let identity: FileSystemIdentityProvider.Identity
        let bytes: Data
    }

    /// A HEAD witness, or the NAMED reason there is none. Never collapsed to
    /// a bare nil: which proposition sits outside the last-instant set is the
    /// thing this round has to be able to state, and a nil cannot state it.
    enum HeadWitnessCapture: Equatable {
        case witness(HeadWitness)
        /// `<admin>/HEAD` is not a readable regular file.
        case unreadable
        /// `<admin>/HEAD` is readable and does NOT corroborate the porcelain
        /// record, AND the reftable stack that would witness it instead is
        /// not readable either. Comparing an uncorroborated HEAD across the
        /// window would be a guard that can never fire — the silently-inert
        /// shape D6 is about.
        ///
        /// The `reftable` backend USED to land here (its `<admin>/HEAD` is the
        /// constant stub `ref: refs/heads/.invalid`, verified git 2.50.1),
        /// which is what made D3 possible; it now corroborates through
        /// `reftableStackPath` instead, so this case is reachable only for a
        /// HEAD file that is neither backend's.
        case uncorroborated(live: String, expected: String)
    }

    /// Per-worktree HEAD, inside the admin directory. A LINKED worktree's
    /// HEAD is per-worktree by git's own layout — MEASURED, the admin
    /// directory of a fresh `git worktree add` holds `HEAD`, `ORIG_HEAD`,
    /// `commondir`, `gitdir`, `index`, `logs/` and `refs/` — so this is the
    /// file that moves when the checkout commits. Verified on git 2.50.1: a
    /// commit on a DETACHED head rewrites it (the bytes ARE the SHA); a
    /// commit on an ATTACHED branch does not (the bytes stay
    /// `ref: refs/heads/<branch>` while the branch tip moves).
    static let headFileName = "HEAD"

    /// The reftable backend's PER-WORKTREE ref stack (PR #460 codex r5, D3).
    ///
    /// Through r4 a reftable worktree had no witness at all: `<admin>/HEAD`
    /// is a constant stub there, so `captureHead` returned `.uncorroborated`,
    /// an ATTACHED record fell through to `.proceed(head: nil)`, and
    /// `reproveFromTheFilesystem` skipped the HEAD proposition entirely.
    /// MEASURED BY THE r5 REVIEW at c8ab723 (their figures): on
    /// `git init --ref-format=reftable`, a `git switch --detach` followed by
    /// a commit inside the window destroyed the worktree, left the commit
    /// reachable from no ref, and returned `Entry(exactBytes: 45056,
    /// .permanent, warning: nil)` with `errors == []`.
    ///
    /// `tables.list` is the substrate that closes it. MEASURED THIS ROUND,
    /// git 2.50.1, on a linked worktree of a `--ref-format=reftable`
    /// repository — `git init --ref-format=reftable`, seed commit,
    /// `worktree add -b feature`, then each operation in the order shown,
    /// `stat`-ing the file after each (one run, figures pasted from its
    /// output):
    ///
    /// | operation | `tables.list` inode | contents |
    /// |---|---|---|
    /// | baseline | 117937252 | `0x…0001-0x…0003-296e1169.ref` |
    /// | `git status` | 117937252 | unchanged |
    /// | `git worktree list` | 117937252 | unchanged |
    /// | commit on the ATTACHED branch | 117937281 | `…0x…0004-0caa0886.ref` |
    /// | `git switch --detach` | 117937297 | `…0x…0005-4f3d89fa.ref` |
    /// | commit while DETACHED | 117937323 | `…0x…0006-b54c4d23.ref` |
    ///
    /// So it is stable under reads and moves on every ref write — including
    /// the ATTACHED-branch commit, which the files backend's HEAD file does
    /// NOT catch (residual 2 in "What is left, measured"). A reftable
    /// worktree therefore gets a STRICTLY STRONGER guarantee here than a
    /// files-backend one, and that asymmetry is real rather than cosmetic.
    ///
    /// The two backends are mutually exclusive on disk: a files-backend
    /// linked worktree's admin directory holds `HEAD ORIG_HEAD commondir
    /// gitdir index logs refs` and NO `reftable` directory (measured, same
    /// run), so the presence of this file identifies the backend with no
    /// configuration read.
    static let reftableStackPath = "reftable/tables.list"

    // THERE IS NO `reftablePlaceholderRef` GUARD, AND THE MEASUREMENT IS WHY
    // (PR #460 codex r5). While building D3's fixtures this file briefly
    // refused a record naming `refs/heads/.invalid`, on the theory that an
    // unreadable per-worktree ref stack would make git report the stub as the
    // branch and let the stub corroborate itself. MEASURED on git 2.50.1
    // (stack replaced by a directory, `worktree add --detach`), the record is
    // instead `HEAD 0000000000000000000000000000000000000000` with NO
    // `branch` and NO `detached` attribute — so `branchRef` is nil, the
    // capture is `.uncorroborated`, and the removal is refused by the gates
    // that already exist (`status` reports the whole tree added against the
    // null HEAD, and the ancestry ladder cannot answer). The guard could not
    // be made to fire by any fixture, which is the definition of the
    // unevidenced guard this project has shipped twice; it was deleted rather
    // than asserted.

    /// git's OWN representation of a worktree lock: `git worktree lock`
    /// creates `<admin>/locked` (empty, or holding the `--reason` text) and
    /// `git worktree unlock` removes it — verified on git 2.50.1 both ways.
    /// Its PRESENCE is the lock; the reason is display data.
    static let lockFileName = "locked"

    /// THE LAST-INSTANT RE-PROOF — every gate whose ORACLE IS THE FILESYSTEM
    /// ITSELF, re-proved immediately before the destructive act — and since
    /// r5 there is exactly one destructive act to be before.
    ///
    /// ## THE GENERAL SHAPE, AND WHY IT IS NOT "MOVE ONE CALL DOWN"
    ///
    /// `reestablishStaleGates` asks GIT. Every question it asks costs a
    /// subprocess, and the answer is stale the moment the pipe closes — so
    /// the re-establishment cannot be pushed arbitrarily close to the
    /// mutation: something always sits between the last answer and the act.
    /// MEASURED BY THE r4 REVIEW at r3's ordering, 5 samples each,
    /// uninstrumented (their numbers, carried here as the baseline this round
    /// improves on): fallback last gate → destructive call, median 77.9 ms;
    /// all identity gates done → destructive call, median 58.0 ms; primary
    /// R1b-done → `worktree remove` spawned, median 56.9 ms, containing THREE
    /// further subprocess spawns. Those windows swallowed a whole
    /// `git worktree remove` + `git worktree add` at the same path, a
    /// `git worktree lock`, and a commit on a detached HEAD, each destroying
    /// real data with `errors == []` — and all three are reproduced HERE, as
    /// cells that go red the moment this function is removed.
    ///
    /// The division that closes them is not "run the gates later". It is:
    /// **a proposition whose authority is the filesystem can be re-proved at
    /// the last instant for the price of a few `lstat`s; a proposition whose
    /// authority is git cannot be re-proved without opening a new window.**
    /// This function is the whole first class:
    ///
    /// | proposition | substrate | re-proved here |
    /// |---|---|---|
    /// | WHICH CHECKOUT this is (R1b) | `<wt>/.git` → admin dir → back-link → inode | YES — the same pure-filesystem resolver R1b runs, no git at all |
    /// | THE LOCK (G4) | `<admin>/locked` exists | YES — git's own on-disk representation |
    /// | HEAD UNMOVED (R2's premise) | `<admin>/HEAD` bytes + inode, or `<admin>/reftable/tables.list` when that file cannot corroborate (D3) | YES |
    ///
    /// and the second class is stated, not hidden, in the "What is left,
    /// measured" section above.
    ///
    /// ORDER: identity first. The lock file and the HEAD file are read
    /// THROUGH the admin directory, so "which admin directory" must be
    /// settled before either answer means anything.
    ///
    /// NO D13 GUARD RUNS HERE, and that is not an omission. This function
    /// spawns nothing: there is no subprocess to hand a path to, which is the
    /// only thing `validateSubprocessTraversalDirectory` exists to protect.
    /// It is itself a fail-closed path proof — `<wt>/.git` must be a regular
    /// FILE (never followed), the admin directory must be a real directory
    /// whose `gitdir` points BACK at that file, and its inode must equal the
    /// scan's. A `<wt>` swapped for a symlink to another checkout fails that
    /// chain rather than passing an unresolved-spelling containment check.
    ///
    /// RETRY: every refusal below clears. A replacement checkout, a lock, a
    /// moved HEAD are all states a re-scan re-evaluates from scratch — none
    /// is a deterministic limit whose printed remedy could never differ.
    private func reproveFromTheFilesystem(
        worktreePath: URL,
        adminEntry: URL,
        carriedIdentity: FileSystemIdentityProvider.Identity?,
        head: HeadWitness?
    ) -> GateReestablishment {
        // (1) WHICH CHECKOUT. Same function R1b runs — one implementation, so
        // the last instant and the gate can never disagree about identity.
        if case .refuse(let tag, let detail) = reestablishWorktreeIdentity(
            worktreePath: worktreePath, adminEntry: adminEntry,
            carriedIdentity: carriedIdentity
        ) {
            return .refuse(tag: tag, detail: detail)
        }

        // (2) THE LOCK. G4 re-read from git's own file rather than from the
        // porcelain record, because the record costs a subprocess and this
        // costs one `lstat`. ANY object at that name is a lock — git tests
        // for existence, not for kind.
        let lockFile = adminEntry.appendingPathComponent(Self.lockFileName)
        switch provider.probeKind(of: lockFile) {
        case .absent:
            break
        case .kind:
            return .refuse(
                tag: "worktree-locked",
                detail: "refused: this worktree was LOCKED while the "
                    + "delete-time checks were running (\(lockFile.path) "
                    + "exists) — nothing was removed. Run `git worktree "
                    + "unlock \(worktreePath.path)` first, then re-scan; a "
                    + "re-scan alone will keep refusing while the lock is "
                    + "held."
            )
        case .failed(let code):
            return .refuse(
                tag: "worktree-lock-unreadable",
                detail: "refused: whether this worktree is locked could not "
                    + "be determined at the last instant (\(lockFile.path): "
                    + "errno \(code)) — nothing was removed. Re-scan once "
                    + "that directory is readable."
            )
        }

        // (3) HEAD UNMOVED. Absent witness ⇒ this proposition is not in the
        // last-instant set at all, and `reestablishStaleGates` has already
        // refused the one case where that absence is unrecoverable.
        guard let head else { return .proceed }
        guard let live = readWitness(
            adminEntry: adminEntry, substrate: head.substrate
        ) else {
            return .refuse(
                tag: "worktree-head-unreadable",
                detail: "refused: this worktree's HEAD witness "
                    + "(\(adminEntry.appendingPathComponent(head.substrate.relativePath).path)) "
                    + "could not be re-read at the last instant, so the "
                    + "ancestry answer cannot be tied to a commit — nothing "
                    + "was removed. Re-scan to rebuild this item."
            )
        }
        guard live == head else {
            return .refuse(
                tag: "worktree-head-moved",
                detail: "refused: this worktree's HEAD MOVED while the "
                    + "delete-time checks were running, so the ancestry "
                    + "answer is no longer about the commit that is checked "
                    + "out — nothing was removed. Re-scan; the checkout is "
                    + "judged on its new HEAD."
            )
        }
        return .proceed
    }

    /// `<admin>/HEAD`, no-follow: the inode it IS and the bytes it holds.
    /// `nil` when it is not a regular file or cannot be read — a symlink at
    /// that name is never followed, so a link planted over HEAD reads as an
    /// absent witness rather than as whatever it points at.
    private func readWitness(
        adminEntry: URL, substrate: HeadWitness.Substrate
    ) -> HeadWitness? {
        let file = adminEntry.appendingPathComponent(substrate.relativePath)
        guard provider.probeKind(of: file) == .kind(.regularFile),
              let identity = provider.identity(of: file),
              let bytes = try? Data(contentsOf: file)
        else { return nil }
        return HeadWitness(
            substrate: substrate, identity: identity, bytes: bytes
        )
    }

    /// The HEAD witness, CORROBORATED against the porcelain record git just
    /// gave us.
    ///
    /// The corroboration is what stops this from being an inert guard. A file
    /// that never changes compares equal across every window and would
    /// silently prove nothing; requiring it to AGREE with what git reports
    /// HEAD to be — the SHA for a detached record, `ref: <branch>` for an
    /// attached one — admits only a file that is actually tracking HEAD.
    /// MEASURED: the files backend corroborates in both shapes, and the
    /// `reftable` backend's `ref: refs/heads/.invalid` stub corroborates in
    /// neither.
    private func captureHead(
        adminEntry: URL, record: GitWorktreeEntry
    ) -> HeadWitnessCapture {
        // (1) THE FILES BACKEND. `<admin>/HEAD` is a witness only when it
        // CORROBORATES the record git just gave us.
        if let witness = readWitness(adminEntry: adminEntry, substrate: .headFile) {
            let live = String(decoding: witness.bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = record.isDetached
                ? record.headSHA
                : record.branchRef.map { "ref: \($0)" }
            if let expected, !expected.isEmpty,
               live.caseInsensitiveCompare(expected) == .orderedSame {
                return .witness(witness)
            }
            // (2) THE REFTABLE BACKEND (D3). HEAD is readable and does not
            // corroborate — the measured shape is the `ref: refs/heads/.invalid`
            // stub. The PER-WORKTREE REF STACK is the substrate that does move,
            // and it needs no corroboration against the record because it is
            // not a copy of HEAD: it is the log of every ref write this
            // worktree has made, and a witness that MOVES on every write is the
            // opposite of the inert-file shape corroboration exists to reject.
            if let stack = readWitness(
                adminEntry: adminEntry, substrate: .reftableStack
            ) {
                return .witness(stack)
            }
            return .uncorroborated(live: live, expected: expected ?? "nothing")
        }
        // (3) HEAD IS NOT A READABLE REGULAR FILE. There is no third arm
        // here, and the measurement is why (PR #460 codex r6, D5).
        //
        // r5 shipped `if let stack = readWitness(adminEntry:substrate:
        // .reftableStack) { return .witness(stack) }` on this line, in the
        // round whose own doctrine deleted a guard twenty lines above for
        // being unevidenced. It was unevidenced too: MUTATION M7 replaced this
        // whole block with `return .unreadable` and the FULL suite stayed
        // GREEN — `swift test`, run AT COMMIT 06c1ad5, reported 1466
        // executed / 2 skipped / 0 failures.
        //
        // THE COMMAND AND THE COMMIT ARE BOTH STATED BECAUSE THE TOTAL MOVES
        // (PR #460 codex r7, D5). 1466 is 06c1ad5's total, not this branch's:
        // 0284fd1 took it to 1467, 193b043 to 1470, bcfcb7e to 1471, r7's own
        // cells to 1480, and r8's six fence and citation cells to 1486 (the
        // measurement 7e9b2c5 records). "THIS COMMIT" IS NOT AN ENDPOINT, SO
        // IT WENT STALE AT THE VERY NEXT COMMIT (PR #460 codex r10, D4): r9's
        // cells moved the total and this line did not follow. r9 and r10 took
        // it to 1496 — `swift test` AT COMMIT 101753b reported 1496 executed /
        // 2 skipped / 0 failures, exit 0 — and r11's four cells (two on the
        // Trash fallback's errno gate, two on the unbounded-park fence) took
        // it to 1500: `swift test` AT COMMIT a917447 reported 1500 executed /
        // 2 skipped / 0 failures, exit 0. r12's eleven cells — five on the
        // directory-verdict arm's landing, one on an absent container, three
        // on the scan session's wall-clock bound, one on its visible row and
        // one on the errno-carrying open — took it to 1511: `swift test` AT
        // COMMIT 592eb0a reported 1511 executed / 2 skipped / 0 failures,
        // exit 0. Every figure here now names the
        // commit it was taken at, which is the only spelling that cannot rot.
        // The half that survives every commit — and the half a mutation
        // actually establishes — is the ZERO FAILURES.
        //
        // MEASURED, git 2.50.1, on a `--ref-format=reftable` linked worktree
        // (`git init --ref-format=reftable`, seed commit, `worktree add -b
        // feature`), making `<admin>/HEAD` unreadable in the only two ways
        // there are — replacing it with a symlink, and removing it outright:
        //
        //   git -C <parent> worktree list --porcelain   exit 0, BOTH records
        //                                               reported normally
        //   git -C <worktree> status --porcelain        exit 128,
        //                                               "fatal: not a git
        //                                               repository: …/worktrees/wt"
        //
        // So the state this arm existed for is exactly the state in which git
        // cannot answer ANY question about the worktree: the parent's record
        // still passes R0/R1/R1b, and then the ignored witness, G2 and R2's
        // ladder all fail closed. The arm could turn `.unreadable` into a
        // witness, and the witness could never change an outcome — the removal
        // is refused either way, by gates that already exist. And `.unreadable`
        // is the STRICTER answer: on a DETACHED record it earns
        // `worktree-head-unwitnessable` outright.
        //
        // `testAReftableWorktreeWhoseHeadFileIsGoneIsRefusedByTheGatesThatRemain`
        // pins that outcome.
        return .unreadable
    }

    /// **R2** — G3, re-run through the SHARED `GitWorktreeMergedCheck`.
    ///
    /// The scan's ancestry answer is the whole authorization for destroying
    /// this checkout, and it is the one gate a user can invalidate simply by
    /// working: committing in the worktree after the scan leaves the tree
    /// CLEAN, leaves the record REGISTERED and UNLOCKED, and leaves git's own
    /// `worktree remove` perfectly willing (measured: exit 0, silent). On a
    /// branch the commit survives on the ref; on a DETACHED HEAD it survives
    /// only as a dangling object with no reflog left to name it.
    private func reestablishAncestry(
        plan: GitWorktreeReclaimPlan, worktreePath: URL, record: GitWorktreeEntry
    ) async -> GateReestablishment {
        switch await GitWorktreeMergedCheck.run(
            worktreeAt: worktreePath,
            parentRepoWorkingDir: plan.parentRepoWorkingDir,
            using: runner, timeout: gitTimeout
        ) {
        case .merged:
            return .proceed
        case .notAncestor(let defaultRef):
            var detail = "refused: this worktree's HEAD is no longer an "
                + "ancestor of \(defaultRef) — work was committed after the "
                + "scan (HEAD \(Self.shortOID(record.headSHA))); nothing was "
                + "removed."
            if record.isDetached {
                detail += " HEAD is DETACHED, so removing this worktree would "
                    + "leave that commit reachable from no ref at all."
            }
            detail += " Merge, rebase or push that commit — or move it onto a "
                + "branch — then re-scan."
            return .refuse(tag: "worktree-unmerged", detail: detail)
        case .unanswered(let reason):
            return .refuse(
                tag: "worktree-ancestry-unanswered",
                detail: "refused: the delete-time ancestry re-check could not "
                    + "be answered (\(reason)) — nothing was removed. Retry "
                    + "once git can answer, or repair the named ref."
            )
        }
    }

    // MARK: - Oracle recompute (shared by both modes)

    private enum PrunableSetRecompute {
        case set([URL])
        case failed(String)
    }

    /// Re-run the porcelain oracle and re-map it through fn-5.1's SHARED
    /// mapper. Every failure class is NAMED — there is no benign catch-all:
    /// only an oracle exit 0 whose bytes parse and whose records map
    /// COMPLETELY yields a set.
    private func recomputePrunableSet(
        plan: GitWorktreeReclaimPlan, container: AdmittedContainer
    ) async -> PrunableSetRecompute {
        // The recompute is `git -C <parent> worktree list` — the SAME argv
        // R1 fires, so it traverses the same two paths: the `-C` target, and
        // the admin container the listing ENUMERATES to answer `prunable`
        // (PR #460 codex r2; the container was previously unguarded here).
        do {
            try guardTraversal([
                parentGuardPath(plan), adminContainerGuardPath(plan),
            ], inside: container)
        } catch {
            return .failed(
                "the traversal guard refused a path the oracle listing "
                    + "traverses (\(error.localizedDescription))"
            )
        }

        let listing = await runner.run(
            GitWorktreeOracle.listArguments(
                forRepositoryAt: plan.parentRepoWorkingDir
            ),
            timeout: gitTimeout
        )
        let stdout: Data
        switch listing.outcome {
        case .success(let data):
            stdout = data
        case .failure(let exitCode, let stderr):
            return .failed(
                "the porcelain oracle failed "
                    + "(\(GitCommandFailureSummary.describe(exitCode: exitCode, stderr: stderr)))"
            )
        case .timeout:
            return .failed(
                "the porcelain oracle timed out after \(Self.seconds(gitTimeout))s"
            )
        case .gitUnavailable:
            return .failed("git is unavailable at clean time")
        }

        guard let inventory = GitWorktreeInventory.parse(stdout) else {
            return .failed("the porcelain -z listing could not be parsed")
        }
        switch mapper.map(
            prunableRecordsIn: inventory.entries,
            adminContainer: plan.parentAdminContainer
        ) {
        case .complete(let directories):
            return .set(directories)
        case .incomplete(let reason):
            return .failed("the prunable set is not provably complete: \(reason)")
        }
    }

    // MARK: - Guard plumbing

    private typealias GuardedPath = (
        label: String, url: URL,
        containment: PathGuard.SubprocessTraversalContainment
    )

    /// The paths the D13 guard covers at ADMISSION time, per mode.
    private func admissionPaths(for plan: GitWorktreeReclaimPlan) -> [GuardedPath] {
        var paths: [GuardedPath] = [
            (label: "parent repository", url: plan.parentRepoWorkingDir,
             containment: .descendantOrEqual),
            (label: "admin container", url: plan.parentAdminContainer,
             containment: .strictDescendant),
        ]
        if let worktreePath = plan.worktreePath {
            paths.append((
                label: "worktree", url: worktreePath,
                containment: .strictDescendant
            ))
        }
        return paths
    }

    /// The paths the repository-level mutation covers: the `-C` target (the
    /// oracle recompute and R0 both traverse it immediately before) and the
    /// admin container the removal rewrites.
    private func prunePaths(for plan: GitWorktreeReclaimPlan) -> [GuardedPath] {
        [
            (label: "parent repository", url: plan.parentRepoWorkingDir,
             containment: .descendantOrEqual),
            (label: "admin container", url: plan.parentAdminContainer,
             containment: .strictDescendant),
        ]
    }

    private func guardTraversal(
        _ paths: [GuardedPath], inside container: AdmittedContainer
    ) throws {
        for path in paths {
            try pathGuard.validateSubprocessTraversalDirectory(
                path.url, inside: container, containment: path.containment
            )
        }
    }

    /// An affected admin directory is BOTH a deletion-scope path (the prune
    /// removes it) and a traversal path (the prune recurses into it), so it
    /// faces both checks.
    private func admitAffectedAdminDirectory(
        _ directory: URL, inside container: AdmittedContainer
    ) throws {
        try pathGuard.validateRemovableItem(directory, inside: container)
        try pathGuard.validateSubprocessTraversalDirectory(
            directory, inside: container, containment: .strictDescendant
        )
    }

    // MARK: - Result plumbing

    private func entry(
        for item: ReclaimableItem,
        accepted: AcceptedByteComponents,
        disposal: CleanupReport.Disposal,
        warning: String? = nil
    ) -> CleanupReport.Entry {
        CleanupReport.Entry(
            itemID: item.id, scannerID: item.scannerID,
            displayName: item.displayName,
            exactBytes: accepted.exactBytes,
            estimatedUpToBytes: accepted.estimatedUpToBytes,
            disposal: disposal,
            warning: warning
        )
    }

    /// A PathGuard (or other thrown) refusal, logged with its typed tag.
    private func refusal(
        _ item: ReclaimableItem, _ error: Error, at path: URL
    ) -> WorktreeReclaimOutcome {
        logRefusal(
            CacheCleaner.refusalTag(error),
            "\(path.path): \(error.localizedDescription)"
        )
        return WorktreeReclaimOutcome(entry: nil, errors: [
            CacheCleaner.itemError(item, error.localizedDescription),
        ])
    }

    /// A per-item failure with an already-composed message. Named `failure`
    /// rather than `error` on purpose: inside a `catch` the latter would be
    /// shadowed by the caught error.
    private func failure(
        _ item: ReclaimableItem, _ message: String, tag: String?
    ) -> WorktreeReclaimOutcome {
        if let tag { logRefusal(tag, message) }
        return WorktreeReclaimOutcome(entry: nil, errors: [
            CacheCleaner.itemError(item, message),
        ])
    }

    /// The refusal TAG for a clean reading that did not answer "clean".
    /// `.clean` never reaches here — a clean reading always carries its
    /// ignored set — so the arm is total over what a caller can hold.
    private static func uncleanTag(_ verdict: WorktreeCleanVerdict) -> String {
        if case .dirty = verdict { return "worktree-dirty" }
        return "worktree-recheck-failed"
    }

    /// The user-facing sentence for the same, with the action that clears it.
    /// RETRY: both classes clear — a dirty tree clears when the work is
    /// committed, stashed or discarded; an unanswered check clears when git
    /// can answer. Neither keys on a deterministic limit.
    private static func uncleanDetail(_ verdict: WorktreeCleanVerdict) -> String {
        switch verdict {
        case .dirty(let entryCount):
            return "aborted: the delete-time re-check found this worktree "
                + "DIRTY (\(entryCount) porcelain "
                + "\(entryCount == 1 ? "entry" : "entries")) — the tree was "
                + "left untouched. Commit, stash or discard that work, then "
                + "re-scan."
        case .failed(let reason):
            return "aborted: the delete-time re-check could not prove this "
                + "worktree clean (\(reason)) — the tree was left untouched. "
                + "Retry once git can answer."
        case .clean:
            return "aborted: the delete-time re-check reported CLEAN without "
                + "an ignored-path reading, which cannot happen — the tree "
                + "was left untouched. Re-scan to rebuild this item."
        }
    }

    private func warning(_ cause: String) -> String {
        "\(cause) — \(Self.orphanedAdminWarning)"
    }

    // MARK: - Small shared helpers

    /// Lexical path comparison on STANDARDIZED spellings (`.`, `//` and
    /// trailing slashes collapsed, no symlink resolution): the recomputed set
    /// and the plan's disclosed set are both built by appending an admin
    /// entry's name to the SAME carried container, so they compare as
    /// spellings — the mapper's own traversal gates are what prove those
    /// spellings are real, contained directories.
    private static func standardPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        standardPath(lhs) == standardPath(rhs)
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(Int(interval.rounded()))
    }

    /// The porcelain record's HEAD, abbreviated for a human-readable refusal.
    /// `unknown` rather than an empty slot when git emitted no `HEAD` line —
    /// the message must never read as if it named a commit it did not.
    static func shortOID(_ sha: String?) -> String {
        guard let sha, sha.count >= 8 else { return sha ?? "unknown" }
        return String(sha.prefix(12))
    }
}
