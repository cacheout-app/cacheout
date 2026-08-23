import XCTest
@testable import Cacheout

/// fn-5.4 coverage: `WorktreeReclaimPerformer` — the git-mediated reclaim.
///
/// FIXTURE DOCTRINE, inherited from fn-5.1/fn-5.2 and sharpened by the epic's
/// Decision Context:
/// - Real git builds every repository fixture (hermetic env, `GIT_CONFIG_*`
///   pinned to `/dev/null`), and real git executes wherever the behaviour
///   under test IS git's.
/// - THERE IS NO FALLBACK ARM TO INJECT A REFUSAL INTO ANY MORE (PR #460
///   codex r5/r6). Through r4 this header described a doctrine for the
///   "fallback cell": `git worktree remove` was the primary arm, the
///   ignored-tree `Directory not empty` refusal it produced on ≤2.39 could
///   not be reproduced on 2.50.1, so cells INJECTED a failing runner result
///   to reach the second arm. That machinery went with the arm (`14155bf`),
///   and this bullet described it for one round after it was deleted. The
///   check that reproduces is on the PRODUCT, not on this file's own prose:
///
///       $ grep -rn 'worktree", "remove' Sources/
///       Sources/Cacheout/Scanner/SpaceScanner.swift:143:/// `["git", "-C", <parentRepoWorkingDir>, "worktree", "remove", <path>]`;
///
///   one hit, in a doc comment that names the builder as RETIRED. No Swift
///   statement anywhere in `Sources/` spells that argv. This file still
///   spells it three times, always as FIXTURE setup — the test itself asking
///   real git to build a state. The field class it was about is
///   now REFUSED rather than routed: the last gate runs `status --porcelain
///   --ignored`, so an ignored file that appeared since the scan aborts the
///   removal (`testAnIgnoredFileThatAppearsInTheGateWindowIsNotDestroyed`),
///   while an ignored tree that was ALREADY there is removed with the
///   checkout and has its own boundary cell.
/// - `InterceptingGitRunner` is still how a cell reaches a WINDOW: its
///   `intercept` closure runs BEFORE the delegated call, so a test can mutate
///   the filesystem between two git invocations. What it no longer does on
///   this path is synthesise a MUTATION's failure, because no git invocation
///   here mutates anything.
/// ## THE MUTATION LEDGER, AND A CORRECTION OF RECORD (PR #460 codex r6, D6)
///
/// `7260964`'s commit message published a mutation table against
/// `swift test --filter 'Worktree|GitWorktree'` with "baseline 220 executed"
/// and, for two of its four rows, **"218 exec, 1 cell RED"**. 218 is
/// unreachable: mutating PRODUCTION cannot change which CELLS exist, and this
/// filtered family has no skips, so the executed count is invariant under
/// every mutation in that table. The rows also conflated "cells that went red"
/// with XCTest's failure count.
///
/// Re-run at r6's baseline, command stated, output pasted:
///
///     swift test --filter 'Worktree|GitWorktree'
///
///     baseline
///       Executed 222 tests, with 0 failures (0 unexpected) in 41.038 seconds
///       exit 0
///
///     D2 — `if let first = appeared.first` → `if false, let first = …`
///       Executed 222 tests, with 3 failures (1 unexpected) in 44.161 seconds
///       exit 1
///       RED: testAnIgnoredFileThatAppearsInTheGateWindowIsNotDestroyed
///
///     D3 — the `.reftableStack` branch deleted from `captureHead`'s
///          corroboration-failure arm
///       Executed 222 tests, with 3 failures (1 unexpected) in 44.475 seconds
///       exit 1
///       RED: testAReftableAttachedWorktreeDetachedAndCommittedInsideTheWindowIsRefused
///
/// Both guards ARE evidenced — one cell each, exactly as claimed. It was the
/// figures that could not be reproduced, in the very round whose job included
/// fixing that class of claim. The count that MOVES under a mutation is the
/// FAILURE count (3 here: two assertions plus `XCTUnwrapElement`'s own throw);
/// the executed count moves only when CELLS are added or removed.
///
/// A THIRD MUTATION, from the same round, is recorded here because its
/// subject no longer exists: M7 replaced `captureHead`'s THIRD arm — the
/// reftable-stack read after "HEAD is not a readable regular file" — with
/// `return .unreadable`, and the FULL suite stayed GREEN: `swift test`, run AT
/// COMMIT 06c1ad5, reported 1466 executed / 2 skipped / 0 failures. The TOTAL
/// belongs to that commit and not to this branch (PR #460 codex r7, D5) —
/// 0284fd1 → 1467, 193b043 → 1470, bcfcb7e → 1471, r7 → 1480, r8 → 1486 (the
/// measurement 7e9b2c5 records), r9 and r10 → 1496 (`swift test` AT COMMIT
/// 101753b: 1496 executed / 2 skipped / 0 failures, exit 0), r11 → 1500
/// (`swift test` AT COMMIT a917447: 1500 executed / 2 skipped / 0 failures,
/// exit 0), r12 → 1511 (`swift test` AT COMMIT 592eb0a: 1511 executed /
/// 2 skipped / 0 failures, exit 0). The previous
/// spelling was "r8 → 1486 (`swift test`, this commit)" — true at 7e9b2c5,
/// which wrote it, and stale at the very next commit, because "this commit"
/// is not an endpoint. r9's cells moved the total and this line did not
/// follow; that is the D4 this round fixed. Every figure here now names the
/// commit it was taken at, which is the only spelling that cannot rot.
/// What a mutation establishes is the zero failures. That arm was deleted at r6
/// rather than evidenced; see
/// `testAReftableWorktreeWhoseHeadFileIsGoneIsRefusedByTheGatesThatRemain` and
/// the measurement in `captureHead` itself.
///
final class WorktreeReclaimPerformerTests: XCTestCase {

    // MARK: - Fixture state

