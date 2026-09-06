import XCTest
@testable import Cacheout

/// THE CALL SITES, not the primitive (PR #461 merge gate r4, P5).
///
/// `smallRegularFile` has nine cells of its own, and they proved nothing
/// about whether anything USES it: the gate reverted two of the eight
/// converted sites to their pre-PR `String(contentsOf:)` / `Data(contentsOf:)`
/// shape and the FULL 1692-cell suite stayed green. A guard with no failing
/// test is unevidenced, and eight of them were.
///
/// The steady state is not the gap. Every one of these sites still asks
/// `probeKind` first, so a symlink that is simply SITTING there is refused by
/// the probe under either shape. What the descriptor buys is the RACE: the
/// probe answers about a path, and a path-based read then resolves that path
/// AGAIN. These cells stage exactly that window — the provider plants the
/// symlink on its way out of the probe — which is the only arrangement in
/// which the two shapes differ.
///
/// MUTATION for each cell, measured: reverting the `HEAD` read reds
/// `…ABareRepoProbe…` and nothing else; reverting `pointerPath`'s read reds
/// `…AWorktreePointerRead…` and nothing else. Both deterministic.
///
/// COVERAGE, stated rather than implied: this is TWO of the eight converted
/// sites. The other six — including `WorktreeReclaimPerformer`'s
/// `headWitness`, which the commit that converted it called "what the reclaim
/// proves the far side against" — still have no call-site cell, and reverting
/// them leaves the suite green. The two here were chosen because they are the
/// two distinct mechanisms (a text read and the pointer-path read that
/// `adminDirectory` depends on); the remaining six are the same shape at
/// different callers, and that is an argument for expecting them to be
/// correct, not evidence that they are.
///
/// Both cells carry a CONTROL that must resolve with nothing swapped — and
/// that was FALSE when first written: only the second had one, and the claim
/// stood here unchecked until a merge gate read it (r5, P5). The second one
/// earned it: its first version answered nil because the fixture
/// wrote a `gitdir:` prefix into the admin's back-link file, where real git
/// writes a bare path — so the cell was green, vacuous, and would have
/// reported the read as guarded when nothing had been read at all.
final class GitMetadataReadCallSiteTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("git-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// Answers `.regularFile` for the named file — truthfully, it IS one —
    /// and then replaces it with a symlink before the caller can read it.
    /// Every answer is the real answer; only the timing is the fixture.
    private final class SwapToSymlinkAfterProbe: FileSystemIdentityProvider {
        var watched: String = ""
        var decoy: URL!
        private(set) var swapped = false

        override func probeKind(of url: URL) -> KindProbe {
            let answer = super.probeKind(of: url)
            guard !swapped, url.lastPathComponent == watched,
                  answer == .kind(.regularFile)
            else { return answer }
            swapped = true
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createSymbolicLink(
                at: url, withDestinationURL: decoy
            )
            return answer
        }
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    /// `bareRepositoryGitDirectory` reads `HEAD` and `config`.
    func testABareRepoProbeDoesNotFollowASymlinkPlantedAfterTheProbe() throws {
        let repo = base.appendingPathComponent("bare.git")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("objects"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("refs"),
            withIntermediateDirectories: true
        )
        try write("ref: refs/heads/main\n", to: repo.appendingPathComponent("HEAD"))
        try write("[core]\n\tbare = true\n", to: repo.appendingPathComponent("config"))

        // The decoy holds content that WOULD satisfy the caller, so a read
        // that follows the link succeeds and the repository is admitted.
        let decoy = base.appendingPathComponent("decoy-HEAD")
        try write("ref: refs/heads/main\n", to: decoy)

        // CONTROL FIRST. The class doc claimed both cells carried one; this
        // cell did not (PR #461 gate r5, P5). Without it, a later edit to the
        // hand-built HEAD/config/objects/refs fixture turns this cell
        // green-and-vacuous with nothing to catch it — the same fixture rot
        // the sibling cell already earned its control for.
        let control = SwapToSymlinkAfterProbe()
        control.watched = "nothing"
        control.decoy = decoy
        XCTAssertNotNil(
            GitWorktreeGitdirResolver(identity: control)
                .bareRepositoryGitDirectory(at: repo),
            "the fixture must be accepted when nothing is swapped, or the "
                + "refusal below would not be the symlink's"
        )

        let provider = SwapToSymlinkAfterProbe()
        provider.watched = "HEAD"
        provider.decoy = decoy

        let resolver = GitWorktreeGitdirResolver(identity: provider)
        let found = resolver.bareRepositoryGitDirectory(at: repo)

        XCTAssertTrue(provider.swapped, "the fixture never planted the symlink")
        XCTAssertNil(
            found,
            "the HEAD read followed a symlink installed after the probe said "
                + "'regular file' — a scan of a dev root can be steered into "
                + "a TCC-protected or unresponsive target this way"
        )
    }

    /// `adminDirectory(forWorktreeAt:)` reads a linked worktree's `.git`
    /// pointer file — the same probe-then-read shape, on the path the
    /// reclaim performer trusts to identify an admin directory.
    func testAWorktreePointerReadDoesNotFollowALatePlantedSymlink() throws {
        let worktree = base.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(
            at: worktree, withIntermediateDirectories: true
        )
        let admin = base.appendingPathComponent("main.git/worktrees/checkout")
        try FileManager.default.createDirectory(
            at: admin, withIntermediateDirectories: true
        )
        // The admin's `gitdir` holds a BARE PATH to the worktree's `.git`
        // FILE — no `gitdir:` prefix; only the worktree's own `.git` file
        // carries that. The first version of this fixture wrote the prefix
        // into both and the back-link never matched, which made the cell
        // answer nil for a reason that had nothing to do with the read.
        try write(
            "\(worktree.appendingPathComponent(".git").path)\n",
            to: admin.appendingPathComponent("gitdir")
        )
        try write(
            "gitdir: \(admin.path)\n", to: worktree.appendingPathComponent(".git")
        )

        let decoy = base.appendingPathComponent("decoy-dotgit")
        try write("gitdir: \(admin.path)\n", to: decoy)

        // CONTROL FIRST: unarmed, this fixture must RESOLVE. Without it a
        // nil below proves nothing — the resolver has a bidirectional
        // back-link check that can answer nil for reasons that have nothing
        // to do with the read.
        let control = SwapToSymlinkAfterProbe()
        control.watched = "nothing"
        control.decoy = decoy
        // NotNil, not equality: the resolver returns the CANONICAL spelling
        // (`/private/var/…`) of a fixture built at `/var/…`, and comparing
        // the two spellings tests Foundation, not the resolver.
        XCTAssertNotNil(
            GitWorktreeGitdirResolver(identity: control)
                .adminDirectory(forWorktreeAt: worktree),
            "the fixture does not resolve even when nothing is swapped, so "
                + "the refusal below would not be the swap's"
        )

        let provider = SwapToSymlinkAfterProbe()
        provider.watched = ".git"
        provider.decoy = decoy

        let resolver = GitWorktreeGitdirResolver(identity: provider)
        let found = resolver.adminDirectory(forWorktreeAt: worktree)

        XCTAssertTrue(provider.swapped, "the fixture never planted the symlink")
        XCTAssertNil(
            found,
            "the .git pointer read followed a symlink installed after the "
                + "probe — the admin directory a reclaim would then act on "
                + "was named by a file this process never verified"
        )
    }
}
