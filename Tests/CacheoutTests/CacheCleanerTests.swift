import XCTest
@testable import Cacheout

/// Round-trip tests for `CacheCleaner` against tmp directories.
///
/// The original six cases lock in the pre-guard semantics (parent survives,
/// large fan-outs complete, per-item error isolation, unselected skipped).
/// fn-1.3 adds the safety + accounting coverage: PathGuard enforcement at all
/// three deletion primitives, scan-state refusal (R18), cleanCommands root
/// admission (R17), honest measured freed bytes with split components
/// (R1/R16), symlink-child semantics (R4), per-child isolation (R10),
/// disposal-mode headlines (R11), cross-device item refusal (R15), and the
/// claim-based two-phase hardlink ordering matrix (R8).
///
/// No test deletes or trashes anything outside its fixture root: trash goes
/// through the injectable seam, and guard-refusal fixtures use an injected
/// fixture home.
final class CacheCleanerTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String = #function) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheCleanerTests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func writeFile(_ url: URL, bytes: Int = 16) throws {
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    private func makeCategory(
        at urls: [URL], name: String = "test-cache",
        cleanCommands: [[String]]? = nil
    ) -> CacheCategory {
        CacheCategory(
            name: name,
            slug: name,
            description: "test",
            icon: "trash",
            discovery: urls.map { .absolutePath($0.path) },
            riskLevel: .safe,
            rebuildNote: "",
            defaultSelected: true,
            cleanCommands: cleanCommands
        )
    }

    private func makeCategory(at url: URL, name: String = "test-cache") -> CacheCategory {
        makeCategory(at: [url], name: name)
    }

    private func makeScanResult(category: CacheCategory, size: Int64 = 1024, items: Int = 1) -> ScanResult {
        var r = ScanResult(category: category, sizeBytes: size, itemCount: items, exists: true)
        r.isSelected = true
        return r
    }

    /// Full-state ScanResult, force-selected (the cleaner must judge state,
    /// not selection).
    private func makeStateResult(
        category: CacheCategory, state: ScanState,
        exact: Int64 = 0, estimated: Int64 = 0, items: Int = 0,
        scanError: ScanError? = nil
    ) -> ScanResult {
        var r = ScanResult(
            category: category, state: state, exactBytes: exact,
            estimatedUpToBytes: estimated, itemCount: items, scanError: scanError
        )
        r.isSelected = true
        return r
    }

    /// Independent fixture math: measure a deletion target the same way the
    /// cleaner must, with a sizer the cleaner does not own.
    private func measured(_ url: URL) -> SizeReport {
        DirectorySizer().measure(at: url, mode: .deletionTarget)
    }

    /// Sum of independently-measured exact bytes for every child of `root`.
    private func measuredExactOfChildren(of root: URL) throws -> Int64 {
        try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .reduce(0) { $0 + measured($1).exactAllocatedBytes }
    }

    /// A scan-session container snapshot over the given roots — what the
    /// runtime's validated-scan entry point captures before launching
    /// scanners (fn-3.4, R9). Delete-time `.removeItem` admission requires
    /// the producing session's snapshot; a snapshot-less cleaner refuses.
    private func sessionSnapshot(
        of roots: [URL],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> ContainerSnapshot {
        ContainerSnapshot.capture(roots: roots, provider: provider)
    }

    /// The ScanResult→item mapping the deleted `clean(results:nodeModules:)`
    /// compatibility adapter performed, kept HERE (fn-4.7): the category
    /// coverage below predates the item currency and still belongs on the ONE
    /// clean path, so its fixtures are mapped exactly as the adapter mapped
    /// them — `CategoryScanner.item(from:rootRecords:)` over records
    /// synthesized from the category's own delete-time resolution when the
    /// fixture carries no scan-time capture, and the adapter's `isSelected`
    /// filter (selection never rides a `ReclaimableItem`).
    private func categoryItems(
        _ results: [ScanResult],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> [ReclaimableItem] {
        results.filter(\.isSelected).map { result in
            let records: [RootScanRecord]
            if result.rootRecords.isEmpty, result.state != .missing {
                records = result.category.resolvedPaths(home: home).map { url in
                    RootScanRecord(
                        requestedURL: url,
                        resolvedURL: provider.canonicalize(url),
                        status: .measured
                    )
                }
            } else {
                records = result.rootRecords
            }
            return CategoryScanner.item(from: result, rootRecords: records)
        }
    }

    /// A per-item `.removeItem` fixture — the currency the ONE clean path
    /// consumes. The UNRESOLVED discovered target is BOTH the root record's
    /// `requestedURL` and the `.containerItem` descriptor's
    /// `requestedTargetURL` (leaf never resolved, fn-1 doctrine). Replaces the
    /// `NodeModulesItem` fixtures the deleted adapter took: the cleaner's
    /// item-mode behavior was never node_modules-specific, and the unified
    /// descriptor makes origin-container provenance non-optional.
    private func removableItem(
        at target: URL,
        originContainer: URL,
        displayName: String = "proj",
        scannerID: String = "fixture_scanner",
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> ReclaimableItem {
        let resolved = provider.canonicalize(target)
        return ReclaimableItem(
            id: ReclaimableItem.stableID(
                scannerID: scannerID, canonicalPath: resolved.path
            ),
            scannerID: scannerID,
            displayName: displayName,
            exactBytes: 16,
            estimatedUpToBytes: 0,
            logicalBytes: nil,
            itemCount: 0,
            url: resolved,
            declaredDisplayPath: target.path,
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: resolved, status: .measured
            )],
            state: .measured,
            scanError: nil,
            risk: .review,
            evidence: "",
            rebuildNote: nil,
            action: .removeItem,
            admission: .containerItem(
                originContainer: originContainer, requestedTargetURL: target
            ),
            defaultSelected: false,
            automaticCleanEligible: false,
            isStale: nil
        )
    }

    /// Two directory entries, one inode (8192 bytes allocated).
    private func makeHardlinkPair(
        in dir: URL, name: String = "hl"
    ) throws -> (a: URL, b: URL) {
        let a = dir.appendingPathComponent("\(name)-a.bin")
        let b = dir.appendingPathComponent("\(name)-b.bin")
        try Data(repeating: 0xCD, count: 8192).write(to: a)
        try FileManager.default.linkItem(at: a, to: b)
        return (a, b)
    }

    private func logContents(home: URL) -> String {
        (try? String(
            contentsOf: home.appendingPathComponent(".cacheout/cleanup.log"),
            encoding: .utf8
        )) ?? ""
    }

    /// Thread-safe URL recorder for the trash seam.
    private final class TrashRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URL] = []
        var urls: [URL] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
        func record(_ url: URL) {
            lock.lock(); recorded.append(url); lock.unlock()
        }
    }

    /// Seam that "trashes" by moving into a fixture-local dir — nothing ever
    /// reaches the real Trash. Throws for basenames in `failingNames`.
    private func makeTrashSeam(
        into trashDir: URL, recorder: TrashRecorder,
        failingNames: Set<String> = []
    ) -> CacheCleaner.TrashHandler {
        return { url in
            if failingNames.contains(url.lastPathComponent) {
                throw NSError(domain: "TrashSeam", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "simulated trash failure for \(url.lastPathComponent)"
                ])
            }
            recorder.record(url)
            try FileManager.default.moveItem(
                at: url,
                to: trashDir.appendingPathComponent(
                    "\(UUID().uuidString)-\(url.lastPathComponent)"
                )
            )
        }
    }

    /// Provider that reports a fake device id for every path at/under a
    /// registered canonical prefix — hermetic stand-in for a mounted volume
    /// (same pattern as PathGuardTests).
    private final class DeviceInjectingProvider: FileSystemIdentityProvider {
        var overrides: [(canonicalPrefix: String, device: UInt64)] = []
        /// Canonical paths reported as mount points while keeping their real
        /// device — the same-st_dev firmlink-mount stand-in.
        var mountPointPaths: Set<String> = []
        /// Paths whose probe reports `.absent` even though they exist —
        /// hermetic stand-in for a child vanishing between enumeration and
        /// the cleaner's already-gone probe (fn-2.3 ENOENT-asymmetry tests).
        var absentPaths: Set<String> = []

        override func identity(of url: URL) -> Identity? {
            let path = url.path
            for (prefix, device) in overrides {
                if path == prefix || path.hasPrefix(prefix + "/") {
                    let inode = super.identity(of: url)?.inode
                        ?? UInt64(bitPattern: Int64(path.hashValue))
                    return Identity(device: device, inode: inode)
                }
            }
            return super.identity(of: url)
        }

        override func isMountPoint(_ url: URL) -> Bool {
            if mountPointPaths.contains(url.path)
                || mountPointPaths.contains(canonicalize(url).path) {
                return true
            }
            return super.isMountPoint(url)
        }

        override func probeKind(of url: URL) -> KindProbe {
            if absentPaths.contains(url.path)
                || absentPaths.contains(canonicalize(url).path) {
                return .absent
            }
            return super.probeKind(of: url)
        }
    }

    /// Minimal protocol conformer for the runtime-derived-admission test
    /// (R4 groundwork): registration is the ONLY thing that puts its
    /// container roots into the cleaner's admission set.
    private struct FixtureSpaceScanner: SpaceScanner {
        let id: String
        let displayName = "Fixture Scanner"
        let trustedContainerRoots: [URL]
        func scan(context: ScanContext) async -> ScanOutcome {
            ScanOutcome(items: [], errors: [])
        }
    }

    // MARK: - Unified-entry fixtures (fn-2.3)

    private func makeRecord(
        _ url: URL, status: RootScanStatus = .measured
    ) -> RootScanRecord {
        RootScanRecord(
            requestedURL: url,
            resolvedURL: FileSystemIdentityProvider().canonicalize(url),
            status: status
        )
    }

    private func makeItem(
        id: String = "fixture-item",
        scannerID: String = "fixture_scanner",
        displayName: String = "fixture",
        exact: Int64 = 1024,
        estimated: Int64 = 0,
        records: [RootScanRecord] = [],
        state: ScanState = .measured,
        scanError: ScanError? = nil,
        action: ReclaimAction,
        admission: AdmissionDescriptor,
        autoEligible: Bool = true,
        requiresRevalidation: Bool = false
    ) -> ReclaimableItem {
        ReclaimableItem(
            id: id, scannerID: scannerID, displayName: displayName,
            exactBytes: exact, estimatedUpToBytes: estimated,
            logicalBytes: nil, itemCount: 0,
            url: nil, declaredDisplayPath: "",
            rootRecords: records, state: state, scanError: scanError,
            risk: .safe, evidence: "", rebuildNote: nil,
            action: action, admission: admission,
            defaultSelected: true, automaticCleanEligible: autoEligible,
            isStale: nil,
            requiresPreDeleteRevalidation: requiresRevalidation
        )
    }

    /// Aggregate item (`.removeContents`, or `.commands` when the category
    /// declares `cleanCommands`) — id is the category slug, scanner is the
    /// frozen aggregate id, exactly the production mapping.
    private func makeCategoryItem(
        category: CacheCategory,
        records: [RootScanRecord],
        state: ScanState = .measured,
        exact: Int64 = 1024,
        estimated: Int64 = 0,
        scanError: ScanError? = nil
    ) -> ReclaimableItem {
        let action: ReclaimAction
        if let commands = category.cleanCommands {
            action = .commands(commands)
        } else {
            action = .removeContents
        }
        return makeItem(
            id: category.slug, scannerID: "categories",
            displayName: category.name,
            exact: exact, estimated: estimated, records: records,
            state: state, scanError: scanError,
            action: action, admission: .category(category)
        )
    }

    /// Per-item scanner fixture (`.removeItem`) with the frozen
    /// container-item descriptor.
    private func makeRemoveItem(
        id: String = "item-1",
        scannerID: String = "fixture_scanner",
        displayName: String = "fixture-item",
        origin: URL, target: URL,
        state: ScanState = .measured,
        exact: Int64 = 1024,
        autoEligible: Bool = true,
        requiresRevalidation: Bool = false
    ) -> ReclaimableItem {
        makeItem(
            id: id, scannerID: scannerID, displayName: displayName,
            exact: exact, records: [makeRecord(target)], state: state,
            action: .removeItem,
            admission: .containerItem(
                originContainer: origin, requestedTargetURL: target
            ),
            autoEligible: autoEligible,
            requiresRevalidation: requiresRevalidation
        )
    }

    // MARK: - removeContents semantics

    func testCleanRemovesAllTopLevelEntriesAndPreservesParent() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        for i in 0..<10 {
            try writeFile(tmp.appendingPathComponent("file-\(i).bin"))
        }
        let nestedDir = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try writeFile(nestedDir.appendingPathComponent("inner.bin"))

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: makeCategory(at: tmp))]),
            moveToTrash: false
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path),
                      "parent directory must survive — recreated by tools/apps that depend on it")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertEqual(remaining, [], "all top-level entries should be gone")
    }

    func testCleanHandlesManyFilesUnderParallelWindow() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let count = 200 // exceeds the 8-wide window many times over
        for i in 0..<count {
            try writeFile(tmp.appendingPathComponent("f-\(i)"))
        }

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: makeCategory(at: tmp))]),
            moveToTrash: false
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertEqual(remaining.count, 0, "expected all \(count) files deleted")
    }

    func testCleanOnEmptyDirectoryIsNoop() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // ScanResult marks empty directories as not selected by default. Force-select
        // to exercise the cleaner's empty-iteration path explicitly.
        var result = makeScanResult(category: makeCategory(at: tmp), size: 0, items: 0)
        result.isSelected = true

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(items: categoryItems([result]), moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
    }

    // MARK: - Injected-home path resolution (hermetic seam)

    func testStaticPathCategoryResolvesUnderInjectedHomeForCleaning() async throws {
        // The cleaner must resolve `.staticPath` roots against ITS injected
        // home — the same home its admission policy and PathGuard root at.
        // Resolving against the real account home would either find nothing
        // or refuse the real home's tree against a fixture-rooted policy.
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let cacheDir = home.appendingPathComponent("Library/Caches/fixture-static")
        try FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true
        )
        try writeFile(cacheDir.appendingPathComponent("stale.bin"))

        let category = CacheCategory(
            name: "static-under-home", slug: "static-under-home",
            description: "test", icon: "trash",
            discovery: [.staticPath("Library/Caches/fixture-static")],
            riskLevel: .safe, rebuildNote: "", defaultSelected: true
        )

        let cleaner = CacheCleaner(home: home, containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems(
                [makeScanResult(category: category)], home: home
            ),
            moveToTrash: false
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.path),
                      "category root survives — contents mode")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cacheDir.path), [],
            "children under the injected-home-resolved root must be deleted"
        )
    }

    // MARK: - Per-item parallel deletion

    func testPerItemParallelDeleteRemovesAll() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        var targets: [URL] = []
        var items: [ReclaimableItem] = []
        for i in 0..<12 {
            let target = root
                .appendingPathComponent("proj-\(i)")
                .appendingPathComponent("artifacts")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try writeFile(target.appendingPathComponent("pkg.json"))
            targets.append(target)
            items.append(removableItem(
                at: target, originContainer: root, displayName: "proj-\(i)"
            ))
        }

        let cleaner = CacheCleaner(
            containerRoots: [root], containerSnapshot: sessionSnapshot(of: [root])
        )
        let report = await cleaner.clean(items: items, moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.entries.count, items.count)
        for target in targets {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                           "expected \(target.path) removed")
        }
    }

    func testPerItemCleanIsolatesPerItemErrors() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Mix one missing path between two real ones — the item pipeline must
        // surface a single error and still clean the surviving items.
        let goodA = root.appendingPathComponent("a/artifacts")
        let goodB = root.appendingPathComponent("b/artifacts")
        try FileManager.default.createDirectory(at: goodA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: goodB, withIntermediateDirectories: true)
        try writeFile(goodA.appendingPathComponent("a.json"))
        try writeFile(goodB.appendingPathComponent("b.json"))

        let missing = root.appendingPathComponent("ghost/artifacts")

        let items = [
            removableItem(at: goodA, originContainer: root, displayName: "a"),
            removableItem(at: missing, originContainer: root, displayName: "ghost"),
            removableItem(at: goodB, originContainer: root, displayName: "b"),
        ]

        let cleaner = CacheCleaner(
            containerRoots: [root], containerSnapshot: sessionSnapshot(of: [root])
        )
        let report = await cleaner.clean(items: items, moveToTrash: false)

        XCTAssertEqual(report.errors.count, 1, "exactly one missing item should surface as error")
        XCTAssertEqual(report.errors.first?.displayName, "ghost")
        XCTAssertEqual(report.entries.count, 2, "the two real items should still be cleaned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: goodA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: goodB.path))
    }

    // MARK: - Honest freed bytes (R1/R16)

    func testCategoryFreedEqualsMeasuredDeletedBytesAcrossTwoPaths() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let p1 = base.appendingPathComponent("cache-one")
        let p2 = base.appendingPathComponent("cache-two")
        try FileManager.default.createDirectory(at: p1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: p2, withIntermediateDirectories: true)

        // p1: a subtree and a top-level regular file (regular-file dispatch
        // must measure nonzero, R1); p2: plain files.
        let sub = p1.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile(sub.appendingPathComponent("inner.bin"), bytes: 4096)
        try writeFile(p1.appendingPathComponent("top.bin"), bytes: 8192)
        try writeFile(p2.appendingPathComponent("a.bin"), bytes: 4096)
        try writeFile(p2.appendingPathComponent("b.bin"), bytes: 4096)

        let topFileExact = measured(p1.appendingPathComponent("top.bin")).exactAllocatedBytes
        XCTAssertGreaterThan(topFileExact, 0, "a top-level regular file must measure nonzero")
        let expected = try measuredExactOfChildren(of: p1) + measuredExactOfChildren(of: p2)
        XCTAssertGreaterThan(expected, 0)

        let category = makeCategory(at: [p1, p2])
        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: category)]), moveToTrash: false
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.entries.count, 1, "one category = ONE entry")
        XCTAssertEqual(report.entries.first?.exactBytes, expected,
                       "freed must equal the sum of measured deleted bytes, counted once")
        XCTAssertEqual(report.entries.first?.estimatedUpToBytes, 0)
        XCTAssertEqual(report.totalFreedExact, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p2.path))
    }

    func testOnePathFailingReportsOnlySuccessfulBytes() async throws {
        try XCTSkipIf(geteuid() == 0, "permission-based failure requires non-root")
        let base = try makeTempDir()
        let p1 = base.appendingPathComponent("cache-good")
        let p2 = base.appendingPathComponent("cache-bad")
        try FileManager.default.createDirectory(at: p1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: p2, withIntermediateDirectories: true)
        try writeFile(p1.appendingPathComponent("a.bin"), bytes: 4096)
        try writeFile(p1.appendingPathComponent("b.bin"), bytes: 4096)

        // p2's only child refuses deletion: removing `locked` must unlink its
        // inner file, which needs write permission on `locked` itself.
        let locked = p2.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try writeFile(locked.appendingPathComponent("pinned.bin"), bytes: 4096)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: base)
        }

        let expected = try measuredExactOfChildren(of: p1)

        let category = makeCategory(at: [p1, p2])
        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: category)]), moveToTrash: false
        )

        XCTAssertEqual(report.errors.count, 1, "exactly one failed child: \(report.errors)")
        XCTAssertEqual(report.entries.count, 1, "partially-failed category still yields ONE entry")
        XCTAssertEqual(report.entries.first?.exactBytes, expected,
                       "freed must count ONLY the successful deletions")
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path),
                      "the undeletable child must survive")
    }

    // MARK: - Scan-state refusal (R18)

    func testDeniedScanResultRefusedEvenWhenForceSelected() async throws {
        let home = try makeTempDir("fixture-home")
        let cacheRoot = try makeTempDir("denied-root")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        try writeFile(cacheRoot.appendingPathComponent("survivor.bin"))

        let category = makeCategory(at: cacheRoot)
        let denied = makeStateResult(
            category: category, state: .denied,
            scanError: ScanError(kind: .tccDenied, message: "test TCC denial")
        )
        XCTAssertTrue(denied.isSelected, "force-selected — the cleaner must still refuse")

        let cleaner = CacheCleaner(home: home, containerRoots: [])
        let report = await cleaner.clean(items: categoryItems([denied]), moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1, "the refusal must SURFACE, not silently skip")
        XCTAssertEqual(report.errors.first?.displayName, category.name)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("survivor.bin").path),
            "nothing may be deleted for a .denied category"
        )
        XCTAssertTrue(logContents(home: home).contains("REFUSED [scan-denied]"),
                      "the refusal must be logged")
    }

    func testPartiallyDeniedExplicitSelectionProceedsWithMeasuredBytes() async throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        try writeFile(cacheRoot.appendingPathComponent("data.bin"), bytes: 8192)
        let expected = try measuredExactOfChildren(of: cacheRoot)

        let category = makeCategory(at: cacheRoot)
        // Pre-scan claimed more than is deletable (parts were denied) — the
        // report must carry measured deletions only, never the scan estimate.
        let partial = makeStateResult(
            category: category, state: .partiallyDenied,
            exact: expected + 999_999, items: 2,
            scanError: ScanError(kind: .permissionDenied, message: "partial denial")
        )

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(items: categoryItems([partial]), moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.exactBytes, expected,
                       "explicit .partiallyDenied cleans with measured bytes only")
    }

    // MARK: - Symlink child semantics (R4)

    func testOutboundSymlinkChildRemovedTargetUntouched() async throws {
        let cacheRoot = try makeTempDir("symlink-cache")
        let external = try makeTempDir("symlink-target")
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: external)
        }
        let precious = external.appendingPathComponent("precious.bin")
        try writeFile(precious, bytes: 8192)

        let link = cacheRoot.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        try writeFile(cacheRoot.appendingPathComponent("real.bin"), bytes: 4096)
        let expected = measured(cacheRoot.appendingPathComponent("real.bin")).exactAllocatedBytes

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: makeCategory(at: cacheRoot))]),
            moveToTrash: false
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                     "the link itself must be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path),
                      "the symlink TARGET must be untouched")
        XCTAssertEqual(report.entries.first?.exactBytes, expected,
                       "the symlink child contributes 0 bytes")
        XCTAssertEqual(report.entries.first?.estimatedUpToBytes, 0)
    }

    // MARK: - Per-item mode (R1/R15)

    func testPerItemModeDeletesTheTargetDirectoryItself() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("app")
        let target = projectDir.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try writeFile(target.appendingPathComponent("dep.js"), bytes: 4096)
        let expected = measured(target).exactAllocatedBytes

        let item = removableItem(
            at: target, originContainer: root, displayName: "app"
        )
        let cleaner = CacheCleaner(
            containerRoots: [root], containerSnapshot: sessionSnapshot(of: [root])
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "item mode deletes the target directory ITSELF")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.path),
                      "the project directory survives")
        XCTAssertEqual(report.entries.first?.exactBytes, expected,
                       "freed bytes are measured at delete time, never the "
                        + "item's scan-time components")
    }

    // MARK: - Guard refusals block all three primitives (R15/R17/R18)

    func testGuardRefusalBlocksPermanentCategoryDeletion() async throws {
        let home = try makeTempDir("guard-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let marker = home.appendingPathComponent("do-not-delete.bin")
        try writeFile(marker)

        // The category literally declares $HOME — the deny list must beat
        // the policy at delete time.
        let category = makeCategory(at: home, name: "hostile")
        let cleaner = CacheCleaner(home: home, containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: category)]), moveToTrash: false
        )

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "nothing under a refused root may be deleted")
        let log = logContents(home: home)
        XCTAssertTrue(log.contains("REFUSED [home-directory]"),
                      "refusal must be logged with its typed classification, got: \(log)")
    }

    func testGuardRefusalBlocksTrashCategoryDeletion() async throws {
        let home = try makeTempDir("guard-home-trash")
        defer { try? FileManager.default.removeItem(at: home) }
        let marker = home.appendingPathComponent("do-not-trash.bin")
        try writeFile(marker)
        let trashDir = try makeTempDir("fake-trash")
        defer { try? FileManager.default.removeItem(at: trashDir) }

        let recorder = TrashRecorder()
        let cleaner = CacheCleaner(
            home: home,
            containerRoots: [],
            trashHandler: makeTrashSeam(into: trashDir, recorder: recorder)
        )
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: makeCategory(at: home, name: "hostile"))]),
            moveToTrash: true
        )

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(recorder.urls.isEmpty, "the trash primitive must never be invoked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUnconfiguredContainerBlocksPerItemTarget() async throws {
        let configured = try makeTempDir("configured-container")
        let elsewhere = try makeTempDir("unconfigured-container")
        defer {
            try? FileManager.default.removeItem(at: configured)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let target = elsewhere.appendingPathComponent("proj/artifacts")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try writeFile(target.appendingPathComponent("x.js"))

        let item = removableItem(at: target, originContainer: elsewhere)
        let cleaner = CacheCleaner(
            containerRoots: [configured],
            containerSnapshot: sessionSnapshot(of: [configured])
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path),
                      "an item under an unconfigured container must not be deleted")
    }

    func testCrossDevicePerItemTargetRefused() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let mountedProject = root.appendingPathComponent("mounted-proj")
        let target = mountedProject.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try writeFile(target.appendingPathComponent("x.js"))

        let provider = DeviceInjectingProvider()
        // The foreign device covers the project subtree, so the item is not
        // itself a mount point — only on the wrong device (R15 item mode).
        provider.overrides = [
            (provider.canonicalize(mountedProject).path, 0xBEEF)
        ]

        let item = removableItem(
            at: target, originContainer: root, displayName: "mounted-proj",
            provider: provider
        )
        let cleaner = CacheCleaner(
            containerRoots: [root],
            containerSnapshot: sessionSnapshot(of: [root], provider: provider),
            provider: provider
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path),
                      "a cross-device item must not be deleted")
    }

    func testCategoryChildThatIsAMountBoundaryIsRefusedNotDeleted() async throws {
        // `validateContainedChild` is descendant-only by design, so the mount
        // rule for category children lands via the sizer's root-boundary
        // check: a direct child that IS a mount boundary must be refused, not
        // enumerated-and-deleted (R15 completion-review gap).
        let root = try makeTempDir("mount-child-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let mounted = root.appendingPathComponent("mounted-volume")
        let normal = root.appendingPathComponent("normal-cache")
        try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: normal, withIntermediateDirectories: true)
        try writeFile(mounted.appendingPathComponent("payload.bin"))
        try writeFile(normal.appendingPathComponent("cache.bin"))

        let provider = DeviceInjectingProvider()
        provider.overrides = [(provider.canonicalize(mounted).path, 0xBEEF)]

        let category = makeCategory(at: root, name: "mount-child")
        let cleaner = CacheCleaner(containerRoots: [], provider: provider)
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: category)]), moveToTrash: false
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: mounted.path),
                      "a mount-boundary child must not be deleted")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: mounted.appendingPathComponent("payload.bin").path
            ),
            "nothing beneath the boundary may be touched"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: normal.path),
                       "siblings are still cleaned (per-child isolation)")
        XCTAssertEqual(report.errors.count, 1)
    }

    func testNestedMountBoundaryInsideChildRefusesThatChildOnly() async throws {
        // Round-2 completion-review gap: the sizer records-and-skips an INNER
        // mount for sizing, but removeItem would recurse straight through it.
        // A boundary anywhere in the measured tree must refuse that child;
        // both nested-mount signals covered, sibling isolation preserved.
        let root = try makeTempDir("nested-mount-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host-cache")
        let sibling = root.appendingPathComponent("plain-cache")
        let innerForeign = host.appendingPathComponent("foreign-mount")
        let innerFirmlink = host.appendingPathComponent("firmlink-mount")
        for dir in [host, sibling, innerForeign, innerFirmlink] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
        try writeFile(host.appendingPathComponent("loose.bin"))
        try writeFile(innerForeign.appendingPathComponent("payload-a.bin"))
        try writeFile(innerFirmlink.appendingPathComponent("payload-b.bin"))
        try writeFile(sibling.appendingPathComponent("cache.bin"))

        let provider = DeviceInjectingProvider()
        provider.overrides = [(provider.canonicalize(innerForeign).path, 0xF00D)]
        provider.mountPointPaths = [provider.canonicalize(innerFirmlink).path]

        let category = makeCategory(at: root, name: "nested-mount")
        let cleaner = CacheCleaner(containerRoots: [], provider: provider)
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: category)]), moveToTrash: false
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: innerForeign.appendingPathComponent("payload-a.bin").path
            ),
            "foreign-device mounted payload must survive"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: innerFirmlink.appendingPathComponent("payload-b.bin").path
            ),
            "same-device mount-point payload must survive"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: host.path),
                      "the hosting child is refused wholesale, not partially deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path),
                       "the unrelated sibling is still cleaned")
        XCTAssertEqual(report.errors.count, 1)
    }

    func testNestedMountBoundaryInsidePerItemTargetRefused() async throws {
        // Item mode has the same shape: validateRemovableItem catches the
        // item ITSELF being a mount target, but not a mount nested beneath.
        let root = try makeTempDir("nested-mount-item")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("proj/artifacts")
        let inner = target.appendingPathComponent("inner-mount")
        try FileManager.default.createDirectory(
            at: inner, withIntermediateDirectories: true
        )
        try writeFile(target.appendingPathComponent("x.js"))
        try writeFile(inner.appendingPathComponent("payload.bin"))

        let provider = DeviceInjectingProvider()
        provider.mountPointPaths = [provider.canonicalize(inner).path]

        let item = removableItem(
            at: target, originContainer: root, provider: provider
        )
        let cleaner = CacheCleaner(
            containerRoots: [root],
            containerSnapshot: sessionSnapshot(of: [root], provider: provider),
            provider: provider
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path),
                      "an item with a nested mount must not be deleted")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: inner.appendingPathComponent("payload.bin").path
            )
        )
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
    }

    // MARK: - cleanCommands root admission (R17)

    func testInadmissibleCleanCommandsRootBlocksExecution() async throws {
        let home = try makeTempDir("cmd-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let marker = home.appendingPathComponent("command-ran.marker")

        // The command category's declared root is $HOME itself — refused, so
        // the argv must never execute.
        let category = makeCategory(
            at: [home], name: "cmd-hostile",
            cleanCommands: [["/usr/bin/touch", marker.path]]
        )
        let cleaner = CacheCleaner(home: home, containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: category)]), moveToTrash: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "commands must NOT execute when a root fails admission")
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(logContents(home: home).contains("REFUSED"),
                      "the refusal must be logged")
    }

    func testVanishedCleanCommandsRootRefusesExecution() async throws {
        let home = try makeTempDir("cmd-home-vanished")
        defer { try? FileManager.default.removeItem(at: home) }
        let marker = home.appendingPathComponent("command-ran.marker")

        // The category's only root does not exist at clean time — modeling a
        // directory that vanished between scan and confirmation. Delete-time
        // resolution is therefore empty, so the admission loop would pass
        // vacuously; the cleaner must refuse instead of running the argv.
        let vanished = home.appendingPathComponent("vanished-root")
        let category = makeCategory(
            at: [vanished], name: "cmd-vanished",
            cleanCommands: [["/usr/bin/touch", marker.path]]
        )
        // The scan result still claims measurable content (captured before
        // the root disappeared) and is selected.
        let cleaner = CacheCleaner(home: home, containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: category, size: 4096)]),
            moveToTrash: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "commands must NOT execute when no root resolves at delete time")
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(logContents(home: home).contains("REFUSED [no-root-records]"),
                      "the empty-resolution refusal must be logged")
    }

    func testAdmissibleCleanCommandsRootRunsAndReportsEstimatedBytes() async throws {
        let home = try makeTempDir("cmd-home-ok")
        let cmdRoot = try makeTempDir("cmd-root")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: cmdRoot)
        }
        let marker = cmdRoot.appendingPathComponent("command-ran.marker")

        let category = makeCategory(
            at: [cmdRoot], name: "cmd-ok",
            cleanCommands: [["/usr/bin/touch", marker.path]]
        )
        let cleaner = CacheCleaner(home: home, containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: category, size: 2048)]), moveToTrash: false
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "admissible command categories must run")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.exactBytes, 0,
                       "nothing measures what a command frees — exact is 0")
        XCTAssertEqual(report.entries.first?.estimatedUpToBytes, 2048,
                       "command categories report the pre-scan size as estimated")
    }

    func testCleanCommandObservesInjectedHome() async throws {
        let home = try makeTempDir("cmd-home-env")
        let cmdRoot = try makeTempDir("cmd-root-env")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: cmdRoot)
        }
        let capture = cmdRoot.appendingPathComponent("observed-home.txt")

        // The command itself consults $HOME — it must see the injected
        // fixture home, never the real account, or a hermetic run could
        // operate on the real user's data.
        let category = makeCategory(
            at: [cmdRoot], name: "cmd-env",
            cleanCommands: [
                ["/bin/sh", "-c", "printf %s \"$HOME\" > '\(capture.path)'"]
            ]
        )
        let cleaner = CacheCleaner(home: home, containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: category, size: 1024)]),
            moveToTrash: false
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        let observed = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertEqual(observed, home.path,
                       "clean commands must observe the injected home")
        XCTAssertNotEqual(
            observed, FileManager.default.homeDirectoryForCurrentUser.path,
            "clean commands must not leak the real account home"
        )
    }

    // MARK: - Per-child isolation (R10)

    func testOneUndeletableChildAmongNIsIsolated() async throws {
        try XCTSkipIf(geteuid() == 0, "permission-based failure requires non-root")
        let cacheRoot = try makeTempDir()
        for i in 0..<4 {
            try writeFile(cacheRoot.appendingPathComponent("ok-\(i).bin"), bytes: 4096)
        }
        let locked = cacheRoot.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try writeFile(locked.appendingPathComponent("pinned.bin"), bytes: 4096)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let expected = (0..<4).reduce(Int64(0)) {
            $0 + measured(cacheRoot.appendingPathComponent("ok-\($1).bin")).exactAllocatedBytes
        }

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: makeCategory(at: cacheRoot))]),
            moveToTrash: false
        )

        XCTAssertEqual(report.errors.count, 1, "exactly one error for the undeletable child")
        for i in 0..<4 {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("ok-\(i).bin").path),
                "sibling ok-\(i).bin must still be deleted"
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
        XCTAssertEqual(report.entries.first?.exactBytes, expected)
    }

    func testTrashFailureIsIsolatedPerChildAndNeverFallsThrough() async throws {
        let cacheRoot = try makeTempDir()
        let trashDir = try makeTempDir("fake-trash")
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: trashDir)
        }
        try writeFile(cacheRoot.appendingPathComponent("good-1.bin"), bytes: 4096)
        try writeFile(cacheRoot.appendingPathComponent("bad.bin"), bytes: 4096)
        try writeFile(cacheRoot.appendingPathComponent("good-2.bin"), bytes: 4096)
        let expected = measured(cacheRoot.appendingPathComponent("good-1.bin")).exactAllocatedBytes
            + measured(cacheRoot.appendingPathComponent("good-2.bin")).exactAllocatedBytes

        let recorder = TrashRecorder()
        let cleaner = CacheCleaner(
            containerRoots: [],
            trashHandler: makeTrashSeam(
                into: trashDir, recorder: recorder, failingNames: ["bad.bin"]
            )
        )
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: makeCategory(at: cacheRoot))]),
            moveToTrash: true
        )

        XCTAssertEqual(report.errors.count, 1, "the failed trash is one child error")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("bad.bin").path),
            "a trash failure must NEVER fall through to permanent deletion"
        )
        XCTAssertEqual(recorder.urls.count, 2, "the two good children still get trashed")
        XCTAssertEqual(report.entries.first?.exactBytes, expected)
        XCTAssertEqual(report.disposal, .trash)
        XCTAssertEqual(report.entries.first?.disposal, .trash,
                       "path-based categories honor the Trash mode per entry")
    }

    // MARK: - Hardlink ordering matrix (R8)

    func testHardlinksBothSucceedSequentialCountOnceAsEstimated() async throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let (a, _) = try makeHardlinkPair(in: cacheRoot)
        let canonical = measured(a).estimatedUpToBytes
        XCTAssertGreaterThan(canonical, 0)

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: makeCategory(at: cacheRoot))]),
            moveToTrash: false
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.estimatedUpToBytes, canonical,
                       "the shared inode transfers ONCE, as estimated")
        XCTAssertEqual(report.entries.first?.exactBytes, 0,
                       "hardlinked bytes never land in exact")
    }

    func testMatrixFailThenSucceedTransfersOnceEstimated() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = try makeHardlinkPair(in: dir)
        let registry = InodeAccountingRegistry()
        let sizer = DirectorySizer()

        // A measures and registers, then its deletion FAILS — no accept.
        let reportA = sizer.measure(at: a, mode: .deletionTarget)
        let canonical = reportA.claims.first?.canonicalByteSize ?? 0
        XCTAssertGreaterThan(canonical, 0)
        _ = await registry.registerObservations(reportA.claims)

        // B measures with the registry's known inodes, succeeds, accepts.
        let reportB = sizer.measure(
            at: b, mode: .deletionTarget,
            knownInodes: await registry.knownIdentities
        )
        let tokenB = await registry.registerObservations(reportB.claims)
        try FileManager.default.removeItem(at: b)
        let accepted = await registry.acceptSuccessful(tokenB)

        XCTAssertEqual(accepted.estimatedUpToBytes, canonical,
                       "the sibling transfers the failed child's registered bytes, once")
        XCTAssertEqual(accepted.exactBytes, 0)
    }

    func testMatrixSucceedThenFailAddsNothingAfterTransfer() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = try makeHardlinkPair(in: dir)
        let registry = InodeAccountingRegistry()
        let sizer = DirectorySizer()

        let reportA = sizer.measure(at: a, mode: .deletionTarget)
        let canonical = reportA.claims.first?.canonicalByteSize ?? 0
        let tokenA = await registry.registerObservations(reportA.claims)
        try FileManager.default.removeItem(at: a)
        let acceptedA = await registry.acceptSuccessful(tokenA)
        XCTAssertEqual(acceptedA.estimatedUpToBytes, canonical, "transferred once")

        // B registers and FAILS — accepts nothing; and a later successful
        // observer of the same inode transfers nothing more.
        let reportB = sizer.measure(
            at: b, mode: .deletionTarget,
            knownInodes: await registry.knownIdentities
        )
        let tokenB = await registry.registerObservations(reportB.claims)
        // (deletion failure — acceptSuccessful is never called for B)
        let lateAccept = await registry.acceptSuccessful(tokenB)
        // Even if B HAD succeeded, the inode is already transferred:
        XCTAssertEqual(lateAccept.exactBytes, 0)
        XCTAssertEqual(lateAccept.estimatedUpToBytes, 0,
                       "an already-transferred inode adds nothing")
    }

    func testMatrixConcurrentMeasureBothSucceedTransfersOnce() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = try makeHardlinkPair(in: dir)
        let registry = InodeAccountingRegistry()
        let sizer = DirectorySizer()

        // Concurrent measurement: both walks ran before EITHER registered,
        // so neither knows the other's inodes.
        let reportA = sizer.measure(at: a, mode: .deletionTarget)
        let reportB = sizer.measure(at: b, mode: .deletionTarget)
        let canonical = reportA.claims.first?.canonicalByteSize ?? 0
        XCTAssertGreaterThan(reportB.estimatedUpToBytes, 0,
                             "concurrent measure: B locally carries the bytes too")

        let tokenA = await registry.registerObservations(reportA.claims)
        let tokenB = await registry.registerObservations(reportB.claims)
        try FileManager.default.removeItem(at: a)
        try FileManager.default.removeItem(at: b)
        let acceptedA = await registry.acceptSuccessful(tokenA)
        let acceptedB = await registry.acceptSuccessful(tokenB)

        XCTAssertEqual(
            acceptedA.estimatedUpToBytes + acceptedB.estimatedUpToBytes, canonical,
            "both children succeed but the inode transfers exactly once"
        )
        XCTAssertEqual(acceptedA.exactBytes + acceptedB.exactBytes, 0)
    }

    func testMatrixDeleteThenObserveRegisteredClassificationWins() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = try makeHardlinkPair(in: dir)
        let registry = InodeAccountingRegistry()
        let sizer = DirectorySizer()

        let reportA = sizer.measure(at: a, mode: .deletionTarget)
        XCTAssertEqual(reportA.claims.first?.observedHardlinked, true)
        let canonical = reportA.claims.first?.canonicalByteSize ?? 0
        let tokenA = await registry.registerObservations(reportA.claims)
        try FileManager.default.removeItem(at: a)
        let acceptedA = await registry.acceptSuccessful(tokenA)
        XCTAssertEqual(acceptedA.estimatedUpToBytes, canonical)

        // B observes AFTER A's deletion: the survivor's st_nlink has decayed
        // to 1, so B's LOCAL claim says "not hardlinked"...
        let reportB = sizer.measure(
            at: b, mode: .deletionTarget,
            knownInodes: await registry.knownIdentities
        )
        XCTAssertEqual(reportB.claims.first?.observedHardlinked, false,
                       "the decayed link count is exactly why classification is sticky")
        XCTAssertEqual(reportB.exactAllocatedBytes + reportB.estimatedUpToBytes, 0,
                       "known inode contributes zero local bytes")

        // ...but the registry's sticky classification wins: nothing more
        // transfers, and nothing ever lands in exact.
        let tokenB = await registry.registerObservations(reportB.claims)
        try FileManager.default.removeItem(at: b)
        let acceptedB = await registry.acceptSuccessful(tokenB)
        XCTAssertEqual(acceptedB.exactBytes, 0)
        XCTAssertEqual(acceptedB.estimatedUpToBytes, 0)
    }

    func testMatrixLateMeasureFailThenSucceedTransfersRegisteredBytes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = try makeHardlinkPair(in: dir)
        let registry = InodeAccountingRegistry()
        let sizer = DirectorySizer()

        // A registers, then FAILS. B is measured ONLY AFTER that.
        let reportA = sizer.measure(at: a, mode: .deletionTarget)
        let canonical = reportA.claims.first?.canonicalByteSize ?? 0
        _ = await registry.registerObservations(reportA.claims)

        let reportB = sizer.measure(
            at: b, mode: .deletionTarget,
            knownInodes: await registry.knownIdentities
        )
        XCTAssertEqual(reportB.exactAllocatedBytes + reportB.estimatedUpToBytes, 0,
                       "B's local components exclude the known inode")
        XCTAssertEqual(reportB.claims.count, 1,
                       "…but B still claims it (acceptance transfers only claimed bytes)")

        let tokenB = await registry.registerObservations(reportB.claims)
        try FileManager.default.removeItem(at: b)
        let acceptedB = await registry.acceptSuccessful(tokenB)
        XCTAssertEqual(acceptedB.estimatedUpToBytes, canonical,
                       "B's accept transfers A's registered canonical bytes, estimated")
        XCTAssertEqual(acceptedB.exactBytes, 0)
    }

    func testMatrixUniqueFileBaselineTransfersFullExactBytes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unique = dir.appendingPathComponent("unique.bin")
        try Data(repeating: 0xEF, count: 8192).write(to: unique)
        let registry = InodeAccountingRegistry()
        let sizer = DirectorySizer()

        let report = sizer.measure(at: unique, mode: .deletionTarget)
        XCTAssertEqual(report.claims.count, 1,
                       "a newly-encountered st_nlink == 1 file MUST claim")
        XCTAssertEqual(report.claims.first?.observedHardlinked, false)
        let canonical = report.claims.first?.canonicalByteSize ?? 0
        XCTAssertGreaterThan(canonical, 0)

        let token = await registry.registerObservations(report.claims)
        try FileManager.default.removeItem(at: unique)
        let accepted = await registry.acceptSuccessful(token)

        XCTAssertEqual(accepted.exactBytes, canonical,
                       "the register → delete → accept round-trip transfers full canonical bytes as exact")
        XCTAssertEqual(accepted.estimatedUpToBytes, 0)
    }

    // MARK: - Split components + aggregates (R16)

    func testEntryComponentsAndAggregatesAcrossMixedCategories() async throws {
        let exactRoot = try makeTempDir("mixed-exact")
        let linkRoot = try makeTempDir("mixed-links")
        let cmdRoot = try makeTempDir("mixed-cmd")
        defer {
            try? FileManager.default.removeItem(at: exactRoot)
            try? FileManager.default.removeItem(at: linkRoot)
            try? FileManager.default.removeItem(at: cmdRoot)
        }
        try writeFile(exactRoot.appendingPathComponent("u.bin"), bytes: 8192)
        let expectedExact = try measuredExactOfChildren(of: exactRoot)
        let (a, _) = try makeHardlinkPair(in: linkRoot)
        let expectedEstimated = measured(a).estimatedUpToBytes

        let exactCat = makeCategory(at: exactRoot, name: "cat-exact")
        let linkCat = makeCategory(at: linkRoot, name: "cat-links")
        let cmdCat = makeCategory(
            at: [cmdRoot], name: "cat-cmd", cleanCommands: [["/usr/bin/true"]]
        )

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([
                makeScanResult(category: exactCat),
                makeScanResult(category: linkCat),
                makeScanResult(category: cmdCat, size: 2048),
            ]),
            moveToTrash: false
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        let byName = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.displayName, $0) })
        XCTAssertEqual(byName["cat-exact"]?.exactBytes, expectedExact)
        XCTAssertEqual(byName["cat-exact"]?.estimatedUpToBytes, 0)
        XCTAssertEqual(byName["cat-links"]?.exactBytes, 0)
        XCTAssertEqual(byName["cat-links"]?.estimatedUpToBytes, expectedEstimated)
        XCTAssertEqual(byName["cat-cmd"]?.exactBytes, 0)
        XCTAssertEqual(byName["cat-cmd"]?.estimatedUpToBytes, 2048)

        // Aggregates are pure sums of entry components.
        XCTAssertEqual(report.totalFreedExact, expectedExact)
        XCTAssertEqual(report.totalEstimatedUpTo, expectedEstimated + 2048)
        // Entry compatibility sums stay coherent with the split aggregates.
        XCTAssertEqual(
            report.entries.map(\.bytesFreed).reduce(0, +),
            report.totalFreedExact + report.totalEstimatedUpTo
        )
    }

    // MARK: - Disposal-mode headlines (R11)

    func testHeadlinesAreModeDrivenAndHonest() {
        let erasedEntry = CleanupReport.Entry(
            itemID: "c", scannerID: "categories", displayName: "c", exactBytes: 4096, estimatedUpToBytes: 0, disposal: .permanent
        )
        let trashedEntry = CleanupReport.Entry(
            itemID: "c", scannerID: "categories", displayName: "c", exactBytes: 4096, estimatedUpToBytes: 0, disposal: .trash
        )
        let permanent = CleanupReport(disposal: .permanent, entries: [erasedEntry], errors: [])
        XCTAssertTrue(permanent.headline.hasPrefix("Freed "))

        let trashed = CleanupReport(disposal: .trash, entries: [trashedEntry], errors: [])
        XCTAssertFalse(trashed.headline.contains("Freed"),
                       "a Trash run must never claim bytes were freed")
        XCTAssertTrue(trashed.headline.contains("Moved"))
        XCTAssertTrue(trashed.headline.contains("empty Trash to reclaim"))

        let allFailed = CleanupReport(
            disposal: .permanent, entries: [],
            errors: [CleanupReport.ItemError(
                key: ItemKey(scannerID: "categories", itemID: "c"),
                displayName: "c", message: "boom"
            )]
        )
        XCTAssertFalse(allFailed.headline.contains("Freed"),
                       "no success claim when everything failed")
        XCTAssertFalse(allFailed.headline.contains("Moved"))
    }

    // MARK: - Per-entry disposal honesty (P2)

    func testTrashRunWithOnlyCommandErasedEntryNeverClaimsTrash() {
        // A Trash-mode run whose only entry was command-erased: the argv put
        // nothing in the Trash, so the headline must not promise reclaim.
        let commandEntry = CleanupReport.Entry(
            itemID: "sim", scannerID: "categories", displayName: "sim", exactBytes: 0, estimatedUpToBytes: 2048, disposal: .permanent
        )
        let report = CleanupReport(disposal: .trash, entries: [commandEntry], errors: [])
        XCTAssertTrue(report.headline.hasPrefix("Freed "))
        XCTAssertFalse(report.headline.contains("Trash"),
                       "command-erased bytes must never be claimed recoverable from the Trash")
        XCTAssertEqual(report.rowAnnotation(for: commandEntry),
                       "erased permanently — not in Trash")
    }

    func testMixedDisposalHeadlineRendersBothPartsAndAnnotatesRows() {
        let trashedEntry = CleanupReport.Entry(
            itemID: "cache", scannerID: "categories", displayName: "cache", exactBytes: 4096, estimatedUpToBytes: 0, disposal: .trash
        )
        let commandEntry = CleanupReport.Entry(
            itemID: "sim", scannerID: "categories", displayName: "sim", exactBytes: 0, estimatedUpToBytes: 2048, disposal: .permanent
        )
        let report = CleanupReport(
            disposal: .trash, entries: [trashedEntry, commandEntry], errors: []
        )
        XCTAssertTrue(report.headline.contains("Freed"),
                      "the command-erased part renders as freed, not trashed")
        XCTAssertTrue(report.headline.contains("moved"))
        XCTAssertTrue(report.headline.contains("empty Trash to reclaim"))
        XCTAssertNil(report.rowAnnotation(for: trashedEntry),
                     "an entry matching the requested mode carries no marker")
        XCTAssertNotNil(report.rowAnnotation(for: commandEntry))

        // A fully-permanent run annotates nothing — every row did what the
        // mode said.
        let permanentRun = CleanupReport(
            disposal: .permanent, entries: [commandEntry], errors: []
        )
        XCTAssertNil(permanentRun.rowAnnotation(for: commandEntry))
    }

    func testCommandCategoryReportsPermanentDisposalInTrashRun() async throws {
        let cmdRoot = try makeTempDir("cmd-trash-run")
        defer { try? FileManager.default.removeItem(at: cmdRoot) }
        let category = makeCategory(
            at: [cmdRoot], name: "cat-cmd", cleanCommands: [["/usr/bin/true"]]
        )

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(
            items: categoryItems([makeScanResult(category: category, size: 2048)]),
            moveToTrash: true
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.disposal, .trash,
                       "the report keeps the REQUESTED mode")
        XCTAssertEqual(report.entries.first?.disposal, .permanent,
                       "a command-backed category erases permanently even in a Trash run (P2)")
        XCTAssertFalse(report.headline.contains("Trash"),
                       "the sheet must not claim command-erased bytes can be reclaimed by emptying the Trash")
    }

    // MARK: - Trash mode end-to-end via seam

    func testTrashModeTrashesPerItemTargetViaSeam() async throws {
        let root = try makeTempDir()
        let trashDir = try makeTempDir("fake-trash")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: trashDir)
        }
        let target = root.appendingPathComponent("proj/artifacts")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try writeFile(target.appendingPathComponent("dep.js"), bytes: 4096)
        let expected = measured(target).exactAllocatedBytes

        let recorder = TrashRecorder()
        let item = removableItem(at: target, originContainer: root)
        let cleaner = CacheCleaner(
            containerRoots: [root],
            containerSnapshot: sessionSnapshot(of: [root]),
            trashHandler: makeTrashSeam(into: trashDir, recorder: recorder)
        )
        let report = await cleaner.clean(items: [item], moveToTrash: true)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(recorder.urls, [target], "item mode trashes the directory itself")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(report.entries.first?.exactBytes, expected)
        XCTAssertEqual(report.disposal, .trash)
    }

    // MARK: - Unified entry: action dispatch (fn-2.3, R1)

    func testUnifiedEntryDispatchesAllThreeActions() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        // .removeContents fixture
        let contentsRoot = base.appendingPathComponent("contents-root")
        try FileManager.default.createDirectory(at: contentsRoot, withIntermediateDirectories: true)
        try writeFile(contentsRoot.appendingPathComponent("payload.bin"), bytes: 4096)
        let expectedContents = try measuredExactOfChildren(of: contentsRoot)

        // .removeItem fixture
        let container = base.appendingPathComponent("container")
        let target = container.appendingPathComponent("proj/node_modules")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try writeFile(target.appendingPathComponent("dep.js"), bytes: 4096)
        let expectedItem = measured(target).exactAllocatedBytes

        // .commands fixture
        let cmdRoot = base.appendingPathComponent("cmd-root")
        try FileManager.default.createDirectory(at: cmdRoot, withIntermediateDirectories: true)
        let marker = cmdRoot.appendingPathComponent("ran.marker")

        let contentsItem = makeCategoryItem(
            category: makeCategory(at: contentsRoot, name: "contents-cat"),
            records: [makeRecord(contentsRoot)]
        )
        let removeItem = makeRemoveItem(origin: container, target: target)
        let commandsItem = makeCategoryItem(
            category: makeCategory(
                at: [cmdRoot], name: "cmd-cat",
                cleanCommands: [["/usr/bin/touch", marker.path]]
            ),
            records: [makeRecord(cmdRoot)],
            exact: 2048
        )

        let cleaner = CacheCleaner(
            containerRoots: [container],
            containerSnapshot: sessionSnapshot(of: [container])
        )
        let report = await cleaner.clean(
            items: [contentsItem, removeItem, commandsItem], moveToTrash: false
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.entries.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: contentsRoot.path),
                      "contents mode preserves the parent")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: contentsRoot.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "item mode deletes the target itself")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path),
            "the project directory survives"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the admissible command ran")

        // Entries carry identity and components sourced from the item's
        // REQUIRED ownership fields — never looked up.
        let byID = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.itemID, $0) })
        XCTAssertEqual(byID["contents-cat"]?.scannerID, "categories")
        XCTAssertEqual(byID["contents-cat"]?.displayName, "contents-cat")
        XCTAssertEqual(byID["contents-cat"]?.exactBytes, expectedContents)
        XCTAssertEqual(byID["item-1"]?.scannerID, "fixture_scanner")
        XCTAssertEqual(byID["item-1"]?.displayName, "fixture-item")
        XCTAssertEqual(byID["item-1"]?.exactBytes, expectedItem)
        XCTAssertEqual(byID["cmd-cat"]?.exactBytes, 0,
                       "nothing measures what a command frees")
        XCTAssertEqual(byID["cmd-cat"]?.estimatedUpToBytes, 2048,
                       "command items report the pre-scan size as estimated")
    }

    func testZeroAllocatedMeasuredAggregateIsSkippedChildrenSurvive() async throws {
        let root = try makeTempDir("zero-alloc-aggregate")
        defer { try? FileManager.default.removeItem(at: root) }
        // Zero-allocation regular files: the scan measures itemCount > 0
        // with allocatedBytes == 0, so the aggregate is `.measured` — NOT
        // `.empty` — yet the CLI confirmation/dry-run plan reports "skip"
        // for it (the as-built `result.isEmpty` parity). The confirmed run
        // must not delete what its plan said it would skip.
        let emptyA = root.appendingPathComponent("zero-a.bin")
        let emptyB = root.appendingPathComponent("zero-b.bin")
        try Data().write(to: emptyA)
        try Data().write(to: emptyB)

        let item = makeCategoryItem(
            category: makeCategory(at: root, name: "zero-alloc-cat"),
            records: [makeRecord(root)],
            exact: 0, estimated: 0
        )
        XCTAssertEqual(item.state, .measured)
        XCTAssertEqual(item.allocatedBytes, 0)

        let report = await CacheCleaner(containerRoots: []).clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty,
                      "a zero-allocated aggregate yields no entry")
        XCTAssertTrue(report.errors.isEmpty,
                      "the skip is a no-op, never an error: \(report.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyA.path),
                      "children survive a confirmed clean of a zero-allocated aggregate")
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyB.path),
                      "children survive a confirmed clean of a zero-allocated aggregate")
    }

    func testCommandsIgnoreMoveToTrashAndNeverUseAShell() async throws {
        let cmdRoot = try makeTempDir("cmd-argv")
        let trashDir = try makeTempDir("fake-trash")
        defer {
            try? FileManager.default.removeItem(at: cmdRoot)
            try? FileManager.default.removeItem(at: trashDir)
        }
        // Shell probe: `/bin/echo` receives the redirect spelling as ONE
        // exec argument — a file appears at `escape` ONLY if some shell
        // interpreted the argv.
        let marker = cmdRoot.appendingPathComponent("ran.marker")
        let escape = cmdRoot.appendingPathComponent("shell-was-used")
        let recorder = TrashRecorder()
        let item = makeCategoryItem(
            category: makeCategory(
                at: [cmdRoot], name: "cmd-trash-mode",
                cleanCommands: [
                    ["/usr/bin/touch", marker.path],
                    ["/bin/echo", "redirect > \(escape.path)"],
                ]
            ),
            records: [makeRecord(cmdRoot)],
            exact: 512
        )

        let cleaner = CacheCleaner(
            containerRoots: [],
            trashHandler: makeTrashSeam(into: trashDir, recorder: recorder)
        )
        let report = await cleaner.clean(items: [item], moveToTrash: true)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the argv ran despite the Trash toggle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escape.path),
                       "no shell may ever interpret the argv — the redirect stays a literal argument")
        XCTAssertTrue(recorder.urls.isEmpty,
                      ".commands ignores moveToTrash — the trash seam is never invoked")
        XCTAssertEqual(report.disposal, .trash)
        XCTAssertEqual(report.entries.first?.disposal, .permanent,
                       "command bytes are erased permanently even in a Trash run")
    }

    // MARK: - Unified entry: delete-time command survival gate (R17)

    func testCommandsRefusedWhenAllCapturedRootsDeletedAfterScan() async throws {
        let home = try makeTempDir("cmd-survival-home")
        let cmdRoot = try makeTempDir("cmd-survival-root")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: cmdRoot)
        }
        // The marker lives OUTSIDE the vanished root: the touch would
        // succeed if the argv ever launched, so its absence proves the
        // command never ran.
        let marker = home.appendingPathComponent("never-run.marker")

        // Record captured while the root existed (fn-2.1 snapshot) — then
        // the root is deleted before confirmation. Re-admission alone would
        // pass the stale spelling via the canonical-components fallback.
        let item = makeCategoryItem(
            category: makeCategory(
                at: [cmdRoot], name: "cmd-root-deleted",
                cleanCommands: [["/usr/bin/touch", marker.path]]
            ),
            records: [makeRecord(cmdRoot)],
            exact: 4096
        )
        try FileManager.default.removeItem(at: cmdRoot)

        let report = await CacheCleaner(home: home, containerRoots: []).clean(
            items: [item], moveToTrash: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "commands must NOT execute after every captured root vanished")
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(logContents(home: home).contains("REFUSED [no-resolved-root]"),
                      "the survival-gate refusal must be logged")
    }

    func testCommandsRefusedWhenCapturedRootRenamedAfterScan() async throws {
        let home = try makeTempDir("cmd-renamed-home")
        let base = try makeTempDir("cmd-renamed-base")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: base)
        }
        let cmdRoot = base.appendingPathComponent("cmd-root")
        try FileManager.default.createDirectory(
            at: cmdRoot, withIntermediateDirectories: true
        )
        let marker = home.appendingPathComponent("never-run.marker")

        let item = makeCategoryItem(
            category: makeCategory(
                at: [cmdRoot], name: "cmd-root-renamed",
                cleanCommands: [["/usr/bin/touch", marker.path]]
            ),
            records: [makeRecord(cmdRoot)],
            exact: 4096
        )
        // Renamed (not deleted) after capture: the captured spelling no
        // longer exists, and nothing may silently retarget the moved tree.
        try FileManager.default.moveItem(
            at: cmdRoot, to: base.appendingPathComponent("cmd-root-moved")
        )

        let report = await CacheCleaner(home: home, containerRoots: []).clean(
            items: [item], moveToTrash: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "commands must NOT execute after the captured root was renamed")
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(logContents(home: home).contains("REFUSED [no-resolved-root]"),
                      "the survival-gate refusal must be logged")
    }

    func testCommandsProceedWhenSomeCapturedRootsSurvive() async throws {
        let base = try makeTempDir("cmd-partial-base")
        defer { try? FileManager.default.removeItem(at: base) }
        let survivor = base.appendingPathComponent("survivor-root")
        let vanished = base.appendingPathComponent("vanished-root")
        for dir in [survivor, vanished] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
        let marker = survivor.appendingPathComponent("ran.marker")

        // Both roots captured at scan time; one vanishes before
        // confirmation. Pre-unification semantics: surviving roots still
        // resolved at delete time, so the command set ran — partial
        // survival proceeds.
        let item = makeCategoryItem(
            category: makeCategory(
                at: [survivor, vanished], name: "cmd-partial",
                cleanCommands: [["/usr/bin/touch", marker.path]]
            ),
            records: [makeRecord(survivor), makeRecord(vanished)],
            exact: 2048
        )
        try FileManager.default.removeItem(at: vanished)

        let report = await CacheCleaner(containerRoots: []).clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the command set runs while at least one captured root survives")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.estimatedUpToBytes, 2048)
    }

    // MARK: - Unified entry: root-record statuses (frozen truth table)

    func testRootRecordStatusesHonoredOnlyMeasuredRootsClean() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let refused = base.appendingPathComponent("refused-root")
        let denied = base.appendingPathComponent("denied-root")
        let walked = base.appendingPathComponent("walked-root")
        let cleanEmpty = base.appendingPathComponent("clean-empty-root")
        for dir in [refused, denied, walked, cleanEmpty] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try writeFile(refused.appendingPathComponent("keep-a.bin"))
        try writeFile(denied.appendingPathComponent("keep-b.bin"))
        try writeFile(walked.appendingPathComponent("go.bin"), bytes: 4096)
        let expected = try measuredExactOfChildren(of: walked)

        let category = makeCategory(
            at: [refused, denied, walked, cleanEmpty], name: "status-cat"
        )
        let item = makeCategoryItem(category: category, records: [
            makeRecord(refused, status: .refusedAdmission),
            makeRecord(denied, status: .deniedUnmeasured),
            makeRecord(walked, status: .measured),
            makeRecord(cleanEmpty, status: .measured),
        ])

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty,
                      "non-measured statuses are silently non-deletable, not errors: \(report.errors)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: refused.appendingPathComponent("keep-a.bin").path),
            "a refusedAdmission record is NEVER deletable"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: denied.appendingPathComponent("keep-b.bin").path),
            "a deniedUnmeasured record is NOT deletable"
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: walked.path), [],
                       "the measured root's children are deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanEmpty.path),
                      "a clean-empty measured root is still processed — a no-op, no error")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.exactBytes, expected)
    }

    func testDeleteTimeRefusedMeasuredRootAmongNReportsAndOthersClean() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let declared = base.appendingPathComponent("declared-root")
        let outsider = base.appendingPathComponent("outsider-root")
        try FileManager.default.createDirectory(at: declared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsider, withIntermediateDirectories: true)
        try writeFile(declared.appendingPathComponent("go.bin"), bytes: 4096)
        try writeFile(outsider.appendingPathComponent("keep.bin"), bytes: 4096)
        let expected = try measuredExactOfChildren(of: declared)

        // The category declares ONLY `declared` — the outsider record is a
        // measured root that FAILS delete-time admission (policy drift).
        let category = makeCategory(at: declared, name: "drift-cat")
        let item = makeCategoryItem(category: category, records: [
            makeRecord(outsider),
            makeRecord(declared),
        ])

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertEqual(report.errors.count, 1,
                       "the refused root is ONE per-item error: \(report.errors)")
        XCTAssertEqual(report.errors.first?.key, item.key)
        XCTAssertTrue(report.errors.first?.message.contains(outsider.path) == true,
                      "the error names the refused root")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsider.appendingPathComponent("keep.bin").path),
            "nothing under the refused root is deleted"
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: declared.path), [],
                       "per-root isolation: the remaining root still cleans")
        XCTAssertEqual(report.entries.first?.exactBytes, expected)
    }

    func testCommandsWholeSetRefusedWhenAnyRecordedRootRefused() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let declared = base.appendingPathComponent("sim-root")
        let outsider = base.appendingPathComponent("drifted-root")
        try FileManager.default.createDirectory(at: declared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsider, withIntermediateDirectories: true)
        let marker = base.appendingPathComponent("command-ran.marker")

        let category = makeCategory(
            at: [declared], name: "cmd-refused",
            cleanCommands: [["/usr/bin/touch", marker.path]]
        )
        let item = makeCategoryItem(category: category, records: [
            makeRecord(declared),
            makeRecord(outsider),
        ], exact: 2048)

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "ONE refused root refuses the ENTIRE command set (R17 parity)")
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(report.errors.first?.key, item.key)
    }

    // MARK: - Unified entry: ENOENT asymmetry (frozen)

    func testMissingRemoveItemTargetIsAnItemKeyedError() async throws {
        let container = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: container) }
        let target = container.appendingPathComponent("ghost/node_modules")
        let item = makeRemoveItem(origin: container, target: target)

        let cleaner = CacheCleaner(
            containerRoots: [container],
            containerSnapshot: sessionSnapshot(of: [container])
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1,
                       "a missing .removeItem target is an ERROR, never a silent skip")
        XCTAssertEqual(report.errors.first?.key, item.key)
        XCTAssertEqual(report.errors.first?.displayName, item.displayName,
                       "the error renders without any item lookup")
    }

    func testMissingCategoryChildIsStillSkippedNotAnError() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let ghost = root.appendingPathComponent("ghost.bin")
        let real = root.appendingPathComponent("real.bin")
        try writeFile(ghost, bytes: 4096)
        try writeFile(real, bytes: 4096)

        // The provider reports the ghost child ABSENT — the hermetic
        // stand-in for a child vanishing between enumeration and the
        // already-gone probe. Contents mode SKIPS it (the one place the
        // ENOENT skip lives); its bytes are neither freed nor errored.
        let provider = DeviceInjectingProvider()
        provider.absentPaths = [provider.canonicalize(ghost).path]

        let item = makeCategoryItem(
            category: makeCategory(at: root, name: "enoent-cat"),
            records: [makeRecord(root)]
        )
        let cleaner = CacheCleaner(containerRoots: [], provider: provider)
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty,
                      "an already-gone category child is a SKIP, not an error: \(report.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ghost.path),
                      "the probe-absent child is left alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.path),
                       "siblings still clean")
    }

    // MARK: - Unified entry: symlink leaf (R4 mirror)

    func testRemoveItemSymlinkTargetDeletesLinkDestinationUntouched() async throws {
        let container = try makeTempDir("symlink-container")
        let external = try makeTempDir("symlink-destination")
        defer {
            try? FileManager.default.removeItem(at: container)
            try? FileManager.default.removeItem(at: external)
        }
        let precious = external.appendingPathComponent("precious.bin")
        try writeFile(precious, bytes: 8192)
        let projectDir = container.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let link = projectDir.appendingPathComponent("linked-target")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)

        let item = makeRemoveItem(origin: container, target: link)
        let cleaner = CacheCleaner(
            containerRoots: [container],
            containerSnapshot: sessionSnapshot(of: [container])
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                     "the UNRESOLVED leaf — the link itself — is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path),
                      "the destination and its contents are untouched")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.bytesFreed, 0,
                       "a symlink leaf measures nothing")
    }

    // MARK: - Delete-time auto-clean revalidation (sweep items, PR #456)
    //
    // fn-4.8 migrated these onto the generalized per-scanner revalidator
    // seam: the cleaner no longer hard-codes the sweep scanner's id, so the
    // fixtures now register the sweep scanner's OWN declared revalidator —
    // exactly what `SpaceScannerRuntime.makeCleaner(snapshot:)` injects in
    // production — and the sweep items carry the marker their emission now
    // sets. Same fixtures, same assertions, same refusal messages.

    /// The registration-captured registry a runtime-built cleaner would
    /// hold for the sweep scanner, spelled out for the DIRECT constructions
    /// in this file.
    private var sweepRevalidators: [String: PreDeleteRevalidator] {
        [OrphanedCachesScanner.registeredID:
            OrphanedCachesScanner.preDeleteRevalidator(
                provider: FileSystemIdentityProvider()
            )]
    }

    /// A fixture "~/Library/Caches" container plus one sweep entry holding
    /// plain cache content, with the session snapshot captured while that
    /// content exists — the pre-mutation state every revalidation test
    /// starts from.
    private func makeSweepFixture(
        _ label: String = #function
    ) throws -> (home: URL, caches: URL, entry: URL, snapshot: ContainerSnapshot) {
        let home = try makeTempDir(label)
        let caches = home.appendingPathComponent("Library/Caches")
        let entry = caches.appendingPathComponent("com.apple.SwiftUI.Drag-REVAL")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try writeFile(entry.appendingPathComponent("payload.bin"), bytes: 4096)
        return (home, caches, entry, sessionSnapshot(of: [caches]))
    }

    func testAutoEligibleSweepItemRecreatedWithUserDataIsRefusedUntouched() async throws {
        let (home, caches, entry, snapshot) = try makeSweepFixture()
        defer { try? FileManager.default.removeItem(at: home) }

        // Between scan and confirmation: the ENTRY (not the container) is
        // removed and recreated at the same name holding user-data-shaped
        // content the scan never inspected. The container's identity — all
        // the session snapshot binds — is untouched, so every pre-existing
        // check still passes.
        try FileManager.default.removeItem(at: entry)
        let library = entry.appendingPathComponent("Photos Library.photoslibrary")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let victim = library.appendingPathComponent("database.db")
        try writeFile(victim, bytes: 4096)

        let item = makeRemoveItem(
            scannerID: OrphanedCachesScanner.registeredID,
            displayName: entry.lastPathComponent,
            origin: caches, target: entry,
            requiresRevalidation: true
        )
        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot,
            preDeleteRevalidators: sweepRevalidators
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty, "nothing may be deleted")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("contents changed since scan"), message)
        XCTAssertTrue(message.contains("photos-library"),
                      "the refusal names the matched shape: \(message)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path),
                      "the recreated, uninspected content is untouched")
        XCTAssertTrue(logContents(home: home).contains("REFUSED [content-drift]"),
                      "the refusal is logged with its own tag")
    }

    func testAutoEligibleSweepItemProbeIncompleteAtDeleteTimeIsRefused() async throws {
        let (home, caches, entry, snapshot) = try makeSweepFixture()
        defer { try? FileManager.default.removeItem(at: home) }

        // Recreate the entry with a directory sitting AT the probe's depth
        // boundary (entry/a/b/c — c is a directory at depth 3, left
        // unexpanded): the pre-delete probe cannot prove the absence of
        // user data, and an inspection that could not finish is treated
        // like a change (fail closed).
        try FileManager.default.removeItem(at: entry)
        let deep = entry.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let survivor = deep.appendingPathComponent("hidden.bin")
        try writeFile(survivor, bytes: 1024)

        let item = makeRemoveItem(
            scannerID: OrphanedCachesScanner.registeredID,
            displayName: entry.lastPathComponent,
            origin: caches, target: entry,
            requiresRevalidation: true
        )
        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot,
            preDeleteRevalidators: sweepRevalidators
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("couldn't fully re-inspect"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.path),
                      "content behind the uninspectable boundary survives")
        XCTAssertTrue(logContents(home: home).contains("REFUSED [content-drift]"))
    }

    func testAutoEligibleSweepItemUnchangedStillDeletes() async throws {
        let (home, caches, entry, snapshot) = try makeSweepFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = measured(entry).exactAllocatedBytes

        let item = makeRemoveItem(
            scannerID: OrphanedCachesScanner.registeredID,
            displayName: entry.lastPathComponent,
            origin: caches, target: entry,
            requiresRevalidation: true
        )
        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot,
            preDeleteRevalidators: sweepRevalidators
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.exactBytes, expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path),
                       "an unchanged clean entry deletes normally")
    }

    func testRevalidationScopedToAutoEligibleSweepItemsOnly() async throws {
        // (a) A review-tier sweep item (`automaticCleanEligible == false`)
        // whose user-data shape was DISCLOSED in its displayed evidence at
        // scan time: conscious per-item confirmation still deletes it — the
        // epic's verified-Photos-library field case must never become
        // permanently undeletable. (b) Another scanner's `.removeItem`
        // target containing user-data-shaped content: the revalidation is
        // keyed to the sweep scanner and must not fire.
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let caches = home.appendingPathComponent("Library/Caches")
        let reviewed = caches.appendingPathComponent("com.apple.SwiftUI.Drag-REVIEWED")
        try FileManager.default.createDirectory(
            at: reviewed.appendingPathComponent("Pictures"),
            withIntermediateDirectories: true
        )
        try writeFile(reviewed.appendingPathComponent("Pictures/photo.jpg"), bytes: 2048)
        let other = caches.appendingPathComponent("other-scanner-target")
        try FileManager.default.createDirectory(
            at: other.appendingPathComponent("Documents"),
            withIntermediateDirectories: true
        )
        try writeFile(other.appendingPathComponent("Documents/doc.txt"), bytes: 1024)

        let reviewedItem = makeRemoveItem(
            id: "reviewed", scannerID: OrphanedCachesScanner.registeredID,
            displayName: reviewed.lastPathComponent,
            origin: caches, target: reviewed,
            autoEligible: false
        )
        let otherItem = makeRemoveItem(
            id: "other", scannerID: "fixture_scanner",
            displayName: other.lastPathComponent,
            origin: caches, target: other
        )
        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches],
            containerSnapshot: sessionSnapshot(of: [caches]),
            preDeleteRevalidators: sweepRevalidators
        )
        let report = await cleaner.clean(
            items: [reviewedItem, otherItem], moveToTrash: false
        )

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reviewed.path),
                       "a consciously-confirmed review item still deletes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path),
                       "the sweep-keyed revalidation never fires for other scanners")
    }

    // MARK: - Pre-delete revalidator seam (fn-4.8, R17/D8)

    /// A build-artifact-shaped fixture: a "dev root" container holding one
    /// artifact directory whose contents the item never bound.
    private func makeArtifactFixture(
        _ label: String = #function
    ) throws -> (home: URL, devRoot: URL, artifact: URL, snapshot: ContainerSnapshot) {
        let home = try makeTempDir(label)
        let devRoot = home.appendingPathComponent("dev")
        let artifact = devRoot.appendingPathComponent("proj/target")
        try FileManager.default.createDirectory(
            at: artifact, withIntermediateDirectories: true
        )
        try writeFile(artifact.appendingPathComponent("build.o"), bytes: 4096)
        return (home, devRoot, artifact, sessionSnapshot(of: [devRoot]))
    }

    func testMarkedItemsOfBothScannersRefusedByCleanerWithoutRegistry() async throws {
        // THE fail-closed guarantee the scanner-agnostic marker exists for:
        // a `CacheCleaner` built DIRECTLY — bypassing the runtime that
        // captures the revalidator registry — cannot perform the
        // re-inspection a marked item structurally demands, so it refuses
        // it. Proven for BOTH scanners in ONE clean, so the orphaned-caches
        // migration provably does not weaken what the hard-coded gate gave
        // that scanner: an auto-clean-eligible sweep entry and a
        // build-artifact directory are both refused, both untouched.
        let (home, caches, entry, _) = try makeSweepFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let artifact = home.appendingPathComponent("dev/proj/target")
        try FileManager.default.createDirectory(
            at: artifact, withIntermediateDirectories: true
        )
        try writeFile(artifact.appendingPathComponent("build.o"), bytes: 2048)
        let devRoot = home.appendingPathComponent("dev")

        let sweepItem = makeRemoveItem(
            id: "sweep", scannerID: OrphanedCachesScanner.registeredID,
            displayName: entry.lastPathComponent,
            origin: caches, target: entry,
            requiresRevalidation: true
        )
        let artifactItem = makeRemoveItem(
            id: "artifact", scannerID: BuildArtifactsScanner.registeredID,
            displayName: "target", origin: devRoot, target: artifact,
            autoEligible: false, requiresRevalidation: true
        )
        // A cleaner with the container roots and the session snapshot — the
        // registry is the ONLY thing missing.
        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches, devRoot],
            containerSnapshot: sessionSnapshot(of: [caches, devRoot])
        )
        let report = await cleaner.clean(
            items: [sweepItem, artifactItem], moveToTrash: false
        )

        XCTAssertTrue(report.entries.isEmpty, "nothing may be deleted")
        XCTAssertEqual(report.errors.count, 2)
        XCTAssertEqual(
            Set(report.errors.map(\.key)),
            [sweepItem.key, artifactItem.key],
            "both refusals are ITEM-KEYED"
        )
        for error in report.errors {
            XCTAssertTrue(
                error.message.contains("no revalidator is registered"),
                error.message
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertTrue(
            logContents(home: home).contains("REFUSED [revalidator-unavailable]"),
            "the fail-closed refusal is logged, never a silent skip"
        )
    }

    func testMarkedItemWithoutRegistryRefusesBeforeAnyStateSkip() async throws {
        // Review r1: the fail-closed marker check is ordered WITH the
        // structural check, not at the destructive chokepoint — otherwise a
        // `.missing`/`.empty` skip or a `.denied` refusal would SWALLOW it
        // and a marked item that cannot be re-inspected would leave no
        // trace. An empty build-artifact directory is a real emission
        // (`.empty` items exist), so this is not a hypothetical shape.
        let (home, _, artifact, snapshot) = try makeArtifactFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let devRoot = home.appendingPathComponent("dev")

        let states: [ScanState] = [.missing, .empty, .denied]
        let marked = states.enumerated().map { index, state in
            makeRemoveItem(
                id: "marked-\(index)",
                scannerID: BuildArtifactsScanner.registeredID,
                origin: devRoot, target: artifact, state: state,
                autoEligible: false, requiresRevalidation: true
            )
        }
        let cleaner = CacheCleaner(
            home: home, containerRoots: [devRoot], containerSnapshot: snapshot
        )
        let report = await cleaner.clean(items: marked, moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, states.count,
                       "every marked item surfaces its own item-keyed error")
        XCTAssertEqual(Set(report.errors.map(\.key)), Set(marked.map(\.key)))
        for error in report.errors {
            XCTAssertTrue(
                error.message.contains("no revalidator is registered"),
                "a state skip must not mask the fail-closed refusal: "
                    + error.message
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))

        // With the registry present, the SAME items behave exactly as they
        // always did: `.missing`/`.empty` are silent no-ops and `.denied`
        // refuses for its scan state — check (1b) changes nothing for a
        // cleaner that can actually revalidate.
        let equipped = CacheCleaner(
            home: home, containerRoots: [devRoot], containerSnapshot: snapshot,
            preDeleteRevalidators: [
                BuildArtifactsScanner.registeredID:
                    BuildArtifactsScanner.preDeleteRevalidator(
                        provider: FileSystemIdentityProvider()
                    )
            ]
        )
        let second = await equipped.clean(items: marked, moveToTrash: false)
        XCTAssertTrue(second.entries.isEmpty)
        XCTAssertEqual(second.errors.count, 1, "only the `.denied` item errors")
        XCTAssertEqual(second.errors.first?.key, marked[2].key)
        XCTAssertFalse(
            try XCTUnwrap(second.errors.first?.message)
                .contains("no revalidator is registered"),
            second.errors.first?.message ?? ""
        )
    }

    func testUnmarkedItemOfScannerWithoutRevalidatorIsUnaffected() async throws {
        // The no-regression half of the same contract: an UNMARKED item of
        // a scanner with no registered revalidator (and no predicate to ask)
        // deletes exactly as it did before the seam existed — the whole
        // pre-fn-4.8 behaviour of every other scanner.
        let (home, _, artifact, snapshot) = try makeArtifactFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let devRoot = home.appendingPathComponent("dev")

        let item = makeRemoveItem(
            scannerID: "fixture_scanner", origin: devRoot, target: artifact
        )
        let cleaner = CacheCleaner(
            home: home, containerRoots: [devRoot], containerSnapshot: snapshot,
            preDeleteRevalidators: sweepRevalidators
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
    }

    func testMarkerForgottenSweepItemStillReProbesViaRegistryPredicate() async throws {
        // BELT-AND-BRACES, the cleaner half. A mapping regression emits an
        // `automaticCleanEligible` sweep entry but FORGETS the marker. The
        // registry's own applicability predicate still says "re-probe", so
        // the protection the removed hard-coded gate provided is not lost:
        // the recreated user data is refused, untouched. (The scan-time half
        // — the same shape failing `validatedOutcome` — is proven in
        // `OrphanedCachesScannerTests`.)
        let (home, caches, entry, snapshot) = try makeSweepFixture()
        defer { try? FileManager.default.removeItem(at: home) }

        try FileManager.default.removeItem(at: entry)
        let library = entry.appendingPathComponent("Photos Library.photoslibrary")
        try FileManager.default.createDirectory(
            at: library, withIntermediateDirectories: true
        )
        let victim = library.appendingPathComponent("database.db")
        try writeFile(victim, bytes: 4096)

        let unmarked = makeRemoveItem(
            scannerID: OrphanedCachesScanner.registeredID,
            displayName: entry.lastPathComponent,
            origin: caches, target: entry,
            requiresRevalidation: false
        )
        XCTAssertTrue(unmarked.automaticCleanEligible)
        XCTAssertFalse(unmarked.requiresPreDeleteRevalidation,
                       "the regression fixture is deliberately unmarked")

        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot,
            preDeleteRevalidators: sweepRevalidators
        )
        let report = await cleaner.clean(items: [unmarked], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty, "nothing may be deleted")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("contents changed since scan"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path),
                      "the recreated content is byte-untouched")
        XCTAssertTrue(logContents(home: home).contains("REFUSED [content-drift]"))
    }

    func testMarkedAggregateItemIsStructurallyRefused() async throws {
        // The marker is a PER-TARGET contract: the seam re-inspects the one
        // `.containerItem` target. An aggregate carrying it could never be
        // re-inspected that way, so it is refused at the structural check
        // rather than deleted through a path the marker does not cover.
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("cat-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile(root.appendingPathComponent("f.bin"), bytes: 1024)

        let category = makeCategory(at: [root], name: "marked-cat")
        let item = makeItem(
            id: category.slug, scannerID: "categories",
            displayName: category.name, records: [makeRecord(root)],
            action: .removeContents, admission: .category(category),
            requiresRevalidation: true
        )
        let cleaner = CacheCleaner(home: home, containerRoots: [])
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(report.errors.first?.message)
                .contains("per-target contract"),
            report.errors.first?.message ?? ""
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("f.bin").path
            ),
            "nothing under the aggregate is touched"
        )
    }

    // MARK: - Unified entry: accounting-registry scope

    func testScannerGroupRegistryTransfersSharedInodeOnce() async throws {
        let container = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: container) }
        let dirA = container.appendingPathComponent("proj-a/artifacts")
        let dirB = container.appendingPathComponent("proj-b/artifacts")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        let fileA = dirA.appendingPathComponent("shared.bin")
        try Data(repeating: 0xCD, count: 8192).write(to: fileA)
        try FileManager.default.linkItem(
            at: fileA, to: dirB.appendingPathComponent("shared.bin")
        )
        let canonical = measured(fileA).estimatedUpToBytes
        XCTAssertGreaterThan(canonical, 0)

        let itemA = makeRemoveItem(
            id: "item-a", displayName: "proj-a", origin: container, target: dirA
        )
        let itemB = makeRemoveItem(
            id: "item-b", displayName: "proj-b", origin: container, target: dirB
        )

        let cleaner = CacheCleaner(
            containerRoots: [container],
            containerSnapshot: sessionSnapshot(of: [container])
        )
        let report = await cleaner.clean(items: [itemA, itemB], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirB.path))
        // The SCANNER-GROUP total — not any per-item split — transfers the
        // shared inode exactly once, as estimated (one registry per scanner
        // operation).
        let rollup = report.scannerRollups.first { $0.scannerID == "fixture_scanner" }
        XCTAssertEqual(rollup?.estimatedUpToBytes, canonical,
                       "the shared inode transfers ONCE across the scanner group")
        XCTAssertEqual(rollup?.exactBytes, 0,
                       "hardlinked bytes never land in exact")
        XCTAssertEqual(rollup?.entryCount, 2)
    }

    func testCrossCategoryHardlinkStillCountsPerCategory() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let rootA = base.appendingPathComponent("cat-a-root")
        let rootB = base.appendingPathComponent("cat-b-root")
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let fileA = rootA.appendingPathComponent("shared.bin")
        try Data(repeating: 0xCD, count: 8192).write(to: fileA)
        try FileManager.default.linkItem(
            at: fileA, to: rootB.appendingPathComponent("shared.bin")
        )
        let canonical = measured(fileA).estimatedUpToBytes

        let itemA = makeCategoryItem(
            category: makeCategory(at: rootA, name: "cat-a"),
            records: [makeRecord(rootA)]
        )
        let itemB = makeCategoryItem(
            category: makeCategory(at: rootB, name: "cat-b"),
            records: [makeRecord(rootB)]
        )

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(items: [itemA, itemB], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        let byID = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.itemID, $0) })
        // ITEM-LOCAL registries: each aggregate counts the shared inode's
        // bytes — the preserved fn-1 scope, disclosed by the D8 caveat
        // (unchanged). The first walk sees st_nlink == 2 (estimated); the
        // second registry never saw the link count before it decayed, so
        // its classification is its own — the double COUNT is the point.
        XCTAssertEqual(byID["cat-a"]?.bytesFreed, canonical)
        XCTAssertEqual(byID["cat-b"]?.bytesFreed, canonical)
        XCTAssertEqual(byID["cat-a"]?.estimatedUpToBytes, canonical,
                       "the first walk observes the live hardlink — estimated")
    }

    // MARK: - Unified entry: structural refusals (rounds 11-13)

    func testStructuralShapeRefusalsAtDispatchWithoutValidator() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let survivorRoot = base.appendingPathComponent("survivor-root")
        try FileManager.default.createDirectory(at: survivorRoot, withIntermediateDirectories: true)
        try writeFile(survivorRoot.appendingPathComponent("keep.bin"))
        let marker = base.appendingPathComponent("never-run.marker")

        // (a) NON-missing `.commands` with ZERO root records: no argv may
        // ever run off a vacuous admission pass.
        let zeroRecordCommands = makeCategoryItem(
            category: makeCategory(
                at: [survivorRoot], name: "zero-rec-cmd",
                cleanCommands: [["/usr/bin/touch", marker.path]]
            ),
            records: [], exact: 2048
        )
        // (b) NON-missing `.removeContents` with ZERO root records.
        let zeroRecordContents = makeCategoryItem(
            category: makeCategory(at: survivorRoot, name: "zero-rec-contents"),
            records: []
        )
        // (c) `.removeItem` without the `.containerItem` descriptor.
        let wrongDescriptorItem = makeItem(
            id: "wrong-descriptor-item",
            records: [makeRecord(survivorRoot)],
            action: .removeItem,
            admission: .category(makeCategory(at: survivorRoot, name: "not-a-container-cat"))
        )
        // (d) `.removeContents` without category provenance.
        let wrongDescriptorContents = makeItem(
            id: "wrong-descriptor-contents",
            records: [makeRecord(survivorRoot)],
            action: .removeContents,
            admission: .containerItem(
                originContainer: base, requestedTargetURL: survivorRoot
            )
        )

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(
            items: [
                zeroRecordCommands, zeroRecordContents,
                wrongDescriptorItem, wrongDescriptorContents,
            ],
            moveToTrash: false
        )

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 4,
                       "every malformed shape is an ItemError refusal: \(report.errors)")
        XCTAssertEqual(
            Set(report.errors.map(\.key)),
            Set([zeroRecordCommands, zeroRecordContents,
                 wrongDescriptorItem, wrongDescriptorContents].map(\.key)),
            "each refusal is keyed to its item"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "no argv executes for a zero-record commands item")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: survivorRoot.appendingPathComponent("keep.bin").path),
            "nothing is deleted through a malformed shape"
        )
    }

    func testForgedArgvPayloadRefusedCommandArgvIsRegistryCode() async throws {
        let cmdRoot = try makeTempDir("cmd-forged-argv")
        defer { try? FileManager.default.removeItem(at: cmdRoot) }
        let declaredMarker = cmdRoot.appendingPathComponent("declared.marker")
        let forgedMarker = cmdRoot.appendingPathComponent("forged.marker")

        // The category DECLARES one argv; the item's action payload carries
        // a DIFFERENT one. Command argv is trusted registry code — a
        // payload that is not the category's declaration is a structural
        // refusal, and NOTHING executes.
        let category = makeCategory(
            at: [cmdRoot], name: "cmd-forged",
            cleanCommands: [["/usr/bin/touch", declaredMarker.path]]
        )
        let item = makeItem(
            id: "cmd-forged", scannerID: "categories",
            displayName: "cmd-forged",
            exact: 2048, records: [makeRecord(cmdRoot)],
            action: .commands([["/usr/bin/touch", forgedMarker.path]]),
            admission: .category(category)
        )

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(report.errors.first?.key, item.key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: forgedMarker.path),
                       "the forged argv must never execute")
        XCTAssertFalse(FileManager.default.fileExists(atPath: declaredMarker.path),
                       "a malformed item is refused wholesale — not silently substituted")
    }

    func testCommandBackedCategoryCannotRouteThroughRemoveContents() async throws {
        let cmdRoot = try makeTempDir("cmd-as-contents")
        defer { try? FileManager.default.removeItem(at: cmdRoot) }
        try writeFile(cmdRoot.appendingPathComponent("keep.bin"))

        // A command-backed category carried under `.removeContents`: the
        // category's own declaration decides the clean path, so this
        // mismatch can only be a forged or corrupted item — refused, no
        // file deletion.
        let category = makeCategory(
            at: [cmdRoot], name: "cmd-as-contents",
            cleanCommands: [["/usr/bin/true"]]
        )
        let item = makeItem(
            id: "cmd-as-contents", scannerID: "categories",
            displayName: "cmd-as-contents",
            records: [makeRecord(cmdRoot)],
            action: .removeContents,
            admission: .category(category)
        )

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(report.errors.first?.key, item.key)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cmdRoot.appendingPathComponent("keep.bin").path),
            "a command category must never be routed through file deletion"
        )
    }

    func testMalformedMissingItemRefusedButWellFormedMissingSkips() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        // (a) MALFORMED `.missing` item — the structural check (order step
        // 1) must fire BEFORE the `.missing` skip (step 2) so the skip can
        // never mask a bad shape.
        let malformedMissing = makeItem(
            id: "malformed-missing",
            records: [], state: .missing,
            action: .removeContents,
            admission: .containerItem(
                originContainer: base, requestedTargetURL: base
            )
        )
        // (b) WELL-FORMED `.missing` category item with empty records: the
        // round-8 pre-dispatch skip — no entry, no error.
        let wellFormedMissing = makeCategoryItem(
            category: makeCategory(at: base, name: "missing-cat"),
            records: [], state: .missing, exact: 0
        )

        let cleaner = CacheCleaner(containerRoots: [])
        let report = await cleaner.clean(
            items: [malformedMissing, wellFormedMissing], moveToTrash: false
        )

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1,
                       "ONLY the malformed missing item errors: \(report.errors)")
        XCTAssertEqual(report.errors.first?.key, malformedMissing.key,
                       "the malformed .missing item is refused, NOT silently skipped")
    }

    // MARK: - Unified entry: pre-dispatch state eligibility (rounds 8-9)

    func testPreDispatchEligibilitySkipsNeverReachAdmissionOrArgv() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let cmdRoot = base.appendingPathComponent("cmd-root")
        let contentsRoot = base.appendingPathComponent("contents-root")
        let emptyItemDir = base.appendingPathComponent("container/proj/empty-nm")
        try FileManager.default.createDirectory(at: cmdRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contentsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyItemDir, withIntermediateDirectories: true)
        try writeFile(contentsRoot.appendingPathComponent("survivor.bin"))
        let marker = base.appendingPathComponent("never-run.marker")
        let cmdCategory = makeCategory(
            at: [cmdRoot], name: "cmd-elig",
            cleanCommands: [["/usr/bin/touch", marker.path]]
        )

        // (a) `.missing` `.commands`: skips pre-dispatch — the empty record
        // set must never vacuously pass re-admission and run argv.
        let missingCommands = makeCategoryItem(
            category: cmdCategory, records: [], state: .missing, exact: 0
        )
        // (b) `.empty` `.commands`: the as-built zero-measured skip parity.
        let emptyCommands = makeCategoryItem(
            category: cmdCategory, records: [makeRecord(cmdRoot)],
            state: .empty, exact: 0
        )
        // (c) force-passed `.empty` `.removeContents`: a no-op — NO entry,
        // no error, and (having measured nothing at scan) nothing deleted.
        let emptyContents = makeCategoryItem(
            category: makeCategory(at: contentsRoot, name: "empty-contents"),
            records: [makeRecord(contentsRoot)], state: .empty, exact: 0
        )
        // (d) `.empty` `.removeItem`, DELIBERATELY claiming an origin the
        // cleaner does not admit: if admission ran, this would error — the
        // round-9 skip must fire BEFORE any admission call.
        let emptyRemoveItem = makeRemoveItem(
            id: "empty-item",
            origin: base.appendingPathComponent("unconfigured-container"),
            target: emptyItemDir,
            state: .empty, exact: 0
        )

        let cleaner = CacheCleaner(
            containerRoots: [base.appendingPathComponent("some-other-container")]
        )
        let report = await cleaner.clean(
            items: [missingCommands, emptyCommands, emptyContents, emptyRemoveItem],
            moveToTrash: false
        )

        XCTAssertTrue(report.entries.isEmpty, "eligibility skips produce NO entries")
        XCTAssertTrue(report.errors.isEmpty,
                      "eligibility skips are never errors — even explicitly addressed: \(report.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "no argv for missing/empty command items")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: contentsRoot.appendingPathComponent("survivor.bin").path),
            "a force-passed .empty contents item deletes nothing"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyItemDir.path),
                      "an .empty .removeItem item is skipped BEFORE admission — nothing deleted")
    }

    // MARK: - Unified entry: report identity + rollups + runtime admission

    func testReportRollupsDerivePerScannerAndErrorsAreSelfContained() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let container = base.appendingPathComponent("container")
        let dirA = container.appendingPathComponent("a/artifacts")
        let dirB = container.appendingPathComponent("b/artifacts")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try writeFile(dirA.appendingPathComponent("a.bin"), bytes: 4096)
        try writeFile(dirB.appendingPathComponent("b.bin"), bytes: 8192)
        let catRoot = base.appendingPathComponent("cat-root")
        try FileManager.default.createDirectory(at: catRoot, withIntermediateDirectories: true)
        try writeFile(catRoot.appendingPathComponent("c.bin"), bytes: 4096)
        let ghostTarget = container.appendingPathComponent("ghost/artifacts")

        let items = [
            makeRemoveItem(id: "item-a", displayName: "a", origin: container, target: dirA),
            makeRemoveItem(id: "item-b", displayName: "b", origin: container, target: dirB),
            makeRemoveItem(id: "item-ghost", displayName: "ghost", origin: container, target: ghostTarget),
            makeCategoryItem(
                category: makeCategory(at: catRoot, name: "cat-c"),
                records: [makeRecord(catRoot)]
            ),
        ]

        let cleaner = CacheCleaner(
            containerRoots: [container],
            containerSnapshot: sessionSnapshot(of: [container])
        )
        let report = await cleaner.clean(items: items, moveToTrash: false)

        XCTAssertEqual(report.entries.count, 3)
        XCTAssertEqual(report.errors.count, 1)
        // Self-contained error record: renderable with NO item lookup.
        let error = try XCTUnwrap(report.errors.first)
        XCTAssertEqual(error.key, ItemKey(scannerID: "fixture_scanner", itemID: "item-ghost"))
        XCTAssertEqual(error.displayName, "ghost")
        XCTAssertFalse(error.message.isEmpty)

        // Rollups derive per scannerID and equal the sum of that scanner's
        // entry components — pure sums, first-appearance order.
        let rollups = report.scannerRollups
        XCTAssertEqual(rollups.map(\.scannerID), ["fixture_scanner", "categories"])
        let fixtureEntries = report.entries.filter { $0.scannerID == "fixture_scanner" }
        XCTAssertEqual(fixtureEntries.count, 2)
        XCTAssertEqual(
            rollups[0].exactBytes,
            fixtureEntries.reduce(0) { $0 + $1.exactBytes }
        )
        XCTAssertEqual(
            rollups[0].estimatedUpToBytes,
            fixtureEntries.reduce(0) { $0 + $1.estimatedUpToBytes }
        )
        XCTAssertEqual(rollups[0].entryCount, 2)
        XCTAssertEqual(
            rollups.reduce(0) { $0 + $1.exactBytes }, report.totalFreedExact,
            "rollups partition the report totals"
        )
    }

    func testRuntimeConstructedCleanerDerivesAdmissionFromRegistrationOnly() async throws {
        let home = try makeTempDir("runtime-home")
        let declaredContainer = try makeTempDir("declared-container")
        let foreignContainer = try makeTempDir("foreign-container")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: declaredContainer)
            try? FileManager.default.removeItem(at: foreignContainer)
        }
        let goodTarget = declaredContainer.appendingPathComponent("proj/artifacts")
        let foreignTarget = foreignContainer.appendingPathComponent("proj/artifacts")
        try FileManager.default.createDirectory(at: goodTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreignTarget, withIntermediateDirectories: true)
        try writeFile(goodTarget.appendingPathComponent("x.bin"))
        try writeFile(foreignTarget.appendingPathComponent("y.bin"))

        // The runtime's container-root union comes from scanner
        // REGISTRATION — the one trusted composition source.
        let runtime = try SpaceScannerRuntime(
            scanners: [FixtureSpaceScanner(
                id: "fixture_scanner",
                trustedContainerRoots: [declaredContainer]
            )],
            categories: [],
            home: home,
            provider: FileSystemIdentityProvider()
        )
        let cleaner = runtime.makeCleaner(
            snapshot: sessionSnapshot(of: runtime.trustedContainerRoots)
        )

        let goodItem = makeRemoveItem(
            id: "good", displayName: "good",
            origin: declaredContainer, target: goodTarget
        )
        // The foreign item CLAIMS a container outside the runtime union —
        // provenance is a claim, and the claim gains nothing.
        let foreignItem = makeRemoveItem(
            id: "foreign", displayName: "foreign",
            origin: foreignContainer, target: foreignTarget
        )

        let report = await cleaner.clean(
            items: [goodItem, foreignItem], moveToTrash: false
        )

        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.itemID, "good")
        XCTAssertFalse(FileManager.default.fileExists(atPath: goodTarget.path),
                       "the registration-derived container admits its item")
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(report.errors.first?.key, foreignItem.key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignTarget.path),
                      "an item claiming an unregistered container is refused — items cannot widen admission")
    }

    // MARK: - Bounded subprocess wait primitive (waitUntilExit flake fix)

    func testWaitForExitObservesFastExitAndBoundsSlowChild() throws {
        // Every command/probe wait goes through `waitForExit(within:)` —
        // never `waitUntilExit()`, which misses its termination wakeup
        // under concurrent process spawning/reaping and misreported
        // millisecond commands as 30s timeouts. Fast path: a trivial child
        // is observed exited within a generous bound.
        let fast = Process()
        fast.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try fast.run()
        XCTAssertTrue(fast.waitForExit(within: 10),
                      "a trivially-fast child is observed exited within the bound")
        XCTAssertEqual(fast.terminationStatus, 0,
                       "terminationStatus is readable once the wait reports exit")

        // Bound path: the deadline caps the wait (`false`, caller owns
        // termination policy) instead of blocking. `sleep 30` cannot exit
        // within 0.2s, so this is deterministic — not a race.
        let slow = Process()
        slow.executableURL = URL(fileURLWithPath: "/bin/sleep")
        slow.arguments = ["30"]
        try slow.run()
        XCTAssertFalse(slow.waitForExit(within: 0.2),
                       "a still-running child bounds out as false")
        slow.terminate()
        XCTAssertTrue(slow.waitForExit(within: 10),
                      "termination after a bounded refusal is still observed")
    }

    // MARK: - fn-6.3: ephemeral temp-item deletion (R9)

    // The delete path for `ephemeral_tmp` items is FREE: they are ordinary
    // `.removeItem` participants through `removeGuardedItem`, so this task
    // adds ZERO production code — these tests PROVE the as-built contract
    // holds for temp items rather than building a new one.
    //
    // The contract (epic D3 REVISED): temp items FOLLOW the Move-to-Trash
    // toggle exactly like every other item. A failed trash move is an
    // ITEM-KEYED error that leaves the item in place — there is NO permanent
    // fallback (`CacheCleaner.swift` R11 comment above the toggle dispatch),
    // and consequently NOTHING anywhere claims or implies forced permanence.
    // The earlier "permanent even with Trash on" disclosure was CUT because
    // it described a degradation the cleaner cannot produce.
    //
    // Every fixture below runs the REAL `EphemeralTempScanner` over an
    // INJECTED fixture root and cleans its REAL items through a cleaner built
    // by `SpaceScannerRuntime.makeCleaner` — delete-time admission therefore
    // comes from REGISTRATION (`trustedContainerRoots`) bound to the producing
    // session's `ContainerSnapshot`, which is the production composition. The
    // only hand-built items are the FORGED ones the scanner structurally
    // cannot emit (a root-level target), which exist to prove the guard
    // refuses them anyway.
    //
    // House rules: no test trashes outside its fixture root (the trash seam
    // MOVES into a fixture-local directory, so "recoverable" is asserted by
    // reading the moved payload back); the chmod stand-in restores 0755 before
    // teardown and skips under euid 0.

    /// Fixed scan instant — the scanner takes an injected clock, so no fixture
    /// depends on wall-clock time and nothing sleeps.
    private var ephemeralClock: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    /// 7-day stale age (the shipped default) with a small POSITIVE floor so
    /// fixtures stay cheap — the fn-6.2 test thresholds verbatim.
    private var ephemeralThresholds: EphemeralTempSweepConfig.Thresholds {
        EphemeralTempSweepConfig.Thresholds(
            sizeFloorBytes: 4_096, staleAge: 7 * 86_400
        )
    }

    private func canonical(_ url: URL) -> URL {
        FileSystemIdentityProvider().canonicalize(url)
    }

    /// Backdate a whole tree — children first, the directory itself LAST (its
    /// own mtime is a staleness input and writing children bumps it).
    private func backdateTree(_ url: URL, to date: Date) throws {
        let fm = FileManager.default
        if let kind = FileSystemIdentityProvider().kind(of: url),
           kind == .directory {
            for child in try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: []
            ) {
                try backdateTree(child, to: date)
            }
        }
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// A stale first-level temp entry — the field shape the scanner lists: an
    /// old scratch directory holding one payload file, 30 days behind the
    /// injected clock.
    @discardableResult
    private func stageStaleTempEntry(
        _ name: String, under root: URL, bytes: Int = 8_192
    ) throws -> URL {
        let entry = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: entry, withIntermediateDirectories: true
        )
        try writeFile(entry.appendingPathComponent("payload.bin"), bytes: bytes)
        try backdateTree(entry, to: ephemeralClock.addingTimeInterval(-30 * 86_400))
        return entry
    }

    /// The payload bytes `writeFile` wrote — read back out of the fixture
    /// Trash to prove a trashed entry is RECOVERABLE, not merely gone.
    private func payloadBytes(_ count: Int = 8_192) -> Data {
        Data(repeating: 0xAB, count: count)
    }

    /// A fixture world for the temp fixtures: an injected home (the cleanup
    /// log's anchor), one world-writable temp root, and a fixture-local Trash.
    private func makeEphemeralWorld(
        _ label: String = #function
    ) throws -> (base: URL, home: URL, root: URL, trash: URL) {
        let base = try makeTempDir(label)
        let home = base.appendingPathComponent("home")
        let root = base.appendingPathComponent("shared-temp")
        let trash = base.appendingPathComponent("fixture-trash")
        for url in [home, root, trash] {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
        }
        return (base, home, root, trash)
    }

    /// The scanner over an injected fixture root in the CANONICAL spelling
    /// fn-6.1 hands production (`/private/var/…`), with the fixed clock.
    private func makeEphemeralTempScanner(
        root: URL, home: URL
    ) -> EphemeralTempScanner {
        let clock = ephemeralClock
        return EphemeralTempScanner(
            roots: [EphemeralTempRoot(
                url: canonical(root),
                label: "Shared temp",
                cleanupEvidence: EphemeralTempRoots.sharedTempEvidence,
                writability: .worldWritable
            )],
            home: home,
            thresholds: ephemeralThresholds,
            now: { clock }
        )
    }

    /// Registration is the ONLY thing that puts a temp root into delete-time
    /// admission — the same runtime composition production uses.
    private func makeEphemeralRuntime(
        _ scanner: EphemeralTempScanner, home: URL
    ) throws -> SpaceScannerRuntime {
        try SpaceScannerRuntime(
            scanners: [scanner], categories: [], home: home,
            provider: FileSystemIdentityProvider()
        )
    }

    /// The scanner's REAL items for a user-initiated scan, keyed by the
    /// first-level entry name (`displayName`).
    private func scannedTempItems(
        _ scanner: EphemeralTempScanner
    ) async -> [String: ReclaimableItem] {
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))
        return Dictionary(
            uniqueKeysWithValues: outcome.items.map { ($0.displayName, $0) }
        )
    }

    /// The single entry the fixture Trash received, or nil.
    private func soleTrashedEntry(in trashDir: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: trashDir, includingPropertiesForKeys: nil, options: []
        )
        XCTAssertLessThanOrEqual(contents.count, 1,
                                 "the fixture Trash holds at most one entry here")
        return contents.first
    }

    func testEphemeralTempItemTrashModeMovesEntryIntoFixtureTrashRecoverably() async throws {
        let world = try makeEphemeralWorld("ephemeral-trash")
        defer { try? FileManager.default.removeItem(at: world.base) }
        let target = try stageStaleTempEntry("old-scratch", under: world.root)
        let expected = measured(target).exactAllocatedBytes
        XCTAssertGreaterThan(expected, 0, "the fixture must have measurable bytes")

        let scanner = makeEphemeralTempScanner(root: world.root, home: world.home)
        let items = await scannedTempItems(scanner)
        let item = try XCTUnwrap(items["old-scratch"],
                                 "the stale entry must be listed to be deleted")

        let runtime = try makeEphemeralRuntime(scanner, home: world.home)
        let recorder = TrashRecorder()
        let cleaner = runtime.makeCleaner(
            snapshot: sessionSnapshot(of: runtime.trustedContainerRoots),
            trashHandler: makeTrashSeam(into: world.trash, recorder: recorder)
        )

        let report = await cleaner.clean(items: [item], moveToTrash: true)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        // The seam received the item's UNRESOLVED requested target, spelled
        // under the scanner's ONE canonical root (R3).
        XCTAssertEqual(
            recorder.urls.map(\.path),
            [canonical(world.root).appendingPathComponent("old-scratch").path],
            "item mode trashes the temp entry itself, in the canonical spelling"
        )
        // A no-op recording handler would prove nothing: the source must be
        // GONE and the payload must be READABLE where the handler put it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "the trashed entry is gone from the temp root")
        let recovered = try XCTUnwrap(try soleTrashedEntry(in: world.trash),
                                      "the entry must land in the fixture Trash")
        XCTAssertTrue(recovered.lastPathComponent.hasSuffix("-old-scratch"))
        XCTAssertEqual(
            try Data(contentsOf: recovered.appendingPathComponent("payload.bin")),
            payloadBytes(),
            "a trashed temp entry is RECOVERABLE — its payload bytes survive"
        )
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.scannerID,
                       EphemeralTempScanner.registeredID)
        XCTAssertEqual(report.entries.first?.itemID, item.id)
        XCTAssertEqual(report.entries.first?.exactBytes, expected,
                       "freed bytes are measured at delete time")
        // The toggle is HONORED — no forced permanence exists for temp items,
        // so nothing may report or imply it (epic D3 revised).
        XCTAssertEqual(report.entries.first?.disposal, .trash)
        XCTAssertEqual(report.disposal, .trash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.root.path),
                      "the temp ROOT survives — item mode deletes the entry, never its container")
    }

    func testEphemeralTempItemPermanentModeRemovesEntryAndNeverTouchesTheTrashSeam() async throws {
        let world = try makeEphemeralWorld("ephemeral-permanent")
        defer { try? FileManager.default.removeItem(at: world.base) }
        let target = try stageStaleTempEntry("old-scratch", under: world.root)
        let expected = measured(target).exactAllocatedBytes

        let scanner = makeEphemeralTempScanner(root: world.root, home: world.home)
        let items = await scannedTempItems(scanner)
        let item = try XCTUnwrap(items["old-scratch"])

        // D1 INVARIANT, asserted where it is load-bearing: temp items are
        // never auto-clean eligible and carry no revalidation marker, and the
        // scanner declares no revalidator — so they route around the
        // delete-time revalidation seam entirely and reach the toggle
        // dispatch unmodified.
        XCTAssertFalse(item.automaticCleanEligible)
        XCTAssertFalse(item.requiresPreDeleteRevalidation)
        XCTAssertNil(scanner.preDeleteRevalidator)

        let runtime = try makeEphemeralRuntime(scanner, home: world.home)
        let recorder = TrashRecorder()
        let cleaner = runtime.makeCleaner(
            snapshot: sessionSnapshot(of: runtime.trustedContainerRoots),
            trashHandler: makeTrashSeam(into: world.trash, recorder: recorder)
        )

        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(recorder.urls.isEmpty,
                      "permanent mode never invokes the Trash primitive")
        XCTAssertNil(try soleTrashedEntry(in: world.trash),
                     "nothing reaches the Trash in permanent mode")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.exactBytes, expected)
        XCTAssertEqual(report.entries.first?.disposal, .permanent)
        XCTAssertEqual(report.disposal, .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.root.path))
    }

    func testEphemeralTempRootItselfAndOutsideTargetsAreRefused() async throws {
        let world = try makeEphemeralWorld("ephemeral-root-refusal")
        defer { try? FileManager.default.removeItem(at: world.base) }
        try stageStaleTempEntry("old-scratch", under: world.root)
        // A sibling of the root, outside every admitted container.
        let outside = world.base.appendingPathComponent("outside-entry")
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: true
        )
        try writeFile(outside.appendingPathComponent("payload.bin"), bytes: 8_192)

        let scanner = makeEphemeralTempScanner(root: world.root, home: world.home)
        let runtime = try makeEphemeralRuntime(scanner, home: world.home)
        let cleaner = runtime.makeCleaner(
            snapshot: sessionSnapshot(of: runtime.trustedContainerRoots)
        )

        // FORGED items: the scanner is first-level-only and can never emit a
        // root-level or outside-the-root target. They exist to prove that the
        // strict-descendant/deny family refuses them regardless of provenance
        // — an item's claim never widens admission.
        let canonicalRoot = canonical(world.root)
        let rootItem = removableItem(
            at: canonicalRoot, originContainer: canonicalRoot,
            displayName: "shared-temp",
            scannerID: EphemeralTempScanner.registeredID
        )
        let outsideItem = removableItem(
            at: outside, originContainer: canonicalRoot,
            displayName: "outside-entry",
            scannerID: EphemeralTempScanner.registeredID
        )

        let report = await cleaner.clean(
            items: [rootItem, outsideItem], moveToTrash: false
        )

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.root.path),
                      "a temp ROOT is never a deletion target")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: canonicalRoot.appendingPathComponent("old-scratch").path
            ),
            "refusing the root leaves its entries untouched"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        let log = logContents(home: world.home)
        XCTAssertTrue(log.contains("REFUSED [root-itself]"),
                      "the root refusal is logged with its typed classification, got: \(log)")
        XCTAssertTrue(log.contains("REFUSED [not-a-descendant]"),
                      "the outside-target refusal is logged with its typed classification, got: \(log)")
    }

    func testEphemeralTempTrashFailureIsItemKeyedWithNoPermanentFallback() async throws {
        let world = try makeEphemeralWorld("ephemeral-trash-failure")
        defer { try? FileManager.default.removeItem(at: world.base) }
        let bad = try stageStaleTempEntry("bad-scratch", under: world.root)
        let good = try stageStaleTempEntry("good-scratch", under: world.root)

        let scanner = makeEphemeralTempScanner(root: world.root, home: world.home)
        let items = await scannedTempItems(scanner)
        let badItem = try XCTUnwrap(items["bad-scratch"])
        let goodItem = try XCTUnwrap(items["good-scratch"])

        let runtime = try makeEphemeralRuntime(scanner, home: world.home)
        let recorder = TrashRecorder()
        let cleaner = runtime.makeCleaner(
            snapshot: sessionSnapshot(of: runtime.trustedContainerRoots),
            trashHandler: makeTrashSeam(
                into: world.trash, recorder: recorder,
                failingNames: ["bad-scratch"]
            )
        )

        let report = await cleaner.clean(
            items: [badItem, goodItem], moveToTrash: true
        )

        XCTAssertEqual(report.errors.count, 1, "the failed trash is ONE item error")
        XCTAssertEqual(report.errors.first?.key, badItem.key,
                       "the error is keyed to the item that failed, not the run")
        XCTAssertEqual(report.errors.first?.displayName, "bad-scratch")
        // THE contract: no fallthrough to a permanent delete.
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path),
                      "a trash failure NEVER falls through to permanent deletion")
        XCTAssertEqual(
            try Data(contentsOf: bad.appendingPathComponent("payload.bin")),
            payloadBytes(),
            "the failed item is left fully in place — not partially removed"
        )
        // Remaining items are unaffected.
        XCTAssertFalse(FileManager.default.fileExists(atPath: good.path))
        let recovered = try XCTUnwrap(try soleTrashedEntry(in: world.trash))
        XCTAssertTrue(recovered.lastPathComponent.hasSuffix("-good-scratch"),
                      "only the sibling reached the Trash")
        XCTAssertEqual(recorder.urls.count, 1)
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries.first?.itemID, goodItem.id)
        XCTAssertEqual(report.entries.first?.disposal, .trash)
        XCTAssertEqual(report.disposal, .trash)
    }

    func testEphemeralTempUndeletableEntryAmongNIsIsolatedAsExactlyOneError() async throws {
        // The EACCES-class stand-in. A real cross-user sticky-directory EPERM
        // needs a second uid and cannot be fixtured from one — but note the
        // asymmetry the epic pins (D8 r6 clause (d)): a DELETION failure under
        // a sticky root is the one place where operation semantics prove a
        // non-TCC cause, so a cleaner-side permission failure here is
        // legitimately permission-flavored, unlike a bare scan-time errno.
        try XCTSkipIf(geteuid() == 0, "chmod-based failure requires non-root")
        let world = try makeEphemeralWorld("ephemeral-undeletable")
        let locked = world.root.appendingPathComponent("locked-scratch")
        // ONE teardown path, ordered: the 0555 directory is restored to 0755
        // FIRST, because the recursive fixture removal cannot unlink a payload
        // inside it and would otherwise leak the whole temp tree. Registered
        // before the fixture is staged so an early throw still cleans up (both
        // calls are harmless no-ops against a path that never existed).
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path
            )
            try? FileManager.default.removeItem(at: world.base)
        }
        let keepA = try stageStaleTempEntry("aaa-scratch", under: world.root)
        try stageStaleTempEntry("locked-scratch", under: world.root)
        let keepB = try stageStaleTempEntry("zzz-scratch", under: world.root)

        // r-xr-xr-x AFTER backdating (chmod moves ctime, never mtime): the
        // entry stays readable — so the scanner still lists it — while its
        // payload can no longer be unlinked.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: locked.path
        )
        // Characterize the fixture rather than trusting it: the raw operation
        // underneath the cleaner's deletion fails EACCES for THIS user right
        // now, so the stand-in cannot silently degrade into a no-op.
        let lockedPayload = locked.appendingPathComponent("payload.bin")
        let probe = lockedPayload.path.withCString { unlink($0) }
        XCTAssertEqual(probe, -1, "the fixture must be undeletable")
        XCTAssertEqual(errno, EACCES, "the stand-in is the EACCES class")

        // CLASSIFY the failure independently, through the SAME operation the
        // cleaner performs, so the assertion below is locale-independent: the
        // deletion fails as Cocoa `NSFileWriteNoPermissionError` wrapping the
        // POSIX EACCES the probe just observed. This is what makes the item
        // error "classified" rather than merely non-empty.
        var independentFailure: NSError?
        do {
            try FileManager.default.removeItem(at: locked)
            XCTFail("the locked entry must not be removable")
        } catch {
            independentFailure = error as NSError
        }
        let classified = try XCTUnwrap(independentFailure)
        XCTAssertEqual(classified.domain, NSCocoaErrorDomain)
        XCTAssertEqual(classified.code, NSFileWriteNoPermissionError,
                       "the deletion failure is permission-classified")
        XCTAssertEqual(
            (classified.userInfo[NSUnderlyingErrorKey] as? NSError)?.code,
            Int(EACCES),
            "the Cocoa error carries the POSIX EACCES provenance"
        )

        let scanner = makeEphemeralTempScanner(root: world.root, home: world.home)
        let items = await scannedTempItems(scanner)
        XCTAssertEqual(items.count, 3, "all three entries are listed: \(items.keys)")
        let lockedItem = try XCTUnwrap(items["locked-scratch"])

        let runtime = try makeEphemeralRuntime(scanner, home: world.home)
        let cleaner = runtime.makeCleaner(
            snapshot: sessionSnapshot(of: runtime.trustedContainerRoots)
        )

        let report = await cleaner.clean(
            items: Array(items.values), moveToTrash: false
        )

        XCTAssertEqual(report.errors.count, 1,
                       "exactly one error for the undeletable entry: \(report.errors)")
        XCTAssertEqual(report.errors.first?.key, lockedItem.key)
        // The item error carries the PERMISSION-CLASSIFIED failure verbatim —
        // byte-identical to the independently classified NSError above, which
        // pins domain/code/underlying-errno without depending on the locale
        // any localized description is rendered in. A generic deletion error
        // (or an admission refusal) would not match.
        XCTAssertEqual(report.errors.first?.message,
                       classified.localizedDescription,
                       "the error text is the permission-classified deletion failure")
        XCTAssertEqual(report.entries.count, 2, "N−1 entries still deleted")
        for entry in report.entries {
            XCTAssertEqual(entry.disposal, .permanent)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: keepA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keepB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
        XCTAssertEqual(
            try Data(contentsOf: lockedPayload), payloadBytes(),
            "the undeletable entry is untouched, not partially removed"
        )
        // An operational deletion failure is NOT an admission refusal — the
        // guard never spoke here (the cleanup log's refusal grammar is
        // reserved for typed PathGuard refusals).
        XCTAssertFalse(logContents(home: world.home).contains("REFUSED"),
                       "a permission failure at delete time is not a guard refusal")
    }

    func testEphemeralTempItemRefusedWithoutTheProducingSessionSnapshot() async throws {
        let world = try makeEphemeralWorld("ephemeral-no-snapshot")
        defer { try? FileManager.default.removeItem(at: world.base) }
        let target = try stageStaleTempEntry("old-scratch", under: world.root)

        let scanner = makeEphemeralTempScanner(root: world.root, home: world.home)
        let items = await scannedTempItems(scanner)
        let item = try XCTUnwrap(items["old-scratch"])
        let runtime = try makeEphemeralRuntime(scanner, home: world.home)
        // FAIL-CLOSED: a cleaner holding no scan-session snapshot refuses
        // every `.removeItem` item — temp items included, no exemption.
        let cleaner = runtime.makeCleaner(snapshot: nil)

        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(report.errors.first?.key, item.key)
        XCTAssertTrue(
            report.errors.first?.message.contains(
                "no scan-session container snapshot"
            ) ?? false,
            "the refusal names the missing snapshot, got: \(report.errors)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(
            logContents(home: world.home).contains("REFUSED [container-unavailable]")
        )
    }

    func testEphemeralTempItemRefusedWhenTempRootIsReplacedAfterTheSnapshot() async throws {
        let world = try makeEphemeralWorld("ephemeral-stale-snapshot")
        defer { try? FileManager.default.removeItem(at: world.base) }
        try stageStaleTempEntry("old-scratch", under: world.root)

        let scanner = makeEphemeralTempScanner(root: world.root, home: world.home)
        let items = await scannedTempItems(scanner)
        let item = try XCTUnwrap(items["old-scratch"])
        let runtime = try makeEphemeralRuntime(scanner, home: world.home)
        let cleaner = runtime.makeCleaner(
            snapshot: sessionSnapshot(of: runtime.trustedContainerRoots)
        )

        // Temp roots churn by design, so the rm+mkdir shape is REAL here: the
        // root is replaced (new inode) at the same path after the capture and
        // the entry is moved back under it. Every path spelling still matches;
        // only the snapshot-bound identity does not.
        let fm = FileManager.default
        let canonicalRoot = canonical(world.root)
        let stashed = world.base.appendingPathComponent("stashed-root")
        try fm.moveItem(at: canonicalRoot, to: stashed)
        try fm.createDirectory(at: canonicalRoot, withIntermediateDirectories: false)
        let target = canonicalRoot.appendingPathComponent("old-scratch")
        try fm.moveItem(at: stashed.appendingPathComponent("old-scratch"), to: target)

        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(report.errors.first?.key, item.key)
        XCTAssertTrue(fm.fileExists(atPath: target.path),
                      "a stale snapshot refuses — it never deletes through the swapped root")
        XCTAssertTrue(
            logContents(home: world.home).contains("REFUSED [container-unavailable]")
        )
    }
}
