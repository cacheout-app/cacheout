/// # GitWorktreeEndToEndTests — fn-5.6 (R11), the epic's closing acceptance
///
/// Everything here drives the REAL `SpaceScannerRuntime.production(...)`
/// composition. Registering a scanner is supposed to be the ONLY step, so the
/// proof that it was has to run through the same factory the GUI and the CLI
/// call — not through a hand-assembled runtime that could quietly disagree
/// with production.
///
/// 1. **Registration** — `git_worktrees` is in the production registry, its
///    declared dev roots are in the runtime's container-root union (which is
///    what extends DELETE-TIME admission), and the composition holds exactly
///    ONE git runner: the SAME instance detects composite items and executes
///    them. fn-5.1's `git --version` availability verdict is instance-cached,
///    so a second runner would let the scan and the clean disagree about
///    whether git exists at all.
/// 2. **Scan → select → clean → report** over the three-worktree fixture: a
///    merged-clean worktree under a HIDDEN parent (the field case), a DIRTY
///    worktree that is assessed and then omitted (D15), and a manually
///    deleted checkout that becomes the repository-level prune item.
/// 3. **The wire** — the CLI's `--confirm` gate over the slug, and the
///    `tool_unavailable` `scanner_errors` row's shape on the actual envelope.
/// 4. **The grep gates** — read over the production source tree: one
///    oracle→admin mapping implementation with both call sites, no
///    `<wd>/.git/worktrees` reconstruction, no `--force`, no branch deletion,
///    NO repository-wide `worktree prune` argv anywhere (the expire override
///    now rides the oracle listing instead), and no git execution outside
///    `GitCommandRunner`.
///
/// HERMETIC BY CONSTRUCTION: the git runner is injected into `production()`
/// with `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` pinned to `/dev/null` and an
/// injected HOME, so no scan or clean in this file can read the developer's
/// real git configuration — a system-level `status.showUntrackedFiles=no`
/// would otherwise decide the G2 gate. `production()`'s own default still
/// builds the one production runner; the parameter only substitutes WHICH one.

import XCTest
@testable import Cacheout

final class GitWorktreeEndToEndTests: XCTestCase {

    private var base: URL!
    /// The injected fixture home — zero real-`$HOME` reads.
    private var home: URL!
    /// The declared dev root every fixture repository lives under.
    private var dev: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("GitWorktreeEndToEnd-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        dev = base.appendingPathComponent("dev")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: dev, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
    }

    // MARK: - Fixture

    /// The dev-root resolution `production()` receives — invocation-scoped,
    /// exactly as `--dev-root` supplies it, so nothing here touches
    /// `UserDefaults` or the persisted store.
    private func devRoots() -> DevRootsResolution {
        DevRootsResolution(keptRoots: [dev], issues: [])
    }

    private func hermeticRunner() -> InterceptingGitRunner {
        InterceptingGitRunner(
            wrapping: GitCommandRunner(
                environment: GitFixture.environment(home: home)
            )
        )
    }

    /// THE production composition, with the hermetic runner substituted for
    /// the one `production()` would otherwise build.
    private func productionRuntime(
        runner: any GitCommandRunning
    ) -> SpaceScannerRuntime {
        SpaceScannerRuntime.production(
            home: home, devRoots: devRoots(), gitRunner: runner
        )
    }

    /// A repository whose committed `.gitignore` hides fixture payloads, so a
    /// worktree can carry measurable bytes and still be status-CLEAN.
    @discardableResult
    private func makeRepository(at url: URL) throws -> URL {
        try GitFixture.makeRepository(at: url, home: home)
        try "payload.bin\n".write(
            to: url.appendingPathComponent(".gitignore"),
            atomically: true, encoding: .utf8
        )
        try GitFixture.git(["-C", url.path, "add", ".gitignore"], home: home)
        try GitFixture.git(
            ["-C", url.path, "-c", "user.name=t", "-c", "user.email=t@t",
             "commit", "-m", "ignore"],
            home: home
        )
        return url
    }

    /// `git worktree add`: HEAD equals the default branch tip, so G3 passes
    /// and the tree is clean — the ordinary CANDIDATE shape.
    @discardableResult
    private func addWorktree(
        of repository: URL, at path: URL, branch: String, payloadBytes: Int = 8192
    ) throws -> URL {
        try fm.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let added = try GitFixture.git(
            ["-C", repository.path, "worktree", "add", path.path, "-b", branch],
            home: home
        )
        XCTAssertEqual(added.status, 0, "git worktree add failed at \(path.path)")
        if payloadBytes > 0 {
            try Data(repeating: 0xAB, count: payloadBytes)
                .write(to: path.appendingPathComponent("payload.bin"))
        }
        return path
    }

    /// The three-worktree field fixture, in one repository:
    ///
    /// - `.worktrees/merged` — clean, merged, under a HIDDEN parent (the 23 GB
    ///   field case: hidden directories are exactly where these accumulate);
    /// - `dirty` — an UNTRACKED file makes G2 fail, so it is assessed and then
    ///   omitted from items entirely (D15);
    /// - `gone` — added and then deleted from disk, leaving the registered
    ///   checkout prunable: the repository-level prune tier.
    private struct Fixture {
        let repository: URL
        let merged: URL
        let dirty: URL
        let gone: URL
    }

    private func makeThreeWorktreeFixture() throws -> Fixture {
        let repository = try makeRepository(at: dev.appendingPathComponent("repo"))
        let merged = try addWorktree(
            of: repository,
            at: dev.appendingPathComponent(".worktrees/merged"),
            branch: "merged"
        )
        let dirty = try addWorktree(
            of: repository, at: dev.appendingPathComponent("dirty"), branch: "dirty"
        )
        // NOT ignored by `.gitignore` — an untracked file git will report.
        try Data(repeating: 0xCD, count: 128)
            .write(to: dirty.appendingPathComponent("uncommitted-work.txt"))
        let gone = try addWorktree(
            of: repository, at: dev.appendingPathComponent("gone"), branch: "gone"
        )
        try fm.removeItem(at: gone)
        return Fixture(
            repository: repository, merged: merged, dirty: dirty, gone: gone
        )
    }

    // MARK: - Helpers

    private func identityPath(_ url: URL) -> String {
        FileSystemIdentityProvider().resolveTargetKeepingLeaf(url).path
    }

    private func plan(
        of item: ReclaimableItem, file: StaticString = #filePath, line: UInt = #line
    ) throws -> GitWorktreeReclaimPlan {
        guard case .gitWorktreeReclaim(let plan) = item.action else {
            XCTFail("item action is '\(item.action.wireString)', not "
                        + "git_worktree_reclaim", file: file, line: line)
            throw CocoaError(.featureUnsupported)
        }
        return plan
    }

