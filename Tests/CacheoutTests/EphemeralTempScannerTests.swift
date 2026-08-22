import XCTest
import Darwin
@testable import Cacheout

/// fn-6.2 tests: the `EphemeralTempScanner` core — the scanner-wide trigger
/// gate (R13), the sticky-root ownership gate (R14), the two-stage staleness
/// truth table (R1), the pinned stage order and the cooperative lock probe
/// (R6), `.deletionTarget` sizing with its between-stages window closed (R8),
/// the freshness re-check and the post-sizing outcome table (R12), denial
/// classification by operation + provenance (R5), missing-vs-denied roots
/// (R11), and leaf-preserving identity/emission (R3/R4/R8).
///
/// House rules honored throughout: every root is an INJECTED fixture — no test
/// reads a real temp root or the real `$HOME`; `chmod 000` fixtures yield
/// EACCES for the test's own user (real sticky-root EPERM needs a second uid
/// and is NOT fixturable, so every EPERM cell is INJECTED), permissions are
/// restored before teardown, and those tests skip under euid 0.
///
/// NOTE ON CLAIM SCOPE (epic D10): the symlink-swap test below proves that the
/// BETWEEN-STAGES window is closed. It does not — and no assertion, name or
/// comment here may — claim that a swap is impossible: the pre-filter
/// lstat→walk, sizer probe→enumerate, and root probe→list windows are
/// documented, accepted residuals.
final class EphemeralTempScannerTests: XCTestCase {

    private var base: URL!
    private var home: URL!
    private var sharedRootURL: URL!
    private var userRootURL: URL!
    private let fm = FileManager.default

    /// A fixed scan instant; every fixture date is expressed against it.
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var oldDate: Date { clock.addingTimeInterval(-30 * 86_400) }
    private var freshDate: Date { clock.addingTimeInterval(-3_600) }

