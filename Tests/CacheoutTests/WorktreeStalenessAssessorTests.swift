/// # WorktreeStalenessAssessorTests — fn-5.2 (R1 / R2 / R3)
///
/// Four contracts:
///
/// 1. **The gate matrix on REAL hermetic fixture repos** — merged+clean,
///    modified, untracked, unmerged, locked, detached (merged and unmerged),
///    main and bare. Real git decides; the assessor only routes.
/// 2. **Fail-closed routing under INJECTED runner results** — every failure
///    class of every gate command, including `--is-ancestor` exit 128, which
///    must never be dressed up as the hedged "not an ancestor" answer.
/// 3. **The canonical four-clause evidence format** — the pinned candidate
///    shape and a pinned MIXED-FAILURE shape asserted VERBATIM as string
///    literals (never assembled from the source's own constants, which would
///    make the assertion circular).
/// 4. **The D17 read-only profile on every recorded invocation** — asserted
///    against the REAL runner, so the assertion sees exactly the argv and
///    environment the child saw.
///
/// Real-git fixtures are hermetic (`GitFixture`, GitCommandRunnerTests.swift):
/// `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` pinned to `/dev/null` and an
/// injected `HOME`. Absence and failure are proven with INJECTED runner
/// results, never with the host's git layout. Evidence dates are rendered in
/// an injected UTC time zone against a pinned committer date, so the verbatim
/// shapes hold on any machine.

import XCTest
@testable import Cacheout

// MARK: - Test doubles

/// A per-COMMAND script. Defaults describe the ordinary candidate path: a
/// clean tree, no `origin/HEAD` (the common shape on fetched repos), a local
/// `main`, an ancestral HEAD, and a readable commit date.
private struct GitScript: Sendable {
    var status: GitCommandOutcome = .success(stdout: Data())
    var symbolicRef: GitCommandOutcome = .failure(
        exitCode: 128, stderr: "fatal: ref refs/remotes/origin/HEAD is not a symbolic ref\n"
    )
    var revParseMain: GitCommandOutcome = .success(
        stdout: Data("221c2f088de2c34c76347bde00820accad4f529c\n".utf8)
    )
    var revParseMaster: GitCommandOutcome = .failure(exitCode: 1, stderr: "")
    var isAncestor: GitCommandOutcome = .success(stdout: Data())
    var show: GitCommandOutcome = .success(stdout: Data("1614834367\n".utf8))

    func outcome(for arguments: [String]) -> GitCommandOutcome {
        if arguments.contains("status") { return status }
        if arguments.contains("symbolic-ref") { return symbolicRef }
        if arguments.contains("rev-parse") {
            return arguments.contains("refs/heads/main") ? revParseMain : revParseMaster
        }
        if arguments.contains("merge-base") { return isAncestor }
        if arguments.contains("show") { return show }
        XCTFail("unscripted git command: \(arguments)")
        return .failure(exitCode: 1, stderr: "unscripted")
    }
}

/// Records every requested argv and answers from a `GitScript`. No process
/// ever runs, so failure classes are exact.
private final class ScriptedWorktreeRunner: GitCommandRunning, @unchecked Sendable {
    let defaultTimeout: TimeInterval = 5

    private let script: GitScript
    private let lock = NSLock()
    private var recorded: [(arguments: [String], timeout: TimeInterval)] = []

    init(_ script: GitScript = GitScript()) { self.script = script }

    /// Every argv the assessor asked for, in order.
    var requests: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map(\.arguments)
    }

    /// The per-invocation budget each request carried.
    var timeouts: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map(\.timeout)
    }

    func requests(containing token: String) -> [[String]] {
        requests.filter { $0.contains(token) }
    }

    func run(_ arguments: [String], timeout: TimeInterval) async -> GitCommandInvocation {
        lock.lock()
        recorded.append((arguments, timeout))
        lock.unlock()
        return GitCommandInvocation(
            profile: GitSafetyProfile.classify(arguments),
            argv: ["git", "-c", GitCommandRunner.fsmonitorNeutralization] + arguments,
            environment: [:],
            outcome: script.outcome(for: arguments)
        )
    }
}

/// Forwards to a REAL runner and records what it returned — so the D17
/// profile assertions run against the argv and environment the child
/// actually received.
private final class RecordingGitRunner: GitCommandRunning, @unchecked Sendable {
    private let wrapped: any GitCommandRunning
    private let lock = NSLock()
    private var recorded: [GitCommandInvocation] = []

    init(wrapping wrapped: any GitCommandRunning) { self.wrapped = wrapped }

    var defaultTimeout: TimeInterval { wrapped.defaultTimeout }

    var invocations: [GitCommandInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ arguments: [String], timeout: TimeInterval) async -> GitCommandInvocation {
        let invocation = await wrapped.run(arguments, timeout: timeout)
        lock.lock()
        recorded.append(invocation)
        lock.unlock()
        return invocation
    }
}

