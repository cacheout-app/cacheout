import XCTest
import Darwin
@testable import Cacheout

/// fn-1.5 CLI gate tests (D5: R5/R16/R18 CLI half) + fn-2.6 registry-driven
/// CLI tests (R2/R7/R8: schema-4 envelope, address grammar, node_modules
/// exposure behind `--confirm`).
///
/// UNIT tier — hermetic and in-process: the pure gate decision matrix, the
/// schema bump, the plan/dry-run builders (scan-time components only, exact
/// bytes never laundered), smart-clean candidate eligibility and the
/// exact-only loop decision, the spotlight admission gate, AND the whole
/// clean/smart-clean pipelines driven through the INJECTED
/// `CLIRuntimeDependencies` bundle — addressing, resolution, gating, schema
/// shape, and the confirmed fixture deletion all run without a subprocess.
/// No test touches the real `$HOME`; no test deletes outside its fixture
/// root.
final class CLIGateTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("CLIGateTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Helpers

    private func makeCategory(
        name: String = "test-cache",
        risk: RiskLevel = .safe,
        path: String? = nil,
        defaultSelected: Bool = true,
        cleanCommands: [[String]]? = nil
    ) -> CacheCategory {
        CacheCategory(
            name: name,
            slug: name,
            description: "test",
            icon: "trash",
            discovery: [.absolutePath(path ?? "/nonexistent-fixture-\(name)")],
            riskLevel: risk,
            rebuildNote: "rebuilds",
            defaultSelected: defaultSelected,
            cleanCommands: cleanCommands
        )
    }

    private func makeResult(
        state: ScanState,
        category: CacheCategory? = nil,
        exact: Int64 = 0,
        estimated: Int64 = 0,
        items: Int = 0,
        scanError: ScanError? = nil
    ) -> ScanResult {
        ScanResult(
            category: category ?? makeCategory(),
            state: state,
            exactBytes: exact,
            estimatedUpToBytes: estimated,
            itemCount: items,
            scanError: scanError
        )
    }

    /// Aggregate item fixtures reuse the ONE production mapping
    /// (`CategoryScanner.item(from:)`) so plan-builder assertions exercise
    /// exactly the rows the registry-driven pipeline produces.
    private func makeItem(
        state: ScanState,
        category: CacheCategory? = nil,
        exact: Int64 = 0,
        estimated: Int64 = 0,
        items: Int = 0,
        scanError: ScanError? = nil
    ) -> ReclaimableItem {
        CategoryScanner.item(from: makeResult(
            state: state, category: category, exact: exact,
            estimated: estimated, items: items, scanError: scanError
        ))
    }

    /// A hand-built per-item scanner item (the smart-clean eligibility and
    /// address-shape fixtures — nothing here is ever deleted).
    private func makeStandaloneItem(
        id: String,
        scannerID: String = "fixture_scanner",
        name: String? = nil,
        risk: RiskLevel = .review,
        exact: Int64 = 4096,
        estimated: Int64 = 0,
        state: ScanState = .measured,
        action: ReclaimAction = .removeItem,
        automaticCleanEligible: Bool = false,
        defaultSelected: Bool = false,
        container: URL = URL(fileURLWithPath: "/tmp/fixture-container")
    ) -> ReclaimableItem {
        let target = container.appendingPathComponent(id)
        return ReclaimableItem(
            id: id, scannerID: scannerID,
            displayName: name ?? "item \(id)",
            exactBytes: exact, estimatedUpToBytes: estimated,
            logicalBytes: nil, itemCount: 1,
            url: target, declaredDisplayPath: target.path,
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: target, status: .measured
            )],
            state: state, scanError: nil,
            risk: risk, evidence: "fixture evidence", rebuildNote: nil,
            action: action,
            admission: .containerItem(
                originContainer: container, requestedTargetURL: target
            ),
            defaultSelected: defaultSelected,
            automaticCleanEligible: automaticCleanEligible,
            isStale: nil
        )
    }

    private let gb: Int64 = 1024 * 1024 * 1024

    // MARK: - Registry fixtures (fn-2.6)

    private actor ScanCallRecorder {
        private(set) var calls = 0
        func record() { calls += 1 }
        func count() -> Int { calls }
    }

    /// Registers with zero production edits; records its scan calls; emits
    /// a fixed outcome (items and/or scanner-level issues).
    private struct FixtureScanner: SpaceScanner {
        let id: String
        var displayName: String { "Fixture \(id)" }
        var trustedContainerRoots: [URL] = []
        var recorder: ScanCallRecorder?
        var items: [ReclaimableItem] = []
        var errors: [ScanIssue] = []

        func scan(context: ScanContext) async -> ScanOutcome {
            await recorder?.record()
            return ScanOutcome(items: items, errors: errors)
        }
    }

    /// The injected dependency bundle over a fixture registry: the
    /// CategoryScanner adapter (anchored to the fixture home) plus any
    /// extra per-item scanners.
    private func makeDeps(
        categories: [CacheCategory],
        extraScanners: [any SpaceScanner] = []
    ) throws -> CLIHandler.CLIRuntimeDependencies {
        let categoryScanner = CategoryScanner(
            categories: categories,
            scanner: CacheScanner(home: fixtureHome)
        )
        let runtime = try SpaceScannerRuntime(
            scanners: [categoryScanner] + extraScanners,
            categories: categories,
            home: fixtureHome,
            provider: FileSystemIdentityProvider()
        )
        return CLIHandler.CLIRuntimeDependencies(
            runtime: runtime,
            categorySlugs: Set(categories.map(\.slug))
        )
    }

    /// A real node_modules fixture: `<container>/<project>/node_modules`
    /// (optionally with content) plus a scanner over that container.
    private func makeNodeModulesFixture(
        project: String = "projA", withContent: Bool = true
    ) throws -> (container: URL, nodeModules: URL, scanner: NodeModulesScanner) {
        let container = base.appendingPathComponent("container-\(UUID().uuidString)")
        let nodeModules = container
            .appendingPathComponent(project)
            .appendingPathComponent("node_modules")
        try fm.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        if withContent {
            try Data(repeating: 0xAB, count: 8192).write(
                to: nodeModules.appendingPathComponent("dep.bin")
            )
        }
        let scanner = NodeModulesScanner(
            home: fixtureHome, searchRoots: [container]
        )
        return (container, nodeModules, scanner)
    }

    private func successPayload(
        _ outcome: CLIHandler.CLIOutcome, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        guard case .success(let payload) = outcome else {
            XCTFail("expected success, got \(outcome)", file: file, line: line)
            throw XCTSkip("not a success outcome")
        }
        return payload
    }

    private func failureOutcome(
        _ outcome: CLIHandler.CLIOutcome, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (code: String, message: String, details: [String: Any]?) {
        guard case .failure(let code, let message, let details) = outcome else {
            XCTFail("expected failure, got \(outcome)", file: file, line: line)
            throw XCTSkip("not a failure outcome")
        }
        return (code, message, details)
    }

    private func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys]
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    // MARK: - Gate decision matrix (R5)

    func testGateDecisionMatrixNonRoot() {
        XCTAssertEqual(
            CLIHandler.cleanGateDecision(confirmed: false, dryRun: false, euid: 501),
            .refuseUnconfirmed,
            "destructive without --confirm is refused"
        )
        XCTAssertEqual(
            CLIHandler.cleanGateDecision(confirmed: true, dryRun: false, euid: 501),
            .proceed
        )
        XCTAssertEqual(
            CLIHandler.cleanGateDecision(confirmed: false, dryRun: true, euid: 501),
            .dryRun,
            "--dry-run needs no confirmation (intervene parity)"
        )
        XCTAssertEqual(
            CLIHandler.cleanGateDecision(confirmed: true, dryRun: true, euid: 501),
            .dryRun,
            "--dry-run stays non-destructive even beside --confirm"
        )
    }

    func testGateDecisionRefusesRootRegardlessOfFlags() {
        for confirmed in [false, true] {
            for dryRun in [false, true] {
                XCTAssertEqual(
                    CLIHandler.cleanGateDecision(confirmed: confirmed, dryRun: dryRun, euid: 0),
                    .refuseRootUser,
                    "euid 0 is refused before any other consideration (confirmed=\(confirmed), dryRun=\(dryRun))"
                )
            }
        }
    }

    // MARK: - Schema bump (R8)

    func testSchemaVersionIsFour() {
        XCTAssertEqual(CLIHandler.cliSchemaVersion, 4,
                       "schema 4 = scan envelope + address grammar + identity fields (PROTOCOL.md)")
    }

    // MARK: - Plan actions mirror the cleaner's decisions (R18)

    func testCleanPlanActionsMatchCleanerDecisions() {
        XCTAssertEqual(CLIHandler.cleanPlanAction(for: makeItem(state: .missing)), "skip")
        XCTAssertEqual(CLIHandler.cleanPlanAction(for: makeItem(state: .empty)), "skip")
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeItem(state: .measured)), "skip",
            "zero-byte measured aggregates keep the schema-3 isEmpty skip"
        )
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeItem(state: .measured, exact: 4096, items: 1)),
            "clean"
        )
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeItem(
                state: .denied,
                scanError: ScanError(kind: .tccDenied, message: "denied")
            )),
            "refuse",
            "a named .denied target surfaces as a refusal, never a silent skip (R18)"
        )
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeItem(
                state: .partiallyDenied, exact: 2048, items: 1,
                scanError: ScanError(kind: .permissionDenied, message: "partial")
            )),
            "clean_with_warning"
        )
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeItem(
                state: .partiallyDenied,
                scanError: ScanError(kind: .permissionDenied, message: "partial")
            )),
            "skip",
            "a partiallyDenied aggregate with zero measured bytes has nothing the cleaner would touch"
        )
    }

    func testCleanPlanActionsForPerItemRowsFollowTheDispatch() {
        // Per-item rows mirror `clean(items:)` exactly: state gates only —
        // `.removeItem` has NO zero-byte skip (a measured item with
        // countable-but-zero-byte content IS deleted).
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeStandaloneItem(id: "a", state: .empty)),
            "skip",
            ".empty per-item candidates are the cleaner's silent pre-admission skip"
        )
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeStandaloneItem(id: "b", state: .denied)),
            "refuse"
        )
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeStandaloneItem(id: "c", exact: 0, state: .measured)),
            "clean",
            "no zero-byte skip in item mode — only aggregates keep the schema-3 isEmpty decision"
        )
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeStandaloneItem(id: "d", state: .partiallyDenied)),
            "clean_with_warning"
        )
    }

    func testCleanPlanItemCarriesComponentsWarningScanErrorAndIdentity() throws {
        let partial = makeItem(
            state: .partiallyDenied, category: makeCategory(name: "partial-cat"),
            exact: 2048, estimated: 512, items: 1,
            scanError: ScanError(kind: .permissionDenied, message: "permission denied")
        )
        let item = CLIHandler.cleanPlanItemJSON(for: partial)

        XCTAssertEqual(item["slug"] as? String, "partial-cat",
                       "aggregate rows keep the bare category slug (round 9)")
        XCTAssertEqual(item["state"] as? String, "partiallyDenied")
        XCTAssertEqual(item["action"] as? String, "clean_with_warning")
        XCTAssertEqual(item["exact_bytes"] as? Int64, 2048)
        XCTAssertEqual(item["estimated_up_to_bytes"] as? Int64, 512)
        XCTAssertEqual(item["warning"] as? String, CLIHandler.partiallyDeniedCleanWarning)
        XCTAssertEqual(item["scanner_id"] as? String, "categories",
                       "identity fields ride every clean-side row (schema 4)")
        XCTAssertEqual(item["item_id"] as? String, "partial-cat")
        let scanError = try XCTUnwrap(item["scan_error"] as? [String: Any])
        XCTAssertEqual(scanError["kind"] as? String, "permission_denied")

        let clean = CLIHandler.cleanPlanItemJSON(
            for: makeItem(state: .measured, exact: 4096, items: 1)
        )
        XCTAssertNil(clean["warning"], "clean categories carry no warning")
        XCTAssertNil(clean["scan_error"])

        // Per-item rows carry the composite ADDRESS in the retained key.
        let standalone = makeStandaloneItem(id: "abc123", scannerID: "fixture_scanner")
        let row = CLIHandler.cleanPlanItemJSON(for: standalone)
        XCTAssertEqual(row["slug"] as? String, "fixture_scanner:abc123")
        XCTAssertEqual(row["scanner_id"] as? String, "fixture_scanner")
        XCTAssertEqual(row["item_id"] as? String, "abc123")
    }

    // MARK: - Dry-run payload: exact-only totals, scan-time components (R16)

    func testCleanDryRunPayloadIsExactOnlyWithComponents() throws {
        let items = [
            makeItem(state: .measured, category: makeCategory(name: "m"),
                     exact: 4096, estimated: 512, items: 1),
            makeItem(state: .partiallyDenied, category: makeCategory(name: "p"),
                     exact: 2048, items: 1,
                     scanError: ScanError(kind: .permissionDenied, message: "partial")),
            makeItem(state: .denied, category: makeCategory(name: "d"),
                     scanError: ScanError(kind: .tccDenied, message: "denied")),
            makeItem(state: .missing, category: makeCategory(name: "gone")),
        ]
        let payload = CLIHandler.cleanDryRunPayload(for: items)

        XCTAssertEqual(payload["schema_version"] as? Int, 4,
                       "every payload self-describes (round 8)")
        XCTAssertEqual(payload["dry_run"] as? Bool, true)
        XCTAssertEqual(payload["total_would_free"] as? Int64, 4096 + 2048,
                       "totals count exact bytes only — estimates never advance them (R16)")
        XCTAssertEqual(payload["total_estimated_up_to_bytes"] as? Int64, 512)

        let entries = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 4, "every requested target appears, whatever its fate")

        let bySlug = Dictionary(uniqueKeysWithValues: entries.map { ($0["slug"] as! String, $0) })
        XCTAssertEqual(bySlug["m"]?["bytes_would_free"] as? Int64, 4096,
                       "per-entry would-free is exact-only; the 512 estimated bytes are additive")
        XCTAssertEqual(bySlug["m"]?["estimated_up_to_bytes"] as? Int64, 512)
        XCTAssertEqual(bySlug["p"]?["action"] as? String, "clean_with_warning")
        XCTAssertEqual(bySlug["d"]?["action"] as? String, "refuse")
        XCTAssertEqual(bySlug["d"]?["bytes_would_free"] as? Int64, 0)
        XCTAssertNotNil(bySlug["d"]?["scan_error"])
        XCTAssertEqual(bySlug["gone"]?["action"] as? String, "skip")
    }

    func testCleanConfirmationDetailsCarryThePlan() throws {
        let items = [
            makeItem(state: .measured, category: makeCategory(name: "m"),
                     exact: 4096, items: 1),
            makeItem(state: .denied, category: makeCategory(name: "d"),
                     scanError: ScanError(kind: .tccDenied, message: "denied")),
        ]
        let details = CLIHandler.cleanConfirmationDetails(for: items)

        XCTAssertEqual(details["command"] as? String, "clean")
        XCTAssertEqual(details["total_exact_bytes"] as? Int64, 4096)
        XCTAssertEqual(details["total_estimated_up_to_bytes"] as? Int64, 0)
        let plan = try XCTUnwrap(details["plan"] as? [[String: Any]])
        XCTAssertEqual(plan.count, 2,
                       "the plan mirrors the real run's per-target decisions")
        XCTAssertEqual(plan[1]["action"] as? String, "refuse")
    }

    func testCleanPlanTotalsSaturateAcrossScanners() throws {
        // Round 8: the runtime validator bounds each scanner's outcome
        // individually, but a multi-target plan can span scanners — the
        // plan totals must clamp at Int64.max, never trap. Each item here
        // is individually valid (and would ride an individually valid
        // outcome); only their cross-scanner sum is impossible.
        let items = [
            makeStandaloneItem(id: "huge_a", scannerID: "scanner_a",
                               exact: .max),
            makeStandaloneItem(id: "huge_b", scannerID: "scanner_b",
                               exact: .max),
        ]

        let details = CLIHandler.cleanConfirmationDetails(for: items)
        XCTAssertEqual(details["total_exact_bytes"] as? Int64, Int64.max,
                       "cross-scanner exact totals clamp instead of trapping")
        XCTAssertEqual(details["total_estimated_up_to_bytes"] as? Int64, 0)

        let payload = CLIHandler.cleanDryRunPayload(for: items)
        XCTAssertEqual(payload["total_would_free"] as? Int64, Int64.max,
                       "the dry-run total rides the same saturating sums")

        // The estimated column clamps independently through the same
        // helper.
        let estimated = [
            makeStandaloneItem(id: "est_a", scannerID: "scanner_a",
                               exact: 0, estimated: .max),
            makeStandaloneItem(id: "est_b", scannerID: "scanner_b",
                               exact: 0, estimated: .max),
        ]
        let estDetails = CLIHandler.cleanConfirmationDetails(for: estimated)
        XCTAssertEqual(
            estDetails["total_estimated_up_to_bytes"] as? Int64, Int64.max
        )
        XCTAssertEqual(estDetails["total_exact_bytes"] as? Int64, 0)
    }

    // MARK: - Smart-clean candidates (R18 CLI half, policy (c))

    func testSmartCleanCandidatesExcludeDeniedPartialAndCaution() {
        let safeMeasured = makeItem(
            state: .measured, category: makeCategory(name: "safe"),
            exact: 4096, items: 1
        )
        let reviewMeasured = makeItem(
            state: .measured, category: makeCategory(name: "review", risk: .review),
            exact: 8192, items: 1
        )
        let partial = makeItem(
            state: .partiallyDenied, category: makeCategory(name: "partial"),
            exact: 1 * gb, items: 1,
            scanError: ScanError(kind: .permissionDenied, message: "partial")
        )
        let denied = makeItem(
            state: .denied, category: makeCategory(name: "denied"),
            scanError: ScanError(kind: .tccDenied, message: "denied")
        )
        let caution = makeItem(
            state: .measured, category: makeCategory(name: "caution", risk: .caution),
            exact: 2 * gb, items: 1
        )
        let empty = makeItem(state: .empty, category: makeCategory(name: "empty"))

        let candidates = CLIHandler.smartCleanCandidates(
            [partial, caution, safeMeasured, denied, reviewMeasured, empty]
        )

        XCTAssertEqual(
            candidates.map(\.id), ["safe", "review"],
            ".partiallyDenied (measured bytes and all) and .denied are skipped by the "
            + "auto path (R18); caution and empty are ineligible; safe sorts before review"
        )
    }

    func testSmartCleanCandidatesParityAcrossDefaultSelectedAndExcludeIneligible() {
        // Parity fixtures crossing {safe, review} risk with {true, false}
        // defaultSelected: the decision output must be byte-identical to
        // schema 3, where defaultSelected never entered the smart-clean
        // decision — eligibility and ordering read risk + size ONLY.
        let safeSelected = makeItem(
            state: .measured,
            category: makeCategory(name: "safe_sel", defaultSelected: true),
            exact: 8 * gb, items: 1
        )
        let safeDeselected = makeItem(
            state: .measured,
            category: makeCategory(name: "safe_desel", defaultSelected: false),
            exact: 6 * gb, items: 1
        )
        let reviewSelected = makeItem(
            state: .measured,
            category: makeCategory(name: "review_sel", risk: .review, defaultSelected: true),
            exact: 10 * gb, items: 1
        )
        let reviewDeselected = makeItem(
            state: .measured,
            category: makeCategory(name: "review_desel", risk: .review, defaultSelected: false),
            exact: 2 * gb, items: 1
        )

        let candidates = CLIHandler.smartCleanCandidates(
            [reviewDeselected, safeDeselected, reviewSelected, safeSelected]
        )
        XCTAssertEqual(
            candidates.map(\.id),
            ["safe_sel", "safe_desel", "review_sel", "review_desel"],
            "safe-then-review, larger first within a tier — defaultSelected "
            + "plays NO part in the smart-clean decision (as-built parity)"
        )

        // THE one addition (epic contract): automaticCleanEligible == false
        // is excluded — node_modules becoming CLI-visible must never
        // silently enroll in the automatic path.
        let ineligible = makeStandaloneItem(
            id: "nm", scannerID: "node_modules", risk: .review,
            exact: 50 * gb, automaticCleanEligible: false
        )
        let withIneligible = CLIHandler.smartCleanCandidates(
            [ineligible, safeSelected, reviewSelected]
        )
        XCTAssertEqual(
            withIneligible.map(\.id), ["safe_sel", "review_sel"],
            "automaticCleanEligible == false items never become candidates, "
            + "whatever their size"
        )
    }

    // MARK: - Smart-clean loop decision: exact-only target math (R16)

    func testSmartCleanTargetMathIsExactOnly() {
        // Hardlink-heavy category: 10 GB estimated, ZERO exact. The pre-split
        // code would have counted 10 GB and claimed target_met.
        let hardlinkHeavy = makeItem(
            state: .measured, category: makeCategory(name: "links"),
            estimated: 10 * gb, items: 1
        )
        let plan = CLIHandler.smartCleanPlan(items: [hardlinkHeavy], targetBytes: 5 * gb)

        XCTAssertFalse(plan.targetMet, "estimated bytes never advance the target (R16)")
        XCTAssertEqual(plan.totalExact, 0)
        XCTAssertEqual(plan.totalEstimated, 10 * gb)
        XCTAssertEqual(plan.entries.count, 1,
                       "the category is still cleaned — it just cannot satisfy the target")
        XCTAssertEqual(plan.entries[0]["bytes_freed"] as? Int64, 0,
                       "per-entry freed bytes are exact-only")
        // Plan shape parity with `clean` (PROTOCOL.md details.plan).
        XCTAssertEqual(plan.entries[0]["state"] as? String, "measured")
        XCTAssertEqual(plan.entries[0]["action"] as? String, "clean")
        // Identity fields ride smart-clean rows too (schema 4).
        XCTAssertEqual(plan.entries[0]["scanner_id"] as? String, "categories")
        XCTAssertEqual(plan.entries[0]["item_id"] as? String, "links")
    }

    func testSmartCleanPlanMarksPostTargetCandidatesAsConditionalFallbacks() {
        // Same risk tier — ordering is by compatibility size descending:
        // links (10 GB estimated), exact6 (6 GB exact), small (4 KB).
        let hardlinkHeavy = makeItem(
            state: .measured, category: makeCategory(name: "links"),
            estimated: 10 * gb, items: 1
        )
        let exact6 = makeItem(
            state: .measured, category: makeCategory(name: "exact6"),
            exact: 6 * gb, items: 1
        )
        let small = makeItem(
            state: .measured, category: makeCategory(name: "small"),
            exact: 4096, items: 1
        )
        let plan = CLIHandler.smartCleanPlan(
            items: [small, exact6, hardlinkHeavy], targetBytes: 5 * gb
        )

        XCTAssertTrue(plan.targetMet)
        XCTAssertEqual(plan.totalExact, 6 * gb,
                       "projected totals count the unconditional entries only")
        XCTAssertEqual(
            plan.entries.map { $0["slug"] as? String }, ["links", "exact6", "small"],
            "every eligible candidate is DISCLOSED — the real loop advances on "
            + "delete-time bytes and may reach 'small' if an earlier category under-delivers"
        )
        XCTAssertEqual(
            plan.entries.map { $0["action"] as? String },
            ["clean", "clean", "clean_if_needed"],
            "candidates past the projected target-met point are conditional fallbacks"
        )
        // The fallback projects zero freed bytes but keeps its would-free
        // components intact.
        XCTAssertEqual(plan.entries[2]["bytes_freed"] as? Int64, 0)
        XCTAssertEqual(plan.entries[2]["exact_bytes"] as? Int64, 4096)
    }

    // MARK: - Exit decision: total vs partial failure (R5)

    func testCleanTotalFailureExitDecisionMatrix() {
        // No-op run (nothing requested/attempted) is a success.
        XCTAssertFalse(CLIHandler.cleanRunIsTotalFailure(
            successFlags: [], freedExact: 0, freedEstimated: 0
        ))
        // All succeeded.
        XCTAssertFalse(CLIHandler.cleanRunIsTotalFailure(
            successFlags: [true, true], freedExact: 4096, freedEstimated: 0
        ))
        // Zero-byte success (vacuous rows) is still a success.
        XCTAssertFalse(CLIHandler.cleanRunIsTotalFailure(
            successFlags: [true], freedExact: 0, freedEstimated: 0
        ))
        // PARTIAL: one failed beside one success — exit 0 with flags.
        XCTAssertFalse(CLIHandler.cleanRunIsTotalFailure(
            successFlags: [false, true], freedExact: 0, freedEstimated: 0
        ))
        // PARTIAL: every flag failed but bytes were freed (a category can
        // carry an entry AND errors) — exit 0.
        XCTAssertFalse(CLIHandler.cleanRunIsTotalFailure(
            successFlags: [false, false], freedExact: 4096, freedEstimated: 0
        ))
        XCTAssertFalse(CLIHandler.cleanRunIsTotalFailure(
            successFlags: [false, false], freedExact: 0, freedEstimated: 4096
        ))
        // TOTAL: everything failed, nothing freed — exit 1 CLEAN_FAILED.
        XCTAssertTrue(CLIHandler.cleanRunIsTotalFailure(
            successFlags: [false], freedExact: 0, freedEstimated: 0
        ))
        XCTAssertTrue(CLIHandler.cleanRunIsTotalFailure(
            successFlags: [false, false], freedExact: 0, freedEstimated: 0
        ))
    }

    // MARK: - Scan envelope (R2, R8)

    func testScanEnvelopeCategoriesRowsAreSchema3FieldForField() async throws {
        let measuredRoot = base.appendingPathComponent("measured-root")
        try fm.createDirectory(at: measuredRoot, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 4096).write(
            to: measuredRoot.appendingPathComponent("f.bin")
        )
        let emptyRoot = base.appendingPathComponent("empty-root")
        try fm.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let categories = [
            makeCategory(name: "measured_cat", path: measuredRoot.path),
            makeCategory(name: "empty_cat", path: emptyRoot.path),
            makeCategory(name: "missing_cat"),
        ]

        // The frozen schema-3 rows on the same fixture input.
        let direct = await CacheScanner(home: fixtureHome).scanAll(categories)
        let expected = direct.map { CLIHandler.scanItemJSON(for: $0) }

        let deps = try makeDeps(categories: categories)
        let envelope = await CLIHandler.scanEnvelope(deps: deps)

        XCTAssertEqual(envelope["schema_version"] as? Int, 4)
        let rows = try XCTUnwrap(envelope["categories"] as? [[String: Any]])
        XCTAssertEqual(
            rows as NSArray, expected as NSArray,
            "categories rows are field-for-field the schema-3 shape — same "
            + "keys, same values, same order (size-descending)"
        )
        for row in rows {
            XCTAssertNil(row["scanner_id"],
                         "NO identity fields on scan categories rows (round 7)")
            XCTAssertNil(row["item_id"])
        }
        XCTAssertEqual((envelope["scanner_items"] as? [[String: Any]])?.count, 0,
                       "no per-item scanner registered — additive key still present")
        XCTAssertEqual((envelope["scanner_errors"] as? [[String: Any]])?.count, 0)
    }

    func testScanEnvelopeDeniedCategoryRowParity() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let deniedRoot = base.appendingPathComponent("denied-root")
        try fm.createDirectory(at: deniedRoot, withIntermediateDirectories: true)
        try Data(repeating: 0xEF, count: 4096).write(
            to: deniedRoot.appendingPathComponent("f.bin")
        )
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: deniedRoot.path)
        addTeardownBlock { [fm] in
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deniedRoot.path)
        }
        let categories = [makeCategory(name: "denied_cat", path: deniedRoot.path)]

        let direct = await CacheScanner(home: fixtureHome).scanAll(categories)
        let expected = direct.map { CLIHandler.scanItemJSON(for: $0) }
        let envelope = await CLIHandler.scanEnvelope(deps: try makeDeps(categories: categories))
        let rows = try XCTUnwrap(envelope["categories"] as? [[String: Any]])

        XCTAssertEqual(rows as NSArray, expected as NSArray,
                       "denied rows (state + scan_error) survive the envelope byte-for-byte")
        XCTAssertEqual(rows[0]["state"] as? String, "denied")
        XCTAssertNotNil(rows[0]["scan_error"])
    }

    /// fn-4.5 (R6/R7/R12): the SAME envelope assertions as the node_modules
    /// twin above, on the slug that replaced it — plus the two properties
    /// the swap adds: no `node_modules` rows can exist (the scanner is
    /// unregistered), and the scanner's config/per-root issues ride
    /// `scanner_errors` rather than vanishing into a silent zero.
    ///
    /// The registry here is fixture-composed (the CategoryScanner over an
    /// EMPTY category list) for the usual reason: production categories run
    /// `.probed` tool subprocesses. The production COMPOSITION itself — that
    /// `build_artifacts` is registered and `node_modules` is not — is
    /// asserted against the real `production(...)` factory in
    /// `SpaceScannerIntegrationTests` and `CategoryScannerTests`.
    func testScanEnvelopeListsBuildArtifactsItemsAndNeverNodeModulesRows()
        async throws
    {
        let dev = base.appendingPathComponent("dev-\(UUID().uuidString)")
        let project = dev.appendingPathComponent("projA")
        let nodeModules = project.appendingPathComponent("node_modules")
        try fm.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try Data(repeating: 0xC3, count: 64).write(
            to: project.appendingPathComponent("package.json")
        )
        try Data(repeating: 0xAB, count: 8192).write(
            to: nodeModules.appendingPathComponent("dep.bin")
        )
        // A policy-rejected persisted root beside the good one: its config
        // issue must reach `scanner_errors` on every scan (R16).
        let suiteName = "CLIGateTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(["/", dev.path], forKey: DevRootsStore.devRootsKey)
        let scanner = BuildArtifactsScanner(
            home: fixtureHome,
            devRoots: DevRootsStore(defaults: suite)
                .effectiveRoots(home: fixtureHome)
        )
        let deps = try makeDeps(categories: [], extraScanners: [scanner])

        let envelope = await CLIHandler.scanEnvelope(deps: deps)

        XCTAssertEqual(envelope["schema_version"] as? Int, 4)
        let items = try XCTUnwrap(envelope["scanner_items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let row = items[0]
        XCTAssertEqual(row["scanner_id"] as? String, "build_artifacts")
        XCTAssertFalse(
            items.contains { $0["scanner_id"] as? String == "node_modules" },
            "the retired slug can never author a row — it is unregistered"
        )

        let itemID = try XCTUnwrap(row["item_id"] as? String)
        XCTAssertEqual(itemID.count, 64, "full-hash opaque id — never truncated")
        XCTAssertEqual(itemID, itemID.lowercased())
        XCTAssertTrue(itemID.allSatisfy { $0.isHexDigit })
        let resolved = FileSystemIdentityProvider()
            .resolveTargetKeepingLeaf(nodeModules)
        XCTAssertEqual(
            itemID,
            ReclaimableItem.stableID(
                scannerID: "build_artifacts", canonicalPath: resolved.path
            ),
            "the id IS the frozen preimage derivation — stable across rescans"
        )

        XCTAssertEqual(row["path"] as? String, resolved.path)
        XCTAssertEqual(row["name"] as? String, "node_modules")
        XCTAssertEqual(row["state"] as? String, "measured")
        XCTAssertEqual(row["action"] as? String, "remove_item")
        XCTAssertEqual(row["risk_level"] as? String, "review",
                       "the node_modules rule row preserves the as-built risk")
        XCTAssertTrue(((row["evidence"] as? String) ?? "")
            .contains("beside package.json"))
        let exact = try XCTUnwrap(row["exact_bytes"] as? Int64)
        XCTAssertGreaterThan(exact, 0)
        XCTAssertEqual(row["size_bytes"] as? Int64,
                       exact + (row["estimated_up_to_bytes"] as? Int64 ?? 0),
                       "size_bytes stays the compatibility component sum")

        // R12/R16: the classified config issue is VISIBLE on the wire.
        let errors = try XCTUnwrap(envelope["scanner_errors"] as? [[String: Any]])
        let refusals = errors.filter {
            $0["scanner_id"] as? String == "build_artifacts"
                && $0["kind"] as? String == "container_refused"
        }
        XCTAssertEqual(refusals.count, 1, "\(errors)")
        XCTAssertEqual(refusals[0]["path"] as? String, "/")
    }

    /// R12: a DENIED dev root is a classified, visible error on the wire —
    /// never a silent zero. The healthy root's items still ride the same
    /// envelope, so a partial failure is honestly partial.
    func testScanEnvelopeSurfacesDeniedDevRootBesideHealthyItems() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let dev = base.appendingPathComponent("dev-\(UUID().uuidString)")
        let denied = base.appendingPathComponent("denied-dev-\(UUID().uuidString)")
        let project = dev.appendingPathComponent("rust")
        let artifact = project.appendingPathComponent("target")
        try fm.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data(repeating: 0xC3, count: 64).write(
            to: project.appendingPathComponent("Cargo.toml")
        )
        try Data(repeating: 0xAB, count: 4096).write(
            to: artifact.appendingPathComponent("out.o")
        )
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        addTeardownBlock { [fm] in
            try? fm.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: denied.path
            )
        }

        let suiteName = "CLIGateTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let scanner = BuildArtifactsScanner(
            home: fixtureHome,
            devRoots: DevRootsStore(defaults: suite)
                .effectiveRoots(replacing: [dev, denied], home: fixtureHome)
        )
        let deps = try makeDeps(categories: [], extraScanners: [scanner])

        let envelope = await CLIHandler.scanEnvelope(deps: deps)

        let errors = try XCTUnwrap(envelope["scanner_errors"] as? [[String: Any]])
        let denials = errors.filter { $0["path"] as? String == denied.path }
        XCTAssertEqual(denials.count, 1, "\(errors)")
        XCTAssertEqual(denials[0]["scanner_id"] as? String, "build_artifacts")
        XCTAssertEqual(denials[0]["kind"] as? String, "permission_denied")
        XCTAssertFalse((denials[0]["detail"] as? String ?? "").isEmpty)

        let items = try XCTUnwrap(envelope["scanner_items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["name"] as? String }, ["target"],
                       "the readable root's items are unaffected")
    }

    func testScanEnvelopeListsNodeModulesItems() async throws {
        let fixture = try makeNodeModulesFixture()
        let deps = try makeDeps(categories: [], extraScanners: [fixture.scanner])

        let envelope = await CLIHandler.scanEnvelope(deps: deps)

        XCTAssertEqual(envelope["schema_version"] as? Int, 4)
        let items = try XCTUnwrap(envelope["scanner_items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let row = items[0]
        XCTAssertEqual(row["scanner_id"] as? String, "node_modules")

        let itemID = try XCTUnwrap(row["item_id"] as? String)
        XCTAssertEqual(itemID.count, 64, "full-hash opaque id — never truncated")
        XCTAssertEqual(itemID, itemID.lowercased())
        XCTAssertTrue(itemID.allSatisfy { $0.isHexDigit },
                      "64 lowercase-hex chars, always beside its scanner_id sibling")
        let resolved = FileSystemIdentityProvider().canonicalize(fixture.nodeModules)
        XCTAssertEqual(
            itemID,
            ReclaimableItem.stableID(scannerID: "node_modules", canonicalPath: resolved.path),
            "the id IS the frozen preimage derivation — stable across rescans"
        )

        XCTAssertEqual(row["path"] as? String, resolved.path)
        XCTAssertEqual(row["name"] as? String, "projA")
        XCTAssertEqual(row["state"] as? String, "measured")
        XCTAssertEqual(row["action"] as? String, "remove_item")
        XCTAssertEqual(row["risk_level"] as? String, "review",
                       "the frozen node_modules risk mapping (round 11)")
        XCTAssertTrue(((row["evidence"] as? String) ?? "").contains("projA"))
        let exact = try XCTUnwrap(row["exact_bytes"] as? Int64)
        XCTAssertGreaterThan(exact, 0)
        XCTAssertEqual(row["size_bytes"] as? Int64,
                       exact + (row["estimated_up_to_bytes"] as? Int64 ?? 0),
                       "size_bytes stays the compatibility component sum")
    }

    func testScanEnvelopeScannerErrorsBothForms() async throws {
        // Filesystem-kind issue: carries its real path.
        let refusedRoot = base.appendingPathComponent("refused-root")
        let errScanner = FixtureScanner(
            id: "err_scanner",
            errors: [ScanIssue(
                url: refusedRoot, kind: .permissionDenied, detail: "fixture denial"
            )]
        )
        // Malformed scanner: emits an item owned by someone else — the
        // validator replaces the WHOLE outcome with a path-less issue.
        let foreign = makeStandaloneItem(id: "abc", scannerID: "someone_else")
        let badScanner = FixtureScanner(id: "bad_scanner", items: [foreign])
        // A valid scanner in the same run keeps publishing — declaring the
        // origin container its item claims (round 6 origin binding).
        let good = makeStandaloneItem(id: "ok1", scannerID: "good_scanner")
        let goodScanner = FixtureScanner(
            id: "good_scanner",
            trustedContainerRoots: [URL(fileURLWithPath: "/tmp/fixture-container")],
            items: [good]
        )

        let deps = try makeDeps(
            categories: [],
            extraScanners: [errScanner, badScanner, goodScanner]
        )
        let envelope = await CLIHandler.scanEnvelope(deps: deps)

        let errors = try XCTUnwrap(envelope["scanner_errors"] as? [[String: Any]])
        XCTAssertEqual(errors.count, 2)

        // Exact JSON, filesystem form: path PRESENT.
        XCTAssertEqual(errors[0] as NSDictionary, [
            "scanner_id": "err_scanner",
            "kind": "permission_denied",
            "detail": "fixture denial",
            "path": refusedRoot.path,
        ] as NSDictionary)

        // Exact-shape assertion, malformed form: NO path key at all — the
        // detail is the validator's synthesized message.
        let malformedRow = errors[1]
        XCTAssertEqual(malformedRow["scanner_id"] as? String, "bad_scanner")
        XCTAssertEqual(malformedRow["kind"] as? String, "malformed_outcome")
        XCTAssertNil(malformedRow["path"],
                     "no filesystem location exists — a fake path must never be invented")
        XCTAssertEqual(
            Set(malformedRow.keys), ["scanner_id", "kind", "detail"],
            "the malformed row carries exactly scanner_id/kind/detail"
        )

        // The malformed scanner's items are EXCLUDED; the valid scanner's
        // rows are intact (excluded-and-report, proceed with the rest).
        let items = try XCTUnwrap(envelope["scanner_items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["item_id"] as? String }, ["ok1"])
        XCTAssertEqual(items[0]["scanner_id"] as? String, "good_scanner")
    }

    func testNoArgvContentAppearsInAnyCLIPayload() async throws {
        // A `.commands` category whose argv carries a sentinel token: the
        // JSON is a reporting surface, not an execution contract — the argv
        // arrays must never appear in scan, clean, or smart-clean output.
        let token = "SECRET_ARGV_TOKEN_XYZZY"
        let root = base.appendingPathComponent("cmd-root")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 4096).write(
            to: root.appendingPathComponent("f.bin")
        )
        let commandCat = makeCategory(
            name: "cmd_cat", path: root.path,
            cleanCommands: [["true", token]]
        )
        let deps = try makeDeps(categories: [commandCat])

        let envelope = await CLIHandler.scanEnvelope(deps: deps)
        XCTAssertFalse(try jsonString(envelope).contains(token),
                       "scan output never carries argv content")

        let unconfirmed = try failureOutcome(await CLIHandler.cleanCLIOutcome(
            targets: ["cmd_cat"], dryRun: false, confirmed: false, euid: 501, deps: deps
        ))
        XCTAssertEqual(unconfirmed.code, "CONFIRMATION_REQUIRED")
        XCTAssertFalse(try jsonString(unconfirmed.details ?? [:]).contains(token),
                       "the confirmation plan never carries argv content")

        let dryRun = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["cmd_cat"], dryRun: true, confirmed: false, euid: 501, deps: deps
        ))
        XCTAssertFalse(try jsonString(dryRun).contains(token))

        let smartDry = try successPayload(await CLIHandler.smartCleanCLIOutcome(
            targetGB: 0.001, dryRun: true, confirmed: false, euid: 501, deps: deps
        ))
        XCTAssertFalse(try jsonString(smartDry).contains(token))

        // Confirmed run: `/usr/bin/env true <token>` executes harmlessly;
        // the result payload reports the commands entry without argv.
        let confirmed = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["cmd_cat"], dryRun: false, confirmed: true, euid: 501, deps: deps
        ))
        XCTAssertFalse(try jsonString(confirmed).contains(token))
        let rows = try XCTUnwrap(confirmed["results"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["success"] as? Bool, true)
    }

    // MARK: - Frozen wire values, complete matrix (R8)

    func testFrozenWireValuesAssertedExactlyOnCLIRows() throws {
        // ALL THREE ReclaimAction wire strings, asserted through the CLI's
        // scanner_items row builder (permanent external contract — fn-3..6
        // and cacheout-mcp inherit these values verbatim). The `.commands`
        // case doubles as the argv non-exposure proof at the row level:
        // ONLY the kind is serialized.
        let actionMatrix: [(ReclaimAction, String)] = [
            (.removeContents, "remove_contents"),
            (.removeItem, "remove_item"),
            (.commands([["rm", "-rf", "NEVER_ON_THE_WIRE"]]), "commands"),
        ]
        for (action, wire) in actionMatrix {
            let row = CLIHandler.scannerItemRowJSON(
                for: makeStandaloneItem(id: "wire_\(wire)", action: action)
            )
            XCTAssertEqual(row["action"] as? String, wire,
                           "frozen wire string for \(wire)")
            XCTAssertFalse(try jsonString(row).contains("NEVER_ON_THE_WIRE"),
                           "argv arrays never appear in any row")
        }

        // ALL SEVEN ScanIssue.Kind wire strings through the scanner_errors
        // row builder — exact rows: the five filesystem kinds carry their
        // real `path`; the non-filesystem kinds (`malformed_outcome`,
        // `config_invalid`) have NO path key at all; `tcc_denied` ALONE
        // additionally carries `grant_hint` (macOS denies CLI processes
        // silently — the row must say what to do about it).
        let url = URL(fileURLWithPath: "/tmp/wire-fixture-root")
        let filesystemKinds: [(ScanIssue.Kind, String)] = [
            (.containerRefused, "container_refused"),
            (.symlinkRoot, "symlink_root"),
            (.permissionDenied, "permission_denied"),
            (.unreadable, "unreadable"),
        ]
        for (kind, wire) in filesystemKinds {
            let row = CLIHandler.scannerErrorRowJSON(
                scannerID: "wire_scanner",
                issue: ScanIssue(url: url, kind: kind, detail: "fixture detail")
            )
            XCTAssertEqual(row as NSDictionary, [
                "scanner_id": "wire_scanner",
                "kind": wire,
                "detail": "fixture detail",
                "path": url.path,
            ] as NSDictionary, "exact row for filesystem kind \(wire) — no grant_hint")
        }
        let tccRow = CLIHandler.scannerErrorRowJSON(
            scannerID: "wire_scanner",
            issue: ScanIssue(url: url, kind: .tccDenied, detail: "fixture detail")
        )
        XCTAssertEqual(tccRow as NSDictionary, [
            "scanner_id": "wire_scanner",
            "kind": "tcc_denied",
            "detail": "fixture detail",
            "path": url.path,
            "grant_hint": CLIHandler.tccGrantHint,
        ] as NSDictionary, "tcc_denied alone carries the FDA remedy")
        let malformedRow = CLIHandler.scannerErrorRowJSON(
            scannerID: "wire_scanner",
            issue: ScanIssue(url: nil, kind: .malformedOutcome, detail: "fixture detail")
        )
        XCTAssertEqual(malformedRow as NSDictionary, [
            "scanner_id": "wire_scanner",
            "kind": "malformed_outcome",
            "detail": "fixture detail",
        ] as NSDictionary, "malformed_outcome is path-less by contract")
        let configInvalidRow = CLIHandler.scannerErrorRowJSON(
            scannerID: "wire_scanner",
            issue: ScanIssue(url: nil, kind: .configInvalid,
                             detail: "fixture detail")
        )
        XCTAssertEqual(configInvalidRow as NSDictionary, [
            "scanner_id": "wire_scanner",
            "kind": "config_invalid",
            "detail": "fixture detail",
        ] as NSDictionary, "config_invalid is path-less by contract (fn-4 — "
            + "a config parse failure has no honest filesystem path)")

        // The frozen aggregate scanner id on clean-side identity fields —
        // the literal string, not just the constant (a renamed constant
        // must not silently change the wire).
        let aggregateRow = CLIHandler.cleanPlanItemJSON(
            for: makeItem(state: .measured, exact: 4096, items: 1)
        )
        XCTAssertEqual(aggregateRow["scanner_id"] as? String, "categories")
    }

    /// fn-4.4: the two ADDITIVE `scanner_items` fields, at the shared row
    /// builder every scanner's items flow through. Absence is the DEFAULT —
    /// an item that carries neither must emit neither key (never `null`), so
    /// no existing scanner's envelope changes shape.
    func testAdditiveLogicalBytesAndValuablesRowFieldsAreOmittedByDefault()
        throws
    {
        let plain = makeStandaloneItem(id: "plain")
        let plainRow = CLIHandler.scannerItemRowJSON(for: plain)
        XCTAssertNil(plain.logicalBytes)
        XCTAssertNil(plain.valuablesDisclosure)
        XCTAssertFalse(plainRow.keys.contains("logical_bytes"))
        XCTAssertFalse(plainRow.keys.contains("valuables"))

        // The ONE pinned SIX-FIELD element shape, asserted as an EXACT row —
        // plan rows and refusal rows (fn-4.9) REUSE this builder, so this is
        // the one place the shape is pinned.
        let valuable = DetectedValuable(
            name: "Murmur_0.1.7_aarch64.dmg",
            displayURL: URL(fileURLWithPath: "/alias/target/dmg/Murmur.dmg"),
            canonicalIdentityPath: "/canonical/target/dmg/Murmur.dmg",
            identity: ValuableIdentity(
                allocatedBytes: 44_040_192, device: 16_777_232,
                inode: 12_345_678, modifiedSeconds: 1_755_057_600,
                modifiedNanoseconds: 123_456_789
            )
        )
        XCTAssertEqual(CLIHandler.valuableRowJSON(for: valuable) as NSDictionary, [
            "name": "Murmur_0.1.7_aarch64.dmg",
            "path": "/canonical/target/dmg/Murmur.dmg",
            "allocated_bytes": Int64(44_040_192),
            "device": UInt64(16_777_232),
            "inode": UInt64(12_345_678),
            "modified_at_ns": Int64(1_755_057_600_123_456_789),
        ] as NSDictionary, "the pinned valuables element — the display "
            + "spelling never reaches the wire")
    }

    // MARK: - Address grammar (R7)

    func testCleanTargetGrammarAllThreeFormsResolve() async throws {
        let catRoot = base.appendingPathComponent("cat-root")
        try fm.createDirectory(at: catRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x22, count: 4096).write(
            to: catRoot.appendingPathComponent("f.bin")
        )
        let category = makeCategory(name: "cat_a", path: catRoot.path)
        let fixture = try makeNodeModulesFixture()
        let deps = try makeDeps(categories: [category], extraScanners: [fixture.scanner])

        // Echo-back: the item id comes from scan output, never derived.
        let envelope = await CLIHandler.scanEnvelope(deps: deps)
        let scanItems = try XCTUnwrap(envelope["scanner_items"] as? [[String: Any]])
        let itemID = try XCTUnwrap(scanItems.first?["item_id"] as? String)

        // Form 1: bare category slug (aggregate, unchanged from schema 3).
        let bySlug = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["cat_a"], dryRun: true, confirmed: false, euid: 501, deps: deps
        ))
        let slugRows = try XCTUnwrap(bySlug["results"] as? [[String: Any]])
        XCTAssertEqual(slugRows.map { $0["slug"] as? String }, ["cat_a"])
        XCTAssertEqual(slugRows[0]["scanner_id"] as? String, "categories")

        // Form 2: bare per-item scanner slug — ALL its items.
        let byScanner = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["node_modules"], dryRun: true, confirmed: false, euid: 501, deps: deps
        ))
        let scannerRows = try XCTUnwrap(byScanner["results"] as? [[String: Any]])
        XCTAssertEqual(scannerRows.map { $0["slug"] as? String },
                       ["node_modules:\(itemID)"])

        // Form 3: `<scanner-slug>:<item-id>` — one item, id echoed back.
        let byAddress = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["node_modules:\(itemID)"], dryRun: true, confirmed: false,
            euid: 501, deps: deps
        ))
        let addressRows = try XCTUnwrap(byAddress["results"] as? [[String: Any]])
        XCTAssertEqual(addressRows.count, 1)
        XCTAssertEqual(addressRows[0]["item_id"] as? String, itemID)

        // Mixed forms in one invocation resolve together, deduped by item.
        let mixed = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["cat_a", "node_modules", "node_modules:\(itemID)"],
            dryRun: true, confirmed: false, euid: 501, deps: deps
        ))
        let mixedRows = try XCTUnwrap(mixed["results"] as? [[String: Any]])
        XCTAssertEqual(
            mixedRows.map { $0["slug"] as? String },
            ["cat_a", "node_modules:\(itemID)"],
            "an item named twice (scanner-wide + addressed) appears once, argument order kept"
        )
    }

    func testCleanUnknownTargetsAreInvalidArguments() async throws {
        let fixture = try makeNodeModulesFixture()
        let deps = try makeDeps(
            categories: [makeCategory(name: "cat_a")],
            extraScanners: [fixture.scanner]
        )

        for target in ["nope", "node_modules:" + String(repeating: "0", count: 64),
                       "node_modules:", "cat_a:whatever", "nope:abc"] {
            let failure = try failureOutcome(await CLIHandler.cleanCLIOutcome(
                targets: [target], dryRun: true, confirmed: false, euid: 501, deps: deps
            ))
            XCTAssertEqual(failure.code, "INVALID_ARGUMENTS",
                           "'\(target)' must be refused with INVALID_ARGUMENTS parity")
        }
    }

    func testFrozenCategoriesIDIsNotAValidTargetAndCleansNothing() async throws {
        let catRoot = base.appendingPathComponent("agg-root")
        try fm.createDirectory(at: catRoot, withIntermediateDirectories: true)
        let marker = catRoot.appendingPathComponent("survivor.bin")
        try Data(repeating: 0x33, count: 4096).write(to: marker)
        let deps = try makeDeps(categories: [makeCategory(name: "cat_a", path: catRoot.path)])

        for target in ["categories", "categories:cat_a"] {
            let failure = try failureOutcome(await CLIHandler.cleanCLIOutcome(
                targets: [target], dryRun: false, confirmed: true, euid: 501, deps: deps
            ))
            XCTAssertEqual(failure.code, "INVALID_ARGUMENTS",
                           "the frozen aggregate scanner id is excluded from addressing ('\(target)')")
        }
        XCTAssertTrue(fm.fileExists(atPath: marker.path),
                      "a refused 'categories' token cleans NOTHING — even with --confirm")
    }

    // MARK: - Target-scoped scanning (R2)

    func testCategoryCleanNeverInvokesPerItemScanner() async throws {
        let catRoot = base.appendingPathComponent("scope-root")
        try fm.createDirectory(at: catRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 4096).write(
            to: catRoot.appendingPathComponent("f.bin")
        )
        let recorder = ScanCallRecorder()
        let fixture = FixtureScanner(id: "recorder_scanner", recorder: recorder)
        let deps = try makeDeps(
            categories: [makeCategory(name: "cat_a", path: catRoot.path)],
            extraScanners: [fixture]
        )

        let confirmed = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["cat_a"], dryRun: false, confirmed: true, euid: 501, deps: deps
        ))
        XCTAssertEqual(confirmed["schema_version"] as? Int, 4)
        let calls = await recorder.count()
        XCTAssertEqual(
            calls, 0,
            "a category-targeted clean records ZERO per-item scanner scan calls "
            + "— without the subset it would walk Documents/Desktop (TCC prompts)"
        )
    }

    func testSmartCleanInvokesOnlyTheCategoriesScanner() async throws {
        let catRoot = base.appendingPathComponent("smart-root")
        try fm.createDirectory(at: catRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 4096).write(
            to: catRoot.appendingPathComponent("f.bin")
        )
        let recorder = ScanCallRecorder()
        let fixture = FixtureScanner(id: "recorder_scanner", recorder: recorder)
        let deps = try makeDeps(
            categories: [makeCategory(name: "cat_a", path: catRoot.path)],
            extraScanners: [fixture]
        )

        let payload = try successPayload(await CLIHandler.smartCleanCLIOutcome(
            targetGB: 0.000001, dryRun: false, confirmed: true, euid: 501, deps: deps
        ))
        XCTAssertEqual(payload["schema_version"] as? Int, 4)
        let cleaned = try XCTUnwrap(payload["cleaned"] as? [[String: Any]])
        XCTAssertEqual(cleaned.map { $0["slug"] as? String }, ["cat_a"])
        XCTAssertEqual(cleaned[0]["scanner_id"] as? String, "categories",
                       "smart-clean aggregate rows carry the frozen 'categories' id")
        XCTAssertEqual(cleaned[0]["item_id"] as? String, "cat_a")
        let calls = await recorder.count()
        XCTAssertEqual(calls, 0,
                       "smart-clean scans the aggregate `categories` scanner ONLY (round 10)")
    }

    func testCategoryGranularScopingNeverInvokesUnrequestedResolvers() async throws {
        // Probe-counting categories: each resolver evaluation leaves one
        // observable mark, proving when probes run — and when they do NOT.
        func probeCategory(slug: String, dir: URL) -> CacheCategory {
            CacheCategory(
                name: slug, slug: slug,
                description: "probe-counting fixture \(slug)",
                icon: "trash",
                discovery: [.probed(
                    command: "printf x >> \"$HOME/probe-\(slug)-count\"; echo \(dir.path)",
                    requiresTool: nil,
                    fallbacks: [dir.path]
                )],
                riskLevel: .safe, rebuildNote: "", defaultSelected: true
            )
        }
        func probeCount(_ slug: String) -> Int {
            (try? Data(contentsOf: fixtureHome.appendingPathComponent("probe-\(slug)-count")))?.count ?? 0
        }

        let dirA = base.appendingPathComponent("probe-a")
        try fm.createDirectory(at: dirA, withIntermediateDirectories: true)
        try Data(repeating: 0x66, count: 4096).write(to: dirA.appendingPathComponent("a.bin"))
        let dirB = base.appendingPathComponent("probe-b")
        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data(repeating: 0x77, count: 4096).write(to: dirB.appendingPathComponent("b.bin"))

        let deps = try makeDeps(categories: [
            probeCategory(slug: "cat_a", dir: dirA),
            probeCategory(slug: "cat_b", dir: dirB),
        ])

        _ = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["cat_a"], dryRun: false, confirmed: true, euid: 501, deps: deps
        ))

        XCTAssertEqual(probeCount("cat_a"), 1, "the requested category's resolver ran once")
        XCTAssertEqual(
            probeCount("cat_b"), 0,
            "the UNREQUESTED category's resolver/probe is NEVER invoked — "
            + "requested-categories-only holds at category granularity (round 10)"
        )
        XCTAssertTrue(fm.fileExists(atPath: dirB.appendingPathComponent("b.bin").path),
                      "the unrequested category's content is untouched")
    }

    // MARK: - node_modules clean behind --confirm (R2, the acceptance headline)

    func testNodeModulesCleanWithoutConfirmIsRefusedWithPlan() async throws {
        let fixture = try makeNodeModulesFixture()
        let deps = try makeDeps(categories: [], extraScanners: [fixture.scanner])
        let envelope = await CLIHandler.scanEnvelope(deps: deps)
        let itemID = try XCTUnwrap(
            (envelope["scanner_items"] as? [[String: Any]])?.first?["item_id"] as? String
        )

        let failure = try failureOutcome(await CLIHandler.cleanCLIOutcome(
            targets: ["node_modules:\(itemID)"], dryRun: false, confirmed: false,
            euid: 501, deps: deps
        ))

        XCTAssertEqual(failure.code, "CONFIRMATION_REQUIRED")
        let details = try XCTUnwrap(failure.details)
        let plan = try XCTUnwrap(details["plan"] as? [[String: Any]])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0]["slug"] as? String, "node_modules:\(itemID)")
        XCTAssertEqual(plan[0]["action"] as? String, "clean")
        XCTAssertTrue(fm.fileExists(atPath: fixture.nodeModules.path),
                      "an unconfirmed clean deletes NOTHING")
    }

    func testNodeModulesConfirmedCleanDeletesAndReportsExactRow() async throws {
        let fixture = try makeNodeModulesFixture()
        let deps = try makeDeps(categories: [], extraScanners: [fixture.scanner])
        let envelope = await CLIHandler.scanEnvelope(deps: deps)
        let itemID = try XCTUnwrap(
            (envelope["scanner_items"] as? [[String: Any]])?.first?["item_id"] as? String
        )
        let address = "node_modules:\(itemID)"

        let payload = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: [address], dryRun: false, confirmed: true, euid: 501, deps: deps
        ))

        // The confirmed deletion, exercised IN-PROCESS through the injected
        // bundle: the node_modules tree is gone, its project dir survives.
        XCTAssertFalse(fm.fileExists(atPath: fixture.nodeModules.path),
                       "the addressed node_modules tree is deleted")
        XCTAssertTrue(
            fm.fileExists(atPath: fixture.nodeModules.deletingLastPathComponent().path),
            "the project directory itself survives"
        )

        XCTAssertEqual(payload["schema_version"] as? Int, 4)
        let rows = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        // Exact row contract (R8): the retained `category` key IS the
        // composite address, with separate sibling identity fields whose
        // concatenation matches it.
        XCTAssertEqual(row["category"] as? String, address)
        XCTAssertEqual(row["scanner_id"] as? String, "node_modules")
        XCTAssertEqual(row["item_id"] as? String, itemID)
        XCTAssertEqual(
            "\(row["scanner_id"] as? String ?? ""):\(row["item_id"] as? String ?? "")",
            row["category"] as? String,
            "consumers never parse the composite — the siblings reproduce it"
        )
        XCTAssertEqual(row["name"] as? String, "projA")
        XCTAssertEqual(row["success"] as? Bool, true)
        let freed = try XCTUnwrap(row["bytes_freed"] as? Int64)
        XCTAssertGreaterThan(freed, 0)
        XCTAssertEqual(row["exact_bytes"] as? Int64, freed)

        // Per-scanner rollup rides additively (fn-2.3's report on the wire).
        let rollups = try XCTUnwrap(payload["scanner_rollups"] as? [[String: Any]])
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0]["scanner_id"] as? String, "node_modules")
        XCTAssertEqual(rollups[0]["entry_count"] as? Int, 1)
        XCTAssertEqual(rollups[0]["exact_bytes"] as? Int64, freed)
    }

    func testExplicitlyAddressedEmptyPerItemCandidateIsANoOp() async throws {
        // An EMPTY node_modules dir: recognized, emitted as `.empty` —
        // explicitly addressing it with --confirm deletes nothing, yields
        // NO result row, and stays a process-level success (round 9).
        let fixture = try makeNodeModulesFixture(project: "emptyProj", withContent: false)
        let deps = try makeDeps(categories: [], extraScanners: [fixture.scanner])
        let envelope = await CLIHandler.scanEnvelope(deps: deps)
        let items = try XCTUnwrap(envelope["scanner_items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["state"] as? String, "empty",
                       ".empty is emitted and addressable-in-form — an honest state")
        let itemID = try XCTUnwrap(items.first?["item_id"] as? String)

        let payload = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["node_modules:\(itemID)"], dryRun: false, confirmed: true,
            euid: 501, deps: deps
        ))

        XCTAssertTrue(fm.fileExists(atPath: fixture.nodeModules.path),
                      "nothing is deleted for an .empty candidate")
        XCTAssertEqual((payload["results"] as? [[String: Any]])?.count, 0,
                       "no result entry — the cleaner's silent pre-admission skip surfaces as absence")
        XCTAssertEqual(payload["total_freed_bytes"] as? Int64, 0)
    }

    // MARK: - Scanner-wide targets surface scan impediments (P2)

    /// A REAL removable per-item fixture (`<container>/projX` with content)
    /// emitted by a FixtureScanner that ALSO reports root-level issues —
    /// the shapes a TCC/permission-impeded per-item scanner produces.
    private func makeImpededScannerFixture(
        id: String, errors: [ScanIssue]
    ) throws -> (scanner: FixtureScanner, itemDir: URL, address: String) {
        let container = base.appendingPathComponent("\(id)-container")
        let itemDir = container.appendingPathComponent("projX")
        try fm.createDirectory(at: itemDir, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 8192).write(
            to: itemDir.appendingPathComponent("payload.bin")
        )
        let resolved = FileSystemIdentityProvider().canonicalize(itemDir)
        let itemID = ReclaimableItem.stableID(
            scannerID: id, canonicalPath: resolved.path
        )
        let item = ReclaimableItem(
            id: itemID, scannerID: id, displayName: "projX",
            exactBytes: 8192, estimatedUpToBytes: 0,
            logicalBytes: nil, itemCount: 1,
            url: resolved, declaredDisplayPath: itemDir.path,
            rootRecords: [RootScanRecord(
                requestedURL: itemDir, resolvedURL: resolved, status: .measured
            )],
            state: .measured, scanError: nil,
            risk: .review, evidence: "fixture item", rebuildNote: nil,
            action: .removeItem,
            admission: .containerItem(
                originContainer: container, requestedTargetURL: itemDir
            ),
            defaultSelected: false, automaticCleanEligible: false,
            isStale: nil
        )
        let scanner = FixtureScanner(
            id: id, trustedContainerRoots: [container],
            items: [item], errors: errors
        )
        return (scanner, itemDir, "\(id):\(itemID)")
    }

    func testScannerWideCleanFullDenialIsAVisiblyImpededNoOp() async throws {
        // Every search root TCC-denied: the scan produced NO items, only
        // root-level issues. The bare `<scanner-slug>` clean must carry
        // those issues on EVERY branch — full denial is an impeded no-op,
        // never a silent success (P2).
        let deniedRoot = base.appendingPathComponent("denied-root")
        let fixture = FixtureScanner(
            id: "denied_scanner",
            errors: [ScanIssue(
                url: deniedRoot, kind: .tccDenied, detail: "fixture TCC denial"
            )]
        )
        let deps = try makeDeps(categories: [], extraScanners: [fixture])
        // The frozen `scan` scanner_errors row shape, verbatim — a TCC
        // denial carries `grant_hint` (the clean surface reuses `scan`'s
        // row builder, so the remedy rides along here too).
        let expectedRow: NSDictionary = [
            "scanner_id": "denied_scanner",
            "kind": "tcc_denied",
            "detail": "fixture TCC denial",
            "path": deniedRoot.path,
            "grant_hint": CLIHandler.tccGrantHint,
        ]

        // Unconfirmed: the plan is empty but the impediment rides the details.
        let unconfirmed = try failureOutcome(await CLIHandler.cleanCLIOutcome(
            targets: ["denied_scanner"], dryRun: false, confirmed: false,
            euid: 501, deps: deps
        ))
        XCTAssertEqual(unconfirmed.code, "CONFIRMATION_REQUIRED")
        let details = try XCTUnwrap(unconfirmed.details)
        XCTAssertEqual((details["plan"] as? [[String: Any]])?.count, 0)
        let planErrors = try XCTUnwrap(details["scanner_errors"] as? [[String: Any]])
        XCTAssertEqual(planErrors.count, 1)
        XCTAssertEqual(planErrors[0] as NSDictionary, expectedRow)

        // Dry run: empty results, zero bytes — WITH the denial rows.
        let dryRun = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["denied_scanner"], dryRun: true, confirmed: false,
            euid: 501, deps: deps
        ))
        XCTAssertEqual((dryRun["results"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(dryRun["total_would_free"] as? Int64, 0)
        let dryErrors = try XCTUnwrap(dryRun["scanner_errors"] as? [[String: Any]])
        XCTAssertEqual(dryErrors[0] as NSDictionary, expectedRow)

        // Confirmed: STILL a process-level success — scan-time impediments
        // are payload data (the `scan` envelope precedent; CLEAN_FAILED
        // stays a delete-time verdict) — but never a SILENT no-op.
        let confirmed = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["denied_scanner"], dryRun: false, confirmed: true,
            euid: 501, deps: deps
        ))
        XCTAssertEqual((confirmed["results"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(confirmed["total_freed_bytes"] as? Int64, 0)
        let confirmedErrors = try XCTUnwrap(confirmed["scanner_errors"] as? [[String: Any]])
        XCTAssertEqual(confirmedErrors[0] as NSDictionary, expectedRow)
    }

    func testScannerWideCleanPartialDenialReportsRowsPlusScannerErrors() async throws {
        // One root scanned (its item is real and deletable), one root
        // denied: the confirmed scanner-wide clean reports the accessible
        // subset's success rows AND says the target was incomplete.
        let otherRoot = base.appendingPathComponent("unreadable-root")
        let fixture = try makeImpededScannerFixture(
            id: "px_scanner",
            errors: [ScanIssue(
                url: otherRoot, kind: .permissionDenied, detail: "fixture EACCES"
            )]
        )
        let deps = try makeDeps(categories: [], extraScanners: [fixture.scanner])

        let payload = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["px_scanner"], dryRun: false, confirmed: true,
            euid: 501, deps: deps
        ))

        XCTAssertFalse(fm.fileExists(atPath: fixture.itemDir.path),
                       "the accessible item is cleaned for real")
        let rows = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["success"] as? Bool, true)
        XCTAssertGreaterThan(try XCTUnwrap(rows[0]["bytes_freed"] as? Int64), 0)
        let errors = try XCTUnwrap(payload["scanner_errors"] as? [[String: Any]])
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0] as NSDictionary, [
            "scanner_id": "px_scanner",
            "kind": "permission_denied",
            "detail": "fixture EACCES",
            "path": otherRoot.path,
        ] as NSDictionary)
    }

    func testExplicitItemAddressCarriesNoScannerErrors() async throws {
        // Root-level issues do NOT impede an explicitly addressed item that
        // WAS discovered — `<scanner>:<item>` payloads stay byte-identical
        // to their pre-P2 shape (the additive key is scanner-wide only).
        let fixture = try makeImpededScannerFixture(
            id: "px_scanner",
            errors: [ScanIssue(
                url: base.appendingPathComponent("unreadable-root"),
                kind: .permissionDenied, detail: "fixture EACCES"
            )]
        )
        let deps = try makeDeps(categories: [], extraScanners: [fixture.scanner])

        let dryRun = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: [fixture.address], dryRun: true, confirmed: false,
            euid: 501, deps: deps
        ))
        XCTAssertEqual((dryRun["results"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(dryRun["scanner_errors"],
                     "scanner-level issues ride only scanner-WIDE targets")
    }

    // MARK: - Malformed outcomes are unaddressable through clean (R2, R8)

    func testMalformedScannerItemsAreUnreachableThroughClean() async throws {
        let foreign = makeStandaloneItem(id: "forged1", scannerID: "someone_else")
        let badScanner = FixtureScanner(id: "bad_scanner", items: [foreign])
        let catRoot = base.appendingPathComponent("valid-root")
        try fm.createDirectory(at: catRoot, withIntermediateDirectories: true)
        let survivor = catRoot.appendingPathComponent("f.bin")
        try Data(repeating: 0x88, count: 4096).write(to: survivor)
        let deps = try makeDeps(
            categories: [makeCategory(name: "cat_valid", path: catRoot.path)],
            extraScanners: [badScanner]
        )

        // Addressing the malformed scanner's item id — and the scanner
        // wholesale — resolves to the unknown/invalid-target error; nothing
        // is selected, addressed, or deleted.
        for target in ["bad_scanner:forged1", "bad_scanner"] {
            let failure = try failureOutcome(await CLIHandler.cleanCLIOutcome(
                targets: [target], dryRun: false, confirmed: true, euid: 501, deps: deps
            ))
            XCTAssertEqual(failure.code, "INVALID_ARGUMENTS")
            XCTAssertTrue(failure.message.contains("malformed"),
                          "the refusal names the malformed outcome: \(failure.message)")
        }

        // A valid scanner's addresses still resolve in the same runtime —
        // the single validated entry point excludes only the bad outcome.
        let payload = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["cat_valid"], dryRun: false, confirmed: true, euid: 501, deps: deps
        ))
        let rows = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["category"] as? String, "cat_valid")
        XCTAssertEqual(rows[0]["success"] as? Bool, true)
        XCTAssertFalse(fm.fileExists(atPath: survivor.path),
                       "the valid category's confirmed clean proceeded")
    }

    // MARK: - Every payload self-describes (R8)

    func testEveryPayloadCarriesSchemaVersionFour() async throws {
        let catRoot = base.appendingPathComponent("sv-root")
        try fm.createDirectory(at: catRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x99, count: 4096).write(
            to: catRoot.appendingPathComponent("f.bin")
        )
        let deps = try makeDeps(categories: [makeCategory(name: "cat_a", path: catRoot.path)])

        let envelope = await CLIHandler.scanEnvelope(deps: deps)
        XCTAssertEqual(envelope["schema_version"] as? Int, 4, "scan envelope")

        let cleanDry = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["cat_a"], dryRun: true, confirmed: false, euid: 501, deps: deps
        ))
        XCTAssertEqual(cleanDry["schema_version"] as? Int, 4, "clean dry-run")

        let smartDry = try successPayload(await CLIHandler.smartCleanCLIOutcome(
            targetGB: 0.001, dryRun: true, confirmed: false, euid: 501, deps: deps
        ))
        XCTAssertEqual(smartDry["schema_version"] as? Int, 4, "smart-clean dry-run")

        let cleanConfirmed = try successPayload(await CLIHandler.cleanCLIOutcome(
            targets: ["cat_a"], dryRun: false, confirmed: true, euid: 501, deps: deps
        ))
        XCTAssertEqual(cleanConfirmed["schema_version"] as? Int, 4, "confirmed clean")

        // Recreate content for the smart-clean confirmed pass.
        try Data(repeating: 0x9A, count: 4096).write(
            to: catRoot.appendingPathComponent("g.bin")
        )
        let smartConfirmed = try successPayload(await CLIHandler.smartCleanCLIOutcome(
            targetGB: 0.000001, dryRun: false, confirmed: true, euid: 501, deps: deps
        ))
        XCTAssertEqual(smartConfirmed["schema_version"] as? Int, 4, "confirmed smart-clean")
    }

    // MARK: - Spotlight admission gate

    func testSpotlightRefusesInadmissibleRootReportsAndWritesNothing() throws {
        // Admissible fixture root — its own declared absolute path.
        let cacheRoot = base.appendingPathComponent("cache-a")
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let admissible = makeResult(
            state: .measured,
            category: makeCategory(name: "cache-a", path: cacheRoot.path),
            exact: 4096, items: 1
        )

        // Inadmissible root: a protected first-level child of the guard home.
        let docs = fixtureHome.appendingPathComponent("Documents")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let protected = makeResult(
            state: .measured,
            category: makeCategory(name: "docs-cat", path: docs.path),
            exact: 4096, items: 1
        )

        let payload = CLIHandler.spotlightPayload(
            for: [admissible, protected], home: fixtureHome
        )

        XCTAssertEqual(payload["tagged_count"] as? Int, 1)
        let tagged = try XCTUnwrap(payload["directories"] as? [[String: Any]])
        XCTAssertEqual(tagged.map { $0["slug"] as? String }, ["cache-a"])
        XCTAssertEqual(tagged[0]["marker_written"] as? Bool, true,
                       "write outcomes are captured, never assumed")
        XCTAssertTrue(
            fm.fileExists(atPath: cacheRoot.appendingPathComponent(".cacheout-managed").path),
            "the admitted root IS tagged"
        )

        let refused = try XCTUnwrap(payload["refused"] as? [[String: Any]])
        XCTAssertEqual(refused.count, 1)
        XCTAssertEqual(payload["refused_count"] as? Int, 1)
        XCTAssertEqual(refused[0]["path"] as? String, docs.path)
        XCTAssertTrue(
            try XCTUnwrap(refused[0]["reason"] as? String)
                .localizedCaseInsensitiveContains("protected"),
            "the refusal reason is the typed PathGuard message"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: docs.appendingPathComponent(".cacheout-managed").path),
            "an inadmissible root gets NO marker write"
        )
    }

    func testSpotlightSkipsDeniedScanStateWithoutWrites() throws {
        let deniedRoot = base.appendingPathComponent("denied-cache")
        try fm.createDirectory(at: deniedRoot, withIntermediateDirectories: true)
        let denied = makeResult(
            state: .denied,
            category: makeCategory(name: "denied-cat", path: deniedRoot.path),
            scanError: ScanError(kind: .tccDenied, message: "operation not permitted")
        )

        let payload = CLIHandler.spotlightPayload(for: [denied], home: fixtureHome)

        XCTAssertEqual(payload["tagged_count"] as? Int, 0)
        let refused = try XCTUnwrap(payload["refused"] as? [[String: Any]])
        XCTAssertEqual(refused.count, 1)
        let reason = try XCTUnwrap(refused[0]["reason"] as? String)
        XCTAssertTrue(reason.contains("scan denied (tcc_denied)"),
                      "the scan-state refusal is classified, never string-matched: \(reason)")
        XCTAssertFalse(
            fm.fileExists(atPath: deniedRoot.appendingPathComponent(".cacheout-managed").path),
            "a .denied root gets NO writes — `exists` alone would have let it through"
        )
    }

    func testSpotlightReportsRootWhereNoMetadataWriteLanded() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        // Read-only root: admission succeeds, but neither the xattr nor the
        // marker can be written — the payload must not claim it was tagged.
        let readOnlyRoot = base.appendingPathComponent("readonly-cache")
        try fm.createDirectory(at: readOnlyRoot, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyRoot.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyRoot.path)
        }
        let result = makeResult(
            state: .measured,
            category: makeCategory(name: "readonly-cat", path: readOnlyRoot.path),
            exact: 4096, items: 1
        )

        let payload = CLIHandler.spotlightPayload(for: [result], home: fixtureHome)

        XCTAssertEqual(payload["tagged_count"] as? Int, 0,
                       "a root where no metadata write landed is not 'tagged'")
        let refused = try XCTUnwrap(payload["refused"] as? [[String: Any]])
        XCTAssertEqual(refused.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(refused[0]["reason"] as? String).contains("metadata writes failed"),
            "the failure is reported, not swallowed"
        )
    }

    // MARK: - Spotlight runs through the validated runtime (R8)

    func testSpotlightOutcomeRoutesThroughValidatedRuntime() async throws {
        let cacheRoot = base.appendingPathComponent("spot-runtime-root")
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x77, count: 4096).write(
            to: cacheRoot.appendingPathComponent("f.bin")
        )
        let deps = try makeDeps(
            categories: [makeCategory(name: "spot_cat", path: cacheRoot.path)]
        )

        let payload = try successPayload(await CLIHandler.spotlightOutcome(
            deps: deps, home: fixtureHome
        ))

        let tagged = try XCTUnwrap(payload["directories"] as? [[String: Any]])
        XCTAssertEqual(tagged.map { $0["slug"] as? String }, ["spot_cat"],
                       "the validated adapter outcome feeds the same payload shape")
        XCTAssertEqual(payload["tagged_count"] as? Int, 1)
        XCTAssertTrue(
            fm.fileExists(atPath: cacheRoot.appendingPathComponent(".cacheout-managed").path),
            "tagging side effects land against the runtime-scanned root"
        )
    }

    func testSpotlightFailsClosedOnMalformedCategoriesOutcome() async throws {
        // A scanner CLAIMING the categories id but emitting foreign-owned
        // items: registration admits it (ids are just slugs) — the outcome
        // VALIDATOR rejects it, and spotlight must fail closed rather than
        // tag from unvalidated results.
        let impostor = FixtureScanner(
            id: CategoryScanner.registeredID,
            items: [makeStandaloneItem(id: "forged", scannerID: "someone_else")]
        )
        let runtime = try SpaceScannerRuntime(
            scanners: [impostor], categories: [],
            home: fixtureHome, provider: FileSystemIdentityProvider()
        )
        let deps = CLIHandler.CLIRuntimeDependencies(
            runtime: runtime, categorySlugs: []
        )

        let failure = try failureOutcome(await CLIHandler.spotlightOutcome(
            deps: deps, home: fixtureHome
        ))
        XCTAssertEqual(failure.code, "MALFORMED_SCANNER_OUTPUT")
        XCTAssertTrue(failure.message.contains(CategoryScanner.registeredID),
                      "the refusal names the scanner: \(failure.message)")
    }

    // MARK: - Smart-clean fails closed on a malformed categories outcome

    func testSmartCleanFailsClosedOnMalformedCategoriesOutcome() async throws {
        // Same impostor shape as the spotlight test: a scanner CLAIMING the
        // categories id but emitting a foreign-owned item — here pointed at
        // REAL content on disk so the survival assertion is meaningful. The
        // validator rejects the outcome; every smart-clean surface must fail
        // loudly with MALFORMED_SCANNER_OUTPUT rather than presenting the
        // rejection as an empty plan or an empty "nothing eligible" success,
        // and nothing may be deleted.
        let victimID = "forged-smart-victim"
        let victim = base.appendingPathComponent(victimID)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        let survivor = victim.appendingPathComponent("keep.bin")
        try Data(repeating: 0x5A, count: 4096).write(to: survivor)

        let impostor = FixtureScanner(
            id: CategoryScanner.registeredID,
            items: [makeStandaloneItem(
                id: victimID, scannerID: "someone_else",
                risk: .safe, automaticCleanEligible: true,
                container: base
            )]
        )
        let runtime = try SpaceScannerRuntime(
            scanners: [impostor], categories: [],
            home: fixtureHome, provider: FileSystemIdentityProvider()
        )
        let deps = CLIHandler.CLIRuntimeDependencies(
            runtime: runtime, categorySlugs: []
        )

        // Unconfirmed plan surface: MALFORMED_SCANNER_OUTPUT, never an
        // empty CONFIRMATION_REQUIRED plan.
        let unconfirmed = try failureOutcome(await CLIHandler.smartCleanCLIOutcome(
            targetGB: 1, dryRun: false, confirmed: false, euid: 501, deps: deps
        ))
        XCTAssertEqual(unconfirmed.code, "MALFORMED_SCANNER_OUTPUT",
                       "an unconfirmed invocation never presents a rejected scanner as an empty plan")

        // Dry-run surface: failure, never an empty success payload.
        let dryRun = try failureOutcome(await CLIHandler.smartCleanCLIOutcome(
            targetGB: 1, dryRun: true, confirmed: false, euid: 501, deps: deps
        ))
        XCTAssertEqual(dryRun.code, "MALFORMED_SCANNER_OUTPUT",
                       "a dry run never presents a rejected scanner as 'nothing eligible'")

        // Confirmed surface: failure before any cleaner runs.
        let confirmed = try failureOutcome(await CLIHandler.smartCleanCLIOutcome(
            targetGB: 1, dryRun: false, confirmed: true, euid: 501, deps: deps
        ))
        XCTAssertEqual(confirmed.code, "MALFORMED_SCANNER_OUTPUT",
                       "a confirmed run never presents a rejected scanner as an empty success")
        XCTAssertTrue(confirmed.message.contains(CategoryScanner.registeredID),
                      "the refusal names the scanner: \(confirmed.message)")

        XCTAssertTrue(fm.fileExists(atPath: survivor.path),
                      "a confirmed run against a rejected scanner deletes nothing")
    }

    // MARK: - Sweep flags rejected on every non-sweep command (R8)

    func testSweepFlagGateMatrixAcrossAllCommands() {
        // The R8 sweep flags are accepted by the commands that actually
        // run the sweep scanner — scan and clean ONLY. Every other command
        // rejects them BEFORE dispatch: silently ignoring a threshold the
        // caller passed would hide the flag landing on the wrong command.
        let flags = [CLIHandler.orphanSizeFloorFlag, CLIHandler.orphanStaleDaysFlag]
        for command in CLIHandler.Command.allCases {
            for flag in flags {
                let args = ["Cacheout", "--cli", command.rawValue, flag, "30"]
                let rejected = CLIHandler.rejectedSweepFlag(for: command, in: args)
                switch command {
                case .scan, .clean:
                    XCTAssertNil(
                        rejected,
                        "\(command.rawValue) runs the sweep and accepts \(flag)"
                    )
                default:
                    XCTAssertEqual(
                        rejected, flag,
                        "\(command.rawValue) never runs the sweep and must reject \(flag)"
                    )
                }
            }
            // Without the flags nothing is rejected anywhere — the gate
            // never turns an ordinary invocation into a usage error.
            XCTAssertNil(CLIHandler.rejectedSweepFlag(
                for: command,
                in: ["Cacheout", "--cli", command.rawValue, "--confirm"]
            ))
        }
    }

    func testSweepFlagRejectionMessageIsActionable() {
        // The refusal names the offending flag, the command that refused
        // it, and the commands that DO accept it — the caller's next
        // invocation should be obvious from the message alone.
        let sampled: [CLIHandler.Command] = [
            .version, .diskInfo, .spotlight, .memoryStats, .smartClean,
        ]
        for command in sampled {
            for flag in [CLIHandler.orphanSizeFloorFlag, CLIHandler.orphanStaleDaysFlag] {
                let message = CLIHandler.sweepFlagRejectionMessage(
                    flag: flag, command: command
                )
                XCTAssertTrue(message.contains(flag),
                              "names the flag: \(message)")
                XCTAssertTrue(message.contains(command.rawValue),
                              "names the refusing command: \(message)")
                XCTAssertTrue(message.contains("scan or clean"),
                              "points at the supported commands: \(message)")
            }
        }
    }
}

