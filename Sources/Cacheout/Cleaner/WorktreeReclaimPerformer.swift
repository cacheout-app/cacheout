/// # WorktreeReclaimPerformer — git-mediated worktree reclaim (fn-5.4, R5/R6/R8)
///
/// The execution behind the composite `ReclaimAction.gitWorktreeReclaim`, in
/// two modes:
///
/// - **`removeStaleWorktree`** — `git -C <parent> worktree remove <path>`
///   first (never `--force`), with a guarded filesystem fallback + a GATED
///   `worktree prune --expire=now` when git refuses with a nonzero exit and
///   the tree re-checks CLEAN.
/// - **`pruneOrphanedAdmin`** — a repository-level
///   `git -C <parent> worktree prune --expire=now` over the PROVABLY-COMPLETE
///   admin-directory set the scan disclosed (D14).
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
/// `PathGuard.validateSubprocessTraversalDirectory` re-runs IMMEDIATELY before
/// EVERY git invocation, over exactly the paths that invocation traverses:
///
/// | invocation                       | guarded paths                          |
/// |----------------------------------|----------------------------------------|
/// | admission (both modes)           | parent (or-equal), admin container; stale mode adds the worktree |
/// | `worktree remove`                | parent (`-C`), the worktree argument   |
/// | `status` re-check                | the worktree (`-C`) AND the admin container — git follows `<wt>/.git` INTO the admin/common git dir, so a swap in EITHER between the remove failure and the re-check would redirect it (epic round 6) |
/// | oracle recompute (`worktree list`) | parent (`-C`)                        |
/// | `worktree prune`                 | parent (`-C`), admin container         |
/// | each affected admin dir (prune mode) | the dir itself, strictly           |
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
///    untouched; branch refs survive).
///
/// ## ACCOUNTING (mirrors `removeGuardedItem`; D14's verified-removal for prune)
///
/// Claims are measured and REGISTERED before any git runs, and accepted ONLY
/// after the removal actually succeeded — git exit 0, or the fallback delete.
/// A failed or aborted removal accepts nothing; its registrations stay
/// transferable by siblings. Prune mode goes further (D14 round 4): it
/// measures the RECOMPUTED set at delete time, never the scan-time disclosed
/// measures, and after exit 0 accepts only the dirs it can VERIFY disappeared
/// — a disclosed entry that became locked or repaired since the scan survives
/// the repo-wide prune, and reporting its bytes as freed would be a lie.
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

    /// `git -C <parent> worktree prune --expire=now`.
    ///
    /// `--expire=now` is LOAD-BEARING (D10): a bare prune respects
    /// `gc.worktreePruneExpire` (default 3 months) for the expire-gated
    /// orphan classes, so detection would offer a fresh orphan that execution
    /// silently left behind — a recurring ~0-byte "success".
    static func pruneArguments(parentRepoWorkingDir: URL) -> [String] {
        ["-C", parentRepoWorkingDir.path, "worktree", "prune", "--expire=now"]
    }

    // MARK: - Injected seams

    let pathGuard: PathGuard
    let provider: FileSystemIdentityProvider
    /// The producing scan session's container snapshot — delete-time
    /// admission is identity-bound to it (fn-3.4, R9).
    let snapshot: ContainerSnapshot
    let runner: any GitCommandRunning
    /// fn-5.1's SHARED oracle→admin mapper — the SAME implementation fn-5.5
    /// discloses with. A second mapping would let detection and execution
    /// disagree about a repository-wide side effect.
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
        // and this call would redirect the check outside the container.
        do {
            try guardTraversal([
                (label: "worktree", url: worktreePath,
                 containment: .strictDescendant),
                (label: "admin container", url: plan.parentAdminContainer,
                 containment: .strictDescendant),
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
    /// recomputed and the prune runs ONLY when that set is EXACTLY the
    /// just-deleted worktree's own admin entry.
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
            // prunable set, and git's own prune would skip it too) — claiming
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
                    + "— pruning would have swept admin data this item never "
                    + "disclosed"
            )
        }

        // The guard re-runs over both paths `worktree prune` traverses.
        do {
            try guardTraversal(prunePaths(for: plan), inside: container)
        } catch {
            return warning(
                "the pre-prune traversal guard refused "
                    + "(\(error.localizedDescription))"
            )
        }

        let prune = await runner.run(
            Self.pruneArguments(parentRepoWorkingDir: plan.parentRepoWorkingDir),
            timeout: gitTimeout
        )
        switch prune.outcome {
        case .success:
            return nil
        case .failure(let exitCode, let stderr):
            return warning(
                "worktree prune failed "
                    + "(\(GitCommandFailureSummary.describe(exitCode: exitCode, stderr: stderr)))"
            )
        case .timeout:
            return warning(
                "worktree prune timed out after \(Self.seconds(gitTimeout))s"
            )
        case .gitUnavailable:
            return warning("git became unavailable before the prune ran")
        }
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
            // (5) MOUNT DOCTRINE (epic round 9): `worktree prune` is a
            // RECURSIVE filesystem mutation over these directories, so the
            // boundary-bearing-recursive-delete rule applies exactly as it
            // does to `removeItem` — and it fails CLOSED here, BEFORE any
            // claim is registered and before the prune runs. The D13 guard
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
        // subprocess: the admission and sizing walks above take time, and an
        // orphan that appeared DURING them would be pruned outside every set
        // this item ever checked. Shrinkage stays legal — verified-removal
        // accounting already handles a survivor.
        let checked = Set(recomputed.map(Self.standardPath))
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
        }

        // (9) The guard re-runs over both paths `worktree prune` traverses.
        do {
            try guardTraversal(prunePaths(for: plan), inside: container)
        } catch {
            return refusal(item, error, at: plan.parentAdminContainer)
        }

        let prune = await runner.run(
            Self.pruneArguments(parentRepoWorkingDir: plan.parentRepoWorkingDir),
            timeout: gitTimeout
        )
        switch prune.outcome {
        case .success:
            break
        case .failure(let exitCode, let stderr):
            let detail = "worktree prune failed "
                + "(\(GitCommandFailureSummary.describe(exitCode: exitCode, stderr: stderr)))"
                + " — nothing was pruned"
            logRefusal("prune-failed", detail)
            return failure(item, detail, tag: nil)
        case .timeout:
            // git may have pruned SOME entries before the kill: never report
            // success, never guess bytes.
            let detail = "prune timed out; the registry may be PARTIALLY "
                + "cleaned — rescan required"
            logRefusal("prune-timeout", detail)
            return failure(item, detail, tag: nil)
        case .gitUnavailable:
            let detail = "git unavailable at clean time — nothing was pruned"
            logRefusal("git-unavailable", detail)
            return failure(item, detail, tag: nil)
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
        // The recompute is `git -C <parent> worktree list` — the guard runs
        // over the parent it traverses.
        do {
            try guardTraversal([
                (label: "parent repository", url: plan.parentRepoWorkingDir,
                 containment: .descendantOrEqual),
            ], inside: container)
        } catch {
            return .failed(
                "the traversal guard refused the parent repository "
                    + "(\(error.localizedDescription))"
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

    /// The paths `worktree prune` traverses: the `-C` target and the admin
    /// container it rewrites.
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
}
