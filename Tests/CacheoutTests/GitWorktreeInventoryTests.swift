/// # GitWorktreeInventoryTests — fn-5.1 (R7 / R9)
///
/// Three contracts:
///
/// 1. **The `--porcelain -z` grammar** — pure BYTE fixtures, no git and no
///    filesystem. NUL-terminated attributes, double-NUL record boundaries,
///    no quoting anywhere, first-record `isMain` by position, unknown
///    attributes ignored, and paths containing spaces AND newlines surviving
///    intact (line splitting is the D8 defect this exists to prevent).
/// 2. **The bidirectional gitdir resolver** — absolute and relative
///    pointers, `commondir` honored, the back-link ENFORCED, the two
///    cross-validation branches (bare / non-bare), and every mismatch
///    failing CLOSED.
/// 3. **The shared oracle→admin mapper** — the round-10 admin-ENTRY
///    traversal gates running BEFORE any back-link read, and the
///    complete-or-incomplete verdict.
///
/// Real-git fixtures are hermetic (`GitFixture`, GitCommandRunnerTests.swift):
/// `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` pinned to `/dev/null` and an
/// injected `HOME`, so nothing reads the developer's real config.

import XCTest
@testable import Cacheout

// MARK: - Identity injection

/// Redirects `realPath(of:)` for chosen paths so the mapper's
/// "canonicalizes outside the container" gate can be exercised without a
/// filesystem trick that gate (a) would already reject.
private final class RedirectingIdentityProvider: FileSystemIdentityProvider {
    var redirects: [String: String] = [:]
    var deviceOverrides: [String: UInt64] = [:]

    override func realPath(of path: String) -> String? {
        if let redirected = redirects[path] { return redirected }
        return super.realPath(of: path)
    }

    override func identity(of url: URL) -> Identity? {
        guard let base = super.identity(of: url) else { return nil }
        guard let device = deviceOverrides[url.path] else { return base }
        return Identity(device: device, inode: base.inode)
    }
}

/// The scanner's `.automatic`-scan provider, reduced to exactly the arms the
/// RESOLVER consumes (fn-4.26): a deferred path probes `.absent` and carries
/// no identity, and every `realpath(3)` ARGUMENT is recorded so a cell can
/// count the dereferences the gate must forestall. Deliberately NO more
/// capable than the production `DeferringIdentityProvider` — a double that
/// answered more would hide exactly the ordering bug under test. The deferral
/// predicate is a plain string prefix, dereferencing nothing, so every
/// recorded realpath is attributable to the RESOLVER's own ordering, never to
/// the predicate's.
private final class DeferralRecordingProvider: FileSystemIdentityProvider {
    private let deferredPrefix: String?
    private let lock = NSLock()
    private var recorded: [String] = []

    init(deferring prefix: String? = nil) {
        self.deferredPrefix = prefix
        super.init()
    }

    var realPathArguments: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func realPathArguments(under prefix: String) -> [String] {
        realPathArguments.filter { $0.hasPrefix(prefix) }
    }

    private func isDeferred(_ path: String) -> Bool {
        guard let deferredPrefix else { return false }
        return path.hasPrefix(deferredPrefix)
    }

    override func probeKind(of url: URL) -> KindProbe {
        isDeferred(url.path) ? .absent : super.probeKind(of: url)
    }

    override func identity(of url: URL) -> Identity? {
        isDeferred(url.path) ? nil : super.identity(of: url)
    }

    override func realPath(of path: String) -> String? {
        lock.lock()
        recorded.append(path)
        lock.unlock()
        return super.realPath(of: path)
    }
}

final class GitWorktreeInventoryTests: XCTestCase {

    private var base: URL!
    private var home: URL!
    private let fm = FileManager.default

    /// chmod-000 fixtures registered for teardown restore (house rule:
    /// restore 0755 before removal).
    private var permsToRestore: [URL] = []

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("GitWorktreeInventoryTests-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in permsToRestore {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        permsToRestore = []
        if let base { try? fm.removeItem(at: base) }
    }

    // MARK: - Byte-fixture helpers

    /// Build `-z` bytes: every attribute line NUL-TERMINATED, every record
    /// closed by a second NUL. Written out longhand so the fixtures are the
    /// grammar, not a re-implementation of the parser.
    private func porcelainBytes(_ records: [[String]]) -> Data {
        var data = Data()
        for record in records {
            for attribute in record {
                data.append(Data(attribute.utf8))
                data.append(0)
            }
            data.append(0)
        }
        return data
    }

    // MARK: - Parser

    func testParsesMainAndLinkedRecordsWithFirstRecordAsMain() throws {
        let data = porcelainBytes([
            ["worktree /repos/r", "HEAD abc123", "branch refs/heads/main"],
            ["worktree /repos/wt", "HEAD abc123", "branch refs/heads/feature"]
        ])
        let inventory = try XCTUnwrap(GitWorktreeInventory.parse(data))
        XCTAssertEqual(inventory.entries.count, 2)

        let main = try XCTUnwrapElement(inventory.entries, 0)
        XCTAssertTrue(main.isMain, "the FIRST record is the main worktree by git contract")
        XCTAssertEqual(main.path.path, "/repos/r")
        XCTAssertEqual(main.headSHA, "abc123")
        XCTAssertEqual(main.branchRef, "refs/heads/main")
        XCTAssertFalse(main.isDetached)
        XCTAssertFalse(main.isBare)
        XCTAssertFalse(main.isLocked)
        XCTAssertFalse(main.isPrunable)

        let linked = try XCTUnwrapElement(inventory.entries, 1)
        XCTAssertFalse(linked.isMain, "isMain is POSITIONAL, never a path heuristic")
        XCTAssertEqual(linked.branchRef, "refs/heads/feature")

        XCTAssertEqual(inventory.mainRecord, main)
        XCTAssertEqual(inventory.parentRepoWorkingDir?.path, "/repos/r")
    }

    func testParsesDetachedAndBareAndUnknownAttributes() throws {
        let data = porcelainBytes([
            ["worktree /repos/bare.git", "bare", "extension-from-the-future value"],
            ["worktree /repos/det", "HEAD deadbeef", "detached", "another-unknown"]
        ])
        let inventory = try XCTUnwrap(GitWorktreeInventory.parse(data))
        XCTAssertTrue(try XCTUnwrapElement(inventory.entries, 0).isBare)
        XCTAssertNil(try XCTUnwrapElement(inventory.entries, 0).headSHA)
        XCTAssertTrue(try XCTUnwrapElement(inventory.entries, 1).isDetached)
        XCTAssertNil(try XCTUnwrapElement(inventory.entries, 1).branchRef,
                     "`detached` and `branch` are exclusive")
        XCTAssertEqual(inventory.entries.count, 2,
                       "unknown attributes are ignored, never fatal")
    }

    func testParsesLockedAndPrunableWithAndWithoutReasons() throws {
        let data = porcelainBytes([
            ["worktree /repos/r", "HEAD a", "branch refs/heads/main"],
            ["worktree /repos/lockedNoReason", "HEAD a", "detached", "locked"],
            ["worktree /repos/lockedReason", "HEAD a", "detached",
             "locked in use on machine"],
            ["worktree /repos/prunableNoReason", "HEAD a", "detached", "prunable"],
            ["worktree /repos/prunableReason", "HEAD a", "detached",
             "prunable gitdir file points to non-existent location"]
        ])
        let entries = try XCTUnwrap(GitWorktreeInventory.parse(data)).entries
        XCTAssertTrue(try XCTUnwrapElement(entries, 1).isLocked)
        XCTAssertNil(try XCTUnwrapElement(entries, 1).lockReason, "a bare `locked` carries no reason")
        XCTAssertTrue(try XCTUnwrapElement(entries, 2).isLocked)
        XCTAssertEqual(try XCTUnwrapElement(entries, 2).lockReason, "in use on machine")
        XCTAssertTrue(try XCTUnwrapElement(entries, 3).isPrunable)
        XCTAssertNil(try XCTUnwrapElement(entries, 3).prunableReason)
        XCTAssertTrue(try XCTUnwrapElement(entries, 4).isPrunable)
        XCTAssertEqual(
            try XCTUnwrapElement(entries, 4).prunableReason, "gitdir file points to non-existent location"
        )
    }

