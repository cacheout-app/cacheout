import XCTest
import Darwin
@testable import Cacheout

/// fn-1.5 CLI gate tests (D5: R5/R16/R18 CLI half).
///
/// UNIT tier — hermetic and in-process: the pure gate decision matrix, the
/// schema bump, the plan/dry-run builders (scan-time components only, exact
/// bytes never laundered), smart-clean candidate eligibility and the
/// exact-only loop decision, and the spotlight admission gate driven with
/// fixture results against an injected home. No test touches the real
/// `$HOME`; no test deletes outside its fixture root.
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
        path: String? = nil
    ) -> CacheCategory {
        CacheCategory(
            name: name,
            slug: name,
            description: "test",
            icon: "trash",
            discovery: [.absolutePath(path ?? "/nonexistent-fixture-\(name)")],
            riskLevel: risk,
            rebuildNote: "rebuilds",
            defaultSelected: true
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

    private let gb: Int64 = 1024 * 1024 * 1024

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

    // MARK: - Schema bump (R5)

    func testSchemaVersionIsThree() {
        XCTAssertEqual(CLIHandler.cliSchemaVersion, 3,
                       "schema 3 = clean/smart-clean require --confirm (PROTOCOL.md)")
    }

    // MARK: - Plan actions mirror the cleaner's decisions (R18)

    func testCleanPlanActionsMatchCleanerDecisions() {
        XCTAssertEqual(CLIHandler.cleanPlanAction(for: makeResult(state: .missing)), "skip")
        XCTAssertEqual(CLIHandler.cleanPlanAction(for: makeResult(state: .empty)), "skip")
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeResult(state: .measured)), "skip",
            "zero-byte measured is skipped by the cleaner (isEmpty)"
        )
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeResult(state: .measured, exact: 4096, items: 1)),
            "clean"
        )
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeResult(
                state: .denied,
                scanError: ScanError(kind: .tccDenied, message: "denied")
            )),
            "refuse",
            "a named .denied slug surfaces as a refusal, never a silent skip (R18)"
        )
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeResult(
                state: .partiallyDenied, exact: 2048, items: 1,
                scanError: ScanError(kind: .permissionDenied, message: "partial")
            )),
            "clean_with_warning"
        )
        XCTAssertEqual(
            CLIHandler.cleanPlanAction(for: makeResult(
                state: .partiallyDenied,
                scanError: ScanError(kind: .permissionDenied, message: "partial")
            )),
            "skip",
            "a partiallyDenied result with zero measured bytes has nothing the cleaner would touch"
        )
    }

    func testCleanPlanItemCarriesComponentsWarningAndScanError() throws {
        let partial = makeResult(
            state: .partiallyDenied, category: makeCategory(name: "partial-cat"),
            exact: 2048, estimated: 512, items: 1,
            scanError: ScanError(kind: .permissionDenied, message: "permission denied")
        )
        let item = CLIHandler.cleanPlanItemJSON(for: partial)

        XCTAssertEqual(item["slug"] as? String, "partial-cat")
        XCTAssertEqual(item["state"] as? String, "partiallyDenied")
        XCTAssertEqual(item["action"] as? String, "clean_with_warning")
        XCTAssertEqual(item["exact_bytes"] as? Int64, 2048)
        XCTAssertEqual(item["estimated_up_to_bytes"] as? Int64, 512)
        XCTAssertEqual(item["warning"] as? String, CLIHandler.partiallyDeniedCleanWarning)
        let scanError = try XCTUnwrap(item["scan_error"] as? [String: Any])
        XCTAssertEqual(scanError["kind"] as? String, "permission_denied")

        let clean = CLIHandler.cleanPlanItemJSON(
            for: makeResult(state: .measured, exact: 4096, items: 1)
        )
        XCTAssertNil(clean["warning"], "clean categories carry no warning")
        XCTAssertNil(clean["scan_error"])
    }

    // MARK: - Dry-run payload: exact-only totals, scan-time components (R16)

    func testCleanDryRunPayloadIsExactOnlyWithComponents() throws {
        let results = [
            makeResult(state: .measured, category: makeCategory(name: "m"),
                       exact: 4096, estimated: 512, items: 1),
            makeResult(state: .partiallyDenied, category: makeCategory(name: "p"),
                       exact: 2048, items: 1,
                       scanError: ScanError(kind: .permissionDenied, message: "partial")),
            makeResult(state: .denied, category: makeCategory(name: "d"),
                       scanError: ScanError(kind: .tccDenied, message: "denied")),
            makeResult(state: .missing, category: makeCategory(name: "gone")),
        ]
        let payload = CLIHandler.cleanDryRunPayload(for: results)

        XCTAssertEqual(payload["dry_run"] as? Bool, true)
        XCTAssertEqual(payload["total_would_free"] as? Int64, 4096 + 2048,
                       "totals count exact bytes only — estimates never advance them (R16)")
        XCTAssertEqual(payload["total_estimated_up_to_bytes"] as? Int64, 512)

        let entries = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 4, "every requested slug appears, whatever its fate")

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
        let results = [
            makeResult(state: .measured, category: makeCategory(name: "m"),
                       exact: 4096, items: 1),
            makeResult(state: .denied, category: makeCategory(name: "d"),
                       scanError: ScanError(kind: .tccDenied, message: "denied")),
        ]
        let details = CLIHandler.cleanConfirmationDetails(for: results)

        XCTAssertEqual(details["command"] as? String, "clean")
        XCTAssertEqual(details["total_exact_bytes"] as? Int64, 4096)
        XCTAssertEqual(details["total_estimated_up_to_bytes"] as? Int64, 0)
        let plan = try XCTUnwrap(details["plan"] as? [[String: Any]])
        XCTAssertEqual(plan.count, 2,
                       "the plan mirrors the real run's per-category decisions")
        XCTAssertEqual(plan[1]["action"] as? String, "refuse")
    }

    // MARK: - Smart-clean candidates (R18 CLI half)

    func testSmartCleanCandidatesExcludeDeniedPartialAndCaution() {
        let safeMeasured = makeResult(
            state: .measured, category: makeCategory(name: "safe"),
            exact: 4096, items: 1
        )
        let reviewMeasured = makeResult(
            state: .measured, category: makeCategory(name: "review", risk: .review),
            exact: 8192, items: 1
        )
        let partial = makeResult(
            state: .partiallyDenied, category: makeCategory(name: "partial"),
            exact: 1 * gb, items: 1,
            scanError: ScanError(kind: .permissionDenied, message: "partial")
        )
        let denied = makeResult(
            state: .denied, category: makeCategory(name: "denied"),
            scanError: ScanError(kind: .tccDenied, message: "denied")
        )
        let caution = makeResult(
            state: .measured, category: makeCategory(name: "caution", risk: .caution),
            exact: 2 * gb, items: 1
        )
        let empty = makeResult(state: .empty, category: makeCategory(name: "empty"))

        let candidates = CLIHandler.smartCleanCandidates(
            [partial, caution, safeMeasured, denied, reviewMeasured, empty]
        )

        XCTAssertEqual(
            candidates.map(\.category.slug), ["safe", "review"],
            ".partiallyDenied (measured bytes and all) and .denied are skipped by the "
            + "auto path (R18); caution and empty are ineligible; safe sorts before review"
        )
    }

    // MARK: - Smart-clean loop decision: exact-only target math (R16)

    func testSmartCleanTargetMathIsExactOnly() {
        // Hardlink-heavy category: 10 GB estimated, ZERO exact. The pre-split
        // code would have counted 10 GB and claimed target_met.
        let hardlinkHeavy = makeResult(
            state: .measured, category: makeCategory(name: "links"),
            estimated: 10 * gb, items: 1
        )
        let plan = CLIHandler.smartCleanPlan(results: [hardlinkHeavy], targetBytes: 5 * gb)

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
    }

    func testSmartCleanPlanMarksPostTargetCandidatesAsConditionalFallbacks() {
        // Same risk tier — ordering is by compatibility size descending:
        // links (10 GB estimated), exact6 (6 GB exact), small (4 KB).
        let hardlinkHeavy = makeResult(
            state: .measured, category: makeCategory(name: "links"),
            estimated: 10 * gb, items: 1
        )
        let exact6 = makeResult(
            state: .measured, category: makeCategory(name: "exact6"),
            exact: 6 * gb, items: 1
        )
        let small = makeResult(
            state: .measured, category: makeCategory(name: "small"),
            exact: 4096, items: 1
        )
        let plan = CLIHandler.smartCleanPlan(
            results: [small, exact6, hardlinkHeavy], targetBytes: 5 * gb
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
}

/// fn-1.5 subprocess INTEGRATION tests (R5) — read-only, framing ONLY.
///
/// These spawn the real `Cacheout` binary built beside the test bundle and
/// assert the process contract of an UNCONFIRMED destructive command: exit
/// code 1, empty stdout, and the structured `CONFIRMATION_REQUIRED` stderr
/// envelope with the plan under `details`. They never pass `--confirm` and
/// never delete anything; the scan they trigger is read-only. Live-`$HOME`
/// `--confirm` cleans are permanently out of scope.
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

    func testCleanWithoutSlugsIsAUsageError() throws {
        let run = try runCLI(["--cli", "clean", "--confirm"])

        XCTAssertEqual(run.exitCode, 1)
        XCTAssertEqual(run.stdout, "",
                       "an empty slug list must not masquerade as a successful no-op clean")
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
}
