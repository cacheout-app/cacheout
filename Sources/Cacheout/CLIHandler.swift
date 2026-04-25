/// # CLIHandler — Headless CLI Interface
///
/// Provides a command-line interface for Cacheout that runs without any UI.
/// Designed for scripting, automation, and MCP server integration.
///
/// ## Commands
///
/// | Command       | Description                                          |
/// |---------------|------------------------------------------------------|
/// | `version`     | Print version info as JSON                           |
/// | `scan`        | Scan all categories and output results as JSON       |
/// | `clean`       | Clean specific categories by slug                    |
/// | `smart-clean` | Auto-clean safe categories until target GB is met    |
/// | `disk-info`   | Show disk space information                          |
/// | `spotlight`   | Tag cache dirs with Spotlight metadata               |
/// | `memory-stats`   | Show system memory statistics as JSON (SystemStatsDTO)|
/// | `top-processes`  | Show top N processes by memory footprint              |
/// | `memory-pressure`| Show current memory pressure classification           |
/// | `purge`          | (DEPRECATED) Redirects to `intervene pressure-trigger` |
/// | `recommendations`| Generate advisory memory recommendations (JSON array) |
/// | `intervene`      | Execute a named memory intervention                   |
/// | `install-helper`    | Register the privileged helper daemon (bundled app only) |
/// | `uninstall-helper`  | Unregister the privileged helper daemon                  |
///
/// ## Flags
///
/// - `--dry-run`: Preview what would be cleaned/intervened without side effects
/// - `--confirm`: Confirm execution for tier 2+ interventions
/// - `--target-pid N`: Target process ID for signal interventions
/// - `--target-name NAME`: Expected process name for PID validation (signal interventions)
/// - `--top N`: Limit top-processes output to N entries (default: 10)
/// - Category slugs are passed as positional arguments after the command
///
/// ## Output Format
///
/// All output is JSON (pretty-printed with sorted keys) written to stdout.
/// Errors are written to stderr. Exit codes: 0 = success, 1 = usage error.
///
/// ## Spotlight Tagging
///
/// The `spotlight` command writes two types of metadata for each discovered cache:
/// 1. `com.apple.metadata:kMDItemFinderComment` xattr for `mdfind` queries
/// 2. `.cacheout-managed` marker files for `mdfind -name` discovery
///
/// ## Examples
///
/// ```bash
/// Cacheout --cli scan
/// Cacheout --cli clean xcode_derived_data npm_cache
/// Cacheout --cli clean xcode_derived_data --dry-run
/// Cacheout --cli smart-clean 10.0
/// Cacheout --cli disk-info
/// Cacheout --cli spotlight
/// Cacheout --cli memory-stats
/// Cacheout --cli top-processes --top 10
/// Cacheout --cli memory-pressure
/// Cacheout --cli purge
/// Cacheout --cli intervene pressure-trigger --dry-run
/// Cacheout --cli intervene sigterm-cascade --confirm --target-pid 12345 --target-name Safari
/// Cacheout --cli intervene sleep-image-delete --confirm
/// Cacheout --cli install-helper
/// Cacheout --cli uninstall-helper
/// ```

import CacheoutShared
import Foundation

/// Handles --cli mode for MCP server integration.
/// When the binary is invoked as `Cacheout --cli <command> [--format json]`,
/// it runs headlessly and outputs structured data to stdout.
struct CLIHandler {
    // ⚡ Bolt: Cache Foundation formatters to prevent allocation overhead
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    enum Command: String, CaseIterable {
        case version
        case scan
        case clean
        case smartClean = "smart-clean"
        case diskInfo = "disk-info"
        case spotlight
        case memoryStats = "memory-stats"
        case topProcesses = "top-processes"
        case memoryPressure = "memory-pressure"
        case recommendations
        case purge
        case intervene
        case installHelper = "install-helper"
        case uninstallHelper = "uninstall-helper"
    }