    private func item(
        _ items: [ReclaimableItem], mode: GitWorktreeReclaimPlan.Mode,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ReclaimableItem {
        let matching = try items.filter { try plan(of: $0).mode == mode }
        guard matching.count == 1 else {
            XCTFail("expected exactly one \(mode) item, found \(matching.count)",
                    file: file, line: line)
            throw CocoaError(.featureUnsupported)
        }
        return try XCTUnwrapElement(matching, 0)
    }

    /// `git worktree list --porcelain` through the FIXTURE git (never the code
    /// under test) — the independent oracle for "the registry is clean".
    private func worktreeListing(of repository: URL) throws -> String {
        let listed = try GitFixture.git(
            ["-C", repository.path, "worktree", "list", "--porcelain"], home: home
        )
        XCTAssertEqual(listed.status, 0)
        return String(decoding: listed.stdout, as: UTF8.self)
    }

    private func branches(of repository: URL) throws -> Set<String> {
        let listed = try GitFixture.git(
            ["-C", repository.path, "branch", "--format=%(refname:short)"],
            home: home
        )
        XCTAssertEqual(listed.status, 0)
        return Set(
            String(decoding: listed.stdout, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    // ====================================================================
    // MARK: - R11: registration at the single production site
    // ====================================================================

    func testProductionRegistersTheScannerAndExtendsDeleteTimeAdmission() throws {
        let runner = hermeticRunner()
        let runtime = productionRuntime(runner: runner)

        XCTAssertEqual(
            runtime.scanners.map(\.id),
            [
                CategoryScanner.registeredID,
                BuildArtifactsScanner.registeredID,
                OrphanedCachesScanner.registeredID,
                GitWorktreeScanner.registeredID,
                EphemeralTempScanner.registeredID,
            ],
            "the single production registry, with git_worktrees registered "
                + "ahead of fn-6's ephemeral_tmp"
        )
        let scanner = try XCTUnwrap(
            runtime.scanners.compactMap { $0 as? GitWorktreeScanner }.first
        )
        XCTAssertEqual(scanner.trustedContainerRoots.map(\.path), [dev.path],
                       "the effective dev roots reach the scanner unchanged")
        // Registration ALONE is what extends delete-time container admission
        // (R4) — items can never widen it.
        XCTAssertTrue(runtime.trustedContainerRoots.contains { $0.path == dev.path })
        // …and the runtime hands its cleaners the SAME runner instance the
        // scanner detects with.
        XCTAssertTrue((runtime.gitRunner as? InterceptingGitRunner) === runner,
                      "the composition holds exactly one git runner")
    }

    /// The single-runner guarantee, proven BEHAVIOURALLY rather than by
    /// identity alone: one injected instance sees the scan's read-only oracle
    /// listing AND the clean's mutation. A second runner anywhere would fork
    /// fn-5.1's instance-scoped availability cache.
    @MainActor
    func testOneRunnerInstanceServesBothDetectionAndExecution() async throws {
        let fixture = try makeThreeWorktreeFixture()
        let runner = hermeticRunner()
        let viewModel = CacheoutViewModel(runtime: productionRuntime(runner: runner))

        await viewModel.scan(
            trigger: .userInitiated, scannerIDs: [GitWorktreeScanner.registeredID]
        )
        let listedDuringScan = runner.invocations.filter { $0.argv.contains("list") }
        XCTAssertFalse(listedDuringScan.isEmpty,
                       "the scan's oracle listing rode the injected runner")

        let stale = try item(
            viewModel.items(forScanner: GitWorktreeScanner.registeredID),
            mode: .removeStaleWorktree
        )
        viewModel.moveToTrash = false
        viewModel.toggleSelection(for: stale.key)
        await viewModel.clean()

        // The clean's OWN delete-time gates rode the same instance. There is
        // no mutating git argv to look for since r5 (D1), so the marker is
        // `rev-parse --git-common-dir`: only the delete path runs it, never
        // the scan.
        XCTAssertTrue(
            runner.invocations.contains { $0.argv.contains("--git-common-dir") },
            "the clean's gates rode the SAME instance: \(runner.argvs)"
        )
        XCTAssertFalse(fm.fileExists(atPath: fixture.merged.path))
    }

    /// THE C1 ACCEPTANCE (PR #460 codex r1), through the production
    /// composition: a DETACHED worktree that was a candidate at scan time,
    /// committed into before the user clicks clean.
    ///
    /// Every later gate the epic already had passes this shape — the tree is
    /// still clean, the record is still registered and unlocked, and the
    /// paths are unmoved. Nothing outside G3 stops it: git would have exited
    /// 0 SILENTLY on this shape when `git worktree remove` was the arm, and
    /// since PR #460 codex r5 no git refusal is consulted at all — the
    /// removal is unconditional once the gates pass. So re-establishing G3 is
    /// the whole protection, and the commit is on no branch, so removal would
    /// leave it reachable from nothing at all.
    @MainActor
    func testACommitMadeBetweenScanAndCleanRefusesTheDetachedRemoval()
        async throws
    {
        let repository = try makeRepository(at: dev.appendingPathComponent("repo"))
        let worktree = dev.appendingPathComponent("detached")
        let added = try GitFixture.git(
            ["-C", repository.path, "worktree", "add", "--detach",
             worktree.path, "HEAD"],
            home: home
        )
        XCTAssertEqual(added.status, 0)
        try Data(repeating: 0xAB, count: 8192)
            .write(to: worktree.appendingPathComponent("payload.bin"))

        let runner = hermeticRunner()
        let viewModel = CacheoutViewModel(runtime: productionRuntime(runner: runner))
        await viewModel.scan(
            trigger: .userInitiated, scannerIDs: [GitWorktreeScanner.registeredID]
        )
        let stale = try item(
            viewModel.items(forScanner: GitWorktreeScanner.registeredID),
            mode: .removeStaleWorktree
        )
        // The scan really did offer it, and its evidence does NOT promise a
        // surviving branch ref for this shape.
        XCTAssertEqual(
            try plan(of: stale).worktreePath.map { identityPath($0) },
            identityPath(worktree)
        )
        XCTAssertFalse(stale.evidence.contains("branch ref survives removal"),
                       stale.evidence)
        XCTAssertTrue(stale.evidence.contains("no branch ref will survive removal"),
                      stale.evidence)

        // ---- THE WINDOW: the user goes back and commits ------------------
        try "precious\n".write(
            to: worktree.appendingPathComponent("precious.txt"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(
            try GitFixture.git(["-C", worktree.path, "add", "precious.txt"],
                               home: home).status, 0
        )
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", worktree.path, "-c", "user.name=t", "-c", "user.email=t@t",
                 "commit", "-m", "precious"], home: home
            ).status, 0
        )
        let precious = String(
            decoding: try GitFixture.git(
                ["-C", worktree.path, "rev-parse", "HEAD"], home: home
            ).stdout, as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // ---- CLEAN -------------------------------------------------------
        viewModel.moveToTrash = false
        viewModel.toggleSelection(for: stale.key)
        await viewModel.clean()

        // (a) the tree — and the commit in it — SURVIVES.
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
        XCTAssertTrue(fm.fileExists(
            atPath: worktree.appendingPathComponent("precious.txt").path
        ))
        XCTAssertEqual(
            String(
                decoding: try GitFixture.git(
                    ["-C", worktree.path, "rev-parse", "HEAD"], home: home
                ).stdout, as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            precious,
            "the commit must still be reachable from the worktree's own HEAD"
        )
        // (b) git was never asked to remove anything.
        XCTAssertNil(runner.argvs.first { $0.contains("remove") }, "\(runner.argvs)")
        // (c) the run reported a REFUSAL, not a success with zero bytes.
        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertTrue(report.entries.isEmpty, "nothing may be reported as freed")
        XCTAssertEqual(report.errors.count, 1, "\(report.errorLines)")
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("no longer an ancestor"), message)
        XCTAssertTrue(message.contains("HEAD is DETACHED"), message)
        XCTAssertTrue(message.contains("then re-scan"), message)
        // (d) the worktree is still registered — nothing half-happened.
        XCTAssertTrue(try worktreeListing(of: repository)
            .contains(identityPath(worktree)))
    }

    // ====================================================================
    // MARK: - R11: scan → select → clean → report
    // ====================================================================

    @MainActor
    func testThreeWorktreeFixtureScansSelectsCleansAndReports() async throws {
        let fixture = try makeThreeWorktreeFixture()
        let runner = hermeticRunner()
        let viewModel = CacheoutViewModel(runtime: productionRuntime(runner: runner))

        // ---- SCAN -------------------------------------------------------
        await viewModel.scan(
            trigger: .userInitiated, scannerIDs: [GitWorktreeScanner.registeredID]
        )

        let section = try XCTUnwrap(viewModel.perItemSections.first {
            $0.scannerID == GitWorktreeScanner.registeredID
        }, "registration alone puts the scanner in the GUI sections")
        XCTAssertEqual(section.displayName, "Stale Git Worktrees")
        XCTAssertEqual(section.items.count, 2,
                       "one stale candidate + one repo-level prune item")

        let stale = try item(section.items, mode: .removeStaleWorktree)
        XCTAssertEqual(stale.url?.path, identityPath(fixture.merged))
        XCTAssertEqual(stale.risk, .review, "D2: a removal is never 'safe'")
        XCTAssertFalse(stale.defaultSelected, "never pre-selected")
        XCTAssertFalse(stale.automaticCleanEligible, "never automatic")
        XCTAssertEqual(stale.state, .measured)
        XCTAssertGreaterThan(stale.exactBytes, 0)
        for clause in ["G1 ", "G2 clean", "G3 ", "G4 not locked"] {
            XCTAssertTrue(stale.evidence.contains(clause),
                          "full gate evidence, got: \(stale.evidence)")
        }

        let prune = try item(section.items, mode: .pruneOrphanedAdmin)
        XCTAssertEqual(prune.state, .measured, "never .empty — it must dispatch")
        XCTAssertFalse(prune.automaticCleanEligible)
        XCTAssertTrue(
            prune.evidence.contains(fixture.gone.lastPathComponent),
            "the prune item discloses its admin set, got: \(prune.evidence)"
        )
        let prunePlan = try plan(of: prune)
        XCTAssertEqual(prunePlan.disclosedAdminDirectories.count, 1)

        // ---- D15: the dirty worktree was ASSESSED and then OMITTED --------
        XCTAssertFalse(
            section.items.contains { $0.url?.path == identityPath(fixture.dirty) },
            "a dirty worktree is never an item"
        )
        // Path spellings differ by /var → /private/var aliasing, so the match
        // is on the leaf: only the dirty worktree is named `dirty`.
        XCTAssertTrue(
            runner.invocations.contains { invocation in
                invocation.argv.contains("status")
                    && invocation.argv.contains {
                        URL(fileURLWithPath: $0).lastPathComponent == "dirty"
                    }
            },
            "omission is not a skip — G2 really ran against the dirty tree: "
                + "\(runner.argvs)"
        )

        // ---- The CLI row for the SAME item, from the generic builder ------
        // Registration alone makes these rows appear; the builder needed no
        // per-scanner branch. The plan payload is NOT on the wire (the
        // `.commands` non-exposure rule, extended to the composite).
        let row = CLIHandler.scannerItemRowJSON(for: stale)
        XCTAssertEqual(row["scanner_id"] as? String,
                       GitWorktreeScanner.registeredID)
        XCTAssertEqual(row["item_id"] as? String, stale.id)
        XCTAssertEqual(row["action"] as? String, "git_worktree_reclaim")
        XCTAssertEqual(
            Set(row.keys),
            ["scanner_id", "item_id", "path", "name", "state", "exact_bytes",
             "estimated_up_to_bytes", "size_bytes", "item_count",
             "risk_level", "evidence", "action"],
            "the documented base row shape — no plan paths, no extra keys"
        )

        // ---- Quick Clean picks up NOTHING --------------------------------
        viewModel.selectAllSafe()
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty,
                      "no worktree item is ever part of the automatic path")
        XCTAssertEqual(viewModel.automaticCleanableSize, 0)

        // ---- SELECT ------------------------------------------------------
        viewModel.moveToTrash = false   // permanent, fixture-contained
        viewModel.toggleSelection(for: stale.key)
        viewModel.toggleSelection(for: prune.key)
        XCTAssertEqual(viewModel.selectedItemKeys.count, 2)

        // The trash-honesty disclosure the sheet renders for exactly this
        // selection (F7): both modes, named separately.
        let disclosures = viewModel.gitWorktreeTrashDisclosures
        XCTAssertEqual(disclosures.count, 2, "\(disclosures)")
        XCTAssertTrue(
            try XCTUnwrapElement(disclosures, 0)
                .contains("removed permanently either way"),
            "the stale wording names the half the toggle does NOT cover"
        )
        XCTAssertTrue(try XCTUnwrapElement(disclosures, 1).contains("repository admin data permanently"))

        let expectedExact = DirectorySizer()
            .measure(at: fixture.merged, mode: .deletionTarget).exactAllocatedBytes
        XCTAssertGreaterThan(expectedExact, 0)

        // ---- CLEAN -------------------------------------------------------
        await viewModel.clean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.errors.map(\.message), [])
        XCTAssertEqual(Set(report.entries.map(\.key)), [stale.key, prune.key])
        let staleEntry = try XCTUnwrap(report.entries.first { $0.key == stale.key })
        XCTAssertEqual(staleEntry.exactBytes, expectedExact,
                       "freed bytes are the delete-time measurement")
        // D16 as of PR #460 codex r5: the entry follows the toggle, and this
        // run has it OFF. It was `.permanent` unconditionally while
        // `git worktree remove` was the arm.
        XCTAssertEqual(staleEntry.disposal, .permanent)
        XCTAssertNil(staleEntry.warning,
                     "the gated prune removed the admin entry too — nothing "
                         + "left behind, so no D11 warning")

        // ---- THE FILESYSTEM AND THE REPOSITORY ---------------------------
        XCTAssertFalse(fm.fileExists(atPath: fixture.merged.path),
                       "the stale worktree is gone")
        XCTAssertTrue(fm.fileExists(atPath: fixture.dirty.path),
                      "the dirty worktree is untouched")
        XCTAssertTrue(
            fm.fileExists(
                atPath: fixture.dirty.appendingPathComponent("uncommitted-work.txt").path
            ),
            "…and so is the uncommitted work inside it"
        )

        // Leaf-scoped matching: the porcelain spells paths git's own way.
        let listing = try worktreeListing(of: fixture.repository)
        XCTAssertFalse(listing.contains("prunable"),
                       "the registry is clean: \(listing)")
        XCTAssertFalse(listing.contains("/.worktrees/merged"),
                       "the removed worktree is deregistered: \(listing)")
        XCTAssertTrue(listing.contains("/dirty"),
                      "the dirty worktree stays registered: \(listing)")

        // Branch refs survive BOTH operations — the epic's central promise.
        XCTAssertEqual(try branches(of: fixture.repository),
                       ["main", "merged", "dirty", "gone"])

        // The prune item really executed — proven by the admin directory
        // being gone, not by a subprocess appearing — and NO repository-wide
        // prune ran (PR #460 codex r1 / C4). D10's expire override rides the
        // oracle listing, which is where prunability is decided.
        XCTAssertNil(runner.argvs.first { $0.contains("prune") },
                     "\(runner.argvs)")
        let listings = runner.invocations.filter { $0.argv.contains("list") }
        XCTAssertFalse(listings.isEmpty)
        for listing in listings {
            XCTAssertTrue(
                listing.argv.contains(GitWorktreeOracle.pruneExpireOverride),
                "\(listing.argv)"
            )
        }
        for invocation in runner.invocations {
            XCTAssertFalse(invocation.argv.contains("--force"),
                           "--force reached git: \(invocation.argv)")
            XCTAssertFalse(invocation.argv.contains("branch"),
                           "a branch command reached git: \(invocation.argv)")
        }
    }

    /// **THE ALL-CHECKOUTS-GONE BARE REPOSITORY, END TO END** (fn-4.28).
    ///
    /// The case the prune tier exists for: a bare parent whose linked
    /// checkouts were all deleted by hand. Discovery used to key on a `.git`
    /// entry, which a bare repository does not have — so this fixture
    /// produced NO item, NO issue, and the orphaned admin data survived
    /// every scan. The cell drives the real production composition and then
    /// asks git itself whether pruning left the repository usable: a clean
    /// registry, a quiet `fsck`, and a FRESH `git worktree add` that
    /// succeeds.
    @MainActor
    func testABareRepositoryWhoseCheckoutsAreAllGoneIsPrunedAndStaysUsable()
        async throws
    {
        let seed = try makeRepository(at: base.appendingPathComponent("seed"))
        let bare = dev.appendingPathComponent("repo.git")
        XCTAssertEqual(
            try GitFixture.git(
                ["clone", "--bare", seed.path, bare.path], home: home
            ).status, 0, "bare clone failed"
        )
        let gone = try addWorktree(
            of: bare, at: dev.appendingPathComponent("gone"), branch: "gone"
        )
        try fm.removeItem(at: gone)

        let runner = hermeticRunner()
        let viewModel = CacheoutViewModel(runtime: productionRuntime(runner: runner))
        await viewModel.scan(
            trigger: .userInitiated, scannerIDs: [GitWorktreeScanner.registeredID]
        )
        let section = try XCTUnwrap(viewModel.perItemSections.first {
            $0.scannerID == GitWorktreeScanner.registeredID
        })
        let prune = try item(section.items, mode: .pruneOrphanedAdmin)
        XCTAssertEqual(section.items.count, 1, "the prune item and nothing else")
        XCTAssertTrue(
            prune.evidence.contains(gone.lastPathComponent),
            "the disclosure names the gone checkout: \(prune.evidence)"
        )

        viewModel.moveToTrash = false   // permanent, fixture-contained
        viewModel.toggleSelection(for: prune.key)
        await viewModel.clean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.errors.map(\.message), [])
        XCTAssertEqual(report.entries.map(\.key), [prune.key])

        // THE REPOSITORY IS USABLE AFTERWARDS, by git's own account.
        let listing = try worktreeListing(of: bare)
        XCTAssertFalse(listing.contains("prunable"),
                       "the registry is clean: \(listing)")
        let fsck = try GitFixture.git(
            ["-C", bare.path, "fsck", "--unreachable", "--no-reflogs"], home: home
        )
        XCTAssertEqual(fsck.status, 0)
        XCTAssertEqual(
            String(decoding: fsck.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "", "fsck must be quiet after the prune"
        )
        let fresh = dev.appendingPathComponent("fresh")
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", bare.path, "worktree", "add", fresh.path, "-b", "fresh"],
                home: home
            ).status, 0,
            "a fresh worktree add must succeed against the pruned repository"
        )
        // Branch refs survive the prune — the epic's central promise, on
        // the bare path too.
        XCTAssertTrue(try branches(of: bare).isSuperset(of: ["main", "gone"]))
    }

