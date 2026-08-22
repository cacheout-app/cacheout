import XCTest
@testable import Cacheout

/// fn-5.4 coverage: `WorktreeReclaimPerformer` — the git-mediated reclaim.
///
/// FIXTURE DOCTRINE, inherited from fn-5.1/fn-5.2 and sharpened by the epic's
/// Decision Context:
/// - Real git builds every repository fixture (hermetic env, `GIT_CONFIG_*`
///   pinned to `/dev/null`), and real git executes wherever the behaviour
///   under test IS git's.
/// - The ignored-tree fallback branch is NOT reliably reproducible with real
///   git (2.50.1 removes such worktrees at exit 0; the field failures were on
///   ≤2.39), so every fallback cell INJECTS a failing runner result and
///   asserts NO refusal message and NO version boundary. The populated
///   submodule refusal is the trigger class real git still produces, and it
///   has its own cell.
/// - Injection happens through `InterceptingGitRunner`: one named invocation
///   is answered synthetically, everything else runs for real — so a fallback
///   cell still proves branch-ref survival, real prune behaviour and real
///   porcelain output.
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

    private func staleplan(
        worktree: URL, membership: WorktreeMembership
    ) -> GitWorktreeReclaimPlan {
        .removeStaleWorktree(
            worktreePath: worktree,
            worktreeAdminEntry: membership.parentAdminContainer
                .appendingPathComponent(worktree.lastPathComponent),
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

    private func realRunner() -> GitCommandRunner {
        GitCommandRunner(environment: GitFixture.environment(home: home))
    }

    /// The performer under test, with every seam injectable.
    private func makePerformer(
        runner: any GitCommandRunning,
        measure: ((URL, DirectorySizer.Mode, Set<FileSystemIdentityProvider.Identity>) -> SizeReport)? = nil,
        moveToTrash: Bool = false,
        trash: ((URL) async throws -> URL?)? = nil,
        revalidate: ((ReclaimableItem) -> PreDeleteSeamRefusal?)? = nil,
        gitTimeout: TimeInterval = WorktreeReclaimPerformer.deleteTimeGitTimeout,
        provider overrideProvider: FileSystemIdentityProvider? = nil
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
            trash: trash ?? { url in
                let landed = trashRoot.appendingPathComponent(
                    url.lastPathComponent
                )
                try fileManager.moveItem(at: url, to: landed)
                return landed
            },
            removeTree: { url, _ in try fileManager.removeItem(at: url) },
            revalidate: revalidate ?? { _ in nil },
            logRefusal: { _, _ in },
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

    // MARK: - R5: git removes it, and nothing else runs

    func testCleanMergedWorktreeIsRemovedByGitWithNoPruneAndASurvivingBranch()
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
        XCTAssertNil(entry.warning, "a clean git removal warns about nothing")
        XCTAssertEqual(entry.disposal, .permanent)

        // EXACTLY ONE git invocation: exit 0 means git removed its own admin
        // directory, so no prune is needed — and none may run.
        XCTAssertEqual(runner.argvs.count, 1)
        let removal = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(
            removal.argv,
            ["git", "-c", "core.fsmonitor=false", "-C", repository.path,
             "worktree", "remove", worktree.path]
        )
        // D17, on a REAL invocation: `worktree remove` is the MUTATION
        // profile — fsmonitor neutralized on argv, optional locks NOT
        // disabled (a mutation needs real locking).
        XCTAssertEqual(removal.profile, .mutation)
        XCTAssertNil(removal.environment[GitCommandRunner.optionalLocksVariable])
        // The DELETE-TIME budget, not fn-5.1's scan default.
        XCTAssertEqual(runner.timeouts, [WorktreeReclaimPerformer.deleteTimeGitTimeout])
        XCTAssertNotEqual(
            WorktreeReclaimPerformer.deleteTimeGitTimeout,
            GitCommandRunner.scanTimeout
        )
        assertNoForbiddenArgv(runner)
    }

    func testGitRemovalEntryStaysPermanentInATrashRun() async throws {
        // D16: git unlinks the tree regardless of the Move-to-Trash toggle,
        // so the entry must not promise the bytes are recoverable from the
        // Trash — and the trash seam must never be called.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let trashed = TrashRecorder()
        let performer = makePerformer(
            runner: InterceptingGitRunner(wrapping: realRunner()),
            moveToTrash: true,
            trash: { url in
                trashed.record(url)
                return nil
            }
        )
        let outcome = await perform(item(plan), plan: plan, with: performer)

        let entry = try XCTUnwrap(outcome.entry)
        XCTAssertEqual(entry.disposal, .permanent)
        XCTAssertTrue(trashed.urls.isEmpty,
                      "git removal must never route through the trash seam")
        XCTAssertFalse(fm.fileExists(atPath: worktree.path))
    }

    // MARK: - R5: four-class routing at the REMOVE call

    func testRemoveTimeoutAbortsWithoutFallbackAndWithoutAcceptingClaims()
        async throws
    {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let runner = InterceptingGitRunner(wrapping: UnreachableGitRunner()) { arguments, _ in
            XCTAssertTrue(arguments.contains("remove"),
                          "nothing may run after a removal timeout: \(arguments)")
            return .timeout
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.entry, "a timeout accepts no claims and reports no bytes")
        let message = try XCTUnwrap(outcome.errors.first?.message)
        XCTAssertTrue(message.contains("may be partially removed"), message)
        XCTAssertTrue(message.contains("rescan"), message)
        // NEVER the fallback: exactly one invocation, and the tree survives.
        XCTAssertEqual(runner.argvs.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }

    func testGitUnavailableAtRemoveRefusesFailClosedAndExecutesNothingElse()
        async throws
    {
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
        XCTAssertTrue(message.contains("git is unavailable at clean time"), message)
        XCTAssertEqual(runner.argvs.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }

    func testNonZeroExitIsTheOnlyClassThatReachesTheReCheck() async throws {
        // The trigger is the CLASS, never a message match: this injected
        // stderr is deliberately not a git string anyone parses.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            arguments.contains("remove")
                ? .failure(exitCode: 128, stderr: "fixture refusal, class only")
                : nil
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.errors.first?.message, "the fallback should have run")
        XCTAssertNotNil(outcome.entry)
        // remove → status re-check → oracle recompute → prune.
        let commands = runner.argvs.map { argv in argv.filter { !$0.hasPrefix("-") } }
        XCTAssertEqual(commands.count, 4, "\(runner.argvs)")
        XCTAssertTrue(runner.argvs[1].contains("status"))
        XCTAssertTrue(runner.argvs[2].contains("list"))
        XCTAssertTrue(runner.argvs[3].contains("prune"))
        assertNoForbiddenArgv(runner)
    }

    // MARK: - R5: the guarded fallback + the GATED prune

    func testInjectedRemoveFailureFallsBackToAGuardedDeleteAndAGatedPrune()
        async throws
    {
        // The field class (ignored trees) is NOT reproducible on this git, so
        // the refusal is INJECTED — no message and no version is asserted.
        // Everything else runs for real: the re-check, the oracle, the prune,
        // and the branch-ref survival check.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let membership = try membership(of: worktree, in: repository)
        let adminEntry = membership.parentAdminContainer
            .appendingPathComponent("wt")
        let plan = staleplan(worktree: worktree, membership: membership)

        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            arguments.contains("remove")
                ? .failure(exitCode: 128, stderr: "injected refusal")
                : nil
        }
        let report = await makeCleaner(runner: runner)
            .clean(items: [item(plan)], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errorLines)")
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertGreaterThan(entry.exactBytes, 40_000)
        XCTAssertNil(entry.warning,
                     "the gated prune ran, so nothing was left behind")
        XCTAssertEqual(entry.disposal, .permanent)

        XCTAssertFalse(fm.fileExists(atPath: worktree.path))
        XCTAssertFalse(fm.fileExists(atPath: adminEntry.path),
                       "the gated prune must have cleaned the registry")
        XCTAssertEqual(try porcelainRecordCount(of: repository), 1)
        XCTAssertTrue(try branchExists("feature", in: repository),
                      "a reclaim must never take the branch with it")

        let pruneArgv = try XCTUnwrap(
            runner.argvs.first { $0.contains("prune") }
        )
        XCTAssertEqual(
            pruneArgv,
            ["git", "-c", "core.fsmonitor=false", "-C", repository.path,
             "worktree", "prune", "--expire=now"]
        )
        assertNoForbiddenArgv(runner)
    }

    func testFallbackEntryIsTrashOnlyWhenTheTrashHandlerActuallySucceeded()
        async throws
    {
        // D16, both directions, plus the R11 rule that a trash FAILURE is an
        // error and never falls through to a permanent delete.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        let failing = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            arguments.contains("remove")
                ? .failure(exitCode: 128, stderr: "injected refusal")
                : nil
        }

        // (a) the trash handler FAILS: per-item error, tree untouched.
        let refused = await perform(
            item(plan), plan: plan,
            with: makePerformer(
                runner: failing, moveToTrash: true,
                trash: { _ in
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

    func testTheFallbackRefusesATrashDisposalItCannotProveTookTheWorktree()
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
        let failing = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            arguments.contains("remove")
                ? .failure(exitCode: 128, stderr: "injected refusal")
                : nil
        }

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
                trash: { url in
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

    /// Reports NO identity for any DESCRIPTOR — the "I opened the folder but
    /// cannot prove which folder it is" case.
    private final class UnprovableDescriptorProvider: FileSystemIdentityProvider {
        override func identity(ofDescriptor fd: Int32) -> Identity? { nil }
    }

    func testTheFallbackRefusesWhenItCannotBindTheFolderItWouldDeleteIn()
        async throws
    {
        // fn-6 RECONCILIATION, and the cell that EVIDENCES the binding.
        //
        // fn-6's removal proves the folder it opens against an identity the
        // caller captured from a descriptor first, so this fallback captures
        // one before its TOCTOU rechecks. Handing `.unbound` instead still
        // compiles and still deletes — measured: replacing the capture with
        // `.unbound` left the whole suite green at 1418/2/0 — so without this
        // cell the binding is a parameter nobody checks.
        //
        // The capture is the fallback's FIRST descriptor-identity call (the
        // gates before it are path-based), so a provider that can prove no
        // descriptor makes exactly that capture fail and nothing else.
        // FAIL-CLOSED is the assertion: the reclaim reports an error and the
        // worktree is still on disk. Under `.unbound` nothing throws, the
        // removal runs, and the existence check below goes red.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let plan = staleplan(
            worktree: worktree, membership: try membership(of: worktree, in: repository)
        )
        // git refuses `remove`, which is what routes this item to the
        // filesystem fallback in the first place.
        let failing = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            arguments.contains("remove")
                ? .failure(exitCode: 128, stderr: "injected refusal")
                : nil
        }

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
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            arguments.contains("remove")
                ? .failure(exitCode: 128, stderr: "injected refusal")
                : nil
        }
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
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            if arguments.contains("remove") {
                return .failure(exitCode: 128, stderr: "injected refusal")
            }
            if arguments.contains("prune") {
                return .failure(exitCode: 3, stderr: "fatal: prune exploded")
            }
            return nil
        }
        let report = await makeCleaner(runner: runner)
            .clean(items: [item(plan)], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty,
                      "a post-delete prune failure is NEVER an ItemError")
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertGreaterThan(entry.bytesFreed, 0)
        let warning = try XCTUnwrap(entry.warning)
        XCTAssertTrue(warning.contains("git exit 3"), warning)
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
            let runner = InterceptingGitRunner(
                wrapping: UnreachableGitRunner()
            ) { arguments, _ in
                arguments.contains("remove")
                    ? .failure(exitCode: 128, stderr: "injected refusal")
                    : scripted
            }
            let outcome = await perform(
                item(plan), plan: plan, with: makePerformer(runner: runner)
            )
            XCTAssertNil(outcome.entry, name)
            let message = try XCTUnwrap(outcome.errors.first?.message, name)
            XCTAssertTrue(message.contains("could not prove it clean"),
                          "\(name): \(message)")
            XCTAssertTrue(message.contains(fragment), "\(name): \(message)")
            XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                          "\(name): the tree must survive")
            XCTAssertEqual(runner.argvs.count, 2,
                           "\(name): nothing may run after the abort")
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
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            arguments.contains("remove")
                ? .failure(exitCode: 128, stderr: "injected refusal")
                : nil
        }
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
                parentRepoWorkingDir: outside,
                parentAdminContainer: real.parentAdminContainer,
                disclosedAdminDirectories: []
            )),
            ("parentAdminContainer outside", GitWorktreeReclaimPlan(
                mode: .removeStaleWorktree, worktreePath: worktree,
                worktreeAdminEntry: real.parentAdminContainer
                    .appendingPathComponent("wt"),
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

    func testTheGuardReRunsBetweenAdmissionAndTheRemoveInvocation() async throws {
        // The audit says "immediately before EVERY invocation", so a swap in
        // the window between admission and `worktree remove` — here, during
        // the measurement walk — must still be caught.
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

    func testTheAdminContainerSwappedInsideTheReCheckWindowIsRefused()
        async throws
    {
        // ROUND 6, the window cell: `git -C <wt> status` follows `<wt>/.git`
        // INTO the admin container, so the re-check guards BOTH — and the
        // swap here happens between the remove failure and the status call,
        // the one window an admission-time-only guard would miss.
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", branch: "feature", in: repository)
        let membership = try membership(of: worktree, in: repository)
        let plan = staleplan(worktree: worktree, membership: membership)
        let outside = try makeOutsideRepository()
        let adminContainer = membership.parentAdminContainer

        let fileManager = fm
        let runner = InterceptingGitRunner(
            wrapping: UnreachableGitRunner()
        ) { arguments, _ in
            guard arguments.contains("remove") else {
                XCTFail("the re-check must never have executed: \(arguments)")
                return .gitUnavailable
            }
            // THE WINDOW: after git refused, before the re-check runs.
            try? fileManager.removeItem(at: adminContainer)
            try? fileManager.createSymbolicLink(
                at: adminContainer, withDestinationURL: outside
            )
            return .failure(exitCode: 128, stderr: "injected refusal")
        }
        let outcome = await perform(
            item(plan), plan: plan, with: makePerformer(runner: runner)
        )

        XCTAssertNil(outcome.entry)
        XCTAssertTrue(
            try XCTUnwrap(outcome.errors.first?.message)
                .contains("not a real directory")
        )
        XCTAssertEqual(runner.argvs.count, 1,
                       "only the removal ran; the re-check was refused")
        XCTAssertTrue(fm.fileExists(atPath: worktree.path),
                      "the tree survives a refused re-check")
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
        XCTAssertEqual(runner.argvs.count, 1)
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

    // MARK: - R5: the second named fallback trigger class (D4)

    func testAPopulatedSubmoduleWorktreeFallsBackWithTheParentStoreIntact()
        async throws
    {
        // The trigger class real git still produces: `validate_no_submodules`
        // refuses a CLEAN worktree containing a populated submodule without
        // `--force`. The re-check passes and the fallback delete is ACCEPTED
        // (user-owned dev roots; the parent's absorbed `modules/` object store
        // is untouched and the branch ref survives).
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
        // git DID refuse first — the fallback is what deleted the tree.
        let removal = try XCTUnwrap(
            runner.invocations.first { $0.argv.contains("remove") }
        )
        if case .success = removal.outcome {
            XCTFail("this git removed a populated-submodule worktree at exit 0")
        }
        assertNoForbiddenArgv(runner)
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

    func testFreshOrphansAreActuallyRemovedByTheExecutionPrune() async throws {
        let fixture = try makePruneFixture(orphans: ["gone"])
        let orphan = fixture.admin[0]
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

        // `--expire=now` on EVERY execution prune, and the mutation profile.
        let prunes = runner.invocations.filter { $0.argv.contains("prune") }
        XCTAssertEqual(prunes.count, 1)
        for prune in prunes {
            XCTAssertTrue(prune.argv.contains("--expire=now"), "\(prune.argv)")
            XCTAssertEqual(prune.profile, .mutation)
            XCTAssertNil(prune.environment[GitCommandRunner.optionalLocksVariable])
            XCTAssertTrue(prune.argv.contains("core.fsmonitor=false"))
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
            membership: fixture.membership, disclosed: [fixture.admin[0]]
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
        // Verified-removal accounting: a scripted exit 0 that removed nothing
        // accepts nothing — and STILL reports a row, never a silent success.
        let fixture = try makePruneFixture(orphans: ["gone"])
        let orphan = fixture.admin[0]
        let plan = prunePlan(membership: fixture.membership, disclosed: [orphan])
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            arguments.contains("prune") ? .success(stdout: Data()) : nil
        }
        let outcome = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(runner: runner)
        )

        XCTAssertTrue(outcome.errors.isEmpty)
        let entry = try XCTUnwrap(outcome.entry, "a row is mandatory at exit 0")
        XCTAssertEqual(entry.bytesFreed, 0,
                       "a directory still on disk was not freed")
        XCTAssertTrue(fm.fileExists(atPath: orphan.path))
    }

    func testEveryFailingPruneClassIsAnErrorAndNeverAWarning() async throws {
        let cases: [(name: String, outcome: GitCommandOutcome, fragment: String)] = [
            ("nonzero", .failure(exitCode: 9, stderr: "fatal: prune refused"),
             "git exit 9"),
            ("timeout", .timeout,
             "prune timed out; the registry may be PARTIALLY cleaned — rescan required"),
            ("unavailable", .gitUnavailable, "git unavailable at clean time"),
        ]
        for (name, scripted, fragment) in cases {
            // Each case gets its OWN repository, worktree and orphan names —
            // a shared fixture would leave the previous iteration's worktree
            // paths behind and make `worktree add` fail.
            let fixture = try makePruneFixture(orphans: ["gone-\(name)"], suffix: "-\(name)")
            let orphan = fixture.admin[0]
            let plan = prunePlan(membership: fixture.membership, disclosed: [orphan])
            let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
                arguments.contains("prune") ? scripted : nil
            }
            let outcome = await perform(
                item(plan, id: "prune"), plan: plan,
                with: makePerformer(runner: runner)
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
        let disclosed = fixture.admin[0]
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
        let disclosed = fixture.admin[0]
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
        let orphan = fixture.admin[0]
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

    func testASurvivingDisclosedEntryNeverReportsItsBytesAsFreed() async throws {
        // The disclosed-set-SHRINKS fixture: one disclosed entry became
        // LOCKED since the scan, so git's prune skips it. The item still
        // executes over the recomputed subset, and the survivor's bytes are
        // NOT reported freed (verified-removal accounting).
        let fixture = try makePruneFixture(orphans: ["gone", "locked"])
        let swept = fixture.admin[0]
        let survivor = fixture.admin[1]
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
                      "a locked admin dir survives git's own prune")
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
            try XCTUnwrap(staleRunner.argvs.first)[4], bare.path,
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
        let pruneArgv = try XCTUnwrap(
            pruneRunner.argvs.first { $0.contains("prune") }
        )
        XCTAssertEqual(pruneArgv[4], bare.path)
        XCTAssertTrue(pruneArgv.contains("--expire=now"))
        assertNoForbiddenArgv(pruneRunner)
    }

    func testNoProductionPathEverRemovesAnAdminDirectoryDirectly() async throws {
        // The prune tier mutates the registry ONLY through git — a direct rm
        // would bypass git's own bookkeeping (an alternative the epic
        // explicitly rejected). Proof: with EVERY git call scripted away, the
        // admin directories are still on disk afterwards.
        let fixture = try makePruneFixture(orphans: ["gone"])
        let orphan = fixture.admin[0]
        let plan = prunePlan(membership: fixture.membership, disclosed: [orphan])
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            arguments.contains("prune") ? .success(stdout: Data()) : nil
        }
        _ = await perform(
            item(plan, id: "prune"), plan: plan,
            with: makePerformer(runner: runner)
        )
        XCTAssertTrue(
            fm.fileExists(atPath: orphan.path),
            "with the prune subprocess stubbed out, nothing else may delete it"
        )
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
                membership: fixture.membership, disclosed: [fixture.admin[0]]
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
            membership: fixture.membership, disclosed: [fixture.admin[0]]
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
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            timeline.record("git:\(arguments.contains("remove") ? "remove" : "other")")
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

        XCTAssertEqual(timeline.events, ["measure", "git:remove"],
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
        let runner = InterceptingGitRunner(wrapping: realRunner()) { arguments, _ in
            arguments.contains("remove")
                ? .failure(exitCode: 128, stderr: "injected refusal")
                : nil
        }
        _ = await perform(
            item(plan), plan: plan,
            with: makePerformer(runner: runner, gitTimeout: 42)
        )
        XCTAssertEqual(runner.timeouts, [42, 42, 42, 42],
                       "every delete-time invocation carries the injected budget")
    }

    func testTheArgvBuildersCarryNoForceAndNoBranchDeletionEver() {
        // The Boundaries, asserted on the BUILDERS themselves so a future
        // edit cannot slip a flag past the fixtures that happen to run.
        let parent = URL(fileURLWithPath: "/dev/repo")
        let worktree = URL(fileURLWithPath: "/dev/wt")
        let remove = WorktreeReclaimPerformer.removeArguments(
            parentRepoWorkingDir: parent, worktreePath: worktree
        )
        let prune = WorktreeReclaimPerformer.pruneArguments(
            parentRepoWorkingDir: parent
        )
        XCTAssertEqual(remove, ["-C", "/dev/repo", "worktree", "remove", "/dev/wt"])
        XCTAssertEqual(
            prune, ["-C", "/dev/repo", "worktree", "prune", "--expire=now"]
        )
        for argv in [remove, prune] {
            XCTAssertFalse(argv.contains("--force"))
            XCTAssertFalse(argv.contains("-f"))
            XCTAssertFalse(argv.contains("branch"))
            XCTAssertFalse(argv.contains("-d"))
            XCTAssertFalse(argv.contains("-D"))
        }
        // Both are MUTATIONS by D17 classification; the oracle listing is not.
        XCTAssertEqual(GitSafetyProfile.classify(remove), .mutation)
        XCTAssertEqual(GitSafetyProfile.classify(prune), .mutation)
        XCTAssertEqual(
            GitSafetyProfile.classify(
                GitWorktreeOracle.listArguments(forRepositoryAt: parent)
            ),
            .readOnly
        )
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
/// everything else executes for real. This is how a fallback cell injects a
/// failing `worktree remove` while the re-check, the oracle and the prune stay
/// genuine (the epic forbids relying on git to produce the refusal).
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
