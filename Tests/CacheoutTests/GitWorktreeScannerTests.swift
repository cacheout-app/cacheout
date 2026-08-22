/// # GitWorktreeScannerTests — fn-5.5 (R6 / R7 / R8 / R10)
///
/// The scanner's contracts, in the epic's own terms:
///
/// 1. **Discovery** — hidden parents traversed, `.git` seen but never
///    descended, nested repositories attributed through the bidirectional
///    resolver, submodules attributed nowhere, one porcelain listing per
///    repository however many spellings the walk reaches it through.
/// 2. **Tiers** — stale candidates emitted, assessed NON-candidates OMITTED
///    (D15) yet observable, and ONE repo-level prune item per repository whose
///    disclosure is PROVABLY complete or absent (D14).
/// 3. **Containment (D13)** — the worktree, its parent repository and the
///    resolver-carried admin container inside ONE declared root, with the
///    parent alone allowed to EQUAL it; everything else is a
///    `.containerRefused` issue and never an item.
/// 4. **The two TCC gates** — protected roots and protected SECONDARY paths
///    are skipped SILENTLY on automatic scans and walked when the user asks,
///    while genuine denials stay visible in both.
/// 5. **Validator round-trip** — every outcome survives the 8-family
///    validator non-malformed, which is what makes the three-key id scheme
///    load-bearing rather than decorative.
///
/// Real-git fixtures are hermetic (`GitFixture`, GitCommandRunnerTests.swift):
/// `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` pinned to `/dev/null`, an injected
/// HOME, and a UUID-derived base. The base is deliberately NOT canonicalized:
/// macOS temp paths live under the `/var` → `/private/var` symlink, so every
/// ordinary fixture here also exercises the alias re-spelling that keeps the
/// plan validator's LEXICAL containment checks satisfiable.
///
/// Shapes real git cannot produce (a first record whose git directory's parent
/// is not the working tree; a locked-AND-prunable record; a prunable record no
/// admin entry maps to) are driven through INJECTED runner results over
/// hand-built fixtures — never by asserting a git version or a refusal
/// message.

import XCTest
@testable import Cacheout

// MARK: - Test doubles

/// Records every argv and forwards to a real runner.
private final class RecordingGitRunner: GitCommandRunning, @unchecked Sendable {
    private let wrapped: any GitCommandRunning
    private let lock = NSLock()
    private var recorded: [[String]] = []

    init(wrapping wrapped: any GitCommandRunning) { self.wrapped = wrapped }

    var defaultTimeout: TimeInterval { wrapped.defaultTimeout }

    var requests: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var listings: [[String]] { requests.filter { $0.contains("list") } }

    func requests(mentioning fragment: String) -> [[String]] {
        requests.filter { argv in argv.contains { $0.contains(fragment) } }
    }

    func run(_ arguments: [String], timeout: TimeInterval) async -> GitCommandInvocation {
        lock.lock()
        recorded.append(arguments)
        lock.unlock()
        return await wrapped.run(arguments, timeout: timeout)
    }
}

/// Forwards everything to a real runner EXCEPT `worktree list`, which answers
/// with doctored porcelain bytes — the only way to express a locked-and-prunable
/// record or a prunable record with no admin entry (git 2.50.1 produces
/// neither).
private final class DoctoringGitRunner: GitCommandRunning, @unchecked Sendable {
    private let wrapped: any GitCommandRunning
    private let listing: Data
    private let lock = NSLock()
    private var recorded: [[String]] = []

    init(wrapping wrapped: any GitCommandRunning, listing: Data) {
        self.wrapped = wrapped
        self.listing = listing
    }

    var defaultTimeout: TimeInterval { wrapped.defaultTimeout }

    var requests: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ arguments: [String], timeout: TimeInterval) async -> GitCommandInvocation {
        lock.lock()
        recorded.append(arguments)
        lock.unlock()
        if arguments.contains("list") {
            return GitCommandInvocation(
                profile: GitSafetyProfile.classify(arguments),
                argv: ["git"] + arguments, environment: [:],
                outcome: .success(stdout: listing)
            )
        }
        return await wrapped.run(arguments, timeout: timeout)
    }
}

/// A fully scripted runner — no process ever runs, so every failure class is
/// exact. Defaults describe the ordinary CANDIDATE path (clean tree, no
/// `origin/HEAD`, a local `main`, an ancestral HEAD, a readable commit date).
private final class ScriptedGitRunner: GitCommandRunning, @unchecked Sendable {
    let defaultTimeout: TimeInterval = 5

    var listing: Data
    var status: GitCommandOutcome = .success(stdout: Data())
    var symbolicRef: GitCommandOutcome = .failure(exitCode: 1, stderr: "")
    var revParseMain: GitCommandOutcome = .success(
        stdout: Data("221c2f088de2c34c76347bde00820accad4f529c\n".utf8)
    )
    var revParseOther: GitCommandOutcome = .failure(exitCode: 1, stderr: "")
    var isAncestor: GitCommandOutcome = .success(stdout: Data())
    var show: GitCommandOutcome = .success(stdout: Data("1614834367\n".utf8))
    /// When set, EVERY invocation answers with it (the unavailable case).
    var forcedOutcome: GitCommandOutcome?

    private let lock = NSLock()
    private var recorded: [[String]] = []

    init(listing: Data = Data()) { self.listing = listing }

    var requests: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requests(mentioning fragment: String) -> [[String]] {
        requests.filter { argv in argv.contains { $0.contains(fragment) } }
    }

    func run(_ arguments: [String], timeout: TimeInterval) async -> GitCommandInvocation {
        lock.lock()
        recorded.append(arguments)
        lock.unlock()
        return GitCommandInvocation(
            profile: GitSafetyProfile.classify(arguments),
            argv: ["git"] + arguments, environment: [:],
            outcome: forcedOutcome ?? outcome(for: arguments)
        )
    }

    private func outcome(for arguments: [String]) -> GitCommandOutcome {
        if arguments.contains("list") { return .success(stdout: listing) }
        if arguments.contains("status") { return status }
        if arguments.contains("symbolic-ref") { return symbolicRef }
        if arguments.contains("rev-parse") {
            return arguments.contains("refs/heads/main") ? revParseMain : revParseOther
        }
        if arguments.contains("merge-base") { return isAncestor }
        if arguments.contains("show") { return show }
        return .failure(exitCode: 1, stderr: "unscripted: \(arguments)")
    }
}

/// Captures the scan's assessment log — the D15 observability surface for
/// worktrees that were assessed and deliberately produced no item.
private final class AssessmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GitWorktreeAssessmentLog?

    var log: GitWorktreeAssessmentLog {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? GitWorktreeAssessmentLog()
    }

    var observe: @Sendable (GitWorktreeAssessmentLog) -> Void {
        { [self] log in
            lock.lock()
            stored = log
            lock.unlock()
        }
    }
}

/// Injects mount points by inode — a mount boundary cannot be fixtured.
private final class MountPointInjectingProvider: FileSystemIdentityProvider {
    var mountPointInodes: Set<UInt64> = []

    override func isMountPoint(_ url: URL) -> Bool {
        if let id = identity(of: url), mountPointInodes.contains(id.inode) {
            return true
        }
        return super.isMountPoint(url)
    }
}

/// Records every lstat PROBE (the operation that precedes every read the
/// resolver and the mapper perform) so a test can prove nothing under a
/// protected ancestor was ever inspected.
private final class ProbeRecordingProvider: FileSystemIdentityProvider {
    private let lock = NSLock()
    private var probed: [String] = []

    var probedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return probed
    }

    override func probeKind(of url: URL) -> KindProbe {
        lock.lock()
        probed.append(url.path)
        lock.unlock()
        return super.probeKind(of: url)
    }

    /// The DESCRIPTOR seam too (fn-6 reconciliation): the walk probes its root
    /// by path but every child through this overload, so recording only the
    /// path one would let "nothing under here was inspected" pass without
    /// having observed the seam most inspections actually use. The cell's
    /// POSITIVE half (`a user-initiated scan follows the pointer`) is what
    /// keeps the negative half from being vacuous either way.
    override func probeKind(
        inDirectory parent: Int32, named name: String, logical url: URL
    ) -> DescriptorKindProbe {
        lock.lock()
        probed.append(url.path)
        lock.unlock()
        return super.probeKind(inDirectory: parent, named: name, logical: url)
    }
}