    /// 7 days / 4 KB — the shipped age default with a small floor so fixtures
    /// stay cheap. The floor stays POSITIVE, which is what keeps the
    /// vacuously-stale empty-directory cell off the list.
    private let thresholds = EphemeralTempSweepConfig.Thresholds(
        sizeFloorBytes: 4_096, staleAge: 7 * 86_400
    )

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("EphemeralTempScannerTests-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        sharedRootURL = base.appendingPathComponent("shared-temp")
        userRootURL = base.appendingPathComponent("user-temp")
        for url in [home, sharedRootURL, userRootURL] {
            try fm.createDirectory(at: url!, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Fixture helpers

    @discardableResult
    private func mkdir(_ url: URL) throws -> URL {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeFile(_ url: URL, bytes: Int = 8_192) throws -> URL {
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func setDate(_ url: URL, _ date: Date) throws {
        try fm.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path
        )
    }

    /// Backdate a whole tree: children first, the directory itself LAST (its
    /// own mtime is a stage-1 input, and creating children bumps it).
    private func backdate(_ url: URL, to date: Date) throws {
        if let kind = FileSystemIdentityProvider().kind(of: url),
           kind == .directory {
            for child in try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: []
            ) {
                try backdate(child, to: date)
            }
        }
        try setDate(url, date)
    }

    private func chmod000(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock { [fm] in
            try? fm.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }
    }

    /// Skip the permission-shaped cells when running as root (where `chmod
    /// 000` denies nothing).
    private func skipUnderRoot() throws {
        try XCTSkipIf(geteuid() == 0, "chmod-000 denies nothing under euid 0")
    }

    private func canonical(_ url: URL) -> URL {
        FileSystemIdentityProvider().canonicalize(url)
    }

    /// The spelling the scanner works in: the root's resolved spelling plus
    /// the entry leaf. Fixture URLs come back from
    /// `FileManager.temporaryDirectory` in the `/var/…` alias spelling, and
    /// fn-6.1 resolves each root's parent chain exactly once — so an
    /// assertion against the raw fixture URL would compare the wrong
    /// spelling. These fixture roots are real directories, so the resolved
    /// spelling and the fully canonical one coincide.
    private func entryPath(_ name: String, under root: URL) -> String {
        canonical(root).appendingPathComponent(name).path
    }

    /// A declared root over a fixture directory, in its CANONICAL spelling
    /// (what fn-6.1 hands the scanner in production).
    private func makeRoot(
        _ url: URL,
        label: String,
        writability: EphemeralTempRoot.Writability,
        evidence: String = EphemeralTempRoots.sharedTempEvidence,
        canonicalize: Bool = true
    ) -> EphemeralTempRoot {
        EphemeralTempRoot(
            url: canonicalize ? canonical(url) : url,
            label: label,
            cleanupEvidence: evidence,
            writability: writability
        )
    }

    private func sharedRoot(
        canonicalize: Bool = true
    ) -> EphemeralTempRoot {
        makeRoot(sharedRootURL, label: "Shared temp",
                 writability: .worldWritable, canonicalize: canonicalize)
    }

    private func userRoot() -> EphemeralTempRoot {
        makeRoot(userRootURL, label: "Per-user temp container (T)",
                 writability: .perUser,
                 evidence: EphemeralTempRoots.userTempEvidence)
    }

    private func makeScanner(
        roots: [EphemeralTempRoot],
        resolutionIssues: [ScanIssue] = [],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        thresholds: EphemeralTempSweepConfig.Thresholds? = nil,
        prefilterEntryLimit: Int =
            EphemeralTempScanner.defaultPrefilterEntryLimit,
        rootEntryLimit: Int = EphemeralTempScanner.defaultRootEntryLimit,
        prefilterRootBudget: Int =
            EphemeralTempScanner.defaultPrefilterRootBudget,
        lockProbe: EphemeralTempScanner.LockProber? = nil,
        listDirectory: EphemeralTempScanner.DirectoryLister? = nil,
        readChildNames: EphemeralTempScanner.BoundedChildReader? = nil,
        candidateSizer: EphemeralTempScanner.CandidateSizer? = nil
    ) -> EphemeralTempScanner {
        let clock = self.clock
        return EphemeralTempScanner(
            roots: roots,
            resolutionIssues: resolutionIssues,
            home: home,
            thresholds: thresholds ?? self.thresholds,
            provider: provider,
            prefilterEntryLimit: prefilterEntryLimit,
            rootEntryLimit: rootEntryLimit,
            prefilterRootBudget: prefilterRootBudget,
            now: { clock },
            lockProbe: lockProbe ?? { EphemeralTempScanner.cooperativeLockProbe($0) },
            listDirectory: listDirectory ?? {
                try EphemeralTempScanner.boundedFirstLevelNames(
                    of: $0, limit: $1
                )
            },
            readChildNames: readChildNames ?? {
                EphemeralTempScanner.boundedChildNames(of: $0, limit: $1)
            },
            candidateSizer: candidateSizer
        )
    }

    private func scan(
        _ scanner: EphemeralTempScanner, trigger: ScanTrigger = .userInitiated
    ) async -> ScanOutcome {
        await scanner.scan(context: ScanContext(trigger: trigger))
    }

    private func itemsByName(
        _ outcome: ScanOutcome
    ) -> [String: ReclaimableItem] {
        Dictionary(
            uniqueKeysWithValues: outcome.items.map { ($0.displayName, $0) }
        )
    }

    /// The outcome must pass fn-2's shared fail-closed validation THROUGH the
    /// runtime — a malformed outcome would drop every item of this scanner
    /// from the GUI, the CLI and the cleaner alike.
    private func assertValidates(
        _ outcome: ScanOutcome, scanner: EphemeralTempScanner,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let runtime = try SpaceScannerRuntime(
            scanners: [scanner], categories: [], home: home,
            provider: FileSystemIdentityProvider()
        )
        let event = runtime.validatedOutcome(
            outcome, from: EphemeralTempScanner.registeredID
        )
        guard case .outcome = event else {
            return XCTFail("outcome failed fn-2 validation: \(event)",
                           file: file, line: line)
        }
    }

    // MARK: - Test doubles

    /// Records every sizing call (URL AND mode), can stage a between-stages
    /// race before delegating, and can stub the report outright for the
    /// post-sizing rows a real fixture cannot produce.
    private final class SizingSpy: @unchecked Sendable {
        private(set) var calls: [(url: URL, mode: DirectorySizer.Mode)] = []
        var beforeMeasure: ((URL) -> Void)?
        var stub: ((URL) -> SizeReport)?
        private let sizer: DirectorySizer

        init(provider: FileSystemIdentityProvider = FileSystemIdentityProvider()) {
            self.sizer = DirectorySizer(provider: provider)
        }

        func measure(_ url: URL, _ mode: DirectorySizer.Mode) -> SizeReport {
            calls.append((url, mode))
            beforeMeasure?(url)
            if let stub { return stub(url) }
            return sizer.measure(at: url, mode: mode)
        }
    }

    /// Records every first-level listing; can throw a crafted error (the only
    /// way to exercise the chain-bearing denial class).
    private final class ListerSpy: @unchecked Sendable {
        private(set) var listed: [URL] = []
        var stubError: Error?

        func list(
            _ url: URL, _ limit: Int
        ) throws -> (names: [String], truncation:
            EphemeralTempScanner.BoundedRead.Truncation?) {
            listed.append(url)
            if let stubError { throw stubError }
            return try EphemeralTempScanner.boundedFirstLevelNames(
                of: url, limit: limit
            )
        }
    }

    private final class OwnerProbeInjectingProvider: FileSystemIdentityProvider {
        var probesByName: [String: OwnerProbe] = [:]

        override func ownerProbe(of url: URL) -> OwnerProbe {
            probesByName[url.lastPathComponent] ?? super.ownerProbe(of: url)
        }
    }

    /// Fails (or vanishes) the kind probe for chosen basenames — the hermetic
    /// stand-in for denials a single uid cannot create.
    private final class FailingKindProbeProvider: FileSystemIdentityProvider {
        var failingNames: [String: Int32] = [:]
        var absentNames: Set<String> = []

        override func probeKind(of url: URL) -> KindProbe {
            let name = url.lastPathComponent
            if absentNames.contains(name) { return .absent }
            if let code = failingNames[name] { return .failed(errno: code) }
            return super.probeKind(of: url)
        }
    }

    /// Lets the first N no-follow metadata reads of a basename succeed and
    /// fails every later one — the hermetic stand-in for a permission change
    /// (or an out-of-domain metadata read) landing DURING the sizing walk,
    /// which a single-uid fixture cannot stage against itself mid-scan.
    ///
    /// Both halves are overridden because `leafDate` re-probes on the nil
    /// path: `leafMetadata` nil alone would be classified `.metadataUnavailable`
    /// via `probeKind`, and this double is about the errno arm.
    private final class LateFailingLeafProvider: FileSystemIdentityProvider {
        /// basename → how many reads succeed before the failure starts.
        var failAfter: [String: Int] = [:]
        private var seen: [String: Int] = [:]
        private var failing: Set<String> = []

        override func leafMetadata(of url: URL) -> LeafMetadata? {
            let name = url.lastPathComponent
            guard let limit = failAfter[name] else {
                return super.leafMetadata(of: url)
            }
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            guard count <= limit else {
                failing.insert(name)
                return nil
            }
            return super.leafMetadata(of: url)
        }

        override func probeKind(of url: URL) -> KindProbe {
            if failing.contains(url.lastPathComponent) {
                return .failed(errno: EIO)
            }
            return super.probeKind(of: url)
        }
    }

    /// Fires a caller-supplied side effect ONCE, immediately after the
    /// staleness pre-filter's metadata read of a chosen walked child has
    /// already been answered.
    ///
    /// This is a TIMING hook, not a behaviour stub: every answer it returns is
    /// `super`'s, and the side effect it runs is a real `rename` + `mkfifo`
    /// that any process sharing a world-writable temp root can perform. It
    /// exists because the window it opens — after the root-level `probeKind`
    /// filter and the ownership gate, before the cooperative lock probe — is
    /// otherwise reachable only by racing a concurrent thread against the
    /// scan (measured: reproduces, but only within 2-4 scan iterations).
    private final class MidWalkSideEffectProvider: FileSystemIdentityProvider {
        /// Basename of the walked CHILD whose metadata read triggers it.
        var trigger: String = ""
        var effect: (() -> Void)?

        override func leafMetadata(of url: URL) -> LeafMetadata? {
            let answer = super.leafMetadata(of: url)
            if url.lastPathComponent == trigger, let effect {
                self.effect = nil
                effect()
            }
            return answer
        }
    }

    /// Reports a child-directory open failure BOTH ways at once, and
    /// disagreeing on purpose: the carrying form returns the real code while
    /// the GLOBAL `errno` is left saying ENOENT.
    ///
    /// That is exactly the hazard `FileSystemIdentityProvider` documents the
    /// carrying twin for — "a test override (or any intervening call) can
    /// clobber it" before the caller reads it — staged hermetically because a
    /// single-uid fixture cannot make a real `openat` fail EACCES against
    /// itself mid-walk while something else resets `errno`.
    private final class ErrnoClobberingProvider: FileSystemIdentityProvider {
        /// Basename of the child directory whose open fails.
        var failingChild: String = ""
        /// The code the CARRYING form reports.
        var carriedCode: Int32 = EACCES

        override func openChildDirectoryCarryingErrno(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> DescriptorOpen {
            guard name == failingChild else {
                return super.openChildDirectoryCarryingErrno(
                    inDirectory: descriptor, named: name, logical: logical()
                )
            }
            errno = ENOENT
            return .failed(errno: carriedCode)
        }

        override func openChildDirectory(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> Int32 {
            guard name == failingChild else {
                return super.openChildDirectory(
                    inDirectory: parent, named: name, logical: url
                )
            }
            errno = ENOENT
            return -1
        }
    }

    /// Injects mount points by inode (the house hermetic pattern).
    private final class BoundaryInjectingProvider: FileSystemIdentityProvider {
        var mountPointInodes: Set<UInt64> = []

        override func isMountPoint(_ url: URL) -> Bool {
            if let id = identity(of: url),
               mountPointInodes.contains(id.inode) { return true }
            return super.isMountPoint(url)
        }
    }

    /// Records every path whose kind was probed — how "nothing outside the
    /// root was enumerated" is asserted (the sizer probes every entry it
    /// walks).
    private final class ProbeRecordingProvider: FileSystemIdentityProvider {
        private(set) var probedPaths: [String] = []

        override func probeKind(of url: URL) -> KindProbe {
            probedPaths.append(url.path)
            return super.probeKind(of: url)
        }
    }

    /// A hand-built report for the post-sizing rows (concurrent-churn cells a
    /// clean pre-filter cannot reach on a real fixture).
    private func report(
        exact: Int64 = 0,
        estimated: Int64 = 0,
        logical: Int64 = 0,
        itemCount: Int = 0,
        denials: [SizeDenial] = [],
        mountBoundaries: [URL] = [],
        rootMountBoundary: Bool = false,
        newestContentDate: Date? = nil
    ) -> SizeReport {
        var report = SizeReport()
        report.exactAllocatedBytes = exact
        report.estimatedUpToBytes = estimated
        report.logicalBytes = logical
        report.itemCount = itemCount
        report.denials = denials
        report.mountBoundaries = mountBoundaries
        report.rootMountBoundary = rootMountBoundary
        report.newestContentDate = newestContentDate
        return report
    }

    /// An old, sized scratch directory under a root — the field shape.
    @discardableResult
    private func makeStaleCandidate(
        _ name: String, under root: URL, bytes: Int = 8_192
    ) throws -> URL {
        let entry = try mkdir(root.appendingPathComponent(name))
        try writeFile(entry.appendingPathComponent("payload.bin"), bytes: bytes)
        try backdate(entry, to: oldDate)
        return entry
    }

    // MARK: - R1: the staleness truth table

    func testOldDirectoryIsListed() async throws {
        try makeStaleCandidate("old-scratch", under: sharedRootURL)
        let scanner = makeScanner(roots: [sharedRoot()])

        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(itemsByName(outcome)["old-scratch"])
        XCTAssertEqual(item.state, .measured)
        XCTAssertNil(item.scanError,
                     "a clean measured item never carries a scan error")
        XCTAssertGreaterThanOrEqual(item.allocatedBytes, 8_192)
        XCTAssertEqual(item.itemCount, 1)
        XCTAssertEqual(item.rootRecords.count, 1)
        XCTAssertEqual(item.rootRecords.first?.status, .measured)
        XCTAssertEqual(item.rootRecords.first?.requestedURL.path,
                       entryPath("old-scratch", under: sharedRootURL))
        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors)")
    }

    func testFreshDirectoryIsNotListed() async throws {
        let entry = try mkdir(
            sharedRootURL.appendingPathComponent("live-session")
        )
        try writeFile(entry.appendingPathComponent("payload.bin"))
        try backdate(entry, to: freshDate)

        let outcome = await scan(makeScanner(roots: [sharedRoot()]))
        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty)
    }

    func testOldDirectoryWithOneDeepFreshFileIsNotListed() async throws {
        let entry = try makeStaleCandidate("mostly-old", under: sharedRootURL)
        let deep = try mkdir(entry.appendingPathComponent("a/b/c"))
        try backdate(entry, to: oldDate)
        // The fresh file lands AFTER the backdating, and only its own mtime is
        // fresh: the newest-content rule must still refuse the whole entry.
        try writeFile(deep.appendingPathComponent("fresh.log"), bytes: 16)
        try setDate(deep.appendingPathComponent("fresh.log"), freshDate)
        try setDate(entry, oldDate)

        let outcome = await scan(makeScanner(roots: [sharedRoot()]))
        XCTAssertTrue(outcome.items.isEmpty,
                      "one deep fresh file disqualifies the whole entry")
        XCTAssertTrue(outcome.errors.isEmpty)
    }

    func testFreshOwnMtimeWithAllOldContentsIsNotListed() async throws {
        let entry = try makeStaleCandidate("touched-dir", under: sharedRootURL)
        // Metadata churn on the entry ITSELF, contents untouched and old: the
        // own-mtime input fails, and this rule is deliberately stricter than
        // `SizeReport.newestContentDate` (which never reads directory mtimes).
        try setDate(entry, freshDate)

        let outcome = await scan(makeScanner(roots: [sharedRoot()]))
        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty)
    }

    func testEmptyOldDirectoryIsNotListedUnderTheFloor() async throws {
        let entry = try mkdir(
            sharedRootURL.appendingPathComponent("empty-old")
        )
        try backdate(entry, to: oldDate)

        let spy = SizingSpy()
        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        ))

        XCTAssertEqual(spy.calls.count, 1,
                       "the empty old directory IS vacuously stale — it "
                        + "reaches stage 2 and is excluded by the floor")
        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty)
        _ = entry
    }

    func testPrefilterCapHitWithoutFreshHitIsNotListed() async throws {
        let entry = try mkdir(sharedRootURL.appendingPathComponent("big-old"))
        for index in 0..<4 {
            try writeFile(
                entry.appendingPathComponent("payload-\(index).bin"), bytes: 4_096
            )
        }
        try backdate(entry, to: oldDate)

        let spy = SizingSpy()
        // A cap below the entry count: the walk cannot prove every file is
        // old, so refusing to list is the safe direction.
        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            prefilterEntryLimit: 2,
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        ))

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(
            outcome.errors.isEmpty,
            "the BUDGET truncation cause is not an anomaly — nothing was "
                + "denied. This cell pins the cap-hit arm ONLY; it has never "
                + "exercised a failed `readdir`, which takes the visible "
                + "`.denied` route (see "
                + "testWalkDisclosesAReadFailureAndStaysSilentOnAVanishedBranch)"
        )
        XCTAssertTrue(spy.calls.isEmpty,
                      "a cap-hit candidate never reaches sizing")
    }

    /// THE r7 CODEX C2 DEFECT, at the walk's disposition.
    ///
    /// A `readdir` that FAILS mid-directory used to be folded into the same
    /// `truncated: Bool` a benign cap hit sets, so the candidate was dropped
    /// with NO item and NO issue — a refusal the user is never told about.
    /// (The GUI consequence stated here was WRONG and is corrected in
    /// PR #459 codex r11: with no items and no issues the section is not
    /// rendered at all — `ScannerSectionModel.isDisplayed` is false — so the
    /// refusal was silent rather than mislabelled "Nothing found".)
    /// An `opendir` failure on the very same subdirectory one entry earlier
    /// was already visible; this closes the asymmetry.
    ///
    /// Driven through the `readChildNames` seam because a real mid-`readdir`
    /// failure cannot be staged deterministically. That production actually
    /// produces `.readFailed` is pinned separately and without any seam by
    /// `testProductionBoundedReadCarriesTheReaddirErrno`.
    func testWalkDisclosesAReadFailureAndStaysSilentOnAVanishedBranch() async throws {
        try makeStaleCandidate("old-scratch", under: sharedRootURL)
        // The walk composes children under the root's DECLARED (canonical)
        // spelling, so the seam must match that, not the `/var/…` fixture URL.
        let subtree = entryPath("old-scratch", under: sharedRootURL)

        // (1) EIO mid-read — the tree could not be read, so the denial is
        //     VISIBLE and the candidate is not listed.
        let denied = await scan(makeScanner(
            roots: [sharedRoot()],
            readChildNames: { url, limit in
                url.path == subtree
                    ? .names([], truncation: .readFailed(errno: EIO))
                    : EphemeralTempScanner.boundedChildNames(of: url, limit: limit)
            }
        ))

        XCTAssertTrue(denied.items.isEmpty,
                      "a tree we could not read is never proven stale")
        XCTAssertEqual(denied.errors.count, 1,
                       "a failed readdir must be disclosed: \(denied.errors)")
        XCTAssertEqual(denied.errors.first?.kind, .unreadable)
        XCTAssertEqual(denied.errors.first?.url?.path, subtree)

        // (2) ENOENT mid-read — the branch vanished under the walk. Absence
        //     is a silent skip at ANY instant (R11), exactly as the
        //     `opendir` ENOENT arm treats it.
        let vanished = await scan(makeScanner(
            roots: [sharedRoot()],
            readChildNames: { url, limit in
                url.path == subtree
                    ? .names([], truncation: .readFailed(errno: ENOENT))
                    : EphemeralTempScanner.boundedChildNames(of: url, limit: limit)
            }
        ))

        XCTAssertTrue(vanished.errors.isEmpty,
                      "a vanished branch is not an impediment: "
                        + "\(vanished.errors)")
    }

    /// THE PRODUCTION HALF that IS provable: a clean read is never misread
    /// as a failed one.
    ///
    /// `readdir` returns nil for BOTH end-of-stream and error, and a cleared
    /// `errno` is the only discriminator. Without the `errno = 0` that
    /// precedes every call, a stale errno left by ANY earlier syscall in the
    /// process would fabricate a `.readFailed` on a perfectly exhaustive
    /// directory — turning a normal scan into a denial row. The stale value
    /// is planted deliberately, because that is exactly what a long-lived
    /// process hands this function.
    ///
    /// HONEST SCOPE — the opposite direction is NOT pinned by this suite.
    /// `.readFailed` itself has no cell, because on this platform a real
    /// mid-loop `readdir` failure could not be staged against the production
    /// function. Measured while writing this cell: a standalone probe holding
    /// a `DIR` handle open and IDLE across `hdiutil detach -force` of an
    /// HFS+ RAM disk DOES get one ("NULL after 256 entries: errno=22
    /// (Invalid argument)"), but eight threads hot-looping the read across
    /// the same teardown produced 1,602 COMPLETE reads, zero interrupted,
    /// and then 55,447 `opendir` failures — the unmount lands between reads,
    /// never inside one, and `boundedChildNames` never leaves a handle idle.
    /// So the disposition of a `.readFailed` is evidenced through the
    /// `readChildNames` seam
    /// (`testWalkDisclosesAReadFailureAndStaysSilentOnAVanishedBranch`) and
    /// the errno carry itself is evidenced only by that direct syscall
    /// measurement. Do not describe this arm as suite-covered.
    func testACleanReadIsNeverMisreadAsAFailedOne() throws {
        let directory = try mkdir(base.appendingPathComponent("clean-read"))
        for index in 0..<5 {
            try writeFile(
                directory.appendingPathComponent("f\(index)"), bytes: 8
            )
        }

        // A stale errno from an unrelated failed syscall, exactly as a
        // long-lived process would carry into this call.
        XCTAssertLessThan(open("/nonexistent-cacheout-probe", O_RDONLY), 0)
        XCTAssertEqual(errno, ENOENT, "the fixture failed to plant a stale errno")

        guard case .names(let names, let truncation) = EphemeralTempScanner
            .boundedChildNames(of: directory, limit: 100)
        else { return XCTFail("the clean read failed outright") }

        XCTAssertEqual(names.count, 5)
        XCTAssertNil(
            truncation,
            "an EXHAUSTIVE read reported truncation — errno is the only "
                + "discriminator between end-of-stream and error, so it must "
                + "be cleared before every readdir or a stale value from any "
                + "earlier syscall fabricates a denial"
        )
    }

    func testRegularFileCandidacyNeedsBothFloorAndAge() async throws {
        // A 16-byte file still ALLOCATES one 4 KB block, so the floor for this
        // cell sits above a single block — otherwise "small" would pass on
        // allocation alone and the test would prove nothing.
        let floored = EphemeralTempSweepConfig.Thresholds(
            sizeFloorBytes: 8_192, staleAge: 7 * 86_400
        )
        let old = try writeFile(
            sharedRootURL.appendingPathComponent("old-big.bin"), bytes: 65_536
        )
        try setDate(old, oldDate)
        let small = try writeFile(
            sharedRootURL.appendingPathComponent("old-small.bin"), bytes: 16
        )
        try setDate(small, oldDate)
        let fresh = try writeFile(
            sharedRootURL.appendingPathComponent("fresh-big.bin"), bytes: 65_536
        )
        try setDate(fresh, freshDate)

        let scanner = makeScanner(
            roots: [sharedRoot()], thresholds: floored
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let names = Set(outcome.items.map(\.displayName))
        XCTAssertEqual(names, ["old-big.bin"],
                       "a regular file is a candidate only when it meets the "
                        + "floor AND is older than the cutoff")
        XCTAssertTrue(outcome.errors.isEmpty)
    }

    /// BOTH THRESHOLD BOUNDARIES, which the docs word DIFFERENTLY on purpose
    /// (PR #459 codex r10, D9): the size floor is "at least 10 MB" and the
    /// age is "OLDER THAN 7 days". One is inclusive and one is not, and until
    /// this cell neither word had a falsifier — the cells around it pin "well
    /// over" and "well under", and no pair of those can tell `>=` from `>`.
    ///
    /// If either assertion goes RED the corresponding word in README.md,
    /// CHANGELOG.md and docs/v1 must change in the SAME commit.
    ///
    /// MUTATION-MEASURED, and the age half is not what it looks like:
    /// relaxing `fileStaleness`'s `date < cutoff` to `<=` ALONE leaves this
    /// cell green, because the post-sizing own-mtime re-check
    /// (`guard own < cutoff`, stage 6) enforces the same boundary a second
    /// time. Both had to be relaxed together — plus the content re-check's
    /// `newest >= cutoff` — before the cell went RED and `exact-age.bin`
    /// appeared. So the cell pins the BEHAVIOUR the docs describe, not any
    /// single comparison; that redundancy is defence in depth, not a spare
    /// line to delete.
    func testTheFloorIsInclusiveAndTheAgeCutoffIsNot() async throws {
        // 8,192 bytes allocates exactly two 4 KB blocks — no rounding slack
        // between the written size and `st_blocks * 512`.
        let floored = EphemeralTempSweepConfig.Thresholds(
            sizeFloorBytes: 8_192, staleAge: 7 * 86_400
        )
        let exactSize = try writeFile(
            sharedRootURL.appendingPathComponent("exact-size.bin"),
            bytes: 8_192
        )
        try setDate(exactSize, oldDate)
        // EXACTLY the cutoff instant: `now - staleAge`. `date < cutoff` is
        // false here, so "older than" excludes it.
        let exactAge = try writeFile(
            sharedRootURL.appendingPathComponent("exact-age.bin"), bytes: 65_536
        )
        try setDate(exactAge, clock.addingTimeInterval(-7 * 86_400))

        let scanner = makeScanner(roots: [sharedRoot()], thresholds: floored)
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertEqual(
            outcome.items.map(\.displayName), ["exact-size.bin"],
            "an entry allocating EXACTLY the floor is listed (the docs say "
                + "\"at least\", and the gate is `>=`) while an entry exactly "
                + "AT the cutoff is not (the docs say \"older than\", and the "
                + "gate is `<`)"
        )
    }

    // MARK: - R4: own-process safety is the AGE gate

    /// The field case: the CURRENTLY RUNNING session's scratchpad sits beside
    /// month-old siblings under the shared root. It is excluded because it is
    /// FRESH — there is no exclusion set anywhere in the shipped code (the
    /// planned inode-exclusion mechanism was inert and was removed, epic D9).
    func testLiveSessionStyleFreshSiblingIsExcludedByTheAgeGate() async throws {
        try makeStaleCandidate("claude-501-old", under: sharedRootURL)
        let live = try mkdir(
            sharedRootURL.appendingPathComponent("claude-501-live")
        )
        try writeFile(live.appendingPathComponent("session.log"), bytes: 8_192)
        try backdate(live, to: freshDate)

        let outcome = await scan(makeScanner(roots: [sharedRoot()]))
        XCTAssertEqual(outcome.items.map(\.displayName), ["claude-501-old"])
    }

    // MARK: - R8: `.deletionTarget` sizing and the between-stages window

    func testCandidatesAreSizedWithDeletionTargetMode() async throws {
        try makeStaleCandidate("old-scratch", under: sharedRootURL)
        let spy = SizingSpy()

        _ = await scan(makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        ))

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.mode, .deletionTarget,
                       "`.scanRoot` fully resolves the leaf before dispatch — "
                        + "a swapped entry would enumerate its target")
    }

    /// Stages the directory→symlink swap in the window BETWEEN the pre-filter
    /// verdict and the `measure()` call, and proves THAT window is closed: the
    /// swapped entry dispatches as a symlink (0 bytes, never walked), nothing
    /// outside the root is enumerated, and the entry is not listed.
    ///
    /// This says nothing about the residual windows inside the substrate (epic
    /// D10) — those are accepted and documented, not closed.
    func testSwapStagedBetweenPrefilterAndSizingIsNotFollowed() async throws {
        let entry = try makeStaleCandidate("swappable", under: sharedRootURL)
        let external = try mkdir(base.appendingPathComponent("external"))
        try writeFile(
            external.appendingPathComponent("secret.bin"), bytes: 64_000
        )
        try backdate(external, to: oldDate)

        let provider = ProbeRecordingProvider()
        let spy = SizingSpy(provider: provider)
        spy.beforeMeasure = { [fm] url in
            try? fm.removeItem(at: url)
            try? fm.createSymbolicLink(at: url, withDestinationURL: external)
        }

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()], provider: provider,
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        ))

        XCTAssertTrue(outcome.items.isEmpty,
                      "the swapped entry sizes 0 and fails the floor")
        XCTAssertFalse(
            provider.probedPaths.contains { $0.hasPrefix(external.path + "/") },
            "nothing inside the swap target was enumerated"
        )
        XCTAssertNotNil(
            try? fm.attributesOfItem(
                atPath: external.appendingPathComponent("secret.bin").path
            ),
            "the swap target is untouched"
        )
        _ = entry
    }

    // MARK: - R6: stage order + the cooperative lock probe

    func testLockedCandidateIsNeverSized() async throws {
        try makeStaleCandidate("busy", under: sharedRootURL)
        let spy = SizingSpy()

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            lockProbe: { _ in .inUse },
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        ))

        XCTAssertTrue(spy.calls.isEmpty,
                      "the probe runs AFTER the pre-filter and BEFORE sizing — "
                        + "an in-use candidate is never traversed or sized")
        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty, "in use is not a denial")
    }

    /// EWOULDBLOCK from a lock the TEST PROCESS really holds (flock locks
    /// belong to the open file description, so a second `open` in this same
    /// process genuinely conflicts).
    func testRealHeldFlockSkipsCandidateAsInUse() async throws {
        let entry = try makeStaleCandidate("locked", under: sharedRootURL)
        let descriptor = open(entry.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        try XCTSkipIf(descriptor < 0, "could not open the fixture candidate")
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        try XCTSkipIf(flock(descriptor, LOCK_EX | LOCK_NB) != 0,
                      "the platform refused an advisory lock on a directory")

        let outcome = await scan(makeScanner(roots: [sharedRoot()]))
        XCTAssertTrue(outcome.items.isEmpty, "an flock holder means in use")
        XCTAssertTrue(outcome.errors.isEmpty)
    }

    /// THE ACCEPTED RESIDUAL BEHIND THE README'S WORDING (r7, codex C3) —
    /// a CHARACTERISATION cell, not an endorsement.
    ///
    /// README.md's temp bullet used to promise "aged by their newest content
    /// so anything in use stays put". The in-use probe cannot establish that:
    /// it takes one `flock(LOCK_EX|LOCK_NB)` on the CANDIDATE INODE, so a
    /// process that merely holds a descendant file OPEN — an mmap'd dataset,
    /// a binary executing out of an unpacked bundle, an idle sqlite handle —
    /// is invisible, and so is an advisory lock one level down. The scanner's
    /// own source says exactly this
    /// (`EphemeralTempScanner.cooperativeLockProbe`'s "Scope, honestly"
    /// note); the README now says it too.
    ///
    /// If this cell ever goes RED because open-file detection was added, the
    /// README and CHANGELOG sentences it quotes must be re-read in the SAME
    /// change — that is what it is here for.
    func testADescendantHeldOpenForReadingIsStillListedAndStillDeletable() async throws {
        let reading = try makeStaleCandidate("reader-held", under: sharedRootURL)
        let locked = try makeStaleCandidate("descendant-locked", under: sharedRootURL)

        // (1) A descendant held open for ordinary reading.
        let payload = reading.appendingPathComponent("payload.bin")
        let readerFD = open(payload.path, O_RDONLY | O_CLOEXEC)
        try XCTSkipIf(readerFD < 0, "could not open the fixture payload")
        defer { close(readerFD) }
        var byte: UInt8 = 0
        XCTAssertEqual(read(readerFD, &byte, 1), 1, "the fd is genuinely live")

        // (2) A real advisory lock on a DESCENDANT, not on the candidate.
        let innerFD = open(
            locked.appendingPathComponent("payload.bin").path,
            O_RDONLY | O_CLOEXEC
        )
        try XCTSkipIf(innerFD < 0, "could not open the fixture payload")
        defer { flock(innerFD, LOCK_UN); close(innerFD) }
        try XCTSkipIf(flock(innerFD, LOCK_EX | LOCK_NB) != 0,
                      "the platform refused an advisory lock on the file")

        // PRODUCTION lock probe and PRODUCTION lister — no double.
        XCTAssertEqual(
            EphemeralTempScanner.cooperativeLockProbe(canonical(reading)),
            .available,
            "the probe cannot see a descendant held open for reading"
        )
        XCTAssertEqual(
            EphemeralTempScanner.cooperativeLockProbe(canonical(locked)),
            .available,
            "the probe cannot see an advisory lock one level down"
        )

        let scanner = makeScanner(roots: [sharedRoot()])
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(
            scanned["reader-held"],
            "the README says age is the protection — a week-idle workspace "
                + "IS listed even while something reads from it"
        )
        XCTAssertNotNil(scanned["descendant-locked"])
        XCTAssertEqual(item.isStale, true,
                       "and it enters the one-click Select Stale set")

        // Delete time refuses nothing either: the re-check re-establishes
        // age, identity and the top-level lock, none of which a reader moves.
        let verdict = try XCTUnwrap(scanner.preDeleteRevalidator)
            .revalidate(item: item, authorization: nil)
        guard case .allow = verdict else {
            return XCTFail(
                "the delete-time re-check refused a merely-read entry — "
                    + "if that is now the contract, README.md's \"it cannot "
                    + "see a program that merely holds a file inside it open "
                    + "for reading\" is out of date"
            )
        }
    }

    /// Set an mtime WITHOUT following a symlink — the only way to age a
    /// symlink's own timestamp (`FileManager.setAttributes` and `utimes(2)`
    /// both follow, and a dangling link makes them fail outright).
    private func setDateNoFollow(_ url: URL, _ date: Date) throws {
        let seconds = time_t(date.timeIntervalSince1970)
        var times = [
            timespec(tv_sec: seconds, tv_nsec: 0),
            timespec(tv_sec: seconds, tv_nsec: 0),
        ]
        let result = utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW)
        XCTAssertEqual(result, 0, "utimensat(\(url.path)): "
            + String(cString: strerror(errno)))
    }

    /// THE SECOND HALF OF THE SAME RESIDUAL (r9, D2) — a CHARACTERISATION
    /// cell, not an endorsement.
    ///
    /// The sibling cell below measures nested DIRECTORY mtimes. This one
    /// measures the other non-input: a nested node that is neither a
    /// directory nor a regular file. `walkForFreshContent`
    /// (`EphemeralTempScanner.swift:1579-1583`) and `freshContentBelow`
    /// (`:3023-3026`) both `continue` past `.symlink` and `.other` without
    /// dating them, so a FIFO, socket or symlink nested below an entry has
    /// no effect on staleness however fresh its OWN timestamp is — at scan
    /// time or at delete time.
    ///
    /// Here the entry's own mtime, its `data/` subdirectory and every regular
    /// file below it are 30 days old, and ONLY a nested FIFO and a nested
    /// symlink carry fresh timestamps. If this ever goes RED because those
    /// kinds became inputs, the README, CHANGELOG and docs/v1 staleness
    /// sentences must be re-read in the SAME change.
    ///
    /// The shipped sentences also name SOCKETS, which are not staged here: a
    /// bound `AF_UNIX` socket needs a path within `sun_path`'s 104 bytes and
    /// this fixture's nested path is ~147. The FIFO covers them at the level
    /// the decision is made — `probeKind` maps every non-regular,
    /// non-directory, non-symlink object to the SAME `.other` value through
    /// one `default` arm (`FileSystemIdentityProvider.swift:292-296`), and
    /// the assertion below pins the FIFO to it, so both walks see one kind
    /// for both objects and have no arm that could tell them apart.
    func testNestedFIFOAndSymlinkTimestampsDecideNothingAtScanOrDeleteTime()
        async throws
    {
        let entry = try mkdir(sharedRootURL.appendingPathComponent("nested-nondir"))
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let data = try mkdir(entry.appendingPathComponent("data"))
        try writeFile(data.appendingPathComponent("inner.bin"))
        let fifo = data.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0,
                       "mkfifo: \(String(cString: strerror(errno)))")
        let link = data.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL:
            data.appendingPathComponent("missing-target"))

        // Age everything that IS an input — children first, directories last,
        // because writing a child bumps its parent.
        try setDate(data.appendingPathComponent("inner.bin"), oldDate)
        try setDate(entry.appendingPathComponent("payload.bin"), oldDate)
        try setDate(data, oldDate)
        try setDate(entry, oldDate)
        // …and leave ONLY the two non-inputs fresh.
        try setDateNoFollow(fifo, freshDate)
        try setDateNoFollow(link, freshDate)

        // The FIFO stands for every socket/device/FIFO: one `.other` value,
        // one `default` arm, no way for either walk to tell them apart.
        let provider = FileSystemIdentityProvider()
        XCTAssertEqual(provider.probeKind(of: fifo), .kind(.other))
        XCTAssertEqual(provider.probeKind(of: link), .kind(.symlink))

        let scanner = makeScanner(roots: [sharedRoot()])
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)
        let listed = itemsByName(outcome)
        XCTAssertEqual(
            listed.keys.sorted(), ["nested-nondir"],
            "a fresh nested FIFO and a fresh nested symlink do not keep an "
                + "entry off the list"
        )
        let item = try XCTUnwrap(listed["nested-nondir"])
        XCTAssertEqual(item.isStale, true)

        // DELETE TIME — two MORE fresh non-inputs appear after the scan, and
        // the re-check still allows the deletion.
        let second = data.appendingPathComponent("pipe2")
        XCTAssertEqual(mkfifo(second.path, 0o600), 0,
                       "mkfifo: \(String(cString: strerror(errno)))")
        let secondLink = data.appendingPathComponent("link2")
        try fm.createSymbolicLink(at: secondLink, withDestinationURL:
            data.appendingPathComponent("missing-target"))
        try setDateNoFollow(second, freshDate)
        try setDateNoFollow(secondLink, freshDate)

        let verdict = try XCTUnwrap(scanner.preDeleteRevalidator)
            .revalidate(item: item, authorization: nil)
        guard case .allow = verdict else {
            return XCTFail(
                "delete time refused an entry whose only post-scan change was "
                    + "a nested FIFO and a nested symlink — if that is now the "
                    + "contract, the README, CHANGELOG and docs/v1 staleness "
                    + "sentences are out of date: \(verdict)"
            )
        }
    }

    /// THE RESIDUAL BEHIND THE README'S STALENESS WORDING (r8, D3/D4) — a
    /// CHARACTERISATION cell, not an endorsement.
    ///
    /// README.md used to promise that an entry is listed "only when neither it
    /// nor anything inside it has been written for 7 days", and that at delete
    /// time "an entry that has been written into since the scan is refused".
    /// Neither holds. The staleness inputs are the entry's OWN mtime plus the
    /// mtimes of REGULAR FILES below it: `walkForFreshContent` dates only
    /// `.kind(.regularFile)` children, and `directoryStaleness`'s truth table
    /// says intermediate DIRECTORY mtimes are deliberately not inputs.
    /// `freshContentBelow` is the descriptor-relative twin of the same rule,
    /// so delete time answers identically.
    ///
    /// WHAT THIS CELL DOES **NOT** SAY (PR #459 codex r10, D1). Until this
    /// round the paragraph here went on to generalise from a bare `utimes`
    /// on `data/` to a whole CLASS of operations — "creating a subdirectory,
    /// a socket/FIFO or a symlink inside one, or unlinking a file from one,
    /// is therefore invisible on both sides" — and the README, the CHANGELOG
    /// and docs/v1 all carried that sentence. Two of the five were FALSE, and
    /// the suite stayed green for four rounds because the falsification was
    /// applied per-CELL rather than per-OPERATION: this cell exercises
    /// exactly ONE of the five. Unlinking a nested file can take the entry
    /// below the SIZE FLOOR and creating enough subdirectories can push it
    /// past the INSPECTION BUDGET, and both of those gates delist AND refuse.
    /// The per-operation falsifiers are the four cells under "The five nested
    /// VERBS" below; the docs no longer enumerate operations at all.
    ///
    /// So what this cell measures is the narrow, true thing: a nested
    /// DIRECTORY's own timestamp is not itself a staleness input on either
    /// side. If it ever goes RED because directory mtimes became inputs, the
    /// README, CHANGELOG and docs/v1 staleness sentences must be re-read in
    /// the SAME change — that is what it is here for.
    func testOnlyOwnMtimeAndRegularFilesDecideStalenessAtScanAndDeleteTime()
        async throws
    {
        /// An old entry with an old payload and an old `data/` subdirectory.
        func entry(_ name: String) throws -> URL {
            let url = try mkdir(sharedRootURL.appendingPathComponent(name))
            try writeFile(url.appendingPathComponent("payload.bin"))
            try mkdir(url.appendingPathComponent("data"))
            try writeFile(url.appendingPathComponent("data/inner.bin"))
            try backdate(url, to: oldDate)
            return url
        }

        // Only a NESTED DIRECTORY is fresh — the entry's own mtime and every
        // regular file below it stay old.
        let nestedDirectory = try entry("nested-directory-fresh")
        try setDate(nestedDirectory.appendingPathComponent("data"), freshDate)
        // A nested REGULAR FILE is fresh: an input, so this must not be listed.
        let nestedFile = try entry("nested-file-fresh")
        try setDate(nestedFile.appendingPathComponent("data/inner.bin"), freshDate)
        // The entry's OWN directory changed: also an input.
        let ownDirectory = try entry("own-directory-fresh")
        try setDate(ownDirectory, freshDate)
        // Untouched — the delete-time control.
        let control = try entry("control")

        let scanner = makeScanner(roots: [sharedRoot()])
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)
        let listed = itemsByName(outcome)

        XCTAssertEqual(
            listed.keys.sorted(), ["control", "nested-directory-fresh"],
            "a fresh NESTED DIRECTORY does not keep an entry off the list, "
                + "while a fresh regular file and a fresh own mtime both do"
        )
        let nested = try XCTUnwrap(listed["nested-directory-fresh"])
        XCTAssertEqual(nested.isStale, true)
        XCTAssertTrue(
            nested.evidence.contains("newest content is 30 days old"),
            "the age shown is the newest REGULAR FILE's, not the newest "
                + "directory's: \(nested.evidence)"
        )

        // DELETE TIME — the same rule, from a held descriptor.
        let revalidator = try XCTUnwrap(scanner.preDeleteRevalidator)

        // A post-scan write that only bumps a nested DIRECTORY is allowed
        // through: this is the D4 residual, stated in the README rather than
        // papered over.
        try setDate(nestedDirectory.appendingPathComponent("data"), freshDate)
        guard case .allow = revalidator.revalidate(item: nested, authorization: nil)
        else {
            return XCTFail(
                "delete time refused a nested-directory-only change — if that "
                    + "is now the contract, the README, CHANGELOG and "
                    + "docs/v1 staleness sentences are out of date"
            )
        }

        // A post-scan fresh REGULAR FILE anywhere inside IS refused.
        let controlItem = try XCTUnwrap(listed["control"])
        try setDate(control.appendingPathComponent("data/inner.bin"), freshDate)
        guard case .refuse = revalidator.revalidate(
            item: controlItem, authorization: nil
        ) else {
            return XCTFail("a fresh regular file inside must be refused")
        }
    }

    // MARK: - The five nested VERBS, one falsifier each (r10, D1)

    /// The five operations the README used to name as a HARMLESS CLASS —
    /// "creating a subdirectory, or a socket, FIFO or symlink inside one, or
    /// unlinking a nested file, bumps only a directory mtime, so it neither
    /// keeps an entry off the list nor refuses it at delete time".
    ///
    /// That universal was false for two of the five, and the suite stayed
    /// green because falsification was applied per-CELL rather than
    /// per-VERB: the cell above exercises exactly ONE of them (a bare
    /// `utimes` on `data/`). These cells run all five, on both sides, at
    /// both scales — and the docs no longer enumerate verbs at all, because
    /// the property that survives measurement is about the TIMESTAMP, not
    /// about the operations that move it.
    private enum NestedVerb: String, CaseIterable {
        case makeSubdirectory = "verb-mkdir"
        case makeSocket = "verb-socket"
        case makeFIFO = "verb-fifo"
        case makeSymlink = "verb-symlink"
        case unlinkRegularFile = "verb-unlink"
    }

    /// An entry whose payload sits at the top level AND inside `data/`, so a
    /// verb applied inside `data/` never touches the entry's own mtime and
    /// never takes the tree below the (4 KB) floor.
    private func verbFixture(_ name: String) throws -> URL {
        let url = try mkdir(sharedRootURL.appendingPathComponent(name))
        try writeFile(url.appendingPathComponent("payload.bin"))
        try mkdir(url.appendingPathComponent("data"))
        try writeFile(url.appendingPathComponent("data/inner.bin"))
        try writeFile(url.appendingPathComponent("data/spare.bin"))
        try backdate(url, to: oldDate)
        return url
    }

    /// A REAL bound `AF_UNIX` socket at `url`. `sun_path` is 104 bytes and
    /// the fixture base is a long `/var/folders/…` path, so it is bound at a
    /// short `/private/tmp` name and renamed into place — the same pattern
    /// the swap-window socket cell below uses.
    private func bindSocket(at url: URL) throws {
        let shortPath = "/private/tmp/co-r10-"
            + UUID().uuidString.prefix(8).lowercased() + ".sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw XCTSkip("socket(2): \(String(cString: strerror(errno)))")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(shortPath.utf8)
        XCTAssertLessThan(bytes.count, 104)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bound == 0 else {
            close(fd)
            unlink(shortPath)
            throw XCTSkip("bind(2): \(String(cString: strerror(errno)))")
        }
        guard rename(shortPath, url.path) == 0 else {
            close(fd)
            unlink(shortPath)
            throw XCTSkip("rename(2): \(String(cString: strerror(errno)))")
        }
        addTeardownBlock { close(fd) }
    }

    /// Run `verb` INSIDE the entry's `data/` subdirectory. Every arm bumps
    /// `data/`'s own mtime and nothing else the staleness rule reads.
    private func apply(_ verb: NestedVerb, inside entry: URL) throws {
        let data = entry.appendingPathComponent("data")
        switch verb {
        case .makeSubdirectory:
            try mkdir(data.appendingPathComponent("sub"))
        case .makeSocket:
            try bindSocket(at: data.appendingPathComponent("s.sock"))
        case .makeFIFO:
            let fifo = data.appendingPathComponent("f.fifo")
            XCTAssertEqual(
                mkfifo(fifo.path, 0o600), 0,
                "mkfifo: \(String(cString: strerror(errno)))"
            )
        case .makeSymlink:
            try fm.createSymbolicLink(
                at: data.appendingPathComponent("l.link"),
                withDestinationURL: data.appendingPathComponent("inner.bin")
            )
        case .unlinkRegularFile:
            let spare = data.appendingPathComponent("spare.bin")
            XCTAssertEqual(
                unlink(spare.path), 0,
                "unlink: \(String(cString: strerror(errno)))"
            )
        }
    }

    /// The entry's OWN mtime, by no-follow `lstat` — what every one of these
    /// cells pins before and after the verb, so a green result means the
    /// NESTED directory's timestamp is the only thing that moved.
    private func ownMtime(_ url: URL) throws -> String {
        var status = stat()
        XCTAssertEqual(
            lstat(url.path, &status), 0,
            "lstat \(url.path): \(String(cString: strerror(errno)))"
        )
        return "\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)"
    }

    /// FALSIFIER 1/5-per-verb, SCAN side, SINGLE scale. All five verbs, each
    /// applied once to a distinct entry before the scan, with the entry's own
    /// mtime proven unmoved by `lstat` on both sides of the verb. Every entry
    /// stays on the list: at this scale the nested directory's timestamp
    /// really is not an input.
    func testEverySingleNestedVerbLeavesTheEntryOnTheList() async throws {
        for verb in NestedVerb.allCases {
            let entry = try verbFixture(verb.rawValue)
            let before = try ownMtime(entry)
            try apply(verb, inside: entry)
            XCTAssertEqual(
                try ownMtime(entry), before,
                "\(verb.rawValue): the verb must move ONLY the nested "
                    + "directory's mtime, or this cell measures the wrong thing"
            )
        }

        let scanner = makeScanner(roots: [sharedRoot()])
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertEqual(
            itemsByName(outcome).keys.sorted(),
            NestedVerb.allCases.map(\.rawValue).sorted(),
            "at single scale every one of the five verbs leaves the entry "
                + "listed — the nested directory's own timestamp is not a "
                + "staleness input"
        )
        XCTAssertTrue(outcome.errors.isEmpty, "and none of them is a denial")
    }

    /// FALSIFIER 1/5-per-verb, DELETE side, SINGLE scale. The same five verbs
    /// applied AFTER the scan, through the production revalidator.
    func testEverySingleNestedVerbStillPassesTheDeleteTimeRecheck()
        async throws
    {
        for verb in NestedVerb.allCases {
            _ = try verbFixture(verb.rawValue)
        }
        let scanner = makeScanner(roots: [sharedRoot()])
        let outcome = await scan(scanner)
        let listed = itemsByName(outcome)
        XCTAssertEqual(listed.count, NestedVerb.allCases.count)
        let revalidator = try XCTUnwrap(scanner.preDeleteRevalidator)

        for verb in NestedVerb.allCases {
            let entry = sharedRootURL.appendingPathComponent(verb.rawValue)
            let before = try ownMtime(entry)
            try apply(verb, inside: entry)
            XCTAssertEqual(try ownMtime(entry), before, verb.rawValue)

            let item = try XCTUnwrap(listed[verb.rawValue])
            guard case .allow = revalidator.revalidate(
                item: item, authorization: nil
            ) else {
                return XCTFail(
                    "\(verb.rawValue): refused at delete time. If that is now "
                        + "the contract, the README, CHANGELOG and docs/v1 "
                        + "staleness sentences must be re-read in this change"
                )
            }
        }
    }

    /// FALSIFIER for the SIZE-FLOOR clause, both sides. Unlinking a nested
    /// regular file bumps only `data/`'s mtime — and takes the entry below
    /// the floor, which keeps it OFF the list and REFUSES it at delete time.
    /// This is one of the two verbs the retired universal got wrong.
    func testUnlinkingANestedFileBelowTheFloorDelistsAndRefuses()
        async throws
    {
        let floor = EphemeralTempSweepConfig.Thresholds(
            sizeFloorBytes: 1_048_576, staleAge: 7 * 86_400
        )
        /// 4 MB of nested payload, 8 KB at the top level: unlinking the
        /// nested file drops the tree far below a 1 MB floor.
        func entry(_ name: String) throws -> URL {
            let url = try mkdir(sharedRootURL.appendingPathComponent(name))
            try writeFile(url.appendingPathComponent("payload.bin"))
            try mkdir(url.appendingPathComponent("data"))
            try writeFile(
                url.appendingPathComponent("data/big.bin"), bytes: 4_194_304
            )
            try backdate(url, to: oldDate)
            return url
        }

        // SCAN side: the unlink happens BEFORE the scan.
        let delisted = try entry("delisted-by-unlink")
        let beforeDelist = try ownMtime(delisted)
        XCTAssertEqual(
            unlink(delisted.appendingPathComponent("data/big.bin").path), 0
        )
        XCTAssertEqual(
            try ownMtime(delisted), beforeDelist,
            "only data/'s mtime moved"
        )
        // DELETE side: this one is unlinked after the scan.
        let refused = try entry("refused-by-unlink")

        let scanner = makeScanner(roots: [sharedRoot()], thresholds: floor)
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertEqual(
            itemsByName(outcome).keys.sorted(), ["refused-by-unlink"],
            "unlinking a nested regular file DOES keep an entry off the list "
                + "— via the size floor, not via any timestamp"
        )
        XCTAssertTrue(
            outcome.errors.isEmpty, "and it is delisted silently, not denied"
        )

        let item = try XCTUnwrap(itemsByName(outcome)["refused-by-unlink"])
        let revalidator = try XCTUnwrap(scanner.preDeleteRevalidator)
        let beforeRefuse = try ownMtime(refused)
        XCTAssertEqual(
            unlink(refused.appendingPathComponent("data/big.bin").path), 0
        )
        XCTAssertEqual(
            try ownMtime(refused), beforeRefuse, "only data/'s mtime moved"
        )
        guard case .refuse(let reason, _, _) = revalidator.revalidate(
            item: item, authorization: nil
        ) else {
            return XCTFail("a below-floor shrink must be refused")
        }
        XCTAssertTrue(
            reason.contains("shrunk below the size threshold"),
            "the refusal must name the floor, not a timestamp: \(reason)"
        )
    }

    /// FALSIFIER for the INSPECTION-BUDGET clause, both sides. Creating
    /// subdirectories inside `data/` bumps only `data/`'s mtime — and once
    /// there are more of them than the walk's budget, the entry is kept OFF
    /// the list (silently, `walkForFreshContent`'s `.budget` arm) and REFUSED
    /// at delete time (`freshContentBelow`'s `.budget` arm). This is the
    /// second verb the retired universal got wrong.
    ///
    /// The budget is INJECTED rather than staged at its 20,000 default: the
    /// arm under test is the same one either way, and 20,010 real
    /// subdirectories cost the suite minutes for no extra proof. It IS the
    /// shipped behaviour, not only the injected one — r9's verifier staged
    /// 20,010 real subdirectories against the untouched
    /// `defaultPrefilterEntryLimit` and got this same refusal, quoting "more
    /// entries than the inspection budget".
    func testCreatingEnoughNestedSubdirectoriesDelistsAndRefuses()
        async throws
    {
        func entry(_ name: String) throws -> URL {
            let url = try mkdir(sharedRootURL.appendingPathComponent(name))
            try writeFile(url.appendingPathComponent("payload.bin"))
            try mkdir(url.appendingPathComponent("data"))
            try writeFile(url.appendingPathComponent("data/inner.bin"))
            try backdate(url, to: oldDate)
            return url
        }
        func spam(_ entry: URL, count: Int) throws {
            let data = entry.appendingPathComponent("data")
            for index in 0..<count {
                try mkdir(data.appendingPathComponent("sub-\(index)"))
            }
        }

        // SCAN side: already over budget when the scan runs.
        let delisted = try entry("delisted-by-mkdir")
        let beforeDelist = try ownMtime(delisted)
        try spam(delisted, count: 20)
        try backdate(delisted.appendingPathComponent("data"), to: oldDate)
        try setDate(delisted, oldDate)
        XCTAssertEqual(
            try ownMtime(delisted), beforeDelist,
            "every timestamp is re-pinned old: only the entry COUNT differs"
        )
        // DELETE side: within budget at scan time, spammed afterwards.
        let refused = try entry("refused-by-mkdir")

        let scanner = makeScanner(
            roots: [sharedRoot()], prefilterEntryLimit: 8
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertEqual(
            itemsByName(outcome).keys.sorted(), ["refused-by-mkdir"],
            "creating subdirectories DOES keep an entry off the list — via "
                + "the inspection budget, not via any timestamp"
        )
        XCTAssertTrue(
            outcome.errors.isEmpty,
            "the budget arm delists SILENTLY (r5, codex C5)"
        )

        let item = try XCTUnwrap(itemsByName(outcome)["refused-by-mkdir"])
        let revalidator = try XCTUnwrap(scanner.preDeleteRevalidator)
        let beforeRefuse = try ownMtime(refused)
        try spam(refused, count: 20)
        XCTAssertEqual(
            try ownMtime(refused), beforeRefuse, "only data/'s mtime moved"
        )
        guard case .refuse(let reason, _, _) = revalidator.revalidate(
            item: item, authorization: nil
        ) else {
            return XCTFail("an over-budget re-inspection must be refused")
        }
        XCTAssertTrue(
            reason.contains("more entries than the inspection budget"),
            "the refusal must name the budget, not a timestamp: \(reason)"
        )
    }

    func testUnlockedCandidateProceedsThroughTheProductionProbe() async throws {
        try makeStaleCandidate("free", under: sharedRootURL)
        // No lock held; the PRODUCTION probe takes and drops one.
        let outcome = await scan(makeScanner(roots: [sharedRoot()]))
        XCTAssertEqual(outcome.items.map(\.displayName), ["free"])
    }

    func testOpenEACCESIsPermissionDeniedAccountingNotInUse() async throws {
        try makeStaleCandidate("denied-open", under: sharedRootURL)

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()], lockProbe: { _ in .failed(errno: EACCES) }
        ))

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertEqual(outcome.errors.first?.kind, .permissionDenied)
    }

    func testOpenEPERMIsNeutralUnreadableAccountingNotInUse() async throws {
        try makeStaleCandidate("eperm-open", under: sharedRootURL)

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()], lockProbe: { _ in .failed(errno: EPERM) }
        ))

        XCTAssertTrue(outcome.items.isEmpty)
        let issue = try XCTUnwrap(outcome.errors.first)
        XCTAssertEqual(issue.kind, .unreadable,
                       "a bare EPERM establishes neither a privacy denial nor "
                        + "a filesystem one")
        XCTAssertNotEqual(issue.kind, .tccDenied)
        XCTAssertNotEqual(issue.kind, .permissionDenied)
    }

    func testOpenENOENTIsASilentRaceSkip() async throws {
        try makeStaleCandidate("vanishing", under: sharedRootURL)

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()], lockProbe: { _ in .vanished }
        ))

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty,
                      "a vanished entry is a race, not a denial")
    }

    func testSpecialFilesAndSymlinksAtRootAreSkippedSilently() async throws {
        try makeStaleCandidate("real-entry", under: sharedRootURL)

        let fifo = sharedRootURL.appendingPathComponent("live.sock")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try setDate(fifo, oldDate)

        let target = try makeStaleCandidate("link-target", under: base)
        let link = sharedRootURL.appendingPathComponent("dangling-or-not")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let spy = SizingSpy()
        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        ))

        XCTAssertEqual(outcome.items.map(\.displayName), ["real-entry"])
        XCTAssertEqual(spy.calls.map(\.url.lastPathComponent), ["real-entry"],
                       "neither the FIFO nor the symlink is ever sized")
        XCTAssertTrue(outcome.errors.isEmpty, "both are skipped SILENTLY")
    }

    /// F1 (PR #459 review r3): a FIFO planted at a candidate's name inside the
    /// scan's own swap window must not wedge `scan`.
    ///
    /// The probe cannot carry `O_DIRECTORY` (regular-file candidates must open
    /// too), so without `O_NONBLOCK` its `open` is the FIFO driver's, which
    /// waits for a writer FOREVER. Measured: the un-flagged open did not
    /// return in 3s, and a real `scan` driven onto one never returned at all.
    /// There is no timeout downstream — the scan body runs on a cooperative
    /// pool thread and the session's task group never drains — so this is
    /// asserted through the WHOLE production scan, not against the probe
    /// function, and with the DEFAULT `lockProbe`: r2 fixed the delete-time
    /// twin with a flag-level test and this sibling call site was missed.
    ///
    /// The window is opened by a real `rename` + `mkfifo` run from the
    /// pre-filter walk's metadata read, which is after the root-level
    /// `probeKind` filter that normally skips special files and before the
    /// lock probe. `zz-control` proves the scan did not merely bail out early.
    ///
    /// A bounded wait is the assertion: if the guard is removed the detached
    /// task never completes, so the cell reddens on the timeout rather than on
    /// a value — which is itself the proof that the open really blocks.
    ///
    /// Wall-clock stability, MEASURED (r4 — fc006ab's body claimed the PR
    /// added only ONE wall-clock-timeout cell and measured only that one;
    /// this cell and the socket cell below were the other two, unmeasured
    /// at that claim): 30/30 runs green with a concurrent full `swift test`
    /// suite running throughout, alongside the other four timeout cells.
    func testAFIFOPlantedInTheSwapWindowNeitherWedgesTheScanNorIsListed()
        throws {
        let root = canonical(sharedRootURL)
        try makeStaleCandidate("swap-me", under: sharedRootURL)
        try makeStaleCandidate("zz-control", under: sharedRootURL)
        let candidate = root.appendingPathComponent("swap-me")
        let away = root.appendingPathComponent("swap-me.away")

        let provider = MidWalkSideEffectProvider()
        provider.trigger = "payload.bin"
        provider.effect = {
            XCTAssertEqual(rename(candidate.path, away.path), 0,
                           "the fixture must free the candidate's name")
            XCTAssertEqual(mkfifo(candidate.path, 0o600), 0,
                           "the fixture must actually stage a named pipe")
        }
        // Releases a reader left blocked by a REMOVED guard, so the mutation
        // run reddens this cell without stranding a thread for the whole
        // suite. With the guard present there is no reader and this returns
        // ENXIO immediately.
        defer {
            let writer = open(candidate.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }

        let spy = SizingSpy()
        let scanner = makeScanner(
            roots: [sharedRoot()], provider: provider,
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        )
        let box = OutcomeBox()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await scanner.scan(
                context: ScanContext(trigger: .userInitiated)
            )
            finished.signal()
        }

        XCTAssertEqual(
            finished.wait(timeout: .now() + 5), .success,
            "the scan must RETURN with a FIFO standing at a candidate's name "
                + "— a blocking open strands the scan session, and with it "
                + "every later scan and clean, for the life of the process"
        )
        let outcome = try XCTUnwrap(box.value)
        XCTAssertEqual(
            FileSystemIdentityProvider().kind(of: candidate), .other,
            "the fixture must still have a special file at the scanned name"
        )
        // The KIND GATE's observable. `flock` on a FIFO descriptor answers
        // ENOTSUP (45), not EWOULDBLOCK (35), so without the gate the probe
        // reports `.available` and the FIFO is carried into stage-2 SIZING —
        // which is exactly what `testSpecialFilesAndSymlinksAtRootAreSkipped\
        // Silently` forbids for a special file that arrives before the scan
        // rather than during it. No row is emitted either way (a FIFO measures
        // 0 bytes, below any positive floor), so the sizing call is the fact
        // that separates the two.
        XCTAssertEqual(
            spy.calls.map(\.url.lastPathComponent), ["zz-control"],
            "a special file is never sized, whenever it arrives"
        )
        XCTAssertEqual(
            outcome.items.map(\.displayName), ["zz-control"],
            "the FIFO is not a kind this scanner lists, and the scan carries "
                + "on to the entries after it"
        )
        XCTAssertTrue(outcome.errors.isEmpty,
                      "a special file arriving mid-scan is the same silent "
                        + "skip the root-level kind filter already applies")
    }

    /// The socket half of the same window, pinned at its MEASURED behaviour.
    ///
    /// A bound, listening AF_UNIX socket does NOT block this open and does not
    /// reach the kind gate at all: on this platform `open` fails EOPNOTSUPP
    /// (102, "Operation not supported on socket") immediately. That is a bare
    /// errno on a raw-errno probe, so it lands in the neutral `.unreadable`
    /// denial accounting — no item, one visible classified issue. (PR #459
    /// review r3 predicted ENOENT and a silent skip for this case from a
    /// standalone C probe; driven through the real scan it is EOPNOTSUPP and a
    /// denial. The cell records what the product does.)
    ///
    /// So this cell does not evidence `O_NONBLOCK` — the FIFO cell above does.
    /// It exists so the second special kind that can arrive in this window has
    /// a pinned disposition instead of an assumed one. Device nodes take the
    /// same path but cannot be staged without root, so they stay untested.
    ///
    /// Wall-clock stability, MEASURED (r4, same protocol as the FIFO cell
    /// above): 30/30 runs green under concurrent full-suite load.
    func testASocketPlantedInTheSwapWindowIsARefusalNotAnItem() throws {
        let root = canonical(sharedRootURL)
        try makeStaleCandidate("swap-me", under: sharedRootURL)
        try makeStaleCandidate("zz-control", under: sharedRootURL)
        let candidate = root.appendingPathComponent("swap-me")
        let away = root.appendingPathComponent("swap-me.away")
        // `sun_path` is 104 bytes and the fixture base is a long
        // `/var/folders/…` path, so the socket is bound at a SHORT name and
        // renamed onto the candidate — the object planted at the scanned name
        // is a real bound, listening AF_UNIX socket either way.
        let shortPath = "/private/tmp/co-r3-"
            + UUID().uuidString.prefix(8).lowercased() + ".sock"
        defer { unlink(shortPath) }

        let provider = MidWalkSideEffectProvider()
        provider.trigger = "payload.bin"
        var listener: Int32 = -1
        provider.effect = {
            XCTAssertEqual(rename(candidate.path, away.path), 0)
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(listener, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = Array(shortPath.utf8)
            XCTAssertLessThan(path.count, 104)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.baseAddress!.copyMemory(from: path, byteCount: path.count)
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(
                    to: sockaddr.self, capacity: 1
                ) {
                    Darwin.bind(
                        listener, $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            XCTAssertEqual(bound, 0, "the fixture must bind a real socket")
            XCTAssertEqual(listen(listener, 1), 0)
            XCTAssertEqual(rename(shortPath, candidate.path), 0,
                           "the socket must end up at the scanned name")
        }
        defer { if listener >= 0 { close(listener) } }

        let scanner = makeScanner(roots: [sharedRoot()], provider: provider)
        let box = OutcomeBox()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await scanner.scan(
                context: ScanContext(trigger: .userInitiated)
            )
            finished.signal()
        }

        XCTAssertEqual(
            finished.wait(timeout: .now() + 5), .success,
            "a bound socket must not stall the open either"
        )
        let outcome = try XCTUnwrap(box.value)
        XCTAssertEqual(
            outcome.items.map(\.displayName), ["zz-control"],
            "a socket is never listed, and the scan carries on past it"
        )
        let issue = try XCTUnwrap(outcome.errors.first)
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertEqual(
            issue.kind, .unreadable,
            "EOPNOTSUPP is a bare errno: it establishes neither a privacy "
                + "denial nor a filesystem one"
        )
        XCTAssertTrue(issue.detail.contains("in-use check"), issue.detail)
    }

    // MARK: - R5: denial classification by operation + provenance

    func testInjectedRawEPERMProbeFailureIsNeutralUnreadable() async throws {
        try makeStaleCandidate("eperm-entry", under: sharedRootURL)
        let provider = FailingKindProbeProvider()
        provider.failingNames["eperm-entry"] = EPERM

        let outcome = await scan(
            makeScanner(roots: [sharedRoot()], provider: provider)
        )

        let issue = try XCTUnwrap(outcome.errors.first)
        XCTAssertEqual(outcome.errors.count, 1, "counted exactly once")
        XCTAssertEqual(issue.kind, .unreadable)
        XCTAssertNotEqual(issue.kind, .tccDenied,
                          "a bare errno carries no provenance")
        XCTAssertNotEqual(issue.kind, .permissionDenied,
                          "stickiness governs unlink/rename, not lstat")
        XCTAssertTrue(outcome.items.isEmpty)
    }

    func testInjectedRawEACCESProbeFailureIsPermissionDenied() async throws {
        try makeStaleCandidate("eacces-entry", under: sharedRootURL)
        let provider = FailingKindProbeProvider()
        provider.failingNames["eacces-entry"] = EACCES

        let outcome = await scan(
            makeScanner(roots: [sharedRoot()], provider: provider)
        )

        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertEqual(outcome.errors.first?.kind, .permissionDenied)
    }

    /// The PROVENANCE-bearing class: a Cocoa 257 wrapping a POSIX EPERM is the
    /// one signal that genuinely indicates TCC, and it must be PRESERVED —
    /// rewriting it would suppress the user's grant remedy.
    func testChainBearingEPERMTraversalErrorPreservesTccDenied() async throws {
        let lister = ListerSpy()
        lister.stubError = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadNoPermission.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain, code: Int(EPERM)
            )]
        )

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            listDirectory: { [lister] url, limit in try lister.list(url, limit) }
        ))

        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertEqual(outcome.errors.first?.kind, .tccDenied)
        XCTAssertTrue(outcome.items.isEmpty)
    }

    func testChainBearingEACCESTraversalErrorIsPermissionDenied() async throws {
        let lister = ListerSpy()
        lister.stubError = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadNoPermission.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain, code: Int(EACCES)
            )]
        )

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            listDirectory: { [lister] url, limit in try lister.list(url, limit) }
        ))

        XCTAssertEqual(outcome.errors.first?.kind, .permissionDenied)
    }

    /// A REAL chmod-000 candidate: the pre-filter's `opendir` fails EACCES, so
    /// the entry is skipped, its staleness declared unprovable, and the denial
    /// counted exactly once for the root.
    func testChmod000CandidateIsSkippedAndCountedOnce() async throws {
        try skipUnderRoot()
        let entry = try makeStaleCandidate("locked-tree", under: sharedRootURL)
        try makeStaleCandidate("readable", under: sharedRootURL)
        try chmod000(entry)

        let scanner = makeScanner(roots: [sharedRoot()])
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertEqual(outcome.items.map(\.displayName), ["readable"])
        XCTAssertEqual(outcome.errors.count, 1)
        let issue = try XCTUnwrap(outcome.errors.first)
        XCTAssertEqual(issue.kind, .permissionDenied)
        XCTAssertEqual(issue.url?.path,
                       entryPath("locked-tree", under: sharedRootURL))
        _ = entry
    }

    /// The purely OBSERVABLE ENOENT contract: no item, no denial, no issue —
    /// and no race counter exists to assert.
    func testENOENTOnChildIsSilentlySkipped() async throws {
        try makeStaleCandidate("vanished", under: sharedRootURL)
        try makeStaleCandidate("survivor", under: sharedRootURL)
        let provider = FailingKindProbeProvider()
        provider.absentNames = ["vanished"]

        let outcome = await scan(
            makeScanner(roots: [sharedRoot()], provider: provider)
        )

        XCTAssertEqual(outcome.items.map(\.displayName), ["survivor"])
        XCTAssertTrue(outcome.errors.isEmpty)
    }

    // MARK: - R13: scanner-wide trigger policy

    /// The deferral arm emits NOTHING — items and errors both, including the
    /// `resolutionIssues` an inspecting scan would lead with.
    ///
    /// D5 (PR #459 codex r10): until this round the `resolutionIssues:` half
    /// was VACUOUS. This cell built its scanner without the argument, so the
    /// field was `[]` and `outcome.errors.isEmpty` held no matter what the
    /// deferral arm returned — flipping it to `errors: resolutionIssues` left
    /// the suite green. The list below is non-empty precisely so that flip
    /// goes RED here.
    func testAutomaticTriggerDefersEveryRootEntirely() async throws {
        try makeStaleCandidate("old-scratch", under: sharedRootURL)
        try makeStaleCandidate("other", under: userRootURL)
        let lister = ListerSpy()
        let spy = SizingSpy()
        let dropped = ScanIssue(
            url: sharedRootURL.appendingPathComponent("alias-C"),
            kind: .symlinkRoot,
            detail: "an alias of a root already declared as a real directory"
        )

        let outcome = await scan(
            makeScanner(
                roots: [sharedRoot(), userRoot()],
                resolutionIssues: [dropped],
                listDirectory: { [lister] url, limit in try lister.list(url, limit) },
                candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
            ),
            trigger: .automatic
        )

        XCTAssertTrue(lister.listed.isEmpty, "nothing is enumerated")
        XCTAssertTrue(spy.calls.isEmpty, "nothing is sized")
        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty,
                      "a deferral is not an anomaly — the same silent "
                        + "semantics a skipped protected root has. The "
                        + "resolution issue this scanner HOLDS must not ride "
                        + "a deferred outcome: \(outcome.errors)")
    }

    /// The other side of the same divergence, so a swap of the two arms is
    /// not mistaken for a pass: an INSPECTING scan DOES lead with the same
    /// `resolutionIssues` the deferral arm suppresses.
    func testUserInitiatedLeadsWithTheSameResolutionIssues() async throws {
        let dropped = ScanIssue(
            url: sharedRootURL.appendingPathComponent("alias-C"),
            kind: .symlinkRoot,
            detail: "an alias of a root already declared as a real directory"
        )
        let scanner = makeScanner(
            roots: [sharedRoot()], resolutionIssues: [dropped]
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertEqual(outcome.errors, [dropped],
                       "an inspecting outcome carries the drop verbatim")
    }

    func testUserInitiatedEnumeratesEveryResolvedRoot() async throws {
        try makeStaleCandidate("in-shared", under: sharedRootURL)
        try makeStaleCandidate("in-user", under: userRootURL)
        let lister = ListerSpy()

        let outcome = await scan(makeScanner(
            roots: [sharedRoot(), userRoot()],
            listDirectory: { [lister] url, limit in try lister.list(url, limit) }
        ))

        XCTAssertEqual(
            Set(lister.listed.map(\.path)),
            [canonical(sharedRootURL).path, canonical(userRootURL).path]
        )
        XCTAssertEqual(Set(outcome.items.map(\.displayName)),
                       ["in-shared", "in-user"])
    }

    // MARK: - R14: the sticky-root ownership gate

    func testForeignOwnedCandidateIsSilentlyExcluded() async throws {
        try makeStaleCandidate("foreign", under: sharedRootURL)
        try makeStaleCandidate("mine", under: sharedRootURL)
        let provider = OwnerProbeInjectingProvider()
        provider.probesByName["foreign"] = .owner(geteuid() &+ 1)

        let outcome = await scan(
            makeScanner(roots: [sharedRoot()], provider: provider)
        )

        XCTAssertEqual(outcome.items.map(\.displayName), ["mine"],
                       "another user's entry is undeletable under sticky "
                        + "rules — listing it would claim bytes known false")
        XCTAssertTrue(outcome.errors.isEmpty,
                      "observed foreign ownership is ordinary background "
                        + "noise, not a denial")
    }

    func testOwnUidCandidateProceeds() async throws {
        try makeStaleCandidate("mine", under: sharedRootURL)
        let provider = OwnerProbeInjectingProvider()
        provider.probesByName["mine"] = .owner(geteuid())

        let outcome = await scan(
            makeScanner(roots: [sharedRoot()], provider: provider)
        )

        XCTAssertEqual(outcome.items.map(\.displayName), ["mine"])
    }

    func testAbsentOwnerProbeIsASilentRaceSkip() async throws {
        try makeStaleCandidate("racing", under: sharedRootURL)
        let provider = OwnerProbeInjectingProvider()
        provider.probesByName["racing"] = .absent

        let outcome = await scan(
            makeScanner(roots: [sharedRoot()], provider: provider)
        )

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty)
    }

    func testOwnerProbeEACCESIsVisiblePermissionDenied() async throws {
        try makeStaleCandidate("unowned", under: sharedRootURL)
        let provider = OwnerProbeInjectingProvider()
        provider.probesByName["unowned"] = .failed(errno: EACCES)

        let outcome = await scan(
            makeScanner(roots: [sharedRoot()], provider: provider)
        )

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertEqual(outcome.errors.first?.kind, .permissionDenied)
    }

    func testOwnerProbeEPERMIsVisibleButNeutral() async throws {
        try makeStaleCandidate("unowned", under: sharedRootURL)
        let provider = OwnerProbeInjectingProvider()
        provider.probesByName["unowned"] = .failed(errno: EPERM)

        let outcome = await scan(
            makeScanner(roots: [sharedRoot()], provider: provider)
        )

        let issue = try XCTUnwrap(outcome.errors.first)
        XCTAssertEqual(issue.kind, .unreadable)
        XCTAssertNotEqual(issue.kind, .tccDenied)
        XCTAssertNotEqual(issue.kind, .permissionDenied)
    }

    /// The gate is scoped to the world-writable root by the fn-6.1 DECLARED
    /// writability class: under a 0700 per-user container every entry is the
    /// user's by construction, so no ownership probe governs it.
    func testOwnershipGateIsVacuousUnderThePerUserRoot() async throws {
        try makeStaleCandidate("foreign", under: userRootURL)
        let provider = OwnerProbeInjectingProvider()
        provider.probesByName["foreign"] = .owner(geteuid() &+ 1)

        let outcome = await scan(
            makeScanner(roots: [userRoot()], provider: provider)
        )

        XCTAssertEqual(outcome.items.map(\.displayName), ["foreign"])
    }

    // MARK: - R12: the freshness re-check (precedence over the mapping)

    func testFreshFileLandingAfterThePrefilterSuppressesACleanCandidate() async throws {
        let entry = try makeStaleCandidate("late-fresh", under: sharedRootURL)
        let spy = SizingSpy()
        let freshDate = self.freshDate
        spy.beforeMeasure = { [fm] url in
            let late = url.appendingPathComponent("late.log")
            try? Data(repeating: 0x42, count: 32).write(to: late)
            try? fm.setAttributes(
                [.modificationDate: freshDate], ofItemAtPath: late.path
            )
        }

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        ))

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertTrue(outcome.items.isEmpty,
                      "positive evidence of freshness disqualifies it")
        XCTAssertTrue(outcome.errors.isEmpty)
        _ = entry
    }

    // MARK: - PR #459 review r1: the OWN-MTIME half, re-checked after sizing
    //
    // DISCLOSURE-HONESTY defect, stated exactly: the row asserted a predicate
    // (`isStale: true`, plus the age evidence) whose own-mtime half had not
    // been re-verified since before the sizing walk. Nothing is deleted
    // autonomously — `defaultSelected: false`, `.review` risk, smart-clean
    // excluded — but `isStale` is the key of the section's one-click
    // "Select Stale" bulk selection, so a false one is one click from
    // a deletion.

    /// The exact mirror of the fresh-FILE cell above, with a DIRECTORY landing
    /// instead: `mkdir` bumps the candidate's own mtime and contributes
    /// NOTHING to `newestContentDate` (the sizer merges regular-file mtimes
    /// only), so only a re-read of the entry's own mtime can see it.
    func testOwnMtimeTouchedDuringSizingSuppressesTheCandidate() async throws {
        try makeStaleCandidate("late-touched", under: sharedRootURL)
        let spy = SizingSpy()
        let freshDate = self.freshDate
        spy.beforeMeasure = { url in
            // A directory ONLY — no regular file is written, which is the
            // whole point of the cell: `mkdir` contributes NOTHING to
            // `newestContentDate` while bumping the entry's own mtime.
            try? FileManager.default.createDirectory(
                at: url.appendingPathComponent("late-sub"),
                withIntermediateDirectories: false
            )
            // A real `mkdir` sets the parent's mtime to the WALL CLOCK, which
            // this suite's injected clock is deliberately far ahead of — so
            // the resulting mtime is stated explicitly rather than inherited
            // from a clock the scanner never reads.
            try? FileManager.default.setAttributes(
                [.modificationDate: freshDate], ofItemAtPath: url.path
            )
        }

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        ))

        XCTAssertEqual(spy.calls.count, 1, "the candidate was measured")
        XCTAssertTrue(
            outcome.items.isEmpty,
            "a fresh OWN mtime disqualifies it exactly as a fresh own mtime "
                + "before the pre-filter would have — the verdict may not "
                + "depend on which side of one `lstat` the change landed"
        )
        XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors)")
    }

    /// Symmetry with the pre-filter cell `testFreshOwnMtimeWithAllOldContents…`
    /// asserted directly: identical filesystem state, staged before vs during
    /// sizing, must produce the identical verdict.
    func testOwnMtimeTouchedDuringSizingSurfacesItsSizingDenials() async throws {
        try makeStaleCandidate("late-touched-denied", under: sharedRootURL)
        let spy = SizingSpy()
        let freshDate = self.freshDate
        spy.beforeMeasure = { url in
            try? FileManager.default.createDirectory(
                at: url.appendingPathComponent("late-sub"),
                withIntermediateDirectories: false
            )
            try? FileManager.default.setAttributes(
                [.modificationDate: freshDate], ofItemAtPath: url.path
            )
        }
        spy.stub = { [self] url in
            report(
                exact: 8_192, itemCount: 1,
                denials: [SizeDenial(
                    url: url.appendingPathComponent("inner"),
                    kind: .permission, detail: "permission denied"
                )]
            )
        }

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        ))

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.errors.count, 1,
                       "visibility survives without a lying row")
        let issue = try XCTUnwrap(outcome.errors.first)
        XCTAssertEqual(issue.kind, .permissionDenied)
        XCTAssertTrue(
            issue.detail.contains("modified while it was being measured"),
            "the note names the ACTUAL cause, not 'excluded as fresh': "
                + issue.detail
        )
    }

    /// FAIL CLOSED, matching stage 1's direction: an own mtime that cannot be
    /// re-established after sizing is "not stale, and VISIBLE".
    func testPostSizingOwnMtimeReprobeFailureSuppressesAndReports() async throws {
        try makeStaleCandidate("unreadable-after", under: sharedRootURL)
        let provider = LateFailingLeafProvider()
        provider.failAfter = ["unreadable-after": 1]

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()], provider: provider
        ))

        XCTAssertTrue(outcome.items.isEmpty,
                      "an unprovable staleness is never listed")
        XCTAssertEqual(outcome.errors.count, 1, "\(outcome.errors)")
        let issue = try XCTUnwrap(outcome.errors.first)
        XCTAssertEqual(issue.url?.lastPathComponent, "unreadable-after")
        XCTAssertTrue(
            issue.detail.contains("could not be re-established after sizing"),
            issue.detail
        )
    }

    /// The ENOENT contract is unchanged by the re-probe: an entry that
    /// vanishes during sizing is a silent skip — no item, no denial, no issue.
    func testPostSizingOwnMtimeReprobeTreatsAVanishedEntryAsASilentSkip()
        async throws {
        try makeStaleCandidate("vanishing", under: sharedRootURL)
        let spy = SizingSpy()
        spy.beforeMeasure = { url in
            try? FileManager.default.removeItem(at: url)
        }

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        ))

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty,
                      "no denial, no issue — the observable-race contract: "
                        + "\(outcome.errors)")
    }

    /// The evidence string's "last modified N days ago" branch reports the
    /// RE-READ own mtime, not the pre-filter one.
    func testNilNewestContentDateEvidenceUsesTheReReadOwnMtime() async throws {
        let entry = try makeStaleCandidate("re-dated", under: sharedRootURL)
        let spy = SizingSpy()
        // Still old — 10 days back rather than the fixture's 30 — so the
        // candidate survives while the two readings are distinguishable.
        let touched = clock.addingTimeInterval(-10 * 86_400)
        spy.beforeMeasure = { url in
            try? FileManager.default.setAttributes(
                [.modificationDate: touched], ofItemAtPath: url.path
            )
        }
        spy.stub = { [self] _ in
            report(exact: 8_192, itemCount: 1, newestContentDate: nil)
        }

        let scanner = makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertTrue(item.evidence.contains("last modified 10 days ago"),
                      "the pre-filter's 30-day reading is stale by the time "
                        + "the row is built: \(item.evidence)")
        _ = entry
    }

    func testFreshDenialBearingReportIsSuppressedYetItsDenialsStayVisible() async throws {
        let entry = try makeStaleCandidate("fresh-denied", under: sharedRootURL)
        let spy = SizingSpy()
        let freshDate = self.freshDate
        spy.stub = { [self] url in
            report(
                exact: 8_192, itemCount: 1,
                denials: [SizeDenial(
                    url: url.appendingPathComponent("inner"),
                    kind: .permission, detail: "permission denied"
                )],
                newestContentDate: freshDate
            )
        }

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        ))

        XCTAssertTrue(outcome.items.isEmpty,
                      "freshness disqualifies regardless of denials — an item "
                        + "would be a lying row")
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertEqual(outcome.errors.first?.kind, .permissionDenied)
        XCTAssertTrue(
            outcome.errors.first?.detail.contains("permission denied") ?? false
        )
        _ = entry
    }

    func testNilNewestContentDatePassesThroughToTheMapping() async throws {
        try makeStaleCandidate("undatable", under: sharedRootURL)
        let spy = SizingSpy()
        spy.stub = { [self] url in
            report(
                denials: [SizeDenial(
                    url: url, kind: .permission, detail: "permission denied"
                )],
                newestContentDate: nil
            )
        }

        let scanner = makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .denied,
                       "absence of a date is not evidence of freshness")
    }

    // MARK: - R12: the post-sizing outcome table

    func testInjectedRootMountBoundaryIsDeniedWithZeroComponents() async throws {
        let entry = try makeStaleCandidate("mounted", under: sharedRootURL)
        let provider = BoundaryInjectingProvider()
        let inode = try XCTUnwrap(
            provider.identity(of: canonical(entry))?.inode
        )
        provider.mountPointInodes.insert(inode)

        let scanner = makeScanner(roots: [sharedRoot()], provider: provider)
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .denied)
        XCTAssertEqual(item.exactBytes, 0)
        XCTAssertEqual(item.estimatedUpToBytes, 0)
        XCTAssertEqual(item.itemCount, 0)
        XCTAssertNil(item.logicalBytes)
        XCTAssertEqual(item.rootRecords.first?.status, .deniedUnmeasured)
        let error = try XCTUnwrap(item.scanError)
        XCTAssertTrue(error.message.contains(canonical(entry).path),
                      error.message)
    }

    /// The cell a boundary-arm mapping most easily gets wrong: the boundary IS
    /// the candidate root, so `mountBoundaries` is empty and a naive message
    /// builder returns nil — which would make a `.denied` item without a
    /// scanError and malform the WHOLE outcome.
    func testRootBoundaryWithoutABoundaryListStillNamesTheCandidate() async throws {
        let entry = try makeStaleCandidate("root-boundary", under: sharedRootURL)
        let spy = SizingSpy()
        spy.stub = { [self] _ in
            report(exact: 4_096, itemCount: 1, rootMountBoundary: true)
        }

        let scanner = makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .denied)
        XCTAssertEqual(item.allocatedBytes, 0,
                       "measured figures may ride the message, never the "
                        + "components")
        let error = try XCTUnwrap(item.scanError)
        XCTAssertEqual(error.kind, .other,
                       "a boundary is neither TCC nor BSD permissions")
        XCTAssertTrue(error.message.contains(canonical(entry).path),
                      error.message)
        XCTAssertTrue(error.message.contains("measured beside the boundary"),
                      error.message)
    }

    func testDenialsWithMeasuredBytesArePartiallyDenied() async throws {
        try makeStaleCandidate("partial", under: sharedRootURL)
        let spy = SizingSpy()
        spy.stub = { [self] url in
            report(
                exact: 12_288, itemCount: 3,
                denials: [SizeDenial(
                    url: url.appendingPathComponent("inner"),
                    kind: .permission, detail: "permission denied"
                )]
            )
        }

        let scanner = makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .partiallyDenied)
        XCTAssertEqual(item.exactBytes, 12_288, "real measured components")
        XCTAssertEqual(item.itemCount, 3)
        XCTAssertEqual(item.rootRecords.first?.status, .measured)
        XCTAssertEqual(item.scanError?.kind, .permissionDenied)
    }

    func testDenialsWithNothingMeasuredAreDenied() async throws {
        try makeStaleCandidate("all-denied", under: sharedRootURL)
        let spy = SizingSpy()
        spy.stub = { [self] url in
            report(denials: [SizeDenial(
                url: url, kind: .permission, detail: "permission denied"
            )])
        }

        let scanner = makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .denied)
        XCTAssertEqual(item.allocatedBytes, 0)
        XCTAssertEqual(item.rootRecords.first?.status, .deniedUnmeasured)
        XCTAssertNotNil(item.scanError)
    }

    /// Per-kind classification (epic D8 r6, class (c)): a `.tcc`-kinded
    /// `SizeDenial` conflates chain-proven denials with raw-probe GUESSES, and
    /// the only discriminator left at this surface is a message string — so it
    /// maps to a NEUTRAL error with its detail preserved, never a TCC claim
    /// and never a rewrite to permission-denied.
    func testTccKindedSizingDenialBecomesANeutralErrorWithDetailPreserved() async throws {
        try makeStaleCandidate("ambiguous", under: sharedRootURL)
        let spy = SizingSpy()
        spy.stub = { [self] url in
            report(
                exact: 8_192, itemCount: 1,
                denials: [SizeDenial(
                    url: url.appendingPathComponent("inner"),
                    kind: .tcc, detail: "lstat failed: Operation not permitted"
                )]
            )
        }

        let scanner = makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let error = try XCTUnwrap(outcome.items.first?.scanError)
        XCTAssertEqual(error.kind, .other)
        XCTAssertNotEqual(error.kind, .tccDenied)
        XCTAssertNotEqual(error.kind, .permissionDenied)
        XCTAssertTrue(error.message.contains("Operation not permitted"),
                      "the detail is preserved verbatim: \(error.message)")
    }

    func testAnomalyRowsAreEmittedRegardlessOfTheSizeFloor() async throws {
        try makeStaleCandidate("tiny-anomaly", under: sharedRootURL)
        let spy = SizingSpy()
        spy.stub = { [self] url in
            report(
                exact: 16, itemCount: 1,
                denials: [SizeDenial(
                    url: url.appendingPathComponent("inner"),
                    kind: .permission, detail: "permission denied"
                )]
            )
        }

        let scanner = makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .partiallyDenied)
        XCTAssertEqual(item.exactBytes, 16,
                       "an unmeasurable tree cannot be honestly "
                        + "floor-evaluated — the floor is trusted only on a "
                        + "clean walk")
    }

    // MARK: - R11: missing vs denied roots

    func testAbsentRootIsSkippedSilently() async throws {
        let missing = base.appendingPathComponent("never-created")
        let root = makeRoot(missing, label: "Missing",
                            writability: .perUser, canonicalize: false)

        let outcome = await scan(makeScanner(roots: [root]))
        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty,
                      "temp roots churn by design — a spurious issue for a "
                        + "vanished root trains users to ignore issues")
    }

    /// The construction-to-scan disappearance race: fn-6.1 resolved the root,
    /// and it was gone before `scan(context:)` ran.
    func testRootRemovedBetweenConstructionAndScanIsSilent() async throws {
        let root = sharedRoot()
        let scanner = makeScanner(roots: [root])
        try fm.removeItem(at: sharedRootURL)

        let outcome = await scan(scanner)
        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty)
    }

    /// The probe-to-list window (PR #459 review r4, codex C5 — DISCLOSURE):
    /// the root exists through the kind probe and PathGuard admission, then
    /// vanishes before the listing's own open. The injected lister removes
    /// the root and calls the REAL production lister, so the genuine
    /// Foundation error (Cocoa 260 wrapping POSIX ENOENT, measured) flows
    /// through the production catch — which must apply R11's silent-absence
    /// contract at THIS instant too, exactly as every other seam in the file
    /// does. Before this fix the catch reported it as a visible
    /// `.unreadable` issue: a benign absence dressed as an impediment.
    func testRootVanishingInTheProbeToListWindowIsSilent() async throws {
        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            listDirectory: { url, limit in
                try FileManager.default.removeItem(at: url)
                return try EphemeralTempScanner.boundedFirstLevelNames(
                    of: url, limit: limit
                )
            }
        ))

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty,
                      "absence in the probe-to-list window is the same "
                        + "benign churn R11 legislates for: \(outcome.errors)")
    }

    /// ENOTDIR is absence too (the house definition, `probeKind`'s own:
    /// something that is not a directory tree stands at the name). Injected
    /// as a chain-bearing throw — Cocoa 256 wrapping POSIX ENOTDIR, the
    /// shape measured for a name replaced by a regular file — so the
    /// ENOTDIR arm is evidenced independently of ENOENT.
    func testChainENOTDIRListingThrowIsSilentlySkipped() async throws {
        let lister = ListerSpy()
        lister.stubError = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)
            )]
        )

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()],
            listDirectory: { [lister] url, limit in try lister.list(url, limit) }
        ))

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty,
                      "chain-ENOTDIR is absence, not an impediment: "
                        + "\(outcome.errors)")
    }

    func testPresentButUnreadableRootIsAVisibleIssue() async throws {
        try skipUnderRoot()
        try makeStaleCandidate("hidden", under: sharedRootURL)
        try chmod000(sharedRootURL)

        let outcome = await scan(makeScanner(roots: [sharedRoot()]))

        XCTAssertTrue(outcome.items.isEmpty)
        let issue = try XCTUnwrap(outcome.errors.first)
        XCTAssertEqual(issue.kind, .permissionDenied,
                       "a silent zero for a denied root is the TCC-silent-zero "
                        + "defect class")
        XCTAssertEqual(issue.url?.path, canonical(sharedRootURL).path)
    }

    /// THE ROOT LISTING IS BOUNDED, AND A CAP HIT IS DISCLOSED (PR #459
    /// review r4, codex C3 — AVAILABILITY). No lister is injected: the
    /// PRODUCTION bounded read runs, per the house doctrine that injecting a
    /// fixture past a seam does not evidence the seam's production default.
    /// The eager listing this replaces materialized a world-writable root's
    /// ENTIRE population in one uninterruptible stretch (measured: 6.8 s
    /// list + 16.4 s sort and an 8.2 GB transient RSS on a staged
    /// ~494k-entry root).
    func testRootListingIsBoundedAndTruncationIsAVisibleIssue() async throws {
        for name in ["cap-a", "cap-b", "cap-c", "cap-d", "cap-e"] {
            try makeStaleCandidate(name, under: sharedRootURL)
        }

        let scanner = makeScanner(roots: [sharedRoot()], rootEntryLimit: 3)
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertEqual(outcome.items.count, 3,
                       "exactly the capped subset is inspected: "
                        + "\(outcome.items.map(\.displayName))")
        XCTAssertEqual(outcome.errors.count, 1)
        let issue = try XCTUnwrap(outcome.errors.first)
        XCTAssertEqual(issue.kind, .enumerationTruncated)
        XCTAssertEqual(issue.kind.wireString, "enumeration_truncated",
                       "frozen wire string")
        XCTAssertEqual(issue.url?.path, canonical(sharedRootURL).path)
        // Pinned VERBATIM: the wording states the convergence FACT (cleaning
        // shrinks the population) and never promises a bare "re-scan and
        // retry" — a promise is only honest where a retry can differ, and
        // this sentence says why it can.
        XCTAssertEqual(
            issue.detail,
            "Shared temp holds more than 3 first-level entries — only the "
                + "first 3 the directory returned were inspected; clearing "
                + "entries, including cleaning the items listed here, lets a "
                + "later scan see the rest"
        )
    }

    /// The ROOT arm's sentence and KIND follow the CAUSE, never the entry
    /// count (r7, codex C2).
    ///
    /// The count heuristic that stood here was a guess: a `readdir` failure
    /// landing exactly at the cap printed "holds more than N first-level
    /// entries" though nothing beyond N was ever proven to exist — the
    /// inference `OrphanedCachesScanner.obstruction(forErrno:)` refuses in
    /// writing. Worse, `.enumerationTruncated`'s single GUI label is the
    /// fixed sentence "too many entries — partially inspected"
    /// (`ScannerItemSection.label(for:)`), which is simply false for a read
    /// that FAILED. So a read failure now takes the CLASSIFIED denial route:
    /// `classify` maps EACCES to `.permissionDenied` and EPERM (with every
    /// other errno) to `.unreadable`, so the kind follows the errno rather
    /// than being fixed. This cell drives EIO, i.e. the `.unreadable` arm.
    /// `.enumerationTruncated` means a cap hit and nothing else.
    func testRootReadFailureIsNotReportedAsTooManyEntries() async throws {
        for name in ["cap-a", "cap-b", "cap-c"] {
            try makeStaleCandidate(name, under: sharedRootURL)
        }

        // Exactly `rootEntryLimit` names AND a failed read — the ambiguous
        // shape the count heuristic got wrong.
        let outcome = await scan(makeScanner(
            roots: [sharedRoot()], rootEntryLimit: 3,
            listDirectory: { url, limit in
                let read = try EphemeralTempScanner.boundedFirstLevelNames(
                    of: url, limit: limit
                )
                return (read.names, .readFailed(errno: EIO))
            }
        ))

        let issue = try XCTUnwrap(outcome.errors.first)
        XCTAssertEqual(
            outcome.errors.count, 1, "\(outcome.errors)"
        )
        XCTAssertEqual(
            issue.kind, .unreadable,
            "EIO takes `classify`'s default arm; a listing that FAILED is a "
                + "denial either way — `.enumerationTruncated` renders as "
                + "\"too many entries — partially inspected\", which would be "
                + "a false claim about the cause"
        )
        XCTAssertFalse(
            issue.detail.contains("holds more than"),
            "nothing beyond the entries actually read was proven to exist: "
                + "\(issue.detail)"
        )
        XCTAssertTrue(
            issue.detail.contains("could not be enumerated completely"),
            issue.detail
        )

        // The OTHER arm of the same route (r8, D6): the kind follows the
        // errno, so a comment or message naming just one of the two is a
        // claim the code does not make.
        let denied = await scan(makeScanner(
            roots: [sharedRoot()], rootEntryLimit: 3,
            listDirectory: { url, limit in
                let read = try EphemeralTempScanner.boundedFirstLevelNames(
                    of: url, limit: limit
                )
                return (read.names, .readFailed(errno: EACCES))
            }
        ))
        XCTAssertEqual(
            denied.errors.first?.kind, .permissionDenied,
            "EACCES is unambiguous BSD permissions — `classify` does not "
                + "flatten it to `.unreadable`: \(denied.errors)"
        )
    }

    /// The FAILURE arm of the production lister throws the CHAIN-BEARING
    /// Cocoa error, never the raw `opendir` errno (PR #459 review r4, codex
    /// C3). The distinction is doctrinal, not cosmetic: class-(a)
    /// classification is licensed by Foundation PROVENANCE — a raw errno
    /// EPERM may NOT claim TCC (class (b)) — and mutation testing showed the
    /// kind-level assertions alone cannot see the difference (a top-level
    /// POSIX EACCES classifies like a chain-EACCES), so this cell pins the
    /// ERROR SHAPE the harvest exists to produce.
    func testBoundedListerFailureThrowsTheChainBearingCocoaError() throws {
        try skipUnderRoot()
        let dir = try mkdir(base.appendingPathComponent("no-read-root"))
        try chmod000(dir)

        XCTAssertThrowsError(
            try EphemeralTempScanner.boundedFirstLevelNames(of: dir, limit: 5)
        ) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, NSCocoaErrorDomain,
                           "the harvested error is Foundation's, carrying "
                            + "provenance — got \(ns)")
            let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(underlying?.domain, NSPOSIXErrorDomain,
                           "…wrapping the POSIX cause: \(ns)")
            XCTAssertEqual(underlying?.code, Int(EACCES))
        }
    }

    /// The FAILURE arm's BOUNDED RETRY (PR #459 review r6, codex C1 —
    /// AVAILABILITY): a listing failure that clears between the two bounded
    /// reads recovers through the SAME `readdir` loop, and the Foundation
    /// chain harvest never runs. This cell drives the ordering through the
    /// seam because that is DETERMINISTIC — a real staging is probabilistic
    /// per attempt (the natural window is the handful of instructions
    /// between two consecutive `opendir` calls), though not rare: a
    /// chmod-000/755 flipper racing the real reads staged it in 200 of
    /// 1,223 attempts (~16% per attempt, measured for PR #459 r6 verify),
    /// and the flipper cell below keeps that staging green. The seam's
    /// production defaults are evidenced by the surrounding cells — the
    /// success path by the bounded-listing cells above, the double-failure
    /// path by the chmod-000 chain-error cell, the fail-then-cleared pair
    /// by the flipper cell.
    func testAClearedListingFailureRecoversBoundedThroughTheRetry() throws {
        let dir = try mkdir(base.appendingPathComponent("retry-root"))
        for name in ["a", "b", "c", "d", ".hidden"] {
            try writeFile(dir.appendingPathComponent(name), bytes: 8)
        }

        var boundedCalls = 0
        let result = try EphemeralTempScanner.boundedFirstLevelNames(
            of: dir, limit: 3,
            boundedRead: { url, limit in
                boundedCalls += 1
                if boundedCalls == 1 { return .failed(errno: EACCES) }
                return EphemeralTempScanner.boundedChildNames(
                    of: url, limit: limit
                )
            },
            chainHarvest: { _, _ in
                XCTFail("the Foundation harvest ran though the bounded retry "
                        + "succeeded — the r4 C3 bound is only owed by the "
                        + "readdir loop")
                return ([], nil)
            }
        )

        XCTAssertEqual(boundedCalls, 2, "exactly one retry, never a loop")
        XCTAssertEqual(result.names.count, 3)
        XCTAssertEqual(result.truncation, .budget,
                       "the retry hit the entry cap — nothing was denied")
    }

    /// THE SAME ORDERING, STAGED AGAINST THE REAL READS (PR #459 r6 verify):
    /// a chmod-000/755 flipper races the PRODUCTION `boundedChildNames`
    /// pair — the seam carries only counting pass-throughs — until an
    /// attempt's first real `opendir` is denied and its immediate retry
    /// succeeds. Measured while writing this cell: 200 stagings in 1,223
    /// attempts (~16% per attempt, 35 ms, every staging returning the
    /// bounded truncated listing), so the first staging typically lands
    /// within a handful of attempts and the 200,000-attempt cap is a
    /// scheduler-pathology bound, not a hope. A successful return whose
    /// attempt made only ONE bounded read is the no-retry signature (a
    /// single cleared failure falling through to Foundation) and fails
    /// immediately.
    func testTheRetryRecoversARealClearedDenialUnderAChmodFlipper() throws {
        try skipUnderRoot()
        let dir = try mkdir(base.appendingPathComponent("flipper-root"))
        for name in ["a", "b", "c", "d", ".hidden"] {
            try writeFile(dir.appendingPathComponent(name), bytes: 8)
        }

        final class StopFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var stopped: Bool {
                lock.lock(); defer { lock.unlock() }; return value
            }
            func stop() { lock.lock(); value = true; lock.unlock() }
        }
        let flag = StopFlag()
        let flipperDone = DispatchSemaphore(value: 0)
        let cPath = dir.path
        Thread.detachNewThread {
            while !flag.stopped {
                chmod(cPath, 0o000)
                chmod(cPath, 0o755)
            }
            chmod(cPath, 0o755)
            flipperDone.signal()
        }
        defer {
            flag.stop()
            flipperDone.wait()
        }

        var attempts = 0
        while attempts < 200_000 {
            attempts += 1
            var reads: [Bool] = []   // per bounded read: true = .names
            let result: (names: [String],
                         truncation: EphemeralTempScanner.BoundedRead.Truncation?)
            do {
                result = try EphemeralTempScanner.boundedFirstLevelNames(
                    of: dir, limit: 3,
                    boundedRead: { url, limit in
                        let read = EphemeralTempScanner.boundedChildNames(
                            of: url, limit: limit
                        )
                        if case .names = read { reads.append(true) }
                        else { reads.append(false) }
                        return read
                    },
                    chainHarvest: { url, limit in
                        try EphemeralTempScanner.lazyChainHarvest(
                            of: url, limit: limit
                        )
                    }
                )
            } catch {
                // Double failure with the harvest denied too — not this
                // cell's ordering; race again.
                continue
            }
            if reads == [false] {
                return XCTFail(
                    "a single cleared failure reached the Foundation "
                        + "harvest — the bounded retry is gone"
                )
            }
            guard reads == [false, true] else { continue }
            // Staged: the retry recovered a REAL cleared EACCES, bounded.
            XCTAssertEqual(result.names.count, 3)
            XCTAssertEqual(result.truncation, .budget,
                           "the recovered read hit the cap, not a denial")
            return
        }
        XCTFail("the fail-then-cleared ordering never staged in "
                + "\(attempts) attempts")
    }

    /// The chain harvest's SUCCESS path (the double-race residual) is capped
    /// at `limit` and keeps hidden entries — the retired eager fallback's
    /// `options: []` semantics, without its materialization.
    func testTheChainHarvestSuccessPathIsCappedAndKeepsHiddenEntries() throws {
        let dir = try mkdir(base.appendingPathComponent("harvest-root"))
        for name in ["e1", "e2", "e3", "e4", "e5", ".dot-scratch"] {
            try writeFile(dir.appendingPathComponent(name), bytes: 8)
        }

        let capped = try EphemeralTempScanner.lazyChainHarvest(
            of: dir, limit: 4
        )
        XCTAssertEqual(capped.names.count, 4)
        XCTAssertEqual(capped.truncation, .budget,
                       "the harvest's only truncation cause is the cap")

        let all = try EphemeralTempScanner.lazyChainHarvest(of: dir, limit: 100)
        XCTAssertEqual(all.names.count, 6)
        XCTAssertNil(all.truncation, "an exhaustive harvest truncates nothing")
        XCTAssertTrue(all.names.contains(".dot-scratch"),
                      "dotfile scratch directories are real payload")
    }

    /// THE BOUND ITSELF, on the harvest's success path (PR #459 review r6,
    /// codex C1 — AVAILABILITY): the harvest must read LAZILY, never
    /// materialize the population. Asserted as an RSS ceiling because the
    /// return value cannot distinguish lazy from eager (`prefix(limit)` of an
    /// eager list returns the same names): take-5 of a 60,000-entry
    /// directory measured +0.0 MB RSS lazily vs +42.5 MB through the eager
    /// `contentsOfDirectory` this replaced, so the 20 MB ceiling separates
    /// the two by a wide margin in both directions.
    func testTheChainHarvestNeverMaterializesTheWholePopulation() throws {
        let dir = try mkdir(base.appendingPathComponent("big-harvest-root"))
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        for index in 0..<60_000 {
            let file = openat(fd, "e\(index)", O_CREAT | O_WRONLY, 0o644)
            XCTAssertGreaterThanOrEqual(file, 0)
            close(file)
        }

        func residentBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(
                MemoryLayout<mach_task_basic_info>.size
                    / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(
                        mach_task_self_,
                        task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count
                    )
                }
            }
            XCTAssertEqual(result, KERN_SUCCESS)
            return info.resident_size
        }

        let before = residentBytes()
        let result = try EphemeralTempScanner.lazyChainHarvest(of: dir, limit: 5)
        let after = residentBytes()

        XCTAssertEqual(result.names.count, 5)
        XCTAssertEqual(result.truncation, .budget)
        let delta = after > before ? after - before : 0
        XCTAssertLessThan(
            delta, 20 * 1_048_576,
            "the harvest materialized the population: RSS grew "
                + "\(delta / 1_048_576) MB across a take-5 of 60k entries"
        )
    }

    /// The boundary is honest in the other direction: a population AT the cap
    /// is fully inspected and reports nothing.
    func testRootListingAtExactlyTheCapIsNotTruncated() async throws {
        for name in ["fit-a", "fit-b", "fit-c"] {
            try makeStaleCandidate(name, under: sharedRootURL)
        }

        let scanner = makeScanner(roots: [sharedRoot()], rootEntryLimit: 3)
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertEqual(outcome.items.count, 3)
        XCTAssertTrue(outcome.errors.isEmpty,
                      "no truncation row for an exhaustive listing: "
                       + "\(outcome.errors)")
    }

    func testSymlinkRootIsNeverTraversed() async throws {
        let realDirectory = try mkdir(base.appendingPathComponent("elsewhere"))
        try makeStaleCandidate("payload", under: realDirectory)
        let link = base.appendingPathComponent("linked-root")
        try fm.createSymbolicLink(at: link, withDestinationURL: realDirectory)

        // Declared WITHOUT canonicalization so the root stays the link
        // itself. That is a HAND-BUILT root: it proves the gate works on the
        // input it is given, and it can say nothing about whether fn-6.1's
        // resolution ever delivers such a root. The sibling cell below is the
        // one that closes that hole, by going through
        // `EphemeralTempRoots.resolve` and then through the real cleaner.
        let root = makeRoot(link, label: "Linked", writability: .perUser,
                            canonicalize: false)
        let outcome = await scan(makeScanner(roots: [root]))

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.errors.first?.kind, .symlinkRoot)
    }

    /// A NON-SYMLINK NON-DIRECTORY ROOT IS NOT DIAGNOSED AS A SYMLINK
    /// (PR #459 codex r13, P2 DISCLOSURE).
    ///
    /// Safety was never in question — the no-follow root gate refuses every
    /// one of these. The VISIBLE row was: `ScanIssuesBlock` renders
    /// `ScanIssueRowPresentation.text`, whose sentence is derived from the
    /// KIND alone, and `.symlinkRoot`'s sentence is the fixed "symlinked —
    /// not searched". A per-user `C`/`T` root replaced by a regular file, a
    /// FIFO, a socket or a device therefore told the user to go find a
    /// symlink that does not exist; the object's real kind was already in
    /// `detail`, which that block shows only as a hover tooltip.
    ///
    /// Three roots in ONE scan so the split is asserted against its own
    /// control: the regular file and the FIFO take `.nonDirectoryRoot`, the
    /// symlink KEEPS `.symlinkRoot`. Each row's rendered sentence is
    /// asserted too — the kind is a means, the sentence is the fix.
    func testANonSymlinkNonDirectoryRootSaysSoInsteadOfClaimingASymlink()
        async throws
    {
        let file = try writeFile(base.appendingPathComponent("file-root"))
        let fifo = base.appendingPathComponent("fifo-root")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0,
                       "mkfifo: \(String(cString: strerror(errno)))")
        let target = try mkdir(base.appendingPathComponent("link-target"))
        let link = base.appendingPathComponent("link-root")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let outcome = await scan(makeScanner(roots: [
            makeRoot(file, label: "File", writability: .perUser),
            makeRoot(fifo, label: "Fifo", writability: .perUser),
            // The link is declared UNCANONICALIZED so the root stays the
            // link itself — canonicalizing it would resolve the leaf away.
            makeRoot(link, label: "Link", writability: .perUser,
                     canonicalize: false),
        ]))

        XCTAssertTrue(outcome.items.isEmpty,
                      "nothing behind any of these roots is listed: "
                        + "\(outcome.items.map(\.displayName))")
        XCTAssertEqual(
            outcome.errors.map(\.kind),
            [.nonDirectoryRoot, .nonDirectoryRoot, .symlinkRoot],
            "a regular file and a FIFO are NOT symlinks; a symlink still is: "
                + "\(outcome.errors)"
        )
        XCTAssertEqual(
            outcome.errors.map {
                ScanIssueRowPresentation(issue: $0, home: home).label
            },
            ["not a directory — not searched",
             "not a directory — not searched",
             "symlinked — not searched"],
            "the VISIBLE sentence, not just the kind"
        )
        // The tooltip still names WHICH object it is — that half was never
        // the defect and must not regress.
        XCTAssertTrue(
            try XCTUnwrapElement(outcome.errors, 0).detail.contains("(regular file)"),
            "detail names the real kind: \(outcome.errors.map(\.detail))"
        )
        XCTAssertTrue(
            try XCTUnwrapElement(outcome.errors, 1).detail.contains("(special file)"),
            "detail names the real kind: \(outcome.errors.map(\.detail))"
        )
    }

    /// A POLICY-REFUSED ROOT IS NOT DIAGNOSED AS UNCONFIGURED (PR #459 codex
    /// r13, P2 DISCLOSURE — the sibling of r11's mounted-root case).
    ///
    /// `EphemeralTempScanner` builds its `PathGuard` with
    /// `containerRoots: roots.map(\.url)` and then iterates those same
    /// roots, so a root reaching the `admitSearchRoot` catch is ALWAYS one
    /// of the guard's own configured roots. `.containerRefused`'s fixed
    /// sentence — "not a configured search root" — was therefore false for
    /// every firing of that arm, and it invites an action (configure the
    /// root) that is impossible here: these roots are `/private/tmp` and two
    /// `confstr` containers, not user settings.
    ///
    /// `$HOME` as a root is the cheapest reachable refusal (`coreDenyCheck`
    /// throws `deniedHomeDirectory`); the arm is shared with the `/` and
    /// volume-root clauses.
    func testAPolicyRefusedRootSaysThePolicyRefusedItNotThatItIsUnconfigured()
        async throws
    {
        let outcome = await scan(makeScanner(roots: [
            makeRoot(home, label: "Shared temp", writability: .perUser),
        ]))

        XCTAssertTrue(outcome.items.isEmpty,
                      "a refused root is never walked: "
                        + "\(outcome.items.map(\.displayName))")
        XCTAssertEqual(outcome.errors.map(\.kind), [.policyRefusedRoot],
                       "\(outcome.errors)")
        let row = ScanIssueRowPresentation(
            issue: try XCTUnwrap(outcome.errors.first), home: home
        )
        XCTAssertEqual(row.label, "refused by the search-root safety policy")
        XCTAssertFalse(
            row.label.contains("not a configured search root"),
            "the root IS configured — this scanner's guard is built FROM it"
        )
        // The clause that fired stays in the tooltip, where it always was.
        XCTAssertTrue(
            try XCTUnwrapElement(outcome.errors, 0).detail.contains("home directory"),
            "detail names the clause: \(outcome.errors.map(\.detail))"
        )
    }

    /// PRODUCTION-PATH symlink root: resolution → scan → deletion, end to end.
    ///
    /// The round-7 defect this pins: fn-6.1 resolved each declared root with
    /// full `realpath(3)`, which follows the LEAF. A symlink standing where
    /// the per-user `C` container should be was therefore replaced by its
    /// DESTINATION before the scanner ever saw it, so the no-follow root gate
    /// inspected a genuine directory and passed it; the destination became a
    /// `trustedContainerRoot`; its children were listed as cache-container
    /// payload; the delete-time revalidator allowed them; and the cleaner
    /// deleted them. No later gate refused, because the container-root policy
    /// refuses only `/`, volume roots and `$HOME` itself — `~/Documents` is a
    /// legal container by design (`PathGuard.swift:350-361`).
    ///
    /// The victim is deliberately `<home>/Documents`, the production shape,
    /// and the disposal is the PERMANENT arm so the assertion observes a real
    /// destroyed tree rather than a missing issue.
    func testResolvedSymlinkContainerIsRefusedAndItsTargetSurvives() async throws {
        let victim = try mkdir(home.appendingPathComponent("Documents"))
        let payload = try makeStaleCandidate("Taxes-2019", under: victim)

        // The per-user `C` container is a SYMLINK to the victim's Documents.
        let container = base.appendingPathComponent("var-folders-bucket-C")
        try fm.createSymbolicLink(at: container, withDestinationURL: victim)

        // Resolution goes through PRODUCTION `EphemeralTempRoots.resolve`.
        // Only the confstr(3) lookup is stubbed; the shared `/private/tmp`
        // root is dropped afterwards so no test reads a real temp root.
        let resolved = EphemeralTempRoots.resolve(
            confstrPath: { name in
                name == _CS_DARWIN_USER_CACHE_DIR ? container.path + "/" : nil
            }
        )
        let cacheRoot = try XCTUnwrap(
            resolved.roots.first { $0.label == EphemeralTempRoots.userCache.label }
        )
        // NOT an alias of anything else declared, so it survives resolution
        // verbatim and the SCAN-time gate is what refuses it — resolution
        // drops a non-directory spelling only when a real-directory spelling
        // of the same location is declared too.
        XCTAssertTrue(resolved.issues.isEmpty, "\(resolved.issues)")
        XCTAssertNotEqual(
            cacheRoot.url.path, canonical(victim).path,
            "resolution must not hand the scanner the symlink's destination"
        )

        let scanner = makeScanner(roots: [cacheRoot])
        let runtime = try SpaceScannerRuntime(
            scanners: [scanner], categories: [], home: home,
            provider: FileSystemIdentityProvider()
        )
        let session = runtime.scanValidatedSession(
            context: ScanContext(trigger: .userInitiated)
        )
        var outcome: ScanOutcome?
        for await event in session.events {
            if case .outcome(_, let produced) = event { outcome = produced }
        }
        let scanned = try XCTUnwrap(outcome)

        XCTAssertEqual(
            scanned.errors.first?.kind, .symlinkRoot,
            "a symlink standing at a container's own name must be REFUSED "
                + "visibly, not silently followed: \(scanned.errors)"
        )
        XCTAssertTrue(
            scanned.items.isEmpty,
            "nothing behind a container symlink may be listed: "
                + "\(scanned.items.map(\.displayName))"
        )

        // Whatever the scan emitted, hand it to the REAL cleaner on the
        // permanent (non-Trash) arm. With the leaf resolved this deleted the
        // user's document tree outright.
        let report = await runtime
            .makeCleaner(snapshot: session.snapshot)
            .clean(items: scanned.items, moveToTrash: false)

        XCTAssertTrue(
            fm.fileExists(atPath: payload.path),
            "the symlink's destination was DELETED — \(report.entries.count) "
                + "entries removed, errors: \(report.errors)"
        )
    }

    /// D1 (PR #459 codex r8), the END-TO-END half: an alias standing at `C`
    /// must not cost the real `T` root its scan.
    ///
    /// Round 7's canonical-key de-dupe kept the FIRST declaration whatever it
    /// was, so with `C` a symlink onto the genuine `T` directory the resolved
    /// set held the LINK and no longer held `T` at all. The scan then refused
    /// the link with `.symlinkRoot` and inspected nothing: `T`'s stale entry
    /// was never listed, so it could never be cleaned, and no issue named
    /// `T`. Round 6 and earlier scanned that same layout normally.
    ///
    /// The whole path runs for real — production `EphemeralTempRoots.resolve`
    /// (only confstr(3) is stubbed), the production scanner, and the runtime
    /// session that carries the registration.
    func testAliasAtOneContainerDoesNotCostTheOtherContainerItsScan() async throws {
        let realTemp = try mkdir(base.appendingPathComponent("real-T"))
        let stale = try makeStaleCandidate("old-scratch", under: realTemp)
        let aliasCache = base.appendingPathComponent("alias-C")
        try fm.createSymbolicLink(at: aliasCache, withDestinationURL: realTemp)

        let resolved = EphemeralTempRoots.resolve(
            confstrPath: { name in
                switch name {
                case _CS_DARWIN_USER_CACHE_DIR: return aliasCache.path + "/"
                case _CS_DARWIN_USER_TEMP_DIR: return realTemp.path
                default: return nil
                }
            }
        )
        // The shared `/private/tmp` root is dropped so no test reads a real
        // temp root; everything else is exactly what production resolved.
        let scannerRoots = resolved.roots.filter { $0.url.path != "/private/tmp" }
        XCTAssertEqual(
            scannerRoots.map(\.url.path), [canonical(realTemp).path],
            "the REAL root must be the survivor: \(resolved.roots.map(\.url.path))"
        )

        let scanner = makeScanner(
            roots: scannerRoots, resolutionIssues: resolved.issues
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertEqual(
            outcome.items.map(\.displayName), ["old-scratch"],
            "the surviving root's stale entry must still be listed: "
                + "\(outcome.items.map(\.displayName))"
        )
        XCTAssertEqual(
            outcome.items.first?.rootRecords.first?.requestedURL.path,
            canonical(stale).path
        )
        XCTAssertEqual(
            outcome.errors.map(\.kind), [.symlinkRoot],
            "the dropped alias rides the outcome — dropping it is not a "
                + "silent loss: \(outcome.errors)"
        )
        // The DECLARED spelling — canonical parent chain, leaf UNRESOLVED —
        // never the link's destination.
        XCTAssertEqual(
            outcome.errors.first?.url?.path,
            canonical(base).appendingPathComponent("alias-C").path
        )
    }

    // MARK: - R3/R8: identity, dedupe and the emitted item shape

    /// Two DECLARED spellings of one directory (`/var/…` vs `/private/var/…`)
    /// must collapse to ONE item whose identity is the canonical parent chain
    /// plus the UNRESOLVED leaf — a full canonicalization would resolve the
    /// leaf, and two symlink entries sharing a target would collide on one id
    /// and malform the whole outcome.
    func testAliasedRootSpellingsProduceOneLeafPreservingItem() async throws {
        let entry = try makeStaleCandidate("shared-entry", under: sharedRootURL)
        let canonicalSpelling = canonical(sharedRootURL)
        try XCTSkipIf(
            canonicalSpelling.path == sharedRootURL.path,
            "this host's temp directory has no /var → /private/var alias"
        )

        let aliasRoot = makeRoot(
            sharedRootURL, label: "Alias", writability: .perUser,
            canonicalize: false
        )
        let canonicalRoot = makeRoot(
            sharedRootURL, label: "Canonical", writability: .perUser
        )
        let scanner = makeScanner(roots: [aliasRoot, canonicalRoot])
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertEqual(outcome.items.count, 1, "one filesystem object, one item")
        let item = try XCTUnwrap(outcome.items.first)
        let identity = canonicalSpelling
            .appendingPathComponent(entry.lastPathComponent)
        XCTAssertEqual(item.url?.path, identity.path)
        XCTAssertEqual(item.id, ReclaimableItem.stableID(
            scannerID: EphemeralTempScanner.registeredID,
            canonicalPath: identity.path
        ))
        // The deletion input keeps the DECLARED (unresolved) spelling.
        guard case .containerItem(let origin, let target) = item.admission else {
            return XCTFail("expected the frozen .containerItem arm")
        }
        XCTAssertEqual(origin.path, aliasRoot.url.path)
        XCTAssertEqual(
            target.path,
            aliasRoot.url.appendingPathComponent("shared-entry").path
        )
        XCTAssertEqual(item.rootRecords.first?.resolvedURL?.path, identity.path)
    }

    func testEmittedItemShapeAndSelectionPolicy() async throws {
        let entry = try makeStaleCandidate("shape", under: sharedRootURL)
        let scanner = makeScanner(roots: [sharedRoot()])
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.scannerID, "ephemeral_tmp")
        XCTAssertEqual(item.risk, .review)
        XCTAssertFalse(item.defaultSelected)
        // WHAT THIS FLAG ACTUALLY GOVERNS (PR #459 review r1). The message
        // that stood here said `false` "routes these items AROUND the
        // orphaned-caches-keyed pre-delete probe" — a mechanism the cleaner
        // does not have: `preDeleteOutcome` looks the registry up by
        // `item.scannerID`, so an `ephemeral_tmp` item could never reach the
        // `orphaned_caches` predicate whatever this flag said, and the flag is
        // read by no revalidation path at all. It is the CLI smart-clean
        // exclusion (`CLIHandler.smartCleanCandidates` is the only consumer
        // that admits `.review` items) and that is the whole of it.
        XCTAssertFalse(item.automaticCleanEligible,
                       "load-bearing as the CLI smart-clean exclusion — the "
                        + "one consumer that admits `.review` items")
        XCTAssertTrue(item.requiresPreDeleteRevalidation,
                      "the braces half of the belt-and-braces dispatch")
        XCTAssertNotNil(scanner.preDeleteRevalidator,
                        "temp items are revalidated from a held descriptor "
                         + "immediately before deletion")
        XCTAssertEqual(item.isStale, true)
        XCTAssertEqual(item.action, .removeItem)
        XCTAssertNil(item.rebuildNote)
        XCTAssertNil(item.logicalBytes, "no sparse divergence in this fixture")
        XCTAssertEqual(item.declaredDisplayPath,
                       canonical(sharedRootURL)
                        .appendingPathComponent("shape").path)
        XCTAssertTrue(item.evidence.contains("Shared temp"), item.evidence)
        XCTAssertTrue(item.evidence.contains("30 days old"), item.evidence)
        XCTAssertTrue(
            item.evidence.contains(EphemeralTempRoots.sharedTempEvidence),
            item.evidence
        )
        XCTAssertEqual(scanner.trustedContainerRoots.map(\.path),
                       [canonical(sharedRootURL).path])
        _ = entry
    }

    /// Temp roots can hold hardlinks, and deleting one link frees nothing
    /// while another survives — so the "up to" component must ride through
    /// verbatim instead of being forced to zero.
    func testHardlinkedBytesRideTheEstimatedComponent() async throws {
        let entry = try mkdir(sharedRootURL.appendingPathComponent("linked"))
        let original = try writeFile(
            entry.appendingPathComponent("payload.bin"), bytes: 8_192
        )
        try fm.linkItem(
            at: original, to: entry.appendingPathComponent("payload-2.bin")
        )
        try backdate(entry, to: oldDate)

        let scanner = makeScanner(roots: [sharedRoot()])
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertGreaterThan(item.estimatedUpToBytes, 0,
                             "hardlinked bytes are 'up to', never exact")
        XCTAssertEqual(item.exactBytes, 0)
        XCTAssertEqual(item.itemCount, 2, "two directory entries, one inode")
    }

    func testLogicalBytesRideOnlyOnDivergence() async throws {
        try makeStaleCandidate("sparse", under: sharedRootURL)
        let spy = SizingSpy()
        spy.stub = { [self] _ in
            report(exact: 8_192, logical: 64_000, itemCount: 1)
        }

        let scanner = makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
        )
        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertEqual(outcome.items.first?.logicalBytes, 64_000,
                       "deletion frees LESS than the apparent size")
    }

    // MARK: - Delete-time revalidation (PR #459 review r1)

    /// Reports a chosen `st_uid` for every descriptor — the hermetic stand-in
    /// for a foreign-owned entry, which a single-uid fixture cannot stage.
    private final class DescriptorOwnerInjectingProvider:
        FileSystemIdentityProvider {
        var uid: UInt32?

        override func ownerUID(ofDescriptor fd: Int32) -> UInt32? {
            uid ?? super.ownerUID(ofDescriptor: fd)
        }
    }

    /// THE BINDING, asserted as a value: a directory candidate's `.allow`
    /// carries the `fstat` identity of the descriptor the revalidation held,
    /// which is what `DepthSafeRemoval.proveInspectedRoot` and
    /// `TrashDisposal.dispose(_:expecting:…)` compare the deletion against.
    /// `.unestablished` here would bind nothing at all.
    func testRevalidatorAllowsAStillStaleDirectoryBoundToItsInodeIdentity()
        async throws {
        let entry = try makeStaleCandidate("still-stale", under: sharedRootURL)
        let scanner = makeScanner(roots: [sharedRoot()])
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["still-stale"])

        let verdict = try XCTUnwrap(scanner.preDeleteRevalidator)
            .revalidate(item: item, authorization: nil)

        let expected = try XCTUnwrap(
            FileSystemIdentityProvider().identity(of: canonical(entry))
        )
        XCTAssertEqual(verdict, .allow(inspected: .directory(expected)))
        XCTAssertTrue(
            try XCTUnwrap(scanner.preDeleteRevalidator)
                .requiresRevalidation(item: item),
            "applicability is EVERY temp item — no flag in the predicate"
        )
    }

    /// A REGULAR-FILE candidate has no tree to walk, and its `.allow` carries
    /// the file's own identity — the `fstat` of the descriptor the
    /// revalidation held, already proven equal to the scan's record. This is
    /// what the permanent arm's `ENOTDIR` `fstatat` comparison and the Trash
    /// arm's two-sided leaf binding prove the disposal against (PR #459
    /// review r5: this verdict used to be the identity-free
    /// `.noDirectoryTree`, which any non-directory at the name satisfied, so
    /// a replacement landing after the re-check was destroyed on both arms).
    func testRevalidatorBindsARegularFileCandidateToItsInodeIdentity()
        async throws {
        let entry = try writeFile(
            sharedRootURL.appendingPathComponent("old-blob.bin"), bytes: 8_192
        )
        try setDate(entry, oldDate)
        let scanner = makeScanner(roots: [sharedRoot()])
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["old-blob.bin"])

        let expected = try XCTUnwrap(
            FileSystemIdentityProvider().identity(of: canonical(entry))
        )
        XCTAssertEqual(
            try XCTUnwrap(scanner.preDeleteRevalidator)
                .revalidate(item: item, authorization: nil),
            .allow(inspected: .nonDirectoryLeaf(expected))
        )
    }

    /// The cooperative lock probe's DELETE-TIME face, taken on the descriptor
    /// the revalidation already holds. `flock` is per open-file-description,
    /// so a second descriptor in this process conflicts exactly as another
    /// process would.
    func testRevalidatorRefusesAnEntryThatIsLockedAgainAtDeleteTime()
        async throws {
        let entry = try makeStaleCandidate("relocked", under: sharedRootURL)
        let scanner = makeScanner(roots: [sharedRoot()])
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["relocked"])

        let held = open(canonical(entry).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(held, 0)
        defer { close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0,
                       "the fixture must actually take the advisory lock")

        guard case .refuse(let reason, let valuables, let token) =
                try XCTUnwrap(scanner.preDeleteRevalidator)
                    .revalidate(item: item, authorization: nil)
        else { return XCTFail("a re-locked entry must be refused") }
        XCTAssertTrue(reason.contains("locked by a running process"), reason)
        XCTAssertTrue(valuables.isEmpty, "temp has no valuables model")
        XCTAssertNil(token, "a temp refusal is cleared by re-scanning, never "
                            + "by acknowledging")
    }

    /// The ownership gate's delete-time face, read from the HELD DESCRIPTOR's
    /// `st_uid` (injected — a real foreign-owned entry needs a second uid).
    /// Scoped by the DECLARED root writability exactly as the scan scopes it:
    /// gated under the world-writable root, vacuous under the 0700 per-user
    /// container.
    func testRevalidatorOwnershipGateFollowsTheDeclaredRootWritability()
        async throws {
        let foreign = geteuid() &+ 1

        let shared = try makeStaleCandidate("gated", under: sharedRootURL)
        let sharedProvider = DescriptorOwnerInjectingProvider()
        let sharedScanner = makeScanner(
            roots: [sharedRoot()], provider: sharedProvider
        )
        let sharedScanned = itemsByName(await scan(sharedScanner))
        let sharedItem = try XCTUnwrap(sharedScanned["gated"])
        sharedProvider.uid = foreign
        guard case .refuse(let reason, _, _) =
                try XCTUnwrap(sharedScanner.preDeleteRevalidator)
                    .revalidate(item: sharedItem, authorization: nil)
        else {
            return XCTFail("a foreign-owned entry under a world-writable root "
                            + "must be refused")
        }
        XCTAssertTrue(reason.contains("no longer belongs to you"), reason)
        _ = shared

        let user = try makeStaleCandidate("ungated", under: userRootURL)
        let userProvider = DescriptorOwnerInjectingProvider()
        let userScanner = makeScanner(roots: [userRoot()], provider: userProvider)
        let userScanned = itemsByName(await scan(userScanner))
        let userItem = try XCTUnwrap(userScanned["ungated"])
        userProvider.uid = foreign
        let expected = try XCTUnwrap(
            FileSystemIdentityProvider().identity(of: canonical(user))
        )
        XCTAssertEqual(
            try XCTUnwrap(userScanner.preDeleteRevalidator)
                .revalidate(item: userItem, authorization: nil),
            .allow(inspected: .directory(expected)),
            "the per-user container is 0700 by declaration — no gate applies"
        )
    }

    /// THE SCAN RECORDS THE OBJECT, NOT ONLY THE NAME (PR #459 review r2) —
    /// every emitted item carries the (device, inode) the scan's post-sizing
    /// `lstat` saw, which is what the delete-time re-check proves against.
    func testEmittedItemsCarryTheScannedTargetIdentity() async throws {
        let entry = try makeStaleCandidate("identified", under: sharedRootURL)
        let scanner = makeScanner(roots: [sharedRoot()])
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["identified"])

        XCTAssertEqual(
            item.scannedTargetIdentity,
            FileSystemIdentityProvider().identity(of: canonical(entry)),
            "the recorded identity is the object the scan inspected — pinned "
                + "to stage 1's observation (r4), not merely the post-sizing "
                + "lstat's, so a same-kind swap during sizing can never make "
                + "this value name an object the report did not size"
        )
    }

    /// THE IDENTITY PIN (PR #459 review r4, codex C1 — DELETION-SAFETY).
    /// Before the pin, the recorded identity was the POST-sizing `lstat`'s
    /// observation: a same-kind swap landing between stage 1 and that read
    /// emitted an item quoting the SIZED object's bytes while
    /// `scannedTargetIdentity` named the REPLACEMENT — so the delete-time
    /// identity re-check passed vacuously and `.allow`ed an object the scan
    /// never sized. This cell performs exactly that swap (real sizing, then
    /// two renames putting a different old, unlocked, user-owned directory at
    /// the name) and requires the SILENT-SKIP contract: no item, no issue —
    /// nothing the scan gated stands at the name any more.
    func testASameKindSwapAfterSizingIsSilentlySkippedNotEmitted() async throws {
        let entry = try makeStaleCandidate(
            "scratch", under: sharedRootURL, bytes: 65_536
        )
        let originalIdentity = try XCTUnwrap(
            FileSystemIdentityProvider().identity(of: canonical(entry))
        )
        // The replacement: old, unlocked, user-owned, 8 KiB — it passes every
        // PROPERTY gate this scanner has, which is the point: only the
        // identity pin can tell it apart from the sized object.
        let replacementSource = base.appendingPathComponent("replacement-src")
        try mkdir(replacementSource)
        try writeFile(replacementSource.appendingPathComponent("other.bin"),
                      bytes: 8_192)
        try backdate(replacementSource, to: oldDate)
        let aside = base.appendingPathComponent("swapped-aside")

        let scanner = makeScanner(
            roots: [sharedRoot()],
            candidateSizer: { url, mode in
                let report = DirectorySizer().measure(at: url, mode: mode)
                if url.lastPathComponent == "scratch" {
                    // The swap, the instant sizing returns: the original
                    // aside, the replacement onto the scanned name.
                    try? FileManager.default.moveItem(at: url, to: aside)
                    try? FileManager.default.moveItem(
                        at: replacementSource, to: url
                    )
                }
                return report
            }
        )

        let outcome = await scan(scanner)
        XCTAssertNil(
            itemsByName(outcome)["scratch"],
            "a swapped candidate must be silently skipped, never emitted "
                + "with the sized object's bytes and the replacement's "
                + "identity: \(outcome.items)"
        )
        XCTAssertTrue(outcome.errors.isEmpty,
                      "the silent-skip contract: no issue either — "
                          + "\(outcome.errors)")
        // The fixture really swapped: a DIFFERENT object stands at the name.
        XCTAssertNotEqual(
            FileSystemIdentityProvider().identity(of: canonical(entry)),
            originalIdentity,
            "the replacement must stand at the scanned name for this cell "
                + "to prove anything"
        )
    }

    /// FAIL CLOSED on an item that records no identity: an identity the
    /// re-check cannot compare is one it cannot prove, so it refuses rather
    /// than falling back to "the four property gates said yes".
    func testRevalidatorRefusesATempItemThatRecordsNoScannedIdentity() throws {
        let entry = sharedRootURL.appendingPathComponent("unrecorded")
        try FileManager.default.createDirectory(
            at: entry, withIntermediateDirectories: true
        )
        let scanner = makeScanner(roots: [sharedRoot()])
        let item = ReclaimableItem(
            id: "unrecorded",
            scannerID: EphemeralTempScanner.registeredID,
            displayName: "unrecorded",
            exactBytes: 8_192,
            estimatedUpToBytes: 0,
            logicalBytes: nil,
            itemCount: 1,
            url: entry,
            declaredDisplayPath: entry.path,
            rootRecords: [RootScanRecord(
                requestedURL: entry, resolvedURL: entry, status: .measured
            )],
            state: .measured,
            scanError: nil,
            risk: .review,
            evidence: "fixture",
            rebuildNote: nil,
            action: .removeItem,
            admission: .containerItem(
                originContainer: canonical(sharedRootURL),
                requestedTargetURL: entry
            ),
            defaultSelected: false,
            automaticCleanEligible: false,
            isStale: true,
            requiresPreDeleteRevalidation: true,
            scannedTargetIdentity: nil
        )

        guard case .refuse(let reason, _, _) =
                try XCTUnwrap(scanner.preDeleteRevalidator)
                    .revalidate(item: item, authorization: nil)
        else { return XCTFail("an unrecorded identity must be refused") }
        XCTAssertTrue(reason.contains("no record of the object the scan "
                                       + "inspected"), reason)
    }

    /// AVAILABILITY, PROVEN THROUGH PRODUCTION (PR #459 review r2).
    ///
    /// The delete-time open cannot carry `O_DIRECTORY` — a regular-file
    /// candidate must open too — so it is the FIFO driver's `open` that runs
    /// when a named pipe stands at a scanned name, and without `O_NONBLOCK`
    /// that call never returns until a writer arrives. `CacheCleaner` is an
    /// `actor` and calls `revalidate` synchronously, so a block here wedges
    /// the clean and every later message to that actor, with no timeout
    /// anywhere. `/private/tmp` is world-writable, so any user can plant one.
    ///
    /// The verdict is taken on a DETACHED THREAD behind a bounded wait: a
    /// regression fails this cell in 5s instead of hanging the whole suite.
    /// Measured on this platform with the exact flag set: without
    /// `O_NONBLOCK` the open did not return in 3s; with it, it returns and
    /// `fstat` reports `S_IFIFO`, which the kind gate refuses.
    func testRevalidatorReturnsAndRefusesAFIFOStandingAtAScannedName()
        async throws {
        let entry = try makeStaleCandidate("fifo-swap", under: sharedRootURL)
        let scanner = makeScanner(roots: [sharedRoot()])
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["fifo-swap"])

        try fm.removeItem(at: entry)
        XCTAssertEqual(mkfifo(entry.path, 0o600), 0,
                       "the fixture must actually stage a named pipe")
        defer { try? fm.removeItem(at: entry) }

        let revalidator = try XCTUnwrap(scanner.preDeleteRevalidator)
        let box = VerdictBox()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.value = revalidator.revalidate(item: item, authorization: nil)
            finished.signal()
        }

        XCTAssertEqual(
            finished.wait(timeout: .now() + 5), .success,
            "the delete-time re-check must RETURN on a FIFO — a blocking open "
                + "wedges the cleaner actor for the life of the process"
        )
        guard case .refuse(let reason, _, _) = try XCTUnwrap(box.value) else {
            return XCTFail("a special file at a scanned name must be refused")
        }
        XCTAssertTrue(reason.contains("no longer the kind of object"), reason)
    }

    /// F7 (PR #459 review r3): the delete-time fresh-content walk must judge
    /// on the errno its OWN open returned, not on whatever the global `errno`
    /// happens to hold.
    ///
    /// 8f513d5 swapped `openChildDirectory` + a read of the global `errno` for
    /// `openChildDirectoryCarryingErrno` in `freshContentBelow` and shipped
    /// with nothing behind it — reverting exactly that hunk left
    /// `EphemeralTemp|CacheCleanerTests` at 194 executed / 0 failures.
    ///
    /// What the swap protects is not a message. In THIS walk ENOENT/ENOTDIR is
    /// a benign vanished branch that is skipped and every other code makes the
    /// verdict `.unprovable`, i.e. a REFUSAL — so a stale `errno` reading
    /// ENOENT converts a refusal into an ALLOW, and the removal proceeds over
    /// a subtree the walk could not read.
    func testDeleteTimeWalkJudgesOnTheErrnoItsOwnOpenReturned() async throws {
        let entry = try makeStaleCandidate("errno-walk", under: sharedRootURL)
        let branch = try mkdir(entry.appendingPathComponent("branch"))
        try writeFile(branch.appendingPathComponent("old.bin"))
        try backdate(entry, to: oldDate)

        let provider = ErrnoClobberingProvider()
        provider.failingChild = "branch"
        let scanner = makeScanner(roots: [sharedRoot()], provider: provider)
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["errno-walk"])

        let verdict = try XCTUnwrap(scanner.preDeleteRevalidator)
            .revalidate(item: item, authorization: nil)
        guard case .refuse(let reason, _, _) = verdict else {
            return XCTFail(
                "a subtree whose open failed EACCES cannot be proven old, and "
                    + "an unprovable walk must refuse — got \(verdict)"
            )
        }
        XCTAssertTrue(reason.contains("could not be fully re-inspected"),
                      reason)
        XCTAssertTrue(reason.contains("Permission denied"),
                      "the reason quotes the code the open ACTUALLY returned, "
                        + "not the clobbered global one: \(reason)")
        XCTAssertTrue(fm.fileExists(atPath: entry.path),
                      "and nothing was deleted")
    }

    /// A vanished entry cannot be re-inspected, so it is refused rather than
    /// allowed on a verdict about nothing.
    func testRevalidatorRefusesAnEntryThatVanishedBeforeDeletion() async throws {
        let entry = try makeStaleCandidate("gone", under: sharedRootURL)
        let scanner = makeScanner(roots: [sharedRoot()])
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["gone"])
        try fm.removeItem(at: entry)

        guard case .refuse(let reason, _, _) =
                try XCTUnwrap(scanner.preDeleteRevalidator)
                    .revalidate(item: item, authorization: nil)
        else { return XCTFail("an absent entry must be refused") }
        XCTAssertTrue(reason.contains("could not be re-opened"), reason)
    }

    // MARK: - Depth is not a resource in the delete-time walk
    // (PR #459 codex r14 — AVAILABILITY)

    /// A chain of `levels` directories built with `mkdirat` against a held
    /// descriptor, two descriptors at a time, then dated deepest-first by
    /// `futimens` on the descriptors it already holds. `backdate` cannot do
    /// this job: it recurses once per level through `contentsOfDirectory`,
    /// and the whole point of these fixtures is depth.
    private func makeDeepStaleChain(
        _ name: String, under root: URL, levels: Int
    ) throws -> URL {
        let entry = try mkdir(root.appendingPathComponent(name))
        try writeFile(entry.appendingPathComponent("payload.bin"))

        var open: [Int32] = []
        defer { for fd in open { close(fd) } }
        var current = entry.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard current >= 0 else { throw XCTSkip("open: \(errno)") }
        open.append(current)
        for _ in 0..<levels {
            guard mkdirat(current, "d", 0o755) == 0 else {
                throw XCTSkip("mkdirat: \(errno)")
            }
            let next = openat(current, "d", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard next >= 0 else { throw XCTSkip("openat: \(errno)") }
            open.append(next)
            current = next
        }
        let stamp = timespec(
            tv_sec: Int(oldDate.timeIntervalSince1970), tv_nsec: 0
        )
        var times = [stamp, stamp]
        guard utimensat(try XCTUnwrapElement(open, 0), "payload.bin", &times, 0) == 0 else {
            throw XCTSkip("utimensat: \(errno)")
        }
        for fd in open.reversed() {
            guard futimens(fd, &times) == 0 else {
                throw XCTSkip("futimens: \(errno)")
            }
        }
        return entry
    }

    /// THE ASYMMETRY, both halves in one cell: the scan LISTS a deep-but-valid
    /// stale tree, and the delete-time re-inspection of the very same tree
    /// must then be able to take it.
    ///
    /// Before the iterative rewrite this walk recursed, one stack frame and
    /// one open descriptor per level. Measured through this exact production
    /// path on the cooperative executor `CacheCleaner`'s actor runs on: depth
    /// 240 allowed, depth 260 died `EXC_BAD_ACCESS (code=2, address=
    /// 0x16fe8fe50)` with `sp` at `0x16fe8fe70` — a guard-page hit 32 bytes
    /// below the stack pointer, ~250 frames of `freshContentBelow` deep. Not
    /// a refusal the user could act on; a crash.
    ///
    /// The scan side has no such wall: `walkForFreshContent` is iterative over
    /// a `[URL]` stack and charges one entry of 20,000 per directory.
    func testRevalidatorAllowsADeepStaleTreeTheScanListed() async throws {
        let entry = try makeDeepStaleChain(
            "deep-stale", under: sharedRootURL, levels: 320
        )
        let scanner = makeScanner(roots: [sharedRoot()])
        let outcome = await scan(scanner)
        let item = try XCTUnwrap(
            itemsByName(outcome)["deep-stale"],
            "fixture precondition: the SCAN must list this tree — without "
                + "that there is no asymmetry to close. errors="
                + "\(outcome.errors.map(\.detail))"
        )

        let expected = try XCTUnwrap(
            FileSystemIdentityProvider().identity(of: canonical(entry))
        )
        XCTAssertEqual(
            try XCTUnwrap(scanner.preDeleteRevalidator)
                .revalidate(item: item, authorization: nil),
            .allow(inspected: .directory(expected)),
            "a deep tree the scan offered must be cleanable, not permanently "
                + "refused"
        )
    }

    /// COUNTS the descriptors the process holds, once per descent, so `peak`
    /// ends up the walk's own high-water mark.
    ///
    /// `openChildDirectoryCarryingErrno` is the walk's ONLY descent, so
    /// `descents` is also an honest count of levels actually entered: a
    /// regression that stopped early would post a small delta for the wrong
    /// reason, and the cells below pin the count to rule that out.
    private final class DescriptorFrontierProbe: FileSystemIdentityProvider,
        @unchecked Sendable {
        var sampling = false
        private(set) var peak = -1
        private(set) var descents = 0
        private(set) var overflowed = false

        /// COUNTING, not the lowest-free-descriptor trick that reads like the
        /// cheap way to do this. `open("/dev/null")` hands back the lowest
        /// FREE number, which is a HOLE whenever the process has closed
        /// something below its high-water mark — so the difference of two such
        /// probes reports the hole, not the walk. Measured: that spelling read
        /// a cost of 38 for this walk in a full suite and 2 alone, and the
        /// walk was identical in both. Counting is immune to holes because it
        /// counts what is actually held.
        ///
        /// `nil` rather than a short count if anything sits at the top of the
        /// window, so the measurement can never silently under-report. The
        /// window is ~10x the most this process is known to hold (~104 at rest
        /// plus the walk's own), and 4096 `fcntl`s take tens of microseconds.
        static let window: Int32 = 4096
        static func heldDescriptors() -> Int? {
            var count = 0
            var highest: Int32 = -1
            for fd in Int32(0)..<window where fcntl(fd, F_GETFD) != -1 {
                count += 1
                highest = fd
            }
            return highest >= window - 1 ? nil : count
        }

        /// The HIGHEST number in use. `RLIMIT_NOFILE` caps the fd NUMBER the
        /// kernel will hand out, not the count, so a limit derived from a
        /// count would be below descriptors the process already holds the
        /// moment there is a hole. `nil` on the same overflow guard.
        static func highestDescriptor() -> Int32? {
            var highest: Int32 = -1
            for fd in Int32(0)..<window where fcntl(fd, F_GETFD) != -1 {
                highest = fd
            }
            return highest >= window - 1 ? nil : highest
        }

        override func openChildDirectoryCarryingErrno(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> DescriptorOpen {
            if sampling {
                descents += 1
                if let held = DescriptorFrontierProbe.heldDescriptors() {
                    peak = max(peak, held)
                } else {
                    overflowed = true
                }
            }
            return super.openChildDirectoryCarryingErrno(
                inDirectory: descriptor, named: name, logical: logical()
            )
        }
    }

    /// THE PROPERTY, MEASURED DIRECTLY: the walk's descriptor cost is CONSTANT
    /// IN DEPTH. Forty times the depth must not buy a single extra descriptor.
    ///
    /// Measured through this exact production path, peak minus baseline:
    ///
    ///     levels:            8      320
    ///     iterative (here):  2        2
    ///     recursive (HEAD):  8      200 (at 320 it dies on the guard page)
    ///
    /// Under the recursion the delta WAS the depth, exactly. Under the climb
    /// it is 2 at both — the level the walk stands on, plus the one the probe
    /// itself holds for the instant it counts.
    ///
    /// WHY THIS CANNOT GO LOAD-SENSITIVE, which the `rlim_cur = 96` spelling
    /// it replaces could and did (PR #459 codex r14): the number asserted on
    /// is a DELTA between two counts of THIS process's own held descriptors,
    /// so whatever the rest of the suite is holding cancels. Measured both
    /// ways on the same build:
    ///
    ///     alone:       baseline   3, peak   5, delta 2 (both depths)
    ///     full suite:  baseline 105, peak 107, delta 2 (both depths)
    ///
    /// A baseline 102 higher, the same answer. The spelling this replaces
    /// compared the walk against an ABSOLUTE process-wide `rlim_cur` of 96,
    /// and by the time this class runs in a full suite the process already
    /// holds ~104 descriptors (104/110/104 across three runs) — MORE than the
    /// limit it set, so the walk's very first `openat` took EMFILE. It passed
    /// alone and failed in the suite.
    ///
    /// The bound is slack by 8x over the measured cost and still an order of
    /// magnitude under the recursion's. It catches any RETENTION PER LEVEL
    /// from about one descriptor per 40 levels upward; it would not catch a
    /// constant-factor rise below that, which is not the defect this closes.
    func testDeleteTimeWalkDescriptorCostDoesNotGrowWithDepth() async throws {
        func peakDescriptorsHeld(
            _ name: String, levels: Int
        ) async throws -> Int {
            try makeDeepStaleChain(name, under: sharedRootURL, levels: levels)
            let probe = DescriptorFrontierProbe()
            let scanner = makeScanner(roots: [sharedRoot()], provider: probe)
            let outcome = await scan(scanner)
            let item = try XCTUnwrap(
                itemsByName(outcome)[name],
                "fixture precondition: the SCAN must list this tree. errors="
                    + "\(outcome.errors.map(\.detail))"
            )
            let baseline = try XCTUnwrap(
                DescriptorFrontierProbe.heldDescriptors(),
                "the process holds descriptors past the probe's window"
            )

            probe.sampling = true
            let verdict = try XCTUnwrap(scanner.preDeleteRevalidator)
                .revalidate(item: item, authorization: nil)
            probe.sampling = false
            XCTAssertFalse(
                probe.overflowed,
                "a sample ran past the probe's window and was discarded"
            )

            guard case .allow = verdict else {
                XCTFail("\(levels) levels must stay provable — got \(verdict)")
                return -1
            }
            XCTAssertEqual(
                probe.descents, levels,
                "the walk must actually have entered every level — a delta "
                    + "measured over a walk that stopped early proves nothing"
            )
            return probe.peak - baseline
        }

        let shallowLevels = 8
        let deepLevels = 320
        let shallow = try await peakDescriptorsHeld(
            "fd-shallow", levels: shallowLevels
        )
        let deep = try await peakDescriptorsHeld(
            "fd-deep", levels: deepLevels
        )

        XCTAssertLessThanOrEqual(
            deep, shallow + 8,
            "descriptor cost must not grow with depth: \(shallowLevels) "
                + "levels cost \(shallow), \(deepLevels) levels cost \(deep)"
        )
        XCTAssertLessThanOrEqual(
            deep, 16,
            "\(deepLevels) levels must cost a constant number of "
                + "descriptors, not \(deep)"
        )
    }

    /// The same bound end-to-end, through the refusal a user would actually
    /// have seen — the twin of
    /// `DepthSafeRemovalTests.testRemovesADeepTreeUnderALoweredDescriptorLimit`
    /// on the INSPECTION side.
    ///
    /// Measured at HEAD before this fix, through this production path: depth
    /// 88 allowed and depth 96 refused "…could not be fully re-inspected at
    /// delete time (Too many open files) … re-scan required". Deterministic —
    /// the re-scan the sentence prescribes re-offers the identical tree and
    /// the identical refusal follows, for ever. A launchd-spawned app on this
    /// platform sees `rlim_cur = 256`, which moves that wall without removing
    /// it.
    ///
    /// THE BUDGET IS DERIVED, NEVER ABSOLUTE. `rlim_cur` is process-wide and
    /// this suite shares one process, so a hardcoded number is a number
    /// relative to whatever the preceding thousand cells happen to be holding
    /// — which is how the r14 spelling of this cell passed alone and failed in
    /// the suite. Anchoring to the live frontier grants the walk exactly 64
    /// descriptors of headroom no matter what else is open: 16x the 4 it
    /// needs, and a fifth of the 320 the recursion needed.
    func testRevalidatorAllowsADeepStaleTreeUnderAConstrainedDescriptorLimit()
        async throws {
        try makeDeepStaleChain("fd-bound", under: sharedRootURL, levels: 320)
        let scanner = makeScanner(roots: [sharedRoot()])
        let outcome = await scan(scanner)
        let item = try XCTUnwrap(
            itemsByName(outcome)["fd-bound"],
            "fixture precondition: the scan must list this tree. errors="
                + "\(outcome.errors.map(\.detail))"
        )

        var original = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &original) == 0 else {
            throw XCTSkip("getrlimit failed")
        }
        let highest = try XCTUnwrap(
            DescriptorFrontierProbe.highestDescriptor(),
            "the process holds descriptors past the probe's window"
        )
        var lowered = original
        // Anchored ABOVE every number already in use, so this never lowers the
        // limit under the process's own live usage — it only bounds what the
        // walk may add.
        lowered.rlim_cur = rlim_t(highest + 1) + 64
        guard lowered.rlim_cur < original.rlim_cur else {
            throw XCTSkip("ambient limit already tighter than the probe")
        }
        guard setrlimit(RLIMIT_NOFILE, &lowered) == 0 else {
            throw XCTSkip("setrlimit failed: \(errno)")
        }
        // `defer`, not a trailing call: an `XCTUnwrap` that throws past a
        // trailing restore would leave the WHOLE REMAINING SUITE running at
        // the lowered limit. The r14 spelling of this cell had that hazard.
        defer { setrlimit(RLIMIT_NOFILE, &original) }

        let verdict = try XCTUnwrap(scanner.preDeleteRevalidator)
            .revalidate(item: item, authorization: nil)
        guard case .allow = verdict else {
            return XCTFail(
                "320 levels with 64 descriptors of headroom must still be "
                    + "provable — got \(verdict)"
            )
        }
    }

    /// THE PROOF THE CLIMB BUYS ITS BOUND WITH. Closing the parent on the way
    /// down means the way back up is an `openat(current, "..")` — a LOOKUP,
    /// not a proof. A directory renamed into a foreign parent while the walk
    /// stood inside it makes `..` name THAT parent, and the rest of the
    /// level's names would be read out of somebody else's tree; the identity
    /// the walk recorded before it descended is what refuses instead.
    ///
    /// The rename is REAL, fired by the kernel at the exact instant the walk
    /// is standing in the moved directory (the last probe it makes before it
    /// climbs), single-threaded, with no sleeps. The refusal is CLEARABLE: a
    /// rename is a race, so the re-scan the sentence prescribes genuinely can
    /// differ.
    func testDeleteTimeWalkRefusesWhenTheLevelItStandsInIsMovedAway()
        async throws {
        let entry = try mkdir(sharedRootURL.appendingPathComponent("moved"))
        let inner = try mkdir(entry.appendingPathComponent("a"))
        try writeFile(inner.appendingPathComponent("old.bin"))
        // Sorts after "a", so the walk descends into "a" first and this is
        // still an unvisited sibling when the refusal lands.
        try mkdir(entry.appendingPathComponent("elsewhere"))
        try backdate(entry, to: oldDate)

        /// Renames `from` into `into` the first time the walk probes `trigger`.
        final class RenamingProvider: FileSystemIdentityProvider,
            @unchecked Sendable {
            var trigger = ""
            var from: URL?
            var into: URL?
            private(set) var fired = false

            override func probeKind(
                inDirectory parent: Int32, named name: String, logical url: URL
            ) -> DescriptorKindProbe {
                if name == trigger, !fired, let from, let into {
                    fired = true
                    _ = rename(from.path, into.path)
                }
                return super.probeKind(
                    inDirectory: parent, named: name, logical: url
                )
            }
        }
        let provider = RenamingProvider()
        let scanner = makeScanner(roots: [sharedRoot()], provider: provider)
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["moved"])

        // Armed only for the DELETE-time walk: the scan above must see the
        // tree in one piece.
        provider.trigger = "old.bin"
        provider.from = canonical(entry).appendingPathComponent("a")
        provider.into = canonical(entry)
            .appendingPathComponent("elsewhere")
            .appendingPathComponent("a")

        let verdict = try XCTUnwrap(scanner.preDeleteRevalidator)
            .revalidate(item: item, authorization: nil)
        XCTAssertTrue(provider.fired, "the fixture never fired its rename")
        guard case .refuse(let reason, _, _) = verdict else {
            return XCTFail(
                "a level whose `..` no longer names the parent it was entered "
                    + "from cannot be proven old — got \(verdict)"
            )
        }
        XCTAssertTrue(
            reason.contains("a was moved while its contents were being "
                            + "re-inspected"),
            reason
        )
    }

    // MARK: - The size floor is a delete-time fact for BOTH kinds
    // (PR #459 review r4, codex C4 — DISCLOSURE)

    /// A DIRECTORY whose nested payload vanished after the scan no longer
    /// QUALIFIES for listing at all, and proceeding would execute an offer
    /// the scanner would refuse to make — while the row still quoted the
    /// scanned bytes at the moment of consent. Removing a NESTED file bumps
    /// only its immediate parent's mtime (measured: unlink of X/a/b/payload
    /// left X and X/a untouched), so no other gate catches this drift: at
    /// HEAD before this fix, exactly this fixture revalidated
    /// `.allow(inspected: .directory(_))` with the tree at 0 payload bytes
    /// against a 4,096-byte floor.
    func testRevalidatorRefusesADirectoryShrunkBelowTheFloor() async throws {
        let entry = try mkdir(sharedRootURL.appendingPathComponent("shrunk"))
        let nested = try mkdir(
            entry.appendingPathComponent("a").appendingPathComponent("b")
        )
        let payload = try writeFile(
            nested.appendingPathComponent("payload.bin"), bytes: 65_536
        )
        try backdate(entry, to: oldDate)

        let scanner = makeScanner(roots: [sharedRoot()])
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["shrunk"])
        XCTAssertGreaterThanOrEqual(item.allocatedBytes, 65_536)

        try fm.removeItem(at: payload)

        guard case .refuse(let reason, _, _) =
                try XCTUnwrap(scanner.preDeleteRevalidator)
                    .revalidate(item: item, authorization: nil)
        else {
            return XCTFail("a below-floor directory must be refused")
        }
        XCTAssertTrue(reason.contains("shrunk below the size threshold"),
                      reason)
    }

    /// The FILE arm's floor guard, evidenced for the first time (house
    /// failure mode #1: at HEAD this guard's refusal string appeared nowhere
    /// under Tests/, and deleting it left every existing cell green). The
    /// mtime is re-backdated after the truncation so the floor guard — not
    /// the staleness gate — is what this cell exercises.
    func testRevalidatorRefusesARegularFileShrunkBelowTheFloor() async throws {
        let entry = try writeFile(
            sharedRootURL.appendingPathComponent("shrinking.bin"),
            bytes: 65_536
        )
        try setDate(entry, oldDate)
        let scanner = makeScanner(roots: [sharedRoot()])
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["shrinking.bin"])

        try Data().write(to: entry)  // truncate to 0 (bumps mtime)
        try setDate(entry, oldDate)  // isolate the floor from the age gate

        guard case .refuse(let reason, _, _) =
                try XCTUnwrap(scanner.preDeleteRevalidator)
                    .revalidate(item: item, authorization: nil)
        else {
            return XCTFail("a below-floor file must be refused")
        }
        XCTAssertTrue(reason.contains("shrunk below the size threshold"),
                      reason)
    }

    /// The delete-time sum counts one inode ONCE, exactly as the scan's
    /// sizer does: two links to one 4,096-byte inode against an 8,192-byte
    /// floor are 4,096 deduped (refuse) but 8,192 per-link (allow) — so a
    /// per-link sum flips this cell's verdict and goes RED.
    func testRevalidatorFloorDedupesHardlinksInItsDeleteTimeSum() async throws {
        let floor8k = EphemeralTempSweepConfig.Thresholds(
            sizeFloorBytes: 8_192, staleAge: 7 * 86_400
        )
        let entry = try mkdir(sharedRootURL.appendingPathComponent("linked"))
        let nested = try mkdir(
            entry.appendingPathComponent("a").appendingPathComponent("b")
        )
        let payload = try writeFile(
            nested.appendingPathComponent("payload.bin"), bytes: 65_536
        )
        let sub = try mkdir(entry.appendingPathComponent("sub"))
        let linkA = sub.appendingPathComponent("hl-a.bin")
        try Data(repeating: 0xCD, count: 4_096).write(to: linkA)
        try fm.linkItem(at: linkA, to: sub.appendingPathComponent("hl-b.bin"))
        try backdate(entry, to: oldDate)

        let scanner = makeScanner(roots: [sharedRoot()], thresholds: floor8k)
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["linked"])

        // The nested payload goes; only the hardlink pair remains below.
        try fm.removeItem(at: payload)

        guard case .refuse(let reason, _, _) =
                try XCTUnwrap(scanner.preDeleteRevalidator)
                    .revalidate(item: item, authorization: nil)
        else {
            return XCTFail(
                "4,096 deduped bytes are below the 8,192 floor — a per-link "
                    + "sum (8,192) is the mutation this cell exists to catch"
            )
        }
        XCTAssertTrue(reason.contains("shrunk below the size threshold"),
                      reason)
    }
}

