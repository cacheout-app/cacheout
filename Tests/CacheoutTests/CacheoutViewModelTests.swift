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
/// - malformed-BLOCKED scanners are display-only: retained items/selections
///   stay visible but every destructive path (clean()'s input, the sheet,
///   Quick Clean/selectAllSafe, Select Stale/All, the Clean gate) excludes
///   them until a valid outcome lifts the block
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

    /// A `FixtureScanner` DECLARING the origin container `perItem(scanner:
    /// id)` claims (`base/<id>`) — the runtime validator's origin binding
    /// (round 6) checks a container-item origin against the producing
    /// scanner's registration-declared roots, so a fixture emitting valid
    /// per-item outcomes must declare like production does.
    private func fixtureScanner(
        _ id: String,
        provide: @escaping @Sendable () async -> ScanOutcome
    ) -> FixtureScanner {
        FixtureScanner(
            id: id,
            trustedContainerRoots: [base.appendingPathComponent(id)],
            provide: provide
        )
    }

    /// A per-item fixture `ReclaimableItem` that PASSES the runtime
    /// validator's structural invariants (`.removeItem` + `.containerItem`
    /// with the producing scanner's declared origin).
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
            fixtureScanner("aaa") { outcomeA },
            fixtureScanner("bbb") { await gate.wait(); return outcomeB },
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

    // MARK: - Cancellation keeps the scan guard honest (PR #455 P2)

    /// Cancelling the consuming task terminates the stream immediately, but
    /// the producer's filesystem walk only winds down cooperatively. The
    /// guard that every scan-start, `clean()`, and `shouldAutoRescan` read
    /// must HOLD until the producer has ACTUALLY finished — releasing it at
    /// stream termination let a new scan or a cleanup overlap the orphaned
    /// walk on the same trees.
    @MainActor
    func testCancelledScanHoldsGuardUntilProducerActuallyFinishes() async throws {
        let entered = ScanGate()  // fixture signals: walk underway
        let release = ScanGate()  // test releases the blocked walk
        let runtime = try makeRuntime([
            fixtureScanner("slow_walk") {
                // Simulates the non-cooperative stretch of a real walk:
                // blocked on a continuation, NOT cancellation-responsive.
                await entered.open()
                await release.wait()
                return ScanOutcome(items: [], errors: [])
            },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        let scanTask = Task { await viewModel.scan(trigger: .automatic) }
        await entered.wait()
        XCTAssertTrue(viewModel.isAnyScanInProgress)

        // Cancel the consumer while the producer's walk is still blocked.
        scanTask.cancel()

        // Give the cancelled scan() every chance to (wrongly) release the
        // guard — before this fix it did so promptly at stream termination.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(viewModel.isAnyScanInProgress,
                      "the guard must hold while the cancelled scan's producer still walks")
        XCTAssertFalse(viewModel.shouldAutoRescan,
                       "a reopened view must not start an overlapping scan")

        // Release the walk: the producer finishes and ONLY then does the
        // guard clear. The cancelled scan still never counts as completed.
        await release.open()
        await scanTask.value
        XCTAssertFalse(viewModel.isAnyScanInProgress)
        XCTAssertFalse(viewModel.hasScanned,
                       "a cancelled scan never counts as a completed one")
    }

    // MARK: - Session-scoped guard & generation pairing (PR #456 P2)

    /// A scan attempt while a session is in flight must NO-OP per the
    /// re-entrancy convention (guard + return) — never queue, never
    /// interleave — and each completed session's adoption pairs ITS OWN
    /// events with ITS OWN snapshot.
    @MainActor
    func testScanAttemptMidSessionNoOpsAndEachSessionPairsItsOwnAdoption() async throws {
        let entered = ScanGate()
        let release = ScanGate()
        let calls = CallCounter()
        let firstGated = ScanOutcome(
            items: [perItem(scanner: "ggg", id: "g1")], errors: []
        )
        let secondGated = ScanOutcome(
            items: [perItem(scanner: "ggg", id: "g2")], errors: []
        )
        let gatedSequence = OutcomeSequence([firstGated, secondGated])
        let fastOutcome = ScanOutcome(
            items: [perItem(scanner: "fff", id: "f1")], errors: []
        )
        let runtime = try makeRuntime([
            fixtureScanner("fff") {
                await calls.increment(); return fastOutcome
            },
            fixtureScanner("ggg") {
                await entered.open()
                await release.wait()
                return await gatedSequence.next()
            },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        let scanA = Task { await viewModel.scan(trigger: .automatic) }
        await entered.wait()
        try await waitUntil("fast scanner delivered mid-session A") {
            !viewModel.items(forScanner: "fff").isEmpty
        }

        // Session A mid-stream: the attempt returns without effect.
        await viewModel.scan(trigger: .userInitiated)
        let callsAfterBlockedAttempt = await calls.count
        XCTAssertEqual(callsAfterBlockedAttempt, 1,
                       "a blocked scan attempt must not re-invoke any scanner")
        XCTAssertEqual(viewModel.scanGeneration, 0, "no completed scan yet")
        XCTAssertTrue(viewModel.isAnyScanInProgress,
                      "the blocked attempt must not perturb session A's guard")

        await release.open()
        await scanA.value

        // A's adoption pairs A's events with A's snapshot: everything the
        // session reconciled is cleanable (stamped generation == adopted
        // generation) — the blocked attempt changed no provenance.
        XCTAssertEqual(viewModel.scanGeneration, 1)
        viewModel.toggleSelection(for: key("fff", "f1"))
        viewModel.toggleSelection(for: key("ggg", "g1"))
        XCTAssertEqual(viewModel.selectedItems.map(\.key),
                       [key("fff", "f1"), key("ggg", "g1")],
                       "session A's items pair with session A's adoption")
        XCTAssertTrue(viewModel.hasCleanableSelection)

        // A subsequent session B pairs its own adoption: g1 vanished (its
        // selection pruned at B's completion), g2 arrives cleanable.
        await viewModel.scan(trigger: .automatic)
        let callsAfterB = await calls.count
        XCTAssertEqual(callsAfterB, 2, "session B invoked each scanner once")
        XCTAssertEqual(viewModel.scanGeneration, 2)
        XCTAssertEqual(viewModel.items(forScanner: "ggg").map(\.id), ["g2"])
        XCTAssertFalse(viewModel.selectedItemKeys.contains(key("ggg", "g1")),
                       "g1 vanished in session B — pruned at B's completion")
        viewModel.toggleSelection(for: key("ggg", "g2"))
        XCTAssertTrue(viewModel.selectedItems.map(\.key).contains(key("ggg", "g2")),
                      "session B's outcome pairs with session B's adoption")
    }

    /// The guard is SESSION-KEYED: a cancelled session's wind-down blocks
    /// new scans, its own epilogue (and only that) releases the guard, and
    /// a fresh session afterwards runs to adoption — the release path can
    /// neither strand the guard nor clear a session it does not own.
    @MainActor
    func testCancelledWindDownBlocksNewScanThenReleasesGuardForFreshSession() async throws {
        let entered = ScanGate()
        let release = ScanGate()
        let calls = CallCounter()
        let runtime = try makeRuntime([
            fixtureScanner("slow_walk") {
                await calls.increment()
                await entered.open()
                await release.wait()
                return ScanOutcome(items: [], errors: [])
            },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        let scanA = Task { await viewModel.scan(trigger: .automatic) }
        await entered.wait()
        scanA.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Mid-wind-down: a new scan must no-op against the held guard.
        await viewModel.scan(trigger: .userInitiated)
        let callsDuringWindDown = await calls.count
        XCTAssertEqual(callsDuringWindDown, 1,
                       "no scanner re-invoked while the walk winds down")
        XCTAssertTrue(viewModel.isAnyScanInProgress)

        await release.open()
        await scanA.value
        XCTAssertFalse(viewModel.isAnyScanInProgress,
                       "the owning session's epilogue releases the guard — "
                       + "cancelled path included")
        XCTAssertFalse(viewModel.hasScanned)

        // Guard released: a FRESH session completes and adopts.
        await viewModel.scan(trigger: .userInitiated)
        let callsAfterFresh = await calls.count
        XCTAssertEqual(callsAfterFresh, 2)
        XCTAssertTrue(viewModel.hasScanned)
        XCTAssertEqual(viewModel.scanGeneration, 1)
    }

    /// PR #456 P2 regression probe: whenever the in-flight guard reads
    /// FALSE on the MainActor, the finished session's adoption has ALREADY
    /// landed (`scanGeneration` advanced in the same synchronous step that
    /// released the guard). Before the fix the guard derived from
    /// `scanningScannerIDs`, which empties on the LAST event — several
    /// MainActor suspensions before adoption — so a poll (or a second
    /// scan, or a clean) could observe guard-down with adoption pending
    /// and interleave into the session's epilogue, cross-pairing its
    /// generation with the other session's snapshot. Each iteration polls
    /// at Task.yield granularity to land inside that window if it exists.
    @MainActor
    func testGuardNeverReadsClearBeforeSnapshotAdoption() async throws {
        let outcome = ScanOutcome(
            items: [perItem(scanner: "sss", id: "s1")], errors: []
        )
        let runtime = try makeRuntime([fixtureScanner("sss") { outcome }])
        let viewModel = CacheoutViewModel(runtime: runtime)

        for iteration in 0..<25 {
            let scanTask = Task { await viewModel.scan(trigger: .automatic) }
            // Wait for the session to rise — or to complete outright
            // between our slices, in which case both loops fall through
            // and the assertion holds trivially.
            while !viewModel.isAnyScanInProgress
                && viewModel.scanGeneration == iteration {
                await Task.yield()
            }
            while viewModel.isAnyScanInProgress {
                await Task.yield()
            }
            XCTAssertEqual(
                viewModel.scanGeneration, iteration + 1,
                "iteration \(iteration): the guard dropped before adoption "
                + "— a second scan could interleave into the epilogue"
            )
            await scanTask.value
        }
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
            fixtureScanner("aaa") { outcomeA },
            fixtureScanner("bbb") { await gateB.wait(); return outcomeB },
            fixtureScanner("ccc") { await gateC.wait(); return outcomeC },
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
            fixtureScanner("aaa") { await gate.wait(); return await sequenceA.next() },
            fixtureScanner("bbb") { outcomeB },
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
            fixtureScanner("xxx") { outcomeX },
            fixtureScanner("yyy") { outcomeY },
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
        let runtime = try makeRuntime([fixtureScanner("ddd") { outcome }])
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
            fixtureScanner("ddd") { await sequence.next() }
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

    @MainActor
    func testBoundaryDeniedShapeIsUnselectableWhileDenialPartialStaysToggleable() throws {
        // PR #455 P2: a boundary-bearing node_modules candidate publishes
        // the `.denied` shape (zero components, `.other` error naming the
        // boundary) because the cleaner refuses the WHOLE target while the
        // boundary remains — the GUI must never stage it, and its bytes
        // must never light a total. A DENIAL-partial item, whose deletion
        // genuinely proceeds and partially succeeds, keeps its
        // manual-selection-with-warning behavior verbatim (R18).
        // The scanner must be REGISTERED (not only seeded): `selectedItems`
        // — and therefore the confirmation-sheet derivations asserted below
        // — iterates the runtime's registration order.
        let runtime = try makeRuntime([
            fixtureScanner("nm") { ScanOutcome(items: [], errors: []) }
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)
        let boundaryKey = key("nm", "boundary_item")
        let partialKey = key("nm", "partial_item")
        seed(viewModel, scanner: "nm", items: [
            perItem(scanner: "nm", id: "boundary_item", bytes: 0,
                    state: .denied,
                    scanError: ScanError(
                        kind: .other,
                        message: "mount boundary at /x — subtree not "
                            + "measured; deletion would be refused"
                    )),
            perItem(scanner: "nm", id: "partial_item", bytes: 2_048,
                    state: .partiallyDenied,
                    scanError: ScanError(kind: .permissionDenied, message: "x")),
        ])

        viewModel.toggleSelection(for: boundaryKey)
        XCTAssertFalse(viewModel.selectedItemKeys.contains(boundaryKey),
                       "a boundary-refused item can never be staged for "
                        + "cleaning — the toggle is a no-op")

        viewModel.toggleSelection(for: partialKey)
        XCTAssertTrue(viewModel.selectedItemKeys.contains(partialKey),
                      "denial-partial stays manually toggleable (R18)")
        XCTAssertTrue(viewModel.hasPartiallyDeniedSelection,
                      "…and the confirmation sheet still gets its warning")
        viewModel.toggleSelection(for: partialKey)

        viewModel.selectAll(inScanner: "nm")
        XCTAssertEqual(viewModel.selectedItemKeys, [partialKey],
                       "Select All stages the denial-partial item only — "
                        + "the boundary shape is skipped")
        XCTAssertEqual(viewModel.totalSize(forScanner: "nm"), 2_048,
                       "the boundary item's zero components contribute "
                        + "nothing to the section total")
    }

    // MARK: - Displayable output: issue-only scans must render (R14/D6)

    @MainActor
    func testIssueOnlyScanOutputIsDisplayable() throws {
        let runtime = try makeRuntime([])
        let viewModel = CacheoutViewModel(runtime: runtime)
        XCTAssertFalse(viewModel.hasDisplayableScanOutput,
                       "nothing scanned yet — the empty state may show")

        // Zero items, one classified issue: the results list must mount so
        // the denied root renders — never the empty state.
        seed(viewModel, scanner: "nmx", items: [], errors: [
            ScanIssue(url: base.appendingPathComponent("Documents"),
                      kind: .permissionDenied, detail: "denied"),
        ])
        XCTAssertFalse(viewModel.hasResults, "no items anywhere")
        XCTAssertTrue(viewModel.hasDisplayableScanOutput,
                      "an issue-only scan is displayable output (R14/D6)")
    }

    @MainActor
    func testFirstEventMalformedWithNoPriorItemsIsDisplayable() async throws {
        // A scanner whose FIRST outcome is malformed has no prior items to
        // retain — the fail-closed refusal must still be visible.
        let foreign = ScanOutcome(
            items: [perItem(scanner: "other", id: "f1")], errors: []
        )
        let runtime = try makeRuntime([
            fixtureScanner("mal") { foreign }
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .automatic)

        XCTAssertFalse(viewModel.hasResults)
        XCTAssertNotNil(viewModel.malformedIssuesByScannerID["mal"])
        XCTAssertTrue(viewModel.hasDisplayableScanOutput,
                      "a fail-closed refusal is only fail-closed if it is visible")
    }

    // MARK: - Quick Clean gate reads the policy (b) surface

    @MainActor
    func testAutomaticCleanableSizeFollowsPolicyBAcrossScanners() throws {
        let runtime = try makeRuntime([])
        let viewModel = CacheoutViewModel(runtime: runtime)

        // Recoverable bytes exist (review-risk category + ineligible safe
        // per-item rows), but policy (b) would select NOTHING — the Quick
        // Clean gate must read as "nothing to clean".
        seed(viewModel, scanner: CategoryScanner.registeredID, items: [
            aggregate(slug: "review_cat", state: .measured, exact: 4096,
                      items: 1, risk: .review, defaultSelected: false),
        ])
        seed(viewModel, scanner: "nmx", items: [
            perItem(scanner: "nmx", id: "safe_ineligible", risk: .safe,
                    automaticCleanEligible: false),
        ])
        XCTAssertGreaterThan(viewModel.totalRecoverable, 0)
        XCTAssertEqual(viewModel.automaticCleanableSize, 0)
        XCTAssertFalse(viewModel.hasAutomaticCleanableItems,
                       "bytes policy (b) will not touch must not light Quick Clean")

        // A safe ELIGIBLE item on a NON-category scanner keeps Quick Clean
        // live even with zero category bytes — the auto path is
        // registry-wide, not category-scoped.
        seed(viewModel, scanner: CategoryScanner.registeredID, items: [])
        seed(viewModel, scanner: "eligible", items: [
            perItem(scanner: "eligible", id: "safe_ok", bytes: 2048,
                    risk: .safe, automaticCleanEligible: true),
        ])
        XCTAssertEqual(viewModel.totalRecoverable, 0, "no category bytes")
        XCTAssertEqual(viewModel.automaticCleanableSize, 2048)
        XCTAssertTrue(viewModel.hasAutomaticCleanableItems)
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

    @MainActor
    func testMultiScannerTotalsSaturateInsteadOfTrapping() async throws {
        // Round 8: the runtime validator bounds every SINGLE outcome's
        // component sum, but the frozen totals add ACROSS scanners — two
        // individually valid outcomes can still exceed Int64.max together,
        // so the shared helper saturates (a clamped ceiling is honest at
        // physically impossible magnitudes; a trap is not). Both outcomes
        // ride the REAL scan path, so each also proves the validator's
        // exactly-Int64.max boundary passes end-to-end.
        let bigA = perItem(scanner: "sat_a", id: "a1", bytes: .max)
        let bigB = perItem(scanner: "sat_b", id: "b1", bytes: .max)
        let runtime = try makeRuntime([
            fixtureScanner("sat_a") { ScanOutcome(items: [bigA], errors: []) },
            fixtureScanner("sat_b") { ScanOutcome(items: [bigB], errors: []) },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .userInitiated)
        XCTAssertNil(viewModel.malformedIssuesByScannerID["sat_a"],
                     "a single outcome AT the Int64.max boundary validates")
        XCTAssertNil(viewModel.malformedIssuesByScannerID["sat_b"])
        XCTAssertEqual(viewModel.totalSize(forScanner: "sat_a"), .max,
                       "a single scanner at the ceiling is exact, not clamped")

        viewModel.toggleSelection(for: key("sat_a", "a1"))
        viewModel.toggleSelection(for: key("sat_b", "b1"))

        XCTAssertEqual(viewModel.totalSelectedSize, .max,
                       "cross-scanner totals clamp at Int64.max instead of trapping")
        XCTAssertEqual(viewModel.totalCleanableSelectedSize, .max,
                       "the destructive-scoped variant rides the same helper")
        XCTAssertFalse(viewModel.formattedTotalSelectedSize.isEmpty,
                       "the clamped total still formats for display")
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
            fixtureScanner("mal") { await sequence.next() }
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
            fixtureScanner("mal") { await sequence.next() }
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

    // MARK: - Malformed-BLOCKED scanners: retained records are display-only
    // (every destructive path excludes them until a valid outcome arrives)

    @MainActor
    func testMalformedRescanBlocksRetainedItemsFromDestructivePaths() async throws {
        let validMal = ScanOutcome(
            items: [perItem(scanner: "mal", id: "m1", bytes: 7000, risk: .safe,
                            automaticCleanEligible: true, isStale: true)],
            errors: []
        )
        let foreign = ScanOutcome(
            items: [perItem(scanner: "other", id: "f1")], errors: []
        )
        let malSequence = OutcomeSequence([validMal, foreign, validMal])
        let okOutcome = ScanOutcome(
            items: [perItem(scanner: "ok", id: "o1", bytes: 5000)], errors: []
        )
        let runtime = try makeRuntime([
            fixtureScanner("mal") { await malSequence.next() },
            fixtureScanner("ok") { okOutcome },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .automatic)
        viewModel.toggleSelection(for: key("mal", "m1"))
        viewModel.toggleSelection(for: key("ok", "o1"))
        XCTAssertEqual(viewModel.selectedItems.map(\.key),
                       [key("mal", "m1"), key("ok", "o1")],
                       "both selections cleanable while both scanners are valid")
        XCTAssertEqual(viewModel.automaticCleanableSize, 7000,
                       "policy (b) sees mal's safe eligible item pre-block")

        // Rescan: mal's outcome is rejected as malformed; ok stays valid.
        await viewModel.scan(trigger: .automatic)
        XCTAssertNotNil(viewModel.malformedIssuesByScannerID["mal"])

        // Display retention is UNCHANGED (epic contract): items, selections,
        // section rows, and the frozen display totals still show the
        // retained records — the block is destructive-path-only.
        XCTAssertEqual(viewModel.items(forScanner: "mal").map(\.id), ["m1"])
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("mal", "m1")))
        XCTAssertTrue(
            viewModel.perItemSections.first { $0.scannerID == "mal" }?
                .items.isEmpty == false,
            "retained rows stay displayable"
        )
        XCTAssertEqual(viewModel.selectedSize(forScanner: "mal"), 7000,
                       "frozen scope 2 stays display-scoped (mirrors checkmarks)")
        XCTAssertEqual(viewModel.totalSelectedSize, 7000 + 5000,
                       "frozen scope 3 stays display-scoped (mirrors checkmarks)")

        // Destructive derivations exclude the blocked scanner.
        XCTAssertEqual(viewModel.selectedItems.map(\.key), [key("ok", "o1")],
                       "clean()'s input excludes the malformed-blocked scanner")
        XCTAssertEqual(viewModel.confirmationRows.map(\.key), [key("ok", "o1")],
                       "the sheet itemizes exactly what clean() acts on")
        XCTAssertEqual(viewModel.cleanableSelectedCount, 1)
        XCTAssertEqual(viewModel.totalCleanableSelectedSize, 5000)
        XCTAssertEqual(viewModel.automaticCleanableSize, 0,
                       "Quick Clean's gate must not count blocked bytes")
        XCTAssertFalse(viewModel.hasAutomaticCleanableItems)

        // The bulk selection paths refuse to (re)stage blocked items.
        viewModel.deselectAll()
        viewModel.selectAllSafe()
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty,
                      "policy (b) skips the blocked scanner's retained safe item")
        viewModel.selectStale(inScanner: "mal")
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty,
                      "Select Stale is a no-op on a blocked scanner")
        viewModel.selectAll(inScanner: "mal")
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty,
                      "Select All is a no-op on a blocked scanner")

        // The Clean gate reads the CLEANABLE selection, not bare keys.
        viewModel.toggleSelection(for: key("mal", "m1"))
        XCTAssertTrue(viewModel.hasSelection,
                      "the individual checkbox stays live — retained state is "
                      + "the user's to curate")
        XCTAssertFalse(viewModel.hasCleanableSelection,
                       "a blocked-only selection must not enable Clean")

        // A subsequent VALID outcome lifts the block: the retained selection
        // (user-set state, kept verbatim) is cleanable again.
        await viewModel.scan(trigger: .automatic)
        XCTAssertNil(viewModel.malformedIssuesByScannerID["mal"])
        XCTAssertEqual(viewModel.selectedItems.map(\.key), [key("mal", "m1")])
        XCTAssertTrue(viewModel.hasCleanableSelection)
        XCTAssertEqual(viewModel.totalCleanableSelectedSize, 7000)
        XCTAssertEqual(viewModel.automaticCleanableSize, 7000)
    }

    @MainActor
    func testCleanNeverTouchesMalformedBlockedScanner() async throws {
        // Real filesystem for the healthy scanner; a fixture scanner that
        // goes malformed AFTER publishing a valid outcome. The blocked
        // scanner's retained selection must leave NO trace in the clean
        // report — no entry AND no error: excluded before dispatch, not
        // refused at dispatch.
        let container = base.appendingPathComponent("projects")
        let junkA = container.appendingPathComponent("junk_a")
        try fm.createDirectory(at: junkA, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4096)
            .write(to: junkA.appendingPathComponent("payload.bin"))

        // The retained item's deletion target (perItem targets base/mal/m1).
        let malTarget = base
            .appendingPathComponent("mal").appendingPathComponent("m1")
        try fm.createDirectory(at: malTarget, withIntermediateDirectories: true)

        let validMal = ScanOutcome(
            items: [perItem(scanner: "mal", id: "m1")], errors: []
        )
        let foreign = ScanOutcome(
            items: [perItem(scanner: "other", id: "f1")], errors: []
        )
        let malSequence = OutcomeSequence([validMal, foreign, validMal])
        let runtime = try makeRuntime([
            fixtureScanner("mal") { await malSequence.next() },
            DirectoryFixtureScanner(id: "fixture_items", container: container),
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)
        viewModel.moveToTrash = false  // permanent delete, fixture-contained

        await viewModel.scan(trigger: .userInitiated)
        viewModel.toggleSelection(for: key("mal", "m1"))
        viewModel.toggleSelection(for: key("fixture_items", "junk_a"))

        // Rescan rejects mal's outcome; its selection is retained, blocked.
        await viewModel.scan(trigger: .userInitiated)
        XCTAssertNotNil(viewModel.malformedIssuesByScannerID["mal"])

        await viewModel.clean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.entries.map(\.itemID), ["junk_a"],
                       "clean receives ONLY the unblocked selection")
        XCTAssertTrue(report.errors.isEmpty,
                      "the blocked item never reaches dispatch — not even as "
                      + "a refusal: \(report.errors)")
        XCTAssertTrue(fm.fileExists(atPath: malTarget.path),
                      "the blocked scanner's retained target is untouched")
        XCTAssertFalse(fm.fileExists(atPath: junkA.path))

        // clean()'s trailing rescan delivered mal's next VALID outcome: the
        // block lifts and the retained selection is cleanable again.
        XCTAssertNil(viewModel.malformedIssuesByScannerID["mal"])
        XCTAssertEqual(viewModel.selectedItems.map(\.key), [key("mal", "m1")])
        XCTAssertTrue(viewModel.hasCleanableSelection)
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
/// `trustedContainerRoots` must cover any container-item origin the
/// injected outcome claims (round 6 origin binding) — the test-class
/// `fixtureScanner` helper declares `perItem`'s origin automatically.
private struct FixtureScanner: SpaceScanner {
    let id: String
    var displayName: String { "Fixture \(id)" }
    let trustedContainerRoots: [URL]
    let provide: @Sendable () async -> ScanOutcome

    init(
        id: String,
        trustedContainerRoots: [URL] = [],
        provide: @escaping @Sendable () async -> ScanOutcome
    ) {
        self.id = id
        self.trustedContainerRoots = trustedContainerRoots
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

/// Counts fixture-scanner invocations — proof that a guarded-out scan
/// attempt never re-invoked the scanners.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
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