    private var base: URL!
    /// The declared container root (a dev root) — every path any plan may
    /// point git at lives inside it.
    private var container: URL!
    private var home: URL!
    private var trashDirectory: URL!
    private let provider = FileSystemIdentityProvider()
    private let fm = FileManager.default
    private let scannerID = "git_worktrees"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // CANONICAL base: git reports canonical worktree paths, and the plan's
        // lexical containment rules compare spellings.
        base = provider.canonicalize(fm.temporaryDirectory)
            .appendingPathComponent("WorktreeReclaimPerformerTests-\(UUID().uuidString)")
        container = base.appendingPathComponent("dev")
        home = base.appendingPathComponent("home")
        trashDirectory = base.appendingPathComponent("trash")
        for directory in [container!, home!, trashDirectory!] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
        base = nil
        try super.tearDownWithError()
    }

    // MARK: - Git fixture builders (real git, hermetic)

    @discardableResult
    private func makeRepository(named name: String) throws -> URL {
        let url = container.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(
            try GitFixture.git(
                ["-c", "init.defaultBranch=main", "init", url.path], home: home
            ).status, 0, "git init failed at \(url.path)"
        )
        // A deliberately CHUNKY tracked file: every worktree checkout then
        // carries measurable bytes, so freed-byte assertions have something
        // real to bite on — and it stays TRACKED, because an untracked file
        // would make git's own clean check refuse the removal.
        try Data(repeating: 7, count: 40_000)
            .write(to: url.appendingPathComponent("tracked.txt"))
        XCTAssertEqual(
            try GitFixture.git(["-C", url.path, "add", "tracked.txt"], home: home).status, 0
        )
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", url.path, "-c", "user.name=t", "-c", "user.email=t@t",
                 "commit", "-m", "seed"], home: home
            ).status, 0
        )
        return url
    }

    /// A linked worktree on `branch`, MERGED by construction (it points at
    /// the repository's only commit).
    @discardableResult
    private func addWorktree(
        named name: String, branch: String, in repository: URL
    ) throws -> URL {
        let url = container.appendingPathComponent(name)
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", repository.path, "worktree", "add", url.path, "-b", branch],
                home: home
            ).status, 0, "git worktree add failed for \(url.path)"
        )
        return url
    }

    private func inventory(of repository: URL) throws -> GitWorktreeInventory {
        let listed = try GitFixture.git(
            ["-C", repository.path, "-c", "gc.worktreePruneExpire=now",
             "worktree", "list", "--porcelain", "-z"],
            home: home
        )
        XCTAssertEqual(listed.status, 0)
        return try XCTUnwrap(GitWorktreeInventory.parse(listed.stdout))
    }

    /// The PRODUCTION derivation of the carried admin container — the
    /// resolver's `<parentGitDir>/worktrees`, never a `<wd>/.git/worktrees`
    /// reconstruction.
    private func membership(
        of worktree: URL, in repository: URL
    ) throws -> WorktreeMembership {
        try XCTUnwrap(
            GitWorktreeGitdirResolver().membership(
                forWorktreeAt: worktree, in: try inventory(of: repository)
            ),
            "the resolver could not attribute \(worktree.path)"
        )
    }

    /// A COMMITTED `.gitignore` inside `worktree` naming `pattern`, so the
    /// tree stays CLEAN while the matching file is invisible to
    /// `status --porcelain` — the D2 shape, built the way a user's repository
    /// actually has it rather than through `.git/info/exclude`.
    private func commitIgnoreRule(_ pattern: String, in worktree: URL) throws {
        try Data("\(pattern)\n".utf8)
            .write(to: worktree.appendingPathComponent(".gitignore"))
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", worktree.path, "add", ".gitignore"], home: home
            ).status, 0
        )
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", worktree.path, "-c", "user.name=t", "-c", "user.email=t@t",
                 "commit", "-m", "ignore \(pattern)"], home: home
            ).status, 0
        )
    }

    /// A linked worktree of a `--ref-format=reftable` repository (D3). Built
    /// separately from `makeRepository` because the ref backend is fixed at
    /// `init` time and cannot be changed afterwards.
    private func makeReftableRepository(named name: String) throws -> URL {
        let url = container.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(
            try GitFixture.git(
                ["-c", "init.defaultBranch=main", "init",
                 "--ref-format=reftable", url.path], home: home
            ).status, 0, "git init --ref-format=reftable failed at \(url.path)"
        )
        try Data(repeating: 7, count: 40_000)
            .write(to: url.appendingPathComponent("tracked.txt"))
        XCTAssertEqual(
            try GitFixture.git(["-C", url.path, "add", "tracked.txt"], home: home).status, 0
        )
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", url.path, "-c", "user.name=t", "-c", "user.email=t@t",
                 "commit", "-m", "seed"], home: home
            ).status, 0
        )
        return url
    }

    /// Move `refs/heads/main` onto `branch`'s tip, so a commit made inside a
    /// linked worktree is an ANCESTOR of the default branch again and G3
    /// stops being the thing under test.
    private func fastForwardDefaultBranch(
        to branch: String, in repository: URL
    ) throws {
        let tip = String(
            decoding: try GitFixture.git(
                ["-C", repository.path, "rev-parse", "refs/heads/\(branch)"],
                home: home
            ).stdout, as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", repository.path, "update-ref", "refs/heads/main", tip],
                home: home
            ).status, 0
        )
    }

    private func branchExists(_ branch: String, in repository: URL) throws -> Bool {
        try GitFixture.git(
            ["-C", repository.path, "rev-parse", "--verify",
             "refs/heads/\(branch)"], home: home
        ).status == 0
    }

    private func porcelainRecordCount(of repository: URL) throws -> Int {
        try inventory(of: repository).entries.count
    }

    // MARK: - Plans & items

    /// - Parameter bindAdminIdentity: capture the admin directory's inode,
    ///   exactly as `GitWorktreeScanner` does (D3 / PR #460 codex r3). Left
    ///   TRUE by default so every cell exercises the production shape; a cell
    ///   that wants the pre-r3, path-only R1b passes `false`.
    private func staleplan(
        worktree: URL, membership: WorktreeMembership,
        bindAdminIdentity: Bool = true
    ) -> GitWorktreeReclaimPlan {
        let adminEntry = membership.parentAdminContainer
            .appendingPathComponent(worktree.lastPathComponent)
        return .removeStaleWorktree(
            worktreePath: worktree,
            worktreeAdminEntry: adminEntry,
            worktreeAdminEntryIdentity: bindAdminIdentity
                ? provider.identity(of: adminEntry) : nil,
            parentRepoWorkingDir: membership.parentRepoWorkingDir,
            adminContainer: membership.parentAdminContainer
        )
    }

    private func prunePlan(
        membership: WorktreeMembership, disclosed: [URL]
    ) -> GitWorktreeReclaimPlan {
        .pruneOrphanedAdmin(
            parentRepoWorkingDir: membership.parentRepoWorkingDir,
            adminContainer: membership.parentAdminContainer,
            disclosedAdminDirectories: disclosed
        )
    }

    private func item(
        _ plan: GitWorktreeReclaimPlan,
        id: String = "item",
        state: ScanState = .measured,
        exactBytes: Int64 = 4096,
        itemCount: Int = 1,
        requiresPreDeleteRevalidation: Bool = false
    ) -> ReclaimableItem {
        let target: URL
        switch plan.mode {
        case .removeStaleWorktree: target = plan.worktreePath ?? container
        case .pruneOrphanedAdmin: target = plan.parentAdminContainer
        }
        return ReclaimableItem(
            id: id, scannerID: scannerID, displayName: "worktree \(id)",
            exactBytes: exactBytes, estimatedUpToBytes: 0, logicalBytes: nil,
            itemCount: itemCount, url: target, declaredDisplayPath: target.path,
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: target, status: .measured
            )],
            state: state, scanError: nil, risk: .review,
            evidence: "fixture", rebuildNote: nil,
            action: .gitWorktreeReclaim(plan),
            admission: .containerItem(
                originContainer: container, requestedTargetURL: target
            ),
            defaultSelected: false, automaticCleanEligible: false,
            isStale: true,
            requiresPreDeleteRevalidation: requiresPreDeleteRevalidation
        )
    }

    // MARK: - Harnesses

    private func snapshot() -> ContainerSnapshot {
        ContainerSnapshot.capture(roots: [container], provider: provider)
    }

    /// Every `logRefusal(tag:detail:)` the performer made, in order.
    final class RefusalLog {
        private let lock = NSLock()
        private var entries: [(tag: String, detail: String)] = []
        func record(_ tag: String, _ detail: String) {
            lock.lock(); entries.append((tag, detail)); lock.unlock()
        }
        var tags: [String] {
            lock.lock(); defer { lock.unlock() }; return entries.map(\.tag)
        }
        var details: [String] {
            lock.lock(); defer { lock.unlock() }; return entries.map(\.detail)
        }
    }

    private func realRunner() -> GitCommandRunner {
        GitCommandRunner(environment: GitFixture.environment(home: home))
    }

    /// The performer under test, with every seam injectable.
    private func makePerformer(
        runner: any GitCommandRunning,
        measure: ((URL, DirectorySizer.Mode, Set<FileSystemIdentityProvider.Identity>) -> SizeReport)? = nil,
        moveToTrash: Bool = false,
        trash: TrashDisposal.Mover? = nil,
        removeTree: (
            (URL, DepthSafeRemoval.AdmittedParent, LastInstantProof)
                async throws -> Void
        )? = nil,
        revalidate: ((ReclaimableItem) -> PreDeleteSeamRefusal?)? = nil,
        gitTimeout: TimeInterval = WorktreeReclaimPerformer.deleteTimeGitTimeout,
        provider overrideProvider: FileSystemIdentityProvider? = nil,
        // THE REFUSAL LOG, INJECTABLE (PR #460 codex r7, D3/M6). The tag is
        // the ONLY thing that distinguishes a refusal raised inside a seam
        // and rethrown through `catch let refusal as LastInstantRefusal` from
        // the same refusal collapsing into the generic `catch`: both produce
        // the identical per-item message, because `LastInstantRefusal`'s
        // `errorDescription` IS the detail. Without a cell that reads the
        // log, that catch arm cannot be killed by any mutation.
        refusals: RefusalLog? = nil
    ) -> WorktreeReclaimPerformer {
        let provider = overrideProvider ?? self.provider
        let sizer = DirectorySizer(provider: provider)
        let fileManager = fm
        let trashRoot = trashDirectory!
        return WorktreeReclaimPerformer(
            pathGuard: PathGuard(
                home: home, containerRoots: [container], provider: provider
            ),
            provider: provider,
            snapshot: snapshot(),
            runner: runner,
            mapper: GitWorktreeAdminMapper(identity: provider),
            measure: measure ?? { url, mode, known in
                sizer.measure(at: url, mode: mode, knownInodes: known)
            },
            gitTimeout: gitTimeout,
            moveToTrash: moveToTrash,
            // THE DEFAULT DOUBLE HONOURS `TrashDisposal.Mover`'s CONTRACT
            // (PR #460 codex r6, D1): `prove()` runs immediately before the
            // move, which is what the production seam does on the far side of
            // its main-actor hop. A double that skipped it would be MORE
            // permissive than production — it would move objects the real
            // seam refuses to move — and this suite's doctrine is that a
            // double must never be more capable than the thing it stands for.
            trash: trash ?? { url, prove in
                try prove()
                let landed = trashRoot.appendingPathComponent(
                    url.lastPathComponent
                )
                try fileManager.moveItem(at: url, to: landed)
                return landed
            },
            // THE DEFAULT DOUBLE HONOURS THE PERMANENT SEAM'S CONTRACT TOO
            // (PR #460 codex r7, D1), for the same reason the trash double
            // does: the production seam runs `prove()` on the far side of its
            // `DispatchQueue.global` hop, immediately before
            // `DepthSafeRemoval.remove`, and a double that skipped it would
            // destroy trees the real seam refuses to destroy.
            removeTree: removeTree ?? { url, _, prove in
                try prove()
                try fileManager.removeItem(at: url)
            },
            revalidate: revalidate ?? { _ in nil },
            logRefusal: { tag, detail in refusals?.record(tag, detail) },
            logCleaned: { _ in }
        )
    }

    private func perform(
        _ item: ReclaimableItem,
        plan: GitWorktreeReclaimPlan,
        with performer: WorktreeReclaimPerformer
    ) async -> WorktreeReclaimOutcome {
        let target: URL
        switch plan.mode {
        case .removeStaleWorktree: target = plan.worktreePath ?? container
        case .pruneOrphanedAdmin: target = plan.parentAdminContainer
        }
        return await performer.perform(
            item: item, plan: plan, origin: container, target: target,
            registry: InodeAccountingRegistry()
        )
    }

    /// The cleaner path — for the cells that must prove the item reaches
    /// dispatch through `clean(items:)` itself.
    private func makeCleaner(
        runner: any GitCommandRunning,
        revalidators: [String: PreDeleteRevalidator] = [:],
        gitTimeout: TimeInterval = WorktreeReclaimPerformer.deleteTimeGitTimeout
    ) -> CacheCleaner {
        CacheCleaner(
            home: home, containerRoots: [container],
            containerSnapshot: snapshot(),
            preDeleteRevalidators: revalidators, provider: provider,
            gitRunner: runner, gitTimeout: gitTimeout
        )
    }

    // MARK: - Shared assertions

    /// Every recorded argv minus the runner's own `git -c core.fsmonitor=…`
    /// prefix, so a cell can compare against the PRODUCTION argv builders
    /// rather than against a hand-copied literal.
    private func bareArgvs(_ runner: InterceptingGitRunner) -> [[String]] {
        runner.argvs.map { Array($0.dropFirst(3)) }
    }

    /// The EXACT, ordered argv `reestablishStaleGates` fires for a fixture
    /// repository (no `origin/HEAD`, default branch `refs/heads/main`).
    ///
    /// Built from the SHARED builders on purpose — this is the cell-level
    /// half of the one-implementation guarantee that exporting
    /// `GitWorktreeCleanCheck` earned for G2. A second spelling of the D6
    /// ladder or of the ancestry argv at delete time turns every cell that
    /// compares against this RED.
    private func reestablishmentArgvs(
        worktree: URL, repository: URL, defaultRef: String = "refs/heads/main"
    ) -> [[String]] {
        [
            WorktreeReclaimPerformer.commonGitDirArguments(
                parentRepoWorkingDir: repository
            ),
            GitWorktreeOracle.listArguments(forRepositoryAt: repository),
            GitWorktreeMergedCheck.originHeadArguments(
                parentRepoWorkingDir: repository
            ),
            GitWorktreeMergedCheck.verifyRefArguments(
                parentRepoWorkingDir: repository, ref: defaultRef
            ),
            GitWorktreeMergedCheck.ancestryArguments(
                worktreeAt: worktree, defaultRef: defaultRef
            ),
        ]
    }

    /// The EXACT, ordered argv a stale removal fires END TO END at r5: the
    /// D2 ignored WITNESS, the five re-establishment rungs, and the LAST
    /// gate — which is the same `status` argv as the witness, because ONE
    /// invocation answers both halves and a second spelling would answer
    /// about a different instant.
    ///
    /// There is no `worktree remove` in it any more (PR #460 codex r5 / D1).
    private func staleGateArgvs(
        worktree: URL, repository: URL, defaultRef: String = "refs/heads/main"
    ) -> [[String]] {
        let rungs = reestablishmentArgvs(
            worktree: worktree, repository: repository, defaultRef: defaultRef
        )
        let status = GitWorktreeCleanCheck.arguments(forWorktreeAt: worktree)
        // R0, R1 — then the WITNESS, taken once identity is settled and
        // before R2's three-rung ladder — then R2, then the LAST gate.
        return Array(rungs.prefix(2)) + [status] + Array(rungs.dropFirst(2))
            + [status]
    }

    /// What the GATED prune adds after a successful removal: the oracle
    /// recompute, then R0 again. The scoped admin removal itself is a
    /// filesystem delete and spawns nothing.
    private func gatedPruneArgvs(repository: URL) -> [[String]] {
        [
            GitWorktreeOracle.listArguments(forRepositoryAt: repository),
            WorktreeReclaimPerformer.commonGitDirArguments(
                parentRepoWorkingDir: repository
            ),
        ]
    }

    /// The `-C` target of a recorded argv, or `nil` when the argv has no
    /// `-C` or nothing after it.
    ///
    /// NEVER a positional subscript (PR #460 codex r2 / D2): `argv[4]` on a
    /// runtime-length array turns a regression that shortens an argv into a
    /// PROCESS abort — every later cell and every later suite silently
    /// skipped — instead of a named failure.
    private func dashCTarget(_ argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: "-C"),
              argv.indices.contains(index + 1) else { return nil }
        return argv[index + 1]
    }

    /// Whether an argv belongs to the delete-time gate re-establishment —
    /// used only where a cell needs to say "and NOTHING ELSE ran".
    private func isReestablishment(_ argv: [String]) -> Bool {
        argv.contains("--git-common-dir") || argv.contains("list")
            || argv.contains("symbolic-ref") || argv.contains("--verify")
            || argv.contains("merge-base")
    }

    /// No recorded argv may ever carry `--force` or a branch deletion — the
    /// epic's Boundaries, asserted on EVERY cell that records invocations.
    private func assertNoForbiddenArgv(
        _ runner: InterceptingGitRunner,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for invocation in runner.invocations {
            XCTAssertFalse(
                invocation.argv.contains("--force"),
                "--force reached git: \(invocation.argv)", file: file, line: line
            )
            XCTAssertFalse(
                invocation.argv.contains("branch"),
                "a branch command reached git: \(invocation.argv)",
                file: file, line: line
            )
        }
    }

    // MARK: - R5: THIS process removes it, under proof, and git only reads

    /// The DEFAULT path, end to end, after r5 moved the removal out of git
    /// (D1). Everything git does here is a READ: the witness, the four gate
    /// re-establishments, the last gate, and the prune recompute. The tree
    /// and the admin entry are removed by this process.
    func testCleanMergedWorktreeIsRemovedUnderProofWithASurvivingBranch()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let membership = try membership(of: worktree, in: repository)
        let adminEntry = membership.parentAdminContainer
            .appendingPathComponent("wt")
        XCTAssertTrue(fm.fileExists(atPath: adminEntry.path))

        let plan = staleplan(worktree: worktree, membership: membership)
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let report = await makeCleaner(runner: runner)
            .clean(items: [item(plan)], moveToTrash: false)

        // The tree, its admin directory and the porcelain registry.
        XCTAssertFalse(fm.fileExists(atPath: worktree.path))
        XCTAssertFalse(fm.fileExists(atPath: adminEntry.path))
        XCTAssertEqual(try porcelainRecordCount(of: repository), 1,
                       "git worktree list must report only the main worktree")
        // The branch ref SURVIVES — the field's 28/28 observation, pinned.
        XCTAssertTrue(try branchExists("feature", in: repository))

        XCTAssertTrue(report.errors.isEmpty, "\(report.errorLines)")
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertGreaterThan(entry.exactBytes, 40_000)
        XCTAssertNil(entry.warning, "the gated prune ran, so nothing is left")
        XCTAssertEqual(entry.disposal, .permanent,
                       "moveToTrash is false in this run")

        // THE WHOLE SEQUENCE, and it contains NO MUTATION (PR #460 codex r5 /
        // D1). Through r4 the last argv here was `worktree remove`, whose
        // spawn→first-destruction window measured 14.87 ms median on a
        // one-file worktree and grew with the tree; the removal is this
        // process's own now, so every argv git sees is a READ.
        let bare = bareArgvs(runner)
        XCTAssertEqual(
            bare,
            staleGateArgvs(worktree: worktree, repository: repository)
                + gatedPruneArgvs(repository: repository),
            "the delete-time sequence must use the SHARED builders, in order"
        )
        XCTAssertNil(bare.first { $0.contains("remove") },
                     "no `worktree remove` may run at all: \(bare)")
        XCTAssertNil(bare.first { $0.contains("prune") }, "\(bare)")
        // D17, on REAL invocations: EVERY git invocation on this path is the
        // read-only profile now — there is no mutating one left to classify.
        for invocation in runner.invocations {
            XCTAssertEqual(invocation.profile, .readOnly, "\(invocation.argv)")
        }
        // The DELETE-TIME budget on EVERY invocation, not fn-5.1's scan
        // default.
        XCTAssertEqual(
            runner.timeouts,
            Array(
                repeating: WorktreeReclaimPerformer.deleteTimeGitTimeout,
                count: bare.count
            )
        )
        XCTAssertNotEqual(
            WorktreeReclaimPerformer.deleteTimeGitTimeout,
            GitCommandRunner.scanTimeout
        )
        assertNoForbiddenArgv(runner)
    }

    /// D16 AS CORRECTED BY r5 (D1/D7). While `git worktree remove` was the
    /// primary arm this cell asserted the opposite — `.permanent` in a Trash
    /// run, trash seam never called — because `git worktree remove` unlinks
    /// whatever the toggle says. The GUI ships `moveToTrash = true`, so that made the
    /// app's most common worktree removal unconditionally unrecoverable.
    /// This process removes the tree now, so the toggle applies.
    func testTheStaleRemovalHonoursTheTrashToggleNowThatGitIsNotTheRemover()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let performer = makePerformer(
            runner: InterceptingGitRunner(wrapping: realRunner()),
            moveToTrash: true
        )
        let outcome = await perform(item(plan), plan: plan, with: performer)

        let entry = try XCTUnwrap(outcome.entry)
        XCTAssertEqual(entry.disposal, .trash)
        XCTAssertFalse(fm.fileExists(atPath: worktree.path))
        XCTAssertTrue(
            fm.fileExists(atPath: trashDirectory.appendingPathComponent("wt").path),
            "the CHECKOUT is recoverable — which it never was through r4"
        )
    }

    // MARK: - R5: four-class routing at the WITNESS and the LAST GATE

    /// The D2 ignored WITNESS is its own fail-closed gate: taken once R0 and
    /// R1/R1b have proved WHICH checkout this is, a reading that cannot
    /// answer refuses before R2's ladder and before anything is removed.
    func testAWitnessThatCannotAnswerRefusesBeforeTheAncestryLadder()
        async throws
    {
        for (name, scripted, fragment) in [
            ("timeout", GitCommandOutcome.timeout, "clean check timed out"),
            ("unavailable", .gitUnavailable, "git unavailable"),
            ("failure", .failure(exitCode: 128, stderr: "fatal: not a work tree"),
             "git exit 128"),
        ] {
            let repository = try makeRepository(named: "repo-\(name)")
            let worktree = try addWorktree(
                named: "wt-\(name)", branch: "feature", in: repository
            )
            let plan = staleplan(
                worktree: worktree,
                membership: try membership(of: worktree, in: repository)
            )
            let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
                arguments.contains("status") ? scripted : nil
            }
            let outcome = await perform(
                item(plan), plan: plan, with: makePerformer(runner: runner)
            )

            XCTAssertNil(outcome.entry, name)
            let message = try XCTUnwrap(outcome.errors.first?.message, name)
            XCTAssertTrue(message.contains("could not prove this worktree clean"),
                          "\(name): \(message)")
            XCTAssertTrue(message.contains(fragment), "\(name): \(message)")
            XCTAssertTrue(message.contains("Retry once git can answer"),
                          "the refusal must name what clears it: \(message)")
            XCTAssertEqual(
                bareArgvs(runner),
                [
                    WorktreeReclaimPerformer.commonGitDirArguments(
                        parentRepoWorkingDir: repository
                    ),
                    GitWorktreeOracle.listArguments(forRepositoryAt: repository),
                    GitWorktreeCleanCheck.arguments(forWorktreeAt: worktree),
                ],
                "\(name): identity first, then the witness, then nothing"
            )
            XCTAssertTrue(fm.fileExists(atPath: worktree.path), name)
        }
    }

    /// The LAST gate's four-class routing, reached only after every other
    /// gate has passed — the counter is what puts the script on the SECOND
    /// `status`, so this cell cannot be satisfied by the witness arm above.
    func testTheLastGateThatCannotAnswerRefusesAfterEveryOtherGatePassed()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let statuses = GitCallCounter()
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            guard arguments.contains("status") else { return nil }
            return statuses.next() == 2 ? .gitUnavailable : nil
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.entry, "an unanswered last gate accepts no claims")
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("could not prove this worktree clean"),
                      message)
        XCTAssertTrue(message.contains("git unavailable"), message)
        XCTAssertEqual(
            bareArgvs(runner),
            staleGateArgvs(worktree: worktree, repository: repository),
            "every gate ran, and NOTHING ran after the last one"
        )
        XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                      "the tree survives an unanswered last gate")
    }

    func testGitUnavailableAtTheGateReestablishmentRefusesBeforeAnyMutation()
        async throws
    {
        // The re-establishment's own four-class routing: a gitUnavailable at
        // R0 must refuse BEFORE `worktree remove` is even attempted, and it
        // must say so in its own words.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let runner = InterceptingGitRunner(wrapping: UnreachableGitRunner()) { _, _ in
            .gitUnavailable
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(
            message.contains("git became unavailable before the parent "
                             + "repository could be re-resolved"), message
        )
        XCTAssertTrue(message.contains("Retry once git is installed"), message)
        XCTAssertEqual(runner.argvs.count, 1, "\(runner.argvs)")
        XCTAssertNil(runner.argvs.first { $0.contains("remove") })
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }

    /// THE WHOLE DELETE-TIME SEQUENCE, pinned as a SEQUENCE, with the r5
    /// shape: witness → R0/R1/R1b/R2 → last gate → prune recompute → R0.
    ///
    /// Through r4 this cell was `testNonZeroExitIsTheOnlyClassThatReachesTheReCheck`
    /// and the sequence ran the gates TWICE around a `worktree remove`,
    /// because the fallback was a second, independently reachable arm. There
    /// is one arm now (D1), so the gates run once and there is no mutating
    /// argv anywhere in the list.
    func testTheDeleteTimeSequenceIsWitnessGatesLastGateAndNoMutatingGit()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.errors.first?.message, "the removal should have run")
        XCTAssertNotNil(outcome.entry)
        // THE STATUS RE-CHECK IS LAST, and this ordering is asserted here
        // rather than inferred (PR #460 codex r3). Through r2 it sat
        // immediately after `remove`, which left five git subprocesses and
        // two path re-admissions between "this tree is clean" and the
        // delete — measured, work saved in that window was destroyed under a
        // SUCCESS entry.
        //
        // ASSERTED AS ONE WHOLE SEQUENCE, never by subscripting (PR #460
        // codex r2 / D2). The previous shape indexed `bare[5]`,
        // `bare[7..<12]` and `bare[13]` into a RUNTIME-LENGTH array, so a
        // regression that dropped one delete-time invocation killed the
        // PROCESS with "Array index is out of range" — measured twice — and
        // every alphabetically-later cell and every later suite silently
        // never ran, behind a per-suite "0 failures" tally. A dropped
        // invocation must fail a NAMED CELL, and in the file that guards the
        // deletion path that is not a stylistic preference.
        let bare = bareArgvs(runner)
        XCTAssertEqual(
            bare,
            staleGateArgvs(worktree: worktree, repository: repository)
                + gatedPruneArgvs(repository: repository)
        )
        XCTAssertNil(bare.first { $0.contains("prune") }, "\(bare)")
        XCTAssertNil(bare.first { $0.contains("remove") },
                     "no mutating git argv survives r5: \(bare)")
        XCTAssertEqual(
            Set(runner.invocations.map(\.profile)), [.readOnly],
            "every git invocation on the delete path is a READ"
        )
        assertNoForbiddenArgv(runner)
    }

    // MARK: - R5: the guarded removal + the GATED prune

    /// THE PRODUCT BOUNDARY D2 MADE EXPLICIT: an ignored file that was
    /// ALREADY there when the checks started is removed with the tree.
    ///
    /// This is not an oversight and it is the reason the D2 gate compares a
    /// SET rather than refusing on any ignored path at all: an ignored build
    /// tree is exactly what this scanner exists to reclaim, and a gate that
    /// refused on `.build/` or `node_modules/` would refuse every worktree it
    /// is for. The companion cell
    /// `testAnIgnoredFileThatAppearsInTheGateWindowIsNotDestroyed` pins the
    /// half that DOES refuse.
    func testAPreexistingIgnoredFileIsRemovedWithTheTreeAndTheGatedPruneRuns()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let membership = try membership(of: worktree, in: repository)
        let adminEntry = membership.parentAdminContainer
            .appendingPathComponent("wt")
        let plan = staleplan(worktree: worktree, membership: membership)

        // The ignored file is present BEFORE the witness is taken, so it is
        // in both readings and refuses nothing. The `.gitignore` is committed
        // on the worktree's branch and merged back into `main`, because a
        // commit the default branch does not contain would fail G3 and this
        // cell would then be about ancestry rather than about ignored files.
        try commitIgnoreRule("secret.env", in: worktree)
        try fastForwardDefaultBranch(to: "feature", in: repository)
        try Data("TOKEN=1".utf8)
            .write(to: worktree.appendingPathComponent("secret.env"))

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let report = await makeCleaner(runner: runner)
            .clean(items: [item(plan)], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errorLines)")
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertGreaterThan(entry.exactBytes, 40_000)
        XCTAssertNil(entry.warning,
                     "the gated prune ran, so nothing was left behind")
        XCTAssertEqual(entry.disposal, .permanent)

        XCTAssertFalse(fm.fileExists(atPath: worktree.path))
        XCTAssertFalse(fm.fileExists(
            atPath: worktree.appendingPathComponent("secret.env").path
        ), "the ignored file went with the tree — the documented boundary")
        XCTAssertFalse(fm.fileExists(atPath: adminEntry.path),
                       "the gated prune must have cleaned the registry")
        XCTAssertEqual(try porcelainRecordCount(of: repository), 1)
        XCTAssertTrue(try branchExists("feature", in: repository),
                      "a reclaim must never take the branch with it")

        // The gated post-removal cleanup is a SCOPED removal of exactly
        // that worktree's own admin entry — no repository-wide prune argv
        // exists to reach (PR #460 codex r1 / C4). Proof is above: the admin
        // entry is gone, the OTHER registered worktree's entry is not
        // consulted, and the registry reads clean through git.
        XCTAssertNil(runner.argvs.first { $0.contains("prune") }, "\(runner.argvs)")
        assertNoForbiddenArgv(runner)
    }

    /// D2, THE HALF THAT REFUSES. A file a committed `.gitignore` hides,
    /// created while the delete-time checks are running, is not destroyed.
    ///
    /// MEASURED at r4, with no witness: `secret.env` written in exactly this
    /// window was destroyed with the tree and the performer returned
    /// `Entry(exactBytes: 49152, .permanent, warning: nil)` with
    /// `errors == []`, while the same fixture using a NON-ignored file
    /// refused — because `git status --porcelain` reports nothing at all
    /// about an ignored path. `docs/v1/CATEGORIES.md:519` said "work saved
    /// while the checks were running is caught rather than destroyed", which
    /// was false for exactly that file.
    ///
    /// The write is staged on the ancestry rung: after the ignored WITNESS
    /// and before the LAST gate, so only the set comparison can catch it.
    ///
    /// MUTATION: delete the `appeared` refusal from
    /// `removeUnderLastInstantProof` and this cell goes RED — the tree and
    /// the file are gone and `outcome.entry` is non-nil.
    func testAnIgnoredFileThatAppearsInTheGateWindowIsNotDestroyed()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        try commitIgnoreRule("secret.env", in: worktree)
        try fastForwardDefaultBranch(to: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let secret = worktree.appendingPathComponent("secret.env")
        let payload = Data("TOKEN=the-only-copy".utf8)
        let staged = InvocationCounter()

        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            if arguments.contains("merge-base"), staged.bump() == 1 {
                try? payload.write(to: secret)
            }
            return nil
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(staged.count, 1, "the fixture never staged the write")
        // The tree is CLEAN throughout — this is not the dirty gate firing.
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("`.gitignore` hides"), message)
        XCTAssertTrue(message.contains("secret.env"), message)
        XCTAssertFalse(message.contains("DIRTY"),
                       "an ignored file is not dirt: \(message)")
        XCTAssertTrue(fm.fileExists(atPath: secret.path),
                      "the only copy of that work was destroyed")
        XCTAssertEqual(try Data(contentsOf: secret), payload)
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
        XCTAssertEqual(try porcelainRecordCount(of: repository), 2)
    }

    // MARK: - D1: the clean re-check is the LAST gate (PR #460 codex r3)

    /// Work saved WHILE the delete-time gates are running survives, in BOTH
    /// disposal arms.
    ///
    /// The write is injected on the FIRST `merge-base` — R2's last rung,
    /// which runs after the D2 ignored witness and before the last gate, so
    /// only the last gate can catch it. (Through r4 this note described an
    /// injection on the SECOND `rev-parse --git-common-dir`, "the first
    /// invocation of the FALLBACK's gate re-establishment": there is one arm
    /// now, so there is no second gate re-establishment, and the second
    /// `--git-common-dir` belongs to the POST-removal prune recompute — after
    /// the delete, where an injected write would prove nothing.) Under the
    /// r1/r2 order — clean re-check, then R0/R1/R1b/R2, then the delete —
    /// that instant is AFTER the re-check, and the file was destroyed while
    /// the performer returned a SUCCESS entry with `errors == []` and
    /// `warning == nil`. Five git subprocesses and two path re-admissions sat
    /// in that window.
    ///
    /// MUTATION EVIDENCE (PR #460 codex r3): move the
    /// `GitWorktreeCleanCheck.read` switch above `reestablishStaleGates`
    /// in `removeUnderLastInstantProof` and this cell goes RED on its first
    /// assertion — the saved file is gone and `outcome.entry` is non-nil.
    ///
    /// r5 restages the write on the ANCESTRY rung: `merge-base` runs after
    /// the D2 witness and before the last gate, so only the last gate can
    /// catch it. Staging it earlier would be caught by the witness instead
    /// and would prove nothing about the ordering.
    func testWorkSavedWhileTheDeleteTimeGatesRunSurvivesInBothDisposals()
        async throws
    {
        for (index, moveToTrash) in [false, true].enumerated() {
            let repository = try makeRepository(named: "repo-\(index)")
            let worktree = try addWorktree(
                named: "wt-\(index)", branch: "feature-\(index)", in: repository
            )
            let plan = staleplan(
                worktree: worktree,
                membership: try membership(of: worktree, in: repository)
            )
            let saved = worktree.appendingPathComponent("saved-work.txt")
            let payload = Data("work saved after the click".utf8)
            let commonDirCalls = InvocationCounter()

            let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
                if arguments.contains("merge-base"), commonDirCalls.bump() == 1 {
                    try? payload.write(to: saved)
                }
                return nil
            }

            let outcome = await perform(
                item(plan), plan: plan,
                with: makePerformer(runner: runner, moveToTrash: moveToTrash)
            )

            XCTAssertTrue(
                fm.fileExists(atPath: saved.path),
                "moveToTrash=\(moveToTrash): the saved work was DESTROYED — "
                    + "the clean re-check is not the last gate"
            )
            XCTAssertEqual(try Data(contentsOf: saved), payload,
                           "moveToTrash=\(moveToTrash)")
            XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                          "moveToTrash=\(moveToTrash)")
            XCTAssertNil(outcome.entry,
                         "moveToTrash=\(moveToTrash): nothing was freed")
            XCTAssertEqual(outcome.errors.count, 1, "\(outcome.errors)")
            let message = try XCTUnwrapElement(outcome.errors, 0).message
            XCTAssertTrue(message.contains("DIRTY"), message)

            // The tree is still registered: nothing touched the registry.
            XCTAssertEqual(try porcelainRecordCount(of: repository), 2)
            XCTAssertTrue(try branchExists("feature-\(index)", in: repository))

            // THE ORDERING, asserted directly: the clean re-check is the LAST
            // git invocation the removal path makes. Under the old order it
            // was the first one after the refusal, with five more behind it.
            XCTAssertEqual(
                bareArgvs(runner).last ?? [],
                GitWorktreeCleanCheck.arguments(forWorktreeAt: worktree),
                "moveToTrash=\(moveToTrash): \(bareArgvs(runner))"
            )
            assertNoForbiddenArgv(runner)
        }
    }

    func testTheEntryIsTrashOnlyWhenTheTrashHandlerActuallySucceeded()
        async throws
    {
        // D16, both directions, plus the R11 rule that a trash FAILURE is an
        // error and never falls through to a permanent delete.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let failing = InterceptingGitRunner(wrapping: realRunner())

        // (a) the trash handler FAILS: per-item error, tree untouched.
        let refused = await perform(
            item(plan), plan: plan,
            with: makePerformer(
                runner: failing, moveToTrash: true,
                trash: { _, prove in
                    try prove()
                    throw NSError(
                        domain: "fixture", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "trash refused"]
                    )
                }
            )
        )
        XCTAssertNil(refused.entry, "a trash failure produces NO entry")
        XCTAssertTrue(
            try XCTUnwrap(refused.errors.first?.message).contains("trash refused")
        )
        XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                      "a trash failure must never fall through to a permanent delete")

        // (b) the handler SUCCEEDS: the entry is `.trash`.
        let succeeded = await perform(
            item(plan), plan: plan,
            with: makePerformer(runner: failing, moveToTrash: true)
        )
        XCTAssertEqual(try XCTUnwrap(succeeded.entry).disposal, .trash)
        XCTAssertFalse(fm.fileExists(atPath: worktree.path))
        XCTAssertTrue(fm.fileExists(
            atPath: trashDirectory.appendingPathComponent("wt").path
        ))
    }

    func testTheRemovalRefusesATrashDisposalItCannotProveTookTheWorktree()
        async throws
    {
        // fn-5 RECONCILIATION — the LAST unbound deletion path in the app.
        //
        // `moveToTrash` is `true` out of the box (`CacheoutViewModel`), so
        // this is the disposal the GUI actually performs on a stale worktree,
        // and it handed the mover a BARE URL while every other item's Trash
        // disposal went through
        // `TrashDisposal.dispose(_:containedIn:provider:via:)`. The CLI is not
        // exposed at all — it always passes `moveToTrash: false`.
        //
        // WHAT THIS ASSERTS IS WHAT THE DISPOSAL PROVED, not that it returned.
        // The seam performs two real renames INSIDE itself, which is the one
        // window `trashItem` leaves open: it takes a URL and resolves it
        // internally, so no descriptor can ride into the call. The object that
        // reaches the Trash is therefore a STRANGER, and the only thing that
        // can notice is the after-proof — the leaf re-read where the mover
        // said it landed, compared with the facts bound under the admitted
        // container before the move.
        //
        // Unbound, the app reports SUCCESS while a stranger's tree sits in the
        // Trash and the worktree it measured is untouched: `disposal: .trash`
        // with the measured byte count, `errors=[]`. That is the shape the
        // four assertions below are pinned to.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let failing = InterceptingGitRunner(wrapping: realRunner())

        // A stranger's tree, and somewhere to park the real worktree — both
        // OUTSIDE the container, so nothing the guard admits changes shape.
        let stranger = base.appendingPathComponent("stranger")
        try fm.createDirectory(at: stranger, withIntermediateDirectories: true)
        try Data("not yours".utf8)
            .write(to: stranger.appendingPathComponent("STRANGER"))
        let stash = base.appendingPathComponent("stashed-worktree")
        let landing = trashDirectory.appendingPathComponent(
            worktree.lastPathComponent
        )
        let fileManager = fm
        let outcome = await perform(
            item(plan), plan: plan,
            with: makePerformer(
                runner: failing, moveToTrash: true,
                trash: { url, prove in
                    // `prove()` FIRST, as the production seam does on the far
                    // side of its hop — the swap below therefore lands where
                    // no proof of ours can reach it, which is exactly the
                    // window this cell exists to pin.
                    try prove()
                    // The swap the mover cannot be protected from: the
                    // worktree steps aside and the stranger answers to its
                    // name, all after the binding was taken.
                    try fileManager.moveItem(at: url, to: stash)
                    try fileManager.moveItem(at: stranger, to: url)
                    try fileManager.moveItem(at: url, to: landing)
                    return landing
                }
            )
        )

        XCTAssertNil(
            outcome.entry,
            "a disposal that cannot be proved reports NO entry and NO bytes"
        )
        XCTAssertTrue(
            try XCTUnwrap(outcome.errors.first?.message).contains("PUT BACK"),
            "the refusal must be the disposal's own after-proof, which says "
                + "what it established: \(outcome.errors)"
        )
        XCTAssertFalse(
            fileManager.fileExists(atPath: landing.path),
            "the stranger's tree must not be LEFT in the Trash — the "
                + "unprovable disposal is undone, not merely reported"
        )
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: worktree.appendingPathComponent("STRANGER").path
            ),
            "the put-back must restore the stranger to the name it was taken "
                + "from, inside the admitted container"
        )
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: stash.appendingPathComponent("tracked.txt").path
            ),
            "the worktree the app measured was never disposed of at all"
        )
    }

    // MARK: - D1: the mover's hop, MEASURED under main-thread load

    /// Every question this deletion asks the FILESYSTEM, timestamped — so the
    /// interval between the LAST of them and the mover can be measured
    /// without instrumenting production at all.
    ///
    /// `probeChild` is the one that matters: it is what
    /// `TrashDisposal.boundLeaf` binds the leaf with, and it is therefore the
    /// last thing that runs before the move. The other three are recorded too
    /// so the "last question" is genuinely the last one and not merely the
    /// last one this class happens to see.
    private final class HopWindowClock: FileSystemIdentityProvider {
        private let lock = NSLock()
        private var lastQuestion: DispatchTime?
        /// Every `probeChild` for the leaf NAME under measurement, in order.
        /// The FIRST is the binding taken before the seam is entered; the
        /// LAST is the one taken on the far side of the seam's hop. Their
        /// distance IS the hop, which is what proves the load was real.
        private var leafBindings: [DispatchTime] = []
        private var leafName = ""
        private var frozen: (proof: DispatchTime, seam: DispatchTime)?

        func measureLeaf(named name: String) {
            lock.lock(); leafName = name; lock.unlock()
        }

        private func note() {
            lock.lock(); lastQuestion = .now(); lock.unlock()
        }

        override func identity(of url: URL) -> Identity? {
            note(); return super.identity(of: url)
        }

        override func identity(ofDescriptor descriptor: Int32) -> Identity? {
            note(); return super.identity(ofDescriptor: descriptor)
        }

        override func probeKind(of url: URL) -> KindProbe {
            note(); return super.probeKind(of: url)
        }

        override func probeChild(
            inDirectory directory: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            lock.lock()
            let now = DispatchTime.now()
            lastQuestion = now
            if name == leafName { leafBindings.append(now) }
            lock.unlock()
            return super.probeChild(
                inDirectory: directory, named: name, logical: logical()
            )
        }

        /// Called from the injected trash handler — production reaches it
        /// INSIDE `MainActor.run`, which is the hop this cell is about.
        func enteredTheSeam() {
            lock.lock()
            if frozen == nil, let proof = lastQuestion {
                frozen = (proof, .now())
            }
            lock.unlock()
        }

        /// Last filesystem question answered → the mover was entered.
        var windowNanoseconds: UInt64? {
            lock.lock(); defer { lock.unlock() }
            guard let frozen,
                  frozen.seam.uptimeNanoseconds >= frozen.proof.uptimeNanoseconds
            else { return nil }
            return frozen.seam.uptimeNanoseconds - frozen.proof.uptimeNanoseconds
        }

        /// First leaf binding → last leaf binding: the hop itself, and the
        /// proof that the main thread really was loaded.
        var hopNanoseconds: UInt64? {
            lock.lock(); defer { lock.unlock() }
            guard let first = leafBindings.first, let last = leafBindings.last,
                  last.uptimeNanoseconds >= first.uptimeNanoseconds
            else { return nil }
            return last.uptimeNanoseconds - first.uptimeNanoseconds
        }
    }

    /// THE D1 MEASUREMENT (PR #460 codex r6) — and the regression guard that
    /// keeps the answer true.
    ///
    /// THE DEFECT. `FileManager.trashItem` requires the main actor, so
    /// `CacheCleaner` wraps the mover in `MainActor.run`. Through r5 every
    /// proof this deletion takes — the clean re-check, the ignored witness,
    /// the last-instant filesystem re-proof, `TrashDisposal`'s own leaf
    /// binding — ran on the NEAR side of that hop, so the interval between the
    /// last of them and the destruction was the MAIN THREAD'S QUEUE DEPTH.
    /// The file header published "trash … median 0.674 ms", measured idle,
    /// and called the 16.152 ms sample in the same run an outlier "from the
    /// mover". It was not: an idle hop is ~0.02 ms and a same-volume mover
    /// cannot take 16 ms, while main-thread scheduling accounts for it
    /// exactly.
    ///
    /// WHAT THIS CELL DOES. It drives the PRODUCTION composition —
    /// `CacheCleaner` building its own performer, wiring its own trash seam —
    /// over a real git worktree, with a 120 ms busy-wait work item pushed onto
    /// the main thread at every `git status` (the last git call before the
    /// disposal), and an instrumented provider that timestamps every
    /// filesystem question. Two numbers come out of each run:
    ///
    /// - **the hop** — first leaf binding → last leaf binding. These are the
    ///   two `boundLeaf` readings that straddle the seam, so this IS the
    ///   queue delay, and it is asserted LARGE. Without it the cell would
    ///   pass trivially on an idle machine and measure nothing.
    /// - **the window** — last filesystem question → the mover is entered. It
    ///   is asserted SMALL, which is only possible if the proof runs on the
    ///   FAR side of the hop.
    ///
    /// MEASURED, n=5, by
    ///
    ///     swift test --filter \
    ///       testTheTrashProofAndTheMoveAreNotSeparatedByTheMainThreadQueue
    ///
    /// pasted from that run's own output:
    ///
    ///     MEASURED-TRASH-HOP-MS ["175.321", "164.578", "174.548",
    ///                            "186.181", "178.629"] median 175.321
    ///     MEASURED-TRASH-WINDOW-UNDER-LOAD-MS ["0.016", "0.004", "0.004",
    ///                            "0.004", "0.004"] median 0.004
    ///
    /// MUTATION, the r5 shape restored — `try prove()` moved back OUTSIDE
    /// `MainActor.run` in both `CacheCleaner.trash(_:provingImmediatelyBefore:)`
    /// and the performer's seam — same command:
    ///
    ///     MEASURED-TRASH-HOP-MS ["185.350", "176.090", "160.957",
    ///                            "162.188", "179.049"] median 176.090
    ///     MEASURED-TRASH-WINDOW-UNDER-LOAD-MS ["184.937", "175.736",
    ///                            "160.352", "161.769", "178.649"]
    ///                            median 175.736
    ///     XCTAssertLessThan failed: ("175.735709") is not less than ("20.0")
    ///
    /// so the cell goes RED on the shape it exists to forbid, and the two
    /// hop medians (175.3 ms / 176.1 ms) show the load was identical.
    func testTheTrashProofAndTheMoveAreNotSeparatedByTheMainThreadQueue()
        async throws
    {
        var hops: [Double] = []
        var windows: [Double] = []
        let samples = 5
        for run in 0..<samples {
            let repository = try makeRepository(named: "repo-\(run)")
            let worktree = try addWorktree(
                named: "wt-\(run)", branch: "feature-\(run)", in: repository
            )
            let plan = staleplan(
                worktree: worktree,
                membership: try membership(of: worktree, in: repository)
            )
            let clock = HopWindowClock()
            clock.measureLeaf(named: worktree.lastPathComponent)
            // 120 ms of main-thread work, pushed at the LAST git call before
            // the disposal. `status` runs twice on this path (the ignored
            // witness and G2), so the main thread is busy across the whole
            // approach to the hop rather than for one instant of it.
            let runner = InterceptingGitRunner(
                wrapping: realRunner(),
                intercept: { argv, _ in
                    guard argv.contains("status") else { return nil }
                    DispatchQueue.main.async {
                        let until = DispatchTime.now().uptimeNanoseconds
                            + 120_000_000
                        while DispatchTime.now().uptimeNanoseconds < until {}
                    }
                    return nil
                }
            )
            let landing = trashDirectory.appendingPathComponent(
                worktree.lastPathComponent
            )
            let cleaner = CacheCleaner(
                home: home,
                containerRoots: [container],
                containerSnapshot: ContainerSnapshot.capture(
                    roots: [container], provider: clock
                ),
                provider: clock,
                trashHandler: { url in
                    clock.enteredTheSeam()
                    try FileManager.default.moveItem(at: url, to: landing)
                    return landing
                },
                gitRunner: runner
            )
            let report = await cleaner.clean(
                items: [item(plan, id: "item-\(run)")], moveToTrash: true
            )
            XCTAssertEqual(
                report.errors.map(\.message), [],
                "the measured run must be a real, successful Trash disposal"
            )
            XCTAssertEqual(report.entries.map(\.disposal), [.trash])
            let hop = try XCTUnwrap(clock.hopNanoseconds)
            let window = try XCTUnwrap(clock.windowNanoseconds)
            hops.append(Double(hop) / 1_000_000)
            windows.append(Double(window) / 1_000_000)
        }
        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }
        print(
            "MEASURED-TRASH-HOP-MS \(hops.map { String(format: "%.3f", $0) })"
                + " median \(String(format: "%.3f", median(hops)))"
        )
        print(
            "MEASURED-TRASH-WINDOW-UNDER-LOAD-MS "
                + "\(windows.map { String(format: "%.3f", $0) })"
                + " median \(String(format: "%.3f", median(windows)))"
        )
        XCTAssertGreaterThan(
            median(hops), 40,
            "the main thread was NOT loaded, so this cell measured nothing: "
                + "hops \(hops)"
        )
        XCTAssertLessThan(
            median(windows), 20,
            "the last proof and the move are separated by the main thread's "
                + "queue depth — the proof is on the wrong side of the hop: "
                + "windows \(windows), hops \(hops)"
        )
    }


    // MARK: - The proofs on the FAR SIDE of each arm's own hop (r6 D1, r7 D1/D3)

    /// M1's cell — the far-side `reproveFromTheFilesystem` inside the mover
    /// closure — AND M6's, the `catch let refusal as LastInstantRefusal` arm.
    ///
    /// r6 added both and evidenced neither: the r7 review measured that
    /// deleting the far-side re-proof (keeping `proveTheLeaf()`) and deleting
    /// the typed catch arm each left `swift test` AT COMMIT 26c880b at
    /// 1471 executed / 2 skipped / 0 failures, exit 0.
    ///
    /// THE ATTACK IS A LOCK, NOT A RE-ADD, AND THAT IS THE WHOLE POINT.
    /// `git worktree lock` writes `<admin>/locked` and touches neither the
    /// checkout's inode nor its contents, so `TrashDisposal`'s own leaf
    /// binding — the other proof inside that closure — still passes. The ONLY
    /// thing that can refuse this is the re-proof, which is what makes the
    /// cell specific to it. (A same-path re-add would be caught by either.)
    ///
    /// AND THE TAG IS ASSERTED, WHICH IS M6. `LastInstantRefusal`'s
    /// `errorDescription` is the detail, so with the typed catch arm deleted
    /// the per-item MESSAGE is byte-identical — the refusal simply stops being
    /// logged and becomes untagged, which is the shape four rounds of this
    /// branch have been removing. Only the log can tell the two apart.
    func testTheTrashArmRefusesACheckoutLockedInsideTheMoversHop()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(
            named: "wt", branch: "feature", in: repository
        )
        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )
        let home = try XCTUnwrap(self.home)
        let trashRoot = try XCTUnwrap(trashDirectory)
        let fileManager = fm
        let staged = InvocationCounter()
        let moved = TrashRecorder()
        let refusals = RefusalLog()

        let outcome = await perform(
            item(plan), plan: plan,
            with: makePerformer(
                runner: InterceptingGitRunner(wrapping: realRunner()),
                moveToTrash: true,
                trash: { url, prove in
                    // THE HOP: production reaches this closure inside
                    // `MainActor.run`, having waited out the main queue. The
                    // wait is replaced by the event it admits.
                    if Self.lockWorktree(
                        worktree, repository: repository, home: home
                    ) { staged.bump() }
                    try prove()
                    moved.record(url)
                    let landed = trashRoot.appendingPathComponent(
                        url.lastPathComponent
                    )
                    try fileManager.moveItem(at: url, to: landed)
                    return landed
                },
                refusals: refusals
            )
        )

        XCTAssertEqual(staged.count, 1, "the fixture never staged the lock")
        XCTAssertNil(outcome.entry, "nothing may be reported as freed")
        XCTAssertEqual(
            moved.urls, [],
            "the refusal is BEFORE the move: the Trash must be untouched"
        )
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(
            message.contains("LOCKED while the delete-time checks"), message
        )
        XCTAssertTrue(
            fm.fileExists(atPath: worktree.path),
            "a worktree locked inside the hop was destroyed"
        )
        // M6: the refusal reached the log WITH its tag, indistinguishable
        // from the same refusal raised on the near side.
        XCTAssertEqual(refusals.tags, ["worktree-locked"])
        XCTAssertEqual(refusals.details, [message])
    }

    /// The permanent arm's own far-side re-proof (PR #460 codex r7, D1) — the
    /// guard this round ADDED, with the cell that kills it.
    ///
    /// r6 asserted that this arm "never had this shape", because it hops to a
    /// global concurrent queue where `DepthSafeRemoval` re-proves the
    /// container from a descriptor. It does — the CONTAINER. Which checkout
    /// stands at the path, whether it is locked and whether HEAD moved are
    /// not propositions `DepthSafeRemoval` can express, and until r7 all three
    /// were last proved on the NEAR side of this hop. Same attack as the
    /// Trash cell above, same refusal, same tag.
    func testThePermanentArmRefusesACheckoutLockedInsideItsOwnHop()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(
            named: "wt", branch: "feature", in: repository
        )
        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )
        let home = try XCTUnwrap(self.home)
        let fileManager = fm
        let staged = InvocationCounter()
        let removed = TrashRecorder()
        let refusals = RefusalLog()

        let outcome = await perform(
            item(plan), plan: plan,
            with: makePerformer(
                runner: InterceptingGitRunner(wrapping: realRunner()),
                moveToTrash: false,
                removeTree: { url, _, prove in
                    if Self.lockWorktree(
                        worktree, repository: repository, home: home
                    ) { staged.bump() }
                    try prove()
                    removed.record(url)
                    try fileManager.removeItem(at: url)
                },
                refusals: refusals
            )
        )

        XCTAssertEqual(staged.count, 1, "the fixture never staged the lock")
        XCTAssertNil(outcome.entry)
        XCTAssertEqual(
            removed.urls, [],
            "the refusal is BEFORE the removal: nothing may be unlinked"
        )
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(
            message.contains("LOCKED while the delete-time checks"), message
        )
        XCTAssertTrue(
            fm.fileExists(atPath: worktree.path),
            "a worktree locked inside the hop was destroyed"
        )
        XCTAssertEqual(refusals.tags, ["worktree-locked"])
        XCTAssertEqual(refusals.details, [message])
    }


    // MARK: - The permanent arm's window, measured under load (r7, D1/D2)

    /// Every filesystem question, timestamped, plus the two boundaries this
    /// cell needs: the last GIT COMPLETION before the destruction (the
    /// cleanliness gate's, which is D2's quantity) and the destruction
    /// itself.
    ///
    /// THE DESTRUCTION MARKER FOR THE PERMANENT ARM is the first
    /// `identity(ofDescriptor:)` asked after `<admin>/locked` has been
    /// probed. `reproveFromTheFilesystem` is the only code that probes that
    /// name, and the next descriptor-identity question after it is
    /// `DepthSafeRemoval.openAndProveContainer` — the first act on the far
    /// side of `removeItemConcurrently`'s hop, one `openat` before the walk
    /// that unlinks. The marker is keyed on a NAMED file rather than on a
    /// call count, so it does not drift with tree shape.
    private final class WindowClock: FileSystemIdentityProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var lastQuestion: DispatchTime?
        private var lastGit: DispatchTime?
        private var sawLockProbe = false
        private var proofWindow: (from: DispatchTime, to: DispatchTime)?
        private var gitWindow: (from: DispatchTime, to: DispatchTime)?
        /// `true` for the permanent arm, where the descriptor question marks
        /// the destruction. The Trash arm marks it from the mover instead —
        /// its own pre-move `boundLeaf` asks a descriptor question on the
        /// NEAR side, which would freeze the wrong instant.
        private let marksOnDescriptor: Bool

        init(marksOnDescriptor: Bool) {
            self.marksOnDescriptor = marksOnDescriptor
            super.init()
        }

        func noteGitCompletion() {
            lock.lock(); lastGit = .now(); lock.unlock()
        }

        /// The destruction is about to happen: freeze both windows.
        func destructionReached() {
            lock.lock()
            let now = DispatchTime.now()
            if proofWindow == nil, let from = lastQuestion {
                proofWindow = (from, now)
            }
            if gitWindow == nil, let from = lastGit { gitWindow = (from, now) }
            lock.unlock()
        }

        private func note() { lock.lock(); lastQuestion = .now(); lock.unlock() }

        override func identity(of url: URL) -> Identity? {
            defer { note() }
            return super.identity(of: url)
        }

        override func identity(ofDescriptor descriptor: Int32) -> Identity? {
            lock.lock()
            let armed = marksOnDescriptor && sawLockProbe
            lock.unlock()
            if armed { destructionReached() }
            defer { note() }
            return super.identity(ofDescriptor: descriptor)
        }

        override func probeKind(of url: URL) -> KindProbe {
            if url.lastPathComponent == "locked" {
                lock.lock(); sawLockProbe = true; lock.unlock()
            }
            defer { note() }
            return super.probeKind(of: url)
        }

        override func probeChild(
            inDirectory directory: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            defer { note() }
            return super.probeChild(
                inDirectory: directory, named: name, logical: logical()
            )
        }

        private func milliseconds(
            _ window: (from: DispatchTime, to: DispatchTime)?
        ) -> Double? {
            guard let window,
                  window.to.uptimeNanoseconds >= window.from.uptimeNanoseconds
            else { return nil }
            return Double(
                window.to.uptimeNanoseconds - window.from.uptimeNanoseconds
            ) / 1_000_000
        }

        /// Last filesystem proof → the destruction.
        var proofMilliseconds: Double? {
            lock.lock(); defer { lock.unlock() }
            return milliseconds(proofWindow)
        }

        /// Last git completion → the destruction. This is CLEANLINESS: the
        /// `status --porcelain --ignored` verdict is the last git answer
        /// before the removal, and nothing re-runs it closer.
        var cleanlinessMilliseconds: Double? {
            lock.lock(); defer { lock.unlock() }
            return milliseconds(gitWindow)
        }
    }

    /// Wraps a runner, times every completion, and runs a hook BEFORE
    /// delegating so a test can put load on a queue at a chosen invocation.
    private final class TimedRunner: GitCommandRunning, @unchecked Sendable {
        private let wrapped: any GitCommandRunning
        private let clock: WindowClock
        private let before: @Sendable ([String]) -> Void
        private let after: @Sendable ([String]) -> Void

        init(
            wrapping wrapped: any GitCommandRunning, clock: WindowClock,
            before: @escaping @Sendable ([String]) -> Void = { _ in },
            after: @escaping @Sendable ([String]) -> Void = { _ in }
        ) {
            self.wrapped = wrapped
            self.clock = clock
            self.before = before
            self.after = after
        }

        var defaultTimeout: TimeInterval { wrapped.defaultTimeout }

        func run(
            _ arguments: [String], timeout: TimeInterval
        ) async -> GitCommandInvocation {
            before(arguments)
            let invocation = await wrapped.run(arguments, timeout: timeout)
            clock.noteGitCompletion()
            after(arguments)
            return invocation
        }
    }

    /// How the machine is loaded while the removal approaches its hop.
    private enum WindowLoad {
        /// 120 ms work items on the MAIN thread — the load the Trash arm's
        /// hop waits behind (r6, D1).
        case mainThread
        /// 32 × 120 ms CPU-bound items on `DispatchQueue.global(.userInitiated)`
        /// — the load the PERMANENT arm's hop waits behind, which is the one
        /// that actually applies to it. libdispatch does not overcommit for
        /// CPU-bound work, so the pool stays at core count and our block
        /// queues behind them.
        case globalQueue
    }

    /// One measured removal through the PRODUCTION composition. Returns the
    /// proof window, the cleanliness window, and the queue delay that proves
    /// the load was real.
    private func measureOneRemoval(
        run index: Int, load: WindowLoad, moveToTrash: Bool
    ) async throws -> (proof: Double, cleanliness: Double, queueDelay: Double) {
        let repository = try makeRepository(named: "repo-\(index)")
        let worktree = try addWorktree(
            named: "wt-\(index)", branch: "feature-\(index)", in: repository
        )
        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )
        let clock = WindowClock(marksOnDescriptor: !moveToTrash)
        let delay = QueueDelayWitness()
        let runner = TimedRunner(
            wrapping: realRunner(), clock: clock,
            // THE MAIN-THREAD LOAD GOES IN BEFORE the git call, exactly where
            // r6 put it: the main queue must already be deep while the checks
            // approach the hop.
            before: { arguments in
                guard case .mainThread = load,
                      arguments.contains("status") else { return }
                DispatchQueue.main.async {
                    let until = DispatchTime.now().uptimeNanoseconds
                        + 120_000_000
                    while DispatchTime.now().uptimeNanoseconds < until {}
                }
                delay.arm(on: DispatchQueue.main)
            },
            // THE POOL LOAD GOES IN AFTER the LAST git call returns, which is
            // the strictest placement there is: the saturating items are
            // enqueued microseconds before the removal enqueues its own, so
            // the removal is behind ALL of them in FIFO order. Loading the
            // pool earlier lets libdispatch grow it back before the removal
            // arrives, which measures the recovery rather than the hop.
            after: { arguments in
                guard case .globalQueue = load,
                      arguments.contains("status") else { return }
                let queue = DispatchQueue.global(qos: .userInitiated)
                for _ in 0..<32 {
                    queue.async {
                        let until = DispatchTime.now().uptimeNanoseconds
                            + 120_000_000
                        while DispatchTime.now().uptimeNanoseconds < until {}
                    }
                }
                delay.arm(on: queue)
            }
        )
        let landing = trashDirectory.appendingPathComponent(
            worktree.lastPathComponent
        )
        let cleaner = CacheCleaner(
            home: home,
            containerRoots: [container],
            containerSnapshot: ContainerSnapshot.capture(
                roots: [container], provider: clock
            ),
            provider: clock,
            trashHandler: { url in
                clock.destructionReached()
                try FileManager.default.moveItem(at: url, to: landing)
                return landing
            },
            gitRunner: runner
        )
        let report = await cleaner.clean(
            items: [item(plan, id: "item-\(index)")], moveToTrash: moveToTrash
        )
        XCTAssertEqual(
            report.errors.map(\.message), [],
            "the measured run must be a real, successful removal"
        )
        return (
            proof: try XCTUnwrap(clock.proofMilliseconds),
            cleanliness: try XCTUnwrap(clock.cleanlinessMilliseconds),
            queueDelay: try XCTUnwrap(delay.settled())
        )
    }

    /// THE r7 MEASUREMENT (D1 and D2), and the regression guard on it.
    ///
    /// r6 moved the last-instant re-proof across the Trash mover's hop and
    /// asserted the permanent arm "never had this shape". What
    /// `DepthSafeRemoval` re-proves past that arm's hop is the ADMITTED
    /// PARENT; WHICH CHECKOUT this is, whether it is LOCKED and whether HEAD
    /// MOVED are outside its vocabulary, so all three sat on the near side.
    /// r7 moves them across, and this cell is the measurement r6 did not
    /// take.
    ///
    /// TWO LOADS, because the two arms wait behind DIFFERENT queues. The
    /// Trash arm hops to the MAIN ACTOR, so main-thread depth is its width;
    /// the permanent arm hops to `DispatchQueue.global`, so a saturated
    /// global pool is its width. Both are applied to the permanent arm here:
    /// D1 asked for the main-thread figure, and the saturation figure is the
    /// one that actually describes the arm.
    ///
    /// AND THE CLEANLINESS WINDOW IS PUBLISHED, NOT MOVED (D2). `git status
    /// --porcelain --ignored` costs a subprocess and cannot run inside a
    /// disposal seam without putting a `fork`/`exec` on the main thread, so
    /// its answer stays on the near side of both hops. Its interval is
    /// therefore NOT the 0.004 ms the identity/lock/HEAD propositions enjoy,
    /// and this cell prints it for both arms rather than letting the header's
    /// summary sentence cover it.
    ///
    /// MEASURED, by
    ///
    ///     swift test --filter \
    ///       testTheWindowsThatRemainAreMeasuredUnderLoadInBothArms
    ///
    /// pasted from that run's own output at f67992e; the figures are restated
    /// in the file header's "What is left, measured".
    ///
    ///     MEASURED-PERMANENT-PROOF-WINDOW-MAIN-THREAD-LOAD-MS
    ///         ["0.030", "0.023", "0.022", "0.023", "0.040"]   median 0.023
    ///     MEASURED-PERMANENT-MAIN-QUEUE-DELAY-MS
    ///         ["120.011", "133.565", "131.197", "132.619", "127.203"]
    ///                                                        median 131.197
    ///     MEASURED-PERMANENT-PROOF-WINDOW-SATURATED-POOL-MS
    ///         ["0.031", "0.032", "0.048"]                     median 0.032
    ///     MEASURED-PERMANENT-GLOBAL-QUEUE-DELAY-MS
    ///         ["241.654", "240.188", "240.140"]               median 240.188
    ///     MEASURED-PERMANENT-CLEANLINESS-WINDOW-MAIN-THREAD-LOAD-MS
    ///         ["0.269", "0.254", "0.247", "0.273", "0.429"]   median 0.269
    ///     MEASURED-PERMANENT-CLEANLINESS-WINDOW-SATURATED-POOL-MS
    ///         ["240.360", "249.808", "241.156"]               median 241.156
    ///     MEASURED-TRASH-CLEANLINESS-WINDOW-MAIN-THREAD-LOAD-MS
    ///         ["185.993", "185.800", "185.785", "185.864", "186.442"]
    ///                                                        median 185.864
    ///     MEASURED-TRASH-MAIN-QUEUE-DELAY-MS
    ///         ["120.012", "120.020", "120.018", "120.009", "120.014"]
    ///                                                        median 120.014
    ///
    /// MUTATION, the r6 shape restored — the permanent arm's proof closure
    /// emptied to `try await removeTree(worktreePath, admittedParent) { }`,
    /// same command:
    ///
    ///     MEASURED-PERMANENT-PROOF-WINDOW-MAIN-THREAD-LOAD-MS
    ///         ["0.093", "0.040", "0.045", "0.034", "0.036"]   median 0.040
    ///     MEASURED-PERMANENT-PROOF-WINDOW-SATURATED-POOL-MS
    ///         ["242.738", "240.010", "242.656"]               median 242.656
    ///     MEASURED-PERMANENT-GLOBAL-QUEUE-DELAY-MS
    ///         ["240.432", "240.424", "242.140"]               median 240.432
    ///     XCTAssertLessThan failed: ("242.655584") is not less than ("20.0")
    ///
    /// WHAT THE TWO RUNS SAY, STATED RATHER THAN SUMMARISED.
    ///
    /// - The permanent arm is INSENSITIVE to main-thread depth — 0.040 ms
    ///   before, 0.023 ms after, against a 120–133 ms main queue. It does not
    ///   wait on that thread, and r6 was right about that much.
    /// - It is NOT insensitive to its OWN queue: with the pool loaded
    ///   microseconds before the hop, the r6 shape left **242.656 ms**
    ///   between the last identity/lock/HEAD proof and the removal, against
    ///   **0.032 ms** with the proof moved across. Four orders of magnitude,
    ///   at an identical measured pool delay (240.4 ms vs 240.2 ms).
    /// - CLEANLINESS does not move, in either arm, and is not claimed to
    ///   (D2): 241.156 ms on the saturated permanent arm and 185.864 ms on
    ///   the loaded Trash arm. `status --porcelain --ignored` is a
    ///   subprocess; putting a `fork`/`exec` inside a disposal seam — on the
    ///   MAIN ACTOR, for the Trash arm — would be a worse trade than the
    ///   window it closes. What is left there is disclosed in "What is left,
    ///   measured", residual 1, with these numbers.
    func testTheWindowsThatRemainAreMeasuredUnderLoadInBothArms()
        async throws
    {
        var mainLoadProof: [Double] = []
        var mainLoadClean: [Double] = []
        var mainLoadDelay: [Double] = []
        for run in 0..<5 {
            let sample = try await measureOneRemoval(
                run: run, load: .mainThread, moveToTrash: false
            )
            mainLoadProof.append(sample.proof)
            mainLoadClean.append(sample.cleanliness)
            mainLoadDelay.append(sample.queueDelay)
        }

        var saturatedProof: [Double] = []
        var saturatedClean: [Double] = []
        var saturatedDelay: [Double] = []
        for run in 0..<3 {
            let sample = try await measureOneRemoval(
                run: 100 + run, load: .globalQueue, moveToTrash: false
            )
            saturatedProof.append(sample.proof)
            saturatedClean.append(sample.cleanliness)
            saturatedDelay.append(sample.queueDelay)
        }

        var trashClean: [Double] = []
        var trashDelay: [Double] = []
        for run in 0..<5 {
            let sample = try await measureOneRemoval(
                run: 200 + run, load: .mainThread, moveToTrash: true
            )
            trashClean.append(sample.cleanliness)
            trashDelay.append(sample.queueDelay)
        }

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }
        func show(_ label: String, _ values: [Double]) {
            print(
                "\(label) \(values.map { String(format: "%.3f", $0) })"
                    + " median \(String(format: "%.3f", median(values)))"
            )
        }
        show("MEASURED-PERMANENT-PROOF-WINDOW-MAIN-THREAD-LOAD-MS", mainLoadProof)
        show("MEASURED-PERMANENT-MAIN-QUEUE-DELAY-MS", mainLoadDelay)
        show("MEASURED-PERMANENT-PROOF-WINDOW-SATURATED-POOL-MS", saturatedProof)
        show("MEASURED-PERMANENT-GLOBAL-QUEUE-DELAY-MS", saturatedDelay)
        show("MEASURED-PERMANENT-CLEANLINESS-WINDOW-MAIN-THREAD-LOAD-MS", mainLoadClean)
        show("MEASURED-PERMANENT-CLEANLINESS-WINDOW-SATURATED-POOL-MS", saturatedClean)
        show("MEASURED-TRASH-CLEANLINESS-WINDOW-MAIN-THREAD-LOAD-MS", trashClean)
        show("MEASURED-TRASH-MAIN-QUEUE-DELAY-MS", trashDelay)

        XCTAssertGreaterThan(
            median(mainLoadDelay), 40,
            "the main thread was NOT loaded, so the main-thread rows measured "
                + "nothing: \(mainLoadDelay)"
        )
        XCTAssertGreaterThan(
            median(saturatedDelay), 40,
            "the global pool was NOT saturated, so the saturation rows "
                + "measured nothing: \(saturatedDelay)"
        )
        XCTAssertLessThan(
            median(saturatedProof), 20,
            "the last identity/lock/HEAD proof and the removal are separated "
                + "by the global pool's depth — the proof is on the wrong "
                + "side of the hop: \(saturatedProof), delays \(saturatedDelay)"
        )
        XCTAssertLessThan(
            median(mainLoadProof), 20,
            "proofs \(mainLoadProof), delays \(mainLoadDelay)"
        )
    }

    /// Reports NO identity for any DESCRIPTOR — the "I opened the folder but
    /// cannot prove which folder it is" case.
    private final class UnprovableDescriptorProvider: FileSystemIdentityProvider {
        override func identity(ofDescriptor fd: Int32) -> Identity? { nil }
    }

    func testTheRemovalRefusesWhenItCannotBindTheFolderItWouldDeleteIn()
        async throws
    {
        // fn-6 RECONCILIATION, and the cell that EVIDENCES the binding.
        //
        // fn-6's removal proves the folder it opens against an identity the
        // caller captured from a descriptor first, so the removal path
        // captures one before its TOCTOU rechecks. Handing `.unbound` instead still
        // compiles and still deletes — measured: replacing the capture with
        // `.unbound` left the whole suite GREEN, zero failures, under
        // `swift test`. The executed total recorded beside that figure (1418)
        // was taken at an earlier commit on this branch that the note did not
        // name, and it does not reproduce at HEAD (PR #460 codex r7, D5), so
        // it is not restated here as though it did; the fact the mutation
        // established is the zero failures. So without this cell the binding
        // is a parameter nobody checks.
        //
        // The capture is the removal path's FIRST descriptor-identity call
        // (the gates before it are path-based), so a provider that can prove no
        // descriptor makes exactly that capture fail and nothing else.
        // FAIL-CLOSED is the assertion: the reclaim reports an error and the
        // worktree is still on disk. Under `.unbound` nothing throws, the
        // removal runs, and the existence check below goes red.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        // A plain wrapping runner: every gate runs for real. (Through r4 this
        // line said git's `remove` refusal "routes this item to the filesystem
        // fallback in the first place" — there is no routing and no second arm
        // now; the removal is the only arm there is.)
        let failing = InterceptingGitRunner(wrapping: realRunner())

        let outcome = await perform(
            item(plan), plan: plan,
            with: makePerformer(
                runner: failing, moveToTrash: false,
                provider: UnprovableDescriptorProvider()
            )
        )

        XCTAssertNil(outcome.entry, "an unprovable container yields NO entry")
        XCTAssertFalse(outcome.errors.isEmpty, "the refusal must be reported")
        XCTAssertTrue(
            fm.fileExists(atPath: worktree.path),
            "a container the deletion cannot bind must leave the tree alone"
        )
    }

    func testGatedPruneIsSkippedWhenAnUndisclosedOrphanWouldAlsoBeSwept()
        async throws
    {
        // Round 8: an unconditional repo-wide prune here would sweep admin
        // data this item never disclosed. The unrelated orphan must survive
        // INTACT for the next scan's repo-level prune item.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let membership = try membership(of: worktree, in: repository)
        let unrelated = try addWorktree(
            named: "other", branch: "other", in: repository
        )
        let unrelatedAdmin = membership.parentAdminContainer
            .appendingPathComponent("other")
        // The pre-existing orphan: its checkout is gone, its admin data is not.
        try fm.removeItem(at: unrelated)
        XCTAssertTrue(fm.fileExists(atPath: unrelatedAdmin.path))

        let plan = staleplan(worktree: worktree, membership: membership)
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let report = await makeCleaner(runner: runner)
            .clean(items: [item(plan)], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errorLines)")
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertGreaterThan(entry.bytesFreed, 0, "the tree WAS deleted")
        let warning = try XCTUnwrap(
            entry.warning, "a skipped prune must be disclosed as a warning"
        )
        XCTAssertTrue(
            warning.contains(WorktreeReclaimPerformer.orphanedAdminWarning),
            warning
        )
        XCTAssertFalse(fm.fileExists(atPath: worktree.path))
        XCTAssertTrue(fm.fileExists(atPath: unrelatedAdmin.path),
                      "the undisclosed orphan must survive intact")
        XCTAssertTrue(
            fm.fileExists(
                atPath: membership.parentAdminContainer
                    .appendingPathComponent("wt").path
            ),
            "nothing was pruned at all — the next scan offers both"
        )
        XCTAssertNil(runner.argvs.first { $0.contains("prune") },
                     "the prune must not have run")
        // The warning is a WARNING: the row stays a success.
        XCTAssertTrue(report.errors.isEmpty)
    }

    func testAParentReboundBetweenTheDeleteAndThePruneLeavesTheAdminEntry()
        async throws
    {
        // D3 (PR #460 codex r2): the R0 re-check inside what is now
        // `gatedPostRemovalPrune` was the ONE unevidenced arm of the three —
        // deleting it left the whole suite green, which is why this cell
        // exists. (r2 recorded a suite count for that run that matches no
        // state of this branch; it is deleted rather than corrected — the
        // proposition it supported is moot now that the arm is
        // mutation-evidenced by this cell.)
        //
        // It is not a duplicate of its two siblings. This is the arm where
        // the RECOMPUTE has already asked `-C <parent>` which entries are
        // prunable, and the answer is what the scoped removal then acts on —
        // so a repository re-pointed between the recompute and the removal
        // means the set being deleted was computed by a repository nobody
        // was shown.
        //
        // The rebind is REAL and lands exactly in that window: the
        // interceptor plants the one-line `gitdir:` redirect when the THIRD
        // `--git-common-dir` is about to run, which is
        // `gatedPostRemovalPrune`'s own R0 — after the removal's
        // filesystem delete, after the oracle recompute.
        let fixture = try makeBareParentFixture()
        let membership = try membership(of: fixture.worktree, in: fixture.bare)
        let plan = staleplan(worktree: fixture.worktree, membership: membership)
        let adminEntry = try XCTUnwrap(plan.worktreeAdminEntry)
        let victim = try makeOutsideRepository()
        let victimAdmin = victim.appendingPathComponent(".git")
            .appendingPathComponent("worktrees")
            .appendingPathComponent("junkdir")
        try fm.createDirectory(at: victimAdmin, withIntermediateDirectories: true)
        let precious = victimAdmin.appendingPathComponent("precious.txt")
        try Data("PRECIOUS".utf8).write(to: precious)

        let bareRepo = fixture.bare
        // R0 runs TWICE in one stale removal now (the gates, then the gated
        // prune), where through r4 it ran three times around the two arms.
        // The rebound lands on the SECOND — the prune's own R0 — which is the
        // window this cell is about.
        let commonDirCalls = GitCallCounter()
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            if arguments.contains("--git-common-dir"),
               commonDirCalls.next() == 2 {
                try? Data("gitdir: \(victim.path)/.git\n".utf8)
                    .write(to: bareRepo.appendingPathComponent(".git"))
            }
            return nil
        }

        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        // (a) The DELETION already succeeded, so this is a WARNING and the
        //     row stays a success (D11).
        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors.map(\.message))")
        let entry = try XCTUnwrap(outcome.entry)
        XCTAssertFalse(fm.fileExists(atPath: fixture.worktree.path))
        let warning = try XCTUnwrap(entry.warning)
        XCTAssertTrue(warning.contains("now resolves to git directory"), warning)
        XCTAssertTrue(warning.contains(victim.path), warning)
        XCTAssertTrue(
            warning.contains(WorktreeReclaimPerformer.orphanedAdminWarning),
            warning
        )
        // (b) NOTHING was removed under the rebound repository: the admin
        //     entry the recompute named is INTACT, and so is the victim's.
        XCTAssertTrue(fm.fileExists(atPath: adminEntry.path),
                      "the admin entry must be left for the next scan")
        XCTAssertTrue(fm.fileExists(atPath: precious.path))
        XCTAssertEqual(commonDirCalls.observed, 2, "\(runner.argvs)")
        assertNoForbiddenArgv(runner)
    }

    func testPruneFailureAfterASuccessfulDeleteIsAWarningNotAnError()
        async throws
    {
        // D11: the bytes ARE freed, so the row must stay `success` and carry
        // the leftover-metadata warning — a "non-fatal error" would flip it.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let runner = InterceptingGitRunner(wrapping: realRunner())
        // The gated post-removal cleanup is a scoped REMOVAL, so its
        // failure class is a removal failure rather than a subprocess one —
        // and it must still be a WARNING, because the tree's bytes are
        // already freed (D11).
        let adminContainerPath = plan.parentAdminContainer.path
        let fileManager = fm
        let outcome = await perform(
            item(plan), plan: plan,
            with: makePerformer(
                runner: runner,
                removeTree: { url, _, prove in
                    try prove()
                    if url.path.hasPrefix(adminContainerPath) {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try fileManager.removeItem(at: url)
                }
            )
        )

        XCTAssertTrue(outcome.errors.isEmpty,
                      "a post-delete cleanup failure is NEVER an ItemError")
        let entry = try XCTUnwrap(outcome.entry)
        XCTAssertGreaterThan(entry.bytesFreed, 0)
        let warning = try XCTUnwrap(entry.warning)
        XCTAssertTrue(warning.contains("could not be removed"), warning)
        XCTAssertTrue(
            warning.contains(WorktreeReclaimPerformer.orphanedAdminWarning),
            warning
        )
    }

    // MARK: - R5: four-class routing at the RE-CHECK call

    func testDirtyWorktreeAtDeleteTimeAbortsAndLeavesTheTreeUntouched()
        async throws
    {
        // REAL git both times: the untracked file makes git refuse (nonzero
        // exit) and makes the re-check report dirty.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        try Data("work that exists nowhere else".utf8)
            .write(to: worktree.appendingPathComponent("untracked.txt"))

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("DIRTY"), message)
        XCTAssertTrue(fm.fileExists(
            atPath: worktree.appendingPathComponent("untracked.txt").path
        ), "the tree — and the work in it — survives untouched")
        XCTAssertNil(runner.argvs.first { $0.contains("prune") })
    }

    func testEveryFailingReCheckClassAbortsWithItsOwnWording() async throws {
        // `.failed(reason:)` is deliberately distinct from `.dirty`, so the
        // three failure classes each abort with a cause the operator can act
        // on — and none of them deletes anything.
        let cases: [(name: String, outcome: GitCommandOutcome, fragment: String)] = [
            ("status failure",
             .failure(exitCode: 128, stderr: "fatal: not a work tree"),
             "git exit 128"),
            ("status timeout", .timeout, "timed out"),
            ("status unavailable", .gitUnavailable, "git unavailable"),
        ]
        for (name, scripted, fragment) in cases {
            let repository = try makeRepository(named: "repo-\(fragment.hashValue.magnitude)")
            let worktree = try addWorktree(
                named: "wt-\(fragment.hashValue.magnitude)", branch: "feature",
                in: repository
            )
            let plan = staleplan(
                worktree: worktree,
                membership: try membership(of: worktree, in: repository)
            )
            // ONLY the status calls are scripted; every gate
            // re-establishment runs against real git, so this cell keeps
            // proving that the CLEAN classes are what abort here.
            let runner = InterceptingGitRunner(
                wrapping: realRunner()
            ) { arguments, _ in
                arguments.contains("status") ? scripted : nil
            }
            let outcome = await perform(
                item(plan), plan: plan, with: makePerformer(runner: runner)
            )
            XCTAssertNil(outcome.entry, name)
            let message = try XCTUnwrap(outcome.errors.first?.message, name)
            XCTAssertTrue(message.contains("could not prove this worktree clean"),
                          "\(name): \(message)")
            XCTAssertTrue(message.contains(fragment), "\(name): \(message)")
            XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                          "\(name): the tree must survive")
            // The whole non-re-establishment sequence, never a subscript
            // (PR #460 codex r2 / D2): `bare[1]` after a count assertion
            // still indexes a runtime-length array, and `XCTAssertEqual`
            // does not stop the cell.
            XCTAssertEqual(
                bareArgvs(runner).filter { !isReestablishment($0) },
                [GitWorktreeCleanCheck.arguments(forWorktreeAt: worktree)],
                "\(name): the witness refuses FIRST, and nothing follows it"
            )
        }
    }

    func testTheReCheckIsAReadOnlyCommandEvenAtDeleteTime() async throws {
        // D17 is classified by COMMAND, never by call phase: the delete-time
        // status re-check carries the FULL read-only profile.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let runner = InterceptingGitRunner(wrapping: realRunner())
        _ = await perform(item(plan), plan: plan, with: makePerformer(runner: runner))

        let statusInvocation = try XCTUnwrap(
            runner.invocations.first { $0.argv.contains("status") }
        )
        XCTAssertEqual(statusInvocation.profile, .readOnly)
        XCTAssertEqual(
            statusInvocation.environment[GitCommandRunner.optionalLocksVariable],
            "0", "the delete-time re-check must still skip optional locks"
        )
        XCTAssertTrue(statusInvocation.argv.contains("core.fsmonitor=false"))
        // The oracle recompute is read-only too, at the same delete time.
        let listInvocation = try XCTUnwrap(
            runner.invocations.first { $0.argv.contains("list") }
        )
        XCTAssertEqual(listInvocation.profile, .readOnly)
        XCTAssertEqual(
            listInvocation.environment[GitCommandRunner.optionalLocksVariable], "0"
        )
        XCTAssertTrue(listInvocation.argv.contains("gc.worktreePruneExpire=now"))
    }

    // MARK: - R5/R8: the D13 subprocess-traversal guard

    /// A directory REPLACED by a symlink pointing at `elsewhere` — the
    /// post-scan swap the guard exists for.
    private func swapToSymlink(_ directory: URL, pointingAt elsewhere: URL) throws {
        try fm.removeItem(at: directory)
        try fm.createSymbolicLink(at: directory, withDestinationURL: elsewhere)
    }

    /// A second repository OUTSIDE the admitted container — where a swapped
    /// symlink would send git if the guard were missing.
    @discardableResult
    private func makeOutsideRepository() throws -> URL {
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertEqual(
            try GitFixture.git(
                ["-c", "init.defaultBranch=main", "init", outside.path], home: home
            ).status, 0
        )
        return outside
    }

    func testAForgedPlanPointingOutsideTheContainerIsRefusedBeforeAnyGit()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let real = try membership(of: worktree, in: repository)
        let outside = try makeOutsideRepository()

        let forgeries: [(name: String, plan: GitWorktreeReclaimPlan)] = [
            ("parentRepoWorkingDir outside", GitWorktreeReclaimPlan(
                mode: .removeStaleWorktree, worktreePath: worktree,
                worktreeAdminEntry: real.parentAdminContainer
                    .appendingPathComponent("wt"),
                worktreeAdminEntryIdentity: nil,
                parentRepoWorkingDir: outside,
                parentAdminContainer: real.parentAdminContainer,
                disclosedAdminDirectories: []
            )),
            ("parentAdminContainer outside", GitWorktreeReclaimPlan(
                mode: .removeStaleWorktree, worktreePath: worktree,
                worktreeAdminEntry: real.parentAdminContainer
                    .appendingPathComponent("wt"),
                worktreeAdminEntryIdentity: nil,
                parentRepoWorkingDir: real.parentRepoWorkingDir,
                parentAdminContainer: outside.appendingPathComponent(".git")
                    .appendingPathComponent("worktrees"),
                disclosedAdminDirectories: []
            )),
        ]
        for (name, forged) in forgeries {
            let runner = InterceptingGitRunner(wrapping: UnreachableGitRunner())
            let spy = SizerSpy()
            let outcome = await perform(
                item(forged), plan: forged,
                with: makePerformer(runner: runner, measure: spy.measure)
            )
            XCTAssertNil(outcome.entry, name)
            XCTAssertEqual(outcome.errors.count, 1, name)
            XCTAssertTrue(runner.argvs.isEmpty, "\(name): git must not run")
            // ADMIT BEFORE MEASURE: a refused item never traverses anything.
            XCTAssertTrue(spy.measuredURLs.isEmpty,
                          "\(name): the sizer must never have been called")
            XCTAssertTrue(fm.fileExists(atPath: worktree.path), name)
        }
    }

    func testEachSymlinkSwappedLeafIsRefusedBeforeAnyGitOrAnyMeasurement()
        async throws
    {
        // The three traversal-exposed leaves, one cell each. A symlink leaf
        // would pass an UNRESOLVED-spelling containment check while git
        // followed it straight out of the container — which is precisely why
        // `validateRemovableItem` is not the guard used here.
        let swaps: [String] = ["parent", "adminContainer", "worktree"]
        for swap in swaps {
            let repository = try makeRepository(named: "repo-\(swap)")
            let worktree = try addWorktree(
                named: "wt-\(swap)", branch: "feature", in: repository
            )
            let membership = try membership(of: worktree, in: repository)
            let plan = staleplan(worktree: worktree, membership: membership)
            let outside = try makeOutsideRepository()

            switch swap {
            case "parent":
                try swapToSymlink(repository, pointingAt: outside)
            case "adminContainer":
                try swapToSymlink(
                    membership.parentAdminContainer, pointingAt: outside
                )
            default:
                try swapToSymlink(worktree, pointingAt: outside)
            }

            let runner = InterceptingGitRunner(wrapping: UnreachableGitRunner())
            let spy = SizerSpy()
            let outcome = await perform(
                item(plan), plan: plan,
                with: makePerformer(runner: runner, measure: spy.measure)
            )
            XCTAssertNil(outcome.entry, swap)
            XCTAssertTrue(
                try XCTUnwrap(outcome.errors.first?.message, swap)
                    .contains("not a real directory"),
                "\(swap): \(outcome.errors.first?.message ?? "<none>")"
            )
            XCTAssertTrue(runner.argvs.isEmpty, "\(swap): git must not run")
            XCTAssertTrue(spy.measuredURLs.isEmpty, "\(swap): nothing measured")
        }
    }

    func testTheGuardReRunsBetweenAdmissionAndTheFirstGitInvocation()
        async throws
    {
        // The audit does NOT say "immediately before EVERY invocation" — that
        // universal was retired as false in r2/r3/r4. What it says is that
        // every path a git invocation traverses is covered by a guard that
        // ran after admission and before that invocation, and the step-(7)
        // site is the one covering the gates. So a swap in the window between
        // admission and the first gate — here, during the measurement walk —
        // must still be caught.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let membership = try membership(of: worktree, in: repository)
        let plan = staleplan(worktree: worktree, membership: membership)
        let outside = try makeOutsideRepository()

        let sizer = DirectorySizer(provider: provider)
        let runner = InterceptingGitRunner(wrapping: UnreachableGitRunner())
        let performer = makePerformer(
            runner: runner,
            measure: { [self] url, mode, known in
                let report = sizer.measure(at: url, mode: mode, knownInodes: known)
                // The swap lands AFTER admission passed and BEFORE the remove.
                try? swapToSymlink(repository, pointingAt: outside)
                return report
            }
        )
        let outcome = await perform(item(plan), plan: plan, with: performer)

        XCTAssertNil(outcome.entry)
        XCTAssertTrue(
            try XCTUnwrap(outcome.errors.first?.message)
                .contains("not a real directory")
        )
        XCTAssertTrue(runner.argvs.isEmpty, "the removal must never have run")
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }

    /// THE WINDOW AFTER THE LAST GUARD (PR #460 codex r5). Through r4 this
    /// cell staged its swap between git's refusal and the clean re-check —
    /// a window that only existed because the fallback was a second,
    /// independently reachable arm. With one arm that window is the same one
    /// `testTheAdminContainerSwappedInsideTheGateWindowIsRefusedBeforeStatus`
    /// already covers, so this cell is repointed at the window NOTHING else
    /// covers: after the pre-`status` guard, after the last gate, and before
    /// the disposal.
    ///
    /// No path GUARD can close that one — a guard is a check, not a handle.
    /// What closes it is the last-instant re-proof's identity chain, which
    /// re-resolves `<wt>/.git` → admin directory → back-link → inode with no
    /// subprocess at all: a container swapped to a symlink stops being a
    /// `.kind(.directory)` and the chain fails closed.
    ///
    /// MUTATION: delete `reproveFromTheFilesystem`'s identity call and this
    /// cell goes RED — the checkout is destroyed while its admin container
    /// points out of the admitted tree.
    func testTheAdminContainerSwappedAfterTheLastGateIsCaughtByTheIdentityReProof()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let membership = try membership(of: worktree, in: repository)
        let plan = staleplan(worktree: worktree, membership: membership)
        let outside = try makeOutsideRepository()
        let adminContainer = membership.parentAdminContainer

        let fileManager = fm
        let swapped = InvocationCounter()
        let runner = lastGateRunner {
            try? fileManager.removeItem(at: adminContainer)
            try? fileManager.createSymbolicLink(
                at: adminContainer, withDestinationURL: outside
            )
            swapped.bump()
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(swapped.count, 1, "the fixture never staged the swap")
        XCTAssertNil(outcome.entry)
        XCTAssertTrue(
            try XCTUnwrapElement(outcome.errors, 0).message
                .contains("no longer resolves through its own `.git` back-link")
        )
        XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                      "the tree survives a swap the guards could not see")
    }

    func testTheAdminContainerSwappedInsideTheGateWindowIsRefusedBeforeStatus()
        async throws
    {
        // D7 (PR #460 codex r4). r3 added a `guardTraversal` immediately
        // before the clean re-check AND a table row asserting it — in the
        // same commit that rewrote `PathGuard`'s doctrine to say "re-runs no
        // cell can distinguish would only be unevidenced guards". Deleting
        // that guard left the whole suite green, so the site was exactly what
        // the doctrine forbids: asserted, not evidenced.
        //
        // This is the window it actually covers, and the sibling cells do
        // NOT: one swaps before the step-(7) guard, which refuses first, and
        // one swaps AFTER the last gate, where no guard can help and the
        // identity re-proof is what catches it. Here the swap lands after
        // R1's own guard, inside R2's ladder, and before the pre-`status`
        // guard — timed off the ancestry call, of which there is exactly one
        // since r5 collapsed the two arms.
        //
        // MUTATION: delete that `guardTraversal` and this cell goes RED —
        // `git -C <wt> status` executes with `<wt>/.git` pointing into a
        // container that is now a symlink out of the admitted tree.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let membership = try membership(of: worktree, in: repository)
        let plan = staleplan(worktree: worktree, membership: membership)
        let outside = try makeOutsideRepository()
        let adminContainer = membership.parentAdminContainer

        let fileManager = fm
        let ancestryCalls = InvocationCounter()
        let swapped = InvocationCounter()
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            guard arguments.contains("merge-base") else { return nil }
            guard ancestryCalls.bump() == 1 else { return nil }
            // THE WINDOW: the delete path's gates have run — entry guard,
            // R0, R1, R1b — and the clean re-check has not.
            if (try? fileManager.removeItem(at: adminContainer)) != nil,
               (try? fileManager.createSymbolicLink(
                   at: adminContainer, withDestinationURL: outside
               )) != nil {
                swapped.bump()
            }
            return .success(stdout: Data())
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(swapped.count, 1, "the fixture never staged the swap")
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("not a real directory"), message)
        XCTAssertEqual(
            bareArgvs(runner).filter { $0.contains("status") }.count, 1,
            "the D2 witness ran; the LAST gate never did: \(bareArgvs(runner))"
        )
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }

    func testADevRootThatIsTheRepositoryIsAdmittedWhileTheRestStayStrict()
        async throws
    {
        // Round 4 EQUALITY cell: `parentRepoWorkingDir` may EQUAL the
        // admitted container — a dev root that IS a repository is ordinary,
        // and only its strictly-contained admin data is mutated.
        XCTAssertEqual(
            try GitFixture.git(
                ["-c", "init.defaultBranch=main", "init", container.path], home: home
            ).status, 0
        )
        try Data(repeating: 7, count: 40_000)
            .write(to: container.appendingPathComponent("tracked.txt"))
        XCTAssertEqual(
            try GitFixture.git(["-C", container.path, "add", "tracked.txt"], home: home).status, 0
        )
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", container.path, "-c", "user.name=t", "-c", "user.email=t@t",
                 "commit", "-m", "seed"], home: home
            ).status, 0
        )
        let worktree = try addWorktree(
            named: "wt", branch: "feature", in: container
        )
        let membership = try membership(of: worktree, in: container)
        XCTAssertEqual(membership.parentRepoWorkingDir.path, container.path)

        let plan = staleplan(worktree: worktree, membership: membership)
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertTrue(outcome.errors.isEmpty,
                      "\(outcome.errors.map(\.message))")
        XCTAssertNotNil(outcome.entry)
        XCTAssertFalse(fm.fileExists(atPath: worktree.path))
        XCTAssertEqual(
            bareArgvs(runner).filter { !isReestablishment($0) }.count, 2,
            "the two `status` calls: the D2 witness and the last gate"
        )
    }

    // MARK: - R5: the pre-delete revalidator seam (D9)

    func testTheRevalidatorSeamRunsForCompositeItemsBeforeAnythingDestructive()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let runner = InterceptingGitRunner(wrapping: UnreachableGitRunner())
        let spy = SizerSpy(stub: { _ in SizeReport() })
        let outcome = await perform(
            item(plan), plan: plan,
            with: makePerformer(
                runner: runner, measure: spy.measure,
                revalidate: { subject in
                    PreDeleteSeamRefusal(
                        reason: "refused: \(subject.displayName) changed since the scan",
                        tag: "content-drift", payload: nil
                    )
                }
            )
        )

        XCTAssertNil(outcome.entry)
        XCTAssertTrue(
            try XCTUnwrap(outcome.errors.first?.message).contains("changed since the scan")
        )
        XCTAssertTrue(runner.argvs.isEmpty, "a refused revalidation runs no git")
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
        // The seam runs AFTER admission and measurement (a revalidator must
        // never inspect a path the performer would refuse to touch) and
        // BEFORE any mutation — so exactly one measurement happened.
        XCTAssertEqual(spy.measuredURLs.map(\.path), [worktree.path])
        XCTAssertEqual(spy.measuredModes, ["deletionTarget"])
    }

    func testAMarkedCompositeItemIsRevalidatedRatherThanRefusedThroughTheCleaner()
        async throws
    {
        // SITE 8, flipped by fn-5.4: a MARKED composite item is no longer
        // refused outright — the cleaner routes it through the registered
        // per-scanner revalidator instead, which is the only reason the flip
        // is honest. Both directions are pinned here, through
        // `clean(items:)` itself so `structuralRefusal` is in the path.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let marked = item(plan, requiresPreDeleteRevalidation: true)

        // (a) the registered revalidator REFUSES → per-item error, no git.
        let refusing = InterceptingGitRunner(wrapping: UnreachableGitRunner())
        let refused = await makeCleaner(
            runner: refusing,
            revalidators: [scannerID: PreDeleteRevalidator(
                requiresRevalidation: { _ in true },
                revalidate: { _, _ in
                    .refuse(
                        reason: "refused: the worktree changed since the scan",
                        valuables: [], acknowledgementToken: nil
                    )
                }
            )]
        ).clean(items: [marked], moveToTrash: false)
        XCTAssertTrue(refused.entries.isEmpty)
        XCTAssertEqual(
            refused.errors.first?.message,
            "refused: the worktree changed since the scan"
        )
        XCTAssertTrue(refusing.argvs.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))

        // (b) the registered revalidator ALLOWS → the reclaim proceeds, which
        // a `revalidatableAction: false` arm would have made impossible.
        let allowing = InterceptingGitRunner(wrapping: realRunner())
        let report = await makeCleaner(
            runner: allowing,
            revalidators: [scannerID: PreDeleteRevalidator(
                requiresRevalidation: { _ in true },
                // `.unestablished` is STATED, because fn-6 gave `.allow` an
                // associated binding with NO DEFAULT precisely so a
                // revalidator holding no descriptor has to say so. This double
                // inspects nothing, so it has nothing to bind; the cell's
                // subject is still that an ALLOWING revalidator lets the
                // reclaim proceed.
                revalidate: { _, _ in .allow(inspected: .unestablished) }
            )]
        ).clean(items: [marked], moveToTrash: false)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errorLines)")
        XCTAssertNotNil(report.entries.first)
        XCTAssertFalse(fm.fileExists(atPath: worktree.path))
    }

    func testAnAllowingRevalidatorLetsTheReclaimProceed() async throws {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let outcome = await perform(
            item(plan, requiresPreDeleteRevalidation: true), plan: plan,
            with: makePerformer(
                runner: InterceptingGitRunner(wrapping: realRunner()),
                revalidate: { _ in nil }
            )
        )
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertNotNil(outcome.entry)
        XCTAssertFalse(fm.fileExists(atPath: worktree.path))
    }

    // MARK: - R5: the class git would have refused (D4)

    /// A CLEAN worktree containing a POPULATED SUBMODULE is removed, and the
    /// parent's absorbed `modules/` object store and the branch ref survive.
    ///
    /// git's own `validate_no_submodules` refuses this without `--force`, so
    /// through r4 the removal reached the fallback and was deleted there
    /// anyway. The OUTCOME is unchanged at r5 and that is stated rather than
    /// quietly inherited: nothing moves from "kept" to "deleted" by making
    /// the re-proved removal the only arm. What changes is that the tree is
    /// no longer destroyed 14.87 ms after the last thing anyone checked.
    func testAPopulatedSubmoduleWorktreeIsRemovedWithTheParentStoreIntact()
        async throws
    {
        let submodule = try makeRepository(named: "sub")
        let repository = try makeRepository(named: "repo")
        let added = try GitFixture.git(
            ["-C", repository.path, "-c", "protocol.file.allow=always",
             "-c", "user.name=t", "-c", "user.email=t@t",
             "submodule", "add", submodule.path, "sub"],
            home: home
        )
        try XCTSkipUnless(
            added.status == 0,
            "this git refuses local-path submodules; the trigger class is "
                + "covered by the injected-failure cells"
        )
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", repository.path, "-c", "user.name=t", "-c", "user.email=t@t",
                 "commit", "-m", "add submodule"], home: home
            ).status, 0
        )
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", worktree.path, "-c", "protocol.file.allow=always",
                 "submodule", "update", "--init"], home: home
            ).status, 0
        )
        let modulesStore = repository.appendingPathComponent(".git")
            .appendingPathComponent("modules")
        XCTAssertTrue(fm.fileExists(atPath: modulesStore.path))

        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors.map(\.message))")
        XCTAssertNotNil(outcome.entry)
        XCTAssertFalse(fm.fileExists(atPath: worktree.path))
        XCTAssertTrue(fm.fileExists(atPath: modulesStore.path),
                      "the parent's submodule object store must be untouched")
        XCTAssertTrue(try branchExists("feature", in: repository))
        // git was never ASKED to remove it — the refusal it would have made
        // is not part of this path any more.
        XCTAssertNil(runner.argvs.first { $0.contains("remove") },
                     "\(runner.argvs)")
        assertNoForbiddenArgv(runner)
    }

    // MARK: - The delete-time gate re-establishment (PR #460 codex r1)

    /// `git` in the fixture's hermetic environment, asserted to succeed.
    @discardableResult
    private func git(_ arguments: [String]) throws -> Data {
        let result = try GitFixture.git(arguments, home: home)
        XCTAssertEqual(result.status, 0, "\(arguments) failed")
        return result.stdout
    }

    private func headOID(of worktree: URL) throws -> String {
        String(
            decoding: try GitFixture.git(
                ["-C", worktree.path, "rev-parse", "HEAD"], home: home
            ).stdout, as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reachability from REFS ONLY — `--branches --tags --remotes`, never
    /// `--all`.
    ///
    /// RE-MEASURED on git 2.50.1 (PR #460 codex r2 / D7 — the previous
    /// parenthetical "even under `--single-worktree`" was FALSE). One
    /// repository, one detached worktree carrying commit `C`, every command
    /// run from the parent:
    ///
    /// | argv | reports `C` |
    /// |---|---|
    /// | `rev-list --all` | YES |
    /// | `rev-list --all --single-worktree` | YES |
    /// | `rev-list --single-worktree --all` | no |
    /// | `rev-list --branches --tags --remotes` | no |
    ///
    /// The substantive half — the reason this helper exists — holds: `--all`
    /// walks OTHER worktrees' HEADs, so it would report a detached worktree's
    /// commit as reachable right up until the worktree is removed, which is
    /// precisely the fact under test. What is not true is that
    /// `--single-worktree` fails to suppress it; it suppresses it when it
    /// PRECEDES `--all`, because the option must be parsed before the
    /// pseudo-ref it constrains.
    private func isReachableFromAnyRef(
        _ oid: String, in repository: URL
    ) throws -> Bool {
        String(
            decoding: try GitFixture.git(
                ["-C", repository.path, "rev-list",
                 "--branches", "--tags", "--remotes"],
                home: home
            ).stdout, as: UTF8.self
        ).contains(oid)
    }

    // MARK: R2 — G3 (ancestry) is re-established before the mutation

    func testACommitMadeAfterTheScanRefusesTheDetachedRemovalAndKeepsTheCommit()
        async throws
    {
        // THE C1 REPRO. A detached worktree at the default branch's tip
        // passes all four scan gates. Committing in it afterwards leaves the
        // tree CLEAN, leaves the record REGISTERED and UNLOCKED, and leaves
        // git's own `worktree remove` willing (measured on 2.50.1: exit 0,
        // silent) — and the commit is on NO branch, so removal would leave it
        // reachable from nothing.
        let repository = try makeRepository(named: "repo")
        let worktree = container.appendingPathComponent("wt")
        try git(["-C", repository.path, "worktree", "add", "--detach",
                 worktree.path, "HEAD"])
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        // THE WINDOW: the user goes back and commits after the scan.
        try Data("precious".utf8)
            .write(to: worktree.appendingPathComponent("tracked.txt"))
        try git(["-C", worktree.path, "-c", "user.name=t", "-c", "user.email=t@t",
                 "commit", "-am", "precious"])
        let precious = try headOID(of: worktree)
        XCTAssertFalse(try isReachableFromAnyRef(precious, in: repository),
                       "the fixture must put the commit on no ref")

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        // (a) THE TREE — and the work in it — SURVIVES.
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
        // (b) the commit is still there to be recovered from.
        XCTAssertEqual(try headOID(of: worktree), precious)
        // (c) the mutation was never attempted.
        XCTAssertNil(runner.argvs.first { $0.contains("remove") }, "\(runner.argvs)")
        // (d) nothing was accepted and no bytes were reported.
        XCTAssertNil(outcome.entry)
        XCTAssertEqual(outcome.errors.count, 1)
        // (e) the message names the ref, the commit, the detached hazard and
        //     the action that clears the refusal.
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("no longer an ancestor of refs/heads/main"),
                      message)
        XCTAssertTrue(message.contains(String(precious.prefix(12))), message)
        XCTAssertTrue(message.contains("HEAD is DETACHED"), message)
        XCTAssertTrue(message.contains("then re-scan"), message)
        assertNoForbiddenArgv(runner)
    }

    func testAnAttachedBranchCommitMadeAfterTheScanIsAlsoRefused() async throws {
        // The common shape. The branch ref would survive the removal, so no
        // COMMIT is lost — but the app would still destroy a checkout on a
        // predicate it knows is stale, and report `errors=[]`.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        try Data("later".utf8)
            .write(to: worktree.appendingPathComponent("tracked.txt"))
        try git(["-C", worktree.path, "-c", "user.name=t", "-c", "user.email=t@t",
                 "commit", "-am", "later"])

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
        XCTAssertNil(runner.argvs.first { $0.contains("remove") })
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("no longer an ancestor"), message)
        XCTAssertFalse(message.contains("DETACHED"),
                       "an attached worktree must not be told its HEAD is detached")
    }

    func testEveryUnansweredAncestryClassRefusesWithItsOwnCause() async throws {
        // Exit 1 is git's ANSWER; 128, a timeout and an absent git are "could
        // not answer". None of them passes, and none is dressed up as the
        // other — the split the scan gate already makes, kept at delete time.
        let classes: [(name: String, outcome: GitCommandOutcome, fragment: String)] = [
            ("exit 128",
             .failure(exitCode: 128, stderr: "fatal: Not a valid object name"),
             "git exit 128"),
            ("timeout", .timeout, "timed out"),
            ("unavailable", .gitUnavailable, "git unavailable"),
        ]
        for (name, scripted, fragment) in classes {
            let repository = try makeRepository(named: "repo-\(name.hashValue.magnitude)")
            let worktree = try addWorktree(
                named: "wt-\(name.hashValue.magnitude)", branch: "feature",
                in: repository
            )
            let plan = staleplan(
                worktree: worktree,
                membership: try membership(of: worktree, in: repository)
            )
            let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
                arguments.contains("merge-base") ? scripted : nil
            }
            let outcome = await perform(
                item(plan), plan: plan, with: makePerformer(runner: runner)
            )
            XCTAssertTrue(fm.fileExists(atPath: worktree.path), name)
            XCTAssertNil(runner.argvs.first { $0.contains("remove") }, name)
            XCTAssertNil(outcome.entry, name)
            let message = try XCTUnwrap(outcome.errors.first?.message, name)
            XCTAssertTrue(message.contains("could not be answered"),
                          "\(name): \(message)")
            XCTAssertTrue(message.contains(fragment), "\(name): \(message)")
            XCTAssertFalse(message.contains("no longer an ancestor"),
                           "\(name): an unanswered check is not a negative answer")
        }
    }

    func testAFailedLadderRungRefusesAtTheDeleteSiteToo() async throws {
        // The D6 ladder's own discriminator, re-asked at delete time: a rung
        // that FAILED is not a rung that is MISSING. Falling through would
        // judge the worktree against a branch that is not this repository's
        // default — so the delete site must refuse, not only the scan site.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            // git's TALKATIVE exit 1 — a ref that exists and cannot be read.
            arguments.contains("--verify")
                ? .failure(
                    exitCode: 1,
                    stderr: "warning: ignoring broken ref refs/heads/main"
                )
                : nil
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
        XCTAssertNil(runner.argvs.first { $0.contains("remove") })
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("refs/heads/main lookup failed"), message)
        // The ladder STOPPED — `master` was never consulted.
        XCTAssertNil(runner.argvs.first { $0.contains("refs/heads/master") },
                     "\(runner.argvs)")
    }

    // MARK: R1 — G4 (locked), G1 and the registration itself

    func testALockAcquiredAfterTheScanAbortsAndKeepsTheTree() async throws {
        // G4 is UNCONDITIONAL at scan time and there is no lock handling in
        // this epic at all. Until PR #460 the delete path never re-read it,
        // so a lock taken after the scan was overridden — git refused with
        // exit 128, the fallback re-checked only cleanliness, and the tree
        // was destroyed with `errors=[]`.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        try git(["-C", repository.path, "worktree", "lock",
                 "--reason", "in use on laptop", worktree.path])

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                      "a locked worktree must never be deleted")
        XCTAssertTrue(fm.fileExists(
            atPath: worktree.appendingPathComponent("tracked.txt").path
        ), "…nor its tracked content")
        // The lock itself survives — nothing tried to clear it.
        XCTAssertTrue(fm.fileExists(
            atPath: plan.parentAdminContainer
                .appendingPathComponent("wt").appendingPathComponent("locked").path
        ))
        XCTAssertNil(runner.argvs.first { $0.contains("remove") })
        XCTAssertNil(runner.argvs.first { $0.contains("prune") })
        XCTAssertNil(outcome.entry, "an aborted removal accepts nothing")
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("LOCKED after the scan"), message)
        XCTAssertTrue(message.contains("in use on laptop"), message)
        XCTAssertTrue(message.contains("git worktree unlock"),
                      "the remedy must be the UNLOCK, not a bare re-scan: \(message)")
        assertNoForbiddenArgv(runner)
    }

    func testALockTakenBeforeTheRegistryReReadIsRefusedByR1()
        async throws
    {
        // R1's OWN LOCK ARM. G4 is a field of the porcelain record, so a
        // lock acquired before the registry is re-read is refused by R1 in
        // R1's words — distinct from the last-instant `<admin>/locked` probe,
        // which covers a lock acquired AFTER it (see
        // `testALockTakenInsideTheDisposalWindowStopsTheRemoval`). Before
        // PR #460 the fallback re-checked only cleanliness and therefore
        // reached `remove -f -f`'s effect on a locked worktree without the
        // flag — measured, with `errors == []`.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let lockCommand = ["-C", repository.path, "worktree", "lock",
                           "--reason", "taken mid-operation", worktree.path]
        let fixtureHome = home!
        // THE WINDOW: the lock lands on R0 — after admission, measurement
        // and registration, and BEFORE the registry re-read that must see it.
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            guard arguments.contains("--git-common-dir") else { return nil }
            _ = try? GitFixture.git(lockCommand, home: fixtureHome)
            return nil
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                      "a worktree locked mid-operation must not be deleted")
        XCTAssertTrue(fm.fileExists(
            atPath: worktree.appendingPathComponent("tracked.txt").path
        ))
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("LOCKED after the scan"), message)
        XCTAssertTrue(message.contains("taken mid-operation"), message)
        // R0 DID pass — this cell is about R1's reading of the record, not
        // about refusing before git ran at all.
        XCTAssertNotNil(runner.argvs.first { $0.contains("--git-common-dir") })
        XCTAssertNil(runner.argvs.first { $0.contains("prune") })
    }

    func testAPathThatIsNoLongerARegisteredWorktreeIsNeverDeleted() async throws {
        // The "is not a working tree" class. Through r4 the second arm
        // treated git's exit 128 as an ordinary refusal, the stranger
        // repository sitting at that path re-checked CLEAN, and it was
        // deleted. There is no second arm now, and this is not why the
        // stranger survives: R1 refuses on the REGISTRY, before any removal,
        // and never on git's message text.
        let repository = try makeRepository(named: "repo")
        let stranger = container.appendingPathComponent("stranger")
        try fm.createDirectory(at: stranger, withIntermediateDirectories: true)
        try git(["-c", "init.defaultBranch=main", "init", stranger.path])
        let mine = stranger.appendingPathComponent("mine.txt")
        try Data("work that exists nowhere else".utf8).write(to: mine)
        try git(["-C", stranger.path, "add", "mine.txt"])
        try git(["-C", stranger.path, "-c", "user.name=t", "-c", "user.email=t@t",
                 "commit", "-m", "mine"])

        // A live worktree only so the resolver can derive the carried admin
        // container; the PLAN points at the stranger.
        let anchor = try addWorktree(named: "anchor", branch: "anchor", in: repository)
        let real = try membership(of: anchor, in: repository)
        let plan = GitWorktreeReclaimPlan.removeStaleWorktree(
            worktreePath: stranger,
            worktreeAdminEntry: real.parentAdminContainer
                .appendingPathComponent("stranger"),
            // The stranger has no admin entry to stat; the record re-read
            // refuses long before the identity gate is consulted.
            worktreeAdminEntryIdentity: nil,
            parentRepoWorkingDir: real.parentRepoWorkingDir,
            adminContainer: real.parentAdminContainer
        )

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertTrue(fm.fileExists(atPath: mine.path),
                      "the stranger's work must survive")
        XCTAssertTrue(fm.fileExists(atPath: stranger.path))
        XCTAssertNil(runner.argvs.first { $0.contains("remove") })
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("no longer a registered worktree"), message)
        XCTAssertTrue(message.contains("Re-scan"), message)
    }

    func testAPlanAimedAtTheMainCheckoutIsRefusedByTheReReadRecord() async throws {
        // G1 at delete time, and it is the ONLY thing standing here now.
        // Through r4 the sequence was: ancestry passes (the main checkout IS
        // at the default branch tip), `worktree remove` refuses with exit 128
        // ("is a main working tree"), the second arm re-checks CLEAN — and
        // deletes the user's main checkout. Since r5 nothing asks git to
        // refuse at all: the removal is unconditional once the gates pass, so
        // G1's re-established record is the whole protection.
        let repository = try makeRepository(named: "repo")
        let anchor = try addWorktree(named: "anchor", branch: "anchor", in: repository)
        let real = try membership(of: anchor, in: repository)
        let plan = GitWorktreeReclaimPlan.removeStaleWorktree(
            worktreePath: repository,
            worktreeAdminEntry: real.parentAdminContainer
                .appendingPathComponent("repo"),
            // The main checkout has no admin entry; G1 refuses first.
            worktreeAdminEntryIdentity: nil,
            parentRepoWorkingDir: real.parentRepoWorkingDir,
            adminContainer: real.parentAdminContainer
        )

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertTrue(fm.fileExists(atPath: repository.path),
                      "the main checkout must never be deleted")
        XCTAssertTrue(fm.fileExists(
            atPath: repository.appendingPathComponent("tracked.txt").path
        ))
        XCTAssertNil(runner.argvs.first { $0.contains("remove") })
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("main worktree"), message)
    }

    func testEveryUnreadableRegistryClassRefusesFailClosed() async throws {
        let classes: [(name: String, outcome: GitCommandOutcome, fragment: String)] = [
            ("failure", .failure(exitCode: 128, stderr: "fatal: not a git repository"),
             "git exit 128"),
            ("timeout", .timeout, "timed out"),
            ("unavailable", .gitUnavailable, "became unavailable"),
            ("unparseable", .success(stdout: Data([0xFF, 0xFE])), "could not be parsed"),
        ]
        for (name, scripted, fragment) in classes {
            let repository = try makeRepository(named: "repo-\(name)")
            let worktree = try addWorktree(
                named: "wt-\(name)", branch: "feature", in: repository
            )
            let plan = staleplan(
                worktree: worktree,
                membership: try membership(of: worktree, in: repository)
            )
            let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
                arguments.contains("list") ? scripted : nil
            }
            let outcome = await perform(
                item(plan), plan: plan, with: makePerformer(runner: runner)
            )
            XCTAssertTrue(fm.fileExists(atPath: worktree.path), name)
            XCTAssertNil(runner.argvs.first { $0.contains("remove") }, name)
            XCTAssertNil(outcome.entry, name)
            let message = try XCTUnwrap(outcome.errors.first?.message, name)
            XCTAssertTrue(message.contains(fragment), "\(name): \(message)")
        }
    }

    // MARK: R0 — the repository behind the `-C` target

    /// A BARE parent inside the container, plus one linked worktree of it.
    /// The bare shape is the reachable one for a repository redirect: a
    /// non-bare parent's `<repo>/.git` is a real directory, and replacing it
    /// with a file or a symlink is already refused by the D13 traversal guard
    /// (ENOTDIR / canonicalizes-outside, both measured).
    private func makeBareParentFixture() throws -> (bare: URL, worktree: URL) {
        let seed = try makeRepository(named: "seed")
        let bare = container.appendingPathComponent("bare.git")
        try git(["clone", "--bare", seed.path, bare.path])
        let worktree = container.appendingPathComponent("bwt")
        try git(["-C", bare.path, "worktree", "add", worktree.path, "-b", "bfeat"])
        return (bare, worktree)
    }

    func testAParentRedirectedToAnotherRepositoryIsRefusedBeforeAnyMutation()
        async throws
    {
        // A ONE-LINE ADDED FILE — nothing replaced, nothing moved, nothing
        // symlinked — repoints `git -C <bare>` at another repository, and
        // every path gate still passes: the leaf is a real directory, it
        // canonicalizes inside the container, it is on the container's
        // device. Only git can answer which repository it resolved.
        //
        // R1 would independently refuse THIS shape (the redirected registry
        // lists no such worktree), so what this cell discriminates is that
        // R0 ran and named the redirect. R0's independent deletion-safety
        // value is evidenced by the prune-mode cell below, where there is no
        // R1 at all.
        let fixture = try makeBareParentFixture()
        let victim = try makeOutsideRepository()
        let plan = staleplan(
            worktree: fixture.worktree,
            membership: try membership(of: fixture.worktree, in: fixture.bare)
        )
        XCTAssertEqual(plan.parentRepoWorkingDir.path, fixture.bare.path)

        try Data("gitdir: \(victim.path)/.git\n".utf8)
            .write(to: fixture.bare.appendingPathComponent(".git"))

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertTrue(fm.fileExists(atPath: fixture.worktree.path))
        XCTAssertNil(runner.argvs.first { $0.contains("remove") })
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("now resolves to git directory"), message)
        XCTAssertTrue(message.contains(victim.path), message)
        XCTAssertTrue(message.contains("Remove the redirect"), message)
        // R0 is FIRST: nothing else in the re-establishment ran.
        XCTAssertEqual(
            bareArgvs(runner),
            [WorktreeReclaimPerformer.commonGitDirArguments(
                parentRepoWorkingDir: fixture.bare
            )]
        )
    }

    func testTheUnredirectedBareParentIsRemovedNormally() async throws {
        // The NEGATIVE CONTROL for the cell above: without the planted file
        // the same fixture removes cleanly, so the refusal is the redirect
        // and not the bare shape.
        let fixture = try makeBareParentFixture()
        let plan = staleplan(
            worktree: fixture.worktree,
            membership: try membership(of: fixture.worktree, in: fixture.bare)
        )
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )
        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors.map(\.message))")
        XCTAssertNotNil(outcome.entry)
        XCTAssertFalse(fm.fileExists(atPath: fixture.worktree.path))
    }

    func testAPruneItemWhoseParentWasRedirectedIsRefusedAndReportsNoRow()
        async throws
    {
        // PRUNE MODE HAS NO R1 — the item's whole subject is one repository's
        // registry, and the recompute asks `-C <parent>` which entries are
        // prunable. Redirected, that question is answered by a repository
        // nobody was shown; before PR #460 the answer (an EMPTY set, because
        // the victim's un-listed orphans are invisible to `worktree list`)
        // made every later gate vacuous and the repo-wide prune ran on the
        // victim, reporting success.
        let seed = try makeRepository(named: "seed")
        let bare = container.appendingPathComponent("bare.git")
        try git(["clone", "--bare", seed.path, bare.path])
        let anchor = container.appendingPathComponent("banchor")
        try git(["-C", bare.path, "worktree", "add", anchor.path, "-b", "banchor"])
        let membership = try membership(of: anchor, in: bare)
        let orphanTree = container.appendingPathComponent("bgone")
        try git(["-C", bare.path, "worktree", "add", orphanTree.path, "-b", "bgone"])
        try fm.removeItem(at: orphanTree)
        let orphan = membership.parentAdminContainer.appendingPathComponent("bgone")
        XCTAssertTrue(fm.fileExists(atPath: orphan.path))

        let victim = try makeOutsideRepository()
        let victimAdmin = victim.appendingPathComponent(".git")
            .appendingPathComponent("worktrees")
            .appendingPathComponent("junkdir")
        try fm.createDirectory(at: victimAdmin, withIntermediateDirectories: true)
        let precious = victimAdmin.appendingPathComponent("precious.txt")
        try Data("PRECIOUS".utf8).write(to: precious)

        let plan = prunePlan(membership: membership, disclosed: [orphan])
        try Data("gitdir: \(victim.path)/.git\n".utf8)
            .write(to: bare.appendingPathComponent(".git"))

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan, with: makePerformer(runner: runner)
        )

        // (a) the victim's data — outside the admitted root — is untouched.
        XCTAssertTrue(fm.fileExists(atPath: precious.path))
        // (b) the disclosed entry was not swept instead.
        XCTAssertTrue(fm.fileExists(atPath: orphan.path))
        // (c) NO row: a success entry here would report a completed operation
        //     on a repository that was never inspected.
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("now resolves to git directory"), message)
        XCTAssertNil(runner.argvs.first { $0.contains("prune") })
    }

    func testEveryUnresolvableParentClassRefusesFailClosed() async throws {
        let classes: [(name: String, outcome: GitCommandOutcome, fragment: String)] = [
            ("failure", .failure(exitCode: 128, stderr: "fatal: not a git repository"),
             "git exit 128"),
            ("timeout", .timeout, "timed out"),
            ("garbage", .success(stdout: Data("not-a-path\n".utf8)),
             "did not answer with an absolute git directory"),
        ]
        for (name, scripted, fragment) in classes {
            let repository = try makeRepository(named: "repo-\(name)")
            let worktree = try addWorktree(
                named: "wt-\(name)", branch: "feature", in: repository
            )
            let plan = staleplan(
                worktree: worktree,
                membership: try membership(of: worktree, in: repository)
            )
            let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
                arguments.contains("--git-common-dir") ? scripted : nil
            }
            let outcome = await perform(
                item(plan), plan: plan, with: makePerformer(runner: runner)
            )
            XCTAssertTrue(fm.fileExists(atPath: worktree.path), name)
            XCTAssertNil(runner.argvs.first { $0.contains("remove") }, name)
            XCTAssertNil(outcome.entry, name)
            let message = try XCTUnwrap(outcome.errors.first?.message, name)
            XCTAssertTrue(message.contains(fragment), "\(name): \(message)")
        }
    }

    // MARK: R1b — WHICH worktree the re-read record is about (codex r2 / D1)

    /// The admin directory a live checkout resolves to through its OWN
    /// `.git` back-link — the production resolver, not a reconstruction.
    private func liveAdminDirectory(of worktree: URL) throws -> URL {
        try XCTUnwrap(
            GitWorktreeGitdirResolver(identity: provider)
                .adminDirectory(forWorktreeAt: worktree),
            "no admin directory resolves from \(worktree.path)"
        )
    }

    func testAWorktreeMovedOntoTheAssessedPathIsRefusedAndSurvives()
        async throws
    {
        // THE D1 REPRO. The user retires the stale worktree THEMSELVES and
        // moves a different, live checkout onto the freed path. Every gate
        // the delete path re-established before this round passes: R0 (the
        // same repository), R1 (a registered, linked, unlocked record AT
        // THAT PATH), G2 (clean) and R2 (merged). The performer destroyed
        // the newcomer and returned a SUCCESS entry with `errors=[]` —
        // measured — while the plan's carried `worktreeAdminEntry`, the
        // token that names WHICH checkout was assessed, sat unconsulted.
        let repository = try makeRepository(named: "repo")
        let assessed = try addWorktree(named: "wt", branch: "feature", in: repository)
        let newcomer = try addWorktree(named: "newcomer", branch: "live", in: repository)
        let plan = staleplan(
            worktree: assessed,
            membership: try membership(of: assessed, in: repository)
        )
        let carriedAdmin = try XCTUnwrap(plan.worktreeAdminEntry)
        let newcomerAdmin = try liveAdminDirectory(of: newcomer)

        try git(["-C", repository.path, "worktree", "remove", assessed.path])
        try git(["-C", repository.path, "worktree", "move",
                 newcomer.path, assessed.path])
        // The two facts that make this the hazard: the token is GONE, and
        // the path is occupied by a different, perfectly healthy checkout.
        XCTAssertFalse(fm.fileExists(atPath: carriedAdmin.path))
        XCTAssertTrue(fm.fileExists(atPath: assessed.path))
        XCTAssertEqual(
            try liveAdminDirectory(of: assessed).path, newcomerAdmin.path
        )

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.entry, "a success entry would report a lie")
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(
            message.contains("is now the checkout of admin directory"), message
        )
        XCTAssertTrue(message.contains(newcomerAdmin.path), message)
        XCTAssertTrue(message.contains(carriedAdmin.path), message)
        // The mutation never ran, and the newcomer — tracked content and all
        // — is still there with its branch.
        XCTAssertNil(runner.argvs.first { $0.contains("remove") }, "\(runner.argvs)")
        XCTAssertTrue(fm.fileExists(
            atPath: assessed.appendingPathComponent("tracked.txt").path
        ))
        XCTAssertTrue(try branchExists("live", in: repository))
        XCTAssertEqual(try porcelainRecordCount(of: repository), 2)
        assertNoForbiddenArgv(runner)
    }

    func testTheSameFixtureWithoutTheMoveIsRemovedNormally() async throws {
        // THE NEGATIVE CONTROL for the cell above: two worktrees, the same
        // plan, no move — the assessed one is removed and the sibling is
        // untouched. So the refusal above is the REBINDING, not the shape.
        let repository = try makeRepository(named: "repo")
        let assessed = try addWorktree(named: "wt", branch: "feature", in: repository)
        let sibling = try addWorktree(named: "newcomer", branch: "live", in: repository)
        let plan = staleplan(
            worktree: assessed,
            membership: try membership(of: assessed, in: repository)
        )
        let outcome = await perform(
            item(plan), plan: plan,
            with: makePerformer(runner: InterceptingGitRunner(wrapping: realRunner()))
        )
        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors.map(\.message))")
        XCTAssertNotNil(outcome.entry)
        XCTAssertFalse(fm.fileExists(atPath: assessed.path))
        XCTAssertTrue(fm.fileExists(atPath: sibling.path))
    }

    func testACheckoutThatNoLongerBacksLinkToAnyAdminDirectoryIsRefused()
        async throws
    {
        // The other R1b class: the record is still registered at the path,
        // but the object there no longer proves WHICH registration it is —
        // its `.git` back-link is gone. Fail CLOSED: the authorisation
        // cannot be tied to an object at all. (A re-scan differs: the admin
        // directory is now an ORPHAN, i.e. prune-tier material, not a stale
        // worktree.)
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )
        try fm.removeItem(at: worktree.appendingPathComponent(".git"))

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(
            message.contains("no longer resolves through its own `.git` "
                             + "back-link"), message
        )
        XCTAssertNil(runner.argvs.first { $0.contains("remove") }, "\(runner.argvs)")
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }

    func testASamePathReAddIsRefusedBecauseTheAdminDirectoryWasRecreated()
        async throws
    {
        // D3, CLOSED (PR #460 codex r3). Through r2 this was a recorded
        // residual and this cell asserted the DESTRUCTION.
        //
        // The mechanism, measured rather than reasoned about below:
        // `git worktree remove` frees the name `worktrees/<basename>`, and a
        // later `git worktree add` at the SAME path takes that name back —
        // so the plan's carried `worktreeAdminEntry` SPELLING resolves again,
        // to a different directory. Every path-level proof in R1b passes. The
        // plan now also carries that directory's scan-time INODE, which the
        // re-creation cannot reproduce.
        //
        // The stakes are why this shape matters most: the replacement is a
        // brand-new checkout whose untracked work is invisible to the clean
        // gate whenever a committed `.gitignore` covers it, so `status
        // --porcelain` reports nothing and every gate but this one agrees the
        // tree is disposable.
        //
        // MUTATION EVIDENCE: drop the `liveIdentity == carriedIdentity`
        // guard from `reestablishWorktreeIdentity` and this cell goes RED —
        // the ignored file and the whole new checkout are gone. (Passing
        // `bindAdminIdentity: false` no longer demonstrates it: since r4 a
        // plan with no carried identity is REFUSED rather than run unbound —
        // see `testAPlanCarryingNoAdminIdentityIsRefusedRatherThanRunUnbound`.)
        let repository = try makeRepository(named: "repo")
        let assessed = try addWorktree(named: "wt", branch: "feature", in: repository)
        // A second worktree keeps the admin CONTAINER alive across the
        // removal, which is the field shape (git rmdir's an emptied one).
        try addWorktree(named: "anchor", branch: "anchor", in: repository)
        let plan = staleplan(
            worktree: assessed,
            membership: try membership(of: assessed, in: repository)
        )
        let carriedAdmin = try XCTUnwrap(plan.worktreeAdminEntry)
        let inodeBefore = try XCTUnwrap(plan.worktreeAdminEntryIdentity)
        XCTAssertEqual(inodeBefore, provider.identity(of: carriedAdmin),
                       "the plan carries the SCAN-TIME identity")

        try git(["-C", repository.path, "worktree", "remove", assessed.path])
        try git(["-C", repository.path, "worktree", "add", assessed.path,
                 "-b", "brand-new"])
        // Work that the clean gate cannot see: ignored by a COMMITTED
        // `.gitignore`, so `status --porcelain` stays empty.
        let ignoreFile = assessed.appendingPathComponent(".gitignore")
        try "secret.env\n".write(to: ignoreFile, atomically: true, encoding: .utf8)
        try git(["-C", assessed.path, "add", ".gitignore"])
        try git(["-C", assessed.path, "-c", "user.name=t", "-c", "user.email=t@t",
                 "commit", "-m", "ignore"])
        let secret = assessed.appendingPathComponent("secret.env")
        try "TOKEN=live\n".write(to: secret, atomically: true, encoding: .utf8)

        // (a) THE MECHANISM: git reused the name, so the carried spelling is
        //     live again — pointing at a different directory.
        let reAdded = try liveAdminDirectory(of: assessed)
        XCTAssertEqual(reAdded.path, carriedAdmin.path,
                       "git re-used the freed admin-directory name")
        XCTAssertNotEqual(
            try XCTUnwrap(provider.identity(of: carriedAdmin)), inodeBefore,
            "…while the directory itself is a new object"
        )

        // (b) THE CONSEQUENCE: refused, and the new checkout is untouched.
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )
        XCTAssertNil(outcome.entry, "nothing may be reported as freed")
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("DIFFERENT checkout"), message)
        XCTAssertTrue(message.contains("re-created since the scan"), message)
        XCTAssertTrue(fm.fileExists(atPath: assessed.path))
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8),
                       "TOKEN=live\n", "the ignored work survives")
        XCTAssertNil(runner.argvs.first { $0.contains("remove") }, "\(runner.argvs)")
    }

    // MARK: The LAST-INSTANT re-proof (PR #460 codex r4 / D1-D3)

    /// Retire the worktree and re-add one at the SAME path. Non-throwing
    /// because it is called from inside `@Sendable` interception closures,
    /// where a throw would be swallowed — every caller asserts the swap took
    /// by its EFFECT before asserting anything else.
    private static func removeAndReAdd(
        worktree: URL, repository: URL, home: URL, branch: String
    ) -> Bool {
        guard let removed = try? GitFixture.git(
            ["-C", repository.path, "worktree", "remove", worktree.path],
            home: home
        ), removed.status == 0,
        let added = try? GitFixture.git(
            ["-C", repository.path, "worktree", "add", worktree.path,
             "-b", branch],
            home: home
        ), added.status == 0 else { return false }
        // Work the replacement's owner would lose. In the field it can be
        // invisible to the clean gate as well — a committed `.gitignore`
        // makes `status --porcelain` report nothing (see
        // `testASamePathReAddIsRefusedBecauseTheAdminDirectoryWasRecreated`).
        return (try? "TOKEN=live\n".write(
            to: worktree.appendingPathComponent("secret.env"),
            atomically: true, encoding: .utf8
        )) != nil
    }

    /// `git worktree lock`, from inside an interception closure.
    private static func lockWorktree(
        _ worktree: URL, repository: URL, home: URL
    ) -> Bool {
        (try? GitFixture.git(
            ["-C", repository.path, "worktree", "lock", "--reason",
             "do not touch", worktree.path],
            home: home
        ))?.status == 0
    }

    /// Commit inside `worktree`, from inside an interception closure.
    private static func commitInside(_ worktree: URL, home: URL) -> Bool {
        guard (try? "committed in the window\n".write(
            to: worktree.appendingPathComponent("tracked.txt"),
            atomically: true, encoding: .utf8
        )) != nil,
        let committed = try? GitFixture.git(
            ["-C", worktree.path, "-c", "user.name=t", "-c", "user.email=t@t",
             "commit", "-am", "window"],
            home: home
        ), committed.status == 0 else { return false }
        return true
    }

    /// The clean check is the LAST git call the removal path makes, so an
    /// interception of it that mutates and then answers CLEAN stages its
    /// attack in exactly the window r3 left open — between the last gate and
    /// the disposal. `.success(Data())` is an empty porcelain listing, i.e.
    /// clean.
    /// Stage an attack in the ONE window no gate can close: after the LAST
    /// gate has answered and before the disposal.
    ///
    /// `status` runs TWICE now (the D2 witness, then the last gate), so the
    /// counter is load-bearing — firing on the first would stage the attack
    /// BEFORE R2 and the ancestry rungs, which is a different window and a
    /// different claim. Exit 0 with empty stdout is "clean, nothing ignored".
    private func lastGateRunner(
        staging attack: @escaping @Sendable () -> Void
    ) -> InterceptingGitRunner {
        let statuses = GitCallCounter()
        return InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            guard arguments.contains("status") else { return nil }
            if statuses.next() == 2 { attack() }
            return .success(stdout: Data())
        }
    }

    /// `merge-base` is the LAST rung of R2's ladder, so an attack staged on
    /// it lands after the D2 witness and BEFORE the last gate — the window
    /// R2's own answer can no longer speak for. Exit 0 from
    /// `merge-base --is-ancestor` is "merged".
    private func ancestryWindowRunner(
        staging attack: @escaping @Sendable () -> Void
    ) -> InterceptingGitRunner {
        InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            if arguments.contains("merge-base") {
                attack()
                return .success(stdout: Data())
            }
            return nil
        }
    }

    func testASamePathReAddInsideTheDisposalWindowIsRefused()
        async throws
    {
        // D1. r3 made G2 the last GATE and argued that
        // "the order is safe both ways round for R0/R1/R2 — they read the
        // PARENT's porcelain record". R1b is not in that list and does not
        // read the parent's record: it reads `<worktree>/.git`. So after G2
        // answered, five subprocesses stood between the identity proof and
        // the delete, and MEASURED at r3 this exact staging destroyed a
        // brand-new checkout and its `secret.env` under a SUCCESS entry with
        // `errors == []`.
        //
        // MUTATION: delete the `reproveFromTheFilesystem` call before the
        // disposal and this cell goes RED — the replacement checkout is
        // destroyed.
        let repository = try makeRepository(named: "repo")
        let assessed = try addWorktree(named: "wt", branch: "feature", in: repository)
        // A second worktree keeps the admin CONTAINER alive across the
        // removal, which is the field shape (git rmdir's an emptied one).
        try addWorktree(named: "anchor", branch: "anchor", in: repository)
        let plan = staleplan(
            worktree: assessed,
            membership: try membership(of: assessed, in: repository)
        )
        let inodeBefore = try XCTUnwrap(plan.worktreeAdminEntryIdentity)
        let home = self.home!
        let staged = InvocationCounter()

        let runner = lastGateRunner(staging: {
            if Self.removeAndReAdd(
                worktree: assessed, repository: repository, home: home,
                branch: "brand-new"
            ) { staged.bump() }
        })
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(staged.count, 1, "the fixture never staged the re-add")
        XCTAssertNotEqual(
            provider.identity(of: try XCTUnwrap(plan.worktreeAdminEntry)),
            inodeBefore,
            "the re-add must have produced a NEW admin directory at the same "
                + "spelling — otherwise this cell proves nothing"
        )
        XCTAssertNil(outcome.entry, "nothing may be reported as freed")
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("DIFFERENT checkout"), message)
        XCTAssertTrue(message.contains("re-created since the scan"), message)
        XCTAssertTrue(fm.fileExists(atPath: assessed.path),
                      "the replacement checkout was destroyed")
        XCTAssertEqual(
            try String(
                contentsOf: assessed.appendingPathComponent("secret.env"),
                encoding: .utf8
            ),
            "TOKEN=live\n", "the replacement's own work was destroyed"
        )
        assertNoForbiddenArgv(runner)
    }

    func testALockTakenInsideTheDisposalWindowStopsTheRemoval()
        async throws
    {
        // D2, THE LOCK. G4 is re-established from the porcelain record, five
        // subprocesses before the delete; a `git worktree lock` acquired
        // after that reached `remove -f -f`'s effect WITHOUT the flag, which
        // this epic's Boundaries forbid — measured with `errors == []` and a
        // user-visible warning that mentioned only leftover metadata.
        //
        // The lock is re-proved here from git's OWN representation of it:
        // `git worktree lock` creates `<admin>/locked` and `unlock` removes
        // it (verified both ways, git 2.50.1), so the last-instant re-proof
        // costs one `lstat` and no subprocess.
        //
        // MUTATION: delete the lock arm of `reproveFromTheFilesystem` and
        // this cell goes RED.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )
        let home = self.home!
        let staged = InvocationCounter()

        let runner = lastGateRunner(staging: {
            if Self.lockWorktree(worktree, repository: repository, home: home) {
                staged.bump()
            }
        })
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(staged.count, 1, "the fixture never staged the lock")
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("LOCKED while the delete-time checks"),
                      message)
        XCTAssertTrue(message.contains("git worktree unlock"), message)
        XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                      "a LOCKED worktree was destroyed")
        XCTAssertEqual(try porcelainRecordCount(of: repository), 2)
        assertNoForbiddenArgv(runner)
    }

    func testACommitMadeInsideTheDisposalWindowIsNotDestroyed() async throws {
        // D2, THE ANCESTRY HALF, in the window the ancestry check cannot
        // cover. R2 costs three subprocesses and cannot be repeated at the
        // last instant; what CAN be repeated is the question its answer
        // depends on — is the same commit still checked out? On a DETACHED
        // head `<admin>/HEAD` holds the SHA and every commit rewrites the
        // file (verified, git 2.50.1), so the witness taken around R2 and
        // re-read here answers it for the price of one `lstat` and one read.
        //
        // Committing does not make the tree dirty, so G2 has nothing to say
        // about this: the tree is clean before and after.
        //
        // MUTATION: delete the HEAD arm of `reproveFromTheFilesystem` and
        // this cell goes RED — the commit is destroyed with the checkout and
        // is reachable from no ref afterwards.
        let repository = try makeRepository(named: "repo")
        let worktree = container.appendingPathComponent("wt")
        try git(["-C", repository.path, "worktree", "add", "--detach",
                 worktree.path, "HEAD"])
        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )
        let home = self.home!
        let staged = InvocationCounter()

        let runner = lastGateRunner(staging: {
            if Self.commitInside(worktree, home: home) { staged.bump() }
        })
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(staged.count, 1, "the fixture never staged the commit")
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("HEAD MOVED"), message)
        XCTAssertTrue(message.contains("delete-time checks were running"), message)
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
        let saved = try headOID(of: worktree)
        XCTAssertEqual(
            try String(
                contentsOf: worktree.appendingPathComponent("tracked.txt"),
                encoding: .utf8
            ),
            "committed in the window\n"
        )
        XCTAssertFalse(
            try isReachableFromAnyRef(saved, in: repository),
            "the fixture must leave the commit on no ref — that is what "
                + "makes destroying it unrecoverable"
        )
        assertNoForbiddenArgv(runner)
    }

    func testALockTakenAfterTheLastGateStopsThePrimaryRemovalToo()
        async throws
    {
        // THE ANCESTRY WINDOW. `merge-base` is R2's last rung, and MEASURED
        // at r3 the gap between it and the destruction was a median 56.9 ms
        // containing three further spawns. A lock acquired in it is invisible
        // to R1's record (already read) and to the HEAD witness (a lock does
        // not move HEAD), so ONLY the last-instant lock re-proof can refuse —
        // which is what makes this cell that re-proof's isolated mutation
        // test. (Through r4 this note called it "the same window in the OTHER
        // arm"; there is one arm.)
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )
        let home = self.home!
        let staged = InvocationCounter()

        let runner = ancestryWindowRunner(staging: {
            if Self.lockWorktree(worktree, repository: repository, home: home) {
                staged.bump()
            }
        })
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(staged.count, 1, "the fixture never staged the lock")
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("LOCKED while the delete-time checks"),
                      message)
        XCTAssertNil(runner.argvs.first { $0.contains("remove") },
                     "git must never have been asked to remove it: \(runner.argvs)")
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
        assertNoForbiddenArgv(runner)
    }

    func testAHeadThatMovesAfterTheAncestryCheckIsRefusedInThePrimaryArm()
        async throws
    {
        // THE HEAD PROPOSITION, IN THE ANCESTRY WINDOW. The witness is taken
        // BEFORE R2's ladder, so the comparison at the last instant spans the
        // whole R2→destruction window — three subprocesses, MEASURED at r3 as
        // a median 56.9 ms — and not merely the tail of it. (The cell's NAME
        // still says "PrimaryArm": renaming it would lose the r3/r4/r5
        // mutation history recorded against that name in three commit
        // messages. There is one arm, and it is this one.)
        //
        // MUTATION: disable the `live == head` comparison in
        // `reproveFromTheFilesystem` and this cell goes RED, with the commit
        // destroyed and reachable from no ref.
        let repository = try makeRepository(named: "repo")
        let worktree = container.appendingPathComponent("wt")
        try git(["-C", repository.path, "worktree", "add", "--detach",
                 worktree.path, "HEAD"])
        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )
        let home = self.home!
        let staged = InvocationCounter()

        let runner = ancestryWindowRunner(staging: {
            if Self.commitInside(worktree, home: home) { staged.bump() }
        })
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(staged.count, 1, "the fixture never staged the commit")
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("HEAD MOVED"), message)
        XCTAssertTrue(message.contains("delete-time checks were running"), message)
        XCTAssertNil(runner.argvs.first { $0.contains("remove") },
                     "\(runner.argvs)")
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
        XCTAssertFalse(
            try isReachableFromAnyRef(try headOID(of: worktree), in: repository)
        )
    }

    /// D3 — THE REFTABLE BACKEND'S ATTACHED RECORD, WHICH r4 LEFT WIDE OPEN.
    ///
    /// Under `--ref-format=reftable`, `<admin>/HEAD` is the constant stub
    /// `ref: refs/heads/.invalid` (measured, git 2.50.1) so it corroborates
    /// nothing. Through r4 that made `captureHead` return `.uncorroborated`,
    /// an ATTACHED record fall through to `.proceed(head: nil)`, and
    /// `reproveFromTheFilesystem` skip HEAD entirely — MEASURED, a
    /// `git switch --detach` plus a commit inside the window destroyed the
    /// worktree, left the commit reachable from no ref, and returned
    /// `Entry(exactBytes: 45056, .permanent, warning: nil)` with
    /// `errors == []`.
    ///
    /// The witness is `<admin>/reftable/tables.list` — the PER-WORKTREE ref
    /// stack, which git replaces on every ref write and leaves untouched by
    /// reads. This cell stages exactly the measured attack.
    ///
    /// MUTATION: drop the `.reftableStack` branch from `captureHead` and this
    /// cell goes RED — the checkout is destroyed and the commit is reachable
    /// from nothing.
    func testAReftableAttachedWorktreeDetachedAndCommittedInsideTheWindowIsRefused()
        async throws
    {
        let repository = try makeReftableRepository(named: "reftable-attached")
        try XCTSkipUnless(
            fm.fileExists(
                atPath: repository.appendingPathComponent(".git/reftable").path
            ),
            "this git has no reftable ref backend"
        )
        let worktree = try addWorktree(named: "rwt", branch: "feature", in: repository)
        let admin = try liveAdminDirectory(of: worktree)
        // The fixture must actually be the shape this cell is about.
        XCTAssertEqual(
            try String(
                contentsOf: admin.appendingPathComponent("HEAD"), encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            "ref: refs/heads/.invalid",
            "the stub is what makes the HEAD file useless as a witness"
        )
        XCTAssertTrue(fm.fileExists(
            atPath: admin.appendingPathComponent("reftable/tables.list").path
        ), "the per-worktree ref stack is the substrate under test")

        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )
        let home = self.home!
        let staged = InvocationCounter()
        let runner = ancestryWindowRunner(staging: {
            guard (try? GitFixture.git(
                ["-C", worktree.path, "switch", "--detach"], home: home
            ))?.status == 0 else { return }
            if Self.commitInside(worktree, home: home) { staged.bump() }
        })
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(staged.count, 1, "the fixture never staged the commit")
        XCTAssertNil(outcome.entry, "\(String(describing: outcome.entry))")
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("HEAD MOVED"), message)
        XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                      "the checkout — and the commit in it — survives")
        XCTAssertFalse(
            try isReachableFromAnyRef(try headOID(of: worktree), in: repository),
            "the commit really is reachable from no ref: this is what would "
                + "have been destroyed"
        )
    }

    /// The refusal that survives D3's fix: a DETACHED worktree with NO
    /// witnessable HEAD at all.
    ///
    /// Both substrates have to be unusable, so the fixture is the FILES
    /// backend (no ref stack exists) with `<admin>/HEAD` replaced by a
    /// DIRECTORY — staged on R1's registry read, so git has already answered
    /// the porcelain record and `captureHead` is the next thing to run.
    ///
    /// Detached is the case worth spending availability on: a commit made in
    /// the window would be reachable from no ref once the admin directory's
    /// reflog went with the worktree. The refusal CLEARS — put the work on a
    /// branch and re-scan.
    func testADetachedWorktreeWithNoWitnessableHeadAtAllIsRefused()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = container.appendingPathComponent("dwt")
        try git(["-C", repository.path, "worktree", "add", "--detach",
                 worktree.path, "HEAD"])
        let headFile = try liveAdminDirectory(of: worktree)
            .appendingPathComponent("HEAD")
        XCTAssertTrue(fm.fileExists(atPath: headFile.path))

        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )
        let fileManager = fm
        let broke = InvocationCounter()
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            guard arguments.contains("list") else { return nil }
            if (try? fileManager.removeItem(at: headFile)) != nil,
               (try? fileManager.createDirectory(
                   at: headFile, withIntermediateDirectories: false
               )) != nil {
                broke.bump()
            }
            return nil
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(broke.count, 1, "the fixture never broke the HEAD file")
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("DETACHED HEAD"), message)
        XCTAssertTrue(message.contains("switch -c"), message)
        // D6: the cause must name BOTH substrates and must NOT claim any
        // backend "keeps no per-worktree HEAD file" — one does keep one, and
        // it is corroboration that fails there, not existence.
        XCTAssertTrue(message.contains("tables.list"), message)
        XCTAssertFalse(message.contains("keeps no"), message)
        XCTAssertNil(runner.argvs.first { $0.contains("remove") },
                     "\(runner.argvs)")
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }

    /// D5 (PR #460 codex r6) — THE OUTCOME THAT MADE `captureHead`'s THIRD
    /// ARM INERT, pinned so its deletion is a decision rather than a gap.
    ///
    /// r5 shipped a reftable-stack fallback after "(3) HEAD is not a readable
    /// regular file", and MUTATION M7 — replacing that block with
    /// `return .unreadable` — left the full suite GREEN: `swift test`, run AT
    /// COMMIT 06c1ad5, reported 1466 executed / 2 skipped / 0 failures (the
    /// total is that commit's; HEAD's is higher — see the class header, D5).
    /// It could not be otherwise: MEASURED on git 2.50.1, making a
    /// reftable worktree's `<admin>/HEAD` unreadable (symlink, or removed)
    /// leaves `git -C <parent> worktree list` reporting BOTH records at exit 0
    /// while `git -C <worktree> …` returns exit 128, "fatal: not a git
    /// repository". So the arm could only ever hand a witness to a removal
    /// that the very next gate refuses.
    ///
    /// This cell is that refusal, through the real performer: the arm is gone
    /// and the tree still survives, because the ignored witness — the FIRST
    /// `status` after the record is re-read — cannot be answered at all.
    func testAReftableWorktreeWhoseHeadFileIsGoneIsRefusedByTheGatesThatRemain()
        async throws
    {
        let repository = try makeReftableRepository(named: "reftable-nohead")
        try XCTSkipUnless(
            fm.fileExists(
                atPath: repository.appendingPathComponent(".git/reftable").path
            ),
            "this git has no reftable ref backend"
        )
        let worktree = try addWorktree(
            named: "rnwt", branch: "feature", in: repository
        )
        let admin = try liveAdminDirectory(of: worktree)
        let headFile = admin.appendingPathComponent("HEAD")
        XCTAssertTrue(
            fm.fileExists(
                atPath: admin.appendingPathComponent("reftable/tables.list").path
            ),
            "the ref stack — the substrate the deleted arm would have used — "
                + "is present, which is what makes this the arm's own case"
        )

        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )
        // Staged on R1's registry read, so the porcelain record is answered
        // normally and `captureHead` is the next thing to run.
        let fileManager = fm
        let broke = InvocationCounter()
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            guard arguments.contains("list") else { return nil }
            if (try? fileManager.removeItem(at: headFile)) != nil {
                broke.bump()
            }
            return nil
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(broke.count, 1, "the fixture never removed the HEAD file")
        XCTAssertNil(outcome.entry, "\(String(describing: outcome.entry))")
        XCTAssertFalse(
            outcome.errors.isEmpty,
            "an unanswerable worktree must produce a per-item error"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: worktree.path),
            "the checkout survives: \(outcome.errors.map(\.message))"
        )
    }

    // MARK: - D4: the two refusals r4 shipped with no cell that could fire

    /// `worktree-head-unreadable`. r4 measured that replacing this refusal
    /// with `return .proceed` left the 225-cell `Worktree|GitWorktree` family
    /// at 225 executed / 0 failures — an unevidenced guard, the class this
    /// file's own commit message forbids.
    ///
    /// It is reachable, and this is the window: the witness was captured and
    /// corroborated around R2, and by the last instant the file it was read
    /// through is no longer a readable regular file. On a DETACHED head that
    /// file IS the commit id, so proceeding would remove the checkout with
    /// the ancestry answer tied to nothing.
    ///
    /// MUTATION: replace the refusal with `return .proceed` and this cell
    /// goes RED — the checkout is destroyed and its commit is reachable from
    /// no ref.
    func testAHeadWitnessThatCannotBeReReadAtTheLastInstantRefuses()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = container.appendingPathComponent("dwt")
        try git(["-C", repository.path, "worktree", "add", "--detach",
                 worktree.path, "HEAD"])
        let headFile = try liveAdminDirectory(of: worktree)
            .appendingPathComponent("HEAD")
        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository)
        )

        let fileManager = fm
        let broke = InvocationCounter()
        // THE WINDOW: after the LAST gate answered, before the disposal.
        let runner = lastGateRunner {
            if (try? fileManager.removeItem(at: headFile)) != nil,
               (try? fileManager.createDirectory(
                   at: headFile, withIntermediateDirectories: false
               )) != nil {
                broke.bump()
            }
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(broke.count, 1, "the fixture never broke the witness")
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("could not be re-read at the last instant"),
                      message)
        XCTAssertTrue(message.contains("HEAD"), message)
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }

    /// `worktree-identity-unreadable`. Same r4 finding: replacing it with
    /// `return .proceed` left the family green.
    ///
    /// It cannot be reached with a fixture made of files, and that is the
    /// point of it: `GitWorktreeGitdirResolver` proves the admin directory is
    /// a `.kind(.directory)` with an `lstat`, and the identity `lstat` that
    /// follows asks the SAME kernel the SAME question. Only a RACE separates
    /// them — the directory going away in between — so the double is what
    /// stages the race deterministically, exactly as a scripted runner stages
    /// a subprocess outcome no fixture can produce on demand.
    ///
    /// Why it must refuse rather than fall through: `sameLocation` compares
    /// INODES only when both sides can be stat'd and otherwise compares
    /// canonical path COMPONENTS, so an unreadable admin directory answered
    /// by a spelling is precisely the ambiguity this gate claims not to have.
    ///
    /// MUTATION: replace the refusal with `return .proceed` and this cell
    /// goes RED.
    func testAnAdminDirectoryThatCannotBeIdentifiedAtCleanTimeRefuses()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let membership = try membership(of: worktree, in: repository)
        // The plan carries a REAL scan-time identity — it is built through
        // the ordinary provider, so the only thing the double changes is the
        // delete-time reading.
        let plan = staleplan(worktree: worktree, membership: membership)
        XCTAssertNotNil(plan.worktreeAdminEntryIdentity)

        let blind = IdentityBlindProvider(
            blindToDirectoryNamed: "wt",
            insideContainerNamed: GitWorktreeGitdirResolver.adminContainerName
        )
        let outcome = await perform(
            item(plan), plan: plan,
            with: makePerformer(
                runner: InterceptingGitRunner(wrapping: realRunner()),
                provider: blind
            )
        )

        XCTAssertGreaterThan(blind.blindedReads, 0,
                             "the double never blinded the admin directory")
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("could not be identified at clean time"),
                      message)
        XCTAssertTrue(message.contains("not provably the one at"), message)
        XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                      "an unidentifiable admin directory must not be removed")
        XCTAssertEqual(try porcelainRecordCount(of: repository), 2)
    }

    func testAPlanCarryingNoAdminIdentityIsRefusedRatherThanRunUnbound()
        async throws
    {
        // D6. Through r3 a plan with no carried identity ran the gate INERT —
        // the `if let carriedIdentity` block was skipped and only the path
        // proof ran, which a same-path re-add satisfies. Any future
        // construction path that forgot the field would have shipped that
        // silently. It is a refusal now, and the field carries no default in
        // either initializer, so forgetting it does not compile.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree,
            membership: try membership(of: worktree, in: repository),
            bindAdminIdentity: false
        )
        XCTAssertNil(plan.worktreeAdminEntryIdentity)

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrapElement(outcome.errors, 0).message
        XCTAssertTrue(message.contains("no scan-time identity"), message)
        XCTAssertTrue(message.contains("Re-scan"), message)
        XCTAssertNil(runner.argvs.first { $0.contains("remove") },
                     "\(runner.argvs)")
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }

    // MARK: The D13 guard sites the oracle listing needs (codex r2 / D4)

    /// Replace `directory` with a SYMLINK to a copy of itself: every byte a
    /// listing would read is still reachable, and only the no-follow leaf
    /// check can tell the difference. Called from inside `@Sendable`
    /// closures, where a throw would be swallowed — so every caller asserts
    /// the swap took by its EFFECT before asserting anything else.
    private static func swapToSymlink(_ directory: URL) {
        let fileManager = FileManager.default
        let moved = directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + "-moved")
        try? fileManager.moveItem(at: directory, to: moved)
        try? fileManager.createSymbolicLink(
            at: directory, withDestinationURL: moved
        )
    }

    func testTheRegistryReReadRefusesWhenTheAdminContainerIsSwappedMidFlight()
        async throws
    {
        // D4 (PR #460 codex r2). `git worktree list` does not merely run in
        // the `-C` target: it ENUMERATES `$GIT_COMMON_DIR/worktrees` to
        // decide which records are `prunable`. The stale arm's pre-remove
        // guard covers the parent and the worktree and NOT that container,
        // so between admission and the registry re-read the container was
        // unguarded. This cell swaps it for a symlink in exactly that
        // window, timed off R0's subprocess.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let membership = try membership(of: worktree, in: repository)
        let adminContainer = membership.parentAdminContainer
        let plan = staleplan(worktree: worktree, membership: membership)

        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            if arguments.contains("--git-common-dir") {
                WorktreeReclaimPerformerTests.swapToSymlink(adminContainer)
            }
            return nil
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertEqual(
            provider.probeKind(of: adminContainer), .kind(.symlink),
            "the swap must have taken, or this cell proves nothing"
        )
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(
            message.contains("the traversal guard for the worktree-registry "
                             + "re-read"), message
        )
        XCTAssertNil(runner.argvs.first { $0.contains("list") },
                     "the listing must not have run at all: \(runner.argvs)")
        XCTAssertNil(runner.argvs.first { $0.contains("remove") })
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }

    // MARK: - R6: prune-only mode

    /// Add a worktree and then DELETE its checkout — the orphaned admin
    /// directory the porcelain oracle annotates `prunable`.
    @discardableResult
    private func makeOrphan(
        named name: String, in repository: URL, membership: WorktreeMembership
    ) throws -> URL {
        let worktree = try addWorktree(
            named: name, branch: "branch-\(name)", in: repository
        )
        try fm.removeItem(at: worktree)
        let adminDirectory = membership.parentAdminContainer
            .appendingPathComponent(name)
        XCTAssertTrue(fm.fileExists(atPath: adminDirectory.path))
        return adminDirectory
    }

    /// A repository with one live worktree (so the resolver can derive the
    /// carried admin container) plus however many orphans a cell needs.
    private func makePruneFixture(
        orphans: [String], suffix: String = ""
    ) throws -> (repository: URL, membership: WorktreeMembership, admin: [URL]) {
        let repository = try makeRepository(named: "repo\(suffix)")
        let anchor = try addWorktree(
            named: "anchor\(suffix)", branch: "anchor\(suffix)", in: repository
        )
        let membership = try membership(of: anchor, in: repository)
        let admin = try orphans.map {
            try makeOrphan(named: $0, in: repository, membership: membership)
        }
        return (repository, membership, admin)
    }

    func testTheOracleRecomputeRefusesWhenTheAdminContainerIsSwappedMidFlight()
        async throws
    {
        // D4's second half (PR #460 codex r2). The delete-time recompute
        // fires the SAME `worktree list` argv as R1, so it traverses the
        // same two paths — and its guard covered only the parent. The
        // revalidator seam is the one production hook that runs BETWEEN the
        // first recompute and the final pre-removal one, which is exactly
        // the window to swap the container in.
        let fixture = try makePruneFixture(orphans: ["gone"])
        let orphan = try XCTUnwrapElement(fixture.admin, 0)
        let adminContainer = fixture.membership.parentAdminContainer
        let plan = prunePlan(membership: fixture.membership, disclosed: [orphan])
        let runner = InterceptingGitRunner(wrapping: realRunner())

        let outcome = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(runner: runner, revalidate: { _ in
                WorktreeReclaimPerformerTests.swapToSymlink(adminContainer)
                return nil
            })
        )

        XCTAssertEqual(
            provider.probeKind(of: adminContainer), .kind(.symlink),
            "the swap must have taken, or this cell proves nothing"
        )
        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        // NAMED as the guard's refusal, not the mapper's: without the
        // container in the guard's path list the listing runs, the mapper
        // then refuses the same symlink for its own reason, and the outer
        // wording is identical. The inner clause is what discriminates.
        XCTAssertTrue(
            message.contains("the traversal guard refused a path the oracle "
                             + "listing traverses"), message
        )
        XCTAssertTrue(
            message.contains("final pre-prune prunable-set check"), message
        )
        XCTAssertTrue(
            fm.fileExists(atPath: adminContainer
                .deletingLastPathComponent()
                .appendingPathComponent(
                    adminContainer.lastPathComponent + "-moved"
                )
                .appendingPathComponent("gone").path),
            "nothing was pruned"
        )
    }

    func testFreshOrphansAreActuallyRemovedByTheExecutionPrune() async throws {
        let fixture = try makePruneFixture(orphans: ["gone"])
        let orphan = try XCTUnwrapElement(fixture.admin, 0)
        let plan = prunePlan(membership: fixture.membership, disclosed: [orphan])
        let runner = InterceptingGitRunner(wrapping: realRunner())

        let report = await makeCleaner(runner: runner)
            .clean(items: [item(plan, id: "prune")], moveToTrash: true)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errorLines)")
        XCTAssertFalse(fm.fileExists(atPath: orphan.path),
                       "the orphan must be REMOVED, not merely detected")
        let entry = try XCTUnwrap(report.entries.first)
        // D16: prune is never a trash operation, whatever the run requested.
        XCTAssertEqual(entry.disposal, .permanent)
        XCTAssertNil(entry.warning,
                     "the D11 warning is exclusive to stale mode")

        // NO repository-wide prune argv exists: the removal is scoped to the
        // disclosed directories (PR #460 codex r1 / C4). D10's `--expire=now`
        // job now lives entirely on the ORACLE listing, which is where
        // prunability is decided — asserted below.
        XCTAssertNil(runner.argvs.first { $0.contains("prune") }, "\(runner.argvs)")
        XCTAssertNil(runner.invocations.first { $0.profile == .mutation },
                     "the prune tier fires no git MUTATION at all")
        for listing in runner.invocations where listing.argv.contains("list") {
            XCTAssertTrue(
                listing.argv.contains(GitWorktreeOracle.pruneExpireOverride),
                "\(listing.argv)"
            )
        }
        // TWO read-only oracle recomputes bracket the measurement (round 8).
        let listings = runner.invocations.filter { $0.argv.contains("list") }
        XCTAssertEqual(listings.count, 2)
        for listing in listings {
            XCTAssertEqual(listing.profile, .readOnly)
            XCTAssertEqual(
                listing.environment[GitCommandRunner.optionalLocksVariable], "0"
            )
        }
        assertNoForbiddenArgv(runner)
    }

    func testAZeroByteMeasuredPruneItemReachesDispatchThroughTheCleaner()
        async throws
    {
        // The composite is excluded from the zero-byte skip, so a prune item
        // with ~0 bytes must still execute — and must still be REPORTED.
        let fixture = try makePruneFixture(orphans: ["gone"])
        let plan = prunePlan(
            membership: fixture.membership, disclosed: [try XCTUnwrapElement(fixture.admin, 0)]
        )
        let zeroByte = item(plan, id: "zero", exactBytes: 0, itemCount: 1)
        XCTAssertEqual(zeroByte.allocatedBytes, 0)

        let runner = InterceptingGitRunner(wrapping: realRunner())
        let report = await makeCleaner(runner: runner)
            .clean(items: [zeroByte], moveToTrash: false)

        XCTAssertFalse(runner.argvs.isEmpty,
                       "a zero-byte prune item must reach dispatch")
        XCTAssertTrue(report.errors.isEmpty, "\(report.errorLines)")
        XCTAssertEqual(report.entries.count, 1,
                       "execution must stay reportable")
    }

    func testASuccessEntryIsEmittedEvenWhenZeroBytesCouldBeAccepted()
        async throws
    {
        // Verified-removal accounting: a removal seam that reports success
        // while removing nothing accepts nothing — and STILL reports a row,
        // never a silent success.
        let fixture = try makePruneFixture(orphans: ["gone"])
        let orphan = try XCTUnwrapElement(fixture.admin, 0)
        let plan = prunePlan(membership: fixture.membership, disclosed: [orphan])
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(runner: runner, removeTree: { _, _, prove in
                try prove()
            })
        )

        XCTAssertTrue(outcome.errors.isEmpty)
        let entry = try XCTUnwrap(outcome.entry, "a row is mandatory on success")
        XCTAssertEqual(entry.bytesFreed, 0,
                       "a directory still on disk was not freed")
        XCTAssertTrue(fm.fileExists(atPath: orphan.path))
    }

    func testEveryFailingPruneClassIsAnErrorAndNeverAWarning() async throws {
        // The failure classes of the prune tier, after the removal became
        // scoped: the two ORACLE classes that decide the set, and the removal
        // itself. All are ERRORS — the D11 warning channel is exclusive to
        // stale mode, where the bytes are already freed.
        let cases: [(name: String, outcome: GitCommandOutcome?, fragment: String)] = [
            ("oracle-nonzero", .failure(exitCode: 9, stderr: "fatal: list refused"),
             "git exit 9"),
            ("oracle-timeout", .timeout, "the porcelain oracle timed out"),
            ("oracle-unavailable", .gitUnavailable, "git is unavailable at clean time"),
            ("removal", nil, "could not be removed"),
        ]
        for (name, scripted, fragment) in cases {
            // Each case gets its OWN repository, worktree and orphan names —
            // a shared fixture would leave the previous iteration's worktree
            // paths behind and make `worktree add` fail.
            let fixture = try makePruneFixture(orphans: ["gone-\(name)"], suffix: "-\(name)")
            let orphan = try XCTUnwrapElement(fixture.admin, 0)
            let plan = prunePlan(membership: fixture.membership, disclosed: [orphan])
            let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, index in
                // The FIRST recompute only — a scripted second one would be
                // testing a different gate.
                guard let scripted, arguments.contains("list"), index == 1 else { return nil }
                return scripted
            }
            let outcome = await perform(
                item(plan, id: "prune"), plan: plan,
                with: makePerformer(
                    runner: runner,
                    removeTree: scripted == nil
                        ? { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
                        : nil
                )
            )
            XCTAssertNil(outcome.entry,
                         "\(name): a failed prune accepts no claims and reports no row")
            let message = try XCTUnwrap(outcome.errors.first?.message, name)
            XCTAssertTrue(message.contains(fragment), "\(name): \(message)")
            XCTAssertTrue(fm.fileExists(atPath: orphan.path), name)
            // The D11 warning channel is EXCLUSIVE to stale mode: a
            // prune-only failure is an error and must never borrow the
            // "next scan will offer it" reassurance.
            XCTAssertFalse(
                message.contains(WorktreeReclaimPerformer.orphanedAdminWarning),
                "\(name): a prune-only failure must not read as a warning"
            )
        }
    }

    func testAnOrphanThatAppearedSinceTheScanRefusesTheWholeItem() async throws {
        // The recomputed set must be a SUBSET of the disclosure: a new orphan
        // would ride a repo-wide prune nobody was told about.
        let fixture = try makePruneFixture(orphans: ["gone"])
        let disclosed = try XCTUnwrapElement(fixture.admin, 0)
        let surprise = try makeOrphan(
            named: "surprise", in: fixture.repository, membership: fixture.membership
        )
        let plan = prunePlan(membership: fixture.membership, disclosed: [disclosed])
        let runner = InterceptingGitRunner(wrapping: realRunner())

        let outcome = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.entry)
        XCTAssertTrue(
            try XCTUnwrap(outcome.errors.first?.message)
                .contains("prune set changed since scan — re-scan required")
        )
        XCTAssertTrue(fm.fileExists(atPath: disclosed.path))
        XCTAssertTrue(fm.fileExists(atPath: surprise.path))
        XCTAssertNil(runner.argvs.first { $0.contains("prune") },
                     "nothing may be pruned after a fail-closed refusal")
    }

    func testAnOrphanIntroducedAfterMeasurementIsCaughtByTheSecondOracleCheck()
        async throws
    {
        // ROUND 8: the admission/measurement walks take time, and an orphan
        // appearing DURING them would be pruned outside every checked set.
        // The window is opened here between the FIRST and the SECOND listing.
        let fixture = try makePruneFixture(orphans: ["gone"])
        let disclosed = try XCTUnwrapElement(fixture.admin, 0)
        let plan = prunePlan(membership: fixture.membership, disclosed: [disclosed])

        let secondOrphanPath = container.appendingPathComponent("late")
        let repository = fixture.repository
        let fixtureHome = home!
        let fileManager = fm
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, index in
            // Call 1 is the first recompute, call 2 the FINAL pre-subprocess
            // check: the orphan is created here, after every admission and
            // measurement walk has already run against the first set.
            if arguments.contains("list"), index == 2 {
                _ = try? GitFixture.git(
                    ["-C", repository.path, "worktree", "add",
                     secondOrphanPath.path, "-b", "late"],
                    home: fixtureHome
                )
                try? fileManager.removeItem(at: secondOrphanPath)
            }
            return nil
        }
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("GREW"), message)
        XCTAssertTrue(fm.fileExists(atPath: disclosed.path))
        XCTAssertNil(runner.argvs.first { $0.contains("prune") },
                     "nothing pruned after the final check refused")
    }

    func testAMountBoundaryInARecomputedAdminDirRefusesBeforeClaimsOrPrune()
        async throws
    {
        // ROUND 9: `worktree prune` is a RECURSIVE mutation over these
        // directories, so the boundary-bearing-recursive-delete doctrine
        // applies — and the D13 guard cannot see a NESTED boundary, only the
        // sizer can. The drift is simulated at the sizer seam because a real
        // mount cannot be staged in a unit test.
        let fixture = try makePruneFixture(orphans: ["gone"])
        let orphan = try XCTUnwrapElement(fixture.admin, 0)
        let plan = prunePlan(membership: fixture.membership, disclosed: [orphan])
        let boundary = orphan.appendingPathComponent("mounted")
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let performer = makePerformer(
            runner: runner,
            measure: { url, _, _ in
                var report = SizeReport()
                if url.path == orphan.path {
                    report.mountBoundaries = [boundary]
                }
                return report
            }
        )
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan, with: performer
        )

        XCTAssertNil(outcome.entry)
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains(boundary.path), message)
        XCTAssertTrue(fm.fileExists(atPath: orphan.path))
        XCTAssertNil(runner.argvs.first { $0.contains("prune") },
                     "the refusal precedes the prune")
    }


    func testADisclosedEntryANOTHERProcessRemovedIsNeverBilledAsFreed()
        async throws
    {
        // **PR #460 codex r13, F.** Step (10) iterated `registered` — the
        // ORIGINALLY MEASURED set — and credited any directory whose path now
        // probed `.absent`. The final oracle recompute may legally SHRINK the
        // set (growth is refused at `prune-set-grew`; shrinkage is what
        // verified-removal accounting exists to handle), so a directory that
        // ANOTHER PROCESS removed inside that window is absent, was never in
        // `removalSet`, and was billed to Cacheout as bytes it freed.
        //
        // `testASurvivingDisclosedEntryNeverReportsItsBytesAsFreed` cannot
        // see this: its survivor SURVIVES, so the `.absent` probe subtracts
        // it. The defect needs a survivor that VANISHES, which is what this
        // fixture stages — and it stages it with a real `removeItem` from
        // outside the performer, at the last runner call before the removal,
        // so nothing about the item's own execution removed it.
        let fixture = try makePruneFixture(orphans: ["gone", "stranger"])
        let swept = try XCTUnwrapElement(fixture.admin, 0)
        let takenByAnother = try XCTUnwrapElement(fixture.admin, 1)
        // Big enough that a leak into the row is unmissable.
        try Data(repeating: 7, count: 400_000)
            .write(to: takenByAnother.appendingPathComponent("filler.bin"))

        let plan = prunePlan(
            membership: fixture.membership,
            disclosed: [swept, takenByAnother]
        )
        let fileManager = fm
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, index in
            // Call 1 is the first recompute (measurement and claims are
            // registered off it); call 2 is the FINAL pre-removal check. The
            // outside removal lands between them, so the final set SHRINKS to
            // `gone` alone and `stranger` is absent by the time step (10)
            // looks.
            if arguments.contains("list"), index == 2 {
                try? fileManager.removeItem(at: takenByAnother)
            }
            return nil
        }
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(runner: runner)
        )

        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors.map(\.message))")
        XCTAssertFalse(fm.fileExists(atPath: swept.path),
                       "the one directory this operation removed is gone")
        XCTAssertFalse(
            fm.fileExists(atPath: takenByAnother.path),
            "the fixture must actually have staged the outside removal, or "
                + "this cell proves nothing"
        )
        let entry = try XCTUnwrap(outcome.entry)
        print("MEASURED-PRUNE-CREDIT-BYTES \(entry.bytesFreed)")
        XCTAssertLessThan(
            entry.bytesFreed, 400_000,
            "bytes another process freed are not this app's to report — the "
                + "credit follows the REMOVAL SET, not the measured set"
        )
    }

    func testASurvivingDisclosedEntryNeverReportsItsBytesAsFreed() async throws {
        // The disclosed-set-SHRINKS fixture: one disclosed entry became
        // LOCKED since the scan, so the delete-time recompute drops it from
        // the removal set. The item still executes over the recomputed
        // subset, and the survivor's bytes are NOT reported freed
        // (verified-removal accounting).
        let fixture = try makePruneFixture(orphans: ["gone", "locked"])
        let swept = try XCTUnwrapElement(fixture.admin, 0)
        let survivor = try XCTUnwrapElement(fixture.admin, 1)
        // A LOCK, exactly as git records one, plus a big filler so the
        // survivor's bytes would be unmissable if they leaked into the row.
        try Data("held".utf8).write(to: survivor.appendingPathComponent("locked"))
        try Data(repeating: 3, count: 400_000)
            .write(to: survivor.appendingPathComponent("filler.bin"))

        let plan = prunePlan(
            membership: fixture.membership, disclosed: [swept, survivor]
        )
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(runner: runner)
        )

        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors.map(\.message))")
        XCTAssertFalse(fm.fileExists(atPath: swept.path))
        XCTAssertTrue(fm.fileExists(atPath: survivor.path),
                      "a locked admin dir is excluded by the mapper — the "
                          + "sole enforcement since the repo-wide prune was "
                          + "retired (D6)")
        let entry = try XCTUnwrap(outcome.entry)
        XCTAssertLessThan(
            entry.bytesFreed, 400_000,
            "the surviving entry's bytes must never be reported freed"
        )
    }

    // MARK: - R6/R8: the BARE-PARENT fixture

    func testABareParentExecutesThroughTheCarriedAdminContainer() async throws {
        // D13 revised: a bare parent's git directory does NOT live at
        // `<wd>/.git`, and a linked worktree of a bare main is not itself
        // `bare`, so G1 never excludes the shape — a `<wd>/.git/worktrees`
        // reconstruction would silently mis-path the mutation scope. Both
        // modes must therefore execute through the RESOLVER-CARRIED
        // `<parentGitDir>/worktrees`.
        let source = try makeRepository(named: "source")
        let bare = container.appendingPathComponent("bare.git")
        XCTAssertEqual(
            try GitFixture.git(
                ["clone", "--bare", source.path, bare.path], home: home
            ).status, 0, "bare clone failed"
        )
        let stale = container.appendingPathComponent("bare-wt")
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", bare.path, "worktree", "add", stale.path, "-b", "feature"],
                home: home
            ).status, 0
        )
        let membership = try membership(of: stale, in: bare)

        // The carried container is `<bare.git>/worktrees` — and the
        // reconstruction that would have been used instead does not even
        // exist on disk, which is exactly why it is forbidden.
        XCTAssertEqual(
            membership.parentAdminContainer.path,
            bare.appendingPathComponent("worktrees").path
        )
        XCTAssertEqual(membership.parentRepoWorkingDir.path, bare.path)
        XCTAssertFalse(
            fm.fileExists(atPath: bare.appendingPathComponent(".git").path),
            "a bare parent has no <wd>/.git to reconstruct from"
        )

        // (a) STALE removal through the bare parent.
        let stalePlan = staleplan(worktree: stale, membership: membership)
        let staleRunner = InterceptingGitRunner(wrapping: realRunner())
        let staleReport = await makeCleaner(runner: staleRunner)
            .clean(items: [item(stalePlan, id: "bare-stale")], moveToTrash: false)
        XCTAssertTrue(staleReport.errors.isEmpty, "\(staleReport.errorLines)")
        XCTAssertFalse(fm.fileExists(atPath: stale.path))
        XCTAssertFalse(fm.fileExists(
            atPath: membership.parentAdminContainer
                .appendingPathComponent("bare-wt").path
        ))
        XCTAssertTrue(try branchExists("feature", in: bare))
        XCTAssertEqual(
            dashCTarget(try XCTUnwrap(staleRunner.argvs.first)), bare.path,
            "git must be pointed at the bare repository itself"
        )

        // (b) PRUNE-ONLY through the same carried container.
        let orphanCheckout = container.appendingPathComponent("bare-gone")
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", bare.path, "worktree", "add", orphanCheckout.path,
                 "-b", "gone"], home: home
            ).status, 0
        )
        try fm.removeItem(at: orphanCheckout)
        let orphanAdmin = membership.parentAdminContainer
            .appendingPathComponent("bare-gone")
        XCTAssertTrue(fm.fileExists(atPath: orphanAdmin.path))

        let prune = prunePlan(membership: membership, disclosed: [orphanAdmin])
        let pruneRunner = InterceptingGitRunner(wrapping: realRunner())
        let pruneReport = await makeCleaner(runner: pruneRunner)
            .clean(items: [item(prune, id: "bare-prune")], moveToTrash: false)

        XCTAssertTrue(pruneReport.errors.isEmpty, "\(pruneReport.errorLines)")
        XCTAssertFalse(fm.fileExists(atPath: orphanAdmin.path),
                       "the bare parent's admin entry must actually be pruned")
        XCTAssertEqual(pruneReport.entries.count, 1)
        // Every git invocation this tier fires is pointed at the BARE
        // repository itself, and none of them is a mutation: the removal is
        // scoped to the carried admin container (PR #460 codex r1 / C4).
        for argv in pruneRunner.argvs {
            XCTAssertEqual(dashCTarget(argv), bare.path, "\(argv)")
        }
        XCTAssertNil(pruneRunner.argvs.first { $0.contains("prune") })
        XCTAssertNil(pruneRunner.invocations.first { $0.profile == .mutation })
        assertNoForbiddenArgv(pruneRunner)
    }

    func testTheRemovalSetIsExactlyTheRecomputedSetAndNeverTheContainer()
        async throws
    {
        // RETIRED (PR #460 codex r1 / C4): this cell used to assert "the prune
        // tier mutates the registry ONLY through git — a direct rm would
        // bypass git's own bookkeeping". That premise is false for THIS
        // object, and it was MEASURED rather than assumed (git 2.50.1, two
        // identically-built repositories, one pruned by git and one whose
        // orphan admin directory was removed directly): IDENTICAL `.git`
        // trees, IDENTICAL `worktree list --porcelain`, IDENTICAL branch
        // lists, `git fsck` clean on both, a subsequent
        // `worktree prune --expire=now` a silent no-op, the surviving live
        // worktree's `status` fine, and a later `worktree add` fine. The admin
        // directory IS the bookkeeping, and git's own prune removes it
        // recursively. What git's prune adds is the RE-ENUMERATION — it takes
        // no path and no set, so it recomputes one AFTER every gate here has
        // already answered.
        //
        // The invariant that replaces it is the one actually at stake: what is
        // removed is the recomputed, DISCLOSED set — never whatever else the
        // container happens to hold.
        let fixture = try makePruneFixture(orphans: ["disclosed", "undisclosed"])
        let disclosed = try XCTUnwrapElement(fixture.admin, 0)
        let undisclosed = try XCTUnwrapElement(fixture.admin, 1)
        // Only ONE of the two orphans is disclosed; the other is prunable and
        // would ride a repository-wide prune.
        let plan = prunePlan(
            membership: fixture.membership, disclosed: [disclosed]
        )
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(runner: runner)
        )

        // The recompute sees BOTH, one was never disclosed, so the item
        // refuses outright and removes nothing at all.
        XCTAssertNil(outcome.entry)
        XCTAssertTrue(fm.fileExists(atPath: disclosed.path))
        XCTAssertTrue(fm.fileExists(atPath: undisclosed.path))
        XCTAssertTrue(
            try XCTUnwrap(outcome.errors.first?.message)
                .contains("was never disclosed")
        )
        // …and there is no repository-wide prune argv anywhere to reach.
        XCTAssertNil(runner.argvs.first { $0.contains("prune") })
    }

    func testTheDisclosedOrphanIsRemovedWhileItsLiveSiblingSurvives()
        async throws
    {
        // The positive half: the scoped removal takes the disclosed admin
        // directory and NOTHING else inside the same container — and it
        // leaves the repository in the state git's own prune would leave,
        // asserted through git rather than through our own bookkeeping.
        let fixture = try makePruneFixture(orphans: ["gone"])
        let orphan = try XCTUnwrapElement(fixture.admin, 0)
        let anchorAdmin = fixture.membership.parentAdminContainer
            .appendingPathComponent("anchor")
        XCTAssertTrue(fm.fileExists(atPath: anchorAdmin.path))

        let plan = prunePlan(membership: fixture.membership, disclosed: [orphan])
        let runner = InterceptingGitRunner(wrapping: realRunner())
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(runner: runner)
        )

        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors.map(\.message))")
        XCTAssertFalse(fm.fileExists(atPath: orphan.path),
                       "the disclosed orphan must be REMOVED")
        XCTAssertTrue(fm.fileExists(atPath: anchorAdmin.path),
                      "the live worktree's admin entry must survive")
        XCTAssertEqual(try porcelainRecordCount(of: fixture.repository), 2)
        XCTAssertEqual(
            String(decoding: try git(["-C", fixture.repository.path, "fsck"]),
                   as: UTF8.self),
            "", "fsck must be clean after a scoped removal"
        )
        XCTAssertNil(runner.argvs.first { $0.contains("prune") })
    }

    func testAnEntryLockedBetweenTheTwoOracleChecksIsNotRemoved() async throws {
        // SHRINKAGE IS LEGAL, AND IT IS ALSO BINDING. What gets removed is the
        // FINAL recomputed set, never the earlier one: an entry the last
        // oracle answer no longer calls prunable must not be destroyed just
        // because an earlier answer did.
        //
        // A LOCK is the shape that proves it, and it is NOT the fact the
        // per-object revival probe re-establishes: the checkout is still gone,
        // so the back-link still reads "orphaned". What changed is that the
        // user marked the entry do-not-touch — exactly as G4 does for a live
        // worktree — and the mapper excludes locked entries because git's own
        // prune skips them too.
        let fixture = try makePruneFixture(orphans: ["gone"])
        let orphan = try XCTUnwrapElement(fixture.admin, 0)
        let plan = prunePlan(membership: fixture.membership, disclosed: [orphan])

        let listings = Timeline()
        let lockFile = orphan.appendingPathComponent("locked")
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            guard arguments.contains("list") else { return nil }
            listings.record("list")
            // THE WINDOW: after the FIRST recompute answered, before the
            // SECOND one runs. `locked` is how git itself records a lock, and
            // the porcelain reports it back.
            if listings.events.count == 2 {
                try? Data("in use on laptop\n".utf8).write(to: lockFile)
            }
            return nil
        }
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(runner: runner)
        )

        XCTAssertTrue(fm.fileExists(atPath: orphan.path),
                      "an entry locked after the first check must survive")
        XCTAssertTrue(fm.fileExists(atPath: lockFile.path),
                      "…and the lock itself must be untouched")
        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors.map(\.message))")
        // The row is still emitted — the execution stays reportable — but it
        // promises NOTHING, because nothing was freed.
        XCTAssertEqual(try XCTUnwrap(outcome.entry).bytesFreed, 0)
    }

    func testACheckoutRevivedAfterTheFinalCheckIsNotSwept() async throws {
        // THE PER-OBJECT GATE. The final oracle check answered one subprocess
        // ago; if a checkout came back in between (a remount, a restore, a
        // `git worktree repair`), its admin directory holds live index, reflog
        // and refs, and destroying it is exactly what `worktree repair` can no
        // longer undo.
        let fixture = try makePruneFixture(orphans: ["first", "revived"])
        let plan = prunePlan(
            membership: fixture.membership, disclosed: fixture.admin
        )
        let revivedAdmin = try XCTUnwrapElement(fixture.admin, 1)
        let revivedCheckout = container.appendingPathComponent("revived")
        let fileManager = fm
        let removed = TrashRecorder()
        // THE WINDOW: removing the FIRST directory revives the SECOND one's
        // checkout, which is strictly after the final oracle check.
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(
                runner: InterceptingGitRunner(wrapping: realRunner()),
                removeTree: { url, _, prove in
                    try prove()
                    removed.record(url)
                    if removed.urls.count == 1 {
                        try? fileManager.createDirectory(
                            at: revivedCheckout, withIntermediateDirectories: true
                        )
                        try? Data("gitdir: \(revivedAdmin.path)\n".utf8).write(
                            to: revivedCheckout.appendingPathComponent(".git")
                        )
                    }
                    try fileManager.removeItem(at: url)
                }
            )
        )

        XCTAssertTrue(
            fm.fileExists(atPath: revivedAdmin.path),
            "an admin directory whose checkout came back must not be removed"
        )
        XCTAssertTrue(fm.fileExists(
            atPath: revivedAdmin.appendingPathComponent("gitdir").path
        ), "…nor any of its live state")
        XCTAssertNil(outcome.entry, "a refused removal accepts nothing")
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("is registered again"), message)
        XCTAssertTrue(message.contains("Re-scan"), message)
    }

    // MARK: - R8: the traversal guard in PRUNE mode

    func testPruneModeRefusesASwappedLeafBeforeAnyGitOrAnyMeasurement()
        async throws
    {
        // The two refusal wordings are BOTH correct and each names the gate
        // that fired first: a swapped ADMIN CONTAINER is a symlink leaf, so
        // the traversal guard's real-directory gate refuses it; a swapped
        // PARENT makes the admin container's ANCESTOR chain resolve outside
        // the dev root, which `validateRemovableItem` catches one gate
        // earlier (the prune-mode target IS that admin container). Either
        // way: refused, no git, nothing measured.
        let expected = [
            "parent": "not strictly inside",
            "adminContainer": "not a real directory",
        ]
        for swap in ["parent", "adminContainer"] {
            let fixture = try makePruneFixture(orphans: ["gone"], suffix: "-\(swap)")
            let plan = prunePlan(
                membership: fixture.membership, disclosed: [try XCTUnwrapElement(fixture.admin, 0)]
            )
            let outside = try makeOutsideRepository()
            switch swap {
            case "parent":
                try swapToSymlink(fixture.repository, pointingAt: outside)
            default:
                try swapToSymlink(
                    fixture.membership.parentAdminContainer, pointingAt: outside
                )
            }

            let runner = InterceptingGitRunner(wrapping: UnreachableGitRunner())
            let spy = SizerSpy()
            let outcome = await perform(
                item(plan, id: "prune"), plan: plan,
                with: makePerformer(runner: runner, measure: spy.measure)
            )
            XCTAssertNil(outcome.entry, swap)
            XCTAssertTrue(
                try XCTUnwrap(outcome.errors.first?.message, swap)
                    .contains(expected[swap] ?? ""),
                "\(swap): \(outcome.errors.first?.message ?? "<none>")"
            )
            XCTAssertTrue(runner.argvs.isEmpty, "\(swap): git must not run")
            XCTAssertTrue(spy.measuredURLs.isEmpty, "\(swap): nothing measured")
        }
    }

    func testTheOracleRecomputeIsGuardedInItsOwnRightBeforeEachListing()
        async throws
    {
        // The recompute is `git -C <parent> worktree list`, so the guard runs
        // over the parent immediately before it — including the SECOND,
        // pre-subprocess listing. The parent is swapped in the window
        // between the two listings, after admission and measurement already
        // passed against the real one.
        let fixture = try makePruneFixture(orphans: ["gone"])
        let plan = prunePlan(
            membership: fixture.membership, disclosed: [try XCTUnwrapElement(fixture.admin, 0)]
        )
        let outside = try makeOutsideRepository()
        let repository = fixture.repository
        let fileManager = fm
        let sizer = DirectorySizer(provider: provider)
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, index in
            // Only the FIRST listing may run: the second one is guarded, and
            // by then the parent has been swapped.
            if arguments.contains("list"), index > 1 {
                XCTFail("a guarded listing executed anyway: \(arguments)")
            }
            if arguments.contains("prune") {
                XCTFail("the prune must never have run: \(arguments)")
                return .success(stdout: Data())
            }
            return nil
        }
        let performer = makePerformer(
            runner: runner,
            measure: { url, mode, known in
                let report = sizer.measure(at: url, mode: mode, knownInodes: known)
                // THE WINDOW: after the first recompute admitted the set and
                // while it is being measured, before the final check runs.
                try? fileManager.removeItem(at: repository)
                try? fileManager.createSymbolicLink(
                    at: repository, withDestinationURL: outside
                )
                return report
            }
        )
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan, with: performer
        )

        XCTAssertNil(outcome.entry)
        XCTAssertTrue(
            try XCTUnwrap(outcome.errors.first?.message)
                .contains("not a real directory")
        )
        // "Nothing was pruned" is proven by the ABSENT prune argv (and the
        // XCTFail above): the admin directory's own path no longer resolves
        // through the swapped parent, so its existence says nothing here.
        XCTAssertNil(runner.argvs.first { $0.contains("prune") })
    }

    // MARK: - Accounting parity with `removeGuardedItem` (R8)

    func testMeasurementAndRegistrationHappenBeforeAnyGitAndAcceptanceAfter()
        async throws
    {
        // Register-before / accept-after, proven as an ORDERING: the sizer
        // (and with it `registerObservations`) runs before the first git
        // invocation, and the bytes only appear on a successful removal.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let timeline = Timeline()
        let sizer = DirectorySizer(provider: provider)
        // EVERY git invocation is read-only now (PR #460 codex r5 / D1), so
        // the ordering is asserted against the FIRST one rather than against
        // "the mutation" — there is no mutation left to name.
        let recorded = GitCallCounter()
        let runner = InterceptingGitRunner(wrapping: realRunner()) { _, _ in
            if recorded.next() == 1 { timeline.record("git") }
            return nil
        }
        let performer = makePerformer(
            runner: runner,
            measure: { url, mode, known in
                timeline.record("measure")
                return sizer.measure(at: url, mode: mode, knownInodes: known)
            }
        )
        let outcome = await perform(item(plan), plan: plan, with: performer)

        XCTAssertEqual(timeline.events, ["measure", "git"],
                       "claims must be registered before git runs")
        XCTAssertGreaterThan(try XCTUnwrap(outcome.entry).exactBytes, 40_000)
    }

    func testAnAbortedRemovalAcceptsNothingEvenThoughItMeasured() async throws {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let spy = SizerSpy(stub: { _ in
            var report = SizeReport()
            report.exactAllocatedBytes = 4096
            return report
        })
        let runner = InterceptingGitRunner(wrapping: UnreachableGitRunner()) { _, _ in
            .timeout
        }
        let outcome = await perform(
            item(plan), plan: plan,
            with: makePerformer(runner: runner, measure: spy.measure)
        )
        XCTAssertEqual(spy.measuredURLs.count, 1, "the measurement DID happen")
        XCTAssertNil(outcome.entry, "an aborted removal accepts nothing")
    }

    // MARK: - Argv provenance & budgets

    func testTheDeleteTimeBudgetIsPassedPerInvocationAndIsInjectable()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let runner = InterceptingGitRunner(wrapping: realRunner())
        _ = await perform(
            item(plan), plan: plan,
            with: makePerformer(runner: runner, gitTimeout: 42)
        )
        XCTAssertGreaterThan(runner.timeouts.count, 4)
        XCTAssertEqual(
            runner.timeouts,
            Array(repeating: 42, count: runner.argvs.count),
            "every delete-time invocation carries the injected budget — "
                + "including every gate re-establishment invocation"
        )
    }


    func testTheArgvBuildersCarryNoForceAndNoBranchDeletionEver() {
        // The Boundaries, asserted on the BUILDERS themselves so a future
        // edit cannot slip a flag past the fixtures that happen to run.
        let parent = URL(fileURLWithPath: "/dev/repo")
        let worktree = URL(fileURLWithPath: "/dev/wt")
        // THERE IS NO MUTATING BUILDER LEFT (PR #460 codex r5 / D1).
        // `removeArguments` was the last one; the checkout and the admin
        // directories are removed by this process, and `git worktree prune`
        // never existed here because it recomputes its own set after every
        // gate has answered.
        let readOnly = [
            WorktreeReclaimPerformer.commonGitDirArguments(
                parentRepoWorkingDir: parent
            ),
            GitWorktreeMergedCheck.originHeadArguments(parentRepoWorkingDir: parent),
            GitWorktreeMergedCheck.verifyRefArguments(
                parentRepoWorkingDir: parent, ref: "refs/heads/main"
            ),
            GitWorktreeMergedCheck.ancestryArguments(
                worktreeAt: worktree, defaultRef: "refs/heads/main"
            ),
            GitWorktreeCleanCheck.arguments(forWorktreeAt: worktree),
        ]
        for argv in readOnly {
            XCTAssertFalse(argv.contains("--force"))
            XCTAssertFalse(argv.contains("-f"))
            XCTAssertFalse(argv.contains("branch"))
            XCTAssertFalse(argv.contains("-d"))
            XCTAssertFalse(argv.contains("-D"))
            XCTAssertFalse(argv.contains("prune"), "\(argv)")
            XCTAssertFalse(argv.contains("remove"), "\(argv)")
            XCTAssertEqual(GitSafetyProfile.classify(argv), .readOnly, "\(argv)")
        }
        XCTAssertEqual(
            GitSafetyProfile.classify(
                GitWorktreeOracle.listArguments(forRepositoryAt: parent)
            ),
            .readOnly
        )
    }
}

