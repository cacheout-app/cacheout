/// # WorktreeReclaimPerformer — git-mediated worktree reclaim (fn-5.4, R5/R6/R8)
///
/// The execution behind the composite `ReclaimAction.gitWorktreeReclaim`, in
/// two modes:
///
/// - **`removeStaleWorktree`** — `git -C <parent> worktree remove <path>`
///   first (never `--force`), with a guarded filesystem fallback + a GATED
///   removal of that worktree's OWN admin entry when git refuses with a
///   nonzero exit, the tree re-checks CLEAN, and the delete-time gate
///   re-establishment below still passes.
/// - **`pruneOrphanedAdmin`** — a SCOPED removal of exactly the
///   PROVABLY-COMPLETE admin-directory set the scan disclosed (D14), never a
///   repository-wide `git worktree prune` (see `removeAdminDirectories`).
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
/// wording, "re-runs IMMEDIATELY before EVERY git invocation", was FALSE:
/// `grep -n guardTraversal` returned six sites and none of them was inside
/// `reestablishStaleGates`, which fires five invocations of its own):
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
/// | pre-`worktree remove` (stale)    | parent, worktree       | R0, R2's ladder + ancestry, and `worktree remove` itself |
/// | inside R1 (PR #460 codex r2)     | parent, admin container | the `worktree list` re-read — it ENUMERATES `$GIT_COMMON_DIR/worktrees` to answer `prunable`, and the pre-remove guard covers only the parent and the worktree |
/// | fallback entry                   | worktree, admin container, parent | the `status` re-check (git follows `<wt>/.git` INTO the admin/common git dir, so a swap in EITHER would redirect it — epic round 6) and the fallback's own R0/R1/R1b/R2 |
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
/// them (G2, and only inside the fallback), so a worktree that was locked,
/// deregistered, or committed into between the scan and the click was
/// destroyed anyway — with an empty error list. `reestablishStaleGates` now
/// re-proves R0 (repository identity), R1 (G1 + G4 + the registration
/// itself, from the re-read porcelain record), R1b (WHICH worktree that
/// record is about) and R2 (G3, through the shared `GitWorktreeMergedCheck`)
/// immediately before the mutation, at BOTH mutating sites: before
/// `worktree remove`, and again inside the fallback before the filesystem
/// delete.
///
/// ## RUNNER-RESULT ROUTING IS TOTAL
///
/// Every `GitCommandOutcome` is switched EXHAUSTIVELY at every call site —
/// there is no "any failure" arm anywhere, because the four classes mean
/// different things: exit 0 is the ONLY signal that admits pre-registered
/// claims; a nonzero exit is git's considered refusal (and the ONLY fallback
/// trigger); a TIMEOUT may have left a partially-removed tree and therefore
/// never falls back and never accepts; `gitUnavailable` executed nothing at
/// all.
///
/// ## THE TWO NAMED FALLBACK TRIGGER CLASSES (D4)
///
/// Both are the NONZERO-EXIT class — never a failure-string match, never the
/// timeout class:
/// 1. an ignored-tree "Directory not empty" refusal (the field class:
///    `status --porcelain` omits ignored files, so the re-check passes);
/// 2. a CLEAN worktree containing a POPULATED SUBMODULE — git's
///    `validate_no_submodules` refuses without `--force`, the re-check
///    passes, and the fallback delete is ACCEPTED (the targets are user-owned
///    dev roots and the parent's absorbed `modules/` object store is
///    untouched; refs of an attached branch survive).
///
/// THE ROUTING ENUMERATES ZERO OF THOSE CLASSES, and that is deliberate — a
/// classification derived from git's message text is forbidden here. What
/// SEPARATES the two intended classes from git's own SAFETY refusals is the
/// re-established state, not the wording: a lock refusal leaves the porcelain
/// record `locked`, an "is not a working tree" refusal leaves no record at
/// all, and both are refused by R1. The ignored-tree and submodule refusals
/// leave the record registered, linked and unlocked, so they proceed. Before
/// PR #460 the fallback re-checked only cleanliness and therefore achieved
/// `remove -f -f`'s effect on a locked worktree without the flag — measured,
/// with `errors=[]`.
///
/// ## ACCOUNTING (mirrors `removeGuardedItem`; D14's verified-removal for prune)
///
/// Claims are measured and REGISTERED before any git runs, and accepted ONLY
/// after the removal actually succeeded — git exit 0, or the fallback delete.
/// A failed or aborted removal accepts nothing; its registrations stay
/// transferable by siblings. Prune mode goes further (D14 round 4): it
/// measures the RECOMPUTED set at delete time, never the scan-time disclosed
/// measures, and accepts only the dirs it can VERIFY disappeared — a
/// disclosed entry that became locked or repaired since the scan is not in
/// the final removal set at all, and reporting its bytes as freed would be a
/// lie.
///
/// ## DISPOSAL HONESTY (D16)
///
/// The git-removal entry and every prune-only entry are `.permanent` ALWAYS,
/// whatever the Move-to-Trash toggle says: git unlinks and prunes, it does not
/// trash (the command-backed-category precedent, `ScanResult.swift`). ONLY the
/// filesystem fallback honours the toggle, and its entry is `.trash` only when
/// the trash handler ACTUALLY succeeded — a trash failure is an error and
/// yields no entry at all, never a fall-through to a permanent delete.

