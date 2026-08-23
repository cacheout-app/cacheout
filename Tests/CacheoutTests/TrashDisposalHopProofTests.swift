import XCTest
@testable import Cacheout

/// # The proofs `TrashDisposal` runs on the FAR SIDE of the mover's hop
///
/// r6 added three of them — one per `dispose` arm — and shipped all three
/// UNEVIDENCED. The r7 review measured it: deleting each in turn (M2, the
/// no-leaf-verdict overload; M3, the `.nonDirectoryLeaf` arm; M4, the
/// `proveStanding` arm) left `swift test` AT COMMIT 26c880b at 1471 executed /
/// 2 skipped / 0 failures, exit 0. A guard no cell can kill is a guard nobody
/// is holding to its contract, and this branch's own doctrine is that such a
/// guard is deleted or evidenced. These three cells evidence them.
///
/// RE-RUN AGAINST THESE CELLS, each mutation reddens exactly its own — the
/// command is `swift test --filter TrashDisposalHopProofTests`, and M2 fails
/// only `testTheNoVerdictArm…`, M3 only `testTheFileVerdictArm…`, M4 only
/// `testTheDirectoryVerdictArm…`.
///
/// ## The shape, and why it is the honest one
///
/// `TrashDisposal.Mover`'s contract is "call `prove()` on the far side of
/// whatever hop you perform, immediately before the move". The hop exists
/// because `FileManager.trashItem` requires the main actor; what the hop
/// COSTS is measured in
/// `WorktreeReclaimPerformerTests.testTheTrashProofAndTheMoveAreNotSeparatedByTheMainThreadQueue`
/// (median 175.736 ms of main-thread queue depth with the proof on r5's side
/// of it, 0.004 ms with it moved across). What the hop ADMITS is what these
/// cells are about: any rename landing inside it.
///
/// So each mover here performs the swap the hop makes possible and THEN calls
/// `prove()` — which is exactly what a real racing writer does, with the
/// scheduling delay replaced by a deterministic one. Each cell asserts three
/// things:
///
/// 1. the disposal THREW — the object is not trashed;
/// 2. the mover never moved anything — the refusal is BEFORE the move, so the
///    Trash is untouched and there is nothing to roll back;
/// 3. the stranger that was swapped in is still on disk.
///
/// With the far-side proof deleted, (1) and (3) both fail: the stranger goes
/// to the Trash and the disposal returns normally.
///
/// ## AND THE r13 GROUP: the arm that bound NOTHING
///
/// `dispose(_:expecting:…)`'s `.noDirectoryTree` path never opened
/// `admittedParent` and had no identity to compare, so both of its proofs
/// reduced to "some non-directory answers to this name". The five cells under
/// "A (r13)" evidence the fix, and the mutation table is MEASURED on this
/// branch rather than asserted — `swift test --filter
/// TrashDisposalHopProofTests`, 20 cells:
///
/// | mutation | red |
/// |---|---|
/// | `.noDirectoryTree` back on `proveStanding`, container proof KEPT | **2** — `…RefusesALeafSwappedInsideTheMoversHop`, `…RefusesAContainerSwappedInsideTheMover` |
/// | …and the container proof dropped as well (the r12 state) | **4** — the two above, `…RefusesAStrangerInAnotherContainer`, `…NamesContainerDriftAsContainerDrift` |
/// | `.anythingButADirectory` admits everything | **1** — `…RefusesADirectoryThatAppearedAtTheName` |
///
/// The first row is the whole of A1: adding the container binding alone fixes
/// the ordinary case and leaves the one that matters — the swap inside the
/// mover, where the after-proof cannot discriminate an identity-free verdict.
final class TrashDisposalHopProofTests: XCTestCase {

    private let fm = FileManager.default
    private var base: URL!
    private var landings: URL!

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("TrashDisposalHop-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        landings = base.appendingPathComponent("landed")
        try fm.createDirectory(at: landings, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    /// Records every URL the mover was actually asked to move, so "nothing
    /// was moved" is an assertion about the seam and not about the tree.
    private final class MoveLog {
        private let lock = NSLock()
        private var moved: [URL] = []
        func record(_ url: URL) {
            lock.lock(); moved.append(url); lock.unlock()
        }
        var urls: [URL] {
            lock.lock(); defer { lock.unlock() }; return moved
        }
    }

    /// The container the disposal is bound to, opened and proved from a
    /// descriptor exactly as every production caller does.
    private func admittedParent(
        of target: URL, provider: FileSystemIdentityProvider
    ) throws -> DepthSafeRemoval.AdmittedParent {
        try DepthSafeRemoval.admittedParent(
            directory: target.deletingLastPathComponent(),
            displayPath: target.path, provider: provider
        )
    }

    /// Replace whatever stands at `url` with a NEW object of the same kind —
    /// a different inode answering to the same name, which is what a rename
    /// pair inside the hop produces.
    private func swapInAStranger(at url: URL, directory: Bool) throws {
        try fm.removeItem(at: url)
        if directory {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("stranger".utf8).write(
                to: url.appendingPathComponent("their-work.txt")
            )
        } else {
            try Data("stranger".utf8).write(to: url)
        }
    }

    // MARK: - M2: the arm with NO leaf verdict (the worktree path's own)

    func testTheNoVerdictArmRefusesALeafSwappedInsideTheMoversHop()
        async throws
    {
        // THE POPULATION: every caller whose scanner registers no
        // `PreDeleteRevalidator` — `git_worktrees` among them, so this is the
        // arm the GUI's default worktree disposal actually takes — plus all
        // of contents mode. There is no leaf verdict, so what is bound is the
        // leaf read under the PROVED container, on both sides of the move.
        let provider = FileSystemIdentityProvider()
        let target = base.appendingPathComponent("victim")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let parent = try admittedParent(of: target, provider: provider)
        let log = MoveLog()
        let landings = try XCTUnwrap(self.landings)
        let fileManager = fm

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, containedIn: parent, provider: provider,
                via: { url, prove in
                    // THE HOP, with its scheduling delay replaced by the
                    // event the delay admits.
                    try self.swapInAStranger(at: url, directory: true)
                    try prove()
                    log.record(url)
                    let landed = landings.appendingPathComponent(
                        url.lastPathComponent
                    )
                    try fileManager.moveItem(at: url, to: landed)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? DepthSafeRemoval.Failure,
            "a leaf swapped inside the hop must refuse: \(String(describing: thrown))"
        )
        XCTAssertEqual(failure.cause, .notTheInspectedObject)
        XCTAssertEqual(
            log.urls, [],
            "the refusal is BEFORE the move, so the Trash is untouched"
        )
        XCTAssertTrue(
            fm.fileExists(
                atPath: target.appendingPathComponent("their-work.txt").path
            ),
            "the stranger's tree was trashed"
        )
    }

    // MARK: - M3: the `.nonDirectoryLeaf` verdict arm

    func testTheFileVerdictArmRefusesALeafSwappedInsideTheMoversHop()
        async throws
    {
        // A NON-DIRECTORY leaf verdict cannot be proved by `look` (its kind
        // gate is an `O_DIRECTORY` open), so this arm binds the leaf under
        // the proved container the same way the no-verdict arm does — and,
        // since r6, on both sides of the hop.
        let provider = FileSystemIdentityProvider()
        let target = base.appendingPathComponent("victim.txt")
        try Data("ours".utf8).write(to: target)
        let identity = try XCTUnwrap(provider.identity(of: target))
        let parent = try admittedParent(of: target, provider: provider)
        let log = MoveLog()
        let landings = try XCTUnwrap(self.landings)
        let fileManager = fm

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .nonDirectoryLeaf(identity),
                provider: provider, containedIn: parent,
                via: { url, prove in
                    try self.swapInAStranger(at: url, directory: false)
                    try prove()
                    log.record(url)
                    let landed = landings.appendingPathComponent(
                        url.lastPathComponent
                    )
                    try fileManager.moveItem(at: url, to: landed)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? DepthSafeRemoval.Failure,
            "a file swapped inside the hop must refuse: \(String(describing: thrown))"
        )
        XCTAssertEqual(failure.cause, .notTheInspectedObject)
        XCTAssertEqual(log.urls, [])
        XCTAssertEqual(
            try String(contentsOf: target, encoding: .utf8), "stranger",
            "the stranger's file was trashed"
        )
    }

    // MARK: - M4: the `proveStanding` arm (a `.directory` verdict)

    func testTheDirectoryVerdictArmRefusesATreeSwappedInsideTheMoversHop()
        async throws
    {
        // This arm's binding is the INSPECTED ROOT itself, so the far-side
        // proof is the same `proveStanding` the near-side one is — the cheap
        // refusal repeated where it counts.
        let provider = FileSystemIdentityProvider()
        let target = base.appendingPathComponent("tree")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let identity = try XCTUnwrap(provider.identity(of: target))
        let parent = try admittedParent(of: target, provider: provider)
        let log = MoveLog()
        let landings = try XCTUnwrap(self.landings)
        let fileManager = fm

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .directory(identity), provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try self.swapInAStranger(at: url, directory: true)
                    try prove()
                    log.record(url)
                    let landed = landings.appendingPathComponent(
                        url.lastPathComponent
                    )
                    try fileManager.moveItem(at: url, to: landed)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        XCTAssertNotNil(
            thrown, "a tree swapped inside the hop must refuse"
        )
        XCTAssertEqual(log.urls, [])
        XCTAssertTrue(
            fm.fileExists(
                atPath: target.appendingPathComponent("their-work.txt").path
            ),
            "the stranger's tree was trashed"
        )
    }

    // ================================================================
    // MARK: - The landing directory this process may not OPEN (r10, D1)
    // ================================================================

    /// The deterministic stand-in for the REAL `~/.Trash`: a provider that
    /// cannot open ONE directory, exactly as TCC denies `~/.Trash` to every
    /// process without Full Disk Access.
    ///
    /// A double LESS capable than production, which is the point — every
    /// other Trash cell in this suite injects a landing directory whose
    /// parent is freely openable, and that ONE property is what the
    /// disposal's after-proof depends on. Measured on this machine, from an
    /// ordinary CLI process: `open("/Users/<u>/.Trash",
    /// O_RDONLY|O_DIRECTORY|O_NOFOLLOW)` → -1, errno 1 (EPERM), while `lstat`
    /// and `open` of `~/.Trash/<name>` both succeed.
    ///
    /// `failing` is the errno it refuses with, because the fallback is now
    /// gated on the errno CLASS (PR #460 codex r11, D1) and the class has two
    /// members: `EPERM` is what TCC answers with, `EACCES` the ordinary
    /// mode-bit spelling of the same fact about the same open. Both must
    /// reach the fallback; nothing else may.
    private final class TrashDeniedProvider: FileSystemIdentityProvider {
        let denied: String
        let failing: Int32
        private(set) var refusals = 0

        init(denying directory: URL, with failing: Int32 = EPERM) {
            denied = directory.standardizedFileURL.path
            self.failing = failing
            super.init()
        }

        override func openDirectoryNoFollow(at url: URL) -> Int32 {
            guard url.standardizedFileURL.path == denied else {
                return super.openDirectoryNoFollow(at: url)
            }
            refusals += 1
            errno = failing
            return -1
        }
    }

    /// THE DEFECT, DETERMINISTICALLY: a landing the process cannot open is a
    /// failure to VERIFY, and until r10 it was reported as a failure to
    /// RESTORE.
    ///
    /// The real-composition twin of this cell is
    /// `GitWorktreeEndToEndTests.testTheTrashDefaultReportsTheCheckoutItReallyMovedToTheTrash`,
    /// which drives `SpaceScannerRuntime.production` with `moveToTrash` at
    /// its shipped default and the production `FileManager.trashItem` into
    /// the real `~/.Trash`. That cell needs no double and is the honest
    /// proof; it is also silent on any machine WITH Full Disk Access, which
    /// is why this one exists as well.
    ///
    /// MUTATION: delete the `probeLeaf` fallback in `TrashDisposal.facts` and
    /// this cell fails with `.lastSeenInTrash` — the disposal refuses an
    /// object that is sitting exactly where it says it is not.
    func testAnUnopenableLandingIsIdentifiedRatherThanRefused() async throws {
        let landings = try XCTUnwrap(self.landings)
        let provider = TrashDeniedProvider(denying: landings)
        let target = base.appendingPathComponent("victim")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let parent = try admittedParent(of: target, provider: provider)
        let fileManager = fm
        let landed = landings.appendingPathComponent(target.lastPathComponent)

        try await TrashDisposal.dispose(
            target, containedIn: parent, provider: provider,
            via: { url, prove in
                try prove()
                try fileManager.moveItem(at: url, to: landed)
                return landed
            }
        )

        XCTAssertGreaterThan(
            provider.refusals, 0,
            "the cell must actually have exercised the denied open"
        )
        XCTAssertFalse(fm.fileExists(atPath: target.path),
                       "the disposal really moved it")
        XCTAssertTrue(
            fm.fileExists(atPath: landed.appendingPathComponent("ours.txt").path),
            "…and it is in the landing, intact — which is what the caller "
                + "reports as freed"
        )
    }

    /// AND THE PROOF IS NOT SKIPPED TO GET THERE: the same unopenable
    /// landing, with a stranger swapped in AFTER the far-side proof, is still
    /// caught — the fallback IDENTIFIES the landed object rather than
    /// assuming it.
    ///
    /// The refusal it produces is `.strandedInTrash`, not `.lastSeenInTrash`:
    /// the rollback cannot open the Trash either, so the object cannot be
    /// moved back — but it IS there, and the cause that names its path is the
    /// one the user can act on.
    ///
    /// MUTATION: restore `.lastSeenInTrash` on `rollBack`'s trash-open arm
    /// and this cell fails on the cause; delete the `probeLeaf` fallback and
    /// it fails there too, because nothing is identified at all.
    func testAnUnopenableLandingStillCatchesAnObjectThatIsNotOurs()
        async throws
    {
        let landings = try XCTUnwrap(self.landings)
        let provider = TrashDeniedProvider(denying: landings)
        let target = base.appendingPathComponent("victim")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let parent = try admittedParent(of: target, provider: provider)
        let fileManager = fm
        let landed = landings.appendingPathComponent(target.lastPathComponent)

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, containedIn: parent, provider: provider,
                via: { url, prove in
                    // The proof passes, and the swap lands in the window no
                    // proof out here reaches: `trashItem` resolves the URL
                    // inside itself.
                    try prove()
                    try self.swapInAStranger(at: url, directory: true)
                    try fileManager.moveItem(at: url, to: landed)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? TrashDisposal.Failure,
            "an object that is not ours must be refused even when the "
                + "landing cannot be opened: \(String(describing: thrown))"
        )
        XCTAssertEqual(failure.cause, .strandedInTrash(landed.path))
        let described = try XCTUnwrap(failure.errorDescription)
        XCTAssertTrue(described.contains("it is in the Trash at \(landed.path)"),
                      described)
        XCTAssertTrue(
            fm.fileExists(
                atPath: landed.appendingPathComponent("their-work.txt").path
            ),
            "the stranger is where the refusal says it is"
        )
    }

    /// **THE SOUNDNESS BOUND ON THE FALLBACK** (PR #460 codex r11, D1): the
    /// failure `O_NOFOLLOW` exists to produce must NOT be answered with a
    /// path `lstat`.
    ///
    /// r10 fired the `probeLeaf` fallback on EVERY failure of the container
    /// open, arguing that it "cannot ADMIT anything the descriptor-relative
    /// read would refuse". It can, and this is the case: `probeChild` reads a
    /// name inside a HELD DESCRIPTOR, `probeLeaf` `lstat`s a PATH, and
    /// `lstat`'s no-follow covers the FINAL component only. So a landing
    /// whose CONTAINER is a symlink fails the open — and the fallback then
    /// walks through that very link.
    ///
    /// WHICH ERRNO, MEASURED RATHER THAN ASSUMED (Darwin 25.5, this machine).
    /// The r11 review called this the `ELOOP` case, and `ELOOP` is what
    /// `open(link, O_RDONLY|O_NOFOLLOW)` returns — 62, for a symlink to a
    /// directory AND for a self-referential one. But this codebase's open
    /// carries `O_DIRECTORY` as well, and `open(link,
    /// O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)` returns **ENOTDIR (20)**
    /// for both: the directory check answers first. The name of the errno
    /// changes nothing about the defect — neither code is in the permitted
    /// class — and the cell asserts the one the kernel actually produces
    /// rather than the one the taxonomy predicted.
    ///
    /// NOTHING IS MOCKED HERE. The provider is the production one; the link
    /// is a real symlink and the errno is the kernel's. The mover moves
    /// NOTHING and reports a landing whose parent link is aimed back at the
    /// item's own container, so the `lstat` finds the ORIGINAL object, still
    /// standing at its original path, and hands back the identity that was
    /// bound before the move.
    ///
    /// MEASURED, with r10's unrestricted fallback restored (delete the
    /// `code == EPERM || code == EACCES` guard in `TrashDisposal.facts`):
    /// `dispose` RETURNS NORMALLY and `victim` is still on disk — a disposal
    /// that reports success having moved nothing, which is strictly worse
    /// than the false refusal r10 removed. This cell is the only one that
    /// reddens.
    func testASymlinkedLandingContainerIsRefusedRatherThanResolvedThroughIt()
        async throws
    {
        let provider = FileSystemIdentityProvider()
        let container = base.appendingPathComponent("container")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        let target = container.appendingPathComponent("victim")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let parent = try admittedParent(of: target, provider: provider)

        // The landing the mover will name: its PARENT is a symlink pointing
        // back at the item's own container, so `lstat` of the whole path
        // resolves to the item itself while the container open cannot.
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: container)
        let landed = link.appendingPathComponent(target.lastPathComponent)

        // The premise, asserted rather than assumed: the open really does
        // fail ELOOP and the path lstat really does resolve through the link.
        let opened = provider.openDirectoryNoFollowCarryingErrno(at: link)
        XCTAssertEqual(
            opened, .failed(errno: ENOTDIR),
            "the container open must fail — ENOTDIR, because O_DIRECTORY "
                + "answers before O_NOFOLLOW's ELOOP: \(opened)"
        )
        XCTAssertEqual(
            provider.probeLeaf(at: landed),
            provider.probeLeaf(at: target),
            "…and the path lstat must resolve through the link to the "
                + "ORIGINAL object, which is what makes this unsound"
        )

        let log = MoveLog()
        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, containedIn: parent, provider: provider,
                via: { url, prove in
                    try prove()
                    // MOVES NOTHING and reports a landing anyway.
                    log.record(url)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? TrashDisposal.Failure,
            "a landing whose container cannot be opened NO-FOLLOW must be "
                + "refused, not resolved through the link: "
                + "\(String(describing: thrown))"
        )
        XCTAssertEqual(failure.cause, .lastSeenInTrash(landed.path))
        XCTAssertEqual(log.urls.map(\.path), [target.path],
                       "the mover was driven exactly once")
        XCTAssertTrue(
            fm.fileExists(atPath: target.appendingPathComponent("ours.txt").path),
            "nothing was moved — which is precisely why reporting success "
                + "would have been a lie"
        )
    }

    /// THE OTHER MEMBER OF THE PERMITTED CLASS: `EACCES` is the same fact
    /// about the same open, spelled by the mode bits rather than by TCC, and
    /// it must reach the fallback too.
    ///
    /// MUTATION: narrow the guard in `TrashDisposal.facts` to `code == EPERM`
    /// and this cell alone fails, with `.lastSeenInTrash`.
    func testAModeDeniedLandingIsIdentifiedRatherThanRefused() async throws {
        let landings = try XCTUnwrap(self.landings)
        let provider = TrashDeniedProvider(denying: landings, with: EACCES)
        let target = base.appendingPathComponent("victim-eacces")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let parent = try admittedParent(of: target, provider: provider)
        let fileManager = fm
        let landed = landings.appendingPathComponent(target.lastPathComponent)

        try await TrashDisposal.dispose(
            target, containedIn: parent, provider: provider,
            via: { url, prove in
                try prove()
                try fileManager.moveItem(at: url, to: landed)
                return landed
            }
        )

        XCTAssertGreaterThan(provider.refusals, 0,
                             "the cell must actually have exercised the "
                                + "denied open")
        XCTAssertFalse(fm.fileExists(atPath: target.path),
                       "the disposal really moved it")
        XCTAssertTrue(
            fm.fileExists(
                atPath: landed.appendingPathComponent("ours.txt").path
            ),
            "…and it is in the landing, intact"
        )
    }

    // ================================================================
    // MARK: - THE SAME QUESTION, ON THE SIBLING ARM (PR #460 codex r12, D1)
    // ================================================================

    /// **THE BLOCKER r11 CLOSED IN ONE ARM AND LEFT OPEN IN ITS SIBLING.**
    ///
    /// r11 bounded `TrashDisposal.facts`'s `probeLeaf` fallback to the
    /// permission class, and its own header then asserted that the
    /// verdict-bound arm was already safe because `look` "is a DIRECT `open`
    /// of `url` and therefore never needed the Trash directory". A direct
    /// open of the whole path is not the safe end of that trade — it is the
    /// SAME unsoundness one call away. **`O_NOFOLLOW` guards only the FINAL
    /// component**, so `open(landed.path, O_RDONLY|O_DIRECTORY|O_NOFOLLOW)`
    /// FOLLOWS a symlinked landing CONTAINER exactly as `probeLeaf`'s `lstat`
    /// did.
    ///
    /// The fixture is r11's, aimed at the other entry point: the mover moves
    /// NOTHING and reports a landing whose parent is a symlink pointing back
    /// at the item's own container, so the resolution finds the ORIGINAL
    /// object still standing at its original path and hands back the very
    /// identity the verdict names.
    ///
    /// MEASURED at 93d6198, with the pre-r12 `look` (one path-spelled
    /// `open`): `dispose` RETURNS NORMALLY, `victim` is still on disk with
    /// its contents, and the caller reports the item freed — a disposal that
    /// reports success having moved nothing. Nothing is mocked: the provider
    /// is the production one, the link is a real symlink, the errno is the
    /// kernel's.
    func testTheDirectoryVerdictArmRefusesASymlinkedLandingContainer()
        async throws
    {
        let provider = FileSystemIdentityProvider()
        let container = base.appendingPathComponent("verdict-container")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        let target = container.appendingPathComponent("victim")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let identity = try XCTUnwrap(provider.identity(of: target))
        let parent = try admittedParent(of: target, provider: provider)

        let link = base.appendingPathComponent("verdict-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: container)
        let landed = link.appendingPathComponent(target.lastPathComponent)

        // THE PREMISE, ASSERTED RATHER THAN ASSUMED. The container open
        // refuses the link (ENOTDIR — `O_DIRECTORY` answers before
        // `O_NOFOLLOW`'s ELOOP, measured in the sibling cell above), and the
        // whole-path open the old `look` performed walks straight through it
        // and identifies the ORIGINAL object.
        XCTAssertEqual(
            provider.openDirectoryNoFollowCarryingErrno(at: link),
            .failed(errno: ENOTDIR),
            "the container open must refuse the link"
        )
        let throughTheLink = open(
            landed.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(
            throughTheLink, 0,
            "the path-spelled open must SUCCEED through the link — that is "
                + "what makes the old `look` unsound"
        )
        if throughTheLink >= 0 {
            XCTAssertEqual(
                provider.identity(ofDescriptor: throughTheLink), identity,
                "…and it must land on the ORIGINAL object, whose identity is "
                    + "exactly the one the verdict names"
            )
            close(throughTheLink)
        }

        let log = MoveLog()
        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .directory(identity), provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try prove()
                    // MOVES NOTHING and reports a landing anyway.
                    log.record(url)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? TrashDisposal.Failure,
            "a landing whose container cannot be opened NO-FOLLOW must be "
                + "refused on THIS arm too, not resolved through the link: "
                + "\(String(describing: thrown))"
        )
        XCTAssertEqual(failure.cause, .lastSeenInTrash(landed.path))
        XCTAssertEqual(log.urls.map(\.path), [target.path],
                       "the mover was driven exactly once")
        XCTAssertTrue(
            fm.fileExists(atPath: target.appendingPathComponent("ours.txt").path),
            "nothing was moved — which is precisely why reporting success "
                + "would have been a lie"
        )
    }

    /// THE OTHER DIRECTION, AND THE REASON THE FIX IS NOT SIMPLY "REFUSE
    /// WHAT CANNOT BE OPENED": `EPERM` is what TCC answers for `~/.Trash` on
    /// every machine without Full Disk Access, and this arm must still
    /// identify the item it really moved.
    ///
    /// Before r12 this arm reached the landing with one path open, which TCC
    /// permits, so it was never broken the way r10's D1 broke the others —
    /// and a descriptor-relative rewrite WITHOUT the permission-class
    /// fallback would have broken it for the first time. That is what this
    /// cell holds.
    ///
    /// MUTATION: delete the permission-class fallback in `look` and this cell
    /// fails with `.strandedInTrash`.
    func testTheDirectoryVerdictArmIdentifiesAnUnopenableLanding()
        async throws
    {
        try await assertTheDirectoryVerdictArmDisposesUnder(errno: EPERM,
                                                            named: "victim-dv-eperm")
    }

    /// The mode-bit spelling of the same fact about the same open — the
    /// second member of the permitted class, evidenced rather than assumed
    /// (the sibling arm's `testAModeDeniedLandingIsIdentifiedRatherThanRefused`).
    ///
    /// MUTATION: narrow `look`'s fallback guard to `code == EPERM` and this
    /// cell alone fails, with `.strandedInTrash`.
    func testTheDirectoryVerdictArmIdentifiesAModeDeniedLanding()
        async throws
    {
        try await assertTheDirectoryVerdictArmDisposesUnder(errno: EACCES,
                                                            named: "victim-dv-eacces")
    }

    private func assertTheDirectoryVerdictArmDisposesUnder(
        errno failing: Int32, named name: String
    ) async throws {
        let landings = try XCTUnwrap(self.landings)
        let provider = TrashDeniedProvider(denying: landings, with: failing)
        let target = base.appendingPathComponent(name)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let identity = try XCTUnwrap(provider.identity(of: target))
        let parent = try admittedParent(of: target, provider: provider)
        let fileManager = fm
        let landed = landings.appendingPathComponent(target.lastPathComponent)

        try await TrashDisposal.dispose(
            target, expecting: .directory(identity), provider: provider,
            containedIn: parent,
            via: { url, prove in
                try prove()
                try fileManager.moveItem(at: url, to: landed)
                return landed
            }
        )

        XCTAssertGreaterThan(
            provider.refusals, 0,
            "the cell must actually have exercised the denied open"
        )
        XCTAssertFalse(fm.fileExists(atPath: target.path),
                       "the disposal really moved it")
        XCTAssertTrue(
            fm.fileExists(
                atPath: landed.appendingPathComponent("ours.txt").path
            ),
            "…and it is in the landing, intact"
        )
    }

    /// AND THE PERMITTED CLASS IS NOT A SKIPPED PROOF ON THIS ARM EITHER: the
    /// same unopenable landing, with a stranger swapped in after the far-side
    /// proof, is still caught. `.strandedInTrash` because the rollback cannot
    /// open the Trash to move it back — but it IS there, and the cause names
    /// the path.
    func testTheDirectoryVerdictArmStillCatchesAStrangerUnderADeniedLanding()
        async throws
    {
        let landings = try XCTUnwrap(self.landings)
        let provider = TrashDeniedProvider(denying: landings)
        let target = base.appendingPathComponent("victim-dv-stranger")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let identity = try XCTUnwrap(provider.identity(of: target))
        let parent = try admittedParent(of: target, provider: provider)
        let fileManager = fm
        let landed = landings.appendingPathComponent(target.lastPathComponent)

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .directory(identity), provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try prove()
                    try self.swapInAStranger(at: url, directory: true)
                    try fileManager.moveItem(at: url, to: landed)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? TrashDisposal.Failure,
            "an object that is not ours must be refused even when the "
                + "landing cannot be opened: \(String(describing: thrown))"
        )
        XCTAssertEqual(failure.cause, .strandedInTrash(landed.path))
        XCTAssertTrue(
            fm.fileExists(
                atPath: landed.appendingPathComponent("their-work.txt").path
            ),
            "the stranger is where the refusal says it is"
        )
    }

    /// THE KIND GATE SURVIVES THE REWRITE. `look`'s gate WAS the
    /// `O_DIRECTORY` open of the path; it is now the `O_DIRECTORY` `openat`
    /// of the NAME under the held container, and a landing that is a regular
    /// file must still be `.noDirectoryTree` rather than an identified
    /// object.
    ///
    /// Green before r12 as well as after — it is the control that stops the
    /// descriptor-relative rewrite from reading the identity of a
    /// non-directory and calling it a match.
    ///
    /// ITS CAUSE CHANGED IN r14, AND THE NEW ONE IS THE ACCURATE ONE FOR THIS
    /// FIXTURE (PR #460 codex r14, V1-D1). The mover here MOVES NOTHING, so
    /// the plain file at `landed` is still sitting there when the refusal is
    /// composed — and `.lastSeenInTrash` says the object "is no longer at"
    /// that path. It said so because `identified` discarded every
    /// non-directory sighting and `rollBack` refused a `nil`; now the file is
    /// named, re-bound, and the put-back is ATTEMPTED — `RENAME_EXCL` refuses
    /// it because the target's own name is still occupied (this fixture never
    /// vacated it), which is `.strandedInTrash`: the item is in the Trash at
    /// this exact path, go and get it.
    func testTheDirectoryVerdictArmRefusesALandingThatIsNotADirectory()
        async throws
    {
        let landings = try XCTUnwrap(self.landings)
        let provider = FileSystemIdentityProvider()
        let target = base.appendingPathComponent("victim-dv-file")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let identity = try XCTUnwrap(provider.identity(of: target))
        let parent = try admittedParent(of: target, provider: provider)
        let landed = landings.appendingPathComponent("a-plain-file")
        try Data("not a tree".utf8).write(to: landed)

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .directory(identity), provider: provider,
                containedIn: parent,
                via: { _, prove in
                    try prove()
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? TrashDisposal.Failure,
            "a landing that is not a directory tree cannot satisfy a "
                + "`.directory` verdict: \(String(describing: thrown))"
        )
        XCTAssertEqual(failure.cause, .strandedInTrash(landed.path))
        XCTAssertTrue(
            fm.fileExists(atPath: target.appendingPathComponent("ours.txt").path),
            "nothing was moved"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: landed.path),
            "the refusal names a path the file is actually at"
        )
    }