/// A one-slot box so a verdict taken on a detached thread can be read back
/// after a bounded wait. `@unchecked Sendable` is sound here because the
/// semaphore establishes the happens-before edge: the writer signals only
/// after the store, and the reader loads only after a successful wait.
private final class VerdictBox: @unchecked Sendable {
    var value: PreDeleteVerdict?
}

/// The same one-slot box for a whole `ScanOutcome` taken on a detached task
/// and read back after a bounded wait. Sound for the same reason: the
/// semaphore is the happens-before edge.
private final class OutcomeBox: @unchecked Sendable {
    var value: ScanOutcome?
}

// MARK: - Mount boundaries: refuse WITHOUT descending (PR #459 codex r5, C2)
//
// AVAILABILITY class. Before these arms, the prefilter walk descended a
// mounted volume (measured on a real 22,545-entry `hdiutil` mount: 19,545
// `probeKind` lstats + 19,500 second lstats strictly below the boundary),
// the first foreign-touching syscall for a mount-at-candidate was stage 1's
// own `lstat` — first contact a dead volume turns into a permanent scan
// wedge — and mount VISIBILITY was population-dependent (visible-denied at
// 303 stale foreign entries, silently absent at 22,545 or behind one fresh
// file). The arms decide from the kernel table (`mountPointPaths`, no
// filesystem contact) and from the stage-1 device already in hand, and the
// terminal state is ONE deterministic row: `.denied`, zero components, a
// message that names the unmount remedy (a mount refusal is CLEARABLE —
// never a deterministic strand).
extension EphemeralTempScannerTests {

