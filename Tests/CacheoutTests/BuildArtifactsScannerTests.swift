import CryptoKit
import XCTest
import Darwin
@testable import Cacheout

/// Hermetic tests for `BuildArtifactsScanner` (fn-4.3, R1/R2/R4/R10/R13/R15).
///
/// Every fixture lives under one UUID-derived temp root with an injected
/// fixture home — zero reads of the real `$HOME`, zero standard-suite
/// writes. Expected sizes come from raw `lstat` math, never from the code
/// under test. chmod-000 fixtures restore 0755 in teardown and skip under
/// euid 0. No sleeps: cancellation is driven by cancelling the scan's OWN
/// task, and staleness by an injected clock.
///
/// **R13 harness.** Production `SpaceScanner` conformance lands in fn-4.5;
/// here every emitted outcome round-trips the REAL validator through the
/// TEST-ONLY `BuildArtifactsAdapterScanner` — same id (`build_artifacts`),
/// same declared `trustedContainerRoots` as the fixture dev roots —
/// registered via the PUBLIC `SpaceScannerRuntime(scanners:…)` initializer
/// (the `SpaceScannerIntegrationTests` fixture-scanner idiom). `runScan`
/// asserts non-malformed on EVERY scan in this file, so the denied-family
/// shapes (mount boundary, candidate denials) are covered by construction.
final class BuildArtifactsScannerTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private var dev: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fm = FileManager.default

    /// chmod-000 fixtures registered for teardown restore (house rule).
    private var permsToRestore: [URL] = []

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("BuildArtifactsScannerTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        dev = base.appendingPathComponent("dev")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: dev, withIntermediateDirectories: true)
        suiteName = "BuildArtifactsScannerTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        for url in permsToRestore {
            try? fm.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }
        permsToRestore = []
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Fixture helpers

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    private func writeFile(_ url: URL, bytes: Int = 4_096) throws -> URL {
        try mkdir(url.deletingLastPathComponent())
        try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
            .write(to: url)
        return url
    }

    private func chmod000(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        permsToRestore.append(url)
    }

    /// Independent fixture math (raw `lstat`), never the code under test.
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

    /// A marker-sibling project: `<dir>/<marker>` beside `<dir>/<artifact>`,
    /// the artifact carrying one payload file (nil = an EMPTY artifact dir).
    /// Returns the artifact directory.
    @discardableResult
    private func makeProject(
        at dir: URL, marker: String, artifact: String, payloadBytes: Int? = 4_096
    ) throws -> URL {
        try mkdir(dir)
        try writeFile(dir.appendingPathComponent(marker), bytes: 32)
        let artifactDir = dir.appendingPathComponent(artifact)
        try mkdir(artifactDir)
        if let payloadBytes {
            try writeFile(
                artifactDir.appendingPathComponent("payload.bin"),
                bytes: payloadBytes
            )
        }
        return artifactDir
    }

    /// A file of `bytes` REAL (non-sparse) bytes — multi-MB valuables
    /// fixtures without millions of `UInt8.random` calls.
    @discardableResult
    private func writeBulkFile(_ url: URL, bytes: Int) throws -> URL {
        try mkdir(url.deletingLastPathComponent())
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    /// A directory BUNDLE whose payload sits INSIDE it, so the bundle ROOT's
    /// own inode allocation is tiny while its SUBTREE is large — the exact
    /// shape single-lstat sizing would wrongly exempt from the floor.
    @discardableResult
    private func makeBundle(at url: URL, contentBytes: Int) throws -> URL {
        try mkdir(url)
        try writeBulkFile(
            url.appendingPathComponent("Contents/MacOS/binary"),
            bytes: contentBytes
        )
        return url
    }

    /// Comfortably above / below the shared allocated floor.
    private var aboveFloorBytes: Int {
        Int(ValuablesDetector.minimumAllocatedBytes) + 1_000_000
    }
    private let subFloorBytes = 4_096

    /// Raw `lstat` of a fixture path — the independent identity math the
    /// disclosed integers are checked against (never the code under test).
    private func rawStat(_ url: URL) throws -> stat {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw XCTSkip("lstat failed for fixture \(url.path)")
        }
        return st
    }

    /// A marker-INSIDE venv (PEP 405): any directory name, `pyvenv.cfg`
    /// among its own entries.
    @discardableResult
    private func makeVenv(at dir: URL, payloadBytes: Int? = 4_096) throws -> URL {
        try mkdir(dir)
        try writeFile(dir.appendingPathComponent("pyvenv.cfg"), bytes: 32)
        if let payloadBytes {
            try writeFile(
                dir.appendingPathComponent("lib/site.py"), bytes: payloadBytes
            )
        }
        return dir
    }

    // MARK: - Scanner helpers

    /// Dev-root resolution through the REAL R16 pipeline (policy + exact-
    /// canonical-duplicate dedupe), never a hand-built resolution — so the
    /// fixtures prove what production roots do.
    private func resolution(
        _ roots: [URL],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> DevRootsResolution {
        DevRootsStore(defaults: defaults, provider: provider)
            .effectiveRoots(replacing: roots, home: fixtureHome)
    }

    private func makeScanner(
        roots: [URL]? = nil,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        valuablesProbeEntryLimit: Int =
            ValuablesDetector.defaultProbeEntryLimit,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> BuildArtifactsScanner {
        BuildArtifactsScanner(
            home: fixtureHome,
            devRoots: resolution(roots ?? [dev], provider: provider),
            provider: provider,
            valuablesProbeEntryLimit: valuablesProbeEntryLimit,
            now: now
        )
    }

    /// Scan + the mandatory R13 round-trip through the real validator.
    @discardableResult
    private func runScan(
        _ scanner: BuildArtifactsScanner,
        trigger: ScanTrigger = .userInitiated,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> ScanOutcome {
        let outcome = await scanner.scan(context: ScanContext(trigger: trigger))
        try assertRoundTripsValidator(
            outcome, scanner: scanner, file: file, line: line
        )
        return outcome
    }

    /// Every fixture outcome must be non-malformed across all 8 check
    /// families — through the scanner's OWN production `SpaceScanner`
    /// conformance (fn-4.5), registered via the PUBLIC runtime initializer.
    private func assertRoundTripsValidator(
        _ outcome: ScanOutcome,
        scanner: BuildArtifactsScanner,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let runtime = try SpaceScannerRuntime(
            scanners: [scanner],
            categories: [],
            home: fixtureHome,
            provider: FileSystemIdentityProvider()
        )
        switch runtime.validatedOutcome(
            outcome, from: BuildArtifactsScanner.registeredID
        ) {
        case .outcome(let scannerID, let validated):
            XCTAssertEqual(
                scannerID, BuildArtifactsScanner.registeredID,
                file: file, line: line
            )
            XCTAssertEqual(
                validated.items.map(\.id), outcome.items.map(\.id),
                "a validated outcome passes its items through untouched",
                file: file, line: line
            )
        case .malformed(_, let issue):
            XCTFail(
                "outcome malformed at the real validator: \(issue.detail)",
                file: file, line: line
            )
        }
    }

    /// The identity path (canonical parent + UNRESOLVED leaf) an artifact
    /// dir MUST map to — computed independently of the scanner.
    private func identityPath(
        of url: URL,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> String {
        provider.resolveTargetKeepingLeaf(url).path
    }

    /// The id an artifact dir MUST carry (frozen `stableID` preimage,
    /// recomputed here — never echoed from the scan).
    private func expectedID(
        of url: URL,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> String {
        ReclaimableItem.stableID(
            scannerID: BuildArtifactsScanner.registeredID,
            canonicalPath: identityPath(of: url, provider: provider)
        )
    }

    private func item(
        _ outcome: ScanOutcome, at url: URL,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> ReclaimableItem? {
        let id = expectedID(of: url, provider: provider)
        return outcome.items.first { $0.id == id }
    }

    private func itemPaths(_ outcome: ScanOutcome) -> [String] {
        outcome.items.compactMap(\.url?.path)
    }

    // MARK: - Injectable providers (hermetic stand-ins)

    /// Marks chosen inodes as mount points — the house injection seam.
    private final class MountPointInjectingProvider: FileSystemIdentityProvider {
        var mountPointInodes: Set<UInt64> = []

        override func isMountPoint(_ url: URL) -> Bool {
            if let id = identity(of: url), mountPointInodes.contains(id.inode) {
                return true
            }
            return super.isMountPoint(url)
        }
    }

    /// Marks chosen inodes as mount points AND records every path anything
    /// lstat-probes. "The probe did not cross the boundary" is then provable
    /// by the ABSENCE of any touch beyond it — a stronger claim than an empty
    /// result, which an unrelated bug could also produce.
    private final class BoundaryTouchRecordingProvider:
        FileSystemIdentityProvider
    {
        var mountPointInodes: Set<UInt64> = []
        private(set) var probedPaths: [String] = []

        override func isMountPoint(_ url: URL) -> Bool {
            if let id = identity(of: url), mountPointInodes.contains(id.inode) {
                return true
            }
            return super.isMountPoint(url)
        }

        override func probeKind(of url: URL) -> KindProbe {
            probedPaths.append(url.path)
            return super.probeKind(of: url)
        }

        /// Every recorded touch STRICTLY beneath `directory`.
        func touches(below directory: URL) -> [String] {
            let prefix = directory.path + "/"
            return probedPaths.filter { $0.hasPrefix(prefix) }
        }
    }

    /// Forces `.failed` lstat probes for exact paths — EPERM cannot be
    /// fixtured from an unentitled process.
    private final class FailingProbeProvider: FileSystemIdentityProvider {
        var failingPaths: Set<String> = []
        var failErrno: Int32 = EPERM

        override func probeKind(of url: URL) -> KindProbe {
            if failingPaths.contains(url.path) {
                return .failed(errno: failErrno)
            }
            return super.probeKind(of: url)
        }
    }

    /// Counts `canonicalize` calls per requested path — the sizer resolves
    /// its `.scanRoot` exactly once per measurement, so the count over an
    /// artifact path IS the number of times that artifact was sized.
    private final class CanonicalizeCountingProvider: FileSystemIdentityProvider {
        private(set) var canonicalizeCounts: [String: Int] = [:]

        override func canonicalize(_ url: URL) -> URL {
            canonicalizeCounts[url.path, default: 0] += 1
            return super.canonicalize(url)
        }
    }

    /// Rewrites canonicalization for exact paths — the injected-synthetic
    /// alias seam (distinct requested spellings, ONE canonical identity)
    /// that no hermetic filesystem fixture can express in general.
    private final class AliasingProvider: FileSystemIdentityProvider {
        var aliases: [String: String] = [:]

        override func canonicalize(_ url: URL) -> URL {
            if let target = aliases[url.path] {
                return URL(fileURLWithPath: target)
            }
            return super.canonicalize(url)
        }
    }

    // MARK: - R1: per-rule-row + per-shape fixtures, selection triple (R15)

    func testEveryRuleRowMatchesItsMarkerAndCarriesItsRowSelectionTriple()
        async throws
    {
        let rust = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        let node = try makeProject(
            at: dev.appendingPathComponent("node"),
            marker: "package.json", artifact: "node_modules"
        )
        let swiftpm = try makeProject(
            at: dev.appendingPathComponent("swiftpm"),
            marker: "Package.swift", artifact: ".build"
        )
        let gradle = try makeProject(
            at: dev.appendingPathComponent("gradle"),
            marker: "build.gradle", artifact: "build"
        )
        // The `.gradle` row shares the full marker set — including the KTS
        // settings variant.
        let gradleCache = try makeProject(
            at: dev.appendingPathComponent("gradlekts"),
            marker: "settings.gradle.kts", artifact: ".gradle"
        )
        let pods = try makeProject(
            at: dev.appendingPathComponent("pods"),
            marker: "Podfile", artifact: "Pods"
        )
        let dist = try makeProject(
            at: dev.appendingPathComponent("distproj"),
            marker: "package.json", artifact: "dist"
        )
        let next = try makeProject(
            at: dev.appendingPathComponent("nextproj"),
            marker: "package.json", artifact: ".next"
        )
        let turbo = try makeProject(
            at: dev.appendingPathComponent("turboproj"),
            marker: "turbo.json", artifact: ".turbo"
        )
        // Marker-INSIDE: any directory name (PEP 405, D5) — "env", not
        // ".venv", proves the row is not name-based.
        let venv = try makeVenv(at: dev.appendingPathComponent("py/env"))

        let outcome = try await runScan(makeScanner())

        let expected: [(URL, RiskLevel)] = [
            (rust, .safe), (node, .review), (swiftpm, .safe),
            (gradle, .review), (gradleCache, .review), (pods, .review),
            (dist, .review), (next, .review), (turbo, .review),
            (venv, .review),
        ]
        XCTAssertEqual(outcome.items.count, expected.count,
                       "one item per rule row: \(itemPaths(outcome))")
        XCTAssertTrue(outcome.errors.isEmpty, "unexpected: \(outcome.errors)")
        for (url, risk) in expected {
            let found = try XCTUnwrap(
                item(outcome, at: url), "no item for \(url.lastPathComponent)"
            )
            XCTAssertEqual(found.risk, risk,
                           "risk is read off the rule ROW for \(url.path)")
            // R15: no Quick Clean enrollment in v1 — every row, no exception.
            XCTAssertFalse(found.defaultSelected, "\(url.path)")
            XCTAssertFalse(found.automaticCleanEligible, "\(url.path)")
            XCTAssertEqual(found.action, .removeItem)
            XCTAssertEqual(found.scannerID, BuildArtifactsScanner.registeredID)
        }
        // Evidence names the artifact AND the marker that proved it, in the
        // shape's own phrasing.
        let rustEvidence = try XCTUnwrap(item(outcome, at: rust)).evidence
        XCTAssertTrue(rustEvidence.hasPrefix("target/ beside Cargo.toml;"),
                      rustEvidence)
        let venvEvidence = try XCTUnwrap(item(outcome, at: venv)).evidence
        XCTAssertTrue(venvEvidence.hasPrefix("env/ containing pyvenv.cfg;"),
                      venvEvidence)
    }

    func testMarkerAbsentStaysInvisibleAndAFileNamedBuildNeverMatches()
        async throws
    {
        // A `target/` without `Cargo.toml` staying invisible is a FEATURE —
        // the sibling marker IS the safety property (D6). Assert ABSENCE.
        try mkdir(dev.appendingPathComponent("lonely/target"))
        try writeFile(dev.appendingPathComponent("lonely/target/payload.bin"))
        try mkdir(dev.appendingPathComponent("swiftless/.build"))
        try mkdir(dev.appendingPathComponent("nodeless/node_modules"))
        // A FILE named `build` beside a real Gradle marker never matches
        // (directory-only guard).
        try writeFile(dev.appendingPathComponent("gradlefile/build.gradle"))
        try writeFile(dev.appendingPathComponent("gradlefile/build"))
        // A marker with NO artifact dir beside it is a plain no-match.
        try writeFile(dev.appendingPathComponent("markeronly/Cargo.toml"))
        // Positive control: the same scan DOES find a proven artifact.
        let real = try makeProject(
            at: dev.appendingPathComponent("real"),
            marker: "Cargo.toml", artifact: "target"
        )

        let outcome = try await runScan(makeScanner())

        XCTAssertEqual(itemPaths(outcome), [identityPath(of: real)],
                       "only the marker-proven artifact is listed")
    }

    func testDevRootItselfIsNeverEligibleWhileAChildVenvIs() async throws {
        // Root-ineligibility through the REAL walker: the matcher's depth
        // gate must hold on LIVE events, not only constructed ones. A stray
        // marker at the root must not convert the broad root into an
        // artifact (D6, the cleardisk incident).
        try writeFile(dev.appendingPathComponent("pyvenv.cfg"), bytes: 32)
        let childVenv = try makeVenv(at: dev.appendingPathComponent("env"))

        let outcome = try await runScan(makeScanner())

        XCTAssertEqual(itemPaths(outcome), [identityPath(of: childVenv)],
                       "the dev root itself is never a candidate; its child "
                        + "venv is")
    }

    // MARK: - R2: prune only matched dirs; monorepo stays reachable

    func testMonorepoNestedNodeModulesFoundWithNoNameBasedPruning()
        async throws
    {
        // Every component of packages/build/pkg is on the OLD name-based
        // skip list this scanner bans. `build` here has no Gradle marker,
        // so it is walked THROUGH, not matched.
        let pkg = dev.appendingPathComponent("mono/packages/build/pkg")
        try writeFile(pkg.appendingPathComponent("package.json"), bytes: 32)
        let nodeModules = pkg.appendingPathComponent("node_modules")
        try writeFile(nodeModules.appendingPathComponent("dep/index.js"))

        let outcome = try await runScan(makeScanner())

        XCTAssertEqual(itemPaths(outcome), [identityPath(of: nodeModules)])
    }

    func testMatchedDirsAndGitProduceNoDescendantWalkEvents() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        // Pruning is proven by the ERROR SURFACE split: an unreadable
        // directory the WALK enters yields an outcome-level classified issue
        // (`ProjectTreeWalker` R12), while one only the SIZER enters yields
        // an item-level scanError. A matched `target/` and `.git` must
        // therefore produce ZERO outcome errors.
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        let insideTarget = target.appendingPathComponent("locked")
        try mkdir(insideTarget)
        let insideGit = dev.appendingPathComponent("proj/.git/locked")
        try mkdir(insideGit)
        try chmod000(insideTarget)
        try chmod000(insideGit)

        let outcome = try await runScan(makeScanner())

        XCTAssertTrue(
            outcome.errors.isEmpty,
            "no walk descended into the matched dir or .git: \(outcome.errors)"
        )
        let found = try XCTUnwrap(item(outcome, at: target))
        XCTAssertNotNil(found.scanError,
                        "the SIZER still entered the matched dir and "
                        + "classified the denial on the item")
    }

    func testInsideRuleRecordsItsOwnDirectoryAndNothingBeneathIt()
        async throws
    {
        // A nested project INSIDE the venv would match on its own; the
        // inside-rule prune (all children) keeps it unwalked, and the
        // ancestor-drop pass is the second line of defence.
        let venv = try makeVenv(at: dev.appendingPathComponent("py/env"))
        let buried = venv.appendingPathComponent("src/inner")
        try writeFile(buried.appendingPathComponent("package.json"), bytes: 32)
        try writeFile(
            buried.appendingPathComponent("node_modules/dep/index.js")
        )

        let outcome = try await runScan(makeScanner())

        XCTAssertEqual(itemPaths(outcome), [identityPath(of: venv)],
                       "the venv itself is the item; nothing inside it is")
    }

    func testSiblingRuleRecordsAndPrunesExactlyTheMatchedChild() async throws {
        // Siblings of a matched child keep being walked — pruning is
        // per-child, never per-parent.
        let target = try makeProject(
            at: dev.appendingPathComponent("ws"),
            marker: "Cargo.toml", artifact: "target"
        )
        let buried = target.appendingPathComponent("vendor/dep")
        try writeFile(buried.appendingPathComponent("Cargo.toml"), bytes: 32)
        try mkdir(buried.appendingPathComponent("target"))
        let sibling = try makeProject(
            at: dev.appendingPathComponent("ws/tools"),
            marker: "package.json", artifact: "node_modules"
        )

        let outcome = try await runScan(makeScanner())

        XCTAssertEqual(
            Set(itemPaths(outcome)),
            [identityPath(of: target), identityPath(of: sibling)],
            "the matched child is pruned; its SIBLING subtree is walked"
        )
    }

    // MARK: - R4: nested workspaces + the load-bearing dedupe (D7)

    func testNestedWorkspaceArtifactsBothListedNothingInsideAListedDir()
        async throws
    {
        let outer = try makeProject(
            at: dev.appendingPathComponent("ws"),
            marker: "Cargo.toml", artifact: "target"
        )
        let inner = try makeProject(
            at: dev.appendingPathComponent("ws/crates/inner"),
            marker: "Cargo.toml", artifact: "target"
        )
        // A vendored workspace INSIDE the outer artifact dir: never listed.
        let vendored = outer.appendingPathComponent("vendor/crate")
        try writeFile(vendored.appendingPathComponent("Cargo.toml"), bytes: 32)
        try mkdir(vendored.appendingPathComponent("target"))

        let outcome = try await runScan(makeScanner())

        XCTAssertEqual(Set(itemPaths(outcome)),
                       [identityPath(of: outer), identityPath(of: inner)],
                       "workspaces nest — matching never stops at the first "
                        + "hit, and nothing inside a listed dir is listed")
    }

    func testDevRootInsideAMatchedArtifactDirHasItsCandidatesDropped()
        async throws
    {
        // The ancestor-drop pass, driven by a REACHABLE production shape: a
        // dev root configured INSIDE an artifact dir another walk matched.
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        let innerRoot = target.appendingPathComponent("nested-root")
        let buried = innerRoot.appendingPathComponent("sub")
        try writeFile(buried.appendingPathComponent("package.json"), bytes: 32)
        try writeFile(
            buried.appendingPathComponent("node_modules/dep/index.js")
        )

        let outcome = try await runScan(makeScanner(roots: [dev, innerRoot]))

        XCTAssertEqual(itemPaths(outcome), [identityPath(of: target)],
                       "a candidate strictly inside another candidate's "
                        + "artifact dir is dropped")
    }

    func testNestedRootsWalkIndependentlyAndCollapseToOneCanonicalItem()
        async throws
    {
        // D7's load-bearing case, on the FILESYSTEM: two kept roots, one
        // nested in the other, both walked independently, one artifact
        // reachable from BOTH walks.
        let innerRoot = dev.appendingPathComponent("inner")
        let target = try makeProject(
            at: innerRoot.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        // The D7 RATIONALE itself: this project sits at depth 8 below
        // `inner` (its own budget reaches it) but depth 9 below `dev` (the
        // ancestor's depth-8 walk does not) — dropping the nested root would
        // make exactly this project invisible.
        let deepTarget = try makeProject(
            at: innerRoot.appendingPathComponent("a/b/c/d/e/f/g/proj"),
            marker: "Cargo.toml", artifact: "target"
        )

        // CONTROL: the outer root ALONE reaches the shallow artifact (so the
        // two-root scan below genuinely produced two candidates to collapse)
        // and never reaches the deep one.
        let outerOnly = try await runScan(makeScanner(roots: [dev]))
        XCTAssertEqual(
            itemPaths(outerOnly), [identityPath(of: target)],
            "the ancestor walk finds the shallow artifact and nothing beyond "
                + "its own depth budget"
        )

        let provider = CanonicalizeCountingProvider()
        let outcome = try await runScan(
            makeScanner(roots: [dev, innerRoot], provider: provider)
        )

        XCTAssertEqual(
            Set(itemPaths(outcome)),
            [identityPath(of: target), identityPath(of: deepTarget)],
            "overlapping walks collapse to ONE canonical item for the shared "
                + "artifact, and the nested root's own budget still yields "
                + "the deep one"
        )
        let found = try XCTUnwrap(
            item(outcome, at: target, provider: provider)
        )
        XCTAssertEqual(found.id, expectedID(of: target, provider: provider))
        guard case .containerItem(let origin, let requested) = found.admission
        else { return XCTFail("expected the frozen containerItem descriptor") }
        XCTAssertEqual(origin.path, innerRoot.path,
                       "provenance: the DEEPEST (most-specific) root wins")
        XCTAssertEqual(requested.path, target.path)
        XCTAssertEqual(
            provider.canonicalizeCounts[target.path], 1,
            "the artifact is sized exactly ONCE — sizing runs after the "
                + "collapse"
        )

        // Deterministic: neither declaration order nor a rerun may change
        // the winner.
        let reversed = try await runScan(
            makeScanner(roots: [innerRoot, dev])
        )
        let rerun = try await runScan(makeScanner(roots: [dev, innerRoot]))
        for other in [reversed, rerun] {
            XCTAssertEqual(Set(itemPaths(other)), Set(itemPaths(outcome)))
            let shared = try XCTUnwrap(item(other, at: target))
            guard case .containerItem(let otherOrigin, _) = shared.admission
            else { return XCTFail("expected the containerItem descriptor") }
            XCTAssertEqual(otherOrigin.path, innerRoot.path)
            XCTAssertEqual(shared.id, found.id)
        }
    }

    func testIntermediateAliasRootAndCanonicalRootCollapseToOneItem()
        async throws
    {
        // The symlinked-INTERMEDIATE-parent alias, reachable on macOS
        // (`/var` → `/private/var`): the declared root's ANCESTOR is a
        // symlink while its LEAF lstats as a real directory, so the root is
        // legal and every event under it carries the alias spelling.
        let real = base.appendingPathComponent("real")
        let projects = real.appendingPathComponent("projects")
        let target = try makeProject(
            at: projects.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let aliasRoot = link.appendingPathComponent("projects")

        // Two DISTINCT declared roots (different canonical keys, so the
        // store keeps both): the alias-declared deeper root and the
        // canonical ancestor root.
        let resolved = resolution([aliasRoot, real])
        XCTAssertEqual(resolved.keptRoots.map(\.path),
                       [aliasRoot.path, real.path],
                       "policy and dedupe keep both declared spellings")
        let outcome = try await runScan(
            BuildArtifactsScanner(
                home: fixtureHome, devRoots: resolved,
                provider: FileSystemIdentityProvider()
            )
        )

        XCTAssertEqual(outcome.items.count, 1,
                       "one artifact reachable under two spellings is ONE "
                        + "canonical item")
        let found = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(found.id, expectedID(of: target),
                       "the id derives from the CANONICAL identity path")
        XCTAssertEqual(found.url?.path, identityPath(of: target))
        guard case .containerItem(let origin, let requested) = found.admission
        else { return XCTFail("expected the frozen containerItem descriptor") }
        XCTAssertEqual(origin.path, aliasRoot.path,
                       "deepest resolved root wins — the alias spelling is "
                        + "preserved VERBATIM for origin binding")
        XCTAssertTrue(requested.path.hasPrefix(aliasRoot.path),
                      "the deletion target keeps the winning root's own "
                        + "unresolved spelling: \(requested.path)")
    }

    func testInjectedSyntheticCanonicalAliasCollapsesWithProvenanceIntact()
        throws
    {
        // GENERALITY beyond what a fixture can build: two DISTINCT requested
        // paths that canonicalize to ONE identity collapse to one candidate,
        // deepest resolved root winning.
        let provider = AliasingProvider()
        provider.aliases = [
            "/synthetic/alias/deep/proj": "/synthetic/real/deep/proj",
            "/synthetic/alias": "/synthetic/real",
        ]
        let rule = try XCTUnwrap(BuildArtifactRules.v1.first)
        let viaAlias = BuildArtifactCandidate(
            artifactDirectory:
                URL(fileURLWithPath: "/synthetic/alias/deep/proj/target"),
            originRoot: URL(fileURLWithPath: "/synthetic/alias"),
            rule: rule, marker: "Cargo.toml"
        )
        let viaCanonical = BuildArtifactCandidate(
            artifactDirectory:
                URL(fileURLWithPath: "/synthetic/real/deep/proj/target"),
            originRoot: URL(fileURLWithPath: "/synthetic/real/deep"),
            rule: rule, marker: "Cargo.toml"
        )

        for input in [[viaAlias, viaCanonical], [viaCanonical, viaAlias]] {
            let collapsed = BuildArtifactsScanner.deduplicated(
                input, provider: provider
            )
            XCTAssertEqual(collapsed.count, 1,
                           "one canonical identity → one candidate")
            XCTAssertEqual(collapsed.first?.originRoot.path,
                           "/synthetic/real/deep",
                           "deepest resolved root wins regardless of input "
                            + "order")
        }
    }

    func testSyntheticEqualDepthProvenanceBreaksTiesByteWise() throws {
        // Equal canonical depth → byte-wise `originRoot.path` decides, so
        // provenance is TOTAL, never traversal-order dependent.
        let provider = AliasingProvider()
        provider.aliases = ["/synthetic/bbb/proj": "/synthetic/aaa/proj"]
        let rule = try XCTUnwrap(BuildArtifactRules.v1.first)
        let first = BuildArtifactCandidate(
            artifactDirectory:
                URL(fileURLWithPath: "/synthetic/aaa/proj/target"),
            originRoot: URL(fileURLWithPath: "/synthetic/aaa"),
            rule: rule, marker: "Cargo.toml"
        )
        let second = BuildArtifactCandidate(
            artifactDirectory:
                URL(fileURLWithPath: "/synthetic/bbb/proj/target"),
            originRoot: URL(fileURLWithPath: "/synthetic/bbb"),
            rule: rule, marker: "Cargo.toml"
        )

        for input in [[first, second], [second, first]] {
            let collapsed = BuildArtifactsScanner.deduplicated(
                input, provider: provider
            )
            XCTAssertEqual(collapsed.count, 1)
            XCTAssertEqual(collapsed.first?.originRoot.path, "/synthetic/aaa")
        }
    }

    func testAncestorDropIsKeyedOnComponentsNeverStringPrefixes() throws {
        // `/dev/proj/target` must NOT swallow `/dev/proj/targetX/...`: the
        // ancestor test compares canonical pathCOMPONENTS, never strings.
        let provider = FileSystemIdentityProvider()
        let rule = try XCTUnwrap(BuildArtifactRules.v1.first)
        let ancestor = BuildArtifactCandidate(
            artifactDirectory: URL(fileURLWithPath: "/synthetic/proj/target"),
            originRoot: URL(fileURLWithPath: "/synthetic"),
            rule: rule, marker: "Cargo.toml"
        )
        let lexicalNeighbour = BuildArtifactCandidate(
            artifactDirectory:
                URL(fileURLWithPath: "/synthetic/proj/targetX/target"),
            originRoot: URL(fileURLWithPath: "/synthetic"),
            rule: rule, marker: "Cargo.toml"
        )
        let genuinelyInside = BuildArtifactCandidate(
            artifactDirectory:
                URL(fileURLWithPath: "/synthetic/proj/target/dep/target"),
            originRoot: URL(fileURLWithPath: "/synthetic"),
            rule: rule, marker: "Cargo.toml"
        )

        let kept = BuildArtifactsScanner.deduplicated(
            [ancestor, lexicalNeighbour, genuinelyInside], provider: provider
        )

        XCTAssertEqual(
            kept.map(\.artifactDirectory.path),
            [ancestor.artifactDirectory.path,
             lexicalNeighbour.artifactDirectory.path],
            "a lexical neighbour survives; only a true descendant drops"
        )
    }

    // MARK: - R10: bytes, sparse divergence, hardlinks

    func testHardlinkedBytesLandInEstimatedAndHiddenBytesAreCounted()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 6_000
        )
        let payload = target.appendingPathComponent("payload.bin")
        // pnpm keeps ~all bytes under a hidden store — hidden files count.
        let hidden = try writeFile(
            target.appendingPathComponent(".pnpm/store.bin"), bytes: 10_000
        )
        // A hardlinked pair: st_nlink > 1 → estimated, never exact.
        let linkA = try writeFile(
            target.appendingPathComponent("link-a.bin"), bytes: 8_192
        )
        try fm.linkItem(
            at: linkA, to: target.appendingPathComponent("link-b.bin")
        )

        let outcome = try await runScan(makeScanner())

        let found = try XCTUnwrap(item(outcome, at: target))
        XCTAssertEqual(found.exactBytes, allocated(payload, hidden),
                       "unique-inode bytes (hidden ones included) are EXACT")
        XCTAssertEqual(found.estimatedUpToBytes, allocated(linkA),
                       "hardlinked bytes stay in the estimated component")
        XCTAssertNil(found.logicalBytes,
                     "block rounding is noise, not sparse divergence")
        XCTAssertEqual(found.state, .measured)
        XCTAssertNil(found.scanError)
    }

    func testSparseArtifactPublishesLogicalBytesAboveAllocated() async throws {
        let target = try makeProject(
            at: dev.appendingPathComponent("sparse"),
            marker: "Cargo.toml", artifact: "target"
        )
        let sparse = target.appendingPathComponent("sparse.bin")
        fm.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 5_000_000)
        try handle.close()

        let outcome = try await runScan(makeScanner())

        let found = try XCTUnwrap(item(outcome, at: target))
        let logical = try XCTUnwrap(
            found.logicalBytes, "sparse divergence must be carried"
        )
        XCTAssertGreaterThanOrEqual(logical, 5_000_000)
        XCTAssertGreaterThan(logical, found.allocatedBytes,
                             "the published direction is the one where "
                              + "deletion frees LESS than the apparent size")
    }

    func testLogicalBytesPredicateMatchesTheAsBuiltBoundaryCells() {
        // The as-built predicate VERBATIM (NodeModulesScanner.swift:618-619)
        // — boundary cells on BOTH sides, which no filesystem fixture can
        // place precisely.
        var equal = SizeReport()
        equal.exactAllocatedBytes = 4_096
        equal.estimatedUpToBytes = 2_048
        equal.logicalBytes = 6_144
        XCTAssertNil(
            BuildArtifactsScanner.publishedLogicalBytes(
                deletable: true, report: equal
            ),
            "logical == measured is not a divergence"
        )

        var oneMore = equal
        oneMore.logicalBytes = 6_145
        XCTAssertEqual(
            BuildArtifactsScanner.publishedLogicalBytes(
                deletable: true, report: oneMore
            ),
            6_145,
            "logical == measured + 1 publishes"
        )
        XCTAssertNil(
            BuildArtifactsScanner.publishedLogicalBytes(
                deletable: false, report: oneMore
            ),
            "a non-deletable item publishes no logical figure"
        )
    }

    // MARK: - R10: staleness + evidence

    func testStalenessFlipsAtTheThirtyDayNewestContentBoundary() async throws {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        let built = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes(
            [.modificationDate: built],
            ofItemAtPath: target.appendingPathComponent("payload.bin").path
        )
        let calendar = Calendar.current
        let atThreshold = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 30, to: built)
        )
        let pastThreshold = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 31, to: built)
        )

        let fresh = try await runScan(
            makeScanner(now: { atThreshold })
        )
        let freshItem = try XCTUnwrap(item(fresh, at: target))
        XCTAssertEqual(freshItem.isStale, false, "30 days is not yet stale")
        XCTAssertEqual(freshItem.evidence,
                       "target/ beside Cargo.toml; last build 30 days ago")

        let stale = try await runScan(
            makeScanner(now: { pastThreshold })
        )
        let staleItem = try XCTUnwrap(item(stale, at: target))
        XCTAssertEqual(staleItem.isStale, true, "31 days flips the predicate")
        XCTAssertEqual(staleItem.evidence,
                       "target/ beside Cargo.toml; last build 31 days ago")
    }

    func testAgeUnknownVariantWhenTheWalkDatedNoContent() async throws {
        // An EMPTY artifact dir dates nothing: staleness is UNKNOWABLE (nil,
        // never a false "fresh") and the evidence says so.
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )

        let outcome = try await runScan(makeScanner())

        let found = try XCTUnwrap(item(outcome, at: target))
        XCTAssertEqual(found.state, .empty)
        XCTAssertNil(found.isStale)
        XCTAssertEqual(found.evidence,
                       "target/ beside Cargo.toml; last build date unknown")
        XCTAssertEqual(found.allocatedBytes, 0)
        XCTAssertNil(found.scanError)
    }

    // MARK: - R10: deterministic TOTAL output order

    func testOutputOrderIsTotalAllocatedDescNameAscThenIdentityAsc()
        async throws
    {
        // Equal-size equal-name ties are the COMMON case (empty artifact
        // dirs); the canonical identity path is the final tie-breaker.
        let big = try makeProject(
            at: dev.appendingPathComponent("big"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 40_000
        )
        // Created out of order on purpose — creation order must not leak.
        let p3 = try makeProject(
            at: dev.appendingPathComponent("p3"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let p1 = try makeProject(
            at: dev.appendingPathComponent("p1"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let p2 = try makeProject(
            at: dev.appendingPathComponent("p2"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        // Zero bytes too, but a name that sorts BEFORE "target".
        let modules = try makeProject(
            at: dev.appendingPathComponent("nodeproj"),
            marker: "package.json", artifact: "node_modules",
            payloadBytes: nil
        )

        let outcome = try await runScan(makeScanner())
        let rerun = try await runScan(makeScanner())

        XCTAssertEqual(
            itemPaths(outcome),
            [identityPath(of: big), identityPath(of: modules),
             identityPath(of: p1), identityPath(of: p2), identityPath(of: p3)],
            "allocated desc, then name asc byte-wise, then identity path asc"
        )
        XCTAssertEqual(itemPaths(rerun), itemPaths(outcome),
                       "the order never depends on traversal or completion "
                        + "order")
        XCTAssertEqual(outcome.items.first?.displayName, "target")
        XCTAssertEqual(outcome.items.dropFirst().first?.displayName,
                       "node_modules")
    }

    // MARK: - R10/R13: the denied family

    func testMountBoundaryInTreeYieldsDeniedUnmeasuredWithBoundaryNamed()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 8_192
        )
        let mounted = target.appendingPathComponent("mounted-volume")
        try writeFile(mounted.appendingPathComponent("beyond.bin"))

        let provider = MountPointInjectingProvider()
        provider.mountPointInodes.insert(
            try XCTUnwrap(provider.identity(of: mounted)?.inode)
        )

        let outcome = try await runScan(makeScanner(provider: provider))

        let found = try XCTUnwrap(item(outcome, at: target, provider: provider))
        XCTAssertEqual(found.state, .denied,
                       "ANY boundary voids the whole target at delete time")
        XCTAssertEqual(found.rootRecords.map(\.status), [.deniedUnmeasured])
        XCTAssertEqual(found.exactBytes, 0)
        XCTAssertEqual(found.estimatedUpToBytes, 0)
        XCTAssertEqual(found.itemCount, 0)
        XCTAssertNil(found.logicalBytes,
                     "a denied item publishes no logical figure")
        let error = try XCTUnwrap(found.scanError)
        XCTAssertEqual(error.kind, .other,
                       "no new wire kind: a boundary is neither TCC nor BSD "
                        + "permissions")
        XCTAssertTrue(error.message.contains("mounted-volume"),
                      "the error NAMES the boundary: \(error.message)")
        XCTAssertTrue(error.message.contains("not reclaimable"),
                      "the measured floor rides the message: \(error.message)")
    }

    func testArtifactDirItselfAMountPointIsDeniedAndStillNamesTheBoundary()
        async throws
    {
        // The ROOT-boundary cell (review r1): the sizer never enumerates the
        // tree, so no nested boundary exists to name — the denied item must
        // STILL carry its classified scanError, or the whole outcome
        // malforms and a silent zero-byte denied item ships.
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 8_192
        )

        let provider = MountPointInjectingProvider()
        provider.mountPointInodes.insert(
            try XCTUnwrap(provider.identity(of: target)?.inode)
        )

        let outcome = try await runScan(makeScanner(provider: provider))

        let found = try XCTUnwrap(item(outcome, at: target, provider: provider))
        XCTAssertEqual(found.state, .denied)
        XCTAssertEqual(found.rootRecords.map(\.status), [.deniedUnmeasured])
        XCTAssertEqual(found.allocatedBytes, 0)
        XCTAssertEqual(found.itemCount, 0)
        XCTAssertNil(found.logicalBytes)
        let error = try XCTUnwrap(
            found.scanError, "a denied item ALWAYS carries its scanError"
        )
        XCTAssertEqual(error.kind, .other)
        XCTAssertTrue(error.message.contains("target"),
                      "the error names the boundary: \(error.message)")
        XCTAssertTrue(error.message.contains("mount point"),
                      "the root-boundary wording: \(error.message)")
    }

    /// MIGRATED from `NodeModulesScannerTests` (fn-4.7): the retired
    /// scanner proved that a boundary-denied item is refused END TO END, and
    /// the subsuming scanner inherited the same `displayPath` helper and the
    /// same `.denied` doctrine — so the proof moves here rather than dying
    /// with its old owner. Three surfaces must AGREE (PR #455 P2): the CLI
    /// plan verb (`refuse`, never `clean_with_warning`), the cleaner's
    /// pre-dispatch R18 refusal, and the on-disk outcome — no deletion
    /// entry, one SURFACED item error, readable siblings untouched. The scan
    /// runs through the runtime's VALIDATED session, so the boundary shape
    /// is also proven non-malformed on the real publication path.
    func testBoundaryDeniedItemPlansRefuseAndIsRefusedWholeByTheCleaner()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 8_192
        )
        let payload = target.appendingPathComponent("payload.bin")
        let mounted = target.appendingPathComponent("mounted-volume")
        try mkdir(mounted)

        let provider = MountPointInjectingProvider()
        provider.mountPointInodes.insert(
            try XCTUnwrap(provider.identity(of: mounted)?.inode)
        )

        let session = try await scanSession(makeScanner(provider: provider))
        let item = try XCTUnwrap(session.items.first,
                                 "the boundary item publishes through the "
                                    + "validated session — never malformed")
        XCTAssertEqual(item.state, .denied)
        XCTAssertEqual(CLIHandler.cleanPlanAction(for: item), "refuse",
                       "dry-run and confirmation say what the confirmed run "
                        + "does — refuse, never clean_with_warning")

        let cleaner = session.runtime.makeCleaner(snapshot: session.snapshot)
        let report = await cleaner.clean(items: [item], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty,
                      "no deletion entry — nothing was freed")
        XCTAssertEqual(report.errors.count, 1,
                       "the refusal SURFACES as an item error (R18), never a "
                        + "silent skip")
        XCTAssertEqual(report.errors.first?.key, item.key)
        XCTAssertTrue(
            report.errors.first?.message.contains("refused") == true,
            "the error says refusal: \(String(describing: report.errors.first))"
        )
        XCTAssertTrue(fm.fileExists(atPath: payload.path),
                      "the readable payload is untouched — whole-target "
                        + "refusal, not partial deletion")
    }

    // MARK: - R12: declared display path

    /// MIGRATED from `NodeModulesScannerTests` (fn-4.7): this scanner
    /// inherited the retired scanner's `displayPath` helper VERBATIM, so it
    /// inherits the review-r1 rule it was hardened with — home shortening
    /// requires a PATH-COMPONENT boundary. A sibling that merely
    /// string-prefixes the home path (`/Users/d-other` beside `/Users/d`)
    /// must render in full, never as `~-other/…`, least of all beside a
    /// destructive `remove_item` action.
    func testDeclaredDisplayPathShorteningRequiresAComponentBoundary()
        async throws
    {
        // (a) A dev root whose path string-prefixes the fixture home.
        let sibling = URL(fileURLWithPath: fixtureHome.path + "-other")
        let outsideTarget = try makeProject(
            at: sibling.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        let outside = try await runScan(makeScanner(roots: [sibling]))
        let outsideItem = try XCTUnwrap(item(outside, at: outsideTarget))
        XCTAssertFalse(
            outsideItem.declaredDisplayPath.hasPrefix("~"),
            "no component boundary, no shortening: "
                + outsideItem.declaredDisplayPath
        )
        XCTAssertTrue(
            outsideItem.declaredDisplayPath.hasSuffix("-other/proj/target"),
            outsideItem.declaredDisplayPath
        )

        // (b) A genuine descendant of home shortens AT the boundary. Home is
        // injected canonically because the walker lists descendants
        // canonically (/private-resolved).
        let canonicalHome = FileSystemIdentityProvider().canonicalize(fixtureHome)
        let code = canonicalHome.appendingPathComponent("Code")
        let insideTarget = try makeProject(
            at: code.appendingPathComponent("proj2"),
            marker: "Cargo.toml", artifact: "target"
        )
        let inside = try await runScan(
            BuildArtifactsScanner(
                home: canonicalHome, devRoots: resolution([code])
            )
        )
        let insideItem = try XCTUnwrap(item(inside, at: insideTarget))
        XCTAssertEqual(insideItem.declaredDisplayPath, "~/Code/proj2/target")
    }

    func testChmod000ArtifactIsDeniedUnmeasuredWithClassifiedError()
        async throws
    {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 8_192
        )
        try chmod000(target)

        let outcome = try await runScan(makeScanner())

        let found = try XCTUnwrap(item(outcome, at: target))
        XCTAssertEqual(found.state, .denied)
        XCTAssertEqual(found.rootRecords.map(\.status), [.deniedUnmeasured])
        XCTAssertEqual(found.allocatedBytes, 0)
        XCTAssertNil(found.logicalBytes)
        XCTAssertEqual(found.scanError?.kind, .permissionDenied,
                       "EACCES is classified, never a silent zero")
    }

    func testPartialDenialInsideTreeIsPartiallyDeniedWithMeasuredRecord()
        async throws
    {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 8_192
        )
        let payload = target.appendingPathComponent("payload.bin")
        let locked = target.appendingPathComponent("locked")
        try writeFile(locked.appendingPathComponent("hidden.bin"))
        try chmod000(locked)

        let outcome = try await runScan(makeScanner())

        let found = try XCTUnwrap(item(outcome, at: target))
        XCTAssertEqual(found.state, .partiallyDenied,
                       "the readable portion IS deletable — deletion "
                        + "partially succeeds")
        XCTAssertEqual(found.rootRecords.map(\.status), [.measured],
                       "the denials sit INSIDE the tree; the root record is "
                        + "honestly measured")
        XCTAssertEqual(found.exactBytes, allocated(payload))
        XCTAssertEqual(found.scanError?.kind, .permissionDenied,
                       "candidate-level denials are never dropped")
    }

    func testInjectedEPERMClassifiesAsTccDenied() async throws {
        // EPERM cannot be fixtured from an unentitled process — inject it.
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let tccLocked = try writeFile(
            target.appendingPathComponent("tcc-locked.bin")
        )
        let provider = FailingProbeProvider()
        // The sizer walks its `.scanRoot` at the CANONICAL location, so both
        // spellings of the fixture file must fail (the temp fixture root
        // itself sits behind macOS's `/var` → `/private/var` alias).
        provider.failingPaths = [
            tccLocked.path, provider.canonicalize(tccLocked).path,
        ]

        let outcome = try await runScan(makeScanner(provider: provider))

        let found = try XCTUnwrap(item(outcome, at: target, provider: provider))
        XCTAssertEqual(found.state, .denied,
                       "nothing measurable behind the denial")
        XCTAssertEqual(found.rootRecords.map(\.status), [.deniedUnmeasured])
        XCTAssertEqual(found.scanError?.kind, .tccDenied,
                       "EPERM → TCC (the frozen taxonomy)")
    }

    // MARK: - R16 data path + per-root issue surfacing

    func testPolicyRejectedPersistedRootRidesEveryOutcomeAndIsNeverWalked()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        let resolved = resolution([URL(fileURLWithPath: "/"), dev])
        XCTAssertEqual(resolved.keptRoots.map(\.path), [dev.path],
                       "the policy-rejected root is never registered")

        let outcome = try await runScan(
            BuildArtifactsScanner(
                home: fixtureHome, devRoots: resolved,
                provider: FileSystemIdentityProvider()
            )
        )

        XCTAssertEqual(itemPaths(outcome), [identityPath(of: target)])
        XCTAssertEqual(outcome.errors.map(\.kind), [.containerRefused],
                       "the config issue rides the outcome: \(outcome.errors)")
        XCTAssertEqual(outcome.errors.first?.url?.path, "/")
    }

    func testUnreadableDevRootSurfacesAsAClassifiedOutcomeIssue()
        async throws
    {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let second = base.appendingPathComponent("dev2")
        let target = try makeProject(
            at: second.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        try mkdir(dev.appendingPathComponent("proj"))
        try chmod000(dev)

        let outcome = try await runScan(makeScanner(roots: [dev, second]))

        XCTAssertEqual(outcome.errors.map(\.kind), [.permissionDenied],
                       "a denied root is a visible per-root problem, never a "
                        + "silent zero")
        XCTAssertEqual(outcome.errors.first?.url?.path, dev.path)
        XCTAssertEqual(itemPaths(outcome), [identityPath(of: target)],
                       "the other root still yields its items")
    }

    func testAutomaticScansSkipTCCProtectedRootsUserInitiatedIncludeThem()
        async throws
    {
        // A protected CHILD is a legal dev root (the seeds depend on it);
        // only the TCC policy gate decides whether it is walked, and the
        // scanner must pass the context flag through unchanged.
        let protectedRoot = fixtureHome
            .appendingPathComponent("Documents/dev")
        let target = try makeProject(
            at: protectedRoot.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        let scanner = makeScanner(roots: [protectedRoot])

        let automatic = try await runScan(scanner, trigger: .automatic)
        let userInitiated = try await runScan(scanner, trigger: .userInitiated)

        XCTAssertTrue(automatic.items.isEmpty,
                      "a background rescan never fires a TCC prompt")
        XCTAssertEqual(itemPaths(userInitiated), [identityPath(of: target)])
    }

    // MARK: - Concurrency

    func testCancelledScanReturnsPartialResultsOffTheMainActor() async throws {
        try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        // Sanity: the same fixture IS discoverable by a live scan.
        let live = try await runScan(makeScanner())
        XCTAssertEqual(live.items.count, 1)

        let probe = ThreadProbe()
        let scanner = makeScanner(now: {
            probe.record(mainThread: Thread.isMainThread)
            return Date()
        })
        let cancelled = await Task { () -> ScanOutcome in
            // Deterministic ordering, no sleeps: cancel SELF before the walk
            // begins, so the very first traversal node observes it.
            withUnsafeCurrentTask { $0?.cancel() }
            return await scanner.scan(
                context: ScanContext(trigger: .userInitiated)
            )
        }.value

        XCTAssertTrue(cancelled.items.isEmpty,
                      "a cancelled scan recognizes no candidates")
        XCTAssertTrue(cancelled.errors.isEmpty,
                      "cancellation truncation is silent, never a classified "
                        + "scan problem")

        // The clock closure runs INSIDE the mapping seam of a live scan —
        // proving the scan body never hops to the main actor.
        _ = try await runScan(scanner)
        XCTAssertTrue(probe.sawAnyCall, "the mapping seam ran")
        XCTAssertFalse(probe.sawMainThread,
                       "the scan never touches the main actor")
    }

    // ====================================================================
    // MARK: - fn-4.4: the valuables gate (R3/R13/R17)
    // ====================================================================

    // MARK: R3 — detection + forcing

    func testFieldDMGInsideTargetForcesReviewUnselectedAndDiscloses()
        async throws
    {
        // THE field case: a signed 42MB DMG that existed ONLY inside
        // `target/release/bundle/dmg/`.
        let target = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target"
        )
        let dmg = try writeBulkFile(
            target.appendingPathComponent(
                "release/bundle/dmg/Murmur_0.1.7_aarch64.dmg"
            ),
            bytes: aboveFloorBytes
        )
        XCTAssertGreaterThanOrEqual(
            allocated(dmg), ValuablesDetector.minimumAllocatedBytes,
            "fixture precondition: the DMG clears the shared floor"
        )

        let outcome = try await runScan(makeScanner())
        let found = try XCTUnwrap(item(outcome, at: target))

        // The `target` rule row is SAFE — the gate forces it off safe.
        XCTAssertEqual(BuildArtifactRules.v1[0].risk, .safe,
                       "fixture precondition: the row under test IS safe")
        XCTAssertEqual(found.risk, .review,
                       "a valuable forces the row OFF safe")
        XCTAssertFalse(found.defaultSelected,
                       "a valuable-bearing item is never pre-selected")

        let disclosure = try XCTUnwrap(found.valuablesDisclosure)
        XCTAssertTrue(disclosure.probeComplete)
        XCTAssertEqual(disclosure.valuables.count, 1)
        let valuable = try XCTUnwrap(disclosure.valuables.first)
        XCTAssertEqual(valuable.name, "Murmur_0.1.7_aarch64.dmg")
        XCTAssertEqual(identityPath(of: valuable.displayURL),
                       identityPath(of: dmg),
                       "displayURL names the same object (the alias-root cell "
                        + "proves it keeps the DISCOVERY spelling)")
        XCTAssertEqual(valuable.canonicalIdentityPath, identityPath(of: dmg))
        XCTAssertEqual(valuable.identity.allocatedBytes, allocated(dmg),
                       "a regular file is sized by its LEAF allocation")

        // Evidence: the pinned epic format, appended to the base clause.
        let human = ByteCountFormatter.sharedFile
            .string(fromByteCount: allocated(dmg))
        XCTAssertEqual(
            found.evidence,
            "target/ beside Cargo.toml; last build today — WARNING: contains "
                + "Murmur_0.1.7_aarch64.dmg (\(human)) — verify before deleting"
        )
    }

    func testBundlesAreSizedByBoundedSubtreeWithRootIdentityAndFloor()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("ios"),
            marker: "Cargo.toml", artifact: "target"
        )
        let app = try makeBundle(
            at: target.appendingPathComponent("release/Murmur.app"),
            contentBytes: aboveFloorBytes
        )
        let archive = try makeBundle(
            at: target.appendingPathComponent("release/Murmur.xcarchive"),
            contentBytes: aboveFloorBytes
        )
        // Case-insensitive extension compare, exact otherwise.
        let dsym = try makeBundle(
            at: target.appendingPathComponent("release/Murmur.DSYM"),
            contentBytes: aboveFloorBytes
        )
        try makeBundle(
            at: target.appendingPathComponent("release/Stub.app"),
            contentBytes: subFloorBytes
        )

        let outcome = try await runScan(makeScanner())
        let found = try XCTUnwrap(item(outcome, at: target))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)
        XCTAssertTrue(disclosure.probeComplete)
        XCTAssertEqual(
            disclosure.valuables.map(\.name).sorted(),
            ["Murmur.DSYM", "Murmur.app", "Murmur.xcarchive"],
            "the three bundle shapes; the sub-floor .app stub is ignored"
        )

        // SPLIT sourcing: the ROOT's own allocation would never clear the
        // floor — the subtree's does, and the identity is still the root's.
        let payload = app.appendingPathComponent("Contents/MacOS/binary")
        XCTAssertLessThan(
            allocated(app), ValuablesDetector.minimumAllocatedBytes,
            "fixture precondition: a bundle root inode is tiny"
        )
        let appValuable = try XCTUnwrap(
            disclosure.valuables.first { $0.name == "Murmur.app" }
        )
        XCTAssertEqual(appValuable.identity.allocatedBytes, allocated(payload),
                       "a bundle is sized by its BOUNDED SUBTREE")
        let rootStat = try rawStat(app)
        XCTAssertEqual(appValuable.identity.inode, UInt64(rootStat.st_ino),
                       "identity is the bundle ROOT's no-follow lstat")
        XCTAssertEqual(appValuable.identity.device,
                       UInt64(bitPattern: Int64(rootStat.st_dev)))
        XCTAssertNotEqual(appValuable.identity.inode,
                          UInt64(try rawStat(payload).st_ino),
                          "never the payload's inode")
        for bundle in [archive, dsym] {
            XCTAssertNotNil(
                disclosure.valuables.first {
                    $0.canonicalIdentityPath == identityPath(of: bundle)
                },
                "\(bundle.lastPathComponent) is a directory bundle valuable"
            )
        }
    }

    func testTruncatedBundleSizingMakesTheProbeIncompleteAndTokenless()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let app = target.appendingPathComponent("Big.app")
        // Above the floor at the bundle ROOT's own level …
        let shallow = try writeBulkFile(
            app.appendingPathComponent("payload.bin"), bytes: aboveFloorBytes
        )
        // … and more bytes BEYOND what the injected budget can reach.
        try writeBulkFile(
            app.appendingPathComponent("Contents/MacOS/binary"),
            bytes: aboveFloorBytes
        )

        // A budget of 3 buys exactly `Big.app` (outer walk) plus its two
        // children: `Contents/` is DISCOVERED but never expanded, so
        // `Contents/MacOS/binary` never joins the sum. The OUTER walk's only
        // child directory is the bundle itself, so the incompleteness can
        // ONLY come from the truncated bundle sizing.
        let outcome = try await runScan(
            makeScanner(valuablesProbeEntryLimit: 3)
        )
        let found = try XCTUnwrap(item(outcome, at: target))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)

        XCTAssertFalse(disclosure.probeComplete,
                       "a truncated bundle subtree walk is an INCOMPLETE probe")
        XCTAssertEqual(disclosure.valuables.map(\.name), ["Big.app"])
        XCTAssertEqual(
            disclosure.valuables.first?.identity.allocatedBytes,
            allocated(shallow),
            "the truncated figure is a FLOOR — which is why it is tokenless"
        )
        XCTAssertNil(disclosure.acknowledgementToken(for: found.key),
                     "no token EVER derives from a partial size")
        XCTAssertEqual(found.risk, .review)
        XCTAssertFalse(found.defaultSelected)
        XCTAssertTrue(
            found.evidence.contains("couldn't fully inspect"), found.evidence
        )
    }

    func testPkgIpaFloorAndADMGNamedDirectoryIsNotAFileValuable()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        try writeBulkFile(
            target.appendingPathComponent("release/Installer.pkg"),
            bytes: aboveFloorBytes
        )
        try writeBulkFile(
            target.appendingPathComponent("release/App.ipa"),
            bytes: aboveFloorBytes
        )
        // Case-insensitive extension compare.
        try writeBulkFile(
            target.appendingPathComponent("release/Legacy.DMG"),
            bytes: aboveFloorBytes
        )
        try writeBulkFile(
            target.appendingPathComponent("release/Fragment.pkg"),
            bytes: subFloorBytes
        )
        // A DIRECTORY named `notes.dmg` is not a file valuable, and `dmg` is
        // no bundle extension — it is an ordinary directory, walked normally.
        try writeBulkFile(
            target.appendingPathComponent("release/notes.dmg/inner.bin"),
            bytes: aboveFloorBytes
        )

        let outcome = try await runScan(makeScanner())
        let disclosure = try XCTUnwrap(
            try XCTUnwrap(item(outcome, at: target)).valuablesDisclosure
        )
        XCTAssertTrue(disclosure.probeComplete,
                      "the dmg-NAMED directory was walked, not truncated")
        XCTAssertEqual(
            disclosure.valuables.map(\.name).sorted(),
            ["App.ipa", "Installer.pkg", "Legacy.DMG"],
            "sub-floor fragments and the dmg-named directory never qualify"
        )
    }

    func testDatabaseAndArchiveExtensionsAreNeverFlagged() async throws {
        // The research's FALSE-POSITIVE MAGNETS — the table proof first, so
        // no future edit can enrol them without failing here.
        XCTAssertTrue(
            ValuablesDetector.fileExtensions.isDisjoint(
                with: ValuablesDetector.deliberatelyNotFlaggedExtensions
            )
        )
        XCTAssertTrue(
            ValuablesDetector.bundleExtensions.isDisjoint(
                with: ValuablesDetector.deliberatelyNotFlaggedExtensions
            )
        )

        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        for name in ["cache.db", "index.sqlite", "bundle.zip"] {
            try writeBulkFile(
                target.appendingPathComponent("release/\(name)"),
                bytes: aboveFloorBytes
            )
        }

        let outcome = try await runScan(makeScanner())
        let found = try XCTUnwrap(item(outcome, at: target))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)
        XCTAssertEqual(disclosure.valuables, [],
                       "\(disclosure.valuables.map(\.name))")
        XCTAssertTrue(disclosure.probeComplete)
        XCTAssertEqual(found.risk, .safe, "nothing forced anything")
    }

    func testCleanArtifactDirKeepsItsRuleRowRiskSelectionAndEvidence()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )

        let outcome = try await runScan(makeScanner())
        let found = try XCTUnwrap(item(outcome, at: target))

        XCTAssertEqual(found.risk, BuildArtifactRules.v1[0].risk)
        XCTAssertEqual(found.defaultSelected,
                       BuildArtifactRules.v1[0].defaultSelected)
        XCTAssertEqual(found.automaticCleanEligible,
                       BuildArtifactRules.v1[0].automaticCleanEligible)
        XCTAssertEqual(found.evidence,
                       "target/ beside Cargo.toml; last build today",
                       "a clean probe appends NOTHING")
        let disclosure = try XCTUnwrap(
            found.valuablesDisclosure,
            "a clean probe still discloses structurally: probed, found "
                + "nothing, finished"
        )
        XCTAssertEqual(disclosure, .clean)
        XCTAssertNil(disclosure.acknowledgementToken(for: found.key),
                     "there is no empty-set token, anywhere")
    }

    func testIncompleteProbeFromEntryCapAndFromAnUnreadableSubtree()
        async throws
    {
        // (a) ENTRY CAP — a budget of one entry cannot exhaust the tree.
        let capped = try makeProject(
            at: dev.appendingPathComponent("capped"),
            marker: "Cargo.toml", artifact: "target"
        )
        try writeBulkFile(
            capped.appendingPathComponent("a/b.bin"), bytes: subFloorBytes
        )
        let cappedOutcome = try await runScan(
            makeScanner(roots: [dev], valuablesProbeEntryLimit: 1)
        )
        let cappedItem = try XCTUnwrap(item(cappedOutcome, at: capped))
        let cappedDisclosure = try XCTUnwrap(cappedItem.valuablesDisclosure)
        XCTAssertFalse(cappedDisclosure.probeComplete)
        XCTAssertEqual(cappedItem.risk, .review, "fail-closed forcing")
        XCTAssertFalse(cappedItem.defaultSelected)
        XCTAssertEqual(
            cappedItem.evidence,
            "target/ beside Cargo.toml; last build today — WARNING: couldn't "
                + "fully inspect this directory for release artifacts — "
                + "verify before deleting"
        )
        XCTAssertNil(cappedDisclosure.acknowledgementToken(for: cappedItem.key),
                     "an INCOMPLETE probe is unauthorizable and TOKENLESS")

        // (b) UNREADABLE SUBTREE — chmod 000 (EACCES; EPERM needs injection).
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let target = try makeProject(
            at: dev.appendingPathComponent("locked"),
            marker: "Cargo.toml", artifact: "target"
        )
        let locked = target.appendingPathComponent("locked-branch")
        try mkdir(locked)
        try chmod000(locked)

        let outcome = try await runScan(makeScanner(roots: [
            dev.appendingPathComponent("locked")
        ]))
        let found = try XCTUnwrap(item(outcome, at: target))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)
        XCTAssertFalse(disclosure.probeComplete,
                       "an unreadable branch leaves absence UNPROVEN")
        XCTAssertEqual(found.risk, .review)
        XCTAssertTrue(found.evidence.contains("couldn't fully inspect"),
                      found.evidence)
    }

    func testProbeNeverFollowsSymlinksAndTouchesOnlyMatchedDirs()
        async throws
    {
        let project = dev.appendingPathComponent("proj")
        let target = try makeProject(
            at: project, marker: "Cargo.toml", artifact: "target"
        )
        // OUTSIDE the artifact dir: beside the marker, in the project root.
        try writeBulkFile(
            project.appendingPathComponent("Shipped.dmg"),
            bytes: aboveFloorBytes
        )
        // Out-of-tree content reachable only through symlinks INSIDE it.
        let outside = base.appendingPathComponent("outside")
        let outsideDMG = try writeBulkFile(
            outside.appendingPathComponent("Outside.dmg"),
            bytes: aboveFloorBytes
        )
        try fm.createSymbolicLink(
            at: target.appendingPathComponent("linked.dmg"),
            withDestinationURL: outsideDMG
        )
        try fm.createSymbolicLink(
            at: target.appendingPathComponent("linked-dir"),
            withDestinationURL: outside
        )

        let outcome = try await runScan(makeScanner())
        let found = try XCTUnwrap(item(outcome, at: target))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)

        XCTAssertEqual(disclosure.valuables, [],
                       "symlinks are never followed and never valuables; the "
                        + "probe never leaves the matched artifact dir")
        XCTAssertTrue(disclosure.probeComplete,
                      "an unexpanded symlink does not make a probe incomplete "
                        + "— deleting the artifact dir removes the LINK")
        XCTAssertEqual(found.risk, .safe)
    }

    func testEntryBudgetBoundsTheDirectoryReadItselfAtTheExactCap()
        async throws
    {
        // The cap bounds the READ, not just the processing: a directory with
        // more entries than the remaining budget is never materialized whole,
        // and the unread remainder is what makes the probe incomplete.
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        for name in ["f1.bin", "f2.bin", "f3.bin", "f4.bin"] {
            try writeFile(target.appendingPathComponent(name), bytes: 512)
        }

        let atCap = try await runScan(
            makeScanner(valuablesProbeEntryLimit: 4)
        )
        XCTAssertTrue(
            try XCTUnwrap(item(atCap, at: target)?.valuablesDisclosure)
                .probeComplete,
            "a budget that exactly covers the tree finishes it"
        )

        let underCap = try await runScan(
            makeScanner(valuablesProbeEntryLimit: 3)
        )
        XCTAssertFalse(
            try XCTUnwrap(item(underCap, at: target)?.valuablesDisclosure)
                .probeComplete,
            "one entry short leaves the directory UNREAD, so unproven"
        )
    }

    func testBasenameDecodeRejectsInvalidUTF8InsteadOfRepairingIt() throws {
        // The fail-closed POLICY, hermetically: a repairing decode would turn
        // `bad\u{FF}.dmg` into a U+FFFD string whose URL names a DIFFERENT
        // path — `probeKind` would call it absent and the probe could report
        // "complete, nothing found" while a real DMG went uninspected.
        func decode(_ bytes: [UInt8]) -> String? {
            var buffer = bytes.map { CChar(bitPattern: $0) } + [0]
            return buffer.withUnsafeBufferPointer {
                ValuablesDetector.decodedBasename(fromCString: $0.baseAddress!)
            }
        }
        XCTAssertEqual(decode(Array("Murmur.dmg".utf8)), "Murmur.dmg")
        XCTAssertEqual(decode(Array("café.pkg".utf8)), "café.pkg",
                       "valid multi-byte UTF-8 decodes normally")
        XCTAssertNil(decode(Array("bad".utf8) + [0xFF] + Array(".dmg".utf8)),
                     "an invalid byte is never repaired into a lie")
        XCTAssertNil(decode([0xC3]), "a truncated sequence is rejected too")
    }

    func testUndecodableBasenameFailsClosedInsteadOfProbingComplete()
        async throws
    {
        // A basename that is not valid UTF-8 cannot be turned into a URL that
        // names the real entry — a REPAIRING decode would substitute U+FFFD
        // and the probe could report "complete, nothing found" while never
        // inspecting a DMG. APFS/HFS+ reject such names at `open(2)`
        // (EILSEQ), so this fixture only runs on a volume that accepts them
        // (exFAT/SMB/FUSE) — the guard exists for exactly those mounts.
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        var raw = Array("bad".utf8) + [0xFF] + Array(".dmg".utf8)
        let created: Int32 = target.path.withCString { dirPath -> Int32 in
            let full = String(cString: dirPath) + "/"
            var bytes = Array(full.utf8) + raw + [0]
            return bytes.withUnsafeMutableBufferPointer { buffer -> Int32 in
                buffer.baseAddress!.withMemoryRebound(
                    to: CChar.self, capacity: buffer.count
                ) { open($0, O_CREAT | O_WRONLY, 0o644) }
            }
        }
        try XCTSkipIf(
            created < 0,
            "this volume enforces UTF-8 basenames (errno \(errno)) — the "
                + "fail-closed decode guards foreign mounts that do not"
        )
        close(created)
        raw.removeAll()

        let outcome = try await runScan(makeScanner())
        let disclosure = try XCTUnwrap(
            item(outcome, at: target)?.valuablesDisclosure
        )
        XCTAssertFalse(disclosure.probeComplete,
                       "an undecodable basename leaves the directory UNPROVEN")
        XCTAssertEqual(
            try XCTUnwrap(item(outcome, at: target)).risk, .review
        )
    }

    func testTruncatedProbeDescendsSiblingsInByteWiseAscendingOrder()
        async throws
    {
        // A budget that can descend exactly ONE of two sibling directories:
        // the byte-wise FIRST one must be the one inspected, deterministically
        // (a reversed stack would silently disclose the other artifact).
        // Both sibling names fit in the artifact dir's own read, so this cell
        // sits inside the deterministic half of the contract — membership is
        // only unspecified when a single directory's READ is truncated.
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        try writeBulkFile(
            target.appendingPathComponent("a/First.dmg"), bytes: aboveFloorBytes
        )
        try writeBulkFile(
            target.appendingPathComponent("b/Second.pkg"), bytes: aboveFloorBytes
        )

        let outcome = try await runScan(
            makeScanner(valuablesProbeEntryLimit: 3)
        )
        let disclosure = try XCTUnwrap(
            item(outcome, at: target)?.valuablesDisclosure
        )
        XCTAssertFalse(disclosure.probeComplete, "the budget ran out")
        XCTAssertEqual(disclosure.valuables.map(\.name), ["First.dmg"],
                       "siblings are descended in ascending order")
    }

    // MARK: R3 — the ONE canonical order

    func testOneCanonicalValuablesOrderSharedByEvidenceModelAndJSON()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        // Discovery order (depth-first over byte-wise-sorted children) is
        // deliberately NOT the canonical path order.
        let zeta = try writeBulkFile(
            target.appendingPathComponent("release/zeta.dmg"),
            bytes: aboveFloorBytes
        )
        let beta = try writeBulkFile(
            target.appendingPathComponent("alpha/beta.pkg"),
            bytes: aboveFloorBytes
        )
        let middle = try writeBulkFile(
            target.appendingPathComponent("middle.ipa"),
            bytes: aboveFloorBytes
        )

        let outcome = try await runScan(makeScanner())
        let found = try XCTUnwrap(item(outcome, at: target))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)

        // Byte-wise ascending by CANONICAL IDENTITY PATH, computed here.
        let expected = [beta, middle, zeta]
            .map { identityPath(of: $0) }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        XCTAssertEqual(disclosure.valuables.map(\.canonicalIdentityPath),
                       expected)

        // The STORED order is what evidence, the model, and JSON present —
        // three surfaces, one sort, applied once at detection.
        let names = disclosure.valuables.map(\.name)
        var cursor = found.evidence.startIndex
        for name in names {
            let range = try XCTUnwrap(
                found.evidence.range(of: name, range: cursor..<found.evidence.endIndex),
                "evidence lists \(name) in canonical order: \(found.evidence)"
            )
            cursor = range.upperBound
        }
        let row = CLIHandler.scannerItemRowJSON(for: found)
        let rows = try XCTUnwrap(row["valuables"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["path"] as? String }, expected,
                       "the wire array is the stored order — no re-sort")
    }

    // MARK: R17 — alias-root coherence

    func testAliasRootSpellingYieldsIdenticalOrderingAndIdenticalTokens()
        async throws
    {
        let real = base.appendingPathComponent("real")
        let projects = real.appendingPathComponent("projects")
        let target = try makeProject(
            at: projects.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        for name in ["release/One.dmg", "release/Two.pkg"] {
            try writeBulkFile(
                target.appendingPathComponent(name), bytes: aboveFloorBytes
            )
        }
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let aliasRoot = link.appendingPathComponent("projects")

        let canonicalScan = try await runScan(makeScanner(roots: [projects]))
        let aliasScan = try await runScan(makeScanner(roots: [aliasRoot]))
        let canonicalItem = try XCTUnwrap(canonicalScan.items.first)
        let aliasItem = try XCTUnwrap(aliasScan.items.first)

        let canonical = try XCTUnwrap(canonicalItem.valuablesDisclosure)
        let alias = try XCTUnwrap(aliasItem.valuablesDisclosure)
        XCTAssertEqual(canonical.valuables.map(\.canonicalIdentityPath),
                       alias.valuables.map(\.canonicalIdentityPath),
                       "one identity path per valuable, whatever the spelling")
        XCTAssertEqual(canonicalItem.id, aliasItem.id,
                       "the ItemKey is spelling-independent too")
        XCTAssertEqual(canonical.acknowledgementToken(for: canonicalItem.key),
                       alias.acknowledgementToken(for: aliasItem.key))
        XCTAssertNotNil(canonical.acknowledgementToken(for: canonicalItem.key))

        // The alias spelling reaches the SHEET but never the wire.
        XCTAssertTrue(
            alias.valuables.allSatisfy {
                $0.displayURL.path.hasPrefix(aliasRoot.path)
            },
            "displayURL keeps the unresolved discovery spelling: "
                + "\(alias.valuables.map(\.displayURL.path)) under "
                + "\(aliasRoot.path)"
        )
        let rows = try XCTUnwrap(
            CLIHandler.scannerItemRowJSON(for: aliasItem)["valuables"]
                as? [[String: Any]]
        )
        for row in rows {
            let path = try XCTUnwrap(row["path"] as? String)
            XCTAssertFalse(path.hasPrefix(link.path),
                           "the wire path is the CANONICAL identity path")
        }
    }

    // MARK: R17 — disclosure is structural, and is never consent

    func testDisclosureIsStructuralAndCarriesCompletenessNotProse()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        let dmg = try writeBulkFile(
            target.appendingPathComponent("release/App.dmg"),
            bytes: aboveFloorBytes
        )

        let outcome = try await runScan(makeScanner())
        let found = try XCTUnwrap(item(outcome, at: target))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)

        // (a) COMPLETENESS and (b) the DISCLOSED identity set, both read
        // STRUCTURALLY — never parsed out of the evidence sentence.
        XCTAssertTrue(disclosure.probeComplete)
        XCTAssertEqual(Set(disclosure.valuables.map(\.canonicalIdentityPath)),
                       [identityPath(of: dmg)])

        // DISCLOSURE IS NEVER CONSENT: the structural set is what the item
        // SHOWS. The token exists as a derivable value, but nothing on the
        // item marks it authorized — authorization lives only in the
        // per-clean [ItemKey: acknowledgement] context (fn-4.6/4.8/4.9).
        let token = try XCTUnwrap(disclosure.acknowledgementToken(for: found.key))
        XCTAssertFalse(found.evidence.contains(token),
                       "the token is never smuggled into human evidence")
        XCTAssertTrue(found.requiresPreDeleteRevalidation,
                      "a disclosed item still demands re-inspection — the "
                        + "scan-time set authorizes nothing")
    }

    // MARK: R17 — acknowledgement-token derivation (pure)

    /// Hand-built valuables: the token derivation is pure math over the
    /// `ValuableIdentity` integers, provable without any filesystem.
    private func fixtureValuable(
        path: String,
        allocatedBytes: Int64 = 6_000_000,
        device: UInt64 = 16_777_232,
        inode: UInt64 = 12_345_678,
        seconds: Int64 = 1_755_057_600,
        nanoseconds: Int64 = 123_456_789
    ) -> DetectedValuable {
        DetectedValuable(
            name: (path as NSString).lastPathComponent,
            displayURL: URL(fileURLWithPath: "/display" + path),
            canonicalIdentityPath: path,
            identity: ValuableIdentity(
                allocatedBytes: allocatedBytes, device: device, inode: inode,
                modifiedSeconds: seconds, modifiedNanoseconds: nanoseconds
            )
        )
    }

    private func token(
        _ valuables: [DetectedValuable],
        scannerID: String = BuildArtifactsScanner.registeredID,
        itemID: String = "item-a",
        complete: Bool = true
    ) -> String? {
        ValuablesDisclosure.acknowledgementToken(
            scannerID: scannerID, itemID: itemID,
            valuables: valuables, probeComplete: complete
        )
    }

    func testAcknowledgementTokenMatchesThePinnedPreimageAndIsDeterministic()
        throws
    {
        let valuables = [
            fixtureValuable(path: "/dev/proj/target/a.dmg"),
            fixtureValuable(
                path: "/dev/proj/target/b.app", allocatedBytes: 9_000_000,
                device: 16_777_233, inode: 99, seconds: 42, nanoseconds: 7
            ),
        ]
        // The preimage, spelled out INDEPENDENTLY here.
        var preimage = "build_artifacts\u{0}item-a\u{0}"
        preimage += "/dev/proj/target/a.dmg\u{0}6000000\u{0}16777232\u{0}"
            + "12345678\u{0}1755057600\u{0}123456789\u{0}"
        preimage += "/dev/proj/target/b.app\u{0}9000000\u{0}16777233\u{0}"
            + "99\u{0}42\u{0}7\u{0}"
        let expected = SHA256.hash(data: Data(preimage.utf8))
            .map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(token(valuables), expected)
        XCTAssertEqual(expected.count, 64, "full hash, never truncated")
        XCTAssertEqual(expected, expected.lowercased())
        XCTAssertEqual(token(valuables), token(valuables),
                       "deterministic across runs")
    }

    func testTokenRotatesOnEveryPinnedInvalidationAndIsItemBound() throws {
        let base = [fixtureValuable(path: "/a/x.dmg")]
        let baseline = try XCTUnwrap(token(base))

        // MEMBERSHIP: added, removed.
        XCTAssertNotEqual(
            token(base + [fixtureValuable(path: "/a/y.pkg")]), baseline
        )
        XCTAssertNil(token([]), "no empty-set token exists ANYWHERE")

        // SIZE, IDENTITY (in-place replacement), MTIME — each alone rotates.
        XCTAssertNotEqual(
            token([fixtureValuable(path: "/a/x.dmg", allocatedBytes: 6_000_001)]),
            baseline, "a resized valuable rotates the token"
        )
        XCTAssertNotEqual(
            token([fixtureValuable(path: "/a/x.dmg", inode: 12_345_679)]),
            baseline,
            "IN-PLACE REPLACEMENT: same path + size, new inode"
        )
        XCTAssertNotEqual(
            token([fixtureValuable(path: "/a/x.dmg", device: 16_777_233)]),
            baseline
        )
        XCTAssertNotEqual(
            token([fixtureValuable(path: "/a/x.dmg", seconds: 1_755_057_601)]),
            baseline, "a touched valuable rotates the token"
        )
        XCTAssertNotEqual(
            token([fixtureValuable(path: "/a/x.dmg", nanoseconds: 123_456_790)]),
            baseline, "nanosecond precision is IN the preimage"
        )
        XCTAssertNotEqual(token([fixtureValuable(path: "/a/z.dmg")]), baseline,
                          "a moved valuable rotates the token")

        // ITEM-BOUND: the preimage begins with the FULL ItemKey.
        XCTAssertNotEqual(token(base, itemID: "item-b"), baseline,
                          "two items with identical valuables differ")
        XCTAssertNotEqual(token(base, scannerID: "other_scanner"), baseline,
                          "the SAME item id under another scanner differs")

        // The uniform R17 rule: an incomplete probe is TOKENLESS.
        XCTAssertNil(token(base, complete: false))
        XCTAssertNil(token([], complete: false))
    }

    // MARK: R17 — all-integer identity, split sourcing, round trips

    func testIdentityIsAllIntegerAndRoundTripsAcrossJSONTokenAndRecompute()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        let dmg = try writeBulkFile(
            target.appendingPathComponent("release/App.dmg"),
            bytes: aboveFloorBytes
        )

        let outcome = try await runScan(makeScanner())
        let found = try XCTUnwrap(item(outcome, at: target))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)
        let valuable = try XCTUnwrap(disclosure.valuables.first)
        let identity = valuable.identity

        // ALL-INTEGER, proven structurally (no Date can hide in there).
        for child in Mirror(reflecting: identity).children {
            let type = String(describing: Swift.type(of: child.value))
            XCTAssertTrue(["Int64", "UInt64"].contains(type),
                          "ValuableIdentity.\(child.label ?? "?") is \(type)")
        }

        // The integers ARE the raw lstat's.
        let st = try rawStat(dmg)
        XCTAssertEqual(identity.device, UInt64(bitPattern: Int64(st.st_dev)))
        XCTAssertEqual(identity.inode, UInt64(st.st_ino))
        XCTAssertEqual(identity.modifiedSeconds, Int64(st.st_mtimespec.tv_sec))
        XCTAssertEqual(identity.modifiedNanoseconds,
                       Int64(st.st_mtimespec.tv_nsec))
        XCTAssertEqual(identity.allocatedBytes,
                       Int64(st.st_blocks) * 512)

        // (1) SCAN JSON carries the same integers, verbatim.
        let rows = try XCTUnwrap(
            CLIHandler.scannerItemRowJSON(for: found)["valuables"]
                as? [[String: Any]]
        )
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["device"] as? UInt64, identity.device)
        XCTAssertEqual(row["inode"] as? UInt64, identity.inode)
        XCTAssertEqual(row["allocated_bytes"] as? Int64,
                       identity.allocatedBytes)
        XCTAssertEqual(
            row["modified_at_ns"] as? Int64,
            identity.modifiedSeconds * 1_000_000_000
                + identity.modifiedNanoseconds
        )

        // (2) DELETE-TIME RECOMPUTATION reproduces the identical disclosure …
        let recomputed = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: target, provider: FileSystemIdentityProvider()
        )
        XCTAssertEqual(recomputed, disclosure,
                       "the same core over the same tree — bit for bit")

        // (3) … and therefore the identical token.
        XCTAssertEqual(recomputed.acknowledgementToken(for: found.key),
                       disclosure.acknowledgementToken(for: found.key))
        XCTAssertNotNil(recomputed.acknowledgementToken(for: found.key))
    }

    func testNoDateTypeExistsAnywhereInTheValuablesIdentityPath() throws {
        // Grep-proof over the identity path's own file: display dates DERIVE
        // from the integers (fn-4.6) — a `Date` in here would reintroduce the
        // precision drift the all-integer model exists to prevent. Comment
        // lines are stripped: the doc comments discuss `Date` on purpose.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CacheoutTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Cacheout/Scanner/ValuablesDetector.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertGreaterThan(code.count, 1_000, "the gate read real code")
        XCTAssertFalse(code.contains("Date"),
                       "no Date type in the valuables identity path")
    }

    // MARK: R17 — one probe core, one cap

    /// A directory chain far deeper than the retired eight-level depth cap —
    /// the shape real `node_modules` and Swift `.build` trees reach routinely
    /// (this repo's own `.build` nests thirteen deep).
    private func deepChain(_ levels: Int) -> String {
        (1...levels).map { "d\($0)" }.joined(separator: "/")
    }

    func testScanTimeAndPreDeleteProbeShareOneCoreAndTheSameCap()
        async throws
    {
        // The cap is SHARED by construction: the scanner's init default and
        // the delete-time entry point both read the detector constant.
        // Proven behaviorally on a tree DEEPER than any fixed level budget —
        // both surfaces walk it whole and disclose exactly the same thing.
        let deep = try makeProject(
            at: dev.appendingPathComponent("deep"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        try writeBulkFile(
            deep.appendingPathComponent("\(deepChain(14))/Deep.dmg"),
            bytes: aboveFloorBytes
        )

        let outcome = try await runScan(makeScanner())
        let provider = FileSystemIdentityProvider()

        let scanned = try XCTUnwrap(
            item(outcome, at: deep)?.valuablesDisclosure
        )
        let atDelete = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: deep, provider: provider
        )
        XCTAssertTrue(scanned.probeComplete,
                      "the entry budget covers this tree, so it is PROVEN")
        XCTAssertEqual(scanned.valuables.map(\.name), ["Deep.dmg"],
                       "a valuable is found however deep it is buried")
        XCTAssertEqual(scanned, atDelete,
                       "scan time and delete time see the SAME thing")
    }

    func testDeepArtifactTreeWithoutValuablesIsProvenCleanAndStaysCleanable()
        async throws
    {
        // PR #457 review — the STRANDING regression. A depth-shaped bound
        // marked an ordinary deep chain incomplete even with nothing to
        // find, and that verdict was DETERMINISTIC: the GUI filtered the row
        // out, the revalidator refused it, no token could ever exist for it,
        // and the "re-scan and retry" guidance every surface prints could
        // not clear it. The tree here is deeper than the retired cap and
        // holds nothing valuable, so the probe must PROVE it clean.
        let artifact = try makeProject(
            at: dev.appendingPathComponent("deep"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        try writeFile(
            artifact.appendingPathComponent("\(deepChain(14))/chunk.js"),
            bytes: 512
        )

        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)

        XCTAssertEqual(disclosure, .clean,
                       "nothing valuable, inspection FINISHED")
        XCTAssertEqual(found.risk, .safe,
                       "the rule row's own risk — the gate never fired")
        XCTAssertFalse(
            found.evidence.contains("couldn't fully inspect"), found.evidence
        )
        // The GUI shows it as an ordinary row: nothing to acknowledge, and
        // nothing blocking it.
        XCTAssertNil(CacheoutViewModel.blockedReason(for: found))
        XCTAssertNil(disclosure.acknowledgementToken(for: found.key),
                     "still no empty-set token, anywhere")

        // And it actually deletes — the delete-time revalidator allows it.
        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [found], moveToTrash: false)
        XCTAssertTrue(report.errors.isEmpty,
                      report.errors.map(\.message).joined(separator: "; "))
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: artifact.path))
    }

    func testDeepBundleIsSizedWholeSoItClearsTheFloorAndIsDisclosed()
        async throws
    {
        // The other half of the retired depth cap: a bundle's subtree sizing
        // truncated at a fixed level UNDER-counts, and an under-counted
        // bundle falls below the floor and vanishes from the disclosure —
        // the probe would then have hidden a real release artifact rather
        // than merely refusing to clean one. `.app` bundles nest deeply by
        // construction (`Contents/Frameworks/…/Versions/A/Resources/…`).
        let artifact = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let app = artifact.appendingPathComponent("Shipped.app")
        let buried = try writeBulkFile(
            app.appendingPathComponent(
                "Contents/Frameworks/Dep.framework/Versions/A/Resources/"
                    + "Base.lproj/payload.bin"
            ),
            bytes: aboveFloorBytes
        )

        let outcome = try await runScan(makeScanner())
        let found = try XCTUnwrap(item(outcome, at: artifact))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)

        XCTAssertTrue(disclosure.probeComplete)
        XCTAssertEqual(disclosure.valuables.map(\.name), ["Shipped.app"])
        XCTAssertEqual(
            disclosure.valuables.first?.identity.allocatedBytes,
            allocated(buried),
            "the WHOLE subtree is summed, so the bundle clears the floor"
        )
        XCTAssertNotNil(disclosure.acknowledgementToken(for: found.key),
                       "a COMPLETE probe of a real hit IS acknowledgeable")
    }

    // MARK: R15/R17 — the probe never crosses a mount boundary

    func testProbeStopsAtANestedMountAndStillWalksTheRestOfTheTree()
        async throws
    {
        // PR #457 review (P2). Removing the depth cap left the 20,000-entry
        // budget as the only bound, so a volume mounted inside a matched
        // artifact dir could absorb the WHOLE budget — up to 20,000 reads
        // outside the configured dev root, on network/removable/FUSE storage,
        // for an item the boundary already made uncleanable.
        let artifact = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        // A real valuable INSIDE the tree, buried deeper than the retired
        // depth cap: the walk must still reach it (no dd9faec regression).
        try writeBulkFile(
            artifact.appendingPathComponent("\(deepChain(14))/InTree.dmg"),
            bytes: aboveFloorBytes
        )
        // The mounted volume, holding a valuable that must NEVER be read.
        let mounted = artifact.appendingPathComponent("mounted-volume")
        let beyond = try writeBulkFile(
            mounted.appendingPathComponent("Beyond.dmg"), bytes: aboveFloorBytes
        )

        let provider = BoundaryTouchRecordingProvider()
        provider.mountPointInodes.insert(
            try XCTUnwrap(provider.identity(of: mounted)?.inode)
        )

        let outcome = try await runScan(makeScanner(provider: provider))
        let found = try XCTUnwrap(item(outcome, at: artifact, provider: provider))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)

        // THE CLAIM: not one entry of the mounted volume was read.
        XCTAssertEqual(
            provider.touches(below: mounted), [],
            "nothing beneath the mount is ever lstat'd — no network round "
                + "trip, no privacy-sensitive read outside the dev root"
        )
        XCTAssertFalse(
            disclosure.valuables.contains { $0.name == "Beyond.dmg" },
            "a valuable past the boundary is not disclosed because it was "
                + "never looked at"
        )
        XCTAssertTrue(fm.fileExists(atPath: beyond.path))

        // Honest, and fail-closed: we did not look there.
        XCTAssertFalse(disclosure.probeComplete,
                       "an uncrossed boundary is UNPROVEN, never 'clean'")
        // And the rest of the tree was still walked whole — the boundary
        // stops one branch, not the probe.
        XCTAssertEqual(disclosure.valuables.map(\.name), ["InTree.dmg"],
                       "the in-tree valuable, deeper than the retired cap, "
                        + "is still found")

        // Nothing NEW is stranded: the boundary already denied this item.
        XCTAssertEqual(found.state, .denied)
        XCTAssertEqual(CLIHandler.cleanPlanAction(for: found), "refuse",
                       "uncleanable before the probe ran, uncleanable after")
    }

    func testDeleteTimeProbeAlsoStopsAtAMountAndAgreesWithScanTime()
        async throws
    {
        // WHY THE CHECK LIVES IN THE PROBE, not at the scan-time call site:
        // the reviewer's cheaper option — gate on the size report's already
        // known `hasBoundary` — fixes ONLY the face that has a report. The
        // delete-time face is handed a bare URL (a volume can be mounted into
        // a build dir between scan and clean), so gating there would leave it
        // walking through the mount: exactly the scan/delete drift the "one
        // core, two call sites" rule exists to prevent.
        let artifact = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let mounted = artifact.appendingPathComponent("mounted-volume")
        try writeBulkFile(
            mounted.appendingPathComponent("Beyond.dmg"), bytes: aboveFloorBytes
        )

        let scanProvider = BoundaryTouchRecordingProvider()
        scanProvider.mountPointInodes.insert(
            try XCTUnwrap(scanProvider.identity(of: mounted)?.inode)
        )
        let outcome = try await runScan(makeScanner(provider: scanProvider))
        let scanned = try XCTUnwrap(
            item(outcome, at: artifact, provider: scanProvider)?
                .valuablesDisclosure
        )

        // The DELETE-TIME face, on its own fresh recorder.
        let deleteProvider = BoundaryTouchRecordingProvider()
        deleteProvider.mountPointInodes.insert(
            try XCTUnwrap(deleteProvider.identity(of: mounted)?.inode)
        )
        let atDelete = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: deleteProvider
        )

        XCTAssertEqual(
            deleteProvider.touches(below: mounted), [],
            "the delete-time probe does not cross either — the check is in "
                + "the shared core, so both faces inherit it"
        )
        XCTAssertFalse(atDelete.probeComplete)
        XCTAssertEqual(atDelete.valuables, [])
        XCTAssertEqual(scanned, atDelete,
                       "scan time and delete time reach the SAME verdict — "
                        + "no drift")
        XCTAssertNil(
            ValuablesDisclosure.acknowledgementToken(
                scannerID: BuildArtifactsScanner.registeredID,
                itemID: "any", valuables: atDelete.valuables,
                probeComplete: atDelete.probeComplete
            ),
            "an unfinished inspection is tokenless, as always"
        )
    }

    func testArtifactDirThatIsItselfAMountIsNeverOpenedByTheProbe()
        async throws
    {
        // The ROOT cell. The sizer declines to enumerate its own root when
        // that root is a mount (`DirectorySizer.swift:202`); the probe must
        // decline identically, or it reads a whole foreign volume that the
        // caller has already denied.
        let artifact = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        try writeBulkFile(
            artifact.appendingPathComponent("Shipped.dmg"),
            bytes: aboveFloorBytes
        )

        let provider = BoundaryTouchRecordingProvider()
        provider.mountPointInodes.insert(
            try XCTUnwrap(provider.identity(of: artifact)?.inode)
        )

        let outcome = try await runScan(makeScanner(provider: provider))
        let found = try XCTUnwrap(item(outcome, at: artifact, provider: provider))

        XCTAssertEqual(
            provider.touches(below: artifact), [],
            "not one entry of the mounted volume is read — the probe returns "
                + "before opening the directory at all"
        )
        XCTAssertEqual(found.valuablesDisclosure, .incomplete,
                       "unproven, and nothing disclosed from a volume we "
                        + "refused to read")
        XCTAssertEqual(found.state, .denied)

        // The delete-time face agrees, on the same root shape.
        let deleteProvider = BoundaryTouchRecordingProvider()
        deleteProvider.mountPointInodes.insert(
            try XCTUnwrap(deleteProvider.identity(of: artifact)?.inode)
        )
        XCTAssertEqual(
            BuildArtifactsScanner.preDeleteValuablesProbe(
                at: artifact, provider: deleteProvider
            ),
            .incomplete
        )
        XCTAssertEqual(deleteProvider.touches(below: artifact), [])
    }

    func testPreDeleteProbeKindGatingFailsClosedOnlyWhereItMust() throws {
        let provider = FileSystemIdentityProvider()
        // Absent: the deletion path owns its own ENOENT.
        XCTAssertEqual(
            BuildArtifactsScanner.preDeleteValuablesProbe(
                at: dev.appendingPathComponent("nope"), provider: provider
            ),
            .clean
        )
        // A non-directory leaf has no contents of its own.
        let file = try writeFile(dev.appendingPathComponent("leaf.bin"))
        XCTAssertEqual(
            BuildArtifactsScanner.preDeleteValuablesProbe(
                at: file, provider: provider
            ),
            .clean
        )
        // Unprobeable → INCOMPLETE (fail closed).
        let failing = FailingProbeProvider()
        let dir = dev.appendingPathComponent("dir")
        try mkdir(dir)
        failing.failingPaths = [dir.path]
        let verdict = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: dir, provider: failing
        )
        XCTAssertFalse(verdict.probeComplete)
        XCTAssertEqual(verdict.valuables, [])
    }

    // MARK: R13 — additive model fields + the value-domain family

    func testAdditiveFieldsDefaultAbsentAndValidatorRejectsEachDomainCell()
        async throws
    {
        let target = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        let scanner = makeScanner()
        let outcome = try await runScan(scanner)
        let found = try XCTUnwrap(item(outcome, at: target))

        // Items WITHOUT the fields (every other scanner, by construction:
        // the initializer defaults them) stay valid, unchanged. Registered
        // WITHOUT a revalidator declaration, because that is what "every
        // other scanner" means once fn-4.8's marker invariant exists: a
        // scanner that declares one must mark the items its predicate deems
        // applicable (proven in
        // `testUnmarkedBuildArtifactItemFailsRuntimeValidation`).
        let legacy = replacing(
            found, disclosure: nil, requiresRevalidation: false
        )
        XCTAssertNil(legacy.valuablesDisclosure)
        XCTAssertFalse(legacy.requiresPreDeleteRevalidation)
        assertValidatorAccepts(
            legacy, scanner: scanner, declaresRevalidator: false
        )

        // One malformed cell per PINNED domain — checked-REJECT, never a
        // saturated lie and never a trap after validation.
        // `derivable` records whether `modified_at_ns` still exists for the
        // cell: only the TIME-domain violations make it underivable, and the
        // wire must never invent a number for those.
        let cells: [(label: String, identity: ValuableIdentity, derivable: Bool)] = [
            ("negative allocatedBytes", ValuableIdentity(
                allocatedBytes: -1, device: 1, inode: 2,
                modifiedSeconds: 0, modifiedNanoseconds: 0
            ), true),
            ("nanoseconds == 1e9", ValuableIdentity(
                allocatedBytes: 1, device: 1, inode: 2,
                modifiedSeconds: 0, modifiedNanoseconds: 1_000_000_000
            ), false),
            ("nanoseconds < 0", ValuableIdentity(
                allocatedBytes: 1, device: 1, inode: 2,
                modifiedSeconds: 0, modifiedNanoseconds: -1
            ), false),
            ("seconds overflow modified_at_ns", ValuableIdentity(
                allocatedBytes: 1, device: 1, inode: 2,
                modifiedSeconds: Int64.max / 1_000_000_000,
                modifiedNanoseconds: 999_999_999
            ), false),
        ]
        for (label, identity, derivable) in cells {
            let malformed = replacing(found, disclosure: ValuablesDisclosure(
                valuables: [DetectedValuable(
                    name: "bad", displayURL: target,
                    canonicalIdentityPath: identityPath(of: target),
                    identity: identity
                )],
                probeComplete: true
            ))
            XCTAssertEqual(identity.modifiedAtNanoseconds != nil, derivable,
                           "\(label): modified_at_ns is never invented")
            assertValidatorRejects(malformed, scanner: scanner, label: label)
        }

        // The LAST representable instant stays valid — the check REJECTS,
        // it never narrows the honest domain.
        let maxSeconds = (Int64.max - 999_999_999) / 1_000_000_000
        let ok = replacing(found, disclosure: ValuablesDisclosure(
            valuables: [DetectedValuable(
                name: "ok", displayURL: target,
                canonicalIdentityPath: identityPath(of: target),
                identity: ValuableIdentity(
                    allocatedBytes: 0, device: 0, inode: 0,
                    modifiedSeconds: maxSeconds,
                    modifiedNanoseconds: 999_999_999
                )
            )],
            probeComplete: true
        ))
        XCTAssertNotNil(
            ValuableIdentity(
                allocatedBytes: 0, device: 0, inode: 0,
                modifiedSeconds: maxSeconds, modifiedNanoseconds: 999_999_999
            ).modifiedAtNanoseconds
        )
        assertValidatorAccepts(ok, scanner: scanner)
    }

    func testRevalidationMarkerRidesEveryBuildArtifactItemAndNothingElse()
        async throws
    {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        // A mixed fixture: a measured row, an empty row, and a DENIED row —
        // all carry the probe, so all carry the marker.
        let measured = try makeProject(
            at: dev.appendingPathComponent("a"),
            marker: "Cargo.toml", artifact: "target"
        )
        let empty = try makeProject(
            at: dev.appendingPathComponent("b"),
            marker: "package.json", artifact: "node_modules",
            payloadBytes: nil
        )
        let denied = try makeProject(
            at: dev.appendingPathComponent("c"),
            marker: "Package.swift", artifact: ".build"
        )
        try chmod000(denied)

        let outcome = try await runScan(makeScanner())
        XCTAssertEqual(outcome.items.count, 3)
        for url in [measured, empty, denied] {
            let found = try XCTUnwrap(item(outcome, at: url))
            XCTAssertTrue(found.requiresPreDeleteRevalidation,
                          "\(url.lastPathComponent) must be re-inspected")
            XCTAssertNotNil(found.valuablesDisclosure)
        }
        XCTAssertEqual(
            try XCTUnwrap(item(outcome, at: denied)).state, .denied
        )

        // Existing scanners are UNAFFECTED: their emissions go through the
        // same initializer WITHOUT the new arguments, which defaults the
        // marker off. fn-4.8 migrates the orphaned-caches entries.
        let untouched = replacing(
            try XCTUnwrap(item(outcome, at: measured)),
            disclosure: nil, requiresRevalidation: false
        )
        XCTAssertFalse(untouched.requiresPreDeleteRevalidation)
    }

    // MARK: R3 — scan JSON rows

    func testScannerItemRowCarriesLogicalBytesAndValuablesElseOmitsThem()
        async throws
    {
        // DIVERGENT (sparse) AND flagged — both additive fields at once.
        let flagged = try makeProject(
            at: dev.appendingPathComponent("flagged"),
            marker: "Cargo.toml", artifact: "target"
        )
        let sparse = flagged.appendingPathComponent("sparse.bin")
        fm.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 50_000_000)
        try handle.close()
        let dmg = try writeBulkFile(
            flagged.appendingPathComponent("release/App.dmg"),
            bytes: aboveFloorBytes
        )
        let plain = try makeProject(
            at: dev.appendingPathComponent("plain"),
            marker: "Cargo.toml", artifact: "target"
        )

        let outcome = try await runScan(makeScanner())
        let flaggedItem = try XCTUnwrap(item(outcome, at: flagged))
        let plainItem = try XCTUnwrap(item(outcome, at: plain))

        let flaggedRow = CLIHandler.scannerItemRowJSON(for: flaggedItem)
        XCTAssertEqual(flaggedRow["logical_bytes"] as? Int64,
                       flaggedItem.logicalBytes)
        let rows = try XCTUnwrap(flaggedRow["valuables"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        // The ONE pinned SIX-FIELD element shape, exactly.
        let st = try rawStat(dmg)
        XCTAssertEqual(rows[0] as NSDictionary, [
            "name": "App.dmg",
            "path": identityPath(of: dmg),
            "allocated_bytes": Int64(st.st_blocks) * 512,
            "device": UInt64(bitPattern: Int64(st.st_dev)),
            "inode": UInt64(st.st_ino),
            "modified_at_ns": Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(st.st_mtimespec.tv_nsec),
        ] as NSDictionary)
        // …and it survives real JSON serialization (unsigned 64-bit ids).
        XCTAssertTrue(JSONSerialization.isValidJSONObject(flaggedRow))
        let encoded = try JSONSerialization.data(withJSONObject: flaggedRow)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(decoded["valuables"])

        // ABSENT — not null — for a clean, non-divergent item.
        let plainRow = CLIHandler.scannerItemRowJSON(for: plainItem)
        XCTAssertNil(plainItem.logicalBytes)
        XCTAssertFalse(plainRow.keys.contains("logical_bytes"))
        XCTAssertFalse(plainRow.keys.contains("valuables"))
        XCTAssertEqual(
            try XCTUnwrap(plainItem.valuablesDisclosure), .clean,
            "the item was probed and clean — the ROW just says nothing"
        )
    }

    // MARK: - fn-4.4 validator helpers

    /// Rebuild an emitted item with a different valuables field — the only
    /// way to express a scanner MAPPING BUG (production sources reject
    /// out-of-domain metadata at the `lstat`).
    private func replacing(
        _ item: ReclaimableItem,
        disclosure: ValuablesDisclosure?,
        requiresRevalidation: Bool = true
    ) -> ReclaimableItem {
        ReclaimableItem(
            id: item.id, scannerID: item.scannerID,
            displayName: item.displayName,
            exactBytes: item.exactBytes,
            estimatedUpToBytes: item.estimatedUpToBytes,
            logicalBytes: item.logicalBytes, itemCount: item.itemCount,
            url: item.url, declaredDisplayPath: item.declaredDisplayPath,
            rootRecords: item.rootRecords, state: item.state,
            scanError: item.scanError, risk: item.risk,
            evidence: item.evidence, rebuildNote: item.rebuildNote,
            action: item.action, admission: item.admission,
            defaultSelected: item.defaultSelected,
            automaticCleanEligible: item.automaticCleanEligible,
            isStale: item.isStale,
            valuablesDisclosure: disclosure,
            requiresPreDeleteRevalidation: requiresRevalidation
        )
    }

    private func validatorVerdict(
        _ item: ReclaimableItem, scanner: BuildArtifactsScanner,
        declaresRevalidator: Bool = true
    ) throws -> ValidatedScannerEvent {
        // The production conformance registers directly; the adapter is
        // used ONLY to strip the revalidator declaration (the
        // no-revalidator shape).
        let scanners: [any SpaceScanner] = declaresRevalidator
            ? [scanner]
            : [BuildArtifactsAdapterScanner(
                scanner: scanner, declaresRevalidator: false
            )]
        let runtime = try SpaceScannerRuntime(
            scanners: scanners,
            categories: [], home: fixtureHome,
            provider: FileSystemIdentityProvider()
        )
        return runtime.validatedOutcome(
            ScanOutcome(items: [item], errors: []),
            from: BuildArtifactsScanner.registeredID
        )
    }

    private func assertValidatorAccepts(
        _ item: ReclaimableItem, scanner: BuildArtifactsScanner,
        declaresRevalidator: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let verdict = try? validatorVerdict(
            item, scanner: scanner, declaresRevalidator: declaresRevalidator
        )
        else { return XCTFail("runtime construction failed", file: file, line: line) }
        if case .malformed(_, let issue) = verdict {
            XCTFail("unexpectedly malformed: \(issue.detail)",
                    file: file, line: line)
        }
    }

    private func assertValidatorRejects(
        _ item: ReclaimableItem, scanner: BuildArtifactsScanner,
        label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let verdict = try? validatorVerdict(item, scanner: scanner)
        else { return XCTFail("runtime construction failed", file: file, line: line) }
        guard case .malformed(_, let issue) = verdict else {
            return XCTFail("\(label) must malform the outcome",
                           file: file, line: line)
        }
        XCTAssertEqual(issue.kind, .malformedOutcome, file: file, line: line)
        XCTAssertNil(issue.url, "the synthesized issue is path-less",
                     file: file, line: line)
    }

    // ====================================================================
    // MARK: - fn-4.8: the pre-delete revalidator seam (R17/D8)
    // ====================================================================
    //
    // `build_artifacts` is NOT registered in production yet (fn-4.5 owns the
    // atomic swap), so every proof below runs through the same TEST-ONLY
    // adapter the R13 round-trips use — now also surfacing the scanner's own
    // `preDeleteRevalidator` declaration — registered via the PUBLIC
    // `SpaceScannerRuntime(scanners:…)` initializer. The runtime captures the
    // declaration at registration and `makeCleaner(snapshot:)` injects it, so
    // these are the production wiring, one conformance line early.

    /// A validated scan SESSION through the adapter-registered runtime: the
    /// items, the session's container snapshot, and the runtime that will
    /// build the cleaner.
    private func scanSession(
        _ scanner: BuildArtifactsScanner,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (
        items: [ReclaimableItem],
        snapshot: ContainerSnapshot,
        runtime: SpaceScannerRuntime
    ) {
        let runtime = try SpaceScannerRuntime(
            scanners: [scanner],
            categories: [], home: fixtureHome,
            provider: FileSystemIdentityProvider()
        )
        let session = runtime.scanValidatedSession(
            context: ScanContext(trigger: .userInitiated)
        )
        var items: [ReclaimableItem] = []
        for await event in session.events {
            switch event {
            case .outcome(_, let outcome):
                items = outcome.items
            case .malformed(_, let issue):
                XCTFail("outcome malformed: \(issue.detail)",
                        file: file, line: line)
            }
        }
        return (items, session.snapshot, runtime)
    }

    private func cleanupLog() -> String {
        (try? String(
            contentsOf: fixtureHome.appendingPathComponent(".cacheout/cleanup.log"),
            encoding: .utf8
        )) ?? ""
    }

    /// The revalidator exactly as the runtime captured it.
    private var revalidator: PreDeleteRevalidator {
        BuildArtifactsScanner.preDeleteRevalidator(
            provider: FileSystemIdentityProvider()
        )
    }

    /// An unreadable branch inside the artifact dir — the fail-closed
    /// "couldn't finish" fixture at PRODUCTION caps. A depth boundary used
    /// to serve here; it no longer exists (PR #457 review), and GENUINE
    /// uncertainty is what must still refuse. chmod 000 is meaningless as
    /// root, so callers skip there.
    private func plantUnreadableBranch(in artifact: URL) throws {
        let locked = artifact.appendingPathComponent("locked-branch")
        try mkdir(locked)
        try chmod000(locked)
    }

    func testValuablePlantedAfterScanRefusesThatItemAndOthersProceed()
        async throws
    {
        // The seam's headline case: `ContainerSnapshot` binds the dev ROOT's
        // identity, not the artifact dir's CONTENTS, so a DMG written after
        // the scan (or mid-build) passes every pre-existing gate. The
        // revalidator re-probes at the chokepoint and refuses FAIL-CLOSED —
        // an item-keyed error plus a REFUSED log line, never a silent skip —
        // while every OTHER selected item deletes normally.
        let guarded = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target"
        )
        let plain = try makeProject(
            at: dev.appendingPathComponent("plain"),
            marker: "Cargo.toml", artifact: "target"
        )

        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let guardedItem = try XCTUnwrap(item(from: items, at: guarded))
        let plainItem = try XCTUnwrap(item(from: items, at: plain))
        XCTAssertEqual(
            try XCTUnwrap(guardedItem.valuablesDisclosure).valuables.count, 0,
            "fixture precondition: nothing valuable existed at scan time"
        )

        // AFTER the scan: a release artifact lands inside the guarded dir.
        let dmg = try writeBulkFile(
            guarded.appendingPathComponent(
                "release/bundle/dmg/Murmur_0.1.7_aarch64.dmg"
            ),
            bytes: aboveFloorBytes
        )

        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(
            items: [guardedItem, plainItem], moveToTrash: false
        )

        XCTAssertEqual(report.errors.count, 1)
        let error = try XCTUnwrap(report.errors.first)
        XCTAssertEqual(error.key, guardedItem.key, "the refusal is ITEM-KEYED")
        XCTAssertTrue(error.message.contains("Murmur_0.1.7_aarch64.dmg"),
                      error.message)
        XCTAssertTrue(error.message.contains("not covered by an acknowledgement"),
                      error.message)
        XCTAssertTrue(fm.fileExists(atPath: dmg.path),
                      "the release artifact is byte-untouched")
        XCTAssertTrue(fm.fileExists(atPath: guarded.path))
        XCTAssertTrue(cleanupLog().contains("REFUSED [content-drift]"),
                      "the refusal is LOGGED, never a silent skip")

        XCTAssertEqual(report.entries.map(\.itemID), [plainItem.id],
                       "other selected items proceed unaffected")
        XCTAssertFalse(fm.fileExists(atPath: plain.path))
    }

    func testIncompleteDeleteTimeProbeRefusesWithIncompleteReasonAndNoToken()
        async throws
    {
        // The uniform R17 rule at delete time: an inspection that could not
        // finish is UNAUTHORIZABLE and TOKENLESS. The scan-time probe
        // completed (the item is honest); only the delete-time state is
        // un-inspectable. GENUINE uncertainty — unlike the retired depth
        // boundary, which was merely a budget we declined to spend.
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let artifact = try makeProject(
            at: dev.appendingPathComponent("deep"),
            marker: "Cargo.toml", artifact: "target"
        )
        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))
        XCTAssertTrue(
            try XCTUnwrap(found.valuablesDisclosure).probeComplete,
            "fixture precondition: the SCAN-time probe finished"
        )

        try plantUnreadableBranch(in: artifact)

        // (a) The TYPED verdict — the payload fn-4.9 serializes from.
        switch revalidator.revalidate(item: found, authorization: nil) {
        case .allow:
            XCTFail("an unfinished inspection must refuse")
        case .refuse(let reason, let valuables, let token):
            XCTAssertTrue(reason.contains("couldn't fully re-inspect"), reason)
            XCTAssertNil(token, "an INCOMPLETE probe is tokenless everywhere")
            XCTAssertTrue(valuables.isEmpty,
                          "nothing above the floor was readable")
        }

        // (b) The same refusal through the cleaner: fail-closed, logged.
        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [found], moveToTrash: false)

        XCTAssertTrue(report.entries.isEmpty, "nothing may be deleted")
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(report.errors.first?.key, found.key)
        XCTAssertTrue(
            try XCTUnwrap(report.errors.first?.message)
                .contains("couldn't fully re-inspect"),
            report.errors.first?.message ?? ""
        )
        XCTAssertTrue(fm.fileExists(atPath: artifact.path))
        XCTAssertTrue(cleanupLog().contains("REFUSED [content-drift]"))
    }

    func testAuthorizationContextEntryMatchingCurrentProbeAllowsDeletion()
        async throws
    {
        // The cleaner is driven DIRECTLY with an INJECTED authorization
        // context (CLI construction is fn-4.9, sheet population fn-4.6). A
        // token computed from the CURRENT delete-time probe — and ONLY that
        // one — lets an acknowledged valuable-bearing item delete.
        let artifact = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target"
        )
        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))

        try writeBulkFile(
            artifact.appendingPathComponent("release/Shipped.dmg"),
            bytes: aboveFloorBytes
        )

        // The token derives from the DELETE-TIME probe, recomputed here
        // independently of the verdict.
        let current = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: FileSystemIdentityProvider()
        )
        XCTAssertTrue(current.probeComplete)
        let expected = try XCTUnwrap(current.acknowledgementToken(for: found.key))

        // A WRONG entry is not an acknowledgement.
        let wrong = runtime.makeCleaner(snapshot: snapshot)
        let refused = await wrong.clean(
            items: [found], moveToTrash: false,
            authorization: [found.key: String(repeating: "0", count: 64)]
        )
        XCTAssertTrue(refused.entries.isEmpty)
        XCTAssertEqual(refused.errors.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: artifact.path))

        // The matching entry proceeds — authorized valuables stay deletable.
        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(
            items: [found], moveToTrash: false,
            authorization: [found.key: expected]
        )

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.entries.map(\.itemID), [found.id])
        XCTAssertFalse(fm.fileExists(atPath: artifact.path))
    }

    func testVanishedValuableSetRefusesOnceWithNoTokenThenRescanDeletes()
        async throws
    {
        // The VANISHED-SET contract: no empty-set token exists anywhere, so
        // an item whose disclosed valuables are gone refuses ONCE with no
        // token; the caller re-scans and retries WITHOUT acknowledgement.
        let artifact = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target"
        )
        let dmg = try writeBulkFile(
            artifact.appendingPathComponent("release/Shipped.dmg"),
            bytes: aboveFloorBytes
        )

        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))
        XCTAssertEqual(
            try XCTUnwrap(found.valuablesDisclosure).valuables.count, 1,
            "fixture precondition: the scan disclosed the DMG"
        )

        try fm.removeItem(at: dmg)

        switch revalidator.revalidate(item: found, authorization: nil) {
        case .allow:
            XCTFail("a vanished disclosed set refuses once")
        case .refuse(let reason, let valuables, let token):
            XCTAssertTrue(reason.contains("no longer there"), reason)
            XCTAssertNil(token, "there is nothing left to acknowledge")
            XCTAssertTrue(valuables.isEmpty)
        }

        let report = await runtime.makeCleaner(snapshot: snapshot)
            .clean(items: [found], moveToTrash: false)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: artifact.path))

        // Re-scan: the item is now valuables-free and needs no
        // acknowledgement at all.
        let (fresh, freshSnapshot, freshRuntime) =
            try await scanSession(makeScanner())
        let refreshed = try XCTUnwrap(item(from: fresh, at: artifact))
        XCTAssertTrue(
            try XCTUnwrap(refreshed.valuablesDisclosure).valuables.isEmpty
        )
        let second = await freshRuntime.makeCleaner(snapshot: freshSnapshot)
            .clean(items: [refreshed], moveToTrash: false)
        XCTAssertTrue(second.errors.isEmpty, "\(second.errors)")
        XCTAssertFalse(fm.fileExists(atPath: artifact.path))
    }

    func testRefuseVerdictCarriesCurrentValuablesInCanonicalOrderWithToken()
        async throws
    {
        // The typed payload is what fn-4.9 serializes: the CURRENT probe's
        // valuables in the ONE canonical order (byte-wise ascending
        // `canonicalIdentityPath`) plus the token — present here because the
        // probe is COMPLETE and the set NON-EMPTY.
        let artifact = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target"
        )
        let (items, _, _) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))

        for name in ["release/zeta.dmg", "release/alpha.pkg"] {
            try writeBulkFile(
                artifact.appendingPathComponent(name), bytes: aboveFloorBytes
            )
        }
        let current = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: FileSystemIdentityProvider()
        )

        switch revalidator.revalidate(item: found, authorization: nil) {
        case .allow:
            XCTFail("an unacknowledged valuable-bearing item refuses")
        case .refuse(_, let valuables, let token):
            XCTAssertEqual(valuables, current.valuables,
                           "the payload IS the current probe's set")
            XCTAssertEqual(valuables.map(\.name), ["alpha.pkg", "zeta.dmg"],
                           "canonical order, not discovery order")
            XCTAssertEqual(
                token, current.acknowledgementToken(for: found.key),
                "a COMPLETE, non-empty current set carries its fresh token"
            )
            XCTAssertNotNil(token)
        }
    }

    func testUnmarkedBuildArtifactItemFailsRuntimeValidation() async throws {
        // The runtime's marker invariant, this scanner's face: its
        // revalidator deems EVERY item applicable, so an item emitted
        // WITHOUT `requiresPreDeleteRevalidation` is a structural violation —
        // a marker-forgetting mapping regression can never publish items.
        let artifact = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target"
        )
        let scanner = makeScanner()
        let outcome = try await runScan(scanner)
        let found = try XCTUnwrap(item(outcome, at: artifact))

        assertValidatorRejects(
            replacing(
                found, disclosure: found.valuablesDisclosure,
                requiresRevalidation: false
            ),
            scanner: scanner,
            label: "an applicable-but-unmarked build-artifact item"
        )
    }

    /// Session items are already validated — index them the same way the
    /// outcome helper does.
    private func item(
        from items: [ReclaimableItem], at url: URL,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> ReclaimableItem? {
        let id = expectedID(of: url, provider: provider)
        return items.first { $0.id == id }
    }

    // ====================================================================
    // MARK: - fn-4.5: the deletion path + the registration story
    // ====================================================================
    //
    // The scanner is registered through the PUBLIC runtime initializer by
    // its OWN production conformance (no adapter), so every deletion below
    // runs the production chain: registration → `trustedContainerRoots` →
    // session `ContainerSnapshot` → `makeCleaner(snapshot:)` →
    // `admitContainer` + `validateRemovableItem` → revalidator → removal.

    /// R5 base: the artifact DIRECTORY ITSELF is removed (never its
    /// contents-with-parent-preserved), the project and its marker survive,
    /// and freed bytes equal an INDEPENDENT lstat measurement.
    func testRegisteredScannerDeletesTheArtifactDirectoryAndReportsFreedBytes()
        async throws
    {
        let project = dev.appendingPathComponent("rust")
        let artifact = try makeProject(
            at: project, marker: "Cargo.toml", artifact: "target"
        )
        let deeper = try writeFile(
            artifact.appendingPathComponent("debug/build/out.o"), bytes: 16_384
        )
        let payload = artifact.appendingPathComponent("payload.bin")
        let expectedExact = allocated(payload, deeper)

        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))
        XCTAssertEqual(found.action.wireString, "remove_item")

        let report = await runtime.makeCleaner(snapshot: snapshot)
            .clean(items: [found], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.entries.map(\.itemID), [found.id])
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertEqual(entry.scannerID, BuildArtifactsScanner.registeredID)
        XCTAssertEqual(entry.disposal, .permanent)
        XCTAssertEqual(entry.exactBytes, expectedExact,
                       "freed bytes are the DELETION-TIME measurement")
        XCTAssertEqual(entry.estimatedUpToBytes, 0, "no hardlinks in the fixture")
        XCTAssertEqual(report.totalFreedExact, expectedExact)

        XCTAssertFalse(fm.fileExists(atPath: artifact.path),
                       "the artifact directory itself is gone")
        XCTAssertTrue(fm.fileExists(atPath: project.path))
        XCTAssertTrue(
            fm.fileExists(atPath: project.appendingPathComponent("Cargo.toml").path),
            "the marker that proved the match is untouched"
        )
    }

    /// R5: the trash toggle is honored BOTH ways, and a trash FAILURE never
    /// falls through to a permanent delete.
    func testTrashDispositionHonoredAndTrashFailureNeverFallsThrough()
        async throws
    {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        let trashed = TrashSpy(destination: base.appendingPathComponent("trash"))
        try mkdir(trashed.destination)

        // (a) FAILURE first, on the same fixture: the item error surfaces
        // and the target is still there — no permanent fallback.
        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))
        let failing = runtime.makeCleaner(
            snapshot: snapshot, trashHandler: { _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        )
        let failedReport = await failing.clean(items: [found], moveToTrash: true)
        XCTAssertTrue(failedReport.entries.isEmpty)
        XCTAssertEqual(failedReport.errors.map(\.key), [found.key])
        XCTAssertTrue(fm.fileExists(atPath: artifact.path),
                      "a trash failure NEVER falls through to permanent delete")

        // (b) SUCCESS: the injected handler receives the UNRESOLVED target
        // and the entry records `.trash`.
        let cleaner = runtime.makeCleaner(
            snapshot: snapshot, trashHandler: { url in try trashed.accept(url) }
        )
        let report = await cleaner.clean(items: [found], moveToTrash: true)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.entries.map(\.disposal), [.trash])
        XCTAssertEqual(report.disposal, .trash)
        XCTAssertEqual(trashed.accepted.map(\.path), [artifact.path],
                       "the trash seam got the unresolved deletion target")
        XCTAssertFalse(fm.fileExists(atPath: artifact.path))
    }

    /// R5: a cleaner with NO session snapshot fails closed — the deletion
    /// token is structurally unmintable — and a STALE snapshot (the root
    /// replaced after capture) is refused with `containerUnavailable`.
    func testNilAndStaleSnapshotsBothFailClosedWithNothingRemoved() async throws {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))

        // (a) nil snapshot — no fail-open path exists.
        let unbound = await runtime.makeCleaner(snapshot: nil)
            .clean(items: [found], moveToTrash: false)
        XCTAssertTrue(unbound.entries.isEmpty)
        XCTAssertEqual(unbound.errors.map(\.key), [found.key])
        XCTAssertTrue(
            try XCTUnwrap(unbound.errors.first?.message)
                .contains("no scan-session container snapshot"),
            unbound.errors.first?.message ?? ""
        )
        XCTAssertTrue(fm.fileExists(atPath: artifact.path))

        // (b) STALE: the dev ROOT is replaced (rm + mkdir → new inode) after
        // capture — the unmount/remount and swap shapes — so its recorded
        // identity no longer matches. The item's own tree is rebuilt exactly
        // as it was, so ONLY the container identity differs.
        try fm.removeItem(at: dev)
        let rebuilt = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        let stale = await runtime.makeCleaner(snapshot: snapshot)
            .clean(items: [found], moveToTrash: false)
        XCTAssertTrue(stale.entries.isEmpty)
        XCTAssertEqual(stale.errors.map(\.key), [found.key])
        XCTAssertTrue(
            try XCTUnwrap(stale.errors.first?.message)
                .contains("identity changed since the scan"),
            stale.errors.first?.message ?? ""
        )
        XCTAssertTrue(fm.fileExists(atPath: rebuilt.path),
                      "nothing was removed under the replaced root")
    }

    /// R5: a SPARSE artifact frees its ALLOCATED bytes (< logical) — the
    /// 57.1G-logical / 31G-allocated field case, measured at deletion time.
    func testSparseArtifactFreesAllocatedBytesBelowItsLogicalSize() async throws {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("sparse"),
            marker: "Cargo.toml", artifact: "target"
        )
        let sparse = artifact.appendingPathComponent("sparse.bin")
        fm.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 50_000_000)
        try handle.close()
        let expectedExact = allocated(
            artifact.appendingPathComponent("payload.bin"), sparse
        )

        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))
        let logical = try XCTUnwrap(found.logicalBytes)

        let report = await runtime.makeCleaner(snapshot: snapshot)
            .clean(items: [found], moveToTrash: false)

        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertEqual(entry.exactBytes, expectedExact)
        XCTAssertLessThan(entry.exactBytes, logical,
                          "deletion frees ALLOCATED bytes, not the apparent "
                              + "logical size")
        XCTAssertFalse(fm.fileExists(atPath: artifact.path))
    }

    /// R5: a large-ish tree deletes green (the kondo #97 "Directory not
    /// empty" race defense rides the existing guarded-removal path).
    func testLargeArtifactTreeDeletesGreen() async throws {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("big"),
            marker: "Cargo.toml", artifact: "target"
        )
        for bucket in 0..<12 {
            for file in 0..<25 {
                try writeFile(
                    artifact.appendingPathComponent("deps/b\(bucket)/f\(file).o"),
                    bytes: 512
                )
            }
        }

        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))
        XCTAssertGreaterThan(found.itemCount, 300)

        let report = await runtime.makeCleaner(snapshot: snapshot)
            .clean(items: [found], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: artifact.path))
    }

    /// R11: every target passes delete-time `admitContainer` +
    /// `validateRemovableItem`. A container-ESCAPING target is refused and
    /// surfaced; the other selected item is unaffected. (Fed to the cleaner
    /// directly: the scan-time validator's origin binding refuses this shape
    /// one layer earlier, so this is the defense-in-depth half.)
    func testContainerEscapingTargetIsRefusedWhileOtherItemsProceed()
        async throws
    {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        let outsider = base.appendingPathComponent("outside/victim")
        try mkdir(outsider)
        try writeFile(outsider.appendingPathComponent("keep.bin"), bytes: 4_096)

        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let good = try XCTUnwrap(item(from: items, at: artifact))
        // Same scanner, same declared origin — but a target OUTSIDE it.
        let escaping = escapingItem(origin: dev, target: outsider)

        let report = await runtime.makeCleaner(snapshot: snapshot)
            .clean(items: [escaping, good], moveToTrash: false)

        XCTAssertEqual(report.errors.map(\.key), [escaping.key])
        XCTAssertTrue(
            try XCTUnwrap(report.errors.first?.message)
                .contains("not strictly inside"),
            report.errors.first?.message ?? ""
        )
        XCTAssertTrue(
            fm.fileExists(atPath: outsider.appendingPathComponent("keep.bin").path),
            "the escaping target is byte-untouched"
        )
        XCTAssertEqual(report.entries.map(\.itemID), [good.id],
                       "the legitimate item in the same clean proceeds")
        XCTAssertFalse(fm.fileExists(atPath: artifact.path))
    }

    /// R16 data path: a POLICY-REJECTED PERSISTED root is never registered
    /// and never walked, while its classified `.containerRefused` issue
    /// rides EVERY scan outcome — asserted across two consecutive scans, and
    /// the stored value is never rewritten.
    func testPolicyRejectedPersistedRootRidesEveryScanAndNeverRegisters()
        async throws
    {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        let persisted = ["/", dev.path]
        defaults.set(persisted, forKey: DevRootsStore.devRootsKey)
        let resolution = DevRootsStore(defaults: defaults)
            .effectiveRoots(home: fixtureHome)
        let scanner = BuildArtifactsScanner(
            home: fixtureHome, devRoots: resolution
        )

        XCTAssertEqual(scanner.trustedContainerRoots.map(\.path), [dev.path],
                       "the refused root is NEVER registered")

        for pass in 1...2 {
            let outcome = try await runScan(scanner)
            let refusals = outcome.errors.filter { $0.kind == .containerRefused }
            XCTAssertEqual(refusals.count, 1, "pass \(pass)")
            XCTAssertEqual(refusals.first?.url?.path, "/", "pass \(pass)")
            XCTAssertTrue(
                (refusals.first?.detail ?? "").contains("filesystem root"),
                "the issue says WHY: \(refusals.first?.detail ?? "")"
            )
            XCTAssertEqual(outcome.items.compactMap(\.url?.path),
                           [identityPath(of: artifact)],
                           "only the kept root was walked (pass \(pass))")
        }

        XCTAssertEqual(
            defaults.array(forKey: DevRootsStore.devRootsKey) as? [String],
            persisted,
            "the persisted list is never rewritten by resolution"
        )
    }

    /// R8/R12 registration story for imperfect roots: NESTED roots register
    /// and walk independently, an ABSENT root is an honest no-item omission
    /// that the snapshot OMITS, and a NON-DIRECTORY root is a classified
    /// per-root issue — all with the DECLARED spellings preserved verbatim.
    func testImperfectKeptRootsRegisterVerbatimAndClassifyAtWalkTime()
        async throws
    {
        let nested = dev.appendingPathComponent("team")
        let outer = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        let inner = try makeProject(
            at: nested.appendingPathComponent("inner"),
            marker: "Cargo.toml", artifact: "target"
        )
        let absent = base.appendingPathComponent("absent-root")
        let fileRoot = try writeFile(
            base.appendingPathComponent("file-root"), bytes: 64
        )
        let declared = [dev!, nested, absent, fileRoot]
        let scanner = makeScanner(roots: declared)

        XCTAssertEqual(scanner.trustedContainerRoots.map(\.path),
                       declared.map(\.path),
                       "kept roots are the DECLARED spellings, verbatim — "
                           + "set-asides pass through")

        // Snapshot capture OMITS the absent root (fail-closed downstream).
        let provider = FileSystemIdentityProvider()
        let snapshot = ContainerSnapshot.capture(
            roots: scanner.trustedContainerRoots, provider: provider
        )
        XCTAssertNil(snapshot.identity(forRootPath: absent.path),
                     "an absent root has no captured identity")
        XCTAssertNotNil(snapshot.identity(forRootPath: dev.path))

        let outcome = try await runScan(scanner)

        // The absent root: NO issue (machines differ), no items.
        XCTAssertFalse(outcome.errors.contains { $0.url?.path == absent.path },
                       "an absent kept root is an honest no-item omission")
        // The non-directory root: a classified per-root issue.
        let fileIssue = try XCTUnwrap(
            outcome.errors.first { $0.url?.path == fileRoot.path }
        )
        XCTAssertEqual(fileIssue.kind, .symlinkRoot)
        // Nested roots walked independently, overlap collapsed to ONE item
        // per canonical identity (D7).
        XCTAssertEqual(
            Set(outcome.items.compactMap(\.url?.path)),
            [identityPath(of: outer), identityPath(of: inner)]
        )
        let innerItem = try XCTUnwrap(item(outcome, at: inner))
        guard case .containerItem(let origin, _) = innerItem.admission else {
            return XCTFail("a build-artifact item carries container admission")
        }
        XCTAssertEqual(origin.path, nested.path,
                       "the DEEPEST declared root wins the provenance")
    }

    /// R12 unmount/permission-loss, both halves: at SCAN time the origin
    /// root failing after admission emits a per-root CLASSIFIED issue (never
    /// a silent zero); at CLEAN time the same disappearance is refused by
    /// the snapshot identity gate.
    func testOriginRootLostAfterAdmissionIsClassifiedAndRefusedAtCleanTime()
        async throws
    {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        // A clean session first — items + snapshot from a healthy scan.
        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))

        // SCAN TIME: the root becomes unreadable mid-life (the unmount /
        // permission-loss shape — admission needs no read permission, so it
        // passes and the ENUMERATION is what fails).
        try chmod000(dev)
        let denied = try await runScan(makeScanner())
        XCTAssertTrue(denied.items.isEmpty, "nothing could be enumerated")
        let issue = try XCTUnwrap(
            denied.errors.first { $0.url?.path == dev.path },
            "the per-root issue is PRESENT — a silent skip is a failure"
        )
        XCTAssertEqual(issue.kind, .permissionDenied)

        // CLEAN TIME: the root VANISHES entirely after capture — the
        // snapshot identity gate refuses (`containerUnavailable`).
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dev.path)
        try fm.removeItem(at: dev)
        let report = await runtime.makeCleaner(snapshot: snapshot)
            .clean(items: [found], moveToTrash: false)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.errors.map(\.key), [found.key])
        XCTAssertTrue(
            try XCTUnwrap(report.errors.first?.message)
                .contains("Container is unavailable"),
            report.errors.first?.message ?? ""
        )
    }

    /// R11/R16 ALIAS-ROOT matrix: a root declared through a symlinked
    /// ANCESTOR admits, walks, and its items DELETE — the snapshot is keyed
    /// by the DECLARED spelling while admission matches by inode identity.
    func testAliasDeclaredRootWalksAndItsItemsDelete() async throws {
        let real = base.appendingPathComponent("real")
        let aliasParent = base.appendingPathComponent("aliaslink")
        try mkdir(real)
        try fm.createSymbolicLink(at: aliasParent, withDestinationURL: real)
        // The declared root's LEAF is a real directory reached THROUGH a
        // symlinked ancestor — the /var → /private/var shape.
        let aliasRoot = aliasParent.appendingPathComponent("dev")
        let artifact = try makeProject(
            at: aliasRoot.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )

        let scanner = makeScanner(roots: [aliasRoot])
        XCTAssertEqual(scanner.trustedContainerRoots.map(\.path),
                       [aliasRoot.path], "the DECLARED spelling is registered")

        let (items, snapshot, runtime) = try await scanSession(scanner)
        XCTAssertNotNil(snapshot.identity(forRootPath: aliasRoot.path),
                        "the snapshot is keyed by the declared spelling")
        let found = try XCTUnwrap(item(from: items, at: artifact))
        guard case .containerItem(let origin, _) = found.admission else {
            return XCTFail("a build-artifact item carries container admission")
        }
        XCTAssertEqual(origin.path, aliasRoot.path)
        XCTAssertEqual(found.url?.path, identityPath(of: artifact),
                       "the published identity is the CANONICAL one")

        let report = await runtime.makeCleaner(snapshot: snapshot)
            .clean(items: [found], moveToTrash: false)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.entries.map(\.itemID), [found.id])
        XCTAssertFalse(fm.fileExists(atPath: artifact.path))
        XCTAssertFalse(
            fm.fileExists(
                atPath: real.appendingPathComponent("dev/rust/target").path
            ),
            "…and it is gone under the canonical spelling too"
        )
    }

    /// R12/R16 alias doctrine, the TCC half: protection is decided on the
    /// CANONICAL root, so an alias spelling INTO `~/Documents` is skipped by
    /// an automatic scan exactly as `~/Documents` would be, and walked by a
    /// user-initiated one.
    func testAliasIntoProtectedAncestorIsGatedOnTheCanonicalRoot() async throws {
        let documents = fixtureHome.appendingPathComponent("Documents")
        let docLink = fixtureHome.appendingPathComponent("doclink")
        try mkdir(documents)
        try fm.createSymbolicLink(at: docLink, withDestinationURL: documents)
        let aliasRoot = docLink.appendingPathComponent("code")
        let artifact = try makeProject(
            at: aliasRoot.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target"
        )
        let scanner = makeScanner(roots: [aliasRoot])

        let automatic = try await runScan(scanner, trigger: .automatic)
        XCTAssertTrue(automatic.items.isEmpty,
                      "an alias INTO ~/Documents is TCC-protected as "
                          + "~/Documents — automatic scans skip it")
        XCTAssertTrue(automatic.errors.isEmpty, "a policy skip is silent")

        let userInitiated = try await runScan(scanner)
        XCTAssertEqual(userInitiated.items.compactMap(\.url?.path),
                       [identityPath(of: artifact)],
                       "an explicit scan walks the protected root")
    }

    // MARK: - fn-4.5 fixtures

    /// A structurally-valid `.removeItem` item of THIS scanner whose target
    /// sits OUTSIDE the declared origin container — the containment-escape
    /// shape, marked exactly as the scanner marks its items so the cleaner's
    /// revalidator dispatch is unchanged.
    private func escapingItem(origin: URL, target: URL) -> ReclaimableItem {
        let provider = FileSystemIdentityProvider()
        let resolved = provider.resolveTargetKeepingLeaf(target)
        return ReclaimableItem(
            id: ReclaimableItem.stableID(
                scannerID: BuildArtifactsScanner.registeredID,
                canonicalPath: resolved.path
            ),
            scannerID: BuildArtifactsScanner.registeredID,
            displayName: target.lastPathComponent,
            exactBytes: 4_096, estimatedUpToBytes: 0, logicalBytes: nil,
            itemCount: 1, url: resolved, declaredDisplayPath: target.path,
            rootRecords: [RootScanRecord(
                requestedURL: target, resolvedURL: resolved, status: .measured
            )],
            state: .measured, scanError: nil, risk: .review,
            evidence: "escaping fixture", rebuildNote: nil,
            action: .removeItem,
            admission: .containerItem(
                originContainer: origin, requestedTargetURL: target
            ),
            defaultSelected: false, automaticCleanEligible: false,
            isStale: nil, valuablesDisclosure: .clean,
            requiresPreDeleteRevalidation: true
        )
    }
}

