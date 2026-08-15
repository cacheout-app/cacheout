/// # WorktreeStalenessAssessor — the four fail-closed gates (fn-5.2, R1/R2/R3)
///
/// Given ONE `git worktree list --porcelain -z` record (fn-5.1's
/// `GitWorktreeEntry`) plus the parent repository's working directory
/// (fn-5.1's `WorktreeMembership.parentRepoWorkingDir` — the round-4
/// authority, NEVER derived from `parentGitDir`), decide whether that
/// worktree is a removal CANDIDATE and produce the evidence string a human
/// reads before approving a deletion.
///
/// This file makes no deletion decision beyond "candidate / not", emits no
/// items (D15 — non-candidates are omitted from items entirely; fn-5.5 owns
/// emission), and never bypasses `GitCommandRunning`.
///
/// ## The four gates (conjunctive, each individually FAIL-CLOSED)
///
/// - **G1 not-main/not-bare** — porcelain POSITION (`isMain`) and the `bare`
///   attribute. No git call.
/// - **G2 clean** — `git -C <wt> status --porcelain --ignore-submodules=none
///   --untracked-files=normal` with EMPTY stdout. Neither flag is
///   decoration: a repository can CONFIGURE its way to a false "clean", and
///   this gate authorises a deletion. `--ignore-submodules=none` is what
///   git's own `check_clean_worktree` (builtin/worktree.c) passes and
///   overrides `submodule.<name>.ignore` / `diff.ignoreSubmodules`;
///   `--untracked-files=normal` overrides `status.showUntrackedFiles=no`.
///   Both holes are verified on git 2.50.1 and both are proven by fixtures
///   that assert the bare-default command reports the tree CLEAN. Exported
///   standalone as `GitWorktreeCleanCheck` because fn-5.4's revalidator
///   re-runs exactly this check immediately before the filesystem fallback;
///   one implementation, two call sites.
/// - **G3 merged** — LOCAL ancestry only. The default branch is resolved in
///   the PARENT repo (`refs/remotes/origin/HEAD` → `refs/heads/main` →
///   `refs/heads/master` → fail closed, D6) and then
///   `git -C <wt> merge-base --is-ancestor HEAD <default>` decides. Exit 0
///   is the only pass; exit 1 is git's ANSWER "not an ancestor" and exit 128
///   is "could not answer" — they are never conflated, and neither passes.
///   The same discipline governs the ladder itself: only a SILENT exit 1
///   ("this ref is not there") moves to the next rung, while a rung that
///   FAILED — including git's talkative exit 1 for an unreadable ref —
///   fails the gate closed rather than silently promoting a lower rung to
///   default branch. No network anywhere (the Boundaries forbid
///   `fetch`/`remote prune`).
/// - **G4 not locked** — porcelain `locked`. A locked worktree is NEVER a
///   candidate; this epic has no lock handling at all (`--force`, including
///   the "twice for locked" trick, is a Boundaries violation).
///
/// EVERY gate is evaluated even after an earlier one fails: the evidence
/// format below requires all four clauses ALWAYS, and the per-worktree git
/// calls are bounded. Any command failure, timeout, git unavailability, or
/// unreadable output fails the affected gate CLOSED with the cause NAMED —
/// never a silent pass, never an unexplained one. The cost asymmetry is the
/// whole reason: a wrongly deleted dirty worktree loses human work, a missed
/// stale one merely wastes disk.
///
/// ## The canonical FOUR-CLAUSE evidence format (epic round 10, R1/R3/R10)
///
/// Every assessment — candidate AND non-candidate — renders all four gate
/// clauses, in G1…G4 order, joined by `"; "`. A candidate additionally
/// carries the display tail:
///
///     G1 linked (not main/bare); G2 clean; G3 HEAD is ancestor of
///     refs/heads/main; G4 not locked; last commit 2026-08-14; branch ref
///     survives removal
///
/// and a multi-failure assessment names every failing gate in the ONE string:
///
///     G1 linked (not main/bare); G2 dirty: 3 modified/untracked entries;
///     G3 HEAD not an ancestor of refs/heads/main (squash/rebase merges not
///     detected); G4 locked: in use on laptop
///
/// The hedged wording lives INSIDE the G3 clause (D5): `--is-ancestor`
/// structurally misses squash and rebase merges, so the evidence never
/// asserts "not merged" as fact. The date slot renders either the date or
/// the explicit `last commit unavailable` marker — the field is never
/// silently absent, and a date-lookup failure NEVER fails an assessment
/// (last activity is a display tiebreaker, never a gate).
///
/// ## D17 safety profile
///
/// Every command here (`status`, `symbolic-ref`, `rev-parse`, `merge-base`,
/// `show`) is READ-ONLY, and fn-5.1's runner classifies by COMMAND — so the
/// read-only profile (`GIT_OPTIONAL_LOCKS=0` + `-c core.fsmonitor=false`)
/// rides every invocation automatically, including the ones aimed at parent
/// repositories outside the effective dev roots. The assessor therefore does
/// NO per-gate profile handling; it just never bypasses the runner.

