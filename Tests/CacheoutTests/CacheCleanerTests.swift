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
            let landed = trashDir.appendingPathComponent(
                "\(UUID().uuidString)-\(url.lastPathComponent)"
            )
            try FileManager.default.moveItem(at: url, to: landed)
            return landed
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
        let byName = XCTUniquelyKeyed(report.entries.map { ($0.displayName, $0) })
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

    // MARK: - D11 warning channel: the PURE presentation helper (fn-5.4)

    func testRowAnnotationsComposeTheDisposalMarkerAndTheEntryWarning() {
        // SwiftUI bodies are not unit-testable, so `rowAnnotations(for:)` IS
        // the assertion surface (the house "Row presentation (testable)"
        // pattern) and `CleanupReportSheet` merely renders what it returns.
        let plain = CleanupReport.Entry(
            itemID: "wt", scannerID: "git_worktrees", displayName: "wt",
            exactBytes: 4096, estimatedUpToBytes: 0, disposal: .permanent
        )
        XCTAssertNil(plain.warning, "the field defaults to nil — additive")
        let warned = CleanupReport.Entry(
            itemID: "wt", scannerID: "git_worktrees", displayName: "wt",
            exactBytes: 4096, estimatedUpToBytes: 0, disposal: .permanent,
            warning: "prune skipped — orphaned admin data remains"
        )

        // (a) nothing to say.
        XCTAssertEqual(
            CleanupReport(disposal: .permanent, entries: [plain], errors: [])
                .rowAnnotations(for: plain),
            []
        )
        // (b) the D11 warning alone, in a matching-disposal run.
        XCTAssertEqual(
            CleanupReport(disposal: .permanent, entries: [warned], errors: [])
                .rowAnnotations(for: warned),
            ["prune skipped — orphaned admin data remains"]
        )
        // (c) the disposal honesty marker alone.
        XCTAssertEqual(
            CleanupReport(disposal: .trash, entries: [plain], errors: [])
                .rowAnnotations(for: plain),
            ["erased permanently — not in Trash"]
        )
        // (d) BOTH, in pinned order — neither annotation may swallow the
        // other: a Trash run whose git-removal entry was erased permanently
        // AND left admin data behind has two true things to say.
        XCTAssertEqual(
            CleanupReport(disposal: .trash, entries: [warned], errors: [])
                .rowAnnotations(for: warned),
            [
                "erased permanently — not in Trash",
                "prune skipped — orphaned admin data remains",
            ]
        )
        // An empty warning string is not an annotation.
        let blank = CleanupReport.Entry(
            itemID: "wt", scannerID: "git_worktrees", displayName: "wt",
            exactBytes: 1, estimatedUpToBytes: 0, disposal: .permanent,
            warning: ""
        )
        XCTAssertEqual(
            CleanupReport(disposal: .permanent, entries: [blank], errors: [])
                .rowAnnotations(for: blank),
            []
        )
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
        let byID = XCTUniquelyKeyed(report.entries.map { ($0.itemID, $0) })
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

    // MARK: - A4 (PR #460 codex r13): the `.noDirectoryTree` verdict, at the
    // CLEANER, on the TRASH arm — the combination with zero cells before r13
    //
    // `grep -c noDirectoryTree Tests/CacheoutTests/CacheCleanerTests.swift`
    // returned 0 at 0139713, and the only cleaner-level `.noDirectoryTree`
    // cell anywhere in the suite drives `moveToTrash: false` — the PERMANENT
    // arm. That gap is what hid A: `dispose(_:expecting:…)`'s
    // `.noDirectoryTree` path never opened `admittedParent`, and the verdict
    // carries no identity, so both of its proofs reduced to "some
    // non-directory answers to this name".

    /// A sweep fixture whose ENTRY IS A REGULAR FILE — the shape that makes
    /// `OrphanedCachesScanner`'s revalidator answer `.noDirectoryTree`: its
    /// root open is `O_DIRECTORY`, a file answers `ENOTDIR`, and the probe
    /// reports "no directory tree of ours is here" with no identity to carry.
    ///
    /// The leaf name is UNIQUE per run so the real-Trash cell below can name
    /// its own landing and remove exactly that.
    private func makeNoTreeSweepFixture(
        _ label: String = #function, bytes: Int = 4096
    ) throws -> (home: URL, caches: URL, entry: URL, snapshot: ContainerSnapshot) {
        let home = try makeTempDir(label)
        let caches = home.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(
            at: caches, withIntermediateDirectories: true
        )
        let entry = caches.appendingPathComponent(
            "cacheout-notree-\(UUID().uuidString.prefix(8))"
        )
        try writeFile(entry, bytes: bytes)
        return (home, caches, entry, sessionSnapshot(of: [caches]))
    }

    /// The item the cells below clean, spelled once.
    private func noTreeSweepItem(caches: URL, entry: URL) -> ReclaimableItem {
        makeRemoveItem(
            scannerID: OrphanedCachesScanner.registeredID,
            displayName: entry.lastPathComponent,
            origin: caches, target: entry,
            requiresRevalidation: true
        )
    }

    /// **THE P1, THROUGH THE PRODUCTION COMPOSITION** (PR #460 codex r13, A).
    ///
    /// Real `CacheCleaner`, real `OrphanedCachesScanner.preDeleteRevalidator`,
    /// real PathGuard admission, real `ContainerSnapshot`, `moveToTrash:
    /// true` — the GUI's shipped default. The seam performs the swap
    /// `trashItem`'s own URL resolution makes possible: the CONTAINER is
    /// replaced with a stranger's directory carrying a file of the same name,
    /// and the mover then moves whatever answers to the target's name.
    ///
    /// MEASURED AT 0139713 on this exact fixture: the stranger's file was
    /// trashed and the report read
    /// `entries=[… exactBytes: 4096, disposal: .trash], errors=[]`.
    ///
    /// The outcome now is the disclosed, honest one: the item is REFUSED —
    /// no entry, no bytes — and the stranger's file stays in the landing,
    /// because the rollback will not restore into a container it cannot
    /// prove. The error names the path it is at.
    func testTrashModeNoTreeVerdictRefusesAContainerSwappedInsideTheSeam()
        async throws
    {
        let (home, caches, entry, snapshot) = try makeNoTreeSweepFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let trashDir = home.appendingPathComponent("fixture-trash")
        try FileManager.default.createDirectory(
            at: trashDir, withIntermediateDirectories: true
        )
        let stash = home.appendingPathComponent("stash")
        let landed = trashDir.appendingPathComponent(entry.lastPathComponent)

        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot,
            preDeleteRevalidators: sweepRevalidators,
            trashHandler: { url in
                // TWO REAL `rename(2)`s, on the far side of every proof this
                // process can take before handing the URL over.
                try FileManager.default.moveItem(at: caches, to: stash)
                try FileManager.default.createDirectory(
                    at: caches, withIntermediateDirectories: true
                )
                try Data("stranger".utf8).write(
                    to: caches.appendingPathComponent(url.lastPathComponent)
                )
                try FileManager.default.moveItem(at: url, to: landed)
                return landed
            }
        )
        let report = await cleaner.clean(
            items: [noTreeSweepItem(caches: caches, entry: entry)],
            moveToTrash: true
        )

        XCTAssertTrue(
            report.entries.isEmpty,
            "a disposal that took a stranger's file must report NOTHING "
                + "freed: \(report.entries)"
        )
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(
            message.contains("the folder that HOLDS this path is no longer "
                                 + "the one the safety check admitted"),
            message
        )
        XCTAssertTrue(message.contains(landed.path),
                      "the refusal names where the item actually is: \(message)")
        XCTAssertEqual(
            try String(contentsOf: landed, encoding: .utf8), "stranger",
            "the disclosed residual: the wrongly-taken object stays in the "
                + "landing rather than being restored into a stranger's folder"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stash.appendingPathComponent(entry.lastPathComponent).path
            ),
            "our own file never left the folder it was inspected in"
        )
        // AND THE LOG SAYS WHICH THING CHANGED (A2's class, one disposal
        // over). `content-drift` says the item changed; this is the FOLDER,
        // and the permanent arm has tagged it `container-drift` since PR
        // #458. MUTATION: make `CacheCleaner.trashRefusalTag` return
        // `content-drift` unconditionally and this assertion fails.
        XCTAssertTrue(
            logContents(home: home).contains("REFUSED [container-drift]"),
            logContents(home: home)
        )
    }

    /// The same verdict and the same composition, with only the LEAF swapped
    /// inside the seam — the window the after-proof exists to catch, and the
    /// one it CAN catch once the disposal binds an object.
    ///
    /// The rollback can prove its destination here (the container never
    /// moved), so the wrongly-taken file is PUT BACK and the item refused.
    func testTrashModeNoTreeVerdictPutsBackALeafSwappedInsideTheSeam()
        async throws
    {
        let (home, caches, entry, snapshot) = try makeNoTreeSweepFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let trashDir = home.appendingPathComponent("fixture-trash")
        try FileManager.default.createDirectory(
            at: trashDir, withIntermediateDirectories: true
        )
        let landed = trashDir.appendingPathComponent(entry.lastPathComponent)

        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot,
            preDeleteRevalidators: sweepRevalidators,
            trashHandler: { url in
                try FileManager.default.removeItem(at: url)
                try Data("stranger".utf8).write(to: url)
                try FileManager.default.moveItem(at: url, to: landed)
                return landed
            }
        )
        let report = await cleaner.clean(
            items: [noTreeSweepItem(caches: caches, entry: entry)],
            moveToTrash: true
        )

        XCTAssertTrue(report.entries.isEmpty, "\(report.entries)")
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("has been PUT BACK"), message)
        XCTAssertEqual(
            try String(contentsOf: entry, encoding: .utf8), "stranger",
            "the object the Trash wrongly took is back at the original name"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: landed.path),
            "nothing is left in the Trash after a proved put-back"
        )
    }

    /// The GHOST TARGET, and the choice this round made about it.
    ///
    /// Through r12 an absent target satisfied `proveStanding`
    /// (`absenceProves: true` — a `.noDirectoryTree` verdict is a statement
    /// that no tree of ours was there, which an absence also satisfies) and
    /// the disposal produced its own `ENOENT`. `boundLeaf` throws
    /// `.posix(ENOENT)` one call earlier instead. Both are item-keyed POSIX
    /// errors and neither is a silent skip; this one additionally leaves the
    /// user's Trash UNTOUCHED, which the other cannot promise because it
    /// hands the NAME to `trashItem` and whatever answers to it a moment
    /// later is what gets taken.
    func testTrashModeRefusesANoTreeItemThatVanishedBeforeItCouldBeBound()
        async throws
    {
        let (home, caches, entry, snapshot) = try makeNoTreeSweepFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let recorder = TrashRecorder()
        let trashDir = home.appendingPathComponent("fixture-trash")
        try FileManager.default.createDirectory(
            at: trashDir, withIntermediateDirectories: true
        )
        let item = noTreeSweepItem(caches: caches, entry: entry)
        // Gone before the clean — the probe's ENOENT root open produces the
        // same `.noDirectoryTree` verdict a non-directory does.
        try FileManager.default.removeItem(at: entry)

        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot,
            preDeleteRevalidators: sweepRevalidators,
            trashHandler: makeTrashSeam(into: trashDir, recorder: recorder)
        )
        let report = await cleaner.clean(items: [item], moveToTrash: true)

        XCTAssertTrue(report.entries.isEmpty, "\(report.entries)")
        XCTAssertEqual(report.errors.count, 1, "an item-keyed error, never a "
                           + "silent skip")
        XCTAssertTrue(recorder.urls.isEmpty,
                      "the user's Trash is not disturbed for an item that "
                          + "was never there")
    }

    /// **THE SHIPPED SEAM, WITH NOTHING INJECTED** (PR #460 codex r13, A4).
    ///
    /// The r11-D4 note in `TrashDisposal.swift` recorded that `CacheCleaner`'s
    /// item-mode Trash disposal had ZERO coverage through the real
    /// `FileManager.trashItem` — every cell injected a landing in a fixture
    /// directory whose parent is freely openable, which is exactly the
    /// property that hid `~/.Trash`'s TCC denial for eight rounds, and the
    /// property that let A's `.noDirectoryTree` arm ship unbound. This cell
    /// closes it for the item arm on the identity-free verdict: the cleaner
    /// is built with NO `trashHandler`, so the mover is
    /// `FileManager.trashItem` landing in the user's REAL `~/.Trash`.
    ///
    /// It removes exactly the one item it put there — the entry name is
    /// unique per run, and `trashItem` only suffixes on collision, so the
    /// landing name is deterministic — and touches nothing else.
    func testTrashDefaultReallyTrashesANoTreeSweepItemIntoTheRealTrash()
        async throws
    {
        let (home, caches, entry, snapshot) = try makeNoTreeSweepFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = measured(entry).exactAllocatedBytes
        XCTAssertGreaterThan(expected, 0)

        let landing = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")
            .appendingPathComponent(entry.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: landing.path),
                       "the landing name must be free before the run")
        // Registered BEFORE the clean: this exact path is removed however the
        // cell ends. Only this path — never the Trash itself.
        addTeardownBlock {
            try? FileManager.default.removeItem(at: landing)
        }

        // NO `trashHandler`: the constructor's default is
        // `FileManager.trashItem`, which is what the GUI runs.
        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot,
            preDeleteRevalidators: sweepRevalidators
        )
        let report = await cleaner.clean(
            items: [noTreeSweepItem(caches: caches, entry: entry)],
            moveToTrash: true
        )

        XCTAssertEqual(
            report.errors.map(\.message), [],
            "the move SUCCEEDED — the file is in the Trash — so any refusal "
                + "here is a false one, which is the shape of the r10 D1 "
                + "defect this seam is the only place to catch"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path),
                       "the entry left the cache folder")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: landing.path, isDirectory: &isDirectory
            ),
            "…and it is in the REAL Trash at \(landing.path), recoverable in "
                + "one drag — which is what the report must not deny"
        )
        XCTAssertFalse(isDirectory.boolValue)
        let entryRow = try XCTUnwrap(report.entries.first)
        XCTAssertEqual(entryRow.disposal, .trash)
        XCTAssertEqual(entryRow.exactBytes, expected)
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
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let (home, caches, entry, snapshot) = try makeSweepFixture()
        defer { try? FileManager.default.removeItem(at: home) }

        // Recreate the entry around a branch the probe cannot READ. Depth
        // no longer truncates anything (the entry budget is the one bound,
        // and it is deterministic — a bound-shaped refusal no retry could
        // ever clear is exactly what was removed), so the remaining
        // fail-closed causes are genuine obstructions like this one: the
        // pre-delete probe cannot prove the absence of user data, and an
        // inspection that could not finish is treated like a change.
        try FileManager.default.removeItem(at: entry)
        let locked = entry.appendingPathComponent("locked-sub")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let survivor = locked.appendingPathComponent("hidden.bin")
        try writeFile(survivor, bytes: 1024)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path
            )
        }

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
        XCTAssertTrue(message.contains("couldn't fully inspect"), message)
        XCTAssertFalse(
            message.contains("re-scan required"),
            "a bare retry does not clear a permission obstruction, so "
                + "prescribing one alone is misleading: \(message)"
        )
        // Cause-specific guidance (PR #458 review): this obstruction is
        // clearable by a GRANT, so the message must say so and must not
        // claim the verdict is permanent.
        XCTAssertTrue(message.contains("granting access"), message)
        XCTAssertFalse(message.contains("will not clear"), message)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: locked.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.path),
                      "content behind the uninspectable branch survives")
        XCTAssertTrue(logContents(home: home).contains("REFUSED [content-drift]"))
    }

    /// The mirror-image harm the PR #458 review named: a TRANSIENT
    /// obstruction — a mid-walk race, an I/O error — must not be reported as
    /// a deterministic verdict. Telling a user "re-scanning reports the same
    /// thing every time" over a disk hiccup steers them onto the riskier
    /// explicit-per-item-confirmation path for no reason.
    func testTransientProbeFailureAtDeleteTimeKeepsRetryGuidance() async throws {
        let (home, caches, entry, snapshot) = try makeSweepFixture()
        defer { try? FileManager.default.removeItem(at: home) }

        let child = entry.appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            at: child, withIntermediateDirectories: true
        )
        // The child's kind probe fails with EIO — the hermetic stand-in for
        // a transient failure or a directory that changed under the walk.
        let provider = FailingChildKindProvider()
        provider.failures[child.standardizedFileURL.path] = EIO

        let item = makeRemoveItem(
            scannerID: OrphanedCachesScanner.registeredID,
            displayName: entry.lastPathComponent,
            origin: caches, target: entry,
            requiresRevalidation: true
        )
        // The revalidator is registered with the SAME injected provider the
        // cleaner holds (fn-4.8 seam): the probe now belongs to the scanner's
        // declared revalidator rather than to a scanner-id branch inside the
        // cleaner, so a hermetic probe failure has to be injected where the
        // probe actually runs.
        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot,
            preDeleteRevalidators: [
                OrphanedCachesScanner.registeredID:
                    OrphanedCachesScanner.preDeleteRevalidator(
                        provider: provider
                    )
            ],
            provider: provider
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty, "fail-closed is untouched")
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("couldn't fully inspect"), message)
        XCTAssertTrue(message.contains("temporary error"), message)
        XCTAssertTrue(message.contains("Re-scan and try again."), message)
        XCTAssertFalse(
            message.contains("will not clear"),
            "a transient failure is cleared by a re-scan — calling it "
                + "deterministic is exactly backwards: \(message)"
        )
        XCTAssertFalse(
            message.contains("explicit per-item confirmation"),
            "and it must not steer the user to the riskier path: \(message)"
        )
    }

    /// Fails a chosen path's kind probe with a chosen errno.
    private final class FailingChildKindProvider: FileSystemIdentityProvider {
        var failures: [String: Int32] = [:]

        override func probeKind(of url: URL) -> KindProbe {
            if let code = failures[url.standardizedFileURL.path] {
                return .failed(errno: code)
            }
            return super.probeKind(of: url)
        }

        /// The probe's per-entry syscall is DESCRIPTOR-RELATIVE now (PR #458
        /// review, ancestor swap): `logical` is the spelling the walk
        /// believes it is at, which production ignores and a test injects
        /// on.
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

    // MARK: - The stranding class that moved to the deletion (PR #458 review)

    /// A chain of `levels` directories built with `mkdirat` — the ONLY way
    /// one past `PATH_MAX` can exist. Holds two descriptors at a time.
    private func makeDeepChain(
        under root: URL, name: String, levels: Int
    ) throws -> Int32 {
        var current = root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard current >= 0 else { throw XCTSkip("open failed: \(errno)") }
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

    /// THE defect, end to end, through the production cleaner.
    ///
    /// Making the probe descriptor-relative let INSPECTION read past
    /// `PATH_MAX` while the deletion stayed on `FileManager.removeItem`, so
    /// the app began manufacturing items that were provably clean and
    /// permanently undeletable. Measured on this exact fixture shape at
    /// depths 446 / 600 / 2000 / 4000 (threshold exactly `PATH_MAX`):
    ///
    /// - probe `complete=true, obstructions=[]`;
    /// - sizer `itemCount=0, exact=0, denials=1`;
    /// - `removeItem` NSCocoaErrorDomain 514 / ENAMETOOLONG in 0.03 s.
    ///
    /// The sizer denial forces the item off `.safe`, so
    /// `automaticCleanEligible` is false and the ONLY remaining route is
    /// explicit per-item confirmation — which re-enters `removeGuardedItem`
    /// and fails identically, forever, blaming a file name that was never
    /// the problem. BOTH routes are asserted here, because the auto route is
    /// what a leak-tier entry takes and the confirmation route is what this
    /// one is actually forced onto.
    func testSweepItemPastPathMaxIsDeletedByBothRoutes() async throws {
        for autoEligible in [false, true] {
            let (home, caches, entry, snapshot) =
                try makeSweepFixture("pastPathMax-\(autoEligible)")
            defer {
                let rm = Process()
                rm.executableURL = URL(fileURLWithPath: "/bin/rm")
                rm.arguments = ["-rf", home.path]
                try? rm.run()
                rm.waitUntilExit()
            }

            let levels = 600
            let deepest = try makeDeepChain(
                under: entry, name: "d", levels: levels
            )
            let leaf = openat(deepest, "payload.bin", O_CREAT | O_WRONLY, 0o644)
            XCTAssertGreaterThanOrEqual(leaf, 0)
            if leaf >= 0 {
                var bytes = [UInt8](repeating: 0xAB, count: 8192)
                XCTAssertEqual(write(leaf, &bytes, 8192), 8192)
                close(leaf)
            }
            close(deepest)

            // The fixture's own precondition: this tree is genuinely past
            // what an absolute path can address.
            var spelled = entry.path
            for _ in 0..<levels { spelled += "/d" }
            let byPath = spelled.withCString { open($0, O_RDONLY | O_DIRECTORY) }
            if byPath >= 0 { close(byPath) }
            XCTAssertEqual(byPath, -1, "fixture is not actually past PATH_MAX")

            // What the two halves of the core say about it, INDEPENDENTLY
            // measured — the probe reaches it, the sizer does not, and that
            // asymmetry is exactly what stranded the item.
            let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
                at: entry, provider: FileSystemIdentityProvider(),
                entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit,
                descriptorWindow: OrphanedCachesScanner.defaultDescriptorWindow()
            )
            XCTAssertTrue(probe.complete, "\(probe.obstructions)")
            XCTAssertEqual(probe.obstructions, [])
            let sized = DirectorySizer().measure(at: entry, mode: .deletionTarget)
            XCTAssertEqual(sized.denials.map(\.kind), [.unaddressablePath],
                           "the sizer still cannot measure it — stated residual")

            let item = makeRemoveItem(
                scannerID: OrphanedCachesScanner.registeredID,
                displayName: entry.lastPathComponent,
                origin: caches, target: entry, autoEligible: autoEligible
            )
            let cleaner = CacheCleaner(
                home: home, containerRoots: [caches],
                containerSnapshot: snapshot
            )
            let report = await cleaner.clean(items: [item], moveToTrash: false)

            XCTAssertEqual(
                report.errors.map(\.message), [],
                "a tree `rm -rf` removes in under a second must not be "
                    + "refused forever with a message about an invalid file "
                    + "name (autoEligible: \(autoEligible))"
            )
            XCTAssertEqual(report.entries.count, 1)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: entry.path),
                "the entry must be gone (autoEligible: \(autoEligible))"
            )
            // RESIDUAL, ASSERTED SO IT CANNOT BE FORGOTTEN: `DirectorySizer`
            // is still path-based, so it counts only what it can reach —
            // here the 4 KiB `payload.bin` at the top and NOT the 8 KiB one
            // 600 levels down. The deletion is honest; the accounting
            // under-reports, and the item carries a denial saying so.
            XCTAssertEqual(report.entries.first?.exactBytes, 4096,
                           "the deep payload's 8 KiB is not counted")
        }
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
        XCTAssertEqual(second.errors.first?.key, try XCTUnwrapElement(marked, 2).key)
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
        let byID = XCTUniquelyKeyed(report.entries.map { ($0.itemID, $0) })
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
            try XCTUnwrapElement(rollups, 0).exactBytes,
            fixtureEntries.reduce(0) { $0 + $1.exactBytes }
        )
        XCTAssertEqual(
            try XCTUnwrapElement(rollups, 0).estimatedUpToBytes,
            fixtureEntries.reduce(0) { $0 + $1.estimatedUpToBytes }
        )
        XCTAssertEqual(try XCTUnwrapElement(rollups, 0).entryCount, 2)
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
        return XCTUniquelyKeyed(outcome.items.map { ($0.displayName, $0) })
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

        // D1 AS CORRECTED (PR #459 review r1). The comment that stood here
        // said these three facts routed temp items "around the delete-time
        // revalidation seam entirely". Only the third conjunct ever did that,
        // and it is now gone: `automaticCleanEligible` is never read by the
        // dispatch (`CacheCleaner.preDeleteOutcome` keys on `scannerID` and
        // the marker), it is the CLI smart-clean exclusion. Temp items now
        // carry the marker and the scanner declares a revalidator, so they go
        // THROUGH the seam and the allow carries a descriptor-proven binding
        // for BOTH kinds — `.directory(identity)` here, `.nonDirectoryLeaf`
        // for a regular-file entry (PR #459 review r5: until the leaf case
        // existed, the file arm carried no binding and this sentence was
        // false for it).
        XCTAssertFalse(item.automaticCleanEligible,
                       "the CLI smart-clean exclusion — not a revalidation fact")
        XCTAssertTrue(item.requiresPreDeleteRevalidation)
        XCTAssertNotNil(scanner.preDeleteRevalidator)

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

    // MARK: - PR #459 review r1: the delete-time revalidation of temp items
    //
    // Every cell below stages a drift BETWEEN the scan and the clean — the
    // window the GUI leaves wide open, because `CacheoutViewModel.clean()`
    // passes the selected items straight through and only re-scans AFTER the
    // deletion. Before this fix nothing in the cleaner re-read one fact about
    // a temp entry's CONTENT: the four gates that made deletion acceptable
    // (ownership, the two-stage staleness rule, the cooperative lock probe,
    // the freshness re-check) all ran at scan time and none re-ran, and the
    // `nil` revalidator additionally left `probedObject` nil, which skipped
    // the leaf identity proof and routed the GUI's DEFAULT Trash disposal to
    // the identity-blind overload.
    //
    // SEVERITY, stated exactly: this is a DELETION-SAFETY defect (a tree that
    // was in use again, or that the app never inspected, was destroyed), not
    // merely a disclosure one — which is why the assertions below are about
    // what survives on disk, not about what a row says.

    /// A modification instant that is FRESH against the injected clock. Real
    /// wall-clock time is far in the PAST of `ephemeralClock`, so a file
    /// merely written "now" reads as months old here — every fresh fixture
    /// must say so explicitly.
    private var ephemeralFreshDate: Date {
        ephemeralClock.addingTimeInterval(-3_600)
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path
        )
    }

    /// CONTENT DRIFT, the deep case: the session resumes and writes live work
    /// into a SUBDIRECTORY, so the entry's own mtime is untouched and only a
    /// walk below it can see the change. This is the arm the descriptor-
    /// relative fresh-content walk carries.
    func testEphemeralTempEntryWithFreshContentWrittenAfterTheScanIsRefused()
        async throws {
        let world = try makeEphemeralWorld("ephemeral-content-drift")
        defer { try? FileManager.default.removeItem(at: world.base) }
        let target = try stageStaleTempEntry("old-scratch", under: world.root)
        let nested = target.appendingPathComponent("nested")
        try FileManager.default.createDirectory(
            at: nested, withIntermediateDirectories: true
        )
        try backdateTree(target, to: ephemeralClock.addingTimeInterval(-30 * 86_400))

        let scanner = makeEphemeralTempScanner(root: world.root, home: world.home)
        let items = await scannedTempItems(scanner)
        let item = try XCTUnwrap(items["old-scratch"],
                                 "the stale entry must be listed to be deleted")

        // THE DRIFT. A fresh file lands two levels down; `nested` and the
        // entry itself are put back to their old mtimes, so nothing but a
        // content walk can tell.
        let fresh = nested.appendingPathComponent("live-work.bin")
        try Data(repeating: 0x5A, count: 4_096).write(to: fresh)
        try setModified(fresh, ephemeralFreshDate)
        try setModified(nested, ephemeralClock.addingTimeInterval(-30 * 86_400))
        try setModified(target, ephemeralClock.addingTimeInterval(-30 * 86_400))

        let runtime = try makeEphemeralRuntime(scanner, home: world.home)
        let recorder = TrashRecorder()
        let cleaner = runtime.makeCleaner(
            snapshot: sessionSnapshot(of: runtime.trustedContainerRoots),
            trashHandler: makeTrashSeam(into: world.trash, recorder: recorder)
        )

        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertEqual(report.errors.count, 1,
                       "the drift is ONE item-keyed refusal: \(report.errors)")
        XCTAssertEqual(report.errors.first?.key, item.key)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("fresh content"), message)
        XCTAssertTrue(message.contains("live-work.bin"), message)
        XCTAssertTrue(report.entries.isEmpty,
                      "nothing may be billed as freed: \(report.entries)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "the live work written after the scan survives")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    /// OWN-MTIME DRIFT: the entry itself is written into, which bumps its own
    /// mtime — the required half of the two-stage staleness rule, re-read from
    /// the HELD DESCRIPTOR rather than from the path.
    func testEphemeralTempEntryTouchedAfterTheScanIsRefused() async throws {
        let world = try makeEphemeralWorld("ephemeral-own-mtime-drift")
        defer { try? FileManager.default.removeItem(at: world.base) }
        let target = try stageStaleTempEntry("old-scratch", under: world.root)

        let scanner = makeEphemeralTempScanner(root: world.root, home: world.home)
        let items = await scannedTempItems(scanner)
        let item = try XCTUnwrap(items["old-scratch"])

        try setModified(target, ephemeralFreshDate)

        let runtime = try makeEphemeralRuntime(scanner, home: world.home)
        let cleaner = runtime.makeCleaner(
            snapshot: sessionSnapshot(of: runtime.trustedContainerRoots)
        )

        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertEqual(report.errors.count, 1, "\(report.errors)")
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("newer than the staleness threshold"),
                      message)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("payload.bin").path
        ), "the re-activated entry is left whole")
    }

    /// REPLACEMENT: the entry is renamed away and a NEW directory takes its
    /// name, holding a tree the app never inspected. Both disposal arms must
    /// refuse, and the Trash arm must refuse BEFORE the mover is touched —
    /// `recorder.urls.isEmpty` is the load-bearing assertion for that.
    ///
    /// THE REPLACEMENT IS DELIBERATELY STALE, UNLOCKED AND OURS (PR #459
    /// review r2). Round 1's fixture backdated nothing — it stamped the
    /// stranger's tree with `ephemeralFreshDate`, so the OWN-MTIME gate
    /// refused it and this cell passed while the revalidator compared no
    /// identity at all: the test NAME claimed more than the code did. Staged
    /// old, all four property gates (ownership, own-mtime staleness, `flock`,
    /// fresh content below) PASS on the replacement, so only the
    /// recorded-identity comparison can refuse it — which is what makes this
    /// cell measure the property it is named for.
    func testEphemeralTempEntryReplacedAfterTheScanIsRefusedOnBothArms()
        async throws {
        for moveToTrash in [false, true] {
            let world = try makeEphemeralWorld(
                "ephemeral-replaced-\(moveToTrash)"
            )
            defer { try? FileManager.default.removeItem(at: world.base) }
            let target = try stageStaleTempEntry("old-scratch", under: world.root)

            let scanner = makeEphemeralTempScanner(
                root: world.root, home: world.home
            )
            let items = await scannedTempItems(scanner)
            let item = try XCTUnwrap(items["old-scratch"])

            // THE DRIFT: `rename(entry, entry.bak)` then a fresh `mkdir` at
            // the same name, filled with a stranger's live work.
            let stash = world.base.appendingPathComponent("moved-away")
            try FileManager.default.moveItem(at: target, to: stash)
            try FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: true
            )
            let stranger = target.appendingPathComponent("stranger.bin")
            try Data(repeating: 0x7E, count: 4_096).write(to: stranger)
            // OLD, not fresh: the replacement satisfies every property gate.
            let old = ephemeralClock.addingTimeInterval(-30 * 86_400)
            try setModified(stranger, old)
            try setModified(target, old)

            let runtime = try makeEphemeralRuntime(scanner, home: world.home)
            let recorder = TrashRecorder()
            let cleaner = runtime.makeCleaner(
                snapshot: sessionSnapshot(of: runtime.trustedContainerRoots),
                trashHandler: makeTrashSeam(into: world.trash, recorder: recorder)
            )

            let report = await cleaner.clean(
                items: [item], moveToTrash: moveToTrash
            )

            XCTAssertEqual(report.errors.count, 1,
                           "moveToTrash=\(moveToTrash): \(report.errors)")
            let message = try XCTUnwrap(report.errors.first?.message)
            XCTAssertTrue(
                message.contains("a different directory now stands at this "
                                 + "temp entry's name"),
                "the refusal must name the IDENTITY mismatch — every other "
                    + "gate passes on this fixture: \(message)"
            )
            XCTAssertTrue(report.entries.isEmpty,
                          "moveToTrash=\(moveToTrash): \(report.entries)")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: stranger.path),
                "moveToTrash=\(moveToTrash): the stranger's tree was destroyed"
            )
            XCTAssertTrue(recorder.urls.isEmpty,
                          "moveToTrash=\(moveToTrash): the refusal must land "
                            + "BEFORE the Trash mover is invoked")
            XCTAssertNil(try soleTrashedEntry(in: world.trash))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: stash.appendingPathComponent("payload.bin").path
                ),
                "moveToTrash=\(moveToTrash): the inspected tree is untouched too"
            )
        }
    }

    /// Wins the race the drift cells above LOSE: every PATH question — the
    /// container admission, the containment chain, and the cleaner's final
    /// `lstat` binding check — answers about the object that WAS there, and
    /// the deletion then opens the object that IS there. Only a question asked
    /// of the HELD DESCRIPTOR can refuse, and that question exists only
    /// because the revalidator's `.allow` now carries a `.directory(identity)`
    /// binding instead of `.unestablished`.
    ///
    /// Modelled on `OrphanedCachesScannerTests`'
    /// `testTargetReplacedAfterTheFinalPathCheckIsRefused`, which is the same
    /// race one scanner over.
    private final class TempRaceWonAtTheFinalCheckProvider:
        FileSystemIdentityProvider {
        var target: URL!
        var stash: URL!
        var replacement: URL!
        private var armed = false
        /// The revalidation's own binding read has happened — everything after
        /// it is the window this fixture aims at.
        private var inspected = false
        private(set) var swapped = false
        private var frozen: Identity?

        func arm() { armed = true }

        override func identity(ofDescriptor descriptor: Int32) -> Identity? {
            inspected = true
            return super.identity(ofDescriptor: descriptor)
        }

        override func identity(of url: URL) -> Identity? {
            guard armed, inspected,
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
            // Every later path question answers about the object that WAS
            // there — which is exactly what a path check cannot notice.
            return frozen
        }
    }

    func testEphemeralTempTargetReplacedAfterTheFinalPathCheckIsRefused()
        async throws {
        let world = try makeEphemeralWorld("ephemeral-final-check-race")
        defer { try? FileManager.default.removeItem(at: world.base) }
        let target = try stageStaleTempEntry("old-scratch", under: world.root)

        let provider = TempRaceWonAtTheFinalCheckProvider()
        provider.target = canonical(world.root)
            .appendingPathComponent("old-scratch")
        provider.stash = world.base.appendingPathComponent("race-moved-away")
        let strangerTree = canonical(world.root)
            .appendingPathComponent("old-scratch/Pictures/Photos Library.photoslibrary")
        provider.replacement = strangerTree

        let clock = ephemeralClock
        let scanner = EphemeralTempScanner(
            roots: [EphemeralTempRoot(
                url: canonical(world.root),
                label: "Shared temp",
                cleanupEvidence: EphemeralTempRoots.sharedTempEvidence,
                writability: .worldWritable
            )],
            home: world.home,
            thresholds: ephemeralThresholds,
            provider: provider,
            now: { clock }
        )
        let runtime = try SpaceScannerRuntime(
            scanners: [scanner], categories: [], home: world.home,
            provider: provider
        )
        let items = await scannedTempItems(scanner)
        let item = try XCTUnwrap(items["old-scratch"])

        provider.arm()
        let cleaner = runtime.makeCleaner(
            snapshot: sessionSnapshot(of: runtime.trustedContainerRoots)
        )
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(provider.swapped, "the fixture never armed the swap")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: strangerTree.path),
            "the replacement's tree was DELETED — the deletion held a "
                + "descriptor and never asked it who it was"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: provider.stash.appendingPathComponent("payload.bin").path
            ),
            "and the inspected tree is untouched too"
        )
        XCTAssertTrue(report.entries.isEmpty,
                      "reported SUCCESS for a tree it never inspected: "
                        + "\(report.entries)")
        XCTAssertEqual(report.errors.count, 1, "\(report.errors)")
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("no longer the one that was inspected"),
                      message)
        _ = target
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
        // The item error carries the PERMISSION-CLASSIFIED failure, in the
        // DESCRIPTOR-RELATIVE remover's own words (PR #458 replaced
        // `FileManager.removeItem` here, so the text is no longer Cocoa's
        // localized sentence but `DepthSafeRemoval`'s `"<place>: <strerror>"`).
        //
        // Still locale-independent, and still the same three things pinned:
        // the errno is EACCES SPECIFICALLY — corroborated by both the raw
        // `unlink` probe and the independently classified NSError above, which
        // agree on the provenance — the failing object is NAMED, and the
        // rendering carries no depth suffix, so the failure is reported AT the
        // target rather than somewhere below it. A generic deletion error, a
        // different errno, or an admission refusal all produce different text.
        XCTAssertEqual(
            (classified.userInfo[NSUnderlyingErrorKey] as? NSError)?.code,
            Int(EACCES),
            "the independent classification still agrees the cause is EACCES"
        )
        // Spelled the way the SCANNER was fed the root — the canonical
        // `/private/var/…` form fn-6.1 hands production, not the `/var/…`
        // alias `makeTempDir` happens to return.
        let lockedCanonical = FileSystemIdentityProvider().canonicalize(locked)
        XCTAssertEqual(report.errors.first?.message,
                       "\(lockedCanonical.path): "
                           + "\(String(cString: strerror(EACCES)))",
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

    // MARK: - The folder that HOLDS the target (PR #458 review — the P1)

    /// Swaps a directory the cleaner never binds — the target's PARENT — at
    /// the one instant that matters: after the cleaner has read that folder's
    /// identity from a descriptor and before `removeItemConcurrently`'s queue
    /// hop hands a PATH to the deletion.
    ///
    /// The seam is the cleaner's own final container re-admission
    /// (`admitContainer` → `probeKind` of the container root, the third such
    /// question in the item pipeline — the first two belong to the admission
    /// above the sizer). Every mutation is a real `rename(2)`; the fixture is
    /// never more capable than a shell in the developer's projects folder.
    private final class SwapTheItemsParentAtTheHopProvider:
        FileSystemIdentityProvider, @unchecked Sendable {
        /// The container root the item was admitted under — the spelling this
        /// fixture COUNTS questions about, and deliberately does not touch.
        var container: URL!
        /// The directory that HOLDS the target. Nothing in the cleaner binds
        /// it: the snapshot binds `container`, and the target is a strict
        /// DESCENDANT of it.
        var parent: URL!
        /// Where that directory is renamed to.
        var parentMovedAway: URL!
        /// A stranger's directory, holding a tree with the target's own name.
        var stranger: URL!
        private var seen = 0
        private(set) var swapped = false

        override func probeKind(of url: URL) -> KindProbe {
            let answer = super.probeKind(of: url)
            guard url.standardizedFileURL.path
                    == container.standardizedFileURL.path else { return answer }
            seen += 1
            guard seen == 3, !swapped else { return answer }
            swapped = true
            XCTAssertEqual(rename(parent.path, parentMovedAway.path), 0,
                           "fixture: the target's parent is renamed away")
            XCTAssertEqual(rename(stranger.path, parent.path), 0,
                           "fixture: a stranger's directory takes its place")
            return answer
        }
    }

    /// A BINDING THAT DOES NOT REACH THE DESTRUCTIVE CALL IS NOT A BINDING.
    ///
    /// `DepthSafeRemoval` resolves exactly one path — the target's parent —
    /// and it resolves it on the far side of a queue hop measured at 0.095 /
    /// 0.097 / 0.126 ms. Nothing else in item mode binds that folder:
    /// `admitContainer` binds the container ROOT to the scan-session
    /// snapshot, and a target is a strict DESCENDANT, so for the ordinary
    /// `<container>/proj/artifacts` shape the directory the deletion actually
    /// opens (`proj`) was bound by NOTHING. This item also has no leaf
    /// binding — its scanner declares no `PreDeleteRevalidator`, so
    /// `preDeleteOutcome` yields `.unestablished` and `expecting:` is `nil`,
    /// which is the exact population residual #3 of `DepthSafeRemoval` named.
    ///
    /// Measured through this cleaner before the wiring: two real `rename(2)`s
    /// at the seam and the deletion emptied the STRANGER's `artifacts` —
    /// `precious.bin` gone, `entries=1`, `errors=[]`, SUCCESS reported for a
    /// tree the app had never looked at.
    func testAnItemWhoseParentIsSwappedAtTheQueueHopIsRefused() async throws {
        let home = try makeTempDir("home")
        let base = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: base)
        }
        let container = base.appendingPathComponent("projects")
        let parent = container.appendingPathComponent("proj")
        let target = parent.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: true
        )
        try writeFile(target.appendingPathComponent("ours.bin"))

        // The stranger: same-named tree, real content, one rename away from
        // standing exactly where the deletion is about to look.
        let stranger = base.appendingPathComponent("stranger")
        let precious = stranger
            .appendingPathComponent("artifacts/precious.bin")
        try FileManager.default.createDirectory(
            at: precious.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeFile(precious, bytes: 4096)

        let provider = SwapTheItemsParentAtTheHopProvider()
        provider.container = provider.canonicalize(container)
        provider.parent = parent
        provider.parentMovedAway = base.appendingPathComponent("proj-gone")
        provider.stranger = stranger

        let cleaner = CacheCleaner(
            home: home,
            containerRoots: [container],
            containerSnapshot: sessionSnapshot(of: [container]),
            provider: provider
        )
        let report = await cleaner.clean(
            items: [removableItem(
                at: target, originContainer: container, provider: provider
            )],
            moveToTrash: false
        )

        XCTAssertTrue(provider.swapped, "the fixture never performed the swap")
        // The stranger now answers to the target's parent path, which is
        // exactly why the deletion would have walked into it.
        let preciousAfterSwap = parent
            .appendingPathComponent("artifacts/precious.bin")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: preciousAfterSwap.path),
            "the STRANGER's tree was deleted — the deletion opened a path "
                + "nobody had bound and every descriptor-relative proof "
                + "below it then agreed, inside somebody else's folder"
        )
        XCTAssertTrue(
            report.entries.isEmpty,
            "reported SUCCESS for a tree it never admitted: \(report.entries)"
        )
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(
            message.contains(
                "the folder that holds this item is no longer the one the "
                    + "safety check admitted"
            ),
            message
        )
        XCTAssertTrue(
            logContents(home: home).contains("REFUSED [container-drift]"),
            "a container swap is a different event from a content swap and "
                + "the cleanup log must not blur them"
        )
    }

    /// Swaps a CATEGORY ROOT after its children have been enumerated, at the
    /// first question the per-child pipeline asks about a child — which is
    /// after the root's identity has been captured and before the queue hop.
    private final class SwapTheCategoryRootMidLoopProvider:
        FileSystemIdentityProvider, @unchecked Sendable {
        var child: URL!
        var root: URL!
        var rootMovedAway: URL!
        var stranger: URL!
        private(set) var swapped = false

        override func probeKind(of url: URL) -> KindProbe {
            guard !swapped,
                  url.standardizedFileURL.path
                      == child.standardizedFileURL.path
            else { return super.probeKind(of: url) }
            swapped = true
            XCTAssertEqual(rename(root.path, rootMovedAway.path), 0,
                           "fixture: the enumerated root is renamed away")
            XCTAssertEqual(rename(stranger.path, root.path), 0,
                           "fixture: a stranger's directory takes its place")
            return super.probeKind(of: url)
        }
    }

    /// CONTENTS MODE HAS NO LEAF BINDING AT ALL, SO THE CONTAINER BINDING IS
    /// THE ONLY ONE IT HAS.
    ///
    /// The per-child loop enumerates names out of one directory and then
    /// unlinks them out of whatever that directory's PATH leads to when the
    /// removal opens it, a queue hop later. `expecting:` is `nil` here by
    /// construction — contents mode runs no user-data probe — so before the
    /// wiring nothing whatsoever could notice the root being swapped: the
    /// stranger's identically-named child was deleted and its bytes reported
    /// as freed.
    func testContentsModeRefusesARootSwappedAfterItsChildrenWereEnumerated()
        async throws {
        let home = try makeTempDir("home")
        let base = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: base)
        }
        let root = base.appendingPathComponent("cache-root")
        let child = root.appendingPathComponent("entry")
        try FileManager.default.createDirectory(
            at: child, withIntermediateDirectories: true
        )
        try writeFile(child.appendingPathComponent("ours.bin"))

        let stranger = base.appendingPathComponent("stranger")
        let precious = stranger.appendingPathComponent("entry/precious.bin")
        try FileManager.default.createDirectory(
            at: precious.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeFile(precious, bytes: 4096)

        let provider = SwapTheCategoryRootMidLoopProvider()
        provider.child = child
        provider.root = root
        provider.rootMovedAway = base.appendingPathComponent("cache-root-gone")
        provider.stranger = stranger

        let category = makeCategory(at: root)
        let cleaner = CacheCleaner(
            home: home, containerRoots: [], provider: provider
        )
        let report = await cleaner.clean(
            items: categoryItems(
                [makeScanResult(category: category)],
                home: home, provider: provider
            ),
            moveToTrash: false
        )

        XCTAssertTrue(provider.swapped, "the fixture never performed the swap")
        // The stranger now answers to the category root's path.
        let preciousAfterSwap = root
            .appendingPathComponent("entry/precious.bin")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: preciousAfterSwap.path),
            "the STRANGER's child was deleted — a contents-mode deletion has "
                + "no leaf binding, so the container binding is the only "
                + "thing that can refuse here"
        )
        XCTAssertTrue(
            report.entries.isEmpty,
            "reported freed bytes for a stranger's tree: \(report.entries)"
        )
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(
            message.contains(
                "the folder that holds this item is no longer the one the "
                    + "safety check admitted"
            ),
            message
        )
        XCTAssertTrue(
            logContents(home: home).contains("REFUSED [container-drift]"),
            "one word for one event, whichever mode caught it"
        )
    }

    // MARK: - The SAME folder, on the disposal the GUI actually uses

    /// THE CONTAINER BINDING ON THE ARM MOST USERS TAKE (PR #458 review — the
    /// P1 three rounds of permanent-delete fixes left open).
    ///
    /// `CacheoutViewModel.moveToTrash` is `true` out of the box, so the two
    /// tests above bound the disposal MOST DELETIONS DO NOT USE. This is the
    /// item-mode twin of `testAnItemWhoseParentIsSwappedAtTheQueueHopIsRefused`
    /// — identical fixture, identical two real `rename(2)`s, one flag flipped
    /// — and before the fix the identical outcome the permanent arm used to
    /// produce: the STRANGER's `artifacts` moved to the Trash, `entries=1`
    /// carrying the byte count of the tree the app had actually measured, and
    /// `errors=[]`.
    ///
    /// The item carries NO leaf binding (`fixture_scanner` declares no
    /// `PreDeleteRevalidator`, so `preDeleteOutcome` yields `.unestablished`),
    /// which is exactly the population the container binding exists for.
    func testTrashModeRefusesAnItemWhoseParentIsSwappedBeforeTheDisposal()
        async throws {
        let home = try makeTempDir("home")
        let base = try makeTempDir()
        let trashDir = try makeTempDir("fake-trash")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: trashDir)
        }
        let container = base.appendingPathComponent("projects")
        let parent = container.appendingPathComponent("proj")
        let target = parent.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: true
        )
        try writeFile(target.appendingPathComponent("ours.bin"))

        let stranger = base.appendingPathComponent("stranger")
        let precious = stranger
            .appendingPathComponent("artifacts/precious.bin")
        try FileManager.default.createDirectory(
            at: precious.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeFile(precious, bytes: 4096)

        let provider = SwapTheItemsParentAtTheHopProvider()
        provider.container = provider.canonicalize(container)
        provider.parent = parent
        provider.parentMovedAway = base.appendingPathComponent("proj-gone")
        provider.stranger = stranger

        let recorder = TrashRecorder()
        let cleaner = CacheCleaner(
            home: home,
            containerRoots: [container],
            containerSnapshot: sessionSnapshot(of: [container]),
            provider: provider,
            trashHandler: makeTrashSeam(into: trashDir, recorder: recorder)
        )
        let report = await cleaner.clean(
            items: [removableItem(
                at: target, originContainer: container, provider: provider
            )],
            moveToTrash: true
        )

        XCTAssertTrue(provider.swapped, "the fixture never performed the swap")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: parent.appendingPathComponent(
                    "artifacts/precious.bin"
                ).path
            ),
            "the STRANGER's tree was moved to the TRASH — the disposal acted "
                + "on whatever answered to the path, with no binding at all"
        )
        XCTAssertTrue(
            recorder.urls.isEmpty,
            "the disposal ran: a container proof that cannot reach the mover "
                + "must refuse BEFORE anything reaches the Trash, got "
                + "\(recorder.urls)"
        )
        XCTAssertTrue(
            report.entries.isEmpty,
            "reported freed bytes for a stranger's tree: \(report.entries)"
        )
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(
            message.contains(
                "the folder that holds this item is no longer the one the "
                    + "safety check admitted"
            ),
            message
        )
        XCTAssertTrue(
            logContents(home: home).contains("REFUSED [container-drift]"),
            "one word for one event, whichever DISPOSAL caught it"
        )
    }

    /// CONTENTS MODE ON THE TRASH ARM HAS NO BINDING WHATSOEVER — the twin of
    /// `testContentsModeRefusesARootSwappedAfterItsChildrenWereEnumerated`,
    /// with `moveToTrash: true`.
    ///
    /// Contents mode runs no user-data probe, so `expecting:` is `nil` by
    /// construction; before the fix the Trash arm additionally ignored the
    /// container binding the permanent arm had just been given, so NOTHING
    /// could notice the enumerated root being swapped: the stranger's
    /// identically-named child went to the Trash and its bytes were reported
    /// as freed.
    func testTrashModeContentsRefusesARootSwappedAfterEnumeration()
        async throws {
        let home = try makeTempDir("home")
        let base = try makeTempDir()
        let trashDir = try makeTempDir("fake-trash")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: trashDir)
        }
        let root = base.appendingPathComponent("cache-root")
        let child = root.appendingPathComponent("entry")
        try FileManager.default.createDirectory(
            at: child, withIntermediateDirectories: true
        )
        try writeFile(child.appendingPathComponent("ours.bin"))

        let stranger = base.appendingPathComponent("stranger")
        let precious = stranger.appendingPathComponent("entry/precious.bin")
        try FileManager.default.createDirectory(
            at: precious.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeFile(precious, bytes: 4096)

        let provider = SwapTheCategoryRootMidLoopProvider()
        provider.child = child
        provider.root = root
        provider.rootMovedAway = base.appendingPathComponent("cache-root-gone")
        provider.stranger = stranger

        let recorder = TrashRecorder()
        let cleaner = CacheCleaner(
            home: home, containerRoots: [], provider: provider,
            trashHandler: makeTrashSeam(into: trashDir, recorder: recorder)
        )
        let report = await cleaner.clean(
            items: categoryItems(
                [makeScanResult(category: makeCategory(at: root))],
                home: home, provider: provider
            ),
            moveToTrash: true
        )

        XCTAssertTrue(provider.swapped, "the fixture never performed the swap")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("entry/precious.bin").path
            ),
            "the STRANGER's child was moved to the Trash — a contents-mode "
                + "disposal has no leaf binding, so the container binding is "
                + "the only thing that can refuse here, on EITHER arm"
        )
        XCTAssertTrue(
            recorder.urls.isEmpty,
            "the disposal ran: nothing may reach the Trash, got \(recorder.urls)"
        )
        XCTAssertTrue(
            report.entries.isEmpty,
            "reported freed bytes for a stranger's tree: \(report.entries)"
        )
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(
            message.contains(
                "the folder that holds this item is no longer the one the "
                    + "safety check admitted"
            ),
            message
        )
        XCTAssertTrue(
            logContents(home: home).contains("REFUSED [container-drift]"),
            "one word for one event, whichever DISPOSAL caught it"
        )
    }

    /// THE WINDOW NO PRE-CALL PROOF CAN REACH, ON THE UNBOUND POPULATION.
    ///
    /// `FileManager.trashItem(at:)` takes a URL and resolves it INSIDE itself,
    /// so the swap performed here — inside the disposal seam, which is exactly
    /// where production's own resolution happens — beats every proof taken
    /// before the call. The Trash is reversible by construction, so what
    /// closes the OUTCOME is the proof taken AFTER: what landed is compared
    /// with the leaf the cleaner bound UNDER the admitted container, and a
    /// mismatch is PUT BACK and refused.
    ///
    /// Before the fix this arm had no binding on either side: the stranger's
    /// tree stayed in the Trash and its bytes were reported as freed.
    func testTrashModeContentsPutsBackAChildTheDisposalTookWrongly()
        async throws {
        let home = try makeTempDir("home")
        let base = try makeTempDir()
        let trashDir = try makeTempDir("fake-trash")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: trashDir)
        }
        let root = base.appendingPathComponent("cache-root")
        let child = root.appendingPathComponent("entry")
        try FileManager.default.createDirectory(
            at: child, withIntermediateDirectories: true
        )
        try writeFile(child.appendingPathComponent("ours.bin"))
        let ourChildMovedAway = base.appendingPathComponent("entry-moved-away")
        // The stranger's tree, one rename away from standing at the child's
        // own name INSIDE the admitted (and still correct) container.
        let stranger = base.appendingPathComponent("stranger-entry")
        try FileManager.default.createDirectory(
            at: stranger, withIntermediateDirectories: true
        )
        try writeFile(
            stranger.appendingPathComponent("precious.bin"), bytes: 4096
        )

        let recorder = TrashRecorder()
        let cleaner = CacheCleaner(
            home: home, containerRoots: [],
            trashHandler: { url in
                // Real syscalls at the one instant no pre-call proof reaches:
                // after the binding, inside the disposal.
                try FileManager.default.moveItem(at: child, to: ourChildMovedAway)
                try FileManager.default.moveItem(at: stranger, to: child)
                recorder.record(url)
                let landed = trashDir
                    .appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: landed)
                return landed
            }
        )
        let report = await cleaner.clean(
            items: categoryItems(
                [makeScanResult(category: makeCategory(at: root))], home: home
            ),
            moveToTrash: true
        )

        XCTAssertEqual(recorder.urls.count, 1,
                       "the fixture never reached the disposal")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: child.appendingPathComponent("precious.bin").path
            ),
            "the wrongly-taken tree was left in the Trash — a disposal that "
                + "cannot be proved must be UNDONE, not merely reported"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: trashDir.appendingPathComponent("entry").path
            ),
            "and nothing of it may remain in the Trash"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ourChildMovedAway.path),
            "our own child is untouched wherever the fixture put it"
        )
        XCTAssertTrue(
            report.entries.isEmpty,
            "reported freed bytes for a tree it never bound: \(report.entries)"
        )
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(message.contains("PUT BACK"), message)
        XCTAssertTrue(message.contains("nothing was reported freed"), message)
    }

    /// Removes the child inside the ONE window between the container proof
    /// and the leaf bind — the `probeChild` that reads the leaf under the
    /// held container descriptor. A real `removeItem`, no sleeps.
    private final class VanishTheChildAtTheBindProvider:
        FileSystemIdentityProvider, @unchecked Sendable {
        var child: URL!
        private(set) var vanished = false

        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            let url = logical()
            if !vanished,
               url.standardizedFileURL.path
                   == child.standardizedFileURL.path {
                vanished = true
                try? FileManager.default.removeItem(at: child)
            }
            return super.probeChild(
                inDirectory: descriptor, named: name, logical: url
            )
        }
    }

    /// A LEAF THAT IS NOT THERE IS NOTHING TO BIND, AND UNBOUND IS REFUSED.
    ///
    /// The binding is taken under the proved container, so a child that
    /// vanishes in that window yields `.absent` — and the disposal must NOT
    /// go ahead unbound, because whatever answers to the name a moment later
    /// is precisely what the Trash would then take with nothing to prove it
    /// against. The refusal is the item-keyed `ENOENT` the disposal would
    /// have produced anyway; what it adds is that the Trash is never touched.
    func testTrashModeRefusesAChildThatVanishedBeforeItCouldBeBound()
        async throws {
        let home = try makeTempDir("home")
        let base = try makeTempDir()
        let trashDir = try makeTempDir("fake-trash")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: trashDir)
        }
        let root = base.appendingPathComponent("cache-root")
        let child = root.appendingPathComponent("entry")
        try FileManager.default.createDirectory(
            at: child, withIntermediateDirectories: true
        )
        try writeFile(child.appendingPathComponent("ours.bin"), bytes: 4096)

        let provider = VanishTheChildAtTheBindProvider()
        provider.child = child

        let recorder = TrashRecorder()
        let cleaner = CacheCleaner(
            home: home, containerRoots: [], provider: provider,
            trashHandler: makeTrashSeam(into: trashDir, recorder: recorder)
        )
        let report = await cleaner.clean(
            items: categoryItems(
                [makeScanResult(category: makeCategory(at: root))],
                home: home, provider: provider
            ),
            moveToTrash: true
        )

        XCTAssertTrue(provider.vanished, "the fixture never removed the child")
        XCTAssertTrue(
            recorder.urls.isEmpty,
            "a disposal with nothing to prove itself against must not run at "
                + "all, got \(recorder.urls)"
        )
        XCTAssertTrue(
            report.entries.isEmpty,
            "nothing may be reported freed: \(report.entries)"
        )
        XCTAssertEqual(report.errors.count, 1)
        let message = try XCTUnwrap(report.errors.first?.message)
        XCTAssertTrue(
            message.contains("No such file or directory"), message
        )
        XCTAssertTrue(message.contains(child.path), message)
    }

    // MARK: - The cleanup log's own open must not block (PR #459 review r4)

    /// A zero-record `.removeContents` item whose refusal is LOGGED — the
    /// cheapest deterministic path into `appendLog` (`clean()`'s step (3)
    /// "no-root-records" arm). Shared by the two FIFO cells below.
    private func loggedRefusalItem(under dir: URL) -> ReclaimableItem {
        makeItem(
            id: "zero-record-contents",
            records: [],
            action: .removeContents,
            admission: .category(makeCategory(at: dir, name: "log-fifo-cat"))
        )
    }

    /// AVAILABILITY (PR #459 review r4, the third blocking-`open` site): the
    /// cleanup log's `openat` is `O_WRONLY` and cannot carry `O_DIRECTORY`
    /// (it creates a regular file), so a FIFO planted at
    /// `~/.cacheout/cleanup.log` blocks the open until a READER appears —
    /// measured, the pre-fix flag set did not return in 2s. Every admission
    /// and refusal logs inside the `CacheCleaner` actor, so that block wedges
    /// the clean and every later message to the actor. `O_NONBLOCK` converts
    /// the no-reader open into ENXIO, which the best-effort log drops.
    func testAFIFOPlantedAtTheCleanupLogDoesNotWedgeTheClean() async throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let logDir = home.appendingPathComponent(".cacheout")
        try FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fifoPath = logDir.appendingPathComponent("cleanup.log").path
        guard mkfifo(fifoPath, 0o600) == 0 else {
            return XCTFail("mkfifo failed: \(String(cString: strerror(errno)))")
        }

        let item = loggedRefusalItem(under: home)
        let done = expectation(description: "clean returned")
        let cleaner = CacheCleaner(home: home, containerRoots: [])
        Task {
            let report = await cleaner.clean(items: [item], moveToTrash: false)
            XCTAssertEqual(report.errors.count, 1,
                           "the refusal itself must still surface")
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)

        var status = stat()
        XCTAssertEqual(lstat(fifoPath, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFIFO,
                       "the planted FIFO still stands — never replaced")
    }

    /// The kind gate, evidenced separately from the flag: with a READER
    /// holding the FIFO open, `O_WRONLY|O_NONBLOCK` SUCCEEDS (measured,
    /// `fstat` reports `S_IFIFO`) — so without the `fstat` regular-file gate
    /// the refusal line would stream into someone else's pipe. This cell
    /// holds a non-blocking reader and asserts the pipe stays EMPTY.
    func testTheCleanupLogNeverWritesIntoAFIFOEvenWithAReaderPresent() async throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let logDir = home.appendingPathComponent(".cacheout")
        try FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fifoPath = logDir.appendingPathComponent("cleanup.log").path
        guard mkfifo(fifoPath, 0o600) == 0 else {
            return XCTFail("mkfifo failed: \(String(cString: strerror(errno)))")
        }
        let readerFd = open(fifoPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard readerFd >= 0 else {
            return XCTFail("reader open failed: \(String(cString: strerror(errno)))")
        }
        defer { close(readerFd) }

        let item = loggedRefusalItem(under: home)
        let cleaner = CacheCleaner(home: home, containerRoots: [])
        let report = await cleaner.clean(items: [item], moveToTrash: false)
        XCTAssertEqual(report.errors.count, 1)

        // An empty pipe whose write side is closed reads 0 (EOF) — measured;
        // EAGAIN would need a live writer holding it open. Any positive count
        // is log text that leaked into the pipe.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let readCount = read(readerFd, &buffer, buffer.count)
        XCTAssertEqual(
            readCount, 0,
            "no bytes may enter the pipe — got \(max(readCount, 0)) bytes: "
                + String(decoding: buffer.prefix(max(readCount, 0)), as: UTF8.self)
        )
    }
}

