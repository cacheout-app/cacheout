/// # CacheoutViewModel — Main Application State
///
/// The central `@MainActor` view model that manages all application state and
/// coordinates between the scanning, cleaning, and UI layers.
///
/// ## State Management
///
/// All `@Published` properties trigger SwiftUI view updates automatically:
/// - `scanResults`: Current scan results for all cache categories
/// - `nodeModulesItems`: Discovered node_modules directories
/// - `diskInfo`: Current disk space information
/// - `isScanning` / `isCleaning` / `isNodeModulesScanning`: Loading states
/// - `scanGeneration`: Monotonic counter incremented on each scan completion,
///   used by views with `.task(id:)` to react to new data
///
/// ## Persistence
///
/// User preferences are stored in `UserDefaults` via `didSet` observers:
/// - `scanIntervalMinutes`: How often to auto-rescan (default: 30)
/// - `lowDiskThresholdGB`: Notification threshold (default: 10)
/// - `launchAtLogin`: Whether to start at login
/// - `moveToTrash`: Deletion mode preference
///
/// ## Scanning
///
/// The `scan()` method runs `CacheScanner` and `NodeModulesScanner` in parallel
/// using `async let`. Cache scanning completes first (typically 2-5s), then
/// node_modules scanning finishes (can take 10-30s depending on project count).
///
/// ## Smart Clean
///
/// `smartClean()` auto-selects all "Safe" categories and runs cleanup — a one-tap
/// operation from the menubar for quick disk recovery without decision fatigue.
///
/// ## Docker Prune
///
/// `dockerPrune()` runs `docker system prune -f` and parses the output for the
/// "Total reclaimed space" line. Handles Docker not running or not installed gracefully.

import Foundation
import SwiftUI

/// What set a scan in motion (fn-1.4, R9). TCC-protected search roots
/// (Documents, Desktop, …) are enumerated ONLY for `.userInitiated` scans —
/// a background refresh must never be the thing that fires a macOS privacy
/// prompt.
enum ScanTrigger: Equatable {
    /// The user explicitly asked (Scan button, Quick Clean, confirmed
    /// cleanup). Protected roots are included; macOS may prompt once.
    case userInitiated
    /// Popover/tab auto-rescan or any other background refresh. Protected
    /// roots are skipped entirely.
    case automatic
}

@MainActor
class CacheoutViewModel: ObservableObject {
    @Published var scanResults: [ScanResult] = []
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var diskInfo: DiskInfo?
    @Published var showCleanConfirmation = false
    @Published var showCleanupReport = false
    @Published var lastReport: CleanupReport?
    @Published var moveToTrash = true

    @Published var nodeModulesItems: [NodeModulesItem] = []
    @Published var isNodeModulesScanning = false

    /// Classified problems from the last node_modules scan (fn-1.4, R14) —
    /// a denied `~/Documents` search root must be VISIBLE here, never an
    /// empty section. GUI-only surfacing: the CLI does not expose
    /// node_modules at all until fn-2.
    @Published var nodeModulesScanIssues: [NodeModulesScanIssue] = []

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

    /// True while ANY phase of a scan is still running (R11). The cache
    /// phase finishes first and clears `isScanning`; node_modules can run
    /// 10–30s longer — scan/clean controls and model guards must cover the
    /// WHOLE window, or a clean could act on a half-built result set.
    var isAnyScanInProgress: Bool { isScanning || isNodeModulesScanning }

    /// Whether the menubar should trigger an auto-rescan (no results or stale data)
    var shouldAutoRescan: Bool {
        if isAnyScanInProgress || isCleaning { return false }
        if !hasResults { return true }
        guard let last = lastScanDate else { return true }
        return Date().timeIntervalSince(last) > scanIntervalMinutes * 60
    }

    private let scanner: CacheScanner
    private let nodeModulesScanner: NodeModulesScanner
    private let cleaner: CacheCleaner
    private let categories: [CacheCategory]

