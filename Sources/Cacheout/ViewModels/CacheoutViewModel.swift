/// # CacheoutViewModel — Main Application State
///
/// The central `@MainActor` view model that manages all application state and
/// coordinates between the scanning, cleaning, and UI layers.
///
/// ## Scanner registry (fn-2.4)
///
/// The twin stacks (`scanResults` + `nodeModulesItems` with duplicate
/// selection/total/clean helpers) are gone. The view model consumes the
/// `SpaceScannerRuntime`'s PROGRESSIVE VALIDATED EVENT STREAM and keeps ONE
/// selection/totals/clean model over `ReclaimableItem`:
///
/// - `outcomesByScannerID`: each scanner's latest VALIDATED outcome,
///   reconciled per-scanner as events arrive (progressive publishing — the
///   category scanner lands in ~2-5s, slower scanners later).
/// - `selectedItemKeys: Set<ItemKey>`: the one selection surface, keyed by
///   the composite cross-scanner identity. Selection SURVIVES rescans (this
///   fixes a live defect — node_modules items minted `UUID()` ids per scan,
///   so their selection reset on every rescan).
/// - The runtime owns orchestration and validation; this view model owns
///   presentation and reconciliation ONLY — no local TaskGroup, no direct
///   scanner calls, no `validatedOutcome` calls, no downcasts.
///
/// ## Reconciliation contract (epic rounds 5-10)
///
/// - A valid outcome reconciles ONLY its own scanner's entry — other
///   scanners' items and selections are never touched by it.
/// - Previously-emitted keys keep their user-set state, selected AND
///   deselected — an explicit deselection is user intent and a rescan must
///   never resurrect it. `defaultSelected` applies ONLY to a key's FIRST
///   emission in this session.
/// - Selections for VANISHED keys are pruned when the stream COMPLETES,
///   never mid-scan — a selection on scanner A must not vanish because
///   scanner B's event landed first.
/// - A `malformedOutcome` event is fail-closed: nothing published for that
///   scanner, the path-less issue surfaced, previous items and selections
///   RETAINED. Validation itself lives in the runtime, never here.
///
/// ## Selection policies (THREE, deliberately separate — epic contract)
///
/// (a) INITIAL selection = `defaultSelected`, first emission only.
/// (b) Quick Clean / `selectAllSafe` = `automaticCleanEligible && risk ==
///     .safe` on cleanly measured items — `defaultSelected` deliberately NOT
///     consulted (today's selectAllSafe ignores it).
/// (c) Smart-clean is EXCLUSIVELY the CLI's (fn-2.6). The GUI NEVER runs it
///     and never auto-selects review-risk; GUI code is PROHIBITED from
///     invoking the CLI's candidate-order helper.
///
/// `.denied`, `.empty`, and `.missing` items are UNSELECTABLE in every
/// surface — nothing to clean (round 9).
///
/// ## Persistence
///
/// User preferences are stored in `UserDefaults` via `didSet` observers:
/// `scanIntervalMinutes`, `lowDiskThresholdGB`, `launchAtLogin`,
/// `moveToTrash`. Untouched by unification, as are Docker prune, disk info,
/// and the memory subsystem.

import Foundation
import SwiftUI

// `ScanTrigger` lives in Scanner/SpaceScanner.swift (fn-2.1): the scanner
// layer consumes it via `ScanContext`, so the declaration must not live in
// this SwiftUI-importing file.

// MARK: - Presentation row models

/// One category aggregate presented through the UNCHANGED `CategoryRow`
/// inputs (fn-2.4): the row still consumes a `ScanResult`, rebuilt from the
/// aggregate `ReclaimableItem`'s carried category + state + components, with
/// `isSelected` projected from the one selection set. List identity is the
/// composite `key`, never `ScanResult.id` (a per-launch category UUID).
struct CategoryRowModel: Identifiable {
    let key: ItemKey
    let result: ScanResult
    var id: ItemKey { key }
}