/// fn-1.5 subprocess INTEGRATION tests (R5) — read-only, framing ONLY.
///
/// These spawn the real `Cacheout` binary built beside the test bundle and
/// assert the process contract of an UNCONFIRMED destructive command: exit
/// code 1, empty stdout, and the structured `CONFIRMATION_REQUIRED` stderr
/// envelope with the plan under `details`. They never pass `--confirm` and
/// never delete anything; the scan they trigger is read-only. Live-`$HOME`
/// `--confirm` cleans are permanently out of scope — the fn-2.6 confirmed
/// deletions are exercised in-process through the injected dependency
/// bundle above.
final class CLIGateFramingTests: XCTestCase {

    private struct CLIRun {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// The build-products directory containing both this .xctest bundle and
    /// the Cacheout executable (SPM builds all products for `swift test`).
    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        preconditionFailure("cannot locate the build-products directory from the XCTest bundles")
    }

    private func runCLI(_ arguments: [String], timeout: TimeInterval = 300) throws -> CLIRun {
        let binary = productsDirectory.appendingPathComponent("Cacheout")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("Cacheout executable missing at \(binary.path) — swift test builds it beside the test bundle")
            throw XCTSkip("executable not built")
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        // Drain both pipes concurrently so a filled pipe buffer can never
        // deadlock the child; watchdog-terminate on timeout.
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        group.wait()

        return CLIRun(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Parse the stderr `{"ok": false, "error": {...}}` envelope.
    private func parseErrorEnvelope(_ stderr: String) throws -> [String: Any] {
        let data = try XCTUnwrap(stderr.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(json as? [String: Any],
                             "stderr is not a JSON object: \(stderr.prefix(500))")
    }

    func testUnconfirmedCleanFraming() throws {
        let run = try runCLI(["--cli", "clean", "npm_cache"])

        XCTAssertEqual(run.exitCode, 1, "unconfirmed clean exits 1")
        XCTAssertEqual(run.stdout, "", "stdout stays EMPTY when refused (R5)")

        let envelope = try parseErrorEnvelope(run.stderr)
        XCTAssertEqual(envelope["ok"] as? Bool, false)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "CONFIRMATION_REQUIRED")
        XCTAssertTrue(((error["message"] as? String) ?? "").contains("--confirm"))
        let details = try XCTUnwrap(envelope["details"] as? [String: Any],
                                    "the refusal carries the plan in details")
        XCTAssertEqual(details["command"] as? String, "clean")
        let plan = try XCTUnwrap(details["plan"] as? [[String: Any]])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0]["slug"] as? String, "npm_cache")
    }