/// A thread-safe call counter for interception closures — a `@Sendable`
/// closure may not capture a mutable local.
final class GitCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    var observed: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// An ordered event log shared by the sizer seam and the runner double.
final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    func record(_ event: String) {
        lock.lock(); recorded.append(event); lock.unlock()
    }
}

/// A trash seam that records instead of trashing.
/// Measures how long a block enqueued on a queue waits before it STARTS —
/// the queue's depth at that instant, and the witness that a load fixture
/// actually loaded something (PR #460 codex r7, D1).
final class QueueDelayWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var waited: UInt64?

    func arm(on queue: DispatchQueue) {
        let enqueued = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            if waited == nil, started >= enqueued { waited = started - enqueued }
            lock.unlock()
        }
    }

    var milliseconds: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let waited else { return nil }
        return Double(waited) / 1_000_000
    }

    /// The witness is enqueued BEHIND the load, so it can still be waiting
    /// when the measured removal has already finished. Bounded, and it
    /// returns nil rather than hanging if the block never runs.
    func settled(within seconds: Double = 5) -> Double? {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(seconds * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let value = milliseconds { return value }
            usleep(2000)
        }
        return milliseconds
    }
}

final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    func record(_ url: URL) {
        lock.lock(); recorded.append(url); lock.unlock()
    }
}