/// One per-item scanner's section (every scanner except the aggregate
/// category adapter): header identity, its items in outcome order, its
/// root/scanner-level issues (including a synthesized `malformedOutcome`
/// issue when the last event was malformed), and its pending state.
struct ScannerSectionModel: Identifiable {
    let scannerID: String
    let displayName: String
    let items: [ReclaimableItem]
    let issues: [ScanIssue]
    let isScanning: Bool
    var id: String { scannerID }

    /// "Select Stale" renders only where staleness applies to at least one
    /// item (`isStale == nil` = control hidden/inapplicable).
    var supportsStaleness: Bool { items.contains { $0.isStale != nil } }
}

@MainActor
class CacheoutViewModel: ObservableObject {

    // MARK: - Unified scan state (fn-2.4)

    /// Each scanner's latest VALIDATED outcome. A malformed event never
    /// lands here — the previous outcome is retained (fail-closed).
    @Published private(set) var outcomesByScannerID: [String: ScanOutcome] = [:]

    /// THE selection surface — composite `ItemKey`s only (a bare item id is
    /// unique only within one scanner and is never a key here).
    @Published private(set) var selectedItemKeys: Set<ItemKey> = []

    /// Scanners whose event has not arrived in the current scan. Replaces
    /// the split `isScanning`/`isNodeModulesScanning` with per-scanner
    /// state. Internal-settable so tests can pin mid-scan windows.
    @Published var scanningScannerIDs: Set<String> = []

    /// The synthesized path-less issue for a scanner whose LAST event was
    /// `malformedOutcome` — surfaced beside the retained previous items,
    /// cleared when a valid outcome arrives (fail-closed disposition).
    @Published private(set) var malformedIssuesByScannerID: [String: ScanIssue] = [:]

    /// Each scanner's ever-emitted key set for THIS session. `defaultSelected`
    /// applies only to keys absent from here (first emission ever);
    /// previously-emitted keys keep their user-set state across rescans.
    /// Deliberately never pruned: a vanished-then-reappearing key was still
    /// emitted this session, so it does not re-enroll in initial selection.
    private var emittedKeysByScannerID: [String: Set<ItemKey>] = [:]

    @Published var isCleaning = false
    @Published var diskInfo: DiskInfo?
    @Published var showCleanConfirmation = false
    @Published var showCleanupReport = false
    @Published var lastReport: CleanupReport?
    @Published var moveToTrash = true

    /// Increments on every completed scan — views can use .task(id:) to react
    @Published var scanGeneration: Int = 0

    /// Whether at least one scan has completed. Unlike `hasResults`, this
    /// stays `true` even if the scan found zero items, preventing redundant
    /// re-scans when switching tabs.
    @Published var hasScanned = false

    /// When the last scan completed
    @Published var lastScanDate: Date?

    /// User-configurable scan interval in minutes (persisted in UserDefaults)
    @Published var scanIntervalMinutes: Double {
        didSet { UserDefaults.standard.set(scanIntervalMinutes, forKey: "cacheout.scanIntervalMinutes") }
    }

    /// Low-disk notification threshold in GB (persisted in UserDefaults)
    @Published var lowDiskThresholdGB: Double {
        didSet { UserDefaults.standard.set(lowDiskThresholdGB, forKey: "cacheout.lowDiskThresholdGB") }
    }

