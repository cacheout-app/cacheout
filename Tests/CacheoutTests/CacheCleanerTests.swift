import XCTest
@testable import Cacheout

/// Round-trip tests for `CacheCleaner` against tmp directories. These lock in the
/// expected semantics of the parallelized `removeContents` and `node_modules` paths
/// added in PRs #275 and the follow-up — specifically:
///   • directory entries are removed but the parent directory itself survives
///   • parallel deletion completes for large fan-outs without dropping items
///   • per-item errors are isolated in the `node_modules` path (one bad item does
///     not poison the rest)
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

    private func makeCategory(at url: URL, name: String = "test-cache") -> CacheCategory {
        CacheCategory(
            name: name,
            slug: name,
            description: "test",
            icon: "trash",
            discovery: [.absolutePath(url.path)],
            riskLevel: .safe,
            rebuildNote: "",
            defaultSelected: true
        )
    }

    private func makeScanResult(category: CacheCategory, size: Int64 = 1024, items: Int = 1) -> ScanResult {
        var r = ScanResult(category: category, sizeBytes: size, itemCount: items, exists: true)
        r.isSelected = true
        return r
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
        XCTAssertEqual(report.cleaned.count, 1)
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
                isSelected: true
            ))
        }

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(results: [], nodeModules: items, moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.cleaned.count, items.count)
        for item in items {
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.nodeModulesPath.path),
                           "expected \(item.nodeModulesPath.path) removed")
        }
    }

    func testCleanNodeModulesIsolatesPerItemErrors() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Mix one missing path between two real ones — the parallel branch must
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
                            nodeModulesPath: goodA, sizeBytes: 16, lastModified: nil, isSelected: true),
            NodeModulesItem(projectName: "ghost", projectPath: missing.deletingLastPathComponent(),
                            nodeModulesPath: missing, sizeBytes: 16, lastModified: nil, isSelected: true),
            NodeModulesItem(projectName: "b", projectPath: goodB.deletingLastPathComponent(),
                            nodeModulesPath: goodB, sizeBytes: 16, lastModified: nil, isSelected: true),
        ]

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(results: [], nodeModules: items, moveToTrash: false)

        XCTAssertEqual(report.errors.count, 1, "exactly one missing item should surface as error")
        XCTAssertEqual(report.errors.first?.category, "node_modules: ghost")
        XCTAssertEqual(report.cleaned.count, 2, "the two real items should still be cleaned")
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
            isSelected: false
        )

        let cleaner = CacheCleaner()
        let report = await cleaner.clean(results: [], nodeModules: [item], moveToTrash: false)

        XCTAssertTrue(report.cleaned.isEmpty)
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path),
                      "unselected items must not be touched")
    }
}
