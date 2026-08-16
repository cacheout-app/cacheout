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
        autoEligible: Bool = true
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
            isStale: nil
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
        autoEligible: Bool = true
    ) -> ReclaimableItem {
        makeItem(
            id: id, scannerID: scannerID, displayName: displayName,
            exact: exact, records: [makeRecord(target)], state: state,
            action: .removeItem,
            admission: .containerItem(
                originContainer: origin, requestedTargetURL: target
            ),
            autoEligible: autoEligible
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

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(
            results: [makeScanResult(category: makeCategory(at: tmp))],
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

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(
            results: [makeScanResult(category: makeCategory(at: tmp))],
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

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(results: [result], moveToTrash: false)

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

        let cleaner = CacheCleaner(home: home)
        let report = await cleaner.clean(
            results: [makeScanResult(category: category)],
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

    // MARK: - node_modules parallel deletion

    func testCleanNodeModulesParallelDeleteRemovesAll() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        var items: [NodeModulesItem] = []
        for i in 0..<12 {
            let projectDir = root.appendingPathComponent("proj-\(i)")
            let nm = projectDir.appendingPathComponent("node_modules")
            try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
            try writeFile(nm.appendingPathComponent("pkg.json"))
            items.append(NodeModulesItem(
                projectName: "proj-\(i)",
                projectPath: projectDir,
                nodeModulesPath: nm,
                sizeBytes: 16,
                lastModified: nil,
                originContainer: root,
                isSelected: true
            ))
        }

        let cleaner = CacheCleaner(
            containerRoots: [root], containerSnapshot: sessionSnapshot(of: [root])
        )
        let report = await cleaner.clean(results: [], nodeModules: items, moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.entries.count, items.count)
        for item in items {
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.nodeModulesPath.path),
                           "expected \(item.nodeModulesPath.path) removed")
        }
    }

    func testCleanNodeModulesIsolatesPerItemErrors() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Mix one missing path between two real ones — the item pipeline must
        // surface a single error and still clean the surviving items.
        let goodA = root.appendingPathComponent("a/node_modules")
        let goodB = root.appendingPathComponent("b/node_modules")
        try FileManager.default.createDirectory(at: goodA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: goodB, withIntermediateDirectories: true)
        try writeFile(goodA.appendingPathComponent("a.json"))
        try writeFile(goodB.appendingPathComponent("b.json"))

        let missing = root.appendingPathComponent("ghost/node_modules")

        let items: [NodeModulesItem] = [
            NodeModulesItem(projectName: "a", projectPath: goodA.deletingLastPathComponent(),
                            nodeModulesPath: goodA, sizeBytes: 16, lastModified: nil,
                            originContainer: root, isSelected: true),
            NodeModulesItem(projectName: "ghost", projectPath: missing.deletingLastPathComponent(),
                            nodeModulesPath: missing, sizeBytes: 16, lastModified: nil,
                            originContainer: root, isSelected: true),
            NodeModulesItem(projectName: "b", projectPath: goodB.deletingLastPathComponent(),
                            nodeModulesPath: goodB, sizeBytes: 16, lastModified: nil,
                            originContainer: root, isSelected: true),
        ]

        let cleaner = CacheCleaner(
            containerRoots: [root], containerSnapshot: sessionSnapshot(of: [root])
        )
        let report = await cleaner.clean(results: [], nodeModules: items, moveToTrash: false)

        XCTAssertEqual(report.errors.count, 1, "exactly one missing item should surface as error")
        XCTAssertEqual(report.errors.first?.displayName, "ghost")
        XCTAssertEqual(report.entries.count, 2, "the two real items should still be cleaned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: goodA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: goodB.path))
    }

    func testCleanNodeModulesUnselectedAreSkipped() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let kept = root.appendingPathComponent("kept/node_modules")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try writeFile(kept.appendingPathComponent("x"))

        let item = NodeModulesItem(
            projectName: "kept",
            projectPath: kept.deletingLastPathComponent(),
            nodeModulesPath: kept,
            sizeBytes: 16,
            lastModified: nil,
            originContainer: root,
            isSelected: false
        )

        let cleaner = CacheCleaner(
            containerRoots: [root], containerSnapshot: sessionSnapshot(of: [root])
        )
        let report = await cleaner.clean(results: [], nodeModules: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path),
                      "unselected items must not be touched")
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
        let cleaner = CacheCleaner()
        let report = await cleaner.clean(
            results: [makeScanResult(category: category)], moveToTrash: false
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
        let cleaner = CacheCleaner()
        let report = await cleaner.clean(
            results: [makeScanResult(category: category)], moveToTrash: false
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

        let cleaner = CacheCleaner(home: home)
        let report = await cleaner.clean(results: [denied], moveToTrash: false)

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

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(results: [partial], moveToTrash: false)

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

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(
            results: [makeScanResult(category: makeCategory(at: cacheRoot))],
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

    // MARK: - node_modules item mode (R1/R15)

    func testNodeModulesItemDeletesDirectoryItself() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("app")
        let nm = projectDir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try writeFile(nm.appendingPathComponent("dep.js"), bytes: 4096)
        let expected = measured(nm).exactAllocatedBytes

        let item = NodeModulesItem(
            projectName: "app", projectPath: projectDir, nodeModulesPath: nm,
            sizeBytes: 999, lastModified: nil, originContainer: root, isSelected: true
        )
        let cleaner = CacheCleaner(
            containerRoots: [root], containerSnapshot: sessionSnapshot(of: [root])
        )
        let report = await cleaner.clean(results: [], nodeModules: [item], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nm.path),
                       "item mode deletes the node_modules directory ITSELF")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.path),
                      "the project directory survives")
        XCTAssertEqual(report.entries.first?.exactBytes, expected,
                       "freed bytes are measured, not the pre-scan sizeBytes")
    }

    func testNodeModulesItemWithoutProvenanceIsRefused() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nm = root.appendingPathComponent("proj/node_modules")
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try writeFile(nm.appendingPathComponent("x.js"))

        let item = NodeModulesItem(
            projectName: "proj", projectPath: nm.deletingLastPathComponent(),
            nodeModulesPath: nm, sizeBytes: 16, lastModified: nil,
            originContainer: nil, isSelected: true
        )
        let cleaner = CacheCleaner(
            containerRoots: [root], containerSnapshot: sessionSnapshot(of: [root])
        )
        let report = await cleaner.clean(results: [], nodeModules: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nm.path),
                      "an item without origin-container provenance must not be deleted")
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
        let cleaner = CacheCleaner(home: home)
        let report = await cleaner.clean(
            results: [makeScanResult(category: category)], moveToTrash: false
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
            trashHandler: makeTrashSeam(into: trashDir, recorder: recorder)
        )
        let report = await cleaner.clean(
            results: [makeScanResult(category: makeCategory(at: home, name: "hostile"))],
            moveToTrash: true
        )

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(recorder.urls.isEmpty, "the trash primitive must never be invoked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUnconfiguredContainerBlocksNodeModulesItem() async throws {
        let configured = try makeTempDir("configured-container")
        let elsewhere = try makeTempDir("unconfigured-container")
        defer {
            try? FileManager.default.removeItem(at: configured)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let nm = elsewhere.appendingPathComponent("proj/node_modules")
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try writeFile(nm.appendingPathComponent("x.js"))

        let item = NodeModulesItem(
            projectName: "proj", projectPath: nm.deletingLastPathComponent(),
            nodeModulesPath: nm, sizeBytes: 16, lastModified: nil,
            originContainer: elsewhere, isSelected: true
        )
        let cleaner = CacheCleaner(
            containerRoots: [configured],
            containerSnapshot: sessionSnapshot(of: [configured])
        )
        let report = await cleaner.clean(results: [], nodeModules: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nm.path),
                      "an item under an unconfigured container must not be deleted")
    }

    func testCrossDeviceNodeModulesItemRefused() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let mountedProject = root.appendingPathComponent("mounted-proj")
        let nm = mountedProject.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try writeFile(nm.appendingPathComponent("x.js"))

        let provider = DeviceInjectingProvider()
        // The foreign device covers the project subtree, so the item is not
        // itself a mount point — only on the wrong device (R15 item mode).
        provider.overrides = [
            (provider.canonicalize(mountedProject).path, 0xBEEF)
        ]

        let item = NodeModulesItem(
            projectName: "mounted-proj", projectPath: mountedProject,
            nodeModulesPath: nm, sizeBytes: 16, lastModified: nil,
            originContainer: root, isSelected: true
        )
        let cleaner = CacheCleaner(
            containerRoots: [root],
            containerSnapshot: sessionSnapshot(of: [root], provider: provider),
            provider: provider
        )
        let report = await cleaner.clean(results: [], nodeModules: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nm.path),
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
        let cleaner = CacheCleaner(provider: provider)
        let report = await cleaner.clean(
            results: [makeScanResult(category: category)], moveToTrash: false
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
        let cleaner = CacheCleaner(provider: provider)
        let report = await cleaner.clean(
            results: [makeScanResult(category: category)], moveToTrash: false
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

    func testNestedMountBoundaryInsideNodeModulesItemRefused() async throws {
        // Item mode has the same shape: validateRemovableItem catches the
        // item ITSELF being a mount target, but not a mount nested beneath.
        let root = try makeTempDir("nested-mount-nm")
        defer { try? FileManager.default.removeItem(at: root) }
        let nm = root.appendingPathComponent("proj/node_modules")
        let inner = nm.appendingPathComponent("inner-mount")
        try FileManager.default.createDirectory(
            at: inner, withIntermediateDirectories: true
        )
        try writeFile(nm.appendingPathComponent("x.js"))
        try writeFile(inner.appendingPathComponent("payload.bin"))

        let provider = DeviceInjectingProvider()
        provider.mountPointPaths = [provider.canonicalize(inner).path]

        let item = NodeModulesItem(
            projectName: "proj", projectPath: nm.deletingLastPathComponent(),
            nodeModulesPath: nm, sizeBytes: 16, lastModified: nil,
            originContainer: root, isSelected: true
        )
        let cleaner = CacheCleaner(
            containerRoots: [root],
            containerSnapshot: sessionSnapshot(of: [root], provider: provider),
            provider: provider
        )
        let report = await cleaner.clean(
            results: [], nodeModules: [item], moveToTrash: false
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: nm.path),
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
        let cleaner = CacheCleaner(home: home)
        let report = await cleaner.clean(
            results: [makeScanResult(category: category)], moveToTrash: false
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
        let cleaner = CacheCleaner(home: home)
        let report = await cleaner.clean(
            results: [makeScanResult(category: category, size: 4096)],
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
        let cleaner = CacheCleaner(home: home)
        let report = await cleaner.clean(
            results: [makeScanResult(category: category, size: 2048)], moveToTrash: false
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
        let cleaner = CacheCleaner(home: home)
        let report = await cleaner.clean(
            results: [makeScanResult(category: category, size: 1024)],
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

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(
            results: [makeScanResult(category: makeCategory(at: cacheRoot))],
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
            trashHandler: makeTrashSeam(
                into: trashDir, recorder: recorder, failingNames: ["bad.bin"]
            )
        )
        let report = await cleaner.clean(
            results: [makeScanResult(category: makeCategory(at: cacheRoot))],
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

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(
            results: [makeScanResult(category: makeCategory(at: cacheRoot))],
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

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(
            results: [
                makeScanResult(category: exactCat),
                makeScanResult(category: linkCat),
                makeScanResult(category: cmdCat, size: 2048),
            ],
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

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(
            results: [makeScanResult(category: category, size: 2048)],
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

    func testTrashModeTrashesNodeModulesItemViaSeam() async throws {
        let root = try makeTempDir()
        let trashDir = try makeTempDir("fake-trash")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: trashDir)
        }
        let nm = root.appendingPathComponent("proj/node_modules")
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try writeFile(nm.appendingPathComponent("dep.js"), bytes: 4096)
        let expected = measured(nm).exactAllocatedBytes

        let recorder = TrashRecorder()
        let item = NodeModulesItem(
            projectName: "proj", projectPath: nm.deletingLastPathComponent(),
            nodeModulesPath: nm, sizeBytes: 16, lastModified: nil,
            originContainer: root, isSelected: true
        )
        let cleaner = CacheCleaner(
            containerRoots: [root],
            containerSnapshot: sessionSnapshot(of: [root]),
            trashHandler: makeTrashSeam(into: trashDir, recorder: recorder)
        )
        let report = await cleaner.clean(results: [], nodeModules: [item], moveToTrash: true)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(recorder.urls, [nm], "item mode trashes the directory itself")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nm.path))
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

        let report = await CacheCleaner().clean(items: [item], moveToTrash: false)

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

        let report = await CacheCleaner(home: home).clean(
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

        let report = await CacheCleaner(home: home).clean(
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

        let report = await CacheCleaner().clean(items: [item], moveToTrash: false)

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

        let cleaner = CacheCleaner()
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

        let cleaner = CacheCleaner()
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

        let cleaner = CacheCleaner()
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
        let cleaner = CacheCleaner(provider: provider)
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
            origin: caches, target: entry
        )
        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot
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
            origin: caches, target: entry
        )
        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot
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
            origin: caches, target: entry
        )
        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot,
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
            origin: caches, target: entry
        )
        let cleaner = CacheCleaner(
            home: home, containerRoots: [caches], containerSnapshot: snapshot
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
            containerSnapshot: sessionSnapshot(of: [caches])
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

        let cleaner = CacheCleaner()
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

        let cleaner = CacheCleaner()
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

        let cleaner = CacheCleaner()
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

        let cleaner = CacheCleaner()
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

        let cleaner = CacheCleaner()
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
}
