import XCTest
@testable import Cacheout

/// fn-6.4 (R7/R10/R13) — REGISTRATION and its consequences.
///
/// The epic's promise is that a scanner ships by implementing the protocol and
/// registering: no ViewModel edits, no view edits, no cleaner edits, no new
/// busy flag, no orchestration change. These tests hold that promise to
/// account for `ephemeral_tmp` — the production registry, the GUI's generic
/// per-item section, the CLI's scan/clean surface, smart-clean's exclusion,
/// and the invocation-scoped `--tmp-*` threshold flags with their family gate.
///
/// TWO ROOT DISCIPLINES, deliberately kept apart:
/// - the REGISTRATION cells drive the real `SpaceScannerRuntime.production(…)`
///   and therefore see the machine's real confstr roots — they only inspect
///   the COMPOSITION (which scanner, which thresholds, which declared roots)
///   and never run a scan, so nothing walks live system state;
/// - every BEHAVIORAL cell (scan, clean, GUI, smart-clean) runs the scanner
///   over an INJECTED fixture root with an injected clock, exactly as fn-6.2
///   and fn-6.3 do. No test here reads a real temp root or the real `$HOME`,
///   and nothing sleeps.
final class EphemeralTempRegistrationTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private var tempRoot: URL!
    private let fm = FileManager.default

    /// The fixed scan instant every fixture date is expressed against.
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    /// The shipped 7-day age with a small POSITIVE floor so fixtures stay
    /// cheap — the fn-6.2/fn-6.3 test thresholds verbatim.
    private let thresholds = EphemeralTempSweepConfig.Thresholds(
        sizeFloorBytes: 4_096, staleAge: 7 * 86_400
    )

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent(
            "EphemeralTempRegistrationTests-\(UUID().uuidString)"
        )
        fixtureHome = base.appendingPathComponent("home")
        tempRoot = base.appendingPathComponent("shared-temp")
        for url in [base, fixtureHome, tempRoot] {
            try fm.createDirectory(at: url!, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
    }

    // MARK: - Fixtures

    private func canonical(_ url: URL) -> URL {
        FileSystemIdentityProvider().canonicalize(url)
    }

    /// Backdate a whole tree — children first, the directory itself LAST (its
    /// own mtime is a staleness input and writing children bumps it).
    private func backdate(_ url: URL, to date: Date) throws {
        if FileSystemIdentityProvider().kind(of: url) == .directory {
            for child in try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: []
            ) {
                try backdate(child, to: date)
            }
        }
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// A stale first-level scratch directory — the field shape the scanner
    /// lists: one payload file, 30 days behind the injected clock.
    @discardableResult
    private func stageStaleEntry(_ name: String, bytes: Int = 8_192) throws -> URL {
        let entry = tempRoot.appendingPathComponent(name)
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes)
            .write(to: entry.appendingPathComponent("payload.bin"))
        try backdate(entry, to: clock.addingTimeInterval(-30 * 86_400))
        return entry
    }

    /// A thread-safe enumeration counter for the injected `listDirectory`
    /// seam — "did this scanner enumerate anything at all" is the assertion
    /// the trigger policy and the smart-clean exclusion both rest on.
    private final class ListCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func bump() {
            lock.lock(); defer { lock.unlock() }
            value += 1
        }
    }

    /// The scanner over the INJECTED fixture root in the CANONICAL spelling
    /// fn-6.1 hands production, with the fixed clock and an optional
    /// enumeration counter.
    private func makeScanner(counter: ListCounter? = nil) -> EphemeralTempScanner {
        let clock = self.clock
        return EphemeralTempScanner(
            roots: [EphemeralTempRoot(
                url: canonical(tempRoot),
                label: "Shared temp",
                cleanupEvidence: EphemeralTempRoots.sharedTempEvidence,
                writability: .worldWritable
            )],
            home: fixtureHome,
            thresholds: thresholds,
            now: { clock },
            listDirectory: { root in
                counter?.bump()
                return try EphemeralTempScanner.firstLevelEntries(of: root)
            }
        )
    }

    /// A runtime around the fixture scanner — registration is what puts the
    /// fixture root into delete-time admission, exactly as in production.
    private func makeRuntime(
        _ scanners: [any SpaceScanner]
    ) throws -> SpaceScannerRuntime {
        try SpaceScannerRuntime(
            scanners: scanners, categories: [], home: fixtureHome,
            provider: FileSystemIdentityProvider()
        )
    }

    private func makeDeps(
        _ runtime: SpaceScannerRuntime
    ) -> CLIHandler.CLIRuntimeDependencies {
        CLIHandler.CLIRuntimeDependencies(runtime: runtime, categorySlugs: [])
    }

    /// An isolated defaults suite — no test here touches the standard one.
    private func makeSuite() throws -> UserDefaults {
        let name = "EphemeralTempRegistrationTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        return suite
    }

    // MARK: - R10: the production registry

    /// The scanner is registered LAST in the production composition, its slug
    /// is the shipped one, and its DECLARED roots — the confstr set, resolved
    /// once — are in the runtime union that delete-time admission reads.
    /// Composition only: nothing is scanned here.
    func testProductionRegistersEphemeralTempScannerWithItsDeclaredRoots() throws {
        let suite = try makeSuite()
        let devRoots = DevRootsStore(defaults: suite).effectiveRoots(home: fixtureHome)
        let runtime = SpaceScannerRuntime.production(
            home: fixtureHome, devRoots: devRoots
        )

        XCTAssertEqual(runtime.scanners.map(\.id), [
            CategoryScanner.registeredID,
            BuildArtifactsScanner.registeredID,
            OrphanedCachesScanner.registeredID,
            EphemeralTempScanner.registeredID,
        ], "the temp scanner is APPENDED — every existing slug keeps its place")

        let scanner = try XCTUnwrap(
            runtime.scanners.compactMap { $0 as? EphemeralTempScanner }.first
        )
        XCTAssertEqual(scanner.id, "ephemeral_tmp")
        XCTAssertEqual(scanner.displayName, "Ephemeral Temp Files")

        // The declared roots are the confstr set — resolved through the SAME
        // declaration, so this is a property of the composition rather than
        // of this machine's answers.
        let declared = EphemeralTempRoots.resolve()
        XCTAssertEqual(scanner.trustedContainerRoots.map(\.path),
                       declared.map(\.url.path))
        XCTAssertFalse(declared.isEmpty,
                       "/private/tmp is unconditional — the set is never empty")
        for root in declared {
            XCTAssertTrue(
                runtime.trustedContainerRoots.contains { $0.path == root.url.path },
                "registration is what extends delete-time admission: \(root.url.path)"
            )
        }
    }

    /// Thresholds are CONSTRUCTION state, threaded through the factory: a
    /// non-nil value reaches the scanner unchanged (the CLI's
    /// invocation-scoped path), and `nil` — the GUI's bare composition —
    /// resolves defaults → UserDefaults INSIDE the factory.
    func testProductionThreadsInvocationThresholdsAndResolvesNilInsideTheFactory() throws {
        let suite = try makeSuite()
        let devRoots = DevRootsStore(defaults: suite).effectiveRoots(home: fixtureHome)

        let injected = EphemeralTempSweepConfig.Thresholds(
            sizeFloorBytes: 123_000_000, staleAge: 9 * 86_400
        )
        let overridden = SpaceScannerRuntime.production(
            home: fixtureHome, devRoots: devRoots,
            ephemeralTempThresholds: injected
        )
        XCTAssertEqual(
            overridden.scanners.compactMap { $0 as? EphemeralTempScanner }
                .first?.thresholds,
            injected,
            "invocation-scoped thresholds reach the scanner unchanged"
        )

        // The GUI's composition passes NOTHING — the factory resolves.
        let bare = SpaceScannerRuntime.production(
            home: fixtureHome, devRoots: devRoots
        )
        XCTAssertEqual(
            bare.scanners.compactMap { $0 as? EphemeralTempScanner }
                .first?.thresholds,
            EphemeralTempSweepConfig.resolvedThresholds(),
            "nil resolves defaults → UserDefaults inside the factory"
        )
    }

    /// The CLI half: invocation-scoped thresholds are threaded into
    /// `production()` BEFORE the dependency bundle is built, because
    /// `trustedContainerRoots` freeze at registration.
    func testCLIRuntimeDependenciesThreadInvocationScopedTempThresholds() throws {
        let injected = EphemeralTempSweepConfig.Thresholds(
            sizeFloorBytes: 5_000_000, staleAge: 2 * 86_400
        )
        let deps = CLIHandler.CLIRuntimeDependencies.production(
            ephemeralTempThresholds: injected
        )
        let scanner = try XCTUnwrap(
            deps.runtime.scanners.compactMap { $0 as? EphemeralTempScanner }.first,
            "the CLI composition registers the ephemeral temp scanner"
        )
        XCTAssertEqual(scanner.thresholds, injected)
    }

    // MARK: - R10/R13: the GUI, through the GENERIC section

    /// The GUI half of registration, end to end and with ZERO view or
    /// ViewModel edits behind it: an automatic refresh enumerates NOTHING
    /// (D11 — the user-visible trigger policy fn-6.4 documents), a
    /// user-initiated scan renders the item in the GENERIC per-item section,
    /// Quick Clean picks up nothing, and an EXPLICIT selection cleans the
    /// entry through the session-bound cleaner.
    @MainActor
    func testAutomaticScanEnumeratesNothingWhileUserInitiatedScanCleansThroughTheGenericSection() async throws {
        let entry = try stageStaleEntry("old-scratch")
        let counter = ListCounter()
        let runtime = try makeRuntime([makeScanner(counter: counter)])
        let viewModel = CacheoutViewModel(runtime: runtime)
        let onlyTemp: Set<String> = [EphemeralTempScanner.registeredID]

        // (1) BACKGROUND refresh: the scanner defers entirely — no
        // enumeration, no items, no issues. This is the behavior CATEGORIES
        // states user-visibly.
        await viewModel.scan(trigger: .automatic, scannerIDs: onlyTemp)
        let deferred = try XCTUnwrap(viewModel.perItemSections.first {
            $0.scannerID == EphemeralTempScanner.registeredID
        })
        XCTAssertEqual(counter.count, 0,
                       "an automatic scan enumerates no temp root at all")
        XCTAssertEqual(deferred.items.count, 0)
        XCTAssertEqual(deferred.issues.count, 0,
                       "a deferral carries no items and no issues. NOTE THE "
                        + "SCOPE (PR #459 review r1): this cell defers BEFORE "
                        + "any user-initiated scan, so there is no prior "
                        + "outcome here to retain — what a deferral does to an "
                        + "ALREADY DISPLAYED outcome is "
                        + "`testAutomaticRefreshAfterAUserInitiatedScanRetains…`")

        // (2) The user presses Scan: the item rides the GENERIC section —
        // there is no `ephemeral_tmp` view anywhere in the app.
        await viewModel.scan(trigger: .userInitiated, scannerIDs: onlyTemp)
        XCTAssertGreaterThan(counter.count, 0)
        let section = try XCTUnwrap(viewModel.perItemSections.first {
            $0.scannerID == EphemeralTempScanner.registeredID
        })
        XCTAssertEqual(section.displayName, "Ephemeral Temp Files")
        XCTAssertEqual(section.items.compactMap(\.url?.path),
                       [canonical(tempRoot).appendingPathComponent("old-scratch").path])
        let item = try XCTUnwrap(section.items.first)
        XCTAssertEqual(item.risk, .review)
        XCTAssertEqual(item.isStale, true)
        XCTAssertFalse(section.isScanning,
                       "the existing per-scanner busy state covers it — "
                        + "fn-6 adds no busy flag of its own")

        // (3) Quick Clean enrolls NOTHING: review risk, never
        // automatically clean-eligible.
        XCTAssertFalse(item.automaticCleanEligible)
        viewModel.selectAllSafe()
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty)
        XCTAssertEqual(viewModel.automaticCleanableSize, 0)

        // (4) …while an EXPLICIT selection cleans, through the registration-
        // derived cleaner bound to the producing session's snapshot.
        viewModel.moveToTrash = false  // permanent, fixture-contained
        viewModel.toggleSelection(for: item.key)
        XCTAssertTrue(viewModel.hasCleanableSelection)
        await viewModel.clean()

        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.errors.map(\.message), [])
        XCTAssertEqual(report.entries.map(\.key), [item.key])
        XCTAssertFalse(fm.fileExists(atPath: entry.path),
                       "the stale entry itself is deleted")
        XCTAssertTrue(fm.fileExists(atPath: canonical(tempRoot).path),
                      "the temp ROOT is never a deletion target")
    }

    // MARK: - R10: the CLI surface

    /// `--cli scan` lists the fixture item under `ephemeral_tmp`, an
    /// unconfirmed clean refuses with the plan and deletes nothing, and the
    /// confirmed `<slug>:<item-id>` address deletes exactly that entry. The
    /// schema version stays 4 — every fn-6 addition is additive.
    func testCLIScanListsTempItemsAndCleanRequiresConfirm() async throws {
        let entry = try stageStaleEntry("old-scratch")
        let deps = makeDeps(try makeRuntime([makeScanner()]))

        let envelope = await CLIHandler.scanEnvelope(deps: deps)
        XCTAssertEqual(envelope["schema_version"] as? Int, 4,
                       "cliSchemaVersion stays 4 — the additions are additive")
        let rows = try XCTUnwrap(envelope["scanner_items"] as? [[String: Any]])
        let tempRows = rows.filter {
            $0["scanner_id"] as? String == EphemeralTempScanner.registeredID
        }
        XCTAssertEqual(tempRows.count, 1, "the stale fixture entry is listed")
        let row = try XCTUnwrap(tempRows.first)
        XCTAssertEqual(row["path"] as? String,
                       canonical(tempRoot).appendingPathComponent("old-scratch").path)
        XCTAssertEqual(row["name"] as? String, "old-scratch")
        XCTAssertEqual(row["action"] as? String, "remove_item")
        XCTAssertEqual(row["risk_level"] as? String, "review")
        let itemID = try XCTUnwrap(row["item_id"] as? String)

        // Unconfirmed: exit-1 shape with the plan, nothing deleted.
        let unconfirmed = await CLIHandler.cleanCLIOutcome(
            targets: [EphemeralTempScanner.registeredID],
            dryRun: false, confirmed: false, euid: 501, deps: deps
        )
        guard case .failure(let code, _, let details) = unconfirmed else {
            return XCTFail("an unconfirmed temp clean must be refused")
        }
        XCTAssertEqual(code, "CONFIRMATION_REQUIRED",
                       "the --confirm gate covers this scanner too")
        let plan = try XCTUnwrap(details?["plan"] as? [[String: Any]])
        XCTAssertEqual(plan.map { $0["scanner_id"] as? String },
                       [EphemeralTempScanner.registeredID])
        XCTAssertTrue(fm.fileExists(atPath: entry.path),
                      "a refused clean deletes nothing")

        // Confirmed, addressed by `<slug>:<item-id>`.
        guard case .success(let payload) = await CLIHandler.cleanCLIOutcome(
            targets: ["\(EphemeralTempScanner.registeredID):\(itemID)"],
            dryRun: false, confirmed: true, euid: 501, deps: deps
        ) else {
            return XCTFail("a confirmed item address must clean")
        }
        XCTAssertEqual(payload["schema_version"] as? Int, 4)
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["item_id"] as? String }, [itemID])
        XCTAssertEqual(results.map { $0["success"] as? Bool }, [true])
        XCTAssertFalse(fm.fileExists(atPath: entry.path))
    }

    /// smart-clean is frozen category-only: it never runs the temp scanner,
    /// proven at the enumeration seam (zero listings) — while a scan through
    /// the same runtime does enumerate, so the assertion is not vacuous.
    func testSmartCleanNeverEnumeratesTheEphemeralTempScanner() async throws {
        try stageStaleEntry("old-scratch")
        let counter = ListCounter()
        let categoryScanner = CategoryScanner(
            categories: [],
            scanner: CacheScanner(
                home: fixtureHome, provider: FileSystemIdentityProvider()
            )
        )
        let deps = makeDeps(
            try makeRuntime([categoryScanner, makeScanner(counter: counter)])
        )

        guard case .success = await CLIHandler.smartCleanCLIOutcome(
            targetGB: 1, dryRun: true, confirmed: false, euid: 501, deps: deps
        ) else {
            return XCTFail("the smart-clean dry run must succeed")
        }
        XCTAssertEqual(counter.count, 0,
                       "smart-clean scans the categories scanner ONLY")

        _ = await CLIHandler.scanEnvelope(deps: deps)
        XCTAssertGreaterThan(counter.count, 0,
                             "…and the same runtime DOES enumerate on scan")
    }

    // MARK: - R7: the `--tmp-*` threshold flags

    /// The parse matrix, one refusal per malformed shape. Every failure is
    /// the INVALID_ARGUMENTS convention naming the flag — there is no
    /// USAGE_ERROR arm for a threshold value, and no truncate-to-zero branch
    /// (a positive Int64 × 1,000,000 either overflows or lands ≥ 1,000,000).
    func testTempThresholdFlagParseMatrix() throws {
        // Absent flags parse as NO overrides — the factory then resolves
        // defaults → UserDefaults itself.
        let none = try CLIHandler.parseEphemeralTempThresholdOverrides(
            from: ["scan"]
        ).get()
        XCTAssertNil(none.ageDays)
        XCTAssertNil(none.minSizeMB)

        // Valid values, boundary included.
        let both = try CLIHandler.parseEphemeralTempThresholdOverrides(from: [
            "scan", CLIHandler.tmpAgeDaysFlag, "1",
            CLIHandler.tmpMinSizeMBFlag, "1",
        ]).get()
        XCTAssertEqual(both.ageDays, 1)
        XCTAssertEqual(both.minSizeMB, 1)

        let bad: [[String]] = [
            [CLIHandler.tmpAgeDaysFlag, "0"],
            [CLIHandler.tmpAgeDaysFlag, "-5"],
            [CLIHandler.tmpAgeDaysFlag, "seven"],
            [CLIHandler.tmpAgeDaysFlag, "7.5"],
            [CLIHandler.tmpAgeDaysFlag, "\(Int64.max)"],   // conversion overflow
            [CLIHandler.tmpMinSizeMBFlag, "0"],
            [CLIHandler.tmpMinSizeMBFlag, "-1"],
            [CLIHandler.tmpMinSizeMBFlag, "garbage"],
            [CLIHandler.tmpMinSizeMBFlag, "\(Int64.max)"],
            // A repeated flag is refused outright — first-/last-wins would
            // silently ignore (and skip validating) one occurrence.
            [CLIHandler.tmpAgeDaysFlag, "1", CLIHandler.tmpAgeDaysFlag, "garbage"],
            [CLIHandler.tmpMinSizeMBFlag, "2", CLIHandler.tmpMinSizeMBFlag, "3"],
        ]
        for args in bad {
            switch CLIHandler.parseEphemeralTempThresholdOverrides(
                from: ["scan"] + args
            ) {
            case .success(let parsed):
                XCTFail("\(args) must be rejected, parsed \(parsed)")
            case .failure(let error):
                XCTAssertTrue(error.message.contains(args[0]),
                              "the refusal names the flag: \(error.message)")
            }
        }
    }

    /// THE TRAILING-FLAG CELL, one per flag: a valued flag in LAST argv
    /// position collects no value, and reading that as an ABSENT flag would
    /// silently scan with the PERSISTED thresholds the caller meant to
    /// override (the fn-4.6/fn-4.7 bug shape). It is a refusal, never a nil.
    func testTrailingTempFlagIsRefusedInsteadOfReadingAsAbsent() throws {
        for flag in [CLIHandler.tmpAgeDaysFlag, CLIHandler.tmpMinSizeMBFlag] {
            switch CLIHandler.parseEphemeralTempThresholdOverrides(
                from: ["Cacheout", "--cli", "scan", flag]
            ) {
            case .success(let parsed):
                XCTFail("a trailing \(flag) must not parse as absent: \(parsed)")
            case .failure(let error):
                XCTAssertTrue(error.message.contains(flag),
                              "names the flag: \(error.message)")
            }

            // …and a flag whose "value" is the NEXT flag is refused too: the
            // grammar leaves the value token to the flag's own validation.
            switch CLIHandler.parseEphemeralTempThresholdOverrides(
                from: ["Cacheout", "--cli", "scan", flag, "--confirm"]
            ) {
            case .success(let parsed):
                XCTFail("\(flag) --confirm must not parse: \(parsed)")
            case .failure(let error):
                XCTAssertTrue(error.message.contains(flag), error.message)
            }
        }
    }

    /// The flags ride the ONE normalized grammar as table entries: their
    /// value tokens are consumed, never mistaken for positional targets.
    func testTempFlagsAreValuedFlagsInTheOneGrammar() throws {
        for flag in [CLIHandler.tmpAgeDaysFlag, CLIHandler.tmpMinSizeMBFlag] {
            XCTAssertTrue(CLIHandler.valuedFlags.contains(flag),
                          "\(flag) must be in the valued-flag table")
        }
        guard case .success(let invocation) = CLIHandler.normalizedInvocation(
            command: .clean,
            arguments: [
                "ephemeral_tmp", "--confirm",
                CLIHandler.tmpAgeDaysFlag, "3",
                CLIHandler.tmpMinSizeMBFlag, "7",
            ]
        ) else { return XCTFail("the documented shape must parse") }
        XCTAssertEqual(invocation.targets, ["ephemeral_tmp"],
                       "the flag VALUES are never read as targets")
    }

    /// An override wins for the invocation only: it beats a persisted value
    /// and writes nothing back.
    func testTempFlagOverridesBeatPersistedValuesAndNeverPersist() throws {
        let suite = try makeSuite()
        suite.set(100, forKey: EphemeralTempSweepConfig.minSizeMBKey)
        suite.set(60, forKey: EphemeralTempSweepConfig.ageDaysKey)

        let parsed = try CLIHandler.parseEphemeralTempThresholdOverrides(from: [
            "scan", CLIHandler.tmpAgeDaysFlag, "3",
            CLIHandler.tmpMinSizeMBFlag, "7",
        ]).get()
        let resolved = EphemeralTempSweepConfig.resolvedThresholds(
            defaults: suite,
            minSizeMBOverride: parsed.minSizeMB,
            ageDaysOverride: parsed.ageDays
        )
        XCTAssertEqual(resolved.sizeFloorBytes, 7_000_000)
        XCTAssertEqual(resolved.staleAge, 3 * 86_400)
        XCTAssertEqual(
            suite.integer(forKey: EphemeralTempSweepConfig.minSizeMBKey), 100,
            "the override is never persisted"
        )
        XCTAssertEqual(
            suite.integer(forKey: EphemeralTempSweepConfig.ageDaysKey), 60
        )

        // Half an override still layers: the other half stays persisted.
        let halfway = EphemeralTempSweepConfig.resolvedThresholds(
            defaults: suite, minSizeMBOverride: nil, ageDaysOverride: 3
        )
        XCTAssertEqual(halfway.sizeFloorBytes, 100_000_000)
        XCTAssertEqual(halfway.staleAge, 3 * 86_400)
    }

    // MARK: - R7: the flag-family gate

    /// The generalized pre-dispatch gate, per family: `scan` and `clean`
    /// accept the `--tmp-*` flags (they run the scanner); EVERY other command
    /// refuses them up front, naming the flag, the refusing command, and the
    /// commands that accept it.
    func testTempFlagFamilyGateMatrixAcrossAllCommands() {
        for command in CLIHandler.Command.allCases {
            for flag in [CLIHandler.tmpAgeDaysFlag, CLIHandler.tmpMinSizeMBFlag] {
                let rejection = CLIHandler.rejectedFlag(
                    for: command, in: ["Cacheout", "--cli", command.rawValue, flag, "3"]
                )
                if command == .scan || command == .clean {
                    XCTAssertNil(rejection,
                                 "\(command.rawValue) runs the temp scanner "
                                    + "and accepts \(flag)")
                    continue
                }
                XCTAssertEqual(rejection?.flag, flag,
                               "\(command.rawValue) must refuse \(flag)")
                let message = rejection?.message ?? ""
                XCTAssertTrue(
                    message.contains(flag)
                        && message.contains(command.rawValue)
                        && message.contains("scan or clean"),
                    "actionable refusal: \(message)"
                )
            }
            // Without the flags the gate stays silent — it never turns an
            // ordinary invocation into a usage error.
            XCTAssertNil(CLIHandler.rejectedFlag(
                for: command,
                in: ["Cacheout", "--cli", command.rawValue, "--confirm"]
            ))
        }
    }

    /// The two families' EXACT wording. The sweep's message is asserted
    /// against the LITERAL fn-3.4 shipped, byte for byte: generalizing the
    /// gate must not reword a refusal that consumers and docs already quote.
    func testFamilyRejectionMessagesAreExactAndTheSweepWordingIsUnchanged() {
        XCTAssertEqual(
            CLIHandler.sweepFlagRejectionMessage(
                flag: CLIHandler.orphanStaleDaysFlag, command: .smartClean
            ),
            "--orphan-stale-days is not accepted by smart-clean — only scan "
                + "and clean run the orphaned-caches sweep; use the flag with "
                + "scan or clean"
        )
        XCTAssertEqual(
            CLIHandler.sweepFlagRejectionMessage(
                flag: CLIHandler.orphanSizeFloorFlag, command: .version
            ),
            "--orphan-size-floor-mb is not accepted by version — only scan "
                + "and clean run the orphaned-caches sweep; use the flag with "
                + "scan or clean"
        )
        XCTAssertEqual(
            CLIHandler.ephemeralTempThresholdFlagFamily.rejectionMessage(
                flag: CLIHandler.tmpAgeDaysFlag, command: .smartClean
            ),
            "--tmp-age-days is not accepted by smart-clean — only scan and "
                + "clean run the ephemeral temp scanner; use the flag with "
                + "scan or clean"
        )
        XCTAssertEqual(
            CLIHandler.ephemeralTempThresholdFlagFamily.rejectionMessage(
                flag: CLIHandler.tmpMinSizeMBFlag, command: .diskInfo
            ),
            "--tmp-min-size-mb is not accepted by disk-info — only scan and "
                + "clean run the ephemeral temp scanner; use the flag with "
                + "scan or clean"
        )
    }

    /// ONE gate, families in declaration order: an invocation carrying flags
    /// from BOTH families still reports the sweep flag first, so fn-3.4's
    /// observable behavior is unchanged. And the sweep gate keeps its own
    /// accepted set — a family cannot widen or narrow its neighbour's.
    func testFamilyOrderAndIndependencePreserveTheSweepGateExactly() {
        let both = [
            CLIHandler.tmpAgeDaysFlag, "3",
            CLIHandler.orphanStaleDaysFlag, "30",
        ]
        let rejection = CLIHandler.rejectedFlag(for: .smartClean, in: both)
        XCTAssertEqual(rejection?.flag, CLIHandler.orphanStaleDaysFlag,
                       "the sweep family is still checked first")
        XCTAssertEqual(rejection?.message, CLIHandler.sweepFlagRejectionMessage(
            flag: CLIHandler.orphanStaleDaysFlag, command: .smartClean
        ))
        XCTAssertNil(CLIHandler.rejectedFlag(for: .scan, in: both),
                     "scan accepts both families")
        XCTAssertNil(CLIHandler.rejectedFlag(for: .clean, in: both))

        // The families declare the same accepting set, and each gate reads
        // ONLY its own flags.
        XCTAssertNil(CLIHandler.sweepThresholdFlagFamily.rejectedFlag(
            for: .smartClean, in: [CLIHandler.tmpAgeDaysFlag, "3"]
        ))
        XCTAssertNil(CLIHandler.ephemeralTempThresholdFlagFamily.rejectedFlag(
            for: .smartClean, in: [CLIHandler.orphanStaleDaysFlag, "30"]
        ))
        XCTAssertEqual(
            CLIHandler.scannerThresholdFlagFamilies.map(\.acceptingCommands),
            [[.scan, .clean], [.scan, .clean]]
        )
    }

    // MARK: - PR #459 review r1: cross-scanner root overlap (D4)

    /// THE CONFIGURATION THAT MAKES THE COLLISION ONE FLAG AWAY, asserted
    /// before the fixture that exercises it — otherwise the cell below reads
    /// as a synthetic arrangement nobody could reach.
    ///
    /// `PathGuard.validateContainerRoot` ADMITS `/private/tmp` and `/tmp`
    /// (measured: same `st_dev` as `/private`, and `statfs` names
    /// `/System/Volumes/Data` as the mount, so neither the device check nor
    /// `isMountPoint` fires), and `EphemeralTempRoots.resolve()` declares
    /// `/private/tmp` unconditionally. One path, legal as a dev root AND
    /// declared as a temp root — reachable with `--dev-root /private/tmp` or
    /// one line in the Settings editor.
    func testPrivateTmpIsBothAnAdmissibleDevRootPathAndADeclaredTempRoot() throws {
        let provider = FileSystemIdentityProvider()
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        for spelling in ["/private/tmp", "/tmp"] {
            XCTAssertNoThrow(
                try PathGuard.validateContainerRoot(
                    URL(fileURLWithPath: spelling), home: realHome,
                    provider: provider
                ),
                "\(spelling) is admissible as a container root — the shared "
                    + "policy refuses only /, a device change, a mount point "
                    + "and $HOME"
            )
        }
        XCTAssertTrue(
            EphemeralTempRoots.resolve().contains {
                $0.url.path == "/private/tmp"
            },
            "and it is a DECLARED temp root, unconditionally"
        )
    }

    /// A stale, >floor Python venv as a FIRST-LEVEL entry of the fixture temp
    /// root — the one shape both scanners claim: `markerInside("pyvenv.cfg")`
    /// matches the walked directory itself at depth 1, which is exactly the
    /// depth `ephemeral_tmp` lists.
    @discardableResult
    private func stageFirstLevelVenv(_ name: String = "venv") throws -> URL {
        let venv = tempRoot.appendingPathComponent(name)
        try fm.createDirectory(
            at: venv.appendingPathComponent("lib"),
            withIntermediateDirectories: true
        )
        try Data().write(to: venv.appendingPathComponent("pyvenv.cfg"))
        try Data(repeating: 0x41, count: 12_000_000).write(
            to: venv.appendingPathComponent("lib/big.bin")
        )
        try backdate(venv, to: clock.addingTimeInterval(-30 * 86_400))
        return venv
    }

    private func listedBy(
        _ runtime: SpaceScannerRuntime, path: String
    ) async throws -> (scanners: [String], bytes: Set<Int64>) {
        let everyScanner: Set<String>? = nil
        let session = runtime.scanValidatedSession(
            scannerIDs: everyScanner,
            context: ScanContext(trigger: .userInitiated)
        )
        var outcomes: [String: ScanOutcome] = [:]
        for await event in session.events {
            switch event {
            case .outcome(let id, let outcome): outcomes[id] = outcome
            case .malformed(let id, let issue):
                XCTFail("\(id) malformed: \(issue.detail)")
            }
        }
        let matching = outcomes.filter { _, outcome in
            outcome.items.contains { $0.url?.path == path }
        }
        let bytes = Set(matching.values.flatMap { outcome in
            outcome.items.filter { $0.url?.path == path }.map(\.exactBytes)
        })
        return (matching.keys.sorted(), bytes)
    }

    /// THE CHARACTERIZATION, executed rather than reasoned about: with two
    /// scanners over ONE root there is NO cross-scanner dedupe anywhere (D4),
    /// and both derive item identity from the same `resolveTargetKeepingLeaf`
    /// — so the SAME directory is published twice, with the same url and the
    /// same bytes. The total double-counts, the GUI shows it in two sections,
    /// and selecting both makes the second deletion a ghost-target error.
    /// Neither outcome is malformed: uniqueness is checked WITHIN one outcome
    /// only, so nothing else in the stack notices.
    ///
    /// This cell does NOT go through `DevRootsStore`, deliberately: it is the
    /// standing property the overlap refusal below narrows but does not
    /// remove. A dev root NESTED inside a temp root
    /// (`--dev-root /private/tmp/claude-501`) still reaches exactly this
    /// state, as does a dev root inside `~/Library/Caches` — the pre-existing
    /// accepted class D7 documents, and neither is covered by any rule.
    func testTwoScannersOverOneRootPublishTheSameDirectoryTwice() async throws {
        let venv = try stageFirstLevelVenv()
        let shared = canonical(tempRoot)
        let runtime = try makeRuntime([
            BuildArtifactsScanner(
                home: fixtureHome,
                devRoots: DevRootsResolution(keptRoots: [shared], issues: [])
            ),
            makeScanner(),
        ])

        let found = try await listedBy(
            runtime,
            path: FileSystemIdentityProvider()
                .resolveTargetKeepingLeaf(canonical(venv)).path
        )

        XCTAssertEqual(
            found.scanners,
            [BuildArtifactsScanner.registeredID,
             EphemeralTempScanner.registeredID],
            "no cross-scanner dedupe exists — the directory is listed twice"
        )
        XCTAssertEqual(found.bytes.count, 1,
                       "and with the SAME byte figure, so the total is "
                        + "double-counted: \(found.bytes)")
    }

    /// THE REFUSAL. `DevRootsStore` drops a dev root that IS a temp root,
    /// visibly, so the exact collision above is unreachable through
    /// configuration — the directory is then listed by `ephemeral_tmp` alone.
    ///
    /// Everything is INJECTED: the "temp root" is the fixture directory,
    /// handed to `DevRootsStore` through its `ephemeralTempRoots` seam, so no
    /// real temp root is read or walked.
    func testADevRootThatIsATempRootIsRefusedSoNothingIsListedTwice() async throws {
        let venv = try stageFirstLevelVenv()
        let declared = canonical(tempRoot)
        let suite = try makeSuite()
        let store = DevRootsStore(
            defaults: suite,
            ephemeralTempRoots: { [declared] }
        )

        let resolution = store.effectiveRoots(
            replacing: [declared], home: fixtureHome
        )

        XCTAssertTrue(
            resolution.keptRoots.isEmpty,
            "a dev root that IS a temp root is refused: \(resolution.keptRoots)"
        )
        XCTAssertEqual(resolution.issues.count, 1, "\(resolution.issues)")
        XCTAssertEqual(resolution.issues.first?.kind, .containerRefused,
                       "visible, never a silent drop (R16)")
        XCTAssertEqual(resolution.issues.first?.url?.path, declared.path)
        XCTAssertTrue(
            resolution.issues.first?.detail
                .contains("ephemeral temp root") == true,
            "\(resolution.issues.first?.detail ?? "no issue")"
        )

        // AND THE CONSEQUENCE, through the real runtime and the real
        // validator: with the refused root the build-artifacts scanner has
        // nothing to walk, so the venv is listed ONCE.
        let runtime = try makeRuntime([
            BuildArtifactsScanner(home: fixtureHome, devRoots: resolution),
            makeScanner(),
        ])
        let found = try await listedBy(
            runtime,
            path: FileSystemIdentityProvider()
                .resolveTargetKeepingLeaf(canonical(venv)).path
        )
        XCTAssertEqual(found.scanners, [EphemeralTempScanner.registeredID],
                       "exactly one scanner lists the directory")
    }

    // MARK: - PR #459 review r1: a deferral must not erase what is displayed

    /// A scanner that declines a trigger is NOT IN THE SESSION — and that is
    /// materially different from returning an empty outcome, which asserts
    /// "the roots are empty" and makes `reconcile` replace the scanner's whole
    /// entry: the items, the issues AND the user's ticks.
    ///
    /// The user-visible sequence this pins: press Scan, see the temp findings,
    /// tick one, walk away. At the next auto-refresh (every
    /// `scanIntervalMinutes`, default 30) the section must still be there,
    /// still ticked, and no temp root may have been opened.
    ///
    /// The residual is PINNED here too, with its measured scope rather than
    /// glossed: the retained rows are excluded from Clean until the next
    /// completed user-initiated session (the as-built subset semantics — R9
    /// freshness, fail-closed), and that exclusion is silent in the UI.
    @MainActor
    func testAutomaticRefreshAfterAUserInitiatedScanRetainsTempFindingsAndSelections()
        async throws {
        let entry = try stageStaleEntry("old-scratch")
        let counter = ListCounter()
        // A SECOND scanner so the automatic session still runs something and
        // still completes and adopts — the temp scanner's absence must be the
        // only difference.
        let companion = AlwaysParticipatingFixtureScanner(id: "fixture_other")
        let runtime = try makeRuntime([makeScanner(counter: counter), companion])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .userInitiated)
        let enumeratedDuringUserScan = counter.count
        XCTAssertGreaterThan(enumeratedDuringUserScan, 0)
        let scanned = try XCTUnwrap(viewModel.perItemSections.first {
            $0.scannerID == EphemeralTempScanner.registeredID
        })
        XCTAssertEqual(scanned.items.count, 1)
        let item = try XCTUnwrap(scanned.items.first)
        viewModel.toggleSelection(for: item.key)
        XCTAssertTrue(viewModel.hasCleanableSelection)

        // The timer tick `CacheoutApp` fires — nil `scannerIDs`, exactly as
        // production calls it.
        await viewModel.scan(trigger: .automatic)

        let after = try XCTUnwrap(viewModel.perItemSections.first {
            $0.scannerID == EphemeralTempScanner.registeredID
        })
        XCTAssertEqual(after.items.count, 1,
                       "the prior outcome is RETAINED — a deferral is not a "
                        + "claim that the roots are empty")
        XCTAssertEqual(after.items.first?.key, item.key)
        XCTAssertTrue(viewModel.selectedItemKeys.contains(item.key),
                      "the user's tick survives an unattended refresh")
        XCTAssertEqual(counter.count, enumeratedDuringUserScan,
                       "and the D11 promise still holds: the automatic "
                        + "session opened no temp root at all")
        XCTAssertFalse(after.isScanning,
                       "a scanner that never ran must not be left spinning")
        // THE MEASURED RESIDUAL, stated rather than assumed: the retained rows
        // keep their ticks but are display-only until the next completed
        // user-initiated session.
        XCTAssertFalse(viewModel.hasCleanableSelection,
                       "retained rows are visible-but-non-cleanable (R9)")
        XCTAssertTrue(fm.fileExists(atPath: entry.path))
    }

    /// THE GUARD THE FIX WOULD OTHERWISE ORPHAN.
    ///
    /// Once participation carries the deferral, the D11 cell above drives a
    /// session that selects NO scanner at all, so its `counter.count == 0`
    /// passes whether or not `scan`'s own trigger gate exists. This cell
    /// invokes `scan` DIRECTLY, which is the only place that guard still
    /// decides anything — delete it and this goes red.
    func testDirectAutomaticInvocationEnumeratesNothingAndReportsNothing()
        async throws {
        try stageStaleEntry("old-scratch")
        let counter = ListCounter()
        let scanner = makeScanner(counter: counter)

        let outcome = await scanner.scan(
            context: ScanContext(trigger: .automatic)
        )

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertEqual(counter.count, 0,
                       "no temp root is opened on an automatic trigger")
        XCTAssertFalse(
            scanner.participates(in: ScanContext(trigger: .automatic)),
            "and the session-level deferral says so where a consumer can see it"
        )
        XCTAssertTrue(
            scanner.participates(in: ScanContext(trigger: .userInitiated))
        )
    }

    /// THE ENFORCEMENT POINT IS THE RUNTIME, NOT ONE CONSUMER (PR #459 review
    /// r2).
    ///
    /// The protocol documented non-participation as "the runtime never invokes
    /// the scanner", but `scanValidatedSession` filtered on `scannerIDs`
    /// alone: the ONLY place the predicate was consulted was
    /// `CacheoutViewModel.scan`. `CLIHandler.collectValidatedScan` calls the
    /// session directly and would have invoked a declining scanner — latent
    /// only because every CLI `ScanContext` is `.userInitiated` today.
    ///
    /// This cell bypasses the ViewModel entirely and drives the session the
    /// way the CLI does: the declining scanner must not be invoked and must
    /// yield NO event at all (an `.outcome` would be an empty outcome, which
    /// asserts "the roots are empty").
    func testTheSessionItselfNeverInvokesADecliningScanner() async throws {
        let gatedContainer = base.appendingPathComponent("session-container")
        try fm.createDirectory(
            at: gatedContainer, withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 4_096).write(
            to: gatedContainer.appendingPathComponent("gated-row")
        )
        let gated = TriggerGatedFixtureScanner(
            id: "fixture_gated", container: canonical(gatedContainer)
        )
        let companion = AlwaysParticipatingFixtureScanner(id: "fixture_other")
        let runtime = try makeRuntime([gated, companion])

        for trigger in [ScanTrigger.userInitiated, .automatic] {
            let everyScanner: Set<String>? = nil
            let session = runtime.scanValidatedSession(
                scannerIDs: everyScanner,
                context: ScanContext(trigger: trigger)
            )
            var delivered: Set<String> = []
            for await event in session.events {
                switch event {
                case .outcome(let id, _): delivered.insert(id)
                case .malformed(let id, let issue):
                    XCTFail("\(id) malformed: \(issue.detail)")
                }
            }
            switch trigger {
            case .userInitiated:
                XCTAssertEqual(gated.scanCount.count, 1,
                               "it runs when it participates")
                XCTAssertTrue(delivered.contains("fixture_gated"))
            case .automatic:
                XCTAssertEqual(gated.scanCount.count, 1,
                               "the session must not invoke a scanner that "
                                + "declines the trigger — the ViewModel is "
                                + "not the only caller")
                XCTAssertFalse(
                    delivered.contains("fixture_gated"),
                    "and it must yield NO event: an empty outcome asserts "
                        + "the roots are empty"
                )
            }
            XCTAssertTrue(delivered.contains("fixture_other"),
                          "the rest of the session is unaffected")
        }
    }

    /// THE PENDING-STATE HALF, OBSERVED DURING THE SESSION (PR #459 review
    /// r2) — the half round 1 shipped unevidenced.
    ///
    /// `scanningScannerIDs` is cleared UNCONDITIONALLY in `scan`'s epilogue,
    /// so any assertion made after `scan(trigger:)` returns is vacuously true
    /// whichever set was assigned at the top. Round 1's cell asserted exactly
    /// that, and the mutation it was supposed to catch (reverting
    /// `scanningScannerIDs = participating` while leaving the session's
    /// subset intact) left the whole suite green.
    ///
    /// What is load-bearing: `.remove(scannerID)` fires only on that
    /// scanner's OWN event, so a scanner that never runs is never removed and
    /// sits in the set for the ENTIRE session — which `perItemSections`
    /// renders as `isScanning`, i.e. a section spinning for the whole scan
    /// while nothing is scanning it. This cell holds the session open at a
    /// rendezvous inside a participating scanner and reads both the set and
    /// the rendered section while the session is still live.
    @MainActor
    func testADecliningScannerIsNotPendingWhileTheSessionRuns() async throws {
        let gatedContainer = base.appendingPathComponent("pending-container")
        try fm.createDirectory(
            at: gatedContainer, withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 4_096).write(
            to: gatedContainer.appendingPathComponent("gated-row")
        )
        let gated = TriggerGatedFixtureScanner(
            id: "fixture_gated", container: canonical(gatedContainer)
        )
        let rendezvous = ScanRendezvous()
        let holder = RendezvousFixtureScanner(
            id: "fixture_holder", rendezvous: rendezvous
        )
        let runtime = try makeRuntime([gated, holder])
        let viewModel = CacheoutViewModel(runtime: runtime)

        // A completed user-initiated session first, so the declining scanner
        // HAS a rendered section for the automatic session to spin.
        await viewModel.scan(trigger: .userInitiated)
        XCTAssertEqual(
            viewModel.perItemSections
                .first { $0.scannerID == "fixture_gated" }?.items.count,
            1
        )

        let session = Task { await viewModel.scan(trigger: .automatic) }
        await rendezvous.waitUntilStarted()

        // OBSERVED WHILE THE SESSION IS LIVE — the epilogue has not run.
        XCTAssertTrue(
            viewModel.scanningScannerIDs.contains("fixture_holder"),
            "the fixture must actually hold the session open: "
                + "\(viewModel.scanningScannerIDs)"
        )
        XCTAssertFalse(
            viewModel.scanningScannerIDs.contains("fixture_gated"),
            "a scanner that declined this trigger is never invoked, so no "
                + "event will ever remove it — it must never be marked pending"
        )
        let during = try XCTUnwrap(viewModel.perItemSections.first {
            $0.scannerID == "fixture_gated"
        })
        XCTAssertFalse(during.isScanning,
                       "and the section the user is looking at must not spin "
                        + "for the whole scan while nothing is scanning it")
        XCTAssertEqual(during.items.count, 1,
                       "its prior rows stay rendered throughout")

        rendezvous.release()
        await session.value
    }

    /// The SEAM, not the one scanner: any scanner that declines a trigger is
    /// left out of the session and keeps its prior displayed outcome.
    @MainActor
    func testANonParticipatingScannerIsNeverInvokedAndKeepsItsPriorOutcome()
        async throws {
        let gatedContainer = base.appendingPathComponent("gated-container")
        try fm.createDirectory(at: gatedContainer, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4_096).write(
            to: gatedContainer.appendingPathComponent("gated-row")
        )
        let gated = TriggerGatedFixtureScanner(
            id: "fixture_gated", container: canonical(gatedContainer)
        )
        let companion = AlwaysParticipatingFixtureScanner(id: "fixture_other")
        let runtime = try makeRuntime([gated, companion])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .userInitiated)
        XCTAssertEqual(gated.scanCount.count, 1)
        let before = try XCTUnwrap(viewModel.perItemSections.first {
            $0.scannerID == "fixture_gated"
        })
        XCTAssertEqual(before.items.count, 1)

        await viewModel.scan(trigger: .automatic)

        XCTAssertEqual(gated.scanCount.count, 1,
                       "a non-participating scanner is never invoked")
        let after = try XCTUnwrap(viewModel.perItemSections.first {
            $0.scannerID == "fixture_gated"
        })
        XCTAssertEqual(after.items.count, 1,
                       "and its prior outcome survives the session")
    }
}

