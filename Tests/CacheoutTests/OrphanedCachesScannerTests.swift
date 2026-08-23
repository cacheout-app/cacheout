import XCTest
import Darwin
@testable import Cacheout

/// fn-3.4 assembly tests: `OrphanedCachesScanner`'s `SpaceScanner`
/// conformance end-to-end (facts → classifier → `ReclaimableItem`s, mapped
/// against fn-2's frozen validator invariants), the config surface (R8),
/// the snapshot-bound delete-time container admission and its container-swap
/// narrowing (R9), the ViewModel session/freshness gates, and the CLI
/// registration/addressing/flag surface (R6).
///
/// Every test runs against a UUID-derived fixture home under the system temp
/// directory — zero reads of the real `$HOME` or the real `~/Library/Caches`,
/// and zero writes to the standard `UserDefaults` (config tests use throwaway
/// suites).
final class OrphanedCachesScannerTests: XCTestCase {

    private var base: URL!
    private var home: URL!
    private var cachesRoot: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("OrphanedCachesScannerTests-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        cachesRoot = home.appendingPathComponent("Library/Caches")
        try fm.createDirectory(at: cachesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Helpers

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    private func writeFile(_ url: URL, bytes: Int = 4096) throws -> URL {
        try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
            .write(to: url)
        return url
    }

    private func chmod000(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }

    private func restorePerms(_ url: URL) {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func setModificationDate(_ url: URL, _ date: Date) throws {
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Open a directory for the descriptor-relative primitives the walk is
    /// built from. The caller owns the descriptor.
    private func openDirectory(
        _ url: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            XCTFail("open(\(url.path)) failed: \(code)", file: file, line: line)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }

    /// How many descriptors this process holds — the fd-balance net that
    /// wraps every probe test, including every refusal path.
    private func openDescriptorCount() -> Int {
        (try? fm.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// The same question asked WITHOUT opening a descriptor to ask it.
    /// `contentsOfDirectory("/dev/fd")` needs a handle of its own, and that
    /// handle is the same order of magnitude as the quantity under test, so
    /// it cannot be used to sample a peak. `fcntl(F_GETFD)` allocates
    /// nothing, so a sample taken from inside a walk event is exactly what
    /// the walk was holding at that instant.
    private func heldDescriptorCount() -> Int {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return -1 }
        let ceiling = Int32(clamping: min(limits.rlim_cur, 65_536))
        var count = 0
        for descriptor in 0..<ceiling where fcntl(descriptor, F_GETFD) >= 0 {
            count += 1
        }
        return count
    }

    /// Run `body` and assert it leaked no descriptors. `SecureDirectory`'s
    /// `deinit` is what makes this pass on `break walk` and early-refusal
    /// paths alike; this is the enforcement, not review vigilance.
    private func assertNoDescriptorLeak(
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) rethrows {
        let before = openDescriptorCount()
        try body()
        let after = openDescriptorCount()
        XCTAssertEqual(after, before,
                       "the probe leaked \(after - before) descriptor(s)",
                       file: file, line: line)
    }

    /// A `MountIdentity` guaranteed distinct from any real one, and distinct
    /// per inode — the descriptor-shaped replacement for injecting
    /// `isMountPoint` by inode (which a path SPELLING could defeat, and did:
    /// that whole failure class dies with the path form).
    private static func injectedMount(
        forInode inode: UInt64, device: UInt64
    ) -> FileSystemIdentityProvider.MountIdentity {
        FileSystemIdentityProvider.MountIdentity(
            fsidMajor: Int32(bitPattern: 0xDEAD_BEEF),
            fsidMinor: Int32(bitPattern: UInt32(truncatingIfNeeded: inode)),
            device: device
        )
    }

    /// The production sweep scanner over the fixture home. `categories: []`
    /// by default — exclusion has its own test; everything else must not
    /// depend on the production category list.
    private func makeScanner(
        categories: [CacheCategory] = [],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        thresholds: OrphanedCacheClassifier.Thresholds =
            OrphanedCachesSweepConfig.defaultThresholds,
        installedAppStatus: @escaping @Sendable (String) -> InstalledAppStatus =
            { _ in .unknown },
        now: @escaping @Sendable () -> Date = { Date() },
        toolAvailability: (@Sendable (String) -> Bool)? = nil,
        probeResolver: (@Sendable (String) -> String?)? = nil
    ) -> OrphanedCachesScanner {
        OrphanedCachesScanner(
            home: home,
            categories: categories,
            provider: provider,
            thresholds: thresholds,
            installedAppStatus: installedAppStatus,
            now: now,
            toolAvailability: toolAvailability,
            probeResolver: probeResolver
        )
    }

    private func makeRuntime(
        _ scanners: [any SpaceScanner],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) throws -> SpaceScannerRuntime {
        try SpaceScannerRuntime(
            scanners: scanners, categories: [], home: home, provider: provider
        )
    }

    /// Scan through the protocol surface and index items by display name.
    private func scanItems(
        _ scanner: OrphanedCachesScanner,
        trigger: ScanTrigger = .userInitiated,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> (byName: [String: ReclaimableItem], outcome: ScanOutcome) {
        let outcome = await scanner.scan(context: ScanContext(trigger: trigger))
        var byName: [String: ReclaimableItem] = [:]
        for item in outcome.items {
            XCTAssertNil(byName[item.displayName],
                         "duplicate display name in fixture", file: file, line: line)
            byName[item.displayName] = item
        }
        return (byName, outcome)
    }

    /// The outcome must PASS fn-2's shared fail-closed validation — a
    /// malformed sweep outcome would poison the entire scanner (nothing
    /// listable, selectable, addressable, or deletable).
    private func assertValidates(
        _ outcome: ScanOutcome, scanner: OrphanedCachesScanner,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let runtime = try makeRuntime([scanner])
        guard case .outcome = runtime.validatedOutcome(
            outcome, from: OrphanedCachesScanner.registeredID
        ) else {
            let event = runtime.validatedOutcome(
                outcome, from: OrphanedCachesScanner.registeredID
            )
            return XCTFail("outcome failed fn-2 validation: \(event)",
                           file: file, line: line)
        }
    }

    /// A throwaway UserDefaults suite (registered for teardown removal).
    private func makeDefaultsSuite() throws -> UserDefaults {
        let name = "OrphanedCachesScannerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    // MARK: - R1: leak glob end-to-end

    func testDragUUIDLeakEndToEndSafeAndBulkEligible() async throws {
        let entry = cachesRoot.appendingPathComponent(
            "com.apple.SwiftUI.Drag-6A1B2C3D-0000-4000-8000-123456789ABC"
        )
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"), bytes: 8192)

        let scanner = makeScanner()
        let (items, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        let leak = try XCTUnwrap(items[entry.lastPathComponent])
        XCTAssertEqual(leak.risk, .safe)
        XCTAssertTrue(leak.evidence.contains(
            "matches leak pattern com.apple.SwiftUI.Drag-* (drag payload cache)"
        ), leak.evidence)
        XCTAssertTrue(leak.defaultSelected)
        XCTAssertTrue(leak.automaticCleanEligible)
        XCTAssertEqual(leak.state, .measured)
        XCTAssertGreaterThan(leak.exactBytes, 0)
        XCTAssertEqual(leak.scannerID, "orphaned_caches")
        XCTAssertNil(leak.rebuildNote, "a leak needs no rebuild note")

        // Deletion contract (R9): .removeItem on the ENTRY directory via
        // the frozen container-item arm, one root record binding the same
        // capture the item displays.
        XCTAssertEqual(leak.action, .removeItem)
        guard case .containerItem(let origin, let target) = leak.admission else {
            return XCTFail("expected .containerItem admission")
        }
        XCTAssertEqual(origin.path, cachesRoot.path,
                       "origin is the scanner's own declared container root")
        // The enumeration's spelling of the entry (the temp fixture rides
        // the /var -> /private/var alias, so compare leaf + location, not
        // the fixture's own string spelling).
        XCTAssertEqual(target.lastPathComponent, entry.lastPathComponent,
                       "requestedTargetURL keeps the UNRESOLVED entry leaf")
        XCTAssertTrue(
            FileSystemIdentityProvider().sameLocation(target, entry),
            "the deletion target IS the fixture entry"
        )
        XCTAssertEqual(leak.rootRecords.count, 1)
        XCTAssertEqual(leak.rootRecords.first?.requestedURL.path, target.path,
                       "the record's requested spelling binds the deletion "
                       + "target — one capture (check (f))")
        XCTAssertEqual(leak.rootRecords.first?.status, .measured)
        XCTAssertEqual(leak.rootRecords.first?.resolvedURL?.path, leak.url?.path)

        // Frozen id derivation (R6).
        let provider = FileSystemIdentityProvider()
        XCTAssertEqual(leak.id, ReclaimableItem.stableID(
            scannerID: "orphaned_caches",
            canonicalPath: provider.resolveTargetKeepingLeaf(entry).path
        ))
    }

    func testUserDataShapedLeakForcesReviewAndCaution() async throws {
        let entry = cachesRoot.appendingPathComponent(
            "com.apple.SwiftUI.Drag-USERDATA"
        )
        let pictures = entry.appendingPathComponent("Pictures")
        try mkdir(pictures.appendingPathComponent("Photos Library.photoslibrary"))
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let scanner = makeScanner()
        let (items, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        let cautious = try XCTUnwrap(items[entry.lastPathComponent])
        XCTAssertEqual(cautious.risk, .review)
        XCTAssertTrue(cautious.evidence.contains(
            "verify the original still exists before deleting"
        ), cautious.evidence)
        XCTAssertFalse(cautious.defaultSelected)
        XCTAssertFalse(cautious.automaticCleanEligible)
    }

    // MARK: - R2: orphan tri-state wiring

    func testOrphanTriStateResolverWiring() async throws {
        for name in ["com.example.gone", "com.example.here", "com.example.mist"] {
            let entry = cachesRoot.appendingPathComponent(name)
            try mkdir(entry)
            try writeFile(entry.appendingPathComponent("cache.bin"))
        }

        let scanner = makeScanner(installedAppStatus: { bundleID in
            switch bundleID {
            case "com.example.gone": return .notInstalled
            case "com.example.here": return .installed
            default: return .unknown
            }
        })
        let (items, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        // POSITIVE not-installed → orphan tier with the frozen evidence.
        let orphan = try XCTUnwrap(items["com.example.gone"])
        XCTAssertTrue(orphan.evidence.contains(
            "no installed app for bundle id com.example.gone"
        ), orphan.evidence)
        XCTAssertEqual(orphan.risk, .review)
        XCTAssertFalse(orphan.defaultSelected)
        XCTAssertFalse(orphan.automaticCleanEligible)
        XCTAssertEqual(orphan.rebuildNote,
                       "reinstalling the app recreates its cache")

        // INSTALLED → no orphan evidence and no bulk eligibility. The ROW
        // may legitimately remain (unclassified informational, output-set
        // rule) — assert evidence absence, never row absence.
        let installed = try XCTUnwrap(items["com.example.here"])
        XCTAssertFalse(installed.evidence.contains("no installed app"),
                       installed.evidence)
        XCTAssertFalse(installed.defaultSelected)
        XCTAssertFalse(installed.automaticCleanEligible)
        XCTAssertNil(installed.rebuildNote)

        // UNKNOWN → never orphan; the incomplete-resolution note rides.
        let unknown = try XCTUnwrap(items["com.example.mist"])
        XCTAssertFalse(unknown.evidence.contains("no installed app"),
                       unknown.evidence)
        XCTAssertTrue(unknown.evidence.contains(
            "couldn't determine whether an app is installed"
        ), unknown.evidence)
        XCTAssertFalse(unknown.automaticCleanEligible)
    }

    // MARK: - R3: category-owned exclusion through the protocol surface

    func testCategoryOwnedEntryAbsentFromItems() async throws {
        let owned = cachesRoot.appendingPathComponent("Homebrew")
        try mkdir(owned)
        try writeFile(owned.appendingPathComponent("bottle.tar.gz"))
        let unowned = cachesRoot.appendingPathComponent("some.leftover.dir")
        try mkdir(unowned)
        try writeFile(unowned.appendingPathComponent("f.bin"))

        // The PRODUCTION category list, resolved against the fixture home —
        // the same exclusion-set construction production uses.
        let scanner = makeScanner(categories: CacheCategory.allCategories)
        let (items, _) = await scanItems(scanner)

        XCTAssertNil(items["Homebrew"],
                     "a category-owned entry is the category's row, not the sweep's")
        XCTAssertNotNil(items["some.leftover.dir"])
    }

    // MARK: - R5 + R7: output set, denied visibility, selection exclusion

    func testTopNCutKeepsLargestAndDeniedEntriesAreUnconditionallyVisible() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        // 12 clean unclassified entries, strictly descending sizes.
        for index in 0..<12 {
            let entry = cachesRoot.appendingPathComponent(
                String(format: "unclassified-%02d", index)
            )
            try mkdir(entry)
            try writeFile(entry.appendingPathComponent("f.bin"),
                          bytes: (20 - index) * 4096)
        }
        // A zero-byte DENIED entry — R7 visibility is unconditional.
        let denied = cachesRoot.appendingPathComponent("zz-denied")
        try mkdir(denied)
        try chmod000(denied)
        addTeardownBlock { [fm, denied] in
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: denied.path)
        }

        let scanner = makeScanner()
        let (items, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertNotNil(items["unclassified-00"], "the largest is always present")
        XCTAssertNotNil(items["unclassified-09"])
        XCTAssertNil(items["unclassified-10"],
                     "clean unclassified entries beyond the top-N are omitted")
        XCTAssertNil(items["unclassified-11"])

        let unclassified = try XCTUnwrap(items["unclassified-00"])
        XCTAssertEqual(unclassified.risk, .review)
        XCTAssertTrue(unclassified.evidence.contains("listed for visibility"),
                      unclassified.evidence)
        XCTAssertFalse(unclassified.defaultSelected)
        XCTAssertFalse(unclassified.automaticCleanEligible)

        // The zero-byte denied entry survives the size cut, as `.denied`
        // with a classified error (never a silent 0-byte row, D6).
        let deniedItem = try XCTUnwrap(items["zz-denied"])
        XCTAssertEqual(deniedItem.state, .denied)
        XCTAssertEqual(deniedItem.scanError?.kind, .permissionDenied)
        XCTAssertEqual(deniedItem.rootRecords.first?.status, .deniedUnmeasured)
        XCTAssertEqual(deniedItem.allocatedBytes, 0)
        XCTAssertFalse(deniedItem.defaultSelected)
        XCTAssertFalse(deniedItem.automaticCleanEligible)

        restorePerms(denied)
    }

    func testPartiallyDeniedEntryCarriesComponentsAndClassifiedError() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let entry = cachesRoot.appendingPathComponent("partially-denied")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("readable.bin"), bytes: 8192)
        let locked = entry.appendingPathComponent("locked")
        try mkdir(locked)
        try chmod000(locked)
        addTeardownBlock { [fm, locked] in
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: locked.path)
        }

        let scanner = makeScanner()
        let (items, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        let partial = try XCTUnwrap(items["partially-denied"])
        XCTAssertEqual(partial.state, .partiallyDenied,
                       "walk denials with measured content partially succeed "
                       + "at delete time — unlike boundaries")
        XCTAssertGreaterThan(partial.allocatedBytes, 0)
        XCTAssertEqual(partial.scanError?.kind, .permissionDenied)
        XCTAssertEqual(partial.rootRecords.first?.status, .measured)
        XCTAssertTrue(partial.evidence.contains("couldn't fully scan: permission denied"),
                      partial.evidence)
        XCTAssertFalse(partial.automaticCleanEligible)

        restorePerms(locked)
    }

    // MARK: - R7: mount boundaries (injected provider), both arms

    /// Injects boundary conditions by inode so canonical-path spelling never
    /// matters (the fn-3.1 test idiom).
    private final class BoundaryInjectingProvider: FileSystemIdentityProvider {
        var deviceOverridesByInode: [UInt64: UInt64] = [:]
        var mountPointInodes: Set<UInt64> = []

        override func identity(of url: URL) -> Identity? {
            guard let id = super.identity(of: url) else { return nil }
            if let device = deviceOverridesByInode[id.inode] {
                return Identity(device: device, inode: id.inode)
            }
            return id
        }

        override func probeKind(of url: URL) -> KindProbe {
            super.probeKind(of: url)
        }

        override func isMountPoint(_ url: URL) -> Bool {
            if let id = identity(of: url), mountPointInodes.contains(id.inode) {
                return true
            }
            return super.isMountPoint(url)
        }

        /// The same two injections, descriptor-shaped, so the probe's own
        /// mount rule sees what the sizer's path rule sees.
        override func mountIdentity(ofDescriptor descriptor: Int32)
            -> MountIdentity? {
            guard let real = super.mountIdentity(ofDescriptor: descriptor),
                  let id = super.identity(ofDescriptor: descriptor)
            else { return nil }
            if mountPointInodes.contains(id.inode) {
                return OrphanedCachesScannerTests.injectedMount(
                    forInode: id.inode, device: real.device
                )
            }
            if let device = deviceOverridesByInode[id.inode] {
                return MountIdentity(
                    fsidMajor: real.fsidMajor, fsidMinor: real.fsidMinor,
                    device: device
                )
            }
            return real
        }
    }

    func testMountPointEntryIsDeniedNeverCleanOrEmpty() async throws {
        let entry = cachesRoot.appendingPathComponent("mounted-entry")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"), bytes: 8192)

        let provider = BoundaryInjectingProvider()
        let inode = try XCTUnwrap(provider.identity(of: entry)?.inode)
        provider.mountPointInodes.insert(inode)

        let scanner = makeScanner(provider: provider)
        let (items, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        let mounted = try XCTUnwrap(items["mounted-entry"])
        XCTAssertEqual(mounted.state, .denied)
        XCTAssertEqual(mounted.rootRecords.first?.status, .deniedUnmeasured)
        XCTAssertEqual(mounted.allocatedBytes, 0)
        XCTAssertEqual(mounted.itemCount, 0)
        XCTAssertEqual(mounted.scanError?.kind, .other)
        XCTAssertTrue(
            try XCTUnwrap(mounted.scanError?.message)
                .contains("item is a mount point"),
            mounted.scanError?.message ?? ""
        )
        XCTAssertFalse(mounted.defaultSelected)
        XCTAssertFalse(mounted.automaticCleanEligible)
    }

    func testNestedBoundaryWithMeasuredContentIsDeniedWithFloorInMessage() async throws {
        let entry = cachesRoot.appendingPathComponent("has-volume")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("local.bin"), bytes: 4096)
        let volume = entry.appendingPathComponent("foreign-volume")
        try mkdir(volume)
        try writeFile(volume.appendingPathComponent("beyond.bin"), bytes: 8192)

        let provider = BoundaryInjectingProvider()
        let inode = try XCTUnwrap(provider.identity(of: volume)?.inode)
        provider.deviceOverridesByInode[inode] = 0xDEAD_BEEF

        let scanner = makeScanner(provider: provider)
        let (items, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        // ANY boundary → `.denied` + ZERO components (delete refuses the
        // whole target); the measured floor rides the scanError message —
        // never `.partiallyDenied`, never a clean row (as-merged
        // NodeModulesScanner doctrine).
        let bounded = try XCTUnwrap(items["has-volume"])
        XCTAssertEqual(bounded.state, .denied)
        XCTAssertEqual(bounded.rootRecords.first?.status, .deniedUnmeasured)
        XCTAssertEqual(bounded.allocatedBytes, 0)
        XCTAssertEqual(bounded.itemCount, 0)
        XCTAssertNil(bounded.logicalBytes)
        let message = try XCTUnwrap(bounded.scanError?.message)
        XCTAssertTrue(message.contains("mount boundary at"), message)
        XCTAssertTrue(message.contains(
            "measured beside the boundary is not reclaimable while the boundary remains"
        ), message)
        XCTAssertTrue(bounded.evidence.contains(
            "contains a mount boundary — size incomplete; deletion would be refused"
        ), bounded.evidence)
        XCTAssertFalse(bounded.defaultSelected)
        XCTAssertFalse(bounded.automaticCleanEligible)
    }

    // MARK: - R7: combined denial + boundary → frozen scanError precedence

    func testCombinedDenialAndBoundaryFollowsFrozenPrecedence() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let entry = cachesRoot.appendingPathComponent("denied-and-bounded")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("local.bin"), bytes: 4096)
        let locked = entry.appendingPathComponent("locked")
        try mkdir(locked)
        let volume = entry.appendingPathComponent("volume")
        try mkdir(volume)

        let provider = BoundaryInjectingProvider()
        let inode = try XCTUnwrap(provider.identity(of: volume)?.inode)
        provider.deviceOverridesByInode[inode] = 0xDEAD_BEEF
        try chmod000(locked)
        addTeardownBlock { [fm, locked] in
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: locked.path)
        }

        let scanner = makeScanner(provider: provider)
        let (items, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        let combined = try XCTUnwrap(items["denied-and-bounded"])
        // The most ACTIONABLE error wins the one slot: the permission
        // denial (a fixable grant) beats the boundary detail.
        XCTAssertEqual(combined.scanError?.kind, .permissionDenied)
        // EVERY condition still appears in evidence.
        XCTAssertTrue(combined.evidence.contains("couldn't fully scan: permission denied"),
                      combined.evidence)
        XCTAssertTrue(combined.evidence.contains("contains a mount boundary"),
                      combined.evidence)
        // The state is the MORE SEVERE mapping: the boundary voids deletion
        // entirely, so `.denied` (not `.partiallyDenied`), zero components.
        XCTAssertEqual(combined.state, .denied)
        XCTAssertEqual(combined.allocatedBytes, 0)

        restorePerms(locked)
    }

    func testScanErrorPrecedenceUnitTable() {
        func entry(
            denials: [SizeDenial], boundary: Bool
        ) -> SweptCacheEntry {
            SweptCacheEntry(
                name: "x", url: cachesRoot.appendingPathComponent("x"),
                exactBytes: 0, estimatedUpToBytes: 0, logicalBytes: 0,
                itemCount: 0, newestContentDate: nil,
                denials: denials,
                mountBoundaries: boundary
                    ? [cachesRoot.appendingPathComponent("x/vol")] : [],
                rootMountBoundary: false,
                userDataShapeMatches: [], userDataProbeComplete: true
            )
        }
        let url = cachesRoot.appendingPathComponent("x")
        let tcc = SizeDenial(url: url, kind: .tcc, detail: "EPERM")
        let perm = SizeDenial(url: url, kind: .permission, detail: "EACCES")
        let meta = SizeDenial(url: url, kind: .metadata, detail: "EIO")

        // tccDenied beats permissionDenied beats other beats boundary —
        // regardless of the denials' recorded order.
        XCTAssertEqual(
            OrphanedCachesScanner.sweepScanError(
                for: entry(denials: [meta, perm, tcc], boundary: true)
            )?.kind, .tccDenied
        )
        XCTAssertEqual(
            OrphanedCachesScanner.sweepScanError(
                for: entry(denials: [meta, perm], boundary: true)
            )?.kind, .permissionDenied
        )
        XCTAssertEqual(
            OrphanedCachesScanner.sweepScanError(
                for: entry(denials: [meta], boundary: true)
            )?.kind, .other
        )
        let boundaryOnly = OrphanedCachesScanner.sweepScanError(
            for: entry(denials: [], boundary: true)
        )
        XCTAssertEqual(boundaryOnly?.kind, .other)
        XCTAssertTrue(boundaryOnly?.message.contains("mount boundary") == true)
        XCTAssertNil(OrphanedCachesScanner.sweepScanError(
            for: entry(denials: [], boundary: false)
        ))
    }

    // MARK: - R7: root-level failures are classified scanner issues

    func testSymlinkedSweepRootYieldsSymlinkRootIssue() async throws {
        let external = base.appendingPathComponent("external-caches")
        try mkdir(external)
        try fm.removeItem(at: cachesRoot)
        try fm.createSymbolicLink(at: cachesRoot, withDestinationURL: external)

        let scanner = makeScanner()
        let outcome = await scanner.scan(
            context: ScanContext(trigger: .userInitiated)
        )
        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertEqual(outcome.errors.first?.kind, .symlinkRoot)
        XCTAssertEqual(outcome.errors.first?.url?.path, cachesRoot.path)
    }

    func testUnreadableSweepRootYieldsClassifiedIssueNotEmptySuccess() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        try writeFile(cachesRoot.appendingPathComponent("f.bin"))
        try chmod000(cachesRoot)
        addTeardownBlock { [fm, cachesRoot] in
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: cachesRoot!.path)
        }

        let scanner = makeScanner()
        let outcome = await scanner.scan(
            context: ScanContext(trigger: .userInitiated)
        )
        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertEqual(outcome.errors.first?.kind, .permissionDenied,
                       "a root-level denial is a classified error — never an "
                       + "empty-looking success (D6)")

        restorePerms(cachesRoot)
    }

    // MARK: - R6/R9 support: stable ids, symlink identity, honest empty rows

    func testStableIDsSurviveRescan() async throws {
        for name in ["com.apple.SwiftUI.Drag-STABLE", "plain-entry"] {
            let entry = cachesRoot.appendingPathComponent(name)
            try mkdir(entry)
            try writeFile(entry.appendingPathComponent("f.bin"))
        }
        let scanner = makeScanner()
        let (first, _) = await scanItems(scanner)
        let (second, _) = await scanItems(scanner)

        XCTAssertEqual(
            first.mapValues(\.id), second.mapValues(\.id),
            "same fixture, same ids — selection survives rescan (fn-2)"
        )
    }

    func testTwoSymlinkEntriesSharingOneTargetGetDistinctStableIDs() async throws {
        let target = base.appendingPathComponent("shared-target")
        try mkdir(target)
        try writeFile(target.appendingPathComponent("payload.bin"))
        let linkA = cachesRoot.appendingPathComponent("link-a")
        let linkB = cachesRoot.appendingPathComponent("link-b")
        try fm.createSymbolicLink(at: linkA, withDestinationURL: target)
        try fm.createSymbolicLink(at: linkB, withDestinationURL: target)
        // A real entry so the outcome is not empty-only.
        let real = cachesRoot.appendingPathComponent("real-entry")
        try mkdir(real)
        try writeFile(real.appendingPathComponent("f.bin"))

        let scanner = makeScanner()
        let (items, outcome) = await scanItems(scanner)
        // Duplicate ids would malform the WHOLE outcome — the identity path
        // keeps the leaf unresolved, so the links stay distinct.
        try assertValidates(outcome, scanner: scanner)

        let a = try XCTUnwrap(items["link-a"])
        let b = try XCTUnwrap(items["link-b"])
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.state, .empty, "a symlink entry sizes 0, never walked")
        XCTAssertTrue(
            a.url?.path.hasSuffix("/link-a") == true,
            "identity keeps the UNRESOLVED leaf — display never points at "
            + "the external target: \(a.url?.path ?? "nil")"
        )

        let (rescan, _) = await scanItems(scanner)
        XCTAssertEqual(rescan["link-a"]?.id, a.id)
        XCTAssertEqual(rescan["link-b"]?.id, b.id)
    }

    func testLeakGlobSymlinkIsHonestEmptyRowAndCleanerSkipsIt() async throws {
        let target = base.appendingPathComponent("link-target")
        try mkdir(target)
        let payload = try writeFile(target.appendingPathComponent("keep.bin"))
        let link = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-LINK")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let scanner = makeScanner()
        let runtime = try makeRuntime([scanner])
        let session = runtime.scanValidatedSession(
            context: ScanContext(trigger: .userInitiated)
        )
        var items: [ReclaimableItem] = []
        for await event in session.events {
            if case .outcome(_, let outcome) = event { items = outcome.items }
        }
        let row = try XCTUnwrap(
            items.first { $0.displayName == link.lastPathComponent },
            "a classified-name symlink is LISTED (output rule) as an honest row"
        )
        XCTAssertEqual(row.state, .empty)
        XCTAssertFalse(row.defaultSelected,
                       "an .empty row is unselectable in every surface")
        XCTAssertFalse(row.automaticCleanEligible)

        // The cleaner skips `.empty` before admission: no entry, no error,
        // link and target untouched.
        let cleaner = runtime.makeCleaner(snapshot: session.snapshot)
        let report = await cleaner.clean(items: [row], moveToTrash: false)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertNotNil(try? fm.attributesOfItem(atPath: link.path),
                        "the link itself survives the skip")
        XCTAssertTrue(fm.fileExists(atPath: payload.path))
    }

    // MARK: - R8: stale-large thresholds + isStale mapping

    func testStaleLargeClassificationAndIsStaleMapping() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = cachesRoot.appendingPathComponent("stale-large")
        try mkdir(stale)
        let staleFile = try writeFile(stale.appendingPathComponent("old.bin"), bytes: 8192)
        try setModificationDate(staleFile, now.addingTimeInterval(-90 * 86_400))

        let fresh = cachesRoot.appendingPathComponent("fresh-small")
        try mkdir(fresh)
        let freshFile = try writeFile(fresh.appendingPathComponent("new.bin"))
        try setModificationDate(freshFile, now.addingTimeInterval(-3_600))

        let scanner = makeScanner(
            thresholds: OrphanedCacheClassifier.Thresholds(
                sizeFloorBytes: 4096, staleAge: 60 * 86_400
            ),
            now: { now }
        )
        let (items, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        let staleItem = try XCTUnwrap(items["stale-large"])
        XCTAssertTrue(staleItem.evidence.contains("untouched 90 days"),
                      staleItem.evidence)
        XCTAssertEqual(staleItem.risk, .review)
        XCTAssertEqual(staleItem.isStale, true)
        XCTAssertFalse(staleItem.automaticCleanEligible)

        let freshItem = try XCTUnwrap(items["fresh-small"])
        XCTAssertEqual(freshItem.isStale, false,
                       "dated content below the thresholds is known-fresh")
    }

    // MARK: - R8: config defaults, persistence, validation

    func testConfigDefaultsAreFiftyMBSixtyDaysDecimal() {
        XCTAssertEqual(
            OrphanedCachesSweepConfig.defaultThresholds.sizeFloorBytes,
            50_000_000, "decimal MB — base-10, matching display convention"
        )
        XCTAssertEqual(
            OrphanedCachesSweepConfig.defaultThresholds.staleAge,
            60 * 86_400
        )
    }

    func testConfigConversionsAreOverflowCheckedNeverTrapping() {
        XCTAssertEqual(OrphanedCachesSweepConfig.sizeFloorBytes(fromMB: 1),
                       1_000_000, "boundary-valid: 1 MB")
        XCTAssertEqual(OrphanedCachesSweepConfig.staleAge(fromDays: 1),
                       86_400, "boundary-valid: 1 day")
        XCTAssertNil(OrphanedCachesSweepConfig.sizeFloorBytes(fromMB: 0))
        XCTAssertNil(OrphanedCachesSweepConfig.sizeFloorBytes(fromMB: -50))
        XCTAssertNil(OrphanedCachesSweepConfig.sizeFloorBytes(fromMB: .max),
                     "overflow is nil, never a trap")
        XCTAssertNil(OrphanedCachesSweepConfig.staleAge(fromDays: 0))
        XCTAssertNil(OrphanedCachesSweepConfig.staleAge(fromDays: -1))
        XCTAssertNil(OrphanedCachesSweepConfig.staleAge(fromDays: .max))
    }

    func testPersistedValuesHonoredAndInvalidOnesFallBackWithoutRewrite() throws {
        let defaults = try makeDefaultsSuite()

        // Valid persisted values are honored.
        defaults.set(100, forKey: OrphanedCachesSweepConfig.sizeFloorMBKey)
        defaults.set(7, forKey: OrphanedCachesSweepConfig.staleAgeDaysKey)
        var resolved = OrphanedCachesSweepConfig.resolvedThresholds(defaults: defaults)
        XCTAssertEqual(resolved.sizeFloorBytes, 100_000_000)
        XCTAssertEqual(resolved.staleAge, 7 * 86_400)

        // Invalid persisted values (zero/negative/non-numeric/non-integral/
        // overflow) fall back to the DEFAULT for that scan — and are NOT
        // rewritten (a value this build cannot read may be meaningful to
        // another build).
        // `true` bridges to NSNumber(1) — a boolean is NOT a
        // positive-integer threshold (review r2).
        let invalids: [Any] = [0, -5, "garbage", 50.5, Int64.max, true]
        for invalid in invalids {
            defaults.set(invalid, forKey: OrphanedCachesSweepConfig.sizeFloorMBKey)
            resolved = OrphanedCachesSweepConfig.resolvedThresholds(defaults: defaults)
            XCTAssertEqual(
                resolved.sizeFloorBytes,
                OrphanedCachesSweepConfig.defaultThresholds.sizeFloorBytes,
                "invalid persisted value \(invalid) falls back to the default"
            )
            let stillStored = defaults.object(
                forKey: OrphanedCachesSweepConfig.sizeFloorMBKey
            )
            XCTAssertNotNil(stillStored, "never rewritten")
            XCTAssertEqual(stillStored as? NSObject, invalid as? NSObject,
                           "the stored value survives unchanged")
        }

        // A numeric-string persisted value parses (positive integer).
        defaults.set("25", forKey: OrphanedCachesSweepConfig.sizeFloorMBKey)
        resolved = OrphanedCachesSweepConfig.resolvedThresholds(defaults: defaults)
        XCTAssertEqual(resolved.sizeFloorBytes, 25_000_000)
    }

    func testCLIOverrideWinsForInvocationOnlyAndIsNeverPersisted() throws {
        let defaults = try makeDefaultsSuite()
        defaults.set(100, forKey: OrphanedCachesSweepConfig.sizeFloorMBKey)

        let resolved = OrphanedCachesSweepConfig.resolvedThresholds(
            defaults: defaults, sizeFloorMBOverride: 7, staleAgeDaysOverride: 3
        )
        XCTAssertEqual(resolved.sizeFloorBytes, 7_000_000,
                       "the invocation-scoped override beats the persisted value")
        XCTAssertEqual(resolved.staleAge, 3 * 86_400)
        XCTAssertEqual(
            defaults.integer(forKey: OrphanedCachesSweepConfig.sizeFloorMBKey),
            100, "the override is never persisted"
        )
        XCTAssertNil(
            defaults.object(forKey: OrphanedCachesSweepConfig.staleAgeDaysKey),
            "an override never creates a persisted value either"
        )
    }

    func testCLIFlagParsingRejectsInvalidValuesPerConvention() throws {
        // Absent flags parse as no overrides.
        let none = try CLIHandler.parseSweepThresholdOverrides(from: ["scan"]).get()
        XCTAssertNil(none.sizeFloorMB)
        XCTAssertNil(none.staleAgeDays)

        // Valid values, boundary included.
        let both = try CLIHandler.parseSweepThresholdOverrides(from: [
            "scan", "--orphan-size-floor-mb", "1", "--orphan-stale-days", "1",
        ]).get()
        XCTAssertEqual(both.sizeFloorMB, 1)
        XCTAssertEqual(both.staleAgeDays, 1)

        // Zero, negative, non-numeric, missing, and overflowing values are
        // REJECTED via the invalid-arguments convention.
        let bad: [[String]] = [
            ["--orphan-size-floor-mb", "0"],
            ["--orphan-size-floor-mb", "-5"],
            ["--orphan-size-floor-mb", "fifty"],
            ["--orphan-size-floor-mb"],
            ["--orphan-size-floor-mb", "\(Int64.max)"],  // conversion overflow
            ["--orphan-stale-days", "0"],
            ["--orphan-stale-days", "garbage"],
            ["--orphan-stale-days", "\(Int64.max)"],
            // A repeated flag is rejected outright — first-/last-wins would
            // silently ignore (and skip validating) one occurrence.
            ["--orphan-size-floor-mb", "1", "--orphan-size-floor-mb", "garbage"],
            ["--orphan-stale-days", "2", "--orphan-stale-days", "3"],
        ]
        for args in bad {
            switch CLIHandler.parseSweepThresholdOverrides(from: ["scan"] + args) {
            case .success(let parsed):
                XCTFail("\(args) must be rejected, parsed \(parsed)")
            case .failure(let error):
                XCTAssertTrue(error.message.contains(try XCTUnwrapElement(args, 0)),
                              "the refusal names the flag: \(error.message)")
            }
        }
    }

    func testSmartCleanRejectsSweepFlags() {
        XCTAssertEqual(
            CLIHandler.smartCleanRejectedSweepFlag(
                in: ["smart-clean", "5", "--orphan-size-floor-mb", "10"]
            ),
            "--orphan-size-floor-mb"
        )
        XCTAssertEqual(
            CLIHandler.smartCleanRejectedSweepFlag(
                in: ["smart-clean", "--orphan-stale-days", "10"]
            ),
            "--orphan-stale-days"
        )
        XCTAssertNil(CLIHandler.smartCleanRejectedSweepFlag(
            in: ["smart-clean", "5", "--confirm"]
        ))
    }

    func testProductionFactoryThreadsThresholdsIntoTheScanner() {
        let thresholds = OrphanedCacheClassifier.Thresholds(
            sizeFloorBytes: 123_000_000, staleAge: 9 * 86_400
        )
        let runtime = SpaceScannerRuntime.production(
            home: home, orphanedCachesThresholds: thresholds
        )
        let scanner = runtime.scanners
            .compactMap { $0 as? OrphanedCachesScanner }.first
        XCTAssertEqual(scanner?.thresholds, thresholds,
                       "invocation-scoped thresholds reach the scanner "
                       + "unchanged through the composition site")
        XCTAssertEqual(scanner?.cachesRoot.path,
                       home.appendingPathComponent("Library/Caches").path)
    }

    // MARK: - R9: PathGuard container admission (unit, as-built guard)

    func testContainerAdmissionMatrixAgainstAsBuiltPathGuard() throws {
        let entry = cachesRoot.appendingPathComponent("some-entry")
        try mkdir(entry)
        let provider = FileSystemIdentityProvider()
        let pathGuard = PathGuard(
            home: home, containerRoots: [cachesRoot!], provider: provider
        )
        let snapshot = ContainerSnapshot.capture(
            roots: [cachesRoot], provider: provider
        )

        // A first-level entry is admitted via container + item validation.
        let container = try pathGuard.admitContainer(cachesRoot, snapshot: snapshot)
        XCTAssertNoThrow(
            try pathGuard.validateRemovableItem(entry, inside: container)
        )

        // The container ITSELF is refused as a removable item.
        XCTAssertThrowsError(
            try pathGuard.validateRemovableItem(cachesRoot, inside: container)
        ) {
            guard case .isRootItself? = $0 as? PathGuardError else {
                return XCTFail("expected isRootItself, got \($0)")
            }
        }

        // A path OUTSIDE the container is refused.
        XCTAssertThrowsError(
            try pathGuard.validateRemovableItem(
                base.appendingPathComponent("outside"), inside: container
            )
        ) {
            guard case .notADescendant? = $0 as? PathGuardError else {
                return XCTFail("expected notADescendant, got \($0)")
            }
        }

        // A symlink LEAF inside the container is ADMITTED (leaf-unresolved
        // doctrine): deleting it removes the LINK, never the target.
        let target = base.appendingPathComponent("external-target")
        try mkdir(target)
        let payload = try writeFile(target.appendingPathComponent("keep.bin"))
        let link = cachesRoot.appendingPathComponent("link-entry")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNoThrow(
            try pathGuard.validateRemovableItem(link, inside: container)
        )
        try fm.removeItem(at: link)
        XCTAssertNil(try? fm.attributesOfItem(atPath: link.path))
        XCTAssertTrue(fm.fileExists(atPath: payload.path),
                      "removal deletes only the link — the external target's "
                      + "content survives untouched")
    }

    func testAdmissionModeSplitTraversalWorksWithoutSnapshotDeletionDoesNot() async throws {
        let entry = cachesRoot.appendingPathComponent("victim")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("f.bin"))
        let pathGuard = PathGuard(home: home, containerRoots: [cachesRoot!])

        // Scan-time traversal admission needs NO snapshot (the node_modules
        // scan path is unchanged) — and its token is not a deletion
        // capability (`validateRemovableItem` does not accept it;
        // compile-time enforced by the type split).
        XCTAssertNoThrow(try pathGuard.admitSearchRoot(cachesRoot))

        // Runtime face of the type rule: a cleaner WITHOUT a session
        // snapshot refuses every `.removeItem` — fail-closed, tagged.
        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))
        let item = try XCTUnwrap(outcome.items.first)
        let cleaner = CacheCleaner(
            home: home, containerRoots: [cachesRoot!], containerSnapshot: nil
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(report.errors.first?.message)
                .contains("Container is unavailable"),
            report.errors.first?.message ?? ""
        )
        XCTAssertTrue(fm.fileExists(atPath: entry.path))
        try assertCleanupLogContains(tag: "container-unavailable")
    }

