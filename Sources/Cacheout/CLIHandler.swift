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
/// - `--tmp-age-days N` / `--tmp-min-size-mb N`: invocation-scoped
///   ephemeral temp-scanner thresholds (positive integers; days / decimal
///   MB), governed by the SAME family gate as the sweep pair — accepted by
///   `scan` and `clean` ONLY, every other command REJECTS them with
///   `INVALID_ARGUMENTS` before dispatch. Overrides the persisted
///   `cacheout.ephemeralTmp.*` value for this invocation; never persisted
/// - `--dev-root <path>`: REPEATABLE, invocation-scoped REPLACEMENT of the
///   dev roots the build-artifacts scanner walks. Accepted by `scan` and
///   `clean` ONLY (every other command REJECTS it with `INVALID_ARGUMENTS`
///   before dispatch). PRECEDENCE: when present, the flag's values are the
///   ENTIRE effective root set for this invocation — the persisted
///   `cacheout.buildArtifacts.devRoots` list is not consulted and is never
///   written. PATH FORMS: an ABSOLUTE path and a `~`-expanded path are
///   accepted; any other relative path is `INVALID_ARGUMENTS` naming the
///   value (a cwd-relative dev root would silently depend on the invocation
///   directory). Values run the same container-root admission policy as the
///   persisted list — a dangerous root (`/`, a volume root, `$HOME`, or a
///   symlink alias of one) is `INVALID_ARGUMENTS` naming it; exact-canonical
///   duplicates collapse (declared spellings preserved) and NESTED roots
///   stay independent walks
/// - `--acknowledge-valuables <scanner-slug>:<item-id>:<token>`: REPEATABLE,
///   item-bound acknowledgement of the release artifacts a `clean` refusal
///   (or plan row) disclosed for that item — one entry per item, accepted by
///   `clean` ONLY (every other command REJECTS it with `INVALID_ARGUMENTS`
///   before dispatch). The token is the full lowercase-hex SHA-256 the
///   refusal printed; deletion proceeds only when the delete-time
///   re-inspection recomputes exactly that token
/// - Positional arguments come BEFORE flags. A positional token appearing
///   after the first flag is `INVALID_ARGUMENTS` naming it (every documented
///   invocation shape is already targets-first)
/// - Clean targets are positional arguments after the command. A target is
///   one of `<category-slug>` (a category aggregate), `<scanner-slug>` (ALL
///   items of a per-item scanner, e.g. `build_artifacts`), or
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
/// Cacheout --cli clean build_artifacts --confirm
/// Cacheout --cli clean build_artifacts:3f0c…e1 --confirm
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

        // The NORMALIZED parse (fn-4.9, F3): positional targets, valued
        // flags, and the pinned TARGETS-BEFORE-FLAGS ordering rule — a
        // positional after the first flag is a loud INVALID_ARGUMENTS naming
        // it, where the as-built parser dropped it silently. Runs before
        // dispatch so every command shares one grammar.
        let invocation: NormalizedInvocation
        switch normalizedInvocation(
            command: command, arguments: Array(args[(cliIndex + 2)...])
        ) {
        case .failure(let error):
            exitWithError(code: "INVALID_ARGUMENTS", message: error.message)
        case .success(let parsed):
            invocation = parsed
        }

        // Pre-dispatch gate: the sweep's config flags (R8) are accepted by
        // the commands that actually run the sweep scanner — scan and clean
        // ONLY — and `--acknowledge-valuables` (R17) by clean only. Every
        // other command rejects them up front; silently ignoring a threshold
        // (or an ACKNOWLEDGEMENT) the caller passed would hide the flag
        // landing on the wrong command.
        if let rejection = rejectedFlag(for: command, in: args) {
            exitWithError(
                code: "INVALID_ARGUMENTS", message: rejection.message
            )
        }

        switch command {
        case .version:
            handleVersion()

        case .diskInfo:
            await handleDiskInfo()

        case .scan:
            // The sweep's config flags (R8) are accepted by the commands
            // that actually run the sweep scanner — scan and clean. The same
            // holds for `--dev-root` (fn-4.6): the roots are threaded into
            // `.production()` BEFORE the dependency bundle is built, because
            // `trustedContainerRoots` freeze at registration (D1).
            let sweepThresholds = resolveSweepThresholds(from: args)
            let devRoots = resolveDevRoots(invocation, in: args)
            let tempThresholds = resolveEphemeralTempThresholds(from: args)
            await handleScan(deps: .production(
                orphanedCachesThresholds: sweepThresholds, devRoots: devRoots,
                ephemeralTempThresholds: tempThresholds
            ))

        case .clean:
            let sweepThresholds = resolveSweepThresholds(from: args)
            let devRoots = resolveDevRoots(invocation, in: args)
            let tempThresholds = resolveEphemeralTempThresholds(from: args)
            await handleClean(
                slugs: invocation.targets,
                acknowledgements: resolveAcknowledgements(invocation, in: args),
                dryRun: isDryRun, confirmed: isConfirmed,
                deps: .production(
                    orphanedCachesThresholds: sweepThresholds,
                    devRoots: devRoots,
                    ephemeralTempThresholds: tempThresholds
                )
            )

        case .smartClean:
            // smart-clean is frozen category-only (fn-2 round 10): NO
            // per-item scanner runs there — not the sweep, not the ephemeral
            // temp scanner (whose items are `.review`, unselected and never
            // automatically clean-eligible by construction). Every
            // scanner-threshold flag is therefore a usage error here, not a
            // silent no-op — rejected by the pre-dispatch gate above along
            // with every other non-scan/clean command.
            //
            // An ABSENT target defaults to 5.0; a PRESENT but malformed one
            // is a usage error — silently defaulting would let
            // `smart-clean garbage --confirm` delete 5 GB the caller never
            // asked for. (Range/finiteness is validated in the handler.)
            let targetGB: Double
            if let raw = invocation.targets.first {
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
            let interventionName = invocation.targets.first
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
        /// - Parameter devRoots: invocation-scoped dev-roots REPLACEMENT
        ///   (fn-4, R8/D1) — nil resolves the persisted `DevRootsStore`
        ///   inside the runtime factory. The roots are threaded into
        ///   `.production()` BEFORE this bundle is constructed, because
        ///   `trustedContainerRoots` freeze at registration: a runtime is
        ///   the only thing that can carry them, and one CLI invocation is
        ///   one runtime. `--dev-root` parsing is fn-4.6's; nothing here is
        ///   ever persisted.
        /// - Parameter ephemeralTempThresholds: invocation-scoped ephemeral
        ///   temp thresholds (fn-6, R7) — nil resolves defaults →
        ///   UserDefaults inside the runtime factory, exactly like the sweep
        ///   pair. Never persisted.
        static func production(
            orphanedCachesThresholds: OrphanedCacheClassifier.Thresholds? = nil,
            devRoots: DevRootsResolution? = nil,
            ephemeralTempThresholds: EphemeralTempSweepConfig.Thresholds? = nil
        ) -> CLIRuntimeDependencies {
            CLIRuntimeDependencies(
                runtime: .production(
                    orphanedCachesThresholds: orphanedCachesThresholds,
                    devRoots: devRoots,
                    ephemeralTempThresholds: ephemeralTempThresholds
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
        let session = await runtime.scanValidatedSession(
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

    /// ONE scanner-threshold flag's value, for EVERY threshold family (fn-6:
    /// the sweep's two flags and the ephemeral temp scanner's two share this
    /// body verbatim, so the two families cannot drift in validation or in
    /// wording).
    ///
    /// The value must be a positive integer whose unit conversion does not
    /// overflow — zero, negative, non-numeric, MISSING, and overflowing
    /// values are REJECTED (fail-safe R8), never silently defaulted. A
    /// REPEATED flag is likewise rejected: any first-/last-wins rule would
    /// silently ignore one of two contradictory values — and skip validating
    /// the ignored occurrence, letting `--orphan-size-floor-mb 1
    /// --orphan-size-floor-mb garbage` slip past the malformed-value gate.
    ///
    /// A flag in LAST argv position collects no value, and silence there
    /// would read exactly like an ABSENT flag — the caller would believe
    /// they narrowed a scan they did not (the fn-4.6/fn-4.7 bug shape). The
    /// occurrence-count guard below is what makes the trailing shape a loud
    /// refusal instead: the flag is PRESENT (occurrence found) but has no
    /// following token, so it fails rather than resolving to `nil`.
    ///
    /// There is deliberately NO truncate-to-zero branch: a positive `Int64`
    /// times a positive unit multiplier either overflows (rejected above) or
    /// lands at or above the multiplier — integer multiplication cannot
    /// truncate toward zero the way the smart-clean `Double`-GB path can.
    static func positiveIntegerFlagValue(
        _ flag: String, in args: [String], converts: (Int64) -> Bool
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

    /// Pure parse of both sweep flags (in-process testable; the process
    /// shell translates a failure into the INVALID_ARGUMENTS exit), through
    /// the shared threshold-flag parse above.
    static func parseSweepThresholdOverrides(
        from args: [String]
    ) -> Result<(sizeFloorMB: Int64?, staleAgeDays: Int64?), CLIAddressError> {
        func parse(
            _ flag: String, converts: (Int64) -> Bool
        ) -> Result<Int64?, CLIAddressError> {
            positiveIntegerFlagValue(flag, in: args, converts: converts)
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

    // MARK: - Ephemeral temp thresholds (fn-6.4, R7)

    /// Invocation-scoped overrides for the ephemeral temp scanner's
    /// thresholds, accepted by `scan` and `clean` ONLY — exactly like the
    /// sweep's pair. Values override the persisted
    /// `cacheout.ephemeralTmp.*` value for this invocation and are NEVER
    /// persisted.
    static let tmpAgeDaysFlag = "--tmp-age-days"
    static let tmpMinSizeMBFlag = "--tmp-min-size-mb"

    /// Pure parse of both `--tmp-*` flags — the sweep parse's twin, sharing
    /// its validation body (`positiveIntegerFlagValue`) so the two families
    /// accept and refuse identically.
    static func parseEphemeralTempThresholdOverrides(
        from args: [String]
    ) -> Result<(ageDays: Int64?, minSizeMB: Int64?), CLIAddressError> {
        func parse(
            _ flag: String, converts: (Int64) -> Bool
        ) -> Result<Int64?, CLIAddressError> {
            positiveIntegerFlagValue(flag, in: args, converts: converts)
        }

        switch parse(tmpAgeDaysFlag, converts: {
            EphemeralTempSweepConfig.staleAge(fromDays: $0) != nil
        }) {
        case .failure(let error):
            return .failure(error)
        case .success(let ageDays):
            switch parse(tmpMinSizeMBFlag, converts: {
                EphemeralTempSweepConfig.sizeFloorBytes(fromMB: $0) != nil
            }) {
            case .failure(let error):
                return .failure(error)
            case .success(let minSizeMB):
                return .success((ageDays, minSizeMB))
            }
        }
    }

    // MARK: - Scanner-threshold flag families (fn-6.4 generalization)

    /// ONE scanner's invocation-scoped threshold flags as a FAMILY: which
    /// flags it owns, which commands accept them, and — derived from those
    /// same commands — its refusal wording.
    ///
    /// fn-3.4 shipped this gate sweep-specific in BOTH its flag list and its
    /// message text. A second scanner with the same need had two options: a
    /// parallel rejection function with its own `run()` call site (where a
    /// future command joins one gate and not the other — silent drift), or
    /// this: declare the family, keep ONE gate call. The sweep family's
    /// message is BYTE-IDENTICAL to fn-3.4's, and the phrases are built from
    /// `acceptingCommands`, so a refusal can never name a command set the
    /// gate does not actually enforce.
    struct ScannerThresholdFlagFamily: Sendable {
        /// The family's flags, in the order a refusal reports them.
        let flags: [String]
        /// The commands that RUN this scanner and therefore accept the
        /// flags — the single source for both the gate and its wording.
        let acceptingCommands: [Command]
        /// What the accepting commands do, e.g. "run the orphaned-caches
        /// sweep" — the middle clause of the refusal.
        let work: String

        func accepts(_ command: Command) -> Bool {
            acceptingCommands.contains(command)
        }

        /// The first of this family's flags present in an invocation of a
        /// command that does not accept it, or nil. Accepting the flags
        /// anywhere else would be a silent no-op lie.
        func rejectedFlag(for command: Command, in args: [String]) -> String? {
            guard !accepts(command) else { return nil }
            return flags.first(where: args.contains)
        }

        /// The INVALID_ARGUMENTS message: names the offending flag, the
        /// command that refused it, and the commands that accept it — the
        /// caller's next invocation should be obvious from the refusal
        /// alone.
        func rejectionMessage(flag: String, command: Command) -> String {
            "\(flag) is not accepted by \(command.rawValue) — only "
                + commandPhrase(joinedBy: "and") + " \(work); use the flag "
                + "with " + commandPhrase(joinedBy: "or")
        }

        /// "scan and clean" / "scan or clean" — the accepted set spelled out
        /// in prose. Two accepting commands is the only shape that exists
        /// today; a longer list would read "a and b and c", which is
        /// clumsy but never wrong.
        private func commandPhrase(joinedBy joiner: String) -> String {
            acceptingCommands.map(\.rawValue).joined(separator: " \(joiner) ")
        }
    }

    /// The orphaned-caches sweep's family (fn-3.4). Only `scan` and `clean`
    /// run the sweep scanner — for every other command (smart-clean is
    /// frozen category-only, fn-2 round 10; the rest have no sweep at all)
    /// the flags are refused pre-dispatch.
    static let sweepThresholdFlagFamily = ScannerThresholdFlagFamily(
        flags: [orphanSizeFloorFlag, orphanStaleDaysFlag],
        acceptingCommands: [.scan, .clean],
        work: "run the orphaned-caches sweep"
    )

    /// The ephemeral temp scanner's family (fn-6.4). Same accepting set: the
    /// two commands that run the scanner. `smart-clean` is frozen
    /// category-only and never runs it, so its flags are refused there too.
    static let ephemeralTempThresholdFlagFamily = ScannerThresholdFlagFamily(
        flags: [tmpAgeDaysFlag, tmpMinSizeMBFlag],
        acceptingCommands: [.scan, .clean],
        work: "run the ephemeral temp scanner"
    )

    /// Every scanner-threshold family, in gate order. The sweep stays FIRST
    /// so an invocation carrying flags from both families reports the sweep
    /// flag exactly as it did before fn-6.
    static let scannerThresholdFlagFamilies: [ScannerThresholdFlagFamily] = [
        sweepThresholdFlagFamily, ephemeralTempThresholdFlagFamily,
    ]

    /// The first sweep flag present in an invocation of a command that
    /// never runs the orphaned-caches sweep, or nil — the family gate,
    /// under fn-3.4's name (the OrphanedCachesScanner test surface and
    /// `smartCleanRejectedSweepFlag` call it).
    static func rejectedSweepFlag(for command: Command, in args: [String]) -> String? {
        sweepThresholdFlagFamily.rejectedFlag(for: command, in: args)
    }

    /// smart-clean's view of the pre-dispatch gate — the original fn-3.4
    /// entry point, retained so existing callers (the OrphanedCachesScanner
    /// test surface) keep working; the gate itself is
    /// `rejectedSweepFlag(for:in:)`.
    static func smartCleanRejectedSweepFlag(in args: [String]) -> String? {
        rejectedSweepFlag(for: .smartClean, in: args)
    }

    // MARK: - Acknowledgement flag + normalized parse (fn-4.9, R17/F3)

    /// The REPEATABLE, ITEM-BOUND valuables acknowledgement (R17):
    /// `--acknowledge-valuables <scanner-slug>:<item-id>:<token>`, one entry
    /// per item. Slug, item id, and token are colon-free by construction
    /// (`[a-z0-9_]+`, the CLI-safe opaque id contract, and 64 lowercase hex),
    /// so the colon-joined form parses unambiguously and covers multi-target
    /// and bare-scanner cleans alike. Accepted by `clean` ONLY — it is the
    /// only command that deletes items a valuables gate can guard.
    static let acknowledgeValuablesFlag = "--acknowledge-valuables"

    // MARK: - Dev roots (fn-4.6, R8/R16)

    /// The REPEATABLE, invocation-scoped dev-roots REPLACEMENT:
    /// `--dev-root <path>`, accepted by `scan` and `clean` ONLY (the two
    /// commands that walk the configured roots; every other command rejects
    /// it up front). Every occurrence's value joins the effective set, which
    /// REPLACES the persisted `DevRootsStore` list for this invocation and is
    /// NEVER persisted.
    ///
    /// PATH FORMS (pinned): an ABSOLUTE path (`/Volumes/Work/code`) and a
    /// `~`-EXPANDED path (`~/dev`) are accepted; ANY other relative spelling
    /// (`projects/x`) is `INVALID_ARGUMENTS` naming the value — a
    /// cwd-relative dev root would silently depend on the invocation
    /// directory, and the store's home-relative SEED resolution is a
    /// store-internal matter, never a CLI input form.
    static let devRootFlag = "--dev-root"

    /// Flags whose NEXT argv token is their VALUE. The normalized parse
    /// consumes those value tokens so they are never mistaken for positional
    /// targets — the ordering rule below would otherwise reject perfectly
    /// valid as-built invocations.
    ///
    /// `--format` is in the table deliberately: the handler ignores it
    /// (output is always JSON), but the MCP consumer appends `--format json`
    /// to EVERY invocation, so its value token must be recognized as a value.
    /// `--dev-root` (fn-4.6) is ONE table entry — the repeatable flag
    /// consumes fn-4.9's grammar and adds no second parser. So do fn-6.4's
    /// `--tmp-*` thresholds: a table entry each, never a second grammar.
    static let valuedFlags: Set<String> = [
        "--target-pid", "--target-name", "--top", "--format",
        orphanSizeFloorFlag, orphanStaleDaysFlag, acknowledgeValuablesFlag,
        devRootFlag, tmpAgeDaysFlag, tmpMinSizeMBFlag,
    ]

    /// One invocation, normalized (F3): the command, its POSITIONAL targets,
    /// and every valued flag's values in argv order. Repeatable flags
    /// (`--acknowledge-valuables`, and fn-4.6's `--dev-root`) collect all of
    /// their values here; single-value flags keep their as-built extraction
    /// semantics and read argv themselves.
    struct NormalizedInvocation: Equatable {
        let command: Command
        /// Positional tokens, in order, ALL of them before the first flag
        /// (the ordering rule guarantees it).
        let targets: [String]
        let flagValues: [String: [String]]

        /// Every value passed for `flag`, in argv order (empty when absent).
        func values(of flag: String) -> [String] { flagValues[flag] ?? [] }
    }

    /// The normalized parse with the PINNED ordering rule: **TARGETS BEFORE
    /// FLAGS** — a positional token appearing AFTER the first `--`-prefixed
    /// token is `INVALID_ARGUMENTS` naming the token.
    ///
    /// Why this rule and not flags-anywhere: the as-built hand parser already
    /// stopped target extraction at the first `--` while detecting flags by
    /// whole-argv scans, so a trailing positional was silently DROPPED. The
    /// ordering rule keeps every currently-valid invocation meaning exactly
    /// what it meant (every documented shape — `clean <targets…> --confirm`,
    /// `smart-clean <gb> --dry-run`, `intervene <name> --confirm --target-pid
    /// N`, `top-processes --top N`, and the MCP's trailing `--format json` —
    /// is targets-first) and converts the silent drop into a loud error.
    /// Flags-anywhere would instead RE-INTERPRET existing argv shapes.
    ///
    /// UNKNOWN flags are tolerated (the MCP passes `--include-caution`, and
    /// the as-built handler ignores what it does not parse); only the
    /// ordering rule rejects here. A valued flag with no following token is
    /// left to that flag's OWN validation, whose message is more specific.
    ///
    /// - Parameter arguments: the argv tokens AFTER the command token.
    static func normalizedInvocation(
        command: Command, arguments: [String]
    ) -> Result<NormalizedInvocation, CLIAddressError> {
        var targets: [String] = []
        var flagValues: [String: [String]] = [:]
        var sawFlag = false
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let token = arguments[index]
            guard !token.hasPrefix("--") else {
                sawFlag = true
                if valuedFlags.contains(token), index + 1 < arguments.endIndex {
                    flagValues[token, default: []].append(arguments[index + 1])
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            guard !sawFlag else {
                return .failure(CLIAddressError(message:
                    "Unexpected argument '\(token)' after flags: "
                    + "\(command.rawValue) takes its targets BEFORE any flag "
                    + "(Cacheout --cli \(command.rawValue) <targets...> "
                    + "[flags]). Move '\(token)' ahead of the flags."
                ))
            }
            targets.append(token)
            index += 1
        }
        return .success(NormalizedInvocation(
            command: command, targets: targets, flagValues: flagValues
        ))
    }

    /// The CENTRALIZED pre-dispatch flag gate: the first flag present in an
    /// invocation of a command that does not accept it, with its refusal
    /// message. The scanner-threshold FAMILIES are checked first, in
    /// declaration order, preserving fn-3.4's exact behavior and wording for
    /// the sweep; `--acknowledge-valuables` is clean-ONLY. Silently ignoring
    /// a flag the caller passed would hide it landing on the wrong command —
    /// and for an acknowledgement, that is a destructive-authorization input
    /// going nowhere. `run()` has exactly ONE call site for this gate, and a
    /// new threshold family joins by declaring itself, never by adding a
    /// second call.
    static func rejectedFlag(
        for command: Command, in args: [String]
    ) -> (flag: String, message: String)? {
        for family in scannerThresholdFlagFamilies {
            if let flag = family.rejectedFlag(for: command, in: args) {
                return (
                    flag,
                    family.rejectionMessage(flag: flag, command: command)
                )
            }
        }
        if command != .clean, args.contains(acknowledgeValuablesFlag) {
            return (
                acknowledgeValuablesFlag,
                acknowledgeFlagRejectionMessage(command: command)
            )
        }
        if command != .scan, command != .clean, args.contains(devRootFlag) {
            return (devRootFlag, devRootFlagRejectionMessage(command: command))
        }
        return nil
    }

    /// The INVALID_ARGUMENTS message for `--dev-root` on a command that
    /// never walks the configured dev roots — same actionable shape as the
    /// sweep-flag refusal (names the flag, the refusing command, and the
    /// commands that accept it).
    static func devRootFlagRejectionMessage(command: Command) -> String {
        "\(devRootFlag) is not accepted by \(command.rawValue) — only scan "
            + "and clean walk the configured dev roots; use the flag with "
            + "scan or clean"
    }

    /// The INVALID_ARGUMENTS message for `--acknowledge-valuables` on a
    /// command that never deletes an item behind a valuables gate — same
    /// actionable shape as the sweep-flag refusal (names the flag, the
    /// refusing command, and the command that accepts it).
    static func acknowledgeFlagRejectionMessage(command: Command) -> String {
        "\(acknowledgeValuablesFlag) is not accepted by \(command.rawValue) "
            + "— only clean deletes items that can require a valuables "
            + "acknowledgement; use the flag with clean"
    }

    /// One parsed `--acknowledge-valuables` entry: the ITEM it binds to and
    /// the token the delete-time revalidation must recompute exactly.
    struct ParsedAcknowledgement: Equatable {
        let key: ItemKey
        let token: String
    }

    /// FORM validation of every `--acknowledge-valuables` entry — run on
    /// EVERY path (`--dry-run`, unconfirmed, confirmed) so malformed
    /// destructive-authorization input fails fast everywhere. This is a
    /// pure parse: it performs NO token-vs-set matching (that can only
    /// happen at delete time, against the CURRENT probe).
    ///
    /// FROZEN rules — this is an authorization input, never incidental
    /// dictionary construction:
    /// - exactly two colons (`<scanner-slug>:<item-id>:<token>`);
    /// - slug matches the address grammar `[a-z0-9_]+`;
    /// - item id is the documented CLI-safe opaque string;
    /// - token is EXACTLY 64 lowercase hex characters (the full SHA-256 the
    ///   refusal printed — never a prefix, never uppercase);
    /// - a DUPLICATE ItemKey is refused outright, including a byte-identical
    ///   repeat: first-wins would ignore a contradicting second entry and
    ///   last-wins would ignore the first, and either silently drops half of
    ///   what the caller authorized.
    static func parseAcknowledgements(
        _ entries: [String]
    ) -> Result<[ParsedAcknowledgement], CLIAddressError> {
        var parsed: [ParsedAcknowledgement] = []
        var seen = Set<ItemKey>()

        for entry in entries {
            let fields = entry.split(
                separator: ":", omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == 3 else {
                return .failure(malformedAcknowledgement(entry))
            }
            let (slug, itemID, token) = (fields[0], fields[1], fields[2])
            guard SpaceScannerRuntime.isValidSlug(slug),
                  SpaceScannerRuntime.isCLISafeItemID(itemID) else {
                return .failure(malformedAcknowledgement(entry))
            }
            guard isAcknowledgementToken(token) else {
                return .failure(CLIAddressError(message:
                    "\(acknowledgeValuablesFlag) token must be exactly 64 "
                    + "lowercase hex characters (the token the refusal "
                    + "printed), got: '\(token)'"
                ))
            }
            let key = ItemKey(scannerID: slug, itemID: itemID)
            guard seen.insert(key).inserted else {
                return .failure(CLIAddressError(message:
                    "\(acknowledgeValuablesFlag) names \(slug):\(itemID) more "
                    + "than once — pass exactly one acknowledgement per item"
                ))
            }
            parsed.append(ParsedAcknowledgement(key: key, token: token))
        }
        return .success(parsed)
    }

    /// The OCCURRENCE-COUNT guard for the repeatable acknowledgement flag,
    /// mirroring `--dev-root`'s (review r1). The normalized grammar leaves a
    /// valued flag with NO following token to that flag's own validation, and
    /// silence is the dangerous direction here too: a trailing
    /// `--acknowledge-valuables` collects no value, so the invocation would
    /// look exactly like an UNACKNOWLEDGED clean and proceed — the caller
    /// believing they authorized something. An acknowledgement is destructive
    /// authorization input; a mismatch is `INVALID_ARGUMENTS`, pre-flight,
    /// nothing deleted (the documented fail-fast rule).
    ///
    /// - Parameter occurrences: how many times the flag appears in argv.
    static func acknowledgementValues(
        from values: [String], occurrences: Int
    ) -> Result<[String], CLIAddressError> {
        guard occurrences <= values.count else {
            return .failure(CLIAddressError(message:
                "\(acknowledgeValuablesFlag) requires an entry — one "
                + "occurrence has no value. Pass "
                + "<scanner-slug>:<item-id>:<token> (the address and token "
                + "the refusal printed). Nothing was cleaned."
            ))
        }
        return .success(values)
    }

    /// The process-facing resolution: the acknowledgement entry list, exiting
    /// via the invalid-arguments convention on a MISSING value. The raw argv
    /// is read for the OCCURRENCE count only (the `--dev-root` convention) —
    /// the values themselves always come from the one normalized grammar.
    private static func resolveAcknowledgements(
        _ invocation: NormalizedInvocation, in args: [String]
    ) -> [String] {
        switch acknowledgementValues(
            from: invocation.values(of: acknowledgeValuablesFlag),
            occurrences: args.filter { $0 == acknowledgeValuablesFlag }.count
        ) {
        case .failure(let error):
            exitWithError(code: "INVALID_ARGUMENTS", message: error.message)
        case .success(let values):
            return values
        }
    }

    private static func malformedAcknowledgement(
        _ entry: String
    ) -> CLIAddressError {
        CLIAddressError(message:
            "\(acknowledgeValuablesFlag) expects "
            + "<scanner-slug>:<item-id>:<token> (the address and token the "
            + "refusal printed), got: '\(entry)'"
        )
    }

    /// The token's exact form: 64 LOWERCASE hex characters — the full
    /// lowercase-hex SHA-256 the refusal and the plan rows emit. Uppercase
    /// is rejected rather than folded: the token is compared byte-for-byte
    /// against a freshly derived one, so accepting a spelling that can never
    /// match would only defer the failure to delete time.
    static func isAcknowledgementToken(_ token: String) -> Bool {
        token.count == 64 && token.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    /// PRE-FLIGHT validation of parsed entries against the RESOLVED clean
    /// selection — after target resolution, before ANY deletion, on every
    /// path. Still no token matching: these rules are about what the entry
    /// BINDS to, which the scan already knows.
    ///
    /// - an entry naming an item that is not in this clean's selection
    ///   (unknown id, or a real item this invocation does not clean) is
    ///   refused: an acknowledgement that authorizes nothing this run touches
    ///   is caller confusion, and accepting it would let a stale script
    ///   believe it acknowledged something;
    /// - an entry for a PROVEN valuables-free item is refused for the same
    ///   reason (no token exists for an empty set anywhere). "Proven" is
    ///   load-bearing: an item whose scan-time probe did NOT finish is not
    ///   proven free — its delete-time probe may find valuables and issue a
    ///   token — so an INCOMPLETE probe with an empty disclosed set is
    ///   accepted here and decided at delete time, where the uniform R17 rule
    ///   refuses it anyway if the inspection still cannot finish.
    static func validateAcknowledgements(
        _ entries: [ParsedAcknowledgement], against items: [ReclaimableItem]
    ) -> CLIAddressError? {
        let itemsByKey = Dictionary(
            items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }
        )
        for entry in entries {
            let address = "\(entry.key.scannerID):\(entry.key.itemID)"
            guard let item = itemsByKey[entry.key] else {
                return CLIAddressError(message:
                    "\(acknowledgeValuablesFlag) names \(address), which is "
                    + "not part of this clean's selection — acknowledge only "
                    + "items this invocation would clean (item ids are "
                    + "echoed from 'scan'). Nothing was cleaned."
                )
            }
            let provenFree: Bool
            if let disclosure = item.valuablesDisclosure {
                provenFree = disclosure.probeComplete
                    && disclosure.valuables.isEmpty
            } else {
                // No valuables model at all (every scanner but
                // build_artifacts today) — nothing this entry could bind to.
                provenFree = true
            }
            guard !provenFree else {
                return CLIAddressError(message:
                    "\(acknowledgeValuablesFlag) names \(address), which "
                    + "discloses no release artifacts — there is nothing to "
                    + "acknowledge; re-run without the entry. Nothing was "
                    + "cleaned."
                )
            }
        }
        return nil
    }

    /// The per-clean `[ItemKey: acknowledgement]` AUTHORIZATION CONTEXT the
    /// cleaner hands to each item's revalidator (fn-4.8's surface). Built
    /// ONLY from validated entries — duplicates are impossible by then, so
    /// this construction can never silently collapse two acknowledgements.
    static func authorizationContext(
        from entries: [ParsedAcknowledgement]
    ) -> PreDeleteAuthorizationContext {
        var context: PreDeleteAuthorizationContext = [:]
        for entry in entries { context[entry.key] = entry.token }
        return context
    }

    /// The PURE `--dev-root` resolution (in-process testable; the process
    /// shell below turns a failure into the INVALID_ARGUMENTS exit).
    ///
    /// `nil` success = the flag was absent, so the persisted `DevRootsStore`
    /// resolves inside the production factory exactly as it does for the
    /// GUI. Otherwise the flag values REPLACE the effective set for this
    /// invocation:
    ///
    /// 1. PATH FORM per value — absolute or `~`-expanded only (see
    ///    `devRootFlag`); anything else is refused NAMING the value;
    /// 2. the SHARED resolution pipeline — `DevRootsStore`'s replacement
    ///    path, so the same container-root admission policy (R16), the same
    ///    exact-canonical-duplicate dedupe, and the same declared-spelling
    ///    preservation apply as for persisted roots; NESTED flag roots stay
    ///    independent walks (D7);
    /// 3. a POLICY-rejected value becomes an INVALID_ARGUMENTS error NAMING
    ///    the offending root — invocation-scoped input has an immediate
    ///    error channel, so it never degrades into a silent config issue the
    ///    way a persisted root does.
    ///
    /// Nothing here reads or writes the defaults suite: the replacement path
    /// consults no persisted value, and `--dev-root` is never persisted.
    ///
    /// - Parameter occurrences: how many times the flag appears in argv.
    ///   The normalized grammar leaves a valued flag with NO following token
    ///   to the flag's own validation, and for THIS flag silence would be
    ///   the dangerous direction: a trailing `--dev-root` would look exactly
    ///   like an absent flag and quietly scan the PERSISTED roots the caller
    ///   meant to replace. A mismatch is therefore INVALID_ARGUMENTS.
    static func devRootsOverride(
        from values: [String],
        occurrences: Int,
        home: URL,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> Result<DevRootsResolution?, CLIAddressError> {
        guard occurrences <= values.count else {
            return .failure(CLIAddressError(message:
                "\(devRootFlag) requires a folder path — one occurrence has "
                + "no value. Pass an absolute path (/Volumes/Work/code) or a "
                + "~/ path (~/dev). Nothing was scanned."
            ))
        }
        guard !values.isEmpty else { return .success(nil) }

        var declaredRoots: [URL] = []
        for value in values {
            switch declaredDevRoot(value, home: home) {
            case .failure(let error):
                return .failure(error)
            case .success(let url):
                declaredRoots.append(url)
            }
        }

        let resolution = DevRootsStore(provider: provider)
            .effectiveRoots(replacing: declaredRoots, home: home)
        // The policy's own verdict, surfaced as a usage error (the CLI
        // attack case: `--dev-root /`). `.configInvalid` cannot occur on the
        // replacement path — nothing was parsed out of the defaults suite.
        if let refused = resolution.issues.first(
            where: { $0.kind == .containerRefused }
        ) {
            return .failure(CLIAddressError(message:
                "\(devRootFlag) \(refused.url?.path ?? "") is not a usable "
                + "dev root: \(refused.detail). Nothing was scanned."
            ))
        }
        return .success(resolution)
    }

    /// ONE `--dev-root` value → its declared URL, enforcing the pinned path
    /// forms. `~` expands against the INJECTED home (never `getpwuid`), so
    /// the flag means the same thing in tests and in production.
    private static func declaredDevRoot(
        _ value: String, home: URL
    ) -> Result<URL, CLIAddressError> {
        func refuse(_ reason: String) -> Result<URL, CLIAddressError> {
            .failure(CLIAddressError(message:
                "\(devRootFlag) \(reason), got: '\(value)'. Pass an absolute "
                + "path (/Volumes/Work/code) or a ~/ path (~/dev) — a "
                + "relative path would depend on the current directory."
            ))
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return refuse("requires a folder path") }
        if value == "~" { return .success(home) }
        if value.hasPrefix("~/") {
            return .success(
                home.appendingPathComponent(String(value.dropFirst(2)))
            )
        }
        guard value.hasPrefix("/") else {
            return refuse("requires an ABSOLUTE or ~-expanded path")
        }
        return .success(URL(fileURLWithPath: value))
    }

    /// The process-facing resolution: `--dev-root` values → the
    /// invocation-scoped replacement, exiting via the invalid-arguments
    /// convention on a MISSING value, a bad path form, or a policy-refused
    /// root. The raw argv is read for the OCCURRENCE count only (the gate's
    /// own convention) — the values themselves always come from the one
    /// normalized grammar.
    private static func resolveDevRoots(
        _ invocation: NormalizedInvocation, in args: [String]
    ) -> DevRootsResolution? {
        switch devRootsOverride(
            from: invocation.values(of: devRootFlag),
            occurrences: args.filter { $0 == devRootFlag }.count,
            home: FileManager.default.homeDirectoryForCurrentUser
        ) {
        case .failure(let error):
            exitWithError(code: "INVALID_ARGUMENTS", message: error.message)
        case .success(let resolution):
            return resolution
        }
    }

    /// The INVALID_ARGUMENTS message for a rejected sweep flag — fn-3.4's
    /// name for its family's wording, BYTE-IDENTICAL across the fn-6.4
    /// generalization (asserted against the literal in the tests).
    static func sweepFlagRejectionMessage(flag: String, command: Command) -> String {
        sweepThresholdFlagFamily.rejectionMessage(flag: flag, command: command)
    }

    /// The process-facing resolution for the `--tmp-*` flags: parse both
    /// (exiting via the invalid-arguments convention on a bad value) and,
    /// when at least one is present, layer them over UserDefaults/defaults.
    /// `nil` — no flags — lets the production factory resolve persisted
    /// values itself, exactly as it does for the GUI. Nothing here writes
    /// the defaults suite: an override is invocation-scoped, period.
    private static func resolveEphemeralTempThresholds(
        from args: [String]
    ) -> EphemeralTempSweepConfig.Thresholds? {
        switch parseEphemeralTempThresholdOverrides(from: args) {
        case .failure(let error):
            exitWithError(code: "INVALID_ARGUMENTS", message: error.message)
        case .success(let overrides):
            guard overrides.ageDays != nil
                || overrides.minSizeMB != nil else { return nil }
            return EphemeralTempSweepConfig.resolvedThresholds(
                minSizeMBOverride: overrides.minSizeMB,
                ageDaysOverride: overrides.ageDays
            )
        }
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
        // within a scanner (`CacheScanner.scanAll` is size-descending, ties
        // broken by category slug — the schema-3 scan order, preserved).
        //
        // The tie-break is load-bearing for this sentence (PR #459 review r3):
        // until it was added, `scanAll` sorted on size alone over an array
        // built in task-group COMPLETION order, so equal-size rows — every
        // missing and every empty category ties at 0 bytes — came out in
        // whatever order the tasks finished. The word "Deterministic" was not
        // true of the within-scanner half it claims.
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
        // ADDITIVE, fn-4.4 (no schema bump). Both keys are OMITTED — never
        // null — when they do not apply: `logical_bytes` only when the model
        // carries a materially diverging figure (the sparse `target/` field
        // case), `valuables` only when the probe actually disclosed some.
        if let logicalBytes = item.logicalBytes {
            row["logical_bytes"] = logicalBytes
        }
        if let disclosure = item.valuablesDisclosure,
           !disclosure.valuables.isEmpty {
            // Array order IS the model's stored canonical order — no re-sort.
            row["valuables"] = disclosure.valuables.map(valuableRowJSON(for:))
        }
        return row
    }

    /// The ONE pinned valuables ELEMENT shape (fn-4.4, R3/R17), six fields:
    ///
    ///     {"name": …, "path": …, "allocated_bytes": …,
    ///      "device": …, "inode": …, "modified_at_ns": …}
    ///
    /// `path` is the CANONICAL IDENTITY PATH (`resolveTargetKeepingLeaf`) —
    /// the same string the token preimage consumes; the unresolved display
    /// spelling NEVER reaches the wire. `device`/`inode` serialize as
    /// UNSIGNED decimal integers (the `FileSystemIdentityProvider.Identity`
    /// convention). `modified_at_ns` is DERIVED as `modifiedSeconds * 1e9 +
    /// modifiedNanoseconds` from the same integers the sheet renders its date
    /// from — one source, no precision drift.
    ///
    /// Plan rows and clean-result refusal rows (fn-4.9) REUSE this builder
    /// verbatim so scan, plan, and refusal surfaces can never drift.
    ///
    /// The `modified_at_ns` key is unconditional for anything real: the value
    /// is absent only for an identity outside the pinned value domains, which
    /// no production probe can produce (`leafMetadata` rejects it at the
    /// `lstat`) and no validated outcome can carry (the value-domain family
    /// malforms it first). The row omits rather than inventing a number.
    static func valuableRowJSON(for valuable: DetectedValuable) -> [String: Any] {
        var row: [String: Any] = [
            "name": valuable.name,
            "path": valuable.canonicalIdentityPath,
            "allocated_bytes": valuable.identity.allocatedBytes,
            "device": valuable.identity.device,
            "inode": valuable.identity.inode,
        ]
        if let modifiedAtNS = valuable.identity.modifiedAtNanoseconds {
            row["modified_at_ns"] = modifiedAtNS
        }
        return row
    }

    /// One `scanner_errors` row. `path` is CONDITIONAL (round 7): present
    /// for the filesystem kinds, ABSENT for the non-filesystem kinds
    /// (`malformed_outcome`, `config_invalid`, `tool_unavailable`) — a fake
    /// path must never be invented. The rule is written over the KIND CLASS,
    /// so this builder needs no per-kind branch. `grant_hint` is CONDITIONAL:
    /// present
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
    /// (`clean build_artifacts build_artifacts:<id>` names the item once).
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
    ///
    /// ADDITIVE (fn-4.9, R17) — the acknowledgement the confirmed run WOULD
    /// require, so the caller learns it from the plan instead of from a
    /// refusal (both the `CONFIRMATION_REQUIRED` details and `--dry-run`
    /// render these rows, so the two surfaces cannot drift):
    /// - `valuables` — the DISCLOSED set in fn-4.4's pinned six-field element
    ///   shape and stored canonical order, omitted when the probe disclosed
    ///   none;
    /// - `acknowledgement_token` — emitted ONLY when the SCAN-TIME probe was
    ///   COMPLETE and the disclosed set NON-EMPTY (the uniform R17 rule: a
    ///   token over an incomplete set could not safely authorize the current
    ///   one, and no empty-set token exists anywhere). The confirmed run
    ///   always recomputes from the DELETE-TIME probe — a scan-derived plan
    ///   token that no longer matches simply yields the standard fresh
    ///   refusal;
    /// - `acknowledgement_note` — present exactly when the scan-time probe
    ///   did NOT finish, saying so and pointing at the confirmed run's
    ///   revalidation, so an ABSENT token is never read as "nothing to
    ///   acknowledge".
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
        if let disclosure = item.valuablesDisclosure {
            if !disclosure.valuables.isEmpty {
                // Stored canonical order — never re-sorted here.
                row["valuables"] = disclosure.valuables.map(valuableRowJSON(for:))
            }
            if disclosure.probeComplete {
                // Derived from the SCAN-TIME identities through the shared
                // preimage; nil for an empty set by that derivation's own
                // precondition, so no empty-set token can ever be emitted.
                if let token = disclosure.acknowledgementToken(for: item.key) {
                    row["acknowledgement_token"] = token
                }
            } else {
                row["acknowledgement_note"] = incompleteProbeNote(
                    for: disclosure.incompleteness
                )
            }
        }
        return row
    }

    /// The plan/dry-run note for THIS item's incompleteness CAUSE. The two
    /// causes end differently, so they may not print one remedy: an
    /// obstruction is cleared by fixing it and re-scanning, while an entry
    /// budget that starts at the tree's own census and DOUBLES until the
    /// inspection finishes is only reached by a tree that is still changing —
    /// and "re-scan" is the advice that cannot work for it.
    static func incompleteProbeNote(
        for cause: ValuablesDisclosure.ProbeIncompleteness?
    ) -> String {
        cause == .entryBudget ? growingTreePlanNote : incompleteProbePlanNote
    }

    /// The note for a tree that outgrew its own census mid-inspection.
    static let growingTreePlanNote =
        "the release-artifact inspection ran out of its entry budget at scan "
        + "time — this directory is changing faster than it can be read — so "
        + "no acknowledgement token exists for this item; a confirmed run "
        + "re-inspects it immediately before deletion and refuses until an "
        + "inspection completes; retry when it settles"

    /// The plan/dry-run note for an item whose scan-time valuables probe
    /// could not finish: no token exists for it on ANY surface, and a
    /// confirmed run re-inspects before deleting anything.
    static let incompleteProbePlanNote =
        "the release-artifact inspection did not finish at scan time, so no "
        + "acknowledgement token exists for this item — a confirmed run "
        + "re-inspects it immediately before deletion and refuses until an "
        + "inspection completes; re-scan and retry"

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
        slugs: [String], acknowledgements: [String],
        dryRun: Bool, confirmed: Bool,
        deps: CLIRuntimeDependencies
    ) async {
        render(await cleanCLIOutcome(
            targets: slugs, acknowledgements: acknowledgements,
            dryRun: dryRun, confirmed: confirmed,
            euid: geteuid(), deps: deps
        ))
    }

    /// The whole `clean` decision pipeline, injected and exit-free so the
    /// in-process tests drive it end-to-end (addressing, resolution,
    /// gating, schema shape, AND the confirmed fixture deletion). Check
    /// order preserved from schema 3: usage → target validation → gate →
    /// read-only scan → branch.
    ///
    /// - Parameter acknowledgements: the raw repeatable
    ///   `--acknowledge-valuables <scanner-slug>:<item-id>:<token>` entries
    ///   (R17). Their FORM is validated here on EVERY path — before the scan,
    ///   so malformed destructive-authorization input fails fast on
    ///   `--dry-run`, unconfirmed, and confirmed alike — and their BINDING
    ///   (selection membership, disclosed valuables) immediately after target
    ///   resolution, before any deletion. Token-vs-current-set MATCHING never
    ///   happens here: it belongs to the delete-time revalidator, which the
    ///   confirmed path alone reaches.
    static func cleanCLIOutcome(
        targets rawTargets: [String],
        acknowledgements: [String] = [],
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

        // FORM first, on every path and before anything is scanned or
        // resolved: an acknowledgement is a destructive-authorization input.
        let parsedAcknowledgements: [ParsedAcknowledgement]
        switch parseAcknowledgements(acknowledgements) {
        case .failure(let error):
            return .failure(
                code: "INVALID_ARGUMENTS", message: error.message, details: nil
            )
        case .success(let entries):
            parsedAcknowledgements = entries
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

        // PRE-FLIGHT acknowledgement binding (R17): after target resolution,
        // before ANY deletion, on EVERY path — an entry that names nothing
        // this invocation cleans, or an item with nothing to acknowledge, is
        // caller confusion and refuses the whole invocation. Still no token
        // matching: that is the delete-time revalidator's, on the confirmed
        // path only.
        if let error = validateAcknowledgements(
            parsedAcknowledgements, against: items
        ) {
            return .failure(
                code: "INVALID_ARGUMENTS", message: error.message, details: nil
            )
        }

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
            // The per-clean AUTHORIZATION CONTEXT (R17), built HERE from the
            // validated entries and handed down the deletion path so each
            // item's revalidator receives ITS OWN entry (nil when absent).
            // The items' structural disclosures are never read as consent.
            let report = await cleaner.clean(
                items: items, moveToTrash: false,
                authorization: authorizationContext(from: parsedAcknowledgements)
            )
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
            rows.append(confirmedCleanRowJSON(
                item: item,
                entry: entriesByKey[item.key],
                errors: errorsByKey[item.key] ?? []
            ))
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

    /// ONE confirmed-clean result row. Extracted from the payload loop
    /// (fn-5.4) so the row SHAPE — in particular the two-source `warning`
    /// merge below — is unit-testable without driving a whole destructive
    /// run; the loop above is now purely correlation and iteration.
    ///
    /// `success` is `errors.isEmpty` (the frozen derivation, and precisely
    /// why D11 gave `CleanupReport.Entry` a `warning` field instead of a
    /// "non-fatal ItemError": an error of any kind flips a successful
    /// removal's row to `success: false`).
    ///
    /// THE `warning` KEY HAS TWO SOURCES and they COMPOSE (fn-5.4, D11):
    /// the scan-time `.partiallyDenied` note and the entry's own delete-time
    /// warning. When both apply they are joined with `"; "` — the row must
    /// never drop one because the other happened to be there.
    static func confirmedCleanRowJSON(
        item: ReclaimableItem,
        entry: CleanupReport.Entry?,
        errors: [CleanupReport.ItemError]
    ) -> [String: Any] {
        let errs = errors.map(\.message)
        // The TYPED refusal payload (fn-4.9, R17), transported through
        // `CleanupReport.ItemError` — the row NEVER parses message prose.
        // At most one revalidation refusal exists per item (the seam
        // returns immediately), so the first payload IS the payload.
        let refusal = errors.compactMap(\.refusal).first
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
        var warnings: [String] = []
        if item.state == .partiallyDenied {
            warnings.append(partiallyDeniedCleanWarning)
        }
        if let warning = entry?.warning, !warning.isEmpty {
            warnings.append(warning)
        }
        if !warnings.isEmpty {
            row["warning"] = warnings.joined(separator: "; ")
        }
        // ADDITIVE refusal fields (R17), from the typed payload only —
        // ABSENT on every ordinary error row and on every success row, so
        // pre-existing row shapes are unchanged. `valuables` is omitted
        // when the refusal disclosed none (a VANISHED set), and
        // `acknowledgement_token` unless the refusal carries a non-empty
        // current set from a COMPLETE delete-time probe (vanished-set and
        // incomplete-probe refusals are tokenless — the uniform R17 rule).
        if let refusal {
            if !refusal.valuables.isEmpty {
                row["valuables"] = refusal.valuables.map(valuableRowJSON(for:))
            }
            if let token = refusal.acknowledgementToken {
                row["acknowledgement_token"] = token
            }
        }
        return row
    }

    /// Smart-clean eligibility + order — policy (c), EXCLUSIVELY this
    /// handler's (epic round 10; the GUI never runs it). Preserved
    /// byte-for-byte from schema 3 (R18): only cleanly-measured items with
    /// bytes qualify — `.denied` AND `.partiallyDenied` are skipped (the
    /// auto path must never ride on a floor measurement), and caution-risk
    /// items are excluded entirely. Safe before review, larger first
    /// within a tier. Exactly ONE addition (epic contract):
    /// `automaticCleanEligible == false` items are excluded — in practice
    /// every per-item scanner row (no `build_artifacts` row is ever
    /// auto-eligible), which becoming CLI-visible must not silently
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
    /// ever invoked (round 10), so per-item scanners can never enter the
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

    // The positional extractors that used to live here (`extractSlugs`,
    // `extractPositionalArg`) are SUBSUMED by the normalized parse
    // (`normalizedInvocation`): one grammar, one positional list, and the
    // trailing positional they dropped silently is now a loud
    // INVALID_ARGUMENTS. `--top` keeps its own as-built extraction (a
    // single-value flag with its own message).

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