/// Forces `.failed` probes for exact paths — EPERM cannot be fixtured from an
/// unentitled process.
///
/// BOTH SEAMS ARE OVERRIDDEN, and the descriptor one is the load-bearing half
/// here (fn-6 reconciliation). The walk probes its ROOT by path but every
/// child through `probeKind(inDirectory:named:logical:)` — so a double that
/// covers only the path overload silently stops intercepting below the root,
/// which is where this file's denial fixtures live. It does not fail loudly:
/// the walk simply succeeds and reports no issue, so the cell asserting the
/// denial stays VISIBLE goes red with an empty error list rather than a wrong
/// kind. Matched on the LOGICAL url, which is the spelling `failingPaths`
/// holds.
private final class FailingProbeProvider: FileSystemIdentityProvider {
    var failingPaths: Set<String> = []
    var failErrno: Int32 = EPERM

    override func probeKind(of url: URL) -> KindProbe {
        if failingPaths.contains(url.path) { return .failed(errno: failErrno) }
        return super.probeKind(of: url)
    }

    override func probeKind(
        inDirectory parent: Int32, named name: String, logical url: URL
    ) -> DescriptorKindProbe {
        if failingPaths.contains(url.path) { return .failed(errno: failErrno) }
        return super.probeKind(inDirectory: parent, named: name, logical: url)
    }
}

// MARK: - Tests

final class GitWorktreeScannerTests: XCTestCase {

    private var base: URL!
    /// The injected fixture home — zero real-`$HOME` reads.
    private var home: URL!
    /// The ordinary declared dev root.
    private var dev: URL!
    private let fm = FileManager.default

    private static let utc = TimeZone(identifier: "UTC")!

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("GitWorktreeScannerTests-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        dev = base.appendingPathComponent("dev")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: dev, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
    }

    // MARK: - Fixture helpers