// MARK: - Doubles

/// Wraps a REAL runner and answers only the invocations a test names —
/// everything else executes for real. Through r4 this was how a cell injected
/// a failing `worktree remove` to reach the fallback arm; that arm and that
/// argv are both gone (PR #460 codex r5), so what it synthesises now is a
/// READ-ONLY gate's failure — a timeout, a nonzero exit, an unavailable git —
/// while the rest of the sequence stays genuine.
///
/// The `intercept` closure also runs BEFORE the delegated call, so a test can
/// mutate the filesystem in the window between two git invocations — that is
/// the round-6 symlink-swap window cell.
final class InterceptingGitRunner: GitCommandRunning, @unchecked Sendable {

    /// `(arguments, oneBasedCallIndex) -> scripted outcome, or nil to delegate`.
    typealias Interception = @Sendable ([String], Int) -> GitCommandOutcome?

    private let wrapped: any GitCommandRunning
    private let intercept: Interception
    private let lock = NSLock()
    private var recorded: [GitCommandInvocation] = []
    private var recordedTimeouts: [TimeInterval] = []
    private var calls = 0

    init(
        wrapping wrapped: any GitCommandRunning,
        intercept: @escaping Interception = { _, _ in nil }
    ) {
        self.wrapped = wrapped
        self.intercept = intercept
    }

