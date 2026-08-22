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

    /// One entry per PROBE PASS over a watched artifact dir (the walk reads
    /// its root exactly once per pass), recorded through the production
    /// `ValuablesDetector.testHook` seam.
    private var probePasses: [String] = []

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

    /// Run an external tool, discarding its output — used only to attach and
    /// detach the disk image the hermetic real-`trashItem` measurement needs.
    @discardableResult
    private static func runTool(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
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

    /// SEARCHABLE but UNREADABLE (`--x--x--x`): paths THROUGH the directory
    /// still resolve — a dev root configured beneath it opens and walks — while
    /// the directory's own entries cannot be enumerated. Restored in teardown
    /// by the same registry `chmod000` uses.
    private func chmod111(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o111], ofItemAtPath: url.path)
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
        valuablesProbeBudget: ValuablesProbeBudget = .censusProportionate(
            floor: ValuablesDetector.defaultProbeEntryLimit
        ),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> BuildArtifactsScanner {
        BuildArtifactsScanner(
            home: fixtureHome,
            devRoots: resolution(roots ?? [dev], provider: provider),
            provider: provider,
            valuablesProbeBudget: valuablesProbeBudget,
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

        /// The probe reads children DESCRIPTOR-RELATIVELY since PR #457 r5, so
        /// recording only the path seam would make "nothing beyond the
        /// boundary was read" vacuously true. Both seams are recorded.
        override func probeKind(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> DescriptorKindProbe {
            probedPaths.append(url.path)
            return super.probeKind(
                inDirectory: parent, named: name, logical: url
            )
        }

        /// Every recorded touch STRICTLY beneath `directory`.
        func touches(below directory: URL) -> [String] {
            let prefix = directory.path + "/"
            return probedPaths.filter { $0.hasPrefix(prefix) }
        }
    }

    /// Mirrors the PRODUCTION `isMountPoint` contract instead of injecting by
    /// inode: `statfs` compares `f_mntonname` — ALWAYS canonical — against the
    /// path it is HANDED, so a real mount answers `true` only for its
    /// CANONICAL spelling. The inode-keyed seam above answers correctly for
    /// ANY spelling, which is exactly why it cannot see a caller that passes
    /// an alias — and why every existing mount test stayed green across this
    /// defect. Devices are deliberately left untouched, so both sides of the
    /// boundary share one `st_dev` and the device arm is genuinely silent
    /// too: the firmlink shape the `statfs` arm exists to catch.
    private final class CanonicalSpellingMountProvider:
        FileSystemIdentityProvider
    {
        /// CANONICAL mount-root paths, spelled exactly as `f_mntonname`
        /// would. Compared with `==` and never normalized here — normalizing
        /// on this side would reintroduce the spelling-blindness the inode
        /// seam has.
        var canonicalMountPaths: Set<String> = []
        private(set) var probedPaths: [String] = []

        override func isMountPoint(_ url: URL) -> Bool {
            if canonicalMountPaths.contains(url.path) { return true }
            return super.isMountPoint(url)
        }

        override func probeKind(of url: URL) -> KindProbe {
            probedPaths.append(url.path)
            return super.probeKind(of: url)
        }

        /// Both seams — see `BoundaryTouchRecordingProvider`.
        override func probeKind(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> DescriptorKindProbe {
            probedPaths.append(url.path)
            return super.probeKind(
                inDirectory: parent, named: name, logical: url
            )
        }

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

    /// Counts how many times a tree was SIZED, spelling-independently.
    ///
    /// `linkCount(of:)` has exactly ONE caller in the whole codebase —
    /// `DirectorySizer.recordRegularFile`, once per measured regular file —
    /// so the count over a payload file IS the number of measurement walks
    /// that reached it. (The earlier proxy counted `canonicalize` of the
    /// artifact path, which stopped being one-per-measure when the sizing
    /// mode became `.deletionTarget` and the LEAF stopped being resolved;
    /// this seam is mode-independent and unaffected by the `/var` →
    /// `/private/var` fixture aliasing, since it matches on a suffix.)
    private final class CanonicalizeCountingProvider: FileSystemIdentityProvider {
        private(set) var canonicalizeCounts: [String: Int] = [:]
        private(set) var measuredFilePaths: [String] = []

        override func canonicalize(_ url: URL) -> URL {
            canonicalizeCounts[url.path, default: 0] += 1
            return super.canonicalize(url)
        }

        override func linkCount(of url: URL) -> UInt64? {
            measuredFilePaths.append(url.path)
            return super.linkCount(of: url)
        }

        /// How many measurement walks reached a file at `suffix`.
        func measurements(of suffix: String) -> Int {
            measuredFilePaths.filter { $0.hasSuffix(suffix) }.count
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
            provider.measurements(of: "/inner/proj/target/payload.bin"), 1,
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
        XCTAssertEqual(try XCTUnwrapElement(BuildArtifactRules.v1, 0).risk, .safe,
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
            makeScanner(valuablesProbeBudget: .fixed(3))
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
        XCTAssertEqual(disclosure.incompleteness, .entryBudget,
                       "the bundle's subtree ran past the pinned bound")
        XCTAssertTrue(
            found.evidence.contains("more entries than the inspection budget"),
            found.evidence
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

        XCTAssertEqual(found.risk, try XCTUnwrapElement(BuildArtifactRules.v1, 0).risk)
        XCTAssertEqual(found.defaultSelected,
                       try XCTUnwrapElement(BuildArtifactRules.v1, 0).defaultSelected)
        XCTAssertEqual(found.automaticCleanEligible,
                       try XCTUnwrapElement(BuildArtifactRules.v1, 0).automaticCleanEligible)
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
            makeScanner(roots: [dev], valuablesProbeBudget: .fixed(1))
        )
        let cappedItem = try XCTUnwrap(item(cappedOutcome, at: capped))
        let cappedDisclosure = try XCTUnwrap(cappedItem.valuablesDisclosure)
        XCTAssertFalse(cappedDisclosure.probeComplete)
        XCTAssertEqual(cappedItem.risk, .review, "fail-closed forcing")
        XCTAssertFalse(cappedItem.defaultSelected)
        XCTAssertEqual(
            cappedDisclosure.incompleteness, .entryBudget,
            "a pinned bound that ran out is the BUDGET cause, and it is "
                + "reported as itself — the two causes clear differently"
        )
        XCTAssertEqual(
            cappedItem.evidence,
            "target/ beside Cargo.toml; last build today — WARNING: couldn't "
                + "finish inspecting this directory for release artifacts — "
                + "it holds more entries than the inspection budget — "
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
        XCTAssertEqual(
            disclosure.incompleteness, .obstruction,
            "an unreadable branch is an OBSTRUCTION, never a budget: no "
                + "bigger budget can read it, so it must not advertise one"
        )
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
            makeScanner(valuablesProbeBudget: .fixed(4))
        )
        XCTAssertTrue(
            try XCTUnwrap(item(atCap, at: target)?.valuablesDisclosure)
                .probeComplete,
            "a budget that exactly covers the tree finishes it"
        )

        let underCap = try await runScan(
            makeScanner(valuablesProbeBudget: .fixed(3))
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
            makeScanner(valuablesProbeBudget: .fixed(3))
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

    // MARK: - The entry budget is PROPORTIONATE, not a constant (review r7)

    /// A chain of `depth` directories, each component 20 bytes wide, with
    /// `leafFiles` files at the bottom — built ENTIRELY fd-relatively
    /// (`mkdirat`/`openat`), because past `PATH_MAX` no path-based API can
    /// create, stat, enumerate or delete it. Returns the number of directory
    /// ENTRIES the chain adds (`depth` directories + `leafFiles` files), which
    /// is what a descriptor-anchored walk must visit.
    ///
    /// At depth 120 under a temp root the deepest logical path measures ~2.6 KB
    /// against a `PATH_MAX` of 1024 — the shape a real Rust/`node_modules`
    /// tree reaches by nesting, and the one where a PATH-based walk stops and
    /// a descriptor-anchored one does not.
    ///
    /// A construction failure THROWS (and so fails the test); it never skips —
    /// a fixture that silently did not get built would make every claim below
    /// it vacuously true.
    @discardableResult
    private func makeOverlongChain(
        under root: URL, depth: Int, leafFiles: Int
    ) throws -> Int {
        struct FixtureError: Error { let detail: String }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            throw FixtureError(detail: "open(\(root.path)): \(errno)")
        }
        defer { close(fd) }
        for index in 0..<depth {
            let name = String(format: "d%019d", index)
            XCTAssertEqual(name.utf8.count, 20, "fixture component width")
            guard mkdirat(fd, name, 0o755) == 0 || errno == EEXIST else {
                throw FixtureError(detail: "mkdirat(\(name)): \(errno)")
            }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY)
            guard child >= 0 else {
                throw FixtureError(detail: "openat(\(name)): \(errno)")
            }
            close(fd)
            fd = child
        }
        for index in 0..<leafFiles {
            let file = openat(fd, "f\(index).bin", O_CREAT | O_WRONLY, 0o644)
            guard file >= 0 else {
                throw FixtureError(detail: "openat(create f\(index)): \(errno)")
            }
            var byte: UInt8 = 0x7
            _ = withUnsafeBytes(of: &byte) { write(file, $0.baseAddress, 1) }
            close(file)
        }
        return depth + leafFiles
    }

    /// Remove a fixture whose paths run past `PATH_MAX` — `FileManager` and
    /// `removefile(3)` both refuse it (measured: Cocoa 514, "the file name is
    /// invalid"), and the teardown that runs after every test uses
    /// `FileManager`. `rm -rf` chdir's its way down and succeeds.
    private func removeOverlongTree(at url: URL) {
        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/bin/rm")
        rm.arguments = ["-rf", url.path]
        try? rm.run()
        rm.waitUntilExit()
    }

    /// An artifact tree of at least `entries` directory entries under one
    /// project, returning the artifact dir. Flat and cheap on purpose: what
    /// matters is the COUNT the census sees, not the shape.
    @discardableResult
    private func makeWideProject(at dir: URL, entries: Int) throws -> URL {
        let artifact = try makeProject(
            at: dir, marker: "Cargo.toml", artifact: "target",
            payloadBytes: nil
        )
        for index in 0..<entries {
            try writeFile(
                artifact.appendingPathComponent("deps/pkg\(index).js"),
                bytes: 64
            )
        }
        return artifact
    }

    /// THE STRANDING DEFECT, in the bound that outlived the depth cap. A FIXED
    /// entry budget is deterministic, so an artifact tree bigger than it
    /// probed incomplete on EVERY scan and EVERY delete-time revalidation: the
    /// GUI filtered the row out of the confirmation clean set, the CLI could
    /// never obtain the token the identical bounded revalidation demands, and
    /// re-scanning an unchanged tree exhausted in exactly the same place —
    /// permanently unauthorizable, for the ordinary large `node_modules` and
    /// `.build` trees this scanner exists to reclaim (measured on this
    /// machine: 44,468 and 53,924 entries against a 20,000-entry cap).
    ///
    /// The budget is now derived from the subject's OWN exhaustive census, so
    /// a tree this pass can enumerate at all is a tree the probe can prove.
    /// The floor is pinned small here so the fixture is a handful of files
    /// rather than a hundred thousand; nothing else about the policy differs.
    func testTreeLargerThanTheBudgetFloorIsProvenAndActuallyDeletes()
        async throws
    {
        let artifact = try makeWideProject(
            at: dev.appendingPathComponent("proj"), entries: 40
        )

        let (items, snapshot, runtime) = try await scanSession(
            makeScanner(valuablesProbeBudget: .censusProportionate(floor: 3))
        )
        let found = try XCTUnwrap(item(from: items, at: artifact))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)

        XCTAssertEqual(
            disclosure, .clean,
            "a tree far past the FLOOR is still PROVEN clean — the budget is "
                + "the subject's own census, not a constant"
        )
        XCTAssertEqual(found.risk, .safe, "the gate never fired")
        XCTAssertNil(CacheoutViewModel.blockedReason(for: found),
                     "…so the GUI never filters it out of the clean set")

        // THE CLAIM THAT MATTERS: it actually deletes. The delete-time face
        // has no census in hand and must earn one, at the SAME policy, or the
        // two faces drift and this item is refused forever.
        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [found], moveToTrash: false)
        XCTAssertTrue(report.errors.isEmpty,
                      report.errors.map(\.message).joined(separator: "; "))
        XCTAssertFalse(fm.fileExists(atPath: artifact.path))
    }

    /// The delete-time face on its own, at the same policy: it starts at the
    /// floor, finds the budget (and ONLY the budget) is what stopped it,
    /// censuses the same subject, and finishes — disclosing exactly what the
    /// scan-time face disclosed, which is what makes the acknowledgement token
    /// reproducible instead of stranding a valuable-bearing tree.
    func testDeleteTimeFaceEscalatesToTheSameCensusAndAgreesWithScanTime()
        async throws
    {
        let artifact = try makeWideProject(
            at: dev.appendingPathComponent("proj"), entries: 40
        )
        let dmg = try writeBulkFile(
            artifact.appendingPathComponent("bundle/dmg/Murmur.dmg"),
            bytes: aboveFloorBytes
        )
        let budget = ValuablesProbeBudget.censusProportionate(floor: 3)

        let outcome = try await runScan(
            makeScanner(valuablesProbeBudget: budget)
        )
        let found = try XCTUnwrap(item(outcome, at: artifact))
        let scanned = try XCTUnwrap(found.valuablesDisclosure)
        XCTAssertTrue(scanned.probeComplete)
        XCTAssertEqual(scanned.valuables.map(\.name), ["Murmur.dmg"])
        let token = try XCTUnwrap(
            scanned.acknowledgementToken(for: found.key),
            "a COMPLETE probe over a non-empty set has a token"
        )

        // Unescalated, the delete-time first pass cannot finish …
        let atFloor = ValuablesDetector.probe(
            at: artifact, provider: FileSystemIdentityProvider(), entryLimit: 3
        )
        XCTAssertEqual(atFloor.incompleteness, .entryBudget,
                       "fixture precondition: the floor is genuinely too small")

        // … and the face escalates past it to the identical answer.
        let atDelete = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: FileSystemIdentityProvider(), budget: budget
        )
        XCTAssertEqual(scanned, atDelete,
                       "scan time and delete time see the SAME thing")
        XCTAssertEqual(
            ValuablesDisclosure.acknowledgementToken(
                scannerID: found.scannerID, itemID: found.id,
                valuables: atDelete.valuables, probeComplete: true
            ),
            token,
            "the delete-time token reproduces the acknowledged one"
        )
        XCTAssertTrue(fm.fileExists(atPath: dmg.path))
    }

    /// The escalation is NARROW: it buys a bigger budget and nothing else. An
    /// unreadable branch is an OBSTRUCTION — no budget can read it — so the
    /// probe stays incomplete and tokenless, and the printed remedy stays the
    /// one that can actually work.
    func testCensusEscalationNeverRescuesAnObstruction() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let artifact = try makeWideProject(
            at: dev.appendingPathComponent("proj"), entries: 40
        )
        let locked = artifact.appendingPathComponent("locked-branch")
        try mkdir(locked)
        try chmod000(locked)

        let outcome = try await runScan(
            makeScanner(valuablesProbeBudget: .censusProportionate(floor: 3))
        )
        let found = try XCTUnwrap(item(outcome, at: artifact))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)

        XCTAssertFalse(disclosure.probeComplete)
        XCTAssertEqual(disclosure.incompleteness, .obstruction,
                       "an obstruction is reported as itself even when the "
                        + "budget was also spent — the causes clear "
                        + "differently and must not be flattened")
        XCTAssertNil(disclosure.acknowledgementToken(for: found.key))
        XCTAssertEqual(found.risk, .review)
        XCTAssertTrue(found.evidence.contains("couldn't fully inspect"),
                      found.evidence)
        XCTAssertFalse(
            found.evidence.contains("more entries than the inspection budget"),
            "the printed remedy must be the one that can work: "
                + found.evidence
        )
    }

    /// BOTH causes at once, deterministically — and the walk reports the one
    /// a bigger budget cannot clear.
    ///
    /// The bound is pinned at exactly the artifact dir's two entries, so its
    /// own read finishes whole (no truncation, no unspecified membership) and
    /// the budget is spent to the last entry. Descending the byte-wise first
    /// child hits EACCES (an OBSTRUCTION); descending the second finds the
    /// budget gone (ENTRY BUDGET). Reporting the budget here would send the
    /// delete-time face into a second pass that must fail identically, and
    /// would print "retry" for a directory whose real remedy is `chmod`.
    func testObstructionOutRanksTheBudgetWhenBothStopTheSameWalk() async throws
    {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let artifact = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let locked = artifact.appendingPathComponent("a-locked")
        try mkdir(locked)
        try chmod000(locked)
        try writeFile(
            artifact.appendingPathComponent("b-sub/chunk.js"), bytes: 64
        )

        let outcome = try await runScan(
            makeScanner(valuablesProbeBudget: .fixed(2))
        )
        let found = try XCTUnwrap(item(outcome, at: artifact))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)

        XCTAssertFalse(disclosure.probeComplete)
        XCTAssertEqual(
            disclosure.incompleteness, .obstruction,
            "both causes fired; the reported one must be the cause no bigger "
                + "budget can clear"
        )
        XCTAssertTrue(found.evidence.contains("couldn't fully inspect"),
                      found.evidence)
        XCTAssertEqual(
            BuildArtifactsScanner.incompleteProbeRefusal(
                disclosure.incompleteness
            ).contains("re-scan required"),
            true,
            "…and the delete-time remedy is the obstruction's, not a retry"
        )
    }

    /// The policy arithmetic itself: the floor is a floor, the census raises
    /// it, a pinned bound is honored verbatim and never escalates, and a
    /// filesystem-supplied census can never trap the multiplication.
    func testProbeBudgetPolicyArithmeticIsPinnedAndSaturating() {
        let production = ValuablesProbeBudget.censusProportionate(floor: 100)
        XCTAssertEqual(production.firstPass, 100)
        XCTAssertEqual(production.limit(census: 0), 100, "the floor holds")
        XCTAssertEqual(production.limit(census: 10), 100)
        XCTAssertEqual(production.limit(census: 60), 120,
                       "twice the subject's own exhaustive census")
        XCTAssertNil(production.escalation(census: 10),
                     "no second pass that could not read one entry more")
        XCTAssertEqual(production.escalation(census: 60), 120)
        XCTAssertEqual(production.limit(census: Int.max), Int.max,
                       "a filesystem-supplied census saturates, never traps")

        let pinned = ValuablesProbeBudget.fixed(7)
        XCTAssertEqual(pinned.firstPass, 7)
        XCTAssertEqual(pinned.limit(census: 10_000), 7,
                       "an explicitly pinned bound is honored verbatim")
        XCTAssertNil(pinned.escalation(census: 10_000), "…and never escalates")
    }

    // MARK: - review r8: the census is a HINT, the doubling is the guarantee

    /// THE DEFECT. The census comes from `DirectorySizer`, a PATH-BASED walk;
    /// the probe it budgets is DESCRIPTOR-ANCHORED. They truncate in different
    /// places, so twice the census is not an upper bound on the probe's work —
    /// it is an undercount — and an undercount used as the probe's ONLY bound
    /// made a STATIC tree deterministically INCOMPLETE: tokenless on every
    /// surface, dropped from the GUI clean set, and told (falsely) that it was
    /// "changing faster than it can be inspected — let the build finish".
    /// Nothing was changing, and no retry, chmod, unmount or re-scan could
    /// ever clear it.
    ///
    /// The divergence is measured, not hypothesised: at 120 components of 20
    /// bytes the deepest path is ~2.6 KB against a `PATH_MAX` of 1024, and the
    /// path walk stops there with ENAMETOOLONG having counted 44 of this
    /// fixture's 151 entries while the descriptor walk reads the tree whole
    /// (the exact split shifts with the length of the temp root, which is why
    /// the assertions below are relational).
    ///
    /// The floor is pinned small so the fixture is 150 entries rather than the
    /// 21,000 the same shape needs to reproduce at the production floor;
    /// nothing else about the policy differs.
    func testStaticTreeWhosePathCensusTruncatesIsStillProvenAndNeverBlamed()
        async throws
    {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 4_096
        )
        addTeardownBlock { [weak self] in self?.removeOverlongTree(at: artifact) }
        let chainEntries = try makeOverlongChain(
            under: artifact, depth: 120, leafFiles: 30
        )
        let reachable = chainEntries + 1  // + the top-level payload.bin

        // PRECONDITION 1 — the CENSUS walk truncates, and says so. It cannot
        // even count the chain it is standing in.
        let census = DirectorySizer()
            .measure(at: artifact, mode: .deletionTarget)
        XCTAssertLessThan(
            census.enumeratedEntries, reachable,
            "fixture precondition: the path-based census must UNDERCOUNT the "
                + "tree the probe walks"
        )
        XCTAssertFalse(
            census.denials.isEmpty,
            "fixture precondition: the sizer records the truncation"
        )

        // PRECONDITION 2 — the census-derived bound is genuinely too small for
        // the descriptor-anchored walk, so the OLD single-pass probe was
        // deterministically incomplete.
        let atCensusBound = ValuablesDetector.probe(
            at: artifact, provider: FileSystemIdentityProvider(),
            entryLimit: max(3, ValuablesProbeBudget.slackFactor
                * census.enumeratedEntries)
        )
        XCTAssertEqual(
            atCensusBound.incompleteness, .entryBudget,
            "fixture precondition: twice the truncated census cannot finish "
                + "the walk"
        )

        // THE CLAIM: the STATIC tree is proven anyway, at both faces.
        let budget = ValuablesProbeBudget.censusProportionate(floor: 3)
        let outcome = try await runScan(
            makeScanner(valuablesProbeBudget: budget)
        )
        let found = try XCTUnwrap(item(outcome, at: artifact))
        let disclosure = try XCTUnwrap(found.valuablesDisclosure)
        XCTAssertTrue(
            disclosure.probeComplete,
            "a static tree the probe can read whole must be PROVEN, whatever "
                + "some other walk managed to count"
        )
        XCTAssertNil(disclosure.incompleteness)
        XCTAssertTrue(disclosure.valuables.isEmpty)
        XCTAssertNil(
            CacheoutViewModel.blockedReason(for: found),
            "…so no surface may drop the row, and none may claim this "
                + "unchanging tree is 'changing faster than it can be read'"
        )
        // The SAME complete probe also reports what it saw about the tree's
        // PATH LENGTHS, and that is a separate verdict with a separate remedy
        // (PR #457 review r10): the row is UNDER-MEASURED because the
        // path-based sizer stops there, NOT because anything about the
        // inspection came up short. Pinned here so the r8 claim above can
        // never be read as "and therefore this row is fully measured".
        //
        // It used to pin `.denied` — the retired path-limit refusal. Both
        // disposal arms handle such a tree (measured; see the section below),
        // so the row is offered and the state is the ordinary partial-
        // measurement one.
        XCTAssertGreaterThan(
            try XCTUnwrap(disclosure.overlongDescendantPathBytes),
            ValuablesDetector.removablePathByteLimit,
            "the fixture's 120-deep chain runs past what a PATH can name "
                + "(the exact figure shifts with the temp root's length, so "
                + "this stays relational)"
        )
        XCTAssertEqual(found.state, .partiallyDenied)
        XCTAssertEqual(
            BuildArtifactsScanner.preDeleteValuablesProbe(
                at: artifact, provider: FileSystemIdentityProvider(),
                budget: budget
            ),
            disclosure,
            "and the delete-time face, which starts from the same truncated "
                + "census, agrees instead of refusing for ever"
        )
    }

    // MARK: - an over-`PATH_MAX` tree is OFFERED and DELETES WHOLE
    //
    // PR #457 review r10 REFUSED these trees, because the remover was
    // `FileManager.removeItem` and that primitive half-deletes them. PR #458
    // replaced the permanent remover with `DepthSafeRemoval`, and the gate was
    // retired — but only after BOTH reachable disposals were measured on real
    // over-`PATH_MAX` fixtures, because the invariant the gate defended is
    // "only offer what can be deleted WHOLE", and the GUI's DEFAULT disposal
    // is the Trash, not the permanent remover.
    //
    // The three tests that carry the retirement's evidence:
    // - `testPathBasedRemovalPartiallyDestroysAnOverlongTree` — the RETIRED
    //   primitive still half-deletes (so the gate was right at the time);
    // - `testTheTrashPrimitiveMovesAnOverlongTreeWholeWhereRemoveItemCannot`
    //   — real `FileManager.trashItem`, on the very same tree, moves it WHOLE;
    // - `DepthSafeRemovalTests
    //    .testRemovesATreeDeeperThanAnAbsolutePathCanAddress` — the permanent
    //   arm at depths 446/600/2000/4000.

    /// Total entries under `url`, counted DESCRIPTOR-RELATIVELY (`fdopendir`
    /// + single-component `openat`), because a tree carrying an
    /// over-`PATH_MAX` descendant cannot be enumerated by path at all.
    ///
    /// Deliberately independent of every walk under test — this is the
    /// before/after measurement partial destruction is proven with, and a
    /// number the code reported about itself would prove nothing.
    private func entryCountFDRelative(under url: URL) -> Int {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return -1 }
        return Self.countEntries(openDirectoryFD: fd)
    }

    /// CONSUMES `fd` (via `closedir`).
    private static func countEntries(openDirectoryFD fd: Int32) -> Int {
        guard let handle = fdopendir(fd) else {
            close(fd)
            return 0
        }
        defer { closedir(handle) }
        var total = 0
        while let entry = readdir(handle) {
            var raw = entry.pointee.d_name
            let name = withUnsafeBytes(of: &raw) {
                String(cString: $0.baseAddress!
                    .assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            total += 1
            guard entry.pointee.d_type == DT_DIR else { continue }
            let child = openat(dirfd(handle), name, O_RDONLY | O_DIRECTORY)
            if child >= 0 { total += Self.countEntries(openDirectoryFD: child) }
        }
        return total
    }

    /// A `target/` with `siblings` ordinary sub-directories (one file each)
    /// PLUS one branch whose deepest descendant runs past `PATH_MAX`. Many
    /// siblings on purpose: a path-based recursive removal unlinks whatever
    /// it reaches BEFORE the over-long descendant, so partial destruction is
    /// only observable when there is something to destroy first.
    @discardableResult
    private func makeOverlongArtifact(
        at dir: URL, siblings: Int = 200
    ) throws -> URL {
        let artifact = try makeProject(
            at: dir, marker: "Cargo.toml", artifact: "target",
            payloadBytes: 4_096
        )
        for index in 0..<siblings {
            try writeFile(
                artifact.appendingPathComponent(
                    String(format: "sib%04d/chunk.js", index)
                ),
                bytes: 64
            )
        }
        let branch = artifact.appendingPathComponent("zdeep")
        try mkdir(branch)
        try makeOverlongChain(under: branch, depth: 120, leafFiles: 5)
        return artifact
    }

    /// THE DEFECT THE RETIRED REFUSAL EXISTED FOR, still measured — and still
    /// measured WITHOUT the scanner, so neither the gate's original
    /// justification nor its retirement rests on a number the code under test
    /// reports about itself.
    ///
    /// `FileManager.removeItem` is `removefile(3)`, which composes and
    /// resolves absolute paths as it recurses. Handed a tree with one
    /// over-`PATH_MAX` descendant it unlinks everything it reaches first and
    /// THEN fails with ENAMETOOLONG (surfaced as Cocoa 514, "the file name is
    /// invalid"), leaving the target half-deleted while the caller gets
    /// nothing but an error — no cleanup entry, zero bytes reported freed.
    ///
    /// THIS IS NOW A CONTROL, NOT A JUSTIFICATION. `removeItem` is no longer
    /// the remover for any permanent deletion in this product, so what it
    /// does to such a tree no longer decides whether the tree may be offered.
    /// The test is kept because the retirement's whole argument is a
    /// COMPARISON — this primitive against the two the product actually uses
    /// — and a comparison needs both sides measured on the same fixture. Its
    /// prediction ("if a descriptor-relative removal primitive makes this
    /// whole-tree-or-nothing, the refusal can be lifted") is what happened.
    func testPathBasedRemovalPartiallyDestroysAnOverlongTree() throws {
        let artifact = try makeOverlongArtifact(
            at: dev.appendingPathComponent("proj")
        )
        addTeardownBlock { [weak self] in self?.removeOverlongTree(at: artifact) }

        let before = entryCountFDRelative(under: artifact)
        XCTAssertGreaterThan(before, 400, "fixture precondition")

        var thrown: NSError?
        do { try fm.removeItem(at: artifact) } catch { thrown = error as NSError }

        let after = entryCountFDRelative(under: artifact)
        XCTAssertNotNil(thrown, "the removal cannot complete")
        XCTAssertEqual(thrown?.code, 514,
                       "…with the filesystem's own name-too-long reason")
        XCTAssertTrue(
            fm.fileExists(atPath: artifact.path),
            "the target itself survives — so nothing is 'freed'"
        )
        XCTAssertLessThan(
            after, before,
            "PARTIAL DESTRUCTION: the failed removal still unlinked entries "
                + "(\(before) → \(after)), and the caller was told only that "
                + "it failed"
        )
    }

    /// THE MEASUREMENT THAT RETIRED THE REFUSAL, on the arm that actually
    /// needed it: **the Trash**, which is the GUI's DEFAULT disposal
    /// (`CacheoutViewModel.moveToTrash = true`).
    ///
    /// "The permanent remover changed" retires nothing on its own. The
    /// invariant is ONLY OFFER WHAT CAN BE DELETED WHOLE, and it is quantified
    /// over every disposal an offered row can reach. `FileManager.trashItem`
    /// takes a URL and resolves it INSIDE itself (see `TrashDisposal`), so
    /// whether it can move a tree whose descendants run past `PATH_MAX` is not
    /// derivable from anything this codebase controls — it had to be measured
    /// with the real primitive, and this is that measurement. Had it failed,
    /// retiring the gate would have re-created #457's half-deletion class on
    /// the MORE travelled path.
    ///
    /// It moves the tree WHOLE, and the reason is structural: an on-volume
    /// Trash move is a `rename(2)` of the TOP directory, so the only paths
    /// spelled are the source and destination — both short. Descendant length
    /// cannot reach it. Measured out of band on the real home volume first
    /// (14/14 entries preserved under `~/.Trash`, source gone, 26.3 ms), then
    /// pinned here.
    ///
    /// HERMETIC BY CONSTRUCTION: the fixture lives on a disk image attached
    /// for this test, so the real `trashItem` lands in that volume's
    /// `.Trashes/<uid>` and the developer's own Trash is never touched. The
    /// suite's `TrashSpy` cannot substitute here — a spy proves what the
    /// CLEANER does with the seam, and the question here is what the SEAM
    /// does with the tree.
    func testTheTrashPrimitiveMovesAnOverlongTreeWholeWhereRemoveItemCannot()
        throws
    {
        let image = base.appendingPathComponent("overlong-trash.dmg")
        let mount = base.appendingPathComponent("overlong-trash-volume")
        try mkdir(mount)
        guard Self.runTool("/usr/bin/hdiutil", [
            "create", "-size", "64m", "-fs", "APFS", "-volname",
            "CacheoutOverlongTrash", "-type", "UDIF", "-quiet", image.path,
        ]) == 0 else { throw XCTSkip("hdiutil create unavailable") }
        guard Self.runTool("/usr/bin/hdiutil", [
            "attach", image.path, "-mountpoint", mount.path,
            "-nobrowse", "-noverify", "-quiet",
        ]) == 0 else { throw XCTSkip("hdiutil attach unavailable") }
        addTeardownBlock {
            _ = Self.runTool("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        }

        // TWO IDENTICAL TREES on the same volume: one for each primitive, so
        // the contrast is measured on the same shape rather than argued.
        let forRemove = try makeOverlongArtifact(
            at: mount.appendingPathComponent("remove-proj"), siblings: 8
        )
        let forTrash = try makeOverlongArtifact(
            at: mount.appendingPathComponent("trash-proj"), siblings: 8
        )
        let before = entryCountFDRelative(under: forTrash)
        XCTAssertGreaterThan(before, 120, "fixture precondition")

        // (a) THE RETIRED PRIMITIVE, on this volume: still refuses, still
        // half-deletes. Without this the test could pass on a fixture that
        // was never actually over-long.
        XCTAssertThrowsError(try fm.removeItem(at: forRemove)) { error in
            XCTAssertEqual((error as NSError).code, 514,
                           "fixture is not actually past PATH_MAX")
        }

        // (b) THE DEFAULT DISPOSAL, real Foundation, same shape.
        var landed: NSURL?
        try fm.trashItem(at: forTrash, resultingItemURL: &landed)
        let destination = try XCTUnwrap(landed as URL?,
                                        "the disposal must say where it put it")
        addTeardownBlock { [weak self] in
            self?.removeOverlongTree(at: destination)
        }

        XCTAssertFalse(
            fm.fileExists(atPath: forTrash.path),
            "the tree left its original place — the move really happened"
        )
        XCTAssertEqual(
            entryCountFDRelative(under: destination), before,
            "WHOLE: every entry arrived (\(before) before), so nothing was "
                + "half-destroyed and nothing was left behind"
        )
    }

    /// THE SCAN-TIME FACE, AFTER THE RETIREMENT. The probe walks
    /// descriptor-relatively, so it still KNOWS a descendant's absolute path
    /// is longer than any path-based API can name — but that is no longer a
    /// reason to refuse the row, because neither remover this product uses is
    /// path-based any more (`DepthSafeRemoval`; the Trash arm's top-level
    /// `rename(2)`, measured above).
    ///
    /// What the fact still costs is MEASUREMENT, not deletion: the sizer IS
    /// path-based, so it stops at that descendant and records an
    /// `.unaddressablePath` denial. The row therefore lands in the ordinary
    /// partial-measurement shape — `.partiallyDenied`, offered, never
    /// auto-selected, byte figure a floor — and the evidence says the size is
    /// a floor rather than that the row is refused.
    ///
    /// The clause must still NAME PATH LENGTH, and must NOT say "REFUSED"
    /// (nothing is), "couldn't inspect" (the probe finished), or "changing
    /// faster" (nothing is changing).
    func testOverlongDescendantIsOfferedWithAFloorSizeNotRefused() async throws {
        let artifact = try makeOverlongArtifact(
            at: dev.appendingPathComponent("proj")
        )
        addTeardownBlock { [weak self] in self?.removeOverlongTree(at: artifact) }

        let outcome = try await runScan(makeScanner())
        let found = try XCTUnwrap(item(outcome, at: artifact))

        XCTAssertEqual(
            found.state, .partiallyDenied,
            "the tree deletes whole — only its SIZE is short, which is what "
                + "`.partiallyDenied` means"
        )
        XCTAssertGreaterThan(found.exactBytes, 0,
                             "the measured floor is published, not zeroed")
        XCTAssertGreaterThan(found.itemCount, 0)
        XCTAssertNotEqual(CLIHandler.cleanPlanAction(for: found), "refuse",
                          "…and every surface agrees the row is actionable")

        // The sizer's own denial is what carries the path-length cause into
        // `scanError` now — the scanner no longer writes a refusal there. And
        // that sentence ALREADY promised what the retirement delivered
        // ("deletion is unaffected", PR #458 review r11); while the gate stood
        // it was the one arm of this scanner that contradicted it.
        let message = try XCTUnwrap(found.scanError?.message)
        XCTAssertTrue(message.contains("an absolute path can address"), message)
        XCTAssertTrue(message.contains("size could not be measured"), message)
        XCTAssertTrue(message.contains("deletion is unaffected"), message)
        XCTAssertFalse(message.contains("refused"), message)

        // The evidence is the string the row's tooltip, the confirmation
        // sheet and the CLI all render in full, so it is where the honest
        // caveat has to live.
        XCTAssertTrue(found.evidence.contains("SIZE IS A FLOOR"), found.evidence)
        XCTAssertTrue(found.evidence.contains("-byte path"), found.evidence)
        XCTAssertTrue(found.evidence.contains("\(ValuablesDetector.removablePathByteLimit)"),
                      "the caveat names the real limit: \(found.evidence)")
        XCTAssertTrue(found.evidence.contains("shorten"),
                      "…and what actually clears it: \(found.evidence)")
        XCTAssertFalse(found.evidence.contains("REFUSED"),
                       "nothing is refused any more: " + found.evidence)
        XCTAssertFalse(found.evidence.contains("cannot be deleted"),
                       found.evidence)
        XCTAssertFalse(found.evidence.contains("changing faster"),
                       found.evidence)
        XCTAssertFalse(
            found.evidence.contains("couldn't"),
            "the probe finished — nothing here failed to inspect: "
                + found.evidence
        )
    }

    /// THE DELETE-TIME FACE, driven through the PRODUCTION cleaner, ON BOTH
    /// DISPOSAL ARMS — and the measurement that matters now: the tree goes
    /// WHOLE, and the row that offered it was telling the truth.
    ///
    /// The two arms are exercised on two identical fixtures in one test on
    /// purpose. A version of this that only drove `moveToTrash: false` would
    /// have left the GUI's DEFAULT disposal — the one most deletions take —
    /// unexercised on the very tree shape whose refusal was just retired,
    /// which is exactly the gap the retirement had to close.
    ///
    /// The Trash arm goes through `TrashSpy`, so the developer's own Trash is
    /// never touched; what the REAL primitive does with such a tree is
    /// measured separately, against real Foundation, in
    /// `testTheTrashPrimitiveMovesAnOverlongTreeWholeWhereRemoveItemCannot`.
    func testOverlongTreeIsDeletedWholeByBothDisposalArms() async throws {
        let permanent = try makeOverlongArtifact(
            at: dev.appendingPathComponent("perm-proj"), siblings: 12
        )
        let trashed = try makeOverlongArtifact(
            at: dev.appendingPathComponent("trash-proj"), siblings: 12
        )
        addTeardownBlock { [weak self] in
            self?.removeOverlongTree(at: permanent)
            self?.removeOverlongTree(at: trashed)
        }
        let trashSpy = TrashSpy(destination: base.appendingPathComponent("trash"))
        try mkdir(trashSpy.destination)
        // The moved tree is still over-long where it lands, so the suite's
        // `FileManager`-based teardown cannot clear it either.
        addTeardownBlock { [weak self] in
            self?.removeOverlongTree(at: trashSpy.destination)
        }
        let entriesBefore = entryCountFDRelative(under: trashed)
        XCTAssertGreaterThan(entriesBefore, 120, "fixture precondition")

        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let permanentItem = try XCTUnwrap(item(from: items, at: permanent))
        let trashedItem = try XCTUnwrap(item(from: items, at: trashed))

        // (a) PERMANENT — `DepthSafeRemoval`, which walks by descriptor.
        let permanentReport = await runtime.makeCleaner(snapshot: snapshot)
            .clean(items: [permanentItem], moveToTrash: false)
        XCTAssertTrue(
            permanentReport.errors.isEmpty,
            permanentReport.errors.map(\.message).joined(separator: "; ")
        )
        XCTAssertEqual(permanentReport.entries.map(\.disposal), [.permanent])
        XCTAssertFalse(
            fm.fileExists(atPath: permanent.path),
            "WHOLE: the over-long tree is gone, root included — the outcome "
                + "the retired refusal existed to prevent `removeItem` from "
                + "botching"
        )

        // (b) TRASH — the GUI's default.
        let trashReport = await runtime.makeCleaner(
            snapshot: snapshot,
            trashHandler: { url in try trashSpy.accept(url) }
        ).clean(items: [trashedItem], moveToTrash: true)
        XCTAssertTrue(
            trashReport.errors.isEmpty,
            trashReport.errors.map(\.message).joined(separator: "; ")
        )
        XCTAssertEqual(trashReport.entries.map(\.disposal), [.trash])
        XCTAssertFalse(fm.fileExists(atPath: trashed.path))
        XCTAssertEqual(trashSpy.accepted.map(\.path), [trashed.path],
                       "the seam got the unresolved deletion target")
        let landed = try XCTUnwrap(
            fm.contentsOfDirectory(
                at: trashSpy.destination, includingPropertiesForKeys: nil
            ).first,
            "the tree must be sitting in the trash destination"
        )
        XCTAssertEqual(
            entryCountFDRelative(under: landed), entriesBefore,
            "WHOLE: every entry arrived in the Trash, nothing half-moved"
        )
    }

    /// THE DELETE-TIME FACE ON ITS OWN — the population the scan-time gate
    /// could never see, and therefore the one that proves the delete-time
    /// refusal is really gone rather than merely unreachable from the scan.
    ///
    /// The scan sees an ordinary short tree and offers it. The branch grows
    /// over-long AFTER the scan (a build running while the user reads the
    /// list — the same drift `ContainerSnapshot` cannot bind, since it binds
    /// the dev root's identity and not the artifact dir's contents). The
    /// revalidator re-probes at delete time and meets a length the scan never
    /// saw; it used to refuse, deterministically and for ever, and now it does
    /// not, because the remover behind it handles the tree.
    ///
    /// The same shape covers a stale item from an earlier session and a CLI
    /// clean addressing the directory directly — both arrive here.
    func testATreeThatGrowsOverlongAfterTheScanStillDeletesWhole()
        async throws
    {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 4_096
        )
        for index in 0..<20 {
            try writeFile(
                artifact.appendingPathComponent(
                    String(format: "sib%04d/chunk.js", index)
                ),
                bytes: 64
            )
        }
        addTeardownBlock { [weak self] in self?.removeOverlongTree(at: artifact) }

        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))
        XCTAssertEqual(found.state, .measured,
                       "precondition: the scan offered this row")

        // …and only THEN does the tree grow past what a PATH can address.
        let branch = artifact.appendingPathComponent("zdeep")
        try mkdir(branch)
        try makeOverlongChain(under: branch, depth: 120, leafFiles: 5)

        // The revalidator's own verdict, first: it ALLOWS. The probe still
        // reports the length — it just no longer decides anything.
        let verdict = revalidator.revalidate(item: found, authorization: nil)
        guard case .allow = verdict else {
            return XCTFail(
                "a length the remover handles must not refuse: \(verdict)"
            )
        }

        // …and the production cleaner, driven with the SAME held item,
        // removes the tree WHOLE.
        let report = await runtime.makeCleaner(snapshot: snapshot)
            .clean(items: [found], moveToTrash: false)
        XCTAssertTrue(report.errors.isEmpty,
                      report.errors.map(\.message).joined(separator: "; "))
        XCTAssertFalse(fm.fileExists(atPath: artifact.path),
                       "the whole tree is gone, over-long branch included")
        XCTAssertEqual(report.entries.count, 1)
    }

    /// IT IS CLEARABLE — the property the retired deterministic bounds never
    /// had — and the caveat that replaced it keeps the property. Shorten the
    /// tree and the same directory stops being under-measured: the floor
    /// becomes the real size, the caveat disappears, and the row is an
    /// ordinary fully measured one. Advice whose stated remedy works is not a
    /// strand, whether it announces a refusal or a measurement limit.
    func testShorteningTheTreeTurnsTheFloorSizedRowIntoAFullyMeasuredOne()
        async throws
    {
        let artifact = try makeOverlongArtifact(
            at: dev.appendingPathComponent("proj"), siblings: 12
        )
        addTeardownBlock { [weak self] in self?.removeOverlongTree(at: artifact) }
        let firstPass = try await runScan(makeScanner())
        let before = try XCTUnwrap(item(firstPass, at: artifact))
        XCTAssertEqual(
            before.state, .partiallyDenied,
            "precondition: under-measured while the over-long branch is there"
        )
        XCTAssertTrue(before.evidence.contains("SIZE IS A FLOOR"),
                      before.evidence)

        // The stated remedy, performed: remove the over-long branch.
        removeOverlongTree(at: artifact.appendingPathComponent("zdeep"))

        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))
        XCTAssertEqual(found.state, .measured, "fully measured now")
        XCTAssertNil(found.scanError)
        XCTAssertEqual(found.valuablesDisclosure, .clean)
        XCTAssertFalse(found.evidence.contains("SIZE IS A FLOOR"),
                       found.evidence)
        XCTAssertEqual(CLIHandler.cleanPlanAction(for: found), "clean")

        let report = await runtime.makeCleaner(snapshot: snapshot)
            .clean(items: [found], moveToTrash: false)
        XCTAssertTrue(report.errors.isEmpty,
                      report.errors.map(\.message).joined(separator: "; "))
        XCTAssertFalse(fm.fileExists(atPath: artifact.path),
                       "…and it really deletes")
    }

    /// The LONGEST deepest-descendant path, in bytes, for which
    /// `FileManager.removeItem` actually removes a tree WHOLE on this
    /// machine — found by BINARY SEARCH against the real filesystem, and
    /// deliberately derived from neither `PATH_MAX` nor
    /// `removablePathByteLimit`. The property is monotone (a longer path
    /// never starts working again), so the search is sound.
    ///
    /// This is the independent oracle the constant is checked against. Using
    /// the constant to build the fixture instead would make the assertion
    /// self-referential — a mutated constant would simply move the fixture
    /// with it and the test would stay green (it did, until this replaced it).
    private func measuredRemovalPathLimit() throws -> Int {
        let scratch = FileSystemIdentityProvider()
            .canonicalize(base)
            .appendingPathComponent("limit-probe")
        let treeURL = scratch.appendingPathComponent("t")
        // The shortest length this fixture shape can even express (the
        // scratch prefix plus a one-byte leaf) — known-good by construction.
        var low = treeURL.path.utf8.count + 2
        var high = 4_096    // known-bad on any Darwin
        XCTAssertLessThan(low, high, "scratch prefix must leave room")
        while high - low > 1 {
            let middle = (low + high) / 2
            removeOverlongTree(at: scratch)
            try mkdir(scratch)
            let tree = treeURL
            try mkdir(tree)
            try makeChain(under: tree, deepestPathBytes: middle)
            let removed = (try? fm.removeItem(at: tree)) != nil
            if removed { low = middle } else { high = middle }
        }
        removeOverlongTree(at: scratch)
        return low
    }

    /// THE BOUNDARY, measured against the filesystem itself rather than
    /// assumed from `PATH_MAX` — and now measured for the OPPOSITE claim.
    ///
    /// While the gate existed, this test's job was to place a REFUSAL exactly
    /// on the byte where `removeItem` starts failing. The refusal is retired,
    /// so its job is now to prove that the byte no longer separates anything
    /// destructive:
    /// - the constant still IS the length path-based APIs stop at
    ///   (binary-searched above, independently of the constant), because it is
    ///   the number the row's caveat quotes and the length the SIZER stops at;
    /// - a deepest descendant of exactly that length is offered, fully
    ///   measured, and really deletes;
    /// - ONE BYTE MORE — the length that half-deleted under the retired
    ///   primitive — is still offered, and STILL REALLY DELETES, whole. Only
    ///   its state and byte figure change, to `.partiallyDenied` and a floor,
    ///   because that is where the path-based sizer stops.
    ///
    /// The one-byte-over case is driven through the PRODUCTION cleaner on
    /// purpose: it is the exact fixture the old test asserted `.denied` on, so
    /// the deletion succeeding here is the retirement's boundary evidence.
    ///
    /// The dev root is spelled CANONICALLY here on purpose. The declared
    /// spelling is what the walker, the probe and the removal all compose
    /// from (`DevRootsResolution` preserves it untouched), while the SIZER
    /// walks the canonical parent chain — under `/var/folders/…` → `/private/
    /// var/folders/…` those differ by 8 bytes, and a fixture straddling a
    /// 1-byte edge cannot be built against two spellings at once. Declaring
    /// the canonical spelling makes them the same string, so this test
    /// measures the edge and nothing else.
    func testBothSidesOfTheRetiredPrimitivesLimitAreOfferedAndReallyDelete()
        async throws
    {
        let measured = try measuredRemovalPathLimit()
        XCTAssertEqual(
            ValuablesDetector.removablePathByteLimit, measured,
            "the constant must BE the length this filesystem stops at — it is "
                + "the number the row's size caveat quotes and the length the "
                + "path-based sizer gives up at"
        )

        let canonicalDev = FileSystemIdentityProvider().canonicalize(dev)
        for (overshoot, expected) in [(0, ScanState.measured),
                                      (1, ScanState.partiallyDenied)] {
            let artifact = try makeProject(
                at: canonicalDev.appendingPathComponent("proj\(overshoot)"),
                marker: "Cargo.toml", artifact: "target", payloadBytes: 4_096
            )
            let deepest = measured + overshoot
            try makeChain(under: artifact, deepestPathBytes: deepest)
            addTeardownBlock { [weak self] in
                self?.removeOverlongTree(at: artifact)
            }

            let (items, snapshot, runtime) = try await scanSession(
                makeScanner(roots: [canonicalDev])
            )
            let found = try XCTUnwrap(item(from: items, at: artifact))
            XCTAssertEqual(
                found.state, expected,
                "a deepest descendant of \(deepest) bytes against a measured "
                    + "path limit of \(measured); "
                    + "scanError=\(found.scanError?.message ?? "nil")"
            )
            XCTAssertNotEqual(
                CLIHandler.cleanPlanAction(for: found), "refuse",
                "neither side is refused any more"
            )
            // BOTH sides are offered because BOTH REALLY DELETE — the
            // property the invariant demands, checked against the filesystem
            // rather than against the constant. The `overshoot == 1` pass is
            // the retirement's boundary evidence: this is the exact fixture
            // that used to be `.denied`.
            let report = await runtime.makeCleaner(snapshot: snapshot)
                .clean(items: [found], moveToTrash: false)
            XCTAssertTrue(report.errors.isEmpty,
                          report.errors.map(\.message).joined(separator: "; "))
            XCTAssertFalse(fm.fileExists(atPath: artifact.path))
        }
    }

    /// A chain under `root` whose DEEPEST descendant's absolute path measures
    /// exactly `deepestPathBytes` — built fd-relatively, because the target
    /// length is on both sides of `PATH_MAX`. Verifies the arithmetic against
    /// the composed path so the fixture cannot silently miss its mark.
    ///
    /// Lengths are composed from `root` VERBATIM, because the removal composes
    /// from the declared spelling verbatim too. A caller that needs the length
    /// to hold for the canonical spelling as well must hand in a canonically
    /// spelled root. (`URL.resolvingSymlinksInPath()` is not the tool for
    /// that: it maps `/private/var/…` back to `/var/…`, the wrong direction.)
    private func makeChain(under root: URL, deepestPathBytes: Int) throws {
        struct FixtureError: Error { let detail: String }
        var logical = root
        var fd = open(root.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            throw FixtureError(detail: "open(\(root.path)): \(errno)")
        }
        defer { close(fd) }
        let width = 30
        while deepestPathBytes - logical.path.utf8.count > width + 1 + 1 {
            let name = String(repeating: "c", count: width)
            guard mkdirat(fd, name, 0o755) == 0 || errno == EEXIST else {
                throw FixtureError(detail: "mkdirat: \(errno)")
            }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY)
            guard child >= 0 else {
                throw FixtureError(detail: "openat: \(errno)")
            }
            close(fd)
            fd = child
            logical.appendPathComponent(name)
        }
        let leafWidth = deepestPathBytes - logical.path.utf8.count - 1
        guard leafWidth >= 1, leafWidth <= 200 else {
            throw FixtureError(detail: "leaf width \(leafWidth)")
        }
        let leaf = String(repeating: "z", count: leafWidth)
        let file = openat(fd, leaf, O_CREAT | O_WRONLY, 0o644)
        guard file >= 0 else {
            throw FixtureError(detail: "create leaf: \(errno)")
        }
        var byte: UInt8 = 0x7
        _ = withUnsafeBytes(of: &byte) { write(file, $0.baseAddress, 1) }
        close(file)
        XCTAssertEqual(
            logical.appendingPathComponent(leaf).path.utf8.count,
            deepestPathBytes, "fixture arithmetic"
        )
    }

    /// The same tree at the PRODUCTION policy shape — no pinned floor, no
    /// injected budget — proving the escalation is not a test-only path: the
    /// production default is `.censusProportionate`, and its first pass over
    /// this fixture starts at the FLOOR (20,000), which the 151-entry tree
    /// never reaches. The pinned-floor test above is what exercises the
    /// escalation itself; this one pins that the shipped policy is the one
    /// that owns the doubling.
    func testProductionBudgetPolicyOwnsTheEscalation() {
        let production = ValuablesProbeBudget.censusProportionate(
            floor: ValuablesDetector.defaultProbeEntryLimit
        )
        XCTAssertEqual(production.escalated(beyond: 20_000), 40_000,
                       "a pass that exhausted its bound is retried at twice it")
        XCTAssertEqual(
            production.escalated(beyond: Int.max), nil,
            "a bound with nowhere left to grow stops, it never wraps"
        )
        XCTAssertEqual(production.escalated(beyond: 0), 2,
                       "…and a zero bound still escalates instead of doubling "
                        + "zero for ever")
        XCTAssertNil(
            ValuablesProbeBudget.fixed(20_000).escalated(beyond: 20_000),
            "a pinned bound is honored verbatim and NEVER escalates"
        )
    }

    /// The escalation TERMINATES, and what survives it is the one case the
    /// "still changing" guidance is TRUE for. A probe that keeps exhausting
    /// every bound it is granted gets exactly `rounds` doublings and then the
    /// honest `.entryBudget` verdict — never an unbounded loop, and never a
    /// rescued obstruction.
    func testEscalationDoublesUpToItsRoundCeilingThenReportsTheBudget() {
        let starved = ValuablesDisclosure(
            valuables: [], probeComplete: false, incompleteness: .entryBudget
        )
        let obstructed = ValuablesDisclosure(
            valuables: [], probeComplete: false, incompleteness: .obstruction
        )
        let budget = ValuablesProbeBudget.censusProportionate(floor: 10)

        var bounds: [Int] = []
        let exhausted = budget.escalating(starved, spent: 10, rounds: 3) {
            bounds.append($0)
            return starved
        }
        XCTAssertEqual(bounds, [20, 40, 80],
                       "doubling, and exactly the rounds it was granted")
        XCTAssertEqual(exhausted.incompleteness, .entryBudget,
                       "what outlives every doubling is reported as itself")

        bounds = []
        let finished = budget.escalating(starved, spent: 10, rounds: 3) {
            bounds.append($0)
            return .clean
        }
        XCTAssertEqual(bounds, [20], "…and it stops the moment one finishes")
        XCTAssertEqual(finished, ValuablesDisclosure.clean)

        bounds = []
        XCTAssertEqual(
            budget.escalating(obstructed, spent: 10, rounds: 3, {
                bounds.append($0)
                return .clean
            }),
            obstructed,
            "an OBSTRUCTION is never escalated: no bound reads an unreadable "
                + "branch, and pretending otherwise prints the wrong remedy"
        )
        XCTAssertTrue(bounds.isEmpty)

        bounds = []
        _ = ValuablesProbeBudget.fixed(10)
            .escalating(starved, spent: 10, rounds: 3) {
                bounds.append($0)
                return .clean
            }
        XCTAssertTrue(bounds.isEmpty,
                      "a pinned bound never escalates, whatever stopped it")

        // The shipped ceiling: 16 doublings from the 20,000 floor is
        // 1,310,720,000 entries — unreachable for a static tree, so reaching
        // it means what the guidance says it means.
        XCTAssertEqual(ValuablesProbeBudget.escalationRounds, 16)
    }

    /// THE CENSUS SOURCE, evidenced. `SizeReport.enumeratedEntries` counts
    /// EVERY directory entry the sizing walk yielded; `itemCount` counts
    /// REGULAR FILES only — no directories, symlinks, specials, or entries
    /// that raced away. Swapping one for the other at either face leaves every
    /// outcome identical (the doubling rescues it) and every existing test
    /// green, which is exactly why the near-neighbour survived undetected: the
    /// difference is WORK, so work is what this measures.
    ///
    /// The fixture is directory-heavy on purpose — 60 subdirectories and one
    /// file — so `enumeratedEntries` (61) and `itemCount` (1) are two orders
    /// of magnitude apart and the file-only count is below the pinned floor.
    func testCensusIsEveryEnumeratedEntryNotOnlyTheRegularFiles() async throws {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        for index in 0..<60 {
            try mkdir(artifact.appendingPathComponent("obj\(index)"))
        }
        try writeFile(artifact.appendingPathComponent("app.o"), bytes: 64)

        // Independent fixture math, never the code under test.
        let census = DirectorySizer()
            .measure(at: artifact, mode: .deletionTarget)
        XCTAssertEqual(census.enumeratedEntries, 61,
                       "fixture precondition: 60 directories + 1 file")
        XCTAssertEqual(census.itemCount, 1,
                       "fixture precondition: the regular-file count is the "
                        + "near-neighbour that undercounts by 60x")

        probePasses = []
        ValuablesDetector.testHook = { [weak self] event in
            guard case .didReadNames(let logical) = event,
                  logical.path == artifact.path else { return }
            self?.probePasses.append(logical.path)
        }
        defer { ValuablesDetector.testHook = nil }

        let budget = ValuablesProbeBudget.censusProportionate(floor: 3)
        let outcome = try await runScan(
            makeScanner(valuablesProbeBudget: budget)
        )
        let found = try XCTUnwrap(item(outcome, at: artifact))
        XCTAssertEqual(found.valuablesDisclosure, .clean)
        XCTAssertEqual(
            probePasses.count, 1,
            "the scan-time census is the subject's EXHAUSTIVE entry count, so "
                + "ONE pass proves the tree; a regular-file count would start "
                + "below the floor and pay six re-walks to reach the same "
                + "answer"
        )

        probePasses = []
        XCTAssertEqual(
            BuildArtifactsScanner.preDeleteValuablesProbe(
                at: artifact, provider: FileSystemIdentityProvider(),
                budget: budget
            ),
            .clean
        )
        XCTAssertEqual(
            probePasses.count, 2,
            "delete time: the floor pass, then ONE census-proportionate pass "
                + "— the census it earns must be the count that finishes it"
        )
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

    // MARK: R15/R17 — the mount check gets a CANONICAL path (PR #457 r4)

    /// `base/aliaslink` → `base/real`, and the declared dev root
    /// `base/aliaslink/dev`: the `/var` → `/private/var` shape, where the
    /// LEAF is a real directory reached through a SYMLINKED ANCESTOR. Every
    /// path the walker then builds carries the alias, because the resolution
    /// pipeline keeps the DECLARED spelling verbatim.
    private func makeAliasDeclaredDevRoot() throws -> URL {
        let real = base.appendingPathComponent("real")
        try mkdir(real)
        let aliasParent = base.appendingPathComponent("aliaslink")
        try fm.createSymbolicLink(at: aliasParent, withDestinationURL: real)
        return aliasParent.appendingPathComponent("dev")
    }

    /// The canonical spelling of `url`, computed with a stock provider — the
    /// test's own independent math, never the code under test.
    private func canonicalPath(of url: URL) -> String {
        FileSystemIdentityProvider().canonicalize(url).path
    }

    func testNestedMountUnderAnAliasedSpellingIsStillNotCrossed()
        async throws
    {
        // BOTH boundary signals silent at once. Arm (a) — device vs the walk
        // root — cannot fire on a firmlink-shaped mount that shares the
        // root's `st_dev` (that is the case arm (b) exists for). Arm (b) then
        // answered `false` too, because the walk hands `isMountPoint` its
        // deliberately UNRESOLVED spelling and `statfs` compares against the
        // always-canonical `f_mntonname`. Two checks with a CORRELATED blind
        // spot, not two independent ones — so the probe enumerated the
        // mounted tree and called the result COMPLETE.
        let aliasRoot = try makeAliasDeclaredDevRoot()
        let artifact = try makeProject(
            at: aliasRoot.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        try writeBulkFile(
            artifact.appendingPathComponent("InTree.dmg"),
            bytes: aboveFloorBytes
        )
        let mounted = artifact.appendingPathComponent("mounted-volume")
        let beyond = try writeBulkFile(
            mounted.appendingPathComponent("Beyond.dmg"), bytes: aboveFloorBytes
        )

        let provider = CanonicalSpellingMountProvider()
        provider.canonicalMountPaths = [canonicalPath(of: mounted)]
        XCTAssertFalse(
            provider.canonicalMountPaths.contains(mounted.path),
            "the fixture must really be aliased, or the test proves nothing"
        )

        // THE DELETE-TIME FACE — the one with no backstop at all: it is
        // handed a bare frozen target and has no size report to consult.
        let atDelete = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: provider
        )
        XCTAssertEqual(
            provider.touches(below: mounted), [],
            "not one entry of the mounted volume is lstat'd"
        )
        XCTAssertFalse(atDelete.probeComplete,
                       "an uncrossed boundary is UNPROVEN, never 'clean'")
        XCTAssertEqual(atDelete.valuables.map(\.name), ["InTree.dmg"],
                       "the rest of the tree is still walked whole")
        XCTAssertTrue(fm.fileExists(atPath: beyond.path))

        // …and the scan-time face reaches the SAME verdict, from the SAME
        // aliased spelling the walker built.
        let scanProvider = CanonicalSpellingMountProvider()
        scanProvider.canonicalMountPaths = [canonicalPath(of: mounted)]
        let outcome = try await runScan(
            makeScanner(roots: [aliasRoot], provider: scanProvider)
        )
        let found = try XCTUnwrap(
            item(outcome, at: artifact, provider: scanProvider)
        )
        XCTAssertEqual(found.valuablesDisclosure, atDelete,
                       "scan time and delete time agree — no drift")
        XCTAssertEqual(scanProvider.touches(below: mounted), [])
    }

    func testArtifactDirThatIsItselfAMountIsRefusedUnderAnAliasedSpelling()
        async throws
    {
        // The ROOT arm, same correlated blind spot: the artifact dir IS the
        // mount, so arm (a)'s device-vs-PARENT comparison is silent on a
        // firmlink-shaped mount, and arm (b) never matched the alias. Against
        // the unfixed source the probe opened a foreign volume and disclosed
        // a valuable from it, reporting COMPLETE — a "proven" verdict derived
        // entirely from a filesystem the user never pointed this scanner at.
        let aliasRoot = try makeAliasDeclaredDevRoot()
        let artifact = try makeProject(
            at: aliasRoot.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        try writeBulkFile(
            artifact.appendingPathComponent("Shipped.dmg"),
            bytes: aboveFloorBytes
        )

        let provider = CanonicalSpellingMountProvider()
        provider.canonicalMountPaths = [canonicalPath(of: artifact)]
        XCTAssertFalse(provider.canonicalMountPaths.contains(artifact.path))

        let atDelete = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: provider
        )
        XCTAssertEqual(atDelete, .incomplete,
                       "nothing is disclosed from a volume we refused to read")
        XCTAssertEqual(
            provider.touches(below: artifact), [],
            "the probe returns before opening the directory at all"
        )
    }

    func testCanonicalizationReachesTheMountCheckAndNothingElse()
        async throws
    {
        // THE SEPARATION, asserted rather than trusted. The canonical
        // spelling is an ARGUMENT and nothing more: canonicalizing the
        // traversal instead would break the `resolveTargetKeepingLeaf`
        // doctrine and aim the walk at paths the deletion does not touch —
        // a worse bug than the one being fixed. Aliased tree, NO mount
        // anywhere, so the probe runs whole and every lstat it makes is
        // visible.
        let aliasRoot = try makeAliasDeclaredDevRoot()
        let artifact = try makeProject(
            at: aliasRoot.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let dmg = try writeBulkFile(
            artifact.appendingPathComponent("nested/Shipped.dmg"),
            bytes: aboveFloorBytes
        )
        try makeBundle(
            at: artifact.appendingPathComponent("Shipped.app"),
            contentBytes: aboveFloorBytes
        )

        let provider = CanonicalSpellingMountProvider()
        let disclosure = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: provider
        )

        XCTAssertTrue(disclosure.probeComplete,
                      "no boundary anywhere: the probe is not made incomplete "
                        + "by the canonicalization it now performs")
        XCTAssertEqual(disclosure.valuables.map(\.name),
                       ["Shipped.app", "Shipped.dmg"])

        let canonicalPrefix = canonicalPath(of: artifact) + "/"
        XCTAssertFalse(
            provider.probedPaths.contains { $0.hasPrefix(canonicalPrefix) },
            "no lstat ever lands on the CANONICAL spelling — the walk keeps "
                + "the aliased one it was given: "
                + "\(provider.probedPaths.filter { $0.hasPrefix(canonicalPrefix) })"
        )
        XCTAssertTrue(
            provider.probedPaths.allSatisfy {
                $0 == artifact.path || $0.hasPrefix(artifact.path + "/")
            },
            "every probed path is the aliased spelling or beneath it"
        )
        XCTAssertEqual(
            disclosure.valuables.first { $0.name == "Shipped.dmg" }?
                .displayURL.path,
            dmg.path,
            "the discovered spelling reaches the item UNRESOLVED, as always"
        )
    }

    // MARK: R15 — the DESCRIPTOR mount arm, on a REAL firmlink (T14)

    /// Blinds BOTH path mount arms and records every DESCRIPTOR-relative
    /// probe the walk makes.
    ///
    /// Blinding is not a convenience. `isMountPoint` compares `f_mntonname` —
    /// always canonical — against the path it is HANDED, so it is `false` for
    /// any aliased spelling; the device arm is blind by construction across an
    /// APFS volume group, where every path shares one `st_dev`; and both are
    /// answers about a PATH, the thing an ancestor swap makes untrustworthy.
    /// With them silent, one guard is left — the child descriptor's own
    /// `f_fsid`/`st_dev` — and this is the only test that puts weight on it.
    private final class PathMountArmsBlindProvider: FileSystemIdentityProvider {
        private(set) var descriptorProbes: [String] = []

        override func isMountPoint(_ url: URL) -> Bool { false }

        override func probeKind(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> DescriptorKindProbe {
            descriptorProbes.append(url.path)
            return super.probeKind(
                inDirectory: parent, named: name, logical: url
            )
        }
    }

    /// T14, the platform fact the descriptor arm exists for — measured, not
    /// assumed. `/` and `/System/Volumes/Data` are SEPARATE mounted volumes
    /// that report the SAME `st_dev` and differ only in `f_fsid`. Every
    /// `st_dev`-based mount test in this codebase is blind to that pair.
    func testFirmlinkedVolumesShareOneDeviceAndSeparateOnlyByFsid() throws {
        let data = "/System/Volumes/Data"
        try XCTSkipUnless(
            fm.fileExists(atPath: data),
            "no /System/Volumes/Data firmlink on this machine"
        )
        let provider = FileSystemIdentityProvider()
        let rootFD = provider.openDirectoryNoFollow(at: URL(fileURLWithPath: "/"))
        let dataFD = provider.openDirectoryNoFollow(at: URL(fileURLWithPath: data))
        defer { close(rootFD); close(dataFD) }

        let rootMount = try XCTUnwrap(provider.mountIdentity(ofDescriptor: rootFD))
        let dataMount = try XCTUnwrap(provider.mountIdentity(ofDescriptor: dataFD))

        XCTAssertEqual(
            rootMount.device, dataMount.device,
            "two distinct volumes, ONE st_dev — this is why a device "
                + "comparison cannot carry the mount check"
        )
        XCTAssertNotEqual(
            [rootMount.fsidMajor, rootMount.fsidMinor],
            [dataMount.fsidMajor, dataMount.fsidMinor],
            "f_fsid is the only discriminator that sees the firmlink split"
        )
    }

    /// The probe against that same real firmlink, with both path arms blind:
    /// nothing under `/System/Volumes/Data` may be read. Crossing it would
    /// spend the entry budget on the whole user data volume — outside any
    /// configured dev root — and put what it found into a disclosure that
    /// feeds an acknowledgement token.
    func testProbeRefusesARealFirmlinkMountOnTheDescriptorArmAlone() throws {
        let systemVolumes = URL(fileURLWithPath: "/System/Volumes")
        let data = systemVolumes.appendingPathComponent("Data")
        try XCTSkipUnless(
            fm.fileExists(atPath: data.path),
            "no /System/Volumes/Data firmlink on this machine"
        )
        let real = FileSystemIdentityProvider()
        XCTAssertEqual(
            real.deviceID(of: data), real.deviceID(of: systemVolumes),
            "the firmlink must share its parent's st_dev, or the device arm "
                + "would be doing this test's work"
        )

        let provider = PathMountArmsBlindProvider()
        // A small budget so a REGRESSION costs a few hundred entries of the
        // data volume rather than twenty thousand.
        _ = ValuablesDetector.probe(
            at: systemVolumes, provider: provider, entryLimit: 200
        )

        XCTAssertTrue(
            provider.descriptorProbes.contains(data.path),
            "precondition: the mount was reached and vetted, so the probe "
                + "really had the chance to descend it"
        )
        let crossed = provider.descriptorProbes
            .filter { $0.hasPrefix(data.path + "/") }
        XCTAssertTrue(
            crossed.isEmpty,
            "the probe crossed a real mount boundary and read the data "
                + "volume: \(crossed.prefix(5))"
        )
    }

    /// …and the THIRD descriptor mount arm, the one the post-walk containment
    /// descent added: a volume mounted over any component BETWEEN the dev root
    /// and the artifact dir since the walk. Driven against the same real
    /// firmlink, with both path arms blind, by handing the descent a root
    /// anchor for `/System/Volumes` and asking it to re-reach `Data`.
    func testContainmentDescentRefusesAMountThatAppearedOnTheChain() throws {
        let systemVolumes = URL(fileURLWithPath: "/System/Volumes")
        let data = systemVolumes.appendingPathComponent("Data")
        try XCTSkipUnless(
            fm.fileExists(atPath: data.path),
            "no /System/Volumes/Data firmlink on this machine"
        )
        let provider = PathMountArmsBlindProvider()
        let anchor = try XCTUnwrap(SecureDirectory(
            fd: provider.openDirectoryNoFollow(at: systemVolumes),
            provider: provider
        ))
        let candidate = BuildArtifactCandidate(
            artifactDirectory: data, originRoot: systemVolumes,
            rule: try XCTUnwrapElement(BuildArtifactRules.v1, 0), marker: "Cargo.toml"
        )

        switch BuildArtifactsScanner.anchoredArtifactDirectory(
            candidate, rootAnchors: [systemVolumes.path: anchor],
            provider: provider
        ) {
        case .obstructed(let report):
            XCTAssertTrue(report.rootMountBoundary)
            XCTAssertEqual(report.mountBoundaries.map(\.path), [data.path])
        case .anchored:
            XCTFail("the descent crossed a real mount boundary")
        case .vanished:
            XCTFail("the firmlink is there; this is a boundary, not a vanish")
        }
    }

    // MARK: R3/R17 — the OPEN itself is no-follow (PR #457 review r5)

    /// Collapses the swap RACE into a lie, so no timing is involved: it
    /// reports a DIRECTORY for a name that is REALLY a symlink — precisely
    /// the state the walk is in between the stat that vetted a child and the
    /// open that descends it. The window cannot be closed by re-stat'ing
    /// (every check re-opens it); only the open itself can refuse, so the
    /// test drives the REAL `openat` against a REAL symlink and lets the
    /// kernel decide.
    ///
    /// It lies on BOTH seams: the path probe (still used for the walk ROOT's
    /// kind gate) and the descriptor-relative probe (every child below it).
    /// The descriptor lie deliberately keeps the REAL identity and metadata,
    /// so the identity corroborator is satisfied and `O_NOFOLLOW` is the only
    /// thing standing between the walk and the foreign tree.
    private final class SwapSimulatingProvider: FileSystemIdentityProvider {
        /// Paths this provider lies about, reporting them as directories.
        var reportedAsDirectory: Set<String> = []
        private(set) var probedPaths: [String] = []

        override func probeKind(of url: URL) -> KindProbe {
            probedPaths.append(url.path)
            if reportedAsDirectory.contains(url.path) {
                return .kind(.directory)
            }
            return super.probeKind(of: url)
        }

        override func probeKind(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> DescriptorKindProbe {
            probedPaths.append(url.path)
            let real = super.probeKind(
                inDirectory: parent, named: name, logical: url
            )
            guard reportedAsDirectory.contains(url.path),
                  case .kind(_, let identity, let metadata) = real
            else { return real }
            return .kind(.directory, identity: identity, metadata: metadata)
        }

        func touches(atOrBelow directory: URL) -> [String] {
            probedPaths.filter {
                $0 == directory.path || $0.hasPrefix(directory.path + "/")
            }
        }

        func touches(below directory: URL) -> [String] {
            probedPaths.filter { $0.hasPrefix(directory.path + "/") }
        }
    }

    /// Reports a bogus INODE for chosen paths, keeping the REAL device so
    /// the mount arm stays silent: the hermetic stand-in for a directory
    /// replaced by a DIFFERENT directory between the vetting stat and the
    /// open — which `O_NOFOLLOW` alone cannot catch, because it passes every
    /// no-follow check there is. Only comparing the OPENED DESCRIPTOR against
    /// what was vetted catches it.
    private final class WrongIdentityProvider: FileSystemIdentityProvider {
        var bogusInodeFor: Set<String> = []
        private(set) var probedPaths: [String] = []

        override func identity(of url: URL) -> Identity? {
            guard let real = super.identity(of: url) else { return nil }
            guard bogusInodeFor.contains(url.path) else { return real }
            return Identity(device: real.device, inode: real.inode &+ 1)
        }

        override func probeKind(of url: URL) -> KindProbe {
            probedPaths.append(url.path)
            return super.probeKind(of: url)
        }

        override func probeKind(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> DescriptorKindProbe {
            probedPaths.append(url.path)
            let real = super.probeKind(
                inDirectory: parent, named: name, logical: url
            )
            guard bogusInodeFor.contains(url.path),
                  case .kind(let kind, let identity, let metadata) = real
            else { return real }
            return .kind(
                kind,
                identity: Identity(
                    device: identity.device, inode: identity.inode &+ 1
                ),
                metadata: metadata
            )
        }

        func touches(below directory: URL) -> [String] {
            probedPaths.filter { $0.hasPrefix(directory.path + "/") }
        }
    }

    /// A foreign tree OUTSIDE every dev root, stocked with an above-floor
    /// `.dmg` and an above-floor bundle — so a probe that reads it produces
    /// a LOUD, checkable disclosure rather than a silent one.
    @discardableResult
    private func makeForeignTree(named name: String) throws -> URL {
        let outside = base.appendingPathComponent(name)
        try writeBulkFile(
            outside.appendingPathComponent("Foreign.dmg"),
            bytes: aboveFloorBytes
        )
        try makeBundle(
            at: outside.appendingPathComponent("Foreign.app"),
            contentBytes: aboveFloorBytes
        )
        return outside
    }

    func testProbeRefusesAChildSwappedForASymlinkAfterItsKindCheck() throws {
        // The child passed the no-follow kind check; by the time it is
        // POPPED and opened it is a symlink into a tree the deletion never
        // touches. A plain `opendir` follows it and spends the entry budget
        // OUTSIDE the artifact dir — and, here, derives an acknowledgement
        // TOKEN from someone else's files on the path that authorizes
        // deletion.
        let outside = try makeForeignTree(named: "outside-the-dev-root")
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let swapped = artifact.appendingPathComponent("release")
        try fm.createSymbolicLink(at: swapped, withDestinationURL: outside)

        let provider = SwapSimulatingProvider()
        provider.reportedAsDirectory.insert(swapped.path)

        let disclosure = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: provider
        )

        XCTAssertEqual(
            provider.touches(below: swapped), [],
            "the probe followed the swapped link and read outside the "
                + "artifact dir: \(provider.probedPaths)"
        )
        XCTAssertEqual(
            disclosure.valuables.map(\.name), [],
            "valuables from OUTSIDE the tree must never be attributed to "
                + "this item: \(disclosure.valuables.map(\.name))"
        )
        XCTAssertFalse(
            disclosure.probeComplete,
            "a refused open is 'we did not look', never 'we looked and it "
                + "was clean'"
        )
        XCTAssertTrue(disclosure.forcesReview)
        XCTAssertNil(
            disclosure.acknowledgementToken(
                for: ItemKey(scannerID: "build_artifacts", itemID: "x")
            ),
            "an incomplete probe is TOKENLESS on every surface"
        )
    }

    func testProbeRefusesTheROOTSwappedForASymlinkAfterItsKindGate() throws {
        // The root kind gate is an `lstat` and the open that follows is a
        // path open: the gate is on the WRONG SIDE of the window. It stops a
        // root that is ALREADY a symlink; it cannot stop one that BECOMES
        // one.
        let outside = try makeForeignTree(named: "outside-via-the-root")
        let project = dev.appendingPathComponent("rust")
        try mkdir(project)
        try writeFile(project.appendingPathComponent("Cargo.toml"), bytes: 32)
        let artifact = project.appendingPathComponent("target")
        try fm.createSymbolicLink(at: artifact, withDestinationURL: outside)

        let provider = SwapSimulatingProvider()
        provider.reportedAsDirectory.insert(artifact.path)

        let disclosure = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: provider
        )

        XCTAssertEqual(
            provider.touches(below: artifact), [],
            "not one path below a swapped ROOT may be read: "
                + "\(provider.probedPaths)"
        )
        XCTAssertEqual(disclosure.valuables.map(\.name), [])
        XCTAssertFalse(disclosure.probeComplete)
    }

    func testProbeRefusesADirectorySwappedForADifferentDirectory() throws {
        // The belt-and-braces half: what we OPENED must BE what we VETTED.
        // A directory swapped for another DIRECTORY passes `O_NOFOLLOW` and
        // every path check there is — only the descriptor's own identity
        // catches it (and, with it, an ANCESTOR re-pointed under us).
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let sub = artifact.appendingPathComponent("release")
        try writeBulkFile(
            sub.appendingPathComponent("Shipped.dmg"), bytes: aboveFloorBytes
        )

        let provider = WrongIdentityProvider()
        provider.bogusInodeFor.insert(sub.path)

        let disclosure = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: provider
        )

        XCTAssertEqual(
            provider.touches(below: sub), [],
            "nothing inside an unvetted directory may be read: "
                + "\(provider.probedPaths)"
        )
        XCTAssertEqual(disclosure.valuables.map(\.name), [])
        XCTAssertFalse(disclosure.probeComplete)
    }

    func testBundleSizingRefusesASubdirectorySwappedForASymlink() throws {
        // The bundle sizer reuses the same directory-reading primitive, so
        // it inherits the same window: a swapped subdirectory would size the
        // bundle from a FOREIGN subtree — and the size is a token input.
        let outside = try makeForeignTree(named: "outside-via-the-bundle")
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let bundle = try makeBundle(
            at: artifact.appendingPathComponent("Shipped.app"),
            contentBytes: aboveFloorBytes
        )
        let swapped = bundle.appendingPathComponent("Frameworks")
        try fm.createSymbolicLink(at: swapped, withDestinationURL: outside)

        let provider = SwapSimulatingProvider()
        provider.reportedAsDirectory.insert(swapped.path)

        let disclosure = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: provider
        )

        XCTAssertEqual(
            provider.touches(below: swapped), [],
            "the bundle sizing followed the swapped link: "
                + "\(provider.probedPaths)"
        )
        XCTAssertFalse(
            disclosure.probeComplete,
            "a bundle sized past a refused open is a FLOOR, never a truth"
        )
        XCTAssertNil(
            disclosure.acknowledgementToken(
                for: ItemKey(scannerID: "build_artifacts", itemID: "x")
            ),
            "no token may derive from a partial size"
        )
    }

    // MARK: R3/R17 — the ANCESTOR-swap race (PR #457 review, thread
    // PRRT_kwDORmg6_86ZjZf9)

    /// Perform `body` exactly ONCE, synchronously, the first time the probe
    /// reports `event` — the exact instant the race lives in, with the REAL
    /// kernel deciding the outcome. Single-threaded: no sleeps, no threads,
    /// no timing dependence whatsoever.
    private func onFirstProbeEvent(
        matching matches: @escaping (ValuablesDetector.WalkEvent) -> Bool,
        perform body: @escaping () -> Void
    ) {
        ValuablesDetector.testHook = { event in
            guard matches(event) else { return }
            ValuablesDetector.testHook = nil
            body()
        }
    }

    /// Live descriptors of this process, for the fd-balance assertions.
    private func openDescriptorCount() -> Int {
        (try? fm.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// THE HEADLINE REGRESSION. A directory the walk already enumerated is
    /// replaced by a SYMLINK to a foreign tree before the walk descends into
    /// its children.
    ///
    /// This is the case an `O_NOFOLLOW` open plus an `fstat` identity re-proof
    /// CANNOT catch, and the reason the previous fix was insufficient:
    /// `O_NOFOLLOW` guards only the FINAL component, so a re-resolved absolute
    /// path `…/mid/deep` walks through the swapped `mid` untouched — and the
    /// identity the discovery `lstat` recorded as "vetted" was ALREADY the
    /// foreign `deep`'s, so the re-proof compares foreign against foreign and
    /// passes. The probe then enumerates outside the artifact dir, and on THIS
    /// scanner what it reads there feeds the acknowledgement-token preimage:
    /// a foreign read corrupts the value that AUTHORIZES DELETION.
    ///
    /// The correct outcome is counter-intuitive and is asserted here in full:
    /// a held descriptor is INODE-PINNED, so the walk keeps reading the very
    /// objects it vetted, wherever they now live. It is not merely "refused" —
    /// it is COMPLETE over the vetted inodes, and the foreign tree is never
    /// touched at all.
    func testProbeNeverFollowsAnANCESTORSwappedAfterItWasEnumerated() throws {
        let outside = base.appendingPathComponent("outside-the-dev-root")
        let foreign = try writeBulkFile(
            outside.appendingPathComponent("deep/Foreign.dmg"),
            bytes: aboveFloorBytes
        )
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let mid = artifact.appendingPathComponent("mid")
        let inTree = try writeBulkFile(
            mid.appendingPathComponent("deep/InTree.dmg"), bytes: aboveFloorBytes
        )
        let realIdentity = try rawStat(inTree)
        let relocated = artifact.appendingPathComponent("mid-relocated")

        // THE RACE: `mid` is enumerated, and only then is it moved aside and
        // replaced by a symlink pointing out of the tree.
        onFirstProbeEvent(
            matching: {
                if case .didEnumerate(let logical) = $0 {
                    return logical.path == mid.path
                }
                return false
            },
            perform: {
                try? self.fm.moveItem(at: mid, to: relocated)
                try? self.fm.createSymbolicLink(
                    at: mid, withDestinationURL: outside
                )
            }
        )
        defer { ValuablesDetector.testHook = nil }

        let disclosure = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: FileSystemIdentityProvider()
        )

        XCTAssertTrue(
            fm.fileExists(atPath: mid.path),
            "fixture precondition: the swap actually happened"
        )
        XCTAssertEqual(
            try? fm.destinationOfSymbolicLink(atPath: mid.path), outside.path,
            "fixture precondition: `mid` is now a symlink out of the tree"
        )

        // THE CLAIM: not one byte of the foreign tree entered the result.
        XCTAssertFalse(
            disclosure.valuables.contains { $0.name == "Foreign.dmg" },
            "a valuable from OUTSIDE the artifact dir was attributed to it: "
                + "\(disclosure.valuables.map(\.name))"
        )
        XCTAssertEqual(
            disclosure.valuables.map(\.name), ["InTree.dmg"],
            "the walk keeps reading the inodes it vetted, wherever they moved"
        )
        // C8: the identity integers that enter the TOKEN preimage come from
        // the real file, never from the foreign one.
        let disclosed = try XCTUnwrap(disclosure.valuables.first)
        XCTAssertEqual(disclosed.identity.inode, UInt64(realIdentity.st_ino))
        XCTAssertEqual(
            disclosed.identity.allocatedBytes,
            Int64(realIdentity.st_blocks) * 512
        )
        XCTAssertEqual(
            disclosed.identity.modifiedSeconds,
            Int64(realIdentity.st_mtimespec.tv_sec)
        )
        XCTAssertNotEqual(
            disclosed.identity.inode,
            UInt64(try rawStat(foreign).st_ino),
            "the token preimage must never be able to name the foreign file"
        )
        XCTAssertTrue(
            disclosure.probeComplete,
            "inode-pinned descriptors mean this is COMPLETE over the vetted "
                + "objects — not a refusal, and not a strand"
        )
    }

    /// THE EXACT INSTANT the defect lived in, isolated: the swap happens
    /// after the directory's NAMES were read and BEFORE any of them was
    /// vetted.
    ///
    /// This is what makes an ancestor swap different in kind from a leaf
    /// swap, and why the previous fix could not cover it. The pre-fix walk
    /// read the real `mid`'s names here, then vetted each child by ABSOLUTE
    /// PATH — so after the swap BOTH the vetting `lstat` and the `O_NOFOLLOW`
    /// open resolved to the foreign object, the recorded "vetted" identity
    /// was ALREADY the foreign one, and the `fstat` re-proof compared foreign
    /// against foreign and PASSED — verified independently by driving the
    /// raw syscall sequence outside this suite, which enumerates
    /// `Foreign.dmg`, and confirmed against this very test by reverting the
    /// descent to its pre-fix path shape, which makes it disclose
    /// `Foreign.dmg` here too.
    ///
    /// A descriptor-relative walk is immune because the vetting `fstatat` and
    /// the descending `openat` are both relative to the descriptor already
    /// held for `mid` — an inode-pinned handle no swap can redirect.
    func testProbeVetsChildrenAgainstTheHELDParentNotTheReResolvedPath()
        throws
    {
        let outside = base.appendingPathComponent("outside-vetting-window")
        try writeBulkFile(
            outside.appendingPathComponent("deep/Foreign.dmg"),
            bytes: aboveFloorBytes
        )
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let mid = artifact.appendingPathComponent("mid")
        try writeBulkFile(
            mid.appendingPathComponent("deep/InTree.dmg"), bytes: aboveFloorBytes
        )
        let relocated = artifact.appendingPathComponent("mid-relocated")

        onFirstProbeEvent(
            matching: {
                if case .didReadNames(let logical) = $0 {
                    return logical.path == mid.path
                }
                return false
            },
            perform: {
                try? self.fm.moveItem(at: mid, to: relocated)
                try? self.fm.createSymbolicLink(
                    at: mid, withDestinationURL: outside
                )
            }
        )
        defer { ValuablesDetector.testHook = nil }

        let disclosure = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: FileSystemIdentityProvider()
        )

        XCTAssertFalse(
            disclosure.valuables.contains { $0.name == "Foreign.dmg" },
            "the probe read a tree OUTSIDE the artifact dir and attributed "
                + "it to this item — and on this scanner that corrupts the "
                + "acknowledgement-token preimage that AUTHORIZES DELETION: "
                + "\(disclosure.valuables.map(\.name))"
        )
        XCTAssertEqual(disclosure.valuables.map(\.name), ["InTree.dmg"])
        XCTAssertTrue(disclosure.probeComplete)
    }

    /// The half `O_NOFOLLOW` is structurally blind to: the enumerated ancestor
    /// is replaced by a DIFFERENT REAL DIRECTORY. No symlink is involved
    /// anywhere, so every no-follow check in existence passes it. Only
    /// CONTAINMENT in the held parent inode closes it.
    func testProbeNeverFollowsAnANCESTORSwappedForADifferentRealDirectory()
        throws
    {
        let outside = base.appendingPathComponent("outside-real-directory")
        try writeBulkFile(
            outside.appendingPathComponent("deep/Foreign.dmg"),
            bytes: aboveFloorBytes
        )
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let mid = artifact.appendingPathComponent("mid")
        try writeBulkFile(
            mid.appendingPathComponent("deep/InTree.dmg"), bytes: aboveFloorBytes
        )
        let relocated = artifact.appendingPathComponent("mid-relocated")

        onFirstProbeEvent(
            matching: {
                if case .didEnumerate(let logical) = $0 {
                    return logical.path == mid.path
                }
                return false
            },
            perform: {
                try? self.fm.moveItem(at: mid, to: relocated)
                try? self.fm.moveItem(at: outside, to: mid)
            }
        )
        defer { ValuablesDetector.testHook = nil }

        let disclosure = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: FileSystemIdentityProvider()
        )

        XCTAssertFalse(
            disclosure.valuables.contains { $0.name == "Foreign.dmg" },
            "a real-directory swap is invisible to O_NOFOLLOW; containment "
                + "is what refuses it: \(disclosure.valuables.map(\.name))"
        )
        XCTAssertEqual(disclosure.valuables.map(\.name), ["InTree.dmg"])
    }

    /// Constraint 5: the scan-time and delete-time faces run the SAME core,
    /// so they must agree under the race too — no drift.
    func testBothFacesAgreeUnderTheAncestorSwap() async throws {
        let outside = base.appendingPathComponent("outside-both-faces")
        try writeBulkFile(
            outside.appendingPathComponent("deep/Foreign.dmg"),
            bytes: aboveFloorBytes
        )
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let mid = artifact.appendingPathComponent("mid")
        try writeBulkFile(
            mid.appendingPathComponent("deep/InTree.dmg"), bytes: aboveFloorBytes
        )

        func swapOnce(into linkTarget: URL, moving aside: URL) {
            onFirstProbeEvent(
                matching: {
                    if case .didEnumerate(let logical) = $0 {
                        return logical.path == mid.path
                    }
                    return false
                },
                perform: {
                    try? self.fm.moveItem(at: mid, to: aside)
                    try? self.fm.createSymbolicLink(
                        at: mid, withDestinationURL: linkTarget
                    )
                }
            )
        }
        defer { ValuablesDetector.testHook = nil }

        swapOnce(
            into: outside, moving: artifact.appendingPathComponent("aside-1")
        )
        let outcome = try await runScan(makeScanner())
        let scanned = try XCTUnwrap(
            item(outcome, at: artifact)?.valuablesDisclosure
        )

        // Put the tree back the way it was, then race the OTHER face.
        try? fm.removeItem(at: mid)
        try fm.moveItem(
            at: artifact.appendingPathComponent("aside-1"), to: mid
        )
        swapOnce(
            into: outside, moving: artifact.appendingPathComponent("aside-2")
        )
        let atDelete = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: FileSystemIdentityProvider()
        )

        XCTAssertEqual(scanned.valuables.map(\.name), ["InTree.dmg"])
        XCTAssertEqual(atDelete.valuables.map(\.name), ["InTree.dmg"])
        XCTAssertEqual(scanned.probeComplete, atDelete.probeComplete)
    }

    // MARK: R3/R17 — the descriptor bound (constraint 3: no depth cap, ever)

    /// THE CONSTRAINT-3 TEST. A tree far deeper than the descriptor window is
    /// READ, not refused.
    ///
    /// The retired depth cap was retired because a DETERMINISTIC bound makes
    /// its refusals permanently unclearable: every re-scan and every
    /// delete-time re-probe reproduces them, and an incomplete probe is
    /// tokenless forever. A descriptor limit must not resurrect that. It does
    /// not, because exceeding the window is not an event of any kind: the
    /// shallowest anchor below the root is released and restored later with a
    /// single identity-verified `openat(child, "..")`.
    func testATreeManyTimesDeeperThanTheDescriptorWindowStillCompletes()
        throws
    {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let buried = try writeBulkFile(
            artifact.appendingPathComponent("\(deepChain(60))/Deep.dmg"),
            bytes: aboveFloorBytes
        )

        let disclosure = ValuablesDetector.probe(
            at: artifact, provider: FileSystemIdentityProvider(),
            descriptorWindow: 3
        )

        XCTAssertTrue(
            disclosure.probeComplete,
            "a tree 20x deeper than the descriptor window is READ, not "
                + "refused — the depth cap did not come back in disguise"
        )
        XCTAssertEqual(disclosure.valuables.map(\.name), ["Deep.dmg"])
        XCTAssertEqual(
            disclosure.valuables.first?.identity.allocatedBytes,
            allocated(buried)
        )
    }

    /// The window is a PERFORMANCE knob, never a policy: the same tree
    /// produces byte-identical output at a window of 2 and at the production
    /// window, on both a deep CHAIN and a wide COMB.
    func testDescriptorWindowNeverChangesTheResult() throws {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        // A chain …
        try writeBulkFile(
            artifact.appendingPathComponent("\(deepChain(9))/Chain.dmg"),
            bytes: aboveFloorBytes
        )
        // … and a comb: siblings at every level, so anchors are re-acquired
        // over and over rather than released once on the way down.
        for branch in ["a", "b", "c"] {
            try writeBulkFile(
                artifact.appendingPathComponent(
                    "comb/\(branch)/x/y/z/\(branch.uppercased()).pkg"
                ),
                bytes: aboveFloorBytes
            )
        }

        let provider = FileSystemIdentityProvider()
        let tight = ValuablesDetector.probe(
            at: artifact, provider: provider, descriptorWindow: 2
        )
        let roomy = ValuablesDetector.probe(
            at: artifact, provider: provider, descriptorWindow: 64
        )
        let production = ValuablesDetector.probe(at: artifact, provider: provider)

        XCTAssertEqual(tight, roomy)
        XCTAssertEqual(tight, production)
        XCTAssertTrue(tight.probeComplete)
        XCTAssertEqual(
            tight.valuables.map(\.name).sorted(),
            ["A.pkg", "B.pkg", "C.pkg", "Chain.dmg"]
        )
    }

    /// Descriptors are BALANCED on every exit path — success, refusal,
    /// budget exhaustion, mount refusal, root-open failure. This is the
    /// number-one hazard of a descriptor-anchored walk and the reason every
    /// directory is owned by an ARC-managed `SecureDirectory` rather than a
    /// bare `Int32`.
    func testEveryProbeExitPathIsDescriptorBalanced() throws {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        try writeBulkFile(
            artifact.appendingPathComponent("\(deepChain(12))/Deep.dmg"),
            bytes: aboveFloorBytes
        )
        try makeBundle(
            at: artifact.appendingPathComponent("Shipped.app"),
            contentBytes: aboveFloorBytes
        )
        let swapped = artifact.appendingPathComponent("swapped")
        try fm.createSymbolicLink(
            at: swapped, withDestinationURL: base.appendingPathComponent("nope")
        )
        let lying = SwapSimulatingProvider()
        lying.reportedAsDirectory.insert(swapped.path)
        let mounting = MountPointInjectingProvider()
        mounting.mountPointInodes.insert(
            try XCTUnwrap(mounting.identity(of: artifact)?.inode)
        )
        let missing = dev.appendingPathComponent("not-there-at-all")

        let baseline = openDescriptorCount()
        for probe in [
            { _ = ValuablesDetector.probe(
                at: artifact, provider: FileSystemIdentityProvider()
            ) },                                            // success
            { _ = ValuablesDetector.probe(
                at: artifact, provider: FileSystemIdentityProvider(),
                entryLimit: 4
            ) },                                            // budget exhausted
            { _ = ValuablesDetector.probe(
                at: artifact, provider: FileSystemIdentityProvider(),
                descriptorWindow: 2
            ) },                                            // eviction path
            { _ = ValuablesDetector.probe(at: artifact, provider: lying) },
            { _ = ValuablesDetector.probe(at: artifact, provider: mounting) },
            { _ = ValuablesDetector.probe(
                at: missing, provider: FileSystemIdentityProvider()
            ) },                                            // root absent
        ] {
            probe()
        }

        XCTAssertEqual(
            openDescriptorCount(), baseline,
            "a descriptor leaked on some exit path of the probe"
        )
    }

    /// The descriptor bound is ENFORCED, not asserted in prose:
    /// `peak = min(depth + 1, window) + 2`, sampled at the deepest point of a
    /// tree far deeper than the window.
    func testLiveDescriptorPeakStaysInsideTheWindowPlusTransients() throws {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        try writeBulkFile(
            artifact.appendingPathComponent("\(deepChain(40))/Deep.dmg"),
            bytes: aboveFloorBytes
        )

        let window = 6
        let baseline = openDescriptorCount()
        var peak = baseline
        ValuablesDetector.testHook = { _ in
            peak = max(peak, self.openDescriptorCount())
        }
        defer { ValuablesDetector.testHook = nil }

        let disclosure = ValuablesDetector.probe(
            at: artifact, provider: FileSystemIdentityProvider(),
            descriptorWindow: window
        )
        ValuablesDetector.testHook = nil

        XCTAssertTrue(disclosure.probeComplete)
        XCTAssertEqual(disclosure.valuables.map(\.name), ["Deep.dmg"])
        // +1 for the descriptor `/dev/fd` enumeration itself needs.
        XCTAssertLessThanOrEqual(
            peak - baseline, window + 2 + 1,
            "the live-descriptor window is not being enforced: peak was "
                + "\(peak - baseline) above baseline for a window of \(window)"
        )
        XCTAssertEqual(
            openDescriptorCount(), baseline,
            "and everything is handed back at the end"
        )
    }

    // MARK: R3/R17 — the platform facts this design rests on

    /// PLATFORM ERRNO PINNING. If a future macOS changes either of these, THIS
    /// test breaks loudly instead of the taxonomy silently rerouting.
    func testOpenErrnoContractOnThisPlatform() throws {
        let target = dev.appendingPathComponent("real-directory")
        try mkdir(target)
        let link = dev.appendingPathComponent("link-to-directory")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        // A symlink with O_DIRECTORY|O_NOFOLLOW is ENOTDIR, never ELOOP:
        // O_DIRECTORY is checked first. Any branch keyed on ELOOP for a
        // swapped leaf is therefore dead code.
        let fd = open(link.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        let code = errno
        if fd >= 0 { close(fd) }
        XCTAssertLessThan(fd, 0)
        XCTAssertEqual(code, ENOTDIR, "O_DIRECTORY|O_NOFOLLOW on a symlink")

        // Without O_DIRECTORY the same open reports ELOOP — the two flags,
        // not the filesystem, decide which errno a caller sees.
        let bare = open(link.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        let bareCode = errno
        if bare >= 0 { close(bare) }
        XCTAssertLessThan(bare, 0)
        XCTAssertEqual(bareCode, ELOOP, "O_NOFOLLOW alone on a symlink")
    }

    /// A multi-component name defeats `O_NOFOLLOW` entirely — measured, not
    /// assumed — which is why every name reaching a descriptor-relative call
    /// is validated as a single component FIRST.
    func testMultiComponentNamesAreRejectedBeforeAnySyscall() throws {
        XCTAssertFalse(FileSystemIdentityProvider.isSafeComponent("a/b"))
        XCTAssertFalse(FileSystemIdentityProvider.isSafeComponent(".."))
        XCTAssertFalse(FileSystemIdentityProvider.isSafeComponent("."))
        XCTAssertFalse(FileSystemIdentityProvider.isSafeComponent(""))
        XCTAssertTrue(FileSystemIdentityProvider.isSafeComponent("Shipped.app"))

        // The hole the guard closes: through a symlinked INTERMEDIATE
        // component, `openat` with O_NOFOLLOW opens a foreign file.
        let outside = base.appendingPathComponent("outside-multi-component")
        try writeFile(outside.appendingPathComponent("secret.bin"))
        let holder = dev.appendingPathComponent("holder")
        try mkdir(holder)
        try fm.createSymbolicLink(
            at: holder.appendingPathComponent("mid"),
            withDestinationURL: outside
        )
        let holderFD = open(holder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(holderFD, 0)
        defer { close(holderFD) }
        let leaked = openat(holderFD, "mid/secret.bin", O_RDONLY | O_NOFOLLOW)
        if leaked >= 0 { close(leaked) }
        XCTAssertGreaterThanOrEqual(
            leaked, 0,
            "platform fact this guard exists for: O_NOFOLLOW guards only the "
                + "FINAL component, so a multi-component name walks straight "
                + "through a symlinked ancestor"
        )
        // …and the provider refuses to issue that call at all.
        XCTAssertLessThan(
            FileSystemIdentityProvider().openChildDirectory(
                inDirectory: holderFD, named: "mid/secret.bin",
                logical: holder.appendingPathComponent("mid/secret.bin")
            ),
            0
        )
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
        XCTAssertEqual(try XCTUnwrapElement(rows, 0) as NSDictionary, [
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

    // ====================================================================
    // MARK: - PR #457 review r3: the scan-time proof must still hold later
    // ====================================================================

    /// Swaps the filesystem out from under the scanner at a DETERMINISTIC
    /// point: the first `canonicalize` of `trigger`, which the scanner reaches
    /// only in the POST-WALK dedupe pass (the walker canonicalizes roots and
    /// home names, never an interior directory). That is exactly the window
    /// thread B names — after the walker event, before the sizing pass.
    private final class PostWalkSwappingProvider: FileSystemIdentityProvider {
        var trigger = ""
        var swap: (() -> Void)?
        private(set) var swapped = false

        override func canonicalize(_ url: URL) -> URL {
            if !swapped, Self.trimmed(url.path) == Self.trimmed(trigger) {
                swapped = true
                swap?()
            }
            return super.canonicalize(url)
        }

        private static func trimmed(_ path: String) -> String {
            path.count > 1 && path.hasSuffix("/")
                ? String(path.dropLast()) : path
        }
    }

    /// THREAD A. The marker is the safety property: `target/` is an ambiguous
    /// name and only the sibling `Cargo.toml` proves it is build output. If
    /// the marker disappears between the scan and the clean, the item's
    /// PROOF is gone — and the valuables probe cannot see that, because the
    /// repurposed contents are ordinary files no extension rule covers.
    func testMarkerVanishedAfterScanRefusesTheDeletionFailClosed()
        async throws
    {
        let project = dev.appendingPathComponent("proj")
        let artifact = try makeProject(
            at: project, marker: "Cargo.toml", artifact: "target"
        )
        // Repurposed content: nothing the valuables table covers, so the
        // valuables probe reports a clean, COMPLETE inspection.
        let repurposed = try writeFile(
            artifact.appendingPathComponent("tax-returns.txt")
        )

        let (items, snapshot, runtime) = try await scanSession(makeScanner())
        let found = try XCTUnwrap(item(from: items, at: artifact))

        // The marker goes away; `target/` is no longer proven build output.
        try fm.removeItem(at: project.appendingPathComponent("Cargo.toml"))

        switch revalidator.revalidate(item: found, authorization: nil) {
        case .allow:
            XCTFail("the artifact rule no longer matches — deletion must be "
                    + "refused, not allowed on a clean valuables probe")
        case .refuse(let reason, let valuables, let token):
            XCTAssertTrue(reason.contains("Cargo.toml"),
                          "the refusal names the missing marker: \(reason)")
            XCTAssertTrue(valuables.isEmpty)
            XCTAssertNil(token, "there is nothing to acknowledge — the "
                            + "refusal is not about valuables")
        }

        let cleaner = runtime.makeCleaner(snapshot: snapshot)
        let report = await cleaner.clean(items: [found], moveToTrash: false)
        XCTAssertTrue(report.entries.isEmpty, "nothing may be deleted")
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(report.errors.first?.key, found.key)
        XCTAssertTrue(fm.fileExists(atPath: repurposed.path),
                      "the repurposed directory is byte-untouched")
    }

    /// THREAD A, the other rule SHAPE and the other kind of loss: the
    /// interior marker (PEP 405) and a target swapped for a symlink. Both
    /// void the same proof, and the proof is what the revalidator re-runs.
    func testInteriorMarkerLossAndKindChangeBothRefuseAtDeleteTime()
        async throws
    {
        let venv = try makeVenv(at: dev.appendingPathComponent("env"))
        let rust = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        let items = try await scanSession(makeScanner()).items
        let venvItem = try XCTUnwrap(item(from: items, at: venv))
        let rustItem = try XCTUnwrap(item(from: items, at: rust))

        // (a) The INSIDE shape: `pyvenv.cfg` is the whole proof.
        try fm.removeItem(at: venv.appendingPathComponent("pyvenv.cfg"))
        switch revalidator.revalidate(item: venvItem, authorization: nil) {
        case .allow:
            XCTFail("a directory with no pyvenv.cfg inside it is not a venv")
        case .refuse(let reason, _, let token):
            XCTAssertTrue(reason.contains("pyvenv.cfg"), reason)
            XCTAssertNil(token)
        }

        // (b) The KIND change: the matcher never matched a symlink, so the
        // re-proof must not accept one either — deleting it would remove a
        // link the user made, and the tree it names was never inspected.
        let outside = base.appendingPathComponent("outside")
        try mkdir(outside)
        try fm.removeItem(at: rust)
        try fm.createSymbolicLink(at: rust, withDestinationURL: outside)
        switch revalidator.revalidate(item: rustItem, authorization: nil) {
        case .allow:
            XCTFail("the artifact dir is a symlink now — refuse")
        case .refuse(let reason, _, let token):
            XCTAssertTrue(reason.contains("symlink"), reason)
            XCTAssertNil(token)
        }
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
    }

    /// THREAD A's other half — the re-proof must not be STRICTER than the
    /// scan, or it invents refusals nothing can clear. The predicate is the
    /// rule SHAPE's whole declared marker set, never the single marker the
    /// evidence happened to name: a Gradle project that migrated
    /// `build.gradle` → `settings.gradle.kts` between scan and clean is still
    /// matched by the same row, exactly as a re-scan would match it.
    func testRuleReproofUsesTheShapesMarkerSetNotTheNamedMarker()
        async throws
    {
        let project = dev.appendingPathComponent("gradle-app")
        let artifact = try makeProject(
            at: project, marker: "build.gradle", artifact: "build"
        )
        let items = try await scanSession(makeScanner()).items
        let found = try XCTUnwrap(item(from: items, at: artifact))
        XCTAssertTrue(found.evidence.contains("build.gradle"),
                      "fixture precondition: the evidence named THAT marker")

        try fm.removeItem(at: project.appendingPathComponent("build.gradle"))
        try writeFile(
            project.appendingPathComponent("settings.gradle.kts"), bytes: 32
        )

        XCTAssertEqual(
            revalidator.revalidate(item: found, authorization: nil),
            .allow(inspected: .unestablished),
            "another declared marker of the SAME row still proves the rule — "
                + "scan time and delete time must agree"
        )
    }

    /// The proof is STRUCTURAL: it rides every emitted item, and an item that
    /// lost it is refused rather than deleted on an unproven rule.
    func testProofRidesEveryItemAndItsAbsenceFailsClosed() async throws {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target"
        )
        try makeVenv(at: dev.appendingPathComponent("env"))
        let outcome = try await runScan(makeScanner())

        XCTAssertEqual(outcome.items.count, 2)
        for emitted in outcome.items {
            let proof = try XCTUnwrap(
                emitted.artifactProof,
                "every build-artifact item carries the rule that matched it"
            )
            XCTAssertFalse(proof.marker.isEmpty)
        }
        let found = try XCTUnwrap(item(outcome, at: artifact))
        XCTAssertEqual(
            found.artifactProof,
            BuildArtifactProof(
                shape: .markerSibling(
                    artifactDirName: "target", markers: ["Cargo.toml"]
                ),
                marker: "Cargo.toml"
            ),
            "the MATCHED row's shape, carried verbatim"
        )

        // A mapping regression that dropped it must not delete.
        let stripped = replacing(found, disclosure: found.valuablesDisclosure)
        XCTAssertNil(stripped.artifactProof, "fixture precondition")
        switch revalidator.revalidate(item: stripped, authorization: nil) {
        case .allow:
            XCTFail("an item with no recorded rule cannot be re-proven")
        case .refuse(let reason, _, let token):
            XCTAssertTrue(
                reason.contains("no record of the build-artifact rule"), reason
            )
            XCTAssertNil(token)
        }
    }

    /// THREAD B, the core half. The probe's ONE bounded core must gate its
    /// own root with a no-follow `lstat` — the delete-time face already did,
    /// the scan-time face did not, and only the core is shared.
    func testValuablesProbeNeverOpensASymlinkedRoot() throws {
        let outside = base.appendingPathComponent("outside")
        try writeBulkFile(
            outside.appendingPathComponent("Shipped.dmg"),
            bytes: aboveFloorBytes
        )
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        let disclosure = ValuablesDetector.probe(
            at: link, provider: FileSystemIdentityProvider()
        )

        XCTAssertTrue(
            disclosure.valuables.isEmpty,
            "the probe followed a symlink leaf and disclosed a tree the "
                + "deletion would never touch: "
                + disclosure.valuables.map(\.name).joined(separator: ", ")
        )
    }

    /// THREAD B, the scanner half. The candidate is replaced by a symlink
    /// after its walker event and before the post-walk sizing pass; neither
    /// walk may follow the leaf, so no byte and no valuable of the external
    /// tree can reach the item.
    func testCandidateSwappedForASymlinkBeforeSizingIsNeverFollowed()
        async throws
    {
        let outside = base.appendingPathComponent("outside")
        try writeBulkFile(
            outside.appendingPathComponent("Shipped.dmg"),
            bytes: aboveFloorBytes
        )
        try writeFile(outside.appendingPathComponent("bulk.bin"), bytes: 65_536)

        let project = dev.appendingPathComponent("proj")
        let artifact = try makeProject(
            at: project, marker: "Cargo.toml", artifact: "target",
            payloadBytes: 8_192
        )

        let provider = PostWalkSwappingProvider()
        provider.trigger = project.path
        let manager = fm
        provider.swap = {
            try? manager.removeItem(at: artifact)
            try? manager.createSymbolicLink(
                at: artifact, withDestinationURL: outside
            )
        }

        let outcome = try await runScan(makeScanner(provider: provider))
        XCTAssertTrue(provider.swapped,
                      "fixture precondition: the swap ran, post-walk")
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: artifact.path),
            outside.path,
            "fixture precondition: the candidate is a symlink now"
        )

        // The subject the matcher proved is gone, so it produces no candidate
        // — the same answer the walker's matcher gives, and the fail-closed
        // one: nothing is listed, so nothing is offered.
        XCTAssertNil(
            item(outcome, at: artifact),
            "a candidate replaced by a symlink is not the artifact dir the "
                + "rule matched and must not be emitted"
        )
        XCTAssertTrue(outcome.items.isEmpty, itemPaths(outcome).description)
        XCTAssertEqual(
            outcome.items.reduce(Int64(0)) { $0 + $1.allocatedBytes }, 0,
            "not one byte of the external tree may be published"
        )
        XCTAssertTrue(
            outcome.items.allSatisfy {
                ($0.valuablesDisclosure?.valuables ?? []).isEmpty
            },
            "the external tree's release artifacts must never be disclosed"
        )
        XCTAssertTrue(
            fm.fileExists(atPath:
                outside.appendingPathComponent("Shipped.dmg").path),
            "the external tree is untouched"
        )

        // …and the two walks themselves never follow a leaf either, so a swap
        // in the remaining nanoseconds still discloses nothing (belt and
        // braces — the gate above is one `lstat` earlier).
        let sized = DirectorySizer(provider: FileSystemIdentityProvider())
            .measure(at: artifact, mode: .deletionTarget)
        XCTAssertEqual(sized.measuredBytes, 0)
        XCTAssertEqual(sized.itemCount, 0)
        XCTAssertTrue(
            ValuablesDetector.probe(
                at: artifact, provider: FileSystemIdentityProvider()
            ).valuables.isEmpty
        )
    }

    // MARK: - The post-walk pass proves CONTAINMENT (review r6)

    /// Fires a REAL `rename(2)` + `symlink(2)` at the ONE instant the
    /// walker→scanner handoff left open: after the ENTIRE walk has finished
    /// and before the post-walk pass touches the candidate.
    ///
    /// `resolveTargetKeepingLeaf` of the ARTIFACT path is the structural
    /// marker for that instant — the walk never asks it (it canonicalizes
    /// only children it DESCENDS, and a matched artifact dir is pruned), and
    /// the dedupe pass asks it FIRST of every candidate. Firing there is
    /// therefore post-walk by construction, not by timing, and it fires in
    /// the pre-fix shape and the fixed shape alike, so the same test is a
    /// real red against one and a real green against the other.
    private final class PostWalkAncestorSwappingProvider:
        FileSystemIdentityProvider
    {
        var trigger = ""
        var swap: (() -> Void)?
        private(set) var swapped = false

        override func resolveTargetKeepingLeaf(_ url: URL) -> URL {
            if !swapped, url.path == trigger {
                swapped = true
                swap?()
            }
            return super.resolveTargetKeepingLeaf(url)
        }
    }

    /// THE HANDOFF HOLE. The walker held a vetted `SecureDirectory` for
    /// `dev/proj` and emitted an event naming child `target`; the scanner
    /// discarded that descriptor and kept a bare URL, and the post-walk pass
    /// then re-resolved that absolute path four separate times (kind gate,
    /// sizing, valuables probe, and the delete-time re-probe after it). A
    /// concurrent writer INSIDE the user's dev root — a `build.rs`, an npm
    /// postinstall, the very racer this work exists to defeat — does
    /// `mv dev/proj dev/proj.real; ln -s outside dev/proj` in that window and
    /// every one of those calls silently resolves through the new link.
    ///
    /// What that bought before this fix, verified by execution: an item whose
    /// disclosure named `Foreign.dmg`, whose `canonicalIdentityPath` pointed
    /// OUTSIDE the dev root, and — worst — a NON-NIL acknowledgement token,
    /// derived entirely from a tree the artifact dir does not contain. That
    /// token is what AUTHORIZES A DELETION, which is why this handoff, and
    /// not the walk itself, was the last hole that mattered.
    func testAncestorSwappedAfterTheWalkNeverMintsATokenOverAForeignTree()
        async throws
    {
        let outside = base.appendingPathComponent("outside-the-dev-root")
        let decoy = outside.appendingPathComponent("decoy")
        try writeFile(decoy.appendingPathComponent("Cargo.toml"), bytes: 32)
        let foreign = try writeBulkFile(
            decoy.appendingPathComponent("target/Foreign.dmg"),
            bytes: aboveFloorBytes
        )

        let project = dev.appendingPathComponent("proj")
        let artifact = try makeProject(
            at: project, marker: "Cargo.toml", artifact: "target",
            payloadBytes: 8_192
        )
        let relocated = dev.appendingPathComponent("proj.real")

        let provider = PostWalkAncestorSwappingProvider()
        provider.trigger = artifact.path
        let manager = fm
        provider.swap = {
            try? manager.moveItem(at: project, to: relocated)
            try? manager.createSymbolicLink(
                at: project, withDestinationURL: decoy
            )
        }

        let outcome = try await runScan(makeScanner(provider: provider))

        XCTAssertTrue(provider.swapped,
                      "fixture precondition: the swap ran, post-walk")
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: project.path), decoy.path,
            "fixture precondition: the ANCESTOR is a symlink out of the tree"
        )

        // THE CLAIM, strongest first: no token, ever. A token is the value a
        // deletion is authorized against.
        for found in outcome.items {
            XCTAssertNil(
                found.valuablesDisclosure?.acknowledgementToken(for: found.key),
                "a token was minted over a tree reached through a swapped "
                    + "ancestor: \(found.url?.path ?? found.displayName)"
            )
        }
        let disclosed = outcome.items
            .flatMap { $0.valuablesDisclosure?.valuables ?? [] }
        XCTAssertTrue(
            disclosed.isEmpty,
            "release artifacts from OUTSIDE the dev root were attributed to "
                + "an artifact dir inside it: "
                + disclosed.map(\.canonicalIdentityPath).description
        )
        XCTAssertFalse(
            itemPaths(outcome).contains { $0.hasPrefix(outside.path + "/") },
            "an item identity resolved outside the dev root: "
                + itemPaths(outcome).description
        )
        // Containment cannot be re-proven through a symlinked ancestor, so
        // the candidate is simply not offered — the same answer a re-scan
        // gives, and the fail-closed one.
        XCTAssertTrue(outcome.items.isEmpty, itemPaths(outcome).description)
        XCTAssertTrue(fm.fileExists(atPath: foreign.path),
                      "the foreign tree is byte-untouched")
    }

    /// The same swap pointed at a sibling INSIDE the dev root, which is the
    /// half `PathGuard`'s canonicalize-containment cannot answer: the
    /// resolved target is genuinely under a configured container root, so
    /// admission passes. With a marker planted alongside it, the pre-fix pass
    /// emitted a fully-formed, deletable item for a directory the walk never
    /// matched and the user never had offered to them.
    func testAncestorSwappedToASiblingInsideTheDevRootIsRefusedToo()
        async throws
    {
        // Not build output, and NOT matched at walk time — the marker is
        // planted by the swap itself, after the walk has already decided.
        let sibling = dev.appendingPathComponent("other")
        let plantedTarget = sibling.appendingPathComponent("target")
        let personal = try writeFile(
            plantedTarget.appendingPathComponent("tax-returns.txt"), bytes: 4_096
        )

        let project = dev.appendingPathComponent("proj")
        let artifact = try makeProject(
            at: project, marker: "Cargo.toml", artifact: "target",
            payloadBytes: 8_192
        )
        let relocated = dev.appendingPathComponent("proj.real")

        let provider = PostWalkAncestorSwappingProvider()
        provider.trigger = artifact.path
        let manager = fm
        provider.swap = {
            try? manager.moveItem(at: project, to: relocated)
            try? manager.createSymbolicLink(
                at: project, withDestinationURL: sibling
            )
            try? Data(repeating: 0x41, count: 32).write(
                to: sibling.appendingPathComponent("Cargo.toml")
            )
        }

        let outcome = try await runScan(makeScanner(provider: provider))

        XCTAssertTrue(provider.swapped,
                      "fixture precondition: the swap ran, post-walk")
        let plantedIdentity = FileSystemIdentityProvider()
            .resolveTargetKeepingLeaf(plantedTarget).path
        XCTAssertFalse(
            itemPaths(outcome).contains(plantedIdentity),
            "a directory the walk never matched was offered for deletion "
                + "because the pass re-resolved a path instead of re-proving "
                + "containment: \(itemPaths(outcome))"
        )
        XCTAssertTrue(outcome.items.isEmpty, itemPaths(outcome).description)
        XCTAssertTrue(fm.fileExists(atPath: personal.path))
    }

    /// Refuses the child open with EACCES for one name — the containment
    /// re-proof's OBSTRUCTED arm, which must be neither a silent drop nor a
    /// silent trust.
    private final class ChildOpenDenyingProvider: FileSystemIdentityProvider {
        var deniedPaths: Set<String> = []
        var denyErrno: Int32 = EACCES

        override func openChildDirectory(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> Int32 {
            if deniedPaths.contains(url.path) {
                errno = denyErrno
                return -1
            }
            return super.openChildDirectory(
                inDirectory: parent, named: name, logical: url
            )
        }
    }

    /// An impediment that is NOT a replacement may not vanish the item: it
    /// becomes a classified, denied, unmeasured row with an INCOMPLETE (so
    /// tokenless) disclosure — visible, honest, and clearable by fixing the
    /// impediment and re-scanning.
    func testUnprovableContainmentDeniesTheItemInsteadOfDroppingOrTrustingIt()
        async throws
    {
        let project = dev.appendingPathComponent("proj")
        let artifact = try makeProject(
            at: project, marker: "Cargo.toml", artifact: "target",
            payloadBytes: 8_192
        )
        let provider = ChildOpenDenyingProvider()
        provider.deniedPaths = [artifact.path]

        let outcome = try await runScan(makeScanner(provider: provider))

        let found = try XCTUnwrap(
            item(outcome, at: artifact, provider: provider),
            "an unprovable candidate must stay VISIBLE: \(itemPaths(outcome))"
        )
        XCTAssertEqual(found.state, .denied)
        XCTAssertEqual(found.rootRecords.map(\.status), [.deniedUnmeasured])
        XCTAssertEqual(found.scanError?.kind, .permissionDenied,
                       "EACCES is classified, never a silent zero")
        XCTAssertEqual(found.allocatedBytes, 0)
        XCTAssertEqual(found.valuablesDisclosure?.probeComplete, false,
                       "nothing was inspected, so nothing is proven clean")
        XCTAssertNil(found.valuablesDisclosure?.acknowledgementToken(
            for: found.key
        ))
        XCTAssertEqual(found.risk, .review)
        XCTAssertFalse(found.defaultSelected)
    }

    /// Fires a REAL `rename(2)` + `symlink(2)` in the ONE window the ANCHORED
    /// probe entry point exists to cover: AFTER the containment descent has
    /// obtained a live descriptor for the artifact dir, and BEFORE the probe
    /// reads a single entry through it.
    ///
    /// Every other swap fixture in this file fires in phase 2 (from
    /// `resolveTargetKeepingLeaf`), which is strictly EARLIER than
    /// `anchoredArtifactDirectory` — so the descent itself refuses, the probe
    /// is never entered, and the anchored entry point is never exercised under
    /// attack. Overriding the child open and firing on the descent's LAST step
    /// (`super` has already returned the fd) is what lands inside the window
    /// instead of before it. Deterministic by construction: no sleeps, no
    /// threads, no timing.
    private final class PostDescentSwappingProvider: FileSystemIdentityProvider
    {
        var trigger = ""
        var swap: (() -> Void)?
        private(set) var swapped = false

        override func openChildDirectory(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> Int32 {
            let fd = super.openChildDirectory(
                inDirectory: parent, named: name, logical: url
            )
            if fd >= 0, !swapped, url.path == trigger {
                swapped = true
                swap?()
            }
            return fd
        }
    }

    /// THE ANCHORED PROBE ENTRY POINT, under the only attack that reaches it.
    ///
    /// Containment is re-proven and the artifact dir's descriptor is HELD —
    /// and only then does the ancestor become a symlink out of the dev root.
    /// A descriptor is inode-pinned, so a probe entered with that descriptor
    /// reads the real artifact dir and discloses nothing. A probe that
    /// re-opens `candidate.artifactDirectory` BY PATH instead (the
    /// `probe(at:provider:)` face) resolves through the fresh symlink,
    /// discloses `…/outside-the-dev-root/decoy/target/Foreign.dmg`, and mints
    /// an acknowledgement token over it — the value that AUTHORIZES A
    /// DELETION, derived entirely from a tree the artifact dir does not
    /// contain.
    func testAnchoredProbeReadsTheHeldDescriptorNotTheSwappedPath()
        async throws
    {
        let outside = base.appendingPathComponent("outside-the-dev-root")
        let decoy = outside.appendingPathComponent("decoy")
        try writeFile(decoy.appendingPathComponent("Cargo.toml"), bytes: 32)
        let foreign = try writeBulkFile(
            decoy.appendingPathComponent("target/Foreign.dmg"),
            bytes: aboveFloorBytes
        )

        let project = dev.appendingPathComponent("proj")
        let artifact = try makeProject(
            at: project, marker: "Cargo.toml", artifact: "target",
            payloadBytes: 8_192
        )
        let relocated = dev.appendingPathComponent("proj.real")

        let provider = PostDescentSwappingProvider()
        // The descent's LAST step: the artifact dir's own descriptor is open.
        provider.trigger = artifact.path
        let manager = fm
        provider.swap = {
            try? manager.moveItem(at: project, to: relocated)
            try? manager.createSymbolicLink(
                at: project, withDestinationURL: decoy
            )
        }

        let outcome = await makeScanner(provider: provider)
            .scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(
            provider.swapped,
            "fixture precondition: the swap ran, and it ran AFTER the "
                + "containment descent held the artifact dir open"
        )
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: project.path), decoy.path,
            "fixture precondition: the ANCESTOR is a symlink out of the tree"
        )

        let disclosed = outcome.items
            .flatMap { $0.valuablesDisclosure?.valuables ?? [] }
        XCTAssertTrue(
            disclosed.isEmpty,
            "the probe read a tree reached through a swapped ancestor: "
                + disclosed.map(\.canonicalIdentityPath).description
        )
        for found in outcome.items {
            XCTAssertNil(
                found.valuablesDisclosure?.acknowledgementToken(for: found.key),
                "a token was minted over a foreign tree — that value "
                    + "AUTHORIZES A DELETION"
            )
        }
        XCTAssertTrue(fm.fileExists(atPath: foreign.path),
                      "the foreign tree is byte-untouched")
        XCTAssertTrue(
            fm.fileExists(
                atPath: relocated.appendingPathComponent("target/payload.bin")
                    .path
            ),
            "and the real artifact dir — the one the held descriptor names — "
                + "is what was inspected"
        )
    }

    // MARK: - The IDENTITY PATH is anchored too (PR #457 review, P2 #1)

    /// THE LAST PATH BELOW THE ROOT. The walk is descriptor-anchored end to
    /// end — and then the identity DERIVATION re-resolved the valuable's whole
    /// parent chain by absolute path, long after those directories were open
    /// and held. Swap one of them for a symlink in that window and the
    /// disclosure carries metadata from the REAL held inode under a path that
    /// names something else entirely: an external `canonicalIdentityPath`,
    /// straight into the acknowledgement-token preimage that AUTHORIZES A
    /// DELETION.
    ///
    /// The swap fires from the production `didReadNames` hook on the DEEPEST
    /// directory — the instant after its names are read and before the
    /// valuable is recorded — so it is deterministic by construction: a real
    /// `rename(2)` + `symlink(2)`, one thread, no sleeps, no timing.
    func testValuableIdentityPathsSurviveAnAncestorSwappedBelowTheWalkRoot()
        throws
    {
        let outside = base.appendingPathComponent("outside-the-dev-root")
        let decoy = outside.appendingPathComponent("decoy")
        // A DIFFERENT file at the SAME relative spelling, so the path the
        // pre-fix derivation published named a real foreign object.
        let foreign = try writeBulkFile(
            decoy.appendingPathComponent("bundle/dmg/Shipped.dmg"),
            bytes: aboveFloorBytes + 1_000_000
        )

        let artifact = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let release = artifact.appendingPathComponent("release")
        let inspected = try writeBulkFile(
            release.appendingPathComponent("bundle/dmg/Shipped.dmg"),
            bytes: aboveFloorBytes
        )
        let relocated = artifact.appendingPathComponent("release.real")
        // Computed BEFORE the swap: the honest identity path, from the
        // house derivation, never echoed from the code under test.
        let honestPath = identityPath(of: inspected)
        let honestStat = try rawStat(inspected)

        let deepest = release.appendingPathComponent("bundle/dmg")
        let manager = fm
        var swapped = false
        ValuablesDetector.testHook = { event in
            guard !swapped, case .didReadNames(let logical) = event,
                  logical.path == deepest.path else { return }
            swapped = true
            try? manager.moveItem(at: release, to: relocated)
            try? manager.createSymbolicLink(
                at: release, withDestinationURL: decoy
            )
        }
        defer { ValuablesDetector.testHook = nil }

        let disclosure = ValuablesDetector.probe(
            at: artifact, provider: FileSystemIdentityProvider()
        )
        ValuablesDetector.testHook = nil

        XCTAssertTrue(swapped, "fixture precondition: the swap ran")
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: release.path), decoy.path,
            "fixture precondition: an ancestor BELOW the walk root is now a "
                + "symlink out of the tree"
        )

        // The WALK is unaffected — that is the point: it read the held
        // inodes, so the integers describe the real file.
        XCTAssertTrue(disclosure.probeComplete)
        let found = try XCTUnwrap(disclosure.valuables.first)
        XCTAssertEqual(disclosure.valuables.count, 1)
        XCTAssertEqual(found.identity.inode, UInt64(honestStat.st_ino))
        XCTAssertEqual(
            found.identity.allocatedBytes,
            Int64(honestStat.st_blocks) * 512
        )

        // …and the identity path must describe THAT file, not whatever the
        // swapped ancestor now points at.
        XCTAssertEqual(
            found.canonicalIdentityPath, honestPath,
            "the identity path was re-resolved through an ancestor the walk "
                + "had already opened and held"
        )
        let foreignPrefix = FileSystemIdentityProvider()
            .canonicalize(outside).path + "/"
        XCTAssertFalse(
            found.canonicalIdentityPath.hasPrefix(foreignPrefix),
            "a path OUTSIDE the artifact dir was published as the identity "
                + "of a file inside it: \(found.canonicalIdentityPath)"
        )

        // THE VALUE THAT AUTHORIZES A DELETION. Built here from the honest
        // path and raw `lstat` integers — never echoed from the probe.
        let expectedToken = ValuablesDisclosure.acknowledgementToken(
            scannerID: BuildArtifactsScanner.registeredID,
            itemID: "item",
            valuables: [DetectedValuable(
                name: "Shipped.dmg",
                displayURL: inspected,
                canonicalIdentityPath: honestPath,
                identity: ValuableIdentity(
                    allocatedBytes: Int64(honestStat.st_blocks) * 512,
                    device: UInt64(bitPattern: Int64(honestStat.st_dev)),
                    inode: UInt64(honestStat.st_ino),
                    modifiedSeconds: Int64(honestStat.st_mtimespec.tv_sec),
                    modifiedNanoseconds:
                        Int64(honestStat.st_mtimespec.tv_nsec)
                )
            )],
            probeComplete: true
        )
        XCTAssertEqual(
            ValuablesDisclosure.acknowledgementToken(
                scannerID: BuildArtifactsScanner.registeredID,
                itemID: "item",
                valuables: disclosure.valuables,
                probeComplete: disclosure.probeComplete
            ),
            expectedToken,
            "the acknowledgement token incorporated a path from outside the "
                + "inspected tree"
        )
        XCTAssertTrue(fm.fileExists(atPath: foreign.path),
                      "the foreign tree is byte-untouched")
    }

    /// The two faces compose the identity path IDENTICALLY. A token that
    /// differs between scan time and delete time is worse than either.
    func testBothFacesComposeTheSameNestedIdentityPathAndToken() throws {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let nested = try writeBulkFile(
            artifact.appendingPathComponent(
                "release/bundle/dmg/Murmur_0.1.7_aarch64.dmg"
            ),
            bytes: aboveFloorBytes
        )
        let provider = FileSystemIdentityProvider()

        // The DELETE-TIME face: a bare URL, opened by path.
        let atDelete = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: provider
        )
        // The SCAN-TIME face: entered with a root reached by containment.
        let root = try XCTUnwrap(SecureDirectory(
            fd: provider.openDirectoryNoFollow(at: artifact),
            provider: provider
        ))
        let atScan = ValuablesDetector.probe(
            at: artifact, root: root, provider: provider
        )

        XCTAssertEqual(
            atScan.valuables.map(\.canonicalIdentityPath),
            [identityPath(of: nested)]
        )
        XCTAssertEqual(
            atScan.valuables.map(\.canonicalIdentityPath),
            atDelete.valuables.map(\.canonicalIdentityPath)
        )
        XCTAssertEqual(
            atScan.acknowledgementToken(for: ItemKey(
                scannerID: BuildArtifactsScanner.registeredID, itemID: "i"
            )),
            atDelete.acknowledgementToken(for: ItemKey(
                scannerID: BuildArtifactsScanner.registeredID, itemID: "i"
            ))
        )
        XCTAssertNotNil(atScan.acknowledgementToken(for: ItemKey(
            scannerID: BuildArtifactsScanner.registeredID, itemID: "i"
        )))
    }

    // MARK: - The probe WINDS DOWN when cancelled (PR #457 review, P2 #2)

    /// A directory of `count` empty entries, created `openat`-relative to the
    /// directory itself — no per-file absolute path, no `FileManager` round
    /// trip. Returns the number actually created (asserted by the callers).
    @discardableResult
    private func fillDirectory(_ url: URL, count: Int) throws -> Int {
        try mkdir(url)
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw XCTSkip("cannot open \(url.path)") }
        defer { close(fd) }
        var made = 0
        for index in 0..<count {
            let child = openat(
                fd, "entry-\(index).bin", O_CREAT | O_WRONLY | O_CLOEXEC, 0o644
            )
            guard child >= 0 else { break }
            close(child)
            made += 1
        }
        return made
    }

    /// THE READDIR LOOP, measured by the work it actually did.
    ///
    /// `boundedChildNames` reads one directory to its bound, and that bound is
    /// no longer a flat 20,000: it is census-proportionate and escalates to
    /// `20_000 << 16`. A cancelled scan that keeps reading is UI time — the
    /// view model AWAITS the producer's real completion after cancelling — so
    /// the loop must poll. The evidence is the RETURNED NAMES, which are the
    /// entries genuinely read, not a counter the code keeps about itself.
    func testTheDirectoryReadStopsWhenTheTaskIsCancelled() async throws {
        let crowded = dev.appendingPathComponent("crowded")
        let entries = 3_000
        XCTAssertEqual(try fillDirectory(crowded, count: entries), entries)

        let provider = FileSystemIdentityProvider()
        let fd = provider.openDirectoryNoFollow(at: crowded)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        // The uncancelled control: the loop reads the whole directory, and
        // says so.
        let whole = try XCTUnwrap(ValuablesDetector.boundedChildNames(
            parentFD: fd, limit: entries * 2, provider: provider
        ))
        XCTAssertEqual(whole.names.count, entries)
        XCTAssertFalse(whole.obstructed)
        XCTAssertFalse(whole.budgetTruncated)

        // REAL cancellation, through the real `Task` machinery, at a
        // deterministic instant: no sleeps, no threads, no timing.
        let cancelled = await Task { () -> (names: Int, unfinished: Bool)? in
            withUnsafeCurrentTask { $0?.cancel() }
            guard let read = ValuablesDetector.boundedChildNames(
                parentFD: fd, limit: entries * 2, provider: provider
            ) else { return nil }
            return (read.names.count, read.obstructed)
        }.value

        let read = try XCTUnwrap(cancelled)
        XCTAssertTrue(
            read.unfinished,
            "a cancelled read must SAY it did not finish — reported as an "
                + "obstruction, never as the escalatable budget cause"
        )
        XCTAssertLessThan(
            read.names, entries,
            "the readdir loop ran to its bound after cancellation: \(read.names)"
                + " of \(entries) entries were still read"
        )
        XCTAssertEqual(
            read.names, 0,
            "wind-down is checked per entry, so a cancel observed at the top "
                + "of the loop reads nothing at all"
        )
    }

    /// The WHOLE walk winds down, and — the half that matters — a cancelled
    /// probe is never mistaken for a clean one.
    func testCancelledProbeIsIncompleteTokenlessAndNeverReportedClean()
        async throws
    {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        try writeBulkFile(
            artifact.appendingPathComponent("release/Shipped.dmg"),
            bytes: aboveFloorBytes
        )
        try fillDirectory(
            artifact.appendingPathComponent("release/deps"), count: 2_000
        )

        // The control: uncancelled, this tree is COMPLETE, discloses the DMG,
        // and mints a token.
        let counting = VettingCountingProvider()
        let live = ValuablesDetector.probe(at: artifact, provider: counting)
        XCTAssertTrue(live.probeComplete)
        XCTAssertEqual(live.valuables.map(\.name), ["Shipped.dmg"])
        let key = ItemKey(
            scannerID: BuildArtifactsScanner.registeredID, itemID: "i"
        )
        XCTAssertNotNil(live.acknowledgementToken(for: key))
        let liveVets = counting.vettedNames
        XCTAssertGreaterThan(liveVets, 2_000,
                             "fixture precondition: the tree is big enough "
                                + "for the wind-down to be measurable")

        counting.vettedNames = 0
        let cancelled = await Task { () -> ValuablesDisclosure in
            withUnsafeCurrentTask { $0?.cancel() }
            return ValuablesDetector.probe(at: artifact, provider: counting)
        }.value

        // WORK, measured by the test's own count of production `fstatat`
        // calls — never a number the probe reports about itself.
        XCTAssertEqual(
            counting.vettedNames, 0,
            "the walk kept vetting entries after cancellation: "
                + "\(counting.vettedNames) of \(liveVets)"
        )
        // VERDICT. Cancellation is not "we looked and found nothing".
        XCTAssertFalse(cancelled.probeComplete)
        XCTAssertTrue(cancelled.forcesReview)
        XCTAssertNil(cancelled.acknowledgementToken(for: key),
                     "a cancelled inspection can never authorize a deletion")
        // …and NOT the escalatable cause: `escalating` would re-walk a
        // cancelled tree at twice the bound, sixteen times over.
        XCTAssertEqual(cancelled.incompleteness, .obstruction)
        XCTAssertNotEqual(cancelled.incompleteness, .entryBudget)
    }

    /// Counts the production per-entry work — the test's OWN instrumentation,
    /// never the walk's self-report: `fstatat` vets and child opens are the
    /// two syscalls the DFS spends per entry.
    private final class VettingCountingProvider: FileSystemIdentityProvider {
        var vettedNames = 0
        var openedChildren = 0

        override func probeKind(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> DescriptorKindProbe {
            vettedNames += 1
            return super.probeKind(
                inDirectory: parent, named: name, logical: url
            )
        }

        override func openChildDirectory(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> Int32 {
            openedChildren += 1
            return super.openChildDirectory(
                inDirectory: parent, named: name, logical: url
            )
        }
    }

    /// THE VETTING LOOP, which the `readdir` poll cannot help: by the time it
    /// runs, the directory's names are ALREADY read, and it spends one
    /// `fstatat` per name — up to the whole granted budget. Cancellation
    /// arrives from the production `didReadNames` hook, i.e. exactly between
    /// the read and the first vet, so the instant is structural, not timed.
    func testTheVettingLoopWindsDownWhenCancelledMidDirectory() async throws {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let crowded = artifact.appendingPathComponent("deps")
        let entries = 3_000
        XCTAssertEqual(try fillDirectory(crowded, count: entries), entries)

        let counting = VettingCountingProvider()
        let live = ValuablesDetector.probe(at: artifact, provider: counting)
        XCTAssertTrue(live.probeComplete)
        XCTAssertGreaterThan(
            counting.vettedNames, entries,
            "fixture precondition: the uncancelled walk vets every entry"
        )

        var vettedBeforeTheCancel = 0
        var cancelled = false
        ValuablesDetector.testHook = { event in
            guard !cancelled, case .didReadNames(let logical) = event,
                  logical.path == crowded.path else { return }
            cancelled = true
            vettedBeforeTheCancel = counting.vettedNames
            withUnsafeCurrentTask { $0?.cancel() }
        }
        defer { ValuablesDetector.testHook = nil }

        counting.vettedNames = 0
        let disclosure = await Task { () -> ValuablesDisclosure in
            ValuablesDetector.probe(at: artifact, provider: counting)
        }.value
        ValuablesDetector.testHook = nil

        XCTAssertTrue(cancelled, "fixture precondition: the cancel fired "
                        + "after a 3,000-entry directory was read")
        XCTAssertEqual(
            counting.vettedNames - vettedBeforeTheCancel, 0,
            "the vetting loop kept `fstatat`-ing after cancellation: "
                + "\(counting.vettedNames - vettedBeforeTheCancel) of "
                + "\(entries) already-read names"
        )
        XCTAssertFalse(disclosure.probeComplete)
        XCTAssertEqual(disclosure.incompleteness, .obstruction)
    }

    /// THE DFS LOOP. Cancellation lands after a directory is fully vetted and
    /// while its children are being descended one `openat` + `fdopendir` at a
    /// time — the phase where neither the read poll nor the vetting poll runs.
    func testTheDescentLoopWindsDownWhenCancelledBetweenChildren()
        async throws
    {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        let parent = artifact.appendingPathComponent("deps")
        try mkdir(parent)
        let children = 500
        for index in 0..<children {
            try mkdir(parent.appendingPathComponent("pkg-\(index)"))
        }

        let counting = VettingCountingProvider()
        let live = ValuablesDetector.probe(at: artifact, provider: counting)
        XCTAssertTrue(live.probeComplete)
        XCTAssertGreaterThanOrEqual(
            counting.openedChildren, children,
            "fixture precondition: the uncancelled walk descends them all"
        )

        var openedBeforeTheCancel = 0
        var cancelled = false
        ValuablesDetector.testHook = { event in
            // Every child of `deps` is vetted; the descents are next.
            guard !cancelled, case .didEnumerate(let logical) = event,
                  logical.path == parent.path else { return }
            cancelled = true
            openedBeforeTheCancel = counting.openedChildren
            withUnsafeCurrentTask { $0?.cancel() }
        }
        defer { ValuablesDetector.testHook = nil }

        counting.openedChildren = 0
        let disclosure = await Task { () -> ValuablesDisclosure in
            ValuablesDetector.probe(at: artifact, provider: counting)
        }.value
        ValuablesDetector.testHook = nil

        XCTAssertTrue(cancelled, "fixture precondition: the cancel fired "
                        + "with 500 vetted children still to descend")
        XCTAssertEqual(
            counting.openedChildren - openedBeforeTheCancel, 0,
            "the descent loop kept opening children after cancellation: "
                + "\(counting.openedChildren - openedBeforeTheCancel) of "
                + "\(children)"
        )
        XCTAssertFalse(disclosure.probeComplete)
        XCTAssertEqual(disclosure.incompleteness, .obstruction)
    }

    /// The ESCALATION DRIVER must not turn one cancelled walk into sixteen.
    /// Proven on the delete-time face, which is the one that censuses and
    /// re-probes: a cancelled first pass returns the obstruction cause, so no
    /// escalation round and no census enumeration is paid at all.
    func testCancelledPreDeleteProbeNeitherEscalatesNorAuthorizes()
        async throws
    {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: nil
        )
        try writeBulkFile(
            artifact.appendingPathComponent("release/Shipped.dmg"),
            bytes: aboveFloorBytes
        )
        // A bound far below the tree, so an UNCANCELLED probe is exactly the
        // escalating case: it exhausts, censuses, doubles, and finishes.
        let tight = ValuablesProbeBudget.censusProportionate(floor: 1)
        let counting = VettingCountingProvider()

        let live = BuildArtifactsScanner.preDeleteValuablesProbe(
            at: artifact, provider: counting, budget: tight
        )
        XCTAssertTrue(live.probeComplete,
                      "fixture precondition: escalation finishes this tree")
        XCTAssertEqual(live.valuables.map(\.name), ["Shipped.dmg"])
        XCTAssertGreaterThan(
            counting.vettedNames, 2,
            "fixture precondition: the uncancelled path took several passes"
        )

        counting.vettedNames = 0
        let cancelled = await Task { () -> ValuablesDisclosure in
            withUnsafeCurrentTask { $0?.cancel() }
            return BuildArtifactsScanner.preDeleteValuablesProbe(
                at: artifact, provider: counting, budget: tight
            )
        }.value

        XCTAssertEqual(
            counting.vettedNames, 0,
            "a cancelled probe was escalated and re-walked: "
                + "\(counting.vettedNames) entries vetted"
        )
        XCTAssertEqual(cancelled.incompleteness, .obstruction)
        XCTAssertTrue(cancelled.valuables.isEmpty)
    }

    /// THE DELETE-TIME FACE, end to end: cancellation refuses the item and
    /// deletes nothing. Fail-closed, and the correct reading of a cancelled
    /// clean.
    func testCancelledRevalidationRefusesAndDeletesNothing() async throws {
        let artifact = try makeProject(
            at: dev.appendingPathComponent("murmur"),
            marker: "Cargo.toml", artifact: "target"
        )
        let outcome = try await runScan(makeScanner())
        let scanned = try XCTUnwrap(item(outcome, at: artifact))
        let revalidator = BuildArtifactsScanner.preDeleteRevalidator(
            provider: FileSystemIdentityProvider()
        )

        // Uncancelled control: an ordinary build directory is allowed.
        switch revalidator.revalidate(item: scanned, authorization: nil) {
        case .allow: break
        case .refuse(let reason, _, _):
            XCTFail("fixture precondition: expected .allow, got \(reason)")
        }

        let verdict = await Task { () -> PreDeleteVerdict in
            withUnsafeCurrentTask { $0?.cancel() }
            return revalidator.revalidate(item: scanned, authorization: nil)
        }.value

        switch verdict {
        case .allow:
            XCTFail("a cancelled re-inspection authorized a deletion")
        case .refuse(_, let valuables, let token):
            XCTAssertTrue(valuables.isEmpty)
            XCTAssertNil(token, "a cancelled probe hands out no token")
        }
        XCTAssertTrue(
            fm.fileExists(
                atPath: artifact.appendingPathComponent("payload.bin").path
            ),
            "nothing was deleted"
        )
    }

    // MARK: - The containment descent's own refusals, driven directly

    /// One open, vetted anchor per declared root — the shape `scan` hands
    /// `anchoredArtifactDirectory`, built here so the descent's refusals can
    /// be driven without a whole scan.
    private func anchors(
        _ roots: [URL], provider: FileSystemIdentityProvider
    ) throws -> [String: SecureDirectory] {
        var anchors: [String: SecureDirectory] = [:]
        for root in roots {
            anchors[root.path] = try XCTUnwrap(SecureDirectory(
                fd: provider.openDirectoryNoFollow(at: root),
                provider: provider
            ))
        }
        return anchors
    }

    private func candidate(
        artifact: URL, originRoot: URL
    ) throws -> BuildArtifactCandidate {
        BuildArtifactCandidate(
            artifactDirectory: artifact, originRoot: originRoot,
            rule: try XCTUnwrapElement(BuildArtifactRules.v1, 0), marker: "Cargo.toml"
        )
    }

    /// A provider whose child open does NOT re-check the component — the
    /// contract weakened exactly one layer down, which is the only thing that
    /// makes the DESCENT's own `isSafeComponent` observable.
    ///
    /// Deliberately LESS capable than production, never more: it is the
    /// question "does this descent delegate its component safety, or hold it
    /// itself?" and no production behavior is being simulated away — the
    /// production provider's own check is pinned by
    /// `testMultiComponentNamesAreRejectedBeforeAnySyscall`.
    private final class UncheckedChildOpenProvider: FileSystemIdentityProvider
    {
        override func openChildDirectory(
            inDirectory parent: Int32, named name: String, logical url: URL
        ) -> Int32 {
            openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
    }

    /// `..` IS a legal `openat` name, and it climbs. The descent's own
    /// component check is what refuses it before any syscall — not the
    /// provider's, which is a different layer and may be overridden,
    /// re-implemented, or (as here) weakened. Without the caller-side check
    /// the descent walks OUT of the dev root and anchors the directory ABOVE
    /// it, which is then probed and sized as if it were build output.
    func testContainmentDescentHoldsItsOwnComponentSafety() throws {
        let provider = UncheckedChildOpenProvider()
        let root = dev.appendingPathComponent("root")
        try mkdir(root)
        let sibling = try makeProject(
            at: dev.appendingPathComponent("sibling"),
            marker: "Cargo.toml", artifact: "target"
        )
        let held = try anchors([root], provider: provider)
        let above = try XCTUnwrap(provider.identity(of: dev))

        var escaping = root
        escaping.appendPathComponent("..")
        escaping.appendPathComponent("sibling")
        escaping.appendPathComponent("target")
        XCTAssertTrue(escaping.pathComponents.contains(".."),
                      "fixture precondition: the candidate spells a climb")

        switch BuildArtifactsScanner.anchoredArtifactDirectory(
            try candidate(artifact: escaping, originRoot: root),
            rootAnchors: held, provider: provider
        ) {
        case .obstructed(let report):
            XCTAssertTrue(
                report.denials.contains {
                    $0.detail.contains("single safe path component")
                },
                "refused, and classified as what it is: "
                    + report.denials.map(\.detail).description
            )
        case .anchored(let anchor):
            XCTAssertNotEqual(
                anchor.identity, above,
                "the descent climbed OUT of the dev root through '..'"
            )
            XCTFail("a '..' component must never anchor anything")
        case .vanished:
            XCTFail("a '..' component is not a vanished subject")
        }
        XCTAssertTrue(fm.fileExists(atPath: sibling.path))
    }

    /// The component-wise containment check on the SPELLING, driven directly
    /// because no walk produces a candidate that violates it — which is
    /// exactly why it must be proven rather than assumed. Its absence is not
    /// a cosmetic difference: `dropFirst(rootComponents.count)` over a
    /// candidate that does not extend its root yields the WRONG suffix, and
    /// the descent then anchors — and the probe then reads, and the token
    /// then covers — a directory the item does not name.
    func testCandidateNotSpelledInsideItsOriginRootIsRefused() throws {
        let provider = FileSystemIdentityProvider()
        let rootA = dev.appendingPathComponent("a")
        let decoyTarget = try makeProject(
            at: rootA, marker: "Cargo.toml", artifact: "target"
        )
        let rootB = dev.appendingPathComponent("b")
        let claimed = try makeProject(
            at: rootB, marker: "Cargo.toml", artifact: "target"
        )
        let held = try anchors([rootA, dev], provider: provider)
        let decoyIdentity = try XCTUnwrap(provider.identity(of: decoyTarget))
        let devIdentity = try XCTUnwrap(provider.identity(of: dev))

        // (a) A SIBLING spelling: same component COUNT past the root, so the
        // suffix looks plausible and lands on the wrong directory.
        switch BuildArtifactsScanner.anchoredArtifactDirectory(
            try candidate(artifact: claimed, originRoot: rootA),
            rootAnchors: held, provider: provider
        ) {
        case .obstructed(let report):
            XCTAssertTrue(
                report.denials.contains {
                    $0.detail.contains("not spelled inside the")
                },
                report.denials.map(\.detail).description
            )
        case .anchored(let anchor):
            XCTAssertNotEqual(
                anchor.identity, decoyIdentity,
                "the descent anchored a DIFFERENT directory than the "
                    + "candidate names — everything downstream (probe, token, "
                    + "sizing) would describe the wrong tree"
            )
            XCTFail("a candidate outside its origin root must not anchor")
        case .vanished:
            XCTFail("the subject exists; this is not a vanish")
        }

        // (b) SHORTER than the root: the suffix is EMPTY, so an unguarded
        // descent takes no step at all and hands back the ROOT itself.
        switch BuildArtifactsScanner.anchoredArtifactDirectory(
            try candidate(artifact: dev, originRoot: rootA),
            rootAnchors: held, provider: provider
        ) {
        case .obstructed:
            break
        case .anchored(let anchor):
            XCTAssertNotEqual(
                anchor.identity, devIdentity,
                "an empty suffix anchored the dev ROOT as the artifact dir"
            )
            XCTFail("a candidate above its origin root must not anchor")
        case .vanished:
            XCTFail("the subject exists; this is not a vanish")
        }

        // (c) …and a candidate whose root was never anchored is refused too,
        // never assumed.
        switch BuildArtifactsScanner.anchoredArtifactDirectory(
            try candidate(artifact: claimed, originRoot: rootB),
            rootAnchors: held, provider: provider
        ) {
        case .obstructed(let report):
            XCTAssertTrue(
                report.denials.contains {
                    $0.detail.contains("no longer open for this scan")
                },
                report.denials.map(\.detail).description
            )
        case .anchored, .vanished:
            XCTFail("an unanchored origin root is an obstruction")
        }
    }

    /// Retaining root anchors and descending to each candidate adds
    /// descriptors to a pass that had none, so its exit paths get the same
    /// treatment the probe's did: a WHOLE SCAN — success, replacement,
    /// obstruction, several roots, several candidates — must return every
    /// descriptor it took. ARC on `SecureDirectory` is what makes that true on
    /// every arm including the refusals; this is the test that says so.
    func testAWholeScanIsDescriptorBalancedAcrossEveryContainmentArm()
        async throws
    {
        let second = base.appendingPathComponent("dev2")
        try mkdir(second)
        let clean = try makeProject(
            at: dev.appendingPathComponent("rust"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 8_192
        )
        try makeVenv(at: second.appendingPathComponent("env"))
        let doomed = try makeProject(
            at: dev.appendingPathComponent("gone"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 4_096
        )
        let denied = try makeProject(
            at: dev.appendingPathComponent("denied"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 4_096
        )
        let provider = ChildOpenDenyingProvider()
        provider.deniedPaths = [denied.path]

        let baseline = openDescriptorCount()
        for _ in 0..<3 {
            _ = await makeScanner(roots: [dev, second], provider: provider)
                .scan(context: ScanContext(trigger: .userInitiated))
        }
        XCTAssertEqual(
            openDescriptorCount(), baseline,
            "a descriptor leaked on some exit path of the scan"
        )

        // …and again with the replacement arm live (the candidate is a
        // symlink now, so the descent refuses mid-chain).
        try fm.removeItem(at: doomed)
        try fm.createSymbolicLink(at: doomed, withDestinationURL: second)
        let afterSwap = openDescriptorCount()
        for _ in 0..<3 {
            _ = await makeScanner(roots: [dev, second], provider: provider)
                .scan(context: ScanContext(trigger: .userInitiated))
        }
        XCTAssertEqual(openDescriptorCount(), afterSwap,
                       "a descriptor leaked on the refusal arm")
        XCTAssertTrue(fm.fileExists(atPath: clean.path))
    }

    /// THREAD C. Overlapping roots: the outer artifact holds a mount
    /// boundary, and a SEPARATELY configured root inside that volume owns an
    /// artifact of its own. The outer item is denied for the boundary, so the
    /// lexical ancestor drop must not take the inner candidate with it —
    /// neither sizing nor deletion crosses the boundary, so nothing the drop
    /// exists to prevent can happen across it.
    func testDescendantBeyondAMountBoundarySurvivesTheAncestorDrop()
        async throws
    {
        let outer = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 8_192
        )
        let mounted = outer.appendingPathComponent("volume")
        let innerRoot = mounted.appendingPathComponent("code")
        let inner = try makeProject(
            at: innerRoot.appendingPathComponent("proj2"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 16_384
        )

        let provider = MountPointInjectingProvider()
        provider.mountPointInodes.insert(
            try XCTUnwrap(provider.identity(of: mounted)?.inode)
        )

        let outcome = try await runScan(
            makeScanner(roots: [dev, innerRoot], provider: provider)
        )

        let outerItem = try XCTUnwrap(
            item(outcome, at: outer, provider: provider)
        )
        XCTAssertEqual(outerItem.state, .denied,
                       "the boundary voids the outer target")

        let innerItem = try XCTUnwrap(
            item(outcome, at: inner, provider: provider),
            "the inner artifact — under its OWN configured root, inside the "
                + "external volume rather than at the mount point — is "
                + "cleanable and must survive the ancestor drop"
        )
        XCTAssertEqual(innerItem.state, .measured)
        XCTAssertGreaterThan(innerItem.allocatedBytes, 0)
    }

    /// THREAD C, the second reason an ancestor cannot reach its descendant.
    /// The outer matched artifact dir is SEARCHABLE but UNREADABLE (mode
    /// `0111`), so a separately configured root beneath it walks perfectly
    /// well and finds an artifact of its own — while the outer's own sizing
    /// can enumerate nothing and its removal can delete nothing past the
    /// barrier. No mount separates them, so the boundary arm never fires, and
    /// the lexical drop took the CLEANABLE inner candidate with it, leaving
    /// only the undeletable outer row.
    func testDescendantUnderAnUnreadableAncestorSurvivesTheAncestorDrop()
        async throws
    {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")

        let outer = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 8_192
        )
        let innerRoot = outer.appendingPathComponent("nested-root")
        let inner = try makeProject(
            at: innerRoot.appendingPathComponent("proj2"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 16_384
        )
        // Searchable, unreadable: the ancestor's walk stops dead here while
        // the inner root — reached by PATH, which needs only search — does not.
        try chmod111(outer)

        let outcome = try await runScan(
            makeScanner(roots: [dev, innerRoot])
        )

        let outerItem = try XCTUnwrap(
            item(outcome, at: outer),
            "the unreadable outer artifact stays visible and classified"
        )
        XCTAssertEqual(outerItem.state, .denied,
                       "an artifact dir that cannot be read is denied")
        XCTAssertEqual(outerItem.allocatedBytes, 0,
                       "…and therefore counted none of the inner bytes")

        let innerItem = try XCTUnwrap(
            item(outcome, at: inner),
            "the inner artifact — under its OWN configured root, past a "
                + "barrier the outer walk cannot cross — is cleanable and "
                + "must survive the ancestor drop: \(itemPaths(outcome))"
        )
        XCTAssertEqual(innerItem.state, .measured)
        XCTAssertGreaterThan(innerItem.allocatedBytes, 0)
        XCTAssertEqual(innerItem.valuablesDisclosure?.probeComplete, true,
                       "the inner tree is readable and proven clean")
    }

    /// The other half of the same rule: an ancestor that CAN reach its
    /// descendant still drops it. Without this cell, "void the drop whenever
    /// anything looks odd" would pass — the drop's double-count and
    /// nested-deletion job has to survive intact for the ordinary readable
    /// tree, which is the shape every real overlapping-root setup has.
    func testReadableAncestorStillDropsItsDescendantCandidate() async throws {
        let outer = try makeProject(
            at: dev.appendingPathComponent("proj"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 8_192
        )
        let innerRoot = outer.appendingPathComponent("nested-root")
        let inner = try makeProject(
            at: innerRoot.appendingPathComponent("proj2"),
            marker: "Cargo.toml", artifact: "target", payloadBytes: 16_384
        )

        let outcome = try await runScan(makeScanner(roots: [dev, innerRoot]))

        XCTAssertEqual(itemPaths(outcome), [identityPath(of: outer)],
                       "the readable ancestor reaches — and would both count "
                        + "and delete — the descendant, so the drop stands")
        XCTAssertNil(item(outcome, at: inner))
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

    /// RETURNS WHERE THE ITEM LANDED (merge of #457/#458): `TrashHandler`
    /// is `(URL) throws -> URL?`, and `TrashDisposal` proves the object on
    /// the far side of the move from exactly this value. A spy that returned
    /// `Void` would read as "the disposal would not say", which the
    /// disposal treats as UNPROVABLE and refuses.
    @discardableResult
    func accept(_ url: URL) throws -> URL {
        lock.lock()
        received.append(url)
        lock.unlock()
        let landed = destination.appendingPathComponent(
            "\(UUID().uuidString)-\(url.lastPathComponent)"
        )
        try FileManager.default.moveItem(at: url, to: landed)
        return landed
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