import Foundation

// MARK: - Gates

/// The four gates, in evidence order. The raw values ARE the evidence
/// clause prefixes.
enum WorktreeGate: String, Equatable, Sendable, CaseIterable {
    /// Not the main worktree and not a bare repository.
    case notMainOrBare = "G1"
    /// `status --porcelain --ignore-submodules=none` is empty.
    case clean = "G2"
    /// HEAD is a local ancestor of the resolved default branch.
    case merged = "G3"
    /// Not locked.
    case notLocked = "G4"
}

/// One gate's verdict plus the human-readable clause BODY that goes into the
/// evidence string after the gate's prefix.
struct WorktreeGateOutcome: Equatable, Sendable {
    let gate: WorktreeGate
    let passed: Bool
    /// The clause body — e.g. `clean`, `dirty: 3 modified/untracked entries`,
    /// `default branch unresolvable`. Rendered as `"<gate.rawValue> <reason>"`.
    let reason: String

    /// The evidence clause this outcome contributes.
    var clause: String { "\(gate.rawValue) \(reason)" }
}

// MARK: - Assessment

/// The result of running all four gates against one worktree.
struct WorktreeAssessment: Equatable, Sendable {
    /// The worktree the gates ran against — the porcelain record's path,
    /// verbatim as git spelled it (also the `-C` target used).
    let worktreePath: URL
    /// All four outcomes, ALWAYS in G1…G4 order and always complete.
    let gates: [WorktreeGateOutcome]
    /// Committer date of the worktree's HEAD. Display only — never a gate.
    /// `nil` when the lookup failed OR when it was never run: it feeds only
    /// the candidate tail, and non-candidates are not emitted as items (D15),
    /// so a non-candidate never pays the extra subprocess.
    let lastCommitDate: Date?
    /// The canonical four-clause string (plus the candidate tail).
    let evidence: String

    /// Conjunctive: all four gates passed.
    var isCandidate: Bool { gates.allSatisfy(\.passed) }

    /// One gate's outcome. `nil` is impossible for a well-formed assessment
    /// (the assessor always fills all four) and exists only so callers need
    /// no force-unwrap.
    func outcome(for gate: WorktreeGate) -> WorktreeGateOutcome? {
        gates.first { $0.gate == gate }
    }
}

/// What the assessor answers for one porcelain record.
enum WorktreeAssessmentResult: Equatable, Sendable {
    /// All four gates ran.
    case assessed(WorktreeAssessment)
    /// A PRUNABLE record: its checkout is already gone, so there is no tree
    /// to gate and nothing for this task to remove — fn-5.5's orphaned-admin
    /// tier owns the shape. A distinct NON-GATE refusal, deliberately not
    /// dressed up as a failed gate (its evidence would otherwise claim four
    /// gate answers about a directory that does not exist).
    case prunableNotAssessed(reason: String)

    /// Never true for a refusal.
    var isCandidate: Bool {
        guard case .assessed(let assessment) = self else { return false }
        return assessment.isCandidate
    }

    var assessment: WorktreeAssessment? {
        guard case .assessed(let assessment) = self else { return nil }
        return assessment
    }
}

// MARK: - G2, exported for fn-5.4

/// The G2 clean verdict. `failed` is deliberately distinct from `dirty`: the
/// gate treats both as "not a candidate", but fn-5.4's pre-fallback re-check
/// reports them differently to the user (a dirty tree survived on purpose; a
/// failed check means we could not tell).
enum WorktreeCleanVerdict: Equatable, Sendable {
    case clean
    /// The entry count is DISPLAY ONLY — see `GitWorktreeCleanCheck.entryCount`.
    case dirty(entryCount: Int)
    /// Command failure, timeout, git unavailability, or unreadable output.
    case failed(reason: String)