    /// **B-P1 THROUGH THE PRODUCTION SEAM** (PR #460 codex r16).
    ///
    /// The scanner-level cells for this defect live in
    /// `GitWorktreeScannerTests`; this one is the end-to-end measurement the
    /// review reported, run against the composition the GUI actually uses.
    /// Before the fix it produced, 4/4 deterministic runs: `items` carrying
    /// the row, `viewModel.issues(forScanner:) == []` — SILENT — an armed
    /// identity belonging to the REPLACEMENT, and a `clean()` that returned
    /// `errors == []` with one SUCCESS entry while destroying a brand-new
    /// checkout together with its ignored payload, its `secret.env` and its
    /// `node_modules/dep.bin`.
    ///
    /// The replacement fires the instant `git worktree list` returns: the
    /// fixture runs that ONE listing itself and hands the scanner its real
    /// bytes, so every record describes the checkout that is now gone while
    /// every subsequent read describes the new one. `runner.argvs` proves the
    /// single listing.
    ///
    /// Everything the replacement carries is `.gitignore`d, so the new
    /// checkout reads CLEAN to git and to this app — which is precisely why
    /// the four gates passed on it and why the destruction was silent.
    @MainActor
    func testACheckoutReplacedTheInstantTheListingReturnedIsRefusedAndSurvivesTheClean()
        async throws
    {
        // A repository that ignores every file the replacement will carry, so
        // the replacement is a CANDIDATE rather than a dirty tree the gates
        // would have refused for an unrelated reason.
        let repository = dev.appendingPathComponent("repo")
        try GitFixture.makeRepository(at: repository, home: home)
        try "payload.bin\nsecret.env\nnode_modules/\n".write(
            to: repository.appendingPathComponent(".gitignore"),
            atomically: true, encoding: .utf8
        )
        try GitFixture.git(["-C", repository.path, "add", ".gitignore"], home: home)
        try GitFixture.git(
            ["-C", repository.path, "-c", "user.name=t", "-c", "user.email=t@t",
             "commit", "-m", "ignore"],
            home: home
        )
        let target = try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt-live"), branch: "live"
        )