// MARK: - The regular-file identity binding, proven at the DISPOSAL itself
// (PR #459 codex r5, P1).
//
// The temp revalidator's file arm verifies the candidate's (device, inode)
// on a held descriptor; since r5 the `.allow` CARRIES that identity
// (`.nonDirectoryLeaf`), and these four cells prove the disposal arms refuse
// a swap that lands PAST every earlier layer: after the revalidator's fd is
// closed, after the admitted-parent capture, and after the cleaner's final
// path check. The swap fires inside the disposal's own container proof —
// the last provider question before the leaf is acted on — so the ONLY
// thing that can catch it is the leaf binding under the proved parent
// (`DepthSafeRemoval`'s `ENOTDIR` `fstatat` comparison on the permanent
// arm, `TrashDisposal.dispose(_:expecting:…)`'s pre-move `boundLeaf`
// equality on the Trash arm). Before the fix this exact fixture destroyed
// the never-scanned replacement on both arms with success reported (the
// r5 investigation's reproduction, run against the unfixed tree).
extension CacheCleanerTests {

    private final class SwapAtTheDisposalContainerProofProvider:
        FileSystemIdentityProvider {
        var target: URL!
        var stash: URL!
        /// Creates whatever should stand at the target's name after the move.
        var plantReplacement: (() -> Void)!
        private var armed = false
        private var revalidatorGatesRan = false
        private var descriptorIdentityCallsAfterGates = 0
        private(set) var swapped = false

        func arm() {
            armed = true
            revalidatorGatesRan = false
            descriptorIdentityCallsAfterGates = 0
            swapped = false
        }

        /// The revalidator's ownership gate — the ONLY production caller of
        /// this accessor — marks that the file arm's identity comparison has
        /// already passed on the held descriptor.
        override func ownerUID(ofDescriptor fd: Int32) -> UInt32? {
            let real = super.ownerUID(ofDescriptor: fd)
            if armed { revalidatorGatesRan = true }
            return real
        }

        /// Descriptor-identity question #1 after the verdict returns is the
        /// cleaner's admitted-parent capture; #2 is the DISPOSAL's own
        /// container proof (`openAdmittedContainer`, reached through
        /// `DepthSafeRemoval.remove` on the permanent arm and
        /// `TrashDisposal.boundLeaf` on the Trash arm) — after the final
        /// path check. The swap lands there, for real; every answer is
        /// `super`'s real answer (the parent directory's identity is
        /// unchanged by a leaf swap, so the container proof rightly passes
        /// and the LEAF binding is the one guard left standing).
        override func identity(ofDescriptor descriptor: Int32) -> Identity? {
            if armed, revalidatorGatesRan {
                descriptorIdentityCallsAfterGates += 1
                if descriptorIdentityCallsAfterGates == 2, !swapped {
                    swapped = true
                    try? FileManager.default.moveItem(at: target, to: stash)
                    plantReplacement()
                }
            }
            return super.identity(ofDescriptor: descriptor)
        }
    }

