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
/// | …and step (0)'s `proveAdmittedContainer` deleted as well (the r12 state) | **4** — the two above, `…RefusesAStrangerInAnotherContainer`, `…NamesContainerDriftAsContainerDrift` |
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
        XCTAssertEqual(failure.cause, .lastSeenInTrash(landed.path))
        XCTAssertTrue(
            fm.fileExists(atPath: target.appendingPathComponent("ours.txt").path),
            "nothing was moved"
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
    /// MUTATION: delete step (0)'s `proveAdmittedContainer` and this cell
    /// fails on the cause (the disposal is still refused — that is the
    /// point: it is a taxonomy defect, not a destruction one).
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
}