    /// The ONLY affirmative state. Everything else — including every failure
    /// class — is not clean.
    var isClean: Bool { self == .clean }
}

/// The G2 check as a standalone, reusable surface.
///
/// fn-5.4's revalidator re-runs it immediately before the guarded filesystem
/// fallback, so it must be ONE implementation with one argv: a second
/// spelling of this check could let the scan and the deletion disagree about
/// whether a tree is clean.
enum GitWorktreeCleanCheck {

    /// The command, minus the `-C <worktree>` prefix.
    ///
    /// BOTH flags exist to defeat repository CONFIGURATION, which the bare
    /// defaults honour and which would otherwise decide what "clean" means
    /// for a deletion gate:
    ///
    /// - `--ignore-submodules=none` matches git's own `check_clean_worktree`
    ///   and overrides `submodule.<name>.ignore` / `diff.ignoreSubmodules`.
    /// - `--untracked-files=normal` overrides `status.showUntrackedFiles=no`,
    ///   which otherwise hides untracked files entirely — verified on git
    ///   2.50.1, a worktree holding only untracked work reports EMPTY under
    ///   that setting. Untracked files are exactly the work that exists
    ///   nowhere else.
    ///
    /// `normal` rather than `all` deliberately: for a gate that only asks
    /// "is there ANY output", listing every file inside an untracked
    /// directory instead of the directory itself changes nothing except
    /// cost — and this scanner's whole subject matter is worktrees carrying
    /// multi-GB untracked build trees, where the extra walk could exhaust
    /// the scan budget and fail the gate closed on a perfectly ordinary
    /// tree.
    static let statusArguments = [
        "status", "--porcelain", "--ignore-submodules=none", "--untracked-files=normal"
    ]

    /// Full argv for one worktree. `-C <path>` rather than a CWD change: the
    /// runner never changes directory, and the shared PATH/`env` shape stays
    /// argv-only.
    static func arguments(forWorktreeAt worktreePath: URL) -> [String] {
        ["-C", worktreePath.path] + statusArguments
    }

    /// TOTAL routing over the runner's four outcome classes. Only an EMPTY
    /// success is clean; every other class — including a success carrying
    /// output — is not, with the cause named.
    static func verdict(for outcome: GitCommandOutcome) -> WorktreeCleanVerdict {
        switch outcome {
        case .success(let stdout):
            // Byte-level: ANY output at all means the tree is not clean.
            // Nothing here trims, tolerates, or interprets the bytes first.
            guard stdout.isEmpty else { return .dirty(entryCount: entryCount(in: stdout)) }
            return .clean
        case .failure(let exitCode, let stderr):
            return .failed(
                reason: "clean check failed "
                    + "(\(GitCommandFailureSummary.describe(exitCode: exitCode, stderr: stderr)))"
            )
        case .timeout:
            return .failed(reason: "clean check timed out")
        case .gitUnavailable:
            return .failed(reason: "git unavailable")
        }
    }

    /// Run the check through the injected runner.
    static func run(
        worktreeAt worktreePath: URL,
        using runner: any GitCommandRunning,
        timeout: TimeInterval? = nil
    ) async -> WorktreeCleanVerdict {
        let arguments = arguments(forWorktreeAt: worktreePath)
        let invocation: GitCommandInvocation
        if let timeout {
            invocation = await runner.run(arguments, timeout: timeout)
        } else {
            invocation = await runner.run(arguments)
        }
        return verdict(for: invocation.outcome)
    }

    /// How many porcelain records the output holds — DISPLAY ONLY.
    ///
    /// The gate decision above is made on the raw bytes (empty vs not), so a
    /// miscount here can never turn a dirty tree into a clean one. Porcelain
    /// v1 C-quotes paths containing newlines, so line counting is accurate in
    /// practice; the `max(1,…)` floor keeps a pathological all-whitespace
    /// body from reporting "0 entries" for output that already proved the
    /// tree dirty.
    static func entryCount(in stdout: Data) -> Int {
        let text = String(decoding: stdout, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return max(1, lines.count)
    }
}

// MARK: - Shared failure rendering

/// One-line, bounded rendering of a git failure for evidence strings.
enum GitCommandFailureSummary {

