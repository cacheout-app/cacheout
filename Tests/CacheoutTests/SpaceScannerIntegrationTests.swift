import XCTest
@testable import Cacheout

/// fn-2.7 — the epic's two headline proofs, end-to-end (R3/R4) plus the
/// final build/test gate (R6).
///
/// **R3 — fixture-scanner end-to-end**: a test-local `SpaceScanner`
/// conformer over a UUID-derived temp tree drives the WHOLE production
/// pipeline with no GUI code: `SpaceScannerRuntime` (validated event
/// stream) → `CacheoutViewModel` (selection over `ItemKey`) →
/// `CacheCleaner.clean(items:)` (fn-2.3's unified entry on the
/// runtime-constructed cleaner) → `CleanupReport` (per-item entries,
/// per-scanner rollups). Both admission modes run: a real
/// `CategoryScanner` over an `.absolutePath` fixture category exercises
/// category-policy admission (`admitDeletionRoot` + per-child
/// `validateContainedChild`), and the fixture per-item scanner exercises
/// container admission (`admitContainer` + `validateRemovableItem`).
/// Freed bytes are checked against INDEPENDENT fixture math (a sizer the
/// cleaner does not own), selection survival across rescans is proven on
/// the same tree, and a PathGuard refusal surfaces as a per-item report
/// error with nothing deleted.
///
/// **R4 — zero-edit extensibility**: adding a scanner is "implement the
/// protocol + register with the runtime" and NOTHING else. The proof is
/// structural, two ways: (1) every fixture scanner here registers through
/// the PUBLIC `SpaceScannerRuntime` initializer — the same seam
/// `CacheoutViewModel.init(runtime:)` consumes — and its declared
/// `trustedContainerRoots` reach delete-time admission with zero
/// ViewModel/Cleaner/Views edits (a `.removeItem` inside the declared
/// container cleans SUCCESSFULLY; an item claiming an UNDECLARED
/// container is refused); (2) a grep gate walks `Sources/Cacheout/` and
/// asserts NO production source references any fixture-scanner slug.
///
/// Hermetic discipline (CacheCleanerTests style): every path lives under
/// one UUID-derived fixture root; the home is an injected fixture home —
/// zero real-`$HOME` reads; deletions are permanent-mode only, so
/// nothing is ever trashed (the production trash seam is never invoked).
///
/// `CacheoutViewModel` is `@MainActor`, so the end-to-end tests are
/// annotated accordingly (project memory: never block a MainActor test
/// on semaphores) — this file imports NO GUI framework.
final class SpaceScannerIntegrationTests: XCTestCase {

    /// The fixture-scanner slugs the zero-edit grep gate hunts for in
    /// production sources. Deliberately distinctive: a naive grep for
    /// "fixture" would false-positive on doc comments ("tests pass a
    /// fixture home"), so the gate matches these EXACT registered slugs.
    private static let fixtureSlugs = [
        "fixture_e2e_tree", "fixture_e2e_refusals", "fixture_e2e_cache",
    ]

    /// The RETIRED per-item scanner slug (fn-4.5 unregistered it atomically
    /// with `build_artifacts`; fn-4.7 deleted the scanner's source). It is a
    /// bare string on purpose — there is no type left to name, and the
    /// negative assertions below must keep proving that this SLUG never
    /// reappears in any registry.
    private let retiredNodeModulesSlug = "node_modules"

