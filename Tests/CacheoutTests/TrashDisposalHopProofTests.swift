import XCTest
@testable import Cacheout

/// # The proofs `TrashDisposal` runs on the FAR SIDE of the mover's hop
///
/// r6 added three of them — one per `dispose` arm — and shipped all three
/// UNEVIDENCED. PR #460 codex r7, D3 measured it: deleting each in turn (M2,
/// the no-leaf-verdict overload; M3, the `.nonDirectoryLeaf` arm; M4, the
/// `proveStanding` arm) left the FULL suite at 1471 executed / 2 skipped /
/// 0 failures, exit 0. A guard no cell can kill is a guard nobody is holding
/// to its contract, and this branch's own doctrine is that such a guard is
/// deleted or evidenced. These three cells evidence them.
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
    }
}
