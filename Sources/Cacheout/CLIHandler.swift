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
/// - `--confirm`: Confirm execution of destructive commands — `clean`,
///   `smart-clean` (schema v3, D5), and tier 2+ interventions
/// - `--target-pid N`: Target process ID for signal interventions
/// - `--target-name NAME`: Expected process name for PID validation (signal interventions)
/// - `--top N`: Limit top-processes output to N entries (default: 10)
/// - Category slugs are passed as positional arguments after the command
///
/// ## Output Format
///
/// All output is JSON (pretty-printed with sorted keys) written to stdout.
/// Errors are written to stderr (structured `{"ok": false, "error": ...}`
/// envelope). Exit codes: 0 = success — including a PARTIAL clean, which
/// reports per-item `success` flags; 1 = usage error, refused confirmation
/// (`CONFIRMATION_REQUIRED`, plan in the error `details`), refused root
/// execution (`ROOT_REFUSED`), or total clean failure (`CLEAN_FAILED`).
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
/// Cacheout --cli clean xcode_derived_data npm_cache --confirm
/// Cacheout --cli clean xcode_derived_data --dry-run
/// Cacheout --cli smart-clean 10.0 --confirm
/// Cacheout --cli smart-clean 10.0 --dry-run
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
        // Parsed once for every command that gates on it (clean, smart-clean,
        // intervene) — never re-read inside individual cases (fn-1.5, D5).
        let isConfirmed = args.contains("--confirm")

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
            await handleClean(slugs: slugs, dryRun: isDryRun, confirmed: isConfirmed)

        case .smartClean:
            // An ABSENT target defaults to 5.0; a PRESENT but malformed one
            // is a usage error — silently defaulting would let
            // `smart-clean garbage --confirm` delete 5 GB the caller never
            // asked for. (Range/finiteness is validated in the handler.)
            let targetGB: Double
            if let raw = extractPositionalArg(from: args, after: cliIndex + 1) {
                guard let parsed = Double(raw) else {
                    exitWithError(code: "INVALID_ARGUMENTS",
                                  message: "smart-clean target must be a number of GB, got: \(raw)")
                }
                targetGB = parsed
            } else {
                targetGB = 5.0
            }
            await handleSmartClean(targetGB: targetGB, dryRun: isDryRun, confirmed: isConfirmed)

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

        // Success paths only. Every failure path exits 1 through
        // `exitWithError` (CONFIRMATION_REQUIRED, CLEAN_FAILED, ROOT_REFUSED,
        // usage errors) and never reaches this line — a PARTIAL clean is a
        // success at process level and reports per-item `success` flags (D5).
        Foundation.exit(0)
    }

    // MARK: - Version

    /// Fallback version for unbundled binaries (e.g. `.build/release/Cacheout`),
    /// where there is no Info.plist to read. Keep in sync with the VERSION file
    /// at the repo root when cutting a release.
    private static let fallbackVersion = "2.1.9"

    /// App version: read from the bundle's Info.plist (stamped from the VERSION
    /// file by scripts/bundle.sh), falling back to the compiled constant when
    /// running as an unbundled binary.
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? fallbackVersion
    }

    /// Protocol schema version (PROTOCOL.md). 3 = `clean`/`smart-clean`
    /// require `--confirm`, clean totals are exact-only with additive
    /// estimated components, and total failure exits 1 `CLEAN_FAILED`
    /// (fn-1.5, D5/R16). Non-private so the schema tests assert the bump
    /// in-process.
    static let cliSchemaVersion = 3

    private static func handleVersion() {
        let helperEnabled = HelperInstaller().status == .enabled
        let capabilities = Command.allCases.map(\.rawValue)
        outputJSON([
            "version": appVersion,
            "schema_version": cliSchemaVersion,
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

        outputJSON(results.map { scanItemJSON(for: $0) })
    }

    /// Actionable remedy emitted with TCC-denied scan errors (fn-1.4, R9):
    /// a CLI process is denied SILENTLY by macOS — no prompt ever appears —
    /// so the JSON must say what to do about it.
    static let tccGrantHint = "macOS denied access without prompting (TCC). "
        + "Grant Full Disk Access to this binary (or your terminal) in "
        + "System Settings > Privacy & Security > Full Disk Access, then rescan."

    /// One category's scan JSON (fn-1.4, R6/R16). Additive on schema v2:
    /// `state`, `exact_bytes`, `estimated_up_to_bytes` always present
    /// (`size_bytes` stays the compatibility sum); `scan_error` (plus
    /// `grant_hint` for TCC denials) present only when the scan was
    /// impeded — a clean category carries neither key.
    static func scanItemJSON(for result: ScanResult) -> [String: Any] {
        var item: [String: Any] = [
            "slug": result.category.slug,
            "name": result.category.name,
            "size_bytes": result.sizeBytes,
            "size_human": result.formattedSize,
            "item_count": result.itemCount,
            "exists": result.exists,
            "risk_level": result.category.riskLevel.rawValue.lowercased(),
            "description": result.category.description,
            "rebuild_note": result.category.rebuildNote,
            "state": result.state.rawValue,
            "exact_bytes": result.exactBytes,
            "estimated_up_to_bytes": result.estimatedUpToBytes,
        ]
        if let scanError = result.scanError {
            item["scan_error"] = [
                "kind": scanError.kind.wireString,
                "message": scanError.message,
            ] as [String: Any]
            if scanError.kind == .tccDenied {
                item["grant_hint"] = tccGrantHint
            }
        }
        return item
    }

    // MARK: - Clean gate (D5, R5)

    /// The pure gate decision for `clean`/`smart-clean`. Free of I/O so the
    /// whole confirmed/dry-run/euid matrix is unit-testable in-process; the
    /// handlers translate the decision into process behavior (exit code,
    /// stderr envelope, stdout silence).
    enum CleanGateDecision: Equatable {
        /// Refused outright, before any scan: destructive cache deletion
        /// must never run with root privileges (categories resolve against
        /// a user home; euid 0 would bypass every permission backstop).
        case refuseRootUser
        /// Destructive run requested without `--confirm`: stdout stays
        /// empty, the plan goes to the stderr error `details`, exit 1.
        case refuseUnconfirmed
        /// Non-destructive preview (`--dry-run` wins even beside
        /// `--confirm` — matching the intervene gate, where dry-run is
        /// always non-destructive).
        case dryRun
        /// Confirmed destructive run.
        case proceed
    }

    static func cleanGateDecision(confirmed: Bool, dryRun: Bool, euid: uid_t) -> CleanGateDecision {
        guard euid != 0 else { return .refuseRootUser }
        if dryRun { return .dryRun }
        return confirmed ? .proceed : .refuseUnconfirmed
    }

    /// The exit-code decision for a completed destructive run (R5), pure so
    /// the whole matrix is unit-testable: TOTAL failure — exit 1
    /// `CLEAN_FAILED` — iff at least one category was attempted, every
    /// attempt failed, AND nothing was freed. Anything else (all-success,
    /// nothing attempted, mixed flags, or bytes freed despite every flag
    /// failing) is exit 0 with per-item `success` flags. Derived from the
    /// per-category flags plus the freed components — never from
    /// `entries.isEmpty`, which zero-byte successes also produce.
    static func cleanRunIsTotalFailure(
        successFlags: [Bool], freedExact: Int64, freedEstimated: Int64
    ) -> Bool {
        !successFlags.isEmpty
            && successFlags.allSatisfy { !$0 }
            && freedExact == 0
            && freedEstimated == 0
    }

    private static let rootRefusalMessage = "clean and smart-clean refuse to run as root (euid 0): "
        + "cache categories resolve against a user home, and deletion with root "
        + "privileges would bypass every filesystem permission backstop. Re-run as the login user."

    /// Warning attached to a `.partiallyDenied` category's clean output
    /// (R18): the cleaner proceeds on explicit selection but its numbers are
    /// a floor, not a promise — the CLI must say so.
    static let partiallyDeniedCleanWarning = "Parts of this category were unreadable at scan "
        + "time; only the measured bytes were cleaned and reported — the true size may be larger."

    /// What the real run would do with one requested category — the same
    /// decisions `CacheCleaner.clean` takes (missing/empty skipped, `.denied`
    /// refused even force-selected, `.partiallyDenied` proceeds with a
    /// warning). Drives both the `CONFIRMATION_REQUIRED` plan and the
    /// dry-run payload so preview and reality cannot drift.
    static func cleanPlanAction(for result: ScanResult) -> String {
        if result.state == .missing { return "skip" }
        if result.state == .denied { return "refuse" }
        if result.isEmpty { return "skip" }
        return result.state == .partiallyDenied ? "clean_with_warning" : "clean"
    }

    /// One plan entry (scan-time split components — never a re-walk, R16).
    static func cleanPlanItemJSON(for result: ScanResult) -> [String: Any] {
        var item: [String: Any] = [
            "slug": result.category.slug,
            "name": result.category.name,
            "state": result.state.rawValue,
            "action": cleanPlanAction(for: result),
            "exact_bytes": result.exactBytes,
            "estimated_up_to_bytes": result.estimatedUpToBytes,
        ]
        if result.state == .partiallyDenied {
            item["warning"] = partiallyDeniedCleanWarning
        }
        if let scanError = result.scanError {
            item["scan_error"] = [
                "kind": scanError.kind.wireString,
                "message": scanError.message,
            ] as [String: Any]
        }
        return item
    }

    /// Exact-only totals over the entries the plan would actually clean.
    private static func cleanPlanTotals(_ results: [ScanResult]) -> (exact: Int64, estimated: Int64) {
        results.reduce(into: (exact: Int64(0), estimated: Int64(0))) { totals, result in
            let action = cleanPlanAction(for: result)
            guard action == "clean" || action == "clean_with_warning" else { return }
            totals.exact += result.exactBytes
            totals.estimated += result.estimatedUpToBytes
        }
    }

    /// The `CONFIRMATION_REQUIRED` details payload for `clean` (R5): the
    /// same per-category decisions the confirmed run would take.
    static func cleanConfirmationDetails(for results: [ScanResult]) -> [String: Any] {
        let totals = cleanPlanTotals(results)
        return [
            "command": "clean",
            "plan": results.map { cleanPlanItemJSON(for: $0) },
            "total_exact_bytes": totals.exact,
            "total_estimated_up_to_bytes": totals.estimated,
        ]
    }

    /// Dry-run clean payload (R16): built from the SCAN-TIME split
    /// components — no re-walk, and `total_would_free` counts exact bytes
    /// only (estimates are additive, never laundered into the total).
    static func cleanDryRunPayload(for results: [ScanResult]) -> [String: Any] {
        let entries: [[String: Any]] = results.map { result in
            var item = cleanPlanItemJSON(for: result)
            let action = cleanPlanAction(for: result)
            let cleans = action == "clean" || action == "clean_with_warning"
            let exact = cleans ? result.exactBytes : 0
            let estimated = cleans ? result.estimatedUpToBytes : 0
            item["bytes_would_free"] = exact
            item["freed_human"] = CleanupReport.componentPhrase(
                exact: exact, estimatedUpTo: estimated
            )
            return item
        }
        let totals = cleanPlanTotals(results)
        return [
            "dry_run": true,
            "total_would_free": totals.exact,
            "total_estimated_up_to_bytes": totals.estimated,
            "results": entries,
        ]
    }

    private static func handleClean(slugs: [String], dryRun: Bool, confirmed: Bool) async {
        // The contract requires one or more slugs — an empty list must not
        // masquerade as a successful no-op clean.
        guard !slugs.isEmpty else {
            exitWithError(code: "MISSING_ARGUMENT",
                          message: "Usage: Cacheout --cli clean <slugs...> [--confirm|--dry-run]. Use 'scan' to list valid slugs.")
        }

        let knownSlugs = Set(CacheCategory.allCategories.map(\.slug))
        let unknown = slugs.filter { !knownSlugs.contains($0) }
        guard unknown.isEmpty else {
            exitWithError(code: "INVALID_ARGUMENTS",
                          message: "Unknown category slug(s): \(unknown.joined(separator: ", ")). Use 'scan' to list valid slugs.")
        }

        // Gate decision BEFORE any scan (D5). The unconfirmed branch still
        // scans below — read-only — because its refusal carries the plan.
        let decision = cleanGateDecision(confirmed: confirmed, dryRun: dryRun, euid: geteuid())
        if case .refuseRootUser = decision {
            exitWithError(code: "ROOT_REFUSED", message: rootRefusalMessage)
        }

        // Scan only what was asked for, deduped in the user's argument order
        // (scanAll returns size-descending).
        var seen = Set<String>()
        let requestedSlugs = slugs.filter { seen.insert($0).inserted }
        let requested = CacheCategory.allCategories.filter { requestedSlugs.contains($0.slug) }
        let scanner = CacheScanner()
        let scanned = await scanner.scanAll(requested)
        let bySlug = Dictionary(scanned.map { ($0.category.slug, $0) },
                                uniquingKeysWith: { first, _ in first })
        let toClean: [ScanResult] = requestedSlugs.compactMap { slug in
            guard var result = bySlug[slug] else { return nil }
            // Force-select: the CLI user named the slug explicitly. The
            // cleaner still refuses `.denied` regardless (R18) — that
            // refusal surfaces below as the per-item error.
            result.isSelected = true
            return result
        }

        switch decision {
        case .refuseRootUser:
            preconditionFailure("unreachable — refused before scanning")

        case .refuseUnconfirmed:
            // Stdout stays EMPTY; the plan rides in the stderr details (R5).
            exitWithError(
                code: "CONFIRMATION_REQUIRED",
                message: "clean deletes cache contents and requires --confirm (preview with --dry-run)",
                details: cleanConfirmationDetails(for: toClean)
            )

        case .dryRun:
            outputJSON(cleanDryRunPayload(for: toClean))

        case .proceed:
            let cleaner = CacheCleaner()
            let report = await cleaner.clean(results: toClean, moveToTrash: false)

            // Report entries/errors are keyed by category NAME; the wire
            // reports per requested slug — including a `success: true` row
            // for a slug that produced neither entry nor error (zero-byte
            // success, missing/empty skip). `entries.isEmpty` is NOT a
            // total-failure signal.
            let entriesByName = Dictionary(report.entries.map { ($0.category, $0) },
                                           uniquingKeysWith: { first, _ in first })
            let errorsByName = Dictionary(grouping: report.errors, by: \.category)

            let results: [[String: Any]] = toClean.map { result in
                let name = result.category.name
                let entry = entriesByName[name]
                let errs = (errorsByName[name] ?? []).map(\.error)
                let exact = entry?.exactBytes ?? 0
                let estimated = entry?.estimatedUpToBytes ?? 0
                var item: [String: Any] = [
                    "category": result.category.slug,
                    "name": name,
                    "bytes_freed": exact,
                    "exact_bytes": exact,
                    "estimated_up_to_bytes": estimated,
                    "freed_human": CleanupReport.componentPhrase(
                        exact: exact, estimatedUpTo: estimated
                    ),
                    "success": errs.isEmpty,
                ]
                if !errs.isEmpty {
                    item["error"] = errs.joined(separator: "; ")
                }
                if result.state == .partiallyDenied {
                    item["warning"] = partiallyDeniedCleanWarning
                }
                return item
            }

            // Exit contract (R5): TOTAL failure — every requested slug
            // errored and nothing was freed — exits 1 CLEAN_FAILED with an
            // empty stdout. Partial success stays exit 0 with per-item
            // `success` flags.
            if cleanRunIsTotalFailure(
                successFlags: results.map { ($0["success"] as? Bool) ?? false },
                freedExact: report.totalFreedExact,
                freedEstimated: report.totalEstimatedUpTo
            ) {
                exitWithError(code: "CLEAN_FAILED",
                              message: "No requested category could be cleaned",
                              details: ["results": results])
            }

            outputJSON([
                "dry_run": false,
                "total_freed_bytes": report.totalFreedExact,
                "total_estimated_up_to_bytes": report.totalEstimatedUpTo,
                "total_freed": CleanupReport.componentPhrase(
                    exact: report.totalFreedExact,
                    estimatedUpTo: report.totalEstimatedUpTo
                ),
                "results": results,
            ] as [String: Any])
        }
    }

    /// Smart-clean eligibility + order (R18): only cleanly-measured
    /// categories with bytes qualify — `.denied` AND `.partiallyDenied` are
    /// skipped (the auto path must never ride on a floor measurement), and
    /// caution-risk categories are excluded entirely. Safe before review,
    /// larger first within a tier.
    static func smartCleanCandidates(_ results: [ScanResult]) -> [ScanResult] {
        results
            .filter {
                $0.state == .measured && $0.sizeBytes > 0
                    && $0.category.riskLevel != .caution
            }
            .sorted { a, b in
                let riskOrder: [RiskLevel: Int] = [.safe: 0, .review: 1, .caution: 2]
                let aOrder = riskOrder[a.category.riskLevel] ?? 99
                let bOrder = riskOrder[b.category.riskLevel] ?? 99
                if aOrder != bOrder { return aOrder < bOrder }
                return a.sizeBytes > b.sizeBytes
            }
    }

    /// The smart-clean loop decision on SCAN-TIME components (R16): only
    /// exact bytes advance the target — a hardlink-heavy category may be
    /// cleaned, but its estimated bytes never mark `target_met`. Pure (no
    /// I/O, no re-walk) so the loop decision is unit-testable; drives both
    /// the dry-run payload and the `CONFIRMATION_REQUIRED` plan.
    ///
    /// The plan must describe EVERYTHING the confirmed run may touch: the
    /// real loop advances on DELETE-TIME bytes, so when an early category
    /// shrinks or partially fails, later candidates are cleaned too.
    /// Candidates past the projected target-met point are therefore listed
    /// with action `clean_if_needed` — deleted only if earlier categories
    /// under-deliver — with projected `bytes_freed` 0 and their would-free
    /// components intact. Projected totals and `target_met` count the
    /// unconditional entries only.
    static func smartCleanPlan(
        results: [ScanResult], targetBytes: Int64
    ) -> (entries: [[String: Any]], totalExact: Int64, totalEstimated: Int64, targetMet: Bool) {
        var freedExact: Int64 = 0
        var estimated: Int64 = 0
        var entries: [[String: Any]] = []
        for result in smartCleanCandidates(results) {
            // Plan shape parity with `clean` (PROTOCOL.md details.plan):
            // every candidate passed the `.measured` filter, so the derived
            // action is "clean" — derived, not hardcoded, so the two
            // commands cannot drift — until the projection meets the
            // target, after which candidates become conditional fallbacks.
            let isFallback = freedExact >= targetBytes
            let projectedExact = isFallback ? 0 : result.exactBytes
            let projectedEstimated = isFallback ? 0 : result.estimatedUpToBytes
            freedExact += projectedExact
            estimated += projectedEstimated
            entries.append([
                "slug": result.category.slug,
                "name": result.category.name,
                "state": result.state.rawValue,
                "action": isFallback ? "clean_if_needed" : cleanPlanAction(for: result),
                "bytes_freed": projectedExact,
                "exact_bytes": result.exactBytes,
                "estimated_up_to_bytes": result.estimatedUpToBytes,
                "freed_human": CleanupReport.componentPhrase(
                    exact: projectedExact,
                    estimatedUpTo: projectedEstimated
                ),
            ])
        }
        return (entries, freedExact, estimated, freedExact >= targetBytes)
    }

    private static func handleSmartClean(targetGB: Double, dryRun: Bool, confirmed: Bool) async {
        // Usage validation first (parity with clean's slug guard): a
        // non-finite or negative target would trap in the Int64 conversion
        // below (nan/inf) or produce nonsense; a ZERO target is already met
        // before anything runs (contradictory plan/target_met semantics);
        // a target past ~8e9 GB would overflow Int64. Refuse with the
        // documented usage error instead.
        guard targetGB.isFinite, targetGB > 0, targetGB <= 1_000_000_000 else {
            exitWithError(code: "INVALID_ARGUMENTS",
                          message: "smart-clean target must be a finite number of GB greater than 0 and at most 1000000000, got: \(targetGB)")
        }

        // Gate decision BEFORE any scan (D5); unconfirmed still scans
        // read-only below to build the refusal plan.
        let decision = cleanGateDecision(confirmed: confirmed, dryRun: dryRun, euid: geteuid())
        if case .refuseRootUser = decision {
            exitWithError(code: "ROOT_REFUSED", message: rootRefusalMessage)
        }

        let targetBytes = Int64(targetGB * 1024 * 1024 * 1024)
        let scanner = CacheScanner()
        let allResults = await scanner.scanAll(CacheCategory.allCategories)

        switch decision {
        case .refuseRootUser:
            preconditionFailure("unreachable — refused before scanning")

        case .refuseUnconfirmed:
            let plan = smartCleanPlan(results: allResults, targetBytes: targetBytes)
            exitWithError(
                code: "CONFIRMATION_REQUIRED",
                message: "smart-clean deletes cache contents and requires --confirm (preview with --dry-run)",
                details: [
                    "command": "smart-clean",
                    "target_gb": targetGB,
                    "plan": plan.entries,
                    "total_exact_bytes": plan.totalExact,
                    "total_estimated_up_to_bytes": plan.totalEstimated,
                    "target_met": plan.targetMet,
                ]
            )

        case .dryRun:
            let plan = smartCleanPlan(results: allResults, targetBytes: targetBytes)
            outputJSON([
                "target_gb": targetGB,
                "target_met": plan.targetMet,
                "total_freed_bytes": plan.totalExact,
                "total_estimated_up_to_bytes": plan.totalEstimated,
                "total_freed": CleanupReport.componentPhrase(
                    exact: plan.totalExact, estimatedUpTo: plan.totalEstimated
                ),
                "dry_run": true,
                "cleaned": plan.entries,
            ] as [String: Any])

        case .proceed:
            let cleaner = CacheCleaner()
            var freedExactSoFar: Int64 = 0
            var estimatedSoFar: Int64 = 0
            var cleaned: [[String: Any]] = []

            for result in smartCleanCandidates(allResults) {
                // Only exact (delete-time measured, unique-inode) bytes
                // advance the target — estimated bytes never mark
                // `target_met` (R16).
                if freedExactSoFar >= targetBytes { break }
                var selected = result
                selected.isSelected = true
                let report = await cleaner.clean(results: [selected], moveToTrash: false)
                let exact = report.totalFreedExact
                let estimated = report.totalEstimatedUpTo
                freedExactSoFar += exact
                estimatedSoFar += estimated

                let errs = report.errors.map(\.error)
                var item: [String: Any] = [
                    "slug": result.category.slug,
                    "name": result.category.name,
                    "bytes_freed": exact,
                    "exact_bytes": exact,
                    "estimated_up_to_bytes": estimated,
                    "freed_human": CleanupReport.componentPhrase(
                        exact: exact, estimatedUpTo: estimated
                    ),
                    "success": errs.isEmpty,
                ]
                if !errs.isEmpty {
                    item["error"] = errs.joined(separator: "; ")
                }
                cleaned.append(item)
            }

            // Exit contract (R5): total failure — every attempted category
            // errored and nothing was freed — exits 1 CLEAN_FAILED. An empty
            // candidate list is a SUCCESS (nothing eligible), and partial
            // failure stays exit 0 with per-item `success` flags.
            if cleanRunIsTotalFailure(
                successFlags: cleaned.map { ($0["success"] as? Bool) ?? false },
                freedExact: freedExactSoFar,
                freedEstimated: estimatedSoFar
            ) {
                exitWithError(code: "CLEAN_FAILED",
                              message: "No eligible category could be cleaned",
                              details: ["cleaned": cleaned, "target_gb": targetGB])
            }

            outputJSON([
                "target_gb": targetGB,
                "target_met": freedExactSoFar >= targetBytes,
                "total_freed_bytes": freedExactSoFar,
                "total_estimated_up_to_bytes": estimatedSoFar,
                "total_freed": CleanupReport.componentPhrase(
                    exact: freedExactSoFar, estimatedUpTo: estimatedSoFar
                ),
                "dry_run": false,
                "cleaned": cleaned,
            ] as [String: Any])
        }
    }

    // MARK: - Spotlight Tagging

    /// Tag all discovered cache directories with Spotlight metadata so
    /// `mdfind "kMDItemFinderComment == 'cacheout-managed'"` finds them.
    /// Also writes a `.cacheout-managed` marker file for `mdfind -name` queries.
    private static func handleSpotlight() async {
        let scanner = CacheScanner()
        let results = await scanner.scanAll(CacheCategory.allCategories)
        outputJSON(spotlightPayload(
            for: results, home: FileManager.default.homeDirectoryForCurrentUser
        ))
    }

    /// The spotlight tagging pass (fn-1.5). Writes are side effects against
    /// category roots, so every root is admitted through `PathGuard` under
    /// its own `CategoryAdmissionPolicy` BEFORE any xattr/marker write —
    /// same admit-before-side-effect shape as `CacheCleaner.cleanViaCommands`
    /// (R17 precedent). A `.denied` scan state is refused first: `exists` is
    /// computed as `state != .missing`, so without this check an unreadable
    /// root would still enter the tag loop. Refused roots are skipped and
    /// reported in the additive `refused` array. Non-private so hermetic
    /// tests can drive it with fixture results and an injected home.
    static func spotlightPayload(for results: [ScanResult], home: URL) -> [String: Any] {
        let pathGuard = PathGuard(home: home)
        var tagged: [[String: Any]] = []
        var refused: [[String: Any]] = []

        for result in results where result.exists {
            // Scan-state refusal first (R18 parity with the cleaner): the
            // scanner established the root is unreadable/refused — never
            // attempt writes against it.
            if result.state == .denied {
                let kind = result.scanError?.kind.wireString ?? "other"
                let message = result.scanError?.message ?? "access denied at scan time"
                for url in result.category.resolvedPaths {
                    refused.append([
                        "slug": result.category.slug,
                        "path": url.path,
                        "reason": "scan denied (\(kind)): \(message)",
                    ])
                }
                continue
            }

            let policy = CategoryAdmissionPolicy(category: result.category, home: home)
            for url in result.category.resolvedPaths {
                // Admission BEFORE any write — a refusal skips the root and
                // is reported, never silently swallowed.
                do {
                    _ = try pathGuard.admitDeletionRoot(url, policy: policy)
                } catch {
                    refused.append([
                        "slug": result.category.slug,
                        "path": url.path,
                        "reason": error.localizedDescription,
                    ])
                    continue
                }

                // 1. Write Finder comment via xattr — outcome captured, not
                // swallowed: a root is only reported "tagged" when at least
                // one discovery mechanism actually landed.
                var xattrWritten = false
                let comment = "cacheout-managed: \(result.category.slug)"
                let commentData = try? PropertyListSerialization.data(
                    fromPropertyList: comment, format: .binary, options: 0
                )
                if let data = commentData {
                    data.withUnsafeBytes { bytes in
                        url.withUnsafeFileSystemRepresentation { path in
                            guard let path = path else { return }
                            xattrWritten = setxattr(
                                path, "com.apple.metadata:kMDItemFinderComment",
                                bytes.baseAddress, data.count, 0, 0
                            ) == 0
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
                    tagged: \(ISO8601DateFormatter.shared.string(from: Date()))
                    """
                let markerWritten = (try? markerContent.write(
                    to: marker, atomically: true, encoding: .utf8
                )) != nil

                guard xattrWritten || markerWritten else {
                    refused.append([
                        "slug": result.category.slug,
                        "path": url.path,
                        "reason": "metadata writes failed: neither the Finder-comment "
                            + "xattr nor the .cacheout-managed marker could be written",
                    ])
                    continue
                }

                tagged.append([
                    "slug": result.category.slug,
                    "path": url.path,
                    "size": result.formattedSize,
                    "xattr_written": xattrWritten,
                    "marker_written": markerWritten,
                ])
            }
        }

        return [
            "tagged_count": tagged.count,
            "directories": tagged,
            "refused_count": refused.count,
            "refused": refused,
            "query_hint": "mdfind 'kMDItemFinderComment == \"cacheout-managed*\"'",
            "marker_hint": "mdfind -name .cacheout-managed",
        ]
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

    /// Re-exec through the real bundled binary when invoked via a symlink.
    ///
    /// The Homebrew cask exposes the CLI as a symlink
    /// (`/opt/homebrew/bin/cacheout` -> `Cacheout.app/Contents/MacOS/Cacheout`).
    /// When launched through that symlink, `Bundle.main` resolves to the
    /// symlink's directory rather than the app bundle, so
    /// `SMAppService.daemon(plistName:)` cannot find the embedded helper plist
    /// and reports `.notFound` even though the app is properly bundled.
    ///
    /// If the running executable is not inside an `.app` bundle but resolves
    /// (through symlinks) to a binary that is, replace the process image with
    /// the resolved binary so SMAppService sees the real bundle. No-ops for
    /// direct bundled invocations and for unbundled `.build` binaries.
    private static func reexecResolvedBundleBinaryIfNeeded() {
        // Main bundle already points at an .app — nothing to fix.
        guard !Bundle.main.bundlePath.hasSuffix(".app") else { return }

        // Get the path this process was exec'd with (may be a symlink).
        var capacity = UInt32(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        if _NSGetExecutablePath(&buffer, &capacity) != 0 {
            // Buffer too small — capacity now holds the required size.
            buffer = [CChar](repeating: 0, count: Int(capacity))
            guard _NSGetExecutablePath(&buffer, &capacity) == 0 else { return }
        }
        let execPath = URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: execPath).resolvingSymlinksInPath().path
        guard resolved != execPath, resolved.contains(".app/Contents/MacOS/") else { return }

        // Replace the process image; argv[0] becomes the resolved path so the
        // re-exec'd process' Bundle.main is the real app bundle.
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv[0] = strdup(resolved)
        argv.append(nil)
        execv(resolved, argv)
        // execv only returns on failure — continue and let SMAppService report.
        printError("Warning: failed to re-exec bundled binary at \(resolved): errno \(errno)")
    }

    /// Register the privileged helper daemon.
    /// Only works from a bundled app context where the plist is embedded at
    /// `Contents/Library/LaunchDaemons/`. Running from `.build/release/Cacheout`
    /// will report the helper as unavailable (not a crash).
    private static func handleInstallHelper() {
        reexecResolvedBundleBinaryIfNeeded()
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
        reexecResolvedBundleBinaryIfNeeded()
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