    private var base: URL!
    private var fixtureHome: URL!
    /// Injected suite for `DevRootsStore` — zero standard-suite reads or
    /// writes (fn-4.5's production composition resolves dev roots).
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("SpaceScannerIntegrationTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
        suiteName = "SpaceScannerIntegrationTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Fixture builders

    private func writeFile(_ url: URL, bytes: Int = 4096) throws {
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    /// A directory with a couple of payload files and a nested subtree —
    /// enough structure that per-child deletion math is non-trivial.
    private func makePayloadTree(at root: URL) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile(root.appendingPathComponent("payload_a.bin"), bytes: 8192)
        try writeFile(root.appendingPathComponent("payload_b.bin"), bytes: 4096)
        let nested = root.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFile(nested.appendingPathComponent("deep.bin"), bytes: 4096)
    }

    /// The `.absolutePath` fixture category driving the aggregate
    /// (`.removeContents`) half of the end-to-end run. Registered with the
    /// runtime so the validator's category-provenance binding accepts its
    /// items (provenance is trusted only for REGISTERED instances).
    private func makeFixtureCategory(root: URL) -> CacheCategory {
        CacheCategory(
            name: "Fixture E2E Cache",
            slug: "fixture_e2e_cache",
            description: "fixture cache tree for the fn-2.7 end-to-end proof",
            icon: "trash",
            discovery: [.absolutePath(root.path)],
            riskLevel: .safe,
            rebuildNote: "",
            defaultSelected: false
        )
    }

    /// The full production composition for one fixture category plus one
    /// per-item fixture scanner — the SAME public initializer and factory
    /// path production uses, just with injected pieces (the R4 seam).
    private func makeRuntime(
        category: CacheCategory,
        perItemScanners: [any SpaceScanner]
    ) throws -> SpaceScannerRuntime {
        let provider = FileSystemIdentityProvider()
        let categoryScanner = CategoryScanner(
            categories: [category],
            scanner: CacheScanner(home: fixtureHome, provider: provider)
        )
        return try SpaceScannerRuntime(
            scanners: [categoryScanner] + perItemScanners,
            categories: [category],
            home: fixtureHome,
            provider: provider
        )
    }

    /// Independent fixture math: measure a deletion target the SAME way the
    /// cleaner must, with a sizer the cleaner does not own.
    private func measuredExact(_ url: URL) -> Int64 {
        DirectorySizer().measure(at: url, mode: .deletionTarget)
            .exactAllocatedBytes
    }

    /// Sum of independently-measured exact bytes over every child of `root`
    /// — exactly what a `.removeContents` clean must report having freed.
    private func measuredExactOfChildren(of root: URL) throws -> Int64 {
        try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .reduce(0) { $0 + measuredExact($1) }
    }

    /// The composite key a `TempTreeScanner` item gets for `target`,
    /// derived INDEPENDENTLY of the scanner (same frozen preimage) — the
    /// test computes what the id MUST be, never echoes what the scan said.
    private func treeItemKey(scanner: String, target: URL) -> ItemKey {
        let canonical = FileSystemIdentityProvider().canonicalize(target).path
        return ItemKey(
            scannerID: scanner,
            itemID: ReclaimableItem.stableID(
                scannerID: scanner, canonicalPath: canonical
            )
        )
    }

    // MARK: - R3 + R4: the end-to-end run (scan → select → clean → report)

    @MainActor
    func testFixtureScannerEndToEndScanSelectCleanReport() async throws {
        // Fixture tree: one aggregate cache root (category-policy admission)
        // and one container of per-item candidates (container admission).
        let cacheRoot = base.appendingPathComponent("cacheroot")
        try makePayloadTree(at: cacheRoot)
        let container = base.appendingPathComponent("projects")
        let projA = container.appendingPathComponent("proj_a")
        let projB = container.appendingPathComponent("proj_b")
        try makePayloadTree(at: projA)
        try makePayloadTree(at: projB)

        let category = makeFixtureCategory(root: cacheRoot)
        let runtime = try makeRuntime(
            category: category,
            perItemScanners: [
                TempTreeScanner(id: "fixture_e2e_tree", container: container)
            ]
        )

        // R4, runtime-derived admission: the container root reaches the
        // cleaner's admission set SOLELY through the scanner's registration
        // — and it is a NON-DEFAULT root no production scanner declares.
        XCTAssertEqual(runtime.trustedContainerRoots, [container],
                       "the runtime union is exactly the registered declaration")
        XCTAssertFalse(
            DevRootsStore.seedRootNames
                .map { fixtureHome.appendingPathComponent($0).path }
                .contains(container.path),
            "the fixture container must be a root only registration declares"
        )

        // Independent delete-time math BEFORE anything runs.
        let expectedAggregateExact = try measuredExactOfChildren(of: cacheRoot)
        let expectedItemExact = measuredExact(projA)
        XCTAssertGreaterThan(expectedAggregateExact, 0)
        XCTAssertGreaterThan(expectedItemExact, 0)

        let viewModel = CacheoutViewModel(runtime: runtime)
        viewModel.moveToTrash = false  // permanent-delete, fixture-contained

        // SCAN — the runtime's validated stream, both scanners.
        await viewModel.scan(trigger: .userInitiated)

        let aggregateKey = ItemKey(
            scannerID: CategoryScanner.registeredID, itemID: category.slug
        )
        let projAKey = treeItemKey(scanner: "fixture_e2e_tree", target: projA)
        let projBKey = treeItemKey(scanner: "fixture_e2e_tree", target: projB)

        let aggregate = try XCTUnwrap(viewModel.item(for: aggregateKey))
        XCTAssertEqual(aggregate.state, .measured)
        XCTAssertEqual(
            aggregate.exactBytes,
            DirectorySizer().measure(at: cacheRoot, mode: .scanRoot)
                .exactAllocatedBytes,
            "scan-time aggregate bytes match an independent same-mode measure"
        )
        XCTAssertEqual(
            viewModel.items(forScanner: "fixture_e2e_tree").map(\.key),
            [projAKey, projBKey],
            "per-item ids equal the independently-derived frozen preimage"
        )

        // SELECT — the unified ItemKey surface, one key per admission mode.
        viewModel.toggleSelection(for: aggregateKey)
        viewModel.toggleSelection(for: projAKey)
        XCTAssertEqual(viewModel.selectedItemKeys, [aggregateKey, projAKey])

        // CLEAN — fn-2.3's unified entry on the runtime-constructed cleaner.
        await viewModel.clean()

        // REPORT — per-item entries in presentation order (registry order:
        // the category adapter registers first), bytes vs independent math.
        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.disposal, .permanent)
        XCTAssertEqual(report.errors.map(\.message), [])
        XCTAssertEqual(report.entries.map(\.key), [aggregateKey, projAKey])
        XCTAssertEqual(report.entries[0].exactBytes, expectedAggregateExact,
                       "aggregate freed bytes == independent per-child math")
        XCTAssertEqual(report.entries[1].exactBytes, expectedItemExact,
                       "per-item freed bytes == independent target math")
        XCTAssertEqual(report.entries.map(\.estimatedUpToBytes), [0, 0],
                       "no hardlinks in the fixture — everything is exact")
        XCTAssertEqual(report.entries.map(\.displayName),
                       ["Fixture E2E Cache", "proj_a"])

        // Per-scanner rollup: one section per scanner, pure sums.
        XCTAssertEqual(report.scannerRollups, [
            CleanupReport.ScannerRollup(
                scannerID: CategoryScanner.registeredID,
                exactBytes: expectedAggregateExact,
                estimatedUpToBytes: 0,
                entryCount: 1
            ),
            CleanupReport.ScannerRollup(
                scannerID: "fixture_e2e_tree",
                exactBytes: expectedItemExact,
                estimatedUpToBytes: 0,
                entryCount: 1
            ),
        ])
        XCTAssertEqual(report.totalFreedExact,
                       expectedAggregateExact + expectedItemExact)

        // Filesystem truth: `.removeContents` empties the root but keeps it;
        // `.removeItem` removes the selected tree; the unselected sibling is
        // untouched.
        XCTAssertTrue(fm.fileExists(atPath: cacheRoot.path),
                      "removeContents preserves the category root itself")
        XCTAssertEqual(
            try fm.contentsOfDirectory(atPath: cacheRoot.path), [],
            "every child of the aggregate root is gone"
        )
        XCTAssertFalse(fm.fileExists(atPath: projA.path),
                       "the selected per-item tree is deleted")
        XCTAssertTrue(fm.fileExists(atPath: projB.path),
                      "the unselected sibling is untouched")

        // clean()'s trailing rescan saw the new truth: the emptied aggregate
        // is `.empty` (unselectable), proj_a vanished — nothing selected.
        let rescanned = try XCTUnwrap(viewModel.item(for: aggregateKey))
        XCTAssertEqual(rescanned.state, .empty)
        XCTAssertEqual(viewModel.items(forScanner: "fixture_e2e_tree").map(\.key),
                       [projBKey])
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty,
                      "the emptied aggregate deselects; the vanished key prunes")
    }

    // MARK: - R3: selection survives a rescan of the same tree, end-to-end

    @MainActor
    func testSelectionSurvivesRescanOfSameTreeEndToEnd() async throws {
        let cacheRoot = base.appendingPathComponent("cacheroot")
        try makePayloadTree(at: cacheRoot)
        let container = base.appendingPathComponent("projects")
        let projA = container.appendingPathComponent("proj_a")
        try makePayloadTree(at: projA)

        let runtime = try makeRuntime(
            category: makeFixtureCategory(root: cacheRoot),
            perItemScanners: [
                TempTreeScanner(id: "fixture_e2e_tree", container: container)
            ]
        )
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .userInitiated)

        let aggregateKey = ItemKey(
            scannerID: CategoryScanner.registeredID, itemID: "fixture_e2e_cache"
        )
        let projAKey = treeItemKey(scanner: "fixture_e2e_tree", target: projA)
        viewModel.toggleSelection(for: aggregateKey)
        viewModel.toggleSelection(for: projAKey)
        XCTAssertEqual(viewModel.selectedItemKeys, [aggregateKey, projAKey])

        // Rescan the UNCHANGED tree through the full pipeline: stable ids
        // (category slug; frozen canonical-path hash) keep both selections.
        await viewModel.scan(trigger: .userInitiated)

        XCTAssertEqual(
            viewModel.selectedItemKeys, [aggregateKey, projAKey],
            "selection keyed by stable ItemKeys survives a full rescan"
        )
        XCTAssertNotNil(viewModel.item(for: projAKey),
                        "the rescan re-derived the SAME per-item id")
    }

    // MARK: - R3 + R4: guard refusals — per-item errors, nothing deleted

    @MainActor
    func testGuardRefusalsSurfacePerItemErrorsAndDeleteNothing() async throws {
        // A declared container the runtime trusts (via registration)…
        let declared = base.appendingPathComponent("declared")
        try fm.createDirectory(at: declared, withIntermediateDirectories: true)
        // …an escape victim OUTSIDE it that an item claims to live inside…
        let escapeVictim = base.appendingPathComponent("escape_victim")
        try makePayloadTree(at: escapeVictim)
        // …and a container the runtime does NOT declare (R4's paired
        // refusal: registration is the ONLY thing that widens admission).
        let undeclared = base.appendingPathComponent("undeclared")
        let undeclaredItem = undeclared.appendingPathComponent("victim_item")
        try makePayloadTree(at: undeclaredItem)

        let escapeKey = treeItemKey(
            scanner: "fixture_e2e_refusals", target: escapeVictim
        )
        let undeclaredKey = treeItemKey(
            scanner: "fixture_e2e_refusals", target: undeclaredItem
        )
        // The escape item is structurally valid AND origin-bound (its
        // origin IS the scanner's declared root), so the runtime validator
        // publishes it — containment is the CLEANER's delete-time verdict,
        // and this pins it end-to-end through the view model.
        let outcome = ScanOutcome(
            items: [
                Self.removeItemFixture(
                    scanner: "fixture_e2e_refusals", key: escapeKey,
                    name: "escape", origin: declared, target: escapeVictim
                ),
            ],
            errors: []
        )
        let runtime = try SpaceScannerRuntime(
            scanners: [OutcomeFixtureScanner(
                id: "fixture_e2e_refusals",
                trustedContainerRoots: [declared],
                provide: { outcome }
            )],
            categories: [],
            home: fixtureHome,
            provider: FileSystemIdentityProvider()
        )
        let viewModel = CacheoutViewModel(runtime: runtime)
        viewModel.moveToTrash = false

        await viewModel.scan(trigger: .userInitiated)
        viewModel.toggleSelection(for: escapeKey)
        XCTAssertEqual(viewModel.selectedCount, 1)

        await viewModel.clean()

        // Per-item, self-contained errors — and NOTHING deleted.
        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.entries.map(\.key), [],
                       "a refused item never yields a report entry")
        XCTAssertEqual(report.errors.map(\.key), [escapeKey])
        XCTAssertEqual(report.errors.map(\.displayName), ["escape"])
        let escapeError = try XCTUnwrap(report.errors.first)
        XCTAssertTrue(escapeError.message.contains("not strictly inside"),
                      "refused for the RIGHT reason (containment): \(escapeError.message)")
        XCTAssertTrue(fm.fileExists(
            atPath: escapeVictim.appendingPathComponent("payload_a.bin").path
        ), "the escape target's payload is intact")

        // The undeclared-container shape can no longer even PUBLISH: the
        // validator's origin binding (round 6) refuses an origin outside
        // the producing scanner's declared roots at scan time, so the item
        // never becomes selectable — fail-closed one layer earlier.
        let undeclaredOutcome = ScanOutcome(
            items: [
                Self.removeItemFixture(
                    scanner: "fixture_e2e_refusals", key: undeclaredKey,
                    name: "undeclared", origin: undeclared,
                    target: undeclaredItem
                ),
            ],
            errors: []
        )
        let event = runtime.validatedOutcome(
            undeclaredOutcome, from: "fixture_e2e_refusals"
        )
        guard case .malformed(_, let issue) = event else {
            return XCTFail("an undeclared origin must malform the outcome")
        }
        XCTAssertEqual(issue.kind, .malformedOutcome)

        // DEFENSE IN DEPTH (frozen R4 design, unchanged): even if such an
        // item reached the cleaner, delete-time admission — derived from
        // the registration union — refuses the undeclared container
        // independently, and nothing is deleted. The snapshot is present
        // so the refusal is the CONTAINER-membership verdict, not the
        // snapshot-less fail-close.
        let cleaner = runtime.makeCleaner(snapshot: ContainerSnapshot.capture(
            roots: runtime.trustedContainerRoots,
            provider: FileSystemIdentityProvider()
        ))
        let deepReport = await cleaner.clean(
            items: [Self.removeItemFixture(
                scanner: "fixture_e2e_refusals", key: undeclaredKey,
                name: "undeclared", origin: undeclared,
                target: undeclaredItem
            )],
            moveToTrash: false
        )
        XCTAssertEqual(deepReport.entries.map(\.key), [])
        XCTAssertEqual(deepReport.errors.map(\.key), [undeclaredKey])
        let undeclaredError = try XCTUnwrap(deepReport.errors.first)
        XCTAssertTrue(
            undeclaredError.message.contains("not a configured search root"),
            "refused for the RIGHT reason (undeclared container): \(undeclaredError.message)"
        )
        XCTAssertTrue(fm.fileExists(
            atPath: undeclaredItem.appendingPathComponent("payload_a.bin").path
        ), "the undeclared-container target's payload is intact")
    }

    // ====================================================================
    // MARK: - fn-4.5: production registration + the ATOMIC registry swap
    // ====================================================================
    //
    // Everything below drives the REAL `SpaceScannerRuntime.production(...)`
    // composition over an injected fixture home and injected dev roots. The
    // `categories` scanner is deliberately kept OUT of every scan here: its
    // `.probed` discovery spawns tool subprocesses, which is neither
    // hermetic nor fast — and it declares no container roots and emits no
    // `scanner_items`, so it can neither list nor hide a build artifact.
    // (Its registration is asserted structurally, and the row-shape half of
    // the envelope lives in `CLIGateTests`.)

    /// A marker-sibling project under `dir`: `<dir>/<marker>` beside
    /// `<dir>/<artifact>/payload.bin`. Returns the artifact directory.
    @discardableResult
    private func makeMarkerProject(
        at dir: URL, marker: String, artifact: String, bytes: Int = 8192
    ) throws -> URL {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xC3, count: 32)
            .write(to: dir.appendingPathComponent(marker))
        let artifactDir = dir.appendingPathComponent(artifact)
        try fm.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        try writeFile(artifactDir.appendingPathComponent("payload.bin"), bytes: bytes)
        return artifactDir
    }

    /// Dev-root resolution through the REAL R16 pipeline (never a hand-built
    /// resolution), invocation-scoped so nothing is persisted.
    private func devRoots(_ roots: [URL]) -> DevRootsResolution {
        DevRootsStore(defaults: defaults)
            .effectiveRoots(replacing: roots, home: fixtureHome)
    }

    /// The production composition over the fixture home + given dev roots.
    private func productionRuntime(devRoots roots: [URL]) -> SpaceScannerRuntime {
        SpaceScannerRuntime.production(
            home: fixtureHome, devRoots: devRoots(roots)
        )
    }

    /// Every PER-ITEM scanner of a runtime that this fixture may drive (the
    /// aggregate adapter excluded, and `ephemeral_tmp` with it): fn-6.4
    /// registers the temp scanner over the machine's REAL confstr roots
    /// (`/private/tmp`, `…/T`, `…/C`), so including it here would walk live
    /// system state — neither hermetic nor fast. Its registration is asserted
    /// structurally, and its scan/clean behavior over INJECTED fixture roots
    /// lives in `EphemeralTempRegistrationTests`.
    private func perItemScannerIDs(_ runtime: SpaceScannerRuntime) -> Set<String> {
        Set(runtime.scanners.map(\.id))
            .subtracting([
                CategoryScanner.registeredID,
                EphemeralTempScanner.registeredID,
            ])
    }

    /// One validated scan of the given scanner subset, collected per scanner
    /// — the same stream the ViewModel and the CLI consume.
    private func collect(
        _ runtime: SpaceScannerRuntime, scannerIDs: Set<String>?,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> (outcomes: [String: ScanOutcome], snapshot: ContainerSnapshot) {
        let session = runtime.scanValidatedSession(
            scannerIDs: scannerIDs, context: ScanContext(trigger: .userInitiated)
        )
        var outcomes: [String: ScanOutcome] = [:]
        for await event in session.events {
            switch event {
            case .outcome(let id, let outcome): outcomes[id] = outcome
            case .malformed(let id, let issue):
                XCTFail("\(id) malformed: \(issue.detail)", file: file, line: line)
            }
        }
        return (outcomes, session.snapshot)
    }

    /// The identity path an artifact dir must publish as its `url`.
    private func identityPath(_ url: URL) -> String {
        FileSystemIdentityProvider().resolveTargetKeepingLeaf(url).path
    }

    /// THE SWAP, proven in ONE run: `build_artifacts` is registered and
    /// addressable, `node_modules` is neither, and the one fixture
    /// node_modules tree is listed EXACTLY once — under `build_artifacts`.
    /// No commit exists in which both are registered (double-listing, D4) or
    /// in which the legacy slug can still emit unmarked, non-revalidated
    /// items for the same trees (an R17 bypass).
    func testAtomicSwapRegistersBuildArtifactsAndRetiresTheNodeModulesSlug() async throws {
        let dev = base.appendingPathComponent("dev")
        let nodeModules = try makeMarkerProject(
            at: dev.appendingPathComponent("web"),
            marker: "package.json", artifact: "node_modules"
        )
        let target = try makeMarkerProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        let runtime = productionRuntime(devRoots: [dev])

        // (1) COMPOSITION — one slot, swapped: the legacy scanner is gone
        // from the registry entirely, so its slug cannot be addressed and
        // its items cannot be emitted.
        XCTAssertEqual(runtime.scanners.map(\.id), [
            CategoryScanner.registeredID,
            BuildArtifactsScanner.registeredID,
            OrphanedCachesScanner.registeredID,
            EphemeralTempScanner.registeredID,
        ])
        XCTAssertFalse(
            runtime.scanners.contains { $0.id == retiredNodeModulesSlug },
            "the node_modules scanner is unregistered by the SAME change — "
                + "and since fn-4.7 its source no longer exists, so the slug "
                + "survives here only as the retired STRING it is"
        )
        // Registration is what extends delete-time admission (R4).
        XCTAssertTrue(runtime.trustedContainerRoots.contains { $0.path == dev.path })

        // (2) ONE SCAN over every registered per-item scanner: the fixture
        // node_modules tree is listed exactly ONCE, by build_artifacts.
        let scanned = await collect(runtime, scannerIDs: perItemScannerIDs(runtime))
        let listedBy = scanned.outcomes.filter { _, outcome in
            outcome.items.contains { $0.url?.path == identityPath(nodeModules) }
        }.keys.sorted()
        XCTAssertEqual(listedBy, [BuildArtifactsScanner.registeredID],
                       "exactly one registered scanner lists the tree")
        let buildItems = try XCTUnwrap(
            scanned.outcomes[BuildArtifactsScanner.registeredID]?.items
        )
        XCTAssertEqual(
            Set(buildItems.compactMap(\.url?.path)),
            [identityPath(nodeModules), identityPath(target)],
            "both ecosystems' artifact dirs ride the ONE scanner"
        )
        XCTAssertTrue(buildItems.allSatisfy(\.requiresPreDeleteRevalidation),
                      "every addressable item carries the R17 marker")

        // (3) CLI ADDRESSING — the retired slug fails per the existing
        // unknown-slug conventions (parse refuses BEFORE any scan runs), in
        // every addressing form, while the new slug resolves.
        let deps = CLIHandler.CLIRuntimeDependencies(
            runtime: runtime,
            categorySlugs: Set(CacheCategory.allCategories.map(\.slug))
        )
        let itemID = try XCTUnwrap(
            buildItems.first { $0.url?.path == identityPath(nodeModules) }?.id
        )
        for retired in ["node_modules", "node_modules:\(itemID)"] {
            let outcome = await CLIHandler.cleanCLIOutcome(
                targets: [retired], dryRun: true, confirmed: false,
                euid: 501, deps: deps
            )
            guard case .failure(let code, let message, _) = outcome else {
                return XCTFail("'\(retired)' must not resolve after the swap")
            }
            XCTAssertEqual(code, "INVALID_ARGUMENTS")
            XCTAssertTrue(message.contains("Unknown or invalid target"),
                          "the frozen unknown-slug message: \(message)")
        }
        XCTAssertTrue(fm.fileExists(atPath: nodeModules.path),
                      "a refused address deletes nothing")

        // `<slug>:<item-id>` addressing through the real clean pipeline.
        guard case .success(let plan) = await CLIHandler.cleanCLIOutcome(
            targets: ["build_artifacts:\(itemID)"], dryRun: true,
            confirmed: false, euid: 501, deps: deps
        ) else {
            return XCTFail("build_artifacts:<item-id> must resolve")
        }
        let rows = try XCTUnwrap(plan["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["slug"] as? String },
                       ["build_artifacts:\(itemID)"])
    }

    /// The GUI half of registration (R5/R7/R15), end to end: the production
    /// composition reaches `perItemSections`, Quick Clean picks up NOTHING
    /// (D3 — v1 enrolls no rule row in the automatic path), and an EXPLICIT
    /// scan → select → clean removes the artifact directory itself through
    /// the session-bound `makeCleaner(snapshot:)`.
    @MainActor
    func testProductionScanSelectCleanEndToEndWhileQuickCleanSelectsNone() async throws {
        let dev = base.appendingPathComponent("dev")
        let target = try makeMarkerProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        let runtime = productionRuntime(devRoots: [dev])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(
            trigger: .userInitiated,
            scannerIDs: [BuildArtifactsScanner.registeredID]
        )

        let section = try XCTUnwrap(viewModel.perItemSections.first {
            $0.scannerID == BuildArtifactsScanner.registeredID
        })
        XCTAssertEqual(section.displayName, "Project Build Artifacts")
        XCTAssertEqual(section.items.compactMap(\.url?.path),
                       [identityPath(target)])
        let item = try XCTUnwrap(section.items.first)
        XCTAssertEqual(item.risk, .safe, "the target/ rule row's declared risk")
        XCTAssertEqual(item.state, .measured)

        // R15: `safe` RISK does not enroll anything in the automatic path —
        // the selection triple's third member is what Quick Clean reads.
        XCTAssertFalse(item.automaticCleanEligible)
        viewModel.selectAllSafe()
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty,
                      "Quick Clean selects ZERO build-artifact items (D3)")
        XCTAssertEqual(viewModel.automaticCleanableSize, 0)
        XCTAssertFalse(viewModel.hasAutomaticCleanableItems)

        // …while EXPLICIT selection still cleans: the artifact directory
        // itself goes, the project and its marker stay, and the freed bytes
        // are the deletion-time measurement.
        let expectedExact = DirectorySizer()
            .measure(at: target, mode: .deletionTarget).exactAllocatedBytes
        XCTAssertGreaterThan(expectedExact, 0)
        viewModel.moveToTrash = false  // permanent-delete, fixture-contained
        viewModel.toggleSelection(for: item.key)
        XCTAssertTrue(viewModel.hasCleanableSelection)

        await viewModel.clean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.errors.map(\.message), [])
        XCTAssertEqual(report.entries.map(\.key), [item.key])
        XCTAssertEqual(report.entries.first?.exactBytes, expectedExact)
        XCTAssertFalse(fm.fileExists(atPath: target.path),
                       "the artifact directory itself is deleted")
        XCTAssertTrue(
            fm.fileExists(atPath: dev.appendingPathComponent("rust/Cargo.toml").path),
            "the project and the marker that proved it survive"
        )
    }

    /// R8/D1 end-to-end: the PRODUCTION view-model factory reads the store
    /// at construction, and a dev-roots change rebuilds THAT composition
    /// through fn-4.10's seam — the next scan walks the new roots.
    @MainActor
    func testProductionFactoryReadsStoreAndRebuildsOnDevRootsChange() async throws {
        let devA = base.appendingPathComponent("devA")
        let devB = base.appendingPathComponent("devB")
        let targetA = try makeMarkerProject(
            at: devA.appendingPathComponent("a"),
            marker: "Cargo.toml", artifact: "target"
        )
        let targetB = try makeMarkerProject(
            at: devB.appendingPathComponent("b"),
            marker: "Cargo.toml", artifact: "target"
        )
        let store = DevRootsStore(defaults: defaults)
        store.resetToDefaults()
        // Only devA is configured at construction time.
        defaults.set([devA.path], forKey: DevRootsStore.devRootsKey)

        let viewModel = CacheoutViewModel.production(
            home: fixtureHome, devRootsStore: store
        )
        let onlyBuildArtifacts: Set<String> = [BuildArtifactsScanner.registeredID]
        await viewModel.scan(trigger: .userInitiated, scannerIDs: onlyBuildArtifacts)
        XCTAssertEqual(
            viewModel.items(forScanner: BuildArtifactsScanner.registeredID)
                .compactMap(\.url?.path),
            [identityPath(targetA)],
            "the initial runtime came from the store, through the factory"
        )

        // Settings adds devB → the SAME factory rebuilds the SAME production
        // composition with the new roots.
        store.add(devB.path)
        viewModel.devRootsDidChange()
        XCTAssertFalse(
            viewModel.hasCleanableSelection,
            "a rebuild invalidates destructive freshness until a new scan adopts"
        )

        await viewModel.scan(trigger: .userInitiated, scannerIDs: onlyBuildArtifacts)
        XCTAssertEqual(
            Set(viewModel.items(forScanner: BuildArtifactsScanner.registeredID)
                .compactMap(\.url?.path)),
            [identityPath(targetA), identityPath(targetB)],
            "the rebuilt runtime walks BOTH configured roots"
        )
        // Still the production registry — the factory rebuilt the same
        // composition, not a different one. (Every registered per-item
        // scanner gets a section, whether or not this scan requested it:
        // `ephemeral_tmp` is here with no items because only
        // `build_artifacts` was scanned.)
        XCTAssertEqual(
            viewModel.perItemSections.map(\.scannerID),
            [
                BuildArtifactsScanner.registeredID,
                OrphanedCachesScanner.registeredID,
                EphemeralTempScanner.registeredID,
            ]
        )
    }

    /// R8, the CLI half: injected roots are threaded into `production()`
    /// BEFORE `CLIRuntimeDependencies` is constructed — the only order that
    /// works, since `trustedContainerRoots` freeze at registration.
    func testCLIRuntimeDependenciesThreadInjectedDevRootsIntoProduction() throws {
        let dev = base.appendingPathComponent("dev")
        try fm.createDirectory(at: dev, withIntermediateDirectories: true)
        let resolution = devRoots([dev])

        let deps = CLIHandler.CLIRuntimeDependencies.production(
            devRoots: resolution
        )

        let scanner = try XCTUnwrap(
            deps.runtime.scanners.compactMap { $0 as? BuildArtifactsScanner }.first,
            "the CLI composition registers the build-artifacts scanner"
        )
        XCTAssertEqual(scanner.trustedContainerRoots.map(\.path),
                       resolution.keptRoots.map(\.path),
                       "the invocation-scoped roots reach the scanner unchanged")
        XCTAssertTrue(deps.runtime.trustedContainerRoots.contains { $0.path == dev.path },
                      "…and therefore delete-time admission")
        XCTAssertFalse(
            deps.runtime.scanners.contains { $0.id == retiredNodeModulesSlug },
            "the CLI composition is the swapped one too"
        )
    }

    /// R17/R6 ordering, proven at the product boundary: a valuable-bearing
    /// item is fail-closed from its FIRST addressable moment. The
    /// revalidator declaration landed BEFORE conformance (fn-4.8 → fn-4.5),
    /// so there is no scan in which such an item is deletable without an
    /// acknowledgement — on either surface.
    @MainActor
    func testValuableBearingItemIsRevalidatorEnforcedFromItsFirstAddressableMoment() async throws {
        let dev = base.appendingPathComponent("dev")
        let target = try makeMarkerProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        // A release DMG inside the build directory, comfortably above the
        // shared allocated floor.
        let dmg = target.appendingPathComponent("release/bundle/App.dmg")
        try fm.createDirectory(
            at: dmg.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(
            repeating: 0xAB,
            count: Int(ValuablesDetector.minimumAllocatedBytes) + 1_000_000
        ).write(to: dmg)

        let runtime = productionRuntime(devRoots: [dev])

        // GUI surface: scan → select → clean, with NO authorization context
        // (fn-4.6's confirmation sheet is what populates one).
        let viewModel = CacheoutViewModel(runtime: runtime)
        viewModel.moveToTrash = false
        await viewModel.scan(
            trigger: .userInitiated,
            scannerIDs: [BuildArtifactsScanner.registeredID]
        )
        let item = try XCTUnwrap(
            viewModel.items(forScanner: BuildArtifactsScanner.registeredID).first
        )
        XCTAssertEqual(item.risk, .review,
                       "the valuables gate forced the safe row off safe")
        XCTAssertFalse(item.defaultSelected)
        viewModel.toggleSelection(for: item.key)
        await viewModel.clean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.entries.map(\.key), [], "nothing was deleted")
        XCTAssertEqual(report.errors.map(\.key), [item.key])
        XCTAssertTrue(
            (report.errors.first?.message ?? "").contains("App.dmg"),
            "the refusal names the valuable: \(report.errors.first?.message ?? "")"
        )
        XCTAssertTrue(fm.fileExists(atPath: dmg.path))
        XCTAssertTrue(fm.fileExists(atPath: target.path))

        // CLI surface: a plain `--confirm` of the same item refuses too.
        let deps = CLIHandler.CLIRuntimeDependencies(
            runtime: runtime,
            categorySlugs: Set(CacheCategory.allCategories.map(\.slug))
        )
        let cliOutcome = await CLIHandler.cleanCLIOutcome(
            targets: ["build_artifacts:\(item.id)"], dryRun: false,
            confirmed: true, euid: 501, deps: deps
        )
        switch cliOutcome {
        case .success(let payload):
            let rows = try XCTUnwrap(payload["results"] as? [[String: Any]])
            XCTAssertEqual(rows.map { $0["success"] as? Bool }, [false],
                           "an unacknowledged valuable-bearing item is refused")
        case .failure(let code, _, _):
            XCTAssertEqual(code, "CLEAN_FAILED")
        }
        XCTAssertTrue(fm.fileExists(atPath: target.path),
                      "the artifact directory survives an unacknowledged CLI clean")
    }

    // MARK: - fn-4.6 (R17): the sheet's authorization reaches the revalidator

    /// A rust project whose `target/` holds one release DMG above the
    /// shared allocated floor. Returns (artifact dir, dmg).
    private func makeValuableBearingProject(
        under dev: URL, name: String = "rust", dmg dmgName: String = "App.dmg"
    ) throws -> (target: URL, dmg: URL) {
        let target = try makeMarkerProject(
            at: dev.appendingPathComponent(name),
            marker: "Cargo.toml", artifact: "target"
        )
        let dmg = target.appendingPathComponent("release/bundle/\(dmgName)")
        try fm.createDirectory(
            at: dmg.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(
            repeating: 0xAB,
            count: Int(ValuablesDetector.minimumAllocatedBytes) + 1_000_000
        ).write(to: dmg)
        return (target, dmg)
    }

    /// THE GUI end-to-end proof (R3 + R17): the item is DISPLAYED in the
    /// confirmation sheet with its valuable, the confirm action builds the
    /// authorization context from exactly that displayed set, the context
    /// travels the clean path into the cleaner, the revalidator's
    /// delete-time recomputation MATCHES — and the directory is deleted.
    ///
    /// The negative control is one line away: the SAME fixture cleaned
    /// through the unauthorized `clean()` path is refused
    /// (`testValuableBearingItemIsRevalidatorEnforcedFromItsFirstAddressableMoment`).
    @MainActor
    func testSheetConfirmAuthorizesTheDisplayedSetAndDeletesTheItem() async throws {
        let dev = base.appendingPathComponent("dev")
        let (target, dmg) = try makeValuableBearingProject(under: dev)

        let viewModel = CacheoutViewModel(runtime: productionRuntime(devRoots: [dev]))
        viewModel.moveToTrash = false
        await viewModel.scan(
            trigger: .userInitiated,
            scannerIDs: [BuildArtifactsScanner.registeredID]
        )
        let item = try XCTUnwrap(
            viewModel.items(forScanner: BuildArtifactsScanner.registeredID).first
        )
        viewModel.toggleSelection(for: item.key)

        // The SHEET displays the valuable — name, size and modified date
        // derived from the stored identity integers, reveal bound to the
        // discovered spelling.
        let row = try XCTUnwrap(viewModel.confirmationRows.first)
        XCTAssertFalse(row.isBlocked)
        XCTAssertEqual(row.valuables.map(\.name), ["App.dmg"])
        XCTAssertEqual(row.valuables.first?.revealURL.path, dmg.path)
        XCTAssertFalse(
            try XCTUnwrap(row.valuables.first?.formattedModified).isEmpty
        )

        // The context the confirm action will pass down: ONE entry, for
        // exactly this displayed item.
        let context = viewModel.confirmationAuthorization
        XCTAssertEqual(Set(context.keys), [item.key])
        XCTAssertEqual(
            context[item.key],
            item.valuablesDisclosure?.acknowledgementToken(for: item.key)
        )

        await viewModel.confirmClean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.errors.map(\.message), [],
                       "the acknowledgement reached the revalidator")
        XCTAssertEqual(report.entries.map(\.key), [item.key])
        XCTAssertFalse(fm.fileExists(atPath: target.path),
                       "an ACKNOWLEDGED valuable-bearing item deletes")
        XCTAssertFalse(fm.fileExists(atPath: dmg.path))
    }

    /// The same path when the disclosed evidence CHANGED since the scan: the
    /// delete-time probe recomputes a DIFFERENT token, so the sheet's
    /// acknowledgement no longer covers what is there — a FRESH refusal with
    /// the current valuables and a fresh token, and nothing deleted.
    @MainActor
    func testSheetConfirmRefusesFreshlyWhenTheValuableChangedSinceScan() async throws {
        let dev = base.appendingPathComponent("dev")
        let (target, dmg) = try makeValuableBearingProject(under: dev)

        let viewModel = CacheoutViewModel(runtime: productionRuntime(devRoots: [dev]))
        viewModel.moveToTrash = false
        await viewModel.scan(
            trigger: .userInitiated,
            scannerIDs: [BuildArtifactsScanner.registeredID]
        )
        let item = try XCTUnwrap(
            viewModel.items(forScanner: BuildArtifactsScanner.registeredID).first
        )
        viewModel.toggleSelection(for: item.key)
        let scanToken = try XCTUnwrap(viewModel.confirmationAuthorization[item.key])

        // A NEW build lands a second release artifact inside the directory
        // between the sheet and the confirm — set membership changed, so the
        // token the user acknowledged is stale by construction.
        try Data(
            repeating: 0xCD,
            count: Int(ValuablesDetector.minimumAllocatedBytes) + 2_000_000
        ).write(to: dmg.deletingLastPathComponent()
            .appendingPathComponent("Later.pkg"))

        await viewModel.confirmClean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.entries.map(\.key), [], "nothing was deleted")
        let error = try XCTUnwrap(report.errors.first)
        XCTAssertEqual(error.key, item.key)
        let refusal = try XCTUnwrap(
            error.refusal, "a valuables refusal carries the typed payload"
        )
        XCTAssertEqual(refusal.valuables.map(\.name).sorted(),
                       ["App.dmg", "Later.pkg"],
                       "the refusal lists the CURRENT delete-time set")
        let freshToken = try XCTUnwrap(refusal.acknowledgementToken)
        XCTAssertNotEqual(freshToken, scanToken,
                          "a changed set ROTATES the token")
        XCTAssertEqual(freshToken.count, 64)
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        XCTAssertTrue(fm.fileExists(atPath: dmg.path))
    }

    /// R17's incomplete cell, end to end: an item whose probe could not
    /// finish stays VISIBLE and SELECTED in the sheet in its blocked state,
    /// the confirm action filters its key out of BOTH the authorization
    /// context and the CLEAN SET — the cleaner provably never sees it (no
    /// entry, no error, the directory intact) — and the OTHER selected item
    /// is cleaned in the same invocation.
    @MainActor
    func testConfirmSkipsBlockedItemsEntirelyAndCleansTheRest() async throws {
        let dev = base.appendingPathComponent("dev")
        let (target, dmg) = try makeValuableBearingProject(under: dev)
        let otherContainer = base.appendingPathComponent("plain")
        let plainTarget = otherContainer.appendingPathComponent("junk")
        try makePayloadTree(at: plainTarget)

        // The REAL scanner and its REAL revalidator, with a probe entry cap
        // of 1 so the scan-time inspection cannot finish (the production
        // caps are unreachable from `production()`).
        let provider = FileSystemIdentityProvider()
        let truncated = BuildArtifactsScanner(
            home: fixtureHome, devRoots: devRoots([dev]), provider: provider,
            valuablesProbeEntryLimit: 1
        )
        let runtime = try SpaceScannerRuntime(
            scanners: [
                truncated,
                TempTreeScanner(id: "fixture_e2e_tree", container: otherContainer),
            ],
            categories: [], home: fixtureHome, provider: provider
        )
        let viewModel = CacheoutViewModel(runtime: runtime)
        viewModel.moveToTrash = false
        await viewModel.scan(trigger: .userInitiated)

        let blockedItem = try XCTUnwrap(
            viewModel.items(forScanner: BuildArtifactsScanner.registeredID).first
        )
        let plainItem = try XCTUnwrap(
            viewModel.items(forScanner: "fixture_e2e_tree").first
        )
        XCTAssertEqual(
            blockedItem.valuablesDisclosure?.probeComplete, false,
            "the capped probe could not finish"
        )
        viewModel.toggleSelection(for: blockedItem.key)
        viewModel.toggleSelection(for: plainItem.key)

        // SELECTION IS UNCHANGED and the blocked row is still RENDERED —
        // deselecting would hide the very warning the user must see.
        let rows = viewModel.confirmationRows
        XCTAssertEqual(Set(rows.map(\.key)), [blockedItem.key, plainItem.key])
        XCTAssertEqual(viewModel.selectedItemKeys,
                       [blockedItem.key, plainItem.key])
        XCTAssertTrue(
            try XCTUnwrap(rows.first { $0.key == blockedItem.key }).isBlocked
        )
        XCTAssertEqual(viewModel.blockedConfirmationKeys, [blockedItem.key])
        XCTAssertEqual(viewModel.confirmableSelectedCount, 1,
                       "the sheet quotes only what confirm will act on")
        XCTAssertTrue(viewModel.confirmationAuthorization.isEmpty)

        await viewModel.confirmClean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.entries.map(\.key), [plainItem.key],
                       "confirm proceeds for the remaining items")
        XCTAssertEqual(report.errors.map(\.key), [],
                       "the blocked item never reached the cleaner — not "
                           + "even as a refusal")
        XCTAssertTrue(fm.fileExists(atPath: target.path),
                      "the blocked item's directory is untouched")
        XCTAssertTrue(fm.fileExists(atPath: dmg.path))
        XCTAssertFalse(fm.fileExists(atPath: plainTarget.path))
    }

    // MARK: - R4: the zero-edit grep gate

    /// Registering the fixture scanners above took ZERO production edits —
    /// asserted structurally: no file under `Sources/Cacheout/` references
    /// any fixture-scanner slug. The gate also proves itself non-vacuous
    /// (the source tree must actually be found and non-trivially large) and
    /// re-checks this file's own no-GUI-import discipline.
    func testRegisteringFixtureScannersRequiredZeroProductionEdits() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let productionSources = testFile
            .deletingLastPathComponent()   // Tests/CacheoutTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Cacheout")

        var swiftFiles: [URL] = []
        let enumerator = fm.enumerator(
            at: productionSources, includingPropertiesForKeys: nil
        )
        while let next = enumerator?.nextObject() as? URL {
            if next.pathExtension == "swift" { swiftFiles.append(next) }
        }
        XCTAssertGreaterThan(
            swiftFiles.count, 20,
            "gate must not be vacuous — Sources/Cacheout was not found or "
            + "is implausibly small at \(productionSources.path)"
        )

        var offenders: [String] = []
        for file in swiftFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            for slug in Self.fixtureSlugs where text.contains(slug) {
                offenders.append("\(file.lastPathComponent) references '\(slug)'")
            }
        }
        XCTAssertEqual(
            offenders, [],
            "R4: registration must be the ONLY step — production sources "
            + "may not know any fixture scanner exists"
        )

        // The no-GUI-code half of R3, self-checked. The needles are built
        // by concatenation so this test's own source cannot match itself.
        let ownSource = try String(contentsOf: testFile, encoding: .utf8)
        for framework in ["SwiftUI", "AppKit", "Cocoa"] {
            XCTAssertFalse(
                ownSource.contains("import " + framework),
                "the end-to-end suite must drive the pipeline with no GUI "
                + "imports (found import \(framework))"
            )
        }
    }

    // MARK: - Item fixture

    /// A structurally-valid `.removeItem` item with the FROZEN
    /// container-item descriptor. `origin` is the container CLAIM the
    /// cleaner validates against the runtime's registration-derived union;
    /// `target` is the unresolved deletion target.
    private static func removeItemFixture(
        scanner: String, key: ItemKey, name: String, origin: URL, target: URL
    ) -> ReclaimableItem {
        // `url` is the record's OWN captured resolution (the documented
        // display contract) — the validator's display-identity binding
        // refuses an item whose display is not its deletion-target capture.
        let resolved = FileSystemIdentityProvider().canonicalize(target)
        return ReclaimableItem(
            id: key.itemID,
            scannerID: scanner,
            displayName: name,
            exactBytes: 4096,
            estimatedUpToBytes: 0,
            logicalBytes: nil,
            itemCount: 1,
            url: resolved,
            declaredDisplayPath: target.path,
            rootRecords: [RootScanRecord(
                requestedURL: target,
                resolvedURL: resolved,
                status: .measured
            )],
            state: .measured,
            scanError: nil,
            risk: .review,
            evidence: "fixture item \(name)",
            rebuildNote: nil,
            action: .removeItem,
            admission: .containerItem(
                originContainer: origin, requestedTargetURL: target
            ),
            defaultSelected: false,
            automaticCleanEligible: false,
            isStale: nil
        )
    }
}

