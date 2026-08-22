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
            listDirectory: { root, limit in
                counter?.bump()
                return try EphemeralTempScanner.boundedFirstLevelNames(
                    of: root, limit: limit
                )
            }
        )
    }

    /// A runtime around the fixture scanner — registration is what puts the
    /// fixture root into delete-time admission, exactly as in production.
    private func makeRuntime(
        _ scanners: [any SpaceScanner],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) throws -> SpaceScannerRuntime {
        try SpaceScannerRuntime(
            scanners: scanners, categories: [], home: fixtureHome,
            provider: provider
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
            GitWorktreeScanner.registeredID,
            EphemeralTempScanner.registeredID,
        ], "the temp scanner is APPENDED — every existing slug keeps its "
            + "place, including git_worktrees, which fn-5 registered ahead "
            + "of it")

        let scanner = try XCTUnwrap(
            runtime.scanners.compactMap { $0 as? EphemeralTempScanner }.first
        )
        XCTAssertEqual(scanner.id, "ephemeral_tmp")
        XCTAssertEqual(scanner.displayName, "Ephemeral Temp Files")

        // The declared roots are the confstr set — resolved through the SAME
        // declaration, so this is a property of the composition rather than
        // of this machine's answers.
        let declared = EphemeralTempRoots.resolve().roots
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

    /// D1 (PR #459 codex r9) — the COMPOSITION link of the alias-drop
    /// disclosure: `production` must hand resolution's `issues` to the
    /// scanner it registers, not just its `roots`.
    ///
    /// b80f15d made a dropped alias spelling visible instead of silent, and
    /// every other link in that chain has a cell: resolution raises the
    /// `.symlinkRoot` issue, and the scanner leads an inspecting outcome with
    /// its `resolutionIssues`. This one did not — deleting the
    /// `resolutionIssues:` argument in `SpaceScannerRuntime.production` left
    /// the whole suite green, so a refactor could drop the argument and ship
    /// a build where a user whose `C` is a symlink onto `T` gets a scan with
    /// `C` absent and nothing naming it.
    ///
    /// Composition only — nothing is scanned, and the fixture roots reach
    /// `production` through the `ephemeralTempRoots:` seam so the resolution
    /// under test is a real `EphemeralTempRoots.resolve` over a real symlink
    /// (only confstr(3) is stubbed).
    func testProductionCarriesResolutionIssuesIntoTheRegisteredScanner() throws {
        let realTemp = base.appendingPathComponent("real-T")
        try fm.createDirectory(at: realTemp, withIntermediateDirectories: true)
        let aliasCache = base.appendingPathComponent("alias-C")
        try fm.createSymbolicLink(at: aliasCache, withDestinationURL: realTemp)

        let resolved = EphemeralTempRoots.resolve(
            confstrPath: { name in
                switch name {
                case _CS_DARWIN_USER_CACHE_DIR: return aliasCache.path
                case _CS_DARWIN_USER_TEMP_DIR: return realTemp.path
                default: return nil
                }
            }
        )
        XCTAssertEqual(
            resolved.issues.map(\.kind), [.symlinkRoot],
            "fixture precondition: the alias spelling is dropped WITH an "
                + "issue — \(resolved.issues)"
        )

        let suite = try makeSuite()
        let runtime = SpaceScannerRuntime.production(
            home: fixtureHome,
            devRoots: DevRootsStore(defaults: suite).effectiveRoots(home: fixtureHome),
            ephemeralTempRoots: resolved
        )
        let scanner = try XCTUnwrap(
            runtime.scanners.compactMap { $0 as? EphemeralTempScanner }.first
        )

        XCTAssertEqual(
            scanner.resolutionIssues, resolved.issues,
            "the registered scanner must carry resolution's drops verbatim"
        )
        XCTAssertFalse(
            scanner.resolutionIssues.isEmpty,
            "an empty list here is the silent-drop regression itself"
        )
        // The other half of the same hand-off, so a swap of the two is not
        // mistaken for a pass.
        XCTAssertEqual(scanner.trustedContainerRoots.map(\.path),
                       resolved.roots.map(\.url.path))
    }

    /// D4 (PR #459 codex r10) — the same wire on the arm the SHIPPED
    /// compositions actually take.
    ///
    /// The cell above hands `production` a pre-built resolution through the
    /// `ephemeralTempRoots:` seam, which BYPASSES the `??` arm entirely.
    /// Neither shipped surface uses that seam: `CacheoutViewModel.production`
    /// (`CacheoutViewModel.swift:483-499`) and
    /// `CLIHandler.CLIRuntimeDependencies.production`
    /// (`CLIHandler.swift:426-438`) both leave it `nil`, so both go through
    /// `EphemeralTempRoots.resolve(provider:confstrPath:)` inside the
    /// factory. Measured at the r9 tip: replacing that arm with one that kept
    /// `roots` and dropped `issues` left the FULL suite green at 1172/2/0 —
    /// the live `confstr(3)` on this host resolves two real directories, so
    /// `resolve().issues` is `[]` and nothing could ever notice.
    ///
    /// This cell stubs `confstr(3)` and NOTHING else — the alias symlink, the
    /// `lstat` probing, the covered-by-a-real-directory comparison and the
    /// drop are all the production code — so the `nil` arm really does
    /// produce a `.symlinkRoot` issue, and the assertion below is what a
    /// future refactor drops the argument against.
    func testProductionsOwnResolutionArmCarriesItsIssuesToo() throws {
        let realTemp = base.appendingPathComponent("real-T")
        try fm.createDirectory(at: realTemp, withIntermediateDirectories: true)
        let aliasCache = base.appendingPathComponent("alias-C")
        try fm.createSymbolicLink(at: aliasCache, withDestinationURL: realTemp)

        let suite = try makeSuite()
        let runtime = SpaceScannerRuntime.production(
            home: fixtureHome,
            devRoots: DevRootsStore(defaults: suite).effectiveRoots(home: fixtureHome),
            // `ephemeralTempRoots:` is deliberately NOT passed: this cell
            // exists to drive the `??` arm those two shipped call sites take.
            ephemeralTempConfstrPath: { name in
                switch name {
                case _CS_DARWIN_USER_CACHE_DIR: return aliasCache.path
                case _CS_DARWIN_USER_TEMP_DIR: return realTemp.path
                default: return nil
                }
            }
        )
        let scanner = try XCTUnwrap(
            runtime.scanners.compactMap { $0 as? EphemeralTempScanner }.first
        )

        XCTAssertEqual(
            scanner.resolutionIssues.map(\.kind), [.symlinkRoot],
            "the factory's OWN resolution must hand its drops to the scanner "
                + "it registers: \(scanner.resolutionIssues)"
        )
        XCTAssertEqual(
            scanner.resolutionIssues.first?.url?.path,
            canonical(base).appendingPathComponent("alias-C").path,
            "and name the DECLARED spelling — canonical parent chain, leaf "
                + "UNRESOLVED — not the link's destination"
        )
        // The roots half of the same hand-off, so a swap is not a pass. The
        // alias is gone; the real container and the unconditional shared root
        // remain.
        XCTAssertEqual(
            scanner.trustedContainerRoots.map(\.path),
            ["/private/tmp", canonical(realTemp).path],
            "the ALIAS is dropped, never the real root"
        )
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

    /// THE DEFERRAL IS DISCLOSED, NOT SILENT (PR #459 codex r11, P2
    /// DISCLOSURE — the exact launch sequence the finding names).
    ///
    /// `ContentView.task` starts an `.automatic` scan on first appearance,
    /// and this scanner does not participate in one, so it publishes NO
    /// outcome: its section carries no items and no issues. That is ALSO
    /// the shape of a scanner that ran and found nothing, and the render
    /// gate hid both — one silence standing for two different facts, with
    /// no way for a user to tell "never looked" from "looked, found
    /// nothing".
    ///
    /// Both halves are asserted here and they MUST differ. After the
    /// automatic scan the section is DISPLAYED and withholds every
    /// affirmative claim ("not scanned yet", no total); after a
    /// user-initiated scan over the SAME (empty) root it goes back to
    /// silence and says "0 found" — which is now a finding rather than a
    /// default.
    @MainActor
    func testTheAutomaticDeferralIsDisclosedAndOnlyAnActualScanClaimsNothingFound() async throws {
        let runtime = try makeRuntime([makeScanner()])
        let viewModel = CacheoutViewModel(runtime: runtime)
        let onlyTemp: Set<String> = [EphemeralTempScanner.registeredID]
        func section() throws -> ScannerSectionModel {
            try XCTUnwrap(viewModel.perItemSections.first {
                $0.scannerID == EphemeralTempScanner.registeredID
            })
        }

        // (1) The launch scan. The scanner defers, so nothing is published.
        await viewModel.scan(trigger: .automatic, scannerIDs: onlyTemp)
        let deferred = try section()
        XCTAssertTrue(deferred.items.isEmpty)
        XCTAssertTrue(deferred.issues.isEmpty)
        XCTAssertFalse(deferred.isScanning)
        XCTAssertTrue(
            deferred.isAwaitingFirstScan,
            "no temp root has been opened — the section may not present "
                + "itself as an inspected one"
        )
        XCTAssertTrue(
            deferred.isDisplayed,
            "the never-inspected case must REACH the user: hiding it is "
                + "the same silence as an inspected-and-empty scanner"
        )
        XCTAssertEqual(deferred.headerCountLabel, "not scanned yet",
                       "\"0 found\" would be an affirmative claim about an "
                        + "inspection that never happened")

        // (2) The user presses Scan. The root is genuinely empty, so this
        //     time "nothing" is a finding — and the section falls silent
        //     again, exactly as every other empty scanner does.
        await viewModel.scan(trigger: .userInitiated, scannerIDs: onlyTemp)
        let scanned = try section()
        XCTAssertTrue(scanned.items.isEmpty)
        XCTAssertTrue(scanned.issues.isEmpty, "\(scanned.issues)")
        XCTAssertFalse(
            scanned.isAwaitingFirstScan,
            "the roots WERE opened this time — an empty outcome is an answer"
        )
        XCTAssertEqual(scanned.headerCountLabel, "0 found")
        XCTAssertFalse(
            scanned.isDisplayed,
            "an inspected-and-empty section stays hidden, unchanged by this "
                + "round — so an ABSENT section means inspected-and-empty "
                + "and nothing else"
        )
    }

    /// SCANNER-DEFINED STALENESS IS THE BULK-SELECTION CONTRACT (PR #459
    /// review r4, codex C2 — DISCLOSURE). At the SHIPPED default thresholds
    /// (7 days / 10 MB), an 8-day-old entry is `isStale: true` and the
    /// section's "Select Stale" action enrolls it, while the 30-day helper
    /// (`ReclaimableItem.isStale(daysSinceModified:)`, build_artifacts' own
    /// predicate) says false for 8 days. That divergence is WHY the button
    /// label carries no numeral: the retired 30-day parenthetical claimed
    /// month-old-only for a selection this cell proves enrolls an 8-day-old
    /// entry in the default configuration. This cell pins all three facts so
    /// neither a re-coupling of temp staleness to 30 days nor a numeral's
    /// return can ship unnoticed. (The 30-day fixture cells elsewhere cannot
    /// see this: only a sub-30-day fixture distinguishes the two predicates.)
    @MainActor
    func testAnEightDayOldEntryIsEnrolledByTheSelectStaleBulkSelection() async throws {
        let entry = tempRoot.appendingPathComponent("eight-day-scratch")
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 12_000_000)
            .write(to: entry.appendingPathComponent("payload.bin"))
        try backdate(entry, to: clock.addingTimeInterval(-8 * 86_400))

        let clock = self.clock
        let scanner = EphemeralTempScanner(
            roots: [EphemeralTempRoot(
                url: canonical(tempRoot),
                label: "Shared temp",
                cleanupEvidence: EphemeralTempRoots.sharedTempEvidence,
                writability: .worldWritable
            )],
            home: fixtureHome,
            thresholds: EphemeralTempSweepConfig.defaultThresholds,
            now: { clock }
        )
        let runtime = try makeRuntime([scanner])
        let viewModel = CacheoutViewModel(runtime: runtime)
        await viewModel.scan(
            trigger: .userInitiated,
            scannerIDs: [EphemeralTempScanner.registeredID]
        )

        let section = try XCTUnwrap(viewModel.perItemSections.first {
            $0.scannerID == EphemeralTempScanner.registeredID
        })
        let item = try XCTUnwrap(section.items.first)
        XCTAssertEqual(item.isStale, true,
                       "8 days > the shipped 7-day default: stale by the "
                        + "scanner that judged it")
        XCTAssertFalse(ReclaimableItem.isStale(daysSinceModified: 8),
                       "…while the 30-day helper disagrees — the two "
                        + "predicates MUST diverge for this cell to pin "
                        + "anything")
        XCTAssertTrue(section.supportsStaleness,
                      "the Select Stale control renders for this section")
        XCTAssertTrue(item.evidence.contains("8 days"),
                      "the TRUE age is the row's evidence: \(item.evidence)")

        viewModel.selectStale(inScanner: EphemeralTempScanner.registeredID)
        XCTAssertEqual(viewModel.selectedItemKeys, [item.key],
                       "the bulk selection enrolls the 8-day-old entry")
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
                XCTAssertTrue(error.message.contains(try XCTUnwrapElement(args, 0)),
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
            EphemeralTempRoots.resolve().roots.contains {
                $0.url.path == "/private/tmp"
            },
            "and it is a DECLARED temp root, unconditionally"
        )
    }

    /// AND THE REAL STORE KEEPS IT (PR #459 review r2). The cell above proves
    /// the two policies do not conflict; this one proves the SHIPPED
    /// resolution actually keeps the path, through a `DevRootsStore` with NO
    /// seam injected — there is no temp-root seam left to inject, which is
    /// half the point of the revert.
    ///
    /// `/private/tmp` is a CONSTANT member of `EphemeralTempRoots.resolve()`
    /// (not confstr-derived), so this needs no machine-specific value and
    /// reads no real `$HOME`; the fixture home is the resolution's home. It
    /// goes RED the moment any store-level overlap refusal returns.
    func testTheRealStoreKeepsPrivateTmpAsADeclaredDevRoot() throws {
        let suite = try makeSuite()
        let declared = URL(fileURLWithPath: "/private/tmp")

        let resolution = DevRootsStore(defaults: suite)
            .effectiveRoots(replacing: [declared], home: fixtureHome)

        XCTAssertEqual(
            resolution.keptRoots.map(\.path), [declared.path],
            "the shipped resolution keeps it: \(resolution.keptRoots)"
        )
        XCTAssertTrue(
            resolution.issues.isEmpty,
            "and raises no issue about it: \(resolution.issues)"
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

    /// One validated session's items per scanner, plus the session snapshot —
    /// which is what `makeCleaner(snapshot:)` requires, so a cell can carry
    /// the same session's items all the way to a real deletion.
    private func scanSession(
        _ runtime: SpaceScannerRuntime
    ) async -> (items: [String: [ReclaimableItem]],
                snapshot: ContainerSnapshot) {
        let everyScanner: Set<String>? = nil
        let session = runtime.scanValidatedSession(
            scannerIDs: everyScanner,
            context: ScanContext(trigger: .userInitiated)
        )
        var items: [String: [ReclaimableItem]] = [:]
        for await event in session.events {
            switch event {
            case .outcome(let id, let outcome): items[id] = outcome.items
            case .malformed(let id, let issue):
                XCTFail("\(id) malformed: \(issue.detail)")
            }
        }
        await session.untilProducerFinishes()
        return (items, session.snapshot)
    }

    /// Every scanner's item paths, so a claim about which SETS overlap can be
    /// executed instead of reasoned about.
    private func itemPathsByScanner(
        _ runtime: SpaceScannerRuntime
    ) async throws -> [String: Set<String>] {
        await scanSession(runtime).items.mapValues {
            Set($0.compactMap { $0.url?.path })
        }
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
    /// same bytes. The GUI shows it in two sections, and selecting both makes
    /// the second deletion a per-item error
    /// (`testCleaningBothDuplicateRowsFreesOnce…` above). Neither outcome is
    /// malformed: uniqueness is checked WITHIN one outcome only, so nothing
    /// else in the stack notices.
    ///
    /// WHICH TOTAL DOUBLES (PR #459 review r3 — F8). The SELECTED-SIZE figure
    /// does, including the one the clean confirmation quotes, because it spans
    /// scanners. The product's headline RECLAIMABLE figure does not: it is
    /// category-scoped and counts per-item scanner bytes ZERO times. Round 2
    /// split those two correctly in `docs/v1/CATEGORIES.md` and in
    /// `testACrossScannerDuplicateInflatesOnlyTheSelectedScopes`, and left the
    /// unqualified "the total double-counts" standing here — including in the
    /// failure message a maintainer reads when this cell breaks.
    ///
    /// This cell does NOT go through `DevRootsStore`, deliberately: it is the
    /// STANDING property, and nothing anywhere narrows it (PR #459 review r2 —
    /// round 1's overlap refusal, which this comment used to point at, is
    /// reverted; it destroyed the whole build-artifacts walk of the colliding
    /// root and aborted the CLI invocation to suppress one duplicated row).
    ///
    /// WHICH ROUTES REACH IT (PR #459 review r3 — F6). Only the EXACT-root
    /// ones: a dev root that IS a temp root, and a dev root that IS
    /// `~/Library/Caches`. A NESTED dev root does not — measured in
    /// `testANestedDevRootProducesNoSamePathDuplicate` above, where the two
    /// scanners' item sets are disjoint because `build_artifacts` items are
    /// proper descendants of its dev root and `ephemeral_tmp` items are the
    /// temp root's first-level entries. The pre-existing accepted class D7
    /// documents, characterized for the caches instance in
    /// `testTwoScannersOverOneCachesRootPublishTheSameDirectoryTwice` below
    /// and written up in `docs/v1/CATEGORIES.md`.
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
                       "and with the SAME byte figure, so the SELECTED-SIZE "
                        + "figure double-counts these bytes (the "
                        + "category-scoped Reclaimable figure counts them "
                        + "zero times): \(found.bytes)")
    }

    /// "CLEANING IS NOT DOUBLED", EXECUTED (PR #459 review r3 — F9).
    ///
    /// `docs/v1/CATEGORIES.md` asserts that selecting both copies of a
    /// cross-scanner duplicate deletes the directory once, that the second row
    /// is refused with nothing reported freed, and that the freed total counts
    /// the bytes once. Round 2 cited a cell that asserts only the four TOTALS
    /// scopes and never cleans anything, so the claim held by construction
    /// with no test behind it. This drives the real `CacheCleaner` over both
    /// rows of the measured exact-root duplicate.
    ///
    /// Order matters to the mechanism (whichever row runs second is the one
    /// refused) but not to the outcome, so both orders are pinned. The doc was
    /// also silent that the refused row surfaces as a per-item ERROR — the
    /// user sees a failure line, not a silent no-op — which is asserted here
    /// and now stated there.
    func testCleaningBothDuplicateRowsFreesOnceBuildArtifactsFirst()
        async throws {
        try await assertDuplicateCleansOnce(buildArtifactsFirst: true)
    }

    func testCleaningBothDuplicateRowsFreesOnceTempFirst() async throws {
        try await assertDuplicateCleansOnce(buildArtifactsFirst: false)
    }

    private func assertDuplicateCleansOnce(
        buildArtifactsFirst: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let venv = try stageFirstLevelVenv()
        let shared = canonical(tempRoot)
        let runtime = try makeRuntime([
            BuildArtifactsScanner(
                home: fixtureHome,
                devRoots: DevRootsResolution(keptRoots: [shared], issues: [])
            ),
            makeScanner(),
        ])
        let scanned = await scanSession(runtime)
        let path = FileSystemIdentityProvider()
            .resolveTargetKeepingLeaf(canonical(venv)).path
        let build = try XCTUnwrap(
            scanned.items[BuildArtifactsScanner.registeredID]?
                .first { $0.url?.path == path },
            file: file, line: line
        )
        let temp = try XCTUnwrap(
            scanned.items[EphemeralTempScanner.registeredID]?
                .first { $0.url?.path == path },
            file: file, line: line
        )
        XCTAssertEqual(build.exactBytes, temp.exactBytes,
                       "the two rows quote the SAME bytes — that is the whole "
                        + "reason the selected-size figure doubles",
                       file: file, line: line)

        let ordered = buildArtifactsFirst ? [build, temp] : [temp, build]
        let report = await runtime
            .makeCleaner(snapshot: scanned.snapshot)
            .clean(items: ordered, moveToTrash: false)

        XCTAssertEqual(report.entries.count, 1,
                       "one directory, one deletion", file: file, line: line)
        XCTAssertEqual(report.entries.first?.scannerID, try XCTUnwrapElement(ordered, 0).scannerID,
                       "the row that ran FIRST is the one that deleted",
                       file: file, line: line)
        XCTAssertEqual(report.totalFreedExact, build.exactBytes,
                       "the freed total counts these bytes ONCE",
                       file: file, line: line)
        XCTAssertEqual(report.errors.count, 1,
                       "the second row is not a silent no-op — it surfaces as "
                        + "a per-item error", file: file, line: line)
        XCTAssertEqual(report.errors.first?.key.scannerID,
                       try XCTUnwrapElement(ordered, 1).scannerID, file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: path),
                       "and the directory really is gone",
                       file: file, line: line)
    }

    /// A NESTED DEV ROOT PRODUCES NO SAME-PATH DUPLICATE AT ALL (PR #459
    /// review r3 — F6). Round 2's characterization, and the doc page it wrote,
    /// listed "a dev root nested inside one" alongside the exact-root case as
    /// if the two behaved identically. MEASURED here, they do not, and the
    /// difference is structural rather than incidental:
    ///
    /// - `build_artifacts` items are proper DESCENDANTS of its dev root; it
    ///   never emits the root itself.
    /// - `ephemeral_tmp` items are exactly the temp root's FIRST-LEVEL
    ///   entries.
    ///
    /// So at nesting depth >= 1 the two sets are DISJOINT by construction: the
    /// only shared object is the dev root, which one scanner emits (as a
    /// first-level temp entry) and the other structurally cannot. What remains
    /// is an ancestor/descendant relation at DIFFERENT paths — the outer
    /// directory's bytes contain the inner one's, which is ordinary nesting
    /// and not a duplicated row. The exact-root case
    /// (`testTwoScannersOverOneRootPublishTheSameDirectoryTwice` above) is the
    /// one that duplicates, and it is the only one.
    func testANestedDevRootProducesNoSamePathDuplicate() async throws {
        let outer = tempRoot.appendingPathComponent("outer")
        let inner = outer.appendingPathComponent("inner-venv")
        try fm.createDirectory(
            at: inner.appendingPathComponent("lib"),
            withIntermediateDirectories: true
        )
        try Data().write(to: inner.appendingPathComponent("pyvenv.cfg"))
        try Data(repeating: 0x41, count: 12_000_000).write(
            to: inner.appendingPathComponent("lib/big.bin")
        )
        try backdate(outer, to: clock.addingTimeInterval(-30 * 86_400))

        let devRoot = canonical(outer)
        let runtime = try makeRuntime([
            BuildArtifactsScanner(
                home: fixtureHome,
                devRoots: DevRootsResolution(keptRoots: [devRoot], issues: [])
            ),
            makeScanner(),
        ])
        let paths = try await itemPathsByScanner(runtime)
        let resolve = { (url: URL) in
            FileSystemIdentityProvider()
                .resolveTargetKeepingLeaf(url).path
        }

        XCTAssertEqual(
            paths[EphemeralTempScanner.registeredID],
            [resolve(devRoot)],
            "ephemeral_tmp lists the temp root's first-level entry — the dev "
                + "root itself"
        )
        XCTAssertEqual(
            paths[BuildArtifactsScanner.registeredID],
            [resolve(canonical(inner))],
            "build_artifacts lists a proper descendant of its dev root, never "
                + "the root"
        )
        XCTAssertEqual(
            paths[EphemeralTempScanner.registeredID]?
                .intersection(paths[BuildArtifactsScanner.registeredID] ?? []),
            [],
            "no path is listed twice, so there is no duplicate to de-duplicate"
        )
    }

    /// The other half of F6, and the sharper one: when the nested dev root IS
    /// itself the artifact — `--dev-root <tempRoot>/venv` on a stale venv —
    /// `build_artifacts` emits NOTHING, because its own root can never be one
    /// of its descendants. `ephemeral_tmp` lists it alone. The doc's
    /// reassurance paragraph about duplicate cleaning has nothing to apply to
    /// here, which is exactly why the nested case must not be sold as the same
    /// case.
    func testADevRootThatIsItselfTheArtifactIsListedOnlyByTheTempScanner()
        async throws {
        let venv = try stageFirstLevelVenv("nested-venv")
        let devRoot = canonical(venv)
        let runtime = try makeRuntime([
            BuildArtifactsScanner(
                home: fixtureHome,
                devRoots: DevRootsResolution(keptRoots: [devRoot], issues: [])
            ),
            makeScanner(),
        ])
        let paths = try await itemPathsByScanner(runtime)

        XCTAssertEqual(
            paths[BuildArtifactsScanner.registeredID], [],
            "build_artifacts never emits its own dev root as an item"
        )
        XCTAssertEqual(
            paths[EphemeralTempScanner.registeredID],
            [FileSystemIdentityProvider()
                .resolveTargetKeepingLeaf(devRoot).path],
            "so the entry is listed exactly once, by the temp scanner"
        )
    }

    /// A DEV ROOT THAT IS A TEMP ROOT IS ACCEPTED (PR #459 review r2 — this
    /// cell replaces round 1's `testADevRootThatIsATempRootIsRefused…`).
    ///
    /// Round 1 answered a DISCLOSURE defect — one directory listed twice —
    /// with a root-granular refusal, and the trade was measured catastrophic:
    /// `--dev-root /private/tmp` returned `{"ok": false, "code":
    /// "INVALID_ARGUMENTS", … "Nothing was scanned."}` for the WHOLE
    /// invocation, and the persisted/Settings route silently discarded the
    /// entire depth-8 build-artifacts walk beneath the root. `ephemeral_tmp`
    /// is no substitute for it: it lists FIRST-LEVEL entries only, at or above
    /// a size floor, and only when both staleness halves pass.
    ///
    /// So the load-bearing assertion is the SECOND one. Round 1's cell only
    /// checked the first-level venv, which is precisely the entry both
    /// scanners claim — that is why it could stay green while everything
    /// deeper vanished. This cell stages a tree BELOW first level and asserts
    /// it is still listed by `build_artifacts` and by nobody else, which is
    /// exactly the coverage a root-level refusal destroys.
    ///
    /// WHAT THIS CELL DOES NOT DO, measured rather than assumed: its temp root
    /// is a FIXTURE directory, so re-landing round 1's refusal verbatim — it
    /// keys on the machine's real temp-root set — leaves this cell GREEN. The
    /// cells that go RED on that exact mutation are
    /// `testTheRealStoreKeepsPrivateTmpAsADeclaredDevRoot` and CLIGateTests'
    /// `testAnEphemeralTempRootIsALegalDevRootValue`, both of which resolve
    /// the literal `/private/tmp` through a non-injected store (verified: 2
    /// cells, 4 assertions red).
    func testADevRootThatIsATempRootIsAcceptedAndItsDeeperTreesStayListed()
        async throws {
        try stageFirstLevelVenv()
        // BELOW first level, and fresh: invisible to `ephemeral_tmp` on both
        // counts, so `build_artifacts` is the only scanner that can list it.
        let project = tempRoot.appendingPathComponent("proj")
        let modules = project.appendingPathComponent("node_modules")
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("package.json"))
        try Data(repeating: 0x42, count: 2_000_000).write(
            to: modules.appendingPathComponent("big.bin")
        )

        let declared = canonical(tempRoot)
        let suite = try makeSuite()
        let resolution = DevRootsStore(defaults: suite)
            .effectiveRoots(replacing: [declared], home: fixtureHome)

        XCTAssertEqual(resolution.keptRoots.map(\.path), [declared.path],
                       "the root is walked: \(resolution.keptRoots)")
        XCTAssertTrue(resolution.issues.isEmpty, "\(resolution.issues)")

        let runtime = try makeRuntime([
            BuildArtifactsScanner(home: fixtureHome, devRoots: resolution),
            makeScanner(),
        ])
        let deep = try await listedBy(
            runtime,
            path: FileSystemIdentityProvider()
                .resolveTargetKeepingLeaf(canonical(modules)).path
        )
        XCTAssertEqual(
            deep.scanners, [BuildArtifactsScanner.registeredID],
            "a tree below first level is listed by build_artifacts and by "
                + "NOBODY else — a root-level refusal would lose it entirely"
        )
    }

    /// THE SAME OVERLAP, PRE-EXISTING AND OLDER THAN fn-6 (PR #459 review r2).
    ///
    /// `~/Library/Caches` is an admissible dev root (the shared policy refuses
    /// only `/`, volume roots/mount points and `$HOME`) and it is the
    /// orphaned-caches sweep's own root, so a dev root configured there
    /// publishes the same directory under `build_artifacts` AND
    /// `orphaned_caches`. Pinned here so the class is not misattributed to
    /// fn-6: there is no cross-scanner de-duplication anywhere, and the temp
    /// instance is one instance of that, not a new defect.
    func testTwoScannersOverOneCachesRootPublishTheSameDirectoryTwice()
        async throws {
        let caches = base.appendingPathComponent("Caches")
        let bundle = caches.appendingPathComponent("com.fixture.stale")
        try fm.createDirectory(
            at: bundle.appendingPathComponent("lib"),
            withIntermediateDirectories: true
        )
        try Data().write(to: bundle.appendingPathComponent("pyvenv.cfg"))
        try Data(repeating: 0x41, count: 12_000_000).write(
            to: bundle.appendingPathComponent("lib/big.bin")
        )
        try backdate(bundle, to: Date().addingTimeInterval(-120 * 86_400))

        let shared = canonical(caches)
        let runtime = try makeRuntime([
            BuildArtifactsScanner(
                home: fixtureHome,
                devRoots: DevRootsResolution(keptRoots: [shared], issues: [])
            ),
            OrphanedCachesScanner(home: fixtureHome, cachesRoot: shared),
        ])

        let found = try await listedBy(
            runtime,
            path: FileSystemIdentityProvider()
                .resolveTargetKeepingLeaf(canonical(bundle)).path
        )

        XCTAssertEqual(
            found.scanners,
            [BuildArtifactsScanner.registeredID,
             OrphanedCachesScanner.registeredID],
            "the overlap class predates fn-6 and is not temp-specific"
        )
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

    // MARK: - Snapshot capture set (PR #459 codex r16, AVAILABILITY)

    /// A deferred scanner's roots must not be `lstat`ed either. Before this
    /// round `ContainerSnapshot.capture` ran over EVERY registered root
    /// BEFORE the participation filter, so an `.automatic` refresh made
    /// filesystem contact with the roots of a scanner the same session had
    /// already decided not to run — the explicit-only contract stopped the
    /// task, the event and the item, and left the access.
    func testAnAutomaticSessionNeverIdentityProbesADeferredScannersRoots()
        async throws {
        let gatedContainer = base.appendingPathComponent("gated-container")
        let liveContainer = base.appendingPathComponent("live-container")
        for url in [gatedContainer, liveContainer] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let provider = IdentityRecordingProvider()
        let gated = TriggerGatedFixtureScanner(
            id: "fixture_gated", container: canonical(gatedContainer)
        )
        let companion = AlwaysParticipatingFixtureScanner(
            id: "fixture_other", containers: [canonical(liveContainer)]
        )
        let runtime = try makeRuntime([gated, companion], provider: provider)

        provider.arm()
        let deferredSession = runtime.scanValidatedSession(
            context: ScanContext(trigger: .automatic)
        )
        for await _ in deferredSession.events {}
        provider.disarm()
        let deferredProbes = provider.recorded

        XCTAssertTrue(
            deferredProbes.contains(canonical(liveContainer).path),
            "the participating scanner's root is still captured: "
                + "\(deferredProbes)"
        )
        XCTAssertFalse(
            deferredProbes.contains(canonical(gatedContainer).path),
            "a scanner that declined this trigger must not have its roots "
                + "touched by the capture either: \(deferredProbes)"
        )

        provider.arm()
        let liveSession = runtime.scanValidatedSession(
            context: ScanContext(trigger: .userInitiated)
        )
        for await _ in liveSession.events {}
        provider.disarm()
        XCTAssertTrue(
            provider.recorded.contains(canonical(gatedContainer).path),
            "and the SAME root is captured when the scanner does run — the "
                + "filter is participation, not a permanent exclusion: "
                + "\(provider.recorded)"
        )
    }

    /// The same narrowing for a caller-chosen SUBSET: a session that never
    /// asked for a scanner must not touch its roots.
    func testAScannerSubsetSessionCapturesOnlyTheSubsetsRoots() async throws {
        let outsideContainer = base.appendingPathComponent("outside-container")
        let insideContainer = base.appendingPathComponent("inside-container")
        for url in [outsideContainer, insideContainer] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let provider = IdentityRecordingProvider()
        let outside = AlwaysParticipatingFixtureScanner(
            id: "fixture_outside", containers: [canonical(outsideContainer)]
        )
        let inside = AlwaysParticipatingFixtureScanner(
            id: "fixture_inside", containers: [canonical(insideContainer)]
        )
        let runtime = try makeRuntime([outside, inside], provider: provider)

        provider.arm()
        let session = runtime.scanValidatedSession(
            scannerIDs: ["fixture_inside"],
            context: ScanContext(trigger: .userInitiated)
        )
        for await _ in session.events {}
        provider.disarm()

        XCTAssertTrue(
            provider.recorded.contains(canonical(insideContainer).path),
            "the requested scanner's root is captured: \(provider.recorded)"
        )
        XCTAssertFalse(
            provider.recorded.contains(canonical(outsideContainer).path),
            "a scanner nobody asked for must not have its roots probed: "
                + "\(provider.recorded)"
        )
    }

    /// THE ANTI-STRAND CELL for the narrowing above. Delete-time root matching
    /// is by canonical identity over the whole union and returns the FIRST
    /// match, and the snapshot is keyed by THAT entry's declared spelling — so
    /// a PARTICIPATING scanner's origin claim can legitimately key off a union
    /// entry only a NON-participating scanner declared. Filtering the capture
    /// set by declared path alone would turn that admission into
    /// `containerUnavailable`: a clean the user is entitled to, refused.
    ///
    /// Staged exactly: `real/x` (declared by the deferred scanner, registered
    /// FIRST so it wins the union's first-match) and `link/x` (declared by the
    /// participating one, a real directory reached through a symlinked
    /// ANCESTOR, so alias suppression drops neither).
    func testAParticipatingScannersAliasedRootIsStillCaptured() async throws {
        let real = base.appendingPathComponent("real")
        let realX = real.appendingPathComponent("x")
        try fm.createDirectory(at: realX, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let linkX = link.appendingPathComponent("x")

        let provider = FileSystemIdentityProvider()
        XCTAssertEqual(
            provider.probeKind(of: linkX), .kind(.directory),
            "the alias spelling must lstat as a real directory, or "
                + "suppressingAliasShadows would drop it and the cell would "
                + "prove nothing"
        )

        let deferred = TriggerGatedFixtureScanner(
            id: "fixture_gated", container: realX
        )
        let participant = AlwaysParticipatingFixtureScanner(
            id: "fixture_other", containers: [linkX]
        )
        let runtime = try makeRuntime([deferred, participant], provider: provider)
        XCTAssertEqual(
            runtime.trustedContainerRoots.map(\.path),
            [realX.path, linkX.path],
            "both spellings must survive into the union, in this order"
        )

        let session = runtime.scanValidatedSession(
            context: ScanContext(trigger: .automatic)
        )
        for await _ in session.events {}

        let pathGuard = PathGuard(
            home: fixtureHome,
            containerRoots: runtime.trustedContainerRoots,
            provider: provider
        )
        XCTAssertNoThrow(
            try pathGuard.admitContainer(linkX, snapshot: session.snapshot),
            "the participating scanner's own container must still admit — "
                + "its claim matches the deferred scanner's spelling, which "
                + "the capture set has to carry for exactly that reason"
        )
    }
}

/// Always runs; emits nothing. Exists so an automatic session still has a
/// participant, completes and adopts a snapshot. `containers` defaults to
/// EMPTY — the cells that only need a participant pass nothing; the snapshot
/// cells give it a root so "the participant's root WAS captured" is a
/// positive observation beside the deferred scanner's negative one.
private struct AlwaysParticipatingFixtureScanner: SpaceScanner {
    let id: String
    var containers: [URL] = []
    var displayName: String { "Fixture \(id)" }
    var trustedContainerRoots: [URL] { containers }

    func scan(context: ScanContext) async -> ScanOutcome {
        ScanOutcome(items: [], errors: [])
    }
}

/// Records every `identity(of:)` the runtime asks for, while recording is
/// ARMED. Capture is the only caller during a session whose scanners touch
/// nothing, so an armed window around `scanValidatedSession` observes exactly
/// the snapshot's capture set.
final class IdentityRecordingProvider: FileSystemIdentityProvider,
    @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var paths: [String] = []

    func arm() {
        lock.lock(); defer { lock.unlock() }
        armed = true
        paths = []
    }

    func disarm() {
        lock.lock(); defer { lock.unlock() }
        armed = false
    }

    var recorded: [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }

    override func identity(of url: URL) -> Identity? {
        lock.lock()
        if armed { paths.append(url.path) }
        lock.unlock()
        return super.identity(of: url)
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

/// A thread-safe invocation counter shared by the fixture doubles.
///
/// `bump()` returns the NEW value so a caller can act on "the Nth time" in
/// ONE atomic step — reading `count` after a separate `bump()` is two
/// operations and can interleave. `WorktreeReclaimPerformerTests` uses that
/// to fire on the Nth invocation of a repeated argv — for example the FIRST
/// `merge-base`, R2's last rung, which is the window between the ignored
/// witness and the last gate. (Through r4 this note named "the fallback's
/// `rev-parse --git-common-dir`, the SECOND one the performer runs"; there is
/// one arm and one gate re-establishment now, and the second
/// `--git-common-dir` belongs to the POST-removal prune recompute.)
final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    @discardableResult
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
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
