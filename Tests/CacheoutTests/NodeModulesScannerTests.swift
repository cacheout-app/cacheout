import XCTest
import Darwin
@testable import Cacheout

/// Hermetic tests for `NodeModulesScanner` (fn-1.2, R13/R14/R19).
///
/// Every test runs against a UUID-derived fixture container under the system
/// temp directory with an injected fixture home — zero reads of the real
/// `$HOME`. Expected sizes come from raw `lstat` math, never from the code
/// under test. chmod-000 fixtures restore 0755 before teardown and skip
/// under euid 0.
final class NodeModulesScannerTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private var container: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("NodeModulesScannerTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        container = base.appendingPathComponent("container")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
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
    private func writeFile(_ url: URL, bytes: Int = 4_096) throws -> URL {
        try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
            .write(to: url)
        return url
    }

    private func allocated(_ urls: URL...) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            var st = stat()
            guard lstat(url.path, &st) == 0 else {
                XCTFail("lstat failed for fixture file \(url.path)")
                continue
            }
            total += Int64(st.st_blocks) * 512
        }
        return total
    }

    private func makeScanner(roots: [URL]? = nil) -> NodeModulesScanner {
        NodeModulesScanner(
            home: fixtureHome,
            searchRoots: roots ?? [container]
        )
    }

    /// `container/<project>/node_modules` with one visible payload file;
    /// returns the payload URL.
    @discardableResult
    private func makeProject(
        _ name: String, under parent: URL? = nil, payloadBytes: Int = 4_096
    ) throws -> URL {
        let projectDir = (parent ?? container).appendingPathComponent(name)
        let nm = projectDir.appendingPathComponent("node_modules")
        try mkdir(nm.appendingPathComponent("dep"))
        return try writeFile(
            nm.appendingPathComponent("dep/index.js"), bytes: payloadBytes
        )
    }

    // MARK: - Discovery, sizing, provenance (R13/R14)

    func testDiscoversProjectWithProvenanceAndHiddenBytesCounted() async throws {
        let visible = try makeProject("proj", payloadBytes: 6_000)
        // pnpm keeps ~all bytes under node_modules/.pnpm — hidden files MUST
        // count (D3).
        let pnpmStore = container
            .appendingPathComponent("proj/node_modules/.pnpm")
        try mkdir(pnpmStore)
        let hidden = try writeFile(pnpmStore.appendingPathComponent("store.bin"), bytes: 10_000)

        let outcome = await makeScanner().scan()

        XCTAssertEqual(outcome.items.count, 1)
        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.projectName, "proj")
        XCTAssertEqual(item.sizeBytes, allocated(visible, hidden),
                       "hidden .pnpm bytes are counted")
        XCTAssertEqual(item.originContainer, container,
                       "items carry origin-container provenance (R14)")
        XCTAssertTrue(outcome.errors.isEmpty, "unexpected: \(outcome.errors)")
    }

    func testDiscoversProjectInsideHiddenDirectory() async throws {
        // 23G of stale worktrees under a hidden dir was the field case — a
        // walk with .skipsHiddenFiles can never find this class.
        let hiddenParent = container.appendingPathComponent(".hidden-worktrees")
        try mkdir(hiddenParent)
        try makeProject("hidden-proj", under: hiddenParent)

        let outcome = await makeScanner().scan()

        XCTAssertEqual(outcome.items.map(\.projectName), ["hidden-proj"])
    }

    func testSkipListPrunesNoiseDirectories() async throws {
        let git = container.appendingPathComponent(".git")
        try mkdir(git)
        try makeProject("inside-git", under: git)
        let derived = container.appendingPathComponent("DerivedData")
        try mkdir(derived)
        try makeProject("inside-derived", under: derived)

        let outcome = await makeScanner().scan()

        XCTAssertTrue(outcome.items.isEmpty,
                      "skip-listed directories are never descended: \(outcome.items)")
    }

    func testMaxDepthBoundsTheWalk() async throws {
        try makeProject("shallow")                              // depth 1
        let deepParent = container.appendingPathComponent("a/b") // depths 1,2
        try mkdir(deepParent)
        try makeProject("deep", under: deepParent)               // depth 3

        let outcome = await makeScanner().scan(maxDepth: 2)

        XCTAssertEqual(outcome.items.map(\.projectName), ["shallow"],
                       "candidates beyond maxDepth are never reached")
    }

    func testDedupeAndSizeSortPreserved() async throws {
        try makeProject("small", payloadBytes: 2_000)
        try makeProject("large", payloadBytes: 60_000)

        // The same container listed twice must not duplicate items.
        let outcome = await makeScanner(roots: [container, container]).scan()

        XCTAssertEqual(outcome.items.map(\.projectName), ["large", "small"],
                       "deduplicated by path, sorted by size descending")
    }

    // MARK: - Symlink hardening (R19)

    func testEscapingSymlinkSearchRootIsNeverTraversed() async throws {
        let external = base.appendingPathComponent("external")
        try mkdir(external)
        try makeProject("external-proj", under: external)
        let linkRoot = base.appendingPathComponent("link-root")
        try fm.createSymbolicLink(at: linkRoot, withDestinationURL: external)

        let outcome = await makeScanner(roots: [linkRoot]).scan()

        XCTAssertTrue(outcome.items.isEmpty,
                      "a symlink search root must never be traversed: \(outcome.items)")
        XCTAssertEqual(outcome.errors.map(\.kind), [.symlinkRoot])
        XCTAssertEqual(outcome.errors.first?.url, linkRoot)
    }

    func testNestedSymlinkToExternalTreeIsNeverDescended() async throws {
        let external = base.appendingPathComponent("external-nested")
        try mkdir(external)
        try makeProject("via-symlink", under: external)
        let project = container.appendingPathComponent("innocent")
        try mkdir(project)
        try fm.createSymbolicLink(
            at: project.appendingPathComponent("escape"),
            withDestinationURL: external
        )

        let outcome = await makeScanner().scan()

        XCTAssertTrue(outcome.items.isEmpty,
                      "manual recursion must lstat-reject symlink descents: \(outcome.items)")
    }

    func testSymlinkNodeModulesCandidateIsNeverSizedOrReturned() async throws {
        let externalNM = base.appendingPathComponent("external-nm/node_modules")
        try mkdir(externalNM)
        try writeFile(externalNM.appendingPathComponent("payload.js"), bytes: 8_192)
        let project = container.appendingPathComponent("linked-nm-proj")
        try mkdir(project)
        try fm.createSymbolicLink(
            at: project.appendingPathComponent("node_modules"),
            withDestinationURL: externalNM
        )

        let outcome = await makeScanner().scan()

        XCTAssertTrue(outcome.items.isEmpty,
                      "a symlink candidate would enumerate its external target if sized: \(outcome.items)")
    }

    // MARK: - Denial visibility (R14, D6)

    func testDeniedNodeModulesRootYieldsClassifiedOutcomeError() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        try makeProject("locked-proj")
        let nm = container.appendingPathComponent("locked-proj/node_modules")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nm.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nm.path)
        }

        let outcome = await makeScanner().scan()

        XCTAssertTrue(outcome.items.isEmpty,
                      "an unmeasurable node_modules must not appear as an item")
        XCTAssertEqual(outcome.errors.map(\.kind), [.permissionDenied],
                       "the denial is a classified, visible outcome error")
    }

    func testUnreadableSubtreeDuringRecursionIsClassifiedNotSwallowed() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let locked = container.appendingPathComponent("locked-dir")
        try mkdir(locked)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let outcome = await makeScanner().scan()

        XCTAssertEqual(outcome.errors.map(\.kind), [.permissionDenied],
                       "the old try?-swallow becomes a real classified capture (D6)")
    }
}
