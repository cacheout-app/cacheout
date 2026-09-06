import XCTest
import Darwin
@testable import Cacheout

/// Hermetic tests for the fn-3.1 sweep enumeration core
/// (`OrphanedCachesScanner.enumerateFacts`) and the additive
/// `SizeReport.newestContentDate` sizer extension.
///
/// Every test runs against a UUID-derived fixture home under the system temp
/// directory — zero reads of the real `$HOME` or the real `~/Library/Caches`.
/// Expected sizes are computed INDEPENDENTLY of the sizer (raw `lstat`
/// `st_blocks * 512`). chmod-000 fixtures restore 0755 before teardown and
/// skip under euid 0 (root ignores permission bits; chmod-000 produces
/// EACCES — TCC's EPERM cannot be fixtured from an unentitled test process,
/// so its classification is exercised via an injected provider failure).
final class OrphanedCachesSweepTests: XCTestCase {

    private var base: URL!
    private var home: URL!
    private var cachesRoot: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("OrphanedCachesSweepTests-\(UUID().uuidString)")
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

    /// Independent fixture math: allocated size straight from `lstat`,
    /// bypassing everything the code under test uses.
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

    private func chmod000(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }

    private func restorePerms(_ url: URL) {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func setModificationDate(_ url: URL, _ date: Date) throws {
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func makeScanner(
        categories: [CacheCategory] = [],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        // The PRODUCTION bound by default — the shared constant, never a
        // hardcoded copy, so these tests cannot drift from what ships.
        probeEntryLimit: Int = OrphanedCachesScanner.defaultProbeEntryLimit,
        toolAvailability: (@Sendable (String) -> Bool)? = nil,
        probeResolver: (@Sendable (String) -> String?)? = nil
    ) -> OrphanedCachesScanner {
        OrphanedCachesScanner(
            home: home,
            categories: categories,
            provider: provider,
            probeEntryLimit: probeEntryLimit,
            toolAvailability: toolAvailability,
            probeResolver: probeResolver
        )
    }

    private func syntheticCategory(
        name: String = "synthetic", discovery: [PathDiscovery]
    ) -> CacheCategory {
        CacheCategory(
            name: name, slug: name, description: "test", icon: "trash",
            discovery: discovery, riskLevel: .safe, rebuildNote: "",
            defaultSelected: false
        )
    }

    private func factsByName(
        _ scanner: OrphanedCachesScanner,
        file: StaticString = #filePath, line: UInt = #line
    ) -> [String: SweptCacheEntry] {
        guard case .entries(let entries) = scanner.enumerateFacts() else {
            XCTFail("expected .entries", file: file, line: line)
            return [:]
        }
        return XCTUniquelyKeyed(
            entries.map { ($0.name, $0) }, file: file, line: line
        )
    }

    // MARK: - First-level facts: enumeration + fixture math (R3/R7 support)

    func testFirstLevelFactsIncludeHiddenEntriesAndMatchFixtureMath() throws {
        let alpha = cachesRoot.appendingPathComponent("AppAlpha")
        try mkdir(alpha.appendingPathComponent("sub"))
        let alphaA = try writeFile(alpha.appendingPathComponent("a.bin"), bytes: 4_096)
        let alphaB = try writeFile(
            alpha.appendingPathComponent("sub/b.bin"), bytes: 8_192
        )
        let hidden = cachesRoot.appendingPathComponent(".hidden-cache")
        try mkdir(hidden)
        let hiddenFile = try writeFile(hidden.appendingPathComponent("h.bin"), bytes: 4_096)
        let loose = try writeFile(
            cachesRoot.appendingPathComponent("loose-file.bin"), bytes: 4_096
        )

        let facts = factsByName(makeScanner())

        XCTAssertEqual(Set(facts.keys), ["AppAlpha", ".hidden-cache", "loose-file.bin"],
                       "hidden/dot entries INCLUDED — D3 lesson")
        XCTAssertEqual(facts["AppAlpha"]?.allocatedBytes, allocated(alphaA, alphaB),
                       "multi-level content matches independent fixture math")
        XCTAssertEqual(facts["AppAlpha"]?.itemCount, 2)
        XCTAssertEqual(facts[".hidden-cache"]?.allocatedBytes, allocated(hiddenFile))
        XCTAssertEqual(facts[".hidden-cache"]?.itemCount, 1)
        XCTAssertEqual(facts["loose-file.bin"]?.allocatedBytes, allocated(loose),
                       "a first-level regular file is sized as its own leaf")
        XCTAssertEqual(facts["loose-file.bin"]?.itemCount, 1)
    }

    func testFactsAreSortedByNameForDeterminism() throws {
        for name in ["zeta", "alpha", ".dot"] {
            try mkdir(cachesRoot.appendingPathComponent(name))
        }

        guard case .entries(let entries) = makeScanner().enumerateFacts() else {
            return XCTFail("expected .entries")
        }
        XCTAssertEqual(entries.map(\.name), entries.map(\.name).sorted(),
                       "facts order is deterministic regardless of directory order")
    }

    // MARK: - Category-owned exclusion (R3)

    func testCategoryOwnedEntriesExcludedViaProductionCategoryList() throws {
        // Homebrew's declared root is a probed FALLBACK
        // (`Library/Caches/Homebrew`) — declared roots include fallbacks
        // WHILE the gating tool is present (tool gate AND probe seam
        // injected here so the test never depends on the machine's tool
        // installations and never spawns the production category list's
        // real probe commands).
        try mkdir(cachesRoot.appendingPathComponent("Homebrew"))
        try writeFile(
            cachesRoot.appendingPathComponent("Homebrew/bottle.tar.gz"), bytes: 4_096
        )
        try mkdir(cachesRoot.appendingPathComponent("UnownedSweepEntry"))

        let facts = factsByName(makeScanner(
            categories: CacheCategory.allCategories,
            toolAvailability: { _ in true },
            probeResolver: { _ in nil }
        ))

        XCTAssertNil(facts["Homebrew"], "category-owned entry absent from facts")
        XCTAssertNotNil(facts["UnownedSweepEntry"], "non-owned sibling present")
    }

    func testInScopeNonFallbackProbeResultIsExcluded() throws {
        // The PR #456 round-3 case: the probe of a TOOL-PRESENT category
        // resolves to an in-scope path that is NOT among the declared
        // fallbacks (`brew --cache` → custom `~/Library/Caches/CustomBrew`).
        // The category scan scans exactly that path
        // (`CacheCategory.resolvedPaths` prefers probe stdout), so the
        // sweep must exclude it — or the same tree is listed, sized, and
        // cleaned TWICE.
        let custom = cachesRoot.appendingPathComponent("CustomBrew")
        try mkdir(custom)
        try writeFile(custom.appendingPathComponent("bottle.tar.gz"))
        try mkdir(cachesRoot.appendingPathComponent("Homebrew"))
        try mkdir(cachesRoot.appendingPathComponent("Sibling"))
        let category = syntheticCategory(discovery: [
            .probed(
                command: "brew --cache",
                requiresTool: "brew",
                fallbacks: ["Library/Caches/Homebrew"]
            ),
        ])

        let facts = factsByName(makeScanner(
            categories: [category],
            toolAvailability: { _ in true },
            probeResolver: { _ in custom.path }
        ))

        XCTAssertNil(facts["CustomBrew"],
                     "the probe-resolved root the category scan owns is "
                     + "excluded even though it is not a declared fallback")
        XCTAssertNil(facts["Homebrew"],
                     "declared fallbacks stay excluded too — the kept set is "
                     + "a deliberate superset of what the category captured")
        XCTAssertNotNil(facts["Sibling"])
    }

    func testRequiresToolNilProbedEntryProbesAndExcludesResult() throws {
        // The pip shape: `requiresTool: nil` means the category scan ALWAYS
        // attempts the probe — so the sweep must run it too, and an
        // in-scope result excludes exactly as in the tool-gated case.
        let recorder = InvocationRecorder()
        let custom = cachesRoot.appendingPathComponent("pip-custom")
        try mkdir(custom)
        try mkdir(cachesRoot.appendingPathComponent("pip"))
        try mkdir(cachesRoot.appendingPathComponent("Sibling"))
        let category = syntheticCategory(discovery: [
            .probed(
                command: "pip3 cache dir",
                requiresTool: nil,
                fallbacks: ["Library/Caches/pip"]
            ),
        ])

        let facts = factsByName(makeScanner(
            categories: [category],
            probeResolver: { recorder.record($0); return custom.path }
        ))

        XCTAssertEqual(recorder.names, ["pip3 cache dir"],
                       "no tool gate — the probe is always attempted, "
                       + "mirroring resolvedPaths")
        XCTAssertNil(facts["pip-custom"])
        XCTAssertNil(facts["pip"])
        XCTAssertNotNil(facts["Sibling"])
    }

    func testProbeFailureFailsTowardVisibilityNeverCrashes() throws {
        // Probe failure/timeout (the production seam returns nil for both):
        // the entry SURFACES in the sweep — failing toward VISIBILITY is
        // the safe direction, because a listed sweep row is never a
        // deletion grant (classification and container admission still
        // govern it), whereas failing toward exclusion would hide a tree
        // from both surfaces. In the common failure modes the category
        // scan's own identical probe fails too and falls back to declared
        // fallbacks — which stay excluded (tool present), keeping the two
        // surfaces coherent.
        let custom = cachesRoot.appendingPathComponent("CustomBrew")
        try mkdir(custom)
        try mkdir(cachesRoot.appendingPathComponent("Homebrew"))
        let category = syntheticCategory(discovery: [
            .probed(
                command: "brew --cache",
                requiresTool: "brew",
                fallbacks: ["Library/Caches/Homebrew"]
            ),
        ])

        let facts = factsByName(makeScanner(
            categories: [category],
            toolAvailability: { _ in true },
            probeResolver: { _ in nil }
        ))

        XCTAssertNotNil(facts["CustomBrew"],
                        "a failed probe contributes no root — the entry is "
                        + "visible, not silently suppressed")
        XCTAssertNil(facts["Homebrew"],
                     "declared fallbacks still excluded while the tool is "
                     + "present")
    }

    func testOutOfScopeOrRootEqualProbeResultsExcludeNothing() throws {
        // The scope filter applies to probe results exactly as to declared
        // roots: an out-of-scope result contributes nothing, and a probe
        // emitting the sweep root ITSELF must not suppress the entire
        // sweep.
        let outside = base.appendingPathComponent("outside-cache")
        try mkdir(outside)
        try mkdir(cachesRoot.appendingPathComponent("Alpha"))
        try mkdir(cachesRoot.appendingPathComponent("Beta"))
        let categories = [
            syntheticCategory(name: "out-of-scope", discovery: [
                .probed(command: "outside-probe", requiresTool: nil,
                        fallbacks: []),
            ]),
            syntheticCategory(name: "root-equal", discovery: [
                .probed(command: "root-probe", requiresTool: nil,
                        fallbacks: []),
            ]),
        ]
        let rootPath = cachesRoot.path

        let facts = factsByName(makeScanner(
            categories: categories,
            probeResolver: { command in
                command == "root-probe" ? rootPath : outside.path
            }
        ))

        XCTAssertEqual(Set(facts.keys), ["Alpha", "Beta"],
                       "all fixture entries remain present")
    }

    func testProbeMemoizedPerCommandPerEnumeration() throws {
        // Two categories sharing one probe command spawn it once; a
        // distinct command spawns separately — the bound that keeps the
        // exclusion pass's subprocess count at most one per distinct
        // tool-present probe command.
        let recorder = InvocationRecorder()
        let categories = [
            syntheticCategory(name: "a", discovery: [
                .probed(command: "shared-probe", requiresTool: nil,
                        fallbacks: []),
            ]),
            syntheticCategory(name: "b", discovery: [
                .probed(command: "shared-probe", requiresTool: nil,
                        fallbacks: []),
            ]),
            syntheticCategory(name: "c", discovery: [
                .probed(command: "distinct-probe", requiresTool: nil,
                        fallbacks: []),
            ]),
        ]

        _ = factsByName(makeScanner(
            categories: categories,
            probeResolver: { recorder.record($0); return nil }
        ))

        XCTAssertEqual(recorder.names, ["shared-probe", "distinct-probe"],
                       "one probe run per distinct command per enumeration")
    }

    func testProductionProbeSeamResolvesInScopeCustomRootViaRealShell() throws {
        // The DEFAULT (uninjected) probe seam end-to-end, tool-free: a
        // probe command that just echoes an in-scope non-fallback path runs
        // through the real `CacheCategory.runProbe` doctrine. The premise
        // half proves the double-count hazard is real — the category scan
        // captures the probed root — and the fix half proves the sweep
        // excludes the same root.
        let custom = cachesRoot.appendingPathComponent("EchoedCustomRoot")
        try mkdir(custom)
        try writeFile(custom.appendingPathComponent("payload.bin"))
        let category = syntheticCategory(discovery: [
            .probed(
                command: "echo '\(custom.path)'",
                requiresTool: nil,
                fallbacks: ["Library/Caches/NoSuchFallback"]
            ),
        ])

        XCTAssertEqual(category.resolvedPaths(home: home).map(\.path),
                       [custom.path],
                       "premise: the category scan scans the probed root")

        let facts = factsByName(makeScanner(categories: [category]))
        XCTAssertNil(facts["EchoedCustomRoot"],
                     "the sweep's production probe seam resolves the same "
                     + "root and excludes it")
    }

    func testProbedFallbackWithAbsentToolIsSwept() throws {
        // The uninstalled-Homebrew case (PR #456 review P2): a missing
        // `requiresTool` makes the category scan skip the WHOLE probed
        // discovery entry (`CacheCategory.resolvedPaths`), fallbacks
        // included — so the sweep must NOT exclude them, or the stale cache
        // the removed tool left behind is invisible to both surfaces.
        let sentinel = base.appendingPathComponent("probe-ran")
        let category = syntheticCategory(discovery: [
            .probed(
                command: "touch '\(sentinel.path)'",
                requiresTool: "cacheout-test-tool",
                fallbacks: ["Library/Caches/UninstalledTool"]
            ),
        ])
        try mkdir(cachesRoot.appendingPathComponent("UninstalledTool"))
        try writeFile(
            cachesRoot.appendingPathComponent("UninstalledTool/stale.bin")
        )

        let facts = factsByName(makeScanner(
            categories: [category], toolAvailability: { _ in false }
        ))

        XCTAssertNotNil(facts["UninstalledTool"],
                        "a fallback the category scan provably skipped is swept")
        XCTAssertFalse(fm.fileExists(atPath: sentinel.path),
                       "an absent tool gates the WHOLE entry — the probe "
                       + "never runs (through the real production seam)")
    }

    func testProbedFallbackWithPresentToolStaysExcluded() throws {
        // Tool present: fallbacks stay excluded, and (round 3) the probe
        // now RUNS through the production seam — this one emits nothing on
        // stdout, so it contributes no additional root.
        let sentinel = base.appendingPathComponent("probe-ran")
        let category = syntheticCategory(discovery: [
            .probed(
                command: "touch '\(sentinel.path)'",
                requiresTool: "cacheout-test-tool",
                fallbacks: ["Library/Caches/InstalledTool"]
            ),
        ])
        try mkdir(cachesRoot.appendingPathComponent("InstalledTool"))
        try mkdir(cachesRoot.appendingPathComponent("Sibling"))

        let facts = factsByName(makeScanner(
            categories: [category], toolAvailability: { _ in true }
        ))

        XCTAssertNil(facts["InstalledTool"],
                     "tool present — the category scan owns the entry; "
                     + "excluded exactly as before")
        XCTAssertNotNil(facts["Sibling"])
        XCTAssertTrue(fm.fileExists(atPath: sentinel.path),
                      "tool present — the probe RUNS during exclusion "
                      + "(round-3 reversal), because the category scan will "
                      + "scan wherever it resolves")
    }

    func testToolGateMemoizedAndConsultedForEveryProbedEntry() throws {
        // The `which` gate runs once per DISTINCT tool per enumeration —
        // never per fallback — and (round 3) for EVERY probed entry, even
        // one whose fallbacks are all out of scope: its probe could still
        // resolve INTO the sweep root, so tool presence must be known
        // before deciding whether to probe.
        let recorder = InvocationRecorder()
        let categories = [
            syntheticCategory(name: "in-scope-a", discovery: [
                .probed(command: "true", requiresTool: "shared-tool",
                        fallbacks: ["Library/Caches/InScopeA"]),
            ]),
            syntheticCategory(name: "in-scope-b", discovery: [
                .probed(command: "true", requiresTool: "shared-tool",
                        fallbacks: ["Library/Caches/InScopeB"]),
            ]),
            syntheticCategory(name: "out-of-scope", discovery: [
                .probed(command: "true", requiresTool: "out-of-scope-tool",
                        fallbacks: [".npm"]),
            ]),
        ]
        try mkdir(cachesRoot.appendingPathComponent("InScopeA"))

        _ = factsByName(makeScanner(
            categories: categories,
            toolAvailability: { recorder.record($0); return false },
            probeResolver: { _ in nil }
        ))

        XCTAssertEqual(recorder.names, ["shared-tool", "out-of-scope-tool"],
                       "once per distinct tool; every probed entry consults "
                       + "the gate")
    }

    func testProductionToolGateAbsentToolViaRealWhich() throws {
        // The DEFAULT (uninjected) gate: a tool name that cannot exist
        // resolves absent through the real bounded `which`, and the
        // fallback is swept — mirroring exactly the discovery entry the
        // category scan skips.
        let category = syntheticCategory(discovery: [
            .probed(
                command: "true",
                requiresTool: "cacheout-absent-\(UUID().uuidString.prefix(8))",
                fallbacks: ["Library/Caches/GhostTool"]
            ),
        ])
        try mkdir(cachesRoot.appendingPathComponent("GhostTool"))

        XCTAssertTrue(category.resolvedPaths(home: home).isEmpty,
                      "the category scan provably does not own the fallback")

        let facts = factsByName(makeScanner(categories: [category]))
        XCTAssertNotNil(facts["GhostTool"],
                        "swept via the production which-based gate")
    }

    func testDeeperCategoryRootExcludesFirstLevelAncestor() throws {
        // Direction (b): a kept root STRICTLY BELOW the entry excludes the
        // first-level ancestor (no double count of the category subtree).
        let category = syntheticCategory(discovery: [
            .staticPath("Library/Caches/Google/Chrome"),
        ])
        try mkdir(cachesRoot.appendingPathComponent("Google/Chrome"))
        try mkdir(cachesRoot.appendingPathComponent("Google/OtherProduct"))
        try mkdir(cachesRoot.appendingPathComponent("Mozilla"))

        let facts = factsByName(makeScanner(categories: [category]))

        XCTAssertNil(facts["Google"], "entry ancestor of a kept root is excluded")
        XCTAssertNotNil(facts["Mozilla"], "unrelated sibling remains")
    }

    func testOutsideOrEqualCategoryRootsExcludeNothing() throws {
        // A root OUTSIDE or EQUAL to the sweep root contributes nothing —
        // otherwise a category declaring ~/Library (an ancestor of every
        // entry) would silently suppress the entire sweep.
        let categories = [
            syntheticCategory(name: "ancestor", discovery: [.staticPath("Library")]),
            syntheticCategory(name: "equal", discovery: [.staticPath("Library/Caches")]),
            syntheticCategory(name: "outside", discovery: [.absolutePath(base.path)]),
        ]
        try mkdir(cachesRoot.appendingPathComponent("Alpha"))
        try mkdir(cachesRoot.appendingPathComponent("Beta"))

        let facts = factsByName(makeScanner(categories: categories))

        XCTAssertEqual(Set(facts.keys), ["Alpha", "Beta"],
                       "all fixture entries remain present")
    }

    // MARK: - Symlink entries: deletion-target semantics + probe no-follow

    func testSymlinkEntryIsZeroBytesNeverWalkedNeverProbed() throws {
        let external = base.appendingPathComponent("external-data")
        try mkdir(external.appendingPathComponent("Photos Library.photoslibrary"))
        try writeFile(external.appendingPathComponent("payload.bin"), bytes: 8_192)
        try fm.createSymbolicLink(
            at: cachesRoot.appendingPathComponent("leaked-link"),
            withDestinationURL: external
        )

        let facts = factsByName(makeScanner())
        let link = try XCTUnwrap(facts["leaked-link"])

        XCTAssertEqual(link.allocatedBytes, 0, "target never walked")
        XCTAssertEqual(link.itemCount, 0)
        XCTAssertTrue(link.denials.isEmpty)
        XCTAssertTrue(link.userDataShapeMatches.isEmpty,
                      "target content provably never inspected by the probe")
        XCTAssertTrue(link.userDataProbeComplete,
                      "deleting the entry removes only the link — nothing "
                      + "deletable went uninspected")
    }

    // MARK: - newestContentDate (R8 input, additive sizer extension)

    func testNewestContentDateNewestRegularFileWinsDirectoryChurnIgnored() throws {
        let entry = cachesRoot.appendingPathComponent("aging-cache")
        let sub = entry.appendingPathComponent("sub")
        try mkdir(sub)
        let older = Date(timeIntervalSinceNow: -100 * 86_400)
        let newest = Date(timeIntervalSinceNow: -10 * 86_400)
        try writeFile(entry.appendingPathComponent("old.bin"), bytes: 4_096)
        try setModificationDate(entry.appendingPathComponent("old.bin"), older)
        try writeFile(sub.appendingPathComponent("new.bin"), bytes: 4_096)
        try setModificationDate(sub.appendingPathComponent("new.bin"), newest)
        // Directory-only churn: both directories carry mtimes ≈ now (the
        // fixture writes just touched them) — they must not contaminate.

        let facts = factsByName(makeScanner())
        let date = try XCTUnwrap(facts["aging-cache"]?.newestContentDate)

        XCTAssertEqual(date.timeIntervalSince1970, newest.timeIntervalSince1970,
                       accuracy: 1.0,
                       "newest regular file anywhere in the subtree wins; "
                       + "directory churn ignored")
    }

    func testRegularFileRootYieldsItsOwnMtime() throws {
        // A regular-file ROOT reaches recordRegularFile DIRECTLY (never
        // through the enumerator prefetch) — the explicit resourceValues
        // read is what makes this case work.
        let file = try writeFile(base.appendingPathComponent("leaf.bin"), bytes: 4_096)
        let stamp = Date(timeIntervalSinceNow: -42 * 86_400)
        try setModificationDate(file, stamp)

        let report = DirectorySizer().measure(at: file, mode: .deletionTarget)
        let date = try XCTUnwrap(report.newestContentDate)

        XCTAssertEqual(date.timeIntervalSince1970, stamp.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    // MARK: - Mount-boundary propagation (R7)

    /// Remaps device ids and injects mount points by inode — the house
    /// hermetic pattern (DirectorySizerTests).
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

        override func isMountPoint(_ url: URL) -> Bool {
            if let id = identity(of: url), mountPointInodes.contains(id.inode) {
                return true
            }
            return super.isMountPoint(url)
        }
    }

    func testMountPointEntrySurfacesRootMountBoundary() throws {
        let entry = cachesRoot.appendingPathComponent("mounted-entry")
        try mkdir(entry)
        try writeFile(entry.appendingPathComponent("payload.bin"), bytes: 8_192)

        let provider = BoundaryInjectingProvider()
        let inode = try XCTUnwrap(provider.identity(of: entry)?.inode)
        provider.mountPointInodes.insert(inode)

        let facts = factsByName(makeScanner(provider: provider))
        let mounted = try XCTUnwrap(facts["mounted-entry"])

        XCTAssertTrue(mounted.rootMountBoundary,
                      "a mount-point entry must never masquerade as clean-empty")
        XCTAssertEqual(mounted.mountBoundaries.count, 1)
        XCTAssertEqual(mounted.allocatedBytes, 0, "tree never enumerated")
    }

    func testNestedMountBoundarySurfacesInFacts() throws {
        let entry = cachesRoot.appendingPathComponent("has-volume")
        try mkdir(entry)
        let local = try writeFile(entry.appendingPathComponent("local.bin"), bytes: 4_096)
        let volume = entry.appendingPathComponent("foreign-volume")
        try mkdir(volume)
        try writeFile(volume.appendingPathComponent("beyond.bin"), bytes: 8_192)

        let provider = BoundaryInjectingProvider()
        let inode = try XCTUnwrap(provider.identity(of: volume)?.inode)
        provider.deviceOverridesByInode[inode] = 0xDEAD_BEEF

        let facts = factsByName(makeScanner(provider: provider))
        let partial = try XCTUnwrap(facts["has-volume"])

        XCTAssertFalse(partial.rootMountBoundary)
        XCTAssertEqual(partial.mountBoundaries.map(\.lastPathComponent),
                       ["foreign-volume"],
                       "a nested boundary is never dropped from the facts — "
                       + "the entry is only PARTIALLY sized")
        XCTAssertEqual(partial.allocatedBytes, allocated(local),
                       "foreign subtree not entered, not counted")
    }

    // MARK: - Root gate (R7): no-follow, classified failures

    func testSymlinkSweepRootIsRefusedNotTraversed() throws {
        let external = base.appendingPathComponent("external-caches")
        try mkdir(external)
        try writeFile(external.appendingPathComponent("payload.bin"), bytes: 8_192)
        try fm.removeItem(at: cachesRoot)
        try fm.createSymbolicLink(at: cachesRoot, withDestinationURL: external)

        let outcome = makeScanner().enumerateFacts()

        XCTAssertEqual(outcome, .rootNotADirectory(.symlink),
                       "a symlink root is NEVER traversed — no facts from the target")
    }

    func testRegularFileSweepRootIsRefused() throws {
        try fm.removeItem(at: cachesRoot)
        try writeFile(cachesRoot, bytes: 4_096)

        XCTAssertEqual(makeScanner().enumerateFacts(),
                       .rootNotADirectory(.regularFile))
    }

    func testMissingSweepRootYieldsEmptyFacts() throws {
        try fm.removeItem(at: cachesRoot)

        XCTAssertEqual(makeScanner().enumerateFacts(), .entries([]),
                       "a missing root is honest empty facts, not an error")
    }

    func testUnreadableSweepRootIsClassifiedScannerLevelError() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        try writeFile(cachesRoot.appendingPathComponent("invisible.bin"), bytes: 4_096)
        try chmod000(cachesRoot)
        defer { restorePerms(cachesRoot) }

        guard case .rootUnreadable(let denial) = makeScanner().enumerateFacts() else {
            return XCTFail("a denied root must be a classified error — "
                           + "never empty-looking success (D6)")
        }
        XCTAssertEqual(denial.kind, .permission, "chmod-000 is EACCES")
        XCTAssertEqual(denial.kind.scanErrorKind, .permissionDenied)
    }

    // MARK: - Per-entry denial propagation (R7)

    func testChmod000EntryRecordsPermissionDenialDistinctFromEmpty() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let locked = cachesRoot.appendingPathComponent("locked")
        try mkdir(locked)
        try writeFile(locked.appendingPathComponent("hidden.bin"), bytes: 4_096)
        try chmod000(locked)
        defer { restorePerms(locked) }
        try mkdir(cachesRoot.appendingPathComponent("genuinely-empty"))

        let facts = factsByName(makeScanner())
        let denied = try XCTUnwrap(facts["locked"])
        let empty = try XCTUnwrap(facts["genuinely-empty"])

        XCTAssertEqual(denied.allocatedBytes, 0)
        XCTAssertEqual(denied.denials.first?.kind, .permission,
                       "EACCES classifies as PERMISSION")
        XCTAssertFalse(denied.userDataProbeComplete,
                       "an unreadable entry cannot prove absence of user data")
        XCTAssertTrue(empty.denials.isEmpty,
                      "zero bytes + no denials is what distinguishes empty from denied")
        XCTAssertTrue(empty.userDataProbeComplete)
    }

    /// Fails the kind probe for chosen basenames — the hermetic stand-in for
    /// a TCC denial (EPERM cannot be fixtured from an unentitled process).
    private final class FailingKindProbeProvider: FileSystemIdentityProvider {
        var failingNames: [String: Int32] = [:]

        override func probeKind(of url: URL) -> KindProbe {
            if let code = failingNames[url.lastPathComponent] {
                return .failed(errno: code)
            }
            return super.probeKind(of: url)
        }
    }

    func testSyntheticEPERMEntryClassifiesNeutrallyDistinctFromEACCES() throws {
        let entry = cachesRoot.appendingPathComponent("tcc-locked")
        try mkdir(entry)

        let provider = FailingKindProbeProvider()
        provider.failingNames["tcc-locked"] = EPERM

        let facts = factsByName(makeScanner(provider: provider))
        let denied = try XCTUnwrap(facts["tcc-locked"])

        // NEUTRAL since fn-4.12: this probe is a raw lstat, and a bare
        // EPERM carries no provenance — `.tcc`, and the `.tccDenied` grant
        // hint downstream of it, may not be asserted from a guess. The
        // denial stays VISIBLE (distinct from EACCES's `.permission`), and
        // its detail says why no cause is named.
        XCTAssertEqual(denied.denials.first?.kind, .metadata,
                       "bare EPERM is neutral — never `.tcc` (fn-4.12)")
        XCTAssertTrue(
            denied.denials.first?.detail
                .contains("could not be established") == true,
            "\(denied.denials)"
        )
        XCTAssertEqual(denied.denials.first?.kind.scanErrorKind, .other)
        XCTAssertFalse(denied.userDataProbeComplete, "fail closed on probe failure")
    }

    // MARK: - User-data-shape probe (R4)

    func testUserDataProbeMatchesFieldCaseAtDepthTwo() throws {
        // The field case: <entry>/Pictures/Photos Library.photoslibrary.
        let entry = cachesRoot.appendingPathComponent("com.apple.SwiftUI.Drag-FIXTURE")
        let library = entry
            .appendingPathComponent("Pictures/Photos Library.photoslibrary")
        try mkdir(library)
        try writeFile(library.appendingPathComponent("database.sqlite"), bytes: 4_096)

        let facts = factsByName(makeScanner())
        let leak = try XCTUnwrap(facts["com.apple.SwiftUI.Drag-FIXTURE"])

        XCTAssertEqual(leak.userDataShapeMatches,
                       ["photos-library", "pictures-directory"],
                       "matched pattern NAMES recorded, table order")
        XCTAssertTrue(leak.userDataProbeComplete)
    }

    func testUserDataProbeMatchesCaseVariants() throws {
        // The guard protects user content in ANY casing (PR #456 review):
        // the stored spelling is arbitrary, and `fnmatch` with flags 0
        // compared it case-sensitively — missing these even on the usual
        // case-insensitive macOS filesystem.
        let upperLibrary = cachesRoot.appendingPathComponent("upper-library")
        try mkdir(upperLibrary.appendingPathComponent(
            "Photos Library.PHOTOSLIBRARY"
        ))
        let lowerPictures = cachesRoot.appendingPathComponent("lower-pictures")
        try mkdir(lowerPictures.appendingPathComponent("pictures"))
        let upperDocuments = cachesRoot.appendingPathComponent("upper-documents")
        try mkdir(upperDocuments.appendingPathComponent("DOCUMENTS"))

        let facts = factsByName(makeScanner())

        XCTAssertEqual(facts["upper-library"]?.userDataShapeMatches,
                       ["photos-library"])
        XCTAssertEqual(facts["lower-pictures"]?.userDataShapeMatches,
                       ["pictures-directory"])
        XCTAssertEqual(facts["upper-documents"]?.userDataShapeMatches,
                       ["documents-directory"])
        XCTAssertEqual(facts["upper-library"]?.userDataProbeComplete, true)
    }

    func testCleanEntryHasNoMatchesAndCompleteProbe() throws {
        let entry = cachesRoot.appendingPathComponent("plain-cache")
        try mkdir(entry.appendingPathComponent("sub"))
        try writeFile(entry.appendingPathComponent("sub/data.bin"), bytes: 4_096)

        let facts = factsByName(makeScanner())
        let clean = try XCTUnwrap(facts["plain-cache"])

        XCTAssertTrue(clean.userDataShapeMatches.isEmpty)
        XCTAssertTrue(clean.userDataProbeComplete,
                      "absence of matches is meaningful — the probe completed")
    }

    func testProbeFailsClosedOnMatchJustBeyondBudgetBoundary() throws {
        // The budget is the ONE bound, and it fails closed exactly where
        // the retired depth cap did: a, b, c cost one entry each, so a
        // budget of 3 is spent before `c`'s children can be read and the
        // match inside it is never seen.
        let entry = cachesRoot.appendingPathComponent("deep-cache")
        try mkdir(entry.appendingPathComponent(
            "a/b/c/Photos Library.photoslibrary"
        ))

        let facts = factsByName(makeScanner(probeEntryLimit: 3))
        let deep = try XCTUnwrap(facts["deep-cache"])

        XCTAssertTrue(deep.userDataShapeMatches.isEmpty,
                      "the match beyond the boundary is not recorded")
        XCTAssertFalse(deep.userDataProbeComplete,
                       "a budget spent before the tree was exhausted fails "
                       + "closed — a knownLeak must never stay bulk-eligible "
                       + "on a truncated inspection")
    }

    func testDepthAloneNeverTruncatesUnderTheProductionBudget() throws {
        // The same fixture under the SHIPPING bound: depth costs entries,
        // not a separate veto, so a tree the budget can afford is PROVEN —
        // and the buried match is actually found rather than silently
        // replaced by "couldn't inspect".
        let entry = cachesRoot.appendingPathComponent("deep-cache")
        try mkdir(entry.appendingPathComponent(
            "a/b/c/d/e/f/g/h/Photos Library.photoslibrary"
        ))

        let deep = try XCTUnwrap(factsByName(makeScanner())["deep-cache"])

        XCTAssertEqual(deep.userDataShapeMatches, ["photos-library"])
        XCTAssertTrue(deep.userDataProbeComplete,
                      "nothing obstructed this walk — depth alone must not "
                      + "manufacture an inescapable INCOMPLETE verdict")
    }

    func testProbeEntryCapHitBeforeExhaustionFailsClosed() throws {
        let capped = cachesRoot.appendingPathComponent("many-files")
        try mkdir(capped)
        for index in 0..<6 {
            try writeFile(capped.appendingPathComponent("f\(index).bin"), bytes: 16)
        }
        let small = cachesRoot.appendingPathComponent("few-files")
        try mkdir(small)
        for index in 0..<3 {
            try writeFile(small.appendingPathComponent("f\(index).bin"), bytes: 16)
        }

        let facts = factsByName(makeScanner(probeEntryLimit: 4))

        XCTAssertEqual(facts["many-files"]?.userDataProbeComplete, false,
                       "cap hit before exhausting the tree")
        XCTAssertEqual(facts["few-files"]?.userDataProbeComplete, true,
                       "under the cap, exhaustive — complete")
    }

    func testProbeUnreadableBranchFailsClosed() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let entry = cachesRoot.appendingPathComponent("partially-locked")
        let sub = entry.appendingPathComponent("locked-sub")
        try mkdir(sub)
        try chmod000(sub)
        defer { restorePerms(sub) }

        let facts = factsByName(makeScanner())

        XCTAssertEqual(facts["partially-locked"]?.userDataProbeComplete, false,
                       "an unreadable branch means absence of matches is unproven")
    }