// MARK: - Tests

final class WorktreeStalenessAssessorTests: XCTestCase {

    /// Pinned committer date for every fixture commit: epoch 1614834367 is
    /// 2021-03-04 05:06:07 UTC, so the UTC-rendered evidence day is stable.
    private static let pinnedCommitterDate = "@1614834367 +0000"
    private static let pinnedCommitDay = "2021-03-04"

    private static let utc = TimeZone(identifier: "UTC")!

    private var base: URL!
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("WorktreeStalenessAssessorTests-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
    }

    // MARK: - Fixture helpers

    /// A repository with ONE tracked file and a pinned committer date.
    @discardableResult
    private func makeRepository(
        named name: String, defaultBranch: String = "main"
    ) throws -> URL {
        let url = base.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let initialized = try GitFixture.git(
            ["-c", "init.defaultBranch=\(defaultBranch)", "init", url.path], home: home
        )
        XCTAssertEqual(initialized.status, 0, "git init failed at \(url.path)")
        try "seed\n".write(
            to: url.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(
            try GitFixture.git(["-C", url.path, "add", "tracked.txt"], home: home).status, 0
        )
        try commit(in: url, message: "seed")
        return url
    }

    private func commit(in repository: URL, message: String, allowEmpty: Bool = false) throws {
        var arguments = [
            "-C", repository.path, "-c", "user.name=t", "-c", "user.email=t@t",
            "commit", "-m", message
        ]
        if allowEmpty { arguments.append("--allow-empty") }
        let committed = try GitFixture.git(
            arguments, home: home,
            environment: [
                "GIT_AUTHOR_DATE": Self.pinnedCommitterDate,
                "GIT_COMMITTER_DATE": Self.pinnedCommitterDate
            ]
        )
        XCTAssertEqual(committed.status, 0, "git commit failed in \(repository.path)")
    }

    @discardableResult
    private func addWorktree(
        named name: String, in repository: URL, arguments extra: [String] = []
    ) throws -> URL {
        let url = base.appendingPathComponent(name)
        let added = try GitFixture.git(
            ["-C", repository.path, "worktree", "add", url.path] + extra, home: home
        )
        XCTAssertEqual(added.status, 0, "git worktree add failed for \(url.path)")
        return url
    }

    /// The real porcelain listing, parsed by fn-5.1's parser.
    private func inventory(of repository: URL) throws -> GitWorktreeInventory {
        let listed = try GitFixture.git(
            ["-C", repository.path, "worktree", "list", "--porcelain", "-z"], home: home
        )
        XCTAssertEqual(listed.status, 0, "git worktree list failed in \(repository.path)")
        return try XCTUnwrap(
            GitWorktreeInventory.parse(listed.stdout), "porcelain -z stream did not parse"
        )
    }

    /// The single linked record of a one-worktree fixture.
    private func linkedRecord(of repository: URL) throws -> GitWorktreeEntry {
        let entries = try inventory(of: repository).entries
        return try XCTUnwrap(entries.first { !$0.isMain }, "no linked worktree listed")
    }

    private func realAssessor(
        recordedBy recorder: RecordingGitRunner? = nil
    ) -> WorktreeStalenessAssessor {
        let runner: any GitCommandRunning = recorder
            ?? GitCommandRunner(environment: GitFixture.environment(home: home))
        return WorktreeStalenessAssessor(runner: runner, timeZone: Self.utc)
    }

    private func realRunner() -> GitCommandRunner {
        GitCommandRunner(environment: GitFixture.environment(home: home))
    }

    /// Assess a real fixture's linked worktree end to end.
    private func assessLinked(of repository: URL) async throws -> WorktreeAssessment {
        let entry = try linkedRecord(of: repository)
        let parent = try XCTUnwrap(inventory(of: repository).parentRepoWorkingDir)
        let result = await realAssessor().assess(entry: entry, parentRepoWorkingDir: parent)
        return try XCTUnwrap(result.assessment, "expected an assessment, got \(result)")
    }

    /// A hand-built linked record — used where a single fixture cannot hold
    /// every failing gate at once.
    private func linkedEntry(
        path: URL,
        isLocked: Bool = false,
        lockReason: String? = nil,
        isPrunable: Bool = false,
        prunableReason: String? = nil,
        isDetached: Bool = false
    ) -> GitWorktreeEntry {
        GitWorktreeEntry(
            path: path,
            headSHA: "221c2f088de2c34c76347bde00820accad4f529c",
            branchRef: isDetached ? nil : "refs/heads/feature",
            isDetached: isDetached,
            isBare: false,
            isLocked: isLocked,
            lockReason: lockReason,
            isPrunable: isPrunable,
            prunableReason: prunableReason,
            isMain: false
        )
    }

    private func scriptedAssessment(
        _ script: GitScript,
        entry: GitWorktreeEntry? = nil,
        runner: ScriptedWorktreeRunner? = nil
    ) async throws -> (assessment: WorktreeAssessment, runner: ScriptedWorktreeRunner) {
        let runner = runner ?? ScriptedWorktreeRunner(script)
        let assessor = WorktreeStalenessAssessor(runner: runner, timeZone: Self.utc)
        let result = await assessor.assess(
            entry: entry ?? linkedEntry(path: URL(fileURLWithPath: "/repos/wt")),
            parentRepoWorkingDir: URL(fileURLWithPath: "/repos/r")
        )
        return (try XCTUnwrap(result.assessment, "expected an assessment, got \(result)"), runner)
    }

    private func reason(
        _ assessment: WorktreeAssessment, _ gate: WorktreeGate
    ) throws -> String {
        try XCTUnwrap(assessment.outcome(for: gate), "missing \(gate.rawValue)").reason
    }

    // MARK: - R1: the gate matrix on real fixtures

    /// The PINNED CANDIDATE SHAPE, asserted VERBATIM.
    func testMergedCleanWorktreeIsACandidateWithThePinnedEvidenceShape() async throws {
        let repository = try makeRepository(named: "repo")
        try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])

