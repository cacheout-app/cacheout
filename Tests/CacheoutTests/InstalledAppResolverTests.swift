import XCTest
import AppKit
import Darwin
@testable import Cacheout

/// Hermetic tests for the fn-3.3 `InstalledAppResolver` census — every
/// resolver here runs with `useLaunchServices: false` over UUID-derived
/// fixture roots under the system temp directory, so nothing reads the
/// real /Applications or the LaunchServices database. The single
/// LaunchServices case is a CONDITIONAL integration test that skips when
/// LS itself has no registration to confirm against.
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
    /// (or explicit `roots`).
    private func makeResolver(roots: [URL]? = nil) -> InstalledAppResolver {
        InstalledAppResolver(censusRoots: roots ?? [appsRoot], useLaunchServices: false)
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
        // Empty census roots: only the LS signal can answer .installed.
        let resolver = InstalledAppResolver(censusRoots: [], useLaunchServices: true)
        XCTAssertEqual(resolver.status(ofBundleID: finderID), .installed)
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
        let resolver = InstalledAppResolver(censusRoots: [], useLaunchServices: false)
        let status = resolver.status(ofBundleID: "com.example.absent")
        XCTAssertEqual(status, .notInstalled)
        requireSendable(resolver)
    }
}