    func testPathsWithSpacesAndNewlinesSurviveTheZParser() throws {
        let spaced = "/repos/wt one two"
        let newlined = "/repos/wt\nwith\nnewlines"
        let data = porcelainBytes([
            ["worktree /repos/r", "HEAD a", "branch refs/heads/main"],
            ["worktree \(spaced)", "HEAD a", "branch refs/heads/spaced"],
            ["worktree \(newlined)", "HEAD a", "branch refs/heads/newlined"]
        ])
        let entries = try XCTUnwrap(GitWorktreeInventory.parse(data)).entries
        XCTAssertEqual(entries.count, 3, "a newline must NOT split a record")
        XCTAssertEqual(try XCTUnwrapElement(entries, 1).path.path, spaced)
        XCTAssertEqual(try XCTUnwrapElement(entries, 2).path.path, newlined)
    }

    func testDoubleNulRecordBoundariesAreHonoredExactly() throws {
        // Hand-built bytes, not via the helper: one record, then TWO NULs,
        // then the next. A stray extra separator must not fabricate an
        // empty record.
        var data = Data()
        data.append(Data("worktree /repos/r".utf8)); data.append(0)
        data.append(Data("bare".utf8)); data.append(0)
        data.append(0)
        data.append(0) // stray separator
        data.append(Data("worktree /repos/wt".utf8)); data.append(0)
        data.append(Data("detached".utf8)); data.append(0)
        data.append(0)

        let entries = try XCTUnwrap(GitWorktreeInventory.parse(data)).entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(try XCTUnwrapElement(entries, 0).isBare)
        XCTAssertTrue(try XCTUnwrapElement(entries, 1).isDetached)
    }

    func testEmptyOutputParsesToAnEmptyInventory() throws {
        let inventory = try XCTUnwrap(GitWorktreeInventory.parse(Data()))
        XCTAssertEqual(inventory.entries, [])
        XCTAssertNil(inventory.mainRecord)
        XCTAssertNil(inventory.parentRepoWorkingDir)
    }

    func testRecordWithoutAWorktreeAttributeFailsClosed() {
        let data = porcelainBytes([["HEAD abc", "branch refs/heads/main"]])
        XCTAssertNil(
            GitWorktreeInventory.parse(data),
            "a record naming no path must never be guessed at"
        )
    }

    func testUnterminatedFinalFieldFailsClosed() {
        // A stream cut mid-path: half a path is exactly the wrong deletion
        // target the `-z` grammar exists to prevent.
        var data = Data()
        data.append(Data("worktree /repos/r".utf8)); data.append(0)
        data.append(Data("branch refs/heads/ma".utf8)) // no terminating NUL
        XCTAssertNil(GitWorktreePorcelainParser.parse(data))
    }

    func testRecordMissingItsClosingNulFailsClosed() {
        var data = Data()
        data.append(Data("worktree /repos/r".utf8)); data.append(0)
        data.append(Data("branch refs/heads/main".utf8)); data.append(0)
        // Every field terminated, but the record's own closing NUL is gone.
        XCTAssertNil(GitWorktreePorcelainParser.parse(data))
    }

    func testNonUTF8BytesFailClosedRatherThanDecodingLossily() {
        var data = Data("worktree /repos/".utf8)
        data.append(contentsOf: [0xFF, 0xFE])
        data.append(0)
        data.append(0)
        XCTAssertNil(
            GitWorktreePorcelainParser.parse(data),
            "an undecodable path is never a deletion target"
        )
    }

    // MARK: - Parser against REAL git bytes (epic early proof point)

    func testParsesRealGitPorcelainZBytesIncludingLockedAndPrunable() async throws {
        let repository = base.appendingPathComponent("real")
        try GitFixture.makeRepository(at: repository, home: home)
        let spaced = base.appendingPathComponent("wt one")
        let locked = base.appendingPathComponent("wt-locked")
        let orphaned = base.appendingPathComponent("wt-orphaned")
        try GitFixture.git(
            ["-C", repository.path, "worktree", "add", spaced.path, "-b", "feature"],
            home: home
        )
        try GitFixture.git(
            ["-C", repository.path, "worktree", "add", locked.path, "-b", "held"], home: home
        )
        try GitFixture.git(
            ["-C", repository.path, "worktree", "lock", "--reason", "in use", locked.path],
            home: home
        )
        try GitFixture.git(
            ["-C", repository.path, "worktree", "add", orphaned.path, "-b", "orphan"],
            home: home
        )
        try fm.removeItem(at: orphaned)

        let runner = GitCommandRunner(environment: GitFixture.environment(home: home))
        let invocation = await runner.run([
            "-C", repository.path, "-c", "gc.worktreePruneExpire=now",
            "worktree", "list", "--porcelain", "-z"
        ])
        guard case .success(let stdout) = invocation.outcome else {
            return XCTFail("porcelain listing failed: \(invocation.outcome)")
        }
        let inventory = try XCTUnwrap(GitWorktreeInventory.parse(stdout))

        XCTAssertEqual(inventory.entries.count, 4)
        XCTAssertTrue(try XCTUnwrapElement(inventory.entries, 0).isMain)
        XCTAssertEqual(
            inventory.parentRepoWorkingDir?.resolvingSymlinksInPath().path,
            repository.resolvingSymlinksInPath().path
        )
        let spacedRecord = try XCTUnwrap(
            inventory.entries.first { $0.path.lastPathComponent == "wt one" }
        )
        XCTAssertEqual(spacedRecord.branchRef, "refs/heads/feature")
        let lockedRecord = try XCTUnwrap(
            inventory.entries.first { $0.path.lastPathComponent == "wt-locked" }
        )
        XCTAssertTrue(lockedRecord.isLocked)
        XCTAssertEqual(lockedRecord.lockReason, "in use")
        let orphanedRecord = try XCTUnwrap(
            inventory.entries.first { $0.path.lastPathComponent == "wt-orphaned" }
        )
        XCTAssertTrue(orphanedRecord.isPrunable, "prunable IS the orphaned-admin oracle")
        XCTAssertEqual(
            orphanedRecord.prunableReason, "gitdir file points to non-existent location"
        )
    }

    // MARK: - Resolver: hand-built fixtures

