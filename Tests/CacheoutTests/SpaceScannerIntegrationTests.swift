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

    private var base: URL!
    private var fixtureHome: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("SpaceScannerIntegrationTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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
            NodeModulesScanner.defaultSearchRoots(home: fixtureHome)
                .contains { $0.path == container.path },
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
        // independently, and nothing is deleted.
        let cleaner = runtime.makeCleaner()
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