    static func shouldHandleCLI() -> Bool {
        CommandLine.arguments.contains("--cli")
    }

    static func run() async {
        let args = CommandLine.arguments
        guard let cliIndex = args.firstIndex(of: "--cli"),
              cliIndex + 1 < args.count else {
            exitWithError(code: "USAGE_ERROR", message: "Usage: Cacheout --cli <command> [options]")
        }

        let commandStr = args[cliIndex + 1]
        let isDryRun = args.contains("--dry-run")

        guard let command = Command(rawValue: commandStr) else {
            exitWithError(code: "UNKNOWN_COMMAND", message: "Unknown command: \(commandStr)")
        }

        switch command {
        case .version:
            handleVersion()

        case .diskInfo:
            await handleDiskInfo()

        case .scan:
            await handleScan()

        case .clean:
            let slugs = extractSlugs(from: args, after: cliIndex + 1)
            await handleClean(slugs: slugs, dryRun: isDryRun)

        case .smartClean:
            let targetGB = extractFloat(from: args, after: cliIndex + 1) ?? 5.0
            await handleSmartClean(targetGB: targetGB, dryRun: isDryRun)

        case .spotlight:
            await handleSpotlight()

        case .memoryStats:
            await handleMemoryStats()

        case .topProcesses:
            let topN = extractTopFlag(from: args, after: cliIndex + 1) ?? 10
            await handleTopProcesses(topN: topN)

        case .memoryPressure:
            handleMemoryPressure()

        case .recommendations:
            await handleRecommendations()

        case .purge:
            // Deprecated: redirects to `intervene pressure-trigger` (spec replacement).
            fputs("warning: 'purge' is deprecated. Use 'intervene pressure-trigger' instead.\n", stderr)
            await handleIntervene(name: "pressure-trigger", dryRun: isDryRun, confirmed: true)

        case .installHelper:
            handleInstallHelper()

        case .uninstallHelper:
            handleUninstallHelper()

        case .intervene:
            let interventionName = extractPositionalArg(from: args, after: cliIndex + 1)
            let isConfirmed = args.contains("--confirm")
            let targetPID: pid_t?
            if let flagIdx = args.firstIndex(of: "--target-pid") {
                // Flag present — validate the value strictly.
                guard flagIdx + 1 < args.count,
                      let pidInt = Int32(args[flagIdx + 1]),
                      pidInt > 0 else {
                    exitWithError(code: "INVALID_ARGUMENTS",
                                  message: "--target-pid requires a positive integer PID value")
                }
                targetPID = pidInt
            } else {
                targetPID = nil
            }
            let targetName: String?
            if let flagIdx = args.firstIndex(of: "--target-name") {
                guard flagIdx + 1 < args.count,
                      !args[flagIdx + 1].hasPrefix("--"),
                      !args[flagIdx + 1].trimmingCharacters(in: .whitespaces).isEmpty else {
                    exitWithError(code: "INVALID_ARGUMENTS",
                                  message: "--target-name requires a non-empty process name value")
                }
                targetName = args[flagIdx + 1]
            } else {
                targetName = nil
            }
            await handleIntervene(name: interventionName, dryRun: isDryRun, confirmed: isConfirmed, targetPID: targetPID, targetName: targetName)
        }

        Foundation.exit(0)
    }

    // MARK: - Version

    private static func handleVersion() {
        let helperEnabled = HelperInstaller().status == .enabled
        let capabilities = Command.allCases.map(\.rawValue)
        outputJSON([
            "version": "2.0.0",
            "schema_version": 2,
            "mode": "cli",
            "app": "Cacheout",
            "helper_installed": helperEnabled, // backward-compat alias (schema v1)
            "helper_enabled": helperEnabled,   // preferred field going forward
            "capabilities": capabilities,
        ] as [String: Any])
    }

    // MARK: - Command Handlers

