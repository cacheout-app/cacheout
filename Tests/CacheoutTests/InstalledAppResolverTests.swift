import XCTest
import AppKit
import Darwin
@testable import Cacheout

/// Hermetic tests for the fn-3.3 `InstalledAppResolver` census — every
/// resolver here runs with `useLaunchServices: false` AND an injected
/// `spotlightPresence` closure (default: a healthy index that finds
/// nothing) over UUID-derived fixture roots under the system temp
/// directory, so nothing reads the real /Applications, the LaunchServices
/// database, or the Spotlight index. The LaunchServices and live-Spotlight
/// cases are CONDITIONAL integration tests that skip when the real machine
/// has nothing to confirm against.
///
/// Fixture `.app` bundles are plain directories carrying
/// `Contents/Info.plist` with `CFBundleIdentifier` — no codesigning needed
/// for `Bundle(url:)`. `Bundle(url:)` caches bundle metadata per URL, so
/// no test ever MUTATES an already-seen bundle's Info.plist; census-once
/// behavior is observed by ADDING a new bundle instead (task spec rule).
///
/// chmod-000 fixtures restore 0755 before teardown and skip under euid 0
/// (root ignores permission bits) — house pattern.
final class InstalledAppResolverTests: XCTestCase {

    private var base: URL!
    private var appsRoot: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("InstalledAppResolverTests-\(UUID().uuidString)")
        appsRoot = base.appendingPathComponent("Applications")
        try fm.createDirectory(at: appsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Helpers

    /// Creates `<url>/Contents/Info.plist` carrying `bundleID`. Pass `nil`
    /// to create the Contents directory WITHOUT any Info.plist.
    @discardableResult
    private func makeApp(at url: URL, bundleID: String?) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        if let bundleID {
            let plist = ["CFBundleIdentifier": bundleID]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        return url
    }

    /// Hermetic resolver: LaunchServices OFF, census over the fixture root
    /// (or explicit `roots`), Spotlight scripted (default: a HEALTHY index
    /// that finds nothing — `.absent` — so census-mechanics tests exercise
    /// the census verdict exactly as before the third signal existed).
    private func makeResolver(
        roots: [URL]? = nil,
        spotlight: @escaping (String) -> SpotlightPresence = { _ in .absent }
    ) -> InstalledAppResolver {
        InstalledAppResolver(
            censusRoots: roots ?? [appsRoot],
            useLaunchServices: false,
            spotlightPresence: spotlight
        )
    }

    private func chmod000(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }

    private func restorePerms(_ url: URL) {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Compile-level Sendable assertion (fn-2 `SpaceScanner: Sendable`
    /// compatibility).
    private func requireSendable<T: Sendable>(_ value: T) {}

    // MARK: - Complete census: installed / notInstalled

    func testCompleteCensusEstablishesPresenceAndAbsence() throws {
        try makeApp(at: appsRoot.appendingPathComponent("Bar.app"),
                    bundleID: "com.example.bar")
        let resolver = makeResolver()
        XCTAssertEqual(resolver.status(ofBundleID: "com.example.bar"), .installed)
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.absent"), .notInstalled,
            "a COMPLETE census establishes absence — this is the positive notInstalled the orphan tier requires"
        )
    }

    // MARK: - Caskroom layout

    func testCaskroomVersionedLayoutDiscovered() throws {
        let caskroom = base.appendingPathComponent("Caskroom")
        try makeApp(at: caskroom.appendingPathComponent("foo/1.2.3/Foo.app"),
                    bundleID: "com.example.foo")
        let resolver = makeResolver(roots: [caskroom])
        XCTAssertEqual(resolver.status(ofBundleID: "com.example.foo"), .installed,
                       "Caskroom/<cask>/<version>/<Name>.app must be discovered")
    }

    // MARK: - No depth cap; prune at .app

    func testNoDepthCapDeeplyNestedAppDiscovered() throws {
        try makeApp(at: appsRoot.appendingPathComponent("A/B/C/Deep.app"),
                    bundleID: "com.example.deep")
        let resolver = makeResolver()
        XCTAssertEqual(resolver.status(ofBundleID: "com.example.deep"), .installed,
                       "completeness must not depend on layout depth")
    }

    func testCensusNeverDescendsInsideABundle() throws {
        let outer = appsRoot.appendingPathComponent("Outer.app")
        try makeApp(at: outer, bundleID: "com.example.outer")
        try makeApp(at: outer.appendingPathComponent("Contents/Resources/Inner.app"),
                    bundleID: "com.example.inner")
        let resolver = makeResolver()
        XCTAssertEqual(resolver.status(ofBundleID: "com.example.outer"), .installed)
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.inner"), .notInstalled,
            "the walk prunes at the first .app component: Inner.app is never seen AND the census stays complete"
        )
    }

    // MARK: - Case-insensitivity

    func testBundleIDMatchingIsCaseInsensitive() throws {
        try makeApp(at: appsRoot.appendingPathComponent("Bar.app"),
                    bundleID: "Com.Example.Bar")
        let resolver = makeResolver()
        XCTAssertEqual(resolver.status(ofBundleID: "COM.EXAMPLE.BAR"), .installed)
        XCTAssertEqual(resolver.status(ofBundleID: "com.example.bar"), .installed)
    }

    func testAppExtensionMatchingIsCaseInsensitive() throws {
        try makeApp(at: appsRoot.appendingPathComponent("Upper.APP"),
                    bundleID: "com.example.upper")
        let resolver = makeResolver()
        XCTAssertEqual(resolver.status(ofBundleID: "com.example.upper"), .installed)
    }

    // MARK: - Missing / non-directory roots are normal absence

    func testAbsentRootsToleratedCensusStillComplete() throws {
        let ghostA = base.appendingPathComponent("no-such-dir-a")
        let ghostB = base.appendingPathComponent("no-such-dir-b")
        let resolver = makeResolver(roots: [ghostA, ghostB])
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.absent"), .notInstalled,
            "missing roots (no Caskroom on a non-Homebrew machine) are normal absence, not incompleteness"
        )
    }

