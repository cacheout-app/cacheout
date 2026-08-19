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

    /// The spelling the scanner works in: the CANONICAL root plus the entry
    /// leaf. Fixture URLs come back from `FileManager.temporaryDirectory` in
    /// the `/var/…` alias spelling, and fn-6.1 canonicalizes roots exactly
    /// once — so an assertion against the raw fixture URL would compare the
    /// wrong spelling.
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
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        thresholds: EphemeralTempSweepConfig.Thresholds? = nil,
        prefilterEntryLimit: Int =
            EphemeralTempScanner.defaultPrefilterEntryLimit,
        lockProbe: EphemeralTempScanner.LockProber? = nil,
        listDirectory: EphemeralTempScanner.DirectoryLister? = nil,
        candidateSizer: EphemeralTempScanner.CandidateSizer? = nil
    ) -> EphemeralTempScanner {
        let clock = self.clock
        return EphemeralTempScanner(
            roots: roots,
            home: home,
            thresholds: thresholds ?? self.thresholds,
            provider: provider,
            prefilterEntryLimit: prefilterEntryLimit,
            now: { clock },
            lockProbe: lockProbe ?? { EphemeralTempScanner.cooperativeLockProbe($0) },
            listDirectory: listDirectory ?? {
                try EphemeralTempScanner.firstLevelEntries(of: $0)
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

        func list(_ url: URL) throws -> [URL] {
            listed.append(url)
            if let stubError { throw stubError }
            return try EphemeralTempScanner.firstLevelEntries(of: url)
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
        XCTAssertTrue(outcome.errors.isEmpty,
                      "a cap hit is not an anomaly — nothing was denied")
        XCTAssertTrue(spy.calls.isEmpty,
                      "a cap-hit candidate never reaches sizing")
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
            listDirectory: { [lister] url in try lister.list(url) }
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
            listDirectory: { [lister] url in try lister.list(url) }
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

    func testAutomaticTriggerDefersEveryRootEntirely() async throws {
        try makeStaleCandidate("old-scratch", under: sharedRootURL)
        try makeStaleCandidate("other", under: userRootURL)
        let lister = ListerSpy()
        let spy = SizingSpy()

        let outcome = await scan(
            makeScanner(
                roots: [sharedRoot(), userRoot()],
                listDirectory: { [lister] url in try lister.list(url) },
                candidateSizer: { [spy] url, mode in spy.measure(url, mode) }
            ),
            trigger: .automatic
        )

        XCTAssertTrue(lister.listed.isEmpty, "nothing is enumerated")
        XCTAssertTrue(spy.calls.isEmpty, "nothing is sized")
        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty,
                      "a deferral is not an anomaly — the same silent "
                        + "semantics a skipped protected root has")
    }

    func testUserInitiatedEnumeratesEveryResolvedRoot() async throws {
        try makeStaleCandidate("in-shared", under: sharedRootURL)
        try makeStaleCandidate("in-user", under: userRootURL)
        let lister = ListerSpy()

        let outcome = await scan(makeScanner(
            roots: [sharedRoot(), userRoot()],
            listDirectory: { [lister] url in try lister.list(url) }
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
    // "Select Stale (30d+)" bulk selection, so a false one is one click from
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

    func testSymlinkRootIsNeverTraversed() async throws {
        let realDirectory = try mkdir(base.appendingPathComponent("elsewhere"))
        try makeStaleCandidate("payload", under: realDirectory)
        let link = base.appendingPathComponent("linked-root")
        try fm.createSymbolicLink(at: link, withDestinationURL: realDirectory)

        // Declared WITHOUT canonicalization so the root stays the link itself.
        let root = makeRoot(link, label: "Linked", writability: .perUser,
                            canonicalize: false)
        let outcome = await scan(makeScanner(roots: [root]))

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.errors.first?.kind, .symlinkRoot)
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

    /// A REGULAR-FILE candidate has no tree to walk, and `.noDirectoryTree` is
    /// the honest binding for it: the deletion's `ENOTDIR` arm proves no
    /// directory has appeared at the name since, and the Trash arm's
    /// `O_DIRECTORY` look agrees.
    func testRevalidatorBindsARegularFileCandidateAsNoDirectoryTree()
        async throws {
        let entry = try writeFile(
            sharedRootURL.appendingPathComponent("old-blob.bin"), bytes: 8_192
        )
        try setDate(entry, oldDate)
        let scanner = makeScanner(roots: [sharedRoot()])
        let scanned = itemsByName(await scan(scanner))
        let item = try XCTUnwrap(scanned["old-blob.bin"])

        XCTAssertEqual(
            try XCTUnwrap(scanner.preDeleteRevalidator)
                .revalidate(item: item, authorization: nil),
            .allow(inspected: .noDirectoryTree)
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
}

/// A one-slot box so a verdict taken on a detached thread can be read back
/// after a bounded wait. `@unchecked Sendable` is sound here because the
/// semaphore establishes the happens-before edge: the writer signals only
/// after the store, and the reader loads only after a successful wait.
private final class VerdictBox: @unchecked Sendable {
    var value: PreDeleteVerdict?
}