    /// Whether to launch at login (persisted in UserDefaults)
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "cacheout.launchAtLogin") }
    }

    /// True while ANY scanner's event is still pending (R11). Scan/clean
    /// controls and model guards must cover the WHOLE window — the category
    /// scanner finishes in seconds while node_modules can run 10-30s longer,
    /// and a clean must never act on a half-built result set.
    var isAnyScanInProgress: Bool { !scanningScannerIDs.isEmpty }

    /// Whether the menubar should trigger an auto-rescan (no results or stale data)
    var shouldAutoRescan: Bool {
        if isAnyScanInProgress || isCleaning { return false }
        if !hasResults { return true }
        guard let last = lastScanDate else { return true }
        return Date().timeIntervalSince(last) > scanIntervalMinutes * 60
    }

    /// The ONE composition source (fn-2.1): scanner instances + the cleaner
    /// configuration derived from them. Because `clean()` uses the
    /// runtime-constructed cleaner, a registered scanner's
    /// `trustedContainerRoots` reach delete-time admission with ZERO view
    /// model edits (R4).
    private let runtime: SpaceScannerRuntime
    private let cleaner: CacheCleaner

    /// - Parameter runtime: injectable for hermetic tests (fixture scanners
    ///   and homes — zero real-`$HOME` reads); production uses the one
    ///   production registry. This injection seam is what fn-2.7's zero-edit
    ///   extensibility proof exercises.
    init(runtime: SpaceScannerRuntime = .production()) {
        self.runtime = runtime
        self.cleaner = runtime.makeCleaner()

        let storedInterval = UserDefaults.standard.double(forKey: "cacheout.scanIntervalMinutes")
        self.scanIntervalMinutes = storedInterval > 0 ? storedInterval : 30

        let storedThreshold = UserDefaults.standard.double(forKey: "cacheout.lowDiskThresholdGB")
        self.lowDiskThresholdGB = storedThreshold > 0 ? storedThreshold : 10

        self.launchAtLogin = UserDefaults.standard.bool(forKey: "cacheout.launchAtLogin")
    }

    // MARK: - Item access

    /// Registry order — the stable presentation order for sections and for
    /// the items handed to `clean()`.
    private var orderedScannerIDs: [String] { runtime.scanners.map(\.id) }

    func items(forScanner id: String) -> [ReclaimableItem] {
        outcomesByScannerID[id]?.items ?? []
    }

    func issues(forScanner id: String) -> [ScanIssue] {
        outcomesByScannerID[id]?.errors ?? []
    }

    func item(for key: ItemKey) -> ReclaimableItem? {
        outcomesByScannerID[key.scannerID]?.items.first { $0.id == key.itemID }
    }

    /// The selected items in presentation order (registry order, then each
    /// outcome's own order) — exactly what `clean()` hands the unified entry
    /// and what the confirmation sheet lists.
    var selectedItems: [ReclaimableItem] {
        orderedScannerIDs.flatMap { id in
            items(forScanner: id).filter { selectedItemKeys.contains($0.key) }
        }
    }

    var selectedCount: Int { selectedItemKeys.count }

    var hasResults: Bool {
        outcomesByScannerID.values.contains { !$0.items.isEmpty }
    }

    var hasSelection: Bool { !selectedItemKeys.isEmpty }

    // MARK: - Derived rows (views render these, logic stays testable here)

    /// Category aggregates through the UNCHANGED `CategoryRow` shape. The
    /// aggregate item's admission descriptor carries the registered
    /// `CacheCategory`, so the row model rebuilds fn-1.4's exact inputs;
    /// selection projects from `selectedItemKeys`.
    var categoryRows: [CategoryRowModel] {
        items(forScanner: CategoryScanner.registeredID).compactMap { item in
            guard case .category(let category) = item.admission else {
                // Category-scanner items always carry category provenance
                // (runtime-validated); anything else is unrenderable here.
                return nil
            }
            var result = ScanResult(
                category: category,
                state: item.state,
                exactBytes: item.exactBytes,
                estimatedUpToBytes: item.estimatedUpToBytes,
                itemCount: item.itemCount,
                scanError: item.scanError,
                rootRecords: item.rootRecords
            )
            result.isSelected = selectedItemKeys.contains(item.key)
            return CategoryRowModel(key: item.key, result: result)
        }
    }

    var selectedCategoryRows: [CategoryRowModel] {
        categoryRows.filter { $0.result.isSelected }
    }

    /// The category scanner emits no outcome-level errors by design; this
    /// surfaces only a synthesized `malformedOutcome` (fail-closed, visible).
    var categoryScanIssues: [ScanIssue] {
        var all = issues(forScanner: CategoryScanner.registeredID)
        if let malformed = malformedIssuesByScannerID[CategoryScanner.registeredID] {
            all.append(malformed)
        }
        return all
    }

    /// One generic section per NON-category scanner, in registry order —
    /// the node_modules section generalized (fn-2.4).
    var perItemSections: [ScannerSectionModel] {
        runtime.scanners
            .filter { $0.id != CategoryScanner.registeredID }
            .map { scanner in
                var issues = issues(forScanner: scanner.id)
                if let malformed = malformedIssuesByScannerID[scanner.id] {
                    issues.append(malformed)
                }
                return ScannerSectionModel(
                    scannerID: scanner.id,
                    displayName: scanner.displayName,
                    items: items(forScanner: scanner.id),
                    issues: issues,
                    isScanning: scanningScannerIDs.contains(scanner.id)
                )
            }
    }

    // MARK: - Totals (three FROZEN scopes, one shared helper — epic round 6)

    /// THE aggregation helper: every byte total flows through here with
    /// EXPLICIT predicates — scope (which scanners) and inclusion (which
    /// items) as arguments, never copy-pasted loops.
    private func aggregateBytes(
        scannerScope: (String) -> Bool,
        include: (ReclaimableItem) -> Bool
    ) -> Int64 {
        var total: Int64 = 0
        for (scannerID, outcome) in outcomesByScannerID where scannerScope(scannerID) {
            for item in outcome.items where include(item) {
                total += item.allocatedBytes
            }
        }
        return total
    }

    /// Scope 1 (FROZEN pre-refactor parity): AGGREGATE-CATEGORY items only —
    /// per-item scanners excluded, exactly like the old `scanResults`-only
    /// property. `.denied` contributes nothing by construction; the explicit
    /// filter keeps that true even if a future state carries bytes it cannot
    /// promise (R18). The old `!isEmpty` filter is spelled out as
    /// not-missing + measurable-bytes.
    var totalRecoverable: Int64 {
        aggregateBytes(
            scannerScope: { $0 == CategoryScanner.registeredID },
            include: { $0.state != .missing && $0.state != .denied && $0.allocatedBytes > 0 }
        )
    }

    /// Scope 2: a per-scanner SECTION total stays section-local (the old
    /// `selectedNodeModulesSize`, generalized per scanner id).
    func selectedSize(forScanner id: String) -> Int64 {
        aggregateBytes(
            scannerScope: { $0 == id },
            include: { selectedItemKeys.contains($0.key) }
        )
    }

    func formattedSelectedSize(forScanner id: String) -> String {
        ByteCountFormatter.sharedFile.string(fromByteCount: selectedSize(forScanner: id))
    }

    /// Scope 3: selected bytes across EVERY scanner (the old
    /// `selectedSize + selectedNodeModulesSize`).
    var totalSelectedSize: Int64 {
        aggregateBytes(
            scannerScope: { _ in true },
            include: { selectedItemKeys.contains($0.key) }
        )
    }

    var formattedTotalSelectedSize: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: totalSelectedSize)
    }

    /// Section-header display total (all of one scanner's items — the old
    /// `nodeModulesTotal`); same helper, unfiltered inclusion.
    func totalSize(forScanner id: String) -> Int64 {
        aggregateBytes(scannerScope: { $0 == id }, include: { _ in true })
    }

    func formattedTotalSize(forScanner id: String) -> String {
        ByteCountFormatter.sharedFile.string(fromByteCount: totalSize(forScanner: id))
    }

    /// D8 disclosure shown beside every recoverable/removable total (R8):
    /// APFS clones and cross-category hardlinks make scan totals a ceiling,
    /// not a promise.
    nonisolated var overcountCaveat: String { DiskSpaceCaveat.overcount }

    /// True when the current selection includes a `.partiallyDenied` item —
    /// the confirmation sheet must warn that its size covers measured bytes
    /// only (R18).
    var hasPartiallyDeniedSelection: Bool {
        selectedItems.contains { $0.state == .partiallyDenied }
    }

    /// True when the current selection includes a command-backed item — its
    /// clean commands execute regardless of the Move-to-Trash toggle and
    /// erase permanently, so the confirmation sheet must say so whenever
    /// Trash mode is on (P2).
    var hasCommandBackedSelection: Bool {
        selectedItems.contains { if case .commands = $0.action { return true } else { return false } }
    }

    /// True when the current selection includes a caution-risk item (the
    /// confirmation sheet's warning banner).
    var hasCautionSelection: Bool {
        selectedItems.contains { $0.risk == .caution }
    }

    // MARK: - Scanning

    /// No default trigger — every caller must classify itself (R9). A
    /// defaulted `.userInitiated` let timer-driven refreshes inherit TCC
    /// consent silently; making the argument mandatory turns a
    /// misclassified new call site into a compile error.
    ///
    /// Consumes fn-2.1's progressive validated event stream — ALL scanners,
    /// nil `categoryFilter`. The trigger rides `ScanContext` (its derived
    /// `includeProtectedRoots` is the exact TCC mapping this view model used
    /// to special-case at the node_modules call site); orchestration,
    /// parallelism, and validation all live inside the runtime.
    func scan(trigger: ScanTrigger) async {
        // Re-entrancy guard (R11): correctness must not depend on button
        // state — an overlapping scan would race two writers over the same
        // published state while slower scanners are still running, and
        // scanning DURING a cleanup would publish results mid-deletion.
        // (clean()'s own post-cleanup rescan runs after isCleaning clears.)
        guard !isAnyScanInProgress && !isCleaning else { return }
        scanningScannerIDs = Set(runtime.scanners.map(\.id))
        diskInfo = await Task.detached { DiskInfo.current() }.value

        let stream = runtime.scanValidated(
            context: ScanContext(trigger: trigger)
        )
        for await event in stream {
            handle(event)
        }

        // If the consuming task was cancelled the stream may have ended
        // early — some scanners never delivered. Pruning then would drop
        // selections for items whose scanner simply never reported.
        let completed = !Task.isCancelled
        scanningScannerIDs = []
        guard completed else { return }

        pruneVanishedSelections()

        // Track scan completion for reactive UI updates
        lastScanDate = Date()
        scanGeneration += 1
        hasScanned = true
    }

    /// Applies ONE stream event — the reconciliation entry point `scan()`
    /// drives. Internal (not private) so tests seed view-model state through
    /// the SAME path production uses, never a parallel back door.
    func handle(_ event: ValidatedScannerEvent) {
        switch event {
        case .outcome(let scannerID, let outcome):
            reconcile(outcome, from: scannerID)
            scanningScannerIDs.remove(scannerID)
        case .malformed(let scannerID, let issue):
            // Fail-closed disposition (epic contract): NOTHING published for
            // this scanner — previous items and selections RETAINED, the
            // path-less issue surfaced. The failure is visible, nothing is
            // corrupted, nothing user-set is lost. Validation itself
            // happened in the runtime; this is only the disposition.
            malformedIssuesByScannerID[scannerID] = issue
            scanningScannerIDs.remove(scannerID)
        }
    }

    /// Per-scanner reconciliation against the PRIOR outcome (epic round 5):
    /// touches ONLY this scanner's entry and selections.
    private func reconcile(_ outcome: ScanOutcome, from scannerID: String) {
        let previouslyEmitted = emittedKeysByScannerID[scannerID] ?? []
        for item in outcome.items {
            let key = item.key
            if !Self.isSelectableState(item.state) {
                // `.denied`/`.empty`/`.missing` are unselectable in EVERY
                // surface (round 9): a retained selection on a now-denied
                // item would show a selected row every path refuses. (fn-1.4
                // parity: a rescan never leaves these selected.)
                selectedItemKeys.remove(key)
            } else if !previouslyEmitted.contains(key), Self.initiallySelected(item) {
                // Policy (a): `defaultSelected` on the key's FIRST emission
                // ever this session. Previously-emitted keys keep their
                // user-set state — selected AND deselected — verbatim.
                selectedItemKeys.insert(key)
            }
        }
        emittedKeysByScannerID[scannerID] =
            previouslyEmitted.union(outcome.items.map(\.key))
        outcomesByScannerID[scannerID] = outcome
        malformedIssuesByScannerID[scannerID] = nil
    }

    /// Vanished-key pruning, run EXACTLY at scan completion (never mid-scan
    /// — a selection on scanner A must not vanish because scanner B's event
    /// landed first, and must not flicker while A is still pending). A
    /// malformed scanner's retained items stay live, so their selections
    /// survive.
    private func pruneVanishedSelections() {
        var liveKeys = Set<ItemKey>()
        for outcome in outcomesByScannerID.values {
            for item in outcome.items { liveKeys.insert(item.key) }
        }
        selectedItemKeys.formIntersection(liveKeys)
    }

    // MARK: - Selection rules (fn-1.4 semantics preserved bit-for-bit)

    /// `.denied`/`.empty`/`.missing` cannot be selected anywhere — nothing
    /// to clean (round 9). `.partiallyDenied` stays manually toggleable; the
    /// confirmation sheet carries the warning.
    private static func isSelectableState(_ state: ScanState) -> Bool {
        switch state {
        case .measured, .partiallyDenied: return true
        case .denied, .empty, .missing: return false
        }
    }

    /// Policy (a) — the EXACT fn-1.4 initial-selection derivation
    /// (`ScanResult.init`): defaultSelected, cleanly measured, measurable
    /// bytes. `.partiallyDenied` is never auto-selected (its size is a
    /// floor, not a promise).
    private static func initiallySelected(_ item: ReclaimableItem) -> Bool {
        item.defaultSelected && item.state == .measured && item.allocatedBytes > 0
    }

    /// Policy (b) — Quick Clean / selectAllSafe eligibility: structured
    /// fields, not risk inference. `defaultSelected` is deliberately NOT
    /// consulted — today's selectAllSafe ignores it, and adding it would be
    /// a silent behavior change dressed as parity. The clean-state rules are
    /// as-built: only cleanly `.measured` items with measurable bytes
    /// (`.partiallyDenied` never rides an auto path — R18).
    private static func safeAutoSelectable(_ item: ReclaimableItem) -> Bool {
        item.automaticCleanEligible
            && item.risk == .safe
            && item.state == .measured
            && item.allocatedBytes > 0
    }

    func toggleSelection(for key: ItemKey) {
        guard let item = item(for: key) else { return }
        // Unselectable states are no-ops for aggregate AND per-item rows
        // alike — the checkbox must not pretend otherwise (R18/round 9).
        guard Self.isSelectableState(item.state) else { return }
        if selectedItemKeys.contains(key) {
            selectedItemKeys.remove(key)
        } else {
            selectedItemKeys.insert(key)
        }
    }

    /// Policy (b) across every scanner. Today only category aggregates are
    /// `automaticCleanEligible`; node_modules ships ineligible, so behavior
    /// is unchanged — and a future eligible safe scanner enrolls by
    /// declaration, not by an edit here.
    func selectAllSafe() {
        for outcome in outcomesByScannerID.values {
            for item in outcome.items where Self.safeAutoSelectable(item) {
                selectedItemKeys.insert(item.key)
            }
        }
    }

    func deselectAll() {
        selectedItemKeys = []
    }

    // MARK: - Per-section selection (the old node_modules quick actions,
    // generalized per scanner id)

    /// "Select Stale" operates on `isStale == true` ONLY — `isStale == nil`
    /// means staleness is inapplicable and contributes nothing.
    func selectStale(inScanner id: String) {
        for item in items(forScanner: id)
        where item.isStale == true && Self.isSelectableState(item.state) {
            selectedItemKeys.insert(item.key)
        }
    }

    func selectAll(inScanner id: String) {
        for item in items(forScanner: id)
        where Self.isSelectableState(item.state) {
            selectedItemKeys.insert(item.key)
        }
    }

    func deselectAll(inScanner id: String) {
        for item in items(forScanner: id) {
            selectedItemKeys.remove(item.key)
        }
    }

    /// Menu bar label: show free GB in the tray
    var menuBarTitle: String {
        guard let disk = diskInfo else { return "💾" }
        let freeGB = Double(disk.freeSpace) / (1024 * 1024 * 1024)
        return String(format: "%.0fGB", freeGB)
    }

    /// Quick clean: a PURE auto path (R18) and strictly policy (b). Any
    /// manual selections — including a deliberately toggled
    /// `.partiallyDenied` category or per-item rows — are cleared first, so
    /// Quick Clean acts on exactly the auto-selected safe set and nothing
    /// rides along. Policy (c) — smart-clean's safe-then-review ordering —
    /// is EXCLUSIVELY the CLI's (fn-2.6): the GUI never invokes its
    /// candidate-order helper and never selects review-risk.
    func smartClean() async {
        deselectAll()
        selectAllSafe()
        await clean()
        // Re-scan updates are handled inside clean()
    }

    // MARK: - Docker Management

    @Published var isDockerPruning = false
    @Published var lastDockerPruneResult: String?

    func dockerPrune() async {
        isDockerPruning = true
        defer { isDockerPruning = false }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "system", "prune", "-f"]
        process.standardOutput = pipe
        process.standardError = pipe
        // Real home is correct here: the view model has no injected-home
        // seam — docker prune is a production-only action on the real
        // account (unlike CacheCleaner/CacheCategory subprocesses, which
        // pin HOME to their injected home).
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path
        ]

        do {
            let result = try await Task.detached { () -> (Int32, String) in
                try process.run()
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                return (process.terminationStatus, output)
            }.value

            if result.0 == 0 {
                // Extract "Total reclaimed space:" line
                if let line = result.1.components(separatedBy: "\n")
                    .first(where: { $0.contains("reclaimed") }) {
                    lastDockerPruneResult = line.trimmingCharacters(in: .whitespaces)
                } else {
                    lastDockerPruneResult = "Docker pruned successfully"
                }
            } else {
                let lowerOutput = result.1.lowercased()
                if lowerOutput.contains("cannot connect") ||
                   lowerOutput.contains("is the docker daemon running") ||
                   lowerOutput.contains("connection refused") ||
                   lowerOutput.contains("no such file or directory") {
                    lastDockerPruneResult = "Docker must be running to prune"
                } else {
                    lastDockerPruneResult = "Docker prune failed — is Docker running?"
                }
            }
        } catch {
            lastDockerPruneResult = "Docker not found"
        }

        // Refresh disk info after prune
        diskInfo = await Task.detached { DiskInfo.current() }.value
    }

    // MARK: - Cleaning

    /// Builds `[ReclaimableItem]` from `selectedItemKeys` and drives
    /// fn-2.3's unified entry on the RUNTIME-constructed cleaner — one
    /// composition source, so delete-time admission covers exactly the
    /// registered scanners' declared container roots.
    func clean() async {
        // Guard at the model, not just the buttons (R11): cleaning while
        // any scanner is still reporting would act on a half-built result
        // set.
        guard !isCleaning && !isAnyScanInProgress else { return }
        isCleaning = true
        let report = await cleaner.clean(
            items: selectedItems, moveToTrash: moveToTrash
        )
        lastReport = report
        isCleaning = false
        showCleanupReport = true

        // Rescan to update sizes. `.userInitiated`: a confirmed cleanup is
        // explicit user action (see ScanTrigger), and the refresh must see
        // the same roots the results being updated came from.
        await scan(trigger: .userInitiated)
    }
}
