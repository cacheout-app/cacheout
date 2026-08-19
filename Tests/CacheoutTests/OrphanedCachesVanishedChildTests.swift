import XCTest
@testable import Cacheout

/// ABSENCE OF A NAME IS NOT ABSENCE OF CONTENT
/// (PR #458 review, thread `PRRT_kwDORmg6_86ZmmYY`).
///
/// Lives in its own file rather than in `OrphanedCachesScannerTests` only
/// because that file was being edited concurrently when these were written;
/// the fixtures follow the same discipline as everything there — REAL
/// syscalls (`rename(2)`, `mkdirat(2)`) fired single-threaded at one
/// deterministic instant inside the PRODUCTION walk, no sleeps, no threads.
final class OrphanedCachesVanishedChildTests: XCTestCase {

    private var base: URL!
    private var cachesRoot: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("cacheout-vanish-\(UUID().uuidString)")
        cachesRoot = base.appendingPathComponent("Library/Caches")
        try fm.createDirectory(at: cachesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - The discovery-time vanish

    /// A subtree RENAMED between `boundedChildNames` reading the directory and
    /// the per-name `fstatat` is not gone: it is still inside the tree the
    /// deletion is about to remove, under a name the captured `names` array
    /// never held and the walk will therefore never visit.
    ///
    /// The seam is `WalkEvent.didEnumerate`, emitted after the read and before
    /// the child loop — the exact window the race lives in. The rename is a
    /// real `rename(2)`; `Documents` under the new name is real content that a
    /// `complete, matches: []` verdict would hand to Quick Clean with no
    /// confirmation.
    func testASubtreeRenamedAfterTheDirectoryReadIsNotReportedClean() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.Vanish")
        let discovered = entry.appendingPathComponent("sub")
        try mkdir(discovered.appendingPathComponent("Documents"))
        let hidden = entry.appendingPathComponent("renamed-after-the-read")

        var armed = false
        var enumeratedNames: [String] = []
        let probe = OrphanedCachesScanner.boundedUserDataShapeWalk(
            at: entry, provider: FileSystemIdentityProvider(),
            entryLimit: OrphanedCachesScanner.defaultProbeEntryLimit
        ) { event in
            guard case .didEnumerate(_, let names) = event, !armed else { return }
            armed = true
            enumeratedNames = names
            XCTAssertEqual(rename(discovered.path, hidden.path), 0,
                           "fixture rename failed: \(errno)")
        }

        XCTAssertTrue(armed, "the fixture never armed the rename")
        XCTAssertEqual(enumeratedNames, ["sub"],
                       "the captured read must not contain the new name")
        // The content is STILL THERE, inside the tree the deletion targets.
        XCTAssertTrue(
            fm.fileExists(atPath: hidden.appendingPathComponent("Documents").path),
            "fixture precondition: the subtree survived the rename"
        )
        XCTAssertTrue(
            probe.matches.isEmpty,
            "the walk never descended into the renamed subtree, so it cannot "
                + "claim a match either way: \(probe.matches)"
        )
        XCTAssertFalse(
            probe.complete,
            "UNINSPECTED IS NOT CLEAN: a `complete` verdict with no matches "
                + "sets automaticCleanEligible and Quick Clean deletes the "
                + "renamed subtree's Documents tree with no confirmation"
        )
        XCTAssertEqual(
            probe.obstructions, [.transientFailure],
            "a rename is retryable — the next scan reads the subtree under "
                + "its new name and completes"
        )
        XCTAssertTrue(
            OrphanedCachesScanner.remediationGuidance(for: probe.obstructions)
                .hasSuffix("Re-scan and try again."),
            OrphanedCachesScanner.remediationGuidance(for: probe.obstructions)
        )
    }

    /// The same rule ONE STEP LATER, kept beside its partner so the two
    /// cannot drift apart again: a name already PROVEN to be a directory that
    /// disappears before the descent `openat` has always been an obstruction.
    /// Both sites now route the same errno through `obstruction(forErrno:)`,
    /// which is the whole of the rule.
    func testBothDisappearanceSitesClassifyTheSameErrnoIdentically() {
        XCTAssertEqual(OrphanedCachesScanner.obstruction(forErrno: ENOENT),
                       .transientFailure)
        XCTAssertEqual(OrphanedCachesScanner.obstruction(forErrno: ENOTDIR),
                       .transientFailure)
    }

    /// The delete-time entry point carries the same verdict — this is the one
    /// `CacheCleaner` consults, and an incomplete probe is what stops the
    /// automatic path.
    func testTheDeleteTimeProbeCarriesTheVanishObstruction() throws {
        let entry = cachesRoot.appendingPathComponent("com.example.VanishDelete")
        let discovered = entry.appendingPathComponent("sub")
        try mkdir(discovered.appendingPathComponent("Documents"))
        let hidden = entry.appendingPathComponent("hidden")

        final class RenameOnFirstChildProbe: FileSystemIdentityProvider {
            var from: URL!
            var to: URL!
            private(set) var fired = false
            override func probeChild(
                inDirectory descriptor: Int32, named name: String,
                logical: @autoclosure () -> URL
            ) -> ChildProbe {
                if !fired, name == from.lastPathComponent {
                    fired = true
                    _ = rename(from.path, to.path)
                }
                return super.probeChild(
                    inDirectory: descriptor, named: name, logical: logical()
                )
            }
        }

        let provider = RenameOnFirstChildProbe()
        provider.from = discovered
        provider.to = hidden
        let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
            at: entry, provider: provider
        )
        XCTAssertTrue(provider.fired, "the fixture never armed the rename")
        XCTAssertFalse(probe.complete, "\(probe.obstructions)")
        XCTAssertEqual(probe.obstructions, [.transientFailure])
    }
}