    /// - Parameters:
    ///   - scanner/nodeModulesScanner/cleaner: injectable for hermetic tests
    ///     (fixture homes and search roots — zero real-`$HOME` reads);
    ///     production uses the defaults.
    ///   - categories: the category registry to scan; tests pass fixtures.
    init(
        scanner: CacheScanner = CacheScanner(),
        nodeModulesScanner: NodeModulesScanner = NodeModulesScanner(),
        cleaner: CacheCleaner = CacheCleaner(),
        categories: [CacheCategory] = CacheCategory.allCategories
    ) {
        self.scanner = scanner
        self.nodeModulesScanner = nodeModulesScanner
        self.cleaner = cleaner
        self.categories = categories

        let storedInterval = UserDefaults.standard.double(forKey: "cacheout.scanIntervalMinutes")
        self.scanIntervalMinutes = storedInterval > 0 ? storedInterval : 30

        let storedThreshold = UserDefaults.standard.double(forKey: "cacheout.lowDiskThresholdGB")
        self.lowDiskThresholdGB = storedThreshold > 0 ? storedThreshold : 10

        self.launchAtLogin = UserDefaults.standard.bool(forKey: "cacheout.launchAtLogin")
    }

    var selectedResults: [ScanResult] {
        scanResults.filter { $0.isSelected }
    }

    var selectedSize: Int64 {
        // ⚡ Bolt: Chain .lazy before .filter to prevent intermediate array allocation
        scanResults.lazy.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
    }