        let assessment = try await assessLinked(of: repository)
        XCTAssertTrue(assessment.isCandidate, "clean + merged + unlocked + linked is a candidate")
        XCTAssertEqual(
            assessment.evidence,
            "G1 linked (not main/bare); G2 clean; "
                + "G3 HEAD is ancestor of refs/heads/main; G4 not locked; "
                + "last commit \(Self.pinnedCommitDay); branch ref survives removal"
        )
        XCTAssertEqual(
            assessment.lastCommitDate, Date(timeIntervalSince1970: 1_614_834_367)
        )
    }

    func testModifiedTrackedFileMakesTheWorktreeANonCandidate() async throws {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])
        try "seed\nlocal edit\n".write(
            to: worktree.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8
        )

        let assessment = try await assessLinked(of: repository)
        XCTAssertFalse(assessment.isCandidate)
        XCTAssertEqual(try reason(assessment, .clean), "dirty: 1 modified/untracked entries")
    }

    func testUntrackedFileMakesTheWorktreeANonCandidate() async throws {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])
        try "scratch\n".write(
            to: worktree.appendingPathComponent("untracked.txt"),
            atomically: true, encoding: .utf8
        )

        let assessment = try await assessLinked(of: repository)
        XCTAssertFalse(assessment.isCandidate, "untracked content is dirty too")
        XCTAssertEqual(try reason(assessment, .clean), "dirty: 1 modified/untracked entries")
    }

    func testUnmergedCommitMakesTheWorktreeANonCandidateWithHedgedWording() async throws {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])
        try commit(in: worktree, message: "ahead of main", allowEmpty: true)

        let assessment = try await assessLinked(of: repository)
        XCTAssertFalse(assessment.isCandidate)
        XCTAssertEqual(
            try reason(assessment, .merged),
            "HEAD not an ancestor of refs/heads/main (squash/rebase merges not detected)",
            "the D5 hedge is MANDATORY — evidence never asserts non-merger as fact"
        )
    }

    func testLockedWorktreeIsNeverACandidate() async throws {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", repository.path, "worktree", "lock", worktree.path,
                 "--reason", "in use on laptop"],
                home: home
            ).status, 0
        )

        let assessment = try await assessLinked(of: repository)
        XCTAssertFalse(
            assessment.isCandidate, "this epic has NO lock handling — locked never goes"
        )
        XCTAssertEqual(try reason(assessment, .notLocked), "locked: in use on laptop")
    }

    func testDetachedHeadAtAMergedCommitIsACandidate() async throws {
        let repository = try makeRepository(named: "repo")
        try addWorktree(named: "wt", in: repository, arguments: ["--detach"])

        let record = try linkedRecord(of: repository)
        XCTAssertTrue(record.isDetached, "fixture must actually be detached")
        let assessment = try await assessLinked(of: repository)
        XCTAssertTrue(
            assessment.isCandidate,
            "detached HEAD needs no special case — the COMMIT is what is judged"
        )
        XCTAssertEqual(try reason(assessment, .merged), "HEAD is ancestor of refs/heads/main")
    }

    func testDetachedHeadAtAnUnmergedCommitIsNotACandidate() async throws {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", in: repository, arguments: ["--detach"])
        try commit(in: worktree, message: "detached work", allowEmpty: true)

        let assessment = try await assessLinked(of: repository)
        XCTAssertFalse(assessment.isCandidate)
        XCTAssertEqual(
            try reason(assessment, .merged),
            "HEAD not an ancestor of refs/heads/main (squash/rebase merges not detected)"
        )
    }

    /// The main record is refused, and its evidence STILL carries all four
    /// clauses — with no candidate tail.
    func testMainWorktreeIsRefusedByG1AndStillCarriesAllFourClauses() async throws {
        let repository = try makeRepository(named: "repo")
        try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])

        let inventory = try inventory(of: repository)
        let main = try XCTUnwrap(inventory.mainRecord)
        let result = await realAssessor().assess(
            entry: main, parentRepoWorkingDir: try XCTUnwrap(inventory.parentRepoWorkingDir)
        )
        let assessment = try XCTUnwrap(result.assessment)

        XCTAssertFalse(assessment.isCandidate)
        XCTAssertEqual(
            assessment.evidence,
            "G1 main worktree; G2 clean; G3 HEAD is ancestor of refs/heads/main; G4 not locked"
        )
        XCTAssertNil(
            assessment.lastCommitDate,
            "the date feeds only the candidate tail — a non-candidate never pays for it"
        )
    }

    func testBareRepositoryRecordIsRefusedByG1() async throws {
        let seed = try makeRepository(named: "seed")
        let bare = base.appendingPathComponent("bare.git")
        XCTAssertEqual(
            try GitFixture.git(
                ["-c", "init.defaultBranch=main", "init", "--bare", bare.path], home: home
            ).status, 0
        )
        XCTAssertEqual(
            try GitFixture.git(["-C", seed.path, "push", bare.path, "main"], home: home).status, 0
        )

        let inventory = try inventory(of: bare)
        let main = try XCTUnwrap(inventory.mainRecord)
        XCTAssertTrue(main.isBare, "fixture must actually be bare")
        let result = await realAssessor().assess(
            entry: main, parentRepoWorkingDir: try XCTUnwrap(inventory.parentRepoWorkingDir)
        )
        let assessment = try XCTUnwrap(result.assessment)

        XCTAssertFalse(assessment.isCandidate)
        XCTAssertEqual(try reason(assessment, .notMainOrBare), "bare")
        // A bare repository has no work tree, so the clean check fails CLOSED
        // (git exits 128) rather than reporting an empty — i.e. clean — tree.
        let cleanReason = try reason(assessment, .clean)
        XCTAssertTrue(
            cleanReason.hasPrefix("clean check failed (git exit 128"), "got: \(cleanReason)"
        )
    }

    // MARK: - R2: the --ignore-submodules=none flag

    /// The bare default honours the repository's own submodule ignore
    /// setting and reports a worktree with uncommitted submodule work as
    /// CLEAN; `--ignore-submodules=none` (what git's `check_clean_worktree`
    /// passes) sees it.
    func testDirtySubmoduleIsSeenOnlyWithIgnoreSubmodulesNone() async throws {
        let submodule = try makeRepository(named: "sub")
        let repository = try makeRepository(named: "repo")
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", repository.path, "-c", "protocol.file.allow=always",
                 "-c", "user.name=t", "-c", "user.email=t@t",
                 "submodule", "add", submodule.path, "sub"],
                home: home
            ).status, 0
        )
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", repository.path, "config", "--file",
                 repository.appendingPathComponent(".gitmodules").path,
                 "submodule.sub.ignore", "all"],
                home: home
            ).status, 0
        )
        XCTAssertEqual(
            try GitFixture.git(["-C", repository.path, "add", ".gitmodules", "sub"], home: home)
                .status, 0
        )
        try commit(in: repository, message: "add submodule")

        let worktree = try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])
        XCTAssertEqual(
            try GitFixture.git(
                ["-C", worktree.path, "-c", "protocol.file.allow=always",
                 "submodule", "update", "--init"],
                home: home
            ).status, 0
        )
        let tracked = worktree.appendingPathComponent("sub/tracked.txt")
        try "seed\nuncommitted submodule work\n".write(
            to: tracked, atomically: true, encoding: .utf8
        )

        // The premise, proven rather than assumed.
        let bareDefault = try GitFixture.git(
            ["-C", worktree.path, "status", "--porcelain"], home: home
        )
        XCTAssertTrue(
            bareDefault.stdout.isEmpty,
            "premise: the bare default UNDER-DETECTS this dirty submodule"
        )
        let withFlag = try GitFixture.git(
            ["-C", worktree.path, "status", "--porcelain", "--ignore-submodules=none"],
            home: home
        )
        XCTAssertFalse(withFlag.stdout.isEmpty, "the flag must catch it")

        let assessment = try await assessLinked(of: repository)
        XCTAssertFalse(
            assessment.isCandidate,
            "a worktree with uncommitted submodule work must never be a candidate"
        )
        XCTAssertEqual(try reason(assessment, .clean), "dirty: 1 modified/untracked entries")
    }

    // MARK: - R3: the default-branch ladder

    func testOriginHeadResolvesTheDefaultBranch() async throws {
        let origin = try makeRepository(named: "origin")
        let clone = base.appendingPathComponent("clone")
        XCTAssertEqual(
            try GitFixture.git(["clone", origin.path, clone.path], home: home).status, 0
        )
        try addWorktree(named: "wt", in: clone, arguments: ["-b", "feature"])

        let assessment = try await assessLinked(of: clone)
        XCTAssertTrue(assessment.isCandidate)
        XCTAssertEqual(
            try reason(assessment, .merged),
            "HEAD is ancestor of refs/remotes/origin/main",
            "step (a) of the ladder wins when origin/HEAD is set"
        )
    }

    func testNoRemoteRepositoryFallsBackToLocalMasterWhenMainIsAbsent() async throws {
        let repository = try makeRepository(named: "repo", defaultBranch: "master")
        try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])

        let assessment = try await assessLinked(of: repository)
        XCTAssertTrue(assessment.isCandidate)
        XCTAssertEqual(
            try reason(assessment, .merged), "HEAD is ancestor of refs/heads/master",
            "no remote, no local main — rung (c) resolves"
        )
    }

    /// Rung (b) on real git, with the LADDER ORDER proven: `origin/HEAD` is
    /// tried first and its exit-128 "unset" answer is what hands control to
    /// the local rung — the common shape on fetched, non-cloned repos.
    func testNoRemoteRepositoryResolvesLocalMainAfterTryingOriginHead() async throws {
        let repository = try makeRepository(named: "repo")
        try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])

        let recorder = RecordingGitRunner(wrapping: realRunner())
        let entry = try linkedRecord(of: repository)
        let parent = try XCTUnwrap(inventory(of: repository).parentRepoWorkingDir)
        let result = await realAssessor(recordedBy: recorder)
            .assess(entry: entry, parentRepoWorkingDir: parent)
        let assessment = try XCTUnwrap(result.assessment)

        XCTAssertTrue(assessment.isCandidate)
        XCTAssertEqual(try reason(assessment, .merged), "HEAD is ancestor of refs/heads/main")

        let ladder = recorder.invocations.filter {
            $0.argv.contains("symbolic-ref") || $0.argv.contains("rev-parse")
        }
        XCTAssertEqual(ladder.count, 2, "origin/HEAD, then refs/heads/main — and stop")
        XCTAssertTrue(ladder[0].argv.contains("refs/remotes/origin/HEAD"))
        guard case .failure(let exitCode, _) = ladder[0].outcome else {
            return XCTFail("expected the origin/HEAD probe to fail, got \(ladder[0].outcome)")
        }
        XCTAssertEqual(exitCode, 128, "real git answers an unset origin/HEAD with exit 128")
        XCTAssertTrue(ladder[1].argv.contains("refs/heads/main"))
        XCTAssertFalse(
            recorder.invocations.contains { $0.argv.contains("refs/heads/master") },
            "the master rung must not run once main resolved"
        )
        // Both rungs run in the PARENT repo, never in the worktree.
        for invocation in ladder {
            let target = try XCTUnwrap(
                invocation.argv.firstIndex(of: "-C").map { invocation.argv[$0 + 1] }
            )
            XCTAssertEqual(target, parent.path, "the ladder runs with -C <parent>")
        }
    }

    func testRepositoryWithNeitherMainNorMasterFailsG3Closed() async throws {
        let repository = try makeRepository(named: "repo", defaultBranch: "trunk")
        try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])

        let assessment = try await assessLinked(of: repository)
        XCTAssertFalse(
            assessment.isCandidate,
            "a develop/trunk repo without origin/HEAD is never a candidate (D6, accepted)"
        )
        XCTAssertEqual(try reason(assessment, .merged), "default branch unresolvable")
    }

    // MARK: - R2: injected failures — every gate, every class

    func testEveryFailureClassOnTheCleanCheckFailsG2Closed() async throws {
        let cases: [(GitCommandOutcome, String)] = [
            (.failure(exitCode: 128, stderr: "fatal: not a git repository\n"),
             "clean check failed (git exit 128: fatal: not a git repository)"),
            (.timeout, "clean check timed out"),
            (.gitUnavailable, "git unavailable")
        ]
        for (outcome, expected) in cases {
            var script = GitScript()
            script.status = outcome
            let (assessment, _) = try await scriptedAssessment(script)
            XCTAssertFalse(assessment.isCandidate, "\(outcome) must never pass G2")
            XCTAssertEqual(try reason(assessment, .clean), expected)
        }
    }

    func testEveryFailureClassOnTheAncestryCheckFailsG3Closed() async throws {
        let cases: [(GitCommandOutcome, String)] = [
            (.failure(exitCode: 1, stderr: ""),
             "HEAD not an ancestor of refs/heads/main (squash/rebase merges not detected)"),
            (.failure(exitCode: 128, stderr: "fatal: Not a valid object name refs/heads/main\n"),
             "ancestry check against refs/heads/main failed "
                + "(git exit 128: fatal: Not a valid object name refs/heads/main)"),
            (.timeout, "ancestry check against refs/heads/main timed out"),
            (.gitUnavailable, "git unavailable")
        ]
        for (outcome, expected) in cases {
            var script = GitScript()
            script.isAncestor = outcome
            let (assessment, _) = try await scriptedAssessment(script)
            XCTAssertFalse(assessment.isCandidate, "\(outcome) must never pass G3")
            XCTAssertEqual(try reason(assessment, .merged), expected)
        }
    }

    /// Exit 1 is git's ANSWER; exit 128 means git could not answer. Rendering
    /// 128 with the hedged "not an ancestor" wording would claim an answer
    /// nobody got.
    func testIsAncestorExit128IsNeverRenderedAsTheHedgedNegative() async throws {
        var script = GitScript()
        script.isAncestor = .failure(exitCode: 128, stderr: "fatal: bad revision\n")
        let (assessment, _) = try await scriptedAssessment(script)

        XCTAssertFalse(assessment.isCandidate)
        XCTAssertFalse(
            try reason(assessment, .merged).contains("not an ancestor"),
            "exit 128 and exit 1 must never be conflated into 'answered'"
        )
        XCTAssertTrue(try reason(assessment, .merged).hasPrefix("ancestry check against"))
    }

    func testLadderTimeoutStopsImmediatelyInsteadOfRelabelingTheCause() async throws {
        var script = GitScript()
        script.symbolicRef = .timeout
        let (assessment, runner) = try await scriptedAssessment(script)

        XCTAssertEqual(try reason(assessment, .merged), "default branch lookup timed out")
        XCTAssertTrue(
            runner.requests(containing: "rev-parse").isEmpty,
            "a timed-out git must not be asked two more questions"
        )
        XCTAssertTrue(
            runner.requests(containing: "merge-base").isEmpty,
            "no ancestry check runs against an unresolved default branch"
        )
    }

    func testLadderGitUnavailableStopsImmediately() async throws {
        var script = GitScript()
        script.symbolicRef = .gitUnavailable
        let (assessment, runner) = try await scriptedAssessment(script)

        XCTAssertEqual(try reason(assessment, .merged), "git unavailable")
        XCTAssertTrue(runner.requests(containing: "rev-parse").isEmpty)
    }

    func testLocalRungTimeoutStopsTheLadderBeforeMaster() async throws {
        var script = GitScript()
        script.revParseMain = .timeout
        let (assessment, runner) = try await scriptedAssessment(script)

        XCTAssertEqual(try reason(assessment, .merged), "default branch lookup timed out")
        XCTAssertTrue(
            runner.requests(containing: "refs/heads/master").isEmpty,
            "the master rung must not run after a timeout on the main rung"
        )
    }

    func testAllThreeRungsMissingFailsClosedWithoutAnAncestryCheck() async throws {
        var script = GitScript()
        script.revParseMain = .failure(exitCode: 1, stderr: "")
        let (assessment, runner) = try await scriptedAssessment(script)

        XCTAssertEqual(try reason(assessment, .merged), "default branch unresolvable")
        XCTAssertEqual(runner.requests(containing: "symbolic-ref").count, 1)
        XCTAssertEqual(runner.requests(containing: "refs/heads/main").count, 1)
        XCTAssertEqual(runner.requests(containing: "refs/heads/master").count, 1)
        XCTAssertTrue(runner.requests(containing: "merge-base").isEmpty)
    }

    /// A SUCCESSFUL `symbolic-ref` whose output is not a ref is an anomaly,
    /// not the benign "unset" case — it must not fall through into the local
    /// ladder as though the pointer were merely absent.
    func testSymbolicRefSuccessWithUnreadableOutputFailsClosed() async throws {
        var script = GitScript()
        script.symbolicRef = .success(stdout: Data("not-a-ref\n".utf8))
        let (assessment, runner) = try await scriptedAssessment(script)

        XCTAssertFalse(assessment.isCandidate)
        XCTAssertEqual(
            try reason(assessment, .merged),
            "refs/remotes/origin/HEAD resolved to an unreadable ref"
        )
        XCTAssertTrue(runner.requests(containing: "rev-parse").isEmpty)
    }

    func testGitUnavailableFailsEveryGitBackedGateClosed() async throws {
        var script = GitScript()
        script.status = .gitUnavailable
        script.symbolicRef = .gitUnavailable
        let (assessment, _) = try await scriptedAssessment(script)

        XCTAssertFalse(assessment.isCandidate)
        XCTAssertEqual(try reason(assessment, .clean), "git unavailable")
        XCTAssertEqual(try reason(assessment, .merged), "git unavailable")
        XCTAssertEqual(
            assessment.evidence,
            "G1 linked (not main/bare); G2 git unavailable; G3 git unavailable; G4 not locked",
            "every clause is still present — an unavailable git is NAMED, never silent"
        )
    }

    // MARK: - R1/R3/R10: the canonical evidence format

    /// The PINNED MIXED-FAILURE SHAPE, asserted VERBATIM: several failing
    /// gates named in ONE string, all four clauses, in order.
    func testPinnedMixedFailureShapeIsAssembledVerbatim() async throws {
        var script = GitScript()
        script.status = .success(stdout: Data(" M a.txt\n?? b.txt\n M c.txt\n".utf8))
        script.isAncestor = .failure(exitCode: 1, stderr: "")
        let entry = linkedEntry(
            path: URL(fileURLWithPath: "/repos/wt"),
            isLocked: true, lockReason: "in use on laptop"
        )
        let (assessment, runner) = try await scriptedAssessment(script, entry: entry)

        XCTAssertEqual(
            assessment.evidence,
            "G1 linked (not main/bare); G2 dirty: 3 modified/untracked entries; "
                + "G3 HEAD not an ancestor of refs/heads/main "
                + "(squash/rebase merges not detected); G4 locked: in use on laptop"
        )
        XCTAssertFalse(assessment.isCandidate)
        XCTAssertTrue(
            runner.requests(containing: "show").isEmpty,
            "the last-commit lookup is candidate-only"
        )
    }

    func testEvidenceAlwaysCarriesAllFourClausesInGateOrder() async throws {
        var script = GitScript()
        script.status = .success(stdout: Data(" M a.txt\n".utf8))
        let (assessment, _) = try await scriptedAssessment(script)

        XCTAssertEqual(
            assessment.gates.map(\.gate), [.notMainOrBare, .clean, .merged, .notLocked],
            "gate order is part of the canonical format"
        )
        let clauses = assessment.evidence.components(separatedBy: "; ")
        XCTAssertEqual(clauses.count, 4, "a non-candidate carries the four clauses and no tail")
        for (index, gate) in WorktreeGate.allCases.enumerated() {
            XCTAssertTrue(
                clauses[index].hasPrefix("\(gate.rawValue) "), "clause \(index): \(clauses[index])"
            )
        }
        XCTAssertFalse(assessment.evidence.contains("branch ref survives removal"))
        XCTAssertFalse(assessment.evidence.contains("last commit"))
    }

    func testDateLookupFailureRendersTheExplicitMarkerAndKeepsTheCandidate() async throws {
        let cases: [GitCommandOutcome] = [
            .failure(exitCode: 128, stderr: "fatal: bad object HEAD\n"),
            .timeout,
            .gitUnavailable,
            .success(stdout: Data("not-a-timestamp\n".utf8))
        ]
        for outcome in cases {
            var script = GitScript()
            script.show = outcome
            let (assessment, _) = try await scriptedAssessment(script)

            XCTAssertTrue(
                assessment.isCandidate,
                "last activity is display data — it must NEVER fail an assessment (\(outcome))"
            )
            XCTAssertNil(assessment.lastCommitDate)
            XCTAssertEqual(
                assessment.evidence,
                "G1 linked (not main/bare); G2 clean; "
                    + "G3 HEAD is ancestor of refs/heads/main; G4 not locked; "
                    + "last commit unavailable; branch ref survives removal",
                "the date SLOT is never silently absent"
            )
        }
    }

    func testLockedWithoutAReasonStillNamesTheGate() async throws {
        let entry = linkedEntry(path: URL(fileURLWithPath: "/repos/wt"), isLocked: true)
        let (assessment, _) = try await scriptedAssessment(GitScript(), entry: entry)

        XCTAssertFalse(assessment.isCandidate)
        XCTAssertEqual(try reason(assessment, .notLocked), "locked (no reason recorded)")
    }

    // MARK: - Prunable records are refused WITHOUT assessment

    func testPrunableRecordIsRefusedWithADistinctNonGateReasonAndNoGitCalls() async throws {
        let runner = ScriptedWorktreeRunner()
        let assessor = WorktreeStalenessAssessor(runner: runner, timeZone: Self.utc)
        let entry = linkedEntry(
            path: URL(fileURLWithPath: "/repos/gone"),
            isPrunable: true, prunableReason: "gitdir file points to non-existent location"
        )

        let result = await assessor.assess(
            entry: entry, parentRepoWorkingDir: URL(fileURLWithPath: "/repos/r")
        )
        guard case .prunableNotAssessed(let reason) = result else {
            return XCTFail("expected a prunable refusal, got \(result)")
        }
        XCTAssertEqual(
            reason,
            "prunable record — the checkout is already gone; the orphaned-admin tier owns it "
                + "(gitdir file points to non-existent location)"
        )
        XCTAssertFalse(result.isCandidate)
        XCTAssertNil(result.assessment)
        XCTAssertTrue(
            runner.requests.isEmpty,
            "no git runs against a checkout that is already gone"
        )
    }

    // MARK: - The per-invocation budget

    /// Scan-time callers take the runner's own default; a caller that needs a
    /// different budget (fn-5.4 buys minutes) passes one and EVERY gate
    /// command must carry it.
    func testTheBudgetIsTheRunnerDefaultUnlessOverriddenForEveryCommand() async throws {
        let entry = linkedEntry(path: URL(fileURLWithPath: "/repos/wt"))
        let parent = URL(fileURLWithPath: "/repos/r")

        let defaulted = ScriptedWorktreeRunner()
        _ = await WorktreeStalenessAssessor(runner: defaulted, timeZone: Self.utc)
            .assess(entry: entry, parentRepoWorkingDir: parent)
        XCTAssertEqual(
            defaulted.timeouts, Array(repeating: defaulted.defaultTimeout, count: 5),
            "status, symbolic-ref, rev-parse, merge-base, show"
        )

        let overridden = ScriptedWorktreeRunner()
        _ = await WorktreeStalenessAssessor(runner: overridden, timeout: 42, timeZone: Self.utc)
            .assess(entry: entry, parentRepoWorkingDir: parent)
        XCTAssertEqual(overridden.timeouts, Array(repeating: 42, count: 5))
    }

    // MARK: - The exported G2 surface (fn-5.4 dependency)

    func testExportedCleanCheckArgumentsCarryTheRequiredFlag() {
        let worktree = URL(fileURLWithPath: "/repos/wt")
        XCTAssertEqual(
            GitWorktreeCleanCheck.arguments(forWorktreeAt: worktree),
            ["-C", "/repos/wt", "status", "--porcelain", "--ignore-submodules=none"]
        )
    }

    /// fn-5.4's revalidator consumes the check through THIS surface — the
    /// same one the G2 gate uses.
    func testExportedCleanCheckIsConsumedDirectlyOnRealAndInjectedOutcomes() async throws {
        let repository = try makeRepository(named: "repo")
        let worktree = try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])
        let runner = realRunner()

        let clean = await GitWorktreeCleanCheck.run(worktreeAt: worktree, using: runner)
        XCTAssertEqual(clean, .clean)
        XCTAssertTrue(clean.isClean)

        try "seed\nedited\n".write(
            to: worktree.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8
        )
        let dirty = await GitWorktreeCleanCheck.run(worktreeAt: worktree, using: runner)
        XCTAssertEqual(dirty, .dirty(entryCount: 1))
        XCTAssertFalse(dirty.isClean)

        // Failure classes route through the SAME surface, and none is clean.
        XCTAssertEqual(
            GitWorktreeCleanCheck.verdict(for: .timeout), .failed(reason: "clean check timed out")
        )
        XCTAssertEqual(
            GitWorktreeCleanCheck.verdict(for: .gitUnavailable),
            .failed(reason: "git unavailable")
        )
        XCTAssertEqual(
            GitWorktreeCleanCheck.verdict(
                for: .failure(exitCode: 128, stderr: "fatal: not a git repository\n")
            ),
            .failed(reason: "clean check failed (git exit 128: fatal: not a git repository)")
        )
        for verdict in [
            WorktreeCleanVerdict.dirty(entryCount: 2),
            .failed(reason: "clean check timed out")
        ] {
            XCTAssertFalse(verdict.isClean, "\(verdict) must never read as clean")
        }
    }

    // MARK: - R9/D17: the read-only profile on every invocation

    func testEveryAssessmentCommandCarriesTheReadOnlyProfile() async throws {
        let repository = try makeRepository(named: "repo")
        try addWorktree(named: "wt", in: repository, arguments: ["-b", "feature"])

        let recorder = RecordingGitRunner(wrapping: realRunner())
        let entry = try linkedRecord(of: repository)
        let parent = try XCTUnwrap(inventory(of: repository).parentRepoWorkingDir)
        let result = await realAssessor(recordedBy: recorder)
            .assess(entry: entry, parentRepoWorkingDir: parent)
        XCTAssertTrue(result.isCandidate, "fixture must exercise all five commands")

        let invocations = recorder.invocations
        XCTAssertEqual(
            invocations.count, 5,
            "status, symbolic-ref, rev-parse(main), merge-base, show — and nothing else"
        )
        for invocation in invocations {
            XCTAssertEqual(
                invocation.profile, .readOnly,
                "every assessment command is READ-ONLY by D17 classification: \(invocation.argv)"
            )
            XCTAssertEqual(
                invocation.environment[GitCommandRunner.optionalLocksVariable], "0",
                "GIT_OPTIONAL_LOCKS=0 rides the read-only profile: \(invocation.argv)"
            )
            XCTAssertEqual(
                Array(invocation.argv.prefix(3)),
                ["git", "-c", "core.fsmonitor=false"],
                "the fsmonitor executor is neutralized on every invocation"
            )
        }

        let commands = ["status", "symbolic-ref", "rev-parse", "merge-base", "show"]
        for command in commands {
            XCTAssertTrue(
                invocations.contains { $0.argv.contains(command) },
                "expected a \(command) invocation"
            )
        }
        let status = try XCTUnwrap(invocations.first { $0.argv.contains("status") })
        XCTAssertTrue(status.argv.contains("--porcelain"))
        XCTAssertTrue(
            status.argv.contains("--ignore-submodules=none"),
            "the G2 argv is pinned: \(status.argv)"
        )
    }
}