    /// Injects a mount table (or passes the REAL kernel table through) and
    /// counts every path-based read, so "nothing touched the volume" is an
    /// assertion rather than a hope.
    private final class MountTableInjectingProvider: FileSystemIdentityProvider,
        @unchecked Sendable {
        private let lock = NSLock()
        var injectedMountPoints: [String] = []
        /// `true` = production default (the real `getfsstat` table): the
        /// integration cell's evidence that the DEFAULT harvest sees a real
        /// volume — injecting past the seam would not evidence it.
        var useRealTable = false
        /// Paths whose leaf metadata reports a FOREIGN device (the racing
        /// mount the table missed — hermetic stand-in).
        var foreignDevicePaths: Set<String> = []
        private(set) var probedPaths: [String] = []
        private(set) var leafReadPaths: [String] = []

        override func mountPointPaths() -> [String] {
            useRealTable ? super.mountPointPaths() : injectedMountPoints
        }

        override func probeKind(of url: URL) -> KindProbe {
            lock.lock(); probedPaths.append(url.path); lock.unlock()
            return super.probeKind(of: url)
        }

        override func leafMetadata(of url: URL) -> LeafMetadata? {
            lock.lock(); leafReadPaths.append(url.path); lock.unlock()
            guard let real = super.leafMetadata(of: url) else { return nil }
            guard foreignDevicePaths.contains(url.path) else { return real }
            return LeafMetadata(
                device: real.device &+ 1, inode: real.inode,
                allocatedBytes: real.allocatedBytes,
                modifiedSeconds: real.modifiedSeconds,
                modifiedNanoseconds: real.modifiedNanoseconds
            )
        }

        /// Every recorded read at `path` or strictly below it.
        func reads(atOrBelow path: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return (probedPaths + leafReadPaths).filter {
                $0 == path || $0.hasPrefix(prefix)
            }
        }
    }

