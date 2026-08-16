import XCTest
@testable import Cacheout

/// Hermetic tests for the fn-3.2 sweep classification engine
/// (`OrphanedCacheClassifier`). PURE LOGIC — no filesystem access, no
/// fixtures, no disk: every `SweptCacheEntry` is constructed directly as data (the
/// URLs are never touched), the clock and the installed-app predicate are
/// injected.
///
/// Evidence-string brittleness stance (task spec): `ByteCountFormatter`
/// output is locale-sensitive, so size substrings asserted here are DERIVED
/// from the same shared formatter rather than hard-coded; day counts and
/// the other frozen evidence shapes are asserted exactly.
final class OrphanedCacheClassifierTests: XCTestCase {

    // MARK: - Fixed clock and thresholds

    /// Arbitrary fixed instant — the classifier never reads the ambient
    /// current date, so nothing here depends on when the tests run.
    private let fixedNow = Date(timeIntervalSince1970: 1_754_500_000)

    private let defaultFloor: Int64 = 50_000_000 // 50 MB (decimal)
    private let defaultStaleAge: TimeInterval = 60 * 86_400 // 60 days

    private func date(daysBeforeNow days: Double) -> Date {
        fixedNow.addingTimeInterval(-days * 86_400)
    }

    /// Expected evidence size text, derived from the SAME shared formatter
    /// the classifier uses (locale-robust by construction).
    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.sharedFile.string(fromByteCount: bytes)
    }

    // MARK: - Entry / classifier builders (pure data, zero disk)

    private func makeEntry(
        name: String,
        exactBytes: Int64 = 0,
        estimatedUpToBytes: Int64 = 0,
        newestContentDate: Date? = nil,
        denials: [SizeDenial] = [],
        mountBoundaries: [URL] = [],
        rootMountBoundary: Bool = false,
        userDataShapeMatches: [String] = [],
        userDataProbeComplete: Bool = true
    ) -> SweptCacheEntry {
        SweptCacheEntry(
            name: name,
            url: URL(fileURLWithPath: "/fixture/home/Library/Caches/\(name)"),
            exactBytes: exactBytes,
            estimatedUpToBytes: estimatedUpToBytes,
            logicalBytes: exactBytes + estimatedUpToBytes,
            itemCount: 1,
            newestContentDate: newestContentDate,
            denials: denials,
            mountBoundaries: mountBoundaries,
            rootMountBoundary: rootMountBoundary,
            userDataShapeMatches: userDataShapeMatches,
            userDataProbeComplete: userDataProbeComplete
        )
    }

    /// Default predicate answers `.installed` (the neutral answer: never
    /// orphan, no extra evidence). Tests that exercise the resolver pass
    /// their own.
    private func makeClassifier(
        sizeFloorBytes: Int64? = nil,
        staleAge: TimeInterval? = nil,
        installedAppStatus: @escaping (String) -> InstalledAppStatus = { _ in .installed }
    ) -> OrphanedCacheClassifier {
        OrphanedCacheClassifier(
            thresholds: OrphanedCacheClassifier.Thresholds(
                sizeFloorBytes: sizeFloorBytes ?? defaultFloor,
                staleAge: staleAge ?? defaultStaleAge
            ),
            installedAppStatus: installedAppStatus,
            now: fixedNow
        )
    }

    private func tccDenial(_ path: String = "/fixture/denied") -> SizeDenial {
        SizeDenial(url: URL(fileURLWithPath: path), kind: .tcc, detail: "EPERM")
    }

    private func permissionDenial(_ path: String = "/fixture/denied") -> SizeDenial {
        SizeDenial(url: URL(fileURLWithPath: path), kind: .permission, detail: "EACCES")
    }

    private func unaddressableDenial(
        _ path: String = "/fixture/deep"
    ) -> SizeDenial {
        SizeDenial(
            url: URL(fileURLWithPath: path), kind: .unaddressablePath,
            detail: "this folder runs deeper than an absolute path can address"
        )
    }

    // MARK: - Evidence names the real cause (PR #458 review)

    /// "Couldn't fully scan: some content was unreadable" was FALSE for a
    /// tree past `PATH_MAX`: every byte is readable by anything that walks
    /// with descriptors, which the probe and the deletion both now do. Only
    /// the SIZING failed. The evidence has to say which, or the user goes
    /// looking for a permission that was never missing — and, worse, assumes
    /// the item cannot be deleted, which is the state this whole review
    /// round is about.
    func testUnaddressablePathEvidenceNamesSizingNotReadability() throws {
        let lines = OrphanedCacheClassifier.denialEvidence(
            [unaddressableDenial()]
        )
        XCTAssertEqual(lines.count, 1, "\(lines)")
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("couldn't measure its size"), line)
        XCTAssertFalse(
            line.contains("unreadable"),
            "nothing here is unreadable — the sizer just cannot spell it: "
                + line
        )
        // BOTH CAUSES, because one KIND carries both (PR #458 review r11,
        // thread `PRRT_kwDORmg6_86Zn1Ph`). Naming only the length sends a
        // user to shorten a path that was never long, when the real cause
        // was a symlink cycle.
        XCTAssertTrue(line.contains("too long"), line)
        XCTAssertTrue(line.contains("too many symbolic links"), line)
        // The intent this line was added for survives: not a permission.
        XCTAssertTrue(line.contains("not a permission problem"), line)
        // And the deletion promise is NOT made from a kind that cannot tell
        // a path-length overflow from a cycle ABOVE the deletion target —
        // the second defeats `DepthSafeRemoval`'s one resolved path
        // (measured in `DirectorySizerTests`).
        XCTAssertFalse(line.contains("deleting it still works"), line)
    }

    /// It is still fail-closed: an unmeasurable entry is never auto-clean
    /// eligible, whatever the message says.
    func testUnaddressablePathStillForcesTheEntryOffSafe() {
        let classifier = makeClassifier(installedAppStatus: { _ in .unknown })
        let entry = makeEntry(
            name: "com.apple.SwiftUI.Drag.\(UUID().uuidString)",
            denials: [unaddressableDenial()]
        )
        let classification = classifier.classify(entry)
        XCTAssertNotEqual(classification.risk, .safe)
        XCTAssertFalse(classification.automaticCleanEligible)
    }

    // MARK: - R1: leak glob

    func testDragUUIDNamesAreKnownLeakSafeWithExactEvidence() {
        let classifier = makeClassifier(installedAppStatus: { _ in
            XCTFail("resolver must not be consulted for a leak-glob match")
            return .unknown
        })
        // TWO different UUID names — the table entry is a glob, not a path
        // (the field machine had two distinct Drag-UUID dirs).
        let names = [
            "com.apple.SwiftUI.Drag-C39B49C5-2E55-4A10-9F35-1D3E5A6B7C8D",
            "com.apple.SwiftUI.Drag-0F0F0F0F-1111-2222-3333-444455556666",
        ]
        for name in names {
            let result = classifier.classify(makeEntry(name: name, exactBytes: 31_000_000_000))
            XCTAssertEqual(result.tier, .knownLeak, name)
            XCTAssertEqual(result.risk, .safe, name)
            XCTAssertEqual(
                result.evidence,
                ["matches leak pattern com.apple.SwiftUI.Drag-* (drag payload cache)"],
                name
            )
            XCTAssertTrue(result.defaultSelected, name)
            XCTAssertTrue(result.automaticCleanEligible, name)
        }
    }

    func testNonLeakNameDoesNotMatchGlob() {
        // Similar but not matching: the glob is anchored to the full name.
        let result = makeClassifier().classify(
            makeEntry(name: "org.example.SwiftUI.Drag-1234")
        )
        XCTAssertNotEqual(result.tier, .knownLeak)
    }

    // MARK: - R2: orphan tier (tri-state resolution)

    func testBundleIdShapedNotInstalledIsOrphanReview() {
        let classifier = makeClassifier(installedAppStatus: { _ in .notInstalled })
        let result = classifier.classify(makeEntry(name: "com.foo.bar", exactBytes: 1_000))
        XCTAssertEqual(result.tier, .orphan)
        XCTAssertEqual(result.risk, .review)
        // The epic's frozen prefix, plus the basis parenthetical (PR #456
        // review P2): the evidence names WHAT was searched instead of
        // asserting bare global absence. fn-3.4's e2e asserts the frozen
        // prefix as a substring, so the addition must stay append-only.
        XCTAssertEqual(result.evidence, [
            "no installed app for bundle id com.foo.bar"
                + " (checked LaunchServices, Spotlight, and standard app folders)"
        ])
        XCTAssertFalse(result.defaultSelected)
        XCTAssertFalse(result.automaticCleanEligible)
    }

    func testInstalledBundleIdIsNotOrphan() {
        let classifier = makeClassifier(installedAppStatus: { _ in .installed })
        // Over both stale-large thresholds so the fallthrough is visible.
        let stale = classifier.classify(makeEntry(
            name: "com.live.app",
            exactBytes: defaultFloor,
            newestContentDate: date(daysBeforeNow: 190)
        ))
        XCTAssertEqual(stale.tier, .staleLarge)
        XCTAssertFalse(stale.evidence.contains { $0.contains("no installed app") })

        // Under thresholds: unclassified, still no orphan evidence.
        let small = classifier.classify(makeEntry(name: "com.live.app", exactBytes: 1_000))
        XCTAssertEqual(small.tier, .unclassified)
        XCTAssertFalse(small.evidence.contains { $0.contains("no installed app") })
    }

    func testUnknownResolutionNeverOrphanAndCarriesIncompleteResolutionEvidence() {
        let classifier = makeClassifier(installedAppStatus: { _ in .unknown })

        // Over both thresholds → falls through to staleLarge WITH the note.
        let stale = classifier.classify(makeEntry(
            name: "com.gone.app",
            exactBytes: defaultFloor,
            newestContentDate: date(daysBeforeNow: 190)
        ))
        XCTAssertEqual(stale.tier, .staleLarge)
        XCTAssertFalse(stale.evidence.contains { $0.contains("no installed app") })
        XCTAssertTrue(stale.evidence.contains("couldn't determine whether an app is installed"))

        // Under thresholds → falls through to unclassified WITH the note.
        let small = classifier.classify(makeEntry(name: "com.gone.app", exactBytes: 1_000))
        XCTAssertEqual(small.tier, .unclassified)
        XCTAssertEqual(small.risk, .review)
        XCTAssertTrue(small.evidence.contains("couldn't determine whether an app is installed"))
        XCTAssertFalse(small.defaultSelected)
        XCTAssertFalse(small.automaticCleanEligible)
    }

    func testBareNamesNeverOrphanAndNeverConsultResolver() {
        var consulted: [String] = []
        let classifier = makeClassifier(installedAppStatus: { name in
            consulted.append(name)
            return .notInstalled
        })
        for name in ["pnpm", "Homebrew", "go-build", "com.foo"] {
            // Over both thresholds → staleLarge (review), never orphan.
            let stale = classifier.classify(makeEntry(
                name: name,
                exactBytes: defaultFloor,
                newestContentDate: date(daysBeforeNow: 190)
            ))
            XCTAssertEqual(stale.tier, .staleLarge, name)
            XCTAssertEqual(stale.risk, .review, name)

            // Under thresholds → unclassified.
            let small = classifier.classify(makeEntry(name: name, exactBytes: 1_000))
            XCTAssertEqual(small.tier, .unclassified, name)
        }
        XCTAssertEqual(consulted, [], "resolver must never be consulted for non-bundle-id names")
    }

    func testComAppleNonLeakNeverOrphanNeverSafeAndNeverConsultsResolver() {
        var consulted: [String] = []
        let classifier = makeClassifier(installedAppStatus: { name in
            consulted.append(name)
            return .notInstalled
        })

        // Over both thresholds → staleLarge at review, never orphan.
        let stale = classifier.classify(makeEntry(
            name: "com.apple.CoreSimulator",
            exactBytes: defaultFloor,
            newestContentDate: date(daysBeforeNow: 190)
        ))
        XCTAssertEqual(stale.tier, .staleLarge)
        XCTAssertEqual(stale.risk, .review)
        XCTAssertFalse(stale.evidence.contains { $0.contains("no installed app") })

        // Under thresholds → unclassified at review — never safe.
        let small = classifier.classify(makeEntry(name: "com.apple.dt.Xcode", exactBytes: 1_000))
        XCTAssertEqual(small.tier, .unclassified)
        XCTAssertEqual(small.risk, .review)
        XCTAssertFalse(small.defaultSelected)
        XCTAssertFalse(small.automaticCleanEligible)

        XCTAssertEqual(consulted, [], "resolver must never be consulted for com.apple.* names")
    }

    // MARK: - R4: user-data-shape caution

    func testUserDataMatchForcesReviewAndCautionEvenOnKnownLeak() {
        let result = makeClassifier().classify(makeEntry(
            name: "com.apple.SwiftUI.Drag-DEADBEEF-0000-1111-2222-333344445555",
            exactBytes: 31_000_000_000,
            userDataShapeMatches: ["photos-library", "pictures-directory"]
        ))
        XCTAssertEqual(result.tier, .knownLeak, "tier stays knownLeak; only risk/selection change")
        XCTAssertEqual(result.risk, .review)
        XCTAssertTrue(result.evidence.contains(
            "contains user-data-shaped content (photos-library, pictures-directory) — verify the original still exists before deleting"
        ))
        XCTAssertFalse(result.defaultSelected)
        XCTAssertFalse(result.automaticCleanEligible)
    }

    func testIncompleteProbeFailsClosedEvenWithZeroMatches() {
        // knownLeak glob match + zero user-data matches + truncated probe:
        // absence of matches from a truncated inspection proves nothing.
        let result = makeClassifier().classify(makeEntry(
            name: "com.apple.SwiftUI.Drag-AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0000",
            exactBytes: 31_000_000_000,
            userDataShapeMatches: [],
            userDataProbeComplete: false
        ))
        XCTAssertEqual(result.tier, .knownLeak)
        XCTAssertEqual(result.risk, .review)
        XCTAssertTrue(result.evidence.contains("couldn't fully inspect for user-data content"))
        XCTAssertFalse(result.defaultSelected)
        XCTAssertFalse(result.automaticCleanEligible)
    }

    // MARK: - R8: stale-large thresholds

    func testStaleLargeRequiresBothThresholdsAndDerivesDayCountFromInjectedNow() {
        let classifier = makeClassifier()
        let bytes: Int64 = 2_100_000_000 // epic example: "2.1 GB"

        // Both exceeded → staleLarge with the frozen evidence shape.
        let stale = classifier.classify(makeEntry(
            name: "OldTool",
            exactBytes: bytes,
            newestContentDate: date(daysBeforeNow: 190)
        ))
        XCTAssertEqual(stale.tier, .staleLarge)
        XCTAssertEqual(stale.risk, .review)
        XCTAssertEqual(stale.evidence, ["\(sizeText(bytes)), untouched 190 days"])
        XCTAssertFalse(stale.defaultSelected)
        XCTAssertFalse(stale.automaticCleanEligible)
    }

    func testStaleLargeBoundaries() {
        let classifier = makeClassifier()
        let oldEnough = date(daysBeforeNow: 61)

        // Exactly AT the floor qualifies (at-or-above).
        XCTAssertEqual(
            classifier.classify(makeEntry(
                name: "AtFloor", exactBytes: defaultFloor, newestContentDate: oldEnough
            )).tier,
            .staleLarge
        )
        // One byte below the floor never qualifies, however old.
        XCTAssertEqual(
            classifier.classify(makeEntry(
                name: "BelowFloor", exactBytes: defaultFloor - 1, newestContentDate: oldEnough
            )).tier,
            .unclassified
        )
        // Exactly AT the stale age is not OLDER than it — not stale.
        XCTAssertEqual(
            classifier.classify(makeEntry(
                name: "AtAge", exactBytes: defaultFloor, newestContentDate: date(daysBeforeNow: 60)
            )).tier,
            .unclassified
        )
        // One second past the age qualifies; day count floors to 60.
        let justStale = classifier.classify(makeEntry(
            name: "JustStale",
            exactBytes: defaultFloor,
            newestContentDate: fixedNow.addingTimeInterval(-(defaultStaleAge + 1))
        ))
        XCTAssertEqual(justStale.tier, .staleLarge)
        XCTAssertEqual(justStale.evidence, ["\(sizeText(defaultFloor)), untouched 60 days"])
    }

    func testHardlinkedBytesCountTowardTheFloor() {
        // allocatedBytes is the exact + estimated sum — the floor applies
        // to the sum, mirroring what a scan row displays.
        let result = makeClassifier().classify(makeEntry(
            name: "SplitBytes",
            exactBytes: defaultFloor / 2,
            estimatedUpToBytes: defaultFloor / 2,
            newestContentDate: date(daysBeforeNow: 190)
        ))
        XCTAssertEqual(result.tier, .staleLarge)
    }

    func testNilNewestContentDateNeverStaleLarge() {
        // Huge and undated (empty or fully denied) — staleness cannot be
        // asserted about content that was never dated.
        let result = makeClassifier().classify(makeEntry(
            name: "Undated", exactBytes: 500_000_000_000, newestContentDate: nil
        ))
        XCTAssertEqual(result.tier, .unclassified)
    }

    // MARK: - Unclassified (informational) representation

    func testUnclassifiedIsReviewUnselectedWithVisibilityEvidence() {
        let bytes: Int64 = 30_000_000
        let result = makeClassifier().classify(makeEntry(name: "SomeTool", exactBytes: bytes))
        XCTAssertEqual(result.tier, .unclassified)
        XCTAssertEqual(result.risk, .review, "review keeps it out of any safe-only bulk selection")
        XCTAssertEqual(
            result.evidence,
            ["listed for visibility because of its size (\(sizeText(bytes)))"]
        )
        XCTAssertFalse(result.defaultSelected)
        XCTAssertFalse(result.automaticCleanEligible)
    }

    // MARK: - R7: denials

    func testDenialEvidenceDistinguishesTCCFromPermissionAndForcesRiskOffSafe() {
        let classifier = makeClassifier()
        // On a leak-glob match so the off-safe forcing is observable.
        let leakName = "com.apple.SwiftUI.Drag-11112222-3333-4444-5555-666677778888"

        let tcc = classifier.classify(makeEntry(
            name: leakName, exactBytes: 1_000, denials: [tccDenial()]
        ))
        XCTAssertEqual(tcc.tier, .knownLeak)
        XCTAssertEqual(tcc.risk, .review)
        XCTAssertTrue(tcc.evidence.contains("couldn't fully scan: TCC denied"))
        XCTAssertFalse(tcc.evidence.contains("couldn't fully scan: permission denied"))
        XCTAssertFalse(tcc.defaultSelected)
        XCTAssertFalse(tcc.automaticCleanEligible)

        let perm = classifier.classify(makeEntry(
            name: leakName, exactBytes: 1_000, denials: [permissionDenial()]
        ))
        XCTAssertEqual(perm.risk, .review)
        XCTAssertTrue(perm.evidence.contains("couldn't fully scan: permission denied"))
        XCTAssertFalse(perm.evidence.contains("couldn't fully scan: TCC denied"))

        // Mixed kinds: one line per distinct class, fixed order.
        let mixed = classifier.classify(makeEntry(
            name: "MixedDenials", exactBytes: 1_000,
            denials: [permissionDenial("/fixture/a"), tccDenial("/fixture/b")]
        ))
        let lines = mixed.evidence.filter { $0.hasPrefix("couldn't fully scan:") }
        XCTAssertEqual(lines, [
            "couldn't fully scan: TCC denied",
            "couldn't fully scan: permission denied",
        ])
    }

    // MARK: - R7: mount boundaries

    func testMountBoundaryForcesOffSafeUnselectedWithBoundaryEvidence() {
        let classifier = makeClassifier()
        let leakName = "com.apple.SwiftUI.Drag-99990000-AAAA-BBBB-CCCC-DDDDEEEEFFFF"
        let boundaryEvidence = "contains a mount boundary — size incomplete; deletion would be refused"

        // Nested boundary — on a leak name so all three forcings are visible.
        let nested = classifier.classify(makeEntry(
            name: leakName,
            exactBytes: 1_000,
            mountBoundaries: [URL(fileURLWithPath: "/fixture/home/Library/Caches/x/mnt")]
        ))
        XCTAssertEqual(nested.tier, .knownLeak)
        XCTAssertEqual(nested.risk, .review)
        XCTAssertTrue(nested.evidence.contains(boundaryEvidence))
        XCTAssertFalse(nested.defaultSelected)
        XCTAssertFalse(nested.automaticCleanEligible)

        // The entry ITSELF is a mount point (zero measured bytes, no date).
        let root = classifier.classify(makeEntry(name: "MountedVolume", rootMountBoundary: true))
        XCTAssertEqual(root.risk, .review)
        XCTAssertTrue(root.evidence.contains(boundaryEvidence))
        XCTAssertFalse(root.defaultSelected)
        XCTAssertFalse(root.automaticCleanEligible)
    }

    // MARK: - Selection policy matrix

    func testSelectionPolicyBothFlagsTrueExactlyForCleanKnownLeak() {
        let leakName = "com.apple.SwiftUI.Drag-00001111-2222-3333-4444-555566667777"
        let clean = makeClassifier().classify(makeEntry(name: leakName, exactBytes: 1_000))
        XCTAssertTrue(clean.defaultSelected)
        XCTAssertTrue(clean.automaticCleanEligible)
        XCTAssertEqual(clean.risk, .safe)

        // Every deviation turns BOTH flags off.
        let deviations: [(String, SweptCacheEntry)] = [
            ("user-data match", makeEntry(
                name: leakName, exactBytes: 1_000, userDataShapeMatches: ["photos-library"]
            )),
            ("incomplete probe", makeEntry(
                name: leakName, exactBytes: 1_000, userDataProbeComplete: false
            )),
            ("denial", makeEntry(name: leakName, exactBytes: 1_000, denials: [tccDenial()])),
            ("nested boundary", makeEntry(
                name: leakName, exactBytes: 1_000,
                mountBoundaries: [URL(fileURLWithPath: "/fixture/mnt")]
            )),
            ("root boundary", makeEntry(name: leakName, rootMountBoundary: true)),
        ]
        for (label, entry) in deviations {
            let result = makeClassifier().classify(entry)
            XCTAssertEqual(result.tier, .knownLeak, label)
            XCTAssertFalse(result.defaultSelected, label)
            XCTAssertFalse(result.automaticCleanEligible, label)
        }

        // Non-leak tiers: both flags always false.
        let orphan = makeClassifier(installedAppStatus: { _ in .notInstalled })
            .classify(makeEntry(name: "com.foo.bar", exactBytes: 1_000))
        XCTAssertEqual(orphan.tier, .orphan)
        XCTAssertFalse(orphan.defaultSelected)
        XCTAssertFalse(orphan.automaticCleanEligible)

        let stale = makeClassifier().classify(makeEntry(
            name: "BigOld", exactBytes: defaultFloor, newestContentDate: date(daysBeforeNow: 190)
        ))
        XCTAssertEqual(stale.tier, .staleLarge)
        XCTAssertFalse(stale.defaultSelected)
        XCTAssertFalse(stale.automaticCleanEligible)

        let unclassified = makeClassifier().classify(makeEntry(name: "Small", exactBytes: 1))
        XCTAssertEqual(unclassified.tier, .unclassified)
        XCTAssertFalse(unclassified.defaultSelected)
        XCTAssertFalse(unclassified.automaticCleanEligible)
    }

    // MARK: - R5: output set

    func testAllClassifiedEntriesAlwaysOutputEvenWhenTheyOutrankEveryUnclassified() {
        // 12 classified entries (> N = 10), ALL larger than every
        // unclassified entry — a "top-N among all entries" rule would drop
        // every unclassified row; the frozen rule keeps the largest
        // unclassified entry.
        let classifier = makeClassifier(installedAppStatus: { _ in .notInstalled })
        var entries: [SweptCacheEntry] = []
        for index in 0..<12 {
            entries.append(makeEntry(
                name: "com.dead.app\(String(format: "%02d", index))",
                exactBytes: 1_000_000 + Int64(index)
            ))
        }
        entries.append(makeEntry(name: "biggest-unclassified", exactBytes: 500_000))
        entries.append(makeEntry(name: "smaller-unclassified", exactBytes: 400_000))

        let output = classifier.classifyForOutput(entries)
        let names = output.map(\.entry.name)
        for index in 0..<12 {
            XCTAssertTrue(
                names.contains("com.dead.app\(String(format: "%02d", index))"),
                "classified entry \(index) must always be output"
            )
        }
        XCTAssertTrue(names.contains("biggest-unclassified"),
                      "largest unclassified entry is always present")
        XCTAssertTrue(names.contains("smaller-unclassified"))
        XCTAssertEqual(output.count, 14)
    }

    func testCleanUnclassifiedBeyondTopNAreOmitted() {
        // 15 clean unclassified, distinct sizes → exactly the 10 largest
        // survive; the largest is always present.
        let classifier = makeClassifier()
        let entries = (1...15).map { index in
            makeEntry(name: "tool\(String(format: "%02d", index))", exactBytes: Int64(index) * 1_000)
        }
        let output = classifier.classifyForOutput(entries.shuffled())
        let names = output.map(\.entry.name)
        XCTAssertEqual(output.count, 10)
        for index in 6...15 {
            XCTAssertTrue(names.contains("tool\(String(format: "%02d", index))"), "top-10 member \(index)")
        }
        for index in 1...5 {
            XCTAssertFalse(names.contains("tool\(String(format: "%02d", index))"), "beyond-N member \(index)")
        }
    }

    // MARK: - R7: visibility beats the size cut

    func testZeroByteDeniedAndBoundaryEntriesSurviveTheSizeCut() {
        // >N larger clean unclassified entries would win any size contest;
        // the zero-byte denied entry and the zero-byte mount-point entry
        // must appear anyway — R7 visibility is unconditional.
        let classifier = makeClassifier()
        var entries = (1...12).map { index in
            makeEntry(name: "big\(String(format: "%02d", index))", exactBytes: Int64(index) * 1_000_000)
        }
        entries.append(makeEntry(name: "zero-denied", denials: [tccDenial()]))
        entries.append(makeEntry(name: "zero-mountpoint", rootMountBoundary: true))

        let output = classifier.classifyForOutput(entries.shuffled())
        let names = output.map(\.entry.name)
        XCTAssertTrue(names.contains("zero-denied"),
                      "a zero-byte denied entry must never be dropped by the size cut")
        XCTAssertTrue(names.contains("zero-mountpoint"),
                      "a zero-byte mount-point entry must never be dropped by the size cut")
        // 10 clean unclassified survive the cut + the 2 impediment rows.
        XCTAssertEqual(output.count, 12)
        XCTAssertFalse(names.contains("big01"))
        XCTAssertFalse(names.contains("big02"))
    }

    // MARK: - R5: deterministic ordering

    func testOutputOrderIsBytesDescendingThenNameAscendingBytewise() {
        let classifier = makeClassifier(installedAppStatus: { _ in .notInstalled })
        let entries = [
            // A small classified entry must sort BELOW a big unclassified
            // one — one frozen order over the whole list, tier-blind.
            makeEntry(name: "com.dead.app", exactBytes: 500),
            makeEntry(name: "huge-unclassified", exactBytes: 9_000),
            // Equal sizes: byte-wise ascending name ("Alpha" < "Zeta" < "beta"
            // — uppercase before lowercase in UTF-8).
            makeEntry(name: "beta", exactBytes: 700),
            makeEntry(name: "Zeta", exactBytes: 700),
            makeEntry(name: "Alpha", exactBytes: 700),
        ]
        let expected = ["huge-unclassified", "Alpha", "Zeta", "beta", "com.dead.app"]
        // Same output for ANY input order.
        XCTAssertEqual(classifier.classifyForOutput(entries).map(\.entry.name), expected)
        XCTAssertEqual(classifier.classifyForOutput(Array(entries.reversed())).map(\.entry.name), expected)
        XCTAssertEqual(classifier.classifyForOutput(entries.shuffled()).map(\.entry.name), expected)
    }

    func testEqualBytesStraddlingTheTopNBoundaryAreCutByNameAscending() {
        // 9 distinct-size larger entries + 3 equal-size entries at the
        // boundary: exactly one of the equal group fits into N = 10, and it
        // must be the byte-wise-first name — for ANY input order.
        let classifier = makeClassifier()
        var entries = (1...9).map { index in
            makeEntry(name: "large\(index)", exactBytes: 10_000 + Int64(index))
        }
        entries.append(makeEntry(name: "ccc", exactBytes: 500))
        entries.append(makeEntry(name: "aaa", exactBytes: 500))
        entries.append(makeEntry(name: "bbb", exactBytes: 500))

        for variant in [entries, Array(entries.reversed()), entries.shuffled()] {
            let names = classifier.classifyForOutput(variant).map(\.entry.name)
            XCTAssertEqual(names.count, 10)
            XCTAssertTrue(names.contains("aaa"), "byte-wise-first tie member survives the cut")
            XCTAssertFalse(names.contains("bbb"))
            XCTAssertFalse(names.contains("ccc"))
        }
    }

    // MARK: - Name-shape helpers

    func testBundleIDShapeHeuristic() {
        XCTAssertTrue(OrphanedCacheClassifier.isBundleIDShapedName("com.foo.bar"))
        XCTAssertTrue(OrphanedCacheClassifier.isBundleIDShapedName("io.github.some.tool"))
        XCTAssertFalse(OrphanedCacheClassifier.isBundleIDShapedName("pnpm"))
        XCTAssertFalse(OrphanedCacheClassifier.isBundleIDShapedName("go-build"))
        XCTAssertFalse(OrphanedCacheClassifier.isBundleIDShapedName("com.foo"))
        XCTAssertFalse(OrphanedCacheClassifier.isBundleIDShapedName(".hidden.thing"),
                       "empty leading component is not bundle-id-shaped")
        XCTAssertFalse(OrphanedCacheClassifier.isBundleIDShapedName("com.foo.bar."),
                       "empty trailing component is not bundle-id-shaped")
        XCTAssertFalse(OrphanedCacheClassifier.isBundleIDShapedName(""))
    }

    func testAppleSystemNameDetectionIsCaseInsensitive() {
        XCTAssertTrue(OrphanedCacheClassifier.isAppleSystemName("com.apple.dt.Xcode"))
        XCTAssertTrue(OrphanedCacheClassifier.isAppleSystemName("COM.APPLE.Something"))
        XCTAssertFalse(OrphanedCacheClassifier.isAppleSystemName("com.appleseed.tool"))
        XCTAssertFalse(OrphanedCacheClassifier.isAppleSystemName("com.notapple.thing"))
    }
}