    /// Shared fixture: one stale top-level regular FILE candidate, scanned by
    /// the real scanner, cleaned through the runtime-built cleaner, with the
    /// swap armed to fire at the disposal's container proof.
    private func runLateFileSwapClean(
        _ label: String,
        moveToTrash: Bool,
        plant: @escaping (URL) -> Void
    ) async throws -> (
        report: CleanupReport,
        target: URL,
        stash: URL,
        trash: URL,
        home: URL,
        provider: SwapAtTheDisposalContainerProofProvider,
        recorder: TrashRecorder
    ) {
        let world = try makeEphemeralWorld(label)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: world.base)
        }
        let rawTarget = world.root.appendingPathComponent("old-scratch.tmp")
        try writeFile(rawTarget, bytes: 8_192)
        try backdateTree(
            rawTarget, to: ephemeralClock.addingTimeInterval(-30 * 86_400)
        )
        let target = canonical(world.root)
            .appendingPathComponent("old-scratch.tmp")

        let provider = SwapAtTheDisposalContainerProofProvider()
        provider.target = target
        provider.stash = world.base.appendingPathComponent("moved-away.tmp")
        provider.plantReplacement = { plant(target) }

        let clock = ephemeralClock
        let scanner = EphemeralTempScanner(
            roots: [EphemeralTempRoot(
                url: canonical(world.root),
                label: "Shared temp",
                cleanupEvidence: EphemeralTempRoots.sharedTempEvidence,
                writability: .worldWritable
            )],
            home: world.home,
            thresholds: ephemeralThresholds,
            provider: provider,
            now: { clock }
        )
        let items = await scannedTempItems(scanner)
        let item = try XCTUnwrap(
            items["old-scratch.tmp"],
            "the stale file must scan as a candidate"
        )
        XCTAssertNotNil(item.scannedTargetIdentity,
                        "the scan records the file's identity")

        let runtime = try SpaceScannerRuntime(
            scanners: [scanner], categories: [], home: world.home,
            provider: provider
        )
        let recorder = TrashRecorder()
        let cleaner = runtime.makeCleaner(
            snapshot: sessionSnapshot(of: runtime.trustedContainerRoots),
            trashHandler: makeTrashSeam(into: world.trash, recorder: recorder)
        )

        provider.arm()
        let report = await cleaner.clean(
            items: [item], moveToTrash: moveToTrash
        )
        XCTAssertTrue(provider.swapped, "the fixture never fired the swap")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: provider.stash.path),
            "the SCANNED file sits untouched in the stash — whatever the "
                + "disposal was asked to take, it was not the scanned object"
        )
        return (report, target, provider.stash, world.trash, world.home,
                provider, recorder)
    }

    /// The one refusal shape all four cells assert: no entry, one item-keyed
    /// content-drift error, the replacement SURVIVING at the name, the Trash
    /// seam never reached.
    private func assertLateSwapRefused(
        _ outcome: (
            report: CleanupReport, target: URL, stash: URL, trash: URL,
            home: URL, provider: SwapAtTheDisposalContainerProofProvider,
            recorder: TrashRecorder
        ),
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertTrue(outcome.report.entries.isEmpty,
                      "SUCCESS was reported for an object nobody scanned: "
                        + "\(outcome.report.entries)", file: file, line: line)
        XCTAssertEqual(outcome.report.errors.count, 1,
                       "\(outcome.report.errors)", file: file, line: line)
        let message = try XCTUnwrap(outcome.report.errors.first?.message,
                                    file: file, line: line)
        XCTAssertTrue(message.contains("no longer the one that was inspected"),
                      message, file: file, line: line)
        XCTAssertTrue(logContents(home: outcome.home).contains("content-drift"),
                      "the cleanup log tags the event content-drift",
                      file: file, line: line)
        XCTAssertTrue(outcome.recorder.urls.isEmpty,
                      "the Trash seam was reached: \(outcome.recorder.urls)",
                      file: file, line: line)
        XCTAssertNil(try soleTrashedEntry(in: outcome.trash),
                     file: file, line: line)
    }

    /// PERMANENT ARM, regular-file replacement: refused by the `ENOTDIR`
    /// arm's `fstatat`-under-the-proved-parent comparison; the never-scanned
    /// replacement survives.
    func testEphemeralTempFileReplacedAtTheDisposalIsRefusedOnThePermanentArm()
    async throws {
        let replacementBytes = Data(repeating: 0x5A, count: 6_000)
        let outcome = try await runLateFileSwapClean(
            "late-swap-file-permanent", moveToTrash: false
        ) { target in
            try? replacementBytes.write(to: target)
        }
        try assertLateSwapRefused(outcome)
        XCTAssertEqual(
            try Data(contentsOf: outcome.target), replacementBytes,
            "the never-scanned replacement still stands at the name"
        )
    }

    /// TRASH ARM (the GUI default), regular-file replacement: refused by the
    /// pre-move `boundLeaf` identity comparison, BEFORE the move — the Trash
    /// is untouched.
    func testEphemeralTempFileReplacedAtTheDisposalIsRefusedOnTheTrashArm()
    async throws {
        let replacementBytes = Data(repeating: 0x5A, count: 6_000)
        let outcome = try await runLateFileSwapClean(
            "late-swap-file-trash", moveToTrash: true
        ) { target in
            try? replacementBytes.write(to: target)
        }
        try assertLateSwapRefused(outcome)
        XCTAssertEqual(
            try Data(contentsOf: outcome.target), replacementBytes,
            "the never-scanned replacement still stands at the name"
        )
    }

    /// PERMANENT ARM, symlink planted at the name: the user's link SURVIVES
    /// (it is not the scanned inode) and its target tree is never entered.
    func testEphemeralTempSymlinkPlantedAtTheDisposalIsRefusedOnThePermanentArm()
    async throws {
        var payload: URL!
        let outcome = try await runLateFileSwapClean(
            "late-swap-symlink-permanent", moveToTrash: false
        ) { target in
            let base = target.deletingLastPathComponent()
                .deletingLastPathComponent()
            let precious = base.appendingPathComponent("precious-docs")
            payload = precious.appendingPathComponent("thesis.txt")
            try? FileManager.default.createDirectory(
                at: precious, withIntermediateDirectories: true
            )
            try? Data(repeating: 0x42, count: 1_234).write(to: payload)
            try? FileManager.default.createSymbolicLink(
                at: target, withDestinationURL: precious
            )
        }
        try assertLateSwapRefused(outcome)
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: outcome.target.path
            ),
            "the planted link still stands at the name"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path),
                      "and its target tree is untouched")
    }

    /// TRASH ARM, symlink planted at the name: refused pre-move; the link
    /// survives, its target tree untouched, the Trash undisturbed.
    func testEphemeralTempSymlinkPlantedAtTheDisposalIsRefusedOnTheTrashArm()
    async throws {
        var payload: URL!
        let outcome = try await runLateFileSwapClean(
            "late-swap-symlink-trash", moveToTrash: true
        ) { target in
            let base = target.deletingLastPathComponent()
                .deletingLastPathComponent()
            let precious = base.appendingPathComponent("precious-docs")
            payload = precious.appendingPathComponent("thesis.txt")
            try? FileManager.default.createDirectory(
                at: precious, withIntermediateDirectories: true
            )
            try? Data(repeating: 0x42, count: 1_234).write(to: payload)
            try? FileManager.default.createSymbolicLink(
                at: target, withDestinationURL: precious
            )
        }
        try assertLateSwapRefused(outcome)
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: outcome.target.path
            ),
            "the planted link still stands at the name"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path),
                      "and its target tree is untouched")
    }
}
