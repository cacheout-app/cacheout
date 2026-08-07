import XCTest
@testable import Cacheout

/// fn-2.4 scanner-registry view-model tests (R1).
///
/// The view model consumes the runtime's PROGRESSIVE VALIDATED EVENT STREAM
/// and keeps ONE selection/totals/clean model over `ReclaimableItem`. These
/// tests pin the epic's reconciliation contract:
///
/// - progressive publish (scanner A lands while B still runs)
/// - per-scanner reconciliation against the PRIOR outcome (user-set
///   selection AND deselection preserved; `defaultSelected` first-emission
///   only)
/// - vanished-key pruning EXACTLY at stream completion, never mid-scan
/// - composite `ItemKey` identity (bare item ids collide across scanners)
/// - the three selection policies — (a) initial, (b) Quick Clean, and the
///   ABSENCE of (c): smart-clean's safe-then-review ordering is exclusively
///   fn-2.6's CLI; the GUI's only auto-selection path is `selectAllSafe`,
///   which never selects review-risk (asserted below)
/// - the three FROZEN totals scopes through the one shared helper
/// - fail-closed malformed-outcome disposition (validation lives in the
///   runtime — the view model applies only the disposition)
/// - `clean()` driving fn-2.3's unified entry with exactly the selection
///
/// Everything runs hermetically against fixture homes and fixture scanners —
/// zero reads of the real `$HOME`.
final class CacheoutViewModelTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("CacheoutViewModelTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Fixtures

    private func makeRuntime(
        _ scanners: [any SpaceScanner],
        categories: [CacheCategory] = []
    ) throws -> SpaceScannerRuntime {
        try SpaceScannerRuntime(
            scanners: scanners,
            categories: categories,
            home: fixtureHome,
            provider: FileSystemIdentityProvider()
        )
    }

    /// A per-item fixture `ReclaimableItem` that PASSES the runtime
    /// validator's structural invariants (`.removeItem` + `.containerItem`).
    private func perItem(
        scanner: String,
        id: String,
        name: String? = nil,
        bytes: Int64 = 4096,
        state: ScanState = .measured,
        scanError: ScanError? = nil,
        risk: RiskLevel = .review,
        defaultSelected: Bool = false,
        automaticCleanEligible: Bool = false,
        isStale: Bool? = nil
    ) -> ReclaimableItem {
        let target = base
            .appendingPathComponent(scanner)
            .appendingPathComponent(id)
        let records: [RootScanRecord]
        switch state {
        case .missing:
            records = []
        case .denied:
            records = [RootScanRecord(
                requestedURL: target, resolvedURL: target,
                status: .deniedUnmeasured
            )]
        case .empty, .measured, .partiallyDenied:
            records = [RootScanRecord(
                requestedURL: target, resolvedURL: target, status: .measured
            )]
        }
        return ReclaimableItem(
            id: id,
            scannerID: scanner,
            displayName: name ?? id,
            exactBytes: state == .empty || state == .missing ? 0 : bytes,
            estimatedUpToBytes: 0,
            logicalBytes: nil,
            itemCount: state == .empty || state == .missing ? 0 : 1,
            url: state == .missing ? nil : target,
            declaredDisplayPath: target.path,
            rootRecords: records,
            state: state,
            scanError: scanError,
            risk: risk,
            evidence: "fixture evidence for \(id)",
            rebuildNote: nil,
            action: .removeItem,
            admission: .containerItem(
                originContainer: target.deletingLastPathComponent(),
                requestedTargetURL: target
            ),
            defaultSelected: defaultSelected,
            automaticCleanEligible: automaticCleanEligible,
            isStale: isStale
        )
    }

    private func makeCategory(
        name: String,
        risk: RiskLevel = .safe,
        defaultSelected: Bool = true,
        at url: URL? = nil
    ) -> CacheCategory {
        CacheCategory(
            name: name,
            slug: name,
            description: "test",
            icon: "trash",
            discovery: [.absolutePath(url?.path ?? "/nonexistent-fixture-\(name)")],
            riskLevel: risk,
            rebuildNote: "rebuilds",
            defaultSelected: defaultSelected
        )
    }

    /// Aggregate item through the ONE real mapping (`CategoryScanner.item`).
    private func aggregate(
        slug: String,
        state: ScanState,
        exact: Int64 = 0,
        items: Int = 0,
        risk: RiskLevel = .safe,
        defaultSelected: Bool = true,
        scanError: ScanError? = nil,
        root: URL? = nil
    ) -> ReclaimableItem {
        var records: [RootScanRecord] = []
        if let root {
            records = [RootScanRecord(
                requestedURL: root,
                resolvedURL: FileSystemIdentityProvider().canonicalize(root),
                status: .measured
            )]
        }
        let result = ScanResult(
            category: makeCategory(
                name: slug, risk: risk, defaultSelected: defaultSelected,
                at: root
            ),
            state: state,
            exactBytes: exact,
            estimatedUpToBytes: 0,
            itemCount: items,
            scanError: scanError,
            rootRecords: records
        )
        return CategoryScanner.item(from: result)
    }

    private func key(_ scanner: String, _ id: String) -> ItemKey {
        ItemKey(scannerID: scanner, itemID: id)
    }

    private func categoriesKey(_ slug: String) -> ItemKey {
        key(CategoryScanner.registeredID, slug)
    }

    /// Seeds one scanner's outcome through the SAME per-event entry point
    /// `scan()` drives — never a parallel back door.
    @MainActor
    private func seed(
        _ viewModel: CacheoutViewModel,
        scanner: String,
        items: [ReclaimableItem],
        errors: [ScanIssue] = []
    ) {
        viewModel.handle(.outcome(
            scannerID: scanner, ScanOutcome(items: items, errors: errors)
        ))
    }

    private struct TimeoutError: Error {}

    /// Polls a MainActor predicate — the observation seam for mid-scan
    /// windows (published state lands per stream event).
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 10,
        _ message: String,
        predicate: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("timed out waiting for: \(message)")
                throw TimeoutError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Progressive publish (epic contract)

    @MainActor
    func testScannerEventPublishesWhileAnotherScannerStillRunning() async throws {
        let gate = ScanGate()
        let outcomeA = ScanOutcome(
            items: [perItem(scanner: "aaa", id: "a1")], errors: []
        )
        let outcomeB = ScanOutcome(
            items: [perItem(scanner: "bbb", id: "b1")], errors: []
        )
        let runtime = try makeRuntime([
            FixtureScanner(id: "aaa") { outcomeA },
            FixtureScanner(id: "bbb") { await gate.wait(); return outcomeB },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        let scanTask = Task { await viewModel.scan(trigger: .automatic) }
        try await waitUntil("scanner A's outcome published") {
            !viewModel.items(forScanner: "aaa").isEmpty
        }

        // A is LIVE in the UI state while B is still running.
        XCTAssertEqual(viewModel.items(forScanner: "aaa").map(\.id), ["a1"])
        XCTAssertTrue(viewModel.scanningScannerIDs.contains("bbb"),
                      "B has not reported — its per-scanner state must say so")
        XCTAssertFalse(viewModel.scanningScannerIDs.contains("aaa"),
                       "A has reported — its per-scanner state clears")
        XCTAssertTrue(viewModel.isAnyScanInProgress)
        XCTAssertTrue(viewModel.items(forScanner: "bbb").isEmpty)

        await gate.open()
        await scanTask.value
        XCTAssertEqual(viewModel.items(forScanner: "bbb").map(\.id), ["b1"])
        XCTAssertFalse(viewModel.isAnyScanInProgress)
        XCTAssertTrue(viewModel.hasScanned)
    }

    // MARK: - Mid-scan selection survival + completion-time pruning

    @MainActor
    func testSelectionOnScannerASurvivesScannerBOutcomeMidScan() async throws {
        let gateB = ScanGate()
        let gateC = ScanGate()
        let outcomeA = ScanOutcome(
            items: [perItem(scanner: "aaa", id: "a1")], errors: []
        )
        let outcomeB = ScanOutcome(
            items: [perItem(scanner: "bbb", id: "b1")], errors: []
        )
        let outcomeC = ScanOutcome(
            items: [perItem(scanner: "ccc", id: "c1")], errors: []
        )
        let runtime = try makeRuntime([
            FixtureScanner(id: "aaa") { outcomeA },
            FixtureScanner(id: "bbb") { await gateB.wait(); return outcomeB },
            FixtureScanner(id: "ccc") { await gateC.wait(); return outcomeC },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        let scanTask = Task { await viewModel.scan(trigger: .automatic) }
        try await waitUntil("scanner A's outcome published") {
            !viewModel.items(forScanner: "aaa").isEmpty
        }
        viewModel.toggleSelection(for: key("aaa", "a1"))
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("aaa", "a1")))

        // B's outcome arrives while C is still pending: reconciliation is
        // per-scanner — A's selection must be untouched, mid-scan.
        await gateB.open()
        try await waitUntil("scanner B's outcome published") {
            !viewModel.items(forScanner: "bbb").isEmpty
        }
        XCTAssertTrue(viewModel.isAnyScanInProgress, "C still pending")
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("aaa", "a1")),
                      "a selection on scanner A must survive scanner B's event mid-scan")

        await gateC.open()
        await scanTask.value
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("aaa", "a1")),
                      "a1 is still live at completion — nothing to prune")
    }

    @MainActor
    func testVanishedKeyPruningHappensExactlyAtScanCompletion() async throws {
        let gate = ScanGate()
        let withItem = ScanOutcome(
            items: [perItem(scanner: "aaa", id: "a1")], errors: []
        )
        let withoutItem = ScanOutcome(items: [], errors: [])
        let sequenceA = OutcomeSequence([withItem, withoutItem])
        let outcomeB = ScanOutcome(
            items: [perItem(scanner: "bbb", id: "b1")], errors: []
        )
        let runtime = try makeRuntime([
            FixtureScanner(id: "aaa") { await gate.wait(); return await sequenceA.next() },
            FixtureScanner(id: "bbb") { outcomeB },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        // Scan 1 (gate open): a1 exists; select it.
        await gate.open()
        await viewModel.scan(trigger: .automatic)
        viewModel.toggleSelection(for: key("aaa", "a1"))
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("aaa", "a1")))

        // Scan 2: B reports instantly; A (whose new outcome DROPS a1) is
        // still pending — the selection must NOT be pruned mid-scan.
        await gate.close()
        let scanTask = Task { await viewModel.scan(trigger: .automatic) }
        try await waitUntil("scanner B reported in scan 2") {
            !viewModel.scanningScannerIDs.contains("bbb")
                && viewModel.scanningScannerIDs.contains("aaa")
        }
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("aaa", "a1")),
                      "pruning must never run mid-scan — the owning scanner is still pending")

        await gate.open()
        await scanTask.value
        XCTAssertFalse(viewModel.selectedItemKeys.contains(key("aaa", "a1")),
                       "once the scan completes without the key, its selection is pruned")
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty)
    }

    // MARK: - Stable identity across rescans (fixes the UUID-per-scan defect)

    @MainActor
    func testSelectionSurvivesRescanAndBareIdsStayIndependentAcrossScanners() async throws {
        // Two scanners emit the SAME bare item id — cross-scanner identity
        // is the composite ItemKey, so they stay independently selectable.
        let outcomeX = ScanOutcome(
            items: [perItem(scanner: "xxx", id: "shared_id", name: "from-x")],
            errors: []
        )
        let outcomeY = ScanOutcome(
            items: [perItem(scanner: "yyy", id: "shared_id", name: "from-y")],
            errors: []
        )
        let runtime = try makeRuntime([
            FixtureScanner(id: "xxx") { outcomeX },
            FixtureScanner(id: "yyy") { outcomeY },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .automatic)
        viewModel.toggleSelection(for: key("xxx", "shared_id"))
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("xxx", "shared_id")))
        XCTAssertFalse(viewModel.selectedItemKeys.contains(key("yyy", "shared_id")),
                       "the same bare id on another scanner is a DIFFERENT key")

        // Rescan of the unchanged fixture tree: the selection survives.
        await viewModel.scan(trigger: .automatic)
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("xxx", "shared_id")),
                      "selection keyed by ItemKey survives a rescan of an unchanged tree")
        XCTAssertFalse(viewModel.selectedItemKeys.contains(key("yyy", "shared_id")))

        viewModel.toggleSelection(for: key("yyy", "shared_id"))
        XCTAssertEqual(
            viewModel.selectedItemKeys,
            [key("xxx", "shared_id"), key("yyy", "shared_id")],
            "both scanners' same-bare-id items are independently selectable"
        )
    }

    @MainActor
    func testExplicitDeselectionIsNeverResurrectedAcrossRescan() async throws {
        let outcome = ScanOutcome(
            items: [perItem(scanner: "ddd", id: "d1", defaultSelected: true)],
            errors: []
        )
        let runtime = try makeRuntime([FixtureScanner(id: "ddd") { outcome }])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .automatic)
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("ddd", "d1")),
                      "policy (a): defaultSelected applies on FIRST emission")

        viewModel.toggleSelection(for: key("ddd", "d1"))  // explicit deselection
        XCTAssertFalse(viewModel.selectedItemKeys.contains(key("ddd", "d1")))

        await viewModel.scan(trigger: .automatic)
        XCTAssertFalse(viewModel.selectedItemKeys.contains(key("ddd", "d1")),
                       "an explicit deselection is user intent — a rescan must never resurrect it")
    }

    @MainActor
    func testNewlyAppearingDefaultSelectedKeyArrivesSelected() async throws {
        let first = ScanOutcome(
            items: [perItem(scanner: "ddd", id: "d1", defaultSelected: true)],
            errors: []
        )
        let second = ScanOutcome(
            items: [
                perItem(scanner: "ddd", id: "d1", defaultSelected: true),
                perItem(scanner: "ddd", id: "d2", defaultSelected: true),
            ],
            errors: []
        )
        let sequence = OutcomeSequence([first, second])
        let runtime = try makeRuntime([
            FixtureScanner(id: "ddd") { await sequence.next() }
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .automatic)
        viewModel.toggleSelection(for: key("ddd", "d1"))  // deselect d1

        await viewModel.scan(trigger: .automatic)
        XCTAssertEqual(viewModel.selectedItemKeys, [key("ddd", "d2")],
                       "d2 is genuinely NEW (absent from the prior outcome) — it arrives "
                       + "selected; previously-emitted d1 keeps its user-set deselection")
    }

    // MARK: - Selection policies (a) and (b); (c) absent from the GUI

    @MainActor
    func testInitialSelectionMatchesAsBuiltPolicy() throws {
        let runtime = try makeRuntime([])
        let viewModel = CacheoutViewModel(runtime: runtime)
        seed(viewModel, scanner: CategoryScanner.registeredID, items: [
            aggregate(slug: "sel_measured", state: .measured, exact: 4096, items: 1),
            aggregate(slug: "sel_empty", state: .empty),
            aggregate(slug: "sel_partial", state: .partiallyDenied, exact: 2048, items: 1,
                      scanError: ScanError(kind: .permissionDenied, message: "x")),
            aggregate(slug: "sel_denied", state: .denied,
                      scanError: ScanError(kind: .tccDenied, message: "x")),
            aggregate(slug: "unsel_measured", state: .measured, exact: 4096, items: 1,
                      defaultSelected: false),
            aggregate(slug: "sel_zero_bytes", state: .measured, items: 1),
        ])
        // node_modules-parity per-item rows: defaultSelected false.
        seed(viewModel, scanner: "nmx", items: [
            perItem(scanner: "nmx", id: "n1"),
        ])

        XCTAssertEqual(
            viewModel.selectedItemKeys, [categoriesKey("sel_measured")],
            "policy (a) parity: only defaultSelected + cleanly measured + measurable "
            + "bytes auto-selects; partiallyDenied/denied/empty/zero-byte never; "
            + "per-item rows ship defaultSelected false and arrive unselected"
        )
    }

    @MainActor
    func testSelectAllSafeIsPolicyBExactly() throws {
        let runtime = try makeRuntime([])
        let viewModel = CacheoutViewModel(runtime: runtime)
        seed(viewModel, scanner: CategoryScanner.registeredID, items: [
            // Safe risk with defaultSelected == false IS selected — today's
            // selectAllSafe ignores defaultSelected (as-built parity).
            aggregate(slug: "safe_not_default", state: .measured, exact: 4096,
                      items: 1, defaultSelected: false),
            aggregate(slug: "review_cat", state: .measured, exact: 4096,
                      items: 1, risk: .review, defaultSelected: false),
            aggregate(slug: "safe_partial", state: .partiallyDenied, exact: 4096,
                      items: 1, defaultSelected: false,
                      scanError: ScanError(kind: .permissionDenied, message: "x")),
        ])
        seed(viewModel, scanner: "nmx", items: [
            // Safe-risk, clean-state, measurable — but automaticCleanEligible
            // is FALSE (node_modules parity): NEVER chosen by the auto path.
            perItem(scanner: "nmx", id: "safe_ineligible", risk: .safe,
                    automaticCleanEligible: false),
            // Review-risk even when eligible: the GUI has NO code path that
            // auto-selects review risk — policy (c) is exclusively fn-2.6's
            // CLI smart-clean (this is the behavioral half of that gate; the
            // structural half is that no candidate-order helper exists for
            // the GUI to call).
            perItem(scanner: "nmx", id: "review_eligible", risk: .review,
                    automaticCleanEligible: true),
        ])

        viewModel.selectAllSafe()

        XCTAssertEqual(
            viewModel.selectedItemKeys, [categoriesKey("safe_not_default")],
            "policy (b): automaticCleanEligible && risk == .safe on cleanly "
            + "measured items — defaultSelected NOT consulted; ineligible and "
            + "review-risk items never chosen"
        )
    }

    @MainActor
    func testSelectStaleSelectsExactlyStaleItemsAndIgnoresInapplicableScanners() throws {
        let runtime = try makeRuntime([])
        let viewModel = CacheoutViewModel(runtime: runtime)
        seed(viewModel, scanner: "sss", items: [
            perItem(scanner: "sss", id: "stale_1", isStale: true),
            perItem(scanner: "sss", id: "fresh_1", isStale: false),
            perItem(scanner: "sss", id: "stale_denied", state: .denied,
                    scanError: ScanError(kind: .permissionDenied, message: "x"),
                    isStale: true),
        ])
        seed(viewModel, scanner: "nostale", items: [
            perItem(scanner: "nostale", id: "n1", isStale: nil),
        ])

        viewModel.selectStale(inScanner: "sss")
        XCTAssertEqual(viewModel.selectedItemKeys, [key("sss", "stale_1")],
                       "exactly isStale == true — fresh items, unselectable states, and "
                       + "other scanners untouched")

        viewModel.selectStale(inScanner: "nostale")
        XCTAssertEqual(viewModel.selectedItemKeys, [key("sss", "stale_1")],
                       "isStale == nil means staleness is inapplicable — nothing selected")
    }

    // MARK: - Unselectable states (aggregate AND per-item, all three states)

    @MainActor
    func testDeniedEmptyMissingAreUnselectableInEverySurface() throws {
        let runtime = try makeRuntime([])
        let viewModel = CacheoutViewModel(runtime: runtime)
        seed(viewModel, scanner: CategoryScanner.registeredID, items: [
            aggregate(slug: "agg_denied", state: .denied,
                      scanError: ScanError(kind: .tccDenied, message: "x")),
            aggregate(slug: "agg_empty", state: .empty),
            aggregate(slug: "agg_missing", state: .missing),
        ])
        seed(viewModel, scanner: "per", items: [
            perItem(scanner: "per", id: "item_denied", state: .denied,
                    scanError: ScanError(kind: .permissionDenied, message: "x")),
            perItem(scanner: "per", id: "item_empty", state: .empty),
            perItem(scanner: "per", id: "item_missing", state: .missing),
        ])

        // Selection attempts are no-ops for EVERY combination.
        for itemKey in [
            categoriesKey("agg_denied"), categoriesKey("agg_empty"),
            categoriesKey("agg_missing"),
            key("per", "item_denied"), key("per", "item_empty"),
            key("per", "item_missing"),
        ] {
            viewModel.toggleSelection(for: itemKey)
            XCTAssertFalse(viewModel.selectedItemKeys.contains(itemKey),
                           "\(itemKey.itemID): unselectable state must be a toggle no-op")
        }
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty)

        // The bulk surfaces refuse them too.
        viewModel.selectAll(inScanner: "per")
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty,
                      "Select All skips unselectable states")
        viewModel.selectAllSafe()
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty)
    }

    // MARK: - Totals: three FROZEN scopes through the one shared helper

    @MainActor
    func testTotalsScopesOnMixedFixture() throws {
        let runtime = try makeRuntime([])
        let viewModel = CacheoutViewModel(runtime: runtime)
        seed(viewModel, scanner: CategoryScanner.registeredID, items: [
            aggregate(slug: "cat_a", state: .measured, exact: 4096, items: 1,
                      defaultSelected: false),
            aggregate(slug: "cat_b", state: .measured, exact: 2048, items: 1,
                      defaultSelected: false),
            aggregate(slug: "cat_partial", state: .partiallyDenied, exact: 1024,
                      items: 1, defaultSelected: false,
                      scanError: ScanError(kind: .permissionDenied, message: "x")),
            aggregate(slug: "cat_denied", state: .denied,
                      scanError: ScanError(kind: .tccDenied, message: "x")),
            aggregate(slug: "cat_empty", state: .empty),
        ])
        seed(viewModel, scanner: "nmx", items: [
            perItem(scanner: "nmx", id: "i1", bytes: 5000),
            perItem(scanner: "nmx", id: "i2", bytes: 3000),
        ])
        viewModel.toggleSelection(for: categoriesKey("cat_a"))
        viewModel.toggleSelection(for: key("nmx", "i1"))

        // Scope 1 — totalRecoverable: AGGREGATE-CATEGORY items only, the
        // as-built `!isEmpty && state != .denied` filter: 4096 + 2048 + the
        // partiallyDenied measured floor. Per-item bytes EXCLUDED.
        XCTAssertEqual(viewModel.totalRecoverable, 4096 + 2048 + 1024)

        // Scope 2 — per-scanner section total: the section's own selected
        // bytes (as-built selectedNodeModulesSize).
        XCTAssertEqual(viewModel.selectedSize(forScanner: "nmx"), 5000)

        // Scope 3 — totalSelectedSize: selected bytes across BOTH scanners
        // (as-built selectedSize + selectedNodeModulesSize).
        XCTAssertEqual(viewModel.totalSelectedSize, 4096 + 5000)

        // The D8 caveat constant still rides beside the headline totals.
        XCTAssertEqual(viewModel.overcountCaveat, DiskSpaceCaveat.overcount)
    }

    // MARK: - Malformed outcomes: fail-closed disposition (validation lives
    // in the runtime; the view model applies only the disposition)

    @MainActor
    func testForeignScannerIDArrivesAsMalformedAndFailsClosed() async throws {
        let valid = ScanOutcome(
            items: [perItem(scanner: "mal", id: "v1")], errors: []
        )
        // An item OWNED by another scanner — the runtime validator (not the
        // view model) classifies the whole outcome malformed.
        let foreign = ScanOutcome(
            items: [perItem(scanner: "other", id: "f1")], errors: []
        )
        let sequence = OutcomeSequence([valid, foreign, valid])
        let runtime = try makeRuntime([
            FixtureScanner(id: "mal") { await sequence.next() }
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .automatic)
        viewModel.toggleSelection(for: key("mal", "v1"))

        await viewModel.scan(trigger: .automatic)

        // Nothing published; previous items AND selections retained; the
        // path-less issue surfaced.
        XCTAssertEqual(viewModel.items(forScanner: "mal").map(\.id), ["v1"],
                       "a malformed outcome publishes NOTHING — previous items retained")
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("mal", "v1")),
                      "previous selections retained — nothing user-set is lost")
        let issue = try XCTUnwrap(viewModel.malformedIssuesByScannerID["mal"])
        XCTAssertEqual(issue.kind, .malformedOutcome)
        XCTAssertNil(issue.url, "no filesystem location exists — never a fake path")
        XCTAssertTrue(
            viewModel.perItemSections.first { $0.scannerID == "mal" }?
                .issues.contains(issue) ?? false,
            "the issue is surfaced on the scanner's section"
        )

        // A later valid outcome clears the malformed surface.
        await viewModel.scan(trigger: .automatic)
        XCTAssertNil(viewModel.malformedIssuesByScannerID["mal"])
    }

    @MainActor
    func testDuplicateItemIDsArriveAsMalformedAndFailClosed() async throws {
        let valid = ScanOutcome(
            items: [perItem(scanner: "mal", id: "v1")], errors: []
        )
        let duplicated = ScanOutcome(
            items: [
                perItem(scanner: "mal", id: "dup"),
                perItem(scanner: "mal", id: "dup", name: "second"),
            ],
            errors: []
        )
        let sequence = OutcomeSequence([valid, duplicated])
        let runtime = try makeRuntime([
            FixtureScanner(id: "mal") { await sequence.next() }
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .automatic)
        viewModel.toggleSelection(for: key("mal", "v1"))

        await viewModel.scan(trigger: .automatic)

        XCTAssertEqual(viewModel.items(forScanner: "mal").map(\.id), ["v1"],
                       "duplicate ids render the WHOLE outcome malformed — nothing published")
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("mal", "v1")))
        let issue = try XCTUnwrap(viewModel.malformedIssuesByScannerID["mal"])
        XCTAssertEqual(issue.kind, .malformedOutcome)
        XCTAssertNil(issue.url)
    }

    // MARK: - clean(): the unified entry, exactly the selection

    @MainActor
    func testCleanDrivesUnifiedEntryWithExactlySelectedItems() async throws {
        // Real filesystem: two candidate directories under one container;
        // only the SELECTED one may be deleted. The cleaner is
        // runtime-constructed, so the fixture scanner's declared container
        // root reaches delete-time admission purely via registration.
        let container = base.appendingPathComponent("projects")
        let junkA = container.appendingPathComponent("junk_a")
        let junkB = container.appendingPathComponent("junk_b")
        for dir in [junkA, junkB] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0xAB, count: 4096)
                .write(to: dir.appendingPathComponent("payload.bin"))
        }

        let runtime = try makeRuntime([
            DirectoryFixtureScanner(id: "fixture_items", container: container)
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)
        viewModel.moveToTrash = false  // permanent delete, fixture-contained

        await viewModel.scan(trigger: .userInitiated)
        XCTAssertEqual(viewModel.items(forScanner: "fixture_items").map(\.id),
                       ["junk_a", "junk_b"])

        viewModel.toggleSelection(for: key("fixture_items", "junk_a"))
        await viewModel.clean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.entries.map(\.itemID), ["junk_a"],
                       "clean receives EXACTLY the selected items")
        XCTAssertEqual(report.entries.map(\.scannerID), ["fixture_items"])
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertFalse(fm.fileExists(atPath: junkA.path),
                       "the selected item is deleted")
        XCTAssertTrue(fm.fileExists(atPath: junkB.path),
                      "the unselected item is untouched")
        XCTAssertTrue(viewModel.showCleanupReport)

        // clean()'s trailing rescan re-emitted only junk_b, so the vanished
        // key's selection was pruned at that scan's completion.
        XCTAssertEqual(viewModel.items(forScanner: "fixture_items").map(\.id),
                       ["junk_b"])
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty)
    }
}