    private static func handleDiskInfo() async {
        guard let disk = DiskInfo.current() else {
            exitWithError(code: "DISK_INFO_FAILED", message: "Failed to read disk info")
        }
        outputJSON([
            "total": disk.formattedTotal,
            "free": disk.formattedFree,
            "used": disk.formattedUsed,
            "total_bytes": disk.totalSpace,
            "free_bytes": disk.freeSpace,
            "used_bytes": disk.usedSpace,
            "free_gb": Double(disk.freeSpace) / (1024 * 1024 * 1024),
            "used_percent": disk.usedPercentage * 100,
        ] as [String: Any])
    }

    private static func handleScan() async {
        let scanner = CacheScanner()
        let results = await scanner.scanAll(CacheCategory.allCategories)

        let items: [[String: Any]] = results.map { result in
            [
                "slug": result.category.slug,
                "name": result.category.name,
                "size_bytes": result.sizeBytes,
                "size_human": result.formattedSize,
                "item_count": result.itemCount,
                "exists": result.exists,
                "risk_level": result.category.riskLevel.rawValue.lowercased(),
                "description": result.category.description,
                "rebuild_note": result.category.rebuildNote,
            ]
        }

        outputJSON(items)
    }

    private static func handleClean(slugs: [String], dryRun: Bool) async {
        let scanner = CacheScanner()
        let allResults = await scanner.scanAll(CacheCategory.allCategories)

        let toClean = allResults.filter { result in
            slugs.contains(result.category.slug)
        }.map { result in
            var r = result
            r.isSelected = true
            return r
        }

        if dryRun {
            let dryResults: [[String: Any]] = toClean.map { r in
                [
                    "slug": r.category.slug,
                    "name": r.category.name,
                    "bytes_would_free": r.sizeBytes,
                    "freed_human": r.formattedSize,
                ]
            }
            outputJSON([
                "dry_run": true,
                "total_would_free": toClean.reduce(Int64(0)) { $0 + $1.sizeBytes },
                "results": dryResults,
            ] as [String: Any])
            return
        }

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(results: toClean, moveToTrash: false)

        let cleanResults: [[String: Any]] = report.cleaned.map { item in
            [
                "category": item.category,
                "bytes_freed": item.bytesFreed,
                "freed_human": Self.byteFormatter.string(fromByteCount: item.bytesFreed),
                "success": true,
            ]
        }

        let errorResults: [[String: Any]] = report.errors.map { item in
            [
                "category": item.category,
                "error": item.error,
                "success": false,
            ]
        }

        outputJSON([
            "dry_run": false,
            "total_freed_bytes": report.totalFreed,
            "total_freed": report.formattedTotal,
            "results": cleanResults + errorResults,
        ] as [String: Any])
    }

    private static func handleSmartClean(targetGB: Double, dryRun: Bool) async {
        let scanner = CacheScanner()
        let allResults = await scanner.scanAll(CacheCategory.allCategories)

        let targetBytes = Int64(targetGB * 1024 * 1024 * 1024)
        var freedSoFar: Int64 = 0
        var cleaned: [[String: Any]] = []

        let sortedResults = allResults
            .filter { $0.exists && $0.sizeBytes > 0 }
            .sorted { a, b in
                let riskOrder: [RiskLevel: Int] = [.safe: 0, .review: 1, .caution: 2]
                let aOrder = riskOrder[a.category.riskLevel] ?? 99
                let bOrder = riskOrder[b.category.riskLevel] ?? 99
                if aOrder != bOrder { return aOrder < bOrder }
                return a.sizeBytes > b.sizeBytes
            }

        let cleaner = CacheCleaner()

        for result in sortedResults {
            if freedSoFar >= targetBytes { break }
            if result.category.riskLevel == .caution { continue }

            if dryRun {
                freedSoFar += result.sizeBytes
                cleaned.append([
                    "name": result.category.name,
                    "bytes_freed": result.sizeBytes,
                    "freed_human": result.formattedSize,
                ])
            } else {
                var selected = result
                selected.isSelected = true
                let report = await cleaner.clean(results: [selected], moveToTrash: false)
                let freed = report.totalFreed
                freedSoFar += freed
                cleaned.append([
                    "name": result.category.name,
                    "bytes_freed": freed,
                    "freed_human": Self.byteFormatter.string(fromByteCount: freed),
                ])
            }
        }

        outputJSON([
            "target_gb": targetGB,
            "target_met": freedSoFar >= targetBytes,
            "total_freed_bytes": freedSoFar,
            "total_freed": Self.byteFormatter.string(fromByteCount: freedSoFar),
            "dry_run": dryRun,
            "cleaned": cleaned,
        ] as [String: Any])
    }