    func testUnconfirmedSmartCleanFraming() throws {
        let run = try runCLI(["--cli", "smart-clean", "0.001"])

        XCTAssertEqual(run.exitCode, 1, "unconfirmed smart-clean exits 1")
        XCTAssertEqual(run.stdout, "", "stdout stays EMPTY when refused (R5)")

        let envelope = try parseErrorEnvelope(run.stderr)
        XCTAssertEqual(envelope["ok"] as? Bool, false)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "CONFIRMATION_REQUIRED")
        let details = try XCTUnwrap(envelope["details"] as? [String: Any])
        XCTAssertEqual(details["command"] as? String, "smart-clean")
        let plan = try XCTUnwrap(details["plan"] as? [[String: Any]],
                                 "the smart-clean refusal carries its plan")
        for entry in plan {
            XCTAssertNotNil(entry["state"],
                            "smart-clean plan entries share the clean plan shape (PROTOCOL.md)")
            let action = entry["action"] as? String
            XCTAssertTrue(action == "clean" || action == "clean_if_needed",
                          "smart-clean plan actions are clean/clean_if_needed, got: \(action ?? "nil")")
        }
        XCTAssertNotNil(details["target_gb"])
    }

    func testCleanWithoutTargetsIsAUsageError() throws {
        let run = try runCLI(["--cli", "clean", "--confirm"])

        XCTAssertEqual(run.exitCode, 1)
        XCTAssertEqual(run.stdout, "",
                       "an empty target list must not masquerade as a successful no-op clean")
        let envelope = try parseErrorEnvelope(run.stderr)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "MISSING_ARGUMENT")
    }

    func testSmartCleanRejectsNonFiniteTarget() throws {
        // No --confirm: target validation precedes the gate, so the usage
        // error must win — and the invocation stays read-only by contract.
        let run = try runCLI(["--cli", "smart-clean", "nan"])

        XCTAssertEqual(run.exitCode, 1,
                       "a nan target must be refused, not trapped in the Int64 conversion")
        XCTAssertEqual(run.stdout, "")
        let envelope = try parseErrorEnvelope(run.stderr)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS")
    }

    func testSmartCleanRejectsZeroTarget() throws {
        // A zero target is already met before anything runs — the plan
        // would mark every candidate clean_if_needed and target_met true
        // while the confirmed run touches nothing. Refused as usage error.
        let run = try runCLI(["--cli", "smart-clean", "0"])

        XCTAssertEqual(run.exitCode, 1)
        XCTAssertEqual(run.stdout, "")
        let envelope = try parseErrorEnvelope(run.stderr)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS")
    }

    func testSmartCleanRejectsSubByteTarget() throws {
        // Positive but truncating to zero bytes (1e-20 GB) — would recreate
        // the zero-target contradiction; the CONVERTED value is validated.
        let run = try runCLI(["--cli", "smart-clean", "1e-20"])

        XCTAssertEqual(run.exitCode, 1)
        XCTAssertEqual(run.stdout, "")
        let envelope = try parseErrorEnvelope(run.stderr)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS")
    }

    func testSmartCleanRejectsMalformedTarget() throws {
        // A PRESENT but non-numeric target must never silently default to
        // 5.0 — that would let `smart-clean garbage --confirm` delete 5 GB
        // the caller never asked for. (Still read-only here: the parse
        // error exits before any scan.)
        let run = try runCLI(["--cli", "smart-clean", "garbage"])

        XCTAssertEqual(run.exitCode, 1)
        XCTAssertEqual(run.stdout, "")
        let envelope = try parseErrorEnvelope(run.stderr)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS")
        XCTAssertTrue(((error["message"] as? String) ?? "").contains("garbage"))
    }

    func testUnknownCleanTargetFraming() throws {
        // Unknown/invalid targets exit through the same INVALID_ARGUMENTS
        // framing as schema 3's unknown slugs — including the excluded
        // frozen aggregate id.
        for target in ["definitely_not_a_slug", "categories"] {
            let run = try runCLI(["--cli", "clean", target])
            XCTAssertEqual(run.exitCode, 1)
            XCTAssertEqual(run.stdout, "")
            let envelope = try parseErrorEnvelope(run.stderr)
            let error = try XCTUnwrap(envelope["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS",
                           "'\(target)' must be refused")
        }
    }

    func testSweepFlagsRejectedOnNonSweepCommandsFraming() throws {
        // R8 sweep flags on commands that never run the sweep: refused
        // BEFORE dispatch — exit 1, empty stdout, INVALID_ARGUMENTS naming
        // the flag and the commands that accept it. Only read-only commands
        // are sampled here so even a gate regression stays side-effect-free
        // (`spotlight`, which writes metadata when dispatched, is covered by
        // the in-process gate matrix instead).
        for command in ["version", "disk-info", "memory-stats"] {
            for flag in [CLIHandler.orphanSizeFloorFlag, CLIHandler.orphanStaleDaysFlag] {
                let run = try runCLI(["--cli", command, flag, "30"])
                XCTAssertEqual(run.exitCode, 1, "\(command) + \(flag) exits 1")
                XCTAssertEqual(run.stdout, "",
                               "stdout stays EMPTY when refused: \(command)")
                let envelope = try parseErrorEnvelope(run.stderr)
                XCTAssertEqual(envelope["ok"] as? Bool, false)
                let error = try XCTUnwrap(envelope["error"] as? [String: Any])
                XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS",
                               "\(command) must refuse \(flag)")
                let message = (error["message"] as? String) ?? ""
                XCTAssertTrue(message.contains(flag),
                              "the refusal names the flag: \(message)")
                XCTAssertTrue(message.contains(command),
                              "the refusal names the command: \(message)")
                XCTAssertTrue(message.contains("scan or clean"),
                              "the refusal points at the supported commands: \(message)")
            }
        }
    }

    func testSmartCleanStillRejectsSweepFlagsFraming() throws {
        // The centralized gate covers smart-clean too — the frozen
        // category-only contract (fn-2 round 10) keeps rejecting the flags
        // pre-dispatch, before target parsing or any confirmation gate.
        let run = try runCLI(["--cli", "smart-clean", "5", "--orphan-stale-days", "30"])
        XCTAssertEqual(run.exitCode, 1)
        XCTAssertEqual(run.stdout, "")
        let envelope = try parseErrorEnvelope(run.stderr)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENTS")
        let message = (error["message"] as? String) ?? ""
        XCTAssertTrue(message.contains("--orphan-stale-days"))
        XCTAssertTrue(message.contains("smart-clean"))
    }

    func testCleanStillAcceptsSweepFlagsFraming() throws {
        // The gate must NOT reject the commands that run the sweep. An
        // unconfirmed clean with a sweep flag falls through to the ordinary
        // CONFIRMATION_REQUIRED refusal — the flag was accepted and the
        // invocation was gated on --confirm like any other clean (read-only).
        let run = try runCLI([
            "--cli", "clean", "npm_cache",
            CLIHandler.orphanSizeFloorFlag, "100",
        ])
        XCTAssertEqual(run.exitCode, 1, "unconfirmed clean still exits 1")
        XCTAssertEqual(run.stdout, "", "stdout stays EMPTY when refused (R5)")
        let envelope = try parseErrorEnvelope(run.stderr)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "CONFIRMATION_REQUIRED",
                       "the sweep flag is accepted — the refusal is the confirm gate, not the flag gate")
    }
}