import Foundation

/// The performer's per-item result, in the shape `CacheCleaner.clean(items:)`
/// consumes from every other action.
struct WorktreeReclaimOutcome {
    var entry: CleanupReport.Entry?
    var errors: [CleanupReport.ItemError]

    static let none = WorktreeReclaimOutcome(entry: nil, errors: [])
}

struct WorktreeReclaimPerformer {

    // MARK: - Pinned constants

    /// DELETE-TIME budget, PER GIT INVOCATION — minutes-scale on purpose and
    /// never fn-5.1's ~10 s scan default: a mid-removal timeout on a
    /// multi-GB tree leaves partial state, so this caller must be able to buy
    /// patience. Injectable; under D18's no-client-timeout rule this budget
    /// plus the runner's termination protocol is the REAL bound.
    static let deleteTimeGitTimeout: TimeInterval = 300

    /// The D11 warning tail every post-fallback prune OUTCOME that left admin
    /// data behind carries — the conservative skip (round 8) and every prune
    /// failure after a successful delete alike. EXCLUSIVE to stale mode:
    /// prune-only failures are ERRORS, never warnings.
    static let orphanedAdminWarning =
        "orphaned admin data remains; next scan will offer it"

    // MARK: - Argv (registry code, built from PLAN FIELDS — never carried)

    /// `git -C <parent> worktree remove <worktree>`.
    ///
    /// The `-C <parent>` form is REQUIRED, not stylistic: `worktree remove`
    /// fails when the process CWD is inside the target, and pinning `-C` to
    /// the parent keeps CWD out of the doomed tree. `--force` NEVER appears —
    /// git's own dirty-refusal is a free TOCTOU gate this epic depends on.
    static func removeArguments(
        parentRepoWorkingDir: URL, worktreePath: URL
    ) -> [String] {
        ["-C", parentRepoWorkingDir.path, "worktree", "remove", worktreePath.path]
    }

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
    /// The run's REQUESTED disposal mode. Only the filesystem fallback honours
    /// it (D16).
    let moveToTrash: Bool
    /// The RAW mover, answering WHERE IT LANDED — `nil` when the disposal
    /// would not say. It is never called directly: the fallback reaches it
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
    let trash: (URL) async throws -> URL?
    /// The permanent-delete seam. It takes the container binding as a SECOND
    /// argument (fn-6 reconciliation) because the removal it fronts —
    /// `DepthSafeRemoval.remove` — proves the folder it opens against an
    /// identity captured from a descriptor BEFORE the hop onto its background
    /// queue. Passing the binding rather than deriving it inside the seam is
    /// what lets the capture happen at the point the ordering requires (see
    /// the fallback's use site), not wherever the closure happens to run.
    let removeTree: (URL, DepthSafeRemoval.AdmittedParent) async throws -> Void
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
        // fallback would recurse straight through an inner mount.
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

        // (7) The guard re-runs immediately before the invocation, over the
        // two paths `worktree remove` traverses.
        do {
            try guardTraversal([
                (label: "parent repository", url: plan.parentRepoWorkingDir,
                 containment: .descendantOrEqual),
                (label: "worktree", url: worktreePath,
                 containment: .strictDescendant),
            ], inside: container)
        } catch {
            return refusal(item, error, at: worktreePath)
        }

        // (8) THE DELETE-TIME GATE RE-ESTABLISHMENT. Placed HERE, before the
        // primary invocation, so it covers BOTH arms: the fallback is only
        // reachable through the `worktree remove` below. It runs its OWN D13
        // guards, per invocation group (PR #460 codex r2) — the guard at (7)
        // covers the mutation's two paths and does not cover the admin
        // container `worktree list` enumerates.
        if case .refuse(let tag, let detail) = await reestablishStaleGates(
            plan: plan, worktreePath: worktreePath, adminEntry: adminEntry,
            container: container
        ) {
            return failure(item, detail, tag: tag)
        }

        let removal = await runner.run(
            Self.removeArguments(
                parentRepoWorkingDir: plan.parentRepoWorkingDir,
                worktreePath: worktreePath
            ),
            timeout: gitTimeout
        )