    // MARK: - Spotlight Tagging

    /// Tag all discovered cache directories with Spotlight metadata so
    /// `mdfind "kMDItemFinderComment == 'cacheout-managed'"` finds them.
    /// Also writes a `.cacheout-managed` marker file for `mdfind -name` queries.
    private static func handleSpotlight() async {
        let scanner = CacheScanner()
        let results = await scanner.scanAll(CacheCategory.allCategories)

        var tagged: [[String: Any]] = []

        for result in results where result.exists {
            for url in result.category.resolvedPaths {
                // 1. Write Finder comment via xattr
                let comment = "cacheout-managed: \(result.category.slug)"
                let commentData = try? PropertyListSerialization.data(
                    fromPropertyList: comment, format: .binary, options: 0
                )
                if let data = commentData {
                    data.withUnsafeBytes { bytes in
                        url.withUnsafeFileSystemRepresentation { path in
                            guard let path = path else { return }
                            setxattr(path, "com.apple.metadata:kMDItemFinderComment",
                                     bytes.baseAddress, data.count, 0, 0)
                        }
                    }
                }

                // 2. Write marker file for mdfind -name queries
                let marker = url.appendingPathComponent(".cacheout-managed")
                let markerContent = """
                    slug: \(result.category.slug)
                    name: \(result.category.name)
                    risk: \(result.category.riskLevel.rawValue)
                    size: \(result.formattedSize)
                    tagged: \(Self.isoFormatter.string(from: Date()))
                    """
                try? markerContent.write(to: marker, atomically: true, encoding: .utf8)

                tagged.append([
                    "slug": result.category.slug,
                    "path": url.path,
                    "size": result.formattedSize,
                ])
            }
        }

        outputJSON([
            "tagged_count": tagged.count,
            "directories": tagged,
            "query_hint": "mdfind 'kMDItemFinderComment == \"cacheout-managed*\"'",
            "marker_hint": "mdfind -name .cacheout-managed",
        ] as [String: Any])
    }

    // MARK: - Memory Stats