// MARK: - Fixture scanner machinery

/// A `SpaceScanner` whose outcome is injected — the epic's "implement
/// protocol + register" seam, exercised with zero production edits.
private struct FixtureScanner: SpaceScanner {
    let id: String
    var displayName: String { "Fixture \(id)" }
    var trustedContainerRoots: [URL] { [] }
    let provide: @Sendable () async -> ScanOutcome

    init(id: String, provide: @escaping @Sendable () async -> ScanOutcome) {
        self.id = id
        self.provide = provide
    }

    func scan(context: ScanContext) async -> ScanOutcome {
        await provide()
    }
}

/// A REAL tiny per-item scanner over one container directory: one
/// `.removeItem` `ReclaimableItem` per child, and the container declared as
/// a trusted root — delete-time admission derives from registration alone.
private struct DirectoryFixtureScanner: SpaceScanner {
    let id: String
    let container: URL
    var displayName: String { "Fixture \(id)" }
    var trustedContainerRoots: [URL] { [container] }

    func scan(context: ScanContext) async -> ScanOutcome {
        let children = ((try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil, options: []
        )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let items = children.map { child in
            ReclaimableItem(
                id: child.lastPathComponent,
                scannerID: id,
                displayName: child.lastPathComponent,
                exactBytes: 4096,
                estimatedUpToBytes: 0,
                logicalBytes: nil,
                itemCount: 1,
                url: child,
                declaredDisplayPath: child.path,
                rootRecords: [RootScanRecord(
                    requestedURL: child, resolvedURL: child, status: .measured
                )],
                state: .measured,
                scanError: nil,
                risk: .review,
                evidence: "fixture item \(child.lastPathComponent)",
                rebuildNote: nil,
                action: .removeItem,
                admission: .containerItem(
                    originContainer: container, requestedTargetURL: child
                ),
                defaultSelected: false,
                automaticCleanEligible: false,
                isStale: nil
            )
        }
        return ScanOutcome(items: items, errors: [])
    }
}

/// An openable/closable gate the staggered fixtures block on.
private actor ScanGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func close() { opened = false }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Sequential outcomes across rescans (the last outcome repeats).
private actor OutcomeSequence {
    private var outcomes: [ScanOutcome]

    init(_ outcomes: [ScanOutcome]) {
        precondition(!outcomes.isEmpty)
        self.outcomes = outcomes
    }

    func next() -> ScanOutcome {
        outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
    }
}