    var formattedSelectedSize: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: selectedSize)
    }

    var totalRecoverable: Int64 {
        // `.denied` contributes nothing by construction (nothing was
        // measurable); the explicit filter keeps that true even if a future
        // state carries bytes it cannot promise (R18).
        scanResults.lazy
            .filter { !$0.isEmpty && $0.state != .denied }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    /// D8 disclosure shown beside every recoverable/removable total (R8):
    /// APFS clones and cross-category hardlinks make scan totals a ceiling,
    /// not a promise.
    nonisolated var overcountCaveat: String { DiskSpaceCaveat.overcount }

    /// True when the current selection includes a `.partiallyDenied`
    /// category — the confirmation sheet must warn that its size covers
    /// measured bytes only (R18).
    var hasPartiallyDeniedSelection: Bool {
        scanResults.contains { $0.isSelected && $0.state == .partiallyDenied }
    }

    /// True when the current selection includes a command-backed category —
    /// its clean commands execute regardless of the Move-to-Trash toggle and
    /// erase permanently, so the confirmation sheet must say so whenever
    /// Trash mode is on (P2).
    var hasCommandBackedSelection: Bool {
        scanResults.contains { $0.isSelected && $0.category.cleanCommands != nil }
    }

    var hasResults: Bool { !scanResults.isEmpty || !nodeModulesItems.isEmpty }
    var hasSelection: Bool {
        // ⚡ Bolt: Use .contains(where:) for O(1) best-case short-circuiting instead of .isEmpty on filtered array or reducing total size
        scanResults.contains(where: \.isSelected) || nodeModulesItems.contains(where: \.isSelected)
    }

    // MARK: - Node Modules computed properties

    var nodeModulesTotal: Int64 {
        nodeModulesItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var formattedNodeModulesTotal: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: nodeModulesTotal)
    }

    var selectedNodeModulesSize: Int64 {
        nodeModulesItems.lazy.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
    }

    var formattedSelectedNodeModulesSize: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: selectedNodeModulesSize)
    }

    var totalSelectedSize: Int64 { selectedSize + selectedNodeModulesSize }

    var formattedTotalSelectedSize: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: totalSelectedSize)
    }

    /// No default trigger — every caller must classify itself (R9). A
    /// defaulted `.userInitiated` let timer-driven refreshes inherit TCC
    /// consent silently; making the argument mandatory turns a
    /// misclassified new call site into a compile error.
    func scan(trigger: ScanTrigger) async {
        // Re-entrancy guard (R11): correctness must not depend on button
        // state — an overlapping scan would race two writers over the same
        // published arrays while the node_modules phase is still running,
        // and scanning DURING a cleanup would publish results mid-deletion.
        // (clean()'s own post-cleanup rescan runs after isCleaning clears.)
        guard !isAnyScanInProgress && !isCleaning else { return }
        isScanning = true
        isNodeModulesScanning = true
        diskInfo = await Task.detached { DiskInfo.current() }.value

        // Scan caches and node_modules in parallel. TCC gating (R9):
        // protected search roots are enumerated only when the user asked.
        async let cacheResults = scanner.scanAll(categories)
        async let nmResults = nodeModulesScanner.scan(
            includeProtectedRoots: trigger == .userInitiated
        )

        scanResults = await cacheResults
        isScanning = false

        let outcome = await nmResults
        nodeModulesItems = outcome.items
        // Classified scan problems are information, not noise (R14/D6) — a
        // denied search root surfaces in the section, never as "found none".
        nodeModulesScanIssues = outcome.errors
        isNodeModulesScanning = false

        // Track scan completion for reactive UI updates
        lastScanDate = Date()
        scanGeneration += 1
        hasScanned = true
    }

    func toggleSelection(for id: UUID) {
        if let index = scanResults.firstIndex(where: { $0.id == id }) {
            // `.denied` is unselectable (R18): nothing was measurable and
            // the cleaner refuses it regardless — the checkbox must not
            // pretend otherwise. `.partiallyDenied` stays manually
            // toggleable; the confirmation sheet carries the warning.
            guard scanResults[index].state != .denied else { return }
            scanResults[index].isSelected.toggle()
        }
    }

    func selectAllSafe() {
        var results = scanResults
        // R18: only cleanly `.measured` categories are auto-selected.
        // `.partiallyDenied` is never auto-selected (smart-clean's auto
        // path goes through here) and `.denied` is unselectable.
        for i in results.indices
        where results[i].category.riskLevel == .safe
            && results[i].state == .measured
            && !results[i].isEmpty {
            results[i].isSelected = true
        }
        scanResults = results
    }

    func deselectAll() {
        var results = scanResults
        for i in results.indices {
            results[i].isSelected = false
        }
        scanResults = results
        deselectAllNodeModules()
    }

    // MARK: - Node Modules selection

    func toggleNodeModulesSelection(for id: UUID) {
        if let i = nodeModulesItems.firstIndex(where: { $0.id == id }) {
            nodeModulesItems[i].isSelected.toggle()
        }
    }

    func selectStaleNodeModules() {
        var items = nodeModulesItems
        for i in items.indices where items[i].isStale {
            items[i].isSelected = true
        }
        nodeModulesItems = items
    }

    func selectAllNodeModules() {
        var items = nodeModulesItems
        for i in items.indices { items[i].isSelected = true }
        nodeModulesItems = items
    }

    func deselectAllNodeModules() {
        var items = nodeModulesItems
        for i in items.indices { items[i].isSelected = false }
        nodeModulesItems = items
    }

    /// Menu bar label: show free GB in the tray
    var menuBarTitle: String {
        guard let disk = diskInfo else { return "💾" }
        let freeGB = Double(disk.freeSpace) / (1024 * 1024 * 1024)
        return String(format: "%.0fGB", freeGB)
    }

    /// Quick clean: a PURE auto path (R18). Any manual selections —
    /// including a deliberately toggled `.partiallyDenied` category or
    /// node_modules items — are cleared first, so Quick Clean acts on
    /// exactly the auto-selected safe `.measured` set and nothing rides
    /// along.
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

    func clean() async {
        // Guard at the model, not just the buttons (R11): cleaning while
        // any scan phase is still running would act on a half-built result
        // set (node_modules may still be populating).
        guard !isCleaning && !isAnyScanInProgress else { return }
        isCleaning = true
        let selectedNM = nodeModulesItems.filter(\.isSelected)
        let report = await cleaner.clean(
            results: selectedResults,
            nodeModules: selectedNM,
            moveToTrash: moveToTrash
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