    func testNonDirectoryRootToleratedCensusStillComplete() throws {
        let fileRoot = base.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: fileRoot)
        let resolver = makeResolver(roots: [fileRoot])
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.absent"), .notInstalled,
            "a non-directory root contains no app bundles, with certainty"
        )
    }

    // MARK: - Incomplete census → unknown (fail closed)

    func testUnreadableExistingRootMakesNoMatchUnknown() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        try makeApp(at: appsRoot.appendingPathComponent("Bar.app"),
                    bundleID: "com.example.bar")
        let locked = base.appendingPathComponent("LockedRoot")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try chmod000(locked)
        defer { restorePerms(locked) }

        let resolver = makeResolver(roots: [appsRoot, locked])
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.absent"), .unknown,
            "an EXISTING root that refuses enumeration means absence cannot be asserted"
        )
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.bar"), .installed,
            "installed wins even over an incomplete census"
        )
    }

    func testPartialEnumerationFailureMakesNoMatchUnknown() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        try makeApp(at: appsRoot.appendingPathComponent("Bar.app"),
                    bundleID: "com.example.bar")
        let locked = appsRoot.appendingPathComponent("Locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try chmod000(locked)
        defer { restorePerms(locked) }

        let resolver = makeResolver()
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.absent"), .unknown,
            "an unreadable branch partway through an existing root fails closed"
        )
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.bar"), .installed,
            "the walk continues past the failure — presence can still be established"
        )
    }

    func testUnreadableAppBundleMakesNoMatchUnknown() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let shady = appsRoot.appendingPathComponent("Shady.app")
        try makeApp(at: shady, bundleID: "com.example.shady")
        try chmod000(shady)
        defer { restorePerms(shady) }

        let resolver = makeResolver()
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.absent"), .unknown,
            "an unreadable bundle could hide any id — its Info.plist's absence cannot be positively established"
        )
    }

    func testUnparseableInfoPlistMakesNoMatchUnknown() throws {
        let junk = appsRoot.appendingPathComponent("Junk.app")
        try fm.createDirectory(at: junk.appendingPathComponent("Contents"),
                               withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(
            to: junk.appendingPathComponent("Contents/Info.plist"))

        let resolver = makeResolver()
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.absent"), .unknown,
            "metadata PRESENT but unreadable is a metadata failure — fail closed"
        )
    }

    // MARK: - Provably id-less bundles do NOT degrade completeness

    func testBundlesWithPositivelyNoInfoPlistKeepCensusComplete() throws {
        // No Contents at all.
        try fm.createDirectory(at: appsRoot.appendingPathComponent("Empty.app"),
                               withIntermediateDirectories: true)
        // Contents but no Info.plist.
        try makeApp(at: appsRoot.appendingPathComponent("NoPlist.app"), bundleID: nil)
        // A regular FILE named .app (ENOTDIR arm).
        try Data("x".utf8).write(to: appsRoot.appendingPathComponent("File.app"))
        // A broken symlink named .app (ENOENT arm).
        try fm.createSymbolicLink(
            at: appsRoot.appendingPathComponent("Broken.app"),
            withDestinationURL: base.appendingPathComponent("gone.app"))

        let resolver = makeResolver()
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.absent"), .notInstalled,
            "a bundle with POSITIVELY no Info.plist has no id to hide — absence stays established"
        )
    }

    // MARK: - Census built once

    func testCensusIsBuiltOnceNewBundleAfterFirstQueryIsInvisible() throws {
        try makeApp(at: appsRoot.appendingPathComponent("Bar.app"),
                    bundleID: "com.example.bar")
        let resolver = makeResolver()
        XCTAssertEqual(resolver.status(ofBundleID: "com.example.bar"), .installed,
                       "first query builds the census")

        // ADD a new bundle (never mutate a seen one — Bundle(url:) caches).
        try makeApp(at: appsRoot.appendingPathComponent("New.app"),
                    bundleID: "com.example.new")
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.new"), .notInstalled,
            "the census is one-shot: a bundle added after the first query is not re-enumerated"
        )
    }

    // MARK: - Conditional LaunchServices integration

    func testLaunchServicesSignalResolvesKnownSystemBundle() throws {
        let finderID = "com.apple.Finder"
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderID) != nil else {
            throw XCTSkip("LaunchServices has no Finder registration in this environment")
        }
        // Empty census roots and Spotlight scripted absent: only the LS
        // signal can answer .installed (and it wins before Spotlight is
        // ever consulted).
        let resolver = InstalledAppResolver(
            censusRoots: [],
            useLaunchServices: true,
            spotlightPresence: { _ in .absent }
        )
        XCTAssertEqual(resolver.status(ofBundleID: finderID), .installed)
    }

    // MARK: - Spotlight signal (resolver-level, scripted)

    func testSpotlightPresenceRescuesAppOutsideCensusRoots() throws {
        // The PR #456 P2 scenario: an app at an arbitrary location
        // (/Volumes/Work/Apps, ~/Developer) is invisible to the census and
        // (here) to LS — only Spotlight can establish presence.
        let resolver = makeResolver(spotlight: { _ in .present })
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.elsewhere"), .installed,
            "a Spotlight hit establishes presence the census cannot see"
        )
    }

    func testSpotlightUnavailableMakesCompleteCensusNoMatchUnknown() throws {
        // The P2 fix proper: a COMPLETE four-root census alone must not
        // assert GLOBAL absence — without a healthy Spotlight index the
        // no-match degrades to .unknown, fail closed.
        let resolver = makeResolver(spotlight: { _ in .unavailable })
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.absent"), .unknown,
            "census roots alone cannot establish absence from arbitrary install locations"
        )
    }

    func testSpotlightCleanMissKeepsCompleteCensusNotInstalled() throws {
        var queried: [String] = []
        let resolver = makeResolver(spotlight: { id in
            queried.append(id)
            return .absent
        })
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.absent"), .notInstalled,
            "complete census + healthy-Spotlight clean miss is the positive notInstalled the orphan tier requires"
        )
        XCTAssertEqual(queried, ["com.example.absent"],
                       "the Spotlight signal is consulted with the exact queried id")
    }

    func testSpotlightPresenceWinsEvenOverIncompleteCensus() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let locked = base.appendingPathComponent("LockedRoot")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try chmod000(locked)
        defer { restorePerms(locked) }

        let resolver = makeResolver(roots: [appsRoot, locked],
                                    spotlight: { _ in .present })
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.elsewhere"), .installed,
            "installed wins from any signal — an incomplete census cannot suppress a Spotlight hit"
        )
    }

    func testSpotlightNotConsultedWhenCensusMatches() throws {
        try makeApp(at: appsRoot.appendingPathComponent("Bar.app"),
                    bundleID: "com.example.bar")
        var queried: [String] = []
        let resolver = makeResolver(spotlight: { id in
            queried.append(id)
            return .unavailable
        })
        XCTAssertEqual(resolver.status(ofBundleID: "com.example.bar"), .installed)
        XCTAssertEqual(queried, [],
                       "a subprocess-backed signal is never consulted for an id a cheaper signal resolves")
    }

    // MARK: - SpotlightBundleIDProbe (hermetic, scripted runner)

    func testProbeCanaryHealthyThenCleanMiss() {
        var queries: [String] = []
        let probe = SpotlightBundleIDProbe(runQuery: { id in
            queries.append(id)
            return id == "com.apple.finder" ? 1 : 0
        })
        XCTAssertEqual(probe.presence(ofBundleID: "com.example.gone"), .absent)
        XCTAssertEqual(
            queries, ["com.apple.finder", "com.example.gone"],
            "the canary runs FIRST (short-circuiting on its first hit) and shares the real query path"
        )
        XCTAssertEqual(probe.presence(ofBundleID: "com.example.here.too"), .absent,
                       "the canary verdict is one-shot — not re-probed per query")
        XCTAssertEqual(queries.filter { $0 == "com.apple.finder" }.count, 1)
    }

    func testProbeCanaryMissLatchesUnavailable() {
        // A zero count for EVERY guaranteed-present system app means the
        // index cannot be trusted for absence (Spotlight disabled,
        // rebuilding, or a query-shape regression — mdfind reports all of
        // them as exit 0, count 0).
        var queryCount = 0
        let probe = SpotlightBundleIDProbe(runQuery: { _ in
            queryCount += 1
            return 0
        })
        XCTAssertEqual(probe.presence(ofBundleID: "com.example.gone"), .unavailable)
        XCTAssertEqual(queryCount, SpotlightBundleIDProbe.canaryBundleIDs.count,
                       "an unhealthy canary never runs the real query")
        XCTAssertEqual(probe.presence(ofBundleID: "com.example.other"), .unavailable)
        XCTAssertEqual(queryCount, SpotlightBundleIDProbe.canaryBundleIDs.count,
                       "the unavailable verdict is LATCHED — no further subprocess cost")
    }

    func testProbeQueryFailureLatchesUnavailable() {
        var queries: [String] = []
        let probe = SpotlightBundleIDProbe(runQuery: { id in
            queries.append(id)
            return id == "com.apple.finder" ? 1 : nil // healthy canary, then failure
        })
        XCTAssertEqual(probe.presence(ofBundleID: "com.example.gone"), .unavailable,
                       "a spawn/timeout/parse failure can never support an absence claim")
        let callsAfterFirst = queries.count
        XCTAssertEqual(probe.presence(ofBundleID: "com.example.other"), .unavailable)
        XCTAssertEqual(queries.count, callsAfterFirst,
                       "one failure latches the probe — a broken mds costs bounded time once")
    }

    func testProbeConcurrentFailureLatchPoisonsInFlightZero() {
        // PR #456 review r2 interleaving: query A fails and latches while
        // query B's zero-count is still in flight. B's zero must NOT become
        // .absent — after ANY query failure no absence is trustworthy.
        // Driven deterministically through the scripted runQuery seam: B's
        // query simulates the concurrent A-failure with a re-entrant
        // presence() call (queries run OUTSIDE the probe's lock, so this
        // cannot deadlock) BEFORE returning its zero — B has already passed
        // ensureHealthy() at that point, exactly the racing schedule.
        weak var probeRef: SpotlightBundleIDProbe?
        var aVerdict: SpotlightPresence?
        let probe = SpotlightBundleIDProbe(runQuery: { id in
            switch id {
            case "com.apple.finder":
                return 1 // healthy canary — both queries pass the gate
            case "com.example.a-fails":
                return nil // A's spawn/timeout failure → latch
            case "com.example.b-zero":
                // A fails and latches while B's subprocess is "running".
                aVerdict = probeRef?.presence(ofBundleID: "com.example.a-fails")
                return 0
            default:
                return 0
            }
        })
        probeRef = probe
        XCTAssertEqual(
            probe.presence(ofBundleID: "com.example.b-zero"), .unavailable,
            "a zero landing after a concurrent failure latched must not mint an absence"
        )
        XCTAssertEqual(aVerdict, .unavailable, "the failing query itself latched")
        XCTAssertEqual(probe.presence(ofBundleID: "com.example.later"), .unavailable,
                       "the latch sticks for all later queries")
    }

    func testResolverInterleavedLatchYieldsUnknownNotNotInstalled() {
        // The same interleaving observed at the resolver level: the
        // poisoned zero degrades a complete-census no-match to .unknown —
        // it must never mint the .notInstalled the orphan tier treats as a
        // positive global-absence claim.
        weak var probeRef: SpotlightBundleIDProbe?
        let probe = SpotlightBundleIDProbe(runQuery: { id in
            switch id {
            case "com.apple.finder": return 1
            case "com.example.a-fails": return nil
            case "com.example.absent":
                _ = probeRef?.presence(ofBundleID: "com.example.a-fails")
                return 0
            default: return 0
            }
        })
        probeRef = probe
        let resolver = makeResolver(spotlight: { probe.presence(ofBundleID: $0) })
        XCTAssertEqual(
            resolver.status(ofBundleID: "com.example.absent"), .unknown,
            "a complete census + a poisoned Spotlight zero fails closed"
        )
    }

    func testProbeQueryStringEscapesQuoteAndBackslash() {
        // A hostile cache-directory NAME must not inject query syntax: the
        // value rides inside argv (no shell) with \ and " escaped.
        XCTAssertEqual(
            SpotlightBundleIDProbe.queryString(forBundleID: "com.foo\"||true\\x"),
            "kMDItemCFBundleIdentifier = \"com.foo\\\"||true\\\\x\"c"
        )
        XCTAssertEqual(
            SpotlightBundleIDProbe.queryString(forBundleID: "com.example.plain"),
            "kMDItemCFBundleIdentifier = \"com.example.plain\"c",
            "the trailing c flag is the case-insensitivity form that works with mdfind (==[c] does not)"
        )
    }

    // MARK: - Conditional live Spotlight integration

    func testLiveSpotlightProbeResolvesFinderOrSkips() throws {
        let probe = SpotlightBundleIDProbe()
        switch probe.presence(ofBundleID: "com.apple.finder") {
        case .unavailable:
            throw XCTSkip("Spotlight unavailable in this environment")
        case .absent:
            XCTFail("a canary-healthy index must see Finder")
        case .present:
            break
        }
        XCTAssertEqual(
            probe.presence(ofBundleID: "com.cacheout.tests.definitely-not-installed"),
            .absent,
            "a healthy live index answers a genuine no-match as absent"
        )
    }

    // MARK: - Production defaults

    func testDefaultCensusRootsResolveAgainstInjectedHome() {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let roots = InstalledAppResolver.defaultCensusRoots(home: home).map(\.path)
        XCTAssertEqual(roots, [
            "/Applications",
            "/Users/fixture/Applications",
            "/opt/homebrew/Caskroom",
            "/usr/local/Caskroom",
        ])
    }

    // MARK: - Concurrency contract (compile-level)

    func testSynchronousQueryFromNonisolatedAsyncContext() async {
        // Compile-level assertion for the epic's concurrency contract: this
        // async test method is nonisolated, and the call below is
        // SYNCHRONOUS — no await, no MainActor hop — mirroring consumption
        // inside `scan(context:) async` and the headless CLI.
        let resolver = InstalledAppResolver(
            censusRoots: [],
            useLaunchServices: false,
            spotlightPresence: { _ in .absent }
        )
        let status = resolver.status(ofBundleID: "com.example.absent")
        XCTAssertEqual(status, .notInstalled)
        requireSendable(resolver)
    }
}