    var defaultTimeout: TimeInterval { wrapped.defaultTimeout }

    var invocations: [GitCommandInvocation] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var timeouts: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return recordedTimeouts
    }

    /// The argv of every recorded invocation, minus the runner's own
    /// `git -c core.fsmonitor=false` prefix.
    var argvs: [[String]] { invocations.map(\.argv) }

    func run(_ arguments: [String], timeout: TimeInterval) async -> GitCommandInvocation {
        lock.lock()
        calls += 1
        let index = calls
        recordedTimeouts.append(timeout)
        lock.unlock()

        let invocation: GitCommandInvocation
        if let scripted = intercept(arguments, index) {
            // Profile and argv come from PRODUCTION assembly rules, so a
            // scripted invocation still records what the runner would have
            // classified and passed. The environment is left empty on this
            // path deliberately — env assertions belong to the delegated
            // (real) invocations, never to a fabricated record.
            invocation = GitCommandInvocation(
                profile: GitSafetyProfile.classify(arguments),
                argv: ["git", "-c", GitCommandRunner.fsmonitorNeutralization]
                    + arguments,
                environment: [:],
                outcome: scripted
            )
        } else {
            invocation = await wrapped.run(arguments, timeout: timeout)
        }
        lock.lock()
        recorded.append(invocation)
        lock.unlock()
        return invocation
    }
}