    /// Thread-safe record of every lock-probe call — the mount arms must
    /// refuse BEFORE the candidate is opened for the in-use check.
    private final class LockProbeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [URL] = []
        func record(_ url: URL) {
            lock.lock(); urls.append(url); lock.unlock()
        }
    }

    private func assertMountRow(
        _ item: ReclaimableItem, messageContains fragment: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(item.state, .denied, file: file, line: line)
        XCTAssertEqual(item.exactBytes, 0, file: file, line: line)
        XCTAssertEqual(item.estimatedUpToBytes, 0, file: file, line: line)
        XCTAssertEqual(item.itemCount, 0, file: file, line: line)
        XCTAssertNil(item.isStale,
                     "a mount row proves no staleness and must never join "
                        + "Select Stale", file: file, line: line)
        let message = item.scanError?.message ?? ""
        XCTAssertTrue(message.contains(fragment), message,
                      file: file, line: line)
        // The deterministic-bound rule: the refusal names the act that
        // clears it, verbatim.
        XCTAssertTrue(message.contains(EphemeralTempScanner.mountRemedy),
                      message, file: file, line: line)
    }

    /// ARM 1 (the kernel-table arm): a first-level candidate the mount table
    /// names is refused visible with ZERO syscalls at or below it — the
    /// stall-avoidance property: a dead volume is never contacted at all.
    func testAMountPointCandidateIsRefusedVisiblyWithoutTouchingIt()
        async throws {
        try makeStaleCandidate("volmount", under: sharedRootURL)
        let candidatePath = entryPath("volmount", under: sharedRootURL)

        let provider = MountTableInjectingProvider()
        provider.injectedMountPoints = [candidatePath]
        let locks = LockProbeRecorder()
        let sizing = SizingSpy(provider: provider)
        let scanner = makeScanner(
            roots: [sharedRoot()], provider: provider,
            lockProbe: { url in
                locks.record(url)
                return EphemeralTempScanner.cooperativeLockProbe(url)
            },
            candidateSizer: { sizing.measure($0, $1) }
        )

        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(itemsByName(outcome)["volmount"])
        assertMountRow(item, messageContains: "entry is a mount point")
        XCTAssertEqual(
            provider.reads(atOrBelow: candidatePath), [],
            "the mount point was contacted — the table arm exists so a dead "
                + "volume is refused without ONE syscall touching it"
        )
        XCTAssertTrue(locks.urls.isEmpty, "\(locks.urls)")
        XCTAssertTrue(sizing.calls.isEmpty, "\(sizing.calls.map(\.url.path))")
    }

    /// ARM 2 (the racing-mount arm): a candidate whose stage-1 device is not
    /// the root's — a mount the table missed — is the same denied row, with
    /// no walk below it, no lock probe and no sizing.
    func testACandidateOnAForeignDeviceIsRefusedWithoutWalkLockOrSizing()
        async throws {
        try makeStaleCandidate("foreign-dev", under: sharedRootURL)
        let candidatePath = entryPath("foreign-dev", under: sharedRootURL)

        let provider = MountTableInjectingProvider()
        provider.foreignDevicePaths = [candidatePath]
        let locks = LockProbeRecorder()
        let sizing = SizingSpy(provider: provider)
        let scanner = makeScanner(
            roots: [sharedRoot()], provider: provider,
            lockProbe: { url in
                locks.record(url)
                return EphemeralTempScanner.cooperativeLockProbe(url)
            },
            candidateSizer: { sizing.measure($0, $1) }
        )

        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(itemsByName(outcome)["foreign-dev"])
        assertMountRow(item, messageContains: "entry is a mount point")
        XCTAssertEqual(provider.reads(atOrBelow: candidatePath + "/"), [],
                       "the walk descended onto the foreign device")
        XCTAssertTrue(locks.urls.isEmpty, "\(locks.urls)")
        XCTAssertTrue(sizing.calls.isEmpty, "\(sizing.calls.map(\.url.path))")
    }

    /// ARM 3 (the walk arm): a mount strictly BELOW the candidate stops the
    /// walk AT the boundary — zero reads at or below it, membership decided
    /// from the table, and the candidate terminates in the visible nested-
    /// boundary row instead of a population-dependent verdict.
    func testTheWalkStopsAtAKernelTableMountBoundary() async throws {
        let candidate = try makeStaleCandidate("scratch", under: sharedRootURL)
        let mnt = try mkdir(candidate.appendingPathComponent("mnt"))
        try writeFile(mnt.appendingPathComponent("foreign.bin"))
        try backdate(candidate, to: oldDate)
        let mntPath = canonical(sharedRootURL)
            .appendingPathComponent("scratch/mnt").path

        let provider = MountTableInjectingProvider()
        provider.injectedMountPoints = [mntPath]
        let sizing = SizingSpy(provider: provider)
        let scanner = makeScanner(
            roots: [sharedRoot()], provider: provider,
            candidateSizer: { sizing.measure($0, $1) }
        )

        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(itemsByName(outcome)["scratch"])
        assertMountRow(item, messageContains: "mount boundary at \(mntPath)")
        XCTAssertEqual(provider.reads(atOrBelow: mntPath), [],
                       "the walk crossed the boundary")
        XCTAssertTrue(sizing.calls.isEmpty,
                      "a boundary candidate must never be sized: "
                        + "\(sizing.calls.map(\.url.path))")
    }

    /// ARM 4 (the delete-time twin): the revalidator's descriptor walk holds
    /// every child's device already (`fstatat`) and refuses to descend onto
    /// another filesystem — a volume mounted in after the cleaner's own
    /// sizer gate. The refusal converges: a re-scan emits the denied mount
    /// row, so the offer disappears rather than re-arming.
    func testRevalidatorRefusesToDescendOntoAnotherFilesystem() async throws {
        let entry = try makeStaleCandidate("remounted", under: sharedRootURL)
        let nested = try mkdir(entry.appendingPathComponent("mnt"))
        try writeFile(nested.appendingPathComponent("old.bin"))
        try backdate(entry, to: oldDate)

        final class ForeignChildDeviceProvider: FileSystemIdentityProvider,
            @unchecked Sendable {
            var foreignChildName = ""
            override func probeKind(
                inDirectory parent: Int32, named name: String,
                logical url: URL
            ) -> DescriptorKindProbe {
                let real = super.probeKind(
                    inDirectory: parent, named: name, logical: url
                )
                guard name == foreignChildName,
                      case .kind(let kind, let identity, let metadata) = real
                else { return real }
                return .kind(
                    kind,
                    identity: Identity(
                        device: identity.device &+ 1, inode: identity.inode
                    ),
                    metadata: metadata
                )
            }
        }
        let provider = ForeignChildDeviceProvider()
        provider.foreignChildName = "mnt"
        let scanner = makeScanner(roots: [sharedRoot()], provider: provider)
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(
            scanned["remounted"],
            "the scan itself walks by path and lists the entry"
        )

        let verdict = try XCTUnwrap(scanner.preDeleteRevalidator)
            .revalidate(item: item, authorization: nil)
        guard case .refuse(let reason, _, _) = verdict else {
            return XCTFail("descended onto another filesystem: \(verdict)")
        }
        XCTAssertTrue(reason.contains("a volume is mounted at mnt"), reason)
    }

    /// A provider that FAILS THE TEST on any call naming the over-mounted
    /// root or anything below it while armed — "zero first contact" as an
    /// assertion on every override point rather than a hope. (`deviceID`
    /// and `kind` are final and derive from `identity`/`probeKind`, so the
    /// overrides cover them too. Arming is explicit because scanner
    /// CONSTRUCTION canonicalizes the fixture home — a recorded residual of
    /// its own, not this cell's subject.)
    private final class OverMountedRootForbiddingProvider:
        FileSystemIdentityProvider, @unchecked Sendable {
        var mountedRootPath = ""
        var armed = false

        private func forbid(_ method: String, _ url: URL) {
            guard armed else { return }
            if url.path == mountedRootPath
                || url.path.hasPrefix(mountedRootPath + "/") {
                XCTFail("\(method) made first contact with the over-mounted "
                        + "root: \(url.path)")
            }
        }

        override func mountPointPaths() -> [String] { [mountedRootPath] }
        override func probeKind(of url: URL) -> KindProbe {
            forbid("probeKind", url)
            return super.probeKind(of: url)
        }
        override func identity(of url: URL) -> Identity? {
            forbid("identity", url)
            return super.identity(of: url)
        }
        override func leafMetadata(of url: URL) -> LeafMetadata? {
            forbid("leafMetadata", url)
            return super.leafMetadata(of: url)
        }
        override func isMountPoint(_ url: URL) -> Bool {
            forbid("isMountPoint", url)
            return super.isMountPoint(url)
        }
        override func canonicalize(_ url: URL) -> URL {
            forbid("canonicalize", url)
            return super.canonicalize(url)
        }
        override func resolveTargetKeepingLeaf(_ url: URL) -> URL {
            forbid("resolveTargetKeepingLeaf", url)
            return super.resolveTargetKeepingLeaf(url)
        }
        override func ownerProbe(of url: URL) -> OwnerProbe {
            forbid("ownerProbe", url)
            return super.ownerProbe(of: url)
        }
    }

    /// THE OVER-MOUNTED-ROOT ARM, hermetic (PR #459 review r6, codex C2):
    /// a root the mount table names EXACTLY is refused as ONE visible issue
    /// naming the unmount remedy, with ZERO provider calls touching the root
    /// — before this arm, the root gate's own `lstat` was the scan's first
    /// contact with the mounted filesystem, made with the root's mount entry
    /// already sitting unread in the snapshot in hand. The table is injected
    /// here; the production-default table over a real volume is evidenced by
    /// the real-mount cell below.
    func testAnOverMountedRootIsRefusedVisiblyWithZeroContact() async throws {
        try makeStaleCandidate("survivor", under: userRootURL)

        let provider = OverMountedRootForbiddingProvider()
        provider.mountedRootPath = canonical(sharedRootURL).path
        let scanner = makeScanner(
            roots: [sharedRoot(), userRoot()], provider: provider
        )

        provider.armed = true
        let outcome = await scan(scanner)
        provider.armed = false
        try assertValidates(outcome, scanner: scanner)

        let refusals = outcome.errors.filter { $0.kind == .mountedVolumeRoot }
        XCTAssertEqual(refusals.count, 1, "\(outcome.errors)")
        let issue = try XCTUnwrap(refusals.first)
        XCTAssertEqual(issue.url?.path, canonical(sharedRootURL).path)
        XCTAssertTrue(issue.detail.contains("is a mounted volume"),
                      issue.detail)
        // The deterministic-bound rule: unmounting genuinely clears this
        // refusal, and the message says so, verbatim.
        XCTAssertTrue(issue.detail.contains(EphemeralTempScanner.mountRemedy),
                      issue.detail)
        // …and the KIND is what the GUI turns into the visible row label
        // (PR #459 codex r11): `.containerRefused` would render "not a
        // configured search root" for a root that IS configured.
        XCTAssertEqual(
            ScanIssueRowPresentation(issue: issue, home: home).label,
            "mounted volume; eject or unmount it, then re-scan"
        )

        // The arm refuses ONE root, never the scan: the sibling root's
        // candidate is still emitted.
        XCTAssertNotNil(itemsByName(outcome)["survivor"])
    }

    /// THE OVER-MOUNTED ROOT, production default end-to-end (PR #459 review
    /// r6, codex C2): a real volume attached EXACTLY at a declared root is
    /// refused from the real kernel table with zero reads at or below the
    /// root and nothing on the volume emitted. This is the cell that
    /// evidences the injected table's production default (real `getfsstat`)
    /// AND the kernel's canonical `f_mntonname` spelling agreeing with the
    /// fn-6.1 declared spelling.
    func testARealVolumeMountedExactlyAtARootIsRefusedWithoutFirstContact()
        async throws {
        let overRoot = try mkdir(base.appendingPathComponent("over-root"))
        let rootPath = canonical(overRoot).path
        guard try attachDMG(
            named: "overroot.dmg", at: URL(fileURLWithPath: rootPath)
        ) else {
            throw XCTSkip("hdiutil could not stage the mount fixture")
        }
        guard FileSystemIdentityProvider().mountPointPaths()
            .contains(rootPath) else {
            throw XCTSkip(
                "kernel table does not spell the mount as \(rootPath)"
            )
        }
        // Foreign payload inside the volume: "nothing emitted" is not
        // vacuous.
        try writeFile(overRoot.appendingPathComponent("foreign.bin"),
                      bytes: 1_024)

        let provider = MountTableInjectingProvider()
        provider.useRealTable = true
        let root = makeRoot(overRoot, label: "Over-mounted root",
                            writability: .perUser)
        let scanner = makeScanner(roots: [root], provider: provider)

        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertTrue(outcome.items.isEmpty,
                      "nothing on the volume may be emitted: "
                        + "\(outcome.items.map(\.displayName))")
        XCTAssertEqual(outcome.errors.count, 1, "\(outcome.errors)")
        let issue = try XCTUnwrap(outcome.errors.first)
        XCTAssertEqual(issue.kind, .mountedVolumeRoot)
        XCTAssertEqual(issue.url?.path, rootPath)
        XCTAssertTrue(issue.detail.contains("is a mounted volume"),
                      issue.detail)
        XCTAssertTrue(issue.detail.contains(EphemeralTempScanner.mountRemedy),
                      issue.detail)
        XCTAssertEqual(provider.reads(atOrBelow: rootPath), [],
                       "the scan made first contact with the mounted "
                        + "filesystem")
    }

    /// THE PRODUCTION-DEFAULT CELL: real `hdiutil` volumes, the real kernel
    /// table (no injection), real lstats — skipped only where `hdiutil`
    /// cannot attach. One volume BELOW a candidate and one AT a candidate
    /// holding a FRESH file: before these arms the fresh file made the
    /// mount-at-candidate SILENTLY absent (stage 1 returned not-stale), and
    /// the walk read every foreign entry; now both are the deterministic
    /// denied row with zero reads at or below either mount.
    func testRealMountsAreRefusedWithoutDescendingIntoThem() async throws {
        let scratch = try mkdir(sharedRootURL.appendingPathComponent("scratch"))
        try writeFile(scratch.appendingPathComponent("payload.bin"))
        let mnt = try mkdir(scratch.appendingPathComponent("mnt"))
        let volcand = try mkdir(sharedRootURL.appendingPathComponent("volcand"))

        guard try attachDMG(named: "below.dmg", at: mnt),
              try attachDMG(named: "atcand.dmg", at: volcand) else {
            throw XCTSkip("hdiutil could not stage the mount fixtures")
        }
        // Foreign content: a few entries below the below-candidate mount
        // (the population a descent would read), and ONE FRESH file on the
        // at-candidate volume (the previously-silent cell; every other
        // fixture is stale against this class's future-fixed clock).
        for index in 0..<3 {
            try writeFile(mnt.appendingPathComponent("f\(index).bin"),
                          bytes: 1_024)
        }
        let fresh = volcand.appendingPathComponent("fresh.bin")
        try writeFile(fresh, bytes: 1_024)
        try setDate(fresh, clock)

        let provider = MountTableInjectingProvider()
        provider.useRealTable = true
        let scanner = makeScanner(roots: [sharedRoot()], provider: provider)

        let outcome = await scan(scanner)
        try assertValidates(outcome, scanner: scanner)
        let items = itemsByName(outcome)

        let mntPath = canonical(sharedRootURL)
            .appendingPathComponent("scratch/mnt").path
        let below = try XCTUnwrap(items["scratch"])
        assertMountRow(below, messageContains: "mount boundary at \(mntPath)")

        let atCandidate = try XCTUnwrap(
            items["volcand"],
            "a mount holding a fresh file used to be SILENTLY absent — it "
                + "must be a visible denied row"
        )
        assertMountRow(atCandidate, messageContains: "entry is a mount point")

        XCTAssertEqual(provider.reads(atOrBelow: mntPath), [])
        XCTAssertEqual(
            provider.reads(
                atOrBelow: entryPath("volcand", under: sharedRootURL)
            ), []
        )
    }

    /// `hdiutil create` + `attach -mountpoint` (nobrowse, quiet); `false`
    /// (→ XCTSkip) when either step fails. Detach is a teardown block.
    private func attachDMG(named name: String, at mountpoint: URL) throws -> Bool {
        let image = base.appendingPathComponent(name)
        func run(_ arguments: [String]) throws -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        guard try run([
            "create", "-size", "8m", "-fs", "APFS",
            "-volname", name, image.path
        ]) else { return false }
        guard try run([
            "attach", image.path, "-mountpoint", mountpoint.path,
            "-nobrowse", "-quiet"
        ]) else { return false }
        addTeardownBlock {
            _ = try? run(["detach", mountpoint.path, "-force"])
        }
        return true
    }
}

