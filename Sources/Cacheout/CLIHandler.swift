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
/// | `scan`        | Run every registered scanner and emit the schema-4 envelope (`categories` + `scanner_items` + `scanner_errors`) |
/// | `clean`       | Clean addressed targets: `<category-slug>`, `<scanner-slug>`, or `<scanner-slug>:<item-id>` |
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
/// - `--orphan-size-floor-mb N` / `--orphan-stale-days N`: invocation-scoped
///   orphaned-caches sweep thresholds (positive integers; decimal MB /
///   days). Accepted by `scan` and `clean` ONLY — EVERY other command
///   (smart-clean is frozen category-only; the rest never run the sweep)
///   REJECTS them with `INVALID_ARGUMENTS` before dispatch. Overrides the
///   persisted `cacheout.orphanedCaches.*` value for this invocation;
///   never persisted
/// - Clean targets are positional arguments after the command. A target is
///   one of `<category-slug>` (a category aggregate), `<scanner-slug>` (ALL
///   items of a per-item scanner, e.g. `node_modules`), or
///   `<scanner-slug>:<item-id>` (one item — the opaque id echoed from
///   `scan`'s `scanner_items`). The frozen aggregate scanner id
///   `categories` is NOT a valid target; address aggregates by their
///   category slug.
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
/// Cacheout --cli clean node_modules --confirm
/// Cacheout --cli clean node_modules:3f0c…e1 --confirm
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

        // Pre-dispatch gate: the sweep's config flags (R8) are accepted by
        // the commands that actually run the sweep scanner — scan and clean
        // ONLY. Every other command rejects them up front; silently
        // ignoring a threshold the caller passed would hide the flag
        // landing on the wrong command.
        if let flag = rejectedSweepFlag(for: command, in: args) {
            exitWithError(
                code: "INVALID_ARGUMENTS",
                message: sweepFlagRejectionMessage(flag: flag, command: command)
            )
        }

        switch command {
        case .version:
            handleVersion()

        case .diskInfo:
            await handleDiskInfo()

        case .scan:
            // The sweep's config flags (R8) are accepted by the commands
            // that actually run the sweep scanner — scan and clean.
            let sweepThresholds = resolveSweepThresholds(from: args)
            await handleScan(deps: .production(
                orphanedCachesThresholds: sweepThresholds
            ))

        case .clean:
            let slugs = extractSlugs(from: args, after: cliIndex + 1)
            let sweepThresholds = resolveSweepThresholds(from: args)
            await handleClean(
                slugs: slugs, dryRun: isDryRun, confirmed: isConfirmed,
                deps: .production(orphanedCachesThresholds: sweepThresholds)
            )

        case .smartClean:
            // smart-clean is frozen category-only (fn-2 round 10): the
            // sweep never runs there. Its sweep flags are a usage error,
            // not a silent no-op — rejected by the pre-dispatch gate above
            // along with every other non-scan/clean command.
            //
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
    private static let fallbackVersion = "2.2.0"

    /// App version: read from the bundle's Info.plist (stamped from the VERSION
    /// file by scripts/bundle.sh), falling back to the compiled constant when
    /// running as an unbundled binary.
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? fallbackVersion
    }

    /// Protocol schema version (PROTOCOL.md). 4 = scan output becomes the
    /// registry envelope (`categories` rows preserved field-for-field from
    /// schema 3, additive `scanner_items`/`scanner_errors`), clean targets
    /// follow the address grammar (`<category-slug>` | `<scanner-slug>` |
    /// `<scanner-slug>:<item-id>`), clean/smart-clean rows gain
    /// `scanner_id`/`item_id` identity fields, and EVERY payload
    /// self-describes with a top-level `schema_version` (fn-2.6, R7/R8).
    /// Schema 3's `--confirm` gate, exact-only totals, and `CLEAN_FAILED`
    /// contract are unchanged. Non-private so the schema tests assert the
    /// bump in-process.
    static let cliSchemaVersion = 4

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

    // MARK: - CLI runtime dependencies (fn-2.6 test seam)

    /// The injected dependency bundle the testable handler entry points
    /// consume: the scanner registry plus a cleaner factory. The
    /// process-facing handlers wire `production()` and stay thin shells;
    /// in-process tests inject fixture runtimes so addressing, resolution,
    /// gating, schema shape, AND the confirmed fixture deletion all run
    /// without a subprocess (subprocess tests stay gate-framing-only).
    struct CLIRuntimeDependencies {
        let runtime: SpaceScannerRuntime
        /// The registered category slugs — the aggregate half of the address
        /// namespace. Carried here (not read off the runtime) because the
        /// runtime keeps its category registry private; production and tests
        /// wire the same list they registered.
        let categorySlugs: Set<String>
        /// Cleaner factory, taking the SCAN SESSION's container snapshot
        /// (fn-3.4, R9 — one CLI invocation, one session: the cleaner must
        /// hold the snapshot of the session that produced the items it
        /// deletes; nil fail-closes every `.removeItem`). The default
        /// derives the cleaner FROM the runtime
        /// (`SpaceScannerRuntime.makeCleaner`) so delete-time container
        /// admission is exactly the scanner-declared union — tests may
        /// override to observe or redirect.
        let makeCleaner: (ContainerSnapshot?) -> CacheCleaner

        init(
            runtime: SpaceScannerRuntime,
            categorySlugs: Set<String>,
            makeCleaner: ((ContainerSnapshot?) -> CacheCleaner)? = nil
        ) {
            self.runtime = runtime
            self.categorySlugs = categorySlugs
            self.makeCleaner = makeCleaner
                ?? { runtime.makeCleaner(snapshot: $0) }
        }

        /// - Parameter orphanedCachesThresholds: invocation-scoped sweep
        ///   thresholds (R8) — nil resolves defaults → UserDefaults inside
        ///   the runtime factory; the CLI passes the flag-layered value.
        ///   Never persisted.
        static func production(
            orphanedCachesThresholds: OrphanedCacheClassifier.Thresholds? = nil
        ) -> CLIRuntimeDependencies {
            CLIRuntimeDependencies(
                runtime: .production(
                    orphanedCachesThresholds: orphanedCachesThresholds
                ),
                categorySlugs: Set(CacheCategory.allCategories.map(\.slug))
            )
        }
    }

    /// What a testable handler decided — the process-facing shell translates
    /// it into stdout/stderr/exit behavior. Pure data so the in-process
    /// tests assert the whole contract without `Foundation.exit`.
    enum CLIOutcome {
        case success([String: Any])
        case failure(code: String, message: String, details: [String: Any]?)
    }

    private static func render(_ outcome: CLIOutcome) {
        switch outcome {
        case .success(let payload):
            outputJSON(payload)
        case .failure(let code, let message, let details):
            exitWithError(code: code, message: message, details: details)
        }
    }

    /// One collected pass over the runtime's progressive validated event
    /// stream (the CLI is stateless: it COLLECTS to completion, unlike the
    /// ViewModel's as-they-arrive consumption). Validation lives in the
    /// runtime — no handler ever touches a raw outcome.
    struct CollectedScanEvents {
        var outcomes: [String: ScanOutcome] = [:]
        var malformed: [String: ScanIssue] = [:]
        /// The session's container-identity snapshot (fn-3.4, R9) — the
        /// ONE cleaner input for this invocation's confirmed run: the CLI's
        /// single invocation pairs items and snapshot naturally.
        var snapshot: ContainerSnapshot?
    }

    private static func collectValidatedScan(
        _ runtime: SpaceScannerRuntime,
        scannerIDs: Set<String>?,
        context: ScanContext
    ) async -> CollectedScanEvents {
        var collected = CollectedScanEvents()
        let session = runtime.scanValidatedSession(
            scannerIDs: scannerIDs, context: context
        )
        collected.snapshot = session.snapshot
        for await event in session.events {
            switch event {
            case .outcome(let scannerID, let outcome):
                collected.outcomes[scannerID] = outcome
            case .malformed(let scannerID, let issue):
                collected.malformed[scannerID] = issue
            }
        }
        return collected
    }

    // MARK: - Orphaned-caches sweep flags (fn-3.4, R8)

    /// Invocation-scoped overrides for the sweep scanner's thresholds,
    /// accepted by `scan` and `clean` ONLY (smart-clean is frozen
    /// category-only and rejects them). Values override the persisted
    /// UserDefaults value for this invocation and are NEVER persisted.
    static let orphanSizeFloorFlag = "--orphan-size-floor-mb"
    static let orphanStaleDaysFlag = "--orphan-stale-days"

    /// Pure parse of both sweep flags (in-process testable; the process
    /// shell translates a failure into the INVALID_ARGUMENTS exit). Each
    /// value must be a positive integer whose unit conversion does not
    /// overflow — zero, negative, non-numeric, and overflowing values are
    /// REJECTED (fail-safe R8), never silently defaulted. A REPEATED flag
    /// is likewise rejected: any first-/last-wins rule would silently
    /// ignore one of two contradictory values — and skip validating the
    /// ignored occurrence, letting `--orphan-size-floor-mb 1
    /// --orphan-size-floor-mb garbage` slip past the malformed-value gate.
    static func parseSweepThresholdOverrides(
        from args: [String]
    ) -> Result<(sizeFloorMB: Int64?, staleAgeDays: Int64?), CLIAddressError> {
        func parse(
            _ flag: String, converts: (Int64) -> Bool
        ) -> Result<Int64?, CLIAddressError> {
            let occurrences = args.indices.filter { args[$0] == flag }
            guard let index = occurrences.first else {
                return .success(nil)
            }
            guard occurrences.count == 1 else {
                return .failure(CLIAddressError(
                    message: "\(flag) may be specified at most once"
                ))
            }
            guard index + 1 < args.count else {
                return .failure(CLIAddressError(
                    message: "\(flag) requires a positive integer value"
                ))
            }
            let raw = args[index + 1]
            guard let value = Int64(raw), value > 0 else {
                return .failure(CLIAddressError(
                    message: "\(flag) requires a positive integer value, got: \(raw)"
                ))
            }
            guard converts(value) else {
                return .failure(CLIAddressError(
                    message: "\(flag) value \(raw) is too large — "
                        + "the converted value overflows"
                ))
            }
            return .success(value)
        }

        switch parse(orphanSizeFloorFlag, converts: {
            OrphanedCachesSweepConfig.sizeFloorBytes(fromMB: $0) != nil
        }) {
        case .failure(let error):
            return .failure(error)
        case .success(let floorMB):
            switch parse(orphanStaleDaysFlag, converts: {
                OrphanedCachesSweepConfig.staleAge(fromDays: $0) != nil
            }) {
            case .failure(let error):
                return .failure(error)
            case .success(let staleDays):
                return .success((floorMB, staleDays))
            }
        }
    }

    /// The first sweep flag present in an invocation of a command that
    /// never runs the orphaned-caches sweep, or nil. Only `scan` and
    /// `clean` run the sweep scanner — for every other command
    /// (smart-clean is frozen category-only, fn-2 round 10; the rest have
    /// no sweep at all) accepting the flags would be a silent no-op lie.
    /// `run()` turns a non-nil result into INVALID_ARGUMENTS before
    /// dispatch.
    static func rejectedSweepFlag(for command: Command, in args: [String]) -> String? {
        guard command != .scan, command != .clean else { return nil }
        return [orphanSizeFloorFlag, orphanStaleDaysFlag].first(where: args.contains)
    }

    /// smart-clean's view of the pre-dispatch gate — the original fn-3.4
    /// entry point, retained so existing callers (the OrphanedCachesScanner
    /// test surface) keep working; the gate itself is
    /// `rejectedSweepFlag(for:in:)`.
    static func smartCleanRejectedSweepFlag(in args: [String]) -> String? {
        rejectedSweepFlag(for: .smartClean, in: args)
    }

    /// The INVALID_ARGUMENTS message for a rejected sweep flag: names the
    /// offending flag, the command that refused it, and the commands that
    /// accept it (kept actionable — the caller's next invocation should be
    /// obvious from the refusal alone).
    static func sweepFlagRejectionMessage(flag: String, command: Command) -> String {
        "\(flag) is not accepted by \(command.rawValue) — only scan and "
            + "clean run the orphaned-caches sweep; use the flag with "
            + "scan or clean"
    }

    /// The process-facing resolution: parse both flags (exiting via the
    /// invalid-arguments convention on a bad value) and, when at least one
    /// is present, layer them over UserDefaults/defaults. `nil` — no flags
    /// — lets the production factory resolve persisted values itself.
    private static func resolveSweepThresholds(
        from args: [String]
    ) -> OrphanedCacheClassifier.Thresholds? {
        switch parseSweepThresholdOverrides(from: args) {
        case .failure(let error):
            exitWithError(code: "INVALID_ARGUMENTS", message: error.message)
        case .success(let overrides):
            guard overrides.sizeFloorMB != nil
                || overrides.staleAgeDays != nil else { return nil }
            return OrphanedCachesSweepConfig.resolvedThresholds(
                sizeFloorMBOverride: overrides.sizeFloorMB,
                staleAgeDaysOverride: overrides.staleAgeDays
            )
        }
    }

    // MARK: - Scan (schema 4 envelope)

    private static func handleScan(deps: CLIRuntimeDependencies) async {
        outputJSON(await scanEnvelope(deps: deps))
    }

    /// The schema-4 scan envelope (R2/R8): ALL registered scanners, nil
    /// `categoryFilter`, a CLI invocation is an explicit user act
    /// (`.userInitiated`). `categories` preserves schema 3's rows
    /// field-for-field (NO identity fields — round 7); `scanner_items` and
    /// `scanner_errors` are additive. A malformed scanner's items are
    /// excluded from the envelope (and from addressability) and its
    /// synthesized path-less issue lands in `scanner_errors`; the remaining
    /// valid scanners' rows are intact.
    static func scanEnvelope(deps: CLIRuntimeDependencies) async -> [String: Any] {
        let collected = await collectValidatedScan(
            deps.runtime, scannerIDs: nil,
            context: ScanContext(trigger: .userInitiated)
        )

        var categories: [[String: Any]] = []
        var scannerItems: [[String: Any]] = []
        var scannerErrors: [[String: Any]] = []

        // Deterministic wire order: registration order across scanners
        // (stream events complete in nondeterministic order), outcome order
        // within a scanner (CacheScanner.scanAll is size-descending — the
        // schema-3 scan order, preserved).
        for scanner in deps.runtime.scanners {
            let scannerID = scanner.id
            if let issue = collected.malformed[scannerID] {
                scannerErrors.append(
                    scannerErrorRowJSON(scannerID: scannerID, issue: issue)
                )
                continue
            }
            guard let outcome = collected.outcomes[scannerID] else { continue }
            if scannerID == CategoryScanner.registeredID {
                categories.append(contentsOf: outcome.items.map(categoryRowJSON(for:)))
            } else {
                scannerItems.append(contentsOf: outcome.items.map(scannerItemRowJSON(for:)))
            }
            scannerErrors.append(contentsOf: outcome.errors.map {
                scannerErrorRowJSON(scannerID: scannerID, issue: $0)
            })
        }

        return [
            "schema_version": cliSchemaVersion,
            "categories": categories,
            "scanner_items": scannerItems,
            "scanner_errors": scannerErrors,
        ]
    }

    /// One `categories` row from the aggregate item — field-for-field the
    /// schema-3 `scanItemJSON` shape (the envelope test asserts the two
    /// stay identical on the same fixture input), sourced from the
    /// adapter's mappings: `evidence` IS the category description and
    /// `rebuildNote` the category's note (`CategoryScanner.item(from:)`).
    /// Deliberately NO `scanner_id`/`item_id` here (round 7): identity
    /// fields live on `scanner_items` and the clean/smart-clean rows ONLY.
    static func categoryRowJSON(for item: ReclaimableItem) -> [String: Any] {
        var row: [String: Any] = [
            "slug": item.id,
            "name": item.displayName,
            "size_bytes": item.allocatedBytes,
            "size_human": ByteCountFormatter.sharedFile.string(
                fromByteCount: item.allocatedBytes
            ),
            "item_count": item.itemCount,
            "exists": item.state != .missing,
            "risk_level": item.risk.rawValue.lowercased(),
            "description": item.evidence,
            "rebuild_note": item.rebuildNote ?? "",
            "state": item.state.rawValue,
            "exact_bytes": item.exactBytes,
            "estimated_up_to_bytes": item.estimatedUpToBytes,
        ]
        if let scanError = item.scanError {
            row["scan_error"] = [
                "kind": scanError.kind.wireString,
                "message": scanError.message,
            ] as [String: Any]
            if scanError.kind == .tccDenied {
                row["grant_hint"] = tccGrantHint
            }
        }
        return row
    }

    /// One `scanner_items` row (additive, R8): `item_id` is the full-hash
    /// opaque stable id, ALWAYS beside its `scanner_id` sibling (a bare
    /// item id is meaningful only in scanner scope). `action` serializes
    /// ONLY the wire kind — argv arrays never appear anywhere in CLI output.
    static func scannerItemRowJSON(for item: ReclaimableItem) -> [String: Any] {
        var row: [String: Any] = [
            "scanner_id": item.scannerID,
            "item_id": item.id,
            // The resolved location when one exists; the declared spelling
            // otherwise — never a fake resolution.
            "path": item.url?.path ?? item.declaredDisplayPath,
            "name": item.displayName,
            "state": item.state.rawValue,
            "exact_bytes": item.exactBytes,
            "estimated_up_to_bytes": item.estimatedUpToBytes,
            "size_bytes": item.allocatedBytes,
            "item_count": item.itemCount,
            "risk_level": item.risk.rawValue.lowercased(),
            "evidence": item.evidence,
            "action": item.action.wireString,
        ]
        if let scanError = item.scanError {
            row["scan_error"] = [
                "kind": scanError.kind.wireString,
                "message": scanError.message,
            ] as [String: Any]
            if scanError.kind == .tccDenied {
                row["grant_hint"] = tccGrantHint
            }
        }
        return row
    }

    /// One `scanner_errors` row. `path` is CONDITIONAL (round 7): present
    /// for the filesystem kinds, ABSENT for `malformed_outcome` — a fake
    /// path must never be invented. `grant_hint` is CONDITIONAL: present
    /// only for `tcc_denied` — the same remedy category and per-item rows
    /// carry, since macOS denies CLI processes silently (no consent prompt).
    static func scannerErrorRowJSON(
        scannerID: String, issue: ScanIssue
    ) -> [String: Any] {
        var row: [String: Any] = [
            "scanner_id": scannerID,
            "kind": issue.kind.wireString,
            "detail": issue.detail,
        ]
        if let url = issue.url {
            row["path"] = url.path
        }
        if issue.kind == .tccDenied {
            row["grant_hint"] = tccGrantHint
        }
        return row
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
    ///
    /// Since fn-2.6 the scan wire path emits `categoryRowJSON(for:)` from
    /// the validated aggregate items; THIS builder is the frozen schema-3
    /// row shape, retained as the field-for-field parity comparator the
    /// envelope tests assert against (R8 — "byte-compat rows inside the new
    /// envelope" is checkable only against the original builder).
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

    // MARK: - Clean target grammar (R7, permanent contract)

    /// A target-address refusal — the INVALID_ARGUMENTS message, typed so
    /// the parse/resolve helpers can return `Result` values the pipeline
    /// (and tests) branch on.
    struct CLIAddressError: Error, Equatable {
        let message: String
    }

    /// One parsed positional clean target. Slugs match `[a-z0-9_]+` (no
    /// colon — the registry validates that at registration), so the FIRST
    /// `:` splits scanner slug from item id unambiguously; item ids are
    /// OPAQUE full-hash strings the CLI never parses or derives — callers
    /// echo back exactly what `scan` printed.
    enum CleanTarget: Equatable {
        /// `<category-slug>` — one category aggregate (unchanged from
        /// schema 3).
        case category(String)
        /// `<scanner-slug>` — ALL items of that per-item scanner.
        case allScannerItems(String)
        /// `<scanner-slug>:<item-id>` — one item.
        case scannerItem(scannerID: String, itemID: String)
    }

    /// Parse + validate the positional targets against the registered
    /// namespace (collision-free by the runtime's registration check, so a
    /// bare token resolves to whichever exists). The frozen aggregate
    /// scanner id `categories` is NOT a valid target in ANY form — a
    /// scanner-wide token over 23 aggregates would be a mass-clean footgun
    /// (epic contract); category aggregates are addressed by category slug
    /// only. Duplicate tokens dedupe in argument order (schema-3 parity).
    /// Failure returns the INVALID_ARGUMENTS message naming EVERY bad
    /// token, mirroring the schema-3 unknown-slug behavior.
    static func parseCleanTargets(
        _ tokens: [String],
        categorySlugs: Set<String>,
        perItemScannerIDs: Set<String>
    ) -> Result<[CleanTarget], CLIAddressError> {
        var targets: [CleanTarget] = []
        var invalid: [String] = []
        var seen = Set<String>()
        for token in tokens {
            guard seen.insert(token).inserted else { continue }
            let base: String
            let itemID: String?
            if let colon = token.firstIndex(of: ":") {
                base = String(token[..<colon])
                itemID = String(token[token.index(after: colon)...])
            } else {
                base = token
                itemID = nil
            }
            // The aggregate scanner id is excluded from addressing outright
            // — bare AND `categories:<anything>` forms both fail.
            if base == CategoryScanner.registeredID {
                invalid.append(token)
                continue
            }
            if let itemID {
                guard !itemID.isEmpty, perItemScannerIDs.contains(base) else {
                    invalid.append(token)
                    continue
                }
                targets.append(.scannerItem(scannerID: base, itemID: itemID))
            } else if categorySlugs.contains(base) {
                targets.append(.category(base))
            } else if perItemScannerIDs.contains(base) {
                targets.append(.allScannerItems(base))
            } else {
                invalid.append(token)
            }
        }
        guard invalid.isEmpty else {
            return .failure(CLIAddressError(message:
                "Unknown or invalid target(s): \(invalid.joined(separator: ", ")). "
                + "A target is <category-slug>, <scanner-slug>, or "
                + "<scanner-slug>:<item-id> ('categories' is not addressable). "
                + "Use 'scan' to list valid slugs and item ids."
            ))
        }
        return .success(targets)
    }

    /// What target resolution selected: the deduped items PLUS the
    /// root/scanner-level scan issues carried by every BARE
    /// `<scanner-slug>` target's outcome. A scanner-wide selection is only
    /// as complete as the scan that backed it, so its impediments travel
    /// WITH the selection instead of being discarded — a fully-denied
    /// scanner must be visible as an impeded no-op, never a clean success.
    /// Explicitly addressed `<scanner>:<item>` targets carry no
    /// scanner-level issues: the addressed item WAS discovered, so root
    /// problems did not impede that specific operation.
    struct ResolvedCleanSelection {
        var items: [ReclaimableItem] = []
        var scannerErrors: [(scannerID: String, issue: ScanIssue)] = []
    }

    /// Resolve parsed targets AGAINST THE VALIDATED SCAN RESULTS ONLY
    /// (round 8): a malformed scanner's items are unaddressable by
    /// construction — any target referencing one fails with the same
    /// unknown/invalid-target message, and nothing is selected, addressed,
    /// or deleted. Items dedupe by `ItemKey` in first-appearance order
    /// (`clean node_modules node_modules:<id>` names the item once).
    static func resolveCleanTargets(
        _ targets: [CleanTarget],
        outcomes: [String: ScanOutcome],
        malformed: [String: ScanIssue]
    ) -> Result<ResolvedCleanSelection, CLIAddressError> {
        var selection = ResolvedCleanSelection()
        var seenKeys = Set<ItemKey>()
        var seenErrorScanners = Set<String>()

        func append(_ item: ReclaimableItem) {
            guard seenKeys.insert(item.key).inserted else { return }
            selection.items.append(item)
        }

        for target in targets {
            switch target {
            case .category(let slug):
                let adapterID = CategoryScanner.registeredID
                if malformed[adapterID] != nil {
                    return .failure(CLIAddressError(message: malformedTargetMessage(
                        token: slug, scannerID: adapterID
                    )))
                }
                guard let item = outcomes[adapterID]?.items
                    .first(where: { $0.id == slug }) else {
                    // Unreachable with the adapter registered (it emits an
                    // item for every category, `.missing` included) — kept
                    // fail-closed rather than assumed.
                    return .failure(CLIAddressError(message:
                        "Target '\(slug)' did not resolve to a scanned category. "
                        + "Use 'scan' to list valid slugs."
                    ))
                }
                append(item)

            case .allScannerItems(let scannerID):
                if malformed[scannerID] != nil {
                    return .failure(CLIAddressError(message: malformedTargetMessage(
                        token: scannerID, scannerID: scannerID
                    )))
                }
                // Zero items is a legitimate no-op (like cleaning an empty
                // category), not an error — but ONLY when the scan actually
                // looked everywhere: root/scanner-level issues (TCC or
                // permission denials, refused roots) ride along with the
                // selection so an impeded scanner-wide clean is reported as
                // impeded, never as a clean empty success.
                let outcome = outcomes[scannerID]
                for item in outcome?.items ?? [] {
                    append(item)
                }
                if let outcome, !outcome.errors.isEmpty,
                   seenErrorScanners.insert(scannerID).inserted {
                    for issue in outcome.errors {
                        selection.scannerErrors.append((scannerID, issue))
                    }
                }

            case .scannerItem(let scannerID, let itemID):
                if malformed[scannerID] != nil {
                    return .failure(CLIAddressError(message: malformedTargetMessage(
                        token: "\(scannerID):\(itemID)", scannerID: scannerID
                    )))
                }
                guard let item = outcomes[scannerID]?.items
                    .first(where: { $0.id == itemID }) else {
                    return .failure(CLIAddressError(message:
                        "Unknown item id for scanner '\(scannerID)': '\(itemID)'. "
                        + "Item ids are opaque and echoed from 'scan' output — rescan and retry."
                    ))
                }
                append(item)
            }
        }
        return .success(selection)
    }

    /// The unknown/invalid-target refusal for addresses that reach a
    /// malformed scanner (fail-closed — its items cannot be listed,
    /// selected, addressed, or deleted through any path).
    private static func malformedTargetMessage(
        token: String, scannerID: String
    ) -> String {
        "Target '\(token)' cannot be resolved: scanner '\(scannerID)' produced "
        + "a malformed outcome and its items are excluded (see 'scan' "
        + "scanner_errors). Nothing was cleaned."
    }

    // MARK: - Clean plan builders (item-based, schema 4)

    /// The retained `category`/`slug` wire value, frozen BY ITEM TYPE
    /// (round 9): aggregate rows keep the category SLUG unchanged; per-item
    /// rows carry the canonical composite ADDRESS `<scanner_id>:<item_id>` —
    /// directly reusable as a clean target token. `scanner_id`/`item_id`
    /// ride as separate sibling fields on every row regardless, so
    /// consumers never parse the composite.
    static func addressValue(for item: ReclaimableItem) -> String {
        item.scannerID == CategoryScanner.registeredID
            ? item.id
            : "\(item.scannerID):\(item.id)"
    }

    /// What the real run would do with one resolved item — the same
    /// decisions `CacheCleaner.clean(items:)` takes (missing/empty skipped,
    /// `.denied` refused even force-selected, `.partiallyDenied` proceeds
    /// with a warning). Drives both the `CONFIRMATION_REQUIRED` plan and
    /// the dry-run payload so preview and reality cannot drift.
    ///
    /// Aggregates keep the schema-3 zero-byte "skip" (the as-built
    /// `isEmpty` plan decision — a zero-byte aggregate clean yields no
    /// entry either way). Per-item rows follow the unified dispatch
    /// exactly: `.removeItem` has NO zero-byte skip (a `.measured` item
    /// with countable-but-zero-byte content IS deleted), so only the state
    /// gates decide.
    static func cleanPlanAction(for item: ReclaimableItem) -> String {
        if item.state == .missing { return "skip" }
        if item.state == .denied { return "refuse" }
        if item.state == .empty { return "skip" }
        if item.scannerID == CategoryScanner.registeredID,
           item.allocatedBytes == 0 {
            return "skip"
        }
        return item.state == .partiallyDenied ? "clean_with_warning" : "clean"
    }

    /// One plan entry (scan-time split components — never a re-walk, R16).
    /// Schema-3 fields retained verbatim; `scanner_id`/`item_id` identity
    /// fields are additive on every row (schema 4).
    static func cleanPlanItemJSON(for item: ReclaimableItem) -> [String: Any] {
        var row: [String: Any] = [
            "slug": addressValue(for: item),
            "name": item.displayName,
            "state": item.state.rawValue,
            "action": cleanPlanAction(for: item),
            "exact_bytes": item.exactBytes,
            "estimated_up_to_bytes": item.estimatedUpToBytes,
            "scanner_id": item.scannerID,
            "item_id": item.id,
        ]
        if item.state == .partiallyDenied {
            row["warning"] = partiallyDeniedCleanWarning
        }
        if let scanError = item.scanError {
            row["scan_error"] = [
                "kind": scanError.kind.wireString,
                "message": scanError.message,
            ] as [String: Any]
        }
        return row
    }

    /// Exact-only totals over the entries the plan would actually clean.
    /// SATURATING (round 8): a multi-target plan can span scanners, and
    /// the validator bounds each scanner's outcome only individually —
    /// clamp at Int64.max instead of trapping (byte-identical for every
    /// physically possible total).
    private static func cleanPlanTotals(_ items: [ReclaimableItem]) -> (exact: Int64, estimated: Int64) {
        items.reduce(into: (exact: Int64(0), estimated: Int64(0))) { totals, item in
            let action = cleanPlanAction(for: item)
            guard action == "clean" || action == "clean_with_warning" else { return }
            totals.exact = totals.exact.saturatingAdding(item.exactBytes)
            totals.estimated = totals.estimated
                .saturatingAdding(item.estimatedUpToBytes)
        }
    }

    /// The `CONFIRMATION_REQUIRED` details payload for `clean` (R5): the
    /// same per-item decisions the confirmed run would take.
    /// `scannerErrors` carries the bare-scanner-target scan impediments
    /// (additive `scanner_errors`, same frozen row shape as `scan`'s) —
    /// present only when non-empty, so pre-existing payloads are unchanged.
    static func cleanConfirmationDetails(
        for items: [ReclaimableItem],
        scannerErrors: [[String: Any]] = []
    ) -> [String: Any] {
        let totals = cleanPlanTotals(items)
        var details: [String: Any] = [
            "command": "clean",
            "plan": items.map { cleanPlanItemJSON(for: $0) },
            "total_exact_bytes": totals.exact,
            "total_estimated_up_to_bytes": totals.estimated,
        ]
        if !scannerErrors.isEmpty {
            details["scanner_errors"] = scannerErrors
        }
        return details
    }

    /// Dry-run clean payload (R16): built from the SCAN-TIME split
    /// components — no re-walk, and `total_would_free` counts exact bytes
    /// only (estimates are additive, never laundered into the total).
    /// Self-describes with `schema_version` (round 8 — every payload).
    /// `scannerErrors` (additive `scanner_errors`, `scan`'s frozen row
    /// shape) surfaces bare-scanner-target scan impediments; the key is
    /// present only when non-empty.
    static func cleanDryRunPayload(
        for items: [ReclaimableItem],
        scannerErrors: [[String: Any]] = []
    ) -> [String: Any] {
        let entries: [[String: Any]] = items.map { item in
            var row = cleanPlanItemJSON(for: item)
            let action = cleanPlanAction(for: item)
            let cleans = action == "clean" || action == "clean_with_warning"
            let exact = cleans ? item.exactBytes : 0
            let estimated = cleans ? item.estimatedUpToBytes : 0
            row["bytes_would_free"] = exact
            row["freed_human"] = CleanupReport.componentPhrase(
                exact: exact, estimatedUpTo: estimated
            )
            return row
        }
        let totals = cleanPlanTotals(items)
        var payload: [String: Any] = [
            "schema_version": cliSchemaVersion,
            "dry_run": true,
            "total_would_free": totals.exact,
            "total_estimated_up_to_bytes": totals.estimated,
            "results": entries,
        ]
        if !scannerErrors.isEmpty {
            payload["scanner_errors"] = scannerErrors
        }
        return payload
    }

    /// Additive per-scanner rollup rows (fn-2.3's report derivation on the
    /// wire): pure sums per `scanner_id`, first-appearance order.
    static func scannerRollupRows(_ report: CleanupReport) -> [[String: Any]] {
        report.scannerRollups.map { rollup in
            [
                "scanner_id": rollup.scannerID,
                "exact_bytes": rollup.exactBytes,
                "estimated_up_to_bytes": rollup.estimatedUpToBytes,
                "bytes_freed": rollup.bytesFreed,
                "entry_count": rollup.entryCount,
            ] as [String: Any]
        }
    }

    private static func handleClean(
        slugs: [String], dryRun: Bool, confirmed: Bool,
        deps: CLIRuntimeDependencies
    ) async {
        render(await cleanCLIOutcome(
            targets: slugs, dryRun: dryRun, confirmed: confirmed,
            euid: geteuid(), deps: deps
        ))
    }

    /// The whole `clean` decision pipeline, injected and exit-free so the
    /// in-process tests drive it end-to-end (addressing, resolution,
    /// gating, schema shape, AND the confirmed fixture deletion). Check
    /// order preserved from schema 3: usage → target validation → gate →
    /// read-only scan → branch.
    static func cleanCLIOutcome(
        targets rawTargets: [String],
        dryRun: Bool, confirmed: Bool, euid: uid_t,
        deps: CLIRuntimeDependencies
    ) async -> CLIOutcome {
        // The contract requires one or more targets — an empty list must
        // not masquerade as a successful no-op clean.
        guard !rawTargets.isEmpty else {
            return .failure(
                code: "MISSING_ARGUMENT",
                message: "Usage: Cacheout --cli clean <targets...> [--confirm|--dry-run]. "
                    + "A target is <category-slug>, <scanner-slug>, or "
                    + "<scanner-slug>:<item-id>. Use 'scan' to list them.",
                details: nil
            )
        }

        let perItemScannerIDs = Set(deps.runtime.scanners.map(\.id))
            .subtracting([CategoryScanner.registeredID])
        let parsed: [CleanTarget]
        switch parseCleanTargets(
            rawTargets,
            categorySlugs: deps.categorySlugs,
            perItemScannerIDs: perItemScannerIDs
        ) {
        case .failure(let error):
            return .failure(code: "INVALID_ARGUMENTS", message: error.message, details: nil)
        case .success(let targets):
            parsed = targets
        }

        // Gate decision BEFORE any scan (D5). The unconfirmed branch still
        // scans below — read-only — because its refusal carries the plan.
        let decision = cleanGateDecision(confirmed: confirmed, dryRun: dryRun, euid: euid)
        if case .refuseRootUser = decision {
            return .failure(code: "ROOT_REFUSED", message: rootRefusalMessage, details: nil)
        }

        // Target-scoped scan (R2, rounds 9-10): ONLY the scanners the
        // parsed targets reference run, and `categoryFilter` carries
        // EXACTLY the requested category slugs — requested-categories-only
        // holds at BOTH granularities (a category clean never invokes a
        // per-item scanner, and never walks unrequested categories'
        // resolvers/probes inside CategoryScanner).
        var requestedCategorySlugs = Set<String>()
        var scannerSubset = Set<String>()
        for target in parsed {
            switch target {
            case .category(let slug):
                requestedCategorySlugs.insert(slug)
                scannerSubset.insert(CategoryScanner.registeredID)
            case .allScannerItems(let scannerID):
                scannerSubset.insert(scannerID)
            case .scannerItem(let scannerID, _):
                scannerSubset.insert(scannerID)
            }
        }
        let collected = await collectValidatedScan(
            deps.runtime, scannerIDs: scannerSubset,
            context: ScanContext(
                trigger: .userInitiated,
                categoryFilter: requestedCategorySlugs
            )
        )

        // Address resolution NEVER sees unvalidated data (round 8).
        let selection: ResolvedCleanSelection
        switch resolveCleanTargets(
            parsed, outcomes: collected.outcomes, malformed: collected.malformed
        ) {
        case .failure(let error):
            return .failure(code: "INVALID_ARGUMENTS", message: error.message, details: nil)
        case .success(let resolved):
            selection = resolved
        }
        let items = selection.items
        // Bare-scanner-target scan impediments as `scan`'s frozen
        // `scanner_errors` rows — surfaced on EVERY branch below (plan,
        // dry-run, confirmed) so a denied or partially-denied scanner-wide
        // clean is never reported as an unimpeded success (P2). Scan-time
        // impediments are payload DATA (the `scan` envelope precedent);
        // exit codes stay reserved for clean-time failures.
        let scannerErrorRows = selection.scannerErrors.map {
            scannerErrorRowJSON(scannerID: $0.scannerID, issue: $0.issue)
        }

        switch decision {
        case .refuseRootUser:
            preconditionFailure("unreachable — refused before scanning")

        case .refuseUnconfirmed:
            // Stdout stays EMPTY; the plan rides in the stderr details (R5).
            return .failure(
                code: "CONFIRMATION_REQUIRED",
                message: "clean deletes cache contents and requires --confirm (preview with --dry-run)",
                details: cleanConfirmationDetails(
                    for: items, scannerErrors: scannerErrorRows
                )
            )

        case .dryRun:
            return .success(cleanDryRunPayload(
                for: items, scannerErrors: scannerErrorRows
            ))

        case .proceed:
            // One invocation, one session (R9): the cleaner holds the
            // snapshot of the very scan that resolved these items.
            let cleaner = deps.makeCleaner(collected.snapshot)
            let report = await cleaner.clean(items: items, moveToTrash: false)
            return confirmedCleanPayload(
                items: items, report: report, scannerErrors: scannerErrorRows
            )
        }
    }

    /// The confirmed-run wire payload. Rows correlate report entries and
    /// errors by `ItemKey` (never display-name lookup): every resolved
    /// aggregate gets a row — including a `success: true` row for a slug
    /// that produced neither entry nor error (zero-byte success,
    /// missing/empty skip; `entries.isEmpty` is NOT a total-failure
    /// signal). Per-item `.empty`/`.missing` items are the cleaner's
    /// silent pre-admission skip (round 9) and get NO row — nothing was
    /// deleted and no error occurred, even when explicitly addressed.
    /// `scannerErrors` (additive `scanner_errors`, `scan`'s frozen row
    /// shape) reports bare-scanner-target scan impediments on BOTH result
    /// arms — the success payload and the `CLEAN_FAILED` details — present
    /// only when non-empty. A fully-denied scanner-wide target therefore
    /// yields empty `results` WITH the denial rows: an impeded no-op, not
    /// a silent success. The exit contract is unchanged — scan-time
    /// impediments never flip the exit code (the `scan` envelope
    /// precedent); `CLEAN_FAILED` stays a delete-time verdict.
    private static func confirmedCleanPayload(
        items: [ReclaimableItem], report: CleanupReport,
        scannerErrors: [[String: Any]] = []
    ) -> CLIOutcome {
        let entriesByKey = Dictionary(
            report.entries.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let errorsByKey = Dictionary(grouping: report.errors, by: \.key)

        var rows: [[String: Any]] = []
        for item in items {
            if item.scannerID != CategoryScanner.registeredID,
               item.state == .empty || item.state == .missing {
                continue
            }
            let entry = entriesByKey[item.key]
            let errs = (errorsByKey[item.key] ?? []).map(\.message)
            let exact = entry?.exactBytes ?? 0
            let estimated = entry?.estimatedUpToBytes ?? 0
            var row: [String: Any] = [
                "category": addressValue(for: item),
                "name": item.displayName,
                "bytes_freed": exact,
                "exact_bytes": exact,
                "estimated_up_to_bytes": estimated,
                "freed_human": CleanupReport.componentPhrase(
                    exact: exact, estimatedUpTo: estimated
                ),
                "success": errs.isEmpty,
                "scanner_id": item.scannerID,
                "item_id": item.id,
            ]
            if !errs.isEmpty {
                row["error"] = errs.joined(separator: "; ")
            }
            if item.state == .partiallyDenied {
                row["warning"] = partiallyDeniedCleanWarning
            }
            rows.append(row)
        }

        // Exit contract (R5): TOTAL failure — every requested target
        // errored and nothing was freed — exits 1 CLEAN_FAILED with an
        // empty stdout. Partial success stays exit 0 with per-item
        // `success` flags.
        if cleanRunIsTotalFailure(
            successFlags: rows.map { ($0["success"] as? Bool) ?? false },
            freedExact: report.totalFreedExact,
            freedEstimated: report.totalEstimatedUpTo
        ) {
            var details: [String: Any] = ["results": rows]
            if !scannerErrors.isEmpty {
                details["scanner_errors"] = scannerErrors
            }
            return .failure(
                code: "CLEAN_FAILED",
                message: "No requested target could be cleaned",
                details: details
            )
        }

        var payload: [String: Any] = [
            "schema_version": cliSchemaVersion,
            "dry_run": false,
            "total_freed_bytes": report.totalFreedExact,
            "total_estimated_up_to_bytes": report.totalEstimatedUpTo,
            "total_freed": CleanupReport.componentPhrase(
                exact: report.totalFreedExact,
                estimatedUpTo: report.totalEstimatedUpTo
            ),
            "results": rows,
            "scanner_rollups": scannerRollupRows(report),
        ]
        if !scannerErrors.isEmpty {
            payload["scanner_errors"] = scannerErrors
        }
        return .success(payload)
    }

    /// Smart-clean eligibility + order — policy (c), EXCLUSIVELY this
    /// handler's (epic round 10; the GUI never runs it). Preserved
    /// byte-for-byte from schema 3 (R18): only cleanly-measured items with
    /// bytes qualify — `.denied` AND `.partiallyDenied` are skipped (the
    /// auto path must never ride on a floor measurement), and caution-risk
    /// items are excluded entirely. Safe before review, larger first
    /// within a tier. Exactly ONE addition (epic contract):
    /// `automaticCleanEligible == false` items are excluded — in practice
    /// only node_modules, which becoming CLI-visible must not silently
    /// enroll in any automatic destructive path. (Vacuously true today:
    /// smart-clean scans the `categories` scanner only, whose aggregates
    /// are all eligible — the filter is the model-encoded guarantee, not a
    /// behavior change.)
    static func smartCleanCandidates(_ items: [ReclaimableItem]) -> [ReclaimableItem] {
        items
            .filter {
                $0.state == .measured && $0.allocatedBytes > 0
                    && $0.risk != .caution
                    && $0.automaticCleanEligible
            }
            .sorted { a, b in
                let riskOrder: [RiskLevel: Int] = [.safe: 0, .review: 1, .caution: 2]
                let aOrder = riskOrder[a.risk] ?? 99
                let bOrder = riskOrder[b.risk] ?? 99
                if aOrder != bOrder { return aOrder < bOrder }
                return a.allocatedBytes > b.allocatedBytes
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
        items: [ReclaimableItem], targetBytes: Int64
    ) -> (entries: [[String: Any]], totalExact: Int64, totalEstimated: Int64, targetMet: Bool) {
        var freedExact: Int64 = 0
        var estimated: Int64 = 0
        var entries: [[String: Any]] = []
        for item in smartCleanCandidates(items) {
            // Plan shape parity with `clean` (PROTOCOL.md details.plan):
            // every candidate passed the `.measured` filter, so the derived
            // action is "clean" — derived, not hardcoded, so the two
            // commands cannot drift — until the projection meets the
            // target, after which candidates become conditional fallbacks.
            let isFallback = freedExact >= targetBytes
            let projectedExact = isFallback ? 0 : item.exactBytes
            let projectedEstimated = isFallback ? 0 : item.estimatedUpToBytes
            freedExact += projectedExact
            estimated += projectedEstimated
            entries.append([
                "slug": addressValue(for: item),
                "name": item.displayName,
                "state": item.state.rawValue,
                "action": isFallback ? "clean_if_needed" : cleanPlanAction(for: item),
                "bytes_freed": projectedExact,
                "exact_bytes": item.exactBytes,
                "estimated_up_to_bytes": item.estimatedUpToBytes,
                "freed_human": CleanupReport.componentPhrase(
                    exact: projectedExact,
                    estimatedUpTo: projectedEstimated
                ),
                "scanner_id": item.scannerID,
                "item_id": item.id,
            ])
        }
        return (entries, freedExact, estimated, freedExact >= targetBytes)
    }

    private static func handleSmartClean(targetGB: Double, dryRun: Bool, confirmed: Bool) async {
        render(await smartCleanCLIOutcome(
            targetGB: targetGB, dryRun: dryRun, confirmed: confirmed,
            euid: geteuid(), deps: .production()
        ))
    }

    /// The whole `smart-clean` decision pipeline, injected and exit-free
    /// (test seam parity with `cleanCLIOutcome`). Scope is policy (c)'s:
    /// the aggregate `categories` scanner ONLY — no per-item scanner is
    /// ever invoked (round 10), so node_modules can never enter the
    /// automatic path. Decision logic byte-identical to schema 3; target
    /// math untouched.
    static func smartCleanCLIOutcome(
        targetGB: Double, dryRun: Bool, confirmed: Bool, euid: uid_t,
        deps: CLIRuntimeDependencies
    ) async -> CLIOutcome {
        // Usage validation first (parity with clean's target guard): a
        // non-finite or negative target would trap in the Int64 conversion
        // below (nan/inf) or produce nonsense; a ZERO target is already met
        // before anything runs (contradictory plan/target_met semantics);
        // a target past ~8e9 GB would overflow Int64. Refuse with the
        // documented usage error instead.
        guard targetGB.isFinite, targetGB > 0, targetGB <= 1_000_000_000 else {
            return .failure(
                code: "INVALID_ARGUMENTS",
                message: "smart-clean target must be a finite number of GB greater than 0 and at most 1000000000, got: \(targetGB)",
                details: nil
            )
        }
        // Validate the CONVERTED value too: a positive sub-byte target
        // (e.g. 1e-20 GB) truncates to zero bytes and would recreate the
        // zero-target contradiction — target_met true, nothing cleaned.
        let targetBytes = Int64(targetGB * 1024 * 1024 * 1024)
        guard targetBytes > 0 else {
            return .failure(
                code: "INVALID_ARGUMENTS",
                message: "smart-clean target must convert to at least one byte, got: \(targetGB) GB",
                details: nil
            )
        }

        // Gate decision BEFORE any scan (D5); unconfirmed still scans
        // read-only below to build the refusal plan.
        let decision = cleanGateDecision(confirmed: confirmed, dryRun: dryRun, euid: euid)
        if case .refuseRootUser = decision {
            return .failure(code: "ROOT_REFUSED", message: rootRefusalMessage, details: nil)
        }

        // The aggregate scanner only, all categories (nil filter), through
        // the validated entry point. A malformed `categories` outcome fails
        // closed LOUDLY (spotlight precedent): nothing is published, so
        // silently deriving an empty candidate list would make a rejected
        // scanner indistinguishable from the documented "nothing eligible"
        // success. The check precedes the gate switch, so all three surfaces
        // — unconfirmed plan, --dry-run, confirmed run — fail identically.
        // (Unreachable with the production adapter, whose outcomes satisfy
        // the validator's invariants by construction.)
        let collected = await collectValidatedScan(
            deps.runtime, scannerIDs: [CategoryScanner.registeredID],
            context: ScanContext(trigger: .userInitiated)
        )
        if let issue = collected.malformed[CategoryScanner.registeredID] {
            return .failure(
                code: "MALFORMED_SCANNER_OUTPUT",
                message: "Scanner '\(CategoryScanner.registeredID)' failed outcome validation; "
                    + "refusing to smart-clean from unvalidated results: \(issue.detail)",
                details: nil
            )
        }
        let allItems = collected.outcomes[CategoryScanner.registeredID]?.items ?? []

        switch decision {
        case .refuseRootUser:
            preconditionFailure("unreachable — refused before scanning")

        case .refuseUnconfirmed:
            let plan = smartCleanPlan(items: allItems, targetBytes: targetBytes)
            return .failure(
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
            let plan = smartCleanPlan(items: allItems, targetBytes: targetBytes)
            return .success([
                "schema_version": cliSchemaVersion,
                "target_gb": targetGB,
                "target_met": plan.targetMet,
                "total_freed_bytes": plan.totalExact,
                "total_estimated_up_to_bytes": plan.totalEstimated,
                "total_freed": CleanupReport.componentPhrase(
                    exact: plan.totalExact, estimatedUpTo: plan.totalEstimated
                ),
                "dry_run": true,
                "cleaned": plan.entries,
            ])

        case .proceed:
            let cleaner = deps.makeCleaner(collected.snapshot)
            var freedExactSoFar: Int64 = 0
            var estimatedSoFar: Int64 = 0
            var cleaned: [[String: Any]] = []

            for item in smartCleanCandidates(allItems) {
                // Only exact (delete-time measured, unique-inode) bytes
                // advance the target — estimated bytes never mark
                // `target_met` (R16).
                if freedExactSoFar >= targetBytes { break }
                let report = await cleaner.clean(items: [item], moveToTrash: false)
                let exact = report.totalFreedExact
                let estimated = report.totalEstimatedUpTo
                freedExactSoFar += exact
                estimatedSoFar += estimated

                let errs = report.errors.map(\.message)
                var row: [String: Any] = [
                    "slug": addressValue(for: item),
                    "name": item.displayName,
                    "bytes_freed": exact,
                    "exact_bytes": exact,
                    "estimated_up_to_bytes": estimated,
                    "freed_human": CleanupReport.componentPhrase(
                        exact: exact, estimatedUpTo: estimated
                    ),
                    "success": errs.isEmpty,
                    "scanner_id": item.scannerID,
                    "item_id": item.id,
                ]
                if !errs.isEmpty {
                    row["error"] = errs.joined(separator: "; ")
                }
                cleaned.append(row)
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
                return .failure(
                    code: "CLEAN_FAILED",
                    message: "No eligible category could be cleaned",
                    details: ["cleaned": cleaned, "target_gb": targetGB]
                )
            }

            return .success([
                "schema_version": cliSchemaVersion,
                "target_gb": targetGB,
                "target_met": freedExactSoFar >= targetBytes,
                "total_freed_bytes": freedExactSoFar,
                "total_estimated_up_to_bytes": estimatedSoFar,
                "total_freed": CleanupReport.componentPhrase(
                    exact: freedExactSoFar, estimatedUpTo: estimatedSoFar
                ),
                "dry_run": false,
                "cleaned": cleaned,
            ])
        }
    }

    // MARK: - Spotlight Tagging

    /// Tag all discovered cache directories with Spotlight metadata so
    /// `mdfind "kMDItemFinderComment == 'cacheout-managed'"` finds them.
    /// Also writes a `.cacheout-managed` marker file for `mdfind -name` queries.
    private static func handleSpotlight() async {
        render(await spotlightOutcome(
            deps: .production(),
            home: FileManager.default.homeDirectoryForCurrentUser
        ))
    }

    /// The spotlight scan pass runs through the SAME validated runtime entry
    /// point as scan/clean/smart-clean (R8 — no CLI consumer scans outside
    /// the chokepoint), scoped to the `categories` adapter: tagging is a
    /// category-root side effect. A malformed `categories` outcome fails
    /// closed — tag targets are never derived from unvalidated results.
    static func spotlightOutcome(
        deps: CLIRuntimeDependencies, home: URL
    ) async -> CLIOutcome {
        let adapterID = CategoryScanner.registeredID
        let collected = await collectValidatedScan(
            deps.runtime, scannerIDs: [adapterID],
            context: ScanContext(trigger: .userInitiated)
        )
        if let issue = collected.malformed[adapterID] {
            return .failure(
                code: "MALFORMED_SCANNER_OUTPUT",
                message: "Scanner '\(adapterID)' failed outcome validation; "
                    + "refusing to tag from unvalidated results: \(issue.detail)",
                details: nil
            )
        }
        // Validated aggregate items map back to the category results the
        // payload consumes; the runtime guarantees `.category` admission on
        // every adapter item, so a non-category descriptor is unreachable
        // (kept fail-closed via compactMap rather than assumed).
        let results = (collected.outcomes[adapterID]?.items ?? []).compactMap {
            item -> ScanResult? in
            guard case .category(let category) = item.admission else { return nil }
            return ScanResult(
                category: category,
                state: item.state,
                exactBytes: item.exactBytes,
                estimatedUpToBytes: item.estimatedUpToBytes,
                itemCount: item.itemCount,
                scanError: item.scanError,
                rootRecords: item.rootRecords
            )
        }
        return .success(spotlightPayload(for: results, home: home))
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
                for url in result.category.resolvedPaths(home: home) {
                    refused.append([
                        "slug": result.category.slug,
                        "path": url.path,
                        "reason": "scan denied (\(kind)): \(message)",
                    ])
                }
                continue
            }

            let policy = CategoryAdmissionPolicy(category: result.category, home: home)
            // Resolution anchors to the same injected home the policy does.
            for url in result.category.resolvedPaths(home: home) {
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