    private static func handleMemoryStats() async {
        let monitor = MemoryMonitor()
        await monitor.start()

        // Race subscription against a 5-second timeout to prevent hanging
        // if MemoryMonitor.sample() returns nil on all attempts.
        let dto: SystemStatsDTO? = await withTaskGroup(of: SystemStatsDTO?.self) { group in
            group.addTask {
                for await stats in await monitor.subscribe() {
                    return stats
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await monitor.stop()

        guard let dto else {
            exitWithError(code: "MEMORY_STATS_TIMEOUT", message: "Failed to capture memory stats within timeout")
        }

        // Serialize pure SystemStatsDTO directly — no extra fields added.
        outputCodable(dto)
    }

    // MARK: - Top Processes

    /// Top-processes envelope carrying scanner metadata alongside results.
    private struct TopProcessesEnvelope: Codable {
        let source: String
        let partial: Bool
        let results: [ProcessEntryDTO]
    }

    private static func handleTopProcesses(topN: Int) async {
        let scanner = ProcessMemoryScanner()
        let result = await scanner.scan(topN: topN)

        if result.partial {
            printError("Warning: partial process data (source: \(result.source)). Install privileged helper for complete enumeration.")
        }

        let envelope = TopProcessesEnvelope(
            source: result.source,
            partial: result.partial,
            results: result.processes
        )
        outputCodable(envelope)
    }

    // MARK: - Recommendations

    private static func handleRecommendations() async {
        // One-shot mode: ephemeral PredictiveEngine, single scan, no trend data
        let engine = PredictiveEngine()

        // Get system stats for snapshot-based recommendations
        let monitor = MemoryMonitor()
        await monitor.start()

        let dto: SystemStatsDTO? = await withTaskGroup(of: SystemStatsDTO?.self) { group in
            group.addTask {
                for await stats in await monitor.subscribe() {
                    return stats
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await monitor.stop()

        let result = await RecommendationEngine.generateRecommendations(
            mode: .cli,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: dto
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(result.recommendations)
            guard let json = String(data: data, encoding: .utf8) else {
                exitWithError(code: "ENCODING_FAILED", message: "Failed to convert encoded data to UTF-8")
            }
            print(json)
        } catch {
            exitWithError(code: "ENCODING_FAILED", message: "JSON encoding failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Memory Pressure

    /// Memory-pressure envelope using canonical PressureTier classification.
    private struct PressureEnvelope: Codable {
        let pressureTier: String
        let numeric: Int32
        let availableMb: Double

        enum CodingKeys: String, CodingKey {
            case pressureTier = "pressure_tier"
            case numeric
            case availableMb = "available_mb"
        }
    }

    private static func handleMemoryPressure() {
        // Query pressure level
        var pressureLevel: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pressureSize, nil, 0) != 0 {
            FileHandle.standardError.write("Warning: Could not read kern.memorystatus_vm_pressure_level, defaulting to 0\n".data(using: .utf8)!)
            pressureLevel = 0
        }

        // Query VM stats to compute available MB
        var pageSize: vm_size_t = 0
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        guard host_page_size(hostPort, &pageSize) == KERN_SUCCESS else {
            exitWithError(code: "PAGE_SIZE_QUERY_FAILED", message: "Failed to query page size")
        }

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let vmResult = withUnsafeMutablePointer(to: &vmStats) { ptr in
            let hostPort2 = mach_host_self()
            defer { mach_port_deallocate(mach_task_self_, hostPort2) }
            return ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort2, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard vmResult == KERN_SUCCESS else {
            exitWithError(code: "VM_STATS_QUERY_FAILED", message: "Failed to query host_statistics64")
        }

        let availableMB = Double(vmStats.free_count + vmStats.inactive_count) * Double(pageSize) / 1048576.0
        let tier = PressureTier.from(pressureLevel: pressureLevel, availableMB: availableMB)

        let envelope = PressureEnvelope(
            pressureTier: tier.rawValue,
            numeric: pressureLevel,
            availableMb: availableMB
        )
        outputCodable(envelope)
    }

    // MARK: - Helper Install/Uninstall

    /// Register the privileged helper daemon.
    /// Only works from a bundled app context where the plist is embedded at
    /// `Contents/Library/LaunchDaemons/`. Running from `.build/release/Cacheout`
    /// will report the helper as unavailable (not a crash).
    private static func handleInstallHelper() {
        let installer = HelperInstaller()
        let currentStatus = installer.status

        if currentStatus == .enabled {
            // Idempotently sync the persisted preference so the app's
            // launch-time gate and helper-intent-dependent UX stay consistent
            // (e.g. user previously skipped onboarding, or helper was registered
            // externally / via an older version).
            OnboardingState.setHelperPreference(install: true)
            outputJSON([
                "success": true,
                "status": "already_enabled",
                "message": "Helper daemon is already registered and enabled",
            ] as [String: Any])
            return
        }

        if currentStatus == .requiresApproval {
            // Already registered, waiting on user — treat as terminal.
            OnboardingState.setHelperPreference(install: true)
            outputJSON([
                "success": true,
                "status": "requires_approval",
                "message": "Helper is registered but requires approval in System Settings > General > Login Items & Extensions",
            ] as [String: Any])
            return
        }

        if currentStatus == .notFound {
            exitWithError(code: "HELPER_UNAVAILABLE",
                          message: "Helper plist not found in app bundle. "
                          + "This command only works from a bundled Cacheout.app "
                          + "(e.g., installed via Homebrew cask), not from an unbundled "
                          + ".build/release/ binary.")
        }

        do {
            try installer.installIfNeeded()
            let newStatus = installer.status
            // Update the persisted preference so the app knows the helper
            // was installed (e.g. after previously skipping onboarding).
            OnboardingState.setHelperPreference(install: true)
            outputJSON([
                "success": true,
                "status": newStatus == .enabled ? "enabled" : "requires_approval",
                "message": newStatus == .enabled
                    ? "Helper daemon registered successfully"
                    : "Helper registered but requires user approval in System Settings",
            ] as [String: Any])
        } catch {
            exitWithError(code: "HELPER_INSTALL_FAILED",
                          message: "Failed to register helper: \(error.localizedDescription)")
        }
    }

    /// Unregister the privileged helper daemon.
    private static func handleUninstallHelper() {
        let installer = HelperInstaller()
        let currentStatus = installer.status

        switch currentStatus {
        case .notRegistered:
            // Idempotently clear persisted preference even if already unregistered,
            // so the app doesn't auto-register on next launch.
            OnboardingState.setHelperPreference(install: false)
            outputJSON([
                "success": true,
                "status": "not_registered",
                "message": "Helper daemon is not registered; nothing to uninstall",
            ] as [String: Any])
            return
        case .notFound:
            exitWithError(code: "HELPER_UNAVAILABLE",
                          message: "Helper plist not found in app bundle. "
                          + "This command only works from a bundled Cacheout.app "
                          + "(e.g., installed via Homebrew cask), not from an unbundled "
                          + ".build/release/ binary.")
        case .enabled, .requiresApproval:
            break
        }

        do {
            try installer.uninstall()
            // Clear the persisted onboarding preference so the app
            // doesn't auto-re-register the helper on next launch.
            OnboardingState.setHelperPreference(install: false)
            outputJSON([
                "success": true,
                "status": "unregistered",
                "message": "Helper daemon unregistered successfully. "
                    + "Note: a running daemon process may need to be stopped manually "
                    + "via 'sudo launchctl bootout system/com.cacheout.memhelper'",
            ] as [String: Any])
        } catch {
            exitWithError(code: "HELPER_UNINSTALL_FAILED",
                          message: "Failed to unregister helper: \(error.localizedDescription)")
        }
    }

    // MARK: - Intervene

    // Delegate to shared InterventionRegistry for intervention lookups.
    // Signal/PID sets and the full registry are maintained in InterventionRegistry.swift.

    /// Open a privileged XPC connection to the helper daemon.
    /// Returns nil if the helper is not installed.
    private static func openHelperConnection() -> NSXPCConnection? {
        let installer = HelperInstaller()
        guard installer.status == .enabled else { return nil }

        let connection = NSXPCConnection(machServiceName: "com.cacheout.memhelper", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: MemoryHelperProtocol.self)
        connection.resume()
        return connection
    }

    private static func handleIntervene(name: String?, dryRun: Bool, confirmed: Bool, targetPID: pid_t? = nil, targetName: String? = nil) async {
        guard let name else {
            exitWithError(code: "MISSING_ARGUMENT", message: "Usage: Cacheout --cli intervene <name> [--dry-run] [--confirm] [--target-pid N] [--target-name NAME]")
        }

        // Normalize: accept both underscore (spec) and hyphen (CLI) forms.
        let canonicalName = InterventionRegistry.canonicalize(name)

        guard let factory = InterventionRegistry.registry[canonicalName] else {
            let available = InterventionRegistry.registry.keys.sorted().joined(separator: ", ")
            exitWithError(code: "UNKNOWN_INTERVENTION", message: "Unknown intervention: \(name). Available: \(available)")
        }

        // Reject --target-pid for interventions that don't use it.
        let acceptsPID = InterventionRegistry.pidAcceptingNames.contains(canonicalName) || InterventionRegistry.signalInterventionNames.contains(canonicalName)
        if targetPID != nil && !acceptsPID {
            exitWithError(code: "INVALID_ARGUMENTS",
                          message: "--target-pid is only valid for signal/jetsam interventions, not \(canonicalName)")
        }

        // Reject --target-name for non-signal interventions.
        if targetName != nil && !InterventionRegistry.signalInterventionNames.contains(canonicalName) {
            exitWithError(code: "INVALID_ARGUMENTS",
                          message: "--target-name is only valid for signal interventions (sigterm-cascade, sigstop-freeze), not \(canonicalName)")
        }

        // Signal interventions require both --target-pid and --target-name.
        if InterventionRegistry.signalInterventionNames.contains(canonicalName) {
            guard targetPID != nil && targetName != nil else {
                exitWithError(code: "MISSING_ARGUMENT",
                              message: "\(canonicalName) requires --target-pid N --target-name NAME")
            }
        }

        let intervention = factory(targetPID, targetName)

        // Gate enforcement by tier.
        switch intervention.tier {
        case .safe:
            break // No confirmation needed.
        case .confirm:
            if !confirmed && !dryRun {
                exitWithError(code: "CONFIRMATION_REQUIRED",
                              message: "\(canonicalName) is tier confirm and requires --confirm or --dry-run")
            }
        case .destructive:
            if !confirmed && !dryRun {
                exitWithError(code: "CONFIRMATION_REQUIRED",
                              message: "\(canonicalName) is tier destructive and requires --confirm or --dry-run")
            }
        }

        // Open XPC connection if helper is available.
        let xpcConnection = openHelperConnection()

        let executor = InterventionExecutor(xpcConnection: xpcConnection, dryRun: dryRun, confirmed: confirmed)

        // Use InterventionEngine for orchestration (before/after snapshots + timing).
        let result = await InterventionEngine.run(intervention: intervention, via: executor)

        // Invalidate connection after use.
        xpcConnection?.invalidate()

        // Build PROTOCOL.md-compliant response.
        switch result.outcome {
        case .success(let reclaimedMB):
            let reclaimedBytes = (reclaimedMB ?? 0) * 1024 * 1024
            var response: [String: Any] = [
                "success": true,
                "intervention": canonicalName,
                "reclaimed_bytes": reclaimedBytes,
                "reclaimed_mb": reclaimedMB ?? 0,
                "dry_run": dryRun,
                "duration_seconds": round(result.duration * 10) / 10,
                "details": result.metadata,
            ]
            if let before = result.before {
                response["before"] = snapshotDict(before)
            }
            if let after = result.after {
                response["after"] = snapshotDict(after)
            }
            outputJSON(response)

        case .skipped(let reason):
            var response: [String: Any] = [
                "success": true,
                "intervention": canonicalName,
                "reclaimed_bytes": 0,
                "reclaimed_mb": 0,
                "dry_run": dryRun,
                "duration_seconds": round(result.duration * 10) / 10,
                "details": result.metadata.merging(["skipped": reason]) { _, new in new },
            ]
            if let before = result.before {
                response["before"] = snapshotDict(before)
            }
            if let after = result.after {
                response["after"] = snapshotDict(after)
            }
            outputJSON(response)

        case .error(let message):
            // Map well-known XPC/helper errors to documented error codes
            // with human-readable messages (internal sentinels stay in details).
            let errorCode: String
            let errorMessage: String
            if message == "xpc_not_available" {
                errorCode = "HELPER_NOT_INSTALLED"
                errorMessage = "Privileged helper not installed or not enabled"
            } else if message.hasPrefix("xpc_timeout") {
                errorCode = "HELPER_UNREACHABLE"
                errorMessage = "Privileged helper not responding via XPC (timeout)"
            } else if message.hasPrefix("xpc_error") {
                errorCode = "HELPER_UNREACHABLE"
                errorMessage = "Privileged helper not responding via XPC: \(message)"
            } else {
                errorCode = "INTERVENTION_FAILED"
                errorMessage = message
            }
            exitWithError(code: errorCode, message: errorMessage,
                          details: [
                            "intervention": canonicalName,
                            "dry_run": dryRun,
                            "duration_seconds": round(result.duration * 10) / 10,
                            "details": result.metadata,
                          ])
        }
    }

    /// Convert a MemorySnapshot to a JSON-friendly dictionary.
    private static func snapshotDict(_ snapshot: MemorySnapshot) -> [String: Any] {
        [
            "free_mb": snapshot.freeMB,
            "inactive_mb": snapshot.inactiveMB,
            "compressed_mb": snapshot.compressedMB,
            "purgeable_mb": snapshot.purgeableMB,
        ]
    }

    // MARK: - Helpers

    private static func extractPositionalArg(from args: [String], after index: Int) -> String? {
        let nextIndex = index + 1
        guard nextIndex < args.count else { return nil }
        let arg = args[nextIndex]
        return arg.hasPrefix("--") ? nil : arg
    }

    private static func extractSlugs(from args: [String], after index: Int) -> [String] {
        var slugs: [String] = []
        var i = index + 1
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--") { break }
            slugs.append(arg)
            i += 1
        }
        return slugs
    }

    private static func extractFloat(from args: [String], after index: Int) -> Double? {
        let nextIndex = index + 1
        guard nextIndex < args.count else { return nil }
        return Double(args[nextIndex])
    }

    /// Parse `--top N` flag from args after the command position.
    /// Returns `nil` if `--top` is absent. Calls `exitWithError` if `--top`
    /// is present but the value is missing, non-numeric, or <= 0.
    private static func extractTopFlag(from args: [String], after index: Int) -> Int? {
        var i = index + 1
        while i < args.count {
            if args[i] == "--top" {
                guard i + 1 < args.count else {
                    exitWithError(code: "INVALID_ARGUMENTS",
                                  message: "--top requires a positive integer value")
                }
                guard let n = Int(args[i + 1]), n > 0 else {
                    exitWithError(code: "INVALID_ARGUMENTS",
                                  message: "--top requires a positive integer value, got: \(args[i + 1])")
                }
                return n
            }
            i += 1
        }
        return nil
    }

    private static func outputCodable<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                exitWithError(code: "ENCODING_FAILED", message: "Failed to convert encoded data to UTF-8")
            }
            print(json)
        } catch {
            exitWithError(code: "ENCODING_FAILED", message: "JSON encoding failed: \(error.localizedDescription)")
        }
    }

    private static func outputJSON(_ value: Any) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }

    /// Write structured error JSON to stderr (for commands that can fail).
    private static func outputJSONError(_ value: Any) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write((json + "\n").data(using: .utf8)!)
        }
    }

    /// Centralized CLI error: writes structured JSON to stderr and exits non-zero.
    /// All CLI failure paths should route through this method.
    private static func exitWithError(code: String, message: String, details: [String: Any]? = nil) -> Never {
        var payload: [String: Any] = [
            "ok": false,
            "error": [
                "code": code,
                "message": message,
            ] as [String: Any],
        ]
        if let details {
            payload["details"] = details
        }
        outputJSONError(payload)
        Foundation.exit(1)
    }

    private static func printError(_ msg: String) {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    }
}