// MARK: - The SHARED pre-filter allowance (PR #459 codex r16)
//
// AVAILABILITY class. The root-listing cap (`defaultRootEntryLimit`) and the
// per-candidate pre-filter cap (`defaultPrefilterEntryLimit`) are each 20,000
// and did not compose: every listed entry reaching the pre-filter received a
// FRESH per-candidate budget, so one root's two advertised bounds multiplied
// to 400 million subtree probes. Measured on this machine through the shipped
// walk: 0.64 us/probe warm (200,000 probes in 0.129 s), 2.3 us/probe on a
// 601k-file staging that no longer fits the cache — so the product is
// ~15 minutes for ONE root, EXTRAPOLATED from the second figure. Cancellation
// was checked once per CANDIDATE, measured at 46 ms of unabortable work per
// candidate at the production cap.
extension EphemeralTempScannerTests {

    /// `count` sibling candidates, each holding `entries` old payload files.
    @discardableResult
    private func stageCandidates(
        _ names: [String], entries: Int
    ) throws -> [URL] {
        try names.map { name in
            let dir = try mkdir(sharedRootURL.appendingPathComponent(name))
            for index in 0..<entries {
                try writeFile(
                    dir.appendingPathComponent("payload-\(index).bin"),
                    bytes: 4_096
                )
            }
            try backdate(dir, to: oldDate)
            return dir
        }
    }