    func testNestedSymlinkMatchedByNameOnlyNeverTraversed() throws {
        let external = base.appendingPathComponent("external-user-data")
        try mkdir(external.appendingPathComponent("Photos Library.photoslibrary"))

        // An innocuously-named nested symlink: nothing from the target.
        let innocuous = cachesRoot.appendingPathComponent("has-innocuous-link")
        try mkdir(innocuous)
        try fm.createSymbolicLink(
            at: innocuous.appendingPathComponent("data-link"),
            withDestinationURL: external
        )
        // A nested symlink NAMED like user data: matched by name only.
        let named = cachesRoot.appendingPathComponent("has-named-link")
        try mkdir(named)
        try fm.createSymbolicLink(
            at: named.appendingPathComponent("Pictures"),
            withDestinationURL: external
        )

        let facts = factsByName(makeScanner())
        let innocuousFacts = try XCTUnwrap(facts["has-innocuous-link"])
        let namedFacts = try XCTUnwrap(facts["has-named-link"])

        XCTAssertTrue(innocuousFacts.userDataShapeMatches.isEmpty,
                      "external content provably not inspected")
        XCTAssertTrue(innocuousFacts.userDataProbeComplete,
                      "an untraversed symlink does not fail the probe closed — "
                      + "deleting the entry removes the link, never its target")
        XCTAssertEqual(namedFacts.userDataShapeMatches, ["pictures-directory"],
                       "matched by NAME only — the target's photoslibrary "
                       + "never surfaces")
    }
}

/// Thread-safe invocation recorder for the exclusion seams — tool-gate
/// names and probe commands alike (the closures are `@Sendable` by type;
/// the tests read after the synchronous enumeration returns).
private final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    func record(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(name)
    }
}