    /// Longest stderr fragment allowed into an evidence clause. Evidence is
    /// read by humans in a confirmation sheet, and git can be verbose.
    static let maximumStderrLength = 120

    /// `git exit 128: fatal: this operation must be run in a work tree`, or
    /// just `git exit 128` when stderr is empty. The stderr fragment is the
    /// FIRST non-empty line, whitespace-collapsed and truncated — never a
    /// path used for anything but display.
    static func describe(exitCode: Int32, stderr: String) -> String {
        guard let summary = summarize(stderr) else { return "git exit \(exitCode)" }
        return "git exit \(exitCode): \(summary)"
    }

    static func summarize(_ stderr: String) -> String? {
        let firstLine = stderr
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let firstLine else { return nil }
        let collapsed = firstLine
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximumStderrLength else { return collapsed }
        return String(collapsed.prefix(maximumStderrLength)) + "…"
    }
}

// MARK: - Assessor

/// Runs the four gates. A value type holding only the injected runner and
/// rendering configuration, so the scanner actor (fn-5.5) can hold one.
struct WorktreeStalenessAssessor: Sendable {

    // MARK: Pinned refs (D6 ladder)

    /// Step (a): the remote's default branch pointer. Frequently UNSET on
    /// fetched (non-cloned) repositories — the local fallback below is the
    /// common path, not the exception.
    static let originHeadRef = "refs/remotes/origin/HEAD"
    /// The exit code BOTH ladder commands use for "this ref is not there"
    /// (`symbolic-ref -q`: unset, deleted, or not symbolic;
    /// `rev-parse --verify --quiet`: absent). Necessary but NOT sufficient
    /// to continue the ladder — see `isRefMissing`.
    static let refMissingExitCode: Int32 = 1

