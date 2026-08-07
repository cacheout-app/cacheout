import XCTest
import Darwin
@testable import Cacheout

/// fn-1.4 presentation-layer tests (R6/R8/R9/R11/R14/R16/R18).
///
/// SwiftUI views are not unit-testable — the model and view-model surfaces
/// the views render from are the assertion targets: `statusLabel`, selection
/// defaults and guards, the D8 caveat constant, component-derived
/// `CleanupReport` rendering, the `ScanError.Kind` wire mapping, the CLI
/// scan-JSON payload, and the TCC scan-trigger gating.
///
/// View-model tests run hermetically: injected fixture-home scanners, an
/// empty category registry, zero reads of the real `$HOME`. chmod-000
/// fixtures restore 0755 before teardown and skip under euid 0.
final class ScanPresentationTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("ScanPresentationTests-\(UUID().uuidString)")
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
        defaultSelected: Bool = true
    ) -> CacheCategory {
        CacheCategory(
            name: name,
            slug: name,
            description: "test",
            icon: "trash",
            discovery: [.absolutePath("/nonexistent-fixture-\(name)")],
            riskLevel: risk,
            rebuildNote: "rebuilds",
            defaultSelected: defaultSelected
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

    /// Hermetic view model (fn-2.4): a fixture-home RUNTIME — empty category
    /// registry, injected search roots, zero reads of the real `$HOME`. The
    /// cleaner is runtime-constructed, exactly as production composes it.
    @MainActor
    private func makeViewModel(
        searchRoots: [URL] = []
    ) throws -> CacheoutViewModel {
        let provider = FileSystemIdentityProvider()
        let runtime = try SpaceScannerRuntime(
            scanners: [
                CategoryScanner(
                    categories: [],
                    scanner: CacheScanner(home: fixtureHome, provider: provider)
                ),
                NodeModulesScanner(
                    home: fixtureHome, searchRoots: searchRoots,
                    provider: provider
                ),
            ],
            categories: [],
            home: fixtureHome,
            provider: provider
        )
        return CacheoutViewModel(runtime: runtime)
    }

    /// Seeds category-aggregate state through the SAME reconciliation path
    /// production uses (`handle` is `scan()`'s per-event entry point) —
    /// aggregate items built by the one real mapping, never a parallel
    /// construction.
    @MainActor
    private func seedCategories(
        _ viewModel: CacheoutViewModel, results: [ScanResult]
    ) {
        viewModel.handle(.outcome(
            scannerID: CategoryScanner.registeredID,
            ScanOutcome(
                items: results.map { CategoryScanner.item(from: $0) },
                errors: []
            )
        ))
    }

    private func categoryKey(_ slug: String) -> ItemKey {
        ItemKey(scannerID: CategoryScanner.registeredID, itemID: slug)
    }

    // MARK: - statusLabel (R6 presentation)

    func testStatusLabelsAreDistinctForAllNonMeasuredStates() {
        let states: [ScanState] = [.missing, .empty, .partiallyDenied, .denied]
        let labels = states.map { makeResult(state: $0).statusLabel }

        for (state, label) in zip(states, labels) {
            XCTAssertNotNil(label, "\(state) must carry a status label")
        }
        XCTAssertEqual(
            Set(labels.compactMap { $0 }).count, states.count,
            "labels must be pairwise distinct — a TCC denial must never read as 'Not found' (D6): \(labels)"
        )
        XCTAssertNil(makeResult(state: .measured, exact: 1024, items: 1).statusLabel,
                     "measured rows show the category description, not a status")
    }

    func testDeniedLabelNeverClaimsNotFoundOrEmpty() throws {
        let denied = try XCTUnwrap(makeResult(state: .denied).statusLabel)
        XCTAssertFalse(denied.localizedCaseInsensitiveContains("not found"))
        XCTAssertFalse(denied.localizedCaseInsensitiveContains("empty"))
        XCTAssertTrue(denied.localizedCaseInsensitiveContains("denied"))
    }

    // MARK: - Selection defaults (R18)

    func testDeniedAndPartiallyDeniedAreNeverAutoSelected() {
        // defaultSelected + bytes present — everything EXCEPT state says
        // "select me".
        let denied = makeResult(state: .denied)
        XCTAssertFalse(denied.isSelected, ".denied is unselectable")

        let partial = makeResult(state: .partiallyDenied, exact: 4096, items: 1)
        XCTAssertFalse(partial.isSelected, ".partiallyDenied is never auto-selected")

        let measured = makeResult(state: .measured, exact: 4096, items: 1)
        XCTAssertTrue(measured.isSelected, "clean measured default preserved")

        XCTAssertFalse(makeResult(state: .measured).isSelected,
                       "zero-byte measured stays unselected")
        XCTAssertFalse(makeResult(state: .missing).isSelected)
    }

    @MainActor
    func testToggleSelectionRefusesDeniedAllowsPartiallyDenied() throws {
        let viewModel = try makeViewModel()
        let denied = makeResult(
            state: .denied, category: makeCategory(name: "denied-cat"),
            scanError: ScanError(kind: .tccDenied, message: "denied")
        )
        let partial = makeResult(
            state: .partiallyDenied, category: makeCategory(name: "partial-cat"),
            exact: 4096, items: 1,
            scanError: ScanError(kind: .permissionDenied, message: "partial")
        )
        seedCategories(viewModel, results: [denied, partial])

        viewModel.toggleSelection(for: categoryKey("denied-cat"))
        XCTAssertFalse(viewModel.selectedItemKeys.contains(categoryKey("denied-cat")),
                       ".denied must not be selectable from the UI (R18)")
        XCTAssertFalse(viewModel.categoryRows[0].result.isSelected,
                       "the row projection must agree")

        viewModel.toggleSelection(for: categoryKey("partial-cat"))
        XCTAssertTrue(viewModel.selectedItemKeys.contains(categoryKey("partial-cat")),
                      "explicit manual toggle of .partiallyDenied is allowed")
        XCTAssertTrue(viewModel.hasPartiallyDeniedSelection,
                      "the confirmation sheet warning must arm")

        viewModel.toggleSelection(for: categoryKey("partial-cat"))
        XCTAssertFalse(viewModel.hasPartiallyDeniedSelection)
    }

    @MainActor
    func testSelectAllSafeSkipsDeniedAndPartiallyDenied() throws {
        let viewModel = try makeViewModel()
        // defaultSelected: false so any true below came from selectAllSafe.
        let safeMeasured = makeResult(
            state: .measured,
            category: makeCategory(name: "safe-measured", defaultSelected: false),
            exact: 4096, items: 1
        )
        let safePartial = makeResult(
            state: .partiallyDenied,
            category: makeCategory(name: "safe-partial", defaultSelected: false),
            exact: 4096, items: 1,
            scanError: ScanError(kind: .permissionDenied, message: "partial")
        )
        let safeDenied = makeResult(
            state: .denied,
            category: makeCategory(name: "safe-denied", defaultSelected: false),
            scanError: ScanError(kind: .tccDenied, message: "denied")
        )
        let reviewMeasured = makeResult(
            state: .measured,
            category: makeCategory(name: "review-measured", risk: .review, defaultSelected: false),
            exact: 4096, items: 1
        )
        seedCategories(viewModel, results: [safeMeasured, safePartial, safeDenied, reviewMeasured])

        viewModel.selectAllSafe()

        XCTAssertEqual(viewModel.selectedItemKeys, [categoryKey("safe-measured")],
                       "safe .measured is auto-selected; .partiallyDenied is excluded from "
                       + "the auto path (smart-clean), .denied stays unselected, non-safe "
                       + "risk untouched")
    }

    @MainActor
    func testTotalRecoverableExcludesDenied() throws {
        let viewModel = try makeViewModel()
        seedCategories(viewModel, results: [
            makeResult(state: .measured, category: makeCategory(name: "m"),
                       exact: 4096, items: 1),
            makeResult(state: .partiallyDenied, category: makeCategory(name: "p"),
                       exact: 2048, items: 1,
                       scanError: ScanError(kind: .permissionDenied, message: "x")),
            makeResult(state: .denied, category: makeCategory(name: "d"),
                       scanError: ScanError(kind: .tccDenied, message: "x")),
        ])

        XCTAssertEqual(viewModel.totalRecoverable, 4096 + 2048,
                       "denied contributes nothing; partiallyDenied contributes its measured floor")
    }

    // MARK: - D8 caveat (R8)

    func testOvercountCaveatDisclosesClonesAndCrossCategoryHardlinks() {
        let caveat = DiskSpaceCaveat.overcount
        XCTAssertTrue(caveat.contains("APFS clones"),
                      "must disclose the clone mechanism (invisible to any API)")
        XCTAssertTrue(caveat.contains("hardlinked across categories"),
                      "must disclose cross-category hardlinks (out of scope for within-walk dedupe)")
    }

    @MainActor
    func testViewModelExposesCaveatBesideRecoverableTotal() throws {
        XCTAssertEqual(try makeViewModel().overcountCaveat, DiskSpaceCaveat.overcount)
    }

    // MARK: - Component-derived rendering (R11/R16)

    func testComponentPhraseFormats() {
        let format = ByteCountFormatter.sharedFile
        XCTAssertEqual(
            CleanupReport.componentPhrase(exact: 4096, estimatedUpTo: 0),
            format.string(fromByteCount: 4096),
            "exact-only renders the plain amount"
        )
        XCTAssertEqual(
            CleanupReport.componentPhrase(exact: 4096, estimatedUpTo: 2048),
            "\(format.string(fromByteCount: 4096)) + up to \(format.string(fromByteCount: 2048)) more",
            "estimates are hedged, never folded into the exact number"
        )
        XCTAssertEqual(
            CleanupReport.componentPhrase(exact: 0, estimatedUpTo: 2048),
            "up to \(format.string(fromByteCount: 2048))",
            "estimate-only renders as a ceiling"
        )
    }

    func testHeadlineDerivesFromComponentsPerDisposal() {
        let format = ByteCountFormatter.sharedFile
        let phrase = "\(format.string(fromByteCount: 4096)) + up to \(format.string(fromByteCount: 2048)) more"

        let permanent = CleanupReport(
            disposal: .permanent,
            entries: [CleanupReport.Entry(
                itemID: "c", scannerID: "categories", displayName: "c", exactBytes: 4096, estimatedUpToBytes: 2048,
                disposal: .permanent
            )],
            errors: []
        )
        XCTAssertEqual(permanent.headline, "Freed \(phrase)")

        let trashed = CleanupReport(
            disposal: .trash,
            entries: [CleanupReport.Entry(
                itemID: "c", scannerID: "categories", displayName: "c", exactBytes: 4096, estimatedUpToBytes: 2048,
                disposal: .trash
            )],
            errors: []
        )
        XCTAssertEqual(trashed.headline,
                       "Moved \(phrase) to Trash — empty Trash to reclaim")

        let estimateOnly = CleanupReport(
            disposal: .permanent,
            entries: [CleanupReport.Entry(
                itemID: "c", scannerID: "categories", displayName: "c", exactBytes: 0, estimatedUpToBytes: 2048,
                disposal: .permanent
            )],
            errors: []
        )
        XCTAssertEqual(estimateOnly.headline,
                       "Freed up to \(format.string(fromByteCount: 2048))")

        // P2: a Trash-mode run mixing a trashed category with a
        // command-erased one renders both parts — command bytes are never
        // claimed recoverable from the Trash.
        let mixed = CleanupReport(
            disposal: .trash,
            entries: [
                CleanupReport.Entry(
                    itemID: "cache", scannerID: "categories", displayName: "cache", exactBytes: 4096, estimatedUpToBytes: 0,
                    disposal: .trash
                ),
                CleanupReport.Entry(
                    itemID: "sim", scannerID: "categories", displayName: "sim", exactBytes: 0, estimatedUpToBytes: 2048,
                    disposal: .permanent
                ),
            ],
            errors: []
        )
        XCTAssertEqual(
            mixed.headline,
            "Freed up to \(format.string(fromByteCount: 2048)); "
                + "moved \(format.string(fromByteCount: 4096)) to Trash — empty Trash to reclaim"
        )

        let allFailed = CleanupReport(
            disposal: .permanent, entries: [],
            errors: [CleanupReport.ItemError(
                key: ItemKey(scannerID: "categories", itemID: "c"),
                displayName: "c", message: "boom"
            )]
        )
        XCTAssertEqual(allFailed.headline, "Nothing cleaned — every item failed",
                       "no success claim when everything failed (R11)")
    }

    func testEntryComponentSummaryMatchesPhrase() {
        let entry = CleanupReport.Entry(
            itemID: "c", scannerID: "categories", displayName: "c", exactBytes: 8192, estimatedUpToBytes: 1024,
            disposal: .permanent
        )
        XCTAssertEqual(
            entry.componentSummary,
            CleanupReport.componentPhrase(exact: 8192, estimatedUpTo: 1024)
        )
    }

    // MARK: - Wire mapping + scan JSON (R6/R16)

    func testScanErrorKindWireStringsAreStable() {
        XCTAssertEqual(ScanError.Kind.admissionRefused.wireString, "admission_refused")
        XCTAssertEqual(ScanError.Kind.tccDenied.wireString, "tcc_denied")
        XCTAssertEqual(ScanError.Kind.permissionDenied.wireString, "permission_denied")
        XCTAssertEqual(ScanError.Kind.other.wireString, "other")
    }

    func testScanItemJSONCleanCategoryCarriesComponentsAndNoError() throws {
        let clean = makeResult(state: .measured, exact: 4096, estimated: 512, items: 3)
        let json = CLIHandler.scanItemJSON(for: clean)

        XCTAssertEqual(json["state"] as? String, "measured")
        XCTAssertEqual(json["exact_bytes"] as? Int64, 4096)
        XCTAssertEqual(json["estimated_up_to_bytes"] as? Int64, 512)
        XCTAssertEqual(json["size_bytes"] as? Int64, 4096 + 512,
                       "size_bytes stays the compatibility sum")
        XCTAssertNil(json["scan_error"], "clean categories carry no scan_error key")
        XCTAssertNil(json["grant_hint"])
        // Untouched schema-v2 fields survive.
        XCTAssertEqual(json["slug"] as? String, "test-cache")
        XCTAssertEqual(json["exists"] as? Bool, true)
    }

    func testScanItemJSONTccDenialCarriesErrorAndGrantHint() throws {
        let denied = makeResult(
            state: .denied,
            scanError: ScanError(kind: .tccDenied, message: "operation not permitted")
        )
        let json = CLIHandler.scanItemJSON(for: denied)

        XCTAssertEqual(json["state"] as? String, "denied")
        let scanError = try XCTUnwrap(json["scan_error"] as? [String: Any])
        XCTAssertEqual(scanError["kind"] as? String, "tcc_denied")
        XCTAssertEqual(scanError["message"] as? String, "operation not permitted")
        let hint = try XCTUnwrap(json["grant_hint"] as? String,
                                 "TCC denial is silent in a CLI — the JSON must carry the remedy (R9)")
        XCTAssertTrue(hint.contains("Full Disk Access"))
    }

    func testScanItemJSONNonTccDenialCarriesErrorWithoutGrantHint() throws {
        let denied = makeResult(
            state: .partiallyDenied, exact: 2048, items: 1,
            scanError: ScanError(kind: .permissionDenied, message: "permission denied")
        )
        let json = CLIHandler.scanItemJSON(for: denied)

        let scanError = try XCTUnwrap(json["scan_error"] as? [String: Any])
        XCTAssertEqual(scanError["kind"] as? String, "permission_denied")
        XCTAssertNil(json["grant_hint"],
                     "System Settings cannot fix BSD permissions — no hint that cannot help")
    }

    func testFullDiskAccessSettingsURLAnchor() {
        XCTAssertEqual(
            ScanError.fullDiskAccessSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }

    // MARK: - Whole-window scan guards (R11)

    @MainActor
    func testIsAnyScanInProgressCoversEveryPendingScanner() throws {
        let viewModel = try makeViewModel()
        XCTAssertFalse(viewModel.isAnyScanInProgress)

        // The category scanner reports in seconds while node_modules keeps
        // running 10–30s longer — ANY pending scanner must read as scanning.
        viewModel.scanningScannerIDs = [NodeModulesScanner.registeredID]
        XCTAssertTrue(viewModel.isAnyScanInProgress)
        XCTAssertFalse(viewModel.shouldAutoRescan,
                       "an in-flight scan must never trigger an auto-rescan")

        viewModel.scanningScannerIDs = [CategoryScanner.registeredID]
        XCTAssertTrue(viewModel.isAnyScanInProgress)
    }

    @MainActor
    func testCleanRefusedWhileAnyScannerStillPending() async throws {
        let viewModel = try makeViewModel()
        // categories already reported; node_modules still pending
        viewModel.scanningScannerIDs = [NodeModulesScanner.registeredID]

        await viewModel.clean()

        XCTAssertNil(viewModel.lastReport,
                     "clean must not run against a half-built result set (R11)")
        XCTAssertFalse(viewModel.showCleanupReport)
        XCTAssertFalse(viewModel.isCleaning)
    }

    @MainActor
    func testScanReentrancyRefusedWhileAnyScannerPending() async throws {
        let viewModel = try makeViewModel()
        viewModel.scanningScannerIDs = [NodeModulesScanner.registeredID]

        await viewModel.scan(trigger: .userInitiated)

        XCTAssertFalse(viewModel.hasScanned,
                       "an overlapping scan must be refused, not raced")
        XCTAssertEqual(viewModel.scanGeneration, 0)
    }

    @MainActor
    func testScanRefusedWhileCleaning() async throws {
        let viewModel = try makeViewModel()
        viewModel.isCleaning = true

        await viewModel.scan(trigger: .userInitiated)

        XCTAssertFalse(viewModel.hasScanned,
                       "scanning during a cleanup would publish results mid-deletion")
        XCTAssertFalse(viewModel.shouldAutoRescan,
                       "auto-rescan must also hold off during cleanup")
    }

    @MainActor
    func testSmartCleanExcludesManuallySelectedPartiallyDenied() async throws {
        // Real fixture payloads: the assertion is on the FILESYSTEM — a
        // manually selected .partiallyDenied category must survive Quick
        // Clean untouched (R18: the auto path excludes it).
        let safeRoot = base.appendingPathComponent("safe-cache")
        let partialRoot = base.appendingPathComponent("partial-cache")
        try fm.createDirectory(at: safeRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: partialRoot, withIntermediateDirectories: true)
        let safePayload = safeRoot.appendingPathComponent("data.bin")
        let partialPayload = partialRoot.appendingPathComponent("data.bin")
        try Data(repeating: 0xAB, count: 4096).write(to: safePayload)
        try Data(repeating: 0xAB, count: 4096).write(to: partialPayload)

        func fixtureCategory(_ name: String, at url: URL) -> CacheCategory {
            CacheCategory(
                name: name, slug: name, description: "test", icon: "trash",
                discovery: [.absolutePath(url.path)],
                riskLevel: .safe, rebuildNote: "", defaultSelected: false
            )
        }

        let viewModel = try makeViewModel()
        viewModel.moveToTrash = false  // permanent delete, fixture-contained
        // Real scan-time-shaped root records — the unified cleaner deletes
        // only what the scan captured (root-snapshot rule).
        let provider = FileSystemIdentityProvider()
        func record(at url: URL) -> RootScanRecord {
            RootScanRecord(
                requestedURL: url,
                resolvedURL: provider.canonicalize(url),
                status: .measured
            )
        }
        let safe = ScanResult(
            category: fixtureCategory("safe-measured", at: safeRoot),
            state: .measured, exactBytes: 4096, estimatedUpToBytes: 0,
            itemCount: 1, scanError: nil,
            rootRecords: [record(at: safeRoot)]
        )
        let partial = ScanResult(
            category: fixtureCategory("partial-denied", at: partialRoot),
            state: .partiallyDenied, exactBytes: 4096, estimatedUpToBytes: 0,
            itemCount: 1,
            scanError: ScanError(kind: .permissionDenied, message: "partial"),
            rootRecords: [record(at: partialRoot)]
        )
        seedCategories(viewModel, results: [safe, partial])
        // Manual selection made BEFORE Quick Clean.
        viewModel.toggleSelection(for: categoryKey("partial-denied"))
        XCTAssertTrue(viewModel.selectedItemKeys.contains(categoryKey("partial-denied")))

        await viewModel.smartClean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.entries.map(\.displayName), ["safe-measured"],
                       "Quick Clean acts on the auto-selected safe set only")
        XCTAssertTrue(fm.fileExists(atPath: partialPayload.path),
                      "a manually selected .partiallyDenied category must NOT ride into the auto path (R18)")
        XCTAssertFalse(fm.fileExists(atPath: safePayload.path),
                       "the auto-selected safe category IS cleaned")
    }

    // MARK: - node_modules issues in the view model (R14) + TCC gating (R9)

    @MainActor
    func testDeniedSearchRootIssueVisibleOnUserInitiatedScanOnly() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        // A protected-named fixture root that is also unreadable: the
        // user-initiated scan must SURFACE the denial (never an empty
        // section), the automatic scan must not touch the root at all.
        let docs = fixtureHome.appendingPathComponent("Documents")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: docs.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docs.path)
        }

        let viewModel = try makeViewModel(searchRoots: [docs])
        let nm = NodeModulesScanner.registeredID

        await viewModel.scan(trigger: .userInitiated)
        XCTAssertFalse(viewModel.issues(forScanner: nm).isEmpty,
                       "the denied root must be visible in the view model (R14)")
        XCTAssertTrue(
            viewModel.issues(forScanner: nm).allSatisfy { $0.kind == .permissionDenied },
            "unexpected classification: \(viewModel.issues(forScanner: nm))"
        )
        XCTAssertTrue(viewModel.items(forScanner: nm).isEmpty)

        await viewModel.scan(trigger: .automatic)
        XCTAssertTrue(viewModel.issues(forScanner: nm).isEmpty,
                      "automatic scans skip protected roots — nothing walked, nothing to report (R9)")
    }

    @MainActor
    func testUserInitiatedScanIncludesProtectedRootFindings() async throws {
        // Readable protected-named root with a real project: user-initiated
        // finds it; automatic skips it (trigger plumbing end-to-end).
        let docs = fixtureHome.appendingPathComponent("Documents")
        let dep = docs.appendingPathComponent("proj/node_modules/dep")
        try fm.createDirectory(at: dep, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 4096)
            .write(to: dep.appendingPathComponent("index.js"))

        let viewModel = try makeViewModel(searchRoots: [docs])
        let nm = NodeModulesScanner.registeredID

        await viewModel.scan(trigger: .automatic)
        XCTAssertTrue(viewModel.items(forScanner: nm).isEmpty,
                      "automatic scans never enumerate protected roots (R9)")
        XCTAssertTrue(viewModel.issues(forScanner: nm).isEmpty,
                      "a policy skip is not a scan problem")

        await viewModel.scan(trigger: .userInitiated)
        XCTAssertEqual(viewModel.items(forScanner: nm).map(\.displayName), ["proj"],
                       "user-initiated scans include protected roots (R9)")
    }
}
