import XCTest
@testable import Cacheout

/// fn-5.3 coverage: the composite `ReclaimAction.gitWorktreeReclaim` case and
/// its `GitWorktreeReclaimPlan` payload, the EIGHT exhaustive switch sites it
/// compiles through, the structural rule set enforced INDEPENDENTLY by the
/// cleaner and the runtime validator, the dispatch arm's fail-closed
/// preconditions plus its runner seam, and the new
/// `ScanIssue.Kind.toolUnavailable`.
///
/// UPDATED BY fn-5.4 where the behaviour it pinned deliberately moved: the
/// dispatch arm is now `WorktreeReclaimPerformer` rather than a placeholder
/// (so "reached dispatch" is observed through the performer's first
/// fail-closed gate), and site 8's `revalidatableAction` flipped to TRUE for
/// the composite because that performer routes the item through the
/// revalidator seam. Everything else here is untouched fn-5.3 contract.
///
/// THE SITE CENSUS (compile-through proof, this tree, 2026-08-14). Adding the
/// case with every site unpatched produced `switch must be exhaustive` at
/// exactly these — no more, no fewer:
///   1. `CacheCleaner.clean` check (3), zero-root-record guard
///   2. `CacheCleaner.clean` check (4), zero-byte skip (composite EXCLUDED)
///   3. `CacheCleaner.clean` check (5), execution dispatch
///   4. `CacheCleaner.structuralRefusal`, the action/descriptor switch
///   5. `ReclaimAction.wireString`
///   6. `SpaceScannerRuntime.structuralViolation`, the outer switch
///   7. the NESTED action/argv-coherence switch inside that arm
///   8. `CacheCleaner.structuralRefusal`, the `revalidatableAction` switch —
///      NOT in the epic's census of seven: fn-4.8 added a SECOND exhaustive
///      switch inside `structuralRefusal` after the census was taken, so the
///      function holds two. Recorded on the epic spec.
/// A ninth, deliberate, TEST-side site lives in
/// `CategoryScannerTests.testReclaimActionDispatchIsExhaustive`, which exists
/// to prove this addition is compile-time-visible.
final class GitWorktreeReclaimActionTests: XCTestCase {

    // MARK: - Fixture geometry

