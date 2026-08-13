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
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> OrphanedCachesScanner {
        OrphanedCachesScanner(
            home: home,
            categories: categories,
            provider: provider,
            thresholds: thresholds,
            installedAppStatus: installedAppStatus,
            now: now
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
                XCTAssertTrue(error.message.contains(args[0]),
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
                try FileManager.default.moveItem(
                    at: url,
                    to: trashDir.appendingPathComponent(url.lastPathComponent)
                )
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
private actor ScanHoldGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Sequential outcomes across scans (last one repeats).
private actor OutcomeSequenceBox {
    private var outcomes: [ScanOutcome]
    init(_ outcomes: [ScanOutcome]) { self.outcomes = outcomes }
    func next() -> ScanOutcome {
        outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
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
