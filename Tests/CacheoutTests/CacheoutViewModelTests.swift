import Combine
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
/// - fn-4.10 (R8): the runtime-RECONSTRUCTION seam — injected composition
///   preserved across a Settings-triggered rebuild, deferred latest-value-
///   wins replacement, and the destructive-freshness invalidation that
///   keeps a new runtime's cleaner away from an old runtime's snapshot
///
/// Everything runs hermetically against fixture homes, fixture scanners and
/// an ephemeral UserDefaults suite — zero reads of the real `$HOME`.
final class CacheoutViewModelTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private var devRootsDefaults: UserDefaults!
    private var suiteName: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("CacheoutViewModelTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
        // The dev-roots config the fn-4.10 seam resolves — an EPHEMERAL
        // suite, never the standard one (house rule).
        suiteName = "CacheoutViewModelTests-\(UUID().uuidString)"
        devRootsDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        if let suiteName {
            devRootsDefaults?.removePersistentDomain(forName: suiteName)
        }
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Fixtures

    private func makeRuntime(
        _ scanners: [any SpaceScanner],
        categories: [CacheCategory] = [],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        sessionBounds: ScanSessionBounds = .default
    ) throws -> SpaceScannerRuntime {
        try SpaceScannerRuntime(
            scanners: scanners,
            categories: categories,
            home: fixtureHome,
            provider: provider,
            sessionBounds: sessionBounds
        )
    }

    /// The root names `makeReconstruction`'s factory knows how to compose a
    /// fixture runtime for.
    private static let reconstructionRootNames = [
        "alpha", "beta", "gamma", "delta",
    ]

    /// Persists the declared dev roots the NEXT `devRootsDidChange()` will
    /// resolve — through the store's OWN key, so resolution runs the same
    /// parse/policy/dedupe pipeline production runs.
    private func persistDevRoots(_ names: [String]) {
        devRootsDefaults.set(names, forKey: DevRootsStore.devRootsKey)
    }

    private func makeDevRootsStore() -> DevRootsStore {
        DevRootsStore(
            defaults: devRootsDefaults, provider: FileSystemIdentityProvider()
        )
    }

    /// The fn-4.10 reconstruction seam over FIXTURE compositions: the
    /// injected factory maps a resolution to a runtime holding ONE fixture
    /// scanner named after the LAST kept root (`~/beta` → `root_beta`), and
    /// records every resolution it was handed. No production scanner could
    /// ever answer those ids, so "the rebuild silently swapped the injected
    /// composition for production defaults" is a single assertion away.
    private func makeReconstruction() throws
        -> (CacheoutViewModel.RuntimeReconstruction, ResolutionLog)
    {
        let base = self.base!
        let home = self.fixtureHome!
        // `let` on purpose: the factory below is `@Sendable`, and a captured
        // `var` is a Swift 6 error.
        let outcomes = XCTUniquelyKeyed(
            Self.reconstructionRootNames.map { name in
                (
                    "root_\(name)",
                    ScanOutcome(
                        items: [
                            perItem(scanner: "root_\(name)", id: "\(name)_item")
                        ],
                        errors: []
                    )
                )
            }
        )
        let log = ResolutionLog()
        // THE FALLBACK EXISTS SO THE FACTORY BELOW CANNOT TRAP (PR #460 codex
        // r6, D4). The factory is NON-throwing, so the composition inside it
        // used to be a `try!` — and what decides that throw is PRODUCTION's
        // registration validation, so a regression there turned this cell into
        // a `SIGILL` that took every later class in the run with it (this class
        // sorts near the front). Built HERE instead, in a throwing test
        // context, where the same failure is one red cell; the factory falls
        // back to it and the assertions about scanner ids then fail loudly
        // rather than the process dying.
        let fallback = try SpaceScannerRuntime(
            scanners: [], categories: [], home: home,
            provider: FileSystemIdentityProvider()
        )
        let seam = CacheoutViewModel.RuntimeReconstruction(
            devRootsStore: makeDevRootsStore(),
            home: home
        ) { resolution in
            log.record(resolution)
            let scannerID =
                "root_\(resolution.keptRoots.last?.lastPathComponent ?? "none")"
            let outcome = outcomes[scannerID]
                ?? ScanOutcome(items: [], errors: [])
            let scanner = FixtureScanner(
                id: scannerID,
                trustedContainerRoots: [base.appendingPathComponent(scannerID)],
                provide: { outcome }
            )
            // A fixture composition with one valid slug and no categories
            // cannot fail registration validation — but "cannot" is what a
            // `try!` here would be asserting about PRODUCTION code, so the
            // failure lands on `fallback` instead of on the run.
            return (try? SpaceScannerRuntime(
                scanners: [scanner],
                categories: [],
                home: home,
                provider: FileSystemIdentityProvider()
            )) ?? fallback
        }
        return (seam, log)
    }

    /// The production scanner ids a rebuilt runtime must NEVER acquire.
    /// Every id `SpaceScannerRuntime.production` registers belongs here — a
    /// missing one silently weakens the guard rather than failing it.
    private static let productionScannerIDs = [
        CategoryScanner.registeredID,
        BuildArtifactsScanner.registeredID,
        OrphanedCachesScanner.registeredID,
        GitWorktreeScanner.registeredID,
        // fn-6's scanner, added HERE as well as to the registry: the merge
        // that brought it in left this list at four of five, which is the
        // silent weakening the comment above warns about rather than a
        // failure — the guard simply stopped covering `ephemeral_tmp`.
        EphemeralTempScanner.registeredID,
    ]

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

    /// WHICH TOTALS A CROSS-SCANNER DUPLICATE INFLATES, and which it does not
    /// (PR #459 review r2). There is NO cross-scanner de-duplication: a
    /// directory that two registered scanners both recognise is published
    /// twice, same bytes, different `ItemKey`s. The totals are KEY-based, so
    /// ticking both copies counts the bytes twice — but only in the scopes
    /// that span scanners.
    ///
    /// This cell exists to EARN the sentence `docs/v1/CATEGORIES.md` ships
    /// about overlapping roots. Round 1's write-up said, unqualified, that
    /// "the total double-counts"; that is false of the product's own
    /// Reclaimable figure, which is category-scoped and counts these bytes
    /// ZERO times.
    @MainActor
    func testACrossScannerDuplicateInflatesOnlyTheSelectedScopes() throws {
        let runtime = try makeRuntime([])
        let viewModel = CacheoutViewModel(runtime: runtime)
        seed(viewModel, scanner: CategoryScanner.registeredID, items: [
            aggregate(slug: "cat_a", state: .measured, exact: 4_096, items: 1,
                      defaultSelected: false),
        ])
        // ONE directory, published by two per-item scanners with the same
        // byte figure — the shape an overlapping root produces.
        seed(viewModel, scanner: BuildArtifactsScanner.registeredID, items: [
            perItem(scanner: BuildArtifactsScanner.registeredID,
                    id: "dup", bytes: 12_000),
        ])
        seed(viewModel, scanner: EphemeralTempScanner.registeredID, items: [
            perItem(scanner: EphemeralTempScanner.registeredID,
                    id: "dup", bytes: 12_000),
        ])
        viewModel.toggleSelection(
            for: key(BuildArtifactsScanner.registeredID, "dup")
        )
        viewModel.toggleSelection(
            for: key(EphemeralTempScanner.registeredID, "dup")
        )

        XCTAssertEqual(viewModel.totalSelectedSize, 24_000,
                       "scope 3 spans scanners and counts the bytes twice")
        XCTAssertEqual(viewModel.totalCleanableSelectedSize, 24_000,
                       "and so does the figure the confirmation sheet quotes")
        XCTAssertEqual(
            viewModel.selectedSize(forScanner: EphemeralTempScanner.registeredID),
            12_000,
            "each per-scanner section total counts its own copy once"
        )
        XCTAssertEqual(
            viewModel.totalRecoverable, 4_096,
            "and the product's Reclaimable figure is CATEGORY-scoped: it "
                + "counts these bytes zero times, not twice"
        )
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

    // ====================================================================
    // MARK: - THE SESSION'S WALL-CLOCK BOUND (PR #460 codex r12, D2)
    // ====================================================================
    //
    // THE MECHANISM, AND WHY IT NEEDED A DESIGN AND NOT A PATCH.
    // `for await event in session.events` — one line of PRODUCTION, four
    // lines below `scanValidatedSession` — consumes a stream whose ONLY
    // terminator was `continuation.finish()`, reached only after the scan
    // `TaskGroup` completes. A scanner that never returns therefore parked
    // that loop forever: no failure, no total line, no exit status, and the
    // 87 `await viewModel.scan(` call sites in this suite reach it without
    // spelling a continuation of their own, so no fence over the TEST
    // sources can see it.
    //
    // REPRODUCED at 46f9640 with ONE production line mutated —
    // `SpaceScanner.swift`'s `continuation.finish()` deleted — run under a
    // pty so nothing is lost to buffering:
    //
    //     Test Suite 'CacheoutViewModelTests' started at 18:49:31.850.
    //     Test Case '…testACleanScanStillDisplaysASectionThatWasNeverInspected' started.
    //     <nothing, 240 s, killed>
    //
    // `grep -c "Executed .* tests"` = 0.
    //
    // THE BOUND IS ON THE SESSION, not on the consumer: see
    // `ScanSessionBounds`. These cells drive it through the SAME production
    // path every other cell in this file uses — `await viewModel.scan(…)` —
    // with the bound injected in milliseconds instead of minutes.

    /// THE WHOLE MECHANISM, END TO END, THROUGH PRODUCTION.
    ///
    /// A wedged scanner must not park the scan; the bound must REPORT it
    /// rather than swallow it; everything else in the session must still be
    /// published; and the next scan must be able to succeed.
    ///
    /// THE CELL ITSELF IS THE STRAND ASSERTION: without the bound, the
    /// `await viewModel.scan(…)` below never returns and this cell prints
    /// its name and nothing else, forever.
    ///
    /// MUTATION: delete the watchdog `Task` in `scanValidatedSession` and
    /// this cell hangs rather than fails — which is exactly the mechanism,
    /// so the run must be given a wall-clock timeout.
    @MainActor
    func testAWedgedScannerIsReportedAndDoesNotParkTheScan() async throws {
        let gate = StallGate()
        let okOutcome = ScanOutcome(
            items: [perItem(scanner: "ok", id: "o1", bytes: 5000)], errors: []
        )
        let wedgedOutcome = ScanOutcome(
            items: [perItem(scanner: "wedged", id: "w1")], errors: []
        )
        let wedgedSequence = OutcomeSequence([wedgedOutcome, wedgedOutcome])
        let runtime = try makeRuntime(
            [
                fixtureScanner("ok") { okOutcome },
                FixtureScanner(
                    id: "wedged",
                    trustedContainerRoots: [
                        base.appendingPathComponent("wedged"),
                    ]
                ) {
                    await gate.hold()
                    return await wedgedSequence.next()
                },
            ],
            sessionBounds: ScanSessionBounds(
                eventDeadline: .milliseconds(250),
                producerWindDownGrace: .milliseconds(50)
            )
        )
        let viewModel = CacheoutViewModel(runtime: runtime)

        // (1) A HEALTHY session first, so the retention assertion below is
        // about real previous results rather than about emptiness.
        await viewModel.scan(trigger: .automatic)
        XCTAssertEqual(viewModel.items(forScanner: "wedged").map(\.id), ["w1"])
        viewModel.toggleSelection(for: key("wedged", "w1"))

        // (2) THE WEDGE. `hold()` does not return until the test releases
        // it, and the test does not release it until after the scan has
        // come back — so the only thing that can end this scan is the bound.
        await gate.wedge()
        await viewModel.scan(trigger: .automatic)

        // (3) REPORTED, not swallowed.
        let issue = try XCTUnwrap(
            viewModel.malformedIssuesByScannerID["wedged"],
            "a scanner the bound cut off must be reported, not dropped"
        )
        XCTAssertEqual(issue.kind, .scanDidNotFinish)
        XCTAssertNil(issue.url, "a NON-filesystem kind never invents a path")
        XCTAssertTrue(
            viewModel.perItemSections.first { $0.scannerID == "wedged" }?
                .issues.contains(issue) ?? false,
            "the row is surfaced on that scanner's own section"
        )

        // (4) FAIL-CLOSED, and the same fail-closed the malformed path
        // already had: nothing published for it, previous rows and the
        // user's ticks retained.
        XCTAssertEqual(viewModel.items(forScanner: "wedged").map(\.id), ["w1"])
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("wedged", "w1")))

        // (5) A PARTIAL SCAN IS REPORTED AS PARTIAL. The scanner that DID
        // report keeps its results — the bound is not a session-wide erase.
        XCTAssertEqual(viewModel.items(forScanner: "ok").map(\.id), ["o1"])

        // (6) THE GUARD IS RELEASED, which is what makes a retry possible at
        // all: before the bound the spinner never stopped and no second scan
        // and no cleanup could start.
        XCTAssertFalse(viewModel.isAnyScanInProgress,
                       "the scan guard must not survive the bound")

        // (7) AND A RETRY CAN DIFFER — the property this branch demands of
        // every incompleteness it reports. The wedge is a wall-clock
        // condition, not a deterministic cap, so releasing it and re-scanning
        // clears the row.
        await gate.release()
        await viewModel.scan(trigger: .automatic)
        XCTAssertNil(viewModel.malformedIssuesByScannerID["wedged"],
                     "a re-scan that finishes clears the row — the remedy the "
                         + "label names is real")
        XCTAssertEqual(viewModel.items(forScanner: "wedged").map(\.id), ["w1"])
    }

    /// THE SECOND BOUND, AND THE ONE THAT IS EASY TO FORGET: ending the
    /// event stream alone would have moved the strand ONE LINE DOWN, to
    /// `await session.untilProducerFinishes()`.
    ///
    /// A task group does not return until every child does, so a scanner
    /// that ignores cancellation keeps the producer alive however firmly it
    /// is cancelled. This scanner blocks its thread outright — the honest
    /// simulation of a walk inside a syscall — for far longer than the
    /// session's two bounds combined, and `scan` must still come back.
    ///
    /// MUTATION: restore `untilProducerFinishes()` to `await producer.value`
    /// and this cell alone takes the full wedge (≈2 s) instead of the bound,
    /// and the assertion on elapsed time fails.
    @MainActor
    func testTheWindDownGraceReleasesAWalkThatIgnoresCancellation()
        async throws
    {
        let wedgeSeconds = 2.0
        let runtime = try makeRuntime(
            [
                FixtureScanner(
                    id: "uncancellable",
                    trustedContainerRoots: [
                        base.appendingPathComponent("uncancellable"),
                    ]
                ) {
                    // NOT `Task.sleep`: this must ignore cancellation the
                    // way a thread inside a syscall does.
                    Thread.sleep(forTimeInterval: wedgeSeconds)
                    return ScanOutcome(items: [], errors: [])
                },
            ],
            sessionBounds: ScanSessionBounds(
                eventDeadline: .milliseconds(200),
                producerWindDownGrace: .milliseconds(100)
            )
        )
        let viewModel = CacheoutViewModel(runtime: runtime)

        let started = Date()
        await viewModel.scan(trigger: .automatic)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, wedgeSeconds,
            "the scan must return on the session's bounds, not on the "
                + "wedged walk: \(elapsed) s"
        )
        XCTAssertFalse(viewModel.isAnyScanInProgress,
                       "…and the guard must be released with it")
        let issue = try XCTUnwrap(
            viewModel.malformedIssuesByScannerID["uncancellable"]
        )
        XCTAssertEqual(issue.kind, .scanDidNotFinish)
    }

    /// THE BOUND MUST FIRE WHEN THE COOPERATIVE POOL IS STARVED — i.e. in
    /// exactly the wedge class it exists for (PR #460 codex r13, B).
    ///
    /// The cell above wedges ONE scanner. One blocked thread out of
    /// `activeProcessorCount` leaves eleven workers free on this machine, so
    /// an r12 watchdog built on `Task.sleep` still had somewhere to resume
    /// and the cell passed — while the mechanism it was written to prove was
    /// broken. THE THRESHOLD IS THE POOL WIDTH. Measured on a 12-core
    /// machine at a 200 ms bound: 11 blocking scanners -> `scan` returned in
    /// 0.335 s (the bound); 12 -> 25.03 s (the walk); 36 -> 75.04 s.
    ///
    /// So this cell blocks MORE THREADS THAN THE POOL HAS and asserts the
    /// scan still returns on the bound. `Thread.sleep`, not `Task.sleep`:
    /// the point is to occupy the worker, not to yield it. The blockers do
    /// NOT observe cancellation, which is the honest simulation of a walk
    /// inside a syscall AND what keeps the mutation below honest — a
    /// cancellable blocker would let the mutated build off by exiting the
    /// moment the watchdog cancelled the producer.
    ///
    /// MUTATION: restore `let task = Task {` (from `Task.detached(priority:
    /// .utility)`) in `scanValidatedSession` and the producer is back in the
    /// consumer's own band; measured 2.82 s against this 0.9 s assertion.
    @MainActor
    func testTheBoundFiresWithEveryCooperativeWorkerBlocked() async throws {
        // MORE than the pool is wide: the pool is `activeProcessorCount`
        // threads per band, and the bound must not need one of them.
        let blockerCount = ProcessInfo.processInfo.activeProcessorCount + 2
        let blockers = LeakFreeBlockers(count: blockerCount)
        defer { blockers.join() }
        let scanners: [any SpaceScanner] = (0..<blockerCount).map { index in
            FixtureScanner(
                id: "blocked_\(index)",
                trustedContainerRoots: [
                    base.appendingPathComponent("blocked_\(index)"),
                ]
            ) {
                blockers.hold()
                return ScanOutcome(items: [], errors: [])
            }
        }
        let runtime = try makeRuntime(
            scanners,
            sessionBounds: ScanSessionBounds(
                eventDeadline: .milliseconds(200),
                producerWindDownGrace: .milliseconds(100)
            )
        )
        let viewModel = CacheoutViewModel(runtime: runtime)

        let started = Date()
        await viewModel.scan(trigger: .automatic)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, 0.9,
            "with all \(blockerCount) workers blocked the session must still "
                + "end on its 200 ms bound, not on the walk: \(elapsed) s"
        )
        XCTAssertFalse(viewModel.isAnyScanInProgress)
        // EVERY starved scanner is reported, not silently dropped.
        for index in 0..<blockerCount {
            let issue = try XCTUnwrap(
                viewModel.malformedIssuesByScannerID["blocked_\(index)"],
                "blocked_\(index) was cut off and must say so"
            )
            XCTAssertEqual(issue.kind, .scanDidNotFinish)
        }
    }

    /// AND PRODUCTION NEEDS NO TWELVE SCANNERS TO GET THERE — ONE IS ENOUGH.
    ///
    /// `CategoryScanner` runs `CacheScanner.scanAll`, which adds one child
    /// task per category — 23 in `CacheCategory.allCategories` — each running
    /// the SYNCHRONOUS `sizer.measure(…)`. A single internally parallel
    /// scanner therefore fills every cooperative worker in its band on every
    /// scan, so the starvation above is not an exotic composition: it is the
    /// shipped one the moment those measurements block (a hung mount, an
    /// unresponsive FUSE volume). This cell is that shape — ONE registered
    /// scanner, 23 thread-blocking children. Measured at 20.13 s under a
    /// 200 ms bound with the r12 producer.
    ///
    /// MUTATION: the same restoration as the cell above.
    @MainActor
    func testOneInternallyParallelScannerAloneCanStarveThePool() async throws {
        let childCount = 23  // CacheCategory.allCategories.count
        let blockers = LeakFreeBlockers(count: childCount)
        defer { blockers.join() }
        let runtime = try makeRuntime(
            [
                FixtureScanner(
                    id: "categories_like",
                    trustedContainerRoots: [
                        base.appendingPathComponent("categories_like"),
                    ]
                ) {
                    await withTaskGroup(of: Void.self) { group in
                        for _ in 0..<childCount {
                            group.addTask { blockers.hold() }
                        }
                        await group.waitForAll()
                    }
                    return ScanOutcome(items: [], errors: [])
                },
            ],
            sessionBounds: ScanSessionBounds(
                eventDeadline: .milliseconds(200),
                producerWindDownGrace: .milliseconds(100)
            )
        )
        let viewModel = CacheoutViewModel(runtime: runtime)

        let started = Date()
        await viewModel.scan(trigger: .automatic)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, 0.9,
            "one scanner with \(childCount) blocking children starves the "
                + "pool exactly as \(childCount) scanners would; the bound "
                + "must still fire: \(elapsed) s"
        )
        let issue = try XCTUnwrap(
            viewModel.malformedIssuesByScannerID["categories_like"]
        )
        XCTAssertEqual(issue.kind, .scanDidNotFinish)
    }

    /// THE DEADLINE MUST NOT DEPEND ON THE CALLER'S OWN PRIORITY BAND —
    /// the half of B that the band separation does NOT cover.
    ///
    /// The two cells above are satisfied by the producer moving to
    /// `.utility`: the consumer keeps a clear band, so a `Task.sleep`
    /// watchdog would find a worker there too and they would pass with the
    /// deadline still on the pool. This cell takes that worker away. The
    /// watchdog is created inside `scanValidatedSession`, which is called
    /// synchronously from the caller — so an r12 `Task { try await
    /// Task.sleep(…) }` watchdog inherits THE CALLER'S priority. Here the
    /// caller IS `.utility`, the same band its own blocking scanners
    /// saturate, so there is no free worker anywhere for a pool-borne
    /// deadline to run on. Real shape: the headless/CLI consumer, which is
    /// not on the MainActor and carries no priority guarantee.
    ///
    /// The assertion is NOT on when the scan returns — that consumer is
    /// starved by construction and cannot be prompt. It is on when the
    /// DEADLINE ITSELF ran, observed the one way a starved pool permits:
    /// the blocking scanners poll `Task.isCancelled` on the threads they
    /// already hold, needing no worker of their own, and record when the
    /// watchdog's `task.cancel()` reached them.
    ///
    /// MUTATION: restore the watchdog to `Task { try await Task.sleep(for:
    /// bounds.eventDeadline) }` and nothing cancels them; they run out their
    /// \(pollCapSeconds) s cap instead — red on the assertion rather than a
    /// hang, which is why the cap is there.
    @MainActor
    func testTheDeadlineDoesNotDependOnTheCallersOwnPriorityBand()
        async throws
    {
        let blockerCount = ProcessInfo.processInfo.activeProcessorCount + 2
        let observedCancellation = TimestampBox()
        let started = Date()
        let scanners: [any SpaceScanner] = (0..<blockerCount).map { index in
            FixtureScanner(
                id: "polling_\(index)",
                trustedContainerRoots: [
                    base.appendingPathComponent("polling_\(index)"),
                ]
            ) {
                // Holds its thread like a walk in a syscall, but wakes often
                // enough to notice cancellation WITHOUT needing a worker.
                let deadline = Date().addingTimeInterval(Self.pollCapSeconds)
                while !Task.isCancelled, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if Task.isCancelled {
                    observedCancellation.record(
                        Date().timeIntervalSince(started)
                    )
                }
                return ScanOutcome(items: [], errors: [])
            }
        }
        let runtime = try makeRuntime(
            scanners,
            sessionBounds: ScanSessionBounds(
                eventDeadline: .milliseconds(200),
                producerWindDownGrace: .milliseconds(100)
            )
        )

        // THE CALLER IS IN THE SCANNERS' OWN BAND. Detached so the band is
        // `.utility` rather than this cell's, and so the starvation below
        // cannot reach the MainActor the test itself runs on.
        let consumer = Task.detached(priority: .utility) {
            let session = runtime.scanValidatedSession(
                context: ScanContext(trigger: .automatic)
            )
            for await _ in session.events {}
            await session.untilProducerFinishes()
        }
        // Polled from the MainActor's own (clear) band, so this wait costs
        // the starved band nothing.
        let waitUntil = Date().addingTimeInterval(Self.pollCapSeconds + 2)
        while observedCancellation.value == nil, Date() < waitUntil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let elapsed = try XCTUnwrap(
            observedCancellation.value,
            "the watchdog must have cancelled the producer at all"
        )
        XCTAssertLessThan(
            elapsed, 0.9,
            "the 200 ms deadline must fire off the cooperative pool, not in "
                + "the caller's own saturated .utility band: \(elapsed) s"
        )
        _ = await consumer.value
    }

    /// AND THE WIND-DOWN GRACE IS THE SECOND TIMER, WITH THE SAME EXPOSURE.
    ///
    /// `untilProducerFinishes()` arms its own timer, and through r12 that was
    /// a `Task.detached` running `Task.sleep`. Detachment fixed the OTHER
    /// pool hazard — a plain `Task` inside an already-cancelled caller starts
    /// cancelled and the grace collapses to zero — but a detached sleep still
    /// resumes only on a cooperative worker, in the band an unspecified
    /// priority lands in. This cell saturates THAT band while the producer is
    /// wedged, so the gate can only be opened by a timer that needs no worker
    /// at all.
    ///
    /// The consumer stays on the MainActor's own clear band, so the ONLY
    /// starved participant is the grace timer itself.
    ///
    /// MUTATION: restore `let timer = Task.detached { try? await
    /// Task.sleep(for: windDownGrace); gate.open() }` and the scan returns
    /// when the saturated band frees instead of on the 100 ms grace.
    @MainActor
    func testTheWindDownGraceDoesNotDependOnTheCooperativePoolEither()
        async throws
    {
        // The band an unspecified-priority detached task lands in.
        let bandCount = ProcessInfo.processInfo.activeProcessorCount + 2
        let bandBlockers = LeakFreeBlockers(count: bandCount)
        defer { bandBlockers.join() }

        // A producer that CANNOT wind down inside the grace, so the gate is
        // opened by the timer rather than by the producer.
        let wedge = LeakFreeBlockers(count: 1)
        defer { wedge.join() }
        let runtime = try makeRuntime(
            [
                FixtureScanner(
                    id: "unwinding",
                    trustedContainerRoots: [
                        base.appendingPathComponent("unwinding"),
                    ]
                ) {
                    // SATURATION STARTS HERE, not before the scan: `scan`'s
                    // own preamble does `await Task.detached { DiskInfo
                    // .current() }.value`, which lands in this very band —
                    // saturating it up front would time that fetch instead of
                    // the grace, and did (1.83 s, all of it before the stream
                    // was even created).
                    for _ in 0..<bandCount {
                        Task.detached(priority: .medium) {
                            bandBlockers.hold()
                        }
                    }
                    wedge.hold()
                    return ScanOutcome(items: [], errors: [])
                },
            ],
            sessionBounds: ScanSessionBounds(
                eventDeadline: .milliseconds(200),
                producerWindDownGrace: .milliseconds(100)
            )
        )
        let viewModel = CacheoutViewModel(runtime: runtime)

        let started = Date()
        await viewModel.scan(trigger: .automatic)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, 0.9,
            "the 100 ms wind-down grace must not wait for a cooperative "
                + "worker in a saturated band: \(elapsed) s"
        )
        XCTAssertFalse(viewModel.isAnyScanInProgress)
    }

    /// EXACTLY ONE EVENT PER SCANNER, EVER — the watchdog's report and the
    /// real outcome must be exclusive in BOTH directions (PR #460 codex r13,
    /// C).
    ///
    /// r12 read `missing(from:)`, yielded, and called `finish()` with no
    /// atomicity against the producer's own yield loop. MEASURED with 12
    /// blocked scanners at a 200 ms bound: of 19 events, SEVEN scanners were
    /// reported as timed out AND published, `M:blocked_1:scan_did_not_finish`
    /// before `O:blocked_1`. That order is the harmful one — `reconcile`
    /// clears `malformedIssuesByScannerID[scannerID]`, so the timeout row the
    /// user was supposed to see disappears and the scanner is republished as
    /// healthy. The same run lost five completed scanners' outcomes when
    /// `finish()` beat their yield.
    ///
    /// THE RACE NEEDS NO STARVATION — only a scanner finishing inside the
    /// watchdog's window — so this cell aims scanners AT the window rather
    /// than blocking anything, and repeats: each trial has every scanner
    /// return at about the deadline, and the invariant is checked over the
    /// raw event stream, which is where "both" and "neither" are both
    /// visible.
    ///
    /// ## THE FIXTURE THIS SHIPPED WITH WAS A COIN FLIP, AND SAID IT WAS NOT
    /// ## (PR #460 codex r14, V2-2)
    ///
    /// Through r13 it ran 12 trials x 6 scanners at a 40 ms deadline, and its
    /// own doc asserted that "`.trials` is what makes it a gate rather than a
    /// coin flip". MEASURED against a faithful reconstruction of the r12 race
    /// (`ledger.record` + a bare `continuation.yield` in the producer, an
    /// unsynchronized `ledger.missing(from:)` in the watchdog): EIGHT
    /// consecutive runs of the old fixture gave exit 0,0,1,0,0,0,0,0 — **red 1
    /// of 8** here, and 0,0,1,0,1,0,0,0 — 2 of 8 — for the round-13 verifier
    /// who found it. Either way an edit reintroducing the race landed GREEN
    /// most of the time. r13's commit message also claimed it was "red on
    /// trial 0 ('racer_3 x2')"; at the shipped trial count that is not what it
    /// does. Both claims are retired here: a repeat count is evidence only
    /// when the RED RATE is measured, and this one's was not.
    ///
    /// The replacement is 40 trials x 8 scanners at a 30 ms deadline with the
    /// per-scanner return jittered across the window, which is enough of the
    /// race to be a gate. MEASURED, same mutant, eight consecutive runs:
    /// **red 8 of 8**, 6 to 30 of the 320 scanner-trials doubly reported per
    /// run, both harmful orders (`OT` and `TO`) seen in every run. Unmutated,
    /// eight consecutive runs: **green 8 of 8**, 1.28-1.30 s each — so the
    /// gate costs about 1.3 s and does not flake.
    ///
    /// MUTATION: replace the `ledger.publish(event, to: continuation)` call
    /// with `ledger.record(event.scannerID); continuation.yield(event)` and
    /// the watchdog's `conclude` with an unsynchronized `missing(from:)` read
    /// — duplicates appear and this cell is red.
    func testEveryScannerGetsExactlyOneEventEvenAtTheDeadline() async throws {
        let trials = 40
        let scannerCount = 8
        let deadlineMilliseconds = 30
        var sawBoth: [String] = []
        var sawNeither: [String] = []
        var doublyReported = 0
        var kindsSeen: Set<String> = []

        for trial in 0..<trials {
            let scanners: [any SpaceScanner] = (0..<scannerCount).map { index in
                let outcome = ScanOutcome(
                    items: [perItem(scanner: "racer_\(index)",
                                    id: "i\(index)", bytes: 100)],
                    errors: []
                )
                // JITTERED PER SCANNER PER TRIAL, not laid out in a fixed
                // fan: the window this races is scheduling, and a fixed
                // offset table samples one point of it 40 times over.
                let jitter = Int.random(in: -6...10)
                return FixtureScanner(
                    id: "racer_\(index)",
                    trustedContainerRoots: [
                        base.appendingPathComponent("racer_\(index)"),
                    ]
                ) {
                    try? await Task.sleep(
                        for: .milliseconds(
                            max(0, deadlineMilliseconds + jitter)
                        )
                    )
                    return outcome
                }
            }
            let runtime = try makeRuntime(
                scanners,
                sessionBounds: ScanSessionBounds(
                    eventDeadline: .milliseconds(deadlineMilliseconds),
                    producerWindDownGrace: .milliseconds(50)
                )
            )
            let session = runtime.scanValidatedSession(
                context: ScanContext(trigger: .automatic)
            )
            // THE RAW STREAM, not the view model's reduction of it: this is
            // the only place where "reported twice" and "reported never" are
            // both still visible.
            var seen: [String: [String]] = [:]
            for await event in session.events {
                switch event {
                case .outcome(let id, _):
                    seen[id, default: []].append("O")
                case .malformed(let id, let issue):
                    seen[id, default: []].append(
                        issue.kind == .scanDidNotFinish ? "T" : "M"
                    )
                }
            }
            await session.untilProducerFinishes()

            for index in 0..<scannerCount {
                let id = "racer_\(index)"
                let events = seen[id] ?? []
                switch events.count {
                case 1: continue
                case 0: sawNeither.append("trial \(trial): \(id)")
                default:
                    doublyReported += 1
                    kindsSeen.insert(events.joined())
                    sawBoth.append(
                        "trial \(trial): \(id) \(events.joined(separator: ","))"
                    )
                }
            }
        }

        XCTAssertEqual(
            sawBoth, [],
            "a scanner reported as timed out must not ALSO publish an "
                + "outcome — `reconcile` would clear the timeout row and "
                + "republish it as healthy. \(doublyReported) of "
                + "\(trials * scannerCount) doubly reported, orders "
                + "\(kindsSeen.sorted())"
        )
        XCTAssertEqual(
            sawNeither, [],
            "and a scanner that finished must not lose its outcome to "
                + "`finish()`: a partial scan is reported as partial"
        )
    }

    /// A SESSION CUT OFF BY ITS BOUND VOUCHES FOR NOTHING — the mitigation
    /// r12 wrote down and did not implement (PR #460 codex r13, D).
    ///
    /// `untilProducerFinishes()` discloses a real residual: when the grace
    /// expires the caller releases its "scan in progress" guard while an
    /// orphaned walk may still be reading the same trees. What made that
    /// acceptable was the next sentence — "a session whose bound fired adopts
    /// nothing, so `adoptedGeneration` never advances and every DESTRUCTIVE
    /// path stays closed on that session's items". It was false. The watchdog
    /// cancels the PRODUCER, never the consumer, so `let completed =
    /// !Task.isCancelled` was TRUE and the adoption block ran: MEASURED on a
    /// first-ever scan with one healthy and one wedged scanner at a 200 ms
    /// bound, `hasScanned == true` and the healthy scanner's item selected
    /// and CLEANABLE.
    ///
    /// This is a FIRST-EVER scan on purpose: it is the case with no earlier
    /// adopted generation to fall back on, so nothing but this gate stands
    /// between a cut-off session and a delete.
    ///
    /// MUTATION: restore `let completed = !Task.isCancelled` in
    /// `CacheoutViewModel.scan` and every assertion below flips.
    @MainActor
    func testABoundedSessionAdoptsNothingAndCleansNothing() async throws {
        let gate = StallGate()
        let healthy = ScanOutcome(
            items: [perItem(scanner: "ok", id: "o1", bytes: 5000,
                            risk: .safe, defaultSelected: true,
                            automaticCleanEligible: true)],
            errors: []
        )
        let runtime = try makeRuntime(
            [
                fixtureScanner("ok") { healthy },
                FixtureScanner(
                    id: "wedged",
                    trustedContainerRoots: [
                        base.appendingPathComponent("wedged"),
                    ]
                ) {
                    await gate.hold()
                    return ScanOutcome(items: [], errors: [])
                },
            ],
            sessionBounds: ScanSessionBounds(
                eventDeadline: .milliseconds(200),
                producerWindDownGrace: .milliseconds(100)
            )
        )
        let viewModel = CacheoutViewModel(runtime: runtime)

        // `hold()` does not return until the test releases it, so the only
        // thing that can end this scan is the bound.
        await gate.wedge()
        await viewModel.scan(trigger: .automatic)

        // The bound fired and said so.
        XCTAssertEqual(
            viewModel.malformedIssuesByScannerID["wedged"]?.kind,
            .scanDidNotFinish
        )
        // The healthy scanner's row is still VISIBLE — a partial scan is
        // reported as partial, which is the other half of the contract.
        XCTAssertEqual(viewModel.items(forScanner: "ok").map(\.id), ["o1"])

        // AND NOTHING IS VOUCHED FOR. This is the sentence made true. The
        // item IS ticked — `defaultSelected` selected it on its first
        // emission, exactly as the measurement found — so this is the gate
        // refusing a live selection, not an empty one trivially passing.
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("ok", "o1")))
        XCTAssertEqual(
            viewModel.selectedItems.map(\.id), [],
            "the measurement found `selectedItems == [\"o1\"]` here: items "
                + "from a cut-off session must not reach a destructive path"
        )
        XCTAssertFalse(
            viewModel.hasCleanableSelection,
            "a session cut off by its bound must not leave its items "
                + "cleanable — an orphaned read-only walk may still be in "
                + "the same trees"
        )
        XCTAssertEqual(viewModel.totalCleanableSelectedSize, 0)
        XCTAssertEqual(viewModel.automaticCleanableSize, 0)
        XCTAssertFalse(
            viewModel.hasScanned,
            "…and the session must not present itself as a completed scan"
        )

        // Bulk selection cannot re-open the door either.
        viewModel.selectAllSafe()
        XCTAssertFalse(viewModel.hasCleanableSelection,
                       "Quick Clean must not stage an unadopted session")

        // AND A RETRY CAN DIFFER: releasing the wedge and re-scanning adopts
        // normally, so the fail-closed state is a state and not a trap.
        await gate.release()
        await viewModel.scan(trigger: .automatic)
        XCTAssertNil(viewModel.malformedIssuesByScannerID["wedged"])
        XCTAssertTrue(viewModel.hasScanned)
        viewModel.selectAllSafe()
        XCTAssertTrue(viewModel.hasCleanableSelection)
        XCTAssertEqual(viewModel.totalCleanableSelectedSize, 5000)
    }

    /// How long this file's polling blockers hold a thread when nothing ever
    /// cancels them — the cap that turns a regression into a RED cell
    /// instead of a hung run.
    private static let pollCapSeconds: TimeInterval = 2.0

    /// THE HEALTHY PATH PAYS NOTHING, asserted rather than assumed: a
    /// session whose scanners all report ends on the producer's own
    /// terminator, immediately, and NO `scan_did_not_finish` row appears —
    /// even with the bound set to a few milliseconds, which every other cell
    /// in this file exercises at the 30 s default.
    ///
    /// Without this, the two cells above would pass against a session that
    /// reported every scanner as timed out.
    @MainActor
    func testAHealthySessionEndsOnItsOwnTerminatorAndReportsNoBound()
        async throws
    {
        let outcome = ScanOutcome(
            items: [perItem(scanner: "ok", id: "o1", bytes: 5000)], errors: []
        )
        let runtime = try makeRuntime(
            [fixtureScanner("ok") { outcome }],
            sessionBounds: ScanSessionBounds(
                eventDeadline: .milliseconds(250),
                producerWindDownGrace: .milliseconds(50)
            )
        )
        let viewModel = CacheoutViewModel(runtime: runtime)

        let started = Date()
        await viewModel.scan(trigger: .automatic)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.25,
                          "a healthy session must not wait out the deadline: "
                              + "\(elapsed) s")
        XCTAssertNil(viewModel.malformedIssuesByScannerID["ok"])
        XCTAssertEqual(viewModel.items(forScanner: "ok").map(\.id), ["o1"])
        XCTAssertTrue(viewModel.hasScanned)
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

    // MARK: - Never inspected vs inspected-and-empty (PR #459 codex r11)

    /// CLAUSE ONE of `isAwaitingFirstScan`, both ways: `!hasPublishedOutcome`.
    ///
    /// Two scanners with identical (empty) outputs; a SUBSET session runs
    /// only one. Their `items`/`issues` are then byte-identical — both `[]`
    /// — so nothing on the section itself distinguishes them except whether
    /// `reconcile` ever ran. Deleting the clause collapses the two, and the
    /// two `isAwaitingFirstScan` assertions below disagree about which way.
    @MainActor
    func testANeverInspectedSectionIsDistinguishableFromOneThatFoundNothing() async throws {
        let runtime = try makeRuntime([
            fixtureScanner("looked") { ScanOutcome(items: [], errors: []) },
            fixtureScanner("never_looked") { ScanOutcome(items: [], errors: []) },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)
        func section(_ id: String) throws -> ScannerSectionModel {
            try XCTUnwrap(viewModel.perItemSections.first { $0.scannerID == id })
        }

        // Before any scan BOTH are awaiting — the state is about the scan,
        // not about the scanner.
        XCTAssertEqual(
            viewModel.perItemSections.map(\.isAwaitingFirstScan), [true, true]
        )

        await viewModel.scan(trigger: .userInitiated, scannerIDs: ["looked"])

        let looked = try section("looked")
        let never = try section("never_looked")
        XCTAssertEqual(looked.items.count, 0)
        XCTAssertEqual(never.items.count, 0)
        XCTAssertEqual(looked.issues.count, 0)
        XCTAssertEqual(never.issues.count, 0)
        XCTAssertEqual(looked.isScanning, never.isScanning,
                       "items, issues and pending state are all identical — "
                        + "`hasPublishedOutcome` is the ONLY thing that "
                        + "separates the two cases")

        XCTAssertFalse(looked.isAwaitingFirstScan,
                       "an empty outcome WAS published — 'nothing' is an answer")
        XCTAssertTrue(never.isAwaitingFirstScan,
                      "this scanner was never in a session; nothing was looked at")

        // …and the two derivations the view reads follow from it.
        XCTAssertEqual(looked.headerCountLabel, "0 found")
        XCTAssertEqual(never.headerCountLabel, "not scanned yet")
        XCTAssertFalse(looked.isDisplayed,
                       "inspected-and-empty stays hidden (unchanged)")
        XCTAssertTrue(never.isDisplayed,
                      "never-inspected must reach the user")
    }

    /// CLAUSE TWO: `!isScanning`. A FIRST scan in flight has published no
    /// outcome yet, but it is not the never-inspected state — the section's
    /// own spinner owns that window. Dropping the clause would make a
    /// running scan claim it never happened.
    @MainActor
    func testAFirstScanInFlightIsNotTheNeverInspectedState() async throws {
        let runtime = try makeRuntime([
            fixtureScanner("busy") { ScanOutcome(items: [], errors: []) },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)
        // The documented seam for pinning a mid-scan window.
        viewModel.scanningScannerIDs = ["busy"]

        let section = try XCTUnwrap(viewModel.perItemSections.first)
        XCTAssertTrue(section.isScanning)
        XCTAssertFalse(section.hasPublishedOutcome,
                       "the fixture is mid-FIRST-scan: nothing published yet")
        XCTAssertFalse(section.isAwaitingFirstScan,
                       "a scan IS happening — the spinner is the disclosure")
        XCTAssertEqual(section.headerCountLabel, "0 found",
                       "the header keeps its ordinary running count — the "
                        + "withheld form belongs to the never-inspected case")
        XCTAssertTrue(section.isDisplayed, "the spinner still renders")
    }

    /// CLAUSE THREE: `issues.isEmpty`. A scanner whose ONLY event was
    /// `malformedOutcome` has no outcome either — but it is not silent, and
    /// mislabelling its visible failure as "not scanned yet" would replace a
    /// disclosed fault with a benign-looking one. Dropping the clause makes
    /// this section claim both at once.
    @MainActor
    func testAMalformedFirstEventIsAVisibleFaultNotANeverInspectedSection() async throws {
        let runtime = try makeRuntime([
            fixtureScanner("mal") { ScanOutcome(items: [], errors: []) },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)
        let issue = ScanIssue(
            url: nil, kind: .malformedOutcome,
            detail: "rejected — malformed scanner output"
        )
        viewModel.handle(.malformed(scannerID: "mal", issue))

        let section = try XCTUnwrap(viewModel.perItemSections.first)
        XCTAssertFalse(section.hasPublishedOutcome,
                       "a malformed event publishes NOTHING (fail-closed)")
        XCTAssertEqual(section.issues, [issue],
                       "…but the fault is surfaced on the section")
        XCTAssertFalse(section.isAwaitingFirstScan,
                       "a disclosed fault must not be re-labelled 'not "
                        + "scanned yet' — the scan ran and failed")
        XCTAssertTrue(section.isDisplayed,
                      "the issue block renders (unchanged behavior)")
    }

    /// THE OUTER GATE, on the machine the disclosure exists for (PR #459
    /// codex r14). r11 gave a never-inspected section `isDisplayed` and a
    /// "not scanned yet" label, then disclosed — and left open — that
    /// `hasDisplayableScanOutput` could not see it. This is the state that
    /// gap is total in: a CLEAN machine, where the participating scanner
    /// publishes an EMPTY outcome and the deferred one publishes nothing.
    /// All three original clauses read false, `cachesTab` takes its
    /// `emptyState` branch, and the results list that would have built the
    /// section — and evaluated `isDisplayed` at all — is never built.
    ///
    /// Both halves are asserted: the section still says it wants to be
    /// shown, AND the gate above it now agrees.
    @MainActor
    func testACleanScanStillDisplaysASectionThatWasNeverInspected() async throws {
        let runtime = try makeRuntime([
            fixtureScanner("looked") { ScanOutcome(items: [], errors: []) },
            fixtureScanner("deferred") { ScanOutcome(items: [], errors: []) },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .userInitiated, scannerIDs: ["looked"])

        // The three original clauses, each false — nothing was found and
        // nothing went wrong.
        XCTAssertFalse(viewModel.hasResults, "no items anywhere")
        XCTAssertTrue(
            viewModel.outcomesByScannerID.values.allSatisfy { $0.errors.isEmpty },
            "no classified issues anywhere"
        )
        XCTAssertTrue(viewModel.malformedIssuesByScannerID.isEmpty,
                      "nothing malformed")

        let deferredSection = try XCTUnwrap(
            viewModel.perItemSections.first { $0.scannerID == "deferred" }
        )
        XCTAssertTrue(deferredSection.isDisplayed,
                      "r11's half: the section asks to be rendered")
        XCTAssertTrue(
            viewModel.hasAwaitingFirstScanSection,
            "…and the fourth clause sees it"
        )
        XCTAssertTrue(
            viewModel.hasDisplayableScanOutput,
            "a never-inspected scanner is displayable output — otherwise the "
                + "results list is never built and the 'not yet scanned' row "
                + "is unreachable on exactly the machines it exists for"
        )
    }

    /// The other direction, so the fourth clause is a GATE and not a
    /// constant: once every per-item scanner has published, a clean machine
    /// is displayable-empty again and the window-level empty state is what
    /// renders.
    @MainActor
    func testAFullyInspectedCleanMachineIsNotDisplayable() async throws {
        let runtime = try makeRuntime([
            fixtureScanner("a") { ScanOutcome(items: [], errors: []) },
            fixtureScanner("b") { ScanOutcome(items: [], errors: []) },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .userInitiated)

        XCTAssertFalse(viewModel.hasAwaitingFirstScanSection,
                       "every scanner published")
        XCTAssertFalse(
            viewModel.hasDisplayableScanOutput,
            "nothing found, nothing deferred, nothing wrong — the empty "
                + "state is the correct surface here"
        )
    }

    // MARK: - Runtime reconstruction (fn-4.10, R8)

    /// The seam is OPT-IN: a view model handed a finished runtime and no
    /// reconstruction seam never rebuilds — and, crucially, never falls back
    /// to production defaults — so a dev-roots change cannot perturb it or
    /// gate its destructive paths. This is the state every pre-fn-4.5 call
    /// site is in.
    @MainActor
    func testDevRootsChangeIsANoOpWithoutTheReconstructionSeam() async throws {
        let outcome = ScanOutcome(
            items: [perItem(scanner: "old_alpha", id: "a1")], errors: []
        )
        let runtime = try makeRuntime([
            fixtureScanner("old_alpha") { outcome },
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .userInitiated)
        viewModel.toggleSelection(for: key("old_alpha", "a1"))
        XCTAssertTrue(viewModel.hasCleanableSelection)

        viewModel.devRootsDidChange()

        XCTAssertEqual(viewModel.perItemSections.map(\.scannerID),
                       ["old_alpha"],
                       "an unwired seam must never rebuild the composition")
        XCTAssertTrue(viewModel.hasCleanableSelection,
                      "no rebuild happened — destructive freshness is untouched")
    }

    /// INJECTED-COMPOSITION PRESERVATION (the reason the factory exists): a
    /// Settings-triggered rebuild goes through the injected factory, so a
    /// fixture-composed runtime is rebuilt as a FIXTURE-composed runtime.
    /// Rebuilding by re-deriving `production(...)` — the only alternative,
    /// since the view model holds a finished runtime it cannot decompose —
    /// would silently swap the hermetic composition for the production
    /// registry here.
    @MainActor
    func testSettingsRebuildPreservesInjectedFixtureComposition() async throws {
        let outcome = ScanOutcome(
            items: [perItem(scanner: "old_alpha", id: "a1")], errors: []
        )
        let runtime = try makeRuntime([
            fixtureScanner("old_alpha") { outcome },
        ])
        let (seam, log) = try makeReconstruction()
        let viewModel = CacheoutViewModel(
            runtime: runtime, reconstruction: seam
        )

        await viewModel.scan(trigger: .userInitiated)
        XCTAssertEqual(viewModel.perItemSections.map(\.scannerID),
                       ["old_alpha"])

        persistDevRoots(["beta"])
        viewModel.devRootsDidChange()

        // ONE factory call, with what the STORE resolved (not what the
        // caller guessed) — and the composition in force is its answer.
        XCTAssertEqual(log.recorded.count, 1)
        XCTAssertEqual(log.recorded.last?.keptRoots.map(\.lastPathComponent),
                       ["beta"])
        XCTAssertEqual(viewModel.perItemSections.map(\.scannerID),
                       ["root_beta"],
                       "the rebuilt composition is the INJECTED factory's")

        await viewModel.scan(trigger: .userInitiated)
        XCTAssertEqual(viewModel.items(forScanner: "root_beta").map(\.id),
                       ["beta_item"],
                       "the new composition's scanners are what ran")
        for productionID in Self.productionScannerIDs {
            XCTAssertNil(
                viewModel.outcomesByScannerID[productionID],
                "a rebuild must never swap an injected composition for the "
                    + "production registry (\(productionID) ran)"
            )
        }
    }

    /// MATRIX (a) — replacement requested during the INITIAL DiskInfo await,
    /// before the session captured its container snapshot (the spy provider
    /// proves the window). The as-built `scan()` read `runtime` again AFTER
    /// that await; the session capture closes it, so the request is deferred
    /// and the session runs, completes and adopts on the runtime it started
    /// with.
    @MainActor
    func testReplacementDuringInitialDiskInfoAwaitDefersToSessionEnd() async throws {
        let spy = SnapshotCaptureSpy()
        let outcome = ScanOutcome(
            items: [perItem(scanner: "old_alpha", id: "a1")], errors: []
        )
        let runtime = try makeRuntime(
            [fixtureScanner("old_alpha") { outcome }], provider: spy
        )
        let (seam, log) = try makeReconstruction()
        let viewModel = CacheoutViewModel(
            runtime: runtime, reconstruction: seam
        )
        persistDevRoots(["beta"])

        let scanTask = Task { await viewModel.scan(trigger: .automatic) }
        // The scan task's synchronous prologue runs before this
        // continuation (MainActor FIFO), and the ONLY suspension it can
        // have reached is the initial DiskInfo await — nothing else
        // suspends before `scanValidatedSession`, whose FIRST act is the
        // snapshot capture the spy counts. No sleeps: the loop yields.
        var yields = 0
        while !viewModel.isAnyScanInProgress && yields < 100 {
            await Task.yield()
            yields += 1
        }
        XCTAssertTrue(viewModel.isAnyScanInProgress,
                      "the scan session never raised its guard")
        XCTAssertEqual(spy.captures, 0,
                       "the request must land in the INITIAL DiskInfo await "
                           + "— before this session captured its snapshot")

        viewModel.devRootsDidChange()

        XCTAssertTrue(log.recorded.isEmpty,
                      "a replacement during an active session is DEFERRED — "
                          + "no composition is built mid-session")
        XCTAssertEqual(viewModel.perItemSections.map(\.scannerID),
                       ["old_alpha"],
                       "the in-flight session keeps its captured composition")

        await scanTask.value

        XCTAssertGreaterThan(spy.captures, 0,
                             "the session captured a snapshot from its OWN runtime")
        XCTAssertEqual(viewModel.items(forScanner: "old_alpha").map(\.id),
                       ["a1"],
                       "the session ran the scanners it captured, start to end")
        XCTAssertEqual(log.recorded.count, 1,
                       "the deferred replacement applies ONCE, at session end")
        XCTAssertEqual(viewModel.perItemSections.map(\.scannerID),
                       ["root_beta"])

        // Destructive freshness is INVALIDATED: the session that just
        // adopted belongs to the previous composition.
        viewModel.toggleSelection(for: key("old_alpha", "a1"))
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key("old_alpha", "a1")),
                      "display state is never lost — only destructive paths gate")
        XCTAssertTrue(viewModel.selectedItems.isEmpty)
        XCTAssertFalse(viewModel.hasCleanableSelection)

        // ...and returns only when a scan from the NEW runtime adopts.
        await viewModel.scan(trigger: .userInitiated)
        viewModel.toggleSelection(for: key("root_beta", "beta_item"))
        XCTAssertEqual(viewModel.selectedItems.map(\.key),
                       [key("root_beta", "beta_item")],
                       "the new composition's own session lifts the gate")
        XCTAssertTrue(viewModel.hasCleanableSelection)
    }

    /// MATRIX (b) — replacement requested while a scanner is EXECUTING (the
    /// gate proves the window): deferred, the session finishes on its
    /// captured runtime, the rebuild lands at session end, and destructive
    /// paths stay gated until a new-runtime scan adopts.
    @MainActor
    func testReplacementDuringScannerExecutionDefersToSessionEnd() async throws {
        let entered = ScanGate()
        let release = ScanGate()
        let outcome = ScanOutcome(
            items: [perItem(scanner: "old_alpha", id: "a1")], errors: []
        )
        let runtime = try makeRuntime([
            fixtureScanner("old_alpha") {
                await entered.open()
                await release.wait()
                return outcome
            },
        ])
        let (seam, log) = try makeReconstruction()
        let viewModel = CacheoutViewModel(
            runtime: runtime, reconstruction: seam
        )
        persistDevRoots(["gamma"])

        let scanTask = Task { await viewModel.scan(trigger: .automatic) }
        await entered.wait()  // provably INSIDE scanner execution

        viewModel.devRootsDidChange()
        XCTAssertTrue(log.recorded.isEmpty,
                      "no composition is built while a scanner is running")
        XCTAssertEqual(viewModel.perItemSections.map(\.scannerID),
                       ["old_alpha"])

        await release.open()
        await scanTask.value

        XCTAssertEqual(viewModel.items(forScanner: "old_alpha").map(\.id),
                       ["a1"],
                       "the in-flight session completed on its captured runtime")
        XCTAssertEqual(log.recorded.count, 1)
        XCTAssertEqual(log.recorded.last?.keptRoots.map(\.lastPathComponent),
                       ["gamma"])
        XCTAssertEqual(viewModel.perItemSections.map(\.scannerID),
                       ["root_gamma"])

        viewModel.toggleSelection(for: key("old_alpha", "a1"))
        XCTAssertTrue(viewModel.selectedItems.isEmpty,
                      "the adopted session's items belong to the OLD runtime")
        XCTAssertFalse(viewModel.hasCleanableSelection)

        await viewModel.scan(trigger: .userInitiated)
        XCTAssertEqual(viewModel.items(forScanner: "root_gamma").map(\.id),
                       ["gamma_item"])
        viewModel.toggleSelection(for: key("root_gamma", "gamma_item"))
        XCTAssertEqual(viewModel.selectedItems.map(\.key),
                       [key("root_gamma", "gamma_item")])
    }

    /// MATRIX (c) — replacement requested AFTER a completed scan and before
    /// the next: nothing is in flight, so it applies immediately, and the
    /// destructive proof is on-disk. `clean()` builds its cleaner from the
    /// CURRENT runtime and the PREVIOUSLY adopted snapshot; the runtime
    /// generation gate empties the selection wholesale, so a real file
    /// selected under the old composition survives a confirmed clean.
    @MainActor
    func testReplacementAfterCompletedScanGatesCleanUntilNewRuntimeAdopts() async throws {
        let container = base.appendingPathComponent("projects")
        let junkA = container.appendingPathComponent("junk_a")
        try fm.createDirectory(at: junkA, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4096)
            .write(to: junkA.appendingPathComponent("payload.bin"))

        let runtime = try makeRuntime([
            DirectoryFixtureScanner(id: "fixture_items", container: container),
        ])
        let (seam, log) = try makeReconstruction()
        let viewModel = CacheoutViewModel(
            runtime: runtime, reconstruction: seam
        )
        viewModel.moveToTrash = false  // permanent delete, fixture-contained

        await viewModel.scan(trigger: .userInitiated)
        viewModel.toggleSelection(for: key("fixture_items", "junk_a"))
        XCTAssertTrue(viewModel.hasCleanableSelection,
                      "the adopted session's items start cleanable")

        persistDevRoots(["delta"])
        viewModel.devRootsDidChange()
        XCTAssertEqual(log.recorded.count, 1,
                       "no session in flight — the rebuild is immediate")
        XCTAssertFalse(viewModel.hasCleanableSelection,
                       "a runtime change invalidates destructive freshness")

        await viewModel.clean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertTrue(report.entries.isEmpty,
                      "a new runtime's cleaner must never act on the old "
                          + "runtime's adopted snapshot: \(report.entries)")
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertTrue(fm.fileExists(atPath: junkA.path),
                      "nothing may be deleted while the model is gated")

        // clean()'s trailing rescan runs on the NEW runtime and adopts,
        // lifting the gate for ITS items only.
        XCTAssertEqual(viewModel.items(forScanner: "root_delta").map(\.id),
                       ["delta_item"])
        viewModel.toggleSelection(for: key("root_delta", "delta_item"))
        XCTAssertEqual(viewModel.selectedItems.map(\.key),
                       [key("root_delta", "delta_item")])
        XCTAssertFalse(viewModel.selectedItems.contains {
            $0.scannerID == "fixture_items"
        }, "the old composition's retained rows never return to a "
            + "destructive path")
    }

    /// A rebuild changes PRIVATE state that published derivations read
    /// (`perItemSections`, `hasCleanableSelection`, the clean totals), so it
    /// must co-publish — otherwise SwiftUI keeps rendering the old
    /// composition's sections and a live Clean control until some unrelated
    /// `@Published` write happens to fire. `installRuntime` is the ONE
    /// replacement site, so this covers the deferred path too.
    @MainActor
    func testRuntimeRebuildPublishesAnObservableChange() async throws {
        let outcome = ScanOutcome(
            items: [perItem(scanner: "old_alpha", id: "a1")], errors: []
        )
        let runtime = try makeRuntime([
            fixtureScanner("old_alpha") { outcome },
        ])
        let (seam, _) = try makeReconstruction()
        let viewModel = CacheoutViewModel(
            runtime: runtime, reconstruction: seam
        )
        await viewModel.scan(trigger: .userInitiated)

        let recorder = ChangeRecorder()
        let subscription = viewModel.objectWillChange.sink { _ in
            recorder.record()
        }
        defer { subscription.cancel() }
        XCTAssertEqual(recorder.count, 0)

        persistDevRoots(["beta"])
        viewModel.devRootsDidChange()

        XCTAssertGreaterThan(recorder.count, 0,
                             "a runtime rebuild must notify observers — its "
                                 + "derived state is published, its storage "
                                 + "is not")
        XCTAssertEqual(viewModel.perItemSections.map(\.scannerID),
                       ["root_beta"])
    }

    /// LATEST-VALUE-WINS: three Settings edits during one session collapse
    /// to exactly ONE rebuild, from the NEWEST resolution — no intermediate
    /// composition is ever built, and the session is never disturbed.
    @MainActor
    func testReplacementsDuringOneSessionCollapseToTheNewestResolution() async throws {
        let entered = ScanGate()
        let release = ScanGate()
        let outcome = ScanOutcome(
            items: [perItem(scanner: "old_alpha", id: "a1")], errors: []
        )
        let runtime = try makeRuntime([
            fixtureScanner("old_alpha") {
                await entered.open()
                await release.wait()
                return outcome
            },
        ])
        let (seam, log) = try makeReconstruction()
        let viewModel = CacheoutViewModel(
            runtime: runtime, reconstruction: seam
        )

        let scanTask = Task { await viewModel.scan(trigger: .automatic) }
        await entered.wait()

        persistDevRoots(["beta"])
        viewModel.devRootsDidChange()
        persistDevRoots(["gamma"])
        viewModel.devRootsDidChange()
        persistDevRoots(["delta"])
        viewModel.devRootsDidChange()
        XCTAssertTrue(log.recorded.isEmpty)

        await release.open()
        await scanTask.value

        XCTAssertEqual(log.recorded.count, 1,
                       "three requests collapse to ONE rebuild")
        XCTAssertEqual(log.recorded.last?.keptRoots.map(\.lastPathComponent),
                       ["delta"], "the NEWEST resolution wins")
        XCTAssertEqual(viewModel.perItemSections.map(\.scannerID),
                       ["root_delta"])
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
///
/// BOUNDED (PR #460 codex r11, D2). Both directions of this gate can be
/// decided by production: a fixture scanner parks on it waiting for the CELL,
/// and the cell parks on `entered` waiting for the SESSION to invoke that
/// scanner. An unbounded park in the second direction turns a production
/// regression into a runner that never finishes and never says why — measured
/// on the twin in `EphemeralTempRegistrationTests`. See `BoundedRendezvous`.
/// A gate a fixture scanner passes through instantly until the test WEDGES
/// it, after which `hold()` does not return until `release()`.
///
/// Built on `BoundedRendezvous` — the r11 primitive — so a wedge the test
/// forgets to release fails the cell after the rendezvous' own bound instead
/// of parking the run. The session's wall-clock bound is what these cells
/// are measuring; the rendezvous' is the backstop under it.
private actor StallGate {
    private let gate = BoundedRendezvous()
    private var wedged = false

    init() { gate.open() }

    func wedge() {
        wedged = true
        gate.close()
    }

    func release() {
        wedged = false
        gate.open()
    }

    func hold(
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        guard wedged else { return }
        await gate.park("a wedged fixture scanner", file: file, line: line)
    }
}

private actor ScanGate {
    private let gate = BoundedRendezvous()

    func open() { gate.open() }

    func close() { gate.close() }

    @discardableResult
    func wait(
        _ what: String = "a staggered scan gate",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        await gate.park(what, file: file, line: line)
    }
}

/// What the INJECTED runtime factory was handed, and how often (fn-4.10) —
/// the deferral and latest-value-wins proofs read this. Lock-guarded because
/// the factory type is `@Sendable`; every call in these tests is in fact on
/// the MainActor.
private final class ResolutionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DevRootsResolution] = []

    func record(_ resolution: DevRootsResolution) {
        lock.lock()
        defer { lock.unlock() }
        values.append(resolution)
    }

    var recorded: [DevRootsResolution] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Counts `objectWillChange` emissions — SwiftUI's ONLY signal that a
/// published derivation may have changed.
private final class ChangeRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

/// Counts `identity(of:)` calls — the SYNCHRONOUS signal that a session
/// reached `scanValidatedSession`, whose first act is the `ContainerSnapshot`
/// capture over the registered roots. Zero captures while a scan is in
/// progress therefore proves the session is still at its FIRST suspension:
/// the initial DiskInfo await (fn-4.10 matrix case (a)). Subclassing is the
/// sanctioned test seam on this type.
private final class SnapshotCaptureSpy: FileSystemIdentityProvider,
                                        @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    override func identity(of url: URL) -> Identity? {
        lock.lock()
        calls += 1
        lock.unlock()
        return super.identity(of: url)
    }

    var captures: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
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
        // FIXTURE-CONTROLLED — `outcomes` is the literal list this test
        // handed the box and no production code can shorten it — but the
        // subscript is gone anyway (PR #460 codex r6, D4): the statement-
        // position fence forbids the SHAPE, because "provably non-empty" is
        // exactly what every stranding subscript in this suite's history also
        // claimed. The `??` arm is unreachable; it is not a guard.
        outcomes.count > 1
            ? outcomes.removeFirst()
            : (outcomes.first ?? ScanOutcome(items: [], errors: []))
    }
}

/// N COOPERATIVE WORKERS HELD, AND THEN JOINED (PR #460 codex r13, B).
///
/// The starvation cells need threads blocked the way a walk inside a syscall
/// blocks one: `Thread.sleep`, ignoring cancellation. A bare sleep does that
/// but LEAKS — the blocked threads outlive the cell that made them and starve
/// the NEXT one, which is not hypothetical: a four-cell run of these very
/// cells failed a mutation check for that reason and passed when run alone.
///
/// So each blocker signals on its way out and the cell JOINS all of them
/// before returning. The hold is uncancellable on purpose — a blocker that
/// exited on cancellation would let a regressed build pass, because the
/// watchdog cancels the producer whether or not the consumer can see it.
private final class LeakFreeBlockers: @unchecked Sendable {
    private let exited = DispatchSemaphore(value: 0)
    private let count: Int
    private let seconds: TimeInterval

    init(count: Int, seconds: TimeInterval = 1.5) {
        self.count = count
        self.seconds = seconds
    }

    /// One blocker's body: holds its thread, cancellation or not.
    func hold() {
        Thread.sleep(forTimeInterval: seconds)
        exited.signal()
    }

    /// Does not return until all `count` blockers have left `hold()`. Safe to
    /// call from the MainActor because every caller puts its blockers BELOW
    /// the MainActor's own band — `.utility` when they are session scanners,
    /// `.medium` when they are detached — so none of them can be scheduled
    /// onto the main thread and wait on the very actor that is joining them.
    /// That is not hypothetical: an earlier draft used
    /// `Task.detached(priority: .high)` and a blocker landed on the main
    /// thread, deadlocking the cell (`sample` showed the main thread inside
    /// `hold()`).
    func join() {
        for _ in 0..<count { exited.wait() }
    }
}

/// A single elapsed-time reading, written from a blocked scanner thread and
/// read from the test — lock-guarded because those are different threads and
/// the writer must not suspend (PR #460 codex r13, B).
private final class TimestampBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval?

    var value: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func record(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if stored == nil { stored = seconds }
    }
}
