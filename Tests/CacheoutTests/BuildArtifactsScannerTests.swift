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
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> BuildArtifactsScanner {
        BuildArtifactsScanner(
            home: fixtureHome,
            devRoots: resolution(roots ?? [dev], provider: provider),
            provider: provider,
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
    /// families — through a TEST-ONLY adapter declaring the SAME id and the
    /// SAME trusted container roots (production conformance is fn-4.5's).
    private func assertRoundTripsValidator(
        _ outcome: ScanOutcome,
        scanner: BuildArtifactsScanner,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let runtime = try SpaceScannerRuntime(
            scanners: [BuildArtifactsAdapterScanner(scanner: scanner)],
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

        let provider = CanonicalizeCountingProvider()
        let outcome = try await runScan(
            makeScanner(roots: [dev, innerRoot], provider: provider)
        )

        XCTAssertEqual(outcome.items.count, 1,
                       "overlapping walks collapse to ONE canonical item")
        let found = try XCTUnwrap(outcome.items.first)
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
            XCTAssertEqual(other.items.count, 1)
            guard case .containerItem(let otherOrigin, _) =
                try XCTUnwrap(other.items.first).admission
            else { return XCTFail("expected the containerItem descriptor") }
            XCTAssertEqual(otherOrigin.path, innerRoot.path)
            XCTAssertEqual(other.items.first?.id, found.id)
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

/// The TEST-ONLY `SpaceScanner` adapter for the R13 round-trips: the SAME
/// id (`build_artifacts`) and the SAME declared `trustedContainerRoots` as
/// the scanner under test, registered through the PUBLIC
/// `SpaceScannerRuntime` initializer. Production conformance and the atomic
/// registry swap stay in fn-4.5 — this adapter exists so the validator's
/// origin binding is checked against a REAL registration declaration without
/// making the scanner registrable early.
private struct BuildArtifactsAdapterScanner: SpaceScanner {
    let scanner: BuildArtifactsScanner

    var id: String { scanner.id }
    var displayName: String { scanner.displayName }
    var trustedContainerRoots: [URL] { scanner.trustedContainerRoots }

    func scan(context: ScanContext) async -> ScanOutcome {
        await scanner.scan(context: context)
    }
}