        let provider = FileSystemIdentityProvider()
        let listedAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: target)
        )
        let listedIdentity = try XCTUnwrap(provider.identity(of: listedAdmin))

        let payload = target.appendingPathComponent("payload.bin")
        let secret = target.appendingPathComponent("secret.env")
        let nested = target.appendingPathComponent("node_modules/dep.bin")
        let fixtureHome = try XCTUnwrap(home)
        let listingLatch = NSLock()
        var intercepted = false
        let runner = InterceptingGitRunner(
            wrapping: GitCommandRunner(environment: GitFixture.environment(home: home))
        ) { arguments, _ in
            listingLatch.lock()
            let first = arguments.contains("list") && !intercepted
            if first { intercepted = true }
            listingLatch.unlock()
            guard first else { return nil }
            guard let listed = try? GitFixture.git(arguments, home: fixtureHome),
                  listed.status == 0
            else { return nil }
            // THE LISTING HAS RETURNED. The developer retires the checkout and
            // creates a fresh one at the same path — REAL git, so the admin
            // entry is genuinely destroyed and recreated — then fills it with
            // the content a new checkout carries before its first commit.
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "remove", target.path],
                home: fixtureHome
            )
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "add", target.path, "-b", "brand-new"],
                home: fixtureHome
            )
            try? Data(repeating: 0xEF, count: 8192).write(to: payload)
            try? Data("TOKEN=live\n".utf8).write(to: secret)
            try? self.fm.createDirectory(
                at: nested.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? Data(repeating: 0x11, count: 4096).write(to: nested)
            return .success(stdout: listed.stdout)
        }

        let viewModel = CacheoutViewModel(runtime: productionRuntime(runner: runner))
        await viewModel.scan(
            trigger: .userInitiated, scannerIDs: [GitWorktreeScanner.registeredID]
        )

        XCTAssertEqual(
            runner.argvs.filter { $0.contains("list") }.count, 1,
            "the ONE listing per repository — the records' only source"
        )
        let replacementAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: target),
            "the replacement must itself be a well-formed linked worktree"
        )
        XCTAssertNotEqual(
            provider.identity(of: replacementAdmin), listedIdentity,
            "the fixture must have replaced the OBJECT, not merely the path"
        )

        let items = viewModel.perItemSections.first {
            $0.scannerID == GitWorktreeScanner.registeredID
        }?.items ?? []
        let offered = try items.filter { item in
            guard case .gitWorktreeReclaim = item.action else { return false }
            let reclaim = try plan(of: item)
            return reclaim.mode == .removeStaleWorktree
                && reclaim.worktreePath?.lastPathComponent == "wt-live"
        }
        let armed = try offered.first.map { try plan(of: $0).worktreeAdminEntryIdentity }
        XCTAssertTrue(
            offered.isEmpty,
            "the GUI was offered a row for a checkout replaced the instant the "
                + "listing returned; its armed identity is "
                + "\(String(describing: armed)) while the listed checkout's was "
                + "\(listedIdentity)"
        )
        // THE SILENCE WAS THE DEFECT: the refusal must reach the GUI's own
        // issue surface, not merely omit the row.
        let issues = viewModel.issues(forScanner: GitWorktreeScanner.registeredID)
        let issue = try XCTUnwrap(
            issues.first {
                $0.detail.contains("replaced") && $0.detail.contains("wt-live")
            },
            "the GUI shows nothing at all about the refusal: \(issues)"
        )
        XCTAssertTrue(issue.detail.contains("no item is offered"), issue.detail)

        // ---- CLEAN: whatever the GUI DID offer, executed for real ---------
        viewModel.moveToTrash = false
        for item in items { viewModel.toggleSelection(for: item.key) }
        await viewModel.clean()

        let report = viewModel.lastReport
        XCTAssertEqual(
            report?.entries.count ?? 0, 0,
            "the clean acted on something: nothing was offered, so nothing "
                + "could be selected: \(String(describing: report?.entries))"
        )
        // The brand-new checkout and everything the developer put in it.
        XCTAssertTrue(fm.fileExists(atPath: target.path), "the checkout is gone")
        XCTAssertEqual(try Data(contentsOf: payload).count, 8192)
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "TOKEN=live\n")
        XCTAssertEqual(try Data(contentsOf: nested).count, 4096)
        XCTAssertTrue(
            try worktreeListing(of: repository).contains("wt-live"),
            "the replacement stays registered — the scan refused it, it did "
                + "not act on it"
        )
    }


    // ====================================================================
    // MARK: - R11: the GUI's DEFAULT disposal, through the production seam
    // ====================================================================

    /// **THE SHIPPED DEFAULT, WITH NOTHING INJECTED AT THE TRASH SEAM** (PR
    /// #460 codex r10, D1/D2).
    ///
    /// `CacheoutViewModel.moveToTrash` DEFAULTS TO `true`
    /// (`CacheoutViewModel.swift`), and until this cell existed
    /// `grep -rn 'viewModel.moveToTrash = true' Tests/` returned NOTHING:
    /// every clean cell in this file — the epic's closing acceptance — turned
    /// the toggle OFF, and every Trash cell in the suite injected a
    /// `trashHandler:` landing in a FIXTURE directory. The fixture's parent is
    /// freely openable; the real `~/.Trash` IS NOT without Full Disk Access,
    /// and that one property is exactly what the disposal's after-proof
    /// depends on. So the GUI's default disposal had zero coverage, and the
    /// D1 defect it hid — `entries=0`, 0 bytes, and an error stating that what
    /// the Trash took "could not be put back — it is no longer at
    /// `~/.Trash/<name>`" about a checkout sitting at that exact path — was
    /// reproduced 3/3 through this composition before the fix.
    ///
    /// Nothing here is injected but the hermetic git runner: the runtime is
    /// `SpaceScannerRuntime.production`, the cleaner is the one
    /// `makeCleaner(snapshot:)` builds, and the mover is
    /// `FileManager.trashItem` landing in the REAL `~/.Trash`. The cell
    /// removes exactly the one item it put there — the landing name is
    /// unique per run — and touches nothing else in the user's Trash.
    @MainActor
    func testTheTrashDefaultReportsTheCheckoutItReallyMovedToTheTrash()
        async throws
    {
        let repository = try makeRepository(at: dev.appendingPathComponent("repo"))
        // UNIQUE per run, so the landing name is DETERMINISTIC (`trashItem`
        // only suffixes on collision) and the cleanup below can name it.
        let leaf = "cacheout-e2e-\(UUID().uuidString.prefix(8))"
        let worktree = try addWorktree(
            of: repository, at: dev.appendingPathComponent(leaf), branch: "merged"
        )
        let landing = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").appendingPathComponent(leaf)
        XCTAssertFalse(fm.fileExists(atPath: landing.path),
                       "the landing name must be free before the run")
        // Registered BEFORE the clean: the fixture is removed from the Trash
        // however this cell ends. Only this exact path — never the Trash.
        addTeardownBlock { try? FileManager.default.removeItem(at: landing) }

        let runner = hermeticRunner()
        let viewModel = CacheoutViewModel(runtime: productionRuntime(runner: runner))
        await viewModel.scan(
            trigger: .userInitiated, scannerIDs: [GitWorktreeScanner.registeredID]
        )
        let stale = try item(
            viewModel.items(forScanner: GitWorktreeScanner.registeredID),
            mode: .removeStaleWorktree
        )
        XCTAssertEqual(stale.url?.path, identityPath(worktree))
        let expectedExact = DirectorySizer()
            .measure(at: worktree, mode: .deletionTarget).exactAllocatedBytes
        XCTAssertGreaterThan(expectedExact, 0)

        // ---- CLEAN, ON THE DEFAULT --------------------------------------
        XCTAssertTrue(viewModel.moveToTrash,
                      "the toggle's shipped default is what this cell drives")
        // Assigned as well as asserted: the assertion pins the DEFAULT, and
        // the assignment is what the rot gate below reads to know the default
        // is still driven by something.
        viewModel.moveToTrash = true
        viewModel.toggleSelection(for: stale.key)
        await viewModel.clean()

        // ---- WHAT ACTUALLY HAPPENED ------------------------------------
        XCTAssertFalse(fm.fileExists(atPath: worktree.path),
                       "the checkout left its path")
        XCTAssertTrue(
            fm.fileExists(atPath: landing.path),
            "…and it is in the Trash at \(landing.path), recoverable in one "
                + "drag — which is what the report must not deny"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: landing.appendingPathComponent("payload.bin").path),
            "the checkout's contents went with it"
        )

        // ---- AND WHAT THE USER IS TOLD ABOUT IT -------------------------
        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(
            report.errors.map(\.message), [],
            "the move SUCCEEDED — the checkout is in the Trash — so any "
                + "refusal here is a false one"
        )
        let entry = try XCTUnwrap(
            report.entries.first { $0.key == stale.key },
            "the disposal that happened must be reported: \(report.entries)"
        )
        XCTAssertEqual(entry.disposal, .trash, "D16: the entry follows the toggle")
        XCTAssertEqual(entry.exactBytes, expectedExact,
                       "the bytes the disposal actually reclaimed")
    }

    // ====================================================================
    // MARK: - R11: the CLI wire
    // ====================================================================

    /// The slug is addressable with ZERO new flags, and the schema-3 gate
    /// covers it like every other destructive target: no `--confirm`, no
    /// deletion, and the plan rides the refusal.
    func testCLICleanOfTheSlugRequiresConfirmAndDeletesNothing() async throws {
        let fixture = try makeThreeWorktreeFixture()
        let runtime = productionRuntime(runner: hermeticRunner())
        let deps = CLIHandler.CLIRuntimeDependencies(
            runtime: runtime,
            categorySlugs: Set(CacheCategory.allCategories.map(\.slug))
        )

        guard case .failure(let code, _, let details) = await CLIHandler.cleanCLIOutcome(
            targets: [GitWorktreeScanner.registeredID],
            dryRun: false, confirmed: false, euid: 501, deps: deps
        ) else {
            return XCTFail("an unconfirmed clean must refuse")
        }
        XCTAssertEqual(code, "CONFIRMATION_REQUIRED")
        let rows = try XCTUnwrap(details?["plan"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2, "both tiers are addressable: \(rows)")
        for row in rows {
            XCTAssertEqual(row["scanner_id"] as? String,
                           GitWorktreeScanner.registeredID)
        }
        XCTAssertTrue(fm.fileExists(atPath: fixture.merged.path),
                      "an unconfirmed clean deletes nothing")
    }

    /// D12 revised, on the ACTUAL wire: a `tool_unavailable` row carries the
    /// kind, NO `path` key (the problem is the toolchain, not a location — a
    /// fake path is never invented) and the pinned detail prefix.
    func testToolUnavailableRowShapeOnTheScanEnvelope() async throws {
        try makeRepository(at: dev.appendingPathComponent("repo"))

        // HERMETIC unavailability: a PATH of one empty directory makes `env`
        // exit 127 on every host.
        let emptyPath = base.appendingPathComponent("empty-path")
        try fm.createDirectory(at: emptyPath, withIntermediateDirectories: true)
        let scanner = GitWorktreeScanner(
            home: home,
            devRoots: devRoots(),
            runner: GitCommandRunner(
                environment: ["PATH": emptyPath.path, "HOME": home.path]
            )
        )
        // The scanner ALONE — the category scanner's probed discovery spawns
        // tool subprocesses, which is neither hermetic nor relevant to a row
        // shape.
        let deps = CLIHandler.CLIRuntimeDependencies(
            runtime: try SpaceScannerRuntime(
                scanners: [scanner], categories: [], home: home,
                provider: FileSystemIdentityProvider()
            ),
            categorySlugs: []
        )

        let envelope = await CLIHandler.scanEnvelope(deps: deps)
        let errors = try XCTUnwrap(envelope["scanner_errors"] as? [[String: Any]])
        let row = try XCTUnwrap(
            errors.first { $0["kind"] as? String == "tool_unavailable" },
            "the tool-less scan publishes its unavailability: \(errors)"
        )
        XCTAssertEqual(row["scanner_id"] as? String, GitWorktreeScanner.registeredID)
        XCTAssertNil(row["path"], "a NON-filesystem kind carries no path key")
        XCTAssertNil(row["grant_hint"], "TCC has nothing to do with a missing tool")
        XCTAssertTrue(
            (row["detail"] as? String)?.hasPrefix("git unavailable") ?? false,
            "the pinned detail prefix; got: \(row["detail"] ?? "<none>")"
        )
        XCTAssertTrue(
            (envelope["scanner_items"] as? [[String: Any]])?.isEmpty ?? false,
            "every item is withdrawn — a tool-less zero is not a clean machine"
        )
    }

    // ====================================================================
    // MARK: - R11: the grep gates
    // ====================================================================

    /// **THE SUITE STILL DRIVES THE SHIPPED DEFAULT, AND STILL DRIVES IT
    /// THROUGH THE PRODUCTION SEAM** (PR #460 codex r10, D2; strengthened
    /// r11, D4).
    ///
    /// This is the rot check for the gap that let D1 survive eight rounds,
    /// and both halves of it are needed:
    ///
    /// 1. At r9 `grep -rn 'viewModel.moveToTrash = true' Tests/` returned
    ///    NOTHING. Every clean cell in this file — the epic's closing
    ///    acceptance, and the only place the real production composition is
    ///    driven — set the toggle to `false`, so the disposal the GUI
    ///    performs by default was never once executed end to end.
    /// 2. Setting the toggle is not enough on its own. Every Trash cell in
    ///    the suite injects a `trashHandler:` landing in a FIXTURE directory,
    ///    whose parent is freely openable — and that ONE property is what
    ///    D1's guard depended on and what the real `~/.Trash` does not have.
    ///    So this file must contain no `trashHandler` at all: whatever it
    ///    drives, it drives through `FileManager.trashItem`.
    ///
    /// WHAT (1) LOOKED FOR UNTIL r11, AND WHY THAT WAS NOT ENOUGH (D4). It
    /// passed if ANY non-comment line anywhere under `Tests/` contained the
    /// assignment. It did not check that the line was in a cell driving the
    /// production composition, or that a clean followed it — so an edit that
    /// set the toggle in an unrelated cell, or that deleted the `clean()`
    /// below it, kept this gate GREEN with the coverage gone. That is the
    /// same class of defect the gate exists to catch, one level up.
    ///
    /// It now requires at least one `func test…` IN THIS FILE that does all
    /// three: assigns the toggle its shipped value, composes
    /// `productionRuntime(` (the real `SpaceScannerRuntime.production`, with
    /// nothing injected but the hermetic git runner), and calls `clean()` on
    /// a LATER line than the assignment. The suite-wide inventory is kept,
    /// but only as failure-message context: a driver in another target proves
    /// nothing about the composition acceptance.
    ///
    /// ## THE RESIDUAL, RECORDED RATHER THAN IMPLIED (r11, D4)
    ///
    /// What this gate holds is the WORKTREE arm. `CacheCleaner`'s item-mode
    /// and contents-mode Trash disposal — the app's primary feature, and the
    /// population `TrashDisposal.dispose(_:containedIn:provider:via:)` was
    /// written for — still has ZERO coverage through the real
    /// `FileManager.trashItem`: every one of those cells injects a
    /// `trashHandler:` landing in a fixture directory whose parent is freely
    /// openable, which is exactly the property that hid D1 for eight rounds.
    /// The bug D1 fixed was in shared code, so the worktree cell would have
    /// caught it for both — but nothing here says the item and contents arms
    /// reach `~/.Trash` correctly, and this gate must not be read as saying
    /// so.
    func testTheSuiteDrivesTheTrashDefaultThroughTheProductionSeam() throws {
        let testsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CacheoutTests
            .deletingLastPathComponent()   // Tests
        var sources: [URL] = []
        let walker = fm.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        while let next = walker?.nextObject() as? URL {
            if next.pathExtension == "swift" { sources.append(next) }
        }
        XCTAssertGreaterThan(sources.count, 40,
                             "the gate must have read the suite, not an "
                                 + "empty listing")

        // SPLIT, so neither this line nor the failure message below is itself
        // a match — a gate its own text satisfies is vacuous.
        let assignment = "moveToTrash" + " = true"
        func isCode(_ line: Substring) -> Bool {
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        var drivers: [String] = []
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            for (offset, line) in text.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() where line.contains(assignment) && isCode(line) {
                drivers.append("\(source.lastPathComponent):\(offset + 1)")
            }
        }

        // THE LOAD-BEARING HALF: a cell IN THIS FILE that assigns the toggle,
        // composes the production runtime, and cleans AFTER assigning.
        let ownLines = try String(
            contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8
        ).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var blocks: [(name: String, first: Int, last: Int)] = []
        var open: (name: String, first: Int)?
        for (offset, line) in ownLines.enumerated() {
            if line.hasPrefix("    func test") {
                open = (String(line.dropFirst(9)), offset)
            } else if line == "    }", let started = open {
                blocks.append((started.name, started.first, offset))
                open = nil
            }
        }
        XCTAssertGreaterThan(
            blocks.count, 5,
            "the block reader found \(blocks.count) cells in this file — it "
                + "has stopped parsing, so every check below is vacuous"
        )

        // A composition seam is what `productionRuntime(` builds; the clean
        // must come AFTER the assignment, not merely appear in the same cell.
        var qualifying: [String] = []
        for block in blocks {
            let body = ownLines[block.first...block.last]
            var assignedAt: Int?
            var cleanedAt: Int?
            var composes = false
            for (index, line) in body.enumerated() where isCode(line[...]) {
                if line.contains(assignment), assignedAt == nil { assignedAt = index }
                if line.contains("productionRuntime(") { composes = true }
                if line.contains(".clean()") { cleanedAt = index }
            }
            if let assignedAt, let cleanedAt, composes, cleanedAt > assignedAt {
                qualifying.append(block.name)
            }
        }
        XCTAssertFalse(
            qualifying.isEmpty,
            "no cell in the composition acceptance assigns the Trash toggle "
                + "its shipped value, builds the production runtime AND "
                + "cleans after it — the GUI's default disposal is uncovered "
                + "again, which is exactly the state D1 shipped in. Lines in "
                + "the suite that merely assign it: \(drivers)"
        )

        // CODE lines only — this cell's own doc comment spells the needle,
        // and a comment that explains the rule is not a violation of it. The
        // needle is SPLIT so this line is not one either.
        let needle = "trash" + "Handler"
        let own = try String(contentsOf: URL(fileURLWithPath: #filePath),
                             encoding: .utf8)
        let injections = own.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated().filter { _, line in
            line.contains(needle)
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }.map { offset, _ in "\(offset + 1)" }
        XCTAssertEqual(
            injections, [],
            "the composition acceptance must never inject the Trash seam: a "
                + "fixture landing directory is freely openable and the real "
                + "~/.Trash is not"
        )
    }

    /// The epic's Boundaries, read off the PRODUCTION SOURCE TREE rather than
    /// off whichever argv a fixture happened to execute.
    ///
    /// TWO LAYERS, because every one of these needles legitimately appears in
    /// prose: layer 1 finds every occurrence, layer 2 admits ONLY comment
    /// lines (and, for the git executable literal, the one runner that is
    /// allowed to spell it). A code line that carries a trailing comment
    /// containing a needle is reported — the conservative direction: a false
    /// positive costs a comment edit, a false negative ships `--force`.
    ///
    /// KNOWN LIMIT, stated rather than hidden: a line INSIDE a multi-line
    /// string literal that itself begins with `//` would be admitted as a
    /// comment. No production source has one, and such a line is string
    /// content rather than argv — but a future heredoc-style literal would
    /// need this gate taught about it.
    func testProductionSourcesHonourTheGitBoundaries() throws {
        let sources = try productionSwiftFiles()
        XCTAssertGreaterThan(sources.count, 20,
                             "gate must not be vacuous — Sources/Cacheout was "
                                 + "not found or is implausibly small")

        var forceOffenders: [String] = []
        var reconstructionOffenders: [String] = []
        var branchOffenders: [String] = []
        var executableOffenders: [String] = []
        var pruneOffenders: [String] = []
        var forceSeen = 0
        var reconstructionSeen = 0
        var expireOverrideSeen = 0
        var executableSeen = 0

        for file in sources {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                let isComment = line.trimmingCharacters(in: .whitespaces)
                    .hasPrefix("//")

                if line.contains("--force") {
                    forceSeen += 1
                    if !isComment { forceOffenders.append("\(name): \(line)") }
                }
                if line.contains(".git/worktrees") {
                    reconstructionSeen += 1
                    if !isComment {
                        reconstructionOffenders.append("\(name): \(line)")
                    }
                }
                // Branch DELETION argv: the token pair, never the porcelain
                // field name `branch` the inventory parses.
                if !isComment, line.contains("\"branch\""),
                   line.contains("\"-d\"") || line.contains("\"-D\"") {
                    branchOffenders.append("\(name): \(line)")
                }
                // Every git EXECUTION goes through GitCommandRunner: it is the
                // only file allowed to spell the executable.
                if line.contains("\"git\"") {
                    executableSeen += 1
                    if !isComment, name != "GitCommandRunner.swift" {
                        executableOffenders.append("\(name): \(line)")
                    }
                }
                // NO repository-wide prune argv may exist AT ALL any more
                // (PR #460 codex r1 / C4): `git worktree prune` takes no set,
                // so it re-enumerates the admin container after every gate has
                // answered. The repository-level mode removes the disclosed
                // directories directly instead.
                if !isComment, line.contains("\"worktree\", \"prune\"") {
                    pruneOffenders.append("\(name): \(line)")
                }
                // …and D10's job moved to where prunability is now decided:
                // the ORACLE listing pins the expire override.
                if !isComment, line.contains("gc.worktreePruneExpire=now") {
                    expireOverrideSeen += 1
                }
            }
        }

        XCTAssertEqual(forceOffenders, [], "--force reached production code")
        XCTAssertEqual(reconstructionOffenders, [],
                       "a `<wd>/.git/worktrees` reconstruction reached code")
        XCTAssertEqual(branchOffenders, [], "a branch deletion reached production code")
        XCTAssertEqual(executableOffenders, [],
                       "git is executed outside GitCommandRunner")
        XCTAssertEqual(pruneOffenders, [],
                       "a repository-wide `worktree prune` argv reached "
                           + "production code")

        // Non-vacuity: each needle must actually occur somewhere, or the gate
        // is asserting over an empty set.
        XCTAssertGreaterThan(forceSeen, 0, "the --force needle found nothing")
        XCTAssertGreaterThan(reconstructionSeen, 0,
                             "the reconstruction needle found nothing")
        XCTAssertGreaterThan(executableSeen, 0,
                             "the git executable needle found nothing")
        // The prune-argv gate is a pure PROHIBITION, so it cannot be
        // non-vacuous by counting its own needle. What must stay non-vacuous
        // is the rule that replaced it: the expire override still exists, on
        // the oracle listing, which is where prunability is decided.
        XCTAssertGreaterThan(expireOverrideSeen, 0,
                             "the gc.worktreePruneExpire needle found nothing")
    }

    /// ONE oracle→admin mapping implementation, with BOTH call sites present:
    /// fn-5.5 discloses the repository's prunable set with it and fn-5.4
    /// recomputes the same set with it. A second implementation would let
    /// detection and execution disagree about which admin directories the
    /// removal destroys.
    func testExactlyOneAdminMappingImplementationWithBothCallSites() throws {
        let sources = try productionSwiftFiles()
        var declarations: [String] = []
        var callSites: Set<String> = []
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                else { continue }
                if line.contains("struct GitWorktreeAdminMapper") {
                    declarations.append(file.lastPathComponent)
                }
                if line.contains("mapper.map(") {
                    callSites.insert(file.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(declarations, ["GitWorktreeInventory.swift"],
                       "exactly ONE mapping implementation")
        XCTAssertEqual(
            callSites,
            ["GitWorktreeScanner.swift", "WorktreeReclaimPerformer.swift"],
            "both call sites consume it, and nothing else maps"
        )
    }

    private func productionSwiftFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CacheoutTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Cacheout")
        var files: [URL] = []
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil)
        while let next = enumerator?.nextObject() as? URL {
            if next.pathExtension == "swift" { files.append(next) }
        }
        return files
    }
}