        switch removal.outcome {
        case .success:
            // git removed the tree AND its own admin directory — no prune is
            // needed or run. Exit 0 is the signal that admits the claims.
            let accepted = await registry.acceptSuccessful(token)
            logCleaned(accepted.exactBytes + accepted.estimatedUpToBytes)
            return WorktreeReclaimOutcome(
                entry: entry(
                    for: item, accepted: accepted,
                    // D16: git unlinks regardless of the Trash toggle.
                    disposal: .permanent
                ),
                errors: []
            )

        case .timeout:
            // NEVER the fallback: compounding a partially-removed tree with a
            // filesystem delete is how a half-removed worktree becomes an
            // unrecoverable one. Nothing is accepted.
            let detail = "git worktree remove timed out after "
                + "\(Self.seconds(gitTimeout))s; the tree may be partially "
                + "removed — rescan required"
            logRefusal("git-timeout", detail)
            return failure(item, detail, tag: nil)

        case .gitUnavailable:
            let detail = "refused: git is unavailable at clean time — nothing "
                + "was reclaimed"
            logRefusal("git-unavailable", detail)
            return failure(item, detail, tag: nil)

        case .failure(let exitCode, let stderr):
            // The ONE fallback trigger class (D4), reached by EXIT CODE — the
            // message is display only and is never matched on.
            return await fallbackAfterRefusal(
                item: item, plan: plan, origin: origin, container: container,
                worktreePath: worktreePath, adminEntry: adminEntry,
                registry: registry, token: token,
                gitRefusal: GitCommandFailureSummary.describe(
                    exitCode: exitCode, stderr: stderr
                )
            )
        }
    }

    /// git refused with a nonzero exit: re-check CLEAN through the seam's
    /// check, then delete the tree ourselves under the `removeGuardedItem`
    /// doctrine, then run the GATED prune.
    private func fallbackAfterRefusal(
        item: ReclaimableItem,
        plan: GitWorktreeReclaimPlan,
        origin: URL,
        container: AdmittedContainer,
        worktreePath: URL,
        adminEntry: URL,
        registry: InodeAccountingRegistry,
        token: RegisteredChild,
        gitRefusal: String
    ) async -> WorktreeReclaimOutcome {
        // The guard re-runs over BOTH paths the re-check traverses (round 6):
        // `git -C <wt> status` follows `<wt>/.git` INTO the admin container,
        // so a leaf swapped to a symlink in EITHER between the remove failure
        // and this call would redirect the check outside the container. The
        // PARENT joins them (PR #460 codex r1) because the gate
        // re-establishment below re-reads the repository and its registry
        // with `-C <parent>`.
        do {
            try guardTraversal([
                (label: "worktree", url: worktreePath,
                 containment: .strictDescendant),
                (label: "admin container", url: plan.parentAdminContainer,
                 containment: .strictDescendant),
                (label: "parent repository", url: plan.parentRepoWorkingDir,
                 containment: .descendantOrEqual),
            ], inside: container)
        } catch {
            return refusal(item, error, at: worktreePath)
        }

        // ONE implementation of the clean check, shared with the G2 gate
        // (fn-5.2) — the scan and the deletion can never disagree about what
        // "clean" means. Its verdict is TOTAL over the runner's four classes,
        // and `.failed` is deliberately distinct from `.dirty` so the abort
        // wording can differ.
        let verdict = await GitWorktreeCleanCheck.run(
            worktreeAt: worktreePath, using: runner, timeout: gitTimeout
        )
        switch verdict {
        case .clean:
            break
        case .dirty(let entryCount):
            let detail = "aborted: git refused to remove this worktree "
                + "(\(gitRefusal)) and the delete-time re-check found it "
                + "DIRTY (\(entryCount) porcelain "
                + "\(entryCount == 1 ? "entry" : "entries")) — the tree was "
                + "left untouched"
            logRefusal("worktree-dirty", detail)
            return failure(item, detail, tag: nil)
        case .failed(let reason):
            let detail = "aborted: git refused to remove this worktree "
                + "(\(gitRefusal)) and the delete-time re-check could not "
                + "prove it clean (\(reason)) — the tree was left untouched"
            logRefusal("worktree-recheck-failed", detail)
            return failure(item, detail, tag: nil)
        }

        // THE GATE RE-ESTABLISHMENT, AGAIN — and this is the placement that
        // makes the fallback safe rather than merely earlier.
        //
        // `case .failure` upstream routes EVERY nonzero exit here, so the
        // classes that arrive include git's own SAFETY refusals: a lock, a
        // deregistered path. Re-running R0/R1/R2 immediately before the
        // filesystem delete is what discriminates them from the two intended
        // trigger classes — and it does it from the re-read porcelain RECORD,
        // never from git's stderr. Running the same check only before
        // `worktree remove` would leave the window between that check and
        // this delete open, which is the window a lock acquired mid-operation
        // lands in.
        if case .refuse(let tag, let detail) = await reestablishStaleGates(
            plan: plan, worktreePath: worktreePath, adminEntry: adminEntry,
            container: container
        ) {
            return failure(
                item,
                "\(detail) (git had refused with: \(gitRefusal))",
                tag: tag
            )
        }

        // Still clean → the guarded filesystem fallback, `removeGuardedItem`'s
        // doctrine verbatim: TOCTOU re-admission immediately pre-delete, then
        // the trash toggle (a trash failure is an error, NEVER a fall-through
        // to a permanent delete).
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
            // BOTH ARMS USE IT. It was captured for the permanent arm alone
            // and the Trash arm — the GUI's default, `moveToTrash` is `true`
            // out of the box — handed the mover a bare URL beside it, which
            // made this the one deletion path in the app with no container
            // binding (fn-5/fn-6 reconciliation). The ordering the capture
            // already had is the ordering the Trash arm needs: the binding
            // covers the two rechecks below, not merely the seam call.
            let admittedParent = try DepthSafeRemoval.admittedParent(
                directory: worktreePath.deletingLastPathComponent(),
                displayPath: worktreePath.path, provider: provider
            )
            let recheck = try pathGuard.admitContainer(origin, snapshot: snapshot)
            try pathGuard.validateRemovableItem(worktreePath, inside: recheck)
            if moveToTrash {
                // NO LEAF VERDICT, WHICH IS THE POPULATION THIS OVERLOAD IS
                // FOR: `git_worktrees` registers no `PreDeleteRevalidator`, so
                // there is nothing to bind the leaf's CONTENTS to — but there
                // is an admitted container, and a leaf read under a proved
                // container descriptor is a fact about an OBJECT. The disposal
                // binds it before the move, re-reads it where the mover says
                // it landed, and PUTS BACK anything it cannot prove: no entry,
                // no bytes.
                try await TrashDisposal.dispose(
                    worktreePath, containedIn: admittedParent,
                    provider: provider, via: trash
                )
            } else {
                try await removeTree(worktreePath, admittedParent)
            }
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
        let warning = await gatedPostFallbackPrune(
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

    /// The GATED post-fallback prune (epic round 8 / D14). Returns the D11
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
    private func gatedPostFallbackPrune(
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
                try await removeTree(directory, admittedParent)
            } catch {
                // A mid-loop failure leaves the directories already removed
                // genuinely gone. Their bytes are NOT reported: this returns
                // an error and no entry, which under-reports what was freed
                // rather than over-reporting it. (In practice the set is one
                // directory — the field shape and the only shape the gated
                // post-fallback prune can ever have.)
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
    /// G2 is deliberately absent here and is NOT an omission: the primary arm
    /// is `git worktree remove` WITHOUT `--force`, whose own dirty-refusal is
    /// the gate (measured: exit 128 `contains modified or untracked files`),
    /// and the fallback re-runs `GitWorktreeCleanCheck` itself before it
    /// deletes anything. Every other scan-time gate is listed above.
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
    ) async -> GateReestablishment {
        // R0 traverses the `-C` target ONLY, and the caller guarded exactly
        // that path immediately before entering here — the primary arm at
        // step (7), the fallback at its own entry. NO extra guard is added:
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

        // R2's ladder runs `-C <parent>` and its ancestry runs
        // `-C <worktree>` — the two paths the caller guarded on entry, and
        // no others. Same reasoning as R0: no extra guard.
        return await reestablishAncestry(
            plan: plan, worktreePath: worktreePath, record: record
        )
    }

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
    /// THIS IS WHAT DISCRIMINATES THE FALLBACK'S TRIGGER CLASSES, and it does
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
        // filesystem fallback that ignored the lock would achieve exactly
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
            worktreePath: worktreePath, adminEntry: adminEntry
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
    /// RETRY: yes, and it can differ. Every class refused here is a change a
    /// re-scan re-evaluates from scratch — the checkout now at that path
    /// becomes its own candidate, or fails the four gates on its own merits,
    /// or is not offered at all.
    ///
    /// RESIDUAL, MEASURED (git 2.50.1, this machine): a user who removes the
    /// stale worktree and then re-adds one AT THE SAME PATH gets an admin
    /// directory of the SAME NAME back (`worktrees/<basename>` is freed by
    /// the removal and reused by the add; the two directories' inodes
    /// differed, 110794887 → 110794910). The plan carries a PATH, not the
    /// scan-time inode, so that one re-creation is indistinguishable here.
    /// Closing it needs a scan-time identity carried in
    /// `GitWorktreeReclaimPlan` — the fn-6 shape — which is a schema change
    /// this round did not take. The `git worktree move` and
    /// `add-under-a-different-path` shapes ARE closed, and those are the ones
    /// that were measured destroying live work.
    private func reestablishWorktreeIdentity(
        worktreePath: URL, adminEntry: URL
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
        return .proceed
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
