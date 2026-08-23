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

/// Fires a side effect the FIRST time the scanner lstats a named admin
/// ENTRY (`<gitdir>/worktrees/<name>`) once `armed` has been claimed.
///
/// The arming latch is what makes the hook name a window rather than a call:
/// the scanner lstats the same admin entry at DISCOVERY (before any listing)
/// and again inside `process`'s (e2) witness loop (after the listing), and a
/// cell about the second must not fire on the first.
private final class ReplaceOnAdminEntryIdentityProvider: FileSystemIdentityProvider,
    @unchecked Sendable
{
    private let name: String
    private let armed: OneShotLatch
    private let effect: () -> Void

    init(adminEntryNamed name: String, armed: OneShotLatch, effect: @escaping () -> Void) {
        self.name = name
        self.armed = armed
        self.effect = effect
        super.init()
    }

    override func identity(of url: URL) -> Identity? {
        if armed.didFire,
           url.lastPathComponent == name,
           url.deletingLastPathComponent().lastPathComponent
            == GitWorktreeGitdirResolver.adminContainerName
        {
            effect()
        }
        return super.identity(of: url)
    }
}

/// A one-shot latch for an interception closure that must fire EXACTLY once —
/// the scan issues several commands per record, and a fixture that mutated the
/// tree on each of them would be testing a different story every time.
private final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// `true` for the FIRST caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