    /// THE COVERAGE GAP THE ONE ABOVE LEFT: a non-directory landing whose
    /// mover ACTUALLY PERFORMED THE MOVE (PR #460 codex r14, V1-D1).
    ///
    /// Every cell that drove a non-directory landing used a mover that moved
    /// NOTHING, so the target's own name stayed occupied and every rollback
    /// was going to be refused by `RENAME_EXCL` anyway — which is why
    /// `identified`'s `guard case .directory` could discard the landing for
    /// three rounds without a single cell noticing. This is the shape the
    /// production defect had: the name is re-pointed at a plain file INSIDE
    /// the hop (the window `trashItem`'s own URL resolution owns), the mover
    /// takes whatever answers to it, and the target's name is left FREE.
    ///
    /// The measured production report before the fix — real `CacheCleaner`,
    /// real `OrphanedCachesScanner.preDeleteRevalidator`, real PathGuard,
    /// `moveToTrash: true` — was `.lastSeenInTrash`, `entries=0`, with the
    /// object still at the landing and the target NOT restored. The
    /// container-bound overload answered `.putBack` on the identical event.
    ///
    /// MUTATION: narrow `identified` back to `guard case .directory(let
    /// identity) = sighting else { return nil }` and this cell alone fails —
    /// `.lastSeenInTrash`, the stranger's file abandoned in the landing
    /// directory, nothing back at the target.
    func testTheDirectoryVerdictArmPutsBackANonDirectoryItReallyMoved()
        async throws
    {
        let landings = try XCTUnwrap(self.landings)
        let provider = FileSystemIdentityProvider()
        let target = base.appendingPathComponent("victim-dv-moved")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let identity = try XCTUnwrap(provider.identity(of: target))
        let parent = try admittedParent(of: target, provider: provider)
        let landed = landings.appendingPathComponent(target.lastPathComponent)
        let log = MoveLog()
        let fileManager = fm

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .directory(identity), provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try prove()
                    // The swap the hop admits, AFTER the far-side proof:
                    // exactly what a racing writer does between the proof
                    // and `trashItem`'s own resolution of the URL.
                    try fileManager.removeItem(at: url)
                    try Data("a stranger's file".utf8).write(to: url)
                    log.record(url)
                    try fileManager.moveItem(at: url, to: landed)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? TrashDisposal.Failure,
            "a plain file the disposal really took cannot satisfy a "
                + "`.directory` verdict: \(String(describing: thrown))"
        )
        XCTAssertEqual(log.urls.count, 1, "the fixture never moved anything")
        XCTAssertEqual(
            failure.cause, .putBack,
            "the object the disposal took was named, re-bound and moved back"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: landed.path),
            "the object may not be abandoned in the landing directory"
        )
        XCTAssertEqual(
            provider.kind(of: target), .regularFile,
            "what came back must be the object the disposal took, not a "
                + "tree: \(String(describing: provider.kind(of: target)))"
        )
        XCTAssertEqual(
            try Data(contentsOf: target), Data("a stranger's file".utf8),
            "a DIFFERENT object was put back"
        )
    }

    /// THE PUT-BACK'S DESTINATION CANNOT BE OPENED — the same fact as the
    /// Trash-open guard two cells up, one directory over, and until r14 it
    /// answered the OPPOSITE cause (PR #460 codex r14, V1-D1).
    ///
    /// `observed` is non-`nil` and the Trash-side re-bind has already passed
    /// by the time this open is attempted, so the item IS in the Trash; what
    /// failed is the put-back, not the finding. `.lastSeenInTrash` sent the
    /// user looking for an object whose exact path the refusal was holding.
    ///
    /// THE DENIAL IS A REAL `EACCES`, AND SINCE r15 IT HAS TO BE (D-P1). The
    /// destination now goes through `DepthSafeRemoval.openAdmittedContainer`,
    /// whose open is a RAW following `open(2)` that no provider double can
    /// intercept — which is the whole point of the alignment, and which
    /// retired the `TrashDeniedProvider` version of this cell: with the
    /// double in place the open simply succeeded, the `RENAME_EXCL` then
    /// failed `EEXIST` on an occupied target name, and `.strandedInTrash` came
    /// back for a reason that had nothing to do with the arm under test.
    /// MEASURED: with that fixture the V1-D1 mutation reddened NOTHING —
    /// 27 executed / 0 failures — so the cell was re-pointed rather than kept.
    ///
    /// THE DISCRIMINATION IS EXPLICIT: the mover really moves the object and
    /// leaves the target's name FREE, so the put-back would SUCCEED
    /// (`.putBack`, evidenced by
    /// `…UndoPutsBackUnderASymlinkedContainerWhatItPutsBackUnderAPlainOne`)
    /// if the container were openable. Mode `0111` is the same traverse-but-
    /// not-read class `…AnswersOneCodePerFailureAndAdmitsMode0111` pins at
    /// `EACCES`.
    ///
    /// MUTATION: restore `.lastSeenInTrash` on `rollBack`'s destination-open
    /// arm and this cell alone fails.
    func testAPutBackWhoseDestinationCannotBeOpenedSaysWhereTheItemIs()
        async throws
    {
        let landings = try XCTUnwrap(self.landings)
        let provider = FileSystemIdentityProvider()
        let container = try makeCacheContainer()
        let target = container.appendingPathComponent("victim-dest-denied")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let identity = try XCTUnwrap(provider.identity(of: target))
        let parent = try admittedParent(of: target, provider: provider)
        let landed = landings.appendingPathComponent("victim-dest-denied")
        let fileManager = fm
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: container.path)
        }

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .directory(identity), provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try prove()
                    // The swap the hop admits, and a REAL move: the target's
                    // name is left free, so nothing but the destination open
                    // can stop the put-back.
                    try self.swapInAStranger(at: url, directory: true)
                    try fileManager.moveItem(at: url, to: landed)
                    // …and THEN the container stops being openable.
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o111],
                        ofItemAtPath: container.path
                    )
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? TrashDisposal.Failure,
            "a stranger's tree the disposal really took must be refused: "
                + "\(String(describing: thrown))"
        )
        XCTAssertEqual(failure.cause, .strandedInTrash(landed.path))
        XCTAssertTrue(
            fm.fileExists(
                atPath: landed.appendingPathComponent("their-work.txt").path
            ),
            "the item is where the refusal says it is"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: target.path),
            "the disclosed residual: an unopenable container means the "
                + "put-back was never attempted, so the target's name stays "
                + "empty and the refusal has to name the Trash"
        )
    }

    /// AN ABSENT CONTAINER IS STILL AN ABSENCE, NOT AN UNREADABLE LOOK — the
    /// arm the descriptor-relative rewrite had to ADD, because one
    /// path-spelled open answered `ENOENT` for a missing name and a missing
    /// container alike and a two-step open does not.
    ///
    /// The contract is `proveStanding`'s frozen ghost-target behaviour: an
    /// absence SATISFIES a `.noDirectoryTree` verdict on the way in and
    /// proves nothing on the way out.
    /// `OrphanedCachesScannerTests.testAnAbsenceProvesTheVerdictBeforeTheDisposalOnly`
    /// pins that for a ghost inside an EXISTING container; nothing pinned it
    /// when the CONTAINER is the thing that is gone, which is the only case
    /// the rewrite could have changed.
    ///
    /// MUTATION: delete the `code == ENOENT` arm in `look` and this cell
    /// alone fails — `.unreadable(2)` instead of `.absent`, and the standing
    /// proof throws `.posix(2)` about a target whose absence is exactly what
    /// the verdict says.
    func testALookInsideAContainerThatIsGoneIsStillAnAbsence() throws {
        let provider = FileSystemIdentityProvider()
        let ghost = base
            .appendingPathComponent("a-container-that-never-existed")
            .appendingPathComponent("ghost")

        XCTAssertEqual(
            TrashDisposal.look(at: ghost, provider: provider), .absent,
            "a name inside a container that is not there is ABSENT, and no "
                + "resolution happened to establish it"
        )
        XCTAssertNoThrow(
            try TrashDisposal.proveStanding(
                .noDirectoryTree, at: ghost, provider: provider
            ),
            "an absent target still satisfies a verdict about an ABSENCE, "
                + "whether the NAME or its whole CONTAINER is what is gone"
        )
        XCTAssertThrowsError(
            try TrashDisposal.proveTaken(
                .noDirectoryTree, at: ghost, provider: provider
            ),
            "…and still proves nothing on the way out"
        )
    }

    // ================================================================
    // MARK: - What the errno-carrying open actually promises (r12, D3)
    // ================================================================

    /// TWO CLAIMS IN `openDirectoryNoFollowCarryingErrno`'s HEADER, MEASURED
    /// RATHER THAN ASSERTED (PR #460 codex r12, D3).
    ///
    /// **(a) The errno-read discipline is EMPIRICAL, not structural.** That
    /// header said the global `errno` "is read on the statement immediately
    /// after, with no intervening call". There IS intervening work between
    /// the `open(2)` and the read: the delegated `openDirectoryNoFollow(at:)`
    /// call and its return, the `url.path` String construction and its
    /// teardown, and the epilogue that builds the result. None of it makes a
    /// syscall or touches `errno` — and that is a property of THIS
    /// delegation as compiled, not a language guarantee, so it is measured
    /// here rather than claimed. 500 consecutive real failing opens, one
    /// errno each.
    ///
    /// **(b) The permitted class has a THIRD cause, and it is neither TCC
    /// nor a directory denied to everyone.** `open(dir, O_RDONLY)` needs READ
    /// on the container; `lstat(dir/name)` needs only TRAVERSAL. So a
    /// container at mode `0111` answers `EACCES` to the container open while
    /// the path read the fallback performs succeeds — the permission class
    /// fires, and the header's "they are the whole measured cause" (TCC's
    /// `EPERM` and its mode-bit spelling) did not cover it.
    ///
    /// IT IS SOUND, WHICH IS WHY THIS IS A WORDING FIX AND NOT A DEFECT:
    /// reaching `EACCES` at all means the container's LAST COMPONENT is a
    /// real directory that `O_NOFOLLOW` accepted — a symlink there answers
    /// `ENOTDIR`/`ELOOP` first, and this cell asserts that too — so the
    /// fallback resolves no link the descriptor-relative read refused.
    func testTheErrnoCarryingOpenAnswersOneCodePerFailureAndAdmitsMode0111()
        throws
    {
        let provider = FileSystemIdentityProvider()
        let container = base.appendingPathComponent("read-denied")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        let child = container.appendingPathComponent("child")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        // TRAVERSE but not READ — the third cause.
        try fm.setAttributes([.posixPermissions: 0o111],
                             ofItemAtPath: container.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: container.path)
        }

        // (b) the premise: the container open is refused for PERMISSION…
        var codes = Set<Int32>()
        for _ in 0..<500 {
            guard case .failed(let code) = provider
                .openDirectoryNoFollowCarryingErrno(at: container)
            else {
                return XCTFail("the container open must be refused")
            }
            codes.insert(code)
        }
        // (a) …and 500 consecutive calls carry exactly ONE code out.
        XCTAssertEqual(codes, [EACCES],
                       "the errno must survive the delegation intact, every "
                           + "time: \(codes.map(String.init).sorted())")

        // …while the path read the fallback performs is permitted, which is
        // what makes this a member of the class at all.
        guard case .facts = provider.probeLeaf(at: child) else {
            return XCTFail("traversal must be permitted where READ is not")
        }

        // AND THE SOUNDNESS BOUND, asserted beside it: a SYMLINKED container
        // never reaches the permission class — it is refused first, so no
        // permission-class fallback can ever resolve one.
        let link = base.appendingPathComponent("read-denied-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: container)
        XCTAssertEqual(
            provider.openDirectoryNoFollowCarryingErrno(at: link),
            .failed(errno: ENOTDIR),
            "a symlinked container must answer OUTSIDE the permitted class"
        )
    }


    // MARK: - E (PR #460 codex r13): the precondition r12's M5 could not kill

    /// **`look`'s `isSafeComponent` GUARD, EVIDENCED** — r12's mutation M5
    /// deleted it and NOTHING went red, and this branch's doctrine gives a
    /// guard in that state two options, not three.
    ///
    /// WHY M5 FOUND NOTHING, AND WHERE THE GUARD IS ACTUALLY LOAD-BEARING.
    /// `look`'s descriptor-relative arm hands the name to
    /// `FileSystemIdentityProvider.openChildDirectory`, which carries the
    /// IDENTICAL precondition and answers `EINVAL` on its own — so on that
    /// arm the guard is genuinely subsumed and no fixture can tell the two
    /// apart. The PERMISSION-CLASS FALLBACK is different: `lookAlongThePath`
    /// is a path-spelled `open(url.path, …)` with NO name check anywhere
    /// beneath it, and `O_NOFOLLOW` does not object to `..`. Reached with an
    /// unsafe last component it RESOLVES it and hands back a real directory
    /// identity — for a directory two levels up from the one the caller
    /// asked about.
    ///
    /// MEASURED with the guard deleted: `.directory(<identity of the
    /// container>)` where the guard produces `.unreadable(errno: EINVAL)`.
    /// The denial here is the ORDINARY production one — `~/.Trash` answers
    /// `EPERM` to every process without Full Disk Access — so this is the
    /// arm the guard has to hold, not an exotic one.
    ///
    /// No production URL can reach `look` with such a name (`target` is an
    /// admitted item, `landed` comes from `trashItem`), which is why the
    /// disposal cells cannot kill it; that makes this a cell about the
    /// FUNCTION's contract, and the contract is what a future caller will
    /// rely on.
    func testALookAtAnUnsafeNameIsRefusedRatherThanResolvedAlongThePath()
        throws
    {
        let container = try makeCacheContainer()
        let child = container.appendingPathComponent("child")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)

        // `URL.deletingLastPathComponent()` does not cancel a `..`, so the
        // container this resolves to IS `container` — which is what the
        // fallback would hand back if the guard were not there.
        let unsafe = child.appendingPathComponent("..")
        XCTAssertEqual(unsafe.lastPathComponent, "..",
                       "the fixture must actually carry an unsafe component")
        let provider = TrashDeniedProvider(
            denying: unsafe.deletingLastPathComponent(), with: EPERM
        )

        // THE FIXTURE IS THE PERMISSION CLASS, ASSERTED RATHER THAN ASSUMED:
        // without this the cell could pass against a container open that
        // simply succeeded, and the fallback — the only arm the guard is
        // load-bearing on — would never be the one answering.
        XCTAssertEqual(
            provider.openDirectoryNoFollowCarryingErrno(
                at: unsafe.deletingLastPathComponent()
            ),
            .failed(errno: EPERM),
            "the container open must land in the permission class, which is "
                + "what routes `look` onto its path-spelled fallback"
        )
        let denialsBefore = provider.refusals

        XCTAssertEqual(
            TrashDisposal.look(at: unsafe, provider: provider),
            .unreadable(errno: EINVAL),
            "an unsafe component is refused; with the guard deleted this "
                + "answers `.directory(...)` for the container two levels up "
                + "— a resolution through `..` taken by the path-spelled open"
        )
        XCTAssertEqual(
            provider.refusals, denialsBefore,
            "the guard answers BEFORE the container is even opened — which "
                + "is exactly why no disposal fixture can kill it, and why "
                + "this cell asks the function directly"
        )
        // AND THE MEASUREMENT THE GUARD PREVENTS, taken here so the failure
        // message above is not the only record of it: the path-spelled open
        // the fallback performs resolves `..` and lands on the container.
        let resolved = open(
            unsafe.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(
            resolved, 0,
            "`O_NOFOLLOW` does not object to `..` — that is the whole point"
        )
        defer { if resolved >= 0 { close(resolved) } }
        XCTAssertEqual(
            provider.identity(ofDescriptor: resolved),
            provider.identity(of: container),
            "…and what it lands on is the CONTAINER, two levels above the "
                + "name the caller asked about"
        )

        // AND `facts` CARRIES THE SAME GUARD OVER THE SAME HOLE. Its
        // permission-class fallback is `probeLeaf`, an `lstat` of the PATH
        // with no name check beneath it, so an unsafe component resolves
        // there exactly as it does above. Deleting `facts`' guard makes this
        // answer `ChildFacts(kind: .directory, identity: <the container>)`
        // where the guard answers `nil` — and `nil` is the value the caller
        // treats as "nothing identified", which is never a match.
        XCTAssertNil(
            TrashDisposal.facts(at: unsafe, provider: provider),
            "an unsafe component identifies NOTHING, on this arm too"
        )

        // AND `boundLeaf`'s COPY, whose removal changes the CAUSE rather than
        // the outcome. It answers BEFORE anything is resolved; without it the
        // malformed name is resolved first, and what comes back is whatever
        // the resolution happens to say — MEASURED on this fixture:
        // `.notTheAdmittedContainer`, i.e. the user is told the FOLDER THAT
        // HOLDS THE ITEM changed, about a target whose name was never valid.
        // That is the same wrong-fact-to-the-user class as A2, one layer
        // down. Deleting this guard alone leaves 361 tests across the six
        // destructive suites GREEN, which is why it needs its own assertion
        // rather than a disposal fixture.
        let parent = try admittedParent(of: child, provider: provider)
        XCTAssertThrowsError(
            try TrashDisposal.boundLeaf(
                of: unsafe, containedIn: parent, provider: provider
            )
        ) { error in
            XCTAssertEqual(
                (error as? DepthSafeRemoval.Failure)?.cause, .invalidTarget,
                "the refusal names the malformed target, not an errno: "
                    + "\(error)"
            )
        }
    }

    // MARK: - The control: an UNDISTURBED hop still disposes

    func testAnUndisturbedHopStillDisposesOnEveryArm() async throws {
        // Without this, all three cells above would pass against a
        // `dispose` that refused everything. Each arm is driven once with a
        // mover that performs no swap, and must complete and land the object.
        let provider = FileSystemIdentityProvider()
        let landings = try XCTUnwrap(self.landings)
        let fileManager = fm
        func move(_ url: URL, _ prove: () throws -> Void) throws -> URL? {
            try prove()
            let landed = landings.appendingPathComponent(url.lastPathComponent)
            try fileManager.moveItem(at: url, to: landed)
            return landed
        }

        let tree = base.appendingPathComponent("plain-tree")
        try fm.createDirectory(at: tree, withIntermediateDirectories: true)
        try await TrashDisposal.dispose(
            tree, containedIn: try admittedParent(of: tree, provider: provider),
            provider: provider, via: { try move($0, $1) }
        )
        XCTAssertFalse(fm.fileExists(atPath: tree.path))

        let file = base.appendingPathComponent("plain-file.txt")
        try Data("ours".utf8).write(to: file)
        let fileIdentity = try XCTUnwrap(provider.identity(of: file))
        try await TrashDisposal.dispose(
            file, expecting: .nonDirectoryLeaf(fileIdentity),
            provider: provider,
            containedIn: try admittedParent(of: file, provider: provider),
            via: { try move($0, $1) }
        )
        XCTAssertFalse(fm.fileExists(atPath: file.path))

        let verdictTree = base.appendingPathComponent("verdict-tree")
        try fm.createDirectory(
            at: verdictTree, withIntermediateDirectories: true
        )
        let treeIdentity = try XCTUnwrap(provider.identity(of: verdictTree))
        try await TrashDisposal.dispose(
            verdictTree, expecting: .directory(treeIdentity),
            provider: provider,
            containedIn: try admittedParent(of: verdictTree, provider: provider),
            via: { try move($0, $1) }
        )
        XCTAssertFalse(fm.fileExists(atPath: verdictTree.path))

        // FOUR arms since r13: the identity-free verdict is a disposal too,
        // and without this the r13 cells below would pass against a
        // `.noDirectoryTree` path that refused everything.
        let noTree = base.appendingPathComponent("no-tree.txt")
        try Data("ours".utf8).write(to: noTree)
        try await TrashDisposal.dispose(
            noTree, expecting: .noDirectoryTree, provider: provider,
            containedIn: try admittedParent(of: noTree, provider: provider),
            via: { try move($0, $1) }
        )
        XCTAssertFalse(fm.fileExists(atPath: noTree.path))
    }

    // MARK: - A (r13): the `.noDirectoryTree` arm, which bound NOTHING

    /// The container for the r13 cells: a directory of its own, so that
    /// swapping it does not disturb `landings`.
    private func makeCacheContainer() throws -> URL {
        let container = base.appendingPathComponent("cache-\(UUID().uuidString)")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    /// Replace the DIRECTORY that holds `target` with a different directory of
    /// the same name, carrying a stranger's file at the same leaf name — the
    /// two `rename(2)`s an attacker performs, spelled deterministically.
    ///
    /// Returns the stranger's file, which is what a disposal that binds
    /// nothing takes.
    @discardableResult
    private func swapTheContainer(of target: URL) throws -> URL {
        let container = target.deletingLastPathComponent()
        let stash = base.appendingPathComponent("stash-\(UUID().uuidString)")
        try fm.moveItem(at: container, to: stash)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        let stranger = container.appendingPathComponent(
            target.lastPathComponent
        )
        try Data("stranger".utf8).write(to: stranger)
        return stranger
    }

    /// **THE P1** (PR #460 codex r13, A): a `.noDirectoryTree` verdict carries
    /// no identity, so before this round BOTH of the arm's proofs reduced to
    /// "some non-directory answers to this name" — which ANY non-directory in
    /// ANY directory satisfies. The arm never opened `admittedParent` at all.
    ///
    /// Measured at 0139713 with exactly this fixture: the stranger's file was
    /// moved to the landing and `dispose` RETURNED NORMALLY.
    ///
    /// MUTATION: route `.noDirectoryTree` back through `proveStanding` and
    /// this cell fails — the disposal succeeds on a file it never inspected.
    func testTheNoTreeVerdictArmRefusesAStrangerInAnotherContainer()
        async throws
    {
        let provider = FileSystemIdentityProvider()
        let container = try makeCacheContainer()
        let target = container.appendingPathComponent("entry")
        try Data("ours".utf8).write(to: target)
        let parent = try admittedParent(of: target, provider: provider)
        let log = MoveLog()
        let landings = try XCTUnwrap(self.landings)
        let fileManager = fm

        // The swap lands BEFORE the disposal — the ordinary case, which must
        // be refused without disturbing the user's Trash at all.
        let stranger = try swapTheContainer(of: target)

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .noDirectoryTree, provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try prove()
                    log.record(url)
                    let landed = landings.appendingPathComponent(
                        url.lastPathComponent
                    )
                    try fileManager.moveItem(at: url, to: landed)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? DepthSafeRemoval.Failure,
            "a stranger's file in a stranger's folder must be refused: "
                + "\(String(describing: thrown))"
        )
        // AND THE CAUSE NAMES THE FOLDER, not the item (A2's taxonomy): the
        // permanent arm and the container-bound overload both say this for
        // the identical event.
        XCTAssertEqual(failure.cause, .notTheAdmittedContainer)
        XCTAssertTrue(log.urls.isEmpty,
                      "the refusal is BEFORE the move — the Trash is untouched")
        XCTAssertTrue(fm.fileExists(atPath: stranger.path),
                      "the stranger's file is still where its owner left it")
    }

    /// The SAME verdict, the same fixture, and the swap moved INSIDE the
    /// mover's hop — the window the seam's far-side proof exists to catch.
    ///
    /// MUTATION: delete the far-side `boundLeaf` comparison in
    /// `disposeBoundLeaf` and this cell fails; the stranger goes to the
    /// landing and the disposal returns normally.
    func testTheNoTreeVerdictArmRefusesALeafSwappedInsideTheMoversHop()
        async throws
    {
        let provider = FileSystemIdentityProvider()
        let container = try makeCacheContainer()
        let target = container.appendingPathComponent("entry")
        try Data("ours".utf8).write(to: target)
        let parent = try admittedParent(of: target, provider: provider)
        let log = MoveLog()
        let landings = try XCTUnwrap(self.landings)
        let fileManager = fm

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .noDirectoryTree, provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try self.swapInAStranger(at: url, directory: false)
                    try prove()
                    log.record(url)
                    let landed = landings.appendingPathComponent(
                        url.lastPathComponent
                    )
                    try fileManager.moveItem(at: url, to: landed)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? DepthSafeRemoval.Failure,
            "a leaf swapped inside the hop must be refused: "
                + "\(String(describing: thrown))"
        )
        XCTAssertEqual(failure.cause, .notTheInspectedObject)
        XCTAssertTrue(log.urls.isEmpty, "nothing may be moved")
        XCTAssertEqual(
            try String(contentsOf: target, encoding: .utf8), "stranger",
            "the stranger is still on disk, untrashed"
        )
    }

    /// **A1 — THE HALF A CONTAINER BINDING ALONE DOES NOT FIX.** The swap is
    /// the CONTAINER, and it lands inside the mover: the window
    /// `trashItem`'s own URL resolution owns, and the one the file header
    /// says the after-proof exists to catch.
    ///
    /// It does not catch it for THIS verdict, and that was measured: a probe
    /// that added `openAdmittedContainer` on both sides of the seam but kept
    /// `proveStanding` as the after-proof still trashed the stranger with
    /// `errors=[]`, because `look(at: landed)` answers `.noDirectoryTree`,
    /// the verdict IS `.noDirectoryTree`, and `disagreement` returns nil. The
    /// BINDING is the load-bearing half here, not the after-proof.
    ///
    /// THE OUTCOME IS THE DISCLOSED, HONEST ONE: the item is REFUSED — no
    /// entry, no bytes — and the stranger's file stays in the landing,
    /// because the rollback will not restore into a container it cannot
    /// prove. That is `.destinationNotTheAdmittedContainer`, whose message
    /// names the path the user can drag it back from.
    func testTheNoTreeVerdictArmRefusesAContainerSwappedInsideTheMover()
        async throws
    {
        let provider = FileSystemIdentityProvider()
        let container = try makeCacheContainer()
        let target = container.appendingPathComponent("entry")
        try Data("ours".utf8).write(to: target)
        let parent = try admittedParent(of: target, provider: provider)
        let landings = try XCTUnwrap(self.landings)
        let fileManager = fm
        let landed = landings.appendingPathComponent(target.lastPathComponent)

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .noDirectoryTree, provider: provider,
                containedIn: parent,
                via: { url, prove in
                    // The proof passes — everything is still ours — and the
                    // swap lands in the window no proof out here reaches.
                    try prove()
                    try self.swapTheContainer(of: url)
                    try fileManager.moveItem(at: url, to: landed)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? TrashDisposal.Failure,
            "a container swapped inside the mover must be refused: "
                + "\(String(describing: thrown))"
        )
        XCTAssertEqual(
            failure.cause, .destinationNotTheAdmittedContainer(landed.path)
        )
        let described = try XCTUnwrap(failure.errorDescription)
        XCTAssertTrue(
            described.contains("It is in the Trash at \(landed.path)"),
            described
        )
        XCTAssertEqual(
            try String(contentsOf: landed, encoding: .utf8), "stranger",
            "the disclosed residual: the wrongly-taken object stays in the "
                + "landing, named by the refusal, and nothing is reported freed"
        )
    }

    /// The verdict's OWN proposition, kept: `.noDirectoryTree` says no
    /// directory TREE of ours stood at this name, so a directory appearing
    /// there voids it. The permanent arm gets this refusal from the kernel
    /// (`unlinkat` without `AT_REMOVEDIR` cannot remove a directory —
    /// measured EPERM); `trashItem` would take it happily, so the kind check
    /// is what keeps the two arms level.
    ///
    /// MUTATION: change `.anythingButADirectory`'s `admits` to `true` and
    /// this cell fails — a directory nobody walked is trashed.
    func testTheNoTreeVerdictArmRefusesADirectoryThatAppearedAtTheName()
        async throws
    {
        let provider = FileSystemIdentityProvider()
        let container = try makeCacheContainer()
        let target = container.appendingPathComponent("entry")
        // The verdict was taken when the name held a file (or nothing); a
        // DIRECTORY stands there now.
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(
            to: target.appendingPathComponent("their-work.txt")
        )
        let parent = try admittedParent(of: target, provider: provider)
        let log = MoveLog()

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .noDirectoryTree, provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try prove()
                    log.record(url)
                    return nil
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? DepthSafeRemoval.Failure,
            "a directory at the name voids the verdict: "
                + "\(String(describing: thrown))"
        )
        XCTAssertEqual(failure.cause, .notTheInspectedObject)
        XCTAssertTrue(log.urls.isEmpty, "the refusal precedes the move")
        XCTAssertTrue(fm.fileExists(
            atPath: target.appendingPathComponent("their-work.txt").path
        ))
    }

    /// **A2 — THE TAXONOMY.** The `.directory` arm survived a container swap
    /// only INCIDENTALLY: `Identity` is dev+inode, so a stranger's directory
    /// can never equal the inspected inode and the refusal came back as
    /// `.notTheInspectedObject` — logged `content-drift`, the tag for "the
    /// item changed", for an event in which the item did not change and its
    /// FOLDER did.
    ///
    /// MUTATION: in `proveStandingUnderAdmittedContainer`, replace the
    /// `openAdmittedContainer` call with an unproved
    /// `provider.openDirectoryNoFollow` of the same directory — the r12 shape
    /// — and this cell fails on the cause (the disposal is still refused —
    /// that is the point: it is a taxonomy defect, not a destruction one).
    /// Named against the r14 spelling: the container proof and the leaf read
    /// are one act now, so there is no separate step (0) to delete.
    func testTheDirectoryVerdictArmNamesContainerDriftAsContainerDrift()
        async throws
    {
        let provider = FileSystemIdentityProvider()
        let container = try makeCacheContainer()
        let target = container.appendingPathComponent("tree")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let identity = try XCTUnwrap(provider.identity(of: target))
        let parent = try admittedParent(of: target, provider: provider)
        let log = MoveLog()

        // A stranger's DIRECTORY at the same name inside a stranger's folder.
        let strangerContainer = target.deletingLastPathComponent()
        let stash = base.appendingPathComponent("stash-\(UUID().uuidString)")
        try fm.moveItem(at: strangerContainer, to: stash)
        try fm.createDirectory(
            at: target, withIntermediateDirectories: true
        )

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .directory(identity), provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try prove()
                    log.record(url)
                    return nil
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? DepthSafeRemoval.Failure,
            String(describing: thrown)
        )
        XCTAssertEqual(
            failure.cause, .notTheAdmittedContainer,
            "the folder changed, so the refusal must say the folder changed "
                + "— `content-drift` sends the user to look at the wrong thing"
        )
        XCTAssertTrue(log.urls.isEmpty)
    }

    // ================================================================
    // MARK: - The symlinked CONTAINER below the admitted root (r14, V1-D2)
    // ================================================================

    /// FIVE DESTRUCTIVE PATHS, ONE FIXTURE, ONE ANSWER — and until r14 the
    /// `.directory` verdict's arm was the one that said no (PR #460 codex
    /// r14, V1-D2).
    ///
    /// `DepthSafeRemoval.openContainer` deliberately FOLLOWS symlinks, and
    /// its header says why in as many words: "a no-follow open would refuse it
    /// while `remove`'s open succeeded — a binding that refuses every deletion
    /// under a symlinked cache root". Every destructive path binds its
    /// container through it — except `dispose(_:expecting:…)`'s `.directory`
    /// arm, which proved the container that way and then read the LEAF with
    /// `look`, whose own container open carries `O_NOFOLLOW`. On this fixture
    /// that open answers `ENOTDIR`, and the user is told
    /// "…/victim: Not a directory" about a directory that plainly is one.
    ///
    /// MEASURED on this fixture at 6866012, production provider, same
    /// `AdmittedParent`: permanent DELETES, `dispose(_:containedIn:)`
    /// TRASHES, the `.noDirectoryTree` arm TRASHES, the `.nonDirectoryLeaf`
    /// arm TRASHES, and the `.directory` arm REFUSED `.posix(20)`. Driven end
    /// to end through the production composition, the same divergence read
    /// DEEP-PERM `errors=[] entries=1 gone=true` against DEEP-TRASH
    /// `errors=["…/Library/Caches/link/…: Not a directory"] entries=0
    /// gone=false`.
    ///
    /// Introduced by r12's descriptor-relative rewrite of `look` (on
    /// `origin/main` it was a path-spelled open of the TARGET, which resolves
    /// a symlinked container fine — syscall probe, Darwin 25.5:
    /// `open(link, O_DIRECTORY|O_NOFOLLOW)` = -1 errno 20,
    /// `open(link/victim, O_DIRECTORY|O_NOFOLLOW)` = fd, `open(link,
    /// O_DIRECTORY)` = fd). No shipped scanner reaches it today — both
    /// `.directory` producers emit only DIRECT children of their admitted
    /// roots, and when the symlink IS the admitted root `ContainerSnapshot`
    /// refuses both arms upstream — so it was latent, not shipping. Latent is
    /// not harmless: it was one-refuses/four-succeed with a message naming the
    /// wrong fact.
    ///
    /// AND THE THIRD PRODUCER IS OUT FOR A REASON THOSE TWO DO NOT COVER (PR
    /// #460 codex r16, G2). The sentence above accounts for the two
    /// `.directory` producers and for `ContainerSnapshot`; it says nothing
    /// about the GIT-WORKTREE path, which does not reach its target by
    /// listing an admitted root at all — it reads the REGISTRY
    /// (`GitWorktreeInventory` runs `git worktree list --porcelain -z`).
    /// `git worktree add` RESOLVES the symlink before it writes that
    /// registry, so the spelling the scanner reads back is always the real
    /// one and the symlinked-container arm is unreachable through it.
    ///
    /// MEASURED at r16 on this machine (git 2.50.1, Apple Git-155), THREE
    /// fresh repositories, each worktree created at `<base>/link<N>/wt<N>`
    /// where `link<N>` is a symlink to `<base>/real/holder<N>`: both
    /// `.git/worktrees/wt<N>/gitdir` and `git worktree list --porcelain` came
    /// back naming `<base>/real/holder<N>/wt<N>` — the RESOLVED spelling — in
    /// 3 of 3 cells. That is a property of `git`, not of this repository, so
    /// it is recorded here rather than fenced by a cell of ours.
    ///
    /// WHAT THIS CELL DOES AND DOES NOT COVER, SINCE ITS NAME USED TO OVERSTATE
    /// BOTH (PR #460 codex r15, D-P4a). It was called
    /// `…EveryDestructivePathAgreesUnderASymlinkedContainer` while exercising
    /// THREE of the five paths and only the FORWARD half of each — and the
    /// undo half was, at the time, exactly where the paths still disagreed
    /// (D-P1). It now runs all FIVE forward disposals, and its name says
    /// forward. The undo half is
    /// `…UndoPutsBackUnderASymlinkedContainerWhatItPutsBackUnderAPlainOne`
    /// and `…UndoNamesContainerDriftUnderASymlinkedContainer`.
    ///
    /// THE LANDING KEEPS ITS `O_NOFOLLOW` CONTAINER OPEN. The two opens are
    /// not the same question: the target's container is PROVED against the
    /// caller's `AdmittedParent`, and the Trash's is not proved against
    /// anything, which is why
    /// `…RefusesASymlinkedLandingContainer` must stay green through this.
    ///
    /// MUTATION: give the verdict arm back its path-spelled leaf read
    /// (`try proveStanding(inspected, at: target, provider: provider)` beside
    /// the container proof) and this cell alone fails with `.posix(20)`.
    func testEveryDestructivePathDisposesUnderASymlinkedContainer()
        async throws
    {
        let landings = try XCTUnwrap(self.landings)
        let provider = FileSystemIdentityProvider()
        let real = base.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        /// One victim directory under the SYMLINKED spelling of its
        /// container, with the container bound exactly as production binds
        /// it.
        func victim(
            _ name: String
        ) throws -> (URL, DepthSafeRemoval.AdmittedParent,
                     FileSystemIdentityProvider.Identity) {
            let url = link.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("ours".utf8).write(
                to: url.appendingPathComponent("ours.txt")
            )
            let identity = try XCTUnwrap(provider.identity(of: url))
            return (url, try admittedParent(of: url, provider: provider),
                    identity)
        }

        // 1. PERMANENT — the path the header quotes.
        let (permanent, permanentParent, permanentIdentity) =
            try victim("victim-permanent")
        try DepthSafeRemoval.remove(
            at: permanent, expecting: .directory(permanentIdentity),
            provider: provider, containedIn: permanentParent
        )
        XCTAssertFalse(fm.fileExists(atPath: permanent.path),
                       "the permanent arm refused a symlinked container")

        // 2. THE CONTAINER-BOUND OVERLOAD — the GUI's contents-mode and
        //    worktree disposal.
        let (bound, boundParent, _) = try victim("victim-bound")
        let boundLanding = landings.appendingPathComponent("victim-bound")
        try await TrashDisposal.dispose(
            bound, containedIn: boundParent, provider: provider,
            via: { url, prove in
                try prove()
                try fm.moveItem(at: url, to: boundLanding)
                return boundLanding
            }
        )
        XCTAssertTrue(fm.fileExists(atPath: boundLanding.path))

        // 3. THE `.directory` VERDICT ARM — the one that refused.
        let (verdict, verdictParent, verdictIdentity) =
            try victim("victim-verdict")
        let verdictLanding = landings.appendingPathComponent("victim-verdict")
        let log = MoveLog()
        try await TrashDisposal.dispose(
            verdict, expecting: .directory(verdictIdentity),
            provider: provider, containedIn: verdictParent,
            via: { url, prove in
                try prove()
                log.record(url)
                try fm.moveItem(at: url, to: verdictLanding)
                return verdictLanding
            }
        )
        XCTAssertEqual(log.urls.count, 1,
                       "the verdict arm refused before the move")
        XCTAssertFalse(fm.fileExists(atPath: verdict.path))
        XCTAssertTrue(
            fm.fileExists(
                atPath: verdictLanding.appendingPathComponent("ours.txt").path
            ),
            "the item the verdict arm disposed of is not at the landing"
        )

        // 4 AND 5. THE TWO NON-DIRECTORY VERDICT ARMS — measured in the doc
        // above and, until r15, not exercised here at all (D-P4a).
        for (name, verdict) in [
            ("victim-no-tree", UserDataProbeResult.InspectedRoot.noDirectoryTree),
            ("victim-leaf", nil),
        ] {
            let leaf = link.appendingPathComponent(name)
            try Data("ours".utf8).write(to: leaf)
            let leafParent = try admittedParent(of: leaf, provider: provider)
            let inspected = try verdict
                ?? .nonDirectoryLeaf(XCTUnwrap(provider.identity(of: leaf)))
            let leafLanding = landings.appendingPathComponent(name)
            try await TrashDisposal.dispose(
                leaf, expecting: inspected, provider: provider,
                containedIn: leafParent,
                via: { url, prove in
                    try prove()
                    try fm.moveItem(at: url, to: leafLanding)
                    return leafLanding
                }
            )
            XCTAssertFalse(fm.fileExists(atPath: leaf.path), name)
            XCTAssertEqual(
                try String(contentsOf: leafLanding, encoding: .utf8), "ours",
                "\(name): the item this arm disposed of is not at the landing"
            )
        }
    }

    /// AND THE SAME GUARD ON THE DESCRIPTOR-RELATIVE ARM, WHICH r14 GAVE A
    /// SECOND CALLER (PR #460 codex r14, V1-D2).
    ///
    /// `look(named:inDirectory:…)` used to be reachable only from `look(at:)`,
    /// which refuses the unsafe component before it ever calls — so the
    /// spelling underneath carried no guard of its own and nothing noticed.
    /// `proveStandingUnderAdmittedContainer` now resolves the TARGET's own
    /// last component under the proved container descriptor, and `openat`
    /// walks `..` out of a descriptor without complaint.
    ///
    /// WHAT IT COSTS IS THE CAUSE, NOT THE OUTCOME — MEASURED, and the
    /// opposite of what this comment first claimed. With the guard deleted the
    /// disposal is STILL refused, as `.notTheInspectedObject`. The arithmetic:
    /// `URL.deletingLastPathComponent()` does not cancel a `..` (it returns
    /// `<child>/../`, measured), so the container open resolves to `<child>/..`
    /// = the CONTAINER, and the `openat` of `..` under it then lands one level
    /// ABOVE the container — while the verdict names what the target's own
    /// spelling resolves to, which is the container itself. The two can never
    /// coincide, so the identity comparison catches it.
    ///
    /// It is therefore the A2 shape one layer down, and it is kept for the A2
    /// reason: the user is told THE ITEM CHANGED (`content-drift`) about a
    /// target whose NAME was never valid, and goes and looks at the wrong
    /// thing. `boundLeaf`'s copy of this guard is disclosed the same way, in
    /// `…ResolvedAlongThePath` above.
    ///
    /// MUTATION: delete the `isSafeComponent` guard at the top of
    /// `look(named:inDirectory:…)` and this cell alone fails, on the cause —
    /// measured over the full suite: 1532 executed / 2 skipped / 1 failure,
    /// exit 1.
    func testTheDirectoryVerdictArmRefusesATargetSpelledOutOfItsOwnContainer()
        async throws
    {
        let provider = FileSystemIdentityProvider()
        let container = try makeCacheContainer()
        let child = container.appendingPathComponent("child")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)

        // `deletingLastPathComponent()` does not cancel a `..`, so this
        // target's container is `child` and what the name RESOLVES to is
        // `container`.
        let unsafe = child.appendingPathComponent("..")
        XCTAssertEqual(unsafe.lastPathComponent, "..",
                       "the fixture must actually carry an unsafe component")
        // The verdict names what the `..` resolves to, which is what makes
        // the identity comparison agree with the guard removed.
        let identity = try XCTUnwrap(provider.identity(of: container))
        let parent = try admittedParent(of: unsafe, provider: provider)
        let log = MoveLog()

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                unsafe, expecting: .directory(identity), provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try prove()
                    log.record(url)
                    return nil
                }
            )
        } catch {
            thrown = error
        }

        XCTAssertEqual(
            unsafe.deletingLastPathComponent().lastPathComponent, "..",
            "the fixture's premise: `deletingLastPathComponent()` does not "
                + "cancel a `..`, which is what keeps the resolutions one "
                + "level apart"
        )
        XCTAssertEqual(
            log.urls, [],
            "a target spelled out of its own container reached the mover"
        )
        XCTAssertEqual(
            (thrown as? DepthSafeRemoval.Failure)?.cause, .posix(EINVAL),
            "the refusal must name the malformed name rather than resolving "
                + "it: \(String(describing: thrown))"
        )
        XCTAssertTrue(fm.fileExists(atPath: child.path),
                      "nothing may be disturbed")
    }

    // ================================================================
    // MARK: - The UNDO under the SAME symlinked container (r15, D-P1)
    // ================================================================

    /// The four Trash entry points, named so a disagreement between them
    /// reads as one row of a table rather than as four cells that happen to
    /// differ.
    private enum TrashArm: String, CaseIterable {
        case noVerdict, noDirectoryTree, nonDirectoryLeaf, directory

        /// Two of the four bind a NON-directory by construction:
        /// `.noDirectoryTree`'s admission is `.anythingButADirectory`, and a
        /// `.nonDirectoryLeaf` verdict is a statement about a leaf that is
        /// not one. The other two take a tree.
        var targetIsADirectory: Bool {
            switch self {
            case .noVerdict, .directory: return true
            case .noDirectoryTree, .nonDirectoryLeaf: return false
            }
        }
    }

    /// Dispose of `target` through ONE of the four Trash arms, with the
    /// object REPLACED inside the mover and the replacement really moved to
    /// `landed` — the shape that reaches `rollBack` with something to put
    /// back and the target's own name left free for it.
    ///
    /// Returns the error the disposal threw (every row here must throw).
    private func undoOutcome(
        _ arm: TrashArm, of target: URL, to landed: URL,
        provider: FileSystemIdentityProvider
    ) async throws -> Error? {
        let parent = try admittedParent(of: target, provider: provider)
        let fileManager = fm
        let directory = arm.targetIsADirectory
        let mover: TrashDisposal.Mover = { url, prove in
            // The far-side proof PASSES — everything is still ours — and the
            // swap lands in the window `trashItem`'s own URL resolution owns.
            try prove()
            try self.swapInAStranger(at: url, directory: directory)
            try fileManager.moveItem(at: url, to: landed)
            return landed
        }
        do {
            switch arm {
            case .noVerdict:
                try await TrashDisposal.dispose(
                    target, containedIn: parent, provider: provider,
                    via: mover
                )
            case .noDirectoryTree:
                try await TrashDisposal.dispose(
                    target, expecting: .noDirectoryTree, provider: provider,
                    containedIn: parent, via: mover
                )
            case .nonDirectoryLeaf:
                let identity = try XCTUnwrap(provider.identity(of: target))
                try await TrashDisposal.dispose(
                    target, expecting: .nonDirectoryLeaf(identity),
                    provider: provider, containedIn: parent, via: mover
                )
            case .directory:
                let identity = try XCTUnwrap(provider.identity(of: target))
                try await TrashDisposal.dispose(
                    target, expecting: .directory(identity),
                    provider: provider, containedIn: parent, via: mover
                )
            }
        } catch {
            return error
        }
        return nil
    }

    /// **D-P1 — THE UNDO REFUSED UNDER THE CONTAINER SPELLING r14 TAUGHT THE
    /// FORWARD PATH TO ACCEPT** (PR #460 codex r15).
    ///
    /// r14's V1-D2 aligned the `.directory` arm's PRE-move container open
    /// with `DepthSafeRemoval.openContainer`, which deliberately FOLLOWS.
    /// `rollBack`'s destination open was left on `openDirectoryNoFollow`, so
    /// the round moved this arm from "refuses before the move" to "moves the
    /// item to the Trash and then cannot put it back" — strictly worse.
    ///
    /// MEASURED at 8f71459, identical event, same fixture, ONLY the container
    /// spelling differing: a PLAIN container answers `.putBack` on all four
    /// arms, the landing is emptied and the object is restored to the
    /// target's name; a SYMLINKED one answers `.strandedInTrash` on all four,
    /// the put-back is NEVER ATTEMPTED, and the target is left ABSENT with
    /// the object in the Trash.
    ///
    /// MUTATION: put `rollBack`'s destination open back on
    /// `provider.openDirectoryNoFollow(at: target.deletingLastPathComponent())`
    /// and this cell fails on the four symlinked rows.
    func testTheUndoPutsBackUnderASymlinkedContainerWhatItPutsBackUnderAPlainOne()
        async throws
    {
        let landings = try XCTUnwrap(self.landings)
        let provider = FileSystemIdentityProvider()
        let real = base.appendingPathComponent("undo-real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("undo-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        for spelling in ["plain": real, "symlinked": link]
            .sorted(by: { $0.key < $1.key })
        {
            for arm in TrashArm.allCases {
                let name = "\(spelling.key)-\(arm.rawValue)"
                let target = spelling.value.appendingPathComponent(name)
                if arm.targetIsADirectory {
                    try fm.createDirectory(
                        at: target, withIntermediateDirectories: true
                    )
                    try Data("ours".utf8).write(
                        to: target.appendingPathComponent("ours.txt")
                    )
                } else {
                    try Data("ours".utf8).write(to: target)
                }
                let landed = landings.appendingPathComponent(name)

                let thrown = try await undoOutcome(
                    arm, of: target, to: landed, provider: provider
                )
                let failure = try XCTUnwrap(
                    thrown as? TrashDisposal.Failure,
                    "\(name): an object replaced inside the mover must be "
                        + "refused: \(String(describing: thrown))"
                )
                XCTAssertEqual(
                    failure.cause, .putBack,
                    "\(name): the object the disposal really took was named, "
                        + "re-bound and moved back"
                )
                XCTAssertFalse(
                    fm.fileExists(atPath: landed.path),
                    "\(name): the object may not be left in the Trash"
                )
                XCTAssertTrue(
                    fm.fileExists(atPath: target.path),
                    "\(name): the target's name must not be left EMPTY"
                )
            }
        }
    }

    /// **AND THE PROOF THE UNDO RESTORES INTO THE ADMITTED FOLDER, REACHED
    /// UNDER THAT SAME SPELLING** (PR #460 codex r15, D-P1(a)).
    ///
    /// `.destinationNotTheAdmittedContainer` was evidenced only under a plain
    /// container (`…RefusesAContainerSwappedInsideTheMover`). Under a
    /// symlinked one it was UNREACHABLE: the no-follow destination open
    /// returned `.strandedInTrash` first, so the arm the r14 documentation
    /// calls "the proof that the undo restores into the admitted folder"
    /// could not answer at all. The swap here is behind the LINK — the link
    /// still resolves, and what it resolves to is a stranger's directory.
    ///
    /// MUTATION: the same one as the cell above; this cell then answers
    /// `.strandedInTrash`, which names the right residual for the wrong
    /// reason.
    func testTheUndoNamesContainerDriftUnderASymlinkedContainer()
        async throws
    {
        let landings = try XCTUnwrap(self.landings)
        let provider = FileSystemIdentityProvider()
        let real = base.appendingPathComponent("drift-real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("drift-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let target = link.appendingPathComponent("entry")
        try Data("ours".utf8).write(to: target)
        let parent = try admittedParent(of: target, provider: provider)
        let landed = landings.appendingPathComponent("drift-entry")
        let fileManager = fm
        let stash = base.appendingPathComponent("drift-stash")

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .noDirectoryTree, provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try prove()
                    // The container swap, performed BEHIND the link: the
                    // spelling still resolves, and what it resolves to is a
                    // different inode holding a stranger's file.
                    try fileManager.moveItem(at: real, to: stash)
                    try fileManager.createDirectory(
                        at: real, withIntermediateDirectories: true
                    )
                    try Data("stranger".utf8).write(
                        to: real.appendingPathComponent("entry")
                    )
                    try fileManager.moveItem(at: url, to: landed)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? TrashDisposal.Failure,
            "a container swapped inside the mover must be refused: "
                + "\(String(describing: thrown))"
        )
        XCTAssertEqual(
            failure.cause, .destinationNotTheAdmittedContainer(landed.path),
            "the FOLDER changed, and the undo must say so rather than "
                + "reporting that it could not open the destination at all"
        )
        XCTAssertEqual(
            try String(contentsOf: landed, encoding: .utf8), "stranger",
            "the disclosed residual: the wrongly-taken object stays in the "
                + "landing, named by the refusal"
        )
    }

    // ================================================================
    // MARK: - A target that is simply GONE (r15, D-P2)
    // ================================================================

    /// **D-P2 — A TARGET THAT IS SIMPLY GONE WAS REPORTED AS A REPLACED ONE,
    /// ON ONE ARM OF FIVE** (PR #460 codex r15).
    ///
    /// MEASURED at 48073c9 on this fixture: `DepthSafeRemoval.remove`,
    /// `dispose(_:containedIn:)`, the `.noDirectoryTree` arm and the
    /// `.nonDirectoryLeaf` arm all answered `.posix(2)` — "…/victim: No such
    /// file or directory". The `.directory` verdict arm answered
    /// `.notTheInspectedObject` — "…the folder at this path is no longer the
    /// one that was inspected — it was REPLACED between the safety check and
    /// the deletion; refused, re-scan required" — and `CacheCleaner` logged it
    /// under `content-drift`. NOTHING WAS REPLACED; THE NAME IS EMPTY.
    ///
    /// Cause: `disagreement`'s `.absent` arm folded "gone" into "not the
    /// inspected object" for every verdict except `.noDirectoryTree`, while
    /// the other four paths reach `boundLeaf`'s `.absent` arm or the removal's
    /// own leaf open, both of which keep `ENOENT`.
    ///
    /// It is the r13-A2 / r14-V1-D2 class one arm over — the user is told the
    /// wrong fact and goes and looks at the wrong thing — and it is reachable
    /// as a plain race: the item vanishes between the revalidator's verdict
    /// and the disposal.
    ///
    /// MUTATION: return `.notTheInspectedObject` from `disagreement`'s
    /// `.absent` arm again and this cell alone fails, on the `.directory` row.
    func testAVanishedTargetIsNotReportedAsAReplacedOne() async throws {
        let provider = FileSystemIdentityProvider()
        let container = try makeCacheContainer()
        let log = MoveLog()

        /// A victim that EXISTS long enough to be inspected and is gone by
        /// the time the disposal runs — the race, spelled deterministically.
        func vanished(
            _ name: String, directory: Bool
        ) throws -> (URL, DepthSafeRemoval.AdmittedParent,
                     FileSystemIdentityProvider.Identity) {
            let url = container.appendingPathComponent(name)
            if directory {
                try fm.createDirectory(
                    at: url, withIntermediateDirectories: true
                )
            } else {
                try Data("ours".utf8).write(to: url)
            }
            let identity = try XCTUnwrap(provider.identity(of: url))
            let parent = try admittedParent(of: url, provider: provider)
            try fm.removeItem(at: url)
            XCTAssertFalse(fm.fileExists(atPath: url.path))
            return (url, parent, identity)
        }

        let mover: TrashDisposal.Mover = { url, prove in
            try prove()
            log.record(url)
            return nil
        }

        var causes: [String: DepthSafeRemoval.Failure.Cause?] = [:]

        // 1. PERMANENT.
        let (permanent, permanentParent, permanentIdentity) =
            try vanished("victim-permanent", directory: true)
        do {
            try DepthSafeRemoval.remove(
                at: permanent, expecting: .directory(permanentIdentity),
                provider: provider, containedIn: permanentParent
            )
            causes["permanent"] = .some(nil)
        } catch {
            causes["permanent"] = (error as? DepthSafeRemoval.Failure)?.cause
        }

        // 2. THE CONTAINER-BOUND OVERLOAD.
        let (bound, boundParent, _) =
            try vanished("victim-bound", directory: true)
        do {
            try await TrashDisposal.dispose(
                bound, containedIn: boundParent, provider: provider,
                via: mover
            )
            causes["bound"] = .some(nil)
        } catch {
            causes["bound"] = (error as? DepthSafeRemoval.Failure)?.cause
        }

        // 3. THE `.noDirectoryTree` ARM.
        let (tree, treeParent, _) =
            try vanished("victim-no-tree", directory: false)
        do {
            try await TrashDisposal.dispose(
                tree, expecting: .noDirectoryTree, provider: provider,
                containedIn: treeParent, via: mover
            )
            causes["noDirectoryTree"] = .some(nil)
        } catch {
            causes["noDirectoryTree"] =
                (error as? DepthSafeRemoval.Failure)?.cause
        }

        // 4. THE `.nonDirectoryLeaf` ARM.
        let (leaf, leafParent, leafIdentity) =
            try vanished("victim-leaf", directory: false)
        do {
            try await TrashDisposal.dispose(
                leaf, expecting: .nonDirectoryLeaf(leafIdentity),
                provider: provider, containedIn: leafParent, via: mover
            )
            causes["nonDirectoryLeaf"] = .some(nil)
        } catch {
            causes["nonDirectoryLeaf"] =
                (error as? DepthSafeRemoval.Failure)?.cause
        }

        // 5. THE `.directory` VERDICT ARM — the one that said "replaced".
        let (verdict, verdictParent, verdictIdentity) =
            try vanished("victim-verdict", directory: true)
        do {
            try await TrashDisposal.dispose(
                verdict, expecting: .directory(verdictIdentity),
                provider: provider, containedIn: verdictParent, via: mover
            )
            causes["directory"] = .some(nil)
        } catch {
            causes["directory"] = (error as? DepthSafeRemoval.Failure)?.cause
        }

        for path in ["permanent", "bound", "noDirectoryTree",
                     "nonDirectoryLeaf", "directory"] {
            XCTAssertEqual(
                causes[path] ?? nil, .posix(ENOENT),
                "\(path): a name nothing occupies is an ABSENCE, and telling "
                    + "the user their folder was REPLACED sends them to look "
                    + "at the wrong thing — "
                    + "\(String(describing: causes[path] ?? nil))"
            )
        }
        XCTAssertEqual(
            log.urls, [],
            "nothing may be handed to the mover for an item that is gone"
        )
    }

    /// The refusal a vanished target produces is the one the USER reads, and
    /// `CacheCleaner` tags it — so the two-fact split is asserted on the
    /// MESSAGE as well as on the cause.
    ///
    /// Before r15 the `.directory` arm's message opened "the folder at this
    /// path is no longer the one that was inspected — it was REPLACED between
    /// the safety check and the deletion", about an empty name.
    func testAVanishedTargetSaysNoSuchFileRatherThanReplaced() async throws {
        let provider = FileSystemIdentityProvider()
        let container = try makeCacheContainer()
        let target = container.appendingPathComponent("ghost")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let identity = try XCTUnwrap(provider.identity(of: target))
        let parent = try admittedParent(of: target, provider: provider)
        try fm.removeItem(at: target)

        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .directory(identity), provider: provider,
                containedIn: parent, via: { _, prove in try prove(); return nil }
            )
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(
            thrown as? DepthSafeRemoval.Failure,
            String(describing: thrown)
        )
        let described = try XCTUnwrap(failure.errorDescription)
        XCTAssertTrue(
            described.contains(String(cString: strerror(ENOENT))),
            "the message must name the absence: \(described)"
        )
        XCTAssertFalse(
            described.contains("it was replaced between the safety check"),
            "nothing was replaced — the name is empty: \(described)"
        )
    }

    // ================================================================
    // MARK: - What the failure MESSAGES may assert (r15, D-P3)
    // ================================================================

    /// **D-P3 — FIVE OF THE SIX MESSAGES OPENED BY ASSERTING A PROPOSITION NO
    /// ARM'S AFTER-PROOF TESTS** (PR #460 codex r15).
    ///
    /// `.putBack`, `.strandedInTrash`, `.lastSeenInTrash`,
    /// `.putBackTookAnotherObject` and `.destinationNotTheAdmittedContainer`
    /// all began "the folder at this path is no longer the one that was
    /// inspected". The after-proof establishes only that the LANDING does not
    /// hold what was bound; IT NEVER RE-READS THE TARGET.
    ///
    /// MEASURED at df551b1 with this fixture — the mover proves, moves
    /// NOTHING, and reports a landing where nothing stands — on all four
    /// Trash paths: `.lastSeenInTrash`, and the target still on disk,
    /// untouched, SAME INODE. The message told the user their folder had been
    /// replaced, and told them to look in the Trash, for an item that never
    /// left.
    ///
    /// (`.destinationUnknown`, the sixth, never carried the clause.)
    ///
    /// MUTATION: put the old opening clause back on any of the five and this
    /// cell fails on that row.
    func testNoFailureMessageAssertsTheTargetWasReplacedWithoutReadingIt()
        async throws
    {
        let landings = try XCTUnwrap(self.landings)
        let provider = FileSystemIdentityProvider()
        let container = try makeCacheContainer()

        for arm in TrashArm.allCases {
            let name = "untouched-\(arm.rawValue)"
            let target = container.appendingPathComponent(name)
            if arm.targetIsADirectory {
                try fm.createDirectory(
                    at: target, withIntermediateDirectories: true
                )
                try Data("ours".utf8).write(
                    to: target.appendingPathComponent("ours.txt")
                )
            } else {
                try Data("ours".utf8).write(to: target)
            }
            let before = try XCTUnwrap(provider.identity(of: target))
            // A NAME NOTHING OCCUPIES: the disposal reports a landing it never
            // put anything at — `moverMovedNothing`.
            let landed = landings.appendingPathComponent("nowhere-\(name)")

            let thrown = try await outcomeOfAMoverThatMovesNothing(
                arm, of: target, reporting: landed, provider: provider
            )
            let failure = try XCTUnwrap(
                thrown as? TrashDisposal.Failure,
                "\(name): \(String(describing: thrown))"
            )
            XCTAssertEqual(failure.cause, .lastSeenInTrash(landed.path),
                           "\(name)")

            // THE FIXTURE'S OWN PREMISE, ASSERTED: the item never left.
            XCTAssertEqual(
                provider.identity(of: target), before,
                "\(name): the fixture must leave the target untouched — that "
                    + "is the whole of what makes the old clause false"
            )

            let described = try XCTUnwrap(failure.errorDescription)
            XCTAssertFalse(
                described.contains(
                    "the folder at this path is no longer the one that was "
                        + "inspected"
                ),
                "\(name): the after-proof never re-read the target, so no "
                    + "message may assert that it changed: \(described)"
            )
            XCTAssertTrue(
                described.contains(
                    "the disposal could not be proved to have moved the item "
                        + "that was inspected"
                ),
                "\(name): \(described)"
            )
        }
    }

    /// The other four causes' openings, taken off the type rather than off a
    /// fixture — three of them need a race the suite drives elsewhere, and
    /// what is asserted here is only the CLAUSE, which is a property of the
    /// message and not of the event.
    func testEveryTrashFailureMessageOpensWithWhatWasActuallyProved() throws {
        let landed = "/tmp/landed"
        let causes: [TrashDisposal.Failure.Cause] = [
            .putBack,
            .strandedInTrash(landed),
            .lastSeenInTrash(landed),
            .putBackTookAnotherObject(landed),
            .destinationNotTheAdmittedContainer(landed),
        ]
        for cause in causes {
            let failure = TrashDisposal.Failure(path: "/tmp/x", cause: cause)
            let described = try XCTUnwrap(failure.errorDescription)
            XCTAssertTrue(
                described.contains(
                    "the disposal could not be proved to have moved the item "
                        + "that was inspected"
                ),
                "\(cause): \(described)"
            )
            XCTAssertFalse(
                described.contains("no longer the one that was inspected"),
                "\(cause): \(described)"
            )
        }
        // AND THE SIXTH, WHICH NEVER CARRIED THE CLAUSE AND MUST NOT GAIN ONE:
        // it is the one cause raised before anything about the landing is
        // known at all.
        let unknown = TrashDisposal.Failure(
            path: "/tmp/x", cause: .destinationUnknown
        )
        let unknownDescribed = try XCTUnwrap(unknown.errorDescription)
        XCTAssertFalse(
            unknownDescribed.contains("was inspected"), unknownDescribed
        )
    }

    // ================================================================
    // MARK: - The taxonomy gap `.strandedInTrash` covers (r16, A-P4a)
    // ================================================================

    /// **A-P4(a) — RECORDED, NOT FIXED: a destination container that is no
    /// longer a FOLDER answers `.strandedInTrash`, and only
    /// `.destinationNotTheAdmittedContainer` tells the user their folder
    /// changed** (PR #460 codex r16).
    ///
    /// `rollBack`'s destination open goes through
    /// `DepthSafeRemoval.openAdmittedContainer`, and its `catch` splits
    /// exactly two ways: `.notTheAdmittedContainer` becomes
    /// `.destinationNotTheAdmittedContainer`, and EVERYTHING ELSE becomes
    /// `.strandedInTrash`. A container replaced by a regular file cannot even
    /// be OPENED as a directory, so it never reaches the identity comparison
    /// and lands in the second bucket.
    ///
    /// MEASURED by this cell: all four Trash arms, both container spellings —
    /// eight rows, `.strandedInTrash` on every one. The refusal then says
    /// "it is in the Trash at <path>. Move it back from there", which is TRUE
    /// and actionable, and carries no hint that the folder it came from is no
    /// longer a folder.
    ///
    /// WHY IT IS RECORDED RATHER THAN SPLIT. The item is safe and its path is
    /// named, which is the whole of what the cause promises; a seventh cause
    /// would need its own user-facing entry and its own evidence, and this
    /// round is not the place to add one on the strength of a note. This cell
    /// exists so the claim is a measurement rather than a reading, and so the
    /// row moves visibly if anyone does split it.
    func testADestinationContainerTurnedIntoAFileIsReportedAsAStranding()
        async throws
    {
        let landings = try XCTUnwrap(self.landings)
        let provider = FileSystemIdentityProvider()

        for spelling in ["plain", "symlinked"] {
            for arm in TrashArm.allCases {
                let name = "notafolder-\(spelling)-\(arm.rawValue)"
                // The REAL directory, and the spelling the disposal is given.
                let real = base.appendingPathComponent("\(name)-real")
                try fm.createDirectory(
                    at: real, withIntermediateDirectories: true
                )
                let container: URL
                if spelling == "symlinked" {
                    container = base.appendingPathComponent("\(name)-link")
                    try fm.createSymbolicLink(
                        at: container, withDestinationURL: real
                    )
                } else {
                    container = real
                }
                let target = container.appendingPathComponent("entry")
                if arm.targetIsADirectory {
                    try fm.createDirectory(
                        at: target, withIntermediateDirectories: true
                    )
                    try Data("ours".utf8).write(
                        to: target.appendingPathComponent("ours.txt")
                    )
                } else {
                    try Data("ours".utf8).write(to: target)
                }
                let parent = try admittedParent(
                    of: target, provider: provider
                )
                let landed = landings.appendingPathComponent(name)
                let directory = arm.targetIsADirectory
                let fileManager = fm

                let mover: TrashDisposal.Mover = { url, prove in
                    try prove()
                    // The object is replaced and the replacement really moved,
                    // so the after-proof refuses and the rollback runs …
                    try fileManager.removeItem(at: url)
                    if directory {
                        try fileManager.createDirectory(
                            at: url, withIntermediateDirectories: true
                        )
                        try Data("stranger".utf8).write(
                            to: url.appendingPathComponent("their-work.txt")
                        )
                    } else {
                        try Data("stranger".utf8).write(to: url)
                    }
                    try fileManager.moveItem(at: url, to: landed)
                    // … and the folder that HELD it is no longer a folder.
                    try fileManager.removeItem(at: real)
                    try Data("not a folder".utf8).write(to: real)
                    return landed
                }

                var thrown: Error?
                do {
                    switch arm {
                    case .noVerdict:
                        try await TrashDisposal.dispose(
                            target, containedIn: parent, provider: provider,
                            via: mover
                        )
                    case .noDirectoryTree:
                        try await TrashDisposal.dispose(
                            target, expecting: .noDirectoryTree,
                            provider: provider, containedIn: parent,
                            via: mover
                        )
                    case .nonDirectoryLeaf:
                        let identity = try XCTUnwrap(
                            provider.identity(of: target)
                        )
                        try await TrashDisposal.dispose(
                            target, expecting: .nonDirectoryLeaf(identity),
                            provider: provider, containedIn: parent,
                            via: mover
                        )
                    case .directory:
                        let identity = try XCTUnwrap(
                            provider.identity(of: target)
                        )
                        try await TrashDisposal.dispose(
                            target, expecting: .directory(identity),
                            provider: provider, containedIn: parent,
                            via: mover
                        )
                    }
                } catch {
                    thrown = error
                }

                let failure = try XCTUnwrap(
                    thrown as? TrashDisposal.Failure,
                    "\(name): \(String(describing: thrown))"
                )
                XCTAssertEqual(
                    failure.cause, .strandedInTrash(landed.path),
                    "\(name): a container that is not a directory cannot be "
                        + "opened, so it never reaches the identity "
                        + "comparison that would name the drift"
                )
                XCTAssertTrue(
                    fm.fileExists(atPath: landed.path),
                    "\(name): the disclosed residual — the object stays at "
                        + "the landing the refusal names"
                )
            }
        }
    }

    // ================================================================
    // MARK: - The WHOLE message, not its opening (r16, A-P1/A-P2)
    // ================================================================

    /// Every cause, spelled once so a new one cannot be added without being
    /// fenced: this `switch` has no `default:`, so the compiler is the rot
    /// gate.
    private func label(for cause: TrashDisposal.Failure.Cause) -> String {
        switch cause {
        case .putBack: return "putBack"
        case .strandedInTrash: return "strandedInTrash"
        case .lastSeenInTrash: return "lastSeenInTrash"
        case .putBackTookAnotherObject: return "putBackTookAnotherObject"
        case .destinationNotTheAdmittedContainer:
            return "destinationNotTheAdmittedContainer"
        case .destinationUnknown: return "destinationUnknown"
        }
    }

    /// WHAT ONE PROPOSITION'S TEXT MUST — AND MUST NOT — LOOK LIKE.
    ///
    /// `all`/`any` are ANTI-DELETION: they keep a disclosure from being
    /// quietly dropped. The other four are the ANTI-ADDITION half, and they
    /// are the reason this is not another phrase list: they are stated over
    /// CATEGORIES of word (does this clause name a place at all? does it
    /// claim a net effect at all?) rather than over sentences anybody had to
    /// think of first.
    private struct FactContract {
        /// Every one of these must appear in a clause tagged with the fact.
        var all: [String] = []
        /// At least one of these must, when the list is non-empty.
        var any: [String] = []
        /// The fact is ABOUT where something is, so a clause carrying it may
        /// name places. A clause tagged with any other fact may not.
        var isWhereabouts = false
        /// …and it places something POSITIVELY. An unhedged clause that
        /// names a place must carry a fact of this kind.
        var isPositivePlacement = false
        /// The fact is about the REPORT or the REMEDY: it may name no place.
        var forbidsPlaces = false
        /// …and may make no claim about bytes.
        var forbidsNetEffect = false
    }

    /// The contract for each proposition, spelled through a `default`-less
    /// `switch` so a new one cannot enter the vocabulary unexamined.
    private func contract(
        for fact: TrashDisposal.Failure.Established
    ) -> FactContract {
        switch fact {
        case .theDisposalWasNotProvedToHaveMovedTheItem:
            return FactContract(
                all: ["could not be proved to have moved the item"],
                isWhereabouts: true
            )
        case .theItemIsBackAtTheTarget:
            return FactContract(
                all: ["identified at this path"], any: ["PUT BACK"],
                isWhereabouts: true, isPositivePlacement: true
            )
        case .theItemIsAtTheLanding:
            return FactContract(
                any: [Self.landingToken, "from there"],
                isWhereabouts: true, isPositivePlacement: true
            )
        case .theLandingDidNotYieldTheItem:
            return FactContract(
                all: [Self.landingToken, "cannot be found"],
                isWhereabouts: true
            )
        case .theLandingNameWasRepointed:
            return FactContract(
                all: [Self.landingToken], any: ["re-used", "re-pointed"],
                isWhereabouts: true, isPositivePlacement: true
            )
        case .aStrangerStandsAtTheTarget:
            return FactContract(
                all: [Self.targetToken, "stands at"],
                isWhereabouts: true, isPositivePlacement: true
            )
        case .theHoldingFolderIsNotTheAdmittedOne:
            return FactContract(
                all: ["folder"], isWhereabouts: true,
                isPositivePlacement: true
            )
        case .theLandingWasNotReported:
            return FactContract(
                all: ["did not report where"], isWhereabouts: true
            )
        case .theTrashHoldsWhatItTook:
            return FactContract(
                all: ["Trash"], isWhereabouts: true,
                isPositivePlacement: true
            )
        case .theItemsWhereaboutsAreNotEstablished:
            return FactContract(
                all: ["was NOT established"], isWhereabouts: true
            )
        case .nothingWasReportedFreed:
            return FactContract(all: ["reported freed"], forbidsPlaces: true)
        case .theRemedyForThisRefusal:
            return FactContract(forbidsPlaces: true, forbidsNetEffect: true)
        case .nothingWasFreedOnDisk, .theTargetWasReplaced:
            // Unsatisfiable ON PURPOSE. No arm establishes these, the fence
            // below asserts that no cause claims them, and the contract is
            // written so that a claim tagged with one fails even if the
            // `established` table is edited to admit it.
            return FactContract(all: ["\u{0}NO ARM ESTABLISHES THIS\u{0}"])
        }
    }

    private static let targetToken = "«target»"
    private static let landingToken = "«landing»"
    private static let targetPath = "/fixture/TARGET-PATH"
    private static let landingPath = "/fixture/LANDING-PATH"

    /// A clause with its two payload paths replaced by tokens.
    ///
    /// THE ONE NORMALISATION THAT IS A JUDGEMENT, DISCLOSED AS ONE: the
    /// string "Move to Trash" is the NAME OF THE APP'S CHECKBOX, not a
    /// location, and it is removed before the place scan so that the remedy
    /// clause naming that control is not read as placing the item in the
    /// Trash. A false sentence that hid behind those four words would evade
    /// the place rule; see the residual list on the fence itself.
    private func normalised(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: "Move to Trash", with: "«control»"
        )
        out = out.replacingOccurrences(
            of: Self.landingPath, with: Self.landingToken
        )
        return out.replacingOccurrences(
            of: Self.targetPath, with: Self.targetToken
        )
    }

    /// Does this clause name a place? A CATEGORY, not a phrase: the two
    /// payload paths, the Trash, and the locative pronouns.
    private func namesAPlace(_ normalisedText: String) -> Bool {
        if normalisedText.contains(Self.targetToken)
            || normalisedText.contains(Self.landingToken)
            || normalisedText.contains("Trash")
            || normalisedText.contains("this path") { return true }
        return normalisedText.range(
            of: "\\b(there|here|somewhere|elsewhere)\\b",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Does it claim, or deny, a net effect on the disk?
    private func namesANetEffect(_ normalisedText: String) -> Bool {
        normalisedText.range(
            of: "\\b(free|freed|frees|reclaimed|deleted|removed)\\b",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Is the clause HEDGED — does it say, in its own words, that the thing
    /// it mentions was not established?
    private func isHedged(_ normalisedText: String) -> Bool {
        for marker in [
            "could not", "cannot", "was NOT", "were NOT", "not established",
            "did not", "no longer", "may ", "might ",
        ] where normalisedText.contains(marker) { return true }
        return false
    }

    /// **M1 — THE FENCE AGAINST PHRASING-FIXES WAS ITSELF A PHRASING-FIX**
    /// (PR #460 codex r17).
    ///
    /// r16 widened r15's opening-clause guard to the whole message by adding
    /// a list of FORBIDDEN PHRASES. MEASURED at e6afc9f, `swift test --filter
    /// TrashDisposalHopProofTests` (36 cells), each mutation rebuilt:
    ///
    /// | mutation | result |
    /// |---|---|
    /// | restore "Look in the Trash for it" on `.lastSeenInTrash` | RED |
    /// | restore "…the item the Trash took is still in the Trash" | RED |
    /// | **"Check your Trash for the item."** on `.lastSeenInTrash` | **GREEN 36/36** |
    /// | **"The object the Trash took remains where the Trash put it."** | **GREEN** |
    ///
    /// A blocklist catches the sentences somebody already wrote down and
    /// nothing else. This cell asserts a PROPERTY instead, over the type:
    ///
    /// 1. every clause of every message is TAGGED with the one proposition
    ///    it asserts, and `errorDescription` is the join of those clauses and
    ///    nothing else — so there is no untagged text to hide in;
    /// 2. no clause may carry a proposition its own cause's code path did not
    ///    establish (`TrashDisposal.Failure.established(for:)`, derived at the
    ///    raise sites);
    /// 3. a clause that NAMES A PLACE AT ALL — either payload path, the
    ///    Trash, or a locative pronoun — must carry a whereabouts
    ///    proposition, and if it does so without hedging, a POSITIVE one;
    /// 4. a clause that makes a NET-EFFECT claim at all must be the one about
    ///    the report, and must say "reported freed";
    /// 5. a clause may contain no sentence break, so a new sentence is
    ///    necessarily a new clause and necessarily tagged;
    /// 6. the two propositions this file has shipped and retired — "the
    ///    target was replaced" and "nothing was freed on disk" — are
    ///    established by NO cause, and their contract is unsatisfiable.
    ///
    /// None of (2)–(6) mentions a sentence, so a NEW false sentence fails
    /// without anyone having predicted its wording. MEASURED at 36cf469,
    /// eight mutations of `TrashDisposal.Failure.claims(path:cause:)`, each
    /// rebuilt and run as `swift test --filter TrashDisposalHopProofTests`
    /// (37 cells). NONE of these wordings appears anywhere in this repository
    /// before this round:
    ///
    /// | mutation | fence |
    /// |---|---|
    /// | `" Check your Trash for the item."` added to `.lastSeenInTrash`, tagged `.theItemsWhereaboutsAreNotEstablished` | **RED** (2 failures) |
    /// | the same sentence tagged `.theTrashHoldsWhatItTook` | **RED** (1) |
    /// | the same sentence GRAFTED onto the end of the whereabouts clause | **RED** (1) |
    /// | `" The object the Trash took remains where the Trash put it."` added to `.putBackTookAnotherObject` | **RED** (2) |
    /// | `"; nothing was reported freed"` reworded to `"; the bytes it took were reclaimed"` | **RED** (8) |
    /// | `" Empty your Trash when you are done"` added to `.strandedInTrash` as a REMEDY | **RED** (3) |
    /// | `"; your disk now has that space back"` added to `.putBack` as a REMEDY | GREEN |
    /// | `"at this path"` → `"at this path within the last second"` | GREEN |
    ///
    /// Every RED row is this cell. The two GREEN rows are the residual, and
    /// they are what it CANNOT catch, stated rather than left to be
    /// discovered:
    ///
    /// * A NET-EFFECT claim made without any word in the net-effect lexicon
    ///   ("your disk now has that space back"). The lexicon is a category,
    ///   but it is a category of WORDS.
    /// * A false clause GRAFTED INTO an existing clause, when the result
    ///   still satisfies that fact's `all`/`any` markers and adds no place
    ///   and no net-effect word — a claim about TIME, or about who did it.
    ///   Rule (5) forces a new SENTENCE to be a new clause; it cannot force
    ///   a new CLAUSE to be one.
    /// * A sentence hidden behind the literal string "Move to Trash", which
    ///   `normalised(_:)` removes as the app's control name.
    /// * An author who edits `established(for:)` itself to admit a
    ///   proposition the code path does not prove. That table is the
    ///   derivation, and nothing here can check a derivation against the
    ///   code — but it is one visible, reviewable edit rather than a
    ///   sentence buried in a string literal, which is the whole of what
    ///   this change buys.
    func testNoTrashFailureMessageAssertsAnythingItsOwnProofDidNotEstablish()
        throws
    {
        let causes: [TrashDisposal.Failure.Cause] = [
            .putBack, .strandedInTrash(Self.landingPath),
            .lastSeenInTrash(Self.landingPath),
            .putBackTookAnotherObject(Self.landingPath),
            .destinationNotTheAdmittedContainer(Self.landingPath),
            .destinationUnknown,
        ]
        // THE ROT GATE: `label(for:)` is a `default`-less switch, so a
        // seventh cause breaks the build, and this count catches one that was
        // added to the enum but not to the list above.
        XCTAssertEqual(
            Set(causes.map { label(for: $0) }).count, 6,
            "every cause must be audited exactly once"
        )

        var used: Set<TrashDisposal.Failure.Established> = []
        for cause in causes {
            let name = label(for: cause)
            let established = TrashDisposal.Failure.established(for: cause)
            let claims = TrashDisposal.Failure.claims(
                path: Self.targetPath, cause: cause
            )

            // (6) The two retired propositions are established by nobody.
            XCTAssertFalse(
                established.contains(.theTargetWasReplaced),
                "\(name): no arm re-reads the target after the move"
            )
            XCTAssertFalse(
                established.contains(.nothingWasFreedOnDisk),
                "\(name): no arm counts bytes after the move"
            )

            // (1) The message is the join and nothing else.
            let failure = TrashDisposal.Failure(
                path: Self.targetPath, cause: cause
            )
            XCTAssertEqual(
                failure.errorDescription, claims.map(\.text).joined(),
                "\(name): errorDescription must carry no free text"
            )

            for claim in claims {
                used.insert(claim.establishes)
                let fact = claim.establishes
                let text = normalised(claim.text)
                let rule = contract(for: fact)
                let where_ = "\(name)/\(fact.rawValue): \(text)"

                // (2) The proposition must be one this cause proved.
                XCTAssertTrue(
                    established.contains(fact),
                    "\(where_) — this cause's code path does not establish it"
                )
                // (5) One clause, no sentence break.
                XCTAssertFalse(
                    text.contains(". "),
                    "\(where_) — a new sentence must be a new, tagged clause"
                )
                // Anti-deletion: the disclosure cannot be silently dropped.
                for marker in rule.all {
                    XCTAssertTrue(text.contains(marker), "\(where_) — «\(marker)»")
                }
                if !rule.any.isEmpty {
                    XCTAssertTrue(
                        rule.any.contains(where: { text.contains($0) }),
                        "\(where_) — one of \(rule.any)"
                    )
                }
                // (3) Naming a place commits the clause to a whereabouts
                // proposition, and doing so unhedged to a positive one.
                let place = namesAPlace(text)
                if place {
                    XCTAssertTrue(
                        rule.isWhereabouts,
                        "\(where_) — names a place under a proposition that "
                            + "is not about where anything is"
                    )
                    if !isHedged(text) {
                        XCTAssertTrue(
                            rule.isPositivePlacement,
                            "\(where_) — places something without hedging, "
                                + "so the proposition must be one that was "
                                + "positively established"
                        )
                    }
                }
                if rule.forbidsPlaces {
                    XCTAssertFalse(
                        place, "\(where_) — this proposition names no place"
                    )
                }
                // (4) Any net-effect word belongs to the report clause.
                if namesANetEffect(text) {
                    XCTAssertEqual(
                        fact, .nothingWasReportedFreed,
                        "\(where_) — a claim about what happened on disk"
                    )
                    XCTAssertTrue(
                        text.contains("reported freed"),
                        "\(where_) — the report is what was established, not "
                            + "the disk"
                    )
                }
                if rule.forbidsNetEffect {
                    XCTAssertFalse(namesANetEffect(text), where_)
                }
                // r15's retired opening, still fenced everywhere.
                XCTAssertFalse(
                    text.contains("no longer the one that was inspected"),
                    where_
                )
            }
        }

        // ROT: every proposition in the vocabulary is either used by some
        // cause or is one of the two no arm establishes.
        for fact in TrashDisposal.Failure.Established.allCases
        where !used.contains(fact) {
            XCTAssertTrue(
                fact == .nothingWasFreedOnDisk
                    || fact == .theTargetWasReplaced,
                "\(fact.rawValue) is dead vocabulary — remove it or use it"
            )
        }
    }
    /// **A-P2 — `.lastSeenInTrash` SENT THE USER TO THE TRASH FOR AN ITEM
    /// THAT NEVER LEFT** (PR #460 codex r16).
    ///
    /// The identical fixture D-P3 used — the mover proves, moves NOTHING and
    /// reports a landing where nothing stands. MEASURED at 3110d1e on all
    /// four Trash arms: `.lastSeenInTrash`, zero moves, the item STILL AT THE
    /// TARGET at the SAME INODE, and NOTHING in the landings directory at
    /// all. D-P3 retired the opening clause of that message and left its tail
    /// telling the user to go and look in the Trash.
    ///
    /// MUTATION: restore "Look in the Trash for it" and this cell fails on
    /// all four arms.
    func testTheLastSeenMessageDoesNotSendTheUserToTheTrashForAnItemStillOnDisk()
        async throws
    {
        let landings = try XCTUnwrap(self.landings)
        let provider = FileSystemIdentityProvider()
        let container = try makeCacheContainer()

        for arm in TrashArm.allCases {
            let name = "never-left-\(arm.rawValue)"
            let target = container.appendingPathComponent(name)
            if arm.targetIsADirectory {
                try fm.createDirectory(
                    at: target, withIntermediateDirectories: true
                )
                try Data("ours".utf8).write(
                    to: target.appendingPathComponent("ours.txt")
                )
            } else {
                try Data("ours".utf8).write(to: target)
            }
            let before = try XCTUnwrap(provider.identity(of: target))
            let landed = landings.appendingPathComponent("nowhere-\(name)")

            let thrown = try await outcomeOfAMoverThatMovesNothing(
                arm, of: target, reporting: landed, provider: provider
            )
            let failure = try XCTUnwrap(
                thrown as? TrashDisposal.Failure,
                "\(name): \(String(describing: thrown))"
            )
            XCTAssertEqual(failure.cause, .lastSeenInTrash(landed.path),
                           "\(name)")
            // THE PREMISE, ASSERTED ON BOTH SIDES: the item never left, and
            // the Trash is EMPTY of it.
            XCTAssertEqual(
                provider.identity(of: target), before,
                "\(name): the item must still be at the target, same inode"
            )
            XCTAssertEqual(
                try fm.contentsOfDirectory(atPath: landings.path)
                    .filter { $0.contains(name) },
                [],
                "\(name): nothing of this item may be in the landing "
                    + "directory — that is what makes the tail false"
            )

            let described = try XCTUnwrap(failure.errorDescription)
            XCTAssertFalse(
                described.contains("Look in the Trash for it"),
                "\(name): the item is at \(target.path) at the same inode "
                    + "and nothing of it is in the Trash: \(described)"
            )
            XCTAssertTrue(
                described.contains("Where the item is now was NOT "
                                   + "established"),
                "\(name): \(described)"
            )
        }
    }

    /// Re-points the landing INSIDE `rollBack`'s own re-bind — after the
    /// `fstatat` has answered and before `renameatx_np` uses the name.
    ///
    /// Unlike `OrphanedCachesScannerTests`' twin, the object the Trash took
    /// is moved OUT of the landing's own container, which is the event
    /// `.putBackTookAnotherObject`'s old tail denied.
    ///
    /// Only the `.directory` verdict arm may use this: `identified` takes a
    /// `.directory` sighting's identity off the descriptor `look` already
    /// holds and does NOT call `facts`, so the FIRST `probeChild` naming the
    /// landing is the re-bind. On the `facts`-reading arms it would fire one
    /// call too early.
    private final class RepointTheLandingInsideTheReBind:
        FileSystemIdentityProvider {
        var landed: URL!
        /// Where the taken object goes — OUTSIDE the landing's container.
        var outOfTheTrash: URL!
        /// The object that takes the landing's name, built outside it.
        var strangerSource: URL!
        private(set) var swapped = false

        override func probeChild(
            inDirectory descriptor: Int32, named name: String,
            logical: @autoclosure () -> URL
        ) -> ChildProbe {
            let url = logical()
            let answer = super.probeChild(
                inDirectory: descriptor, named: name, logical: url
            )
            guard !swapped,
                  url.standardizedFileURL.path
                      == landed.standardizedFileURL.path
            else { return answer }
            swapped = true
            try? FileManager.default.moveItem(at: landed, to: outOfTheTrash)
            try? FileManager.default.moveItem(at: strangerSource, to: landed)
            // The STALE answer — exactly what losing this race yields.
            return answer
        }
    }

    /// **A-P1 — THE MESSAGE ASSERTED A FACT NO PROOF ESTABLISHES, AND IT IS
    /// FALSE ON THE VERY EVENT THE CAUSE IS NAMED FOR** (PR #460 codex r16).
    ///
    /// `.putBackTookAnotherObject` ended "…and the item the Trash took is
    /// still in the Trash". `rollBack` proved the object stood at the landing
    /// NAME; the `renameatx_np` then moved a DIFFERENT object out of that
    /// name. That is a fact about the NAME.
    ///
    /// MEASURED here, with the swap in the real one-syscall window between
    /// the two: the object the Trash took is moved OUT of the landing's own
    /// container, a stranger takes its Trash name, the undo moves the
    /// stranger to the target — and the cell proves the taken object's INODE
    /// is present nowhere under the landing's container. The old tail sent
    /// the user to look there for it while a stranger's tree stood at their
    /// cache path.
    ///
    /// MUTATION: restore the old tail and this cell fails.
    func testAPutBackThatTookAnotherObjectDoesNotClaimWhereTheTakenOneIs()
        async throws
    {
        let provider = RepointTheLandingInsideTheReBind()
        let container = try makeCacheContainer()
        let target = container.appendingPathComponent("victim")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("ours".utf8).write(
            to: target.appendingPathComponent("ours.txt")
        )
        let identity = try XCTUnwrap(provider.identity(of: target))
        let parent = try admittedParent(of: target, provider: provider)

        // THE LANDING'S OWN CONTAINER — a fixture Trash, so the cell can
        // enumerate it and prove an absence.
        let trashDir = base.appendingPathComponent("ap1-trash")
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let landed = trashDir.appendingPathComponent("victim")
        provider.landed = landed
        // OUTSIDE the container, which is the whole point.
        provider.outOfTheTrash = base.appendingPathComponent("ap1-taken-away")
        let strangerSource = base.appendingPathComponent("ap1-stranger")
        try fm.createDirectory(
            at: strangerSource, withIntermediateDirectories: true
        )
        try Data("intruder".utf8).write(
            to: strangerSource.appendingPathComponent("their-work.txt")
        )
        provider.strangerSource = strangerSource

        // WHAT THE TRASH ACTUALLY TOOK, recorded at the instant it took it.
        let taken = IdentityBox()
        let fileManager = fm
        var thrown: Error?
        do {
            try await TrashDisposal.dispose(
                target, expecting: .directory(identity), provider: provider,
                containedIn: parent,
                via: { url, prove in
                    try prove()
                    // The swap inside the mover, so the after-proof refuses
                    // and the rollback runs at all.
                    try fileManager.removeItem(at: url)
                    try fileManager.createDirectory(
                        at: url, withIntermediateDirectories: true
                    )
                    try Data("stranger".utf8).write(
                        to: url.appendingPathComponent("their-work.txt")
                    )
                    try fileManager.moveItem(at: url, to: landed)
                    taken.identity = FileSystemIdentityProvider()
                        .identity(of: landed)
                    return landed
                }
            )
        } catch {
            thrown = error
        }

        XCTAssertTrue(provider.swapped,
                      "the fixture never re-pointed the landing")
        let failure = try XCTUnwrap(
            thrown as? TrashDisposal.Failure, String(describing: thrown)
        )
        XCTAssertEqual(failure.cause, .putBackTookAnotherObject(landed.path))

        // THE PROPOSITION THE OLD TAIL ASSERTED, MEASURED FALSE: the taken
        // object's inode is present NOWHERE under the landing's container.
        let takenIdentity = try XCTUnwrap(taken.identity)
        let survivors = try fm.contentsOfDirectory(atPath: trashDir.path)
            .filter {
                FileSystemIdentityProvider().identity(
                    of: trashDir.appendingPathComponent($0)
                ) == takenIdentity
            }
        XCTAssertEqual(
            survivors, [],
            "the item the Trash took is not under \(trashDir.path) at all — "
                + "which is what the message used to tell the user"
        )
        XCTAssertEqual(
            FileSystemIdentityProvider()
                .identity(of: provider.outOfTheTrash), takenIdentity,
            "the fixture must really have moved it out of the container"
        )

        let described = try XCTUnwrap(failure.errorDescription)
        XCTAssertFalse(
            described.contains("still in the Trash"),
            "nothing here establishes where the taken object is: \(described)"
        )
        XCTAssertTrue(
            described.contains(
                "Where the item the Trash took is now was NOT established"
            ),
            described
        )
    }

    /// A box so the mover can hand back what it saw without capturing the
    /// test case.
    private final class IdentityBox {
        private let lock = NSLock()
        private var value: FileSystemIdentityProvider.Identity?
        var identity: FileSystemIdentityProvider.Identity? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    // ================================================================
    // MARK: - WHICH OF THESE CAUSES A REAL USER CAN REACH (r16, A-P3)
    // ================================================================

    /// **A-P3 — THROUGH THE SHIPPED SEAM THE UNDO PUTS THE ITEM BACK UNDER
    /// NEITHER SPELLING** (PR #460 codex r16).
    ///
    /// Every measurement behind r15's D-P1 — "PLAIN: all four arms
    /// `.putBack`" against "SYMLINKED: all four `.strandedInTrash`" — was
    /// taken through an INJECTED `trashHandler` landing in a fixture
    /// directory. That is the precise property this file's own r11 D4 note
    /// records as having hidden a defect for eight rounds: a fixture landing's
    /// PARENT is freely openable and `~/.Trash` is not.
    ///
    /// `rollBack` returns at its FIRST guard —
    /// `provider.openDirectoryNoFollow(landed.deletingLastPathComponent())`,
    /// three statements BEFORE the destination open D-P1 moved — and for an
    /// item on the HOME VOLUME that directory is `~/.Trash`, which is EPERM
    /// on every machine without Full Disk Access (measured; see `facts` and
    /// the r10 D1 note). So for home-volume items `.putBack`,
    /// `.putBackTookAnotherObject` and `.destinationNotTheAdmittedContainer`
    /// are unreachable for the default user, under either container spelling.
    ///
    /// **AND ONLY FOR HOME-VOLUME ITEMS — THE SENTENCE ABOVE USED TO OMIT
    /// THAT AND WAS THEREFORE FALSE FOR EVERY OTHER VOLUME** (PR #460 codex
    /// r17, M2). The open is of the LANDING's container, and the Trash
    /// `FileManager.trashItem` picks is per volume: an item on any other
    /// mounted volume lands in `<volume>/.Trashes/<uid>`, which TCC does not
    /// gate at all, so the undo runs to completion with no Full Disk Access
    /// anywhere. This cell cannot see that, because it uses no volume fixture
    /// — every landing it makes is in the home Trash by construction. Its
    /// counterpart `…ANonHomeVolumeUndoPutsTheItemBackWithoutFullDiskAccess`
    /// measures the other half on a temporary APFS disk image, and reaches
    /// `.putBack` and `.destinationNotTheAdmittedContainer` on all four arms
    /// with `~/.Trash` still denied.
    ///
    /// THIS CELL IS THE ONE THAT CANNOT BE FOOLED BY A FIXTURE: no
    /// `trashHandler` is injected, the mover is the shipped
    /// `FileManager.trashItem` inside the production main-actor hop, and the
    /// landing is the user's REAL `~/.Trash`. It asserts the outcome AGAINST
    /// THE PERMISSION, so it is a fact about this machine either way:
    ///
    /// * Trash unopenable (the shipped default — measured on this machine,
    ///   Darwin 25.5: `ls ~/.Trash` is "Operation not permitted" from this
    ///   process, 8/8 runs at 3110d1e): all four arms answer
    ///   `.strandedInTrash`, the stranger is LEFT in the real Trash and the
    ///   target's name is left EMPTY.
    ///   THE FORWARD DISPOSAL SUCCEEDS EVERY TIME — the defect is entirely in
    ///   the undo.
    /// * Trash openable (Full Disk Access granted): the D-P1 row, `.putBack`.
    ///
    /// D-P1's fix is still right and is still load-bearing — it is what makes
    /// the second row true for the population that HAS the permission. What
    /// was wrong was publishing it as a change to the outcome the default user
    /// sees.
    ///
    /// MUTATION — RUN, AND THE NOTE THAT STOOD HERE HAD IT BACKWARDS (PR
    /// #460 codex r17, M3). It said "this cell is not a guard … Delete
    /// `rollBack`'s trash-open guard and the run dies rather than reddening —
    /// the descriptor is `-1` and `probeChild` is asked about it", and cited
    /// no run. MEASURED at cd58104 with exactly that line — `guard trashFD >=
    /// 0 else { return .strandedInTrash(landed.path) }` — deleted and the
    /// target rebuilt, `swift test --filter TrashDisposalHopProofTests`: THE
    /// RUN DOES NOT DIE. 36 executed, 5 failures, exit 1, no crash, 6 s. The
    /// `-1` is harmless on both counts — `close(-1)` is an `EBADF` no-op and
    /// `probeChild` on `-1` answers a MISMATCH rather than trapping — so the
    /// deletion silently downgrades `.strandedInTrash` to `.lastSeenInTrash`
    /// — a WRONG CAUSE, on ALL FOUR arms of this cell (measured by printing
    /// `failure.cause` per arm under the mutation; the run's own log records
    /// two of the four as assertion failures, and the reason it records two
    /// and not four is NOT established here) — and THREE cells assert
    /// against it:
    /// `…AnUnopenableLandingStillCatchesAnObjectThatIsNotOurs`,
    /// `…TheDirectoryVerdictArmStillCatchesAStrangerUnderADeniedLanding`, and
    /// THIS ONE. So this cell is BOTH the reachability measurement the
    /// CHANGELOG cites AND one of that guard's three witnesses; the guard is
    /// evidenced, and the note that said otherwise was never run.
    ///
    /// TRASH HYGIENE: each arm's landing name is UNIQUE, so `trashItem` never
    /// suffixes it and the exact path is known before the run; each is
    /// registered for removal BY NAME before anything is moved, and absence is
    /// re-checked with `lstat` afterwards. Nothing else in the Trash is
    /// touched and the Trash is never emptied.
    func testWithoutFullDiskAccessEveryUndoStrandsTheItemInTheRealTrash()
        async throws
    {
        let provider = FileSystemIdentityProvider()
        let container = base.appendingPathComponent("real-trash-container")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        let trash = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")

        // THE PERMISSION, READ THROUGH THE SAME CALL `rollBack` MAKES.
        let trashFD = provider.openDirectoryNoFollow(at: trash)
        let fullDiskAccess = trashFD >= 0
        if fullDiskAccess { close(trashFD) }

        for arm in TrashArm.allCases {
            // UNIQUE per run, so `trashItem` cannot suffix the landing and
            // the cleanup below can name it before anything moves.
            let name = "cacheout-r16-ap3-\(arm.rawValue)-"
                + "\(UUID().uuidString.prefix(8))"
            let target = container.appendingPathComponent(name)
            let landing = trash.appendingPathComponent(name)
            XCTAssertFalse(
                fm.fileExists(atPath: landing.path),
                "\(name): the landing name must be free before the run"
            )
            // Registered BEFORE the disposal: this exact path is removed
            // however the cell ends. Only this path — never the Trash itself.
            addTeardownBlock { try? FileManager.default.removeItem(at: landing) }

            let directory = arm.targetIsADirectory
            if directory {
                try fm.createDirectory(
                    at: target, withIntermediateDirectories: true
                )
                try Data("ours".utf8).write(
                    to: target.appendingPathComponent("ours.txt")
                )
            } else {
                try Data("ours".utf8).write(to: target)
            }
            let parent = try admittedParent(of: target, provider: provider)

            // THE PRODUCTION MOVER, SPELLED THE WAY `CacheCleaner` SPELLS ITS
            // DEFAULT: the main-actor hop, `prove()` on its far side, then
            // `FileManager.trashItem`. The swap rides the window
            // `trashItem`'s own URL resolution owns.
            let mover: TrashDisposal.Mover = { url, prove in
                try await MainActor.run {
                    try prove()
                    // `FileManager.default` rather than a captured instance:
                    // the hop's closure is `@Sendable` and `FileManager` is
                    // not, which is a Swift 6 error rather than a warning.
                    let manager = FileManager.default
                    try manager.removeItem(at: url)
                    if directory {
                        try manager.createDirectory(
                            at: url, withIntermediateDirectories: true
                        )
                        try Data("stranger".utf8).write(
                            to: url.appendingPathComponent("their-work.txt")
                        )
                    } else {
                        try Data("stranger".utf8).write(to: url)
                    }
                    var landed: NSURL?
                    try manager.trashItem(at: url, resultingItemURL: &landed)
                    return landed as URL?
                }
            }

            var thrown: Error?
            do {
                switch arm {
                case .noVerdict:
                    try await TrashDisposal.dispose(
                        target, containedIn: parent, provider: provider,
                        via: mover
                    )
                case .noDirectoryTree:
                    try await TrashDisposal.dispose(
                        target, expecting: .noDirectoryTree,
                        provider: provider, containedIn: parent, via: mover
                    )
                case .nonDirectoryLeaf:
                    let identity = try XCTUnwrap(provider.identity(of: target))
                    try await TrashDisposal.dispose(
                        target, expecting: .nonDirectoryLeaf(identity),
                        provider: provider, containedIn: parent, via: mover
                    )
                case .directory:
                    let identity = try XCTUnwrap(provider.identity(of: target))
                    try await TrashDisposal.dispose(
                        target, expecting: .directory(identity),
                        provider: provider, containedIn: parent, via: mover
                    )
                }
            } catch {
                thrown = error
            }

            let failure = try XCTUnwrap(
                thrown as? TrashDisposal.Failure,
                "\(name): an object replaced inside the mover must be "
                    + "refused: \(String(describing: thrown))"
            )
            // THE FORWARD HALF SUCCEEDED, ON EVERY ARM AND EITHER
            // PERMISSION: the stranger really did reach the real Trash.
            XCTAssertTrue(
                fm.fileExists(atPath: landing.path),
                "\(name): the shipped seam must really have moved the "
                    + "stranger into \(trash.path)"
            )

            if fullDiskAccess {
                XCTAssertEqual(
                    failure.cause, .putBack,
                    "\(name): with the Trash openable this is the D-P1 row"
                )
            } else {
                XCTAssertEqual(
                    failure.cause, .strandedInTrash(landing.path),
                    "\(name): without Full Disk Access `rollBack` returns at "
                        + "its FIRST guard — the Trash open — three "
                        + "statements before the destination open D-P1 fixed"
                )
                XCTAssertFalse(
                    fm.fileExists(atPath: target.path),
                    "\(name): and the target's name is left EMPTY — the "
                        + "put-back was never attempted"
                )
            }

            // REMOVED BY NAME, AND THE ABSENCE VERIFIED — not left for the
            // teardown block alone.
            try? fm.removeItem(at: landing)
            var probe = stat()
            XCTAssertNotEqual(
                lstat(landing.path, &probe), 0,
                "\(name): this cell's own leaving must be gone from the Trash"
            )
        }
    }

    // ================================================================
    // MARK: - AND THE SAME QUESTION ON A VOLUME THAT IS NOT HOME (r17, M2)
    // ================================================================

    /// Run `tool` to completion and answer its exit status.
    ///
    /// `waitForExit(within:)` rather than `waitUntilExit()`: this suite
    /// spawns and reaps processes concurrently, and `waitUntilExit` can miss
    /// its termination wakeup under exactly that load (see the extension's
    /// own note in `CacheCategory.swift`).
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        guard process.waitForExit(within: 120) else {
            process.terminate()
            return -1
        }
        return process.terminationStatus
    }

    /// Drive ONE of the four Trash arms at `target`, and answer what it threw.
    private func disposeThroughTheArm(
        _ arm: TrashArm, of target: URL,
        containedIn parent: DepthSafeRemoval.AdmittedParent,
        provider: FileSystemIdentityProvider,
        via mover: @escaping TrashDisposal.Mover
    ) async throws -> Error? {
        do {
            switch arm {
            case .noVerdict:
                try await TrashDisposal.dispose(
                    target, containedIn: parent, provider: provider, via: mover
                )
            case .noDirectoryTree:
                try await TrashDisposal.dispose(
                    target, expecting: .noDirectoryTree, provider: provider,
                    containedIn: parent, via: mover
                )
            case .nonDirectoryLeaf:
                let identity = try XCTUnwrap(provider.identity(of: target))
                try await TrashDisposal.dispose(
                    target, expecting: .nonDirectoryLeaf(identity),
                    provider: provider, containedIn: parent, via: mover
                )
            case .directory:
                let identity = try XCTUnwrap(provider.identity(of: target))
                try await TrashDisposal.dispose(
                    target, expecting: .directory(identity),
                    provider: provider, containedIn: parent, via: mover
                )
            }
        } catch {
            return error
        }
        return nil
    }

    /// **M2 — A-P3's REACHABILITY CLAIM IS FALSE FOR EVERY ITEM THAT IS NOT
    /// ON THE HOME VOLUME** (PR #460 codex r17).
    ///
    /// A-P3 measured `~/.Trash`, found it EPERM without Full Disk Access, and
    /// published the finding as "`.putBack`, `.putBackTookAnotherObject` and
    /// `.destinationNotTheAdmittedContainer` are ALL UNREACHABLE for the
    /// default user". THE PERMISSION IS NOT THE POPULATION. `rollBack` opens
    /// `landed.deletingLastPathComponent()`, and that directory is `~/.Trash`
    /// only for items that live on the HOME volume. For an item on any other
    /// mounted volume `FileManager.trashItem` lands it in
    /// `<volume>/.Trashes/<uid>` — a directory TCC does not gate at all — so
    /// the undo runs to completion with no Full Disk Access anywhere in
    /// sight. A-P3's own cell could not see this because it uses no volume
    /// fixture: every landing it produces is in the home Trash by
    /// construction.
    ///
    /// THIS CELL IS THE OTHER HALF OF THAT MEASUREMENT, taken in the SAME
    /// process and the same run as A-P3's: no `trashHandler` is injected, the
    /// mover is the shipped `FileManager.trashItem` inside the production
    /// main-actor hop, and the landing is whatever the real Trash mechanism
    /// picks for a temporary APFS disk image attached under this test's own
    /// directory. It first asserts that `~/.Trash` really is closed to this
    /// process (skipping if the machine HAS Full Disk Access, because then
    /// both rows coincide and there is no split to show), then measures both
    /// rows the corrected claim names:
    ///
    /// * `.putBack` — the ordinary swap, all four arms;
    /// * `.destinationNotTheAdmittedContainer` — the container replaced after
    ///   the move, all four arms.
    ///
    /// Two of the three causes A-P3 called unreachable, reached, with the
    /// permission A-P3 measured still denied.
    ///
    /// TRASH HYGIENE: nothing here goes near the user's Trash. Every landing
    /// is inside the disk image, which is detached and deleted in teardown.
    func testANonHomeVolumeUndoPutsTheItemBackWithoutFullDiskAccess()
        async throws
    {
        let provider = FileSystemIdentityProvider()

        // (0) THE PERMISSION A-P3 MEASURED, READ THROUGH THE SAME CALL
        // `rollBack` MAKES. If it is OPEN this machine has Full Disk Access
        // and the two rows coincide, so there is nothing to separate.
        let homeTrash = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")
        let homeFD = provider.openDirectoryNoFollow(at: homeTrash)
        if homeFD >= 0 { close(homeFD) }
        try XCTSkipIf(
            homeFD >= 0,
            "Full Disk Access is granted here: A-P3's row and this one "
                + "coincide, so the split by volume cannot be measured"
        )

        // (1) A REAL SECOND VOLUME, mounted inside this test's own directory.
        let image = base.appendingPathComponent("r17-m2.dmg")
        let mount = base.appendingPathComponent("r17-m2-volume")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/hdiutil", [
            "create", "-size", "16m", "-fs", "APFS", "-volname",
            "CacheoutR17M2", "-type", "UDIF", "-quiet", image.path,
        ]) == 0 else { throw XCTSkip("hdiutil create unavailable") }
        guard Self.run("/usr/bin/hdiutil", [
            "attach", image.path, "-mountpoint", mount.path,
            "-nobrowse", "-noverify", "-quiet",
        ]) == 0 else { throw XCTSkip("hdiutil attach unavailable") }
        addTeardownBlock {
            _ = Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        }
        let volumeTrash = mount.appendingPathComponent(".Trashes")
            .appendingPathComponent("\(getuid())")

        // ---- ROW ONE: the ordinary swap. A-P3 says `.strandedInTrash`;
        // off the home volume it is `.putBack`, on every arm.
        for arm in TrashArm.allCases {
            let container = mount
                .appendingPathComponent("box-putback-\(arm.rawValue)")
            try fm.createDirectory(
                at: container, withIntermediateDirectories: true
            )
            let name = "putback-\(arm.rawValue)"
            let target = container.appendingPathComponent(name)
            let directory = arm.targetIsADirectory
            if directory {
                try fm.createDirectory(
                    at: target, withIntermediateDirectories: true
                )
                try Data("ours".utf8).write(
                    to: target.appendingPathComponent("ours.txt")
                )
            } else {
                try Data("ours".utf8).write(to: target)
            }
            let parent = try admittedParent(of: target, provider: provider)

            let mover: TrashDisposal.Mover = { url, prove in
                try await MainActor.run {
                    try prove()
                    let manager = FileManager.default
                    try manager.removeItem(at: url)
                    if directory {
                        try manager.createDirectory(
                            at: url, withIntermediateDirectories: true
                        )
                        try Data("stranger".utf8).write(
                            to: url.appendingPathComponent("their-work.txt")
                        )
                    } else {
                        try Data("stranger".utf8).write(to: url)
                    }
                    var landed: NSURL?
                    try manager.trashItem(at: url, resultingItemURL: &landed)
                    return landed as URL?
                }
            }

            let thrown = try await disposeThroughTheArm(
                arm, of: target, containedIn: parent, provider: provider,
                via: mover
            )
            let failure = try XCTUnwrap(
                thrown as? TrashDisposal.Failure,
                "\(name): \(String(describing: thrown))"
            )
            XCTAssertEqual(
                failure.cause, .putBack,
                "\(name): the volume's own .Trashes IS openable, so "
                    + "`rollBack` runs past the guard that ends A-P3's row"
            )
            XCTAssertTrue(
                fm.fileExists(atPath: target.path),
                "\(name): the object the Trash took is back at the target"
            )
            XCTAssertFalse(
                fm.fileExists(
                    atPath: volumeTrash.appendingPathComponent(name).path
                ),
                "\(name): and it is no longer in the volume's Trash"
            )
        }

        // (2) THE FACT THAT MAKES THE SPLIT, read side by side: the home
        // Trash is closed to this process (asserted at (0)) and the volume's
        // is not. `.Trashes/<uid>` exists now — row one created it.
        let volumeFD = provider.openDirectoryNoFollow(at: volumeTrash)
        XCTAssertGreaterThanOrEqual(
            volumeFD, 0,
            "the whole split: \(volumeTrash.path) must be openable by a "
                + "process that may not open \(homeTrash.path)"
        )
        if volumeFD >= 0 { close(volumeFD) }

        // ---- ROW TWO: the container replaced AFTER the move, which A-P3
        // also called unreachable for the default user.
        for arm in TrashArm.allCases {
            let container = mount
                .appendingPathComponent("box-drift-\(arm.rawValue)")
            try fm.createDirectory(
                at: container, withIntermediateDirectories: true
            )
            let name = "drift-\(arm.rawValue)"
            let target = container.appendingPathComponent(name)
            let directory = arm.targetIsADirectory
            if directory {
                try fm.createDirectory(
                    at: target, withIntermediateDirectories: true
                )
                try Data("ours".utf8).write(
                    to: target.appendingPathComponent("ours.txt")
                )
            } else {
                try Data("ours".utf8).write(to: target)
            }
            let parent = try admittedParent(of: target, provider: provider)
            let displaced = mount
                .appendingPathComponent("gone-\(arm.rawValue)")

            let mover: TrashDisposal.Mover = { url, prove in
                try await MainActor.run {
                    try prove()
                    let manager = FileManager.default
                    try manager.removeItem(at: url)
                    if directory {
                        try manager.createDirectory(
                            at: url, withIntermediateDirectories: true
                        )
                        try Data("stranger".utf8).write(
                            to: url.appendingPathComponent("their-work.txt")
                        )
                    } else {
                        try Data("stranger".utf8).write(to: url)
                    }
                    var landed: NSURL?
                    try manager.trashItem(at: url, resultingItemURL: &landed)
                    // …and NOW the folder that holds the target is a
                    // different inode answering to the same name.
                    try manager.moveItem(at: container, to: displaced)
                    try manager.createDirectory(
                        at: container, withIntermediateDirectories: true
                    )
                    return landed as URL?
                }
            }

            let thrown = try await disposeThroughTheArm(
                arm, of: target, containedIn: parent, provider: provider,
                via: mover
            )
            let failure = try XCTUnwrap(
                thrown as? TrashDisposal.Failure,
                "\(name): \(String(describing: thrown))"
            )
            guard case .destinationNotTheAdmittedContainer(let landedPath)
                = failure.cause
            else {
                XCTFail("\(name): \(failure.cause)")
                continue
            }
            XCTAssertEqual(
                URL(fileURLWithPath: landedPath)
                    .resolvingSymlinksInPath().path,
                volumeTrash.appendingPathComponent(name)
                    .resolvingSymlinksInPath().path,
                "\(name): the refusal names the volume's own Trash"
            )
            XCTAssertTrue(
                fm.fileExists(
                    atPath: volumeTrash.appendingPathComponent(name).path
                ),
                "\(name): the disclosed residual — nothing was put back, so "
                    + "the object stays where the refusal says it is"
            )
        }
    }

    /// Drive one of the four Trash arms with a mover that PROVES, moves
    /// nothing, and reports `landed` anyway.
    private func outcomeOfAMoverThatMovesNothing(
        _ arm: TrashArm, of target: URL, reporting landed: URL,
        provider: FileSystemIdentityProvider
    ) async throws -> Error? {
        let parent = try admittedParent(of: target, provider: provider)
        let mover: TrashDisposal.Mover = { _, prove in
            try prove()
            return landed
        }
        do {
            switch arm {
            case .noVerdict:
                try await TrashDisposal.dispose(
                    target, containedIn: parent, provider: provider,
                    via: mover
                )
            case .noDirectoryTree:
                try await TrashDisposal.dispose(
                    target, expecting: .noDirectoryTree, provider: provider,
                    containedIn: parent, via: mover
                )
            case .nonDirectoryLeaf:
                let identity = try XCTUnwrap(provider.identity(of: target))
                try await TrashDisposal.dispose(
                    target, expecting: .nonDirectoryLeaf(identity),
                    provider: provider, containedIn: parent, via: mover
                )
            case .directory:
                let identity = try XCTUnwrap(provider.identity(of: target))
                try await TrashDisposal.dispose(
                    target, expecting: .directory(identity),
                    provider: provider, containedIn: parent, via: mover
                )
            }
        } catch {
            return error
        }
        return nil
    }
}