    /// THE COMPOSITION. With the allowance shared, the candidates after it
    /// runs out are left un-inspected — and the root says so ONCE.
    func testTheSharedRootBudgetStopsLaterCandidatesAndIsDisclosedOnce()
        async throws {
        try stageCandidates(["a-first", "b-second", "c-third"], entries: 4)

        let unbounded = await scan(makeScanner(roots: [sharedRoot()]))
        XCTAssertEqual(
            itemsByName(unbounded).keys.sorted(),
            ["a-first", "b-second", "c-third"],
            "control: at the shipped allowance all three are listed"
        )
        XCTAssertTrue(
            unbounded.errors.isEmpty, "control: and nothing is disclosed"
        )

        // 6 entries of allowance against 12 entries of work: the first
        // candidate's four exhaust two thirds of it.
        let outcome = await scan(makeScanner(
            roots: [sharedRoot()], prefilterRootBudget: 6
        ))

        XCTAssertEqual(
            itemsByName(outcome).keys.sorted(), ["a-first"],
            "only the candidates the allowance actually paid for are listed"
        )
        let truncations = outcome.errors.filter {
            $0.kind == .enumerationTruncated
        }
        XCTAssertEqual(
            truncations.count, 1,
            "ONE root-level disclosure, never one per un-inspected candidate: "
                + "\(outcome.errors.map(\.detail))"
        )
        let disclosure = try XCTUnwrap(truncations.first)
        XCTAssertEqual(disclosure.url?.path, canonical(sharedRootURL).path)
        XCTAssertTrue(
            disclosure.detail.contains("6 entries of staleness checking"),
            disclosure.detail
        )
        XCTAssertTrue(
            disclosure.detail.contains("lets a later scan reach further"),
            "the remedy must be the one that can actually differ — clearing "
                + "entries — not a bare re-scan: \(disclosure.detail)"
        )
    }