/// Always runs; emits nothing. Exists so an automatic session still has a
/// participant, completes and adopts a snapshot.
private struct AlwaysParticipatingFixtureScanner: SpaceScanner {
    let id: String
    var displayName: String { "Fixture \(id)" }
    var trustedContainerRoots: [URL] { [] }

    func scan(context: ScanContext) async -> ScanOutcome {
        ScanOutcome(items: [], errors: [])
    }
}

/// Declines `.automatic` through the PARTICIPATION contract, and would emit a
/// row if it ever ran — so "was it invoked" and "did its row survive" are two
/// separate observations.
private struct TriggerGatedFixtureScanner: SpaceScanner {
    let id: String
    let container: URL
    let scanCount = InvocationCounter()
    var displayName: String { "Fixture \(id)" }
    var trustedContainerRoots: [URL] { [container] }

    func participates(in context: ScanContext) -> Bool {
        context.includeProtectedRoots
    }

    func scan(context: ScanContext) async -> ScanOutcome {
        scanCount.bump()
        let children = ((try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil, options: []
        )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        return ScanOutcome(items: children.map { child in
            ReclaimableItem(
                id: child.lastPathComponent,
                scannerID: id,
                displayName: child.lastPathComponent,
                exactBytes: 4_096,
                estimatedUpToBytes: 0,
                logicalBytes: nil,
                itemCount: 1,
                url: child,
                declaredDisplayPath: child.path,
                rootRecords: [RootScanRecord(
                    requestedURL: child, resolvedURL: child, status: .measured
                )],
                state: .measured,
                scanError: nil,
                risk: .review,
                evidence: "fixture item \(child.lastPathComponent)",
                rebuildNote: nil,
                action: .removeItem,
                admission: .containerItem(
                    originContainer: container, requestedTargetURL: child
                ),
                defaultSelected: false,
                automaticCleanEligible: false,
                isStale: nil
            )
        }, errors: [])
    }
}

/// A thread-safe invocation counter for the gated fixture scanner.
final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func bump() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }
}

/// A two-phase rendezvous so a test can observe view-model state WHILE a scan
/// session is live. No sleeping and no polling: the scanner signals that it
/// has been entered, then parks until the test releases it.
final class ScanRendezvous: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func signalStarted() {
        lock.lock()
        started = true
        let waiter = startWaiter
        startWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                releaseWaiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Participates in every session and PARKS inside `scan` until released on the
/// AUTOMATIC trigger only, so the observed session stays open while the
/// user-initiated session that seeds the fixture still completes normally.
/// Emits nothing.
private struct RendezvousFixtureScanner: SpaceScanner {
    let id: String
    let rendezvous: ScanRendezvous
    var displayName: String { "Fixture \(id)" }
    var trustedContainerRoots: [URL] { [] }

    func scan(context: ScanContext) async -> ScanOutcome {
        if !context.includeProtectedRoots {
            rendezvous.signalStarted()
            await rendezvous.waitForRelease()
        }
        return ScanOutcome(items: [], errors: [])
    }
}