// MARK: - Fixture scanners (test-local conformers — the R4 seam)

/// A REAL tiny per-item `SpaceScanner`: one `.removeItem` item per child of
/// its container, ids via the frozen `ReclaimableItem.stableID` preimage
/// over the CANONICAL path (stable across rescans — the R3 selection-
/// survival contract), bytes measured with the shared sizer. The container
/// is declared via `trustedContainerRoots` ALONE — nothing else extends
/// delete-time admission (R4). Holds only Sendable state.
private struct TempTreeScanner: SpaceScanner {
    let id: String
    let container: URL
    var displayName: String { "Temp Tree (\(id))" }
    var trustedContainerRoots: [URL] { [container] }

    func scan(context: ScanContext) async -> ScanOutcome {
        // The generic context crosses the boundary; this scanner has no
        // TCC-protected roots and no categories, so it ignores both knobs
        // (the protocol contract for scanners that don't care).
        let provider = FileSystemIdentityProvider()
        let sizer = DirectorySizer(provider: provider)
        let children = ((try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil
        )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }

        let items = children.map { child -> ReclaimableItem in
            let resolved = provider.canonicalize(child)
            let report = sizer.measure(at: child, mode: .scanRoot)
            let hasContent = report.itemCount > 0 || report.measuredBytes > 0
            return ReclaimableItem(
                id: ReclaimableItem.stableID(
                    scannerID: id, canonicalPath: resolved.path
                ),
                scannerID: id,
                displayName: child.lastPathComponent,
                exactBytes: report.exactAllocatedBytes,
                estimatedUpToBytes: report.estimatedUpToBytes,
                logicalBytes: nil,
                itemCount: report.itemCount,
                url: resolved,
                declaredDisplayPath: child.path,
                rootRecords: [RootScanRecord(
                    requestedURL: child, resolvedURL: resolved,
                    status: .measured
                )],
                state: hasContent ? .measured : .empty,
                scanError: nil,
                risk: .review,
                evidence: "\(report.itemCount) files under \(child.lastPathComponent)",
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

/// A `SpaceScanner` whose outcome is injected — for pinning delete-time
/// refusal paths with precisely-shaped items.
private struct OutcomeFixtureScanner: SpaceScanner {
    let id: String
    let trustedContainerRoots: [URL]
    let provide: @Sendable () async -> ScanOutcome
    var displayName: String { "Fixture \(id)" }

    func scan(context: ScanContext) async -> ScanOutcome {
        await provide()
    }
}