    /// Build a hand-made repo/worktree pair so pointer spellings (absolute
    /// vs relative) and back-links can be varied independently of git.
    private func makeHandBuiltPair(
        gitDirName: String = ".git",
        pointerIsRelative: Bool = false,
        backlinkTarget: URL? = nil,
        commonDirSpelling: String = "../.."
    ) throws -> (repository: URL, gitDir: URL, worktree: URL, adminDir: URL) {
        let repository = base.appendingPathComponent("hand/repo")
        let gitDir = repository.appendingPathComponent(gitDirName)
        let worktree = base.appendingPathComponent("hand/wt")
        let adminDir = gitDir.appendingPathComponent("worktrees/wt")
        try fm.createDirectory(at: adminDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)

        let pointer = pointerIsRelative
            ? "gitdir: ../repo/\(gitDirName)/worktrees/wt\n"
            : "gitdir: \(adminDir.path)\n"
        try pointer.write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )
        let backlink = backlinkTarget ?? worktree.appendingPathComponent(".git")
        try "\(backlink.path)\n".write(
            to: adminDir.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8
        )
        try "\(commonDirSpelling)\n".write(
            to: adminDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8
        )
        return (repository, gitDir, worktree, adminDir)
    }

    private func mainRecord(at path: URL, isBare: Bool = false) -> GitWorktreeEntry {
        GitWorktreeEntry(
            path: path, headSHA: "a", branchRef: isBare ? nil : "refs/heads/main",
            isDetached: false, isBare: isBare, isLocked: false, lockReason: nil,
            isPrunable: false, prunableReason: nil, isMain: true
        )
    }

    func testAbsoluteGitdirPointerResolvesWithTheBacklinkEnforced() throws {
        let fixture = try makeHandBuiltPair()
        let resolver = GitWorktreeGitdirResolver()
        let admin = try XCTUnwrap(resolver.adminDirectory(forWorktreeAt: fixture.worktree))
        XCTAssertEqual(
            admin.resolvingSymlinksInPath().path,
            fixture.adminDir.resolvingSymlinksInPath().path
        )
        let common = try XCTUnwrap(resolver.commonGitDirectory(forAdminDirectory: admin))
        XCTAssertEqual(
            common.resolvingSymlinksInPath().path,
            fixture.gitDir.resolvingSymlinksInPath().path,
            "`commondir` is RESOLVED, never path-stripped"
        )
    }

    func testRelativeGitdirPointerResolvesAgainstTheWorktreeDirectory() throws {
        let fixture = try makeHandBuiltPair(pointerIsRelative: true)
        let resolver = GitWorktreeGitdirResolver()
        let admin = try XCTUnwrap(resolver.adminDirectory(forWorktreeAt: fixture.worktree))
        XCTAssertEqual(
            admin.resolvingSymlinksInPath().path,
            fixture.adminDir.resolvingSymlinksInPath().path
        )
    }

    func testForgedBacklinkPointingElsewhereResolvesToNilWithoutThrowing() throws {
        let elsewhere = base.appendingPathComponent("hand/other/.git")
        let fixture = try makeHandBuiltPair(backlinkTarget: elsewhere)
        XCTAssertNil(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: fixture.worktree),
            "a one-way pointer attributes NOWHERE"
        )
    }

    func testMissingBacklinkFileResolvesToNil() throws {
        let fixture = try makeHandBuiltPair()
        try fm.removeItem(at: fixture.adminDir.appendingPathComponent("gitdir"))
        XCTAssertNil(
            GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: fixture.worktree)
        )
    }

    func testAdminDirectoryOutsideAWorktreesContainerResolvesToNil() throws {
        // The pointer must land in `worktrees/<id>` — git's own shape.
        let stray = base.appendingPathComponent("hand/repo/.git/notworktrees/wt")
        let worktree = base.appendingPathComponent("hand/wt")
        try fm.createDirectory(at: stray, withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(stray.path)\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )
        try "\(worktree.appendingPathComponent(".git").path)\n".write(
            to: stray.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8
        )
        XCTAssertNil(GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: worktree))
    }

    func testADirectoryDotGitIsNotALinkedWorktree() throws {
        let main = base.appendingPathComponent("plain")
        try fm.createDirectory(
            at: main.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        XCTAssertNil(GitWorktreeGitdirResolver().adminDirectory(forWorktreeAt: main))
    }

    // MARK: - Resolver: the bare-repository shape proof (fn-4.28)

    /// A hand-built directory carrying git's bare shape, with each
    /// requirement individually forgeable.
    private func makeHandBuiltBare(
        named name: String = "bare.git",
        head: String? = "ref: refs/heads/main\n",
        config: String? = "[core]\n\trepositoryformatversion = 0\n\tbare = true\n",
        refsBackend: String? = "refs",
        withObjects: Bool = true
    ) throws -> URL {
        let bare = base.appendingPathComponent("hand/\(name)")
        try fm.createDirectory(at: bare, withIntermediateDirectories: true)
        if let head {
            try head.write(
                to: bare.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
            )
        }
        if let config {
            try config.write(
                to: bare.appendingPathComponent("config"), atomically: true, encoding: .utf8
            )
        }
        if let refsBackend {
            try fm.createDirectory(
                at: bare.appendingPathComponent(refsBackend),
                withIntermediateDirectories: true
            )
        }
        if withObjects {
            try fm.createDirectory(
                at: bare.appendingPathComponent("objects"),
                withIntermediateDirectories: true
            )
        }
        return bare
    }

    /// CONTROL for every refusal arm below: the intact hand-built shape IS
    /// accepted, so each refusal is attributable to the one requirement its
    /// arm forged, never to the fixture's own reasons.
    func testBareShapeProofAcceptsTheIntactShapeAndARealBareClone() async throws {
        let resolver = GitWorktreeGitdirResolver()
        let hand = try makeHandBuiltBare()
        XCTAssertEqual(
            resolver.bareRepositoryGitDirectory(at: hand)?.path, hand.path
        )

        // A detached 40-hex HEAD is a shape git accepts too.
        let detached = try makeHandBuiltBare(
            named: "detached.git",
            head: "221c2f088de2c34c76347bde00820accad4f529c\n"
        )
        XCTAssertNotNil(resolver.bareRepositoryGitDirectory(at: detached))

        // The reftable refs backend, in place of a `refs` directory.
        let reftable = try makeHandBuiltBare(
            named: "reftable.git", refsBackend: "reftable"
        )
        XCTAssertNotNil(resolver.bareRepositoryGitDirectory(at: reftable))

        // And the real thing, produced by git rather than by hand.
        let seed = base.appendingPathComponent("seed")
        try GitFixture.makeRepository(at: seed, home: home)
        let cloned = base.appendingPathComponent("real.git")
        XCTAssertEqual(
            try GitFixture.git(
                ["clone", "--bare", seed.path, cloned.path], home: home
            ).status, 0
        )
        XCTAssertNotNil(resolver.bareRepositoryGitDirectory(at: cloned))
    }

    /// Every requirement of the bare shape, forged one at a time — a
    /// directory that merely LOOKS bare is refused on whichever leg its
    /// forgery breaks. The intact-shape control above keeps each nil honest.
    func testBareShapeProofRefusesEachForgedRequirement() throws {
        let resolver = GitWorktreeGitdirResolver()

        // HEAD content no git would accept.
        XCTAssertNil(resolver.bareRepositoryGitDirectory(
            at: try makeHandBuiltBare(named: "badhead.git", head: "not a head\n")
        ))
        // A symref outside refs/, and a truncated object id.
        XCTAssertNil(resolver.bareRepositoryGitDirectory(
            at: try makeHandBuiltBare(named: "strayref.git", head: "ref: HEAD2\n")
        ))
        XCTAssertNil(resolver.bareRepositoryGitDirectory(
            at: try makeHandBuiltBare(named: "shortsha.git", head: "abc123\n")
        ))
        // HEAD missing entirely, and HEAD a symlink (never followed).
        XCTAssertNil(resolver.bareRepositoryGitDirectory(
            at: try makeHandBuiltBare(named: "nohead.git", head: nil)
        ))
        let linkHead = try makeHandBuiltBare(named: "linkhead.git", head: nil)
        let realHead = base.appendingPathComponent("hand/elsewhere-HEAD")
        try "ref: refs/heads/main\n".write(to: realHead, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            at: linkHead.appendingPathComponent("HEAD"), withDestinationURL: realHead
        )
        XCTAssertNil(resolver.bareRepositoryGitDirectory(at: linkHead))
        // No object database.
        XCTAssertNil(resolver.bareRepositoryGitDirectory(
            at: try makeHandBuiltBare(named: "noobjects.git", withObjects: false)
        ))
        // No refs backend of either kind.
        XCTAssertNil(resolver.bareRepositoryGitDirectory(
            at: try makeHandBuiltBare(named: "norefs.git", refsBackend: nil)
        ))
        // A git directory that backs a working tree elsewhere: same
        // HEAD/objects/refs shape, `bare = false` — the `--separate-git-dir`
        // layout this proof must not claim.
        XCTAssertNil(resolver.bareRepositoryGitDirectory(
            at: try makeHandBuiltBare(
                named: "sgd.git",
                config: "[core]\n\trepositoryformatversion = 0\n\tbare = false\n"
            )
        ))
        // No config at all: bareness cannot be established, so nothing is.
        XCTAssertNil(resolver.bareRepositoryGitDirectory(
            at: try makeHandBuiltBare(named: "noconfig.git", config: nil)
        ))
    }

    /// The TCC gate holds for the bare proof exactly as it does for the
    /// pointer reads: a deferred directory probes `.absent` at its first
    /// component read, so nothing under it is opened.
    func testADeferredBareDirectoryIsRefusedByTheGateNotInspected() throws {
        let bare = try makeHandBuiltBare(named: "deferred.git")

        let control = DeferralRecordingProvider()
        XCTAssertNotNil(
            GitWorktreeGitdirResolver(identity: control)
                .bareRepositoryGitDirectory(at: bare),
            "the control must accept the same shape the deferral refuses"
        )

        let deferring = DeferralRecordingProvider(deferring: bare.path)
        XCTAssertNil(
            GitWorktreeGitdirResolver(identity: deferring)
                .bareRepositoryGitDirectory(at: bare)
        )
        XCTAssertEqual(
            deferring.realPathArguments(under: bare.path), [],
            "nothing under a deferred directory is ever dereferenced"
        )
    }

    // MARK: - Resolver: the secondary TCC gate reads the pointer FIRST (fn-4.26)

    func testADeferredPointerTargetIsNeverRealpathedBeforeTheGateAnswers() throws {
        let fixture = try makeHandBuiltPair()

        // CONTROL first: the same fixture over the same double WITHOUT a
        // deferral resolves, and the resolution DOES realpath the pointer
        // target — so whatever the deferring half refuses below, it refuses
        // because of the deferral, not for the fixture's own reasons, and the
        // zero below is measured on a live seam.
        let control = DeferralRecordingProvider()
        XCTAssertNotNil(
            GitWorktreeGitdirResolver(identity: control)
                .adminDirectory(forWorktreeAt: fixture.worktree)
        )
        XCTAssertFalse(
            control.realPathArguments(under: fixture.gitDir.path).isEmpty,
            "an ungated resolution realpaths the pointer target — without "
                + "this the deferring half's zero would be vacuous"
        )

        let deferring = DeferralRecordingProvider(deferring: fixture.gitDir.path)
        XCTAssertNil(
            GitWorktreeGitdirResolver(identity: deferring)
                .adminDirectory(forWorktreeAt: fixture.worktree),
            "a deferred pointer target attributes NOWHERE"
        )
        XCTAssertEqual(
            deferring.realPathArguments(under: fixture.gitDir.path), [],
            "realpath(3) traverses every component it resolves — the gate "
                + "must answer before it runs, not after"
        )
    }

    func testADeferredCommondirTargetIsNeverRealpathedBeforeTheGateAnswers() throws {
        // An absolute `commondir` spelling into deferred territory: the
        // file's content is DATA, so the gate must answer for it before
        // `canonicalize` walks it.
        let outside = base.appendingPathComponent("hand/elsewhere-common")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let fixture = try makeHandBuiltPair(commonDirSpelling: outside.path)

        let control = DeferralRecordingProvider()
        XCTAssertNotNil(
            GitWorktreeGitdirResolver(identity: control)
                .commonGitDirectory(forAdminDirectory: fixture.adminDir)
        )
        XCTAssertFalse(
            control.realPathArguments(under: outside.path).isEmpty,
            "an ungated resolution realpaths the commondir target"
        )

        let deferring = DeferralRecordingProvider(deferring: outside.path)
        XCTAssertNil(
            GitWorktreeGitdirResolver(identity: deferring)
                .commonGitDirectory(forAdminDirectory: fixture.adminDir),
            "a deferred commondir target resolves NOWHERE"
        )
        XCTAssertEqual(
            deferring.realPathArguments(under: outside.path), [],
            "the gate answers before the dereference"
        )
    }

    func testADeferredSeparateGitDirPointerFailsCrossValidationWithoutRealpath() throws {
        // A non-bare first record whose `.git` FILE points into deferred
        // territory. `sameLocation`'s fallback canonicalizes BOTH sides when
        // either identity is missing — and a deferred path carries none — so
        // without the pointer gate the COMPARISON itself would traverse the
        // deferred target (and, worse, canonical path equality would answer
        // true for a path the scan was told not to touch).
        let record = base.appendingPathComponent("hand/sep-wd")
        try fm.createDirectory(at: record, withIntermediateDirectories: true)
        let external = base.appendingPathComponent("hand/sep-git")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try "gitdir: \(external.path)\n".write(
            to: record.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        // CONTROL: ungated, the shape cross-validates — the deferring half's
        // false below is the deferral firing, not a broken fixture.
        let control = DeferralRecordingProvider()
        XCTAssertTrue(
            GitWorktreeGitdirResolver(identity: control).crossValidate(
                mainRecord: mainRecord(at: record), against: external
            )
        )

        let deferring = DeferralRecordingProvider(deferring: external.path)
        XCTAssertFalse(
            GitWorktreeGitdirResolver(identity: deferring).crossValidate(
                mainRecord: mainRecord(at: record), against: external
            ),
            "a deferred pointer target fails cross-validation CLOSED"
        )
        XCTAssertEqual(
            deferring.realPathArguments(under: external.path), [],
            "the comparison must not canonicalize a deferred side"
        )
    }

    func testADeferredBacklinkTargetIsNeverRealpathedByTheComparison() throws {
        // The back-link file lives in an UNdeferred admin directory, but its
        // content is data and can spell a path under a deferred ancestor. The
        // back-link can never verify against such a target (the worktree's
        // own `.git` is reachable, or the resolution would have stopped
        // sooner) — so the comparison must fail closed WITHOUT dereferencing
        // the spelled target.
        let elsewhere = base.appendingPathComponent("hand/protected-elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = elsewhere.appendingPathComponent(".git")
        try "gitdir: nothing\n".write(to: target, atomically: true, encoding: .utf8)
        let fixture = try makeHandBuiltPair(backlinkTarget: target)

        // CONTROL: ungated this is the forged-backlink shape — refused, and
        // refused by the COMPARISON (both sides carry identities, so the
        // comparison runs and answers false).
        let control = DeferralRecordingProvider()
        XCTAssertNil(
            GitWorktreeGitdirResolver(identity: control)
                .adminDirectory(forWorktreeAt: fixture.worktree)
        )

        let deferring = DeferralRecordingProvider(deferring: elsewhere.path)
        XCTAssertNil(
            GitWorktreeGitdirResolver(identity: deferring)
                .adminDirectory(forWorktreeAt: fixture.worktree),
            "a deferred back-link target verifies NOTHING"
        )
        XCTAssertEqual(
            deferring.realPathArguments(under: elsewhere.path), [],
            "a deferred side must fail the comparison closed, not be "
                + "canonicalized by its fallback"
        )
    }

    // MARK: - Resolver: real git, ordinary parent

    func testMembershipOfARealLinkedWorktreeResolvesBothAuthorities() async throws {
        let repository = base.appendingPathComponent("ordinary")
        try GitFixture.makeRepository(at: repository, home: home)
        let worktree = base.appendingPathComponent("ordinary-wt")
        try GitFixture.git(
            ["-C", repository.path, "worktree", "add", worktree.path, "-b", "feature"],
            home: home
        )
        let inventory = try await listing(of: repository)
        let membership = try XCTUnwrap(
            GitWorktreeGitdirResolver().membership(forWorktreeAt: worktree, in: inventory)
        )
        XCTAssertEqual(
            membership.parentGitDir.resolvingSymlinksInPath().path,
            repository.appendingPathComponent(".git").resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            membership.parentRepoWorkingDir.resolvingSymlinksInPath().path,
            repository.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            membership.parentAdminContainer.path,
            membership.parentGitDir.appendingPathComponent("worktrees").path,
            "the admin container is derived ONLY from parentGitDir"
        )
    }

    func testWorktreeOfRepoAInsideRepoBAttributesToAOnly() async throws {
        let repoA = base.appendingPathComponent("A")
        let repoB = base.appendingPathComponent("B")
        try GitFixture.makeRepository(at: repoA, home: home)
        try GitFixture.makeRepository(at: repoB, home: home)
        // Physically INSIDE B, administratively A's.
        let nested = repoB.appendingPathComponent("nested-wt")
        try GitFixture.git(
            ["-C", repoA.path, "worktree", "add", nested.path, "-b", "feature"], home: home
        )

        let resolver = GitWorktreeGitdirResolver()
        let inventoryA = try await listing(of: repoA)
        let membership = try XCTUnwrap(
            resolver.membership(forWorktreeAt: nested, in: inventoryA)
        )
        XCTAssertEqual(
            membership.parentRepoWorkingDir.resolvingSymlinksInPath().path,
            repoA.resolvingSymlinksInPath().path
        )

        // B's inventory names B as the main record — the cross-validation
        // catches the mismatch and the membership fails CLOSED.
        let inventoryB = try await listing(of: repoB)
        XCTAssertNil(
            resolver.membership(forWorktreeAt: nested, in: inventoryB),
            "a first record whose .git resolves to a DIFFERENT common git dir fails closed"
        )
    }

    func testStalePointerToADeletedAdminDirectoryFailsClosed() async throws {
        let repository = base.appendingPathComponent("stale")
        try GitFixture.makeRepository(at: repository, home: home)
        let worktree = base.appendingPathComponent("stale-wt")
        try GitFixture.git(
            ["-C", repository.path, "worktree", "add", worktree.path, "-b", "feature"],
            home: home
        )
        let inventory = try await listing(of: repository)
        try fm.removeItem(
            at: repository.appendingPathComponent(".git/worktrees/stale-wt")
        )
        XCTAssertNil(
            GitWorktreeGitdirResolver().membership(forWorktreeAt: worktree, in: inventory)
        )
    }

    // MARK: - Resolver: BARE parent

    func testBareParentMembershipCarriesTheBareDirectoryAsBothAuthorities() async throws {
        let bare = base.appendingPathComponent("bare.git")
        try GitFixture.git(
            ["-c", "init.defaultBranch=main", "init", "--bare", bare.path], home: home
        )
        // A bare repo needs a commit before `worktree add` can check one out.
        let seed = base.appendingPathComponent("seed")
        try GitFixture.makeRepository(at: seed, home: home)
        try GitFixture.git(["-C", seed.path, "push", bare.path, "main"], home: home)

        let worktree = base.appendingPathComponent("bare-wt")
        let added = try GitFixture.git(
            ["-C", bare.path, "worktree", "add", worktree.path, "-b", "feature", "main"],
            home: home
        )
        XCTAssertEqual(added.status, 0, "worktree add against a bare main")

        let inventory = try await listing(of: bare)
        let main = try XCTUnwrap(inventory.mainRecord)
        XCTAssertTrue(main.isBare, "the fixture exercises the BARE cross-validation branch")

        let membership = try XCTUnwrap(
            GitWorktreeGitdirResolver().membership(forWorktreeAt: worktree, in: inventory)
        )
        XCTAssertEqual(
            membership.parentGitDir.resolvingSymlinksInPath().path,
            bare.resolvingSymlinksInPath().path,
            "parentGitDir IS the bare directory"
        )
        XCTAssertEqual(
            membership.parentRepoWorkingDir.resolvingSymlinksInPath().path,
            bare.resolvingSymlinksInPath().path,
            "parentRepoWorkingDir IS the bare directory — the -C target git accepts"
        )
        XCTAssertEqual(
            membership.parentAdminContainer.path,
            membership.parentGitDir.appendingPathComponent("worktrees").path
        )
        XCTAssertNotEqual(
            membership.parentAdminContainer.path,
            membership.parentRepoWorkingDir
                .appendingPathComponent(".git/worktrees").path,
            "a `<wd>/.git/worktrees` reconstruction would mis-path a bare parent"
        )
    }

    func testBareFirstRecordWhoseCanonicalPathDiffersFromTheCommonGitDirFailsClosed()
    async throws {
        let bare = base.appendingPathComponent("bare2.git")
        try GitFixture.git(
            ["-c", "init.defaultBranch=main", "init", "--bare", bare.path], home: home
        )
        let seed = base.appendingPathComponent("seed2")
        try GitFixture.makeRepository(at: seed, home: home)
        try GitFixture.git(["-C", seed.path, "push", bare.path, "main"], home: home)
        let worktree = base.appendingPathComponent("bare2-wt")
        try GitFixture.git(
            ["-C", bare.path, "worktree", "add", worktree.path, "-b", "feature", "main"],
            home: home
        )
        let inventory = try await listing(of: bare)
        let real = try XCTUnwrap(inventory.mainRecord)

        // Same `bare` attribute, a DIFFERENT path: the branch must reject it.
        let impostor = base.appendingPathComponent("some-other-dir")
        try fm.createDirectory(at: impostor, withIntermediateDirectories: true)
        let forged = GitWorktreeInventory(entries: [
            GitWorktreeEntry(
                path: impostor, headSHA: real.headSHA, branchRef: nil, isDetached: false,
                isBare: true, isLocked: false, lockReason: nil, isPrunable: false,
                prunableReason: nil, isMain: true
            )
        ])
        XCTAssertNil(
            GitWorktreeGitdirResolver().membership(forWorktreeAt: worktree, in: forged)
        )
    }

    // MARK: - Resolver: SEPARATE-GIT-DIR

    func testSeparateGitDirParentGitDirIsExternalAndNeverPathDerived() async throws {
        // `--separate-git-dir=<external>/.git`: the git dir lives OUTSIDE
        // the working tree, so no path-derivation from the working tree can
        // reach it — the resolver's `commondir` walk must.
        let external = base.appendingPathComponent("external")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        let externalGitDir = external.appendingPathComponent(".git")
        let workingTree = base.appendingPathComponent("sgd-wd")
        try fm.createDirectory(at: workingTree, withIntermediateDirectories: true)
        try GitFixture.git(
            ["-c", "init.defaultBranch=main",
             "init", "--separate-git-dir=\(externalGitDir.path)", workingTree.path],
            home: home
        )
        try GitFixture.git(
            ["-C", workingTree.path, "-c", "user.name=t", "-c", "user.email=t@t",
             "commit", "--allow-empty", "-m", "x"],
            home: home
        )
        let worktree = base.appendingPathComponent("sgd-wt")
        try GitFixture.git(
            ["-C", workingTree.path, "worktree", "add", worktree.path, "-b", "feature"],
            home: home
        )

        let inventory = try await listing(of: workingTree)
        let main = try XCTUnwrap(inventory.mainRecord)
        XCTAssertFalse(main.isBare, "the fixture exercises the NON-BARE branch")

        let membership = try XCTUnwrap(
            GitWorktreeGitdirResolver().membership(forWorktreeAt: worktree, in: inventory)
        )
        XCTAssertEqual(
            membership.parentGitDir.resolvingSymlinksInPath().path,
            externalGitDir.resolvingSymlinksInPath().path,
            "parentGitDir is the EXTERNAL git dir"
        )
        XCTAssertNotEqual(
            membership.parentGitDir.resolvingSymlinksInPath().path,
            workingTree.appendingPathComponent(".git").resolvingSymlinksInPath().path,
            "it is emphatically not `<wd>/.git`"
        )
        XCTAssertEqual(
            membership.parentRepoWorkingDir.path, main.path.path,
            "parentRepoWorkingDir's authority is the porcelain FIRST record"
        )
    }

    func testFirstRecordAuthorityWinsWhenTheGitDirsParentIsNotTheWorkingTree() throws {
        // The shape `--separate-git-dir` is SUPPOSED to produce, built by
        // hand because git's own `worktree list` cannot report it (see the
        // test above): the common git dir is external and its PARENT is a
        // different directory from the working tree. Path-deriving the `-C`
        // target from `parentGitDir` would yield `external/` — a wrong
        // target and a wrong containment decision. The porcelain FIRST
        // record is the authority instead, and cross-validation confirms it.
        let root = base.appendingPathComponent("sgd-hand")
        let external = root.appendingPathComponent("external")
        let gitDir = external.appendingPathComponent("gitdir-home")
        let workingTree = root.appendingPathComponent("checkout")
        let worktree = root.appendingPathComponent("linked")
        let adminDir = gitDir.appendingPathComponent("worktrees/linked")
        try fm.createDirectory(at: adminDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: workingTree, withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)

        try "gitdir: \(gitDir.path)\n".write(
            to: workingTree.appendingPathComponent(".git"),
            atomically: true, encoding: .utf8
        )
        try "gitdir: \(adminDir.path)\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )
        try "\(worktree.appendingPathComponent(".git").path)\n".write(
            to: adminDir.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8
        )
        try "../..\n".write(
            to: adminDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8
        )

        let inventory = GitWorktreeInventory(entries: [mainRecord(at: workingTree)])
        let membership = try XCTUnwrap(
            GitWorktreeGitdirResolver().membership(forWorktreeAt: worktree, in: inventory)
        )
        XCTAssertEqual(
            membership.parentRepoWorkingDir.path, workingTree.path,
            "parentRepoWorkingDir is the FIRST RECORD"
        )
        XCTAssertEqual(
            membership.parentGitDir.resolvingSymlinksInPath().path,
            gitDir.resolvingSymlinksInPath().path
        )
        XCTAssertNotEqual(
            membership.parentGitDir.deletingLastPathComponent()
                .resolvingSymlinksInPath().path,
            membership.parentRepoWorkingDir.resolvingSymlinksInPath().path,
            "the git dir's PARENT is not the working tree — path derivation would be wrong"
        )
        XCTAssertEqual(
            membership.parentAdminContainer.resolvingSymlinksInPath().path,
            gitDir.appendingPathComponent("worktrees").resolvingSymlinksInPath().path,
            "the admin container comes from parentGitDir, never from the working tree"
        )
    }

    func testSeparateGitDirWhoseFirstRecordHasNoDotGitFailsClosed() async throws {
        // EMPIRICAL (git 2.50.1): git derives the main record's path by
        // stripping a `/.git` suffix from the common git dir, so
        // `--separate-git-dir=<external>` (no `.git` suffix) makes the first
        // record `<external>` — a path with no `.git` of its own. The
        // NON-BARE cross-validation branch finds nothing to resolve and the
        // membership fails CLOSED, which is the safe direction.
        let external = base.appendingPathComponent("external-nosuffix")
        let workingTree = base.appendingPathComponent("sgd2-wd")
        try fm.createDirectory(at: workingTree, withIntermediateDirectories: true)
        try GitFixture.git(
            ["-c", "init.defaultBranch=main",
             "init", "--separate-git-dir=\(external.path)", workingTree.path],
            home: home
        )
        try GitFixture.git(
            ["-C", workingTree.path, "-c", "user.name=t", "-c", "user.email=t@t",
             "commit", "--allow-empty", "-m", "x"],
            home: home
        )
        let worktree = base.appendingPathComponent("sgd2-wt")
        try GitFixture.git(
            ["-C", workingTree.path, "worktree", "add", worktree.path, "-b", "feature"],
            home: home
        )

        let inventory = try await listing(of: workingTree)
        let main = try XCTUnwrap(inventory.mainRecord)
        XCTAssertEqual(
            main.path.resolvingSymlinksInPath().path,
            external.resolvingSymlinksInPath().path,
            "git reports the external git dir as the main record here"
        )
        XCTAssertFalse(fm.fileExists(atPath: external.appendingPathComponent(".git").path))
        XCTAssertNil(
            GitWorktreeGitdirResolver().membership(forWorktreeAt: worktree, in: inventory),
            "no cross-validation evidence ⇒ fail closed, never a guessed -C target"
        )
    }

    // MARK: - Shared oracle → admin mapper

    /// A repo with `orphanCount` rm-rf'ed worktrees plus one healthy one.
    private func makeOrphanFixture(
        named name: String, orphanCount: Int = 1
    ) async throws -> (repository: URL, container: URL, inventory: GitWorktreeInventory,
                       orphans: [URL]) {
        let repository = base.appendingPathComponent(name)
        try GitFixture.makeRepository(at: repository, home: home)
        let healthy = base.appendingPathComponent("\(name)-healthy")
        try GitFixture.git(
            ["-C", repository.path, "worktree", "add", healthy.path, "-b", "healthy"],
            home: home
        )
        var orphans: [URL] = []
        for index in 0..<orphanCount {
            let orphan = base.appendingPathComponent("\(name)-orphan-\(index)")
            try GitFixture.git(
                ["-C", repository.path, "worktree", "add", orphan.path,
                 "-b", "orphan-\(index)"],
                home: home
            )
            try fm.removeItem(at: orphan)
            orphans.append(orphan)
        }
        let inventory = try await listing(of: repository, pruneExpireNow: true)
        let membership = try XCTUnwrap(
            GitWorktreeGitdirResolver().membership(forWorktreeAt: healthy, in: inventory)
        )
        return (repository, membership.parentAdminContainer, inventory, orphans)
    }

    func testMatchedPrunableRecordsMapToTheirAdminDirectories() async throws {
        let fixture = try await makeOrphanFixture(named: "map-complete", orphanCount: 2)
        let verdict = GitWorktreeAdminMapper()
            .map(prunableRecordsIn: fixture.inventory.entries,
                 adminContainer: fixture.container)
        guard case .complete(let directories) = verdict else {
            return XCTFail("expected complete, got \(verdict)")
        }
        XCTAssertEqual(directories.count, 2)
        // The admin directory NAME is git-sanitized, so the mapping must run
        // through the back-links — never through the worktree's basename.
        for directory in directories {
            XCTAssertEqual(
                directory.deletingLastPathComponent().path, fixture.container.path
            )
            XCTAssertTrue(
                fm.fileExists(atPath: directory.appendingPathComponent("gitdir").path)
            )
        }
    }

    func testNoPrunableRecordsAndNoContainerIsStillComplete() throws {
        // The ONLY benign container failure: a repository that never had a
        // linked worktree.
        let container = base.appendingPathComponent("never-created/worktrees")
        let verdict = GitWorktreeAdminMapper()
            .map(prunableRecordsIn: [], adminContainer: container)
        XCTAssertEqual(verdict, .complete(adminDirectories: []))
    }

    func testAbsentContainerWithPrunableRecordsIsIncomplete() throws {
        let container = base.appendingPathComponent("never-created/worktrees")
        let record = GitWorktreeEntry(
            path: base.appendingPathComponent("ghost"), headSHA: "a", branchRef: nil,
            isDetached: true, isBare: false, isLocked: false, lockReason: nil,
            isPrunable: true, prunableReason: "gone", isMain: false
        )
        guard case .incomplete(let reason) = GitWorktreeAdminMapper()
            .map(prunableRecordsIn: [record], adminContainer: container)
        else { return XCTFail("an absent container cannot account for a prunable record") }
        XCTAssertTrue(reason.contains("is absent"), reason)
    }

    func testContainerThatIsNotADirectoryIsIncompleteEvenWithNothingPrunable() throws {
        // A permission denial, an I/O error, or a container that is a FILE
        // must never read as "nothing to prune" — this mapper's own
        // enumeration would still traverse it, and a set it cannot account
        // for is not a set it may call complete.
        let container = base.appendingPathComponent("file-container")
        try "not a directory".write(to: container, atomically: true, encoding: .utf8)
        guard case .incomplete(let reason) = GitWorktreeAdminMapper()
            .map(prunableRecordsIn: [], adminContainer: container)
        else { return XCTFail("a non-directory container must suppress") }
        XCTAssertTrue(reason.contains("is not a directory"), reason)
    }

    func testUnreadableContainerIsIncompleteEvenWithNothingPrunable() throws {
        let container = base.appendingPathComponent("locked-container")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: container.path)
        permsToRestore.append(container)
        guard case .incomplete(let reason) = GitWorktreeAdminMapper()
            .map(prunableRecordsIn: [], adminContainer: container)
        else { return XCTFail("an unenumerable container must suppress") }
        XCTAssertTrue(reason.contains("could not be read"), reason)
    }

    func testUnmappablePrunableRecordYieldsIncompleteNamingTheEntry() async throws {
        let fixture = try await makeOrphanFixture(named: "map-unmappable")
        // A prunable record git knows nothing about: no back-link can reach it.
        let ghost = base.appendingPathComponent("ghost-worktree")
        var entries = fixture.inventory.entries
        entries.append(GitWorktreeEntry(
            path: ghost, headSHA: "a", branchRef: nil, isDetached: true, isBare: false,
            isLocked: false, lockReason: nil, isPrunable: true,
            prunableReason: "gitdir file points to non-existent location", isMain: false
        ))
        let verdict = GitWorktreeAdminMapper()
            .map(prunableRecordsIn: entries, adminContainer: fixture.container)
        guard case .incomplete(let reason) = verdict else {
            return XCTFail("expected incomplete, got \(verdict)")
        }
        XCTAssertTrue(reason.contains(ghost.path), "the reason NAMES the entry: \(reason)")
    }

    /// TWO ADMIN ENTRIES, ONE BACK-LINK: ambiguous, therefore refused
    /// (PR #460 codex r21).
    ///
    /// The `!matches.isEmpty` guard refused ZERO matches and said nothing
    /// about several. Git can list one duplicate `locked` and the other
    /// `prunable`; `removalTargets` drops the locked RECORD, but this mapper
    /// works from the back-link, so the locked entry's DIRECTORY was mapped in
    /// on the strength of the other record — its lock never consulted, and
    /// detached-HEAD preservation applied only to the record that was seen.
    ///
    /// MUTATION: restore `guard !matches.isEmpty` alone (drop the
    /// `matches.count == 1` guard) and this cell goes red with BOTH
    /// directories returned for one record.
    func testDuplicateAdminBackLinksAreRefusedRatherThanBothMapped()
        async throws
    {
        let fixture = try await makeOrphanFixture(named: "map-ambiguous")
        let orphan = try XCTUnwrap(fixture.orphans.first)

        // A SECOND admin entry carrying the SAME `gitdir` back-link as the
        // first. This is the on-disk shape; nothing here forges a record.
        let original = try XCTUnwrap(
            try fm.contentsOfDirectory(
                at: fixture.container, includingPropertiesForKeys: nil
            ).first { (try? String(
                contentsOf: $0.appendingPathComponent("gitdir"), encoding: .utf8
            ))?.contains(orphan.lastPathComponent) == true }
        )
        let twin = fixture.container.appendingPathComponent("\(original.lastPathComponent)-twin")
        try fm.copyItem(at: original, to: twin)

        let verdict = GitWorktreeAdminMapper()
            .map(prunableRecordsIn: fixture.inventory.entries,
                 adminContainer: fixture.container)

        guard case .incomplete(let reason) = verdict else {
            return XCTFail(
                "two admin entries share one back-link, so which describes the "
                    + "record is unproven — the mapper must refuse, got \(verdict)"
            )
        }
        XCTAssertTrue(
            reason.contains(original.lastPathComponent)
                && reason.contains(twin.lastPathComponent),
            "the reason must NAME the colliding directories so the user can "
                + "look: \(reason)"
        )
    }

    func testLockedPrunableRecordsAreExcludedWithoutSuppressingTheVerdict() async throws {
        let fixture = try await makeOrphanFixture(named: "map-locked")
        var entries = fixture.inventory.entries
        entries.append(GitWorktreeEntry(
            path: base.appendingPathComponent("locked-and-missing"), headSHA: "a",
            branchRef: nil, isDetached: true, isBare: false, isLocked: true,
            lockReason: "held", isPrunable: true, prunableReason: "gone", isMain: false
        ))
        let verdict = GitWorktreeAdminMapper()
            .map(prunableRecordsIn: entries, adminContainer: fixture.container)
        guard case .complete(let directories) = verdict else {
            return XCTFail("locked admin dirs are excluded, not incomplete: \(verdict)")
        }
        XCTAssertEqual(directories.count, 1, "only the unlocked orphan is disclosed")
    }

    func testSymlinkedAdminEntryYieldsIncompleteBeforeAnyBacklinkIsRead() async throws {
        let fixture = try await makeOrphanFixture(named: "map-symlink-entry")
        // The symlink points at a REAL, VALID admin directory: an
        // implementation that read back-links before gating would map it and
        // report `.complete`.
        let real = try XCTUnwrap(
            fm.contentsOfDirectory(atPath: fixture.container.path).first
        )
        let link = fixture.container.appendingPathComponent("zz-linked")
        try fm.createSymbolicLink(
            at: link, withDestinationURL: fixture.container.appendingPathComponent(real)
        )
        let verdict = GitWorktreeAdminMapper()
            .map(prunableRecordsIn: fixture.inventory.entries,
                 adminContainer: fixture.container)
        guard case .incomplete(let reason) = verdict else {
            return XCTFail("a symlinked admin entry must suppress: \(verdict)")
        }
        XCTAssertTrue(reason.contains(link.path), reason)
        XCTAssertTrue(reason.contains("not a real directory"), reason)
    }

    func testSymlinkedGitdirFileYieldsIncomplete() async throws {
        let fixture = try await makeOrphanFixture(named: "map-symlink-gitdir")
        let entryName = try XCTUnwrap(
            fm.contentsOfDirectory(atPath: fixture.container.path).sorted().first
        )
        let entry = fixture.container.appendingPathComponent(entryName)
        let backlink = entry.appendingPathComponent("gitdir")
        let elsewhere = base.appendingPathComponent("relocated-gitdir")
        try fm.moveItem(at: backlink, to: elsewhere)
        try fm.createSymbolicLink(at: backlink, withDestinationURL: elsewhere)

        let verdict = GitWorktreeAdminMapper()
            .map(prunableRecordsIn: fixture.inventory.entries,
                 adminContainer: fixture.container)
        guard case .incomplete(let reason) = verdict else {
            return XCTFail("a non-regular gitdir must suppress: \(verdict)")
        }
        XCTAssertTrue(reason.contains("no regular gitdir file"), reason)
    }

    func testEntryCanonicalizingOutsideTheContainerYieldsIncomplete() async throws {
        let fixture = try await makeOrphanFixture(named: "map-escape")
        let entryName = try XCTUnwrap(
            fm.contentsOfDirectory(atPath: fixture.container.path).sorted().first
        )
        let entry = fixture.container.appendingPathComponent(entryName)
        let provider = RedirectingIdentityProvider()
        provider.redirects[entry.path] = base.appendingPathComponent("escaped").path

        let verdict = GitWorktreeAdminMapper(identity: provider)
            .map(prunableRecordsIn: fixture.inventory.entries,
                 adminContainer: fixture.container)
        guard case .incomplete(let reason) = verdict else {
            return XCTFail("an escaping entry must suppress: \(verdict)")
        }
        XCTAssertTrue(reason.contains("canonicalizes outside"), reason)
    }

    func testEntryOnAnotherDeviceYieldsIncomplete() async throws {
        let fixture = try await makeOrphanFixture(named: "map-device")
        let entryName = try XCTUnwrap(
            fm.contentsOfDirectory(atPath: fixture.container.path).sorted().first
        )
        let entry = fixture.container.appendingPathComponent(entryName)
        let provider = RedirectingIdentityProvider()
        provider.deviceOverrides[entry.path] = 0xDEAD_BEEF

        let verdict = GitWorktreeAdminMapper(identity: provider)
            .map(prunableRecordsIn: fixture.inventory.entries,
                 adminContainer: fixture.container)
        guard case .incomplete(let reason) = verdict else {
            return XCTFail("a cross-device entry must suppress: \(verdict)")
        }
        XCTAssertTrue(reason.contains("device"), reason)
    }

    // MARK: - Detached-HEAD preservation (PR #460 codex r18, C4)

    /// One prunable record, shaped by the caller.
    private func prunableRecord(
        named name: String, detached: Bool, headSHA: String?, locked: Bool = false
    ) -> GitWorktreeEntry {
        GitWorktreeEntry(
            path: base.appendingPathComponent(name), headSHA: headSHA,
            branchRef: detached ? nil : "refs/heads/\(name)",
            isDetached: detached, isBare: false, isLocked: locked, lockReason: nil,
            isPrunable: true, prunableReason: "gitdir file points to non-existent location",
            isMain: false
        )
    }

    /// Records every argv the proof fires and answers each with a script.
    private func proofRecorder(
        _ answer: @escaping @Sendable ([String]) -> GitCommandOutcome
    ) -> (run: @Sendable ([String]) async -> GitCommandOutcome, argvs: () -> [[String]]) {
        let box = ArgvBox()
        return (
            run: { arguments in
                box.record(arguments)
                return answer(arguments)
            },
            argvs: { box.recorded }
        )
    }

    /// AN ATTACHED PRUNABLE RECORD IS NEVER QUERIED, and that is the cheap
    /// half of the guarantee: git refuses to delete a branch a registered
    /// worktree holds, so the ref that names the tip outlives the prune.
    ///
    /// MUTATION: drop the `where record.isDetached` clause on the proof's
    /// loop — RED here, because the attached record then fires two queries.
    func testAnAttachedPrunableRecordFiresNoReachabilityQueryAtAll() async throws {
        let recorder = proofRecorder { _ in .success(stdout: Data()) }
        let verdict = await GitOrphanedHeadPreservation.prove(
            prunableRecords: [
                prunableRecord(named: "attached", detached: false, headSHA: String(repeating: "a", count: 40)),
            ],
            repositoryAt: base, run: recorder.run
        )
        XCTAssertEqual(verdict, .nothingOrphaned)
        XCTAssertEqual(recorder.argvs(), [], "an attached record needs no proof")
    }

    /// A COMMIT THAT IS ALREADY GONE CANNOT BE ORPHANED, and refusing on it
    /// would be a refusal no user action could ever clear. `rev-parse
    /// --verify --quiet` answers a SILENT exit 1 for it (measured, git
    /// 2.50.1).
    ///
    /// MUTATION: treat the silent exit 1 as a refusal — RED here.
    func testAMissingCommitObjectIsNotSomethingAPruneCanDestroy() async throws {
        let recorder = proofRecorder { arguments in
            arguments.contains("rev-parse")
                ? .failure(exitCode: 1, stderr: "")
                : .success(stdout: Data("1\n".utf8))
        }
        let verdict = await GitOrphanedHeadPreservation.prove(
            prunableRecords: [
                prunableRecord(named: "vanished", detached: true, headSHA: String(repeating: "b", count: 40)),
            ],
            repositoryAt: base, run: recorder.run
        )
        XCTAssertEqual(
            verdict, .nothingOrphaned,
            "a commit the object database no longer holds is not at risk"
        )
        XCTAssertEqual(
            recorder.argvs().count, 1,
            "and the reachability query is never reached: \(recorder.argvs())"
        )
    }

    /// EVERY OTHER READING OF EITHER QUERY REFUSES. A nonzero exit that SAYS
    /// something is not "the object is absent" — the same discriminator the
    /// D6 ladder uses — and a timeout, an unavailable git or an
    /// unparseable count are all readings that failed to prove the commit
    /// survives.
    func testEveryUnprovableReadingOfEitherQueryRefusesTheWholePrune() async throws {
        let oid = String(repeating: "c", count: 40)
        let cases: [(name: String, answer: @Sendable ([String]) -> GitCommandOutcome, fragment: String)] = [
            ("noisy-exit-1", { arguments in
                arguments.contains("rev-parse")
                    ? .failure(exitCode: 1, stderr: "warning: ignoring broken ref")
                    : .success(stdout: Data("0\n".utf8))
            }, "still exists could not be answered"),
            ("existence-timeout", { arguments in
                arguments.contains("rev-parse") ? .timeout : .success(stdout: Data("0\n".utf8))
            }, "existence check for the detached commit"),
            ("existence-unavailable", { arguments in
                arguments.contains("rev-parse")
                    ? .gitUnavailable : .success(stdout: Data("0\n".utf8))
            }, "git became unavailable while checking the detached commit"),
            ("reachability-failure", { arguments in
                arguments.contains("rev-list")
                    ? .failure(exitCode: 128, stderr: "fatal: bad object")
                    : .success(stdout: Data(oid.utf8))
            }, "reachable from any ref could not be answered"),
            ("reachability-timeout", { arguments in
                arguments.contains("rev-list") ? .timeout : .success(stdout: Data(oid.utf8))
            }, "reachability query for the detached commit"),
            ("reachability-unavailable", { arguments in
                arguments.contains("rev-list")
                    ? .gitUnavailable : .success(stdout: Data(oid.utf8))
            }, "git became unavailable while checking whether"),
            ("unparseable-count", { arguments in
                arguments.contains("rev-list")
                    ? .success(stdout: Data("no idea\n".utf8))
                    : .success(stdout: Data(oid.utf8))
            }, "produced no count"),
            ("unreachable", { arguments in
                arguments.contains("rev-list")
                    ? .success(stdout: Data("1\n".utf8))
                    : .success(stdout: Data(oid.utf8))
            }, "no branch, tag or other ref reaches that commit"),
        ]
        for (name, answer, fragment) in cases {
            let recorder = proofRecorder(answer)
            let verdict = await GitOrphanedHeadPreservation.prove(
                prunableRecords: [
                    prunableRecord(named: "detached", detached: true, headSHA: oid),
                ],
                repositoryAt: base, run: recorder.run
            )
            guard case .refuse(let reason) = verdict else {
                XCTFail("\(name): expected a refusal, got \(verdict)")
                continue
            }
            XCTAssertTrue(reason.contains(fragment), "\(name): \(reason)")
        }
    }

    /// A DETACHED RECORD WITH NO USABLE OBJECT NAME is refused before git is
    /// asked anything: a revision this process cannot even spell is one it
    /// cannot prove safe.
    func testADetachedRecordWithNoUsableCommitNameRefusesBeforeAnyQuery() async throws {
        for headSHA in [nil, "", "not-a-sha", String(repeating: "z", count: 40)] {
            let recorder = proofRecorder { _ in .success(stdout: Data("0".utf8)) }
            let verdict = await GitOrphanedHeadPreservation.prove(
                prunableRecords: [
                    prunableRecord(named: "nameless", detached: true, headSHA: headSHA),
                ],
                repositoryAt: base, run: recorder.run
            )
            guard case .refuse(let reason) = verdict else {
                XCTFail("expected a refusal for HEAD \(headSHA ?? "nil"), got \(verdict)")
                continue
            }
            XCTAssertTrue(reason.contains("named no usable commit"), reason)
            XCTAssertEqual(recorder.argvs(), [], "git must not be asked")
        }
    }

    /// THE ARGVS ARE THE MEASURED ONES. `--single-worktree` is the whole
    /// correctness of the reachability query: without it `--all` pretends the
    /// DOOMED record's own HEAD is a ref, and the query answers "reachable"
    /// for the very commit `git fsck` calls unreachable one command later.
    func testTheProofFiresTheTwoMeasuredReadOnlyArgvs() async throws {
        let oid = String(repeating: "d", count: 40)
        let recorder = proofRecorder { arguments in
            arguments.contains("rev-list")
                ? .success(stdout: Data("0\n".utf8))
                : .success(stdout: Data(oid.utf8))
        }
        let verdict = await GitOrphanedHeadPreservation.prove(
            prunableRecords: [
                prunableRecord(named: "reachable", detached: true, headSHA: oid),
            ],
            repositoryAt: base, run: recorder.run
        )
        XCTAssertEqual(verdict, .nothingOrphaned)
        XCTAssertEqual(recorder.argvs(), [
            GitOrphanedHeadPreservation.commitExistenceArguments(
                repositoryAt: base, commit: oid
            ),
            GitOrphanedHeadPreservation.unreachableCountArguments(
                repositoryAt: base, commit: oid
            ),
        ])
        let reachability = GitOrphanedHeadPreservation.unreachableCountArguments(
            repositoryAt: base, commit: oid
        )
        XCTAssertTrue(reachability.contains("--single-worktree"), "\(reachability)")
        // D17: both are pure reads of the object graph.
        XCTAssertEqual(
            GitSafetyProfile.classify(
                GitOrphanedHeadPreservation.commitExistenceArguments(
                    repositoryAt: base, commit: oid
                )
            ), .readOnly
        )
        XCTAssertEqual(GitSafetyProfile.classify(reachability), .readOnly)
    }

    /// THE FILTER IS ONE SPELLING. A locked prunable record is not in the
    /// removal set, so it is not in the set the proof speaks for either.
    func testTheRemovalTargetFilterIsSharedAndExcludesLockedRecords() {
        let entries = [
            prunableRecord(named: "unlocked", detached: true, headSHA: nil),
            prunableRecord(named: "locked", detached: true, headSHA: nil, locked: true),
        ]
        XCTAssertEqual(
            GitWorktreeAdminMapper.removalTargets(in: entries).map(\.path.lastPathComponent),
            ["unlocked"]
        )
    }

    // MARK: - Listing helper

    private func listing(
        of repository: URL, pruneExpireNow: Bool = false
    ) async throws -> GitWorktreeInventory {
        var arguments = ["-C", repository.path]
        if pruneExpireNow {
            arguments += ["-c", "gc.worktreePruneExpire=now"]
        }
        arguments += ["worktree", "list", "--porcelain", "-z"]
        let runner = GitCommandRunner(environment: GitFixture.environment(home: home))
        let invocation = await runner.run(arguments)
        guard case .success(let stdout) = invocation.outcome else {
            XCTFail("porcelain listing failed: \(invocation.outcome)")
            throw FixtureFailure.listingFailed
        }
        return try XCTUnwrap(GitWorktreeInventory.parse(stdout))
    }

    private enum FixtureFailure: Error { case listingFailed }
}

/// Thread-safe argv recorder for the preservation proof's injected runner
/// (PR #460 codex r18, C4). A plain array would be mutated from inside a
/// `@Sendable` closure.
final class ArgvBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []

    func record(_ arguments: [String]) {
        lock.lock()
        stored.append(arguments)
        lock.unlock()
    }

    var recorded: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