    /// Whether a nonzero ladder result really means "this ref is not there".
    ///
    /// Exit 1 alone is not enough. Git also answers 1 for a ref that EXISTS
    /// and cannot be read — `warning: ignoring broken ref refs/heads/main`,
    /// verified on git 2.50.1 against a corrupted loose ref — and that is a
    /// completely different fact from "there is no such ref". Continuing on
    /// it would let a repository whose `main` is unreadable be judged
    /// against `master`, so a worktree unmerged into the real default branch
    /// could pass G3.
    ///
    /// The discriminator is stderr: a genuine miss is SILENT (both commands
    /// print nothing for an absent/unset ref — verified), while every
    /// diagnostic answer says something. Erring on the strict side costs at
    /// most a missed reclaim; erring the other way costs human work.
    static func isRefMissing(exitCode: Int32, stderr: String) -> Bool {
        exitCode == refMissingExitCode
            && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Step (b) and (c). A `develop`/`trunk` repository without
    /// `origin/HEAD` resolves to nothing and is never a candidate — accepted
    /// (repairing it would need `fetch`, which the no-network boundary
    /// forbids).
    static let localDefaultRefs = ["refs/heads/main", "refs/heads/master"]

    // MARK: Pinned evidence fragments

    /// The field-verified statement the candidate tail always carries: 28/28
    /// branch refs survived removal of 12 worktrees
    /// (FIELD-EVIDENCE-2026-08-06.md scenario 2).
    static let branchRefSentence = "branch ref survives removal"
    /// The explicit marker that fills the date slot when the lookup failed —
    /// the slot is NEVER silently absent.
    static let lastCommitUnavailableMarker = "last commit unavailable"

    // MARK: Configuration

    private let runner: any GitCommandRunning
    /// Per-invocation budget override; `nil` uses the runner's own default
    /// (~10 s at scan time).
    private let timeout: TimeInterval?
    /// Time zone the evidence date is rendered in. Defaults to the viewer's
    /// own zone (the date is shown to a human); tests pin UTC so the
    /// verbatim shape assertions are host-independent.
    private let timeZone: TimeZone

    init(
        runner: any GitCommandRunning,
        timeout: TimeInterval? = nil,
        timeZone: TimeZone = .current
    ) {
        self.runner = runner
        self.timeout = timeout
        self.timeZone = timeZone
    }

    // MARK: Entry point

    /// Assess ONE porcelain record.
    ///
    /// `parentRepoWorkingDir` MUST come from
    /// `WorktreeMembership.parentRepoWorkingDir` (the porcelain first
    /// record) for a linked worktree — it is the `-C` target the D6 ladder
    /// queries. It is a separate parameter, not a `WorktreeMembership`,
    /// precisely because the main and bare records that G1 refuses have NO
    /// membership (their `.git` is a directory, so fn-5.1's resolver
    /// correctly declines to attribute them) and must still be assessable.
    func assess(
        entry: GitWorktreeEntry, parentRepoWorkingDir: URL
    ) async -> WorktreeAssessmentResult {
        if entry.isPrunable {
            return .prunableNotAssessed(reason: Self.prunableRefusal(for: entry))
        }

        let worktreePath = entry.path
        // ALL FOUR always run — evidence completeness (round 10) is a
        // requirement, not an optimisation target.
        let gates: [WorktreeGateOutcome] = [
            Self.evaluateNotMainOrBare(entry),
            await evaluateClean(worktreeAt: worktreePath),
            await evaluateMerged(
                worktreeAt: worktreePath, parentRepoWorkingDir: parentRepoWorkingDir
            ),
            Self.evaluateNotLocked(entry)
        ]

        let isCandidate = gates.allSatisfy(\.passed)
        // The date feeds ONLY the candidate tail, and non-candidates are
        // never emitted as items (D15) — so a non-candidate does not pay for
        // the lookup. It is display data either way: a failure here yields
        // the explicit marker, never a failed assessment.
        let lastCommitDate = isCandidate ? await lastCommitDate(worktreeAt: worktreePath) : nil

        return .assessed(
            WorktreeAssessment(
                worktreePath: worktreePath,
                gates: gates,
                lastCommitDate: lastCommitDate,
                evidence: Self.evidence(
                    gates: gates, lastCommitDate: lastCommitDate, timeZone: timeZone
                )
            )
        )
    }

    // MARK: G1 — not main, not bare

    static func evaluateNotMainOrBare(_ entry: GitWorktreeEntry) -> WorktreeGateOutcome {
        // `bare` is checked first because a bare repository's record is also
        // the main record: naming the bare shape is the more informative of
        // the two true statements.
        if entry.isBare {
            return WorktreeGateOutcome(gate: .notMainOrBare, passed: false, reason: "bare")
        }
        if entry.isMain {
            return WorktreeGateOutcome(
                gate: .notMainOrBare, passed: false, reason: "main worktree"
            )
        }
        return WorktreeGateOutcome(
            gate: .notMainOrBare, passed: true, reason: "linked (not main/bare)"
        )
    }

    // MARK: G2 — clean

    private func evaluateClean(worktreeAt worktreePath: URL) async -> WorktreeGateOutcome {
        let verdict = await GitWorktreeCleanCheck.run(
            worktreeAt: worktreePath, using: runner, timeout: timeout
        )
        switch verdict {
        case .clean:
            return WorktreeGateOutcome(gate: .clean, passed: true, reason: "clean")
        case .dirty(let entryCount):
            // The plural is part of the PINNED wording and is deliberately
            // not re-inflected for one entry — the shape stays byte-stable.
            return WorktreeGateOutcome(
                gate: .clean, passed: false,
                reason: "dirty: \(entryCount) modified/untracked entries"
            )
        case .failed(let reason):
            return WorktreeGateOutcome(gate: .clean, passed: false, reason: reason)
        }
    }

    // MARK: G3 — merged (LOCAL ancestry, hedged)

    /// The D6 ladder's answer.
    private enum DefaultBranchResolution: Equatable {
        case resolved(ref: String)
        case unresolved(reason: String)
    }

    private func evaluateMerged(
        worktreeAt worktreePath: URL, parentRepoWorkingDir: URL
    ) async -> WorktreeGateOutcome {
        let defaultRef: String
        switch await resolveDefaultBranch(parentRepoWorkingDir: parentRepoWorkingDir) {
        case .resolved(let ref):
            defaultRef = ref
        case .unresolved(let reason):
            // The ladder failed: G3 fails CLOSED with the cause named, and no
            // ancestry command runs against an unresolved ref.
            return WorktreeGateOutcome(gate: .merged, passed: false, reason: reason)
        }

        // Detached HEAD needs no special case: `HEAD` names the commit, and
        // the commit is exactly what is being judged.
        let invocation = await run(
            ["-C", worktreePath.path, "merge-base", "--is-ancestor", "HEAD", defaultRef]
        )
        switch invocation.outcome {
        case .success:
            return WorktreeGateOutcome(
                gate: .merged, passed: true, reason: "HEAD is ancestor of \(defaultRef)"
            )
        case .failure(let exitCode, let stderr):
            // Exit 1 is git's ANSWER ("not an ancestor"); every other exit —
            // 128 for a bad or unresolvable ref above all — means git could
            // not answer. Conflating them would let an unanswered check
            // masquerade as a hedged negative, so they render differently.
            // Both fail closed.
            if exitCode == 1 {
                return WorktreeGateOutcome(
                    gate: .merged, passed: false,
                    reason: "HEAD not an ancestor of \(defaultRef) "
                        + "(squash/rebase merges not detected)"
                )
            }
            return WorktreeGateOutcome(
                gate: .merged, passed: false,
                reason: "ancestry check against \(defaultRef) failed "
                    + "(\(GitCommandFailureSummary.describe(exitCode: exitCode, stderr: stderr)))"
            )
        case .timeout:
            return WorktreeGateOutcome(
                gate: .merged, passed: false,
                reason: "ancestry check against \(defaultRef) timed out"
            )
        case .gitUnavailable:
            return WorktreeGateOutcome(gate: .merged, passed: false, reason: "git unavailable")
        }
    }

    /// The D6 ladder, run in the PARENT repository:
    /// `refs/remotes/origin/HEAD` → `refs/heads/main` → `refs/heads/master`
    /// → fail closed.
    ///
    /// EVERY failure class is enumerated, and exactly ONE of them continues
    /// the ladder: a SILENT exit 1, which is each command's "this rung is
    /// not there" answer. Everything else stops it.
    ///
    /// - `symbolic-ref -q <ref>` exits **1** SILENTLY when the ref is unset,
    ///   deleted, or present-but-not-symbolic (the common shape on fetched,
    ///   non-cloned repos) and **128** when git could not look at all — not
    ///   a repository, or an unreadable ref file. Verified on git 2.50.1;
    ///   the `-q` is what SPLITS those two, because without it the ordinary
    ///   unset case also dies with 128 and becomes indistinguishable from a
    ///   broken repository.
    /// - `rev-parse --verify --quiet <ref>` exits **1** SILENTLY for an
    ///   absent ref, **1 with a `warning: ignoring broken ref …`** for a ref
    ///   that exists and cannot be read, and **128** for a fatal condition.
    ///
    /// Hence the miss test is `isRefMissing` — exit 1 AND a silent stderr —
    /// not the exit code alone.
    ///
    /// Treating a FAILED rung as a missing one would be a real fail-open,
    /// not a conservative refusal: a repository whose `refs/heads/main`
    /// cannot be read but whose `refs/heads/master` still resolves would
    /// silently be judged against `master`, and a worktree unmerged into the
    /// actual default branch could pass G3. So a failed rung fails the gate
    /// CLOSED with the rung and the failure NAMED. A TIMEOUT or a
    /// gitUnavailable stops the ladder for the same reason plus one more:
    /// firing two further subprocesses at a wedged or absent git would only
    /// relabel a real failure as "default branch unresolvable".
    private func resolveDefaultBranch(
        parentRepoWorkingDir: URL
    ) async -> DefaultBranchResolution {
        let parent = parentRepoWorkingDir.path

        let symbolic = await run(
            ["-C", parent, "symbolic-ref", "-q", Self.originHeadRef]
        )
        switch symbolic.outcome {
        case .success(let stdout):
            guard let ref = Self.firstLine(of: stdout), ref.hasPrefix("refs/") else {
                // A successful symbolic-ref whose output is not a ref is an
                // anomaly, NOT the "unset" case — it must not fall through
                // into the local ladder as if the pointer were merely absent.
                return .unresolved(
                    reason: "\(Self.originHeadRef) resolved to an unreadable ref"
                )
            }
            return .resolved(ref: ref)
        case .failure(let exitCode, let stderr):
            guard Self.isRefMissing(exitCode: exitCode, stderr: stderr) else {
                let summary = GitCommandFailureSummary.describe(
                    exitCode: exitCode, stderr: stderr
                )
                return .unresolved(
                    reason: "\(Self.originHeadRef) lookup failed (\(summary))"
                )
            }
            break // The ONLY continuing class: the ref is not there.
        case .timeout:
            return .unresolved(reason: "default branch lookup timed out")
        case .gitUnavailable:
            return .unresolved(reason: "git unavailable")
        }

        for ref in Self.localDefaultRefs {
            let verify = await run(["-C", parent, "rev-parse", "--verify", "--quiet", ref])
            switch verify.outcome {
            case .success:
                return .resolved(ref: ref)
            case .failure(let exitCode, let stderr):
                guard Self.isRefMissing(exitCode: exitCode, stderr: stderr) else {
                    // A FAILED rung is not a MISSING one: falling through to
                    // the next ref would judge the worktree against a branch
                    // that is not this repository's default.
                    let summary = GitCommandFailureSummary.describe(
                        exitCode: exitCode, stderr: stderr
                    )
                    return .unresolved(reason: "\(ref) lookup failed (\(summary))")
                }
                continue // The ref is absent — try the next rung.
            case .timeout:
                return .unresolved(reason: "default branch lookup timed out")
            case .gitUnavailable:
                return .unresolved(reason: "git unavailable")
            }
        }

        return .unresolved(reason: "default branch unresolvable")
    }

    // MARK: G4 — not locked

    static func evaluateNotLocked(_ entry: GitWorktreeEntry) -> WorktreeGateOutcome {
        guard entry.isLocked else {
            return WorktreeGateOutcome(gate: .notLocked, passed: true, reason: "not locked")
        }
        guard let lockReason = entry.lockReason, !lockReason.isEmpty else {
            return WorktreeGateOutcome(
                gate: .notLocked, passed: false, reason: "locked (no reason recorded)"
            )
        }
        return WorktreeGateOutcome(
            gate: .notLocked, passed: false, reason: "locked: \(lockReason)"
        )
    }

    // MARK: Last activity (display only, never a gate)

    /// HEAD's committer date. Every failure class yields `nil`, which the
    /// evidence renders as the explicit unavailable marker — the assessment
    /// itself never fails on it.
    private func lastCommitDate(worktreeAt worktreePath: URL) async -> Date? {
        let invocation = await run(
            ["-C", worktreePath.path, "show", "-s", "--format=%ct", "HEAD"]
        )
        guard case .success(let stdout) = invocation.outcome,
              let line = Self.firstLine(of: stdout),
              let seconds = Int(line)
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // MARK: Evidence assembly (R1/R3/R10)

    /// The canonical four-clause string. The tail (date slot + branch-ref
    /// sentence) rides CANDIDATES only — it describes what happens when the
    /// worktree is removed, and non-candidates are never offered for removal
    /// (D15).
    static func evidence(
        gates: [WorktreeGateOutcome], lastCommitDate: Date?, timeZone: TimeZone
    ) -> String {
        var clauses = gates.map(\.clause)
        if gates.allSatisfy(\.passed) {
            clauses.append(lastCommitPhrase(lastCommitDate, timeZone: timeZone))
            clauses.append(branchRefSentence)
        }
        return clauses.joined(separator: "; ")
    }

    static func lastCommitPhrase(_ date: Date?, timeZone: TimeZone) -> String {
        guard let date else { return lastCommitUnavailableMarker }
        return "last commit \(dateString(date, timeZone: timeZone))"
    }

    /// Fixed-format, POSIX-locale, Gregorian — a date in evidence must not
    /// change shape with the user's locale settings (it is compared and
    /// logged), only with their time zone.
    private static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: Refusals & helpers

    static func prunableRefusal(for entry: GitWorktreeEntry) -> String {
        let base = "prunable record — the checkout is already gone; "
            + "the orphaned-admin tier owns it"
        guard let reason = entry.prunableReason, !reason.isEmpty else { return base }
        return base + " (\(reason))"
    }

    /// First non-empty line of captured stdout, trimmed. Lossy UTF-8 decoding
    /// is safe here: these outputs are refs and integers, and anything that
    /// fails the checks at the call site fails CLOSED.
    static func firstLine(of data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func run(_ arguments: [String]) async -> GitCommandInvocation {
        if let timeout { return await runner.run(arguments, timeout: timeout) }
        return await runner.run(arguments)
    }
}
