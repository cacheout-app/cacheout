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
///    `--expire=now` on every prune argv, and no git execution outside
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
        return matching[0]
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
            ],
            "the single production registry, with git_worktrees registered"
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

        XCTAssertTrue(
            runner.invocations.contains { $0.argv.contains("remove") },
            "the clean's mutation rode the SAME instance: \(runner.argvs)"
        )
        XCTAssertFalse(fm.fileExists(atPath: fixture.merged.path))
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
        XCTAssertTrue(disclosures[0].contains("unlinked permanently"))
        XCTAssertTrue(disclosures[1].contains("repository admin data permanently"))

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
        // D16: git unlinks — the entry is permanent whatever the toggle said.
        XCTAssertEqual(staleEntry.disposal, .permanent)
        XCTAssertNil(staleEntry.warning,
                     "git removed the tree AND its admin entry — nothing left "
                         + "behind, so no D11 warning")

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

        // The executed prune carried `--expire=now` (D10) and nothing forbidden
        // reached git anywhere in the run.
        let executedPrunes = runner.invocations.filter { $0.argv.contains("prune") }
        XCTAssertFalse(executedPrunes.isEmpty, "the prune item really executed")
        for executed in executedPrunes {
            XCTAssertTrue(executed.argv.contains("--expire=now"), "\(executed.argv)")
        }
        for invocation in runner.invocations {
            XCTAssertFalse(invocation.argv.contains("--force"),
                           "--force reached git: \(invocation.argv)")
            XCTAssertFalse(invocation.argv.contains("branch"),
                           "a branch command reached git: \(invocation.argv)")
        }
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
        var pruneArgvSeen = 0
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
                // D10: a bare prune respects `gc.worktreePruneExpire`, so
                // detection would offer orphans execution silently leaves.
                if !isComment, line.contains("\"worktree\", \"prune\"") {
                    pruneArgvSeen += 1
                    if !line.contains("--expire=now") {
                        pruneOffenders.append("\(name): \(line)")
                    }
                }
            }
        }

        XCTAssertEqual(forceOffenders, [], "--force reached production code")
        XCTAssertEqual(reconstructionOffenders, [],
                       "a `<wd>/.git/worktrees` reconstruction reached code")
        XCTAssertEqual(branchOffenders, [], "a branch deletion reached production code")
        XCTAssertEqual(executableOffenders, [],
                       "git is executed outside GitCommandRunner")
        XCTAssertEqual(pruneOffenders, [], "a prune argv without --expire=now")

        // Non-vacuity: each needle must actually occur somewhere, or the gate
        // is asserting over an empty set.
        XCTAssertGreaterThan(forceSeen, 0, "the --force needle found nothing")
        XCTAssertGreaterThan(reconstructionSeen, 0,
                             "the reconstruction needle found nothing")
        XCTAssertGreaterThan(executableSeen, 0,
                             "the git executable needle found nothing")
        // The rule is "EVERY prune argv carries --expire=now" (enforced per
        // line above); this only proves the needle matched something, so a
        // future second builder is checked rather than assumed away.
        XCTAssertGreaterThan(pruneArgvSeen, 0,
                             "the prune argv needle found nothing")
    }

    /// ONE oracle→admin mapping implementation, with BOTH call sites present:
    /// fn-5.5 discloses the repository-wide side effect with it and fn-5.4
    /// recomputes the same set with it. A second implementation would let
    /// detection and execution disagree about what a prune removes.
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
