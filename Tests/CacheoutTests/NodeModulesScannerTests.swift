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

    private func makeScanner(
        roots: [URL]? = nil,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> NodeModulesScanner {
        NodeModulesScanner(
            home: fixtureHome,
            searchRoots: roots ?? [container],
            provider: provider
        )
    }

    /// Forces `.failed` lstat probes for exact paths — hermetic stand-in for
    /// metadata failures that chmod tricks cannot reproduce deterministically.
    private final class FailingProbeProvider: FileSystemIdentityProvider {
        var failingPaths: Set<String> = []
        var failErrno: Int32 = EACCES

        override func probeKind(of url: URL) -> KindProbe {
            if failingPaths.contains(url.path) {
                return .failed(errno: failErrno)
            }
            return super.probeKind(of: url)
        }
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

    func testDescentMetadataFailureIsClassifiedNotSilentlySkipped() async throws {
        // A listed entry whose lstat fails must surface as a classified
        // issue, never be silently treated as "not a directory" (D6).
        let project = container.appendingPathComponent("projM")
        let boom = project.appendingPathComponent("boom")
        try mkdir(boom)

        let provider = FailingProbeProvider()
        // Foundation lists children with canonical (/private-resolved) URL
        // spellings — the probe sees that spelling, so fail on it.
        let canonicalBoom = provider.canonicalize(boom)
        provider.failingPaths = [canonicalBoom.path]

        let outcome = await makeScanner(provider: provider).scan()

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.errors.map(\.kind), [.permissionDenied])
        XCTAssertEqual(outcome.errors.first?.url, canonicalBoom)
    }

    func testCandidateMetadataFailureIsClassifiedNotTreatedAsNotFound() async throws {
        // node_modules exists and holds bytes, but its lstat probe fails:
        // that is a recorded issue and NO item — not a silent "not found".
        let project = container.appendingPathComponent("projC")
        let nm = project.appendingPathComponent("node_modules")
        try mkdir(nm)
        try writeFile(nm.appendingPathComponent("payload.js"), bytes: 4_096)

        let provider = FailingProbeProvider()
        // Foundation lists children with canonical (/private-resolved) URL
        // spellings — the candidate probe sees that spelling.
        let canonicalNM = provider.canonicalize(nm)
        provider.failingPaths = [canonicalNM.path]

        let outcome = await makeScanner(provider: provider).scan()

        XCTAssertTrue(outcome.items.isEmpty,
                      "an unprobeable candidate must not be sized or returned")
        XCTAssertEqual(outcome.errors.map(\.kind), [.permissionDenied])
        XCTAssertEqual(outcome.errors.first?.url, canonicalNM)
    }

    // MARK: - TCC-protected root gating (R9, fn-1.4)

    func testProtectedRootSkippedWhenExcludedIncludedWhenUserInitiated() async throws {
        // Matched by basename — a fixture root named "Documents" behaves
        // exactly like the real `~/Documents`.
        let docs = base.appendingPathComponent("Documents")
        let dep = docs.appendingPathComponent("proj/node_modules/dep")
        try mkdir(dep)
        try writeFile(dep.appendingPathComponent("index.js"))

        let scanner = makeScanner(roots: [docs])

        let automatic = await scanner.scan(includeProtectedRoots: false)
        XCTAssertTrue(automatic.items.isEmpty,
                      "an automatic scan must never enumerate a TCC-prompting root")
        XCTAssertTrue(automatic.errors.isEmpty,
                      "a policy skip is not a scan problem — deliberately silent")

        let userInitiated = await scanner.scan(includeProtectedRoots: true)
        XCTAssertEqual(userInitiated.items.map(\.projectName), ["proj"],
                       "user-initiated scans include protected roots")
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

        // Two classified captures where the old code swallowed both (D6):
        // the candidate lstat probe inside the unreadable dir (EACCES) and
        // the failed directory listing itself.
        XCTAssertFalse(outcome.errors.isEmpty,
                       "the old try?-swallow becomes a real classified capture (D6)")
        XCTAssertTrue(outcome.errors.allSatisfy { $0.kind == .permissionDenied },
                      "unexpected classification: \(outcome.errors)")
    }

    // MARK: - SpaceScanner conformance (fn-2.2)

    private func protocolScan(
        _ scanner: NodeModulesScanner? = nil,
        trigger: ScanTrigger = .userInitiated
    ) async -> ScanOutcome {
        await (scanner ?? makeScanner()).scan(
            context: ScanContext(trigger: trigger)
        )
    }

    func testProtocolScanEmitsSplitComponentsHiddenBytesAndRemoveItemAction() async throws {
        let visible = try makeProject("proj", payloadBytes: 6_000)
        let nm = container.appendingPathComponent("proj/node_modules")
        // pnpm keeps ~all bytes under node_modules/.pnpm — hidden files MUST
        // count (D3).
        try mkdir(nm.appendingPathComponent(".pnpm"))
        let hidden = try writeFile(
            nm.appendingPathComponent(".pnpm/store.bin"), bytes: 10_000
        )
        // A hardlinked pair proves the split is REAL: its bytes land in
        // estimatedUpToBytes, never collapsed into one number.
        let linkA = try writeFile(nm.appendingPathComponent("link-a.bin"))
        try fm.linkItem(at: linkA, to: nm.appendingPathComponent("link-b.bin"))

        let outcome = await protocolScan()

        XCTAssertEqual(outcome.items.count, 1)
        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.exactBytes, allocated(visible, hidden),
                       "unique-inode bytes (hidden .pnpm counted) are EXACT")
        XCTAssertEqual(item.estimatedUpToBytes, allocated(linkA),
                       "hardlinked bytes stay in the estimated component")
        XCTAssertEqual(item.allocatedBytes,
                       allocated(visible, hidden) + allocated(linkA))
        XCTAssertNil(item.logicalBytes,
                     "block rounding is noise, not sparse divergence")
        XCTAssertEqual(item.state, .measured)
        XCTAssertNil(item.scanError)
        XCTAssertEqual(item.action, .removeItem)
        XCTAssertTrue(item.evidence.contains("proj"),
                      "evidence carries the project name: \(item.evidence)")
        XCTAssertTrue(item.itemCount > 0)
    }

    func testProtocolScanCarriesLogicalBytesWhenSparseDiverges() async throws {
        try makeProject("sparse-proj", payloadBytes: 4_096)
        let nm = container.appendingPathComponent("sparse-proj/node_modules")
        let sparse = nm.appendingPathComponent("sparse.bin")
        fm.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 5_000_000)
        try handle.close()

        let outcome = await protocolScan()

        let item = try XCTUnwrap(outcome.items.first)
        let logical = try XCTUnwrap(
            item.logicalBytes,
            "sparse divergence (logical >> allocated) must be carried"
        )
        XCTAssertGreaterThanOrEqual(logical, 5_000_000)
        XCTAssertGreaterThan(logical, item.allocatedBytes,
                             "the carried figure is the divergence direction "
                                + "where deletion frees less than apparent size")
    }

    func testItemIDsStableAcrossRescansAndDerivedViaSharedHelper() async throws {
        try makeProject("proj")
        let provider = FileSystemIdentityProvider()
        let scanner = makeScanner(provider: provider)

        let first = await protocolScan(scanner)
        let second = await protocolScan(scanner)

        XCTAssertEqual(first.items.map(\.id), second.items.map(\.id),
                       "ids survive rescans — the UUID-per-scan defect is fixed")
        let item = try XCTUnwrap(first.items.first)
        XCTAssertNotNil(
            item.id.range(of: "^[0-9a-f]{64}$", options: .regularExpression),
            "full-hash contract: 64-char lowercase hex, no truncation: \(item.id)"
        )
        let canonical = provider.canonicalize(
            container.appendingPathComponent("proj/node_modules")
        )
        XCTAssertEqual(
            item.id,
            ReclaimableItem.stableID(
                scannerID: NodeModulesScanner.registeredID,
                canonicalPath: canonical.path
            ),
            "ids come from fn-2.1's SHARED helper — never a second derivation"
        )
    }

    func testOwnershipFieldsAndTrustedContainerRoots() async throws {
        try makeProject("proj")
        let scanner = makeScanner()

        let outcome = await protocolScan(scanner)

        for item in outcome.items {
            XCTAssertEqual(item.scannerID, NodeModulesScanner.registeredID)
        }
        XCTAssertEqual(outcome.items.map(\.displayName), ["proj"],
                       "displayName is the PROJECT name — the item's display "
                        + "identity today")
        XCTAssertEqual(scanner.id, "node_modules",
                       "the frozen CLI-addressable slug")
        XCTAssertEqual(scanner.trustedContainerRoots.map(\.path),
                       [container.path],
                       "declared container roots == the as-built search set")

        // The default-roots construction declares exactly its as-built
        // container search set too — what the production registry unions.
        let defaulted = NodeModulesScanner(home: fixtureHome)
        XCTAssertEqual(
            defaulted.trustedContainerRoots.map(\.path),
            NodeModulesScanner.defaultSearchRoots(home: fixtureHome).map(\.path)
        )
    }

    func testPolicyFieldsFrozenAndStalenessMatchesStaleBadgeLogic() async throws {
        try makeProject("stale-proj")
        let staleNM = container.appendingPathComponent("stale-proj/node_modules")
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -100 * 86_400)],
            ofItemAtPath: staleNM.path
        )
        try makeProject("fresh-proj")

        let outcome = await protocolScan()

        XCTAssertEqual(outcome.items.count, 2)
        for item in outcome.items {
            XCTAssertFalse(item.defaultSelected,
                           "node_modules is never auto-selected")
            XCTAssertFalse(item.automaticCleanEligible,
                           "CLI-visible must not mean auto-cleanable")
            XCTAssertEqual(item.risk, .review, "the frozen NEW risk mapping")
        }
        let stale = try XCTUnwrap(
            outcome.items.first { $0.displayName == "stale-proj" }
        )
        XCTAssertEqual(stale.isStale, true,
                       "100 days > the 30-day staleBadge threshold")
        XCTAssertTrue(stale.evidence.contains("last touched 3mo ago"),
                      "evidence carries the stale age: \(stale.evidence)")
        let fresh = try XCTUnwrap(
            outcome.items.first { $0.displayName == "fresh-proj" }
        )
        XCTAssertEqual(fresh.isStale, false,
                       "staleness APPLIES to fresh items — false, never nil")
        XCTAssertFalse(fresh.evidence.contains("last touched"))
    }

    func testAutomaticTriggerSkipsProtectedRootsUserInitiatedIncludesThem() async throws {
        // Parity with the legacy includeProtectedRoots gate (R9): the
        // context's derived flag maps onto the SAME gating.
        let docs = base.appendingPathComponent("Documents")
        let dep = docs.appendingPathComponent("proj/node_modules/dep")
        try mkdir(dep)
        try writeFile(dep.appendingPathComponent("index.js"))

        let scanner = makeScanner(roots: [docs])

        let automatic = await protocolScan(scanner, trigger: .automatic)
        XCTAssertTrue(automatic.items.isEmpty,
                      "an automatic scan must never enumerate a TCC-prompting root")
        XCTAssertTrue(automatic.errors.isEmpty,
                      "a policy skip is not a scan problem — deliberately silent")

        let userInitiated = await protocolScan(scanner, trigger: .userInitiated)
        XCTAssertEqual(userInitiated.items.map(\.displayName), ["proj"])
    }

    func testRootLevelProblemsAreOutcomeErrorsWithZeroItems() async throws {
        // A refused/denied SEARCH ROOT has no recognized candidate — the
        // epic's outcome-level error surface, proven by its canonical
        // producer.
        let external = base.appendingPathComponent("external")
        try mkdir(external)
        try makeProject("external-proj", under: external)
        let linkRoot = base.appendingPathComponent("link-root")
        try fm.createSymbolicLink(at: linkRoot, withDestinationURL: external)

        let symlinked = await protocolScan(makeScanner(roots: [linkRoot]))
        XCTAssertTrue(symlinked.items.isEmpty)
        XCTAssertEqual(symlinked.errors.map(\.kind), [.symlinkRoot])
        XCTAssertEqual(symlinked.errors.first?.url, linkRoot)

        // A search root whose lstat probe is denied: classified, zero items.
        try makeProject("proj")
        let provider = FailingProbeProvider()
        provider.failingPaths = [container.path]
        let denied = await protocolScan(makeScanner(provider: provider))
        XCTAssertTrue(denied.items.isEmpty)
        XCTAssertEqual(denied.errors.map(\.kind), [.permissionDenied])
    }

    func testScanIssueKindMappingIsExactlyOneToOne() {
        // All five NodeModulesScanIssue kinds, case-for-case, carrying the
        // same url and detail (epic error-surface contract).
        let url = URL(fileURLWithPath: "/tmp/x")
        let expectations: [(NodeModulesScanIssue.Kind, ScanIssue.Kind)] = [
            (.containerRefused, .containerRefused),
            (.symlinkRoot, .symlinkRoot),
            (.tccDenied, .tccDenied),
            (.permissionDenied, .permissionDenied),
            (.unreadable, .unreadable),
        ]
        for (legacy, unified) in expectations {
            let mapped = NodeModulesScanner.scanIssue(
                from: NodeModulesScanIssue(url: url, kind: legacy, detail: "d")
            )
            XCTAssertEqual(mapped.kind, unified)
            XCTAssertEqual(mapped.url, url)
            XCTAssertEqual(mapped.detail, "d")
        }
    }

    func testFullyDeniedCandidateEmitsDeniedItemNotOutcomeError() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        try makeProject("locked-proj")
        let nm = container.appendingPathComponent("locked-proj/node_modules")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nm.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nm.path)
        }

        let outcome = await protocolScan()

        XCTAssertEqual(outcome.items.count, 1,
                       "a recognized candidate is EMITTED, never suppressed")
        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .denied)
        XCTAssertEqual(item.scanError?.kind, .permissionDenied)
        XCTAssertEqual(item.exactBytes, 0)
        XCTAssertEqual(item.estimatedUpToBytes, 0)
        XCTAssertEqual(item.itemCount, 0)
        XCTAssertTrue(outcome.errors.isEmpty,
                      "candidate-attributable denials ride the ITEM, never "
                        + "the outcome: \(outcome.errors)")
        XCTAssertEqual(outcome.items.first?.rootRecords.map(\.status),
                       [.deniedUnmeasured])
    }

    func testEmptyCandidateEmitsEmptyItemNotSuppressed() async throws {
        let nm = container.appendingPathComponent("empty-proj/node_modules")
        try mkdir(nm)

        let outcome = await protocolScan()

        XCTAssertEqual(outcome.items.count, 1,
                       ".empty is an honest terminal state, not a suppression")
        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .empty)
        XCTAssertNil(item.scanError)
        XCTAssertEqual(item.exactBytes, 0)
        XCTAssertEqual(item.estimatedUpToBytes, 0)
        XCTAssertEqual(item.itemCount, 0)
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertEqual(item.rootRecords.map(\.status), [.measured],
                       "clean-empty walks count as measured (frozen truth table)")
    }

    func testPartiallyDeniedCandidateCarriesReadablePortionOnTheItem() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let readable = try makeProject("partial-proj", payloadBytes: 4_096)
        let nm = container.appendingPathComponent("partial-proj/node_modules")
        let locked = nm.appendingPathComponent("locked")
        try mkdir(locked)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let outcome = await protocolScan()

        XCTAssertEqual(outcome.items.count, 1)
        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .partiallyDenied,
                       "denial + measurable content is NOT .measured")
        XCTAssertNotNil(item.scanError)
        XCTAssertEqual(item.exactBytes, allocated(readable),
                       "the readable portion's components are carried")
        XCTAssertTrue(outcome.errors.isEmpty,
                      "partial denial rides the item, never the outcome: "
                        + "\(outcome.errors)")
        XCTAssertEqual(item.rootRecords.map(\.status), [.measured],
                       "partial walks that measured anything count as measured")
    }

    func testContainerItemDescriptorCarriesUnresolvedDiscoveredPath() async throws {
        // The search root keeps the temp dir's UNRESOLVED spelling
        // (/var/… vs the canonical /private/var/…), and the candidate sits
        // directly at the root — so its discovered spelling provably keeps
        // the unresolved prefix (leaf never resolved, fn-1 doctrine).
        try mkdir(container.appendingPathComponent("node_modules/dep"))
        try writeFile(container.appendingPathComponent("node_modules/dep/index.js"))
        // Computed AFTER creation so Foundation's directory-hint behavior
        // matches the spelling the scanner discovers at scan time.
        let requested = container.appendingPathComponent("node_modules")
        let provider = FileSystemIdentityProvider()

        let outcome = await protocolScan(makeScanner(provider: provider))

        let item = try XCTUnwrap(outcome.items.first)
        guard case .containerItem(let origin, let target) = item.admission else {
            return XCTFail("node_modules items carry the frozen .containerItem "
                            + "arm, got \(item.admission)")
        }
        XCTAssertEqual(target, requested,
                       "requestedTargetURL is the candidate's OWN unresolved "
                        + "discovered path — never resolved, never the display url")
        XCTAssertEqual(origin, container,
                       "origin container provenance from the fn-1.2 traversal")
        let record = try XCTUnwrap(item.rootRecords.first)
        XCTAssertEqual(record.requestedURL, requested)
        XCTAssertEqual(record.resolvedURL, provider.canonicalize(requested))
        XCTAssertEqual(item.url, provider.canonicalize(requested),
                       "display url is the RESOLVED spelling")
    }

    func testAliasedSearchRootsYieldOneItemAndSurviveValidation() async throws {
        // The /var/… and /private/var/… spellings of the SAME root both
        // admit and both discover the direct candidate — under two
        // unresolved spellings. Dedupe must key on the CANONICAL path
        // (review r2): duplicate canonical-derived stable ids would render
        // the WHOLE outcome malformed at the runtime validator, hiding
        // every discovered item.
        try mkdir(container.appendingPathComponent("node_modules/dep"))
        try writeFile(container.appendingPathComponent("node_modules/dep/index.js"))
        let provider = FileSystemIdentityProvider()
        let canonical = provider.canonicalize(container)
        try XCTSkipIf(canonical.path == container.path,
                      "temp dir not symlink-aliased in this environment")
        let scanner = NodeModulesScanner(
            home: fixtureHome,
            searchRoots: [container, canonical],
            provider: provider
        )

        let outcome = await protocolScan(scanner)

        XCTAssertEqual(outcome.items.count, 1,
                       "aliased spellings collapse to ONE item")
        XCTAssertEqual(Set(outcome.items.map(\.id)).count, outcome.items.count,
                       "ids unique within the outcome (R7 invariant)")

        // And through the validated stream: never a malformed outcome.
        let runtime = try SpaceScannerRuntime(
            scanners: [scanner], categories: [],
            home: fixtureHome, provider: provider
        )
        var events: [ValidatedScannerEvent] = []
        for await event in runtime.scanValidated(
            context: ScanContext(trigger: .userInitiated)
        ) {
            events.append(event)
        }
        guard events.count == 1,
              case .outcome(let scannerID, let validated) = events[0] else {
            return XCTFail("aliased roots must not render the outcome "
                            + "malformed: \(events)")
        }
        XCTAssertEqual(scannerID, NodeModulesScanner.registeredID)
        XCTAssertEqual(validated.items.count, 1)
    }

    func testDisplayPathShorteningRequiresComponentBoundary() async throws {
        // A sibling that merely string-prefixes the home path must NOT
        // shorten (/Users/d-other beside /Users/d — review r1): the full
        // path renders, never "~-sibling/…".
        let sibling = base.appendingPathComponent("home-sibling")
        let dep = sibling.appendingPathComponent("proj/node_modules/dep")
        try mkdir(dep)
        try writeFile(dep.appendingPathComponent("index.js"))

        let outside = await protocolScan(
            NodeModulesScanner(home: fixtureHome, searchRoots: [sibling])
        )
        let outsideItem = try XCTUnwrap(outside.items.first)
        XCTAssertFalse(outsideItem.declaredDisplayPath.hasPrefix("~"),
                       "no boundary, no shortening: "
                        + outsideItem.declaredDisplayPath)
        XCTAssertTrue(
            outsideItem.declaredDisplayPath.hasSuffix("home-sibling/proj"),
            outsideItem.declaredDisplayPath
        )

        // A genuine descendant of home shortens at the component boundary.
        // Home is injected in its canonical spelling because Foundation
        // lists descendants canonically (/private-resolved).
        let canonicalHome = FileSystemIdentityProvider().canonicalize(fixtureHome)
        let code = canonicalHome.appendingPathComponent("Code")
        let dep2 = code.appendingPathComponent("proj2/node_modules/dep")
        try mkdir(dep2)
        try writeFile(dep2.appendingPathComponent("index.js"))

        let inside = await protocolScan(
            NodeModulesScanner(home: canonicalHome, searchRoots: [code])
        )
        let insideItem = try XCTUnwrap(inside.items.first)
        XCTAssertEqual(insideItem.declaredDisplayPath, "~/Code/proj2")
    }

    func testRootScanRecordMappingAcrossAllFourCandidateStates() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        // empty
        try mkdir(container.appendingPathComponent("empty_p/node_modules"))
        // measured
        try makeProject("measured_p")
        // partially denied
        try makeProject("partial_p")
        let partialLocked = container
            .appendingPathComponent("partial_p/node_modules/locked")
        try mkdir(partialLocked)
        try fm.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: partialLocked.path
        )
        // denied
        try makeProject("denied_p")
        let deniedNM = container.appendingPathComponent("denied_p/node_modules")
        try fm.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: deniedNM.path
        )
        defer {
            try? fm.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: partialLocked.path
            )
            try? fm.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: deniedNM.path
            )
        }
        let provider = FileSystemIdentityProvider()

        let outcome = await protocolScan(makeScanner(provider: provider))

        XCTAssertEqual(outcome.items.count, 4)
        let expectations: [(name: String, state: ScanState, status: RootScanStatus)] = [
            ("empty_p", .empty, .measured),
            ("measured_p", .measured, .measured),
            ("partial_p", .partiallyDenied, .measured),
            ("denied_p", .denied, .deniedUnmeasured),
        ]
        for expected in expectations {
            let item = try XCTUnwrap(
                outcome.items.first { $0.displayName == expected.name },
                "missing item for \(expected.name)"
            )
            XCTAssertEqual(item.state, expected.state, expected.name)
            let record = try XCTUnwrap(item.rootRecords.first, expected.name)
            XCTAssertEqual(item.rootRecords.count, 1,
                           "per-item scanners carry a SINGLE-element record")
            XCTAssertEqual(record.status, expected.status, expected.name)
            XCTAssertTrue(
                record.requestedURL.path
                    .hasSuffix("\(expected.name)/node_modules"),
                "requestedURL is the discovered candidate path: "
                    + record.requestedURL.path
            )
            XCTAssertEqual(record.resolvedURL,
                           provider.canonicalize(record.requestedURL),
                           "resolvedURL is the canonical form")
            guard case .containerItem(_, let target) = item.admission else {
                XCTFail("\(expected.name): expected .containerItem")
                continue
            }
            XCTAssertEqual(target, record.requestedURL,
                           "one unresolved spelling feeds BOTH the record and "
                            + "the deletion descriptor")
        }
    }

    // MARK: - Mount boundaries fold into item state (R15, PR #455 P2)

    /// Marks chosen inodes as mount points while keeping real devices —
    /// hermetic stand-in for a volume mounted inside a candidate (the same
    /// injection seam `DirectorySizerTests` uses).
    private final class MountPointInjectingProvider: FileSystemIdentityProvider {
        var mountPointInodes: Set<UInt64> = []

        override func isMountPoint(_ url: URL) -> Bool {
            if let id = identity(of: url), mountPointInodes.contains(id.inode) {
                return true
            }
            return super.isMountPoint(url)
        }
    }

    func testCandidateWithMountedSubtreeIsDeniedNotCleanable() async throws {
        // The cleaner refuses the WHOLE target at delete time whenever ANY
        // boundary sits in the tree (`removeGuardedItem`, R15) — so the
        // scan must publish the item as `.denied` (visible, never
        // cleanable), NOT `.partiallyDenied`: that state's manual
        // selection and `clean_with_warning` plan verb would promise a
        // partial clean the confirmed run categorically refuses (PR #455
        // P2).
        try makeProject("mounted-sub", payloadBytes: 4_096)
        let nm = container.appendingPathComponent("mounted-sub/node_modules")
        let mounted = nm.appendingPathComponent("mounted-volume")
        try mkdir(mounted)
        try writeFile(mounted.appendingPathComponent("beyond.bin"), bytes: 8_192)

        let provider = MountPointInjectingProvider()
        let inode = try XCTUnwrap(provider.identity(of: mounted)?.inode)
        provider.mountPointInodes.insert(inode)

        let outcome = await protocolScan(makeScanner(provider: provider))

        XCTAssertEqual(outcome.items.count, 1)
        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .denied,
                       "boundary-bearing items are non-cleanable regardless "
                        + "of measured sibling bytes — never a state any "
                        + "surface presents as cleanable")
        XCTAssertEqual(item.scanError?.kind, .other,
                       "no new wire kind: boundary is neither TCC nor BSD "
                        + "permissions")
        XCTAssertTrue(
            item.scanError?.message.contains("mounted-volume") == true
                && item.scanError?.message.contains("mount boundary") == true,
            "the error names the boundary: \(String(describing: item.scanError))"
        )
        XCTAssertTrue(
            item.scanError?.message.contains("not reclaimable") == true,
            "the readable siblings' measured floor is preserved in the "
                + "message — real information relocated, not discarded: "
                + "\(String(describing: item.scanError))"
        )
        XCTAssertEqual(item.exactBytes, 0,
                       "components mean 'deletion frees these' — the whole "
                        + "target is refused, so zero is the honest figure")
        XCTAssertEqual(item.estimatedUpToBytes, 0)
        XCTAssertEqual(item.itemCount, 0)
        XCTAssertNil(item.logicalBytes)
        XCTAssertEqual(item.rootRecords.map(\.status), [.deniedUnmeasured],
                       "the deletability boundary: nothing deletable was "
                        + "established")
        XCTAssertEqual(CLIHandler.cleanPlanAction(for: item), "refuse",
                       "dry-run and confirmation say what the confirmed run "
                        + "does — refuse, never clean_with_warning")
        XCTAssertTrue(outcome.errors.isEmpty,
                      "candidate-attributable boundaries ride the ITEM, "
                        + "never the outcome: \(outcome.errors)")
    }

    func testCandidateThatIsAMountPointIsDeniedNotEmpty() async throws {
        // A candidate that IS a mount point is never enumerated
        // (`rootMountBoundary`) and never deletable — `.denied`, not a
        // clean-looking `.empty`.
        let nm = container.appendingPathComponent("mount-root/node_modules")
        try mkdir(nm)
        try writeFile(nm.appendingPathComponent("payload.bin"), bytes: 8_192)

        let provider = MountPointInjectingProvider()
        let inode = try XCTUnwrap(provider.identity(of: nm)?.inode)
        provider.mountPointInodes.insert(inode)

        let outcome = await protocolScan(makeScanner(provider: provider))

        XCTAssertEqual(outcome.items.count, 1)
        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .denied,
                       "nothing measurable, nothing deletable — never .empty")
        XCTAssertEqual(item.scanError?.kind, .other)
        XCTAssertTrue(
            item.scanError?.message.contains("mount point") == true,
            "the error names the refusal: \(String(describing: item.scanError))"
        )
        XCTAssertEqual(item.exactBytes, 0)
        XCTAssertEqual(item.estimatedUpToBytes, 0)
        XCTAssertEqual(item.itemCount, 0,
                       "the tree behind the boundary was never enumerated")
        XCTAssertNil(item.logicalBytes)
        XCTAssertEqual(item.rootRecords.map(\.status), [.deniedUnmeasured])
        XCTAssertTrue(outcome.errors.isEmpty)
    }

    func testBoundaryStatesSurviveRuntimeValidation() async throws {
        // Both boundary shapes must pass the runtime's state-coherence
        // validator (checks (d)/(e)) end-to-end through scanValidated —
        // a malformed outcome would hide EVERY discovered item.
        try makeProject("mounted-sub", payloadBytes: 4_096)
        let nm = container.appendingPathComponent("mounted-sub/node_modules")
        let mounted = nm.appendingPathComponent("mounted-volume")
        try mkdir(mounted)
        let rootBoundaryNM = container
            .appendingPathComponent("mount-root/node_modules")
        try mkdir(rootBoundaryNM)

        let provider = MountPointInjectingProvider()
        let mountedInode = try XCTUnwrap(provider.identity(of: mounted)?.inode)
        let rootInode = try XCTUnwrap(
            provider.identity(of: rootBoundaryNM)?.inode
        )
        provider.mountPointInodes = [mountedInode, rootInode]

        let runtime = try SpaceScannerRuntime(
            scanners: [makeScanner(provider: provider)], categories: [],
            home: fixtureHome, provider: provider
        )
        var events: [ValidatedScannerEvent] = []
        for await event in runtime.scanValidated(
            context: ScanContext(trigger: .userInitiated)
        ) {
            events.append(event)
        }
        guard events.count == 1,
              case .outcome(_, let validated) = events[0] else {
            return XCTFail("boundary states must not render the outcome "
                            + "malformed: \(events)")
        }
        XCTAssertEqual(validated.items.count, 2)
        XCTAssertEqual(Set(validated.items.map(\.state)), [.denied],
                       "BOTH boundary shapes — root mount point and nested "
                        + "boundary beside measured content — publish the "
                        + "non-cleanable .denied shape and pass checks "
                        + "(d)/(e)/(f) verbatim")
    }

    func testBoundaryDeniedItemIsRefusedWholeByCleanerAndLeftOnDisk() async throws {
        // End-to-end honesty (PR #455 P2): the plan verb (`refuse`), the
        // cleaner's pre-dispatch R18 state refusal, and the on-disk outcome
        // all agree — no deletion entry, one SURFACED item error, and the
        // readable siblings stay untouched (a boundary refusal is total,
        // never a partial clean).
        let payload = try makeProject("mounted-sub", payloadBytes: 4_096)
        let nm = container.appendingPathComponent("mounted-sub/node_modules")
        let mounted = nm.appendingPathComponent("mounted-volume")
        try mkdir(mounted)

        let provider = MountPointInjectingProvider()
        let inode = try XCTUnwrap(provider.identity(of: mounted)?.inode)
        provider.mountPointInodes.insert(inode)

        let runtime = try SpaceScannerRuntime(
            scanners: [makeScanner(provider: provider)], categories: [],
            home: fixtureHome, provider: provider
        )
        var items: [ReclaimableItem] = []
        for await event in runtime.scanValidated(
            context: ScanContext(trigger: .userInitiated)
        ) {
            if case .outcome(_, let outcome) = event { items = outcome.items }
        }
        let item = try XCTUnwrap(items.first, "the validated item publishes")
        XCTAssertEqual(item.state, .denied)

        let cleaner = runtime.makeCleaner()
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty,
                      "no deletion entry — nothing was freed")
        XCTAssertEqual(report.errors.count, 1,
                       "the refusal SURFACES as an item error (R18), never "
                        + "a silent skip")
        XCTAssertEqual(report.errors.first?.key, item.key)
        XCTAssertTrue(
            report.errors.first?.message.contains("refused") == true,
            "the error says refusal: \(String(describing: report.errors.first))"
        )
        XCTAssertTrue(fm.fileExists(atPath: payload.path),
                      "the readable payload is untouched — whole-target "
                        + "refusal, not partial deletion")
    }

    // MARK: - Cooperative cancellation (PR #455 P2)

    func testCancelledWalkStopsBeforeRecognizingCandidates() async throws {
        // The traversal checks `Task.isCancelled` at every node: a walk
        // whose task is cancelled must STOP instead of running its full
        // 10-30s course orphaned. (The runtime cancels the producer at
        // stream termination, and the ViewModel now holds its scan guard
        // until the walk actually returns — this pins the "returns
        // promptly" half of that contract.)
        try makeProject("proj")

        // Sanity: the same fixture IS discoverable by a live walk.
        let live = await protocolScan()
        XCTAssertEqual(live.items.count, 1)

        let scanner = makeScanner()
        let cancelled = await Task { () -> ScanOutcome in
            // Deterministic ordering: cancel SELF before the walk begins,
            // so the very first traversal node observes the cancellation.
            withUnsafeCurrentTask { $0?.cancel() }
            return await scanner.scan(
                context: ScanContext(trigger: .userInitiated)
            )
        }.value

        XCTAssertTrue(cancelled.items.isEmpty,
                      "a cancelled walk recognizes no candidates")
        XCTAssertTrue(
            cancelled.errors.isEmpty,
            "cancellation truncation is silent — results after termination "
                + "are discarded, so it is never a classified scan problem"
        )
    }
}