    /// The declared container root — the ONLY container these items are
    /// admitted for. Everything the plan may point git at must live inside
    /// it (`parentAdminContainer` strictly; `parentRepoWorkingDir` strictly
    /// or equally).
    private var container: URL!
    private var home: URL!
    /// `<container>/repo` — the `-C` target.
    private var repoDir: URL { container.appendingPathComponent("repo") }
    /// `<container>/repo/.git/worktrees` — RESOLVER-carried in production;
    /// spelled out here only because the fixture chose a non-bare parent.
    private var adminContainer: URL {
        repoDir.appendingPathComponent(".git").appendingPathComponent("worktrees")
    }
    /// `<container>/wt` — the stale worktree (the deletion target).
    private var worktree: URL { container.appendingPathComponent("wt") }
    /// `<adminContainer>/wt` — that worktree's own admin entry.
    private var adminEntry: URL { adminContainer.appendingPathComponent("wt") }
    /// A second admin entry, the one a prune-only plan discloses.
    private var orphanEntry: URL {
        adminContainer.appendingPathComponent("gone")
    }
    private let scannerID = "git_worktrees"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try makeTempDir("container")
        home = try makeTempDir("home")
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GitWorktreeReclaimActionTests-\(label)-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
        return base
    }

    // MARK: - Fixture builders

    /// A plan whose defaults are VALID for the mode; every field is
    /// overridable so a test can construct the exact forgery it names. The
    /// two mode-specific URLs take a double optional so `.some(nil)` can
    /// force a nil the mode requires to be present (and vice versa).
    private func plan(
        _ mode: GitWorktreeReclaimPlan.Mode,
        worktreePath: URL?? = nil,
        worktreeAdminEntry: URL?? = nil,
        parentRepoWorkingDir: URL? = nil,
        parentAdminContainer: URL? = nil,
        disclosedAdminDirectories: [URL]? = nil
    ) -> GitWorktreeReclaimPlan {
        let stale = mode == .removeStaleWorktree
        return GitWorktreeReclaimPlan(
            mode: mode,
            worktreePath: worktreePath ?? (stale ? worktree : nil),
            worktreeAdminEntry: worktreeAdminEntry ?? (stale ? adminEntry : nil),
            // Shape/validation cells only — none reaches the delete path,
            // where a nil identity is itself a refusal (r4/D6).
            worktreeAdminEntryIdentity: nil,
            parentRepoWorkingDir: parentRepoWorkingDir ?? repoDir,
            parentAdminContainer: parentAdminContainer ?? adminContainer,
            disclosedAdminDirectories: disclosedAdminDirectories
                ?? (stale ? [] : [orphanEntry])
        )
    }

    /// The path a well-formed item of this plan is admitted for: the
    /// worktree in stale mode, the admin container in prune mode.
    private func defaultTarget(of plan: GitWorktreeReclaimPlan) -> URL {
        switch plan.mode {
        case .removeStaleWorktree: return plan.worktreePath ?? worktree
        case .pruneOrphanedAdmin: return plan.parentAdminContainer
        }
    }

    /// A structurally VALID composite item for the plan — defaults are
    /// state-coherent and carry the measured record binding the target, so
    /// any refusal a test observes comes from the override it made.
    private func item(
        _ plan: GitWorktreeReclaimPlan,
        id: String = "wt-item",
        state: ScanState = .measured,
        admission: AdmissionDescriptor? = nil,
        rootRecords: [RootScanRecord]? = nil,
        displayURL: URL?? = nil,
        exactBytes: Int64? = nil,
        itemCount: Int? = nil,
        scanError: ScanError?? = nil,
        requiresPreDeleteRevalidation: Bool = false
    ) -> ReclaimableItem {
        let target = defaultTarget(of: plan)
        let zeroComponents =
            state == .missing || state == .empty || state == .denied
        let defaultRecords: [RootScanRecord]
        switch state {
        case .missing:
            defaultRecords = []
        case .denied:
            defaultRecords = [RootScanRecord(
                requestedURL: target, resolvedURL: target,
                status: .deniedUnmeasured
            )]
        case .empty, .measured, .partiallyDenied:
            defaultRecords = [RootScanRecord(
                requestedURL: target, resolvedURL: target, status: .measured
            )]
        }
        let defaultError: ScanError? =
            (state == .denied || state == .partiallyDenied)
            ? ScanError(kind: .permissionDenied, message: "fixture denial")
            : nil
        return ReclaimableItem(
            id: id, scannerID: scannerID,
            displayName: "worktree \(id)",
            exactBytes: exactBytes ?? (zeroComponents ? 0 : 4096),
            estimatedUpToBytes: 0,
            logicalBytes: nil,
            itemCount: itemCount ?? (zeroComponents ? 0 : 1),
            url: displayURL ?? (state == .missing ? nil : target),
            declaredDisplayPath: target.path,
            rootRecords: rootRecords ?? defaultRecords,
            state: state, scanError: scanError ?? defaultError,
            risk: .review, evidence: "fixture", rebuildNote: nil,
            action: .gitWorktreeReclaim(plan),
            admission: admission ?? .containerItem(
                originContainer: container, requestedTargetURL: target
            ),
            defaultSelected: false, automaticCleanEligible: false,
            isStale: nil,
            requiresPreDeleteRevalidation: requiresPreDeleteRevalidation
        )
    }

    private func makeRuntime() throws -> SpaceScannerRuntime {
        try SpaceScannerRuntime(
            scanners: [FixtureScanner(
                id: scannerID, trustedContainerRoots: [container]
            )],
            categories: [],
            home: home,
            provider: FileSystemIdentityProvider()
        )
    }

    private func makeCleaner(
        gitRunner: (any GitCommandRunning)? = nil
    ) -> CacheCleaner {
        CacheCleaner(
            home: home, containerRoots: [container],
            containerSnapshot: nil, gitRunner: gitRunner
        )
    }

    private struct FixtureScanner: SpaceScanner {
        let id: String
        var displayName: String { "Fixture \(id)" }
        let trustedContainerRoots: [URL]
        func scan(context: ScanContext) async -> ScanOutcome {
            ScanOutcome(items: [], errors: [])
        }
    }

    /// A runner double that RECORDS instead of executing. The placeholder
    /// must never reach it — an "unwired" arm that quietly ran git would be
    /// worse than one that refuses.
    private final class RecordingRunner: GitCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var defaultTimeout: TimeInterval { 10 }
        var invocations: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
        func run(
            _ arguments: [String], timeout: TimeInterval
        ) async -> GitCommandInvocation {
            lock.lock(); recorded.append(arguments); lock.unlock()
            return GitCommandInvocation(
                profile: GitSafetyProfile.classify(arguments),
                argv: arguments, environment: [:], outcome: .gitUnavailable
            )
        }
    }

    // MARK: - Shared assertions

    /// Every forged shape must be refused at BOTH enforcing sites — the
    /// runtime validator (outcome malformed, items excluded) AND the
    /// cleaner's chokepoint (item-keyed error, nothing executed). One helper
    /// so no cell can accidentally assert only half of the contract.
    ///
    /// `reason` is the fragment BOTH refusals must carry — asserting it is
    /// what keeps a cell from passing for an unrelated reason (a state
    /// coherence slip in the fixture, say) and simultaneously proves the two
    /// sites run the SAME rule set. `validatorReason` overrides it only where
    /// an EARLIER validator family (value domain, state coherence) honestly
    /// refuses first and never reaches the structural rules.
    private func assertRefusedAtBothSites(
        _ subject: ReclaimableItem,
        _ why: String,
        reason: String,
        validatorReason: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let runtime = try makeRuntime()
        let event = runtime.validatedOutcome(
            ScanOutcome(items: [subject], errors: []), from: scannerID
        )
        guard case .malformed(let id, let issue) = event else {
            XCTFail("the validator accepted \(why)", file: file, line: line)
            return
        }
        XCTAssertEqual(id, scannerID, file: file, line: line)
        XCTAssertEqual(issue.kind, .malformedOutcome, file: file, line: line)
        XCTAssertTrue(
            issue.detail.contains(validatorReason ?? reason),
            "the validator refused \(why) for another reason: \(issue.detail)",
            file: file, line: line
        )

        let runner = RecordingRunner()
        let report = await makeCleaner(gitRunner: runner)
            .clean(items: [subject], moveToTrash: false)
        XCTAssertTrue(report.entries.isEmpty,
                      "\(why) produced a cleanup entry", file: file, line: line)
        XCTAssertEqual(report.errors.count, 1,
                       "\(why) must be ONE item-keyed refusal",
                       file: file, line: line)
        XCTAssertEqual(report.errors.first?.key, subject.key,
                       file: file, line: line)
        let message = report.errors.first?.message ?? "<none>"
        XCTAssertTrue(
            message.hasPrefix("refused: "),
            "the cleaner's refusal must read as one: \(message)",
            file: file, line: line
        )
        XCTAssertTrue(
            message.contains(reason),
            "the cleaner refused \(why) for another reason: \(message)",
            file: file, line: line
        )
        XCTAssertTrue(runner.invocations.isEmpty,
                      "a refused item must never reach git",
                      file: file, line: line)
    }

    /// A well-formed item passes BOTH sites' structural rules: the validator
    /// publishes it, and the cleaner reaches DISPATCH.
    ///
    /// UPDATED BY fn-5.4: dispatch is no longer a placeholder but the real
    /// `WorktreeReclaimPerformer`, so "it reached dispatch" is now observed
    /// through the performer's OWN first fail-closed gate — these cleaners
    /// are built WITHOUT a scan-session snapshot, which the composite arm
    /// refuses exactly as `removeGuardedItem` does (items must be cleaned
    /// with the session that produced them). Structural refusals never reach
    /// that message, so the cell still proves what it always proved; and
    /// git is STILL never executed, which is the other half.
    private func assertReachesExecutionDispatch(
        _ subject: ReclaimableItem,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let runtime = try makeRuntime()
        let event = runtime.validatedOutcome(
            ScanOutcome(items: [subject], errors: []), from: scannerID
        )
        guard case .outcome(_, let outcome) = event else {
            XCTFail("the validator malformed a well-formed composite item",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(outcome.items.count, 1, file: file, line: line)

        let runner = RecordingRunner()
        let report = await makeCleaner(gitRunner: runner)
            .clean(items: [subject], moveToTrash: false)
        XCTAssertTrue(report.entries.isEmpty, file: file, line: line)
        XCTAssertEqual(report.errors.count, 1, file: file, line: line)
        XCTAssertTrue(
            report.errors.first?.message.contains(
                "no scan-session container snapshot"
            ) ?? false,
            "expected the snapshot-less delete-time refusal, got: "
                + "\(report.errors.first?.message ?? "<none>")",
            file: file, line: line
        )
        XCTAssertTrue(runner.invocations.isEmpty,
                      "a snapshot-less cleaner must not execute git",
                      file: file, line: line)
    }

    // MARK: - Payload shape (R4)

    func testPlanCarriesStructuredPathsAndNoArgvAtAll() {
        // The whole point of a PLAN instead of `.commands([[String]])`: the
        // item can describe WHAT to reclaim but never WHAT TO RUN. Reflection
        // makes that a structural assertion rather than a code-reading habit
        // — a string-array field added later fails here.
        // Compared as declared TYPE NAMES, not `is` casts: an EMPTY `[URL]`
        // casts successfully to `[String]`, so a cast-based check would pass
        // for the wrong reason on a stale-mode plan.
        let expected = [
            "mode": "Mode",
            "worktreePath": "Optional<URL>",
            "worktreeAdminEntry": "Optional<URL>",
            // D3 (PR #460 codex r3): the admin entry's SCAN-TIME inode.
            // Structured like every other field — an identity, not a string.
            "worktreeAdminEntryIdentity": "Optional<Identity>",
            "parentRepoWorkingDir": "URL",
            "parentAdminContainer": "URL",
            "disclosedAdminDirectories": "Array<URL>",
        ]
        for candidate in [
            plan(.removeStaleWorktree), plan(.pruneOrphanedAdmin),
        ] {
            var seen: [String: String] = [:]
            for child in Mirror(reflecting: candidate).children {
                let label = child.label ?? "?"
                let typeName = String(describing: type(of: child.value))
                seen[label] = typeName
                XCTAssertFalse(
                    typeName.contains("String"),
                    "\(label) is \(typeName) — argv is registry code and no "
                        + "string payload may ride the plan"
                )
            }
            XCTAssertEqual(seen, expected,
                           "the plan's field set is what fn-5.4/fn-5.5 "
                               + "consume verbatim — keep it minimal")
        }

        let stale = plan(.removeStaleWorktree)
        XCTAssertEqual(stale.mode, .removeStaleWorktree)
        XCTAssertEqual(stale.worktreePath, worktree)
        XCTAssertEqual(stale.worktreeAdminEntry, adminEntry)
        XCTAssertEqual(stale.parentRepoWorkingDir, repoDir)
        XCTAssertEqual(stale.parentAdminContainer, adminContainer)
        XCTAssertTrue(stale.disclosedAdminDirectories.isEmpty)

        let prune = plan(.pruneOrphanedAdmin)
        XCTAssertEqual(prune.mode, .pruneOrphanedAdmin)
        XCTAssertNil(prune.worktreePath)
        XCTAssertNil(prune.worktreeAdminEntry)
        XCTAssertEqual(prune.parentRepoWorkingDir, repoDir)
        XCTAssertEqual(prune.parentAdminContainer, adminContainer)
        XCTAssertEqual(prune.disclosedAdminDirectories, [orphanEntry])

        // Equatable, and the two modes are never equal by accident.
        XCTAssertEqual(stale, plan(.removeStaleWorktree))
        XCTAssertNotEqual(
            ReclaimAction.gitWorktreeReclaim(stale),
            ReclaimAction.gitWorktreeReclaim(prune)
        )
    }

    func testTheConvenienceConstructorsCannotBuildTheCrossedShapes() {
        // The factories exist so production code cannot accidentally cross
        // the modes; the memberwise init stays reachable so the TESTS can.
        let stale = GitWorktreeReclaimPlan.removeStaleWorktree(
            worktreePath: worktree, worktreeAdminEntry: adminEntry,
            worktreeAdminEntryIdentity: nil,
            parentRepoWorkingDir: repoDir, adminContainer: adminContainer
        )
        XCTAssertTrue(stale.disclosedAdminDirectories.isEmpty)
        let prune = GitWorktreeReclaimPlan.pruneOrphanedAdmin(
            parentRepoWorkingDir: repoDir, adminContainer: adminContainer,
            disclosedAdminDirectories: [orphanEntry]
        )
        XCTAssertNil(prune.worktreePath)
        XCTAssertNil(prune.worktreeAdminEntry)
    }

    // MARK: - Frozen wire string (R4)

    func testWireStringIsTheFrozenLiteralAndSerializesKindOnly() {
        // FROZEN at merge. The literal is spelled out here so a rename
        // anywhere else has to come through this assertion.
        XCTAssertEqual(
            ReclaimAction.gitWorktreeReclaim(plan(.removeStaleWorktree)).wireString,
            "git_worktree_reclaim"
        )
        // Kind-only serialization, the `.commands` precedent: two plans that
        // point at completely different repositories are indistinguishable on
        // the wire — plan paths are never a wire surface.
        let elsewhere = plan(
            .pruneOrphanedAdmin,
            parentRepoWorkingDir: URL(fileURLWithPath: "/somewhere/else"),
            parentAdminContainer: URL(fileURLWithPath: "/somewhere/else/.git/worktrees"),
            disclosedAdminDirectories: [
                URL(fileURLWithPath: "/somewhere/else/.git/worktrees/x"),
            ]
        )
        XCTAssertEqual(
            ReclaimAction.gitWorktreeReclaim(elsewhere).wireString,
            "git_worktree_reclaim"
        )
        XCTAssertEqual(
            ReclaimAction.gitWorktreeReclaim(plan(.removeStaleWorktree)).wireString,
            ReclaimAction.gitWorktreeReclaim(elsewhere).wireString
        )
        // snake_case, exactly like its three siblings.
        XCTAssertEqual(ReclaimAction.removeContents.wireString, "remove_contents")
        XCTAssertEqual(ReclaimAction.removeItem.wireString, "remove_item")
        XCTAssertEqual(ReclaimAction.commands([["true"]]).wireString, "commands")
    }

    // MARK: - The valid cells (both modes)

    func testWellFormedStaleAndPruneItemsPassBothSites() async throws {
        try await assertReachesExecutionDispatch(item(plan(.removeStaleWorktree)))
        try await assertReachesExecutionDispatch(
            item(plan(.pruneOrphanedAdmin), id: "prune-item")
        )
    }

    func testADevRootThatIsTheRepositoryIsLegalWhileAnEqualAdminContainerIsNot()
        async throws
    {
        // Round 4: `parentRepoWorkingDir` may EQUAL the admitted container —
        // a dev root that IS a repository is an ordinary shape, and only its
        // strictly-contained admin data is mutated.
        let atRoot = plan(
            .removeStaleWorktree,
            parentRepoWorkingDir: container,
            parentAdminContainer: container
                .appendingPathComponent(".git")
                .appendingPathComponent("worktrees"),
            disclosedAdminDirectories: []
        )
        let legal = GitWorktreeReclaimPlan(
            mode: .removeStaleWorktree,
            worktreePath: worktree,
            worktreeAdminEntry: atRoot.parentAdminContainer
                .appendingPathComponent("wt"),
            worktreeAdminEntryIdentity: nil,
            parentRepoWorkingDir: container,
            parentAdminContainer: atRoot.parentAdminContainer,
            disclosedAdminDirectories: []
        )
        try await assertReachesExecutionDispatch(item(legal))

        // The admin container is held to STRICT descent: equal to the
        // container would put the whole dev root in the mutation scope.
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree,
                      worktreeAdminEntry: container.appendingPathComponent("wt"),
                      parentAdminContainer: container)),
            "an admin container EQUAL to the admitted container",
            reason: "is not strictly inside the admitted originContainer"
        )
    }

    // MARK: - Admission descriptor (R4)

    func testCompositeItemsRequireContainerItemAdmission() async throws {
        let category = CacheCategory(
            name: "fixture", slug: "fixture_cat", description: "d",
            icon: "trash", discovery: [.absolutePath("/tmp/nope")],
            riskLevel: .safe, rebuildNote: "", defaultSelected: false
        )
        for mode in [GitWorktreeReclaimPlan.Mode.removeStaleWorktree, .pruneOrphanedAdmin] {
            try await assertRefusedAtBothSites(
                item(plan(mode), admission: .category(category)),
                "\(mode) with category admission",
                reason: "must carry the container-item admission descriptor"
            )
        }
    }

    // MARK: - `..` screen, ordered BEFORE standardization (round 9)

    func testATraversalSpellingIsMalformedEvenWhenItStandardizesBackInside()
        async throws
    {
        // THE ordering cell. `<container>/repo/../repo` standardizes to
        // `<container>/repo`, so a containment check run on standardized
        // spellings would ACCEPT it — while the verbatim spelling is what
        // reaches git. The `..` screen must therefore run FIRST.
        let sneaky = repoDir.appendingPathComponent("..")
            .appendingPathComponent("repo")
        XCTAssertEqual(sneaky.standardizedFileURL.path, repoDir.path,
                       "the fixture must be one that standardization forgives")
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree, parentRepoWorkingDir: sneaky)),
            "a parent repo spelled through '..'",
            reason: "contains a '..' component"
        )

        // Every plan path is screened, not just the parent — one per field.
        let escaping = container.appendingPathComponent("..")
            .appendingPathComponent("elsewhere")
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree, worktreePath: escaping)),
            "a worktree path spelled through '..'",
            reason: "contains a '..' component"
        )
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree,
                      worktreeAdminEntry: adminContainer
                          .appendingPathComponent("..")
                          .appendingPathComponent("wt"))),
            "an admin entry spelled through '..'",
            reason: "contains a '..' component"
        )
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree,
                      parentAdminContainer: adminContainer
                          .appendingPathComponent("..")),
                 id: "admin-dots"),
            "an admin container spelled through '..'",
            reason: "contains a '..' component"
        )
        try await assertRefusedAtBothSites(
            item(plan(.pruneOrphanedAdmin,
                      disclosedAdminDirectories: [
                        adminContainer.appendingPathComponent("..")
                            .appendingPathComponent("gone"),
                      ]),
                 id: "prune-dots"),
            "a disclosed admin directory spelled through '..'",
            reason: "contains a '..' component"
        )
    }

    // MARK: - Stale-mode shape (R4)

    func testStaleModeForgeriesAreRefusedAtBothSites() async throws {
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree, worktreePath: .some(nil))),
            "a stale plan with no worktree path",
            reason: "must carry the worktree path it removes"
        )
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree, worktreeAdminEntry: .some(nil))),
            "a stale plan with no admin entry",
            reason: "must carry the worktree's admin entry"
        )
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree,
                      disclosedAdminDirectories: [orphanEntry])),
            "a stale plan carrying a disclosed prune set",
            reason: "must disclose no prune set"
        )
        // The plan's target and the ADMITTED target must be one path.
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree),
                 admission: .containerItem(
                    originContainer: container,
                    requestedTargetURL: container.appendingPathComponent("other-wt")
                 )),
            "a stale plan whose worktree path is not the admitted target",
            reason: "is not the admitted requestedTargetURL"
        )
        // Round 8: the admin ENTRY is what the GATED POST-REMOVAL prune gate
        // compares against, so it must live inside the carried container.
        // ("post-fallback" until PR #460 codex r7, D6: there is no fallback
        // arm — the removal is the only arm, and the prune follows it.)
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree,
                      worktreeAdminEntry: container.appendingPathComponent("wt"))),
            "an admin entry outside the carried admin container",
            reason: "is not inside the carried admin container"
        )
        // STRICT: the entry may not BE the container.
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree, worktreeAdminEntry: adminContainer)),
            "an admin entry equal to the carried admin container",
            reason: "is not inside the carried admin container"
        )
    }

    // MARK: - Prune-mode shape (R4)

    func testPruneModeForgeriesAreRefusedAtBothSites() async throws {
        try await assertRefusedAtBothSites(
            item(plan(.pruneOrphanedAdmin, worktreePath: worktree),
                 id: "p1"),
            "a prune plan carrying a worktree path",
            reason: "must carry no worktree path"
        )
        try await assertRefusedAtBothSites(
            item(plan(.pruneOrphanedAdmin, worktreeAdminEntry: adminEntry),
                 id: "p2"),
            "a prune plan carrying a worktree admin entry",
            reason: "must carry no worktree admin entry"
        )
        try await assertRefusedAtBothSites(
            item(plan(.pruneOrphanedAdmin, disclosedAdminDirectories: []),
                 id: "p3"),
            "a prune plan disclosing nothing",
            reason: "must disclose the non-empty set"
        )
        // The admitted target must be the CARRIED container — never a
        // `<wd>/.git/worktrees` reconstruction that happens to look right.
        try await assertRefusedAtBothSites(
            item(plan(.pruneOrphanedAdmin), id: "p4",
                 admission: .containerItem(
                    originContainer: container,
                    requestedTargetURL: repoDir
                        .appendingPathComponent(".git")
                        .appendingPathComponent("worktrees-other")
                 )),
            "a prune plan whose admitted target is not the carried container",
            reason: "is not the carried admin container"
        )
        try await assertRefusedAtBothSites(
            item(plan(.pruneOrphanedAdmin,
                      disclosedAdminDirectories: [
                        orphanEntry, container.appendingPathComponent("stray"),
                      ]),
                 id: "p5"),
            "a disclosed admin directory outside the carried container",
            reason: "disclosed admin directory"
        )
        try await assertRefusedAtBothSites(
            item(plan(.pruneOrphanedAdmin,
                      disclosedAdminDirectories: [adminContainer]),
                 id: "p6"),
            "a disclosed entry equal to the carried admin container",
            reason: "disclosed admin directory"
        )
    }

    // MARK: - D13 mutation scope, both modes (R4/R8)

    func testAPlanMayNotPointGitOutsideTheAdmittedContainer() async throws {
        let outside = try makeTempDir("outside")
        for mode in [GitWorktreeReclaimPlan.Mode.removeStaleWorktree, .pruneOrphanedAdmin] {
            // The `-C` target — a forged parent would have git rewrite
            // ANOTHER repository's administrative data.
            try await assertRefusedAtBothSites(
                item(plan(mode, parentRepoWorkingDir: outside), id: "\(mode)-parent"),
                "\(mode) whose parent repo is outside the admitted container",
                reason: "is outside the admitted originContainer"
            )
            // The admin container — the data the mutation actually rewrites.
            let strayAdmin = outside.appendingPathComponent("worktrees")
            try await assertRefusedAtBothSites(
                item(plan(mode,
                          worktreeAdminEntry: mode == .removeStaleWorktree
                              ? strayAdmin.appendingPathComponent("wt") : nil,
                          parentAdminContainer: strayAdmin,
                          disclosedAdminDirectories: mode == .pruneOrphanedAdmin
                              ? [strayAdmin.appendingPathComponent("gone")] : []),
                     id: "\(mode)-admin"),
                "\(mode) whose admin container is outside the admitted container",
                reason: "is not strictly inside the admitted originContainer"
            )
        }
    }

    func testLexicalContainmentIsComponentWiseNotAPrefixOfCharacters()
        async throws
    {
        // `/a/bc` is not inside `/a/b` — the PathGuard doctrine, restated
        // for the plan's lexical checks (a character-prefix comparison would
        // admit the sibling directory below).
        let sibling = URL(fileURLWithPath: container.path + "-sibling")
        try await assertRefusedAtBothSites(
            item(plan(.removeStaleWorktree,
                      worktreeAdminEntry: sibling
                          .appendingPathComponent("worktrees")
                          .appendingPathComponent("wt"),
                      parentRepoWorkingDir: sibling,
                      parentAdminContainer: sibling
                          .appendingPathComponent("worktrees"))),
            "a sibling directory sharing the container's name prefix",
            reason: "is not strictly inside the admitted originContainer"
        )
    }

    // MARK: - Measured-record / display binding (R4)

    func testForgedRecordAndForgedDisplayCellsAreRefusedInBothModes()
        async throws
    {
        for mode in [GitWorktreeReclaimPlan.Mode.removeStaleWorktree, .pruneOrphanedAdmin] {
            let subject = plan(mode)
            let target = defaultTarget(of: subject)
            let elsewhere = container.appendingPathComponent("elsewhere")

            // FORGED RECORD: nothing the scan measured captures the target,
            // so the item would execute against a path it never measured.
            try await assertRefusedAtBothSites(
                item(subject, id: "\(mode)-record",
                     rootRecords: [RootScanRecord(
                        requestedURL: elsewhere, resolvedURL: elsewhere,
                        status: .measured
                     )],
                     displayURL: elsewhere),
                "\(mode) with no measured record capturing its target",
                reason: "must carry a measured root record capturing its requestedTargetURL"
            )

            // FORGED DISPLAY: the record binds the target, but the item
            // SHOWS another path — confirm one, reclaim another.
            try await assertRefusedAtBothSites(
                item(subject, id: "\(mode)-display",
                     rootRecords: [RootScanRecord(
                        requestedURL: target, resolvedURL: target,
                        status: .measured
                     )],
                     displayURL: elsewhere),
                "\(mode) displaying a path other than its bound record",
                reason: "must be the resolved identity of the record binding its target"
            )

            // A record whose resolution honestly FAILED displays the
            // declared spelling: nil matches nil, and that stays valid.
            try await assertReachesExecutionDispatch(
                item(subject, id: "\(mode)-nil-resolution",
                     rootRecords: [RootScanRecord(
                        requestedURL: target, resolvedURL: nil,
                        status: .measured
                     )],
                     displayURL: .some(nil))
            )
        }
    }

    // MARK: - Site 1: zero root records (R4)

    func testACompositeItemWithNoRootRecordsIsRefusedInBothModes() async throws
    {
        for mode in [GitWorktreeReclaimPlan.Mode.removeStaleWorktree, .pruneOrphanedAdmin] {
            // A DELETABLE state with no records: the binding rule catches it.
            try await assertRefusedAtBothSites(
                item(plan(mode), id: "\(mode)-norec", rootRecords: []),
                "\(mode) with zero root records",
                reason: "must carry a measured root record capturing its requestedTargetURL",
                // The validator's state-coherence family refuses a
                // recordless non-missing item BEFORE the structural rules
                // ever run — an earlier, equally honest refusal.
                validatorReason: "requires at least one root record"
            )
            // And an EMPTY-state item with no records reaches the cleaner's
            // own zero-record guard — the site-1 arm — instead of being
            // silently skipped by the `.empty` no-op that follows it.
            let empty = item(plan(mode), id: "\(mode)-norec-empty",
                             state: .empty, rootRecords: [])
            let report = await makeCleaner().clean(items: [empty], moveToTrash: false)
            XCTAssertEqual(
                report.errors.first?.message,
                "refused: no root records — nothing was captured for this item to admit",
                "\(mode): the zero-record guard must fire before the empty skip"
            )
            XCTAssertTrue(report.entries.isEmpty)
        }
    }

    // MARK: - Site 2: the zero-byte skip excludes the composite (R4)

    func testAZeroByteCompositeItemStillReachesDispatch() async throws {
        // A prune-only item frees essentially nothing — git metadata — yet
        // it MUST run. The zero-byte skip precedes dispatch, so including the
        // composite there would make every such item a silent no-op that
        // reported success.
        let zeroByte = item(plan(.pruneOrphanedAdmin), id: "zero-prune",
                            exactBytes: 0, itemCount: 1)
        XCTAssertEqual(zeroByte.allocatedBytes, 0)
        // The validator's value-domain family accepts it (a `.measured` item
        // with itemCount >= 1 has "measured something"), which is what makes
        // fn-5.5's `.measured` emission policy viable.
        try await assertReachesExecutionDispatch(zeroByte)

        // The contrast that proves the arm is doing work: an AGGREGATE with
        // zero bytes is still skipped silently.
        let category = CacheCategory(
            name: "empty_agg", slug: "empty_agg", description: "d",
            icon: "trash", discovery: [.absolutePath(container.path)],
            riskLevel: .safe, rebuildNote: "", defaultSelected: false
        )
        let aggregate = ReclaimableItem(
            id: "empty_agg", scannerID: CategoryScanner.registeredID,
            displayName: "agg", exactBytes: 0, estimatedUpToBytes: 0,
            logicalBytes: nil, itemCount: 1, url: container,
            declaredDisplayPath: container.path,
            rootRecords: [RootScanRecord(
                requestedURL: container, resolvedURL: container, status: .measured
            )],
            state: .measured, scanError: nil, risk: .safe, evidence: "e",
            rebuildNote: nil, action: .removeContents,
            admission: .category(category),
            defaultSelected: false, automaticCleanEligible: true, isStale: nil
        )
        let report = await makeCleaner().clean(items: [aggregate], moveToTrash: false)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertTrue(report.errors.isEmpty,
                      "a zero-byte aggregate keeps its silent skip")
    }

    func testAnEmptyStateCompositeItemIsSkippedBeforeDispatch() async throws {
        // The anchor fn-5.5's emission policy depends on: `.empty` is a no-op
        // BEFORE dispatch, so a prune item emitted `.empty` would never run.
        // fn-5.5 therefore emits prune items `.measured` — always.
        let runner = RecordingRunner()
        let report = await makeCleaner(gitRunner: runner).clean(
            items: [item(plan(.pruneOrphanedAdmin), id: "empty-prune", state: .empty)],
            moveToTrash: false
        )
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertTrue(report.errors.isEmpty,
                      "an `.empty` item is a silent no-op, never an error")
        XCTAssertTrue(runner.invocations.isEmpty,
                      "an `.empty` item never reaches dispatch — the reason "
                          + "prune items are emitted `.measured`")
    }

    // MARK: - Site 3: the dispatch arm's fail-closed preconditions (R4)

    func testDispatchRefusesPerItemAndNamesTheMissingRunnerSeparately()
        async throws
    {
        // Both causes are per-item ERRORS — never a silent skip — and they
        // stay worded APART so a composition regression (no runner threaded
        // through) cannot hide behind the other refusal. fn-5.4 replaced the
        // placeholder's second cause with the performer's own first gate: a
        // cleaner holding the runner but NO scan-session snapshot.
        let subject = item(plan(.removeStaleWorktree))

        let withoutRunner = await makeCleaner()
            .clean(items: [subject], moveToTrash: false)
        XCTAssertTrue(withoutRunner.entries.isEmpty)
        XCTAssertEqual(withoutRunner.errors.count, 1)
        XCTAssertEqual(withoutRunner.errors.first?.key, subject.key)
        XCTAssertEqual(
            withoutRunner.errors.first?.message,
            "refused: no git runner is available to this cleaner — a "
                + "git_worktree_reclaim item can only be cleaned through a "
                + "cleaner built with one"
        )

        let runner = RecordingRunner()
        let withRunner = await makeCleaner(gitRunner: runner)
            .clean(items: [subject], moveToTrash: false)
        XCTAssertTrue(withRunner.entries.isEmpty)
        XCTAssertEqual(withRunner.errors.count, 1)
        XCTAssertTrue(
            withRunner.errors.first?.message.contains(
                "no scan-session container snapshot"
            ) ?? false,
            "expected the snapshot-less refusal, got: "
                + "\(withRunner.errors.first?.message ?? "<none>")"
        )
        XCTAssertNotEqual(withoutRunner.errors.first?.message,
                          withRunner.errors.first?.message,
                          "the two fail-closed causes must stay legible apart")
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testAFailClosedDispatchDeletesNothingOnDisk() async throws {
        // "Never a silent no-op" cuts both ways: it must also never be a
        // silent DELETION. The worktree and the admin data survive intact.
        let tree = worktree
        try FileManager.default.createDirectory(
            at: tree, withIntermediateDirectories: true
        )
        try Data("keep me".utf8).write(to: tree.appendingPathComponent("file.txt"))
        try FileManager.default.createDirectory(
            at: orphanEntry, withIntermediateDirectories: true
        )

        let runner = RecordingRunner()
        let cleaner = makeCleaner(gitRunner: runner)
        _ = await cleaner.clean(
            items: [item(plan(.removeStaleWorktree)),
                    item(plan(.pruneOrphanedAdmin), id: "prune-item")],
            moveToTrash: false
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tree.appendingPathComponent("file.txt").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanEntry.path))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testTheRunnerSeamIsTrailingAndDefaultedAndRuntimeThreaded() async throws {
        // Zero call-site churn is the contract: every pre-existing
        // construction — including a runtime composed without a runner —
        // still compiles, and the default is the fail-closed nil.
        let runtime = try makeRuntime()
        let fromFactory = runtime.makeCleaner()
        let report = await fromFactory.clean(
            items: [item(plan(.pruneOrphanedAdmin), id: "factory")],
            moveToTrash: false
        )
        XCTAssertEqual(
            report.errors.first?.message,
            "refused: no git runner is available to this cleaner — a "
                + "git_worktree_reclaim item can only be cleaned through a "
                + "cleaner built with one",
            "a runner-less runtime's cleaner fails CLOSED, never silently"
        )

        // fn-5.4: a runtime that DOES hold the shared runner threads it
        // through `makeCleaner`, so composite items reach the performer
        // instead of the composition refusal. (This one still refuses — it
        // has no session snapshot — but the message proves which gate it
        // reached.)
        let wired = try SpaceScannerRuntime(
            scanners: [FixtureScanner(
                id: scannerID, trustedContainerRoots: [container]
            )],
            categories: [], home: home, provider: FileSystemIdentityProvider(),
            gitRunner: RecordingRunner()
        )
        let wiredReport = await wired.makeCleaner().clean(
            items: [item(plan(.pruneOrphanedAdmin), id: "wired")],
            moveToTrash: false
        )
        XCTAssertTrue(
            wiredReport.errors.first?.message.contains(
                "no scan-session container snapshot"
            ) ?? false,
            "expected the performer's own gate, got: "
                + "\(wiredReport.errors.first?.message ?? "<none>")"
        )
    }

    func testTheProductionRuntimeCarriesTheSharedGitRunner() {
        // The composition assertion the execution path depends on: without a
        // runner on the production runtime, every GUI and CLI clean of a
        // composite item would refuse before reaching the performer.
        let runtime = SpaceScannerRuntime.production(
            home: home, provider: FileSystemIdentityProvider(),
            devRoots: DevRootsResolution(keptRoots: [], issues: [])
        )
        XCTAssertNotNil(
            runtime.gitRunner,
            "production() must supply the shared runner to its cleaners"
        )
    }

    // MARK: - Site 8: the fn-4.8 revalidation marker (R4)

    func testAMarkedCompositeItemWithoutARegisteredRevalidatorIsRefused()
        async throws
    {
        // `requiresPreDeleteRevalidation` promises "nothing marked is ever
        // deleted without passing the seam". fn-5.3 kept that promise by
        // refusing every marked composite item (there was no performer to
        // route one through the seam); fn-5.4 FLIPPED the arm because its
        // performer runs the seam in BOTH modes before anything destructive,
        // so the marker is now honoured rather than refused outright.
        //
        // The fail-closed half is what this cell pins: a marked item whose
        // scanner has NO registered revalidator is still refused — by check
        // (1b), the uniform scanner-agnostic refusal — and git never runs.
        let marked = item(plan(.removeStaleWorktree), id: "marked",
                          requiresPreDeleteRevalidation: true)
        let runner = RecordingRunner()
        let report = await makeCleaner(gitRunner: runner)
            .clean(items: [marked], moveToTrash: false)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(
            report.errors.first?.message,
            "refused: this item requires a pre-delete revalidation, but no "
                + "revalidator is registered for scanner 'git_worktrees' — "
                + "clean it through the runtime that registered its scanner"
        )
        XCTAssertTrue(runner.invocations.isEmpty,
                      "an unrevalidatable marked item never reaches git")
    }

    // MARK: - Validator-only rules (R4/R8)

    func testCompositeItemsAreBoundToTheProducingScannersDeclaredRoots()
        throws
    {
        // Origin binding, mirrored from `.removeItem`: delete-time admission
        // checks the runtime-wide UNION, so an undeclared origin could ride
        // another scanner's registration.
        let runtime = try makeRuntime()
        let elsewhere = URL(fileURLWithPath: "/tmp/never-declared")
        let forged = item(
            plan(.removeStaleWorktree,
                 worktreePath: elsewhere.appendingPathComponent("wt"),
                 worktreeAdminEntry: elsewhere
                    .appendingPathComponent("repo/.git/worktrees/wt"),
                 parentRepoWorkingDir: elsewhere.appendingPathComponent("repo"),
                 parentAdminContainer: elsewhere
                    .appendingPathComponent("repo/.git/worktrees")),
            admission: .containerItem(
                originContainer: elsewhere,
                requestedTargetURL: elsewhere.appendingPathComponent("wt")
            )
        )
        guard case .malformed = runtime.validatedOutcome(
            ScanOutcome(items: [forged], errors: []), from: scannerID
        ) else {
            return XCTFail("an undeclared originContainer must malform")
        }
    }

    func testTheCategoryAdapterMayNotEmitCompositeItems() throws {
        // Converse ownership: downstream treats every `categories` item as an
        // aggregate, so a composite bearing the adapter's id is a mapping
        // regression, not a new capability.
        let runtime = try SpaceScannerRuntime(
            scanners: [FixtureScanner(
                id: CategoryScanner.registeredID,
                trustedContainerRoots: [container]
            )],
            categories: [], home: home,
            provider: FileSystemIdentityProvider()
        )
        let adapterItem = ReclaimableItem(
            id: "wt", scannerID: CategoryScanner.registeredID,
            displayName: "wt", exactBytes: 4096, estimatedUpToBytes: 0,
            logicalBytes: nil, itemCount: 1, url: worktree,
            declaredDisplayPath: worktree.path,
            rootRecords: [RootScanRecord(
                requestedURL: worktree, resolvedURL: worktree, status: .measured
            )],
            state: .measured, scanError: nil, risk: .review, evidence: "e",
            rebuildNote: nil,
            action: .gitWorktreeReclaim(plan(.removeStaleWorktree)),
            admission: .containerItem(
                originContainer: container, requestedTargetURL: worktree
            ),
            defaultSelected: false, automaticCleanEligible: false, isStale: nil
        )
        guard case .malformed = runtime.validatedOutcome(
            ScanOutcome(items: [adapterItem], errors: []),
            from: CategoryScanner.registeredID
        ) else {
            return XCTFail("the aggregate adapter may emit only category-backed actions")
        }
    }

    // MARK: - ScanIssue.Kind.toolUnavailable (R4, D12 revised)

    func testToolUnavailableIsAFrozenNonFilesystemKind() {
        XCTAssertEqual(ScanIssue.Kind.toolUnavailable.wireString, "tool_unavailable")

        let issue = ScanIssue(
            url: nil, kind: .toolUnavailable,
            detail: "git unavailable — no usable git on the scanner's PATH"
        )
        XCTAssertNil(issue.url, "a missing tool has no honest filesystem path")

        // The CLI row builder's `path` key is conditional on the kind CLASS,
        // so the new kind needs no branch there — assert the behavior, not
        // the absence of code.
        let row = CLIHandler.scannerErrorRowJSON(scannerID: "git_worktrees", issue: issue)
        XCTAssertEqual(row["kind"] as? String, "tool_unavailable")
        XCTAssertNil(row["path"], "no fake path is ever invented")
        XCTAssertNil(row["grant_hint"], "a missing tool is not a TCC denial")
        XCTAssertEqual(row["detail"] as? String, issue.detail)

        // The GUI's second exhaustive switch renders it — and offers no
        // System Settings link, because none would help.
        let presentation = ScanIssueRowPresentation(issue: issue, home: home)
        XCTAssertEqual(presentation.location, "Scanner output")
        XCTAssertEqual(presentation.label, "required tool unavailable — not scanned")
        XCTAssertFalse(presentation.showsSettingsLink)
        XCTAssertEqual(presentation.text,
                       "Scanner output — required tool unavailable — not scanned")
    }

    // MARK: - No `default:` was introduced anywhere (R4)

    func testNoExhaustiveReclaimActionSwitchGainedADefaultArm() throws {
        // The doctrine the composite case exists to prove: every switch over
        // `ReclaimAction` is exhaustive, so the NEXT case addition is a
        // compile-time decision at every site too. Comment lines are
        // excluded — the files DISCUSS `default:` in their doc comments,
        // which is the opposite of using one.
        for relativePath in [
            "Sources/Cacheout/Cleaner/CacheCleaner.swift",
            "Sources/Cacheout/Scanner/SpaceScanner.swift",
        ] {
            let offenders = try codeLines(of: relativePath)
                .filter { $0.line.contains("default:") }
            XCTAssertTrue(
                offenders.isEmpty,
                "\(relativePath) must contain no `default:` arm — found at "
                    + "line(s) \(offenders.map(\.number))"
            )
        }

        // The GUI file legitimately uses `default:` for an unrelated
        // `ScanState` colour switch, so gate the ScanIssue.Kind label
        // function alone.
        let gui = try codeLines(of: "Sources/Cacheout/Views/ScannerItemSection.swift")
        guard let start = gui.firstIndex(where: {
            $0.line.contains("func label(for kind: ScanIssue.Kind)")
        }) else {
            return XCTFail("the ScanIssue.Kind label switch moved")
        }
        let body = gui[start...].prefix { !$0.line.hasPrefix("    }") }
        XCTAssertFalse(body.contains { $0.line.contains("default:") },
                       "the ScanIssue.Kind label switch must stay exhaustive")
        XCTAssertTrue(body.contains { $0.line.contains("case .toolUnavailable:") },
                      "the label switch must carry the new kind explicitly")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CacheoutTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// Source lines with comment-only lines removed — a `default:` inside a
    /// doc comment is documentation, not an arm.
    private func codeLines(
        of relativePath: String
    ) throws -> [(number: Int, line: String)] {
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { (number: $0.offset + 1, line: String($0.element)) }
            .filter { !$0.line.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
}