/// A runner that must never be reached — the delegate for fully-scripted
/// cells, so an unintended real git call is a test failure rather than a
/// silent success.
struct UnreachableGitRunner: GitCommandRunning {
    var defaultTimeout: TimeInterval { GitCommandRunner.scanTimeout }
    func run(_ arguments: [String], timeout _: TimeInterval) async -> GitCommandInvocation {
        XCTFail("a fully-scripted cell reached real git: \(arguments)")
        return GitCommandInvocation(
            profile: .mutation, argv: arguments, environment: [:],
            outcome: .gitUnavailable
        )
    }
}

/// Records every `DirectorySizer` call the performer makes. The
/// ADMIT-BEFORE-MEASURE proof is "this recorded nothing".
final class SizerSpy: @unchecked Sendable {

    private let lock = NSLock()
    private var recorded: [(url: URL, mode: String)] = []
    private let stub: @Sendable (URL) -> SizeReport

    init(stub: @escaping @Sendable (URL) -> SizeReport = { _ in SizeReport() }) {
        self.stub = stub
    }

    var measuredURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return recorded.map(\.url)
    }

    var measuredModes: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded.map(\.mode)
    }

    func measure(
        _ url: URL, _ mode: DirectorySizer.Mode,
        _ known: Set<FileSystemIdentityProvider.Identity>
    ) -> SizeReport {
        _ = known
        let label: String
        switch mode {
        case .scanRoot: label = "scanRoot"
        case .deletionTarget: label = "deletionTarget"
        }
        lock.lock()
        recorded.append((url, label))
        lock.unlock()
        return stub(url)
    }
}