    private func write(_ url: URL, bytes: Int = 4096) throws {
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    @discardableResult
    private func makeRepository(at url: URL) throws -> URL {
        try GitFixture.makeRepository(at: url, home: home)
        return url
    }

    /// `git worktree add <path> -b <branch>`: HEAD equals the default branch's
    /// tip, so the ancestry gate passes and the tree is clean — the ordinary
    /// CANDIDATE shape.
    @discardableResult
    private func addWorktree(
        of repository: URL, at path: URL, branch: String, payloadBytes: Int = 4096
    ) throws -> URL {
        try fm.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let added = try GitFixture.git(
            ["-C", repository.path, "worktree", "add", path.path, "-b", branch],
            home: home
        )
        XCTAssertEqual(added.status, 0, "git worktree add failed at \(path.path)")
        if payloadBytes > 0 {
            // Ignored by `.gitignore`, so the tree stays CLEAN while carrying
            // measurable bytes.
            try write(path.appendingPathComponent("payload.bin"), bytes: payloadBytes)
        }
        return path
    }

    /// A repository whose committed `.gitignore` hides fixture payload files,
    /// so a worktree can carry bytes and still be status-clean.
    @discardableResult
    private func makeRepositoryIgnoringPayloads(at url: URL) throws -> URL {
        try makeRepository(at: url)
        try "payload.bin\nsparse.bin\n".write(
            to: url.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8
        )
        try GitFixture.git(["-C", url.path, "add", ".gitignore"], home: home)
        try GitFixture.git(
            ["-C", url.path, "-c", "user.name=t", "-c", "user.email=t@t",
             "commit", "-m", "ignore"],
            home: home
        )
        return url
    }

    private func makeRunner() -> GitCommandRunner {
        GitCommandRunner(environment: GitFixture.environment(home: home))
    }

    private func makeScanner(
        roots: [URL]? = nil,
        runner: (any GitCommandRunning)? = nil,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        issues: [ScanIssue] = [],
        recorder: AssessmentRecorder? = nil,
        home overrideHome: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> GitWorktreeScanner {
        GitWorktreeScanner(
            home: overrideHome ?? home,
            devRoots: DevRootsResolution(keptRoots: roots ?? [dev], issues: issues),
            runner: runner ?? makeRunner(),
            provider: provider,
            timeZone: Self.utc,
            now: now,
            observeAssessments: recorder?.observe
        )
    }

    /// `git worktree list --porcelain -z` bytes: NUL after every field, a
    /// second NUL closing each record.
    private static func porcelain(_ records: [[String]]) -> Data {
        var data = Data()
        for record in records {
            for field in record {
                data.append(contentsOf: Array(field.utf8))
                data.append(0)
            }
            data.append(0)
        }
        return data
    }

    /// FAILS (never skips) when the item is not the composite shape — a
    /// regression that changed the action must break the suite, not quietly
    /// remove its own assertions.
    private func plan(
        of item: ReclaimableItem, file: StaticString = #filePath, line: UInt = #line
    ) throws -> GitWorktreeReclaimPlan {
        guard case .gitWorktreeReclaim(let plan) = item.action else {
            XCTFail(
                "item action is '\(item.action.wireString)', not git_worktree_reclaim",
                file: file, line: line
            )
            throw CocoaError(.featureUnsupported)
        }
        return plan
    }

    private func origin(
        of item: ReclaimableItem, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (container: URL, target: URL) {
        guard case .containerItem(let container, let target) = item.admission else {
            XCTFail(
                "item does not carry the container-item admission", file: file, line: line
            )
            throw CocoaError(.featureUnsupported)
        }
        return (container, target)
    }

    /// Round-trip the outcome through the production validator. A duplicate id,
    /// a forged binding or an out-of-domain figure rejects the WHOLE outcome,
    /// so this is the assertion that makes every emission contract load-bearing.
    private func assertNonMalformed(
        _ outcome: ScanOutcome, from scanner: GitWorktreeScanner,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let runtime = try SpaceScannerRuntime(
            scanners: [scanner], categories: [], home: home,
            provider: FileSystemIdentityProvider()
        )
        switch runtime.validatedOutcome(outcome, from: GitWorktreeScanner.registeredID) {
        case .outcome:
            break
        case .malformed(_, let issue):
            XCTFail("outcome malformed: \(issue.detail)", file: file, line: line)
        }
    }

    // MARK: - R7: discovery

    func testHiddenParentWorktreeNestedDeepIsDiscoveredAndBindsTheVerbatimRoot()
        async throws
    {
        // The field shape: a worktree under a HIDDEN parent, three levels below
        // the declared root.
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let worktree = try addWorktree(
            of: repository,
            at: dev.appendingPathComponent(".hidden/worktrees/deep/feature"),
            branch: "feature"
        )

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertEqual(outcome.items.count, 1, "one stale candidate: \(outcome.items)")
        let item = try XCTUnwrap(outcome.items.first)
        let admission = try origin(of: item)
        XCTAssertEqual(
            admission.container.path, dev.path,
            "originContainer is the VERBATIM declared root, never a nearer ancestor"
        )
        XCTAssertEqual(
            admission.target.resolvingSymlinksInPath().path,
            worktree.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(item.risk, .review)
        XCTAssertFalse(item.defaultSelected)
        XCTAssertFalse(item.automaticCleanEligible)
        XCTAssertEqual(item.state, .measured)
        XCTAssertNil(item.scanError)
        try assertNonMalformed(outcome, from: scanner)
    }

    func testDotGitEntriesAreSeenButNeverDescended() async throws {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        // A decoy checkout INSIDE `.git`. Descending `.git` would discover it
        // and fire a listing against it — the walker's hard prune must not.
        let decoy = repository.appendingPathComponent(".git/decoy")
        try fm.createDirectory(
            at: decoy.appendingPathComponent(".git"), withIntermediateDirectories: true
        )

        let runner = RecordingGitRunner(wrapping: makeRunner())
        let scanner = makeScanner(runner: runner)
        _ = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(
            runner.requests(mentioning: "decoy").isEmpty,
            "`.git` was descended: \(runner.requests)"
        )
    }

    func testCheckedOutSubmoduleIsNeverEmittedAsAnItem() async throws {
        let upstream = try makeRepository(at: base.appendingPathComponent("upstream"))
        let superproject = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("super")
        )
        let added = try GitFixture.git(
            ["-C", superproject.path, "-c", "protocol.file.allow=always",
             "-c", "user.name=t", "-c", "user.email=t@t",
             "submodule", "add", upstream.path, "sub"],
            home: home
        )
        XCTAssertEqual(added.status, 0, "submodule fixture failed")
        // The shape that must attribute nowhere: a `.git` FILE pointing into
        // `.git/modules/`, not into a `worktrees/<id>` admin directory.
        let pointer = try String(
            contentsOf: superproject.appendingPathComponent("sub/.git"), encoding: .utf8
        )
        XCTAssertTrue(pointer.contains("modules"), "pointer was: \(pointer)")

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(
            outcome.items.isEmpty, "a submodule root was emitted: \(outcome.items)"
        )
        XCTAssertTrue(
            outcome.errors.isEmpty,
            "a checked-out submodule must not publish an issue either: \(outcome.errors)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testNestedWorktreeOfRepoAInsideRepoBAttributesToA() async throws {
        let repoA = try makeRepositoryIgnoringPayloads(at: dev.appendingPathComponent("a"))
        let repoB = try makeRepositoryIgnoringPayloads(at: dev.appendingPathComponent("b"))
        let nested = try addWorktree(
            of: repoA, at: repoB.appendingPathComponent("nested-wt"), branch: "feature"
        )

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        let item = try XCTUnwrap(outcome.items.first {
            $0.url?.resolvingSymlinksInPath().path
                == nested.resolvingSymlinksInPath().path
        })
        let reclaim = try plan(of: item)
        XCTAssertEqual(
            reclaim.parentRepoWorkingDir.resolvingSymlinksInPath().path,
            repoA.resolvingSymlinksInPath().path,
            "physical location never decides attribution — the back-link does"
        )
        XCTAssertNotEqual(
            reclaim.parentRepoWorkingDir.resolvingSymlinksInPath().path,
            repoB.resolvingSymlinksInPath().path
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testForgedBackLinkAttributesNowhereAndPublishesTheMembershipRefusal()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let good = try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt-good"), branch: "good"
        )
        let forged = try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt-forged"), branch: "forged"
        )
        // Point the forged worktree's `.git` at ANOTHER worktree's admin
        // directory: the pointer resolves, but the admin directory's back-link
        // names a different `.git` file, so the bidirectional check fails.
        let goodAdmin = repository.appendingPathComponent(".git/worktrees/wt-good")
        XCTAssertTrue(fm.fileExists(atPath: goodAdmin.path))
        try "gitdir: \(goodAdmin.path)\n".write(
            to: forged.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertEqual(outcome.items.count, 1, "only the honest worktree is offered")
        XCTAssertEqual(
            outcome.items.first?.url?.resolvingSymlinksInPath().path,
            good.resolvingSymlinksInPath().path
        )
        let refusal = try XCTUnwrap(outcome.errors.first {
            $0.url?.path.contains("wt-forged") == true
        })
        XCTAssertEqual(refusal.kind, .unreadable)
        XCTAssertTrue(
            refusal.detail.contains("could not be attributed"),
            "the refusal must name the membership failure; got: \(refusal.detail)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testPorcelainIsFetchedOncePerRepositoryAcrossAliasedRootSpellings()
        async throws
    {
        // A symlinked ANCESTOR is a legal root spelling (the leaf lstats real
        // through it), so the same repository is reachable under two declared
        // roots and must still be listed ONCE.
        let real = base.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let aliasParent = base.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: aliasParent, withDestinationURL: real)
        let realRoot = real.appendingPathComponent("dev")
        let aliasRoot = aliasParent.appendingPathComponent("dev")
        try fm.createDirectory(at: realRoot, withIntermediateDirectories: true)

        let repository = try makeRepositoryIgnoringPayloads(
            at: realRoot.appendingPathComponent("repo")
        )
        try addWorktree(
            of: repository, at: realRoot.appendingPathComponent("wt-a"), branch: "a"
        )
        try addWorktree(
            of: repository, at: realRoot.appendingPathComponent("wt-b"), branch: "b"
        )

        let runner = RecordingGitRunner(wrapping: makeRunner())
        let scanner = makeScanner(roots: [aliasRoot, realRoot], runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertEqual(
            runner.listings.count, 1,
            "one listing per repository, whatever the walk touched: \(runner.listings)"
        )
        XCTAssertEqual(outcome.items.count, 2, "two candidates, no duplicates")
        XCTAssertEqual(Set(outcome.items.map(\.id)).count, 2)
        for item in outcome.items {
            let admission = try origin(of: item)
            XCTAssertTrue(
                [aliasRoot.path, realRoot.path].contains(admission.container.path),
                "origin must be a DECLARED spelling verbatim: \(admission.container.path)"
            )
        }
        try assertNonMalformed(outcome, from: scanner)
    }

    func testMultiWorktreeRepositoryYieldsUniqueIDsAcrossBothTiers() async throws {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        try addWorktree(of: repository, at: dev.appendingPathComponent("wt-a"), branch: "a")
        try addWorktree(of: repository, at: dev.appendingPathComponent("wt-b"), branch: "b")
        let orphan = try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt-gone"), branch: "gone"
        )
        try fm.removeItem(at: orphan)

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertEqual(outcome.items.count, 3, "two candidates + one prune item")
        XCTAssertEqual(
            Set(outcome.items.map(\.id)).count, 3,
            "worktree-path and admin-container preimages must never collide"
        )
        // The three keys: two stale items preimage their WORKTREE paths, the
        // prune item preimages the ADMIN CONTAINER.
        let prune = try XCTUnwrap(outcome.items.first {
            if case .gitWorktreeReclaim(let plan) = $0.action {
                return plan.mode == .pruneOrphanedAdmin
            }
            return false
        })
        let containerIdentity = FileSystemIdentityProvider().resolveTargetKeepingLeaf(
            repository.appendingPathComponent(".git/worktrees")
        )
        XCTAssertEqual(
            prune.id,
            ReclaimableItem.stableID(
                scannerID: GitWorktreeScanner.registeredID,
                canonicalPath: containerIdentity.path
            )
        )
        // …and each stale item preimages its OWN worktree path.
        for stale in outcome.items where stale.id != prune.id {
            let identity = FileSystemIdentityProvider()
                .resolveTargetKeepingLeaf(try XCTUnwrap(stale.url))
            XCTAssertEqual(
                stale.id,
                ReclaimableItem.stableID(
                    scannerID: GitWorktreeScanner.registeredID,
                    canonicalPath: identity.path
                )
            )
        }
        try assertNonMalformed(outcome, from: scanner)
    }

    // MARK: - R6: the orphaned-admin tier

    func testTwoOrphanedCheckoutsYieldOneMeasuredPruneItemDisclosingBoth()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        var orphans: [URL] = []
        for index in 0..<2 {
            let orphan = try addWorktree(
                of: repository, at: dev.appendingPathComponent("gone-\(index)"),
                branch: "gone-\(index)"
            )
            try fm.removeItem(at: orphan)
            orphans.append(orphan)
        }

        let runner = RecordingGitRunner(wrapping: makeRunner())
        let scanner = makeScanner(runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertEqual(outcome.items.count, 1, "ONE repo-level prune item")
        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.risk, .safe)
        XCTAssertFalse(item.defaultSelected)
        XCTAssertFalse(item.automaticCleanEligible)
        XCTAssertEqual(
            item.state, .measured,
            "never .empty — the cleaner's zero-byte skip precedes action dispatch"
        )
        XCTAssertEqual(item.itemCount, 2, "itemCount is the DISCLOSED count")
        XCTAssertNil(item.scanError)

        let reclaim = try plan(of: item)
        XCTAssertEqual(reclaim.mode, .pruneOrphanedAdmin)
        XCTAssertNil(reclaim.worktreePath)
        XCTAssertNil(reclaim.worktreeAdminEntry)
        XCTAssertEqual(reclaim.disclosedAdminDirectories.count, 2)
        let admission = try origin(of: item)
        XCTAssertEqual(
            admission.target.path, reclaim.parentAdminContainer.path,
            "the admitted target IS the carried admin container"
        )
        for directory in reclaim.disclosedAdminDirectories {
            XCTAssertEqual(
                directory.deletingLastPathComponent().path,
                reclaim.parentAdminContainer.path
            )
        }
        // Both orphaned checkouts are named in the disclosure.
        for orphan in orphans {
            XCTAssertTrue(
                item.evidence.contains(orphan.resolvingSymlinksInPath().lastPathComponent),
                "evidence must disclose \(orphan.path); got: \(item.evidence)"
            )
        }
        // The oracle's pinned config override rode the ONE listing.
        let listing = try XCTUnwrap(runner.listings.first)
        XCTAssertTrue(listing.contains(GitWorktreeOracle.pruneExpireOverride))
        try assertNonMalformed(outcome, from: scanner)
    }

    func testZeroBytePruneShapeSurvivesTheValueDomainFamily() async throws {
        // The as-built parity rule the prune item depends on: a ZERO-byte
        // `.measured` item with itemCount >= 1 is valid, so a disclosure whose
        // admin directories measure nothing still reaches dispatch instead of
        // being skipped as `.empty`.
        let container = dev.appendingPathComponent("repo/.git/worktrees")
        let entry = container.appendingPathComponent("gone")
        let item = ReclaimableItem(
            id: "zero-byte-prune",
            scannerID: GitWorktreeScanner.registeredID,
            displayName: "repo — orphaned worktree registry",
            exactBytes: 0, estimatedUpToBytes: 0, logicalBytes: nil, itemCount: 1,
            url: container, declaredDisplayPath: container.path,
            rootRecords: [RootScanRecord(
                requestedURL: container, resolvedURL: container, status: .measured
            )],
            state: .measured, scanError: nil, risk: .safe,
            evidence: "1 orphaned worktree admin directory to prune: gone",
            rebuildNote: nil,
            action: .gitWorktreeReclaim(.pruneOrphanedAdmin(
                parentRepoWorkingDir: dev.appendingPathComponent("repo"),
                adminContainer: container,
                disclosedAdminDirectories: [entry]
            )),
            admission: .containerItem(originContainer: dev, requestedTargetURL: container),
            defaultSelected: false, automaticCleanEligible: false, isStale: nil
        )
        let scanner = makeScanner()
        try assertNonMalformed(
            ScanOutcome(items: [item], errors: []), from: scanner
        )
    }

    func testUnmappablePrunableRecordSuppressesThePruneItemEntirely() async throws {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let orphan = try addWorktree(
            of: repository, at: dev.appendingPathComponent("gone"), branch: "gone"
        )
        try fm.removeItem(at: orphan)
        let ghost = dev.appendingPathComponent("never-registered")

        // A prunable record no admin entry maps to. git 2.50.1 cannot produce
        // one (its records are DERIVED from the admin entries), so it is
        // injected — the repo-wide prune would still remove the unmapped entry,
        // which is exactly what D14 forbids disclosing around.
        let realListing = try await listing(of: repository)
        let doctored = Self.porcelain([
            ["worktree \(repository.resolvingSymlinksInPath().path)", "HEAD \(String(repeating: "0", count: 40))", "branch refs/heads/main"],
            ["worktree \(orphan.resolvingSymlinksInPath().path)", "HEAD \(String(repeating: "0", count: 40))", "detached", "prunable gitdir file points to non-existent location"],
            ["worktree \(ghost.path)", "HEAD \(String(repeating: "0", count: 40))", "detached", "prunable gitdir file points to non-existent location"],
        ])
        XCTAssertFalse(realListing.isEmpty, "the real listing is the shape being doctored")

        let runner = DoctoringGitRunner(wrapping: makeRunner(), listing: doctored)
        let scanner = makeScanner(runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(
            outcome.items.isEmpty,
            "a knowingly-incomplete disclosure must never ship: \(outcome.items)"
        )
        let issue = try XCTUnwrap(outcome.errors.first { $0.kind == .unreadable })
        XCTAssertTrue(
            issue.detail.contains(ghost.path),
            "the issue must NAME the unmapped entry; got: \(issue.detail)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testLockedPrunableEntryIsExcludedWithoutSuppressingTheItem() async throws {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        var orphans: [URL] = []
        for index in 0..<2 {
            let orphan = try addWorktree(
                of: repository, at: dev.appendingPathComponent("gone-\(index)"),
                branch: "gone-\(index)"
            )
            try fm.removeItem(at: orphan)
            orphans.append(orphan)
        }
        // git withholds `prunable` from a locked-and-missing worktree on
        // 2.50.1, so the LOCKED+PRUNABLE combination is injected. It must be
        // excluded from the disclosure WITHOUT suppressing the item: git's own
        // prune skips locked admin directories, so they are not in the set.
        let doctored = Self.porcelain([
            ["worktree \(repository.resolvingSymlinksInPath().path)", "HEAD \(String(repeating: "0", count: 40))", "branch refs/heads/main"],
            ["worktree \(orphans[0].resolvingSymlinksInPath().path)", "HEAD \(String(repeating: "0", count: 40))", "detached", "prunable gitdir file points to non-existent location"],
            ["worktree \(orphans[1].resolvingSymlinksInPath().path)", "HEAD \(String(repeating: "0", count: 40))", "detached", "locked in use elsewhere", "prunable gitdir file points to non-existent location"],
        ])

        let runner = DoctoringGitRunner(wrapping: makeRunner(), listing: doctored)
        let scanner = makeScanner(runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertEqual(outcome.items.count, 1, "the item survives the locked entry")
        let reclaim = try plan(of: try XCTUnwrap(outcome.items.first))
        XCTAssertEqual(
            reclaim.disclosedAdminDirectories.count, 1,
            "the locked entry stays UNDISCLOSED: \(reclaim.disclosedAdminDirectories)"
        )
        XCTAssertEqual(outcome.items.first?.itemCount, 1)
        try assertNonMalformed(outcome, from: scanner)
    }

    func testBoundaryBearingAdminDirectorySuppressesThePruneItem() async throws {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let orphan = try addWorktree(
            of: repository, at: dev.appendingPathComponent("gone"), branch: "gone"
        )
        try fm.removeItem(at: orphan)
        let adminDirectory = repository.appendingPathComponent(".git/worktrees/gone")
        XCTAssertTrue(fm.fileExists(atPath: adminDirectory.path))

        let provider = MountPointInjectingProvider()
        provider.mountPointInodes = [
            try XCTUnwrap(provider.identity(of: adminDirectory)?.inode),
        ]
        let scanner = makeScanner(provider: provider)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(
            outcome.items.isEmpty,
            "a boundary-bearing admin directory must never ride a recursive prune"
        )
        let issue = try XCTUnwrap(outcome.errors.first { $0.kind == .unreadable })
        XCTAssertTrue(
            issue.detail.contains("mount boundary"),
            "the issue must NAME the boundary; got: \(issue.detail)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testSymlinkedAdminEntrySuppressesThePruneItem() async throws {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let orphan = try addWorktree(
            of: repository, at: dev.appendingPathComponent("gone"), branch: "gone"
        )
        try fm.removeItem(at: orphan)
        // Replace the admin ENTRY with a symlink: the round-10 gate refuses it
        // BEFORE any back-link is read.
        let entry = repository.appendingPathComponent(".git/worktrees/gone")
        let stashed = base.appendingPathComponent("stashed-admin")
        try fm.moveItem(at: entry, to: stashed)
        try fm.createSymbolicLink(at: entry, withDestinationURL: stashed)

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(outcome.items.isEmpty, "symlinked admin entry must suppress")
        let issue = try XCTUnwrap(outcome.errors.first { $0.kind == .unreadable })
        // The reason names gate (a) — the no-follow real-directory probe, which
        // runs BEFORE any back-link is read or any `.scanRoot` sizing happens.
        // The wording is therefore the proof of gate ORDER, not just of refusal.
        XCTAssertTrue(
            issue.detail.contains("not a real directory"),
            "got: \(issue.detail)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testSymlinkedGitdirFileSuppressesThePruneItem() async throws {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let orphan = try addWorktree(
            of: repository, at: dev.appendingPathComponent("gone"), branch: "gone"
        )
        try fm.removeItem(at: orphan)
        let backlink = repository.appendingPathComponent(".git/worktrees/gone/gitdir")
        let stashed = base.appendingPathComponent("stashed-gitdir")
        try fm.moveItem(at: backlink, to: stashed)
        try fm.createSymbolicLink(at: backlink, withDestinationURL: stashed)

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(outcome.items.isEmpty, "symlinked gitdir must suppress")
        let issue = try XCTUnwrap(outcome.errors.first { $0.kind == .unreadable })
        XCTAssertTrue(
            issue.detail.contains("no regular gitdir file"), "got: \(issue.detail)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testTheScannerNeverReconstructsTheAdminContainerFromTheWorkingDirectory()
        throws
    {
        // The grep gate the epic pins: a bare parent's git directory does not
        // live at `<wd>/.git`, so a `<wd>/.git/worktrees` reconstruction would
        // silently mis-path the mutation scope.
        let text = try scannerSource()
        var inspected = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false)
        where line.contains(".git/worktrees") {
            inspected += 1
            XCTAssertTrue(
                line.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                "a `<wd>/.git/worktrees` reconstruction reached code: \(line)"
            )
        }
        XCTAssertGreaterThan(
            inspected, 0, "the gate must actually be reading the scanner source"
        )
    }

    func testOracleToAdminMappingFlowsThroughTheOneSharedComponent() throws {
        // ONE implementation, two call sites (fn-5.4's delete-time recompute is
        // the other). A second mapping would let detection and execution
        // disagree about a repository-wide side effect, so the scanner must
        // neither enumerate the admin container itself nor re-derive the
        // oracle's argv.
        let text = try scannerSource()
        XCTAssertTrue(
            text.contains("mapper.map("),
            "the scanner must consume fn-5.1's shared mapper"
        )
        XCTAssertFalse(
            text.contains("contentsOfDirectory"),
            "enumerating the admin container here would be a SECOND mapping"
        )
        XCTAssertTrue(
            text.contains("GitWorktreeOracle.listArguments"),
            "the oracle argv is fn-5.1's, never re-spelled"
        )
        XCTAssertFalse(
            text.contains("--porcelain"),
            "a locally-spelled porcelain argv would fork the oracle contract"
        )
    }

    private func scannerSource() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // CacheoutTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // package root
            .appendingPathComponent("Sources/Cacheout/Scanner/GitWorktreeScanner.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    // MARK: - R8: containment (D13)

    func testBareParentEmitsWithTheCarriedAdminContainer() async throws {
        let bare = dev.appendingPathComponent("repo.git")
        let seed = try makeRepositoryIgnoringPayloads(at: base.appendingPathComponent("seed"))
        let cloned = try GitFixture.git(
            ["clone", "--bare", seed.path, bare.path], home: home
        )
        XCTAssertEqual(cloned.status, 0, "bare clone failed")
        let worktree = try addWorktree(
            of: bare, at: dev.appendingPathComponent("bare-wt"), branch: "feature"
        )

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        let item = try XCTUnwrap(outcome.items.first {
            $0.url?.resolvingSymlinksInPath().path
                == worktree.resolvingSymlinksInPath().path
        })
        let reclaim = try plan(of: item)
        XCTAssertEqual(
            reclaim.parentAdminContainer.resolvingSymlinksInPath().path,
            bare.appendingPathComponent("worktrees").resolvingSymlinksInPath().path,
            "the carried `<bareGitDir>/worktrees`, never `<wd>/.git/worktrees`"
        )
        XCTAssertEqual(
            reclaim.parentRepoWorkingDir.resolvingSymlinksInPath().path,
            bare.resolvingSymlinksInPath().path,
            "a bare main's `-C` target is the repository directory itself"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testDevRootThatIsARepositoryEmitsWithTheParentEqualToTheRoot()
        async throws
    {
        // The dev root IS the repository (epic round 4/F5): the parent may
        // EQUAL the declared root, while the admin container and the worktree
        // stay STRICT descendants.
        let root = try makeRepositoryIgnoringPayloads(
            at: base.appendingPathComponent("rootrepo")
        )
        let worktree = try addWorktree(
            of: root, at: root.appendingPathComponent("wts/feature"), branch: "feature"
        )

        let scanner = makeScanner(roots: [root])
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        let item = try XCTUnwrap(outcome.items.first {
            $0.url?.resolvingSymlinksInPath().path
                == worktree.resolvingSymlinksInPath().path
        })
        let admission = try origin(of: item)
        let reclaim = try plan(of: item)
        XCTAssertEqual(admission.container.path, root.path)
        XCTAssertEqual(
            reclaim.parentRepoWorkingDir.path, root.path,
            "descendant-OR-EQUAL applies to the parent alone"
        )
        XCTAssertTrue(
            GitWorktreeScanner.isStrictDescendant(
                reclaim.parentAdminContainer, of: root
            )
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testWorktreeOutsideEveryDevRootIsARefusalIssueAndNeverAnItem()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let outside = try addWorktree(
            of: repository, at: base.appendingPathComponent("outside-wt"), branch: "out"
        )

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(outcome.items.isEmpty, "no display-only admission exists")
        let issue = try XCTUnwrap(outcome.errors.first { $0.kind == .containerRefused })
        XCTAssertTrue(
            issue.detail.contains(outside.resolvingSymlinksInPath().path),
            "the refusal must name the worktree; got: \(issue.detail)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testParentRepositoryOutsideEveryRootIsAssessedButNeverEmitted()
        async throws
    {
        // The parent lives OUTSIDE the dev roots while its worktree lives
        // inside: read-only git still assesses it (that is not gated by
        // `admitSearchRoot`), but git would mutate the parent's admin data, so
        // no deletable item may exist.
        let repository = try makeRepositoryIgnoringPayloads(
            at: base.appendingPathComponent("outside-repo")
        )
        let worktree = try addWorktree(
            of: repository, at: dev.appendingPathComponent("inside-wt"), branch: "feature"
        )

        let runner = RecordingGitRunner(wrapping: makeRunner())
        let scanner = makeScanner(runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(outcome.items.isEmpty, "D13 forbids the deletable item")
        let issue = try XCTUnwrap(outcome.errors.first { $0.kind == .containerRefused })
        XCTAssertTrue(
            issue.detail.contains("parent repository"),
            "the refusal must name the parent-outside cause; got: \(issue.detail)"
        )
        // ASSESSED all the same — the status gate ran against the worktree and
        // the default-branch ladder against the parent.
        XCTAssertFalse(
            runner.requests(mentioning: worktree.resolvingSymlinksInPath().path)
                .filter { $0.contains("status") }.isEmpty,
            "the worktree was never assessed: \(runner.requests)"
        )
        XCTAssertFalse(
            runner.requests(mentioning: repository.resolvingSymlinksInPath().path)
                .filter { $0.contains("symbolic-ref") }.isEmpty,
            "read-only git against an outside parent is deliberate: \(runner.requests)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    // MARK: - R10: item shape, sizing, boundaries

    func testMountBoundaryInsideACandidateDeniesWithZeroReclaimableComponents()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let worktree = try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt"), branch: "feature"
        )
        let nested = worktree.appendingPathComponent("mounted")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try write(nested.appendingPathComponent("payload.bin"), bytes: 8192)

        let provider = MountPointInjectingProvider()
        provider.mountPointInodes = [
            try XCTUnwrap(provider.identity(of: nested)?.inode),
        ]
        let scanner = makeScanner(provider: provider)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.state, .denied)
        XCTAssertEqual(item.exactBytes, 0)
        XCTAssertEqual(item.estimatedUpToBytes, 0)
        XCTAssertEqual(item.itemCount, 0)
        XCTAssertNil(item.logicalBytes)
        XCTAssertEqual(item.scanError?.kind, .other)
        XCTAssertTrue(
            item.scanError?.message.contains(nested.path) == true,
            "the error must name the boundary; got: \(item.scanError?.message ?? "nil")"
        )
        XCTAssertEqual(item.rootRecords.first?.status, .deniedUnmeasured)
        try assertNonMalformed(outcome, from: scanner)
    }

    func testLogicalBytesRideOnlyWhenTheyExceedTheAllocatedMeasurement()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let worktree = try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt"), branch: "feature"
        )
        // A sparse file: logical hugely exceeds allocated (the 57.1 GB / 31 GB
        // field case). `.gitignore` keeps the tree status-clean.
        let sparse = worktree.appendingPathComponent("sparse.bin")
        XCTAssertTrue(fm.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 256 * 1024 * 1024)
        try handle.close()

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        let item = try XCTUnwrap(outcome.items.first)
        let logical = try XCTUnwrap(item.logicalBytes, "sparse divergence must publish")
        XCTAssertGreaterThan(logical, item.allocatedBytes)

        // And the predicate itself is the node_modules form, verbatim.
        var dense = SizeReport()
        dense.exactAllocatedBytes = 4096
        dense.logicalBytes = 4000
        XCTAssertNil(
            GitWorktreeScanner.publishedLogicalBytes(deletable: true, report: dense)
        )
        var denied = SizeReport()
        denied.exactAllocatedBytes = 4096
        denied.logicalBytes = 8192
        XCTAssertNil(
            GitWorktreeScanner.publishedLogicalBytes(deletable: false, report: denied)
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testAssessedNonCandidateIsOmittedFromItemsAndStaysObservable()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let dirty = try addWorktree(
            of: repository, at: dev.appendingPathComponent("dirty-wt"), branch: "dirty"
        )
        // Untracked (and NOT ignored) work — the one thing that exists nowhere
        // else.
        try write(dirty.appendingPathComponent("uncommitted.txt"), bytes: 32)
        try addWorktree(
            of: repository, at: dev.appendingPathComponent("clean-wt"), branch: "clean"
        )

        let recorder = AssessmentRecorder()
        let scanner = makeScanner(recorder: recorder)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertEqual(outcome.items.count, 1, "the dirty worktree is OMITTED")
        XCTAssertEqual(
            outcome.items.first?.url?.resolvingSymlinksInPath().lastPathComponent,
            "clean-wt"
        )
        XCTAssertTrue(
            outcome.errors.isEmpty,
            "an omitted non-candidate is not an error either: \(outcome.errors)"
        )
        // D15's observability half.
        let log = recorder.log
        XCTAssertEqual(log.assessedCount, 2)
        XCTAssertEqual(log.candidateCount, 1)
        XCTAssertEqual(log.emittedCount, 1)
        XCTAssertEqual(log.omittedNonCandidateCount, 1)
        let omitted = try XCTUnwrap(log.omittedNonCandidates.first)
        XCTAssertEqual(
            omitted.worktreePath.resolvingSymlinksInPath().path,
            dirty.resolvingSymlinksInPath().path
        )
        XCTAssertTrue(
            omitted.evidence.contains("G2 dirty"),
            "the canonical four-clause evidence survives omission; got: \(omitted.evidence)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    // MARK: - R10: git availability and the empty-roots boundary

    func testEmptyDevRootsProduceACleanEmptyOutcomeWithNoIssueAndNoGit()
        async throws
    {
        let runner = RecordingGitRunner(wrapping: makeRunner())
        let scanner = makeScanner(roots: [], runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertTrue(outcome.errors.isEmpty, "an empty configuration is benign")
        XCTAssertTrue(
            runner.requests.isEmpty,
            "not even an availability probe fires: \(runner.requests)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testGitUnavailableIsAVisibleToolUnavailableIssueAndNeverAnEmptySuccess()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        try addWorktree(of: repository, at: dev.appendingPathComponent("wt"), branch: "f")

        // HERMETIC unavailability: a PATH of one empty directory makes `env`
        // exit 127 on every host (the production PATH contains /usr/bin, where
        // the CLT shim lives, so it can never prove absence).
        let emptyPath = base.appendingPathComponent("empty-path")
        try fm.createDirectory(at: emptyPath, withIntermediateDirectories: true)
        let runner = GitCommandRunner(
            environment: ["PATH": emptyPath.path, "HOME": home.path]
        )
        let scanner = makeScanner(runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(outcome.items.isEmpty)
        let issue = try XCTUnwrap(outcome.errors.first { $0.kind == .toolUnavailable })
        XCTAssertNil(issue.url, "a non-filesystem kind never invents a path")
        XCTAssertTrue(
            issue.detail.hasPrefix("git unavailable"),
            "the pinned detail prefix; got: \(issue.detail)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testConfiguredRootIssuesRideEveryOutcome() async throws {
        let configIssue = ScanIssue(
            url: nil, kind: .configInvalid, detail: "stored dev roots unparseable"
        )
        let scanner = makeScanner(roots: [], issues: [configIssue])
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))
        XCTAssertEqual(outcome.errors, [configIssue])
    }

    // MARK: - R10: the TCC root gate

    func testAutomaticScanSilentlySkipsProtectedRootsAndUserInitiatedWalksThem()
        async throws
    {
        let protectedRoot = home.appendingPathComponent("Documents/dev")
        try fm.createDirectory(at: protectedRoot, withIntermediateDirectories: true)
        let repository = try makeRepositoryIgnoringPayloads(
            at: protectedRoot.appendingPathComponent("repo")
        )
        try addWorktree(
            of: repository, at: protectedRoot.appendingPathComponent("wt"), branch: "f"
        )

        let automaticRunner = RecordingGitRunner(wrapping: makeRunner())
        let automatic = await makeScanner(roots: [protectedRoot], runner: automaticRunner)
            .scan(context: ScanContext(trigger: .automatic))
        XCTAssertTrue(automatic.items.isEmpty)
        XCTAssertTrue(
            automatic.errors.isEmpty,
            "a POLICY skip is silent — it is not a scan problem: \(automatic.errors)"
        )
        XCTAssertTrue(
            automaticRunner.requests.isEmpty,
            "an automatic scan must not be the thing that fires a privacy prompt"
        )

        let userScanner = makeScanner(roots: [protectedRoot])
        let user = await userScanner.scan(context: ScanContext(trigger: .userInitiated))
        XCTAssertEqual(user.items.count, 1, "the user asked: \(user.errors)")
        try assertNonMalformed(user, from: userScanner)
    }

    func testGenuineWalkDenialStaysVisibleUnderBothTriggers() async throws {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        try addWorktree(of: repository, at: dev.appendingPathComponent("wt"), branch: "f")
        let denied = dev.appendingPathComponent("denied-subtree")
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)

        for trigger in [ScanTrigger.automatic, .userInitiated] {
            let provider = FailingProbeProvider()
            provider.failingPaths = [denied.path]
            let scanner = makeScanner(provider: provider)
            let outcome = await scanner.scan(context: ScanContext(trigger: trigger))
            XCTAssertTrue(
                outcome.errors.contains { $0.kind == .tccDenied && $0.url?.path == denied.path },
                "a genuine denial must stay visible under \(trigger): \(outcome.errors)"
            )
        }
    }

    // MARK: - R10: the SECONDARY protected-ancestor gate (epic round 7)

    func testProtectedParentRepositoryDefersAssessmentOnAutomaticScansOnly()
        async throws
    {
        // PARENT-PROTECTED-BUT-ROOT-UNPROTECTED. The fixture home sits INSIDE
        // the dev root, so the parent repository is BOTH inside the declared
        // root (containment holds — an item is legal) and under a protected
        // ancestor (the secondary gate applies).
        let protectedHome = dev.appendingPathComponent("home")
        try fm.createDirectory(
            at: protectedHome.appendingPathComponent("Documents"),
            withIntermediateDirectories: true
        )
        let repository = try makeRepositoryIgnoringPayloads(
            at: protectedHome.appendingPathComponent("Documents/repo")
        )
        let worktree = try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt"), branch: "feature"
        )

        let automaticRunner = RecordingGitRunner(wrapping: makeRunner())
        let automatic = await makeScanner(
            runner: automaticRunner, home: protectedHome
        ).scan(context: ScanContext(trigger: .automatic))
        XCTAssertTrue(automatic.items.isEmpty, "assessment deferred ⇒ no item")
        XCTAssertTrue(
            automatic.errors.isEmpty, "a deferral is silent: \(automatic.errors)"
        )
        XCTAssertTrue(
            automaticRunner.requests(
                mentioning: repository.resolvingSymlinksInPath().path
            ).isEmpty,
            "NO git argv may touch the protected parent: \(automaticRunner.requests)"
        )

        let userRunner = RecordingGitRunner(wrapping: makeRunner())
        let userScanner = makeScanner(runner: userRunner, home: protectedHome)
        let user = await userScanner.scan(context: ScanContext(trigger: .userInitiated))
        XCTAssertEqual(user.items.count, 1, "the user asked: \(user.errors)")
        XCTAssertEqual(
            user.items.first?.url?.resolvingSymlinksInPath().path,
            worktree.resolvingSymlinksInPath().path
        )
        XCTAssertFalse(
            userRunner.requests(
                mentioning: repository.resolvingSymlinksInPath().path
            ).isEmpty,
            "a user-initiated scan assesses it"
        )
        try assertNonMalformed(user, from: userScanner)
    }

    func testProtectedAdminContainerDefersTheRepositoryOnAutomaticScansOnly()
        async throws
    {
        // ADMIN-PROTECTED: only the repository's git directory (and therefore
        // its admin container) sits under a protected ancestor. Real git cannot
        // build this shape — a `--separate-git-dir` repository reports the
        // EXTERNAL git directory as its first record, which fails membership —
        // so the fixture is hand-built and the listing injected.
        let protectedHome = dev.appendingPathComponent("home")
        let gitDirectory = protectedHome.appendingPathComponent("Documents/repo.git")
        let workingTree = dev.appendingPathComponent("wd")
        let worktree = dev.appendingPathComponent("wt")
        try makeSplitRepository(
            gitDirectory: gitDirectory, workingTree: workingTree, worktree: worktree
        )
        let listing = Self.porcelain([
            ["worktree \(workingTree.path)", "HEAD \(String(repeating: "a", count: 40))", "branch refs/heads/main"],
            ["worktree \(worktree.path)", "HEAD \(String(repeating: "a", count: 40))", "branch refs/heads/feature"],
        ])

        let automaticRunner = ScriptedGitRunner(listing: listing)
        let automatic = await makeScanner(
            runner: automaticRunner, home: protectedHome
        ).scan(context: ScanContext(trigger: .automatic))
        XCTAssertTrue(automatic.items.isEmpty)
        XCTAssertTrue(automatic.errors.isEmpty, "silent: \(automatic.errors)")
        XCTAssertTrue(
            automaticRunner.requests.isEmpty, "no git ran at all: \(automaticRunner.requests)"
        )

        let userRunner = ScriptedGitRunner(listing: listing)
        let userScanner = makeScanner(runner: userRunner, home: protectedHome)
        let user = await userScanner.scan(context: ScanContext(trigger: .userInitiated))
        XCTAssertEqual(user.items.count, 1, "the user asked: \(user.errors)")
        let reclaim = try plan(of: try XCTUnwrap(user.items.first))
        XCTAssertEqual(
            reclaim.parentAdminContainer.resolvingSymlinksInPath().path,
            gitDirectory.appendingPathComponent("worktrees")
                .resolvingSymlinksInPath().path
        )
        try assertNonMalformed(user, from: userScanner)
    }

    func testProtectedFirstRecordDefersSilentlyRatherThanFailingCrossValidation()
        async throws
    {
        // The stage-2 cell only a SPLIT repository can express: the common git
        // directory and the worktree are unprotected (so the listing runs),
        // while the porcelain FIRST RECORD — the `-C` target of the
        // default-branch ladder — sits under a protected ancestor.
        //
        // Cross-validation INSPECTS that first record (`<firstRecord>/.git`),
        // so on an automatic scan the deferring provider reports it absent. Were
        // the gate to run after cross-validation, the repository would publish a
        // VISIBLE membership refusal for what is a silent policy deferral.
        let protectedHome = dev.appendingPathComponent("home")
        try fm.createDirectory(
            at: protectedHome.appendingPathComponent("Documents"),
            withIntermediateDirectories: true
        )
        let gitDirectory = dev.appendingPathComponent("gitdir")
        let workingTree = protectedHome.appendingPathComponent("Documents/wd")
        let worktree = dev.appendingPathComponent("wt")
        try makeSplitRepository(
            gitDirectory: gitDirectory, workingTree: workingTree, worktree: worktree
        )
        let listing = Self.porcelain([
            ["worktree \(workingTree.path)", "HEAD \(String(repeating: "a", count: 40))", "branch refs/heads/main"],
            ["worktree \(worktree.path)", "HEAD \(String(repeating: "a", count: 40))", "branch refs/heads/feature"],
        ])

        let automaticRunner = ScriptedGitRunner(listing: listing)
        let automatic = await makeScanner(
            runner: automaticRunner, home: protectedHome
        ).scan(context: ScanContext(trigger: .automatic))
        XCTAssertTrue(automatic.items.isEmpty)
        XCTAssertTrue(
            automatic.errors.isEmpty,
            "a deferral must never surface as a membership refusal: \(automatic.errors)"
        )
        XCTAssertTrue(
            automaticRunner.requests(mentioning: workingTree.path).isEmpty,
            "NO git argv may touch the protected parent: \(automaticRunner.requests)"
        )

        let userRunner = ScriptedGitRunner(listing: listing)
        let userScanner = makeScanner(runner: userRunner, home: protectedHome)
        let user = await userScanner.scan(context: ScanContext(trigger: .userInitiated))
        XCTAssertEqual(user.items.count, 1, "the user asked: \(user.errors)")
        XCTAssertFalse(
            userRunner.requests(mentioning: workingTree.path)
                .filter { $0.contains("symbolic-ref") }.isEmpty,
            "the ladder queries the first record: \(userRunner.requests)"
        )
        let reclaim = try plan(of: try XCTUnwrap(user.items.first))
        XCTAssertEqual(
            reclaim.parentRepoWorkingDir.resolvingSymlinksInPath().path,
            workingTree.resolvingSymlinksInPath().path
        )
        try assertNonMalformed(user, from: userScanner)
    }

    func testAutomaticScanNeverInspectsAProtectedAdminDirectoryWhileAttributing()
        async throws
    {
        // The gate's DISCOVERY-time face. Learning which repository a worktree
        // belongs to means FOLLOWING its `.git` pointer, and the pointer's
        // target is unknowable until it is read — so an ungated resolution
        // would inspect (and open) protected git admin files with no git
        // subprocess for a `requests` assertion to catch.
        //
        // The protected git directory sits OUTSIDE the dev root here on
        // purpose: only the RESOLVER can reach it, so every probe of it is
        // attributable to the resolution under test. (In the cell above the
        // fixture home lives inside the dev root, so the WALKER enumerates the
        // same subtree by fn-4's own per-root contract — which would make this
        // assertion untestable there.)
        let protectedHome = base.appendingPathComponent("protected-home")
        let gitDirectory = protectedHome.appendingPathComponent("Documents/repo.git")
        let workingTree = dev.appendingPathComponent("wd")
        let worktree = dev.appendingPathComponent("wt")
        try makeSplitRepository(
            gitDirectory: gitDirectory, workingTree: workingTree, worktree: worktree
        )
        let listing = Self.porcelain([
            ["worktree \(workingTree.path)", "HEAD \(String(repeating: "a", count: 40))", "branch refs/heads/main"],
            ["worktree \(worktree.path)", "HEAD \(String(repeating: "a", count: 40))", "branch refs/heads/feature"],
        ])

        // Both spellings: the resolver probes the CANONICAL pointer target,
        // while the fixture path carries the `/var` alias macOS temp dirs live
        // under — matching only one of them would make the assertion vacuous.
        let protectedPrefixes = [
            gitDirectory.path,
            FileSystemIdentityProvider().canonicalize(gitDirectory).path,
        ]
        func protectedProbes(_ provider: ProbeRecordingProvider) -> [String] {
            provider.probedPaths.filter { path in
                protectedPrefixes.contains { path.hasPrefix($0) }
            }
        }

        let automaticProvider = ProbeRecordingProvider()
        let automaticRunner = ScriptedGitRunner(listing: listing)
        let automatic = await makeScanner(
            runner: automaticRunner, provider: automaticProvider, home: protectedHome
        ).scan(context: ScanContext(trigger: .automatic))
        XCTAssertTrue(automatic.items.isEmpty)
        XCTAssertTrue(automatic.errors.isEmpty, "a deferral is silent: \(automatic.errors)")
        XCTAssertTrue(automaticRunner.requests.isEmpty)
        XCTAssertTrue(
            protectedProbes(automaticProvider).isEmpty,
            "protected admin paths were inspected: \(protectedProbes(automaticProvider))"
        )

        // The very same fixture under a user-initiated scan DOES inspect it —
        // the deferral is policy, not a capability. No item can exist either
        // way here (the admin container is outside every declared root, D13),
        // and the refusal is published because the assessment was reached.
        let userProvider = ProbeRecordingProvider()
        let userScanner = makeScanner(
            runner: ScriptedGitRunner(listing: listing), provider: userProvider,
            home: protectedHome
        )
        let user = await userScanner.scan(context: ScanContext(trigger: .userInitiated))
        XCTAssertFalse(
            protectedProbes(userProvider).isEmpty,
            "a user-initiated scan follows the pointer"
        )
        XCTAssertTrue(user.items.isEmpty, "the admin container is outside every root")
        XCTAssertTrue(user.errors.contains { $0.kind == .containerRefused })
        try assertNonMalformed(user, from: userScanner)
    }

    func testFirstRecordAuthorityWinsWhenTheGitDirsParentIsNotTheWorkingTree()
        async throws
    {
        // The hand-built shape fn-5.1 pins: the git directory's PARENT is not
        // the working tree, so a path-derived `-C` target would be wrong. The
        // porcelain FIRST RECORD is the authority.
        let gitDirectory = dev.appendingPathComponent("elsewhere/repo.git")
        let workingTree = dev.appendingPathComponent("wd")
        let worktree = dev.appendingPathComponent("wt")
        try makeSplitRepository(
            gitDirectory: gitDirectory, workingTree: workingTree, worktree: worktree
        )
        let listing = Self.porcelain([
            ["worktree \(workingTree.path)", "HEAD \(String(repeating: "a", count: 40))", "branch refs/heads/main"],
            ["worktree \(worktree.path)", "HEAD \(String(repeating: "a", count: 40))", "branch refs/heads/feature"],
        ])

        let runner = ScriptedGitRunner(listing: listing)
        let scanner = makeScanner(runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        let item = try XCTUnwrap(outcome.items.first, "errors: \(outcome.errors)")
        let reclaim = try plan(of: item)
        XCTAssertEqual(
            reclaim.parentRepoWorkingDir.resolvingSymlinksInPath().path,
            workingTree.resolvingSymlinksInPath().path
        )
        XCTAssertNotEqual(
            reclaim.parentRepoWorkingDir.resolvingSymlinksInPath().path,
            gitDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path,
            "the git directory's PARENT is never the `-C` target"
        )
        // The `-C` target the ladder queried is the first record, not the git
        // directory's parent.
        XCTAssertFalse(
            runner.requests(mentioning: workingTree.path)
                .filter { $0.contains("symbolic-ref") }.isEmpty,
            "requests: \(runner.requests)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    func testSeparateGitDirRepositoryIsAFailClosedNonItemNamingTheMembershipRefusal()
        async throws
    {
        // EMPIRICAL (git 2.50.1): `git worktree list` derives the main record
        // by stripping a `/.git` suffix from the common git directory, so
        // `--separate-git-dir=<external>` reports `<external>` as the first
        // record. The NON-BARE cross-validation finds no `<external>/.git` and
        // membership fails CLOSED — before any containment decision.
        let external = dev.appendingPathComponent("external-gitdir")
        let workingTree = dev.appendingPathComponent("wd")
        try fm.createDirectory(at: workingTree, withIntermediateDirectories: true)
        try GitFixture.git(
            ["-c", "init.defaultBranch=main", "init",
             "--separate-git-dir=\(external.path)", workingTree.path],
            home: home
        )
        try GitFixture.git(
            ["-C", workingTree.path, "-c", "user.name=t", "-c", "user.email=t@t",
             "commit", "--allow-empty", "-m", "x"],
            home: home
        )
        let worktree = dev.appendingPathComponent("wt")
        try GitFixture.git(
            ["-C", workingTree.path, "worktree", "add", worktree.path, "-b", "feature"],
            home: home
        )
        XCTAssertFalse(
            fm.fileExists(atPath: external.appendingPathComponent(".git").path),
            "the external git dir has no `.git` of its own — that is the refusal"
        )

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(
            outcome.items.isEmpty,
            "a separate-git-dir repository yields NO deletable item: \(outcome.items)"
        )
        XCTAssertTrue(
            outcome.errors.contains { issue in
                issue.kind == .unreadable
                    && (issue.detail.contains("could not be attributed")
                        || issue.detail.contains("cross-validated"))
            },
            "the refusal must name the membership failure: \(outcome.errors)"
        )
        try assertNonMalformed(outcome, from: scanner)
    }

    // MARK: - Hand-built fixtures

    /// A repository whose git directory sits somewhere the working tree's path
    /// does not imply, plus one linked worktree — the shape real git will not
    /// produce (its `--separate-git-dir` first record is the external directory
    /// itself). Built exactly as git lays a worktree out: `.git` pointer files
    /// both ways plus a `commondir`.
    private func makeSplitRepository(
        gitDirectory: URL, workingTree: URL, worktree: URL
    ) throws {
        let adminDirectory = gitDirectory.appendingPathComponent("worktrees/wt")
        try fm.createDirectory(at: adminDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: workingTree, withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try write(worktree.appendingPathComponent("payload.bin"), bytes: 8192)

        try "gitdir: \(gitDirectory.path)\n".write(
            to: workingTree.appendingPathComponent(".git"),
            atomically: true, encoding: .utf8
        )
        try "gitdir: \(adminDirectory.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true, encoding: .utf8
        )
        try "\(worktree.appendingPathComponent(".git").path)\n".write(
            to: adminDirectory.appendingPathComponent("gitdir"),
            atomically: true, encoding: .utf8
        )
        try "../..\n".write(
            to: adminDirectory.appendingPathComponent("commondir"),
            atomically: true, encoding: .utf8
        )
    }

    /// The real `--porcelain -z` bytes for one repository — used to prove the
    /// doctored listings above are doctoring a real shape.
    private func listing(of repository: URL) async throws -> Data {
        let runner = makeRunner()
        let invocation = await runner.run(
            GitWorktreeOracle.listArguments(forRepositoryAt: repository)
        )
        guard case .success(let stdout) = invocation.outcome else {
            XCTFail("fixture listing failed: \(invocation.outcome)")
            return Data()
        }
        return stdout
    }
}
