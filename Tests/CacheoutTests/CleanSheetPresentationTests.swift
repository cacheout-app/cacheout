import XCTest
@testable import Cacheout

/// fn-2.5 confirmation/report sheet presentation tests (R1).
///
/// SwiftUI bodies are assertion-dead, so the sheets' semantics live as
/// model/view-model presentation helpers and THOSE are the assertion
/// surfaces:
///
/// - `CacheoutViewModel.confirmationRows(for:)` — the unified itemization:
///   aggregates and per-item scanner rows through ONE row shape, each
///   carrying its `evidence` string (epic contract: evidence is first-class
///   in the confirmation sheet).
/// - `CacheoutViewModel.commandsTrashDisclosure(selectedItems:)` — nil
///   without command-backed selection; otherwise names ONLY the
///   command-backed items (their argv runs regardless of the Trash toggle).
/// - `CleanupReport.scannerSections` — per-scanner rollup grouping in
///   first-appearance order, pure sums.
/// - `CleanupReport.errorLines` — failed items render from SELF-CONTAINED
///   `ItemError` records alone; a vanished item still renders (no lookup).
///
/// Pure helpers are asserted statically (no runtime); the caution-warning
/// parity test drives a hermetic fixture-home view model through the SAME
/// `handle` event path production uses.
final class CleanSheetPresentationTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("CleanSheetPresentationTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Fixtures

    private func makeCategory(
        name: String,
        description: String = "test description",
        icon: String = "trash",
        risk: RiskLevel = .safe
    ) -> CacheCategory {
        CacheCategory(
            name: name,
            slug: name,
            description: description,
            icon: icon,
            discovery: [.absolutePath("/nonexistent-fixture-\(name)")],
            riskLevel: risk,
            rebuildNote: "rebuilds",
            defaultSelected: true
        )
    }

    /// Aggregate item through the ONE real mapping (`CategoryScanner.item`)
    /// — evidence/icon/label provenance must match what production rows
    /// carry, never a parallel construction.
    private func aggregate(
        name: String,
        description: String = "test description",
        icon: String = "trash",
        exact: Int64 = 4096
    ) -> ReclaimableItem {
        CategoryScanner.item(from: ScanResult(
            category: makeCategory(name: name, description: description, icon: icon),
            state: .measured,
            exactBytes: exact,
            estimatedUpToBytes: 0,
            itemCount: 1,
            scanError: nil
        ))
    }

    /// A per-item scanner fixture row (`.removeItem` + `.containerItem` —
    /// the shape the runtime validator admits for per-item scanners).
    private func perItem(
        scanner: String = "node_modules",
        id: String = "item-a",
        name: String = "projectA",
        bytes: Int64 = 8192,
        state: ScanState = .measured,
        risk: RiskLevel = .review,
        evidence: String = "node_modules of projectA — ~/dev/projectA",
        action: ReclaimAction = .removeItem
    ) -> ReclaimableItem {
        let target = base
            .appendingPathComponent(scanner)
            .appendingPathComponent(id)
        return ReclaimableItem(
            id: id,
            scannerID: scanner,
            displayName: name,
            exactBytes: bytes,
            estimatedUpToBytes: 0,
            logicalBytes: nil,
            itemCount: 1,
            url: target,
            declaredDisplayPath: target.path,
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: target, status: .measured
            )],
            state: state,
            scanError: nil,
            risk: risk,
            evidence: evidence,
            rebuildNote: nil,
            action: action,
            admission: .containerItem(
                originContainer: target.deletingLastPathComponent(),
                requestedTargetURL: target
            ),
            defaultSelected: false,
            automaticCleanEligible: false,
            isStale: nil
        )
    }

    private func entry(
        scanner: String, id: String, name: String,
        exact: Int64, estimated: Int64 = 0,
        disposal: CleanupReport.Disposal = .permanent
    ) -> CleanupReport.Entry {
        CleanupReport.Entry(
            itemID: id, scannerID: scanner, displayName: name,
            exactBytes: exact, estimatedUpToBytes: estimated,
            disposal: disposal
        )
    }

    // MARK: - Unified itemization with evidence (R1)

    func testConfirmationRowsUnifyAggregateAndPerItemRowsWithEvidence() {
        let cacheAggregate = aggregate(
            name: "npm-cache",
            description: "npm package cache — restored on next install",
            icon: "shippingbox"
        )
        let projectRow = perItem(
            id: "abc", name: "projectA",
            evidence: "node_modules of projectA — ~/dev/projectA"
        )

        let rows = CacheoutViewModel.confirmationRows(
            for: [cacheAggregate, projectRow]
        )

        XCTAssertEqual(rows.count, 2, "ONE unified list carries both kinds")
        XCTAssertEqual(
            rows.map(\.id), [cacheAggregate.key, projectRow.key],
            "input (presentation) order preserved; identity is the composite key"
        )

        // Aggregate row: registered category icon + name; evidence is the
        // category description (description-grade — honest, not padded).
        XCTAssertEqual(rows[0].icon, "shippingbox")
        XCTAssertEqual(rows[0].label, "npm-cache")
        XCTAssertEqual(
            rows[0].evidence,
            "npm package cache — restored on next install"
        )

        // Per-item row: "scanner: item" label (the pre-unification
        // "node_modules: <project>" rendering) + the item's evidence.
        XCTAssertEqual(rows[1].icon, "shippingbox.fill")
        XCTAssertEqual(rows[1].label, "node_modules: projectA")
        XCTAssertEqual(
            rows[1].evidence, "node_modules of projectA — ~/dev/projectA"
        )

        // Sizes are the component-sum bytes through the shared formatter.
        XCTAssertEqual(
            rows[0].formattedSize,
            ByteCountFormatter.sharedFile.string(fromByteCount: 4096)
        )
        XCTAssertEqual(
            rows[1].formattedSize,
            ByteCountFormatter.sharedFile.string(fromByteCount: 8192)
        )
    }

    // MARK: - .commands Move-to-Trash disclosure (R1, epic contract)

    func testCommandsTrashDisclosureNamesOnlyCommandBackedItems() throws {
        let commandItem = perItem(
            scanner: "sims", id: "sim-devices", name: "Simulator Devices",
            action: .commands([["xcrun", "simctl", "delete", "unavailable"]])
        )
        let deletionItem = perItem(id: "abc", name: "projectA")
        let aggregateItem = aggregate(name: "npm-cache")

        let disclosure = try XCTUnwrap(
            CacheoutViewModel.commandsTrashDisclosure(
                selectedItems: [aggregateItem, commandItem, deletionItem]
            ),
            "a command-backed selection must produce a disclosure"
        )

        XCTAssertTrue(disclosure.contains("Simulator Devices"),
                      "the command-backed item is named")
        XCTAssertFalse(disclosure.contains("projectA"),
                       "deletion-cleaned neighbors are NEVER named")
        XCTAssertFalse(disclosure.contains("npm-cache"),
                       "aggregate deletion items are NEVER named")
        XCTAssertTrue(disclosure.contains("Move to Trash does not apply"),
                      "the disclosure says what the toggle does not cover")
    }

    func testCommandsTrashDisclosurePresentForCommandsOnlySelection() throws {
        let first = perItem(
            scanner: "sims", id: "a", name: "Simulator Devices",
            action: .commands([["true"]])
        )
        let second = perItem(
            scanner: "docker", id: "b", name: "Docker Images",
            action: .commands([["true"]])
        )

        let disclosure = try XCTUnwrap(
            CacheoutViewModel.commandsTrashDisclosure(
                selectedItems: [first, second]
            )
        )
        XCTAssertTrue(disclosure.contains("Simulator Devices"))
        XCTAssertTrue(disclosure.contains("Docker Images"))
    }

    func testCommandsTrashDisclosureNilWithoutCommandBackedSelection() {
        XCTAssertNil(
            CacheoutViewModel.commandsTrashDisclosure(selectedItems: [
                aggregate(name: "npm-cache"),
                perItem(id: "abc", name: "projectA"),
            ]),
            "no command-backed item selected → no disclosure"
        )
        XCTAssertNil(
            CacheoutViewModel.commandsTrashDisclosure(selectedItems: []),
            "empty selection → no disclosure"
        )
    }

    // MARK: - Caution/partiallyDenied warnings from unified items (fn-1.4 parity)

    /// The caution warning arms from the UNIFIED selection surface — a
    /// caution-risk per-item scanner row (not a category aggregate) must
    /// fire it. Drives the hermetic view model through the SAME `handle`
    /// event path production uses. (`.partiallyDenied` parity is pinned in
    /// `ScanPresentationTests.testToggleSelectionRefusesDeniedAllowsPartiallyDenied`.)
    @MainActor
    func testCautionWarningFiresFromUnifiedPerItemSelection() throws {
        let provider = FileSystemIdentityProvider()
        let runtime = try SpaceScannerRuntime(
            scanners: [
                CategoryScanner(
                    categories: [],
                    scanner: CacheScanner(home: fixtureHome, provider: provider)
                ),
                NodeModulesScanner(
                    home: fixtureHome, searchRoots: [], provider: provider
                ),
            ],
            categories: [],
            home: fixtureHome,
            provider: provider
        )
        let viewModel = CacheoutViewModel(runtime: runtime)

        let cautionRow = perItem(
            scanner: NodeModulesScanner.registeredID,
            id: "abc", name: "projectA", risk: .caution,
            evidence: "node_modules of projectA — ~/dev/projectA"
        )
        viewModel.handle(.outcome(
            scannerID: NodeModulesScanner.registeredID,
            ScanOutcome(items: [cautionRow], errors: [])
        ))

        XCTAssertFalse(viewModel.hasCautionSelection,
                       "nothing selected yet — no warning")
        viewModel.toggleSelection(for: cautionRow.key)
        XCTAssertTrue(viewModel.hasCautionSelection,
                      "a caution-risk per-item row must arm the sheet warning")

        // The instance itemization mirrors the unified selection: the
        // selected per-item row renders with its evidence line.
        XCTAssertEqual(viewModel.confirmationRows.map(\.id), [cautionRow.key])
        XCTAssertEqual(
            viewModel.confirmationRows[0].evidence,
            "node_modules of projectA — ~/dev/projectA"
        )
    }

    // MARK: - Report sheet: per-scanner rollup sections (R1)

    func testScannerSectionsGroupEntriesByScannerWithRollups() {
        // Interleaved on purpose: grouping is by scannerID in FIRST-
        // APPEARANCE order, entries keep report order within each section.
        let report = CleanupReport(
            disposal: .permanent,
            entries: [
                entry(scanner: "categories", id: "npm-cache",
                      name: "npm-cache", exact: 1024),
                entry(scanner: "node_modules", id: "abc",
                      name: "projectA", exact: 4096, estimated: 512),
                entry(scanner: "categories", id: "pip-cache",
                      name: "pip-cache", exact: 2048),
            ],
            errors: []
        )

        let sections = report.scannerSections
        XCTAssertEqual(sections.map(\.scannerID), ["categories", "node_modules"],
                       "first-appearance order, one section per scanner")

        XCTAssertEqual(sections[0].entries.map(\.displayName),
                       ["npm-cache", "pip-cache"],
                       "entries keep report order within their section")
        XCTAssertEqual(sections[0].rollup.exactBytes, 1024 + 2048,
                       "rollup is the pure sum of the section's entries")
        XCTAssertEqual(sections[0].rollup.estimatedUpToBytes, 0)
        XCTAssertEqual(sections[0].rollup.entryCount, 2)

        XCTAssertEqual(sections[1].entries.map(\.displayName), ["projectA"])
        XCTAssertEqual(sections[1].rollup.exactBytes, 4096)
        XCTAssertEqual(sections[1].rollup.estimatedUpToBytes, 512)

        // The section header text is the same R16 component phrase the
        // entry rows use — estimates stay hedged, never laundered.
        XCTAssertEqual(
            sections[0].rollup.componentSummary,
            CleanupReport.componentPhrase(exact: 3072, estimatedUpTo: 0)
        )
        XCTAssertEqual(
            sections[1].rollup.componentSummary,
            CleanupReport.componentPhrase(exact: 4096, estimatedUpTo: 512)
        )
    }

    func testReportTotalsAndRollupsSaturateInsteadOfTrapping() {
        // Round 8: report entries cross scanners, and the runtime
        // validator bounds each scanner's outcome only individually —
        // every derived report sum must clamp at Int64.max, never trap
        // mid-render.
        let report = CleanupReport(
            disposal: .permanent,
            entries: [
                entry(scanner: "scanner_a", id: "a", name: "a", exact: .max),
                entry(scanner: "scanner_b", id: "b", name: "b",
                      exact: .max, estimated: .max),
            ],
            errors: []
        )

        XCTAssertEqual(report.totalFreedExact, Int64.max,
                       "the report-wide exact total clamps")
        XCTAssertEqual(report.totalEstimatedUpTo, Int64.max)
        XCTAssertEqual(report.entries[1].bytesFreed, Int64.max,
                       "the per-entry compatibility sum clamps too")
        XCTAssertEqual(report.scannerRollups.map(\.bytesFreed),
                       [Int64.max, Int64.max],
                       "rollup sums and their compatibility sums clamp")
        XCTAssertFalse(report.headline.isEmpty,
                       "the amount phrase renders from clamped sums")
    }

    // MARK: - Vanished failed item renders from the ItemError record alone (R1)

    func testVanishedFailedItemRendersFromItemErrorRecordAlone() {
        // The failed item's key references a scanner/item that exists in NO
        // entry, NO rescan, nowhere — by construction there is nothing to
        // look up. Rendering must come from the self-contained record.
        let vanished = CleanupReport.ItemError(
            key: ItemKey(scannerID: "node_modules", itemID: "gone-forever"),
            displayName: "projectGone",
            message: "Directory was removed mid-clean"
        )
        let report = CleanupReport(
            disposal: .permanent, entries: [], errors: [vanished]
        )

        XCTAssertEqual(
            report.errorLines,
            ["projectGone: Directory was removed mid-clean"],
            "name and message render from the record alone — no lookup, no crash"
        )

        // fn-1.4 honesty preserved around it: nothing succeeded, so the
        // headline claims no success.
        XCTAssertEqual(report.headline, "Nothing cleaned — every item failed")
        XCTAssertTrue(report.scannerSections.isEmpty,
                      "no entries → no rollup sections")
    }

    /// Several error lines for one item stay distinct (positional identity
    /// in the sheet) and total-failure honesty holds with MULTIPLE records.
    func testMultipleErrorLinesForOneItemAllRender() {
        let key = ItemKey(scannerID: "categories", itemID: "npm-cache")
        let report = CleanupReport(
            disposal: .trash,
            entries: [],
            errors: [
                CleanupReport.ItemError(
                    key: key, displayName: "npm-cache", message: "child A failed"
                ),
                CleanupReport.ItemError(
                    key: key, displayName: "npm-cache", message: "child B failed"
                ),
            ]
        )
        XCTAssertEqual(report.errorLines, [
            "npm-cache: child A failed",
            "npm-cache: child B failed",
        ])
        XCTAssertEqual(report.headline, "Nothing cleaned — every item failed")
    }
}
