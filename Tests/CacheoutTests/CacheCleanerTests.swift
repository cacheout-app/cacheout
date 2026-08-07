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

        let cleaner = CacheCleaner(containerRoots: [root])
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

        let cleaner = CacheCleaner(containerRoots: [root])
        let report = await cleaner.clean(results: [], nodeModules: items, moveToTrash: false)

        XCTAssertEqual(report.errors.count, 1, "exactly one missing item should surface as error")
        XCTAssertEqual(report.errors.first?.category, "node_modules: ghost")
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

        let cleaner = CacheCleaner(containerRoots: [root])
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
        XCTAssertEqual(report.errors.first?.category, category.name)
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
        let cleaner = CacheCleaner(containerRoots: [root])
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
        let cleaner = CacheCleaner(containerRoots: [root])
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
        let cleaner = CacheCleaner(containerRoots: [configured])
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
        let cleaner = CacheCleaner(containerRoots: [root], provider: provider)
        let report = await cleaner.clean(results: [], nodeModules: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nm.path),
                      "a cross-device item must not be deleted")
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
        let byName = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.category, $0) })
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
        let entry = CleanupReport.Entry(
            category: "c", exactBytes: 4096, estimatedUpToBytes: 0
        )
        let permanent = CleanupReport(disposal: .permanent, entries: [entry], errors: [])
        XCTAssertTrue(permanent.headline.hasPrefix("Freed "))

        let trashed = CleanupReport(disposal: .trash, entries: [entry], errors: [])
        XCTAssertFalse(trashed.headline.contains("Freed"),
                       "a Trash run must never claim bytes were freed")
        XCTAssertTrue(trashed.headline.contains("Moved"))
        XCTAssertTrue(trashed.headline.contains("empty Trash to reclaim"))

        let allFailed = CleanupReport(
            disposal: .permanent, entries: [],
            errors: [("c", "boom")]
        )
        XCTAssertFalse(allFailed.headline.contains("Freed"),
                       "no success claim when everything failed")
        XCTAssertFalse(allFailed.headline.contains("Moved"))
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
            trashHandler: makeTrashSeam(into: trashDir, recorder: recorder)
        )
        let report = await cleaner.clean(results: [], nodeModules: [item], moveToTrash: true)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(recorder.urls, [nm], "item mode trashes the directory itself")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nm.path))
        XCTAssertEqual(report.entries.first?.exactBytes, expected)
        XCTAssertEqual(report.disposal, .trash)
    }
}