    /// THE OTHER ADMISSION POINT: a candidate whose walk never gets to read
    /// anything at all. With the allowance an exact multiple of the first
    /// candidate's payload, the read that would have exhausted it never
    /// happens — the second candidate is refused when its directory is popped,
    /// and only that arm can produce the disclosure.
    func testACandidateRefusedBeforeItsFirstReadStillDisclosesTheAllowance()
        async throws {
        try stageCandidates(["a-first", "b-second"], entries: 4)

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()], prefilterRootBudget: 4
        ))

        XCTAssertEqual(
            itemsByName(outcome).keys.sorted(), ["a-first"],
            "the first candidate spends the whole allowance and is listed"
        )
        XCTAssertEqual(
            outcome.errors.filter { $0.kind == .enumerationTruncated }.count, 1,
            "and the candidate that was never read is disclosed: "
                + "\(outcome.errors.map(\.detail))"
        )
    }

    /// The disclosure is keyed on being CUT SHORT, not on landing on zero. An
    /// allowance that exactly fits must make no partial-inspection claim —
    /// the GUI label for that kind is the fixed sentence "too many entries —
    /// partially inspected", which would be a lie here.
    func testAnAllowanceThatExactlyFitsMakesNoPartialInspectionClaim()
        async throws {
        try stageCandidates(["a-first", "b-second", "c-third"], entries: 4)

        let outcome = await scan(makeScanner(
            roots: [sharedRoot()], prefilterRootBudget: 12
        ))

        XCTAssertEqual(
            itemsByName(outcome).keys.sorted(),
            ["a-first", "b-second", "c-third"],
            "every candidate was inspected within the allowance"
        )
        XCTAssertEqual(
            outcome.errors.filter { $0.kind == .enumerationTruncated }.count, 0,
            "so nothing may claim the root was only partially inspected: "
                + "\(outcome.errors.map(\.detail))"
        )
    }

    /// CANCELLATION INSIDE THE WALK, at the directory the stack pops.
    ///
    /// STAGED SO ONLY THAT CHECK CAN ANSWER: every subdirectory is EMPTY, so
    /// the per-name check below it never executes its body and the stack
    /// drains through the pop alone. A first attempt at this cell used a deep
    /// CHAIN instead, and removing the pop check left the whole suite green —
    /// the per-name check was catching it. (`readChildNames` is the seam
    /// because it is called exactly once per popped directory.)
    func testCancellationStopsAWalkBetweenItsDirectories() async throws {
        let breadth = 20
        let candidate = try mkdir(
            sharedRootURL.appendingPathComponent("wide-empty")
        )
        for index in 0..<breadth {
            try mkdir(candidate.appendingPathComponent("sub-\(index)"))
        }
        try backdate(candidate, to: oldDate)

        let controlCalls = WalkSeamCallCounter()
        _ = await scan(makeScanner(
            roots: [sharedRoot()],
            readChildNames: { [controlCalls] url, limit in
                controlCalls.bump()
                return EphemeralTempScanner.boundedChildNames(
                    of: url, limit: limit
                )
            }
        ))
        XCTAssertEqual(
            controlCalls.count, breadth + 1,
            "control: an uncancelled walk reads the candidate and every one "
                + "of its subdirectories"
        )

        let canceller = TaskCanceller()
        let calls = WalkSeamCallCounter()
        let scanner = makeScanner(
            roots: [sharedRoot()],
            readChildNames: { [calls, canceller] url, limit in
                calls.bump()
                // Cancel from INSIDE the walk, on the walk's own task, at the
                // FIRST subdirectory — the candidate's own names are already
                // on the stack, and every one of them is empty.
                if calls.count == 2 { canceller.fire() }
                return EphemeralTempScanner.boundedChildNames(
                    of: url, limit: limit
                )
            }
        )
        let gate = ScanRendezvous()
        let task = Task {
            await gate.waitForRelease()
            return await scanner.scan(
                context: ScanContext(trigger: .userInitiated)
            )
        }
        canceller.hold { task.cancel() }
        gate.release()
        _ = await task.value

        XCTAssertLessThanOrEqual(
            calls.count, 3,
            "a cancelled walk must stop at the next directory it pops, not "
                + "drain all \(breadth + 1) of them"
        )
    }

    /// CANCELLATION INSIDE THE WALK, between the NAMES of one directory —
    /// the other admission point. One `readChildNames` call can hand back a
    /// whole per-candidate budget's worth of names, so a per-directory check
    /// alone leaves that batch unabortable.
    func testCancellationStopsAWalkBetweenTheNamesOfOneDirectory()
        async throws {
        let entryCount = 60
        let candidate = try mkdir(
            sharedRootURL.appendingPathComponent("wide")
        )
        for index in 0..<entryCount {
            try writeFile(
                candidate.appendingPathComponent("payload-\(index).bin"),
                bytes: 4_096
            )
        }
        try backdate(candidate, to: oldDate)

        let canceller = TaskCanceller()
        let provider = CancellingKindProbeProvider(
            under: canonical(candidate).path, cancelAtCall: 5,
            canceller: canceller
        )
        let scanner = makeScanner(roots: [sharedRoot()], provider: provider)
        let gate = ScanRendezvous()
        let task = Task {
            await gate.waitForRelease()
            return await scanner.scan(
                context: ScanContext(trigger: .userInitiated)
            )
        }
        canceller.hold { task.cancel() }
        gate.release()
        _ = await task.value

        XCTAssertLessThanOrEqual(
            provider.callsUnderCandidate, 6,
            "the walk must stop at the next NAME once cancelled, not probe "
                + "all \(entryCount) entries of the batch"
        )
    }
}

/// A thread-safe call counter for the walk seams.
final class WalkSeamCallCounter: @unchecked Sendable {
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

/// Cancels the scan's OWN task from inside a seam the scan calls, exactly
/// once. The action is installed after the task exists and before the gate
/// releases it, so the ordering is deterministic rather than raced.
final class TaskCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var fired = false

    func hold(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.action = action
    }

    func fire() {
        lock.lock()
        let action = fired ? nil : self.action
        fired = true
        lock.unlock()
        action?()
    }
}

/// Counts `probeKind` calls under one candidate and cancels the scan at the
/// Nth of them — the walk's per-NAME admission point.
final class CancellingKindProbeProvider: FileSystemIdentityProvider,
    @unchecked Sendable {
    private let prefix: String
    private let cancelAtCall: Int
    private let canceller: TaskCanceller
    private let lock = NSLock()
    private var calls = 0

    init(under prefix: String, cancelAtCall: Int, canceller: TaskCanceller) {
        self.prefix = prefix + "/"
        self.cancelAtCall = cancelAtCall
        self.canceller = canceller
        super.init()
    }

    var callsUnderCandidate: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    override func probeKind(of url: URL) -> KindProbe {
        var shouldCancel = false
        if url.path.hasPrefix(prefix) {
            lock.lock()
            calls += 1
            shouldCancel = calls == cancelAtCall
            lock.unlock()
        }
        if shouldCancel { canceller.fire() }
        return super.probeKind(of: url)
    }
}