/// The one-based call index an interception fired at. Read back after the
/// scan, it is what proves WHICH window a fixture entered — a claim a cell
/// about overlapping windows cannot afford to assume.
private final class AtomicIndexBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?

    /// FIRST writer wins, so a fixture that fired twice cannot quietly
    /// re-date itself.
    func store(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        if stored == nil { stored = value }
    }

    /// `-1` when nothing ever fired — never a plausible index.
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? -1
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

    /// D3 (PR #460 codex r3): every stale plan the SCANNER emits carries the
    /// admin directory's scan-time inode, and it is the inode of the entry
    /// the plan names.
    ///
    /// "Unreachable in production" is what this cell used to claim, and that
    /// claim was UNEVIDENCED and false (PR #460 codex r4, D6): the capture
    /// was a bare `provider.identity(of:)`, and an `lstat` failure — EPERM
    /// under a protected root, or the directory vanishing in the
    /// resolve→plan-build window — yielded nil and disarmed the gate
    /// silently. The nil arm is now unreachable BY CONSTRUCTION instead: the
    /// scanner refuses to emit an item it cannot stat the admin directory of
    /// (see `testAnUnstattableAdminEntryIsRefusedRatherThanOfferedUnbound`),
    /// the field carries no default, and R1b refuses a plan without it.
    func testEveryStalePlanCarriesTheAdminEntrysScanTimeIdentity() async throws {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        try addWorktree(of: repository, at: dev.appendingPathComponent("wt-a"), branch: "a")
        try addWorktree(of: repository, at: dev.appendingPathComponent("wt-b"), branch: "b")

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        let provider = FileSystemIdentityProvider()
        var checked = 0
        for item in outcome.items {
            let reclaim = try plan(of: item)
            guard reclaim.mode == .removeStaleWorktree else {
                XCTAssertNil(
                    reclaim.worktreeAdminEntryIdentity,
                    "a prune plan is not about one checkout"
                )
                continue
            }
            let entry = try XCTUnwrap(reclaim.worktreeAdminEntry)
            XCTAssertNotNil(reclaim.worktreeAdminEntryIdentity, entry.path)
            XCTAssertEqual(
                reclaim.worktreeAdminEntryIdentity, provider.identity(of: entry),
                "the carried identity must be \(entry.path)'s own"
            )
            checked += 1
        }
        XCTAssertEqual(checked, 2, "both stale candidates were inspected")
        try assertNonMalformed(outcome, from: scanner)
    }

    func testAnUnstattableAdminEntryIsRefusedRatherThanOfferedUnbound()
        async throws
    {
        // D6 (PR #460 codex r4). The scan-time capture used to be a bare
        // `provider.identity(of: adminEntry)` with no `guard let`, so an
        // `lstat` failure — EPERM under a protected root, or the directory
        // vanishing between the resolve and the plan build — produced a plan
        // whose delete-time identity gate was silently INERT. Two universals
        // asserted that could not happen and neither was evidenced.
        //
        // The double here is LESS capable than production, never more: it
        // reports exactly one path as unidentifiable and delegates everything
        // else, which is what an `lstat` denial on that one directory looks
        // like.
        //
        // MUTATION: restore the bare capture (drop the `guard let` in
        // `emitStaleCandidate`) and this cell goes RED — an item is offered
        // carrying no identity at all.
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let worktree = try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt-a"), branch: "a"
        )
        let adminEntry = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: worktree),
            "the fixture must have a resolvable admin directory"
        )

        let outcome = await makeScanner(
            provider: BlindToOnePathProvider(blinded: adminEntry)
        ).scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(
            outcome.items.allSatisfy { item in
                if case .gitWorktreeReclaim(let plan) = item.action {
                    return plan.mode != .removeStaleWorktree
                }
                return true
            },
            "a stale item was offered for a checkout whose admin directory "
                + "could not be identified: \(outcome.items.map(\.displayName))"
        )
        let issue = try XCTUnwrap(
            outcome.errors.first { $0.detail.contains("could not be identified") },
            "the refusal must be visible, not silent: \(outcome.errors)"
        )
        XCTAssertEqual(issue.kind, .unreadable)
        XCTAssertTrue(issue.detail.contains("no item is offered"), issue.detail)
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }

    func testASamePathReplacementInheritsTheItemIdAndIsACandidateAtOnce()
        async throws
    {
        // D4 (PR #460 codex r4). Four places — CHANGELOG.md,
        // docs/v1/CATEGORIES.md, the R1b doc in `WorktreeReclaimPerformer`
        // and 26e8bdf's own commit message — claimed `--cli clean` is
        // protected from a same-path replacement because its in-process
        // re-scan answers one with "Unknown item id … rescan and retry".
        // THIS CELL IS THE FALSIFICATION, run rather than reasoned:
        //
        //   (a) item ids are `SHA256(scannerID + NUL + canonicalPath)`, so a
        //       replacement AT THE SAME PATH gets the SAME id;
        //   (b) candidacy is "all four gates pass" with NO age term, so a
        //       brand-new `git worktree add` on a merged branch is a
        //       candidate the instant it exists.
        //
        // The CLI is therefore exposed to the same class by a different
        // route, and the corrected claim in those four places is that its
        // re-scan RE-JUDGES the path rather than DETECTING the substitution.
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let path = dev.appendingPathComponent("wt-a")
        try addWorktree(of: repository, at: path, branch: "a")

        let firstScan = await makeScanner()
            .scan(context: ScanContext(trigger: .userInitiated))
        let before = try XCTUnwrap(
            firstScan.items.first { $0.url?.path.hasSuffix("/wt-a") == true },
            "the fixture must produce a stale candidate"
        )

        // The user retires it themselves and adds a NEW checkout at the same
        // path — a different branch, a different admin directory, seconds old.
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", repository.path, "worktree", "remove", path.path],
                home: home
            ).status, 0
        )
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", repository.path, "worktree", "add", path.path, "-b", "brand-new"],
                home: home
            ).status, 0
        )

        let secondScan = await makeScanner()
            .scan(context: ScanContext(trigger: .userInitiated))
        let after = try XCTUnwrap(
            secondScan.items.first { $0.url?.path.hasSuffix("/wt-a") == true },
            "the replacement is a candidate the instant it exists — there is "
                + "no age term in candidacy"
        )
        XCTAssertEqual(
            after.id, before.id,
            "the replacement inherits the assessed checkout's item id, so "
                + "`--cli clean <id>` resolves to it and no 'unknown item id' "
                + "is ever produced"
        )
        XCTAssertNotEqual(
            try plan(of: after).worktreeAdminEntryIdentity,
            try plan(of: before).worktreeAdminEntryIdentity,
            "…while it is provably a different checkout: the re-scan JUDGED "
                + "the replacement, it did not DETECT the substitution"
        )
    }

    /// N1 (PR #460 codex r14). The identity the delete-time gate is armed
    /// with used to be captured AFTER `assessor.assess` returned. Its guard
    /// was written against `lstat` FAILING — "the directory vanishing between
    /// the resolve above and the plan build" — and never considered the case
    /// where `lstat` SUCCEEDS and answers about a DIFFERENT object.
    ///
    /// So a worktree removed and re-added at the SAME path inside the
    /// assessment window produced an item whose `record` and
    /// `assessment.evidence` describe the ORIGINAL checkout while its armed
    /// identity is the REPLACEMENT's. R1b then compares the live admin inode
    /// against that identity, both are the replacement, they MATCH, and the
    /// gate passes — the GUI deletes a brand-new checkout, ignored content
    /// and all, on the strength of a row the user read about the old one.
    ///
    /// The window is entered through the assessor's LAST command for a
    /// candidate (`show -s --format=%ct HEAD`, display-only): every gate has
    /// already answered about the original when the replacement lands.
    ///
    /// MUTATION A (the re-proof): delete the `guard let assessmentWitness,
    /// assessmentWitness == adminEntryIdentity` block in `handle` — RED here
    /// (2/2 at r15).
    /// MUTATION B (the capture): re-take the witness inside `handle`, below
    /// `await assessor.assess(...)`, so it witnesses the post-assessment
    /// world — the comparison becomes a tautology and this cell goes RED too.
    ///
    /// r15 note: the capture itself now lives at `process`'s (e2), one window
    /// EARLIER than this cell needs — so moving it back to the top of
    /// `handle` (r14's own spelling) leaves this cell GREEN and reddens only
    /// the S-P1 cell below. That asymmetry is what tells the two windows
    /// apart; neither cell subsumes the other.
    func testAWorktreeReplacedInsideItsAssessmentWindowIsRefusedRatherThanOffered()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let path = dev.appendingPathComponent("wt-a")
        try addWorktree(of: repository, at: path, branch: "a")

        let identityProvider = FileSystemIdentityProvider()
        let originalAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: path),
            "the fixture must have a resolvable admin directory"
        )
        let originalIdentity = try XCTUnwrap(identityProvider.identity(of: originalAdmin))

        let latch = OneShotLatch()
        let fixtureHome = try XCTUnwrap(home)
        let runner = InterceptingGitRunner(wrapping: makeRunner()) { arguments, _ in
            guard arguments.contains("show"),
                  arguments.contains(where: { $0.hasSuffix("/wt-a") }),
                  latch.claim()
            else { return nil }
            // The developer retires the worktree and creates a fresh one at
            // the same path while the scan is still running. REAL git, real
            // removal, real re-add — the admin entry is destroyed and
            // recreated, so its inode genuinely changes.
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "remove", path.path],
                home: fixtureHome
            )
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "add", path.path, "-b", "brand-new"],
                home: fixtureHome
            )
            // nil = delegate: the real `show` now runs against the replacement,
            // exactly as it would in the field.
            return nil
        }

        let scanner = makeScanner(runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(
            latch.didFire, "the fixture never entered the assessment window"
        )
        let replacementAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: path),
            "the replacement must itself be a well-formed linked worktree"
        )
        XCTAssertNotEqual(
            identityProvider.identity(of: replacementAdmin), originalIdentity,
            "the fixture must have replaced the OBJECT, not merely the path"
        )

        let offered = try outcome.items.filter { item in
            guard case .gitWorktreeReclaim = item.action else { return false }
            let reclaim = try plan(of: item)
            return reclaim.mode == .removeStaleWorktree
                && reclaim.worktreePath?.path.hasSuffix("/wt-a") == true
        }
        let armed = try offered.first.map { try plan(of: $0).worktreeAdminEntryIdentity }
        XCTAssertTrue(
            offered.isEmpty,
            "an item was offered for a checkout that was replaced mid-assessment; "
                + "its armed identity is \(String(describing: armed)) while the "
                + "assessed checkout's was \(originalIdentity)"
        )
        let issue = try XCTUnwrap(
            outcome.errors.first { $0.detail.contains("replaced") },
            "the refusal must be visible, not silent: \(outcome.errors)"
        )
        XCTAssertEqual(issue.kind, .unreadable)
        XCTAssertTrue(issue.detail.contains("no item is offered"), issue.detail)
        // The replacement is left entirely alone — the scan refuses it, it
        // does not touch it.
        XCTAssertTrue(fm.fileExists(atPath: path.path))
        try assertNonMalformed(outcome, from: scanner)
    }

    /// S-P1 (PR #460 codex r15). r14's N1 witness spanned `assessor.assess`
    /// ONLY. It was captured at the top of `handle(record:)` — which is AFTER
    /// the ONE `git worktree list` that produced `record`, and after every
    /// EARLIER record's whole assessment. A `git worktree remove` + `git
    /// worktree add <same path>` landing in THAT stretch left every later read
    /// describing the REPLACEMENT: `worktreeIdentity`, `resolver.membership`,
    /// `sameLocation`, the witness and the re-proof alike — so the re-proof
    /// compared the replacement with itself and passed.
    ///
    /// The record is the stale half, and it is load-bearing: G1 ("linked (not
    /// main/bare)"), G4 ("not locked") and the detached/HEAD clause of the
    /// evidence are read off the LISTING, never re-read. So the row names a
    /// checkout that no longer exists while the plan is armed with the NEW
    /// one's inode; R1b then compares the live inode against that identity,
    /// both are the replacement, they match, and the deletion takes a
    /// brand-new checkout with whatever ignored content it already carries.
    ///
    /// The window is entered through an EARLIER record's assessment — the one
    /// production-reachable seam between the listing and the witness. Records
    /// are listed in admin-directory name order (git 2.50.1, verified), so
    /// `wt-a` is assessed while `wt-z` is still nothing but a row from the
    /// listing; the cell asserts that ordering rather than assuming it.
    ///
    /// MUTATION (the widened capture): move the capture back into `handle` —
    /// RED here and GREEN on the r14 cell above, which is exactly what
    /// distinguishes the two windows.
    func testAWorktreeReplacedBetweenTheListingAndItsAssessmentIsRefusedRatherThanOffered()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        // `wt-a` is assessed FIRST and is only the trigger; `wt-z` is the
        // target, replaced while `wt-a` is still being assessed.
        let trigger = try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt-a"), branch: "a"
        )
        let target = dev.appendingPathComponent("wt-z")
        try addWorktree(of: repository, at: target, branch: "z")

        let identityProvider = FileSystemIdentityProvider()
        let originalAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: target),
            "the fixture must have a resolvable admin directory"
        )
        let originalIdentity = try XCTUnwrap(identityProvider.identity(of: originalAdmin))

        let latch = OneShotLatch()
        let interceptionIndex = AtomicIndexBox()
        let fixtureHome = try XCTUnwrap(home)
        let payload = target.appendingPathComponent("payload.bin")
        let runner = InterceptingGitRunner(wrapping: makeRunner()) { arguments, index in
            guard arguments.contains("show"),
                  arguments.contains(where: { $0.hasSuffix("/wt-a") }),
                  latch.claim()
            else { return nil }
            interceptionIndex.store(index)
            // The developer retires `wt-z` and creates a fresh checkout at the
            // same path, then writes 8 KiB of ignored content into it — REAL
            // git, so the admin entry is genuinely destroyed and recreated.
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "remove", target.path],
                home: fixtureHome
            )
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "add", target.path, "-b", "brand-new"],
                home: fixtureHome
            )
            try? Data(repeating: 0xCD, count: 8192).write(to: payload)
            return nil // delegate: `wt-a`'s own `show` still runs for real
        }

        let scanner = makeScanner(runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(latch.didFire, "the fixture never entered the window")
        let replacementAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: target),
            "the replacement must itself be a well-formed linked worktree"
        )
        XCTAssertNotEqual(
            identityProvider.identity(of: replacementAdmin), originalIdentity,
            "the fixture must have replaced the OBJECT, not merely the path"
        )
        // THE WINDOW THIS CELL IS ABOUT: the replacement landed after the ONE
        // listing and BEFORE the first command ever issued about `wt-z`.
        let firstTargetCall = try XCTUnwrap(
            runner.argvs.firstIndex { argv in
                argv.contains { $0.hasSuffix("/wt-z") }
            },
            "no command ever mentioned the target: \(runner.argvs)"
        ) + 1 // `argvs` is 0-based; the interception index is 1-based
        XCTAssertGreaterThan(
            firstTargetCall, interceptionIndex.value,
            "the fixture replaced the target AFTER its assessment began, so it "
                + "exercises r14's window and not this one: \(runner.argvs)"
        )
        XCTAssertEqual(
            runner.argvs.filter { $0.contains("list") }.count, 1,
            "the ONE listing per repository — the record's only source"
        )

        let stale = try outcome.items.filter { item in
            guard case .gitWorktreeReclaim = item.action else { return false }
            return try plan(of: item).mode == .removeStaleWorktree
        }
        let offered = try stale.filter {
            try plan(of: $0).worktreePath?.path.hasSuffix("/wt-z") == true
        }
        let armed = try offered.first.map { try plan(of: $0).worktreeAdminEntryIdentity }
        XCTAssertTrue(
            offered.isEmpty,
            "an item was offered for a checkout that was replaced between the "
                + "listing and its assessment; its armed identity is "
                + "\(String(describing: armed)) while the listed checkout's was "
                + "\(originalIdentity)"
        )
        let issue = try XCTUnwrap(
            outcome.errors.first {
                $0.detail.contains("replaced") && $0.detail.contains("/wt-z")
            },
            "the refusal must be visible, not silent: \(outcome.errors)"
        )
        XCTAssertEqual(issue.kind, .unreadable)
        XCTAssertTrue(issue.detail.contains("no item is offered"), issue.detail)

        // THE CONTROL: widening the witness refuses the REPLACED record only.
        // The untouched sibling is still offered on its own evidence.
        XCTAssertEqual(
            try stale.compactMap { try plan(of: $0).worktreePath?.lastPathComponent },
            ["wt-a"],
            "the sibling that was never replaced must still be offered"
        )
        // The replacement and the 8 KiB the user wrote into it are left alone.
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        XCTAssertEqual(
            try Data(contentsOf: payload).count, 8192,
            "the scan refuses the replacement; it never touches it"
        )
        XCTAssertTrue(fm.fileExists(atPath: trigger.path))
        try assertNonMalformed(outcome, from: scanner)
    }


    /// B-P1 (PR #460 codex r16). r15 moved the witness capture out of
    /// `handle` and into `process`'s (e2) — AFTER the one `git worktree list`
    /// that produces the records. The code, the CHANGELOG and
    /// `docs/v1/CATEGORIES.md` all then said the binding "spans the scan's own
    /// window", and that the only uncovered sliver was inside the listing
    /// command itself, answered at delete time by R1b.
    ///
    /// MEASURED FALSE, and this cell is the falsification. The replacement
    /// here lands the INSTANT the listing returned — the scanner has not yet
    /// read a single admin inode — and every read the scan makes afterwards
    /// (the (e2) witness, the membership, the re-proof) describes the
    /// REPLACEMENT, while `record` (G1, G4 and the detached/HEAD clause of the
    /// evidence, all read off the listing and never re-read) still describes
    /// the checkout that is gone. Before the fix: `items` carried the row,
    /// `errors` was silent, and the armed identity was the replacement's — so
    /// the delete-time gate agreed with itself and destroyed a brand-new
    /// checkout together with its ignored payload.
    ///
    /// R1b CANNOT answer this: the identity R1b re-stats against is the very
    /// one poisoned here, so both sides of its comparison are the
    /// replacement. That claim is retired in code, CHANGELOG and docs by the
    /// same commit as this cell.
    ///
    /// The fix is a witness taken at DISCOVERY — `repositoryGroups` resolves
    /// every linked checkout's `<wt>/.git` before any listing runs, so the
    /// identity is captured on the far side of the listing from the (e2) one.
    ///
    /// MUTATION (the discovery capture): drop the `discoveryWitness` guard in
    /// `handle`, or stop populating `RepositoryGroup.discoveryWitnesses` —
    /// RED here, GREEN on the r14/r15 cells above, which is what tells this
    /// window from theirs.
    func testAWorktreeReplacedTheInstantTheListingReturnedIsRefusedRatherThanOffered()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let target = dev.appendingPathComponent("wt-a")
        try addWorktree(of: repository, at: target, branch: "a")

        let identityProvider = FileSystemIdentityProvider()
        let originalAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: target),
            "the fixture must have a resolvable admin directory"
        )
        let originalIdentity = try XCTUnwrap(identityProvider.identity(of: originalAdmin))

        let latch = OneShotLatch()
        let fixtureHome = try XCTUnwrap(home)
        let payload = target.appendingPathComponent("payload.bin")
        let runner = InterceptingGitRunner(wrapping: makeRunner()) { arguments, _ in
            guard arguments.contains("list"), latch.claim() else { return nil }
            // THE ONE LISTING, run for real by the FIXTURE and handed back
            // VERBATIM — so the scanner's records describe the ORIGINAL
            // checkout...
            guard let listed = try? GitFixture.git(arguments, home: fixtureHome),
                  listed.status == 0
            else { return nil }
            // ...and the developer's replacement lands the instant it
            // returned, before the scan has read one admin inode. REAL git:
            // the admin entry is genuinely destroyed and recreated.
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "remove", target.path],
                home: fixtureHome
            )
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "add", target.path, "-b", "brand-new"],
                home: fixtureHome
            )
            try? Data(repeating: 0xCD, count: 8192).write(to: payload)
            return .success(stdout: listed.stdout)
        }

        let scanner = makeScanner(runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(latch.didFire, "the fixture never intercepted the listing")
        XCTAssertEqual(
            runner.argvs.filter { $0.contains("list") }.count, 1,
            "the ONE listing per repository — the record's only source"
        )
        let replacementAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: target),
            "the replacement must itself be a well-formed linked worktree"
        )
        XCTAssertNotEqual(
            identityProvider.identity(of: replacementAdmin), originalIdentity,
            "the fixture must have replaced the OBJECT, not merely the path"
        )

        let offered = try outcome.items.filter { item in
            guard case .gitWorktreeReclaim = item.action else { return false }
            let reclaim = try plan(of: item)
            return reclaim.mode == .removeStaleWorktree
                && reclaim.worktreePath?.path.hasSuffix("/wt-a") == true
        }
        let armed = try offered.first.map { try plan(of: $0).worktreeAdminEntryIdentity }
        XCTAssertTrue(
            offered.isEmpty,
            "an item was offered for a checkout replaced the instant the "
                + "listing returned; its armed identity is "
                + "\(String(describing: armed)) while the LISTED checkout's "
                + "was \(originalIdentity)"
        )
        // SILENCE IS THE DEFECT, not a lesser form of it.
        let issue = try XCTUnwrap(
            outcome.errors.first {
                $0.detail.contains("replaced") && $0.detail.contains("/wt-a")
            },
            "the refusal must be VISIBLE, not a silent omission: \(outcome.errors)"
        )
        XCTAssertEqual(issue.kind, .unreadable)
        XCTAssertTrue(issue.detail.contains("no item is offered"), issue.detail)
        // The replacement and the 8 KiB written into it are left alone.
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: payload).count, 8192)
        try assertNonMalformed(outcome, from: scanner)
    }

    /// B-P2 (PR #460 codex r16). The second half of the same measurement:
    /// r15 called the uncovered window "a sliver inside the listing command,
    /// bounded by one git process's own runtime". It is not bounded by that.
    /// (e2) walks EVERY assessable record of the repository, paying one
    /// `adminDirectory` read plus one `identity` lstat each, so the window
    /// grows with the worktree count — in the very loop r15's fix added.
    ///
    /// This cell enters the window through an EARLIER record's admin-entry
    /// lstat: the provider fires the replacement of `wt-z` while (e2) is
    /// witnessing `wt-a`, after the listing has returned and before any
    /// assessment has started. No git command has yet mentioned `wt-z`.
    ///
    /// MUTATION (the discovery capture): the same one the B-P1 cell names —
    /// RED here too. Both cells are needed: B-P1 proves the boundary moved to
    /// the far side of the listing, this one proves the (e2) loop itself is
    /// inside the covered span.
    func testAWorktreeReplacedInsideTheWitnessLoopIsRefusedRatherThanOffered()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        // Records are listed in admin-directory name order, so `wt-a` is
        // witnessed first and `wt-z` is still nothing but a row from the
        // listing when the replacement lands. The cell asserts that ordering
        // below rather than assuming it.
        let trigger = try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt-a"), branch: "a"
        )
        let target = dev.appendingPathComponent("wt-z")
        try addWorktree(of: repository, at: target, branch: "z")

        let identityProvider = FileSystemIdentityProvider()
        let originalAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: target),
            "the fixture must have a resolvable admin directory"
        )
        let originalIdentity = try XCTUnwrap(identityProvider.identity(of: originalAdmin))

        let listingReturned = OneShotLatch()
        let listingLatch = OneShotLatch()
        let replaced = OneShotLatch()
        let fixtureHome = try XCTUnwrap(home)
        let payload = target.appendingPathComponent("payload.bin")

        let runner = InterceptingGitRunner(wrapping: makeRunner()) { arguments, _ in
            guard arguments.contains("list"), listingLatch.claim() else { return nil }
            guard let listed = try? GitFixture.git(arguments, home: fixtureHome),
                  listed.status == 0
            else { return nil }
            // The listing has RETURNED — everything after this line runs in
            // the window (e2) opens.
            _ = listingReturned.claim()
            return .success(stdout: listed.stdout)
        }

        let provider = ReplaceOnAdminEntryIdentityProvider(
            adminEntryNamed: "wt-a", armed: listingReturned
        ) {
            guard replaced.claim() else { return }
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "remove", target.path],
                home: fixtureHome
            )
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "add", target.path, "-b", "brand-new"],
                home: fixtureHome
            )
            try? Data(repeating: 0xCD, count: 8192).write(to: payload)
        }

        let scanner = makeScanner(runner: runner, provider: provider)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(listingReturned.didFire, "the fixture never saw the listing return")
        XCTAssertTrue(
            replaced.didFire,
            "the fixture never entered the witness loop: \(runner.argvs)"
        )
        let replacementAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: target),
            "the replacement must itself be a well-formed linked worktree"
        )
        XCTAssertNotEqual(
            identityProvider.identity(of: replacementAdmin), originalIdentity,
            "the fixture must have replaced the OBJECT, not merely the path"
        )
        // THE WINDOW: no command had yet been issued about the target when
        // the replacement landed — the whole exchange is inside (e2).
        XCTAssertEqual(
            runner.argvs.filter { $0.contains("list") }.count, 1,
            "the ONE listing per repository"
        )
        XCTAssertEqual(
            runner.argvs.first, ["git", "-c", GitCommandRunner.fsmonitorNeutralization]
                + GitWorktreeOracle.listArguments(forRepositoryAt: repository),
            "the listing must be the FIRST command, so the replacement fired "
                + "before any assessment: \(runner.argvs)"
        )

        let stale = try outcome.items.filter { item in
            guard case .gitWorktreeReclaim = item.action else { return false }
            return try plan(of: item).mode == .removeStaleWorktree
        }
        let offered = try stale.filter {
            try plan(of: $0).worktreePath?.path.hasSuffix("/wt-z") == true
        }
        let armed = try offered.first.map { try plan(of: $0).worktreeAdminEntryIdentity }
        XCTAssertTrue(
            offered.isEmpty,
            "an item was offered for a checkout replaced inside the witness "
                + "loop; its armed identity is \(String(describing: armed)) "
                + "while the listed checkout's was \(originalIdentity)"
        )
        let issue = try XCTUnwrap(
            outcome.errors.first {
                $0.detail.contains("replaced") && $0.detail.contains("/wt-z")
            },
            "the refusal must be VISIBLE, not a silent omission: \(outcome.errors)"
        )
        XCTAssertEqual(issue.kind, .unreadable)
        XCTAssertTrue(issue.detail.contains("no item is offered"), issue.detail)
        // THE CONTROL: only the replaced record is refused.
        XCTAssertEqual(
            try stale.compactMap { try plan(of: $0).worktreePath?.lastPathComponent },
            ["wt-a"],
            "the sibling that was never replaced must still be offered"
        )
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: payload).count, 8192)
        XCTAssertTrue(fm.fileExists(atPath: trigger.path))
        try assertNonMalformed(outcome, from: scanner)
    }



    /// B-P4 (PR #460 codex r16). (e2) leaves a record unwitnessed when
    /// `adminDirectory` or `identity` returns nil — EPERM, a momentary vanish
    /// — and if both succeed again by the time `handle` runs, the record
    /// reached the re-proof with `assessmentWitness == nil`. The user was
    /// then told the worktree "was replaced while this scan was running …
    /// the evidence belongs to a checkout that is gone", for what was a
    /// transient stat failure: a different cause with a different remedy
    /// (nothing was replaced, and nothing about the checkout needs
    /// re-judging).
    ///
    /// The pre-existing `adminEntryIdentity` guard already had the honest
    /// wording — "lstat failed … the delete-time gate … could not be armed" —
    /// and this arm now carries it too. BOTH arms suppress the item, so this
    /// is message correctness, not a safety hole, and the cell asserts the
    /// suppression as well so a future edit cannot buy the wording by
    /// offering the item.
    ///
    /// The double fails the THIRD `identity` call for the admin entry: the
    /// first is the discovery capture, the second is (a2)'s admin-container
    /// pass (PR #460 codex r17, W1), the third is (e2)'s, the fourth is the
    /// live one in `handle`. Its call counter is asserted so a re-ordering of
    /// those captures cannot leave this cell exercising a different arm — and
    /// it did exactly that job when r17 inserted (a2): the counter went red
    /// and the cell had to be re-aimed rather than silently drifting onto the
    /// container pass.
    ///
    /// MUTATION: collapse this arm back into the re-proof's `guard let
    /// assessmentWitness, assessmentWitness == adminEntryIdentity` — RED
    /// here, GREEN everywhere else.
    func testATransientLstatFailureAtTheWitnessLoopIsNotReportedAsAReplacement()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let worktree = try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt-a"), branch: "a"
        )
        let adminEntry = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: worktree),
            "the fixture must have a resolvable admin directory"
        )

        let provider = BlindOnNthIdentityCallProvider(blinded: adminEntry, onCall: 3)
        let outcome = await makeScanner(provider: provider)
            .scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertEqual(
            provider.calls, 5,
            "the admin entry is identified five times — discovery, (a2)'s "
                + "pre-listing admin-container pass, the witness loop, the "
                + "live read in `handle`, and the prune tier's admin-container "
                + "mapping; this cell names the THIRD and cannot be read if "
                + "that ordering changes"
        )
        // Suppression is unchanged: an unwitnessed record is never armed.
        XCTAssertTrue(
            try outcome.items.allSatisfy { try plan(of: $0).mode != .removeStaleWorktree },
            "a stale item was offered for an unwitnessed checkout: "
                + "\(outcome.items.map(\.displayName))"
        )
        let issue = try XCTUnwrap(
            outcome.errors.first { $0.url?.lastPathComponent == "wt-a" },
            "the refusal must be visible, not silent: \(outcome.errors)"
        )
        XCTAssertFalse(
            issue.detail.contains("replaced"),
            "a transient lstat failure is reported as a REPLACEMENT — a "
                + "different cause with a different remedy: \(issue.detail)"
        )
        XCTAssertTrue(issue.detail.contains("lstat failed"), issue.detail)
        XCTAssertTrue(issue.detail.contains("could not be armed"), issue.detail)
        XCTAssertTrue(issue.detail.contains("no item is offered"), issue.detail)
        XCTAssertEqual(issue.kind, .unreadable)
        XCTAssertTrue(fm.fileExists(atPath: worktree.path))
    }



    // MARK: - W1: the walk's depth budget must not decide what is reclaimable

    /// W1 (PR #460 codex r17). r16's `guard let discoveryWitness` refuses any
    /// porcelain-listed worktree the WALK never reached, and its comment said
    /// "It CLEARS: the next scan re-walks." For the DEPTH cause that sentence
    /// was false: `discoveryWitnesses` was populated only from walk
    /// discoveries, the walk is bounded by `ProjectTreeWalker.defaultMaxDepth`
    /// (8), no production call site overrides it and no user setting reaches
    /// it — so every future scan re-walked to the same depth and refused
    /// again. A deterministic bound cannot be cleared by the remedy the
    /// refusal named.
    ///
    /// This fixture straddles the bound inside ONE repository: `dev` is depth
    /// 0, the deepest directory the walk VISITS is depth 8, so `wt-edge` (8)
    /// is walked and `wt-deep` (9) never is. Both are ordinary candidates and
    /// git lists both.
    ///
    /// MEASURED at e6afc9f: `wt-edge` offered, `wt-deep` refused, byte-identical
    /// across three consecutive scans. The three scans are part of the cell
    /// because permanence — not the refusal — is the defect.
    ///
    /// MUTATION: delete the admin-container witness pass in `process` (a2), or
    /// stop consulting `containerWitnesses` in (e2) — RED here, GREEN on every
    /// replacement cell above.
    func testAWorktreeBelowTheWalksDepthBudgetIsOfferedOnEveryScan() async throws {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let shallowPrefix = "l1/l2/l3/l4/l5/l6/l7"
        let edge = try addWorktree(
            of: repository,
            at: dev.appendingPathComponent("\(shallowPrefix)/wt-edge"),
            branch: "edge"
        )
        let deep = try addWorktree(
            of: repository,
            at: dev.appendingPathComponent("\(shallowPrefix)/l8/wt-deep"),
            branch: "deep"
        )

        // The fixture must actually straddle the bound, or the cell proves
        // nothing: the walk sees `wt-edge`'s `.git` and never sees `wt-deep`'s.
        var walked: Set<String> = []
        let walker = ProjectTreeWalker(
            home: home,
            pathGuard: PathGuard(
                home: home, containerRoots: [dev],
                provider: FileSystemIdentityProvider()
            ),
            provider: FileSystemIdentityProvider()
        )
        _ = walker.walk(roots: [dev], consumers: [{ event in
            walked.insert(event.directory.path)
            return []
        }])
        XCTAssertTrue(
            walked.contains(edge.path),
            "the depth-8 control must be inside the walk's budget"
        )
        XCTAssertFalse(
            walked.contains(deep.path),
            "the depth-9 subject must be OUTSIDE the walk's budget — the "
                + "fixture no longer straddles `defaultMaxDepth`"
        )

        let liveAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: deep)
        )
        let liveIdentity = try XCTUnwrap(
            FileSystemIdentityProvider().identity(of: liveAdmin)
        )

        // THREE consecutive scans of an UNCHANGED tree. A refusal that a
        // re-scan cannot clear reproduces identically every time; that is the
        // property this asserts, and it is the one r16 shipped false.
        for attempt in 1...3 {
            let scanner = makeScanner()
            let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))
            let stale = try outcome.items.filter {
                guard case .gitWorktreeReclaim = $0.action else { return false }
                return try plan(of: $0).mode == .removeStaleWorktree
            }
            XCTAssertEqual(
                try stale.compactMap { try plan(of: $0).worktreePath?.lastPathComponent }
                    .sorted(),
                ["wt-deep", "wt-edge"],
                "scan \(attempt): the walk's depth budget decided what is "
                    + "reclaimable — git listed both worktrees and both are "
                    + "candidates. Issues: \(outcome.errors.map(\.detail))"
            )
            let deepItem = try XCTUnwrap(stale.first {
                try plan(of: $0).worktreePath?.lastPathComponent == "wt-deep"
            })
            XCTAssertEqual(
                try plan(of: deepItem).worktreeAdminEntryIdentity, liveIdentity,
                "scan \(attempt): the walk-unreached checkout must be armed "
                    + "with its OWN admin entry's identity"
            )
            XCTAssertFalse(
                outcome.errors.contains { $0.detail.contains("wt-deep") },
                "scan \(attempt): \(outcome.errors.map(\.detail))"
            )
            try assertNonMalformed(outcome, from: scanner)
        }
    }

    /// W1's other half (PR #460 codex r17). The walk-unreached population is
    /// no longer refused, so the thing that must be proved is that it is not
    /// merely WAIVED: the identity it is armed with has to be one taken
    /// BEFORE the listing that produced its evidence, or the fix would be a
    /// hole rather than a witness.
    ///
    /// Both subjects here are checkouts the walk cannot reach. ONE of them is
    /// replaced the instant the listing returns, exactly as the B-P1 cell
    /// does for a walked one. The pre-listing capture is the admin-container
    /// pass at (a2); the assessment capture at (e2) and the live one in
    /// `handle` both see the replacement, so the three-way re-proof disagrees
    /// and that row alone is refused.
    ///
    /// THE UNTOUCHED SIBLING IS THE DISCRIMINATOR, and it is why this cell is
    /// not satisfiable by the strand it replaces: a refusal that fires on the
    /// walk-unreached POPULATION refuses both, and no wording of it can
    /// offer `wt-keep`. Asserting "an issue mentioning wt-deep exists" alone
    /// would have passed at e6afc9f — MEASURED, which is how this cell came
    /// to be written this way.
    ///
    /// MUTATION: take the container witnesses AFTER the listing instead of
    /// before it — RED here, GREEN on the cell above.
    func testAWalkUnreachedWorktreeReplacedTheInstantTheListingReturnedIsRefused()
        async throws
    {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        let prefix = "l1/l2/l3/l4/l5/l6/l7/l8"
        let keep = try addWorktree(
            of: repository,
            at: dev.appendingPathComponent("\(prefix)/wt-keep"),
            branch: "keep"
        )
        let deep = try addWorktree(
            of: repository,
            at: dev.appendingPathComponent("\(prefix)/wt-deep"),
            branch: "deep"
        )

        let identityProvider = FileSystemIdentityProvider()
        let originalAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: deep)
        )
        let originalIdentity = try XCTUnwrap(identityProvider.identity(of: originalAdmin))

        let latch = OneShotLatch()
        let fixtureHome = try XCTUnwrap(home)
        let payload = deep.appendingPathComponent("payload.bin")
        let runner = InterceptingGitRunner(wrapping: makeRunner()) { arguments, _ in
            guard arguments.contains("list"), latch.claim() else { return nil }
            guard let listed = try? GitFixture.git(arguments, home: fixtureHome),
                  listed.status == 0
            else { return nil }
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "remove", deep.path],
                home: fixtureHome
            )
            _ = try? GitFixture.git(
                ["-C", repository.path, "worktree", "add", deep.path, "-b", "brand-new"],
                home: fixtureHome
            )
            try? Data(repeating: 0xCD, count: 8192).write(to: payload)
            return .success(stdout: listed.stdout)
        }

        let scanner = makeScanner(runner: runner)
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))

        XCTAssertTrue(latch.didFire, "the fixture never intercepted the listing")
        let replacementAdmin = try XCTUnwrap(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: deep)
        )
        XCTAssertNotEqual(
            identityProvider.identity(of: replacementAdmin), originalIdentity,
            "the fixture must have replaced the OBJECT, not merely the path"
        )

        let stale = try outcome.items.filter {
            guard case .gitWorktreeReclaim = $0.action else { return false }
            return try plan(of: $0).mode == .removeStaleWorktree
        }
        let armed = try stale.first {
            try plan(of: $0).worktreePath?.lastPathComponent == "wt-deep"
        }.map { try plan(of: $0).worktreeAdminEntryIdentity }
        XCTAssertEqual(
            try stale.compactMap { try plan(of: $0).worktreePath?.lastPathComponent }
                .sorted(),
            ["wt-keep"],
            "the replaced checkout must be refused and the untouched sibling "
                + "must still be offered — armed identity for wt-deep was "
                + "\(String(describing: armed)) while the LISTED checkout's "
                + "was \(originalIdentity). Issues: \(outcome.errors.map(\.detail))"
        )
        let issue = try XCTUnwrap(
            outcome.errors.first { $0.detail.contains("/wt-deep") },
            "the refusal must be VISIBLE, not a silent omission: \(outcome.errors)"
        )
        XCTAssertEqual(issue.kind, .unreadable)
        XCTAssertTrue(issue.detail.contains("no item is offered"), issue.detail)
        XCTAssertTrue(fm.fileExists(atPath: deep.path))
        XCTAssertTrue(fm.fileExists(atPath: keep.path))
        XCTAssertEqual(try Data(contentsOf: payload).count, 8192)
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
        // injected — a record the disclosure cannot account for is exactly
        // what D14 forbids disclosing around.
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
        // 2.50.1, so the LOCKED+PRUNABLE combination is INJECTED — which is
        // also why the filter is defence in depth rather than a live guard.
        // It must be excluded from the disclosure WITHOUT suppressing the
        // item, because the removal set is the mapper's output and a locked
        // entry is not in it. (The old reason given here — "git's own prune
        // skips locked admin directories" — is retired: the repository-wide
        // prune no longer runs at all, so nothing downstream would skip
        // anything; PR #460 codex r3 / D4.)
        let firstOrphan = try XCTUnwrapElement(orphans, 0)
        let secondOrphan = try XCTUnwrapElement(orphans, 1)
        let doctored = Self.porcelain([
            ["worktree \(repository.resolvingSymlinksInPath().path)", "HEAD \(String(repeating: "0", count: 40))", "branch refs/heads/main"],
            ["worktree \(firstOrphan.resolvingSymlinksInPath().path)", "HEAD \(String(repeating: "0", count: 40))", "detached", "prunable gitdir file points to non-existent location"],
            ["worktree \(secondOrphan.resolvingSymlinksInPath().path)", "HEAD \(String(repeating: "0", count: 40))", "detached", "locked in use elsewhere", "prunable gitdir file points to non-existent location"],
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

    /// ONE implementation, two call sites (fn-5.4's delete-time recompute is
    /// the other). A second mapping would let detection and execution
    /// disagree about which admin directories are destroyed.
    ///
    /// THROUGH r16 THIS WAS A LITERAL BAN on the string `contentsOfDirectory`
    /// appearing in the scanner source, and that is phrasing-fencing in both
    /// directions (PR #460 codex r17). It passes a hand-rolled `readdir`, a
    /// `FileManager.enumerator` or a `Glob` — any second mapping that spells
    /// itself differently — and it FAILS a read of the container that derives
    /// no removal target at all, which is exactly what r17's pre-listing
    /// witness pass at (a2) is. A ban on one API spelling is not the
    /// proposition; this is:
    ///
    ///   whatever else the scanner reads, the set of admin directories it
    ///   OFFERS for removal is the shared mapper's answer for the same
    ///   container and the same porcelain records.
    ///
    /// So the cell recomputes that answer independently — fresh listing,
    /// fresh `GitWorktreeAdminMapper` — and asserts set equality against the
    /// emitted plan. A second derivation only survives this by agreeing, and
    /// a derivation that agrees is not the failure mode the fence exists for.
    ///
    /// MUTATION: have `pruneTier` filter `directories` by anything of its own
    /// (drop the last entry, re-add a locked one) — RED here whatever it is
    /// spelled with.
    func testOracleToAdminMappingFlowsThroughTheOneSharedComponent() async throws {
        let repository = try makeRepositoryIgnoringPayloads(
            at: dev.appendingPathComponent("repo")
        )
        // Two orphans and one LIVE worktree, so the mapper's answer is a
        // strict subset of the container's entries and an enumeration that
        // simply listed the container would not match it.
        for index in 0..<2 {
            let orphan = try addWorktree(
                of: repository, at: dev.appendingPathComponent("gone-\(index)"),
                branch: "gone-\(index)"
            )
            try fm.removeItem(at: orphan)
        }
        try addWorktree(
            of: repository, at: dev.appendingPathComponent("wt-live"), branch: "live"
        )

        let scanner = makeScanner()
        let outcome = await scanner.scan(context: ScanContext(trigger: .userInitiated))
        let pruneItem = try XCTUnwrap(
            outcome.items.first { (try? plan(of: $0).mode) == .pruneOrphanedAdmin },
            "the prune item must be published: \(outcome.errors.map(\.detail))"
        )
        let reclaim = try plan(of: pruneItem)

        // THE INDEPENDENT RECOMPUTE: the oracle's own argv, re-run against
        // the unchanged fixture, parsed by the shared inventory and mapped by
        // the shared mapper.
        let listed = try GitFixture.git(
            GitWorktreeOracle.listArguments(forRepositoryAt: repository), home: home
        )
        XCTAssertEqual(listed.status, 0)
        let inventory = try XCTUnwrap(GitWorktreeInventory.parse(listed.stdout))
        let verdict = GitWorktreeAdminMapper().map(
            prunableRecordsIn: inventory.entries,
            adminContainer: reclaim.parentAdminContainer
        )
        guard case .complete(let expected) = verdict else {
            return XCTFail("the shared mapper refused the fixture: \(verdict)")
        }
        XCTAssertEqual(
            expected.count, 2,
            "the recompute must be non-vacuous — two orphans, one live "
                + "worktree, so the container holds three entries and the "
                + "mapper names two"
        )
        XCTAssertEqual(
            Set(reclaim.disclosedAdminDirectories.map { $0.path }),
            Set(expected.map { $0.path }),
            "the offered removal set is not the shared mapper's answer"
        )

        // The oracle argv itself is still never re-spelled locally: a second
        // porcelain grammar would fork the contract before the mapping is
        // even reached.
        let text = try scannerSource()
        XCTAssertTrue(
            text.contains("mapper.map("),
            "the scanner must consume fn-5.1's shared mapper"
        )
        XCTAssertTrue(
            text.contains("GitWorktreeOracle.listArguments"),
            "the oracle argv is fn-5.1's, never re-spelled"
        )
        XCTAssertFalse(
            text.contains("--porcelain"),
            "a locally-spelled porcelain argv would fork the oracle contract"
        )
        try assertNonMalformed(outcome, from: scanner)
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

/// A provider that reports one path as unidentifiable on the Nth `identity`
/// call for it ONLY, and answers truthfully on every other — the shape of a
/// TRANSIENT `lstat` failure (EPERM under a momentary sandbox change, an
/// entry that vanishes and comes back).
///
/// Strictly LESS capable than production on that one call and identical to it
/// everywhere else, so it can never answer a question the real provider would
/// refuse. The counter is per-path and matched on the admin-entry SUFFIX, for
/// the same reason `BlindToOnePathProvider` is: the scanner asks about the
/// entry under several legal spellings.
private final class BlindOnNthIdentityCallProvider: FileSystemIdentityProvider,
    @unchecked Sendable
{
    private let suffix: String
    private let blindCall: Int
    private let lock = NSLock()
    private var seen = 0

    init(blinded: URL, onCall blindCall: Int) {
        self.suffix = "/" + blinded.deletingLastPathComponent().lastPathComponent
            + "/" + blinded.lastPathComponent
        self.blindCall = blindCall
        super.init()
    }

    /// How many times the blinded path was asked about — read back so a cell
    /// cannot silently stop exercising the call it names.
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    override func identity(of url: URL) -> Identity? {
        guard url.path.hasSuffix(suffix) else { return super.identity(of: url) }
        lock.lock()
        seen += 1
        let index = seen
        lock.unlock()
        return index == blindCall ? nil : super.identity(of: url)
    }
}

/// A provider that reports ONE path as unidentifiable and delegates
/// everything else — the shape of an `lstat` denial on a single directory
/// (D6). Strictly LESS capable than production: it never answers a question
/// the real provider would refuse.
private final class BlindToOnePathProvider: FileSystemIdentityProvider {

    private let blinded: String

    init(blinded: URL) {
        self.blinded = "/" + blinded.deletingLastPathComponent().lastPathComponent
            + "/" + blinded.lastPathComponent
        super.init()
    }

    override func identity(of url: URL) -> Identity? {
        // SUFFIX, not exact spelling: the scanner asks about the admin entry
        // through `resolveTargetKeepingLeaf`, and a double that missed the
        // question by a `/private` prefix would silently prove nothing.
        url.path.hasSuffix(blinded) ? nil : super.identity(of: url)
    }
}