/// Records what the injectable trash seam received and moves it aside — a
/// hermetic stand-in for `FileManager.trashItem` (the production seam is
/// never invoked in tests).
private final class TrashSpy: @unchecked Sendable {
    let destination: URL
    private let lock = NSLock()
    private var received: [URL] = []

    init(destination: URL) {
        self.destination = destination
    }

    var accepted: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func accept(_ url: URL) throws {
        lock.lock()
        received.append(url)
        lock.unlock()
        try FileManager.default.moveItem(
            at: url,
            to: destination.appendingPathComponent(
                "\(UUID().uuidString)-\(url.lastPathComponent)"
            )
        )
    }
}

// MARK: - Test-only fixtures

/// Records whether any observation happened on the main thread. A reference
/// box so the `@Sendable` clock closure can report out of the scan.
private final class ThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThread = false
    private var calls = 0

    func record(mainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        self.mainThread = self.mainThread || mainThread
    }

    var sawMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mainThread
    }

    var sawAnyCall: Bool {
        lock.lock()
        defer { lock.unlock() }
        return calls > 0
    }
}

/// TEST-ONLY `SpaceScanner` adapter, now reduced to ONE job (fn-4.5): the
/// scanner itself conforms and is registered directly everywhere else in
/// this file, so this wrapper survives only to register the SAME scanner
/// WITHOUT its `preDeleteRevalidator` declaration — the shape of a scanner
/// that needs no delete-time revalidation, which is what proves fn-4.8's
/// marker invariant applies to declared applicability and not to the marker
/// alone.
private struct BuildArtifactsAdapterScanner: SpaceScanner {
    let scanner: BuildArtifactsScanner
    /// Registration WITHOUT the declaration — the shape of every scanner
    /// that needs no delete-time revalidation, used to prove that such a
    /// scanner's unmarked items stay valid under fn-4.8's marker invariant.
    var declaresRevalidator = true

    var id: String { scanner.id }
    var displayName: String { scanner.displayName }
    var trustedContainerRoots: [URL] { scanner.trustedContainerRoots }
    var preDeleteRevalidator: PreDeleteRevalidator? {
        declaresRevalidator ? scanner.preDeleteRevalidator : nil
    }

    func scan(context: ScanContext) async -> ScanOutcome {
        await scanner.scan(context: context)
    }
}