/// A provider whose `identity(of:)` fails for ONE directory — the TOCTOU the
/// `worktree-identity-unreadable` refusal exists for.
///
/// `identity(of:)` is `FileSystemIdentityProvider`'s documented override
/// point; nothing else is overridden, so `probeKind`, `canonicalize` and the
/// descriptor family all answer for real. The match is by NAME rather than by
/// absolute path because the resolver hands back a CANONICALIZED URL, which on
/// macOS differs from the fixture's spelling by the `/private` prefix.
final class IdentityBlindProvider: FileSystemIdentityProvider, @unchecked Sendable {
    private let directoryName: String
    private let containerName: String
    private let lock = NSLock()
    private var blinded = 0

    /// How many times the blind arm actually fired — asserted, so a cell can
    /// never pass because the double silently matched nothing.
    var blindedReads: Int {
        lock.lock(); defer { lock.unlock() }
        return blinded
    }

    init(blindToDirectoryNamed directoryName: String,
         insideContainerNamed containerName: String) {
        self.directoryName = directoryName
        self.containerName = containerName
        super.init()
    }

    override func identity(of url: URL) -> Identity? {
        if url.lastPathComponent == directoryName,
           url.deletingLastPathComponent().lastPathComponent == containerName {
            lock.lock(); blinded += 1; lock.unlock()
            return nil
        }
        return super.identity(of: url)
    }
}