    /// The cleanup log's refusal tag — classified off the TYPED error case.
    private func assertCleanupLogContains(
        tag: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let log = home.appendingPathComponent(".cacheout/cleanup.log")
        let contents = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(contents.contains("REFUSED [\(tag)]"),
                      "expected a [\(tag)] refusal in:\n\(contents)",
                      file: file, line: line)
    }

    // MARK: - R9: container-swap gate, end-to-end

    /// Scan a REAL fixture root through a validated session, returning the
    /// produced items and the session snapshot.
    private func scanSession(
        _ runtime: SpaceScannerRuntime
    ) async -> (items: [ReclaimableItem], snapshot: ContainerSnapshot) {
        let session = runtime.scanValidatedSession(
            context: ScanContext(trigger: .userInitiated)
        )
        var items: [ReclaimableItem] = []
        for await event in session.events {
            if case .outcome(_, let outcome) = event { items = outcome.items }
        }
        return (items, session.snapshot)
    }

    func testSymlinkSwapAfterScanIsRefusedAndExternalTreeUntouched() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-SWAP")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let runtime = try makeRuntime([makeScanner()])
        let (items, snapshot) = await scanSession(runtime)
        let item = try XCTUnwrap(items.first)

        // Between scan and clean: replace ~/Library/Caches with a symlink
        // to a populated external tree carrying a same-named entry.
        let external = base.appendingPathComponent("external-tree")
        let externalEntry = external.appendingPathComponent(entry.lastPathComponent)
        try mkdir(externalEntry)
        let victim = externalEntry.appendingPathComponent("victim.bin")
        let victimBytes = Data(repeating: 0x5A, count: 4096)
        try victimBytes.write(to: victim)
        try fm.removeItem(at: cachesRoot)
        try fm.createSymbolicLink(at: cachesRoot, withDestinationURL: external)

        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty, "nothing deleted")
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(report.errors.first?.message)
                .contains("Container is unavailable"),
            report.errors.first?.message ?? ""
        )
        try assertCleanupLogContains(tag: "container-unavailable")
        XCTAssertEqual(try Data(contentsOf: victim), victimBytes,
                       "the external tree is byte-for-byte untouched")
        XCTAssertTrue(fm.fileExists(atPath: externalEntry.path))
    }

    func testDirectoryInodeSwapIsRefusedUntilRescanRecaptures() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-INODE")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let runtime = try makeRuntime([makeScanner()])
        let (items, snapshot) = await scanSession(runtime)
        let item = try XCTUnwrap(items.first)

        // Same-path DIRECTORY swap: rm + mkdir → same spelling, new inode.
        try fm.removeItem(at: cachesRoot)
        try mkdir(cachesRoot)
        let recreated = cachesRoot.appendingPathComponent(entry.lastPathComponent)
        try mkdir(recreated)
        try writeFile(recreated.appendingPathComponent("new-payload.bin"))

        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [item], moveToTrash: false)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(report.errors.first?.message)
                .contains("Container is unavailable"),
            report.errors.first?.message ?? ""
        )
        XCTAssertTrue(fm.fileExists(atPath: recreated.path),
                      "the recreated container's content is untouched")

        // Fail-closed, SELF-HEALING: the next session re-captures the new
        // identity and its own items clean normally.
        let (rescanned, freshSnapshot) = await scanSession(runtime)
        let freshItem = try XCTUnwrap(rescanned.first)
        let freshCleaner = runtime.makeCleaner(snapshot: freshSnapshot)
        let freshReport = await freshCleaner.clean(
            items: [freshItem], moveToTrash: false
        )
        XCTAssertTrue(freshReport.errors.isEmpty, "\(freshReport.errors)")
        XCTAssertEqual(freshReport.entries.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: recreated.path),
                       "after rescan the entry directory itself is deleted")
    }

    func testContainerSwappedDuringScanAfterCaptureIsRefused() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-MID")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        // A gate between capture and walk makes the mid-scan swap
        // DETERMINISTIC: the session captures the container identity at
        // creation, the swap happens while the walk is still held, and the
        // walk then enumerates the swapped (recreated) root.
        let gate = ScanHoldGate()
        let runtime = try makeRuntime([DelegatingGatedSweepScanner(
            inner: makeScanner(), gate: gate
        )])
        let session = runtime.scanValidatedSession(
            context: ScanContext(trigger: .userInitiated)
        )
        try fm.removeItem(at: cachesRoot)
        try mkdir(cachesRoot)
        let recreated = cachesRoot.appendingPathComponent(entry.lastPathComponent)
        try mkdir(recreated)
        try writeFile(recreated.appendingPathComponent("swapped.bin"))
        await gate.open()

        var items: [ReclaimableItem] = []
        for await event in session.events {
            if case .outcome(_, let outcome) = event { items = outcome.items }
        }
        let item = try XCTUnwrap(items.first,
                                 "the scan enumerated the swapped directory")

        // Delete time: the captured identity predates the swap → refused.
        let cleaner = runtime.makeCleaner(snapshot: session.snapshot)
        let report = await cleaner.clean(items: [item], moveToTrash: false)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: recreated.path))
    }

    func testRootAbsentAtRuntimeCreationButPresentAtScanIsCleanable() async throws {
        // The capture-at-SESSION rule (a capture-at-construction snapshot
        // would break this — the node_modules regression the epic pins).
        try fm.removeItem(at: cachesRoot)
        let runtime = try makeRuntime([makeScanner()])

        // The container comes into existence AFTER runtime construction,
        // BEFORE the session.
        try mkdir(cachesRoot)
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-LATE")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let (items, snapshot) = await scanSession(runtime)
        let item = try XCTUnwrap(items.first)
        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: entry.path),
                       "cleanable in the session that captured the new root")
    }

    // MARK: - R9: clean end-to-end (entry directory itself; trash honored)

    func testCleanDeletesEntryDirectoryItselfLeavingNoMarker() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-GONE")
        try mkdir(entry.appendingPathComponent("nested"))
        try writeFile(entry.appendingPathComponent("nested/payload.bin"))
        let survivor = cachesRoot.appendingPathComponent("survivor-entry")
        try mkdir(survivor)
        try writeFile(survivor.appendingPathComponent("keep.bin"))

        let runtime = try makeRuntime([makeScanner()])
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(
            items.first { $0.displayName == entry.lastPathComponent }
        )

        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [leak], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: entry.path),
                       "the ENTRY DIRECTORY itself is deleted — no empty "
                       + "leak-marker directory remains")
        XCTAssertTrue(fm.fileExists(atPath: survivor.path),
                      "unselected entries are untouched")
        XCTAssertTrue(fm.fileExists(atPath: cachesRoot.path),
                      "the sweep root itself survives")
    }

    func testCleanHonorsTrashSettingThroughTheSeam() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-TRASH")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let trashDir = base.appendingPathComponent("fake-trash")
        try mkdir(trashDir)

        let runtime = try makeRuntime([makeScanner()])
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)

        let recorder = TrashURLRecorder()
        let cleaner = runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in
                recorder.record(url)
                let landed = trashDir
                    .appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: landed)
                return landed
            }
        )
        let report = await cleaner.clean(items: [leak], moveToTrash: true)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.disposal, .trash)
        XCTAssertEqual(recorder.urls.map(\.lastPathComponent),
                       [entry.lastPathComponent],
                       "trash mode trashes the entry directory itself")
        XCTAssertEqual(recorder.urls.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: entry.path))
        XCTAssertTrue(fm.fileExists(
            atPath: trashDir.appendingPathComponent(entry.lastPathComponent).path
        ))
    }

    // MARK: - Delete-time revalidation probe (PR #456 review)

    func testPreDeleteUserDataProbeKindGatingAndFailClosed() throws {
        let provider = FileSystemIdentityProvider()

        // (a) Real directory holding a user-data shape → matched, complete.
        let shaped = cachesRoot.appendingPathComponent("shaped-entry")
        try mkdir(shaped.appendingPathComponent("Pictures"))
        var result = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: shaped, provider: provider
        )
        XCTAssertEqual(result.matches, ["pictures-directory"])
        XCTAssertTrue(result.complete)

        // (b) Clean directory → no matches, complete.
        let clean = cachesRoot.appendingPathComponent("clean-entry")
        try mkdir(clean)
        try writeFile(clean.appendingPathComponent("cache.bin"))
        result = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: clean, provider: provider
        )
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.complete)

        // (c) Absent target → clean and complete: the deletion path owns
        // the ENOENT surfacing (frozen ghost asymmetry) — the probe must
        // not preempt it with a refusal.
        result = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: cachesRoot.appendingPathComponent("never-existed"),
            provider: provider
        )
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.complete)

        // (d) Symlink at the target — even one pointing at a tree full of
        // user data — is NEVER followed: deletion removes the link, not
        // the target, so nothing deletable goes uninspected.
        let external = base.appendingPathComponent("external-userdata")
        try mkdir(external.appendingPathComponent("Pictures"))
        let link = cachesRoot.appendingPathComponent("link-entry")
        try fm.createSymbolicLink(at: link, withDestinationURL: external)
        result = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: link, provider: provider
        )
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.complete)

        // (e) DEPTH alone never truncates: the entry budget is the one
        // bound, so a tree it can afford is walked whole and PROVEN.
        let deep = cachesRoot.appendingPathComponent("deep-entry")
        try mkdir(deep.appendingPathComponent("a/b/c/d/e/f/g/h/i/j"))
        result = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: deep, provider: provider
        )
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.complete,
                      "nothing obstructed this walk — a deterministic depth "
                          + "verdict here could never be cleared by any retry")

        // (f) A GENUINELY obstructed branch is still fail-closed.
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let blocked = cachesRoot.appendingPathComponent("blocked-entry")
        let locked = blocked.appendingPathComponent("locked-sub")
        try mkdir(locked)
        try chmod000(locked)
        defer { restorePerms(locked) }
        result = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: blocked, provider: provider
        )
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertFalse(result.complete,
                       "an unreadable branch means absence of matches is unproven")
    }

    func testPreDeleteProbeMatchesCaseVariants() throws {
        // Delete-time face of the FNM_CASEFOLD fix (PR #456 review): both
        // probe faces share one static core, so a differently cased
        // user-data name is caught here too.
        let entry = cachesRoot.appendingPathComponent("cased-entry")
        try mkdir(entry.appendingPathComponent("PICTURES"))

        let result = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: entry, provider: FileSystemIdentityProvider()
        )

        XCTAssertEqual(result.matches, ["pictures-directory"])
        XCTAssertTrue(result.complete)
    }

    func testEntryRecreatedAfterScanWithUserDataIsRefusedAtDeleteTime() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-REBORN")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let runtime = try makeRuntime([makeScanner()])
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)
        XCTAssertTrue(leak.automaticCleanEligible,
                      "the fixture entry scans as a clean known leak")

        // The ENTRY — not the container — is removed and recreated at the
        // same name with user-data-shaped content the scan never saw. The
        // session snapshot binds the CONTAINER's identity and still
        // matches, so only the pre-delete revalidation stands between
        // Quick Clean and the uninspected content.
        try fm.removeItem(at: entry)
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        try mkdir(library)
        let victim = try writeFile(library.appendingPathComponent("database.db"))

        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [leak], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty, "nothing deleted")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("contents changed since scan"), message)
        XCTAssertTrue(fm.fileExists(atPath: victim.path),
                      "the recreated content is byte-untouched")
        try assertCleanupLogContains(tag: "content-drift")

        // Self-healing: a fresh session inspects the recreated content and
        // classifies it honestly — review risk with the caution evidence,
        // never auto-eligible.
        let (rescanned, _) = await scanSession(runtime)
        let fresh = try XCTUnwrap(rescanned.first)
        XCTAssertFalse(fresh.automaticCleanEligible)
        XCTAssertEqual(fresh.risk, .review)
        XCTAssertTrue(fresh.evidence.contains(
            "verify the original still exists before deleting"
        ), fresh.evidence)
        XCTAssertFalse(fresh.requiresPreDeleteRevalidation,
                       "a non-eligible sweep item keeps its accepted "
                           + "conscious-confirmation residual, unmarked")
    }

    // MARK: - Revalidator seam migration (fn-4.8, R17/D8)

    func testMarkerEmittedForExactlyTheAutoCleanEligibleSweepEntries() async throws {
        // The migration's emission half: the scanner-agnostic
        // `requiresPreDeleteRevalidation` marker rides EXACTLY the set the
        // registered revalidator's predicate deems applicable — the entries
        // the removed hard-coded cleaner gate re-probed. One scan, both
        // shapes.
        let clean = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-CLEAN")
        try mkdir(clean)
        try writeFile(clean.appendingPathComponent("payload.bin"))
        let shaped = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-SHAPED")
        try mkdir(shaped.appendingPathComponent("Pictures"))
        try writeFile(shaped.appendingPathComponent("payload.bin"))

        let scanner = makeScanner()
        let (byName, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        let eligible = try XCTUnwrap(byName["com.apple.SwiftUI.Drag-CLEAN"])
        XCTAssertTrue(eligible.automaticCleanEligible)
        XCTAssertTrue(eligible.requiresPreDeleteRevalidation,
                      "an auto-clean-eligible sweep entry is marked")

        let reviewed = try XCTUnwrap(byName["com.apple.SwiftUI.Drag-SHAPED"])
        XCTAssertFalse(reviewed.automaticCleanEligible)
        XCTAssertFalse(reviewed.requiresPreDeleteRevalidation,
                       "a review-tier entry stays unmarked — behavior preserved")

        // The predicate and the emission agree ITEM FOR ITEM: that equality
        // is what the runtime's marker invariant enforces.
        let revalidator = OrphanedCachesScanner.preDeleteRevalidator(
            provider: FileSystemIdentityProvider()
        )
        for item in outcome.items {
            XCTAssertEqual(
                revalidator.requiresRevalidation(item: item),
                item.requiresPreDeleteRevalidation,
                "declared applicability must match the emitted marker: "
                    + item.displayName
            )
        }
    }

    func testMarkerForgottenApplicableItemFailsRuntimeValidation() async throws {
        // BELT-AND-BRACES, the scan-time half (the cleaner half — the same
        // shape still re-probed at the chokepoint — lives in
        // `CacheCleanerTests`). A mapping regression that emits an
        // `automaticCleanEligible` entry WITHOUT the marker is a structural
        // violation: the whole outcome is replaced by the synthesized
        // path-less `malformed_outcome`, so nothing from it is listable,
        // addressable, or deletable. This invariant is what allowed the old
        // hard-coded cleaner gate to be removed in the same change.
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-UNMARKED")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let scanner = makeScanner()
        let (_, outcome) = await scanItems(scanner)
        let emitted = try XCTUnwrap(outcome.items.first)
        XCTAssertTrue(emitted.requiresPreDeleteRevalidation)

        // The HONEST outcome validates; only the stripped one malforms —
        // so the fixture proves the marker, not some unrelated field.
        let runtime = try makeRuntime([scanner])
        guard case .outcome = runtime.validatedOutcome(
            outcome, from: OrphanedCachesScanner.registeredID
        ) else {
            return XCTFail("the marked outcome must validate")
        }

        let stripped = ScanOutcome(
            items: [Self.withoutRevalidationMarker(emitted)],
            errors: outcome.errors
        )
        switch runtime.validatedOutcome(
            stripped, from: OrphanedCachesScanner.registeredID
        ) {
        case .outcome:
            XCTFail("an applicable-but-unmarked item must malform the outcome")
        case .malformed(let scannerID, let issue):
            XCTAssertEqual(scannerID, OrphanedCachesScanner.registeredID)
            XCTAssertEqual(issue.kind, .malformedOutcome)
            XCTAssertNil(issue.url, "the synthesized issue is path-less")
            XCTAssertTrue(
                issue.detail.contains("requiresPreDeleteRevalidation"),
                issue.detail
            )
        }
    }

    /// The mapping regression, spelled out: the SAME item with the marker
    /// dropped (every other field byte-identical).
    private static func withoutRevalidationMarker(
        _ item: ReclaimableItem
    ) -> ReclaimableItem {
        ReclaimableItem(
            id: item.id, scannerID: item.scannerID,
            displayName: item.displayName,
            exactBytes: item.exactBytes,
            estimatedUpToBytes: item.estimatedUpToBytes,
            logicalBytes: item.logicalBytes, itemCount: item.itemCount,
            url: item.url, declaredDisplayPath: item.declaredDisplayPath,
            rootRecords: item.rootRecords, state: item.state,
            scanError: item.scanError, risk: item.risk,
            evidence: item.evidence, rebuildNote: item.rebuildNote,
            action: item.action, admission: item.admission,
            defaultSelected: item.defaultSelected,
            automaticCleanEligible: item.automaticCleanEligible,
            isStale: item.isStale,
            valuablesDisclosure: item.valuablesDisclosure,
            requiresPreDeleteRevalidation: false
        )
    }

    func testCaseVariantUserDataForcesReviewAtScanTime() async throws {
        // Scan-time face of the FNM_CASEFOLD fix (PR #456 review): a
        // leak-named entry holding `DOCUMENTS` — a differently cased
        // user-data name — must classify exactly like the exact-case
        // fixture: review risk, never default-selected, never
        // auto-clean-eligible.
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-CASE")
        try mkdir(entry.appendingPathComponent("DOCUMENTS"))
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let scanner = makeScanner()
        let (byName, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(byName["com.apple.SwiftUI.Drag-CASE"])
        XCTAssertEqual(item.risk, .review, "forced off safe by the guard")
        XCTAssertFalse(item.defaultSelected)
        XCTAssertFalse(item.automaticCleanEligible)
        XCTAssertTrue(item.evidence.contains("user-data-shaped content"),
                      item.evidence)
    }

    func testEntryRecreatedWithCaseVariantUserDataIsRefusedAtDeleteTime() async throws {
        // The recreation TOCTOU with a CASE-VARIANT payload: without
        // FNM_CASEFOLD the delete-time revalidation reported clean and the
        // recreated user data was deleted.
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-CASED")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let runtime = try makeRuntime([makeScanner()])
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)
        XCTAssertTrue(leak.automaticCleanEligible,
                      "the fixture entry scans as a clean known leak")

        try fm.removeItem(at: entry)
        let library = entry.appendingPathComponent(
            "PICTURES/Photos Library.PHOTOSLIBRARY"
        )
        try mkdir(library)
        let victim = try writeFile(library.appendingPathComponent("database.db"))

        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [leak], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty, "nothing deleted")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("contents changed since scan"), message)
        XCTAssertTrue(fm.fileExists(atPath: victim.path),
                      "the case-variant recreated content is byte-untouched")
    }

    // MARK: - One budget, no depth cap (PR #456 follow-up)

    /// A directory chain far deeper than the retired three-level cap — the
    /// shape ordinary caches reach constantly (this machine's own
    /// `~/Library/Caches` nests fourteen levels in `com.microsoft.VSCode.ShipIt`).
    private func deepChain(_ levels: Int) -> String {
        (1...levels).map { "d\($0)" }.joined(separator: "/")
    }

    /// A realistically deep AND large orphaned cache holding nothing
    /// user-data-shaped. Under the retired bounds (depth 3 / 512 entries)
    /// this probed INCOMPLETE — deterministically, so every re-scan and
    /// every delete-time re-probe reproduced it — which forced a clean
    /// known leak off `.safe`, out of `defaultSelected`, and out of every
    /// automatic path FOREVER, over evidence claiming the contents could
    /// not be inspected when nothing had actually obstructed the walk.
    func testDeepLargeCleanLeakIsProvenCleanAndStaysAutoEligible() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-DEEP")
        let leaf = entry.appendingPathComponent(deepChain(12))
        try mkdir(leaf)
        try writeFile(leaf.appendingPathComponent("payload.bin"))
        // …and wider than the retired 512-entry budget.
        let wide = entry.appendingPathComponent("blobs")
        try mkdir(wide)
        for index in 0..<600 {
            try writeFile(wide.appendingPathComponent("b\(index).bin"), bytes: 8)
        }

        let scanner = makeScanner()
        let (byName, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        let item = try XCTUnwrap(byName["com.apple.SwiftUI.Drag-DEEP"])
        XCTAssertFalse(
            item.evidence.contains("couldn't fully inspect"),
            "nothing obstructed this walk — the probe must not manufacture "
                + "uncertainty it can afford to resolve: \(item.evidence)"
        )
        XCTAssertEqual(item.risk, .safe)
        XCTAssertTrue(item.defaultSelected)
        XCTAssertTrue(item.automaticCleanEligible,
                      "a deterministic bound made this permanently ineligible "
                          + "for Quick Clean and CLI smart-clean")
    }

    /// The safety half, and the reason removing the depth cap is not merely
    /// an optimism change: user data sitting BELOW the retired boundary was
    /// never seen at all. The old probe reported "no matches, incomplete";
    /// it must now report the match itself, on BOTH faces.
    func testUserDataBelowTheRetiredDepthBoundaryIsFoundOnBothFaces() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-BURIED")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let buried = entry.appendingPathComponent(
            "\(deepChain(6))/Pictures/Photos Library.photoslibrary"
        )
        try mkdir(buried)

        // Scan-time face.
        let scanner = makeScanner()
        let (byName, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)
        let item = try XCTUnwrap(byName["com.apple.SwiftUI.Drag-BURIED"])
        XCTAssertEqual(item.risk, .review, "the buried match forces it off safe")
        XCTAssertFalse(item.automaticCleanEligible)
        XCTAssertTrue(item.evidence.contains(
            "user-data-shaped content (photos-library, pictures-directory)"
        ), item.evidence)

        // Delete-time face — the SAME core, the SAME bound.
        let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: entry, provider: FileSystemIdentityProvider()
        )
        XCTAssertEqual(probe.matches, ["photos-library", "pictures-directory"])
        XCTAssertTrue(probe.complete)
    }

    /// Scan time and delete time must agree on the same static tree — they
    /// read ONE constant, so a tree either surface can afford is proven by
    /// both.
    func testScanTimeAndDeleteTimeProbesAgreeOnADeepTree() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-AGREE")
        try mkdir(entry.appendingPathComponent(deepChain(20)))
        try writeFile(entry.appendingPathComponent("payload.bin"))

        guard case .entries(let facts) = makeScanner().enumerateFacts() else {
            return XCTFail("expected facts")
        }
        let fact = try XCTUnwrap(facts.first { $0.name == entry.lastPathComponent })
        let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: entry, provider: FileSystemIdentityProvider()
        )

        XCTAssertTrue(fact.userDataProbeComplete)
        XCTAssertEqual(fact.userDataProbeComplete, probe.complete)
        XCTAssertEqual(fact.userDataShapeMatches, probe.matches)
    }

    // MARK: - Mount boundaries stop the probe (PR #458 review)

    /// Records every no-follow kind probe — the walk's ONE per-entry syscall
    /// — and injects boundary conditions by inode, so "did not cross" is
    /// proven by the ABSENCE of any touch beyond the boundary rather than by
    /// an empty result (which an unrelated bug would also produce).
    private final class RecordingBoundaryProvider: FileSystemIdentityProvider {
        var deviceOverridesByInode: [UInt64: UInt64] = [:]
        var mountPointInodes: Set<UInt64> = []
        private(set) var probedPaths: [String] = []

        override func identity(of url: URL) -> Identity? {
            guard let id = super.identity(of: url) else { return nil }
            if let device = deviceOverridesByInode[id.inode] {
                return Identity(device: device, inode: id.inode)
            }
            return id
        }

        override func isMountPoint(_ url: URL) -> Bool {
            if let id = identity(of: url), mountPointInodes.contains(id.inode) {
                return true
            }
            return super.isMountPoint(url)
        }

        override func probeKind(of url: URL) -> KindProbe {
            probedPaths.append(url.standardizedFileURL.path)
            return super.probeKind(of: url)
        }

        /// The walk's ONE per-entry syscall, descriptor-relative. `logical`
        /// is the spelling the walk believes it is at — production ignores
        /// it, and recording it is how "did not cross" is proven by the
        /// ABSENCE of any touch rather than by an empty result.
        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            // Evaluated ONCE, here: the walk composes no path below its root
            // (hence the autoclosure), so a double that keys on the spelling
            // is the one that pays for composing it.
            let logical = logical()
            probedPaths.append(logical.standardizedFileURL.path)
            return super.probeChild(
                inDirectory: descriptor, named: name, logical: logical
            )
        }

        override func mountIdentity(ofDescriptor descriptor: Int32)
            -> MountIdentity? {
            guard let real = super.mountIdentity(ofDescriptor: descriptor),
                  let id = super.identity(ofDescriptor: descriptor)
            else { return nil }
            if mountPointInodes.contains(id.inode) {
                return OrphanedCachesScannerTests.injectedMount(
                    forInode: id.inode, device: real.device
                )
            }
            if let device = deviceOverridesByInode[id.inode] {
                return MountIdentity(
                    fsidMajor: real.fsidMajor, fsidMinor: real.fsidMinor,
                    device: device
                )
            }
            return real
        }

        func reset() { probedPaths = [] }

        /// Did anything STRICTLY BELOW `url` get touched?
        func touchedAnythingBelow(_ url: URL) -> Bool {
            let prefix = url.standardizedFileURL.path + "/"
            return probedPaths.contains { $0.hasPrefix(prefix) }
        }
    }

    /// A real mount point nested inside a cache entry must stop the walk.
    /// Removing the depth cap is what exposed this: the walk now descends
    /// every directory it can afford, so without this check it reads a
    /// foreign volume — latency, and privacy-sensitive access to a
    /// filesystem the user never pointed this scanner at — on an item the
    /// cleaner refuses whole anyway.
    func testProbeStopsAtANestedMountBoundaryAndNeverReadsPastIt() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.NestedMount")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let mounted = entry.appendingPathComponent("volume")
        try mkdir(mounted.appendingPathComponent("Pictures/Photos Library.photoslibrary"))

        let provider = RecordingBoundaryProvider()
        let inode = try XCTUnwrap(provider.identity(of: mounted)?.inode)
        provider.mountPointInodes.insert(inode)
        provider.reset()

        let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: entry, provider: provider
        )

        XCTAssertFalse(
            provider.touchedAnythingBelow(mounted),
            "not one entry of the mounted filesystem may be read: "
                + "\(provider.probedPaths)"
        )
        XCTAssertTrue(probe.matches.isEmpty,
                      "nothing past an uncrossed boundary may be claimed")
        XCTAssertFalse(probe.complete,
                       "UNCROSSED means UNPROVEN — never 'clean'")
    }

    /// The device-id arm of the same rule (a foreign volume mounted with its
    /// own `st_dev`), on the SCAN-time face — which runs BEFORE the sizing
    /// pass that would mark the item review-only, so it cannot lean on it.
    func testScanTimeProbeStopsAtAForeignDeviceSubtree() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.ForeignDevice")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let mounted = entry.appendingPathComponent("volume")
        try mkdir(mounted.appendingPathComponent("Documents"))

        let provider = RecordingBoundaryProvider()
        let inode = try XCTUnwrap(provider.identity(of: mounted)?.inode)
        provider.deviceOverridesByInode[inode] = 0xDEAD_BEEF
        provider.reset()

        guard case .entries(let facts) =
            makeScanner(provider: provider).enumerateFacts() else {
            return XCTFail("expected facts")
        }
        let fact = try XCTUnwrap(facts.first { $0.name == entry.lastPathComponent })

        XCTAssertFalse(
            provider.touchedAnythingBelow(mounted),
            "the scan-time probe read the foreign volume: \(provider.probedPaths)"
        )
        XCTAssertTrue(fact.userDataShapeMatches.isEmpty)
        XCTAssertFalse(fact.userDataProbeComplete,
                       "an uncrossed boundary fails closed like any other "
                           + "branch the walk could not read")
    }

    /// A cache entry that IS a mount root is never opened at all — the same
    /// stance `DirectorySizer` takes on its own root.
    func testProbeRootThatIsItselfAMountIsNeverOpened() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.MountedEntry")
        try mkdir(entry.appendingPathComponent("Pictures"))

        let provider = RecordingBoundaryProvider()
        let inode = try XCTUnwrap(provider.identity(of: entry)?.inode)
        provider.mountPointInodes.insert(inode)
        provider.reset()

        let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: entry, provider: provider
        )

        XCTAssertFalse(
            provider.touchedAnythingBelow(entry),
            "a mount-root target must not be enumerated: \(provider.probedPaths)"
        )
        XCTAssertTrue(probe.matches.isEmpty)
        XCTAssertFalse(probe.complete)
    }

    // MARK: - Aliased spellings vs the mount check (PR #458 review r4/r6)

    /// The mount rule now reads DESCRIPTORS (`fstatfs`'s `f_fsid`, plus
    /// `st_dev`), so injection is keyed to the INODE and cannot be
    /// spelling-sensitive — which is the entire point. The retired path
    /// form compared `statfs`'s `f_mntonname` against whatever spelling it
    /// was handed, so a root reached through a symlinked ancestor never
    /// equalled it and the arm silently answered `false` for a real mount;
    /// on a firmlink-shaped mount (one `st_dev` on both sides) the device
    /// arm was silent too, and the walk enumerated a mounted volume while
    /// calling the result COMPLETE. Devices are deliberately NOT overridden
    /// here, so these fixtures keep that firmlink shape.
    private final class AliasedSpellingMountProvider: FileSystemIdentityProvider {
        /// Inodes to present as sitting on a DIFFERENT mount.
        var mountedInodes: Set<UInt64> = []
        private(set) var probedPaths: [String] = []

        override func mountIdentity(ofDescriptor descriptor: Int32)
            -> MountIdentity? {
            guard let real = super.mountIdentity(ofDescriptor: descriptor),
                  let id = super.identity(ofDescriptor: descriptor)
            else { return nil }
            guard mountedInodes.contains(id.inode) else { return real }
            return OrphanedCachesScannerTests.injectedMount(
                forInode: id.inode, device: real.device
            )
        }

        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            // Evaluated ONCE, here: the walk composes no path below its root
            // (hence the autoclosure), so a double that keys on the spelling
            // is the one that pays for composing it.
            let logical = logical()
            probedPaths.append(logical.path)
            return super.probeChild(
                inDirectory: descriptor, named: name, logical: logical
            )
        }

        func reset() { probedPaths = [] }

        func touchedAnythingBelow(_ url: URL) -> Bool {
            probedPaths.contains { $0.hasPrefix(url.path + "/") }
        }
    }

    /// A fixture reachable by TWO spellings of the same object: the real
    /// path, and one through a symlinked ancestor. Returns the aliased
    /// spelling, which is what a delete-time target or a symlinked home
    /// hands the probe.
    private func aliasedEntry(named name: String) throws -> (aliased: URL, real: URL) {
        let realHome = base.appendingPathComponent("aliased-home")
        let realCaches = realHome.appendingPathComponent("Library/Caches")
        let real = realCaches.appendingPathComponent(name)
        try mkdir(real)
        let alias = base.appendingPathComponent("alias")
        if !fm.fileExists(atPath: alias.path) {
            try fm.createSymbolicLink(at: alias, withDestinationURL: realHome)
        }
        let aliased = alias
            .appendingPathComponent("Library/Caches")
            .appendingPathComponent(name)
        return (aliased, real)
    }

    /// A nested mount reached through a symlinked ancestor. The descriptor
    /// form has no spelling to be defeated by, so it is caught.
    func testNestedMountIsDetectedThroughAnAliasedSpelling() throws {
        let (aliased, real) = try aliasedEntry(named: "com.example.AliasedMount")
        try writeFile(real.appendingPathComponent("payload.bin"))
        let realMount = real.appendingPathComponent("volume")
        try mkdir(realMount.appendingPathComponent("Pictures/Photos Library.photoslibrary"))

        let provider = AliasedSpellingMountProvider()
        let inode = try XCTUnwrap(provider.identity(of: realMount)?.inode)
        provider.mountedInodes.insert(inode)
        // Precondition: the two spellings really do differ, or the fixture
        // is not exercising the alias at all.
        let aliasedMount = aliased.appendingPathComponent("volume")
        try XCTSkipIf(
            provider.canonicalize(aliasedMount).path == aliasedMount.path,
            "fixture is already canonical — nothing aliased to test"
        )
        provider.reset()

        var probe = UserDataProbeResult.complete()
        assertNoDescriptorLeak {
            probe = OrphanedCachesScanner.preDeleteUserDataProbe(
                at: aliased, provider: provider
            )
        }

        XCTAssertFalse(
            provider.touchedAnythingBelow(aliasedMount),
            "not one entry of the mounted filesystem may be read: "
                + "\(provider.probedPaths)"
        )
        XCTAssertTrue(probe.matches.isEmpty,
                      "nothing past an uncrossed boundary may be claimed")
        XCTAssertEqual(probe.obstructions, [.mountBoundary])

        // …and the TRAVERSAL still used the walk's own unresolved spelling.
        // Nothing canonical may leak into the paths the walk reports — those
        // are the ones a deletion removes (the `resolveTargetKeepingLeaf`
        // doctrine).
        XCTAssertTrue(
            provider.probedPaths.allSatisfy { $0.hasPrefix(aliased.path) },
            "traversal must keep the unresolved spelling: \(provider.probedPaths)"
        )
    }

    /// The same, at the ROOT — where the check is `openat(root, "..")` and a
    /// mount comparison against the parent, never a path.
    func testRootMountIsDetectedThroughAnAliasedSpelling() throws {
        let (aliased, real) = try aliasedEntry(named: "com.example.AliasedRoot")
        try mkdir(real.appendingPathComponent("Pictures"))

        let provider = AliasedSpellingMountProvider()
        let inode = try XCTUnwrap(provider.identity(of: real)?.inode)
        provider.mountedInodes.insert(inode)
        try XCTSkipIf(provider.canonicalize(aliased).path == aliased.path,
                      "fixture is already canonical")
        provider.reset()

        var probe = UserDataProbeResult.complete()
        assertNoDescriptorLeak {
            probe = OrphanedCachesScanner.preDeleteUserDataProbe(
                at: aliased, provider: provider
            )
        }

        XCTAssertFalse(
            provider.touchedAnythingBelow(aliased),
            "a mount-root target must not be enumerated: \(provider.probedPaths)"
        )
        XCTAssertTrue(probe.matches.isEmpty)
        XCTAssertEqual(probe.obstructions, [.mountBoundary])
    }

    /// The guard against over-correcting: an ordinary aliased tree with no
    /// mount anywhere still probes COMPLETE, and every path the walk
    /// reported is the unresolved spelling it was given.
    func testAliasedTreeWithoutAMountStaysCompleteAndUnresolved() throws {
        let (aliased, real) = try aliasedEntry(named: "com.example.AliasedClean")
        try mkdir(real.appendingPathComponent("sub/deeper"))
        try writeFile(real.appendingPathComponent("sub/deeper/payload.bin"))

        let provider = AliasedSpellingMountProvider()
        let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: aliased, provider: provider
        )

        XCTAssertTrue(probe.complete, "\(probe.obstructions)")
        XCTAssertTrue(probe.matches.isEmpty)
        XCTAssertTrue(
            provider.probedPaths.allSatisfy { $0.hasPrefix(aliased.path) },
            "no canonical spelling may leak into the walk: \(provider.probedPaths)"
        )
    }

    // MARK: - The open itself is no-follow (PR #458 review r5)

    /// Collapses the swap RACE into a lie, so no timing is involved: it
    /// reports `.kind(.directory)` for a path that is really a symlink,
    /// which is precisely the state the walk is in between its `lstat` and
    /// its `opendir` when a concurrent writer swaps the leaf. The window
    /// cannot be closed by re-`lstat`ing — only the open can refuse — so
    /// the test drives the real open against a real symlink.
    private final class SwapSimulatingProvider: FileSystemIdentityProvider {
        /// Paths this provider lies about, reporting them as directories.
        var reportedAsDirectory: Set<String> = []
        private(set) var probedPaths: [String] = []

        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            // Evaluated ONCE, here: the walk composes no path below its root
            // (hence the autoclosure), so a double that keys on the spelling
            // is the one that pays for composing it.
            let logical = logical()
            probedPaths.append(logical.path)
            let real = super.probeChild(
                inDirectory: descriptor, named: name, logical: logical
            )
            guard reportedAsDirectory.contains(logical.path),
                  case .facts(let facts) = real
            else { return real }
            return .facts(ChildFacts(kind: .directory, identity: facts.identity))
        }

        func touchedAnythingBelow(_ url: URL) -> Bool {
            probedPaths.contains { $0.hasPrefix(url.path + "/") }
        }
    }

    /// A child that passed the no-follow kind check and was then replaced
    /// by a symlink must not be followed by the open that comes next. Left
    /// open, the probe reads up to the whole entry budget OUTSIDE the cache
    /// tree — the exact boundary the no-follow rule exists to hold — and
    /// attributes what it finds there to the cache entry.
    func testOpenRefusesALeafSwappedForASymlink() throws {
        let external = base.appendingPathComponent("outside-the-cache-tree")
        try mkdir(external.appendingPathComponent("Pictures/Photos Library.photoslibrary"))
        try writeFile(external.appendingPathComponent("secret.bin"))

        let entry = cachesRoot.appendingPathComponent("com.example.Swapped")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let swapped = entry.appendingPathComponent("sub")
        try fm.createSymbolicLink(at: swapped, withDestinationURL: external)

        let provider = SwapSimulatingProvider()
        provider.reportedAsDirectory.insert(swapped.path)

        let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: entry, provider: provider
        )

        XCTAssertFalse(
            provider.touchedAnythingBelow(swapped),
            "the walk followed the swapped link and read outside the cache "
                + "tree: \(provider.probedPaths)"
        )
        XCTAssertTrue(
            probe.matches.isEmpty,
            "user-data shapes from OUTSIDE the tree must not be attributed "
                + "to this entry: \(probe.matches)"
        )
        // A swap is the tree changing under the walk — the same class as the
        // ENOENT/ENOTDIR vanish race, and just as retryable.
        XCTAssertEqual(probe.obstructions, [.transientFailure])
        let guidance = OrphanedCachesScanner.remediationGuidance(
            for: probe.obstructions
        )
        XCTAssertTrue(guidance.hasSuffix("Re-scan and try again."), guidance)
    }

    /// Reports a bogus INODE for chosen paths, keeping the real device so
    /// the mount arm stays silent: the hermetic stand-in for a directory
    /// replaced by a DIFFERENT directory between the vetting `lstat` and the
    /// open, which `O_NOFOLLOW` alone cannot catch.
    private final class WrongIdentityProvider: FileSystemIdentityProvider {
        var bogusInodeFor: Set<String> = []
        private(set) var probedPaths: [String] = []

        override func identity(of url: URL) -> Identity? {
            guard let real = super.identity(of: url) else { return nil }
            guard bogusInodeFor.contains(url.path) else { return real }
            return Identity(device: real.device, inode: real.inode &+ 1)
        }

        /// The VETTED value is the one that is wrong here — the descent's
        /// `fstat` of what it actually opened is left honest, which is what
        /// makes the corroborator fire. (It is only sound BECAUSE the
        /// vetted value came from an `fstatat` on the held parent; against
        /// an ancestor swap the same comparison proves nothing, which is
        /// why containment, not identity, is the guarantee.)
        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            // Evaluated ONCE, here: the walk composes no path below its root
            // (hence the autoclosure), so a double that keys on the spelling
            // is the one that pays for composing it.
            let logical = logical()
            probedPaths.append(logical.path)
            let real = super.probeChild(
                inDirectory: descriptor, named: name, logical: logical
            )
            guard bogusInodeFor.contains(logical.path),
                  case .facts(let facts) = real
            else { return real }
            return .facts(ChildFacts(
                kind: facts.kind,
                identity: Identity(device: facts.identity.device,
                                   inode: facts.identity.inode &+ 1)
            ))
        }

        func touchedAnythingBelow(_ url: URL) -> Bool {
            probedPaths.contains { $0.hasPrefix(url.path + "/") }
        }
    }

    /// The belt-and-braces half: what we opened must BE what we vetted. A
    /// directory swapped for another directory keeps passing every path
    /// check there is, so only the descriptor's own identity can catch it.
    func testOpenRefusesADirectorySwappedForADifferentDirectory() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Restat")
        let sub = entry.appendingPathComponent("sub")
        try mkdir(sub.appendingPathComponent("Pictures"))
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let provider = WrongIdentityProvider()
        provider.bogusInodeFor.insert(sub.path)

        let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: entry, provider: provider
        )

        XCTAssertFalse(
            provider.touchedAnythingBelow(sub),
            "nothing inside an unvetted directory may be read: "
                + "\(provider.probedPaths)"
        )
        XCTAssertTrue(probe.matches.isEmpty)
        XCTAssertEqual(probe.obstructions, [.transientFailure])
    }


    // MARK: - ANCESTOR swap (PR #458 review, thread PRRT_kwDORmg6_86ZjZf9)

    /// Performs a REAL ancestor swap at the exact instant the walk is
    /// vulnerable — deterministically, with no timing and no threads.
    ///
    /// The window is between the parent's directory read finishing (its
    /// descriptor closed) and the per-child metadata call that vets the
    /// grandchild. The provider IS that call, so the swap is performed
    /// inside it: single-threaded, and the real kernel decides what the
    /// walk then sees.
    private final class AncestorSwappingProvider: FileSystemIdentityProvider {
        /// Fires the first time a logical path ENDING IN this is probed.
        /// A suffix, not an absolute path: the scan-time face hands the walk
        /// `contentsOfDirectory`\'s already-resolved spelling
        /// (`/var` → `/private/var`), so an absolute comparison would
        /// silently never fire on one of the two faces.
        var swapWhenProbing: String = ""
        /// The ancestor to move out of the way.
        var ancestor: URL!
        /// Where the original ancestor goes.
        var stash: URL!
        /// What takes its place (a symlink to this, or this itself moved in).
        var replacement: URL!
        /// Replace with a SYMLINK to `replacement` (else move it in whole).
        var replaceWithSymlink = true
        private(set) var swapped = false
        private(set) var probedPaths: [String] = []

        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            // Evaluated ONCE, here: the walk composes no path below its root
            // (hence the autoclosure), so a double that keys on the spelling
            // is the one that pays for composing it.
            let logical = logical()
            probedPaths.append(logical.path)
            if !swapped, logical.standardizedFileURL.path.hasSuffix(swapWhenProbing) {
                swapped = true
                try? FileManager.default.moveItem(at: ancestor, to: stash)
                if replaceWithSymlink {
                    try? FileManager.default.createSymbolicLink(
                        at: ancestor, withDestinationURL: replacement
                    )
                } else {
                    try? FileManager.default.moveItem(at: replacement, to: ancestor)
                }
            }
            return super.probeChild(
                inDirectory: descriptor, named: name, logical: logical
            )
        }

        func touched(_ url: URL) -> Bool { probedPaths.contains(url.path) }
    }

    /// An ANCESTOR replaced by a symlink after the walk read it, but BEFORE
    /// the grandchild is vetted. `O_NOFOLLOW` guards only the final
    /// component, and the identity the discovery `lstat` recorded already
    /// belongs to the FOREIGN object — so the descriptor re-proof compares
    /// foreign against foreign and passes. The probe then reads outside the
    /// cache tree and attributes what it finds to this entry.
    func testAncestorSwappedToASymlinkIsNeverFollowed() throws {
        let foreign = base.appendingPathComponent("outside-the-cache-tree")
        try mkdir(foreign.appendingPathComponent("deep/Documents"))
        try writeFile(foreign.appendingPathComponent("deep/secret.bin"))

        let entry = cachesRoot.appendingPathComponent("com.example.AncestorSwap")
        let mid = entry.appendingPathComponent("mid")
        try mkdir(mid.appendingPathComponent("deep/keeper"))
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let provider = AncestorSwappingProvider()
        provider.swapWhenProbing = "/\(mid.lastPathComponent)/deep"
        provider.ancestor = mid
        provider.stash = base.appendingPathComponent("stashed-mid")
        provider.replacement = foreign
        provider.replaceWithSymlink = true

        let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: entry, provider: provider
        )

        XCTAssertTrue(provider.swapped, "the fixture never armed the swap")
        XCTAssertFalse(
            provider.touched(mid.appendingPathComponent("deep/Documents")),
            "the walk resolved a child through the swapped ancestor and read "
                + "OUTSIDE the cache tree: \(provider.probedPaths)"
        )
        XCTAssertTrue(
            probe.matches.isEmpty,
            "user-data shapes from outside the tree were attributed to this "
                + "entry: \(probe.matches)"
        )
        // Held descriptors are inode-pinned: the walk keeps reading the
        // VETTED objects at their new location. That is the correct
        // outcome — complete over what was vetted, foreign content unread.
        XCTAssertTrue(
            provider.touched(mid.appendingPathComponent("deep/keeper")),
            "the walk should have kept reading the vetted inodes: "
                + "\(provider.probedPaths)"
        )
    }

    /// The same swap to a DIFFERENT REAL DIRECTORY — the case `O_NOFOLLOW`
    /// cannot see at all, since no symlink is ever traversed.
    func testAncestorSwappedToADifferentDirectoryIsNeverFollowed() throws {
        let foreign = base.appendingPathComponent("outside-real-dir")
        try mkdir(foreign.appendingPathComponent("deep/Documents"))

        let entry = cachesRoot.appendingPathComponent("com.example.AncestorMoved")
        let mid = entry.appendingPathComponent("mid")
        try mkdir(mid.appendingPathComponent("deep/keeper"))

        let provider = AncestorSwappingProvider()
        provider.swapWhenProbing = "/\(mid.lastPathComponent)/deep"
        provider.ancestor = mid
        provider.stash = base.appendingPathComponent("stashed-mid-2")
        provider.replacement = foreign
        provider.replaceWithSymlink = false

        let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: entry, provider: provider
        )

        XCTAssertTrue(provider.swapped, "the fixture never armed the swap")
        XCTAssertFalse(
            provider.touched(mid.appendingPathComponent("deep/Documents")),
            "the walk descended into a foreign directory swapped in above "
                + "the child: \(provider.probedPaths)"
        )
        XCTAssertTrue(probe.matches.isEmpty, "\(probe.matches)")
        // Held descriptors are inode-pinned: the vetted objects keep being
        // read at their new location. Anything that resolves the child by
        // PATH — even with `O_NOFOLLOW` — loses them, so this is the
        // assertion that separates "refused" from "correct".
        XCTAssertTrue(
            provider.touched(mid.appendingPathComponent("deep/keeper")),
            "the walk should have kept reading the vetted inodes: "
                + "\(provider.probedPaths)"
        )
        XCTAssertTrue(probe.complete, "\(probe.obstructions)")
    }

    // MARK: - A subtree PROVEN to exist that the open cannot find

    /// The window between the discovery `fstatat` — which PROVED, against a
    /// parent descriptor we hold, that this name is a DIRECTORY — and the
    /// `openat` that descends into it. A real `rename(2)` fired inside that
    /// window moves the subtree to a name the bounded read has already gone
    /// past, so this walk never inspects it, and the bytes are still there.
    ///
    /// Recording NOTHING at that site is the fail-open: the entry comes back
    /// `complete` with no matches, which for a known-leak tier is exactly
    /// the input Quick Clean deletes with no per-item confirmation
    /// (`OrphanedCacheClassifier.cleanKnownLeak`).
    func testRenameBetweenVettingAndOpenIsRecordedNotSwallowed() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Leak")
        try mkdir(entry.appendingPathComponent("aaa"))
        try mkdir(entry.appendingPathComponent("zzz/Documents"))

        var renamed = false
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit
        ) { event in
            guard case .willDescend(let name, let from) = event,
                  name == "zzz", !renamed else { return }
            // A REAL `rename(2)`, single-threaded, at the one deterministic
            // instant the race lives in. `bbb` sorts BEFORE `zzz`, so the
            // byte-ascending read has already passed it: nothing else in
            // this walk will ever look at it.
            let moved = rename(from.appendingPathComponent("zzz").path,
                               from.appendingPathComponent("bbb").path)
            XCTAssertEqual(moved, 0, "fixture rename failed: \(errno)")
            renamed = true
        }

        XCTAssertTrue(renamed, "the fixture never armed the rename")
        XCTAssertTrue(
            fm.fileExists(
                atPath: entry.appendingPathComponent("bbb/Documents").path
            ),
            "the subtree must still be ON DISK — renamed, not deleted"
        )
        XCTAssertTrue(probe.matches.isEmpty,
                      "the shape was never seen: \(probe.matches)")
        XCTAssertEqual(
            probe.obstructions, [.transientFailure],
            "a directory the walk PROVED exists and then could not open was "
                + "never inspected; a rename is retryable, so it is a "
                + "transient failure, not silence"
        )
        XCTAssertFalse(
            probe.complete,
            "UNINSPECTED IS NOT CLEAN: complete + no matches on a known-leak "
                + "entry is automatically clean-eligible, and Quick Clean "
                + "would delete the uninspected Documents tree"
        )
        XCTAssertTrue(
            OrphanedCachesScanner.remediationGuidance(for: probe.obstructions)
                .hasSuffix("Re-scan and try again."),
            "and the refusal must be CLEARABLE by a retry"
        )
    }

    /// The same instant, but the directory is genuinely UNLINKED rather than
    /// renamed. Indistinguishable from the rename at the `openat` — both
    /// return ENOENT — so it is classified the same way, and this test
    /// pins that the fail-closed choice was made deliberately rather than
    /// by accident of which fixture was written.
    func testDirectoryUnlinkedBetweenVettingAndOpenIsAlsoRecorded() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Evicted")
        try mkdir(entry.appendingPathComponent("gone"))

        var removed = false
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit
        ) { event in
            guard case .willDescend(let name, let from) = event,
                  name == "gone", !removed else { return }
            try? self.fm.removeItem(at: from.appendingPathComponent("gone"))
            removed = true
        }

        XCTAssertTrue(removed, "the fixture never armed the removal")
        XCTAssertEqual(probe.obstructions, [.transientFailure])
        XCTAssertFalse(probe.complete)
    }

    // MARK: - The descriptor bound never becomes a refusal (constraint 3)

    /// Builds `levels` nested directories with `mkdirat`, holding at most
    /// TWO descriptors at a time (the fixture must not itself exhaust the
    /// lowered descriptor limit the test then imposes). Returns the deepest
    /// descriptor, which the caller owns.
    private func makeDeepChain(
        under root: URL, name: String, levels: Int
    ) throws -> Int32 {
        var current = try openDirectory(root)
        for _ in 0..<levels {
            guard mkdirat(current, name, 0o755) == 0 else {
                close(current)
                throw XCTSkip("mkdirat failed: \(errno)")
            }
            let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw XCTSkip("openat failed: \(errno)") }
            current = next
        }
        return current
    }

    /// Tears such a chain down bottom-up by climbing `..`, which is the only
    /// way past `PATH_MAX` — `FileManager.removeItem` cannot address it.
    /// Consumes `deepest`.
    private func removeDeepChain(deepest: Int32, stopAt: URL, name: String) {
        var current = deepest
        let stopInode = FileSystemIdentityProvider().identity(of: stopAt)?.inode
        while true {
            var here = stat()
            if fstat(current, &here) == 0, UInt64(here.st_ino) == stopInode {
                break
            }
            let parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if parent < 0 { break }
            close(current)
            unlinkat(parent, name, AT_REMOVEDIR)
            current = parent
        }
        close(current)
    }

    /// THE acceptance criterion for "the depth cap did not come back".
    ///
    /// A tree an order of magnitude deeper than the descriptor window, with
    /// the process's own descriptor limit lowered under it, must be READ —
    /// with an EMPTY obstruction set. A design whose descriptor bound is a
    /// refusal (an `.excessiveNesting`, an fd-pressure abort) fails here,
    /// and it would be the retired depth cap with a better error message:
    /// deterministic, adversary-triggerable, and unclearable by any retry.
    func testFiveHundredDeepTreeCompletesUnderALoweredDescriptorLimit() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.VeryDeep")
        try mkdir(entry)
        let deepest = try makeDeepChain(under: entry, name: "d", levels: 500)
        defer { removeDeepChain(deepest: deepest, stopAt: entry, name: "d") }

        // Lower the process limit for the duration, exactly as a launchd
        // -spawned app sees it (measured soft limit there: 256).
        var original = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &original) == 0 else {
            throw XCTSkip("getrlimit failed")
        }

        // MEASURED FROM WHAT THE PROCESS ALREADY HOLDS, never hardcoded.
        //
        // XCTest, dispatch and Swift Concurrency keep a drifting number of
        // ANONYMOUS descriptors (sockets, pipes, kqueues — measured: not one
        // of them has an `F_GETPATH`, so none is a leak of this walk's) that
        // grows with the size of the suite. Measured at this test's entry:
        // 93 before the fn-6 branch merged, 104–109 after, against the 96
        // this test used to hardcode.
        //
        // Once that ambient count passes the ceiling, EVERY `open` fails
        // before the walk takes a single step, and the wreckage is an exact
        // impostor of the regression this test exists to catch — an
        // obstruction set of `[.transientFailure]` and a descriptor peak of
        // 0. A fixed ceiling therefore stops testing the walk at all, and
        // does it by silently turning green into a false red.
        //
        // The criterion is a ceiling FAR BELOW THE TREE DEPTH, not a
        // particular integer: the walk must read 500 levels while never
        // holding more than a handful of handles. Measuring the live count
        // and adding a small margin preserves that exactly, and makes the
        // test independent of how many tests ran before it.
        var liveDescriptors = 0
        let scanBound = Int32(clamping: min(original.rlim_cur, 65536))
        for fd in 0..<scanBound where fcntl(fd, F_GETFD) != -1 {
            liveDescriptors += 1
        }
        let ceiling = liveDescriptors + 32
        // Both halves of "lowered UNDER the depth" have to still be true, so
        // neither is assumed: the ceiling must really be a reduction, and it
        // must stay an order of magnitude under the 500 levels below it.
        // Skipping beats asserting a criterion the environment has voided.
        try XCTSkipUnless(
            rlim_t(ceiling) < original.rlim_cur && ceiling < 500,
            "ambient descriptor use (\(liveDescriptors)) leaves no room to "
                + "lower the limit under a 500-deep tree"
        )
        var lowered = original
        lowered.rlim_cur = rlim_t(ceiling)
        guard setrlimit(RLIMIT_NOFILE, &lowered) == 0 else {
            throw XCTSkip("setrlimit failed: \(errno)")
        }
        defer { setrlimit(RLIMIT_NOFILE, &original) }

        var reanchors = 0
        var peakLive = 0
        var peakHeld = 0
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
            descriptorWindow: OrphanedCachesScanner.defaultDescriptorWindow()
        ) { event in
            switch event {
            case .didReanchor: reanchors += 1
            case .descriptorCensus(let live, let transient, _):
                peakLive = max(peakLive, live)
                peakHeld = max(peakHeld, live + transient)
            default: break
            }
        }

        XCTAssertEqual(probe.obstructions, [],
                       "a 500-deep tree must be READ, not refused")
        XCTAssertTrue(probe.complete)
        XCTAssertTrue(probe.matches.isEmpty)
        // EAGER TAIL RELEASE: a pure chain never needs to climb back, so it
        // holds ~2 descriptors the whole way down and spends no `..` at all.
        XCTAssertEqual(reanchors, 0,
                       "a pure deep chain must not re-anchor even once")
        XCTAssertLessThanOrEqual(peakLive, 2,
                                 "tail release should hold root + current only")
        // And the TRUE peak, transients included: root, the level being left
        // behind, and the one handle in flight. 500 levels deep, under a
        // soft limit of 96.
        XCTAssertEqual(peakHeld, 3,
                       "a pure chain must peak at root + current + one "
                           + "in-flight handle, at ANY depth")
    }

    /// The formula, enforced rather than asserted in prose:
    /// `peak_live_fds = min(depth + 1, W) + 2`.
    ///
    /// AND ENFORCED WHERE THE PEAK ACTUALLY IS. The previous version of this
    /// test sampled only the post-append census — the one instant of the
    /// loop at which the walk holds NO transient handle — so the margin it
    /// asserted could never be approached and a regression inside it could
    /// not have failed the test. Every sample here is taken at a moment the
    /// walk is holding an extra descriptor (mid-read, mid-descent,
    /// mid-climb), and each one is cross-checked against a real `fcntl`
    /// count of this process's descriptors so the census cannot flatter
    /// itself.
    func testDescriptorPeakStaysInsideTheWindow() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Peak")
        // A COMB: every level keeps a pending sibling, so no tail release
        // is free and the window is the only thing holding the count down.
        var here = entry
        let depth = 12
        for level in 0..<depth {
            try mkdir(here.appendingPathComponent("keep\(level)"))
            here = here.appendingPathComponent("down")
            try mkdir(here)
        }

        let window = 4
        var peakLive = 0
        var peakCensus = 0
        var peakMeasured = 0
        var samples = 0
        var disagreements: [String] = []
        let before = heldDescriptorCount()
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
            descriptorWindow: window
        ) { event in
            guard case .descriptorCensus(let live, let transient, _) = event
            else { return }
            let measured = self.heldDescriptorCount() - before
            samples += 1
            peakLive = max(peakLive, live)
            peakCensus = max(peakCensus, live + transient)
            peakMeasured = max(peakMeasured, measured)
            if measured != live + transient {
                disagreements.append(
                    "census \(live)+\(transient) vs measured \(measured)"
                )
            }
        }

        XCTAssertTrue(probe.complete, "\(probe.obstructions)")
        XCTAssertGreaterThan(samples, depth,
                             "the walk must be sampled throughout, not once")
        XCTAssertEqual(peakLive, window,
                       "the comb must actually FILL the window, or this "
                           + "test proves nothing")
        // THE CENSUS CANNOT LIE: at every sampled instant it equals what
        // `fcntl` says this process is really holding. A census that
        // undercounts its own transients would show up here, not as a
        // silently comfortable margin.
        XCTAssertEqual(disagreements, [],
                       "the census disagreed with the kernel: \(disagreements)")
        // THE PEAK IS REACHED, not merely bounded: W frame anchors plus the
        // one handle in flight. Written as an equality so that a change
        // which stops holding the peak — or one that starts holding more —
        // both fail here.
        XCTAssertEqual(peakMeasured, window + 1,
                       "the observed peak must be exactly W + 1")
        XCTAssertLessThanOrEqual(
            peakMeasured, min(depth + 1, window) + 2,
            "peak = min(depth + 1, W) + 2 — the +2 covers the enumeration "
                + "handle, the in-flight child, and the `..` descriptor, "
                + "which are mutually exclusive"
        )
        XCTAssertEqual(heldDescriptorCount(), before,
                       "and every one of them is released")
    }

    /// This process's resident bytes, sampled without allocating.
    private func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { raw in
            raw.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int64(info.resident_size) : -1
    }

    /// Samples this process's resident size at every per-entry syscall,
    /// WITHOUT evaluating `logical` — which is exactly the production
    /// contract: nothing below the walk root composes a path.
    private final class MemorySamplingProvider: FileSystemIdentityProvider {
        var sample: (() -> Void)?

        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            sample?()
            // `logical` is deliberately NOT evaluated.
            return super.probeChild(
                inDirectory: descriptor, named: name,
                logical: URL(fileURLWithPath: "/")
            )
        }
    }

    /// THE ENTRY BUDGET BOUNDS ATTENTION, NOT RESOURCES — the distinction
    /// that has now cost this walk three times (after `contentsOfDirectory`
    /// materialising a whole directory before any cap could apply, and the
    /// full-frame-stack rescan `makeRoom` used to perform on every descent).
    /// A `URL` stored per frame retained a private copy of the whole prefix
    /// above it, so the walk's own bookkeeping grew QUADRATICALLY with depth
    /// while the entry count stayed flat: this fixture — 1,800 levels of
    /// 240-byte basenames, 1,800 entries out of a 20,000-entry budget —
    /// retains hundreds of megabytes of duplicated path prefixes that way,
    /// before the tree is even large.
    ///
    /// Sampled from the PROVIDER rather than from a `WalkEvent` observer on
    /// purpose: an observer asks for URLs, and asking is what costs.
    ///
    /// ## The ceiling is measured, not guessed (PR #458 review r7)
    /// It was 48 MiB, and it was loose in the way that matters: it caught
    /// the shape that had just been fixed while a NEAR NEIGHBOUR of the same
    /// defect — RETAINING the on-demand-composed URL per frame instead of
    /// composing it on demand — slipped under it. A ceiling that admits the
    /// defect's next-door neighbour is not a ceiling.
    ///
    /// Every figure below was re-measured on this fixture by reintroducing
    /// the shape in a scratch copy, because the record has been wrong twice
    /// (387 MiB claimed for the retired shape, then 230; 42 for the
    /// neighbour):
    ///
    ///   one basename per level, as built ......... 1.6 – 2.1 MiB
    ///   on-demand URL RETAINED per frame ......... 29.6 MiB
    ///   URL per frame composed from its parent ... 139 MiB
    ///
    /// (resident growth, 1,800 levels × 240-byte basenames). Correct
    /// bookkeeping is 1,800 × 240 B ≈ 0.4 MiB; the rest of the as-built
    /// figure is allocator and harness noise, not retention.
    ///
    /// 8 MiB is therefore ~4× the observed worst case and ~3.7× BELOW the
    /// tightest defect shape known — a band no per-frame-URL design fits in.
    func testDeepChainDoesNotRetainQuadraticPathPrefixes() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.LongNames")
        try mkdir(entry)
        let levels = 1_800
        let name = String(repeating: "n", count: 240)
        let deepest = try makeDeepChain(under: entry, name: name, levels: levels)
        defer { removeDeepChain(deepest: deepest, stopAt: entry, name: name) }

        let provider = MemorySamplingProvider()
        let baseline = residentBytes()
        var peak = baseline
        provider.sample = { peak = max(peak, self.residentBytes()) }

        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: provider,
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit
        )

        XCTAssertTrue(probe.complete, "\(probe.obstructions)")
        XCTAssertTrue(probe.matches.isEmpty)
        let grew = peak - baseline
        XCTAssertLessThan(
            grew, 8 * 1_024 * 1_024,
            "the walk grew \(grew / 1_048_576) MiB of bookkeeping over "
                + "\(levels) levels (expected ≈ 0.4 MiB, measured 1.6–2.1 "
                + "MiB with noise) — a URL retained PER FRAME is back in "
                + "some form; the nearest such shape measures 29.6 MiB and "
                + "the retired one 139 MiB"
        )
    }

    /// The refactor must not change the spelling an observer sees: the
    /// composed-on-demand URL has to equal the URL the per-frame copy used
    /// to carry, at every level and for every awkward basename.
    ///
    /// The expected values are composed WITHOUT touching the filesystem, and
    /// that is the point of the assertion as much as the components are: the
    /// bare `appendingPathComponent(_:)` the walk used to call decides its
    /// trailing slash by statting the composed path, which makes an
    /// observer's spelling depend on what is on disk at the moment it is
    /// composed — including on a rename an attacker just landed.
    func testOnDemandSpellingMatchesComponentWiseComposition() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Spelling")
        // Awkward on purpose: spaces, leading dots, a percent, non-ASCII.
        let components = ["a b", "..dots", "100%", "Ünïcodé", ".hidden", "z"]
        var expected: [URL] = [entry]
        var here = entry
        for component in components {
            here = here.appendingPathComponent(component, isDirectory: true)
            expected.append(here)
        }
        try mkdir(here)

        var enumerated: [URL] = []
        var descended: [String: URL] = [:]
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit
        ) { event in
            switch event {
            case .didEnumerate(let logical, _): enumerated.append(logical)
            case .willDescend(let name, let from): descended[name] = from
            default: break
            }
        }

        XCTAssertTrue(probe.complete, "\(probe.obstructions)")
        XCTAssertEqual(enumerated, expected,
                       "an observer must see the walk's OWN spelling, "
                           + "composed root-first, one component per level")
        for (index, component) in components.enumerated() {
            // `expected` is the test's own array, but `index` runs over a
            // DIFFERENT collection: the pairing is an invariant, not a
            // guarantee, and a trap here would strand the run.
            let parent = try XCTUnwrapElement(expected, index)
            XCTAssertEqual(descended[component], parent,
                           "descent into \(component) was reported from the "
                               + "wrong parent spelling")
        }
    }

    /// The peak of a walk that is CLIMBING: a comb narrower than its depth
    /// forces `..` re-anchors, and a climb holds two handles of its own
    /// (the level it is standing on and the level it just opened) on top of
    /// the frame stack. Sampled mid-climb, which no census taken after the
    /// climb finished could ever see.
    func testDescriptorPeakDuringAReAnchorClimb() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Climb")
        var here = entry
        let depth = 8
        for level in 0..<depth {
            try mkdir(here.appendingPathComponent("keep\(level)"))
            here = here.appendingPathComponent("down")
            try mkdir(here)
        }

        let window = 2   // the floor: every pop past it must climb
        var reanchors = 0
        var peakMeasured = 0
        var peakCensus = 0
        var disagreements: [String] = []
        // The event SEQUENCE, so "was a sample taken while the climb was in
        // flight" is decided by position rather than by hope: a mid-climb
        // census lands strictly between the pop that started the climb and
        // the re-anchor that ended it.
        var sequence: [String] = []
        let before = heldDescriptorCount()
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
            descriptorWindow: window
        ) { event in
            switch event {
            case .didReanchor:
                reanchors += 1
                sequence.append("reanchor")
            case .willPop: sequence.append("pop")
            case .willDescend: sequence.append("descend")
            case .didEnumerate: sequence.append("enumerate")
            // Deliberately NOT in the sequence: the mid-climb detector below
            // keys on pop/census/reanchor ADJACENCY, and bookkeeping is
            // emitted on descent and after a pop's climb has already
            // finished — never between a climb's own steps.
            case .frameBookkeeping: break
            case .descriptorCensus(let live, let transient, _):
                sequence.append("census")
                let measured = self.heldDescriptorCount() - before
                peakCensus = max(peakCensus, live + transient)
                peakMeasured = max(peakMeasured, measured)
                if measured != live + transient {
                    disagreements.append(
                        "census \(live)+\(transient) vs measured \(measured)"
                    )
                }
            }
        }

        XCTAssertTrue(probe.complete, "\(probe.obstructions)")
        XCTAssertGreaterThan(reanchors, 0, "the fixture never forced a climb")
        XCTAssertEqual(disagreements, [],
                       "the census disagreed with the kernel: \(disagreements)")
        let midClimbSamples = sequence.indices.filter { index in
            index + 2 < sequence.count
                && sequence[index] == "pop"
                && sequence[index + 1] == "census"
                && sequence[index + 2] == "reanchor"
        }.count
        XCTAssertGreaterThan(
            midClimbSamples, 0,
            "not one sample was taken WHILE a climb held its extra "
                + "descriptors — the peak of the climb is unobserved: "
                + "\(sequence.prefix(24))"
        )
        XCTAssertEqual(peakMeasured, peakCensus,
                       "the census must reach the measured peak")
        XCTAssertLessThanOrEqual(
            peakMeasured, min(depth + 1, window) + 2,
            "a climb must stay inside min(depth + 1, W) + 2"
        )
        XCTAssertEqual(heldDescriptorCount(), before,
                       "and every one of them is released")
    }

    /// `descriptorWindow` is a PERFORMANCE knob: shrinking it to 3 must not
    /// change one byte of the output, on either tree shape. The comb pays
    /// one `..` per level past the window; the chain pays none.
    func testTinyDescriptorWindowChangesNothingButSyscallCount() throws {
        let comb = cachesRoot.appendingPathComponent("com.example.Comb")
        var here = comb
        for level in 0..<6 {
            try mkdir(here.appendingPathComponent("sibling\(level)"))
            here = here.appendingPathComponent("down")
            try mkdir(here)
        }
        try mkdir(here.appendingPathComponent("Documents"))

        let chain = cachesRoot.appendingPathComponent("com.example.Chain")
        try mkdir(chain.appendingPathComponent(deepChain(6) + "/Pictures"))

        for tree in [comb, chain] {
            var reanchors = 0
            let narrow = OrphanedCachesScanner.boundedUserDataShapeWalk(
                at: tree, provider: FileSystemIdentityProvider(),
                entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
                descriptorWindow: 3
            ) { if case .didReanchor = $0 { reanchors += 1 } }
            let wide = OrphanedCachesScanner.boundedUserDataShapeWalk(
                at: tree, provider: FileSystemIdentityProvider(),
                entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
                descriptorWindow: 64
            )

            XCTAssertEqual(narrow, wide,
                           "W changed the OUTPUT at \(tree.lastPathComponent)")
            XCTAssertTrue(narrow.complete, "\(narrow.obstructions)")
            if tree == chain {
                XCTAssertEqual(reanchors, 0,
                               "a chain releases its tail for free and never "
                                   + "climbs back")
            } else {
                XCTAssertGreaterThan(reanchors, 0,
                                     "a comb past the window must re-anchor")
            }
        }
    }

    /// A re-anchor that cannot prove it landed where it left ENDS the walk,
    /// fail-closed. We can never get back above that level, and continuing
    /// would be a silent truncation.
    func testAReAnchorThatLandsElsewhereTerminatesTheWalk() throws {
        let foreign = base.appendingPathComponent("foreign-parent")
        try mkdir(foreign)

        let entry = cachesRoot.appendingPathComponent("com.example.Reanchor")
        let a = entry.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        let c = b.appendingPathComponent("c")
        try mkdir(c)
        // A second sibling under `a`, so `a` is NOT tail-released and the
        // climb back to it really is required.
        try mkdir(a.appendingPathComponent("z"))

        var moved = false
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
            descriptorWindow: 2
        ) { event in
            // The instant before the walk climbs back out of the bottom of
            // the chain, move that bottom under a foreign parent: `..` now
            // names something the walk never vetted.
            guard case .willPop(let depth) = event, depth == 3, !moved else {
                return
            }
            moved = true
            try? FileManager.default.moveItem(
                at: c, to: foreign.appendingPathComponent("c")
            )
        }

        XCTAssertTrue(moved, "the fixture never armed the move")
        XCTAssertEqual(probe.obstructions, [.transientFailure])
        XCTAssertFalse(probe.complete)
    }

    /// THE fd-balance net: every exit path the probe has — success, budget
    /// exhaustion, a mount refusal, a root that cannot be opened, a
    /// mid-walk `openat` failure, an ancestor swap, and a terminated walk —
    /// must leave the process holding exactly the descriptors it started
    /// with. A descriptor leaked on a refusal path is this design's number
    /// one hazard; `SecureDirectory`'s `deinit` is what closes it, and this
    /// is the enforcement rather than review vigilance.
    func testEveryProbeExitPathReleasesEveryDescriptor() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let plain = FileSystemIdentityProvider()

        // (a) plain success over a real tree
        let ok = cachesRoot.appendingPathComponent("fdbalance-ok")
        try mkdir(ok.appendingPathComponent("a/b/c"))
        try writeFile(ok.appendingPathComponent("a/f.bin"), bytes: 1)

        // (b) budget exhaustion
        let wide = cachesRoot.appendingPathComponent("fdbalance-wide")
        try mkdir(wide)
        for index in 0..<12 {
            try mkdir(wide.appendingPathComponent("d\(index)"))
        }

        // (c) mount refusal, nested and at the root
        let mounted = cachesRoot.appendingPathComponent("fdbalance-mount")
        let inner = mounted.appendingPathComponent("volume")
        try mkdir(inner.appendingPathComponent("Documents"))
        let mountProvider = AliasedSpellingMountProvider()
        mountProvider.mountedInodes.insert(
            try XCTUnwrap(plain.identity(of: inner)?.inode)
        )
        let rootMountProvider = AliasedSpellingMountProvider()
        rootMountProvider.mountedInodes.insert(
            try XCTUnwrap(plain.identity(of: mounted)?.inode)
        )

        // (d) an unopenable root and an unopenable branch
        let lockedRoot = cachesRoot.appendingPathComponent("fdbalance-locked")
        try mkdir(lockedRoot)
        try chmod000(lockedRoot)
        defer { restorePerms(lockedRoot) }
        let lockedBranch = cachesRoot.appendingPathComponent("fdbalance-branch")
        let branch = lockedBranch.appendingPathComponent("sub")
        try mkdir(branch)
        try chmod000(branch)
        defer { restorePerms(branch) }

        // (e) a leaf swapped for a symlink (mid-walk `openat` failure)
        let swapped = cachesRoot.appendingPathComponent("fdbalance-swap")
        try mkdir(swapped)
        let link = swapped.appendingPathComponent("sub")
        try fm.createSymbolicLink(
            at: link, withDestinationURL: base.appendingPathComponent("elsewhere")
        )
        let swapProvider = SwapSimulatingProvider()
        swapProvider.reportedAsDirectory.insert(link.path)

        // (f) a terminated walk: the re-anchor lands somewhere else
        let moved = cachesRoot.appendingPathComponent("fdbalance-moved")
        let movedC = moved.appendingPathComponent("a/b/c")
        try mkdir(movedC)
        try mkdir(moved.appendingPathComponent("a/z"))
        let foreign = base.appendingPathComponent("fdbalance-foreign")
        try mkdir(foreign)

        let scenarios: [(String, () -> Void)] = [
            ("success", {
                _ = OrphanedCachesScanner.preDeleteUserDataProbe(
                    at: ok, provider: plain
                )
            }),
            ("budget", {
                _ = OrphanedCachesScanner.boundedUserDataShapeWalk(
                    at: wide, provider: plain, entryLimit: 3
                )
            }),
            ("nested mount", {
                _ = OrphanedCachesScanner.preDeleteUserDataProbe(
                    at: mounted, provider: mountProvider
                )
            }),
            ("root mount", {
                _ = OrphanedCachesScanner.preDeleteUserDataProbe(
                    at: mounted, provider: rootMountProvider
                )
            }),
            ("absent root", {
                _ = OrphanedCachesScanner.preDeleteUserDataProbe(
                    at: self.cachesRoot.appendingPathComponent("nope"),
                    provider: plain
                )
            }),
            ("unopenable root", {
                _ = OrphanedCachesScanner.preDeleteUserDataProbe(
                    at: lockedRoot, provider: plain
                )
            }),
            ("unopenable branch", {
                _ = OrphanedCachesScanner.preDeleteUserDataProbe(
                    at: lockedBranch, provider: plain
                )
            }),
            ("leaf swap", {
                _ = OrphanedCachesScanner.preDeleteUserDataProbe(
                    at: swapped, provider: swapProvider
                )
            }),
            ("terminated walk", {
                var armed = false
                _ = OrphanedCachesScanner.boundedUserDataShapeWalk(
                    at: moved, provider: plain,
                    entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
                    descriptorWindow: 2
                ) { event in
                    guard case .willPop(let depth) = event, depth == 3, !armed
                    else { return }
                    armed = true
                    try? FileManager.default.moveItem(
                        at: movedC, to: foreign.appendingPathComponent("c")
                    )
                }
            }),
        ]

        for (name, run) in scenarios {
            // One warm-up: Foundation caches on first use, and this test is
            // about the WALK's descriptors, not about lazy globals.
            run()
            let before = openDescriptorCount()
            run()
            XCTAssertEqual(openDescriptorCount(), before,
                           "\(name) leaked a descriptor")
        }
    }

    // MARK: - The swap DUAL: right inode inspected, wrong one deleted
    //         (PR #458 review r7, thread PRRT_kwDORmg6_86ZkfDQ)

    /// Holding a descriptor is what stops this walk FOLLOWING a swap. It is
    /// also what PINS it to the old inode when one happens — the exact dual.
    /// Rename the target away mid-walk and stand a replacement directory at
    /// the same name: every descriptor-relative step below stays perfectly
    /// correct ABOUT THE RELOCATED TREE, and the verdict would otherwise be
    /// `complete` for a path that now names a tree nobody has looked at.
    /// `automaticCleanEligible` is set from exactly that verdict, and the
    /// deletion takes a PATH.
    func testTargetRenamedAwayMidWalkIsNotReportedComplete() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.RootSwap")
        try mkdir(entry.appendingPathComponent("sub"))
        let stash = cachesRoot.appendingPathComponent("com.example.RootSwap-gone")
        let replacement = entry.appendingPathComponent("Documents")

        var swapped = false
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit
        ) { event in
            guard case .willDescend(let name, _) = event,
                  name == "sub", !swapped else { return }
            swapped = true
            // A REAL `rename(2)` and a REAL replacement, single-threaded, at
            // one deterministic instant inside the walk.
            XCTAssertEqual(rename(entry.path, stash.path), 0,
                           "fixture rename failed: \(errno)")
            try? self.mkdir(replacement)
        }

        XCTAssertTrue(swapped, "the fixture never armed the swap")
        XCTAssertTrue(fm.fileExists(atPath: replacement.path),
                      "the replacement must be standing at the target's name")
        XCTAssertTrue(
            probe.matches.isEmpty,
            "the walk inspected the RELOCATED tree, so it can claim nothing "
                + "about the replacement: \(probe.matches)"
        )
        XCTAssertEqual(probe.obstructions, [.transientFailure],
                       "a rename is retryable — a re-scan finds whatever is "
                           + "really there now")
        XCTAssertFalse(
            probe.complete,
            "UNINSPECTED IS NOT CLEAN: `complete` here makes a known-leak "
                + "entry auto-clean-eligible and Quick Clean deletes the "
                + "replacement's Documents tree with no confirmation"
        )
    }

    /// Fires a REAL swap of the probe's target at the ONE instant the review
    /// names: after the pre-delete probe's last look, before the deletion.
    ///
    /// The walk's closing re-`lstat` of its own root IS that last look, so
    /// the swap is performed from inside it, AFTER `super` has answered —
    /// which means the probe still legitimately reports `complete` about the
    /// object it inspected, and the delete-time binding is the only thing
    /// left standing between Quick Clean and the replacement.
    private final class SwapAfterProbeProvider: FileSystemIdentityProvider {
        var target: URL!
        var stash: URL!
        /// Created (with intermediates) at the target's name after the move.
        var replacement: URL!
        private var armed = false
        private var walkOpened = false
        private(set) var swapped = false

        /// Arm for the NEXT walk only — the scan runs this same walk, and a
        /// fixture that fired there would be testing scan-time staleness.
        func arm() {
            armed = true
            walkOpened = false
            swapped = false
        }

        /// Only the walk's `SecureDirectory` asks this question.
        override func mountIdentity(ofDescriptor descriptor: Int32)
            -> MountIdentity? {
            walkOpened = true
            return super.mountIdentity(ofDescriptor: descriptor)
        }

        override func identity(of url: URL) -> Identity? {
            let real = super.identity(of: url)
            guard armed, walkOpened, !swapped,
                  url.standardizedFileURL.path
                      == target.standardizedFileURL.path
            else { return real }
            swapped = true
            try? FileManager.default.moveItem(at: target, to: stash)
            try? FileManager.default.createDirectory(
                at: replacement, withIntermediateDirectories: true
            )
            return real
        }
    }

    /// The reviewer's scenario end-to-end: the probe returns `complete`
    /// honestly, about the object it held open; the target is then replaced
    /// before the deletion; and the cleaner must refuse rather than delete a
    /// tree it never inspected. Detecting the swap in the probe and then
    /// deleting by path anyway would be no fix at all — this is the
    /// assertion that the binding is CARRIED to the deletion.
    func testTargetReplacedBetweenTheProbeAndTheDeleteIsRefused() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-LATE")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let provider = SwapAfterProbeProvider()
        provider.target = entry
        provider.stash = base.appendingPathComponent("drag-late-moved-away")
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        provider.replacement = library

        let runtime = try makeRuntime(
            [makeScanner(provider: provider)], provider: provider
        )
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)
        XCTAssertTrue(leak.automaticCleanEligible,
                      "the fixture entry scans as a clean known leak")

        provider.arm()
        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [leak], moveToTrash: false)

        XCTAssertTrue(provider.swapped, "the fixture never armed the swap")
        XCTAssertTrue(report.entries.isEmpty, "nothing may be deleted")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("no longer the one that was inspected"),
                      message)
        XCTAssertTrue(
            fm.fileExists(atPath: library.path),
            "the replacement standing at the target's name was DELETED — the "
                + "probe's verdict was about a different inode entirely"
        )
        XCTAssertTrue(fm.fileExists(atPath: provider.stash.path),
                      "and the inspected tree is untouched too")
        try assertCleanupLogContains(tag: "content-drift")
    }

    /// `SwapAfterProbeProvider` with the ONE change that matters: the
    /// attacker wins the race by one syscall instead of losing it by one.
    ///
    /// The sibling above lets the delete-time `lstat` see the NEW inode, so
    /// the path check catches the swap. Here the swap is performed INSIDE
    /// that `lstat` and the PRE-swap identity is returned — and, because a
    /// swap that landed at instant T is invisible to every check that ran
    /// before T, the frozen answer is given to ALL later path questions
    /// about the target too. The fixture is therefore not more capable than
    /// an attacker with a shell in `~/Library/Caches`; it is exactly an
    /// attacker whose `rename(2)` + `mkdir(2)` land in the window between
    /// the last path check and the deletion's `openat`. The real filesystem
    /// mutation is performed for real, once, with real syscalls.
    private final class RaceWonAtTheFinalCheckProvider:
        FileSystemIdentityProvider {
        var target: URL!
        var stash: URL!
        var replacement: URL!
        private var armed = false
        private var walkOpened = false
        private(set) var swapped = false
        /// The identity the probe's verdict is about, frozen at the swap.
        private var frozen: Identity?
        /// Last path question about the target, and the deletion's first
        /// provider question — the window, measured rather than argued.
        private(set) var lastTargetCheck: DispatchTime?
        private(set) var firstDeletionQuestion: DispatchTime?

        func arm() {
            armed = true
            walkOpened = false
            swapped = false
        }

        /// Nanoseconds from the final path check to the first question the
        /// deletion asks of a DESCRIPTOR — which is already past
        /// `open(parent)` and `openat(leaf)`, so it is an UNDER-estimate of
        /// the window. The window did not go away with the fix; it stopped
        /// deciding anything, because the question asked at the end of it is
        /// now asked of the inode rather than of the path.
        var windowNanoseconds: UInt64? {
            guard let lastTargetCheck, let firstDeletionQuestion,
                  firstDeletionQuestion.uptimeNanoseconds
                      >= lastTargetCheck.uptimeNanoseconds
            else { return nil }
            return firstDeletionQuestion.uptimeNanoseconds
                - lastTargetCheck.uptimeNanoseconds
        }

        override func mountIdentity(ofDescriptor descriptor: Int32)
            -> MountIdentity? {
            walkOpened = true
            return super.mountIdentity(ofDescriptor: descriptor)
        }

        /// The deletion's first question about the object it opened — and
        /// the instrument that measures what the window actually is.
        override func identity(ofDescriptor descriptor: Int32) -> Identity? {
            if swapped, firstDeletionQuestion == nil {
                firstDeletionQuestion = .now()
            }
            return super.identity(ofDescriptor: descriptor)
        }

        override func identity(of url: URL) -> Identity? {
            guard armed, walkOpened,
                  url.standardizedFileURL.path
                      == target.standardizedFileURL.path
            else { return super.identity(of: url) }
            if !swapped {
                frozen = super.identity(of: url)
                swapped = true
                try? FileManager.default.moveItem(at: target, to: stash)
                try? FileManager.default.createDirectory(
                    at: replacement, withIntermediateDirectories: true
                )
            }
            lastTargetCheck = .now()
            return frozen
        }
    }

    /// THE BINDING MUST REACH THE DELETION, NOT THE LAST PATH CHECK.
    ///
    /// Same scenario as `testTargetReplacedBetweenTheProbeAndTheDeleteIsRefused`
    /// with the race won rather than lost: every path question — container
    /// admission, containment, deny list, mount, and the probe's own binding
    /// `lstat` — answers about the object that WAS there, and the deletion
    /// then opens the object that IS there. A path re-resolved after the
    /// check is not a proof, so the only thing that can refuse here is a
    /// question asked of the HELD DESCRIPTOR the deletion is about to empty.
    ///
    /// Before the fix this reported `entries=1, errors=[]` — SUCCESS, with
    /// the byte count of a tree that still existed at the stash path — while
    /// deleting the replacement's `Photos Library.photoslibrary`.
    func testTargetReplacedAfterTheFinalPathCheckIsRefused() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-RACE")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let provider = RaceWonAtTheFinalCheckProvider()
        provider.target = entry
        provider.stash = base.appendingPathComponent("drag-race-moved-away")
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        provider.replacement = library

        let runtime = try makeRuntime(
            [makeScanner(provider: provider)], provider: provider
        )
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)
        XCTAssertTrue(leak.automaticCleanEligible,
                      "the fixture entry scans as a clean known leak")

        provider.arm()
        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [leak], moveToTrash: false)

        XCTAssertTrue(provider.swapped, "the fixture never armed the swap")
        if let window = provider.windowNanoseconds {
            print("MEASURED-WINDOW-NS \(window)")
        }
        XCTAssertTrue(
            fm.fileExists(atPath: library.path),
            "the replacement's Photos Library was DELETED — the deletion "
                + "held a descriptor and never asked it who it was"
        )
        XCTAssertTrue(fm.fileExists(atPath: provider.stash.path),
                      "and the inspected tree is untouched too")
        XCTAssertTrue(
            report.entries.isEmpty,
            "reported SUCCESS for a tree it never inspected: \(report.entries)"
        )
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("no longer the one that was inspected"),
                      message)
        try assertCleanupLogContains(tag: "content-drift")
    }

    // MARK: - The same race, on the disposal the GUI actually uses

    /// THE DEFAULT PATH, NOT THE ONE THE FIX LANDED ON (PR #458 review — the
    /// P1 the descriptor binding left open).
    ///
    /// `CacheoutViewModel.moveToTrash` is `true` out of the box, so the
    /// disposal most users take is `FileManager.trashItem`, not
    /// `DepthSafeRemoval`. Identical fixture to
    /// `testTargetReplacedAfterTheFinalPathCheckIsRefused`, identical swap,
    /// one flag flipped — and before the fix the identical outcome the
    /// permanent arm used to produce: the replacement's
    /// `Photos Library.photoslibrary` moved to the Trash, `entries=1`,
    /// `errors=[]`, the byte count of the tree that is still sitting at the
    /// stash path.
    ///
    /// `recorder.urls.isEmpty` is the load-bearing assertion for the PRE-trash
    /// proof specifically: a refusal that only arrives after the item has been
    /// moved would leave the user's Trash disturbed and this list non-empty.
    func testTrashDisposalOfATargetReplacedAfterTheFinalPathCheckIsRefused()
        async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-TRASHRACE")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let provider = RaceWonAtTheFinalCheckProvider()
        provider.target = entry
        provider.stash = base.appendingPathComponent("drag-trashrace-moved-away")
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        provider.replacement = library

        let trashDir = base.appendingPathComponent("fake-trash-race")
        try mkdir(trashDir)
        let recorder = TrashURLRecorder()

        let runtime = try makeRuntime(
            [makeScanner(provider: provider)], provider: provider
        )
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)
        XCTAssertTrue(leak.automaticCleanEligible,
                      "the fixture entry scans as a clean known leak")

        provider.arm()
        let cleaner = runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in
                recorder.record(url)
                let landed = trashDir
                    .appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: landed)
                return landed
            }
        )
        let report = await cleaner.clean(items: [leak], moveToTrash: true)

        XCTAssertTrue(provider.swapped, "the fixture never armed the swap")
        XCTAssertTrue(
            fm.fileExists(atPath: library.path),
            "the replacement's Photos Library was moved to the TRASH — the "
                + "disposal acted on whatever answered to the path"
        )
        XCTAssertTrue(fm.fileExists(atPath: provider.stash.path),
                      "and the inspected tree is untouched too")
        XCTAssertTrue(
            recorder.urls.isEmpty,
            "the disposal ran at all: the proof must refuse BEFORE anything "
                + "reaches the Trash, got \(recorder.urls)"
        )
        XCTAssertTrue(
            report.entries.isEmpty,
            "reported SUCCESS for a tree it never inspected: \(report.entries)"
        )
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("no longer the one that was inspected"),
                      message)
        try assertCleanupLogContains(tag: "content-drift")
    }

    /// Times the residual the Trash arm cannot close: from the pre-trash
    /// proof's question about the OPENED INODE — the last thing the cleaner
    /// asks before the disposal — to the instant the disposal seam is
    /// entered. Production's window is WIDER: `trashItem` resolves the URL
    /// inside itself, after the seam.
    private final class TrashWindowClockProvider: FileSystemIdentityProvider {
        private let lock = NSLock()
        private var lastDescriptorQuestion: DispatchTime?
        /// The pair FROZEN at seam entry — the post-disposal proof asks the
        /// same question again, and an unfrozen "last" would then be later
        /// than the seam and measure nothing.
        private var window: (proof: DispatchTime, seam: DispatchTime)?

        override func identity(ofDescriptor descriptor: Int32) -> Identity? {
            lock.lock()
            lastDescriptorQuestion = .now()
            lock.unlock()
            return super.identity(ofDescriptor: descriptor)
        }

        func enteredTheSeam() {
            lock.lock()
            if window == nil, let proof = lastDescriptorQuestion {
                window = (proof, .now())
            }
            lock.unlock()
        }

        var windowNanoseconds: UInt64? {
            lock.lock(); defer { lock.unlock() }
            guard let window,
                  window.seam.uptimeNanoseconds
                      >= window.proof.uptimeNanoseconds
            else { return nil }
            return window.seam.uptimeNanoseconds
                - window.proof.uptimeNanoseconds
        }
    }

    /// THE WINDOW THE PRE-TRASH PROOF CANNOT CLOSE — and what closes the
    /// OUTCOME instead.
    ///
    /// `trashItem(at:)` takes a URL and resolves it inside itself, so no
    /// proof taken before the call can be carried into it: the binding stops
    /// at the API boundary. This fixture is that residual, exercised — the
    /// swap is performed INSIDE the disposal seam, which is exactly where
    /// production's own resolution happens, and the disposal then takes the
    /// object that is standing at the name.
    ///
    /// The Trash is the one disposal that is REVERSIBLE by construction, so
    /// the answer is not a narrower window: it is proving the object AFTER
    /// the move and putting back what should never have been taken. Nothing
    /// is destroyed, nothing is reported freed, and the user's own tree ends
    /// up exactly where it started.
    func testATrashDisposalThatTookTheWrongObjectPutsItBackAndRefuses()
        async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-PUTBACK")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let stash = base.appendingPathComponent("drag-putback-moved-away")
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        let trashDir = base.appendingPathComponent("fake-trash-putback")
        try mkdir(trashDir)
        let landed = trashDir.appendingPathComponent(entry.lastPathComponent)
        let recorder = TrashURLRecorder()
        let clock = TrashWindowClockProvider()

        let runtime = try makeRuntime(
            [makeScanner(provider: clock)], provider: clock
        )
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)
        XCTAssertTrue(leak.automaticCleanEligible,
                      "the fixture entry scans as a clean known leak")

        let cleaner = runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in
                clock.enteredTheSeam()
                // Real syscalls, at the one instant no pre-call proof can
                // reach: after the proof, inside the disposal.
                try FileManager.default.moveItem(at: entry, to: stash)
                try FileManager.default.createDirectory(
                    at: library, withIntermediateDirectories: true
                )
                recorder.record(url)
                try FileManager.default.moveItem(at: url, to: landed)
                return landed
            }
        )
        let report = await cleaner.clean(items: [leak], moveToTrash: true)

        XCTAssertEqual(recorder.urls.count, 1,
                       "the fixture never reached the disposal")
        // The residual, MEASURED rather than argued: pre-proof `fstat` →
        // disposal seam entered. Under-estimates production, where
        // `trashItem` resolves the URL later still, inside itself.
        if let window = clock.windowNanoseconds {
            print("MEASURED-TRASH-WINDOW-NS \(window)")
        }
        XCTAssertTrue(
            report.entries.isEmpty,
            "reported SUCCESS for a tree it never inspected: \(report.entries)"
        )
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("PUT BACK"), message)
        XCTAssertTrue(message.contains("nothing was freed"), message)
        XCTAssertTrue(
            fm.fileExists(atPath: library.path),
            "the wrongly-taken tree was left in the Trash — a disposal that "
                + "cannot be proved must be UNDONE, not merely reported"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: landed.path),
            "and nothing of it may remain in the Trash"
        )
        XCTAssertTrue(fm.fileExists(atPath: stash.path),
                      "the inspected tree is untouched")
        try assertCleanupLogContains(tag: "content-drift")
    }

    // MARK: - The rollback is a MOVE, so it needs a binding of its own

    /// Re-points the Trash entry at the ONE instant the rollback's binding
    /// has to survive: after the post-disposal proof has looked at the landed
    /// object and rejected it, before the put-back moves anything.
    ///
    /// The seam is a question production already asks at exactly that point —
    /// `identity(ofDescriptor:)` on the descriptor the proof opened for the
    /// landed URL — and every mutation is a real syscall (`rename(2)`,
    /// `mkdir(2)`, `open(2)`), so the fixture is never more capable than an
    /// attacker with a shell: a Finder "Put Back" of the real item plus any
    /// other Trash entry arriving at the vacated name does the same thing.
    private final class SwapTheTrashEntryAfterItIsRejectedProvider:
        FileSystemIdentityProvider {
        /// Where the disposal said it put the item.
        var landed: URL!
        /// Where the wrongly-taken tree goes — still in the Trash, under a
        /// name nobody recorded.
        var elsewhere: URL!
        /// An unrelated Trash entry that takes over `landed`'s name.
        var intruder: URL!
        private(set) var swapped = false

        override func identity(ofDescriptor fd: Int32) -> Identity? {
            let answer = super.identity(ofDescriptor: fd)
            guard !swapped, let answer, answer == super.identity(of: landed)
            else { return answer }
            swapped = true
            try? FileManager.default.moveItem(at: landed, to: elsewhere)
            try? FileManager.default.createDirectory(
                at: landed, withIntermediateDirectories: true
            )
            FileManager.default.createFile(
                atPath: intruder.path, contents: Data("intruder".utf8)
            )
            return answer
        }
    }

    /// A PUT-BACK MAY ONLY MOVE THE OBJECT THE PROOF LOOKED AT (PR #458
    /// review — the P2 on the P1's own fix).
    ///
    /// The rollback is not a read: it MOVES an object INTO the user's cache
    /// tree. `putBack` did that by path — `renamex_np(landed, target)` — so
    /// whatever occupied `landed` at rename time was moved, not the object
    /// whose failed proof triggered the rollback. Before the fix this
    /// fixture moved an unrelated Trash entry into `~/Library/Caches`, left
    /// the wrongly-taken `Photos Library.photoslibrary` sitting in the Trash
    /// under a name the error never mentioned, and reported `.putBack` —
    /// "the item the Trash took has been PUT BACK" — for a recovery that
    /// never happened.
    ///
    /// Same class as the finding above it, one layer down: a proof taken
    /// about an object must reach the destructive call, and the rollback IS
    /// a destructive call.
    func testAPutBackWillNotMoveAnObjectItNeverSawTheTrashTake() async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-REBIND")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let stash = base.appendingPathComponent("drag-rebind-moved-away")
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        let trashDir = base.appendingPathComponent("fake-trash-rebind")
        try mkdir(trashDir)
        let landed = trashDir.appendingPathComponent(entry.lastPathComponent)

        let provider = SwapTheTrashEntryAfterItIsRejectedProvider()
        provider.landed = landed
        provider.elsewhere = trashDir.appendingPathComponent("some-other-name")
        provider.intruder = landed.appendingPathComponent("intruder.bin")

        let runtime = try makeRuntime(
            [makeScanner(provider: provider)], provider: provider
        )
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)
        XCTAssertTrue(leak.automaticCleanEligible,
                      "the fixture entry scans as a clean known leak")

        let cleaner = runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in
                // The disposal takes the wrong object (the residual
                // `testATrashDisposalThatTookTheWrongObjectPutsItBackAndRefuses`
                // measures), which is what arms the rollback at all.
                try FileManager.default.moveItem(at: entry, to: stash)
                try FileManager.default.createDirectory(
                    at: library, withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: url, to: landed)
                return landed
            }
        )
        let report = await cleaner.clean(items: [leak], moveToTrash: true)

        XCTAssertTrue(provider.swapped,
                      "the fixture never re-pointed the Trash entry")
        XCTAssertFalse(
            fm.fileExists(atPath: entry.appendingPathComponent("intruder.bin").path),
            "the put-back moved an object it never saw the Trash take INTO "
                + "the user's cache tree — a rollback is a move, and a move "
                + "with no binding is the very bug it is undoing"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: provider.intruder.path),
            "the unrelated Trash entry must be left exactly where it was"
        )
        XCTAssertTrue(
            fm.fileExists(
                atPath: provider.elsewhere
                    .appendingPathComponent(
                        "Pictures/Photos Library.photoslibrary"
                    ).path
            ),
            "the wrongly-taken tree is still whole, wherever it now is"
        )
        XCTAssertTrue(report.entries.isEmpty,
                      "nothing may be reported freed: \(report.entries)")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertFalse(
            message.contains("PUT BACK"),
            "claimed a recovery that did not happen: \(message)"
        )
        XCTAssertTrue(
            message.contains(landed.path),
            "the refusal must name where the item was last seen: \(message)"
        )
        XCTAssertTrue(fm.fileExists(atPath: stash.path),
                      "the inspected tree is untouched")
        try assertCleanupLogContains(tag: "content-drift")
    }

    /// Re-points the Trash entry INSIDE the rollback's own re-bind — after
    /// the `fstatat` has answered, before `renameatx_np` uses the name.
    ///
    /// That window is one syscall wide inside a directory held by
    /// descriptor, and it cannot be closed: macOS has no rename that takes
    /// the SOURCE as a descriptor. So it is exercised rather than argued,
    /// and what the fixture pins is that losing it produces an honest report
    /// instead of a claimed recovery.
    private final class SwapTheTrashEntryInsideTheReBindProvider:
        FileSystemIdentityProvider {
        var landed: URL!
        var elsewhere: URL!
        /// `nil` re-points the name at NOTHING, so the rename fails ENOENT;
        /// non-nil re-points it at an unrelated object, so the rename
        /// SUCCEEDS on the wrong one. Two different errno classes out of one
        /// window, which is the whole reason they are not flattened.
        var intruder: URL?
        private(set) var swapped = false

        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            let url = logical()
            let answer = super.probeChild(
                inDirectory: descriptor, named: name, logical: url
            )
            guard !swapped,
                  url.standardizedFileURL.path
                      == landed.standardizedFileURL.path
            else { return answer }
            swapped = true
            try? FileManager.default.moveItem(at: landed, to: elsewhere)
            if let intruder {
                try? FileManager.default.createDirectory(
                    at: landed, withIntermediateDirectories: true
                )
                FileManager.default.createFile(
                    atPath: intruder.path, contents: Data("intruder".utf8)
                )
            }
            // The STALE answer — exactly what losing this race yields.
            return answer
        }
    }

    /// A RENAME THAT RETURNS 0 SAYS A NAME MOVED, NOT THAT OUR OBJECT DID.
    ///
    /// The re-bind above it narrows the rollback to one syscall; this is
    /// what happens when that syscall is lost anyway. The put-back moves
    /// SOMETHING into the cache path, and the only acceptable answer is to
    /// prove the arrival and, failing that, say plainly that the object now
    /// standing there came out of the Trash and was not put there by the
    /// user. Reporting `.putBack` here would be the byte-count lie in
    /// another costume.
    func testAPutBackThatMovedSomethingElseSaysSoRatherThanClaimingRecovery()
        async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-ARRIVAL")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let stash = base.appendingPathComponent("drag-arrival-moved-away")
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        let trashDir = base.appendingPathComponent("fake-trash-arrival")
        try mkdir(trashDir)
        let landed = trashDir.appendingPathComponent(entry.lastPathComponent)

        let provider = SwapTheTrashEntryInsideTheReBindProvider()
        provider.landed = landed
        provider.elsewhere = trashDir.appendingPathComponent("some-other-name")
        provider.intruder = landed.appendingPathComponent("intruder.bin")

        let runtime = try makeRuntime(
            [makeScanner(provider: provider)], provider: provider
        )
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)

        let cleaner = runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in
                try FileManager.default.moveItem(at: entry, to: stash)
                try FileManager.default.createDirectory(
                    at: library, withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: url, to: landed)
                return landed
            }
        )
        let report = await cleaner.clean(items: [leak], moveToTrash: true)

        XCTAssertTrue(provider.swapped,
                      "the fixture never re-pointed the Trash entry")
        XCTAssertTrue(report.entries.isEmpty,
                      "nothing may be reported freed: \(report.entries)")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertFalse(
            message.contains("PUT BACK"),
            "claimed a recovery of an object it did not move: \(message)"
        )
        XCTAssertTrue(
            message.contains(landed.path) && message.contains(entry.path),
            "the refusal must name BOTH the Trash name it moved from and "
                + "the path the stranger now occupies: \(message)"
        )
        XCTAssertTrue(fm.fileExists(atPath: stash.path),
                      "the inspected tree is untouched")
        try assertCleanupLogContains(tag: "content-drift")
    }

    /// Swaps THE CACHE ROOT — the directory the put-back would restore INTO
    /// — at the instant the post-disposal proof rejects what the Trash took,
    /// i.e. after the rollback's destination descriptor is about to be opened
    /// and before it is used.
    ///
    /// The seam is production's own question: `identity(ofDescriptor:)` on
    /// the descriptor `look(at: landed)` opened. Every mutation is a real
    /// `rename(2)`/`mkdir(2)` — an app reinstalling its cache folder does
    /// exactly this.
    private final class SwapTheDestinationContainerBeforeThePutBackProvider:
        FileSystemIdentityProvider {
        var landed: URL!
        /// The cache root the item was admitted under.
        var container: URL!
        /// Where that root goes.
        var containerMovedAway: URL!
        private(set) var swapped = false

        override func identity(ofDescriptor fd: Int32) -> Identity? {
            let answer = super.identity(ofDescriptor: fd)
            guard !swapped, let answer, answer == super.identity(of: landed)
            else { return answer }
            swapped = true
            try? FileManager.default.moveItem(
                at: container, to: containerMovedAway
            )
            try? FileManager.default.createDirectory(
                at: container, withIntermediateDirectories: true
            )
            return answer
        }
    }

    /// A PUT-BACK MUST PROVE WHERE IT IS PUTTING THINGS BACK (PR #458 review
    /// — the P2 on the P2).
    ///
    /// The rollback HELD its destination directory by descriptor and never
    /// PROVED it: the descriptor was opened from a path, and a container swap
    /// in that window aimed the undo at a stranger's directory. Worse, the
    /// arrival proof that follows is taken under THAT SAME unproven
    /// descriptor, so it self-confirms — before the fix this moved the
    /// wrongly-taken `Photos Library.photoslibrary` out of the Trash into a
    /// directory nobody admitted and reported `.putBack`, "the item the Trash
    /// took has been PUT BACK", for a recovery into somebody else's folder.
    ///
    /// A descriptor cannot be its own reference point. The identity the
    /// cleaner captured BEFORE the disposal is from outside it, so that is
    /// what the destination is proved against — and when it disagrees,
    /// NOTHING is moved and the error says where the item still is.
    func testAPutBackWillNotRestoreIntoAContainerItCannotProve() async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-DESTINATION")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let stash = base.appendingPathComponent("drag-destination-moved-away")
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        let trashDir = base.appendingPathComponent("fake-trash-destination")
        try mkdir(trashDir)
        let landed = trashDir.appendingPathComponent(entry.lastPathComponent)

        let provider = SwapTheDestinationContainerBeforeThePutBackProvider()
        provider.landed = landed
        provider.container = cachesRoot
        provider.containerMovedAway = base
            .appendingPathComponent("caches-root-moved-away")

        let runtime = try makeRuntime(
            [makeScanner(provider: provider)], provider: provider
        )
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)
        XCTAssertTrue(leak.automaticCleanEligible,
                      "the fixture entry scans as a clean known leak")

        let cleaner = runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in
                // The disposal takes the WRONG object, which is what arms the
                // rollback at all (the residual
                // `testATrashDisposalThatTookTheWrongObjectPutsItBackAndRefuses`
                // measures).
                try FileManager.default.moveItem(at: entry, to: stash)
                try FileManager.default.createDirectory(
                    at: library, withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: url, to: landed)
                return landed
            }
        )
        let report = await cleaner.clean(items: [leak], moveToTrash: true)

        XCTAssertTrue(provider.swapped,
                      "the fixture never re-pointed the cache root")
        XCTAssertTrue(
            fm.fileExists(
                atPath: landed
                    .appendingPathComponent(
                        "Pictures/Photos Library.photoslibrary"
                    ).path
            ),
            "the wrongly-taken tree was moved OUT of the Trash and into a "
                + "directory the safety check never admitted — and the "
                + "arrival proof, taken under that same unproven descriptor, "
                + "confirmed it"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: entry.path),
            "nothing may be restored into the stranger's directory"
        )
        XCTAssertTrue(report.entries.isEmpty,
                      "nothing may be reported freed: \(report.entries)")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertFalse(
            message.contains("PUT BACK"),
            "claimed a recovery into a folder it could not prove: \(message)"
        )
        XCTAssertTrue(
            message.contains(landed.path),
            "the refusal must name where the item still is: \(message)"
        )
        XCTAssertTrue(
            message.contains(
                "the folder that HOLDS it is no longer the one the safety "
                    + "check admitted"
            ),
            message
        )
        XCTAssertTrue(fm.fileExists(atPath: stash.path),
                      "the inspected tree is untouched")
        try assertCleanupLogContains(tag: "content-drift")
    }

    /// Swaps the TRASH DIRECTORY ITSELF — not the entry in it — inside the
    /// rollback's re-bind, which is the mutation a path-spelled rename
    /// cannot survive and a descriptor-relative one does not notice.
    private final class SwapTheTrashDirectoryInsideTheReBindProvider:
        FileSystemIdentityProvider {
        var landed: URL!
        /// Where the WHOLE Trash directory goes.
        var trashMovedAway: URL!
        /// The decoy that answers to `landed`'s spelling afterwards.
        var intruder: URL!
        private(set) var swapped = false

        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            let url = logical()
            let answer = super.probeChild(
                inDirectory: descriptor, named: name, logical: url
            )
            guard !swapped,
                  url.standardizedFileURL.path
                      == landed.standardizedFileURL.path
            else { return answer }
            swapped = true
            let trash = landed.deletingLastPathComponent()
            try? FileManager.default.moveItem(at: trash, to: trashMovedAway)
            try? FileManager.default.createDirectory(
                at: intruder.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(
                atPath: intruder.path, contents: Data("intruder".utf8)
            )
            return answer
        }
    }

    /// THE ROLLBACK'S RENAME GOES THROUGH THE DIRECTORY IT CHECKED, NOT
    /// THROUGH THAT DIRECTORY'S NAME.
    ///
    /// An `fstatat` under a held directory descriptor followed by a rename
    /// through a re-resolved PATH is a check of one thing and a move of
    /// another: re-point the Trash directory between them and the path-spelled
    /// rename walks into a NEW directory and moves whatever answers to the
    /// same leaf. `renameatx_np` against the descriptor the re-bind used
    /// cannot be redirected that way — it moves the object out of the inode
    /// it verified, wherever that inode's name has gone.
    ///
    /// This is the test that makes the descriptors load-bearing rather than
    /// decorative: spell the rename `renamex_np(landed.path, target.path)`
    /// and it goes RED, reporting `putBackTookAnotherObject` for a recovery
    /// that would otherwise have succeeded.
    func testAPutBackFollowsTheTrashDirectoryItCheckedNotItsName() async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-PINNED")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let stash = base.appendingPathComponent("drag-pinned-moved-away")
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        let trashDir = base.appendingPathComponent("fake-trash-pinned")
        try mkdir(trashDir)
        let landed = trashDir.appendingPathComponent(entry.lastPathComponent)

        let provider = SwapTheTrashDirectoryInsideTheReBindProvider()
        provider.landed = landed
        provider.trashMovedAway = base
            .appendingPathComponent("fake-trash-pinned-moved-away")
        provider.intruder = landed.appendingPathComponent("intruder.bin")

        let runtime = try makeRuntime(
            [makeScanner(provider: provider)], provider: provider
        )
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)

        let cleaner = runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in
                try FileManager.default.moveItem(at: entry, to: stash)
                try FileManager.default.createDirectory(
                    at: library, withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: url, to: landed)
                return landed
            }
        )
        let report = await cleaner.clean(items: [leak], moveToTrash: true)

        XCTAssertTrue(provider.swapped,
                      "the fixture never re-pointed the Trash directory")
        XCTAssertTrue(report.entries.isEmpty,
                      "nothing may be reported freed: \(report.entries)")
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(
            message.contains("PUT BACK"),
            "the object the re-bind verified was reachable through the "
                + "descriptor it verified it in — the recovery should have "
                + "succeeded: \(message)"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: library.path),
            "the wrongly-taken tree must be back at its own path, not "
                + "whatever the Trash's NAME now leads to"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: provider.intruder.path),
            "the decoy standing at the re-spelled Trash name must be "
                + "untouched — a rollback that follows a name moves it "
                + "instead"
        )
        XCTAssertTrue(fm.fileExists(atPath: stash.path),
                      "the inspected tree is untouched")
        try assertCleanupLogContains(tag: "content-drift")
    }

    /// "COULD NOT BE PUT BACK" AND "IS NOT WHERE THE TRASH SAID" ARE
    /// DIFFERENT FACTS, AND ONLY ONE OF THEM CAN BE ACTED ON.
    ///
    /// The rename's errno separates them: `EEXIST` from `RENAME_EXCL` leaves
    /// the item exactly where the re-bind found it (`.strandedInTrash`, "move
    /// it back from there"), while `ENOENT` means it went away in the window
    /// the descriptor cannot close, and telling the user to drag it back from
    /// a path nothing occupies is the flattened-errno lie in miniature.
    ///
    /// Same one-syscall window as the test above, one errno over.
    func testAPutBackWhoseSourceVanishedDoesNotSendTheUserToAnEmptyPath()
        async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-VANISH")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let stash = base.appendingPathComponent("drag-vanish-moved-away")
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        let trashDir = base.appendingPathComponent("fake-trash-vanish")
        try mkdir(trashDir)
        let landed = trashDir.appendingPathComponent(entry.lastPathComponent)

        let provider = SwapTheTrashEntryInsideTheReBindProvider()
        provider.landed = landed
        provider.elsewhere = trashDir.appendingPathComponent("some-other-name")
        provider.intruder = nil

        let runtime = try makeRuntime(
            [makeScanner(provider: provider)], provider: provider
        )
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)

        let cleaner = runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in
                try FileManager.default.moveItem(at: entry, to: stash)
                try FileManager.default.createDirectory(
                    at: library, withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: url, to: landed)
                return landed
            }
        )
        let report = await cleaner.clean(items: [leak], moveToTrash: true)

        XCTAssertTrue(provider.swapped,
                      "the fixture never re-pointed the Trash entry")
        XCTAssertFalse(fm.fileExists(atPath: landed.path),
                       "the fixture's premise: the name is empty now")
        XCTAssertTrue(report.entries.isEmpty,
                      "nothing may be reported freed: \(report.entries)")
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertFalse(
            message.contains("it is in the Trash at"),
            "sent the user to a path nothing occupies: \(message)"
        )
        XCTAssertTrue(
            message.contains("no longer at \(landed.path)"),
            "the refusal must say the item is not where the Trash put it: "
                + message
        )
        XCTAssertFalse(
            fm.fileExists(atPath: entry.path),
            "nothing may be moved into the cache tree when the object the "
                + "rollback bound to is gone"
        )
        try assertCleanupLogContains(tag: "content-drift")
    }

    /// A DISPOSAL THAT REPORTS A NAME NOTHING OCCUPIES HAS PUT NOTHING THERE.
    ///
    /// `.absent` at the landing proves nothing (that is what `proveTaken`'s
    /// asymmetry says), and the rollback then has NO object to bind to. The
    /// old put-back tried the rename anyway, got its own ENOENT, and reported
    /// "it is in the Trash at <path>. Move it back from there" — an
    /// instruction pointing at an empty name. Nothing identified, nothing
    /// moved, and the error says where it was last claimed to be.
    func testAPutBackWithNothingToBindToMovesNothingAndSaysSo() async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-NOWHERE")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let trashDir = base.appendingPathComponent("fake-trash-nowhere")
        try mkdir(trashDir)
        let actual = trashDir.appendingPathComponent("where-it-really-went")
        let claimed = trashDir.appendingPathComponent("nothing-is-here")

        let runtime = try makeRuntime([makeScanner()])
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)

        let cleaner = runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in
                try FileManager.default.moveItem(at: url, to: actual)
                return claimed
            }
        )
        let report = await cleaner.clean(items: [leak], moveToTrash: true)

        XCTAssertTrue(report.entries.isEmpty,
                      "nothing may be reported freed: \(report.entries)")
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertFalse(
            message.contains("it is in the Trash at"),
            "told the user to drag back an item from an empty name: \(message)"
        )
        XCTAssertTrue(message.contains(claimed.path), message)
        XCTAssertFalse(
            fm.fileExists(atPath: entry.path),
            "moved something into the cache tree with nothing to bind to"
        )
        XCTAssertTrue(
            fm.fileExists(
                atPath: actual.appendingPathComponent("payload.bin").path
            ),
            "the item is where the disposal really put it, untouched"
        )
        try assertCleanupLogContains(tag: "content-drift")
    }

    /// A DISPOSAL THAT WILL NOT SAY WHAT IT TOOK HAS NOT BEEN PROVED.
    ///
    /// The whole after-the-fact proof rests on `trashItem` reporting where it
    /// put the item. When it does not, there is no object to compare and no
    /// path to put anything back from — so the honest outcome is a refusal
    /// that names the situation, never an entry: an item reported as freed on
    /// the strength of "the call did not throw" is the byte-count lie this
    /// codebase exists to avoid.
    func testATrashDisposalThatWillNotSayWhereItPutTheItemIsRefused()
        async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-SILENT")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let trashDir = base.appendingPathComponent("fake-trash-silent")
        try mkdir(trashDir)
        let landed = trashDir.appendingPathComponent(entry.lastPathComponent)

        let runtime = try makeRuntime([makeScanner()])
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)

        let cleaner = runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in
                try FileManager.default.moveItem(at: url, to: landed)
                return nil
            }
        )
        let report = await cleaner.clean(items: [leak], moveToTrash: true)

        XCTAssertTrue(
            report.entries.isEmpty,
            "reported freed bytes for a disposal it could not check: "
                + "\(report.entries)"
        )
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("did not report where"), message)
        XCTAssertTrue(
            fm.fileExists(atPath: landed.path),
            "the item really was disposed of — the refusal is about what "
                + "cannot be PROVED, not about what did not happen"
        )
        try assertCleanupLogContains(tag: "content-drift")
    }

    /// WHEN THE UNDO ITSELF CANNOT LAND, SAY WHERE THE ITEM IS.
    ///
    /// The put-back is `renamex_np(RENAME_EXCL)`, so it refuses to overwrite
    /// whatever now stands at the original name — undoing one mistake by
    /// destroying somebody else's directory is not an undo. The disclosed
    /// residual of that choice is an item left in the Trash, and the only
    /// acceptable form of it is an error that names the path so the user can
    /// finish the job in one drag.
    func testATrashDisposalThatCannotBePutBackNamesWhereTheItemIs()
        async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-STRANDED")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))
        let stash = base.appendingPathComponent("drag-stranded-moved-away")
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        let occupantMarker = entry.appendingPathComponent("occupant.bin")
        let trashDir = base.appendingPathComponent("fake-trash-stranded")
        try mkdir(trashDir)
        let landed = trashDir.appendingPathComponent(entry.lastPathComponent)

        let runtime = try makeRuntime([makeScanner()])
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)

        let cleaner = runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in
                try FileManager.default.moveItem(at: entry, to: stash)
                try FileManager.default.createDirectory(
                    at: library, withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: url, to: landed)
                // …and the name is taken again before the undo can use it.
                try FileManager.default.createDirectory(
                    at: entry, withIntermediateDirectories: true
                )
                FileManager.default.createFile(
                    atPath: occupantMarker.path, contents: Data("x".utf8)
                )
                return landed
            }
        )
        let report = await cleaner.clean(items: [leak], moveToTrash: true)

        XCTAssertTrue(report.entries.isEmpty, "nothing may be reported freed")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains(landed.path),
                      "the error must name where the item actually is: "
                          + message)
        XCTAssertTrue(
            fm.fileExists(atPath: occupantMarker.path),
            "the undo overwrote the directory standing at the name — an undo "
                + "that destroys is not an undo"
        )
        XCTAssertTrue(
            fm.fileExists(
                atPath: landed.appendingPathComponent(
                    "Pictures/Photos Library.photoslibrary"
                ).path
            ),
            "the wrongly-taken tree is still in the Trash, whole"
        )
        XCTAssertTrue(fm.fileExists(atPath: stash.path),
                      "the inspected tree is untouched")
        try assertCleanupLogContains(tag: "content-drift")
    }

    /// AN ABSENCE PROVES A `.noDirectoryTree` VERDICT ON THE WAY IN, AND
    /// NOTHING AT ALL ON THE WAY OUT — the two positions are not the same
    /// question and the code does not pretend they are.
    ///
    /// Before the disposal, "nothing is there" is exactly what that verdict
    /// says, and the disposal's own ENOENT is the frozen ghost-target
    /// behaviour. After it, the disposal has CLAIMED to put an item at a URL:
    /// if nothing is there, what it took cannot be established, and
    /// unestablished is refused.
    func testAnAbsenceProvesTheVerdictBeforeTheDisposalOnly() throws {
        let ghost = cachesRoot.appendingPathComponent("com.example.Ghost-TRASH")
        let provider = FileSystemIdentityProvider()

        XCTAssertNoThrow(
            try TrashDisposal.proveStanding(
                .noDirectoryTree, at: ghost, provider: provider
            ),
            "an absent target still satisfies a verdict about an ABSENCE"
        )
        XCTAssertThrowsError(
            try TrashDisposal.proveTaken(
                .noDirectoryTree, at: ghost, provider: provider
            ),
            "a disposal that put an item nowhere provable must not pass"
        )
    }

    /// The verdict SHAPE this arm binds to: an absent path proves the
    /// ABSENCE of a tree, and says so rather than reporting a directory it
    /// never saw. Kept as its own unit — it is a statement about the probe,
    /// and the end-to-end refusal below is the statement about the cleaner.
    func testAnAbsentTargetProbesAsNoDirectoryTree() throws {
        let ghost = cachesRoot.appendingPathComponent("com.example.Ghost")
        let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: ghost, provider: FileSystemIdentityProvider()
        )

        XCTAssertTrue(probe.complete)
        XCTAssertEqual(probe.inspected, .noDirectoryTree,
                       "an absent target proves the ABSENCE of a tree — that "
                           + "is what the verdict is about")
    }

    /// The `.noDirectoryTree` sibling of `SwapAfterProbeProvider`: the target
    /// is UNLINKED before the pre-delete probe opens it, so the probe's clean
    /// verdict is about an ABSENCE — and a directory holding user data is
    /// created at that same name before the deletion.
    ///
    /// EVERY MUTATION IS A REAL SYSCALL, and the seam is a question
    /// production already asks at exactly those instants: the deny list's
    /// `isMountPoint` of the target, once in the pre-probe
    /// `validateRemovableItem` and once in the post-probe recheck. The
    /// fixture is therefore never more capable than an attacker with a shell
    /// — it only has better timing.
    private final class DirectoryAfterAbsentProbeProvider:
        FileSystemIdentityProvider {
        var target: URL!
        /// Where the real entry is moved to, before the probe looks.
        var stash: URL!
        /// Created (with intermediates) at the target's name after the probe.
        var replacement: URL!
        /// When set, chmod-000'd once the replacement lands, so the
        /// delete-time `lstat` of the target fails EACCES for real.
        var blinded: URL?
        private var armed = false
        private var mountChecks = 0
        private(set) var removed = false
        private(set) var recreated = false

        /// Arm for the CLEAN only — the scan walks this same tree, and a
        /// fixture that fired there would be testing scan-time staleness.
        func arm() {
            armed = true
            mountChecks = 0
            removed = false
            recreated = false
        }

        override func isMountPoint(_ url: URL) -> Bool {
            guard armed,
                  url.lastPathComponent == target.lastPathComponent
            else { return super.isMountPoint(url) }
            mountChecks += 1
            switch mountChecks {
            case 1:
                // Pre-probe admission: the owning app removes its own cache
                // directory. The probe that follows finds nothing to open.
                try? FileManager.default.moveItem(at: target, to: stash)
                removed = true
            case 2:
                // Post-probe recheck: something recreates the name, holding
                // content nobody has inspected.
                try? FileManager.default.createDirectory(
                    at: replacement, withIntermediateDirectories: true
                )
                recreated = true
                if let blinded {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o000], ofItemAtPath: blinded.path
                    )
                }
            default:
                break
            }
            return super.isMountPoint(url)
        }
    }

    /// The other arm of the binding, END TO END — which is the whole point
    /// (r8). The test that used to carry this name asserted only that the
    /// probe SAYS `.noDirectoryTree` for an absent path: it built no item,
    /// no cleaner and no refusal, so replacing the arm's body with `return
    /// true` left the suite at 667/0. The arm is the ONLY thing standing
    /// between an `automaticCleanEligible` sweep item whose target was
    /// unlinked between scan and delete and the deletion of a tree nobody
    /// ever opened — the same defect class as the swapped-inode arm above,
    /// on the sibling branch of the same switch.
    func testDirectoryAppearingAtAnAbsentTargetIsRefused() async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-GONE")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let provider = DirectoryAfterAbsentProbeProvider()
        provider.target = entry
        provider.stash = base.appendingPathComponent("drag-gone-unlinked")
        let library = entry.appendingPathComponent(
            "Pictures/Photos Library.photoslibrary"
        )
        provider.replacement = library

        let runtime = try makeRuntime(
            [makeScanner(provider: provider)], provider: provider
        )
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)
        XCTAssertTrue(leak.automaticCleanEligible,
                      "the fixture entry scans as a clean known leak")

        provider.arm()
        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [leak], moveToTrash: false)

        XCTAssertTrue(provider.removed, "the fixture never unlinked the target")
        XCTAssertTrue(provider.recreated,
                      "the fixture never recreated the target")
        XCTAssertTrue(report.entries.isEmpty, "nothing may be deleted")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        // THIS MESSAGE PROVES THE ORDERING, not just the verdict. Had the
        // replacement landed BEFORE the probe, the probe would have walked
        // it and refused with "user-data-shaped content" instead — so the
        // fixture cannot silently degrade into testing the other arm.
        XCTAssertTrue(message.contains("no longer the one that was inspected"),
                      message)
        XCTAssertTrue(
            fm.fileExists(atPath: library.path),
            "a directory created at the target's name after an ABSENT "
                + "verdict was DELETED — the probe never opened one byte of it"
        )
        try assertCleanupLogContains(tag: "content-drift")
    }

    /// DIRECTION, at the same site. `kind(of:)` collapses "absent" and
    /// "`lstat` failed" onto `nil`, so `kind(of: target) != .directory` was
    /// TRUE for an unreadable target — an EACCES/EIO `lstat` ADMITTED the
    /// deletion, while the sibling `.directory` arm fails closed on exactly
    /// the same nil. A guard whose failure mode is "proceed" is not a guard.
    ///
    /// The EACCES is real: the target's parent is chmod-000'd for real
    /// between the probe and the check, which is what a `lstat` of a child
    /// of an unsearchable directory returns on this platform.
    func testAnUnreadableTargetAfterAnAbsentProbeIsRefused() async throws {
        let entry = cachesRoot
            .appendingPathComponent("com.apple.SwiftUI.Drag-BLIND")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let provider = DirectoryAfterAbsentProbeProvider()
        provider.target = entry
        provider.stash = base.appendingPathComponent("drag-blind-unlinked")
        provider.replacement = entry.appendingPathComponent("Documents")
        provider.blinded = cachesRoot
        defer { restorePerms(cachesRoot) }

        let runtime = try makeRuntime(
            [makeScanner(provider: provider)], provider: provider
        )
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)
        XCTAssertTrue(leak.automaticCleanEligible)

        provider.arm()
        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [leak], moveToTrash: false)
        restorePerms(cachesRoot)

        XCTAssertTrue(provider.recreated, "the fixture never armed the case")
        XCTAssertTrue(report.entries.isEmpty, "nothing may be deleted")
        let message = try XCTUnwrap(report.errors.first?.message)
        // A refusal, NOT a POSIX error that happened to stop the delete:
        // the guard must be what said no. Under a fail-open `.failed` arm
        // the deletion is attempted and the message is the errno's.
        XCTAssertTrue(message.contains("no longer the one that was inspected"),
                      message)
        try assertCleanupLogContains(tag: "content-drift")
    }

    // MARK: - The root re-bind keeps its errno (PR #458 review r9,
    //         thread PRRT_kwDORmg6_86ZlKDx)

    /// The closing root re-bind is an `lstat`, and `identity(of:)` collapses
    /// EVERY failure onto `nil`. Recording `.transientFailure` for all of
    /// them is the errno flattening this branch built `obstruction(forErrno:)`
    /// to retire — reintroduced by the check that closed the swap dual.
    ///
    /// Here the target's parent becomes UNSEARCHABLE mid-walk, for real
    /// (`chmod 000` fired from inside a walk event, single-threaded, no
    /// sleeps). The closing `lstat` returns `EACCES`, and the honest remedy
    /// is a GRANT — not "re-scan and try again", which reproduces exactly.
    func testUnsearchableParentAtTheRootReBindIsAnAccessDenial() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let entry = cachesRoot.appendingPathComponent("com.example.RootEACCES")
        try mkdir(entry.appendingPathComponent("sub"))
        defer { restorePerms(cachesRoot) }

        var blinded = false
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit
        ) { event in
            guard case .willDescend(let name, _) = event,
                  name == "sub", !blinded else { return }
            blinded = true
            try? self.chmod000(self.cachesRoot)
        }

        XCTAssertTrue(blinded, "the fixture never armed the denial")
        XCTAssertEqual(
            probe.obstructions, [.accessDenied],
            "the closing re-bind could not read the target's own name, and "
                + "the reason was a PERMISSION — a bare re-scan reproduces it"
        )
        XCTAssertEqual(
            OrphanedCachesScanner.remediationGuidance(for: probe.obstructions)
                .contains("granting access"),
            true,
            OrphanedCachesScanner.remediationGuidance(for: probe.obstructions)
        )
    }

    /// The same site, the other permanent class: an ancestor replaced by a
    /// REAL self-referential symlink mid-walk, so the closing `lstat` returns
    /// `ELOOP`. Nothing about a re-scan changes a symlink cycle; only
    /// restructuring the path does, and `.unaddressablePath` is the class
    /// that says so.
    func testSymlinkCycleAtTheRootReBindIsAnUnaddressablePath() throws {
        let anchor = base.appendingPathComponent("loop-anchor")
        let mid = anchor.appendingPathComponent("mid")
        let entry = mid.appendingPathComponent("entry")
        try mkdir(entry.appendingPathComponent("sub"))
        let stash = anchor.appendingPathComponent("mid-gone")

        var looped = false
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit
        ) { event in
            guard case .willDescend(let name, _) = event,
                  name == "sub", !looped else { return }
            looped = true
            XCTAssertEqual(rename(mid.path, stash.path), 0,
                           "fixture rename failed: \(errno)")
            // A REAL cycle: `mid` -> `mid`, resolved relative to `anchor`.
            XCTAssertEqual(symlink("mid", mid.path), 0,
                           "fixture symlink failed: \(errno)")
        }

        XCTAssertTrue(looped, "the fixture never armed the cycle")
        var probeStat = stat()
        XCTAssertEqual(lstat(entry.path, &probeStat), -1)
        XCTAssertEqual(errno, ELOOP,
                       "the fixture must really produce ELOOP on this platform")
        XCTAssertEqual(
            probe.obstructions, [.unaddressablePath],
            "a symlink cycle in the path is STRUCTURAL — a re-scan of an "
                + "unchanged tree reproduces it exactly"
        )
    }

    // MARK: - The climb's per-level `..` re-proof (PR #458 review r7)

    /// A two-step climb whose FIRST landing cannot be proven and whose
    /// SECOND lands correctly.
    ///
    /// Without the per-level comparison the walk accepts the re-anchor and
    /// finishes `complete`: the intermediate level was foreign, and "the
    /// last step happened to match" is luck, not proof. This is the shape
    /// the DESCENT corroborator cannot mask — every inode opened afterwards
    /// really is a vetted one — so the verdict itself is the only
    /// observable, which is exactly why the guard was unevidenced before.
    func testAClimbLevelThatCannotBeProvenEndsTheWalk() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.ClimbProof")
        let a = entry.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        let c = b.appendingPathComponent("c")
        try mkdir(c)
        // `q` sorts after `b`, so `a` still has pending work when the walk
        // unwinds out of `c` — which is what forces the climb.
        let q = a.appendingPathComponent("q")
        try mkdir(q)

        var moved = false
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
            descriptorWindow: 2
        ) { event in
            guard case .willPop(let depth) = event, depth == 3, !moved else {
                return
            }
            moved = true
            // `c` moves from `a/b/c` to `a/q/c`: its `..` now names `q`, a
            // directory this walk has vetted but is NOT standing on — and
            // the step ABOVE that still lands on `a`, correctly.
            try? FileManager.default.moveItem(
                at: c, to: q.appendingPathComponent("c")
            )
        }

        XCTAssertTrue(moved, "the fixture never armed the move")
        XCTAssertEqual(probe.obstructions, [.transientFailure])
        XCTAssertFalse(
            probe.complete,
            "the climb passed through a level it could not prove; a later "
                + "level matching is coincidence, not proof, and a walk that "
                + "cannot say where it stood must not certify anything clean"
        )
    }

    /// Records the INODE of the directory every descriptor-relative call was
    /// made against — what the walk actually HELD, never the spelling it
    /// believes in. Containment is the guarantee, so "which objects did this
    /// walk operate inside" is the property worth asserting directly.
    private final class ParentRecordingProvider: FileSystemIdentityProvider {
        private(set) var openedInside: [UInt64] = []
        private(set) var namesOpened: [String] = []
        private(set) var namesProbed: [String] = []

        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            namesProbed.append(name)
            return super.probeChild(
                inDirectory: descriptor, named: name, logical: logical()
            )
        }

        override func openChildDirectoryCarryingErrno(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> DescriptorOpen {
            if let id = super.identity(ofDescriptor: descriptor) {
                openedInside.append(id.inode)
            }
            namesOpened.append(name)
            return super.openChildDirectoryCarryingErrno(
                inDirectory: descriptor, named: name, logical: logical()
            )
        }
    }

    /// The containment half of the same guard: a climb that lands somewhere
    /// it cannot prove must not go on to OPEN things inside it. Without the
    /// per-level re-proof the walk re-anchors onto `~/Library/Caches` itself
    /// and issues a real `openat` in there — a filesystem operation against
    /// an object this walk never vetted, which is the doctrine's whole line.
    func testAFailedClimbNeverOpensChildrenOfAnUnvettedParent() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.ClimbEscape")
        let a = entry.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        let c = b.appendingPathComponent("c")
        try mkdir(c)
        try mkdir(a.appendingPathComponent("z"))
        // Where a wrong climb lands, and what it would then open: a sibling
        // of the entry, one `..` above the walk root.
        let outside = cachesRoot.appendingPathComponent("z")
        try mkdir(outside.appendingPathComponent("Documents"))
        let elsewhere = base.appendingPathComponent("elsewhere")
        try mkdir(elsewhere)

        let provider = ParentRecordingProvider()
        var moved = false
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: provider,
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
            descriptorWindow: 2
        ) { event in
            guard case .willPop(let depth) = event, depth == 3, !moved else {
                return
            }
            moved = true
            try? FileManager.default.moveItem(
                at: c, to: elsewhere.appendingPathComponent("c")
            )
        }

        XCTAssertTrue(moved, "the fixture never armed the move")
        let inside = Set([entry, a, b].compactMap {
            provider.identity(of: $0)?.inode
        })
        XCTAssertEqual(inside.count, 3, "fixture inodes")
        XCTAssertTrue(
            Set(provider.openedInside).isSubset(of: inside),
            "the walk opened a child inside a directory it never vetted — "
                + "containment, not identity, is the guarantee"
        )
        XCTAssertFalse(probe.complete)
        XCTAssertTrue(probe.matches.isEmpty,
                      "and nothing outside the entry was attributed to it: "
                          + "\(probe.matches)")
    }

    // MARK: - `O_NOFOLLOW` on the descent open, standing alone (r7)

    /// A vetted directory replaced by a SYMLINK TO ITSELF.
    ///
    /// The descent corroborator is blind here BY CONSTRUCTION: following the
    /// link lands on the very inode that was vetted, so `child.identity ==
    /// vetted[name]` holds and the comparison waves it through. Only the
    /// no-follow flag on the open refuses to traverse a link at all — which
    /// is why the flag has to stand on its own rather than lean on a check
    /// that cannot see this case. (A guard masked by another guard is one
    /// refactor from being deleted as dead.)
    func testADirectoryReplacedByALinkToItselfIsStillNeverFollowed() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.SelfLink")
        let sub = entry.appendingPathComponent("sub")
        try mkdir(sub.appendingPathComponent("inner"))

        var swapped = false
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit
        ) { event in
            guard case .willDescend(let name, let from) = event,
                  name == "sub", !swapped else { return }
            swapped = true
            // Real `rename(2)` + real `symlink(2)`: the SAME inode, now
            // reachable only through a link at the vetted name.
            XCTAssertEqual(
                rename(from.appendingPathComponent("sub").path,
                       from.appendingPathComponent("sub-real").path),
                0, "fixture rename failed: \(errno)"
            )
            XCTAssertEqual(
                symlink("sub-real", from.appendingPathComponent("sub").path),
                0, "fixture symlink failed: \(errno)"
            )
        }

        XCTAssertTrue(swapped, "the fixture never armed the swap")
        XCTAssertEqual(
            probe.obstructions, [.transientFailure],
            "`O_DIRECTORY|O_NOFOLLOW` on a symlink is ENOTDIR — the tree "
                + "changed under the walk, which is retryable"
        )
        XCTAssertFalse(
            probe.complete,
            "the walk traversed a symlink. The identity corroborator cannot "
                + "see this: the link resolves to the inode it vetted"
        )
    }

    // MARK: - One validation point for a component (r7)

    /// A `d_name` the walk must refuse to hand to any syscall.
    ///
    /// `openat` accepts a MULTI-COMPONENT relative path and `O_NOFOLLOW`
    /// then guards only its LAST component, so a name containing `/` walks
    /// straight out of the entry. APFS and HFS+ will not create such a
    /// basename — which is exactly why this is driven through the same
    /// `decode` seam the undecodable-name policy is already tested through
    /// (`boundedChildNames(decode:)`): the double is the raw-bytes → String
    /// step, no more capable than the `d_name` a userland filesystem driver
    /// (FUSE, SMB) can put in front of the kernel.
    ///
    /// The rule used to be spelled twice — once before the discovery
    /// `fstatat`, once before the descent `openat` — and deleting EITHER
    /// left the suite green, because the other caught the name first. It is
    /// now a TYPE with one construction point, so this test has exactly one
    /// guard to fail against.
    func testAMultiComponentBasenameNeverReachesASyscall() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.UnsafeName")
        try mkdir(entry.appendingPathComponent("bait"))
        // One `..` above the walk root — where `openat(entry, "../…")` lands.
        let outside = cachesRoot.appendingPathComponent("outside-the-entry")
        try mkdir(outside.appendingPathComponent("Documents"))

        let provider = ParentRecordingProvider()
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: provider,
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
            decode: { pointer in
                guard let name = OrphanedCachesScanner
                    .decodedBasename(fromCString: pointer)
                else { return nil }
                return name == "bait" ? "../outside-the-entry" : name
            }
        )

        XCTAssertTrue(
            probe.matches.isEmpty,
            "the walk escaped the entry through a multi-component basename "
                + "and attributed what it found there to this entry: "
                + "\(probe.matches)"
        )
        XCTAssertEqual(probe.obstructions, [.transientFailure])
        XCTAssertFalse(probe.complete, "a name it will not address is a "
                           + "branch it did not inspect")
        XCTAssertFalse(
            provider.namesProbed.contains { $0.contains("/") },
            "an unvalidated name reached the discovery `fstatat`: "
                + "\(provider.namesProbed)"
        )
        XCTAssertFalse(
            provider.namesOpened.contains { $0.contains("/") },
            "an unvalidated name reached the descent `openat`: "
                + "\(provider.namesOpened)"
        )
    }

    // MARK: - The walk's spelling never asks the filesystem (r7)

    /// `URL.appendingPathComponent(_:)` WITHOUT `isDirectory:` decides its
    /// trailing slash by STATTING the composed path — measured on this
    /// platform: an existing directory composes as `…/name/`, an absent one
    /// as `…/name`. That is a path-based filesystem access below the walk
    /// root, performed once per entry, whose answer depends on whether an
    /// attacker's rename has already landed.
    ///
    /// The fixture renames the walk's own parent out from under it mid-walk
    /// (the walk keeps going: it holds the descriptor), so every composition
    /// after that instant would silently change shape. Compared as
    /// `absoluteString`, because `URL.path` normalises the trailing slash
    /// away and would hide the whole effect.
    func testTheWalksSpellingIsComposedWithoutConsultingTheFilesystem() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Spelled")
        let xURL = entry.appendingPathComponent("x", isDirectory: true)
        let yURL = xURL.appendingPathComponent("y", isDirectory: true)
        let yAsLeaf = xURL.appendingPathComponent("y", isDirectory: false)
        try mkdir(yURL)

        final class SpellingProvider: FileSystemIdentityProvider {
            var probed: [String: String] = [:]
            var opened: [String: String] = [:]

            override func probeChild(
                inDirectory descriptor: Int32, named name: String,
                logical: @autoclosure () -> URL
            ) -> ChildProbe {
                let logical = logical()
                probed[name] = logical.absoluteString
                return super.probeChild(
                    inDirectory: descriptor, named: name, logical: logical
                )
            }

            override func openChildDirectoryCarryingErrno(
                inDirectory descriptor: Int32, named name: String,
                logical: @autoclosure () -> URL
            ) -> DescriptorOpen {
                let logical = logical()
                opened[name] = logical.absoluteString
                return super.openChildDirectoryCarryingErrno(
                    inDirectory: descriptor, named: name, logical: logical
                )
            }
        }

        let provider = SpellingProvider()
        var enumerated: [String] = []
        var renamed = false
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: provider,
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit
        ) { event in
            switch event {
            case .didEnumerate(let logical, _):
                enumerated.append(logical.absoluteString)
            case .willDescend(let name, _) where name == "y" && !renamed:
                renamed = true
                // From here on the composed path `…/x` does NOT exist, so a
                // stat-deciding composition changes its answer.
                XCTAssertEqual(
                    rename(xURL.path,
                           entry.appendingPathComponent("moved-x").path),
                    0, "fixture rename failed: \(errno)"
                )
            default: break
            }
        }

        XCTAssertTrue(renamed, "the fixture never armed the rename")
        XCTAssertTrue(probe.complete, "\(probe.obstructions)")

        // (a) A child whose kind the probe is ABOUT to establish claims
        //     nothing — even though `y` is a real directory on disk at this
        //     moment, which is precisely what a stat would notice.
        XCTAssertEqual(provider.probed["y"], yAsLeaf.absoluteString,
                       "the discovery spelling consulted the filesystem")
        // (b) A vetted directory states what the `fstatat` already proved —
        //     composed AFTER its parent's name went away.
        XCTAssertEqual(provider.opened["y"], yURL.absoluteString,
                       "the descent spelling consulted the filesystem")
        // (c) And the walk's own per-level composition, likewise.
        XCTAssertEqual(
            enumerated,
            [entry.absoluteString, xURL.absoluteString, yURL.absoluteString],
            "an observer's spelling changed shape because of a rename an "
                + "attacker landed mid-walk"
        )
    }

    // MARK: - The bookkeeping is bounded in CPU too (r7, thread
    //         PRRT_kwDORmg6_86ZkfDO)

    /// One pass's accounting sample set.
    private struct BookkeepingTally {
        var passes = 0
        var worst = 0
        var total = 0

        mutating func record(_ inspected: Int) {
            passes += 1
            worst = max(worst, inspected)
            total += inspected
        }
    }

    /// THE BUDGET BOUNDS ATTENTION, NOT RESOURCES — and CPU is a resource.
    ///
    /// `makeRoom` used to rescan the WHOLE frame stack three times per
    /// descent (the eager-tail-release loop, `liveCount()`'s reduce, and the
    /// shallowest-live search), so a single-child chain grew quadratically
    /// in CPU while its entry count stayed flat: ~10⁹ frame inspections at
    /// the 20,000-entry budget, before the walk even begins to unwind.
    ///
    /// BOTH PASSES, AND THAT IS THE POINT (r8). The first fix reached only
    /// `makeRoom`, and the test that certified it sampled only `makeRoom`,
    /// so the pop path's `frames[..<depth].lastIndex(where:)` — which on a
    /// single-child chain matches NOTHING and therefore scans the entire
    /// prefix, every pop, d²/2 inspections over the unwind: 5,121,601
    /// measured at depth 3200, ~2.0 × 10⁸ at the 20,000-entry budget —
    /// survived a fix and a review round untouched.
    ///
    /// AND THE NUMBER IS NO LONGER THE WALK'S OWN CLAIM (PR #458 review, the
    /// pop-path mutation). Both earlier versions of this test read
    /// `popInspected`/`inspected` — literals the walk maintained by hand —
    /// so the mutation that matters most here passed them all: restore the
    /// O(depth) prefix scan, leave `popInspected = 1` alone, suite green at
    /// 672/672. What is asserted below is a difference of `FrameStateReads`,
    /// charged INSIDE `Frame.cursor` and `Frame.pending`. Those two fields
    /// are the only state a "does this frame still have work?" predicate can
    /// consult, so a prefix scan cannot be written that does not pay for
    /// itself, and cannot forget to.
    ///
    /// The bound asserted is a CONSTANT, not `2 × window`: neither pass has
    /// any business reading more than the handful of fields it decides on,
    /// and a window-shaped ceiling leaves room for a scan that a constant
    /// does not.
    func testFrameBookkeepingIsBoundedByTheWindowNotTheDepth() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Bookkeeping")
        try mkdir(entry)
        // Deep enough that a depth-shaped accounting is unmistakable (800 ≫
        // 2W = 16), shallow enough that composing a `WalkEvent` observer's
        // O(depth) spelling twice per level stays a second or two — the
        // observer is what costs here, never the walk.
        let levels = 800
        let deepest = try makeDeepChain(under: entry, name: "d", levels: levels)
        defer { removeDeepChain(deepest: deepest, stopAt: entry, name: "d") }

        let window = 8
        var descent = BookkeepingTally()
        var pop = BookkeepingTally()
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
            descriptorWindow: window
        ) { event in
            guard case .frameBookkeeping(let reads, _, let pass) = event
            else { return }
            switch pass {
            case .descent: descent.record(reads)
            case .pop: pop.record(reads)
            }
        }

        XCTAssertTrue(probe.complete, "\(probe.obstructions)")
        XCTAssertEqual(descent.passes, levels,
                       "one accounting pass per descent, or this test is not "
                           + "measuring the descent path at all")
        // Every frame pushed is popped, root included — anything less and
        // the pop assertions below are pinned to a sample set that misses
        // the deep end of the unwind, which is exactly how this defect
        // survived r7.
        XCTAssertEqual(pop.passes, levels + 1,
                       "one accounting pass per popped frame, or this test is "
                           + "not measuring the pop path at all")

        // A pass decides on the frame it is standing on: measured, 3 field
        // reads in the worst pass on either side, at ANY depth. Reading
        // more than a handful means the frame STACK is being scanned again
        // — at this depth a prefix scan reports ~\(2 * levels) per pop.
        let ceiling = 4
        XCTAssertLessThan(
            ceiling, window,
            "the bound must be a CONSTANT, tighter than the window — a "
                + "window-shaped ceiling leaves room for the very scan this "
                + "test exists to catch"
        )
        for (name, tally) in [("descent", descent), ("pop", pop)] {
            XCTAssertLessThanOrEqual(
                tally.worst, ceiling,
                "one \(name) pass READ \(tally.worst) frame-state fields at "
                    + "a depth of \(levels) — the bookkeeping is a function "
                    + "of DEPTH again"
            )
            XCTAssertLessThanOrEqual(
                tally.total, (levels + 1) * ceiling,
                "\(tally.total) frame-state reads over \(tally.passes) "
                    + "\(name) passes — linear in entries is the contract; "
                    + "a prefix scan would spend ~\(levels * levels)"
            )
        }
    }

    // MARK: - Platform errno pinning (PR #458 review, ancestor swap)

    /// The taxonomy is routed by errno, so the errnos themselves are pinned.
    /// A future macOS change breaks THIS test, loudly, instead of silently
    /// re-routing obstruction classes.
    func testPlatformErrnosThisTaxonomyIsRoutedBy() throws {
        let dir = base.appendingPathComponent("errno-pinning")
        try mkdir(dir.appendingPathComponent("real"))
        let link = dir.appendingPathComponent("link")
        try fm.createSymbolicLink(
            at: link, withDestinationURL: dir.appendingPathComponent("real")
        )

        // A symlink leaf under O_DIRECTORY|O_NOFOLLOW is ENOTDIR, NEVER
        // ELOOP — which is why the `openObstruction` disambiguator this
        // review deleted had never once fired in production.
        let swapped = open(link.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertEqual(swapped, -1)
        XCTAssertEqual(errno, ENOTDIR, "a swapped leaf must classify as ENOTDIR")
        if swapped >= 0 { close(swapped) }
        XCTAssertEqual(OrphanedCachesScanner.obstruction(forErrno: ENOTDIR),
                       .transientFailure)

        // ELOOP does survive O_DIRECTORY for a genuine ANCESTOR cycle —
        // which is the only way it can still reach this walk, and only at
        // the root open.
        let loopA = dir.appendingPathComponent("loopA")
        let loopB = dir.appendingPathComponent("loopB")
        try fm.createSymbolicLink(at: loopA, withDestinationURL: loopB)
        try fm.createSymbolicLink(at: loopB, withDestinationURL: loopA)
        let cycle = open(
            loopA.appendingPathComponent("x").path, O_RDONLY | O_DIRECTORY
        )
        XCTAssertEqual(cycle, -1)
        XCTAssertEqual(errno, ELOOP, "a structural cycle must stay ELOOP")
        if cycle >= 0 { close(cycle) }
        XCTAssertEqual(OrphanedCachesScanner.obstruction(forErrno: ELOOP),
                       .unaddressablePath)
    }

    /// A multi-component name defeats `O_NOFOLLOW` entirely — measured:
    /// `openat(base, "cache/mid/secret.bin", O_NOFOLLOW)` opens a foreign
    /// file through a symlinked `mid`. `readdir` cannot produce such a name
    /// today; the guard turns a future refactor that could into a refusal.
    func testUnsafeComponentsAreRefusedBeforeAnySyscall() {
        XCTAssertFalse(OrphanedCachesScanner.isSafeComponent("a/b"))
        XCTAssertFalse(OrphanedCachesScanner.isSafeComponent("/"))
        XCTAssertFalse(OrphanedCachesScanner.isSafeComponent("."))
        XCTAssertFalse(OrphanedCachesScanner.isSafeComponent(".."))
        XCTAssertFalse(OrphanedCachesScanner.isSafeComponent(""))
        XCTAssertTrue(OrphanedCachesScanner.isSafeComponent("Photos Library.photoslibrary"))
        XCTAssertTrue(OrphanedCachesScanner.isSafeComponent(".hidden"))
    }

    /// The mount discriminator, against a REAL firmlink rather than an
    /// injected fake: `/` and `/System/Volumes/Data` share one `st_dev` on
    /// every macOS 11+ machine, and only `f_fsid` separates them. The old
    /// device arm was blind to exactly this.
    func testRealFirmlinkIsDistinguishedByFilesystemID() throws {
        let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data")
        try XCTSkipIf(!fm.fileExists(atPath: dataVolume.path),
                      "no firmlinked data volume on this machine")
        let provider = FileSystemIdentityProvider()
        let rootFD = try openDirectory(URL(fileURLWithPath: "/"))
        defer { close(rootFD) }
        let dataFD = try openDirectory(dataVolume)
        defer { close(dataFD) }

        let rootMount = try XCTUnwrap(provider.mountIdentity(ofDescriptor: rootFD))
        let dataMount = try XCTUnwrap(provider.mountIdentity(ofDescriptor: dataFD))

        XCTAssertEqual(rootMount.device, dataMount.device,
                       "precondition: the firmlink pair shares one st_dev, "
                           + "which is why a device comparison cannot see it")
        XCTAssertNotEqual(rootMount, dataMount,
                          "f_fsid is what actually carries the mount check")
    }

    // MARK: - Order and budget are unchanged (constraint 7)

    /// Byte-wise ascending siblings, depth-first pre-order, one global entry
    /// budget — the same sequence the flat-URL stack produced, now driven by
    /// a per-level frame. Recorded through the walk's own hook and compared
    /// against the order computed independently from the fixture.
    func testVisitOrderIsDeterministicDepthFirstAndByteAscending() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Order")
        for name in ["b", "a", "C", "a/deep", "a/deep/z", "a/deep/y", "b/x"] {
            try mkdir(entry.appendingPathComponent(name))
        }
        try writeFile(entry.appendingPathComponent("a/file.bin"), bytes: 1)

        func record() -> [String] {
            var sequence: [String] = []
            _ = OrphanedCachesScanner.boundedUserDataShapeWalk(
                at: entry, provider: FileSystemIdentityProvider(),
                entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit
            ) { event in
                if case .didEnumerate(let logical, let names) = event {
                    sequence.append(
                        "\(logical.lastPathComponent):\(names.joined(separator: ","))"
                    )
                }
            }
            return sequence
        }

        let first = record()
        XCTAssertEqual(first, record(), "the walk must be deterministic")
        XCTAssertEqual(first, [
            "com.example.Order:C,a,b",   // byte-wise: uppercase sorts first
            "C:",
            "a:deep,file.bin",
            "deep:y,z",
            "y:",
            "z:",
            "b:x",
            "x:",
        ], "depth-first pre-order, siblings byte-ascending")
    }

    /// The budget is ONE global count across the whole frame stack, and a
    /// tree bigger than it truncates at the SAME place every time.
    func testBudgetTruncationIsGlobalAndReproducible() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Budget")
        for name in ["a", "b", "c"] {
            try mkdir(entry.appendingPathComponent("\(name)/inner"))
        }

        func run() -> UserDataProbeResult {
            OrphanedCachesScanner.boundedUserDataShapeWalk(
                at: entry, provider: FileSystemIdentityProvider(), entryLimit: 4
            )
        }
        let first = run()
        XCTAssertEqual(first, run())
        XCTAssertEqual(first.obstructions, [.budgetExhausted])
        XCTAssertFalse(first.complete)
    }

    /// Constraint 5: the scan-time and delete-time faces are ONE core, so an
    /// ancestor swap is refused identically on both — including the item the
    /// scan-time face builds out of it.
    func testAncestorSwapIsRefusedOnBothFaces() async throws {
        let foreign = base.appendingPathComponent("outside-both-faces")
        try mkdir(foreign.appendingPathComponent("deep/Documents"))

        let entry = cachesRoot.appendingPathComponent("com.example.BothFaces")
        let mid = entry.appendingPathComponent("mid")
        try mkdir(mid.appendingPathComponent("deep/keeper"))
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let provider = AncestorSwappingProvider()
        provider.swapWhenProbing = "/\(mid.lastPathComponent)/deep"
        provider.ancestor = mid
        provider.stash = base.appendingPathComponent("stashed-both")
        provider.replacement = foreign
        provider.replaceWithSymlink = true

        guard case .entries(let facts) =
            makeScanner(provider: provider).enumerateFacts() else {
            return XCTFail("expected facts")
        }
        let fact = try XCTUnwrap(
            facts.first { $0.name == entry.lastPathComponent }
        )
        XCTAssertTrue(provider.swapped, "the fixture never armed the swap")
        XCTAssertTrue(fact.userDataShapeMatches.isEmpty,
                      "the scan-time face attributed foreign user data to "
                          + "this entry: \(fact.userDataShapeMatches)")
        XCTAssertTrue(fact.userDataProbeComplete,
                      "and it stayed COMPLETE over the vetted inodes — the "
                          + "held descriptors keep reading the objects that "
                          + "were proven, wherever the swap moved them")
    }

    // MARK: - The budget bounds WORK, not just attention (PR #458 review)

    /// The entry budget must bound what the walk MATERIALIZES, not only what
    /// it inspects. `contentsOfDirectory(at:).sorted` read and sorted every
    /// child before any per-entry guard could fire, so a single cache
    /// directory with millions of entries could spike memory and stall the
    /// scan while only 20,000 entries were ever looked at.
    func testBoundedDirectoryReadStopsAtTheBudgetAndReportsTruncation() throws {
        let wide = cachesRoot.appendingPathComponent("wide")
        try mkdir(wide)
        for index in 0..<2_000 {
            try writeFile(wide.appendingPathComponent("f\(index).bin"), bytes: 1)
        }

        // The read is DESCRIPTOR-RELATIVE now: the caller hands over a
        // parent it already holds, so there is no path resolution here at
        // all and nothing to swap under it.
        let wideFD = try openDirectory(wide)
        defer { close(wideFD) }
        let bounded = OrphanedCachesScanner.boundedChildNames(
            inDirectory: wideFD, limit: 5
        )
        guard case .read(let names, let truncatedBy) = bounded else {
            return XCTFail("expected a bounded read, got \(bounded)")
        }
        XCTAssertEqual(names.count, 5,
                       "at most `limit` basenames are ever held in memory")
        XCTAssertEqual(truncatedBy, [.budgetExhausted],
                       "and the read reports that more entries remained")

        // The anchor SURVIVES the read (`closedir` closes only the
        // enumeration handle `openat(fd, ".")` produced), and a second pass
        // starts from offset 0 — which `dup`/`F_DUPFD_CLOEXEC` would not,
        // since both share the file offset and return zero entries.
        let second = OrphanedCachesScanner.boundedChildNames(
            inDirectory: wideFD, limit: 5
        )
        guard case .read(let secondNames, _) = second else {
            return XCTFail("the anchor did not survive the first read")
        }
        XCTAssertEqual(secondNames.count, 5,
                       "a re-enumeration must not start at a shared offset")

        // Read whole when it fits, and PROVEN exhausted — the completeness
        // signal the fail-closed rule depends on.
        let small = cachesRoot.appendingPathComponent("narrow")
        try mkdir(small)
        try writeFile(small.appendingPathComponent("only.bin"), bytes: 1)
        let smallFD = try openDirectory(small)
        defer { close(smallFD) }
        XCTAssertEqual(
            OrphanedCachesScanner.boundedChildNames(inDirectory: smallFD, limit: 5),
            .read(["only.bin"], truncatedBy: [])
        )

        // An unopenable directory is refused BEFORE any descriptor exists,
        // and the walk attributes it — the same class, one level up.
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let blocked = cachesRoot.appendingPathComponent("blocked-read")
        let locked = blocked.appendingPathComponent("locked")
        try mkdir(locked)
        try chmod000(locked)
        defer { restorePerms(locked) }
        XCTAssertEqual(
            OrphanedCachesScanner.preDeleteUserDataProbe(
                at: blocked, provider: FileSystemIdentityProvider()
            ).obstructions,
            [.accessDenied]
        )
    }

    /// THE PRIMITIVE THE EXACT-BUDGET PROOF RESTS ON: at a capacity of ZERO
    /// the read still separates "this directory is empty" from "this
    /// directory holds something we cannot afford", and admits no name
    /// either way. Without that separation the walk has nothing to descend
    /// with, and a spent budget has to be guessed at (which is what
    /// manufactured a permanent `.budgetExhausted` for trees that fit).
    func testAZeroCapacityReadStillTellsEOFFromAnOverBudgetEntry() throws {
        let empty = cachesRoot.appendingPathComponent("zero-empty")
        try mkdir(empty)
        let emptyFD = try openDirectory(empty)
        defer { close(emptyFD) }
        XCTAssertEqual(
            OrphanedCachesScanner.boundedChildNames(
                inDirectory: emptyFD, limit: 0
            ),
            .read([], truncatedBy: []),
            "immediate EOF PROVES exhaustion: nothing is beyond the budget"
        )

        // `.` and `..` are still skipped rather than counted as entries —
        // otherwise every directory on the system would read as over budget.
        let occupied = cachesRoot.appendingPathComponent("zero-occupied")
        try mkdir(occupied)
        try writeFile(occupied.appendingPathComponent("only.bin"), bytes: 1)
        let occupiedFD = try openDirectory(occupied)
        defer { close(occupiedFD) }
        XCTAssertEqual(
            OrphanedCachesScanner.boundedChildNames(
                inDirectory: occupiedFD, limit: 0
            ),
            .read([], truncatedBy: [.budgetExhausted]),
            "one real entry beyond the budget, and NO name materialised"
        )
    }

    /// The SENTINEL read — the one extra `readdir` whose only job is to
    /// prove the directory holds more than the budget allows — must not
    /// lose that proof to the decode guard sitting in front of the capacity
    /// check. Both facts are true of the same entry, both survive clearing
    /// the other (raise the budget and the name still stops the walk;
    /// rename it and the entry count still exceeds the budget), so both
    /// must reach the remedy ordering.
    ///
    /// The fixture cannot be built on this filesystem — APFS and HFS+
    /// reject non-UTF-8 basenames outright (EILSEQ), which is why the
    /// production code needs the validating decode in the first place — so
    /// the DECODE is injected rather than the bytes. The loop under test is
    /// the real one, including the exact guard ordering at issue, and the
    /// injection is keyed to the sentinel's POSITION rather than to a name,
    /// so the test does not depend on `readdir` order.
    func testUndecodableSentinelStillRecordsTheBudgetItProved() throws {
        let wide = cachesRoot.appendingPathComponent("sentinel")
        try mkdir(wide)
        for index in 0..<6 {
            try writeFile(wide.appendingPathComponent("f\(index).bin"), bytes: 1)
        }
        let limit = 4
        var realEntriesSeen = 0
        // The (limit + 1)-th REAL entry — whichever one `readdir` puts
        // there — is the undecodable one. `.` and `..` stay decodable, as
        // they always are on a real volume.
        let sentinelUndecodable: (UnsafePointer<CChar>) -> String? = { pointer in
            guard let name = OrphanedCachesScanner
                .decodedBasename(fromCString: pointer) else { return nil }
            if name == "." || name == ".." { return name }
            realEntriesSeen += 1
            return realEntriesSeen > limit ? nil : name
        }

        let wideFD = try openDirectory(wide)
        defer { close(wideFD) }
        let bounded = OrphanedCachesScanner.boundedChildNames(
            inDirectory: wideFD, limit: limit, decode: sentinelUndecodable
        )

        guard case .read(let names, let causes) = bounded else {
            return XCTFail("expected a bounded read, got \(bounded)")
        }
        XCTAssertEqual(names.count, limit)
        XCTAssertEqual(
            causes, [.budgetExhausted, .undecodableName],
            "the extra readdir PROVED the directory is over budget — an "
                + "undecodable name on that same entry does not erase it"
        )

        // The user-visible half: renaming the entry leaves the folder just
        // as over-budget, so the closing must be the irreducible one.
        let guidance = OrphanedCachesScanner.remediationGuidance(for: causes)
        XCTAssertTrue(guidance.contains("will not clear this"), guidance)
        XCTAssertTrue(guidance.contains("explicit per-item confirmation"),
                      guidance)
        XCTAssertFalse(guidance.hasSuffix("Clear that, then re-scan."), guidance)
    }

    /// The other direction, so the fix cannot become over-recording: an
    /// undecodable entry met BEFORE the budget is spent proves nothing
    /// about capacity. The read stops there, so the entries behind it were
    /// never counted — claiming budget exhaustion would be inventing a
    /// cause, which is the same sin in reverse.
    func testUndecodableEntryBeforeTheBudgetClaimsOnlyItself() throws {
        let wide = cachesRoot.appendingPathComponent("early-undecodable")
        try mkdir(wide)
        for index in 0..<6 {
            try writeFile(wide.appendingPathComponent("f\(index).bin"), bytes: 1)
        }
        var realEntriesSeen = 0
        let firstUndecodable: (UnsafePointer<CChar>) -> String? = { pointer in
            guard let name = OrphanedCachesScanner
                .decodedBasename(fromCString: pointer) else { return nil }
            if name == "." || name == ".." { return name }
            realEntriesSeen += 1
            return realEntriesSeen == 1 ? nil : name
        }

        let wideFD = try openDirectory(wide)
        defer { close(wideFD) }
        let bounded = OrphanedCachesScanner.boundedChildNames(
            inDirectory: wideFD, limit: 4, decode: firstUndecodable
        )

        XCTAssertEqual(bounded, .read([], truncatedBy: [.undecodableName]),
                       "the directory really does hold more than 4 entries, "
                           + "but this read never established that")
    }

    /// And the plumbing above it: obstructions established in DIFFERENT
    /// layers of one walk — the bounded read and the per-child kind probe —
    /// must union rather than overwrite. `sub` truncates on budget while
    /// both entries it did read fail their kind probe, so a single-slot
    /// hand-off would drop one of them.
    func testWalkUnionsObstructionsFromEveryLayer() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Layered")
        let sub = entry.appendingPathComponent("sub")
        try mkdir(sub)
        let provider = ErrnoInjectingProvider()
        for index in 0..<4 {
            let file = sub.appendingPathComponent("f\(index).bin")
            try writeFile(file, bytes: 1)
            provider.failures[file.standardizedFileURL.path] = EIO
        }

        // Budget 3: reading the root spends 1 on `sub`, leaving 2 for a
        // directory holding 4.
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: provider, entryLimit: 3
        )

        XCTAssertEqual(probe.obstructions,
                       [.budgetExhausted, .transientFailure])
    }

    /// A SPENT BUDGET IS NOT A CAUSE UNTIL SOMETHING BEYOND IT IS PROVEN
    /// (PR #458 review r9, thread `PRRT_kwDORmg6_86ZlKD0`).
    ///
    /// This test used to assert the opposite — that `a` is never opened once
    /// the budget is spent, and that the verdict is therefore
    /// `.budgetExhausted`. That reading confused the ATTENTION the budget
    /// bounds with the FACT the walk is missing: `a` was already paid for
    /// when the root's read discovered it, and its children are what the
    /// budget cannot afford — of which the zero-capacity descent admits
    /// exactly none (`testTheExactBudgetReadAdmitsNoNames` pins that, and it
    /// is what the original "the read came before the guard" regression
    /// really cost). What the refusal threw away was the only outstanding
    /// question, and answering it wrongly by default manufactured the sole
    /// IRREDUCIBLE class for trees that had proven nothing of the sort.
    ///
    /// Here the answer genuinely cannot be obtained: `a` is chmod-000, so
    /// the descent's `openat` fails `EACCES`. The verdict must name THAT —
    /// a grant lets the next scan get further, whereas the budget claim
    /// steered the user to per-item confirmation over a permission bit, and
    /// no budget increase could ever have read this directory.
    func testAnUnreadableExactBudgetDirectoryBlamesTheDenialNotTheBudget()
        throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let entry = cachesRoot.appendingPathComponent("com.example.SpentBudget")
        let unreadable = entry.appendingPathComponent("a")
        try mkdir(unreadable.appendingPathComponent("child"))
        try chmod000(unreadable)
        defer { restorePerms(unreadable) }

        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(), entryLimit: 1
        )

        XCTAssertEqual(probe.obstructions, [.accessDenied],
                       "nothing beyond the budget was ever proven to exist; "
                           + "what actually stopped the walk was a permission")
        XCTAssertFalse(probe.complete)
        XCTAssertEqual(
            probe.obstructions.map(\.remedy), [.userActionThenRetry],
            "and the remedy offered is the one that can actually work"
        )
    }

    // MARK: - An exact-budget directory may PROVE exhaustion (PR #458
    //         review r9, thread PRRT_kwDORmg6_86ZlKD0)

    /// A tree of exactly `entryLimit` entries whose last one is an EMPTY
    /// directory is COMPLETE, and the old guard called it truncated.
    ///
    /// Nothing beyond the budget was ever proven to exist: the directory
    /// itself was discovered and PAID FOR, and one zero-capacity read reaches
    /// EOF and settles the question. Refusing to look manufactured a
    /// `.budgetExhausted` — the one irreducible class — for a tree that fits,
    /// which excluded it from automatic cleaning FOREVER on nothing but the
    /// kind of its last entry.
    func testExactBudgetEmptyDirectoryProvesTheWalkComplete() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.ExactFit")
        try mkdir(entry.appendingPathComponent("sub"))

        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(), entryLimit: 1
        )

        XCTAssertEqual(probe.obstructions, [],
                       "one entry, a budget of one, and nothing beyond it")
        XCTAssertTrue(probe.complete)

        // AND WITH THE WHOLE TAIL AT ZERO CAPACITY. Once the budget is
        // spent, EVERY remaining pending entry is descended at capacity
        // zero; each was already counted when it was discovered, so the
        // extra descents are bounded by the budget and the walk still
        // terminates with a proven verdict rather than a manufactured one.
        let wide = cachesRoot.appendingPathComponent("com.example.WideFit")
        for index in 0..<8 {
            try mkdir(wide.appendingPathComponent("d\(index)"))
        }
        let widely = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: wide, provider: FileSystemIdentityProvider(), entryLimit: 8
        )
        XCTAssertEqual(widely.obstructions, [])
        XCTAssertTrue(widely.complete)
    }

    /// The proof runs both ways: the same shape with ONE entry inside the
    /// exact-budget directory is still `.budgetExhausted`, because the
    /// zero-capacity read really did meet an entry the budget cannot afford.
    /// The guard is narrowed, not deleted.
    func testExactBudgetNonEmptyDirectoryStillReportsExhaustion() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.ExactOver")
        try mkdir(entry.appendingPathComponent("sub/child"))

        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(), entryLimit: 1
        )

        XCTAssertEqual(probe.obstructions, [.budgetExhausted])
        XCTAssertFalse(probe.complete)
    }

    /// THE ZERO-CAPACITY DESCENT SPENDS NOTHING, evidenced independently of
    /// any counter the walk keeps about itself: a `Documents` directory
    /// sitting inside the exact-budget directory must NOT appear in
    /// `matches`, and the verdict must still be the one that was PROVEN.
    ///
    /// WHICH LAYER THIS PINS, MEASURED RATHER THAN ASSERTED. Two guards
    /// stand between a spent budget and a matched name: the read's own
    /// capacity check, and the walk's per-name `visited < entryLimit`.
    /// Breaking the read alone (`names.count <= limit`) leaves this test
    /// GREEN — the per-name guard drops the extra name before matching — and
    /// fails `testAZeroCapacityReadStillTellsEOFFromAnOverBudgetEntry`
    /// instead. Breaking BOTH lets `Documents` reach `matches` and fails
    /// THIS one. So the primitive test evidences layer one and this test
    /// evidences layer two; neither claim rides on the other.
    func testTheExactBudgetReadAdmitsNoNames() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.ExactLeak")
        try mkdir(entry.appendingPathComponent("sub/Documents"))

        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(), entryLimit: 1
        )

        XCTAssertEqual(probe.matches, [],
                       "a name was admitted past a spent budget")
        XCTAssertEqual(probe.obstructions, [.budgetExhausted])
    }

    /// The harm, end to end through the production classifier: an unchanged
    /// tree that fits its budget exactly must be automatically cleanable.
    /// Before the narrowing it carried a `.budgetExhausted` — the irreducible
    /// remedy — so it fell to review risk and stayed there on every future
    /// scan of the same bytes.
    func testExactBudgetLeakIsAutomaticallyCleanable() async throws {
        let entry = cachesRoot.appendingPathComponent(
            "com.apple.SwiftUI.Drag-EXACTFIT"
        )
        try mkdir(entry.appendingPathComponent("sub"))
        try writeFile(entry.appendingPathComponent("payload.bin"))

        // Budget 2 = `payload.bin` + `sub`, and `sub` is empty.
        let scanner = OrphanedCachesScanner(
            home: home, categories: [], probeEntryLimit: 2
        )
        let (items, _) = await scanItems(scanner)
        let leak = try XCTUnwrap(items[entry.lastPathComponent])

        XCTAssertEqual(leak.risk, .safe)
        XCTAssertTrue(
            leak.automaticCleanEligible,
            "a tree that fits its budget exactly was held off the automatic "
                + "path forever because its last entry was a directory"
        )
    }

    // MARK: - Obstructions are distinguished, not flattened (PR #458 review)

    /// Fails one child's kind probe with a chosen errno — the hermetic
    /// stand-in for a transient I/O error mid-walk.
    private final class ErrnoInjectingProvider: FileSystemIdentityProvider {
        var failures: [String: Int32] = [:]

        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            // Evaluated ONCE, here: the walk composes no path below its root
            // (hence the autoclosure), so a double that keys on the spelling
            // is the one that pays for composing it.
            let logical = logical()
            if let code = failures[logical.standardizedFileURL.path] {
                return .failed(errno: code)
            }
            return super.probeChild(
                inDirectory: descriptor, named: name, logical: logical
            )
        }
    }

    /// The walk must be ABLE to tell its causes apart: a bare `Bool` forced
    /// every message downstream to flatten a retryable race together with a
    /// bound that reproduces exactly, and both flattenings shipped a wrong
    /// remedy.
    func testProbeAttributesEachObstructionToItsOwnCause() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let plain = FileSystemIdentityProvider()

        // (a) Budget exhausted — deterministic on a static tree.
        let wide = cachesRoot.appendingPathComponent("com.example.Wide")
        try mkdir(wide)
        for index in 0..<4 {
            try writeFile(wide.appendingPathComponent("f\(index).bin"), bytes: 1)
        }
        XCTAssertEqual(
            OrphanedCachesScanner.boundedUserDataShapeWalk(
                at: wide, provider: plain, entryLimit: 2
            ).obstructions,
            [.budgetExhausted]
        )

        // (b) Access denied — clearable by a GRANT, not by a bare retry.
        let blocked = cachesRoot.appendingPathComponent("com.example.Blocked")
        let locked = blocked.appendingPathComponent("locked-sub")
        try mkdir(locked)
        try chmod000(locked)
        defer { restorePerms(locked) }
        XCTAssertEqual(
            OrphanedCachesScanner.preDeleteUserDataProbe(
                at: blocked, provider: plain
            ).obstructions,
            [.accessDenied]
        )

        // (c) A transient I/O failure — the class a re-scan really does
        // clear, and the one the previous message called permanent.
        let flaky = cachesRoot.appendingPathComponent("com.example.Flaky")
        let child = flaky.appendingPathComponent("sub")
        try mkdir(child)
        let provider = ErrnoInjectingProvider()
        provider.failures[child.standardizedFileURL.path] = EIO
        XCTAssertEqual(
            OrphanedCachesScanner.preDeleteUserDataProbe(
                at: flaky, provider: provider
            ).obstructions,
            [.transientFailure]
        )

        // (d) A vanished directory — the mid-walk RACE the review named —
        // is fail-closed but honestly retryable, never "deterministic".
        XCTAssertEqual(OrphanedCachesScanner.obstruction(forErrno: ENOENT),
                       .transientFailure)
        XCTAssertEqual(OrphanedCachesScanner.obstruction(forErrno: EPERM),
                       .accessDenied)
    }

    /// The guidance may claim a verdict is permanent ONLY when every cause
    /// behind it really is. Steering a user toward the riskier
    /// explicit-confirmation path over a transient failure is the harm.
    func testRemediationGuidanceOnlyClaimsPermanenceWhenNothingCanClearIt() {
        let permanent = OrphanedCachesScanner.remediationGuidance(
            for: [.budgetExhausted]
        )
        XCTAssertTrue(permanent.contains("will not clear this"), permanent)
        XCTAssertTrue(permanent.contains("explicit per-item confirmation"),
                      permanent)

        for clearable: UserDataProbeObstruction in
            [.mountBoundary, .accessDenied, .transientFailure,
             .undecodableName, .unaddressablePath] {
            let guidance = OrphanedCachesScanner.remediationGuidance(
                for: [clearable]
            )
            XCTAssertFalse(
                guidance.contains("will not clear"),
                "\(clearable) is clearable — the guidance must not call the "
                    + "result permanent: \(guidance)"
            )
            XCTAssertTrue(guidance.lowercased().contains("re-scan"),
                          "it must point at the retry that DOES help: \(guidance)")
        }

        // Cause-specific remedies, not one blanket instruction.
        XCTAssertTrue(
            OrphanedCachesScanner.remediationGuidance(for: [.mountBoundary])
                .contains("unmounting it"))
        XCTAssertTrue(
            OrphanedCachesScanner.remediationGuidance(for: [.accessDenied])
                .contains("granting access"))
        XCTAssertTrue(
            OrphanedCachesScanner.remediationGuidance(for: [.transientFailure])
                .contains("Re-scan and try again."))

        XCTAssertTrue(
            OrphanedCachesScanner.remediationGuidance(for: []).isEmpty,
            "a complete probe has nothing to remediate")
    }

    /// Causes are CONJUNCTIVE: the user has to clear every one of them, so
    /// the closing advice must be the MOST DEMANDING remedy in the set, not
    /// the easiest one present. Closing a budget-plus-transient set with
    /// "Re-scan and try again" sends the user around a loop that can never
    /// succeed — the transient error clears, the over-budget folder does
    /// not, and the delete-time probe refuses again with no remedy ever
    /// offered. That is the stranding shape this branch exists to remove.
    func testMixedGuidanceKeepsTheMostDemandingRemedy() {
        let mixed = OrphanedCachesScanner.remediationGuidance(
            for: [.transientFailure, .budgetExhausted]
        )
        // Both causes are still described…
        XCTAssertTrue(mixed.contains("inspection budget allows"), mixed)
        XCTAssertTrue(mixed.contains("temporary error"), mixed)
        // …but the closing belongs to the one a retry cannot fix.
        XCTAssertFalse(
            mixed.hasSuffix("Re-scan and try again."),
            "the over-budget folder still refuses after the retry: \(mixed)"
        )
        XCTAssertTrue(mixed.contains("will not clear this"), mixed)
        XCTAssertTrue(mixed.contains("explicit per-item confirmation"), mixed)

        // Same rule one rung down: a user action outranks a bare retry.
        let actionable = OrphanedCachesScanner.remediationGuidance(
            for: [.transientFailure, .accessDenied]
        )
        XCTAssertFalse(actionable.hasSuffix("Re-scan and try again."), actionable)
        XCTAssertTrue(actionable.contains("then re-scan"), actionable)
        XCTAssertFalse(actionable.contains("will not clear"), actionable)

        // And an irreducible cause outranks a user action too.
        let both = OrphanedCachesScanner.remediationGuidance(
            for: [.accessDenied, .budgetExhausted]
        )
        XCTAssertTrue(both.contains("will not clear this"), both)
        XCTAssertTrue(both.contains("granting access"),
                      "the clearable cause is still described: \(both)")

        // Order-independent and duplicate-proof.
        XCTAssertEqual(
            mixed,
            OrphanedCachesScanner.remediationGuidance(
                for: [.budgetExhausted, .transientFailure, .budgetExhausted]
            ),
            "guidance is the declaration order whatever the input order, and "
                + "a repeated cause is stated once"
        )
    }

    // MARK: - errno routing (PR #458 review r2)

    /// The errno router must decide EVERY class on the same test the
    /// guidance turns on — can a retry, unaided, change this? — instead of
    /// letting one benign case (the mid-walk race) justify a catch-all
    /// default that absorbs structural failures too.
    func testErrnoRoutingSeparatesPermanentFromTransientFailures() throws {
        // Grantable.
        for code in [EACCES, EPERM] {
            XCTAssertEqual(OrphanedCachesScanner.obstruction(forErrno: code),
                           .accessDenied, "errno \(code)")
        }
        // STRUCTURAL — a retry on an unchanged tree reproduces these
        // exactly, so they must never be reported as temporary.
        for code in [ENAMETOOLONG, ELOOP] {
            XCTAssertEqual(OrphanedCachesScanner.obstruction(forErrno: code),
                           .unaddressablePath, "errno \(code)")
        }
        // Genuinely retryable: the mid-walk race, I/O, resource shortage,
        // and the network-volume family.
        for code in [ENOENT, ENOTDIR, EIO, EINTR, EAGAIN, EMFILE, ENFILE,
                     ENOMEM, ESTALE, ETIMEDOUT, ENOTCONN, EBUSY] {
            XCTAssertEqual(OrphanedCachesScanner.obstruction(forErrno: code),
                           .transientFailure, "errno \(code)")
        }
        // An errno the router cannot reason about claims NEITHER — it is
        // not obviously retryable, and asserting permanence we cannot prove
        // would steer the user to the riskier path on a guess.
        for code in [EINVAL, EBADF, EOVERFLOW, EFAULT, 0] {
            XCTAssertEqual(OrphanedCachesScanner.obstruction(forErrno: code),
                           .unclassifiedFailure, "errno \(code)")
        }
        let unknown = OrphanedCachesScanner.remediationGuidance(
            for: [.unclassifiedFailure]
        )
        XCTAssertFalse(unknown.contains("will not clear"), unknown)
        XCTAssertFalse(unknown.hasSuffix("Re-scan and try again."), unknown)
    }

    /// Builds a directory chain whose ABSOLUTE path exceeds `PATH_MAX`, the
    /// only way one can exist: `mkdirat` against a directory descriptor, so
    /// each individual name stays legal while the absolute path does not.
    /// Real trees reach this the same way (deep relative creation), and
    /// retiring the depth cap is what let the probe walk far enough to meet
    /// one. Returns the descriptor chain so it can be torn down the same
    /// way — `FileManager.removeItem` cannot address it either.
    private func makeOverlongChain(
        under root: URL, segment: String, levels: Int
    ) throws -> [Int32] {
        var fds = [open(root.path, O_RDONLY | O_DIRECTORY)]
        guard try XCTUnwrapElement(fds, 0) >= 0 else {
            throw XCTSkip("cannot open fixture root: \(errno)")
        }
        for _ in 0..<levels {
            guard mkdirat(fds.last!, segment, 0o755) == 0 else {
                throw XCTSkip("mkdirat failed: \(errno)")
            }
            let next = openat(fds.last!, segment, O_RDONLY | O_DIRECTORY)
            guard next >= 0 else { throw XCTSkip("openat failed: \(errno)") }
            fds.append(next)
        }
        return fds
    }

    private func teardownOverlongChain(_ fds: [Int32], segment: String) {
        for index in stride(from: fds.count - 2, through: 0, by: -1) {
            unlinkat(fds[index], segment, AT_REMOVEDIR)
        }
        for fd in fds { close(fd) }
    }

    /// A path beyond `PATH_MAX` now COMPLETES instead of stranding (PR #458
    /// review, ancestor swap). The walk spells no path below its root, so
    /// `ENAMETOOLONG` cannot arise there at all — measured: a 500-deep tree
    /// reads fine descriptor-relative while `open` on its 14,628-byte
    /// absolute path returns errno 63.
    ///
    /// This retires a whole stranding class rather than reclassifying it.
    /// The entry used to probe permanently unprovable, which downstream is
    /// permanent removal from Quick Clean and smart-clean — over a tree
    /// nothing actually obstructed. And the user data at the bottom of it,
    /// which the old walk never saw, is now FOUND.
    func testOverlongPathNowCompletesInsteadOfStranding() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Overlong")
        try mkdir(entry)
        // 7 × 200 characters clears PATH_MAX (1024) from any temp root.
        let segment = String(repeating: "n", count: 200)
        let fds = try makeOverlongChain(under: entry, segment: segment, levels: 7)
        guard mkdirat(fds.last!, "Documents", 0o755) == 0 else {
            throw XCTSkip("mkdirat failed: \(errno)")
        }
        defer {
            unlinkat(fds.last!, "Documents", AT_REMOVEDIR)
            teardownOverlongChain(fds, segment: segment)
        }

        // The platform fact this test exists on top of: that same tree is
        // unaddressable BY PATH.
        let overlong = entry.appendingPathComponent(
            Array(repeating: segment, count: 7).joined(separator: "/")
        )
        let byPath = open(overlong.path, O_RDONLY | O_DIRECTORY)
        XCTAssertEqual(byPath, -1, "fixture is not actually past PATH_MAX")
        XCTAssertEqual(errno, ENAMETOOLONG)
        if byPath >= 0 { close(byPath) }

        var probe = UserDataProbeResult.complete()
        assertNoDescriptorLeak {
            probe = OrphanedCachesScanner.preDeleteUserDataProbe(
                at: entry, provider: FileSystemIdentityProvider()
            )
        }

        XCTAssertTrue(probe.complete,
                      "nothing obstructed this walk: \(probe.obstructions)")
        XCTAssertEqual(probe.matches, ["documents-directory"],
                       "user data below the old PATH_MAX wall must be found")

        // The taxonomy entry survives for the ROOT open, and still never
        // promises a retry it cannot honour.
        let guidance = OrphanedCachesScanner.remediationGuidance(
            for: [.unaddressablePath]
        )
        XCTAssertFalse(
            guidance.hasSuffix("Re-scan and try again."),
            "an unchanged tree reproduces this error exactly — promising a "
                + "retry is the same wrong remedy the review removed: \(guidance)"
        )
    }

    /// Fail-closed is untouched: a GENUINELY obstructed probe — a branch
    /// the walk cannot read — still refuses at delete time, and the refusal
    /// no longer prescribes a re-scan it knows cannot help.
    func testObstructedDeleteTimeProbeStillRefusesWithHonestGuidance() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-BLOCKED")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let runtime = try makeRuntime([makeScanner()])
        let (items, snapshot) = await scanSession(runtime)
        let leak = try XCTUnwrap(items.first)
        XCTAssertTrue(leak.automaticCleanEligible,
                      "the fixture entry scans as a clean known leak")

        // The entry is recreated with an unreadable branch between scan and
        // clean — the walk cannot prove what is inside it.
        try fm.removeItem(at: entry)
        let locked = entry.appendingPathComponent("locked-sub")
        try mkdir(locked)
        let victim = try writeFile(locked.appendingPathComponent("data.bin"))
        try chmod000(locked)
        defer { restorePerms(locked) }

        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [leak], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty, "nothing deleted")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("couldn't fully inspect"), message)
        XCTAssertFalse(
            message.contains("re-scan required"),
            "a bare retry does not clear a permission obstruction, so "
                + "prescribing one alone is misleading: \(message)"
        )
        // The guidance names THIS cause and its actual remedy — a grant —
        // rather than a blanket claim about the class (PR #458 review).
        XCTAssertTrue(message.contains("granting access"), message)
        XCTAssertFalse(
            message.contains("will not clear"),
            "an unreadable branch is clearable by granting access — calling "
                + "the verdict permanent pushes the user to the riskier "
                + "explicit-confirmation path for nothing: \(message)"
        )
        restorePerms(locked)
        XCTAssertTrue(fm.fileExists(atPath: victim.path),
                      "the uninspectable content is byte-untouched")
        try assertCleanupLogContains(tag: "content-drift")
    }

    func testUninstalledToolStaleFallbackSurfacesThroughProtocolScan() async throws {
        // The fn-3 epic case end-to-end (PR #456 review P2): tool
        // uninstalled, its stale cache dir still on disk — the category
        // scan skips the probed discovery entry entirely, so the sweep
        // must list it, classified (review-tier visibility, never a
        // deletion widening: auto-eligibility still requires a clean known
        // leak).
        let category = CacheCategory(
            name: "Homebrew Cache", slug: "homebrew_cache",
            description: "test", icon: "mug.fill",
            discovery: [.probed(
                command: "brew --cache",
                requiresTool: "brew",
                fallbacks: ["Library/Caches/Homebrew"]
            )],
            riskLevel: .safe, rebuildNote: "", defaultSelected: true
        )
        let stale = cachesRoot.appendingPathComponent("Homebrew")
        try mkdir(stale)
        try writeFile(stale.appendingPathComponent("bottle.tar.gz"))

        let swept = makeScanner(
            categories: [category], toolAvailability: { _ in false }
        )
        let (byName, outcome) = await scanItems(swept)
        try assertValidates(outcome, scanner: swept)

        let item = try XCTUnwrap(
            byName["Homebrew"],
            "the stale cache of an uninstalled tool is visible in the sweep"
        )
        XCTAssertEqual(item.risk, .review,
                       "surfaced through classification — never auto-safe")
        XCTAssertFalse(item.defaultSelected)
        XCTAssertFalse(item.automaticCleanEligible)

        // Tool present: excluded from the sweep exactly as before (the
        // category scan owns it). Probe seam injected — the test must
        // never spawn a real `brew`.
        let excluded = makeScanner(
            categories: [category], toolAvailability: { _ in true },
            probeResolver: { _ in nil }
        )
        let (byNamePresent, _) = await scanItems(excluded)
        XCTAssertNil(byNamePresent["Homebrew"])
    }

    func testProbedCustomRootNotDoubleListedThroughProtocolScan() async throws {
        // The PR #456 round-3 case end-to-end: the tool is present and its
        // probe resolves to an in-scope path that is NOT a declared
        // fallback. The category scan scans exactly that path, so a sweep
        // item for the same tree would be a DOUBLE listing — the same bytes
        // counted twice and a confirmed clean selecting both rows
        // operating on the target twice.
        let category = CacheCategory(
            name: "Homebrew Cache", slug: "homebrew_cache",
            description: "test", icon: "mug.fill",
            discovery: [.probed(
                command: "brew --cache",
                requiresTool: "brew",
                fallbacks: ["Library/Caches/Homebrew"]
            )],
            riskLevel: .safe, rebuildNote: "", defaultSelected: true
        )
        let custom = cachesRoot.appendingPathComponent("CustomBrew")
        try mkdir(custom)
        try writeFile(custom.appendingPathComponent("bottle.tar.gz"))
        let customPath = custom.path

        let scanner = makeScanner(
            categories: [category],
            toolAvailability: { _ in true },
            probeResolver: { _ in customPath }
        )
        let (byName, outcome) = await scanItems(scanner)
        try assertValidates(outcome, scanner: scanner)

        XCTAssertNil(byName["CustomBrew"],
                     "the probe-resolved tree belongs to the category scan "
                     + "— no second sweep row over the same bytes")
    }

    // MARK: - R5/R9: GUI selection policy + session gates

    /// A runtime whose sweep fixture carries every tier: only the clean
    /// known leak may ever ride a bulk path.
    private func makeAllTiersFixture() throws -> SpaceScannerRuntime {
        let leak = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-CLEAN")
        try mkdir(leak)
        try writeFile(leak.appendingPathComponent("payload.bin"), bytes: 8192)

        let orphan = cachesRoot.appendingPathComponent("com.example.orphan")
        try mkdir(orphan)
        try writeFile(orphan.appendingPathComponent("cache.bin"))

        let big = cachesRoot.appendingPathComponent("big-unclassified")
        try mkdir(big)
        try writeFile(big.appendingPathComponent("blob.bin"), bytes: 64 * 4096)

        let userData = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-UD")
        try mkdir(userData.appendingPathComponent("Documents"))
        try writeFile(userData.appendingPathComponent("payload.bin"))

        let scanner = makeScanner(installedAppStatus: { bundleID in
            bundleID == "com.example.orphan" ? .notInstalled : .unknown
        })
        return try makeRuntime([scanner])
    }

    @MainActor
    func testSelectAllSafePicksOnlyCleanKnownLeaks() async throws {
        let runtime = try makeAllTiersFixture()
        let viewModel = CacheoutViewModel(runtime: runtime)
        await viewModel.scan(trigger: .userInitiated)

        let items = viewModel.items(forScanner: "orphaned_caches")
        XCTAssertEqual(items.count, 4, "\(items.map(\.displayName))")
        let leakKey = try XCTUnwrap(
            items.first { $0.displayName == "com.apple.SwiftUI.Drag-CLEAN" }
        ).key

        // Policy (a): the clean leak (and ONLY it) is initially selected.
        XCTAssertEqual(viewModel.selectedItemKeys, [leakKey],
                       "defaultSelected enrolls exactly the clean known leak")

        // Policy (b): Quick Clean / select-all-safe never picks up orphan,
        // stale, unclassified, or cautioned rows.
        viewModel.deselectAll()
        viewModel.selectAllSafe()
        XCTAssertEqual(viewModel.selectedItemKeys, [leakKey],
                       "the bulk path selects nothing but clean known leaks")
    }

    func testSweepItemsAbsentFromSmartCleanSurfaces() async throws {
        // smart-clean is frozen category-only: even with the sweep scanner
        // REGISTERED and a safe eligible leak on disk, no sweep row may
        // appear in any smart-clean surface (plan, dry-run) — the cheap
        // guard that also catches fn-2 drift on the freeze.
        let leak = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-SC")
        try mkdir(leak)
        try writeFile(leak.appendingPathComponent("payload.bin"), bytes: 8192)

        let runtime = try makeRuntime([makeScanner()])
        let deps = CLIHandler.CLIRuntimeDependencies(
            runtime: runtime, categorySlugs: []
        )

        let dryRun = await CLIHandler.smartCleanCLIOutcome(
            targetGB: 1, dryRun: true, confirmed: false, euid: 501, deps: deps
        )
        guard case .success(let payload) = dryRun else {
            return XCTFail("dry-run smart-clean succeeds: \(dryRun)")
        }
        let cleaned = payload["cleaned"] as? [[String: Any]] ?? []
        XCTAssertTrue(
            cleaned.allSatisfy { ($0["scanner_id"] as? String) != "orphaned_caches" },
            "sweep items are entirely absent from smart-clean output: \(cleaned)"
        )
        XCTAssertTrue(cleaned.isEmpty,
                      "no categories registered — nothing eligible at all")
        XCTAssertTrue(fm.fileExists(atPath: leak.path))
    }

    @MainActor
    func testCleanWhileScanInFlightIsBlocked() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-GATE")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let gate = ScanHoldGate()
        let runtime = try makeRuntime([
            makeScanner(),
            GatedFixtureScanner(
                id: "slow_fixture",
                trustedContainerRoots: [base.appendingPathComponent("slow")],
                gate: gate
            ),
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)
        viewModel.moveToTrash = false

        let scanTask = Task { await viewModel.scan(trigger: .userInitiated) }
        try await waitUntil("sweep outcome published") {
            !viewModel.items(forScanner: "orphaned_caches").isEmpty
        }
        XCTAssertTrue(viewModel.isAnyScanInProgress)

        // The GUI gate: cleaning while a progressive scan is in flight is
        // a no-op — no pairing of items with an unadopted snapshot.
        await viewModel.clean()
        XCTAssertNil(viewModel.lastReport, "clean() must not run mid-scan")
        XCTAssertTrue(fm.fileExists(atPath: entry.path))

        await gate.open()
        await scanTask.value
        XCTAssertFalse(viewModel.isAnyScanInProgress)

        // After completion the adopted session pairs items and snapshot —
        // the same selection cleans.
        await viewModel.clean()
        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertFalse(fm.fileExists(atPath: entry.path))
    }

    @MainActor
    func testFreshnessGateCancelledSessionLeavesItemsNonCleanable() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-FRESH")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"))

        let gate = ScanHoldGate()
        let runtime = try makeRuntime([
            makeScanner(),
            GatedFixtureScanner(
                id: "slow_fixture",
                trustedContainerRoots: [base.appendingPathComponent("slow")],
                gate: gate
            ),
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)
        viewModel.moveToTrash = false

        // The sweep delivers; the slow scanner never does; the consumer is
        // cancelled — the session is never adopted.
        let scanTask = Task { await viewModel.scan(trigger: .userInitiated) }
        try await waitUntil("sweep outcome published") {
            !viewModel.items(forScanner: "orphaned_caches").isEmpty
        }
        scanTask.cancel()
        await gate.open()
        await scanTask.value

        // The delivered items are VISIBLE but non-cleanable: they belong to
        // a session whose snapshot was never adopted (fail-closed pairing).
        let items = viewModel.items(forScanner: "orphaned_caches")
        XCTAssertFalse(items.isEmpty, "delivered outcomes stay displayed")
        let key = try XCTUnwrap(items.first).key
        XCTAssertTrue(viewModel.selectedItemKeys.contains(key),
                      "policy (a) auto-selected the clean leak on first "
                      + "emission — selection is display state")
        XCTAssertTrue(viewModel.hasSelection)
        XCTAssertFalse(viewModel.hasCleanableSelection,
                       "an unadopted session's items never reach a "
                       + "destructive path")
        XCTAssertTrue(viewModel.selectedItems.isEmpty)

        // A COMPLETED session restores cleanability.
        await viewModel.scan(trigger: .userInitiated)
        XCTAssertTrue(viewModel.hasCleanableSelection,
                      "cleanability returns when the scanner succeeds in a "
                      + "completed session")
        await viewModel.clean()
        XCTAssertFalse(fm.fileExists(atPath: entry.path))
    }

    @MainActor
    func testSubsetScanRevokesProvenanceOfUnscannedScannersUntilTheySucceed() async throws {
        // The R9 subset arm: a subset session adopts its snapshot, and a
        // scanner OUTSIDE the subset keeps its prior provenance — its
        // retained rows stay visible but are excluded from selectedItems,
        // Quick Clean staging, and clean() dispatch until the scanner
        // succeeds in a later session.
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-SUBSET")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"), bytes: 8192)

        // A second per-item fixture scanner over its own real container.
        let otherContainer = base.appendingPathComponent("other")
        let otherTarget = otherContainer.appendingPathComponent("junk")
        try mkdir(otherTarget)
        try writeFile(otherTarget.appendingPathComponent("f.bin"))
        let provider = FileSystemIdentityProvider()
        let otherResolved = provider.canonicalize(otherTarget)
        let otherItem = ReclaimableItem(
            id: ReclaimableItem.stableID(
                scannerID: "other_fixture", canonicalPath: otherResolved.path
            ),
            scannerID: "other_fixture", displayName: "junk",
            exactBytes: 4096, estimatedUpToBytes: 0, logicalBytes: nil,
            itemCount: 1, url: otherResolved,
            declaredDisplayPath: otherTarget.path,
            rootRecords: [RootScanRecord(
                requestedURL: otherTarget, resolvedURL: otherResolved,
                status: .measured
            )],
            state: .measured, scanError: nil, risk: .review,
            evidence: "fixture", rebuildNote: nil, action: .removeItem,
            admission: .containerItem(
                originContainer: otherContainer, requestedTargetURL: otherTarget
            ),
            defaultSelected: false, automaticCleanEligible: false, isStale: nil
        )
        let runtime = try makeRuntime([
            makeScanner(),
            GatedFixtureScanner(
                id: "other_fixture", trustedContainerRoots: [otherContainer],
                gate: nil,
                provide: { ScanOutcome(items: [otherItem], errors: []) }
            ),
        ])
        let viewModel = CacheoutViewModel(runtime: runtime)
        viewModel.moveToTrash = false

        // Full scan: both scanners fresh; the clean leak auto-selects
        // (policy (a)); the fixture item is selected explicitly.
        await viewModel.scan(trigger: .userInitiated)
        let leakKey = try XCTUnwrap(
            viewModel.items(forScanner: "orphaned_caches").first
        ).key
        XCTAssertTrue(viewModel.selectedItemKeys.contains(leakKey))
        viewModel.toggleSelection(for: otherItem.key)
        XCTAssertEqual(Set(viewModel.selectedItems.map(\.key)),
                       [leakKey, otherItem.key],
                       "both scanners cleanable after the full scan")

        // SUBSET scan excluding the sweep: its retained rows stay VISIBLE
        // (items + checkmark) but its provenance is revoked — the newer
        // session's snapshot never vouched for them.
        await viewModel.scan(
            trigger: .userInitiated, scannerIDs: ["other_fixture"]
        )
        XCTAssertFalse(
            viewModel.items(forScanner: "orphaned_caches").isEmpty,
            "retained rows stay displayed after the subset scan"
        )
        XCTAssertTrue(viewModel.selectedItemKeys.contains(leakKey),
                      "the retained selection survives (display state)")
        XCTAssertEqual(viewModel.selectedItems.map(\.key), [otherItem.key],
                       "the unscanned scanner is excluded from clean()'s input")
        XCTAssertEqual(viewModel.automaticCleanableSize, 0,
                       "Quick Clean's gate must not count the revoked safe leak")
        viewModel.deselectAll()
        viewModel.selectAllSafe()
        XCTAssertTrue(viewModel.selectedItemKeys.isEmpty,
                      "the bulk path refuses to stage the revoked leak")

        // clean() dispatches ONLY the subset-fresh scanner's item; the
        // revoked leak's tree is untouched.
        viewModel.toggleSelection(for: leakKey)
        viewModel.toggleSelection(for: otherItem.key)
        await viewModel.clean()
        let report = try XCTUnwrap(viewModel.lastReport)
        XCTAssertEqual(report.entries.map(\.itemID), [otherItem.id],
                       "only the subset-fresh item reaches the cleaner")
        XCTAssertTrue(
            report.errors.allSatisfy { $0.key != leakKey },
            "the revoked item never reaches dispatch — not even as a refusal"
        )
        XCTAssertFalse(fm.fileExists(atPath: otherTarget.path))
        XCTAssertTrue(fm.fileExists(atPath: entry.path),
                      "the unscanned scanner's target is untouched")

        // clean()'s trailing FULL rescan restores the sweep's provenance:
        // cleanability returns once the scanner succeeds in a completed
        // session, and the retained selection cleans normally.
        XCTAssertTrue(viewModel.selectedItems.map(\.key).contains(leakKey),
                      "cleanability returns after the scanner succeeds")
        viewModel.toggleSelection(for: otherItem.key)  // deselect the ghost
        await viewModel.clean()
        XCTAssertFalse(fm.fileExists(atPath: entry.path),
                       "the restored item cleans end-to-end")
    }

    @MainActor
    func testFreshnessGateMalformedRetentionIsVisibleButNonCleanable() async throws {
        // A scanner that emits a VALID outcome, then a malformed one
        // (foreign-owned item), then valid again.
        let target = base.appendingPathComponent("mal/entry-1")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try writeFile(target.appendingPathComponent("f.bin"))
        let container = base.appendingPathComponent("mal")
        let provider = FileSystemIdentityProvider()
        let resolved = provider.canonicalize(target)
        let valid = ReclaimableItem(
            id: ReclaimableItem.stableID(
                scannerID: "mal", canonicalPath: resolved.path
            ),
            scannerID: "mal", displayName: "entry-1",
            exactBytes: 4096, estimatedUpToBytes: 0, logicalBytes: nil,
            itemCount: 1, url: resolved, declaredDisplayPath: target.path,
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: resolved, status: .measured
            )],
            state: .measured, scanError: nil, risk: .review,
            evidence: "fixture", rebuildNote: nil, action: .removeItem,
            admission: .containerItem(
                originContainer: container, requestedTargetURL: target
            ),
            defaultSelected: false, automaticCleanEligible: false, isStale: nil
        )
        let foreign = ReclaimableItem(
            id: "foreign", scannerID: "someone_else", displayName: "forged",
            exactBytes: 0, estimatedUpToBytes: 0, logicalBytes: nil,
            itemCount: 0, url: nil, declaredDisplayPath: "x",
            rootRecords: [], state: .missing, scanError: nil, risk: .review,
            evidence: "", rebuildNote: nil, action: .removeItem,
            admission: .containerItem(
                originContainer: container, requestedTargetURL: target
            ),
            defaultSelected: false, automaticCleanEligible: false, isStale: nil
        )
        let sequence = OutcomeSequenceBox([
            ScanOutcome(items: [valid], errors: []),
            ScanOutcome(items: [foreign], errors: []),
            ScanOutcome(items: [valid], errors: []),
        ])
        let runtime = try makeRuntime([GatedFixtureScanner(
            id: "mal", trustedContainerRoots: [container], gate: nil,
            provide: { await sequence.next() }
        )])
        let viewModel = CacheoutViewModel(runtime: runtime)

        await viewModel.scan(trigger: .userInitiated)
        viewModel.toggleSelection(for: valid.key)
        XCTAssertTrue(viewModel.hasCleanableSelection)

        // The malformed rescan retains the rows for DISPLAY but revokes
        // their session provenance — non-cleanable with the newer session's
        // snapshot.
        await viewModel.scan(trigger: .userInitiated)
        XCTAssertEqual(viewModel.items(forScanner: "mal").map(\.id),
                       [valid.id], "retained rows stay visible")
        XCTAssertFalse(viewModel.hasCleanableSelection,
                       "retained rows never pair with the newer snapshot")

        // A valid outcome in a completed session restores cleanability.
        await viewModel.scan(trigger: .userInitiated)
        XCTAssertTrue(viewModel.hasCleanableSelection)
    }

    // MARK: - R6: CLI registration, addressing, --confirm gate

    func testCLIScanEnvelopeCarriesSweepRowsAndAddressingWorks() async throws {
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-CLI")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"), bytes: 8192)

        let runtime = try makeRuntime([makeScanner()])
        let deps = CLIHandler.CLIRuntimeDependencies(
            runtime: runtime, categorySlugs: []
        )

        // Slug appears in scan output as scanner_items rows.
        let envelope = await CLIHandler.scanEnvelope(deps: deps)
        let rows = try XCTUnwrap(envelope["scanner_items"] as? [[String: Any]])
        let sweepRow = try XCTUnwrap(rows.first {
            ($0["scanner_id"] as? String) == "orphaned_caches"
        })
        let itemID = try XCTUnwrap(sweepRow["item_id"] as? String)
        XCTAssertEqual(itemID.count, 64, "the frozen full-hash stable id")
        XCTAssertEqual(sweepRow["action"] as? String, "remove_item")
        XCTAssertEqual(sweepRow["risk_level"] as? String, "safe")

        // Addressable as orphaned_caches:<item-id>, cleanable ONLY with
        // --confirm (fn-1.5's gate).
        let unconfirmed = await CLIHandler.cleanCLIOutcome(
            targets: ["orphaned_caches:\(itemID)"],
            dryRun: false, confirmed: false, euid: 501, deps: deps
        )
        guard case .failure(let code, _, let details) = unconfirmed else {
            return XCTFail("unconfirmed clean must refuse")
        }
        XCTAssertEqual(code, "CONFIRMATION_REQUIRED")
        XCTAssertNotNil(details?["plan"])
        XCTAssertTrue(fm.fileExists(atPath: entry.path),
                      "the refusal deleted nothing")

        // Confirmed: the entry directory itself is deleted.
        let confirmed = await CLIHandler.cleanCLIOutcome(
            targets: ["orphaned_caches:\(itemID)"],
            dryRun: false, confirmed: true, euid: 501, deps: deps
        )
        guard case .success(let payload) = confirmed else {
            return XCTFail("confirmed clean succeeds: \(confirmed)")
        }
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?["success"] as? Bool, true)
        XCTAssertEqual(results.first?["scanner_id"] as? String, "orphaned_caches")
        XCTAssertFalse(fm.fileExists(atPath: entry.path))
        XCTAssertTrue(fm.fileExists(atPath: cachesRoot.path))
    }

    // MARK: - R6: registration-only integration (grep gate)

    func testSweepSlugAppearsNowhereInProductionSourcesButItsOwnFile() throws {
        // SCANNER-SPECIFIC integration is registration-only: the slug may
        // appear in the scanner's own file (definition) and NOWHERE else
        // under Sources/Cacheout — no ViewModel/Cleaner/Views/CLI
        // special-casing. (The shared container-hardening in PathGuard/
        // CacheCleaner/runtime is slug-free infrastructure by construction.)
        let testFile = URL(fileURLWithPath: #filePath)
        let sourcesRoot = testFile
            .deletingLastPathComponent()  // CacheoutTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/Cacheout")
        let enumerator = try XCTUnwrap(fm.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: nil
        ))
        var scanned = 0
        var offenders: [String] = []
        while let file = enumerator.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            scanned += 1
            let contents = try String(contentsOf: file, encoding: .utf8)
            if contents.contains("orphaned_caches"),
               file.lastPathComponent != "OrphanedCachesScanner.swift" {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the gate actually scanned the tree")
        XCTAssertEqual(offenders, [],
                       "the sweep slug leaked into production files beyond "
                       + "its own definition: \(offenders)")
    }

    // MARK: - Test-local fixtures

    /// Minimal polling helper for mid-scan windows.
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 10,
        _ message: String,
        predicate: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("timed out waiting for: \(message)")
                struct TimeoutError: Error {}
                throw TimeoutError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Fixture scanner types (file-local)

/// The REAL sweep scanner behind a gate: same id, same declared roots,
/// same outcomes — the walk just waits for the test's signal, pinning the
/// capture-then-swap-then-walk ordering deterministically.
private struct DelegatingGatedSweepScanner: SpaceScanner {
    let inner: OrphanedCachesScanner
    let gate: ScanHoldGate
    var id: String { inner.id }
    var displayName: String { inner.displayName }
    var trustedContainerRoots: [URL] { inner.trustedContainerRoots }

    func scan(context: ScanContext) async -> ScanOutcome {
        await gate.wait()
        return await inner.scan(context: context)
    }
}

/// A fixture scanner that optionally blocks on a gate before returning; the
/// default outcome is empty.
private struct GatedFixtureScanner: SpaceScanner {
    let id: String
    let trustedContainerRoots: [URL]
    let gate: ScanHoldGate?
    var provide: @Sendable () async -> ScanOutcome = {
        ScanOutcome(items: [], errors: [])
    }
    var displayName: String { id }

    func scan(context: ScanContext) async -> ScanOutcome {
        if let gate { await gate.wait() }
        return await provide()
    }
}

/// A hold-open gate for pinning mid-scan windows.
///
/// BOUNDED (PR #460 codex r11, D2) — see `BoundedRendezvous`: a park with no
/// deadline strands the whole runner when the signal it waits for stops
/// arriving, which is precisely what a production regression does.
private actor ScanHoldGate {
    private let gate = BoundedRendezvous()

    func open() { gate.open() }

    @discardableResult
    func wait(
        _ what: String = "a mid-scan hold gate",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        await gate.park(what, file: file, line: line)
    }
}

/// Sequential outcomes across scans (last one repeats).
private actor OutcomeSequenceBox {
    private var outcomes: [ScanOutcome]
    init(_ outcomes: [ScanOutcome]) { self.outcomes = outcomes }
    func next() -> ScanOutcome {
        // FIXTURE-CONTROLLED (see the note on the twin in
        // CacheoutViewModelTests): the literal list is the test's own. The
        // subscript is gone anyway — the statement-position fence forbids the
        // shape (PR #460 codex r6, D4); the `??` arm is unreachable.
        precondition(!outcomes.isEmpty)
        return outcomes.count > 1
            ? outcomes.removeFirst()
            : (outcomes.first ?? ScanOutcome(items: [], errors: []))
    }
}

/// Thread-safe URL recorder for the trash seam (`@MainActor` handler writes,
/// test reads after completion).
private final class TrashURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(url)
    }
}
