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

    /// Whether the menubar should trigger an auto-rescan (no results or stale data)
    var shouldAutoRescan: Bool {
        if !hasResults && !isScanning { return true }
        guard let last = lastScanDate else { return true }
        return Date().timeIntervalSince(last) > scanIntervalMinutes * 60
    }

    private let scanner = CacheScanner()
    private let nodeModulesScanner = NodeModulesScanner()
    private let cleaner = CacheCleaner()

    init() {
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
        selectedResults.reduce(0) { $0 + $1.sizeBytes }
    }

    var formattedSelectedSize: String {
        ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file)
    }

    var totalRecoverable: Int64 {
        scanResults.filter { !$0.isEmpty }.reduce(0) { $0 + $1.sizeBytes }
    }

    var hasResults: Bool { !scanResults.isEmpty || !nodeModulesItems.isEmpty }
    var hasSelection: Bool { !selectedResults.isEmpty || selectedNodeModulesSize > 0 }

    // MARK: - Node Modules computed properties

    var nodeModulesTotal: Int64 {
        nodeModulesItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var formattedNodeModulesTotal: String {
        ByteCountFormatter.string(fromByteCount: nodeModulesTotal, countStyle: .file)
    }

    var selectedNodeModulesSize: Int64 {
        nodeModulesItems.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
    }

    var formattedSelectedNodeModulesSize: String {
        ByteCountFormatter.string(fromByteCount: selectedNodeModulesSize, countStyle: .file)
    }

    var totalSelectedSize: Int64 { selectedSize + selectedNodeModulesSize }

    var formattedTotalSelectedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file)
    }

    func scan() async {
        isScanning = true
        isNodeModulesScanning = true
        diskInfo = DiskInfo.current()

        // Scan caches and node_modules in parallel
        async let cacheResults = scanner.scanAll(CacheCategory.allCategories)
        async let nmResults = nodeModulesScanner.scan()

        scanResults = await cacheResults
        isScanning = false

        nodeModulesItems = await nmResults
        isNodeModulesScanning = false

        // Track scan completion for reactive UI updates
        lastScanDate = Date()
        scanGeneration += 1
        hasScanned = true
    }

    func toggleSelection(for id: UUID) {
        if let index = scanResults.firstIndex(where: { $0.id == id }) {
            scanResults[index].isSelected.toggle()
        }
    }

    func selectAllSafe() {
        // PERFORMANCE (Bolt): Using .map to batch update the @Published array and
        // prevent individual UI update notifications for every element change.
        scanResults = scanResults.map { result in
            var copy = result
            if copy.category.riskLevel == .safe && !copy.isEmpty {
                copy.isSelected = true
            }
            return copy
        }
    }

    func deselectAll() {
        // PERFORMANCE (Bolt): Using .map to batch update the @Published array and
        // prevent individual UI update notifications for every element change.
        scanResults = scanResults.map { result in
            var copy = result
            copy.isSelected = false
            return copy
        }
        deselectAllNodeModules()
    }

    // MARK: - Node Modules selection

    func toggleNodeModulesSelection(for id: UUID) {
        if let i = nodeModulesItems.firstIndex(where: { $0.id == id }) {
            nodeModulesItems[i].isSelected.toggle()
        }
    }

    func selectStaleNodeModules() {
        // PERFORMANCE (Bolt): Using .map to batch update the @Published array and
        // prevent individual UI update notifications for every element change.
        nodeModulesItems = nodeModulesItems.map { item in
            var copy = item
            if copy.isStale {
                copy.isSelected = true
            }
            return copy
        }
    }

    func selectAllNodeModules() {
        // PERFORMANCE (Bolt): Using .map to batch update the @Published array and
        // prevent individual UI update notifications for every element change.
        nodeModulesItems = nodeModulesItems.map { item in
            var copy = item
            copy.isSelected = true
            return copy
        }
    }

    func deselectAllNodeModules() {
        // PERFORMANCE (Bolt): Using .map to batch update the @Published array and
        // prevent individual UI update notifications for every element change.
        nodeModulesItems = nodeModulesItems.map { item in
            var copy = item
            copy.isSelected = false
            return copy
        }
    }

    /// Menu bar label: show free GB in the tray
    var menuBarTitle: String {
        guard let disk = diskInfo else { return "💾" }
        let freeGB = Double(disk.freeSpace) / (1024 * 1024 * 1024)
        return String(format: "%.0fGB", freeGB)
    }

    /// Quick clean: auto-select all safe categories, clean, deselect
    func smartClean() async {
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
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "docker system prune -f 2>&1"]
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path
        ]

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                // Extract "Total reclaimed space:" line
                if let line = output.components(separatedBy: "\n")
                    .first(where: { $0.contains("reclaimed") }) {
                    lastDockerPruneResult = line.trimmingCharacters(in: .whitespaces)
                } else {
                    lastDockerPruneResult = "Docker pruned successfully"
                }
            } else {
                let lowerOutput = output.lowercased()
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
        diskInfo = DiskInfo.current()
    }

    func clean() async {
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

        // Rescan to update sizes
        await scan()
    }
}
